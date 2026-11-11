/// Stock adjustments and stock take. Port of tools/src/stock.ts (read the notes at the top of that file).
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/money.dart';
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

enum AdjustKind { damaged, expired, loss, found, otherOut }

class AdjustKindInfo {
  const AdjustKindInfo(this.kind, this.label, this.type, this.sign);
  final AdjustKind kind;
  final String label, type;
  final int sign;
}

const List<AdjustKindInfo> adjustKinds = [
  AdjustKindInfo(AdjustKind.damaged, 'Damaged', 'damaged', -1),
  AdjustKindInfo(AdjustKind.expired, 'Expired', 'expired', -1),
  AdjustKindInfo(AdjustKind.loss, 'Lost or stolen', 'loss', -1),
  AdjustKindInfo(AdjustKind.otherOut, 'Other removal', 'adjustment', -1),
  AdjustKindInfo(AdjustKind.found, 'Found or extra stock', 'adjustment', 1),
];

String qtyText(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

class Bucket {
  const Bucket({this.batchId, this.batchCode, this.expiryDate, required this.qtyMilli});
  final String? batchId, batchCode, expiryDate;
  final int qtyMilli;
}

class AdjustResult {
  const AdjustResult(this.movementId, this.qtyMilli, this.valueMinor);
  final String movementId;
  final int qtyMilli, valueMinor;
}

class AdjustmentRow {
  const AdjustmentRow({required this.id, required this.at, required this.product, required this.type, required this.qtyMilli, required this.valueMinor, this.reason, this.user});
  final String id, product, type;
  final int at, qtyMilli, valueMinor;
  final String? reason, user;
}

class AdjustmentSummary {
  AdjustmentSummary(this.type);
  final String type;
  int count = 0, qtyMilli = 0, valueMinor = 0;
}

class AdjustmentHistory {
  const AdjustmentHistory(this.rows, this.summary);
  final List<AdjustmentRow> rows;
  final List<AdjustmentSummary> summary;
}

class TakeInfo {
  const TakeInfo({required this.id, required this.branchId, required this.scope, required this.status, required this.startedAt, this.closedAt, this.approvedBy});
  final String id, branchId, scope, status;
  final int startedAt;
  final int? closedAt;
  final String? approvedBy;
}

class TakeLine {
  const TakeLine({required this.id, required this.productId, required this.product, this.batchId, this.batchCode, required this.expectedMilli, this.countedMilli});
  final String id, productId, product;
  final String? batchId, batchCode;
  final int expectedMilli;
  final int? countedMilli;
}

class TakeReportLine {
  const TakeReportLine(this.line, this.differenceMilli, this.valueMinor);
  final TakeLine line;
  final int? differenceMilli;
  final int valueMinor;
}

class TakeReport {
  const TakeReport({required this.take, required this.lines, required this.countedLines, required this.uncountedLines, required this.surplusMinor, required this.shortageMinor});
  final TakeInfo take;
  final List<TakeReportLine> lines;
  final int countedLines, uncountedLines, surplusMinor, shortageMinor;
}

class ApprovalResult {
  const ApprovalResult(this.corrections, this.surplusMinor, this.shortageMinor);
  final int corrections, surplusMinor, shortageMinor;
}

class StockRepository {
  StockRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();

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
    if (userId != null && !await _has(tx, userId, 'stock.adjust')) throw SetupError('forbidden', 'You are not allowed to adjust stock.');
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

  Future<String> _baseCurrency(SqlDb tx) async => (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String;

  /// The first active branch, for phones that sell for one branch.
  Future<String?> branchId() async => (await _get(db, 'select id from branches where deleted_at is null and is_active = 1 order by created_at limit 1'))?['id'] as String?;

  /// Tracked products, for picking one to adjust or count.
  Future<List<({String id, String name, int qtyMilli})>> products(String branch, {String search = ''}) async {
    final like = '%${search.trim().replaceAll('%', '').replaceAll('_', '')}%';
    final rows = await db.query(
        'select p.id, p.name, coalesce((select sum(l.qty_milli) from stock_levels l where l.product_id = p.id and l.branch_id = ?), 0) as q from products p where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.name like ? order by p.name limit 100',
        [branch, like]);
    return [for (final r in rows) (id: r['id'] as String, name: r['name'] as String, qtyMilli: _i(r['q']))];
  }

  // ---- adjustments ----

  /// What is on the shelf for a product at a branch, split by batch.
  Future<List<Bucket>> buckets(String branch, String productId, [SqlDb? tx]) async {
    final rows = await (tx ?? db).query(
        'select l.batch_key, l.qty_milli, b.batch_code, b.expiry_date from stock_levels l left join stock_batches b on b.id = l.batch_key where l.branch_id = ? and l.product_id = ? order by (b.expiry_date is null), b.expiry_date, l.batch_key',
        [branch, productId]);
    return [
      for (final r in rows)
        Bucket(batchId: r['batch_key'] == '' ? null : r['batch_key'] as String, batchCode: r['batch_code'] as String?, expiryDate: r['expiry_date'] as String?, qtyMilli: _i(r['qty_milli'])),
    ];
  }

  Future<int> _level(SqlDb tx, String branch, String productId, String? batchId) async =>
      _i((await _get(tx, 'select coalesce(sum(qty_milli), 0) as q from stock_levels where branch_id = ? and product_id = ? and batch_key = ?', [branch, productId, batchId ?? '']))!['q']);

  Future<AdjustResult> adjustStock({required String branchId, required String productId, String? batchId, required AdjustKind kind, required int qtyMilli, required String reason}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      final def = adjustKinds.firstWhere((k) => k.kind == kind);
      if (qtyMilli <= 0) throw SetupError('bad_quantity', 'Quantity must be more than zero.');
      final why = reason.trim();
      if (why.isEmpty) throw SetupError('reason_needed', 'Give a reason.');
      final p = await _get(tx, 'select * from products where id = ? and deleted_at is null', [productId]);
      if (p == null) throw SetupError('not_found', 'That product was not found.');
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      if (batchId != null && await _get(tx, 'select 1 as x from stock_batches where id = ? and product_id = ? and deleted_at is null', [batchId, productId]) == null) {
        throw SetupError('unknown_batch', 'That batch was not found.');
      }
      final have = await _level(tx, branchId, productId, batchId);
      if (def.sign < 0 && qtyMilli > have) {
        throw SetupError('not_enough_stock', 'Only ${qtyText(have < 0 ? 0 : have)} of ${p['name']} on the shelf${batchId != null ? ' in that batch' : ''}.');
      }
      final qty = def.sign * qtyMilli;
      final cost = p['cost_minor'] == null ? null : _i(p['cost_minor']);
      final mid = await _add(tx, 'stock_movements', {
        'branch_id': branchId, 'product_id': productId, 'batch_id': batchId, 'type': def.type, 'qty_milli': qty, 'unit_cost_minor': cost,
        'cost_currency': await _baseCurrency(tx), 'ref_type': null, 'ref_id': null, 'reason': why,
      }, now);
      await _add(tx, 'audit_log', {'user_id': userId, 'action': 'stock_adjust', 'table_name': 'stock_movements', 'row_id': mid, 'after': jsonEncode({'kind': kind.name == 'otherOut' ? 'other_out' : kind.name, 'qty_milli': qty, 'reason': why})}, now);
      return AdjustResult(mid, qty, cost == null ? 0 : lineAmount(qty, cost));
    });
  }

  /// Adjustments and count corrections in [from, to), newest first, with totals by type. Values are at cost.
  Future<AdjustmentHistory> history(int from, int to, {String? branchId}) async {
    final rows = await db.query(
        "select m.id, m.created_at as at, p.name as product, m.type, m.qty_milli, m.unit_cost_minor, m.reason, u.name as user from stock_movements m join products p on p.id = m.product_id left join users u on u.id = m.created_by where m.type in ('damaged', 'expired', 'loss', 'adjustment', 'count_correction') and m.created_at >= ? and m.created_at < ? ${branchId != null ? 'and m.branch_id = ?' : ''} order by m.created_at desc, m.rowid desc",
        [from, to, if (branchId != null) branchId]);
    final out = [
      for (final r in rows)
        AdjustmentRow(
          id: r['id'] as String, at: _i(r['at']), product: r['product'] as String, type: r['type'] as String, qtyMilli: _i(r['qty_milli']),
          valueMinor: r['unit_cost_minor'] == null ? 0 : lineAmount(_i(r['qty_milli']), _i(r['unit_cost_minor'])), reason: r['reason'] as String?, user: r['user'] as String?),
    ];
    final by = <String, AdjustmentSummary>{};
    for (final r in out) {
      final s = by.putIfAbsent(r.type, () => AdjustmentSummary(r.type));
      s.count += 1;
      s.qtyMilli += r.qtyMilli;
      s.valueMinor += r.valueMinor;
    }
    final summary = by.values.toList()..sort((a, b) => a.type.compareTo(b.type));
    return AdjustmentHistory(out, summary);
  }

  // ---- stock take ----

  Future<({String takeId, int lines})> startStockTake({required String branchId, List<String>? productIds}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      if (await _get(tx, "select 1 as x from stock_takes where branch_id = ? and status in ('open', 'counted') and deleted_at is null", [branchId]) != null) {
        throw SetupError('take_open', 'A stock take is already in progress for this branch. Finish or cancel it first.');
      }
      final partial = productIds != null && productIds.isNotEmpty;
      final products = [
        for (final p in await tx.query('select id, name from products where deleted_at is null and is_active = 1 and track_stock = 1 order by name'))
          if (!partial || productIds.contains(p['id'])) p,
      ];
      if (products.isEmpty) throw SetupError('nothing_to_count', 'There are no stock-keeping products to count.');
      final takeId = await _add(tx, 'stock_takes', {'branch_id': branchId, 'scope': partial ? 'partial' : 'full', 'status': 'open', 'started_at': now, 'closed_at': null, 'approved_by': null}, now, versioned: true);
      var lines = 0;
      for (final p in products) {
        final bs = [for (final b in await buckets(branchId, p['id'] as String, tx)) if (b.qtyMilli != 0 || b.batchId != null) b];
        if (bs.isEmpty) bs.add(const Bucket(qtyMilli: 0));
        for (final b in bs) {
          await _add(tx, 'stock_take_lines', {'stock_take_id': takeId, 'product_id': p['id'], 'batch_id': b.batchId, 'expected_qty_milli': b.qtyMilli, 'counted_qty_milli': null}, now, versioned: true);
          lines += 1;
        }
      }
      return (takeId: takeId, lines: lines);
    });
  }

  TakeInfo _info(_Row r) => TakeInfo(
      id: r['id'] as String, branchId: r['branch_id'] as String, scope: r['scope'] as String, status: r['status'] as String,
      startedAt: _i(r['started_at']), closedAt: r['closed_at'] == null ? null : _i(r['closed_at']), approvedBy: r['approved_by'] as String?);

  Future<TakeInfo?> currentStockTake(String branchId) async {
    final r = await _get(db, "select * from stock_takes where branch_id = ? and status in ('open', 'counted') and deleted_at is null order by started_at desc limit 1", [branchId]);
    return r == null ? null : _info(r);
  }

  Future<List<TakeLine>> stockTakeLines(String takeId, [SqlDb? tx]) async {
    final rows = await (tx ?? db).query(
        'select l.id, l.product_id, p.name as product, l.batch_id, b.batch_code, l.expected_qty_milli, l.counted_qty_milli from stock_take_lines l join products p on p.id = l.product_id left join stock_batches b on b.id = l.batch_id where l.stock_take_id = ? and l.deleted_at is null order by p.name, (b.expiry_date is null), b.expiry_date, l.rowid',
        [takeId]);
    return [
      for (final r in rows)
        TakeLine(
          id: r['id'] as String, productId: r['product_id'] as String, product: r['product'] as String, batchId: r['batch_id'] as String?, batchCode: r['batch_code'] as String?,
          expectedMilli: _i(r['expected_qty_milli']), countedMilli: r['counted_qty_milli'] == null ? null : _i(r['counted_qty_milli'])),
    ];
  }

  /// Records (or clears, with null) the count for one line. Only while the take is open.
  Future<void> recordCount(String lineId, int? counted) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      if (counted != null && (counted < 0 || counted > 1000000000)) throw SetupError('bad_quantity', 'The count must be zero or more.');
      final l = await _get(tx, 'select l.id, t.status from stock_take_lines l join stock_takes t on t.id = l.stock_take_id where l.id = ? and l.deleted_at is null and t.deleted_at is null', [lineId]);
      if (l == null) throw SetupError('not_found', 'That line was not found.');
      if (l['status'] != 'open') throw SetupError('take_closed', 'This stock take is no longer open for counting.');
      await _edit(tx, 'stock_take_lines', lineId, {'counted_qty_milli': counted}, now);
    });
  }

  Future<TakeReport> stockTakeReport(String takeId, [SqlDb? tx]) async {
    final d = tx ?? db;
    final t = await _get(d, 'select * from stock_takes where id = ? and deleted_at is null', [takeId]);
    if (t == null) throw SetupError('not_found', 'That stock take was not found.');
    final cost = {for (final p in await d.query('select id, cost_minor from products')) p['id'] as String: p['cost_minor'] == null ? null : _i(p['cost_minor'])};
    final lines = <TakeReportLine>[];
    var surplus = 0, shortage = 0;
    for (final l in await stockTakeLines(takeId, d)) {
      final diff = l.countedMilli == null ? null : l.countedMilli! - l.expectedMilli;
      final c = cost[l.productId];
      final v = diff == null || c == null ? 0 : lineAmount(diff, c);
      if (v > 0) {
        surplus += v;
      } else {
        shortage += -v;
      }
      lines.add(TakeReportLine(l, diff, v));
    }
    final counted = lines.where((l) => l.line.countedMilli != null).length;
    return TakeReport(take: _info(t), lines: lines, countedLines: counted, uncountedLines: lines.length - counted, surplusMinor: surplus, shortageMinor: shortage);
  }

  /// Ends counting. The figures can now be reviewed; nothing in stock changes yet.
  Future<TakeReport> finishCounting(String takeId) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final t = await _get(tx, 'select * from stock_takes where id = ? and deleted_at is null', [takeId]);
      if (t == null) throw SetupError('not_found', 'That stock take was not found.');
      if (t['status'] != 'open') throw SetupError('take_closed', 'Counting is already finished.');
      if (await _get(tx, 'select 1 as x from stock_take_lines where stock_take_id = ? and counted_qty_milli is not null and deleted_at is null', [takeId]) == null) {
        throw SetupError('nothing_counted', 'Count at least one item first.');
      }
      await _edit(tx, 'stock_takes', takeId, {'status': 'counted'}, now);
    });
    return stockTakeReport(takeId);
  }

  /// Goes back to counting, for example when a figure looks wrong. Only before approval.
  Future<void> reopenCounting(String takeId) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final t = await _get(tx, 'select status from stock_takes where id = ? and deleted_at is null', [takeId]);
      if (t == null || t['status'] != 'counted') throw SetupError('take_not_counted', 'This stock take is not waiting for approval.');
      await _edit(tx, 'stock_takes', takeId, {'status': 'open'}, now);
    });
  }

  /// Posts the corrections. Needs stock.adjust, or a manager's approval (approvedBy) for someone without it.
  Future<ApprovalResult> approveStockTake(String takeId, {String? approvedBy}) async {
    final now = _clock();
    return db.transaction((tx) async {
      if (userId != null && !await _has(tx, userId, 'stock.adjust') && !(approvedBy != null && await _has(tx, approvedBy, 'stock.adjust'))) {
        throw SetupError('forbidden', 'Approving a stock take needs a manager.');
      }
      final rep = await stockTakeReport(takeId, tx);
      if (rep.take.status != 'counted') throw SetupError('take_not_counted', 'Finish counting before approving.');
      final base = await _baseCurrency(tx);
      var corrections = 0;
      for (final l in rep.lines) {
        final diff = l.differenceMilli;
        if (diff == null || diff == 0) continue;
        final p = await _get(tx, 'select cost_minor from products where id = ?', [l.line.productId]);
        await _add(tx, 'stock_movements', {
          'branch_id': rep.take.branchId, 'product_id': l.line.productId, 'batch_id': l.line.batchId, 'type': 'count_correction', 'qty_milli': diff,
          'unit_cost_minor': p?['cost_minor'], 'cost_currency': base, 'ref_type': 'stock_take', 'ref_id': takeId, 'reason': 'Stock take',
        }, now);
        corrections += 1;
      }
      await _edit(tx, 'stock_takes', takeId, {'status': 'approved', 'closed_at': now, 'approved_by': approvedBy ?? userId}, now);
      await _add(tx, 'audit_log', {
        'user_id': userId, 'action': 'stock_take_approved', 'table_name': 'stock_takes', 'row_id': takeId,
        'after': jsonEncode({'corrections': corrections, 'surplus_minor': rep.surplusMinor, 'shortage_minor': rep.shortageMinor}),
      }, now);
      return ApprovalResult(corrections, rep.surplusMinor, rep.shortageMinor);
    });
  }

  /// Throws a stock take away (nothing was changed in stock). Not possible once approved.
  Future<void> cancelStockTake(String takeId) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final t = await _get(tx, 'select status from stock_takes where id = ? and deleted_at is null', [takeId]);
      if (t == null) throw SetupError('not_found', 'That stock take was not found.');
      if (t['status'] == 'approved') throw SetupError('take_approved', 'An approved stock take cannot be cancelled.');
      await _edit(tx, 'stock_takes', takeId, {'deleted_at': now}, now);
    });
  }
}
