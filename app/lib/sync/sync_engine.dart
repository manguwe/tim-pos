import 'dart:collection';
import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import 'api_client.dart';

/// Thrown when the server answers a sync call with an error.
class SyncException implements Exception {
  SyncException(this.response);
  final ApiResponse response;
  @override
  String toString() => 'SyncException(${response.status} ${response.errorCode})';
}

class SyncReport {
  const SyncReport({required this.pushed, required this.rejected, required this.pulled, required this.restarted});
  final int pushed;
  final List<Map<String, dynamic>> rejected;
  final int pulled;

  /// True when the server was restored from a backup and this phone had to pull again from the start.
  final bool restarted;
}

/// Sends this phone's changes and fetches the other phones' changes.
///
/// This is a line-for-line port of tools/src/phone_sync.ts, which is tested against the real server.
/// If you change one, change the other.
class SyncEngine {
  SyncEngine({required this.db, required this.api, required this.kinds, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final SqlDb db;
  final ApiTransport api;

  /// table name -> 'append' or 'versioned', from assets/sql/schema_manifest.json. Also the list of tables we accept.
  final Map<String, String> kinds;
  final int Function() _clock;

  static const int batchRows = 200;
  static const int pageSize = 500;

  final Map<String, Set<String>> _columns = {};

  static String q(String name) => '"$name"';

  /// Sends everything that is waiting. Safe to call again after any failure: a batch that was cut off
  /// is sent again with the same ID and the same content, and the server ignores what it already has.
  Future<({int pushed, List<Map<String, dynamic>> rejected})> push() async {
    var pushed = 0;
    final rejected = <Map<String, dynamic>>[];
    while (true) {
      final found = await _pendingBatch() ?? await db.transaction(_makeBatch);
      if (found == null) break;
      final batch = found;

      await db.exec('update sync_batches set attempts = attempts + 1 where id = ?', [batch.id]);
      final res = await api.send('POST', '/v1/sync/push', body: {'batch_id': batch.id, 'changes': jsonDecode(batch.payload)});
      if (res.status != 200) {
        await db.exec('update sync_state set last_error = ? where id = 1', ['push ${res.status} ${res.errorCode}']);
        throw SyncException(res);
      }
      for (final r in (res.json['rejected'] as List<dynamic>? ?? const [])) {
        rejected.add(Map<String, dynamic>.from(r as Map));
      }
      pushed += ((res.json['accepted'] as num?) ?? 0).toInt() + ((res.json['skipped'] as num?) ?? 0).toInt();
      final now = _clock();
      await db.transaction((tx) async {
        await tx.exec('update change_log set sent_at = ? where batch_id = ?', [now, batch.id]);
        await tx.exec("update sync_batches set status = 'sent', payload = null where id = ?", [batch.id]);
        await tx.exec('update sync_state set last_push_at = ?, last_success_at = ?, last_error = null where id = 1', [now, now]);
      });
    }
    return (pushed: pushed, rejected: rejected);
  }

  Future<_Batch?> _pendingBatch() async {
    final rows = await db.query("select id, payload from sync_batches where status = 'pending' order by created_at limit 1");
    if (rows.isEmpty) return null;
    return _Batch(rows.first['id'] as String, rows.first['payload'] as String);
  }

  /// Freezes the next waiting changes into a batch with its own ID. The payload is stored, so a resend is identical
  /// even if the rows are edited again in the meantime.
  Future<_Batch?> _makeBatch(SqlDb tx) async {
    final waiting = await tx.query('select * from change_log where sent_at is null and batch_id is null order by seq limit ?', [batchRows]);
    if (waiting.isEmpty) return null;
    final id = newId();
    // Several edits to one row in the same batch collapse to the latest, which carries the row as it is now.
    final latest = LinkedHashMap<String, Map<String, Object?>>();
    for (final w in waiting) {
      latest['${w['table_name']}|${w['row_id']}'] = w;
    }
    final changes = <Map<String, Object?>>[];
    for (final w in latest.values) {
      final table = w['table_name'] as String;
      final rows = await tx.query('select * from ${q(table)} where id = ?', [w['row_id']]);
      changes.add({
        'table': table,
        'row_id': w['row_id'],
        'op': w['op'],
        'version': w['version'],
        'updated_at': w['updated_at'],
        'data': rows.isEmpty ? <String, Object?>{} : rows.first,
      });
    }
    final payload = jsonEncode(changes);
    final marks = List.filled(waiting.length, '?').join(',');
    await tx.exec('update change_log set batch_id = ? where seq in ($marks)', [id, ...waiting.map((w) => w['seq'])]);
    await tx.exec(
      "insert into sync_batches (id, from_seq, to_seq, status, bytes, payload, created_at) values (?, ?, ?, 'pending', ?, ?, ?)",
      [id, waiting.first['seq'], waiting.last['seq'], payload.length, payload, _clock()],
    );
    return _Batch(id, payload);
  }

  /// Fetches the other phones' changes and applies them. A phone restoring itself asks for its own changes too.
  Future<({int pulled, bool restarted})> pull({bool includeOwn = false}) async {
    var pulled = 0;
    var restarted = false;
    var own = includeOwn;
    while (true) {
      final st = (await db.query('select last_pull_seq, epoch from sync_state where id = 1')).first;
      final qs = <String, String>{'since': '${st['last_pull_seq']}', 'limit': '$pageSize'};
      if (st['epoch'] != null) qs['epoch'] = st['epoch'] as String;
      if (own) qs['include_own'] = '1';
      final res = await api.send('GET', '/v1/sync/pull?${Uri(queryParameters: qs).query}');

      if (res.status == 409 && (res.errorCode == 'epoch_changed' || res.errorCode == 'cursor_ahead')) {
        // The server was restored from a backup. Start again from the beginning and take our own rows back too;
        // rows we already have are skipped, so nothing is doubled.
        final epoch = (res.json['error'] as Map)['epoch'] as String?;
        await db.exec('update sync_state set last_pull_seq = 0, epoch = ? where id = 1', [epoch]);
        restarted = true;
        own = true;
        continue;
      }
      if (res.status != 200) {
        await db.exec('update sync_state set last_error = ? where id = 1', ['pull ${res.status} ${res.errorCode}']);
        throw SyncException(res);
      }
      await _applyPage(res.json);
      pulled += (res.json['changes'] as List<dynamic>).length;
      await db.exec('update sync_state set last_success_at = ?, last_error = null where id = 1', [_clock()]);
      if (res.json['has_more'] != true) break;
    }
    return (pulled: pulled, restarted: restarted);
  }

  Future<SyncReport> sync() async {
    final p = await push();
    final l = await pull();
    return SyncReport(pushed: p.pushed, rejected: p.rejected, pulled: l.pulled, restarted: l.restarted);
  }

  Future<Set<String>> _columnsOf(SqlDb tx, String table) async {
    final known = _columns[table];
    if (known != null) return known;
    final rows = await tx.query('pragma table_info(${q(table)})');
    return _columns[table] = rows.map((r) => r['name'] as String).toSet();
  }

  /// Applies one page in one transaction. Links between tables are checked at commit, so order inside the page does not matter.
  /// While `applying` is 1 the database does not log these rows for sending, which is what stops them bouncing back.
  Future<void> _applyPage(Map<String, dynamic> page) async {
    final changes = page['changes'] as List<dynamic>;
    await db.transaction((tx) async {
      await tx.exec('update sync_state set applying = 1 where id = 1');
      for (final c in changes) {
        await _applyOne(tx, Map<String, dynamic>.from(c as Map));
      }
      await tx.exec('update sync_state set applying = 0, last_pull_seq = ?, epoch = ? where id = 1', [page['next_seq'], page['epoch']]);
    });
  }

  /// SQLite takes numbers, text and null. Anything else from a newer server is stored as JSON text.
  static Object? _arg(Object? v) {
    if (v == null || v is num || v is String) return v;
    if (v is bool) return v ? 1 : 0;
    return jsonEncode(v);
  }

  Future<void> _applyOne(SqlDb tx, Map<String, dynamic> c) async {
    final table = c['table'] as String;
    final kind = kinds[table];
    // A table this app version does not know is skipped, never trusted: the name goes into SQL.
    if (kind == null) return;
    final have = await _columnsOf(tx, table);
    final data = Map<String, dynamic>.from(c['data'] as Map);
    final rowId = c['row_id'] as String;
    final row = <String, Object?>{
      for (final e in data.entries)
        if (have.contains(e.key) && e.key != 'id') e.key: _arg(e.value),
      'id': rowId,
    };
    final cols = row.keys.map(q).join(', ');
    final marks = List.filled(row.length, '?').join(', ');

    if (kind == 'append') {
      await tx.exec('insert or ignore into ${q(table)} ($cols) values ($marks)', row.values.toList());
      return;
    }
    final local = await tx.query('select version, updated_at from ${q(table)} where id = ?', [rowId]);
    if (local.isEmpty) {
      await tx.exec('insert into ${q(table)} ($cols) values ($marks)', row.values.toList());
      return;
    }
    // Higher version wins; at the same version the later edit wins.
    final version = (c['version'] as num).toInt();
    final localVersion = (local.first['version'] as num).toInt();
    final localTime = (local.first['updated_at'] as num).toInt();
    final remoteTime = ((data['updated_at'] as num?) ?? 0).toInt();
    final remoteWins = version > localVersion || (version == localVersion && remoteTime > localTime);
    if (!remoteWins) return;
    final others = row.entries.where((e) => e.key != 'id').toList();
    await tx.exec(
      'update ${q(table)} set ${others.map((e) => '${q(e.key)} = ?').join(', ')} where id = ?',
      [...others.map((e) => e.value), rowId],
    );
  }

  /// For the "last synced" line and the pending count on screen.
  Future<({int? lastSuccessAt, String? lastError, int waiting})> status() async {
    final st = (await db.query('select last_success_at, last_error from sync_state where id = 1')).first;
    final w = (await db.query('select count(*) as c from change_log where sent_at is null')).first;
    return (lastSuccessAt: (st['last_success_at'] as num?)?.toInt(), lastError: st['last_error'] as String?, waiting: (w['c'] as num).toInt());
  }
}

class _Batch {
  _Batch(this.id, this.payload);
  final String id;
  final String payload;
}
