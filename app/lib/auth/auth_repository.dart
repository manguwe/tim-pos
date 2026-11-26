import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../core/uuid7.dart';
import '../data/sql_db.dart';

/// Staff, roles and PINs. Port of tools/src/auth.ts, which is tested against the real schema.
/// PINs are checked here, on the phone, against a salted PBKDF2-SHA256 hash, so login works offline.
/// Wrong-PIN counts live in device_state (this phone only, never synced).

const int pbkdf2Iterations = 10000;
const int lockAfter = 5;
const int baseLockMs = 5 * 60000;
const int maxLockMs = 60 * 60000;

const List<String> allPermissions = [
  'sale.create', 'sale.discount', 'sale.void', 'sale.refund', 'price.edit', 'cost.view', 'stock.receive', 'stock.adjust',
  'product.edit', 'customer.manage', 'shift.manage', 'report.view', 'data.export', 'user.manage', 'settings.edit', 'rate.edit', 'supplier.pay',
];

const Map<String, String> roleNames = {'owner': 'Owner', 'manager': 'Manager', 'cashier': 'Cashier', 'stock_clerk': 'Stock clerk'};
const Map<String, List<String>> defaultRoles = {
  'owner': allPermissions,
  'manager': ['sale.create', 'sale.discount', 'sale.void', 'sale.refund', 'price.edit', 'cost.view', 'stock.receive', 'stock.adjust', 'product.edit', 'customer.manage', 'shift.manage', 'report.view', 'rate.edit', 'supplier.pay'],
  'cashier': ['sale.create', 'shift.manage'],
  'stock_clerk': ['stock.receive', 'product.edit', 'cost.view'],
};

/// The code the vendor reads out so someone who forgot their PIN can choose a new one. Matches pinResetCode() in server/src/crypto.ts.
String pinResetCode(String recoveryKey, String challenge, String userId) {
  final mac = Hmac(sha256, utf8.encode(recoveryKey)).convert(utf8.encode('$challenge|$userId')).bytes;
  final n = (mac[0] << 24) | (mac[1] << 16) | (mac[2] << 8) | mac[3];
  return (n % 100000000).toString().padLeft(8, '0');
}

class AuthError implements Exception {
  AuthError(this.code, this.message, [this.detail = const {}]);
  final String code;
  final String message;
  final Map<String, Object?> detail;
  @override
  String toString() => 'AuthError($code): $message';
}

/// Returns null if the PIN is acceptable, else the reason in words.
String? validatePin(String pin) {
  if (!RegExp(r'^\d{4,8}$').hasMatch(pin)) return 'A PIN is 4 to 8 digits.';
  if (RegExp(r'^(\d)\1+$').hasMatch(pin)) return 'Choose a PIN that is not all the same digit.';
  final d = pin.codeUnits.map((c) => c - 48).toList();
  final step = d[1] - d[0];
  if ((step == 1 || step == -1)) {
    var run = true;
    for (var i = 1; i < d.length; i++) {
      if (d[i] - d[i - 1] != step) run = false;
    }
    if (run) return 'Choose a PIN that is not a simple run of digits.';
  }
  return null;
}

/// PBKDF2 with HMAC-SHA256, one 32-byte block (what node's pbkdf2Sync gives for a 32-byte key).
Uint8List pbkdf2Sha256(List<int> password, List<int> salt, int iterations) {
  final hmac = Hmac(sha256, password);
  var u = Uint8List.fromList(hmac.convert([...salt, 0, 0, 0, 1]).bytes);
  final t = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = Uint8List.fromList(hmac.convert(u).bytes);
    for (var j = 0; j < t.length; j++) {
      t[j] ^= u[j];
    }
  }
  return t;
}

/// pbkdf2-sha256$<iterations>$<salt b64>$<hash b64>
String hashPin(String pin, {List<int>? salt, int iterations = pbkdf2Iterations}) {
  final s = salt ?? List<int>.generate(16, (_) => Random.secure().nextInt(256));
  final h = pbkdf2Sha256(utf8.encode(pin), s, iterations);
  return 'pbkdf2-sha256\$$iterations\$${base64.encode(s)}\$${base64.encode(h)}';
}

