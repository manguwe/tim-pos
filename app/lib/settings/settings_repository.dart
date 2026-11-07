/// Shop settings the owner can change. Port of tools/src/settings.ts.
///
/// Only the keys in [shopSettings] can be changed here. Values are stored as text in the `settings` table (scope 'shop');
/// a key with no row uses its default.
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../setup/setup_repository.dart' show SetupError;

enum SettingKind { bool, int, text }

class SettingDef {
  const SettingDef({required this.key, required this.group, required this.label, required this.help, required this.kind, required this.def, this.min = 0, this.max, this.maxLen, this.digits});
  final String key, group, label, help, def;
  final SettingKind kind;
  final int min;
  final int? max, maxLen, digits;
}

const List<SettingDef> shopSettings = [
  SettingDef(key: 'require_shift', group: 'Selling', label: 'Cashiers must open a shift before selling', help: 'Every sale is then tied to a shift, so cash-up can account for it.', kind: SettingKind.bool, def: '0'),
  SettingDef(key: 'allow_negative_stock', group: 'Selling', label: 'Allow selling when stock shows zero', help: 'Off by default: a sale is blocked when there is not enough stock. Turn on only if you do not keep stock counts up to date.', kind: SettingKind.bool, def: '0'),
  SettingDef(key: 'layby_min_deposit_pct', group: 'Selling', label: 'Minimum layby deposit (%)', help: 'The share of the total a customer must pay when starting a layby. 0 means no minimum.', kind: SettingKind.int, def: '0', min: 0, max: 100),
  SettingDef(key: 'receipt_header', group: 'Receipts', label: 'Receipt header', help: 'A line printed under the shop name, for example a slogan.', kind: SettingKind.text, def: '', maxLen: 120),
  SettingDef(key: 'receipt_footer', group: 'Receipts', label: 'Receipt footer', help: 'Printed at the bottom of receipts and slips, for example your returns policy.', kind: SettingKind.text, def: '', maxLen: 120),
  SettingDef(key: 'scale_prefix', group: 'Barcodes', label: 'Scale label prefix', help: 'Two digits. Fill in only if you have a shop scale that prints weight labels. Leave empty if not.', kind: SettingKind.text, def: '', maxLen: 2, digits: 2),
];

/// Checks one value and returns it in the form that is stored.
String normaliseSetting(SettingDef d, String raw) {
  switch (d.kind) {
    case SettingKind.bool:
      if (raw != '0' && raw != '1') throw SetupError('bad_setting', '${d.label}: choose on or off.');
      return raw;
    case SettingKind.int:
      final t = raw.trim();
      if (!RegExp(r'^\d{1,9}$').hasMatch(t)) throw SetupError('bad_setting', '${d.label}: enter a whole number.');
      final n = int.parse(t);
      if (n < d.min || n > (d.max ?? 1000000000)) throw SetupError('bad_setting', '${d.label}: enter a number from ${d.min} to ${d.max}.');
      return '$n';
    case SettingKind.text:
      final t = raw.replaceAll(RegExp(r'\s+'), ' ').trim();
      if (d.digits != null && t.isNotEmpty && !RegExp('^\\d{${d.digits}}\$').hasMatch(t)) throw SetupError('bad_setting', '${d.label}: enter exactly ${d.digits} digits, or leave it empty.');
      if (t.length > (d.maxLen ?? 200)) throw SetupError('bad_setting', '${d.label}: use at most ${d.maxLen} characters.');
      return t;
  }
}

class SettingsRepository {
  SettingsRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  Future<Map<String, String>> load([SqlDb? tx]) async {
    final out = {for (final d in shopSettings) d.key: d.def};
    for (final r in await (tx ?? db).query("select key, value from settings where scope = 'shop' and deleted_at is null")) {
      final k = r['key'];
      if (out.containsKey(k) && r['value'] is String) out[k as String] = r['value'] as String;
    }
    return out;
  }

  Future<bool> _can(SqlDb tx, String? uid) async {
    if (uid == null) return false;
    final r = await tx.query('select r.permissions from users u join roles r on r.id = u.role_id where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null', [uid]);
    if (r.isEmpty) return false;
    try {
      final list = jsonDecode(r.first['permissions'] as String);
      return list is List && list.contains('settings.edit');
    } on FormatException {
      return false;
    }
  }

  /// Saves the changed values. Everything is checked first, so nothing is saved if one value is wrong. Returns the keys that changed.
  Future<List<String>> save(Map<String, String> changes) async {
    final now = _clock();
    return db.transaction((tx) async {
      if (userId != null && !await _can(tx, userId)) throw SetupError('forbidden', 'You are not allowed to change settings.');
      final cur = await load(tx);
      final todo = <(SettingDef, String)>[];
      for (final e in changes.entries) {
        final i = shopSettings.indexWhere((d) => d.key == e.key);
        if (i < 0) throw SetupError('unknown_setting', 'That setting does not exist.');
        final v = normaliseSetting(shopSettings[i], e.value);
        if (v != cur[e.key]) todo.add((shopSettings[i], v));
      }
      for (final (d, v) in todo) {
        final row = await tx.query("select id, version from settings where scope = 'shop' and key = ? and deleted_at is null", [d.key]);
        if (row.isNotEmpty) {
          await tx.exec('update settings set value = ?, version = ?, updated_at = ? where id = ?', [v, (row.first['version'] as num).toInt() + 1, now, row.first['id']]);
        } else {
          await _insert(tx, 'settings', {'scope': 'shop', 'key': d.key, 'value': v, 'updated_at': now, 'version': 1}, now);
        }
        await _insert(tx, 'audit_log', {'user_id': userId, 'action': 'setting_change', 'table_name': 'settings', 'row_id': d.key, 'before': cur[d.key], 'after': v}, now);
      }
      return [for (final t in todo) t.$1.key];
    });
  }

  Future<void> _insert(SqlDb tx, String table, Map<String, Object?> row, int now) async {
    final o = <String, Object?>{'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId, ...row};
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
  }
}
