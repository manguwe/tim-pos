/// Shifts and cash-up. Port of tools/src/shifts.ts (read the notes at the top of that file).
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

class ShiftInfo {
  const ShiftInfo({required this.id, required this.branchId, required this.userId, required this.openedAt});
  final String id, branchId;
  final String? userId;
  final int openedAt;
}

class CashEventLine {
  const CashEventLine(this.type, this.currency, this.amountMinor, this.reason);
  final String type, currency;
  final int amountMinor;
  final String? reason;
}

class Taking {
  const Taking(this.method, this.currency, this.amountMinor);
  final String method, currency;
  final int amountMinor;
}

class ShiftReport {
  const ShiftReport({
    required this.shiftId, required this.status, required this.openedAt, this.closedAt, this.user, required this.sales, required this.voided,
    required this.sold, required this.takings, required this.refunds, required this.float, required this.expected, required this.counted, required this.difference, required this.events,
  });
  final String shiftId, status;
  final int openedAt;
  final int? closedAt;
  final String? user;
  final int sales, voided;
  final Map<String, int> sold; // sale currency -> total
  final List<Taking> takings;

  /// Money paid back to customers during this shift (returns, voids).
  final List<Taking> refunds;
  final Map<String, int> float, expected;
  final Map<String, int?> counted, difference;
  final List<CashEventLine> events;
}

class ShiftRepository {
  ShiftRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();
  bool _minor(int n) => n >= 0 && n <= 10000000000;

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<bool> _has(SqlDb tx, String? uid, String permission) async {
    if (uid == null) return false;
    final r = await _get(tx, 'select r.permissions from users u join roles r on r.id = u.role_id where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null', [uid]);
    if (r == null) return false;
    try {
      final list = jsonDecode(r['permissions'] as String);
      return list is List && list.contains(permission);
    } on FormatException {
      return false;
    }
  }

  Future<void> _allow(SqlDb tx) async {
    if (userId != null && !await _has(tx, userId, 'shift.manage')) throw SetupError('forbidden', 'You are not allowed to do that.');
  }