bool verifyPin(String pin, String? stored) {
  if (stored == null) return false;
  final parts = stored.split(r'$');
  if (parts.length != 4 || parts[0] != 'pbkdf2-sha256') return false;
  final n = int.tryParse(parts[1]);
  if (n == null || n < 1 || n > 10000000) return false;
  try {
    final want = base64.decode(parts[3]);
    final got = pbkdf2Sha256(utf8.encode(pin), base64.decode(parts[2]), n);
    if (want.length != got.length) return false;
    var diff = 0; // constant-time compare
    for (var i = 0; i < want.length; i++) {
      diff |= want[i] ^ got[i];
    }
    return diff == 0;
  } on FormatException {
    return false;
  }
}

/// 5 minutes after the 5th wrong PIN, doubling with each further one, up to an hour.
int lockDuration(int failed) {
  if (failed < lockAfter) return 0;
  final d = baseLockMs * (1 << min(failed - lockAfter, 20));
  return min(d, maxLockMs);
}

class SignedIn {
  const SignedIn({required this.id, required this.name, required this.roleId, required this.permissions});
  final String id;
  final String name;
  final String? roleId;
  final Set<String> permissions;
  bool can(String p) => permissions.contains(p);
}

class LoginUser {
  const LoginUser(this.id, this.name, this.role);
  final String id;
  final String name;
  final String? role;
}

typedef _Row = Map<String, Object?>;