  Future<String> _add(SqlDb tx, String table, _Row row, int now, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  Future<void> _edit(SqlDb tx, String table, String id, _Row set, int now) async {
    final cur = await _get(tx, 'select version from "$table" where id = ?', [id]);
    if (cur == null) throw SetupError('not_found', 'That record was not found.');
    final o = <String, Object?>{...set, 'version': _i(cur['version']) + 1, 'updated_at': now};
    final k = o.keys.toList();
    await tx.exec('update "$table" set ${k.map((x) => '"$x" = ?').join(', ')} where id = ?', [...k.map((x) => o[x]), id]);
  }

  /// This cashier's open shift, if any.
  Future<ShiftInfo?> current([SqlDb? tx]) async {
    final r = await _get(tx ?? db, "select * from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1", [userId]);
    return r == null ? null : ShiftInfo(id: r['id'] as String, branchId: r['branch_id'] as String, userId: r['user_id'] as String?, openedAt: _i(r['opened_at']));
  }

  Future<List<String>> currencyCodes() async =>
      [for (final r in await db.query('select code from currencies where deleted_at is null and is_active = 1 order by code')) r['code'] as String];

  /// The branch this phone sells for (the first active one).
  Future<String?> defaultBranchId() async =>
      (await _get(db, 'select id from branches where deleted_at is null order by created_at, rowid limit 1'))?['id'] as String?;

  Future<String> openShift({required String branchId, required Map<String, int> float}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      if (await current(tx) != null) throw SetupError('shift_open', 'You already have a shift open. Close it first.');
      final codes = [for (final r in await tx.query('select code from currencies where deleted_at is null and is_active = 1 order by code')) r['code'] as String];
      for (final e in float.entries) {
        if (!codes.contains(e.key)) throw SetupError('unknown_currency', 'Currency ${e.key} is not set up.');
        if (!_minor(e.value)) throw SetupError('bad_amount', 'The float must be zero or more.');
      }
      final id = await _add(tx, 'shifts', {'branch_id': branchId, 'user_id': userId, 'opened_at': now, 'closed_at': null, 'status': 'open'}, now, versioned: true);
      for (final code in codes) {
        await _add(tx, 'shift_cash', {'shift_id': id, 'currency': code, 'opening_float_minor': float[code] ?? 0, 'expected_minor': null, 'counted_minor': null, 'difference_minor': null}, now, versioned: true);
      }
      return id;
    });
  }

  /// What the drawer should hold now, per currency.
  Future<Map<String, int>> expectedCash(String shiftId, [SqlDb? tx]) async {
    final d = tx ?? db;
    final sh = await _get(d, 'select * from shifts where id = ?', [shiftId]);
    if (sh == null) throw SetupError('unknown_shift', 'That shift was not found.');
    final out = <String, int>{};
    for (final r in await d.query('select currency, opening_float_minor from shift_cash where shift_id = ?', [shiftId])) {
      out[r['currency'] as String] = r['opening_float_minor'] == null ? 0 : _i(r['opening_float_minor']);
    }
    void add(String cur, int v) => out[cur] = (out[cur] ?? 0) + v;
    final until = sh['closed_at'] == null ? 9007199254740991 : _i(sh['closed_at']);
    for (final r in await d.query(
        "select sp.currency, sp.amount_minor, sp.is_change from sale_payments sp join sales s on s.id = sp.sale_id join payment_methods pm on pm.code = sp.method_code where s.shift_id = ? and pm.kind = 'cash'", [shiftId])) {
      add(r['currency'] as String, r['is_change'] == 1 ? -_i(r['amount_minor']) : _i(r['amount_minor']));
    }
    for (final r in await d.query(
        "select ap.currency, ap.amount_minor from account_payments ap join payment_methods pm on pm.code = ap.method_code where ap.user_id is ? and ap.created_at >= ? and ap.created_at <= ? and pm.kind = 'cash'",
        [sh['user_id'], sh['opened_at'], until])) {
      add(r['currency'] as String, _i(r['amount_minor']));
    }
    for (final r in await d.query(
        "select rp.currency, rp.amount_minor from return_payouts rp join sale_returns r on r.id = rp.return_id join payment_methods pm on pm.code = rp.method_code where r.shift_id = ? and pm.kind = 'cash'",
        [shiftId])) {
      add(r['currency'] as String, -_i(r['amount_minor']));
    }
    for (final r in await d.query('select currency, type, amount_minor from cash_events where shift_id = ?', [shiftId])) {
      add(r['currency'] as String, r['type'] == 'cash_in' ? _i(r['amount_minor']) : -_i(r['amount_minor']));
    }
    return out;
  }

  /// Money put into or taken out of the drawer outside a sale. The amount is positive; [type] says which way it goes.
  Future<String> addCashEvent({required String shiftId, required String currency, required String type, required int amountMinor, String? reason}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      final sh = await _get(tx, 'select * from shifts where id = ?', [shiftId]);
      if (sh == null || sh['status'] != 'open') throw SetupError('shift_closed', 'That shift is not open.');
      if (!['cash_in', 'cash_out', 'bank_drop'].contains(type)) throw SetupError('bad_type', 'Unknown cash movement.');
      if (amountMinor <= 0) throw SetupError('bad_amount', 'The amount must be more than zero.');
      if (await _get(tx, 'select 1 as x from shift_cash where shift_id = ? and currency = ?', [shiftId, currency]) == null) throw SetupError('unknown_currency', 'Currency $currency is not set up.');
      final why = (reason ?? '').trim().isEmpty ? null : reason!.trim();
      if (type != 'bank_drop' && why == null) throw SetupError('reason_needed', 'Say why the cash is moving.');
      if (type != 'cash_in') {
        final have = (await expectedCash(shiftId, tx))[currency] ?? 0;
        if (amountMinor > have) throw SetupError('not_enough_cash', 'There is not that much cash in the drawer.');
      }
      return _add(tx, 'cash_events', {'shift_id': shiftId, 'currency': currency, 'type': type, 'amount_minor': amountMinor, 'reason': why}, now);
    });
  }

  Future<ShiftReport> report(String shiftId, [SqlDb? tx]) async {
    final d = tx ?? db;
    final sh = await _get(d, 'select * from shifts where id = ?', [shiftId]);
    if (sh == null) throw SetupError('unknown_shift', 'That shift was not found.');
    final cash = await d.query('select * from shift_cash where shift_id = ? order by currency', [shiftId]);
    final closed = sh['status'] == 'closed';
    final expNow = closed ? <String, int>{} : await expectedCash(shiftId, d);
    final user = sh['user_id'] == null ? null : (await _get(d, 'select name from users where id = ?', [sh['user_id']]))?['name'] as String?;
    Map<String, T> rec<T>(T Function(_Row) f) => {for (final c in cash) c['currency'] as String: f(c)};
    return ShiftReport(
      shiftId: shiftId, status: sh['status'] as String, openedAt: _i(sh['opened_at']), closedAt: sh['closed_at'] == null ? null : _i(sh['closed_at']), user: user,
      sales: _i((await _get(d, "select count(*) as c from sales s where s.shift_id = ? and not exists (select 1 from sale_voids v where v.sale_id = s.id)", [shiftId]))!['c']),
      voided: _i((await _get(d, "select count(*) as c from sales s where s.shift_id = ? and exists (select 1 from sale_voids v where v.sale_id = s.id)", [shiftId]))!['c']),
      sold: {
        for (final r in await d.query("select s.sale_currency as currency, sum(s.total_minor) as total_minor from sales s where s.shift_id = ? and not exists (select 1 from sale_voids v where v.sale_id = s.id) group by s.sale_currency order by s.sale_currency", [shiftId]))
          r['currency'] as String: _i(r['total_minor']),
      },
      takings: [
        for (final r in await d.query(
            "select pm.name as method, sp.currency, sum(case when sp.is_change = 1 then -sp.amount_minor else sp.amount_minor end) as amount_minor from sale_payments sp join sales s on s.id = sp.sale_id join payment_methods pm on pm.code = sp.method_code where s.shift_id = ? group by pm.name, sp.currency order by pm.name, sp.currency",
            [shiftId]))
          Taking(r['method'] as String, r['currency'] as String, _i(r['amount_minor'])),
      ],
      refunds: [
        for (final r in await d.query(
            'select pm.name as method, rp.currency, sum(rp.amount_minor) as amount_minor from return_payouts rp join sale_returns r on r.id = rp.return_id join payment_methods pm on pm.code = rp.method_code where r.shift_id = ? group by pm.name, rp.currency order by pm.name, rp.currency',
            [shiftId]))
          Taking(r['method'] as String, r['currency'] as String, _i(r['amount_minor'])),
      ],
      float: rec((c) => c['opening_float_minor'] == null ? 0 : _i(c['opening_float_minor'])),
      expected: closed ? rec((c) => c['expected_minor'] == null ? 0 : _i(c['expected_minor'])) : expNow,
      counted: rec<int?>((c) => c['counted_minor'] == null ? null : _i(c['counted_minor'])),
      difference: rec<int?>((c) => c['difference_minor'] == null ? null : _i(c['difference_minor'])),
      events: [
        for (final r in await d.query('select type, currency, amount_minor, reason from cash_events where shift_id = ? order by created_at, rowid', [shiftId]))
          CashEventLine(r['type'] as String, r['currency'] as String, _i(r['amount_minor']), r['reason'] as String?),
      ],
    );
  }

  /// Ends the shift. [counted] must list every currency in the drawer (zero is a valid count). A difference is recorded, never blocked.
  Future<ShiftReport> closeShift(String shiftId, Map<String, int> counted) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      final sh = await _get(tx, 'select * from shifts where id = ?', [shiftId]);
      if (sh == null) throw SetupError('unknown_shift', 'That shift was not found.');
      if (sh['status'] != 'open') throw SetupError('shift_closed', 'That shift is already closed.');
      if (userId != null && sh['user_id'] != userId && !await _has(tx, userId, 'report.view')) {
        throw SetupError('forbidden', 'Only the cashier or a manager can close this shift.');
      }
      final cash = await tx.query('select * from shift_cash where shift_id = ?', [shiftId]);
      for (final c in cash) {
        final v = counted[c['currency']];
        if (v == null || !_minor(v)) throw SetupError('count_needed', 'Count the ${c['currency']} cash in the drawer.');
      }
      for (final code in counted.keys) {
        if (!cash.any((c) => c['currency'] == code)) throw SetupError('unknown_currency', 'Currency $code is not part of this shift.');
      }
      final exp = await expectedCash(shiftId, tx);
      await _edit(tx, 'shifts', shiftId, {'status': 'closed', 'closed_at': now}, now);
      for (final c in cash) {
        final code = c['currency'] as String;
        final e = exp[code] ?? 0;
        await _edit(tx, 'shift_cash', c['id'] as String, {'expected_minor': e, 'counted_minor': counted[code], 'difference_minor': counted[code]! - e}, now);
      }
      return report(shiftId, tx);
    });
  }
}