class AuthRepository {
  AuthRepository({required this.db, required this.shopId, required this.deviceId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId;
  final String deviceId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<String> _add(SqlDb tx, String table, _Row row, int now, String? actor, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': actor, 'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  Future<void> _edit(SqlDb tx, String table, String id, _Row set, int now) async {
    final cur = await _get(tx, 'select version from "$table" where id = ?', [id]);
    if (cur == null) throw AuthError('unknown_user', 'That record was not found.');
    final o = <String, Object?>{...set, 'version': _i(cur['version']) + 1, 'updated_at': now};
    final k = o.keys.toList();
    await tx.exec('update "$table" set ${k.map((x) => '"$x" = ?').join(', ')} where id = ?', [...k.map((x) => o[x]), id]);
  }

  Future<void> _audit(SqlDb tx, String? actor, String action, String? rowId, int now, [Object? after]) =>
      _add(tx, 'audit_log', {'user_id': actor, 'action': action, 'table_name': 'users', 'row_id': rowId, 'after': after == null ? null : jsonEncode(after)}, now, actor);

  // ---- permissions ----

  Future<Set<String>> permissionsOf(String userId, [SqlDb? tx]) async {
    final r = await _get(
      tx ?? db,
      'select r.permissions from users u join roles r on r.id = u.role_id '
      'where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null',
      [userId],
    );
    if (r == null) return {};
    try {
      final list = jsonDecode(r['permissions'] as String);
      return list is List ? list.whereType<String>().toSet() : {};
    } on FormatException {
      return {};
    }
  }

  Future<bool> hasPermission(String userId, String permission) async => (await permissionsOf(userId)).contains(permission);

  Future<void> _require(String? userId, String permission) async {
    if (userId == null || !await hasPermission(userId, permission)) {
      throw AuthError('forbidden', 'You do not have permission to do that.', {'permission': permission});
    }
  }

  // ---- lockout (this phone only) ----

  Future<({int failed, int until})> _readLock(SqlDb tx, String userId) async {
    final r = await _get(tx, 'select value from device_state where key = ?', ['lock:$userId']);
    if (r == null) return (failed: 0, until: 0);
    try {
      final v = jsonDecode(r['value'] as String) as Map<String, dynamic>;
      return (failed: (v['failed'] as num?)?.toInt() ?? 0, until: (v['until'] as num?)?.toInt() ?? 0);
    } catch (_) {
      return (failed: 0, until: 0);
    }
  }

  Future<void> _writeLock(SqlDb tx, String userId, int failed, int until) async {
    if (failed == 0 && until == 0) {
      await tx.exec('delete from device_state where key = ?', ['lock:$userId']);
    } else {
      await tx.exec(
        'insert into device_state (key, value) values (?, ?) on conflict (key) do update set value = excluded.value',
        ['lock:$userId', jsonEncode({'failed': failed, 'until': until})],
      );
    }
  }

  // ---- login ----

  Future<List<LoginUser>> listLoginUsers() async {
    final rows = await db.query(
      'select u.id, u.name, r.name as role from users u left join roles r on r.id = u.role_id '
      'where u.deleted_at is null and u.is_active = 1 and u.pin_hash is not null order by u.name',
    );
    return [for (final r in rows) LoginUser(r['id'] as String, r['name'] as String, r['role'] as String?)];
  }

  Future<bool> hasUsers() async => (await listLoginUsers()).isNotEmpty;

  /// Checks the PIN. Failed attempts and the lock are saved even though the call then throws, so they survive the failure.
  Future<SignedIn> login(String userId, String pin) async {
    final now = _clock();
    AuthError? failure;
    SignedIn? ok;
    await db.transaction((tx) async {
      final u = await _get(tx, 'select * from users where id = ? and deleted_at is null', [userId]);
      if (u == null) {
        failure = AuthError('unknown_user', 'That user was not found.');
        return;
      }
      if (u['is_active'] != 1) {
        failure = AuthError('inactive', 'This user has been switched off.');
        return;
      }
      if (u['pin_hash'] == null) {
        failure = AuthError('no_pin', 'This user has no PIN yet.');
        return;
      }
      final lock = await _readLock(tx, userId);
      if (lock.until > now) {
        failure = AuthError('locked', 'Too many wrong PINs. Try again later.', {'until': lock.until});
        return;
      }
      if (verifyPin(pin, u['pin_hash'] as String)) {
        await _writeLock(tx, userId, 0, 0);
        await _audit(tx, userId, 'login', userId, now);
        ok = SignedIn(id: userId, name: u['name'] as String, roleId: u['role_id'] as String?, permissions: await permissionsOf(userId, tx));
        return;
      }
      final failed = lock.failed + 1;
      final dur = lockDuration(failed);
      await _writeLock(tx, userId, failed, dur > 0 ? now + dur : 0);
      await _audit(tx, userId, 'login_failed', userId, now);
      failure = dur > 0
          ? AuthError('locked', 'Too many wrong PINs. Try again later.', {'until': now + dur})
          : AuthError('wrong_pin', 'Wrong PIN.', {'attempts_left': lockAfter - failed});
    });
    if (failure != null) throw failure!;
    return ok!;
  }

  // ---- managing staff ----

  String _cleanName(String n) {
    final t = n.trim();
    if (t.isEmpty) throw AuthError('missing', 'Enter a name.');
    return t;
  }

  Future<String?> _ownerRoleId(SqlDb tx) async => (await _get(tx, "select id from roles where name = 'Owner' and deleted_at is null"))?['id'] as String?;

  Future<int> _activeOwners(SqlDb tx, String exceptUserId) async {
    final o = await _ownerRoleId(tx);
    if (o == null) return 0;
    final r = await _get(tx, 'select count(*) c from users where role_id = ? and is_active = 1 and deleted_at is null and id <> ?', [o, exceptUserId]);
    return _i(r!['c']);
  }

  Future<List<Map<String, Object?>>> listStaff() => db.query(
        'select u.id, u.name, u.phone, u.is_active, r.name as role, u.role_id from users u left join roles r on r.id = u.role_id '
        'where u.deleted_at is null order by u.is_active desc, u.name',
      );

  Future<List<Map<String, Object?>>> listRoles() => db.query('select id, name from roles where deleted_at is null order by name');

  Future<String> createUser(String actorId, {required String name, String? phone, required String roleId, required String pin, List<String> branchIds = const []}) async {
    await _require(actorId, 'user.manage');
    final cleaned = _cleanName(name);
    final bad = validatePin(pin);
    if (bad != null) throw AuthError('weak_pin', bad);
    final hash = hashPin(pin);
    final now = _clock();
    return db.transaction((tx) async {
      if (await _get(tx, 'select 1 as x from roles where id = ? and deleted_at is null', [roleId]) == null) throw AuthError('unknown_role', 'That role was not found.');
      if (await _get(tx, 'select 1 as x from users where lower(name) = lower(?) and deleted_at is null and is_active = 1', [cleaned]) != null) {
        throw AuthError('name_taken', 'Someone with that name already works here.');
      }
      final id = await _add(tx, 'users', {'name': cleaned, 'phone': (phone ?? '').trim().isEmpty ? null : phone!.trim(), 'role_id': roleId, 'pin_hash': hash, 'is_active': 1}, now, actorId, versioned: true);
      for (final b in branchIds) {
        await _add(tx, 'user_branches', {'user_id': id, 'branch_id': b}, now, actorId, versioned: true);
      }
      await _audit(tx, actorId, 'user_created', id, now, {'role_id': roleId});
      return id;
    });
  }

  Future<void> changeRole(String actorId, String userId, String roleId) async {
    await _require(actorId, 'user.manage');
    final now = _clock();
    await db.transaction((tx) async {
      final u = await _get(tx, 'select role_id, is_active from users where id = ? and deleted_at is null', [userId]);
      if (u == null) throw AuthError('unknown_user', 'That user was not found.');
      if (await _get(tx, 'select 1 as x from roles where id = ? and deleted_at is null', [roleId]) == null) throw AuthError('unknown_role', 'That role was not found.');
      if (u['role_id'] == await _ownerRoleId(tx) && roleId != u['role_id'] && u['is_active'] == 1 && await _activeOwners(tx, userId) == 0) {
        throw AuthError('last_owner', 'The shop must keep at least one owner.');
      }
      await _edit(tx, 'users', userId, {'role_id': roleId}, now);
      await _audit(tx, actorId, 'role_changed', userId, now, {'role_id': roleId});
    });
  }

  Future<void> setActive(String actorId, String userId, bool active) async {
    await _require(actorId, 'user.manage');
    if (!active && userId == actorId) throw AuthError('self', 'You cannot switch yourself off.');
    final now = _clock();
    await db.transaction((tx) async {
      final u = await _get(tx, 'select role_id, is_active from users where id = ? and deleted_at is null', [userId]);
      if (u == null) throw AuthError('unknown_user', 'That user was not found.');
      if (!active && u['role_id'] == await _ownerRoleId(tx) && u['is_active'] == 1 && await _activeOwners(tx, userId) == 0) {
        throw AuthError('last_owner', 'The shop must keep at least one owner.');
      }
      await _edit(tx, 'users', userId, {'is_active': active ? 1 : 0}, now);
      await _audit(tx, actorId, active ? 'user_enabled' : 'user_disabled', userId, now);
    });
  }

  /// A manager of users sets a new PIN for someone (a forgotten PIN). Also clears that person's lock on this phone.
  Future<void> resetPin(String actorId, String userId, String newPin) async {
    await _require(actorId, 'user.manage');
    final bad = validatePin(newPin);
    if (bad != null) throw AuthError('weak_pin', bad);
    final hash = hashPin(newPin);
    final now = _clock();
    await db.transaction((tx) async {
      await _edit(tx, 'users', userId, {'pin_hash': hash}, now);
      await _writeLock(tx, userId, 0, 0);
      await _audit(tx, actorId, 'pin_reset', userId, now);
    });
  }

  /// Starts a forgotten-PIN request: makes an 8-digit number to read to the vendor. It is good for 24 hours and 5 wrong codes.
  Future<String> startPinRecovery() async {
    final r = Random.secure();
    final challenge = List.generate(8, (_) => r.nextInt(10)).join();
    final now = _clock();
    await db.transaction((tx) async {
      await tx.exec(
        'insert into device_state (key, value) values (?, ?) on conflict (key) do update set value = excluded.value',
        ['pin_recovery', jsonEncode({'challenge': challenge, 'at': now, 'tries': 0})],
      );
    });
    return challenge;
  }

  /// The number currently waiting for a code, if it is still valid.
  Future<String?> pendingPinRecovery() async {
    final row = await db.query('select value from device_state where key = ?', ['pin_recovery']);
    if (row.isEmpty) return null;
    final v = jsonDecode(row.first['value'] as String) as Map<String, dynamic>;
    if (_clock() - (v['at'] as num).toInt() > 24 * 3600000) return null;
    return v['challenge'] as String;
  }

  /// Checks the vendor's code for this person and, if right, sets the new PIN and clears the lock.
  Future<void> recoverPin({required String userId, required String recoveryKey, required String code, required String newPin}) async {
    if (recoveryKey.isEmpty) throw AuthError('no_key', 'Connect to the internet once so this phone can get its recovery key, then try again.');
    final bad = validatePin(newPin);
    if (bad != null) throw AuthError('weak_pin', bad);
    final now = _clock();
    AuthError? failure;
    await db.transaction((tx) async {
      final r = await _get(tx, 'select value from device_state where key = ?', ['pin_recovery']);
      if (r == null) {
        failure = AuthError('no_request', 'Tap "Forgot PIN" again to get a new number.');
        return;
      }
      final v = jsonDecode(r['value'] as String) as Map<String, dynamic>;
      final tries = (v['tries'] as num).toInt();
      if (now - (v['at'] as num).toInt() > 24 * 3600000 || tries >= 5) {
        await tx.exec('delete from device_state where key = ?', ['pin_recovery']);
        failure = AuthError('expired', 'That request has expired. Tap "Forgot PIN" again to get a new number.');
        return;
      }
      final want = pinResetCode(recoveryKey, v['challenge'] as String, userId);
      if (code.trim() != want) {
        v['tries'] = tries + 1;
        await tx.exec('update device_state set value = ? where key = ?', [jsonEncode(v), 'pin_recovery']);
        failure = AuthError('wrong_code', 'That code is not right. ${4 - tries} ${4 - tries == 1 ? 'try' : 'tries'} left.');
        return;
      }
      final hash = hashPin(newPin);
      await _edit(tx, 'users', userId, {'pin_hash': hash}, now);
      await _writeLock(tx, userId, 0, 0);
      await tx.exec('delete from device_state where key = ?', ['pin_recovery']);
      await _audit(tx, userId, 'pin_recovered', userId, now);
    });
    if (failure != null) throw failure!;
  }

  /// Someone changes their own PIN; the old one must be right (and counts towards the lock if not).
  Future<void> changeOwnPin(String userId, String oldPin, String newPin) async {
    final bad = validatePin(newPin);
    if (bad != null) throw AuthError('weak_pin', bad);
    await login(userId, oldPin);
    final hash = hashPin(newPin);
    final now = _clock();
    await db.transaction((tx) async {
      await _edit(tx, 'users', userId, {'pin_hash': hash}, now);
      await _audit(tx, userId, 'pin_changed', userId, now);
    });
  }

  /// A second person approves a risky action on the spot with their own PIN. The approval is recorded and the approver's id returned.
  Future<String> approve({required String action, String? requestedBy, required String approverId, required String pin, String? refType, String? refId}) async {
    await login(approverId, pin);
    if (!await hasPermission(approverId, action)) throw AuthError('forbidden', 'That person cannot approve this action.', {'permission': action});
    final now = _clock();
    return db.transaction((tx) => _add(tx, 'approvals', {'action': action, 'requested_by': requestedBy, 'approved_by': approverId, 'ref_type': refType, 'ref_id': refId}, now, requestedBy));
  }
}
