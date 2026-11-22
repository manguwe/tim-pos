/// Suppliers, purchase orders, goods received, supplier returns and supplier payments.
/// Port of tools/src/purchasing.ts (read the notes at the top of that file for the rules).
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/money.dart';
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

String? _clean(String? v, [int max = 200]) {
  final t = (v ?? '').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return null;
  return t.length > max ? t.substring(0, max) : t;
}

bool _validDate(String? s) {
  if (s == null || !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s)) return false;
  final y = int.parse(s.substring(0, 4)), m = int.parse(s.substring(5, 7)), d = int.parse(s.substring(8, 10));
  final t = DateTime.utc(y, m, d);
  return t.year == y && t.month == m && t.day == d && y >= 2000;
}

String _qtyText(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
bool _isMinor(int n) => n >= 0 && n <= 10000000000;
bool _isQty(int n) => n > 0 && n <= 1000000000;

class SupplierInput {
  const SupplierInput({this.id, required this.name, this.phone, this.address, this.terms, this.isActive = true});
  final String? id;
  final String name;
  final String? phone, address, terms;
  final bool isActive;
}

class Owed {
  const Owed(this.currency, this.amountMinor);
  final String currency;
  final int amountMinor;
  @override
  bool operator ==(Object o) => o is Owed && o.currency == currency && o.amountMinor == amountMinor;
  @override
  int get hashCode => Object.hash(currency, amountMinor);
}

class SupplierSummary {
  const SupplierSummary({required this.id, required this.name, this.phone, this.terms, required this.isActive, required this.owes});
  final String id, name;
  final String? phone, terms;
  final bool isActive;
  final List<Owed> owes;
}

class SupplierStatementLine {
  const SupplierStatementLine({required this.at, required this.type, required this.currency, required this.amountMinor, required this.balanceMinor, this.ref});
  final int at, amountMinor, balanceMinor;
  final String type, currency;
  final String? ref;
}

class LastCost {
  const LastCost(this.costMinor, this.currency);
  final int costMinor;
  final String currency;
}

class PoLineInput {
  const PoLineInput({required this.productId, required this.qtyMilli, required this.costMinor});
  final String productId;
  final int qtyMilli, costMinor;
}

class PoLine {
  const PoLine({required this.lineId, required this.productId, required this.product, required this.qtyMilli, required this.receivedMilli, required this.remainingMilli, required this.costMinor, required this.lineTotalMinor});
  final String lineId, productId, product;
  final int qtyMilli, receivedMilli, remainingMilli, costMinor, lineTotalMinor;
}

class PoDetail {
  const PoDetail({required this.id, required this.orderNo, required this.supplierId, required this.supplier, this.branchId, required this.status, required this.currency, this.orderedAt, this.expectedAt, required this.totalMinor, required this.lines});
  final String id, orderNo, supplierId, supplier, status, currency;
  final String? branchId;
  final int? orderedAt, expectedAt;
  final int totalMinor;
  final List<PoLine> lines;
}

class PoRow {
  const PoRow({required this.id, required this.orderNo, required this.supplier, required this.status, required this.currency, required this.totalMinor, this.orderedAt, this.expectedAt});
  final String id, orderNo, supplier, status, currency;
  final int totalMinor;
  final int? orderedAt, expectedAt;
}

class ReceiveLine {
  const ReceiveLine({required this.productId, required this.qtyMilli, required this.costMinor, this.batchCode, this.expiryDate});
  final String productId;
  final int qtyMilli, costMinor;
  final String? batchCode, expiryDate;
}

class ReceiveResult {
  const ReceiveResult(this.goodsReceivedId, this.totalMinor, this.orderStatus);
  final String goodsReceivedId;
  final int totalMinor;
  final String? orderStatus;
}

class SupplierReturnLine {
  const SupplierReturnLine({required this.productId, required this.qtyMilli, required this.costMinor, this.batchId});
  final String productId;
  final int qtyMilli, costMinor;
  final String? batchId;
}

class SupplierPayResult {
  const SupplierPayResult({required this.paymentId, required this.appliedMinor, required this.debtCurrency, required this.balanceAfterMinor, required this.cashOutRecorded});
  final String paymentId, debtCurrency;
  final int appliedMinor, balanceAfterMinor;
  final bool cashOutRecorded;
}

class PurchasingRepository {
  PurchasingRepository({required this.db, required this.shopId, required this.deviceId, required this.receiptPrefix, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId, receiptPrefix;
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

  Future<void> _allow(SqlDb tx, [String permission = 'stock.receive']) async {
    if (userId != null && !await _has(tx, userId, permission)) throw SetupError('forbidden', 'You are not allowed to do that.');
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

  Future<_Row> _currency(SqlDb tx, String code) async {
    final c = await _get(tx, 'select * from currencies where code = ? and deleted_at is null', [code]);
    if (c == null) throw SetupError('unknown_currency', 'Currency $code is not set up.');
    return c;
  }

  Future<int> _rate(SqlDb tx, String from, String to, int now) async {
    if (from == to) return 1000000;
    const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
    final d = await _get(tx, q, [from, to, now]);
    if (d != null) return _i(d['rate_micro']);
    final i = await _get(tx, q, [to, from, now]);
    if (i == null) throw SetupError('no_rate', 'No exchange rate between $from and $to.');
    return invertRate(_i(i['rate_micro']));
  }

  Future<String> _base(SqlDb tx) async => (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))!['base_currency'] as String;

  /// Cost per unit in the shop's base currency, from a cost in [currency].
  Future<int> _toBaseCost(SqlDb tx, int cost, String currency, String base, int now) async {
    if (currency == base) return cost;
    return convertMinor(cost, await _rate(tx, currency, base, now), _i((await _currency(tx, currency))['minor_units']), _i((await _currency(tx, base))['minor_units']));
  }

  /// The first active branch, for phones that work for one branch.
  Future<String?> branchId() async => (await _get(db, 'select id from branches where deleted_at is null and is_active = 1 order by created_at limit 1'))?['id'] as String?;

  Future<List<({String id, String name, int? costMinor})>> products({String search = ''}) async {
    final like = '%${search.trim().replaceAll('%', '').replaceAll('_', '')}%';
    final rows = await db.query('select id, name, cost_minor from products where deleted_at is null and is_active = 1 and track_stock = 1 and name like ? order by name limit 100', [like]);
    return [for (final r in rows) (id: r['id'] as String, name: r['name'] as String, costMinor: r['cost_minor'] == null ? null : _i(r['cost_minor']))];
  }

  // ---- suppliers ----

  Future<String> saveSupplier(SupplierInput s) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      final name = _clean(s.name, 100);
      if (name == null) throw SetupError('name_needed', 'Enter the supplier\'s name.');
      if (await _get(tx, 'select id from suppliers where deleted_at is null and lower(name) = lower(?) and id is not ?', [name, s.id ?? '']) != null) {
        throw SetupError('duplicate_supplier', 'You already have a supplier with that name.');
      }
      final row = <String, Object?>{'name': name, 'phone': _clean(s.phone, 40), 'address': _clean(s.address, 200), 'terms': _clean(s.terms, 120), 'is_active': s.isActive ? 1 : 0};
      if (s.id != null) {
        if (await _get(tx, 'select 1 as x from suppliers where id = ? and deleted_at is null', [s.id]) == null) throw SetupError('not_found', 'That supplier was not found.');
        await _edit(tx, 'suppliers', s.id!, row, now);
        return s.id!;
      }
      return _add(tx, 'suppliers', row, now, versioned: true);
    });
  }

  Future<List<Owed>> owedToSupplier(String supplierId, [SqlDb? tx]) async {
    final rows = await (tx ?? db).query('select currency, sum(amount_minor) as a from supplier_ledger where supplier_id = ? group by currency having a <> 0 order by currency', [supplierId]);
    return [for (final r in rows) Owed(r['currency'] as String, _i(r['a']))];
  }

  Future<List<SupplierSummary>> listSuppliers({String search = '', bool onlyOwed = false, bool includeInactive = false}) async {
    final q = search.trim();
    final like = '%${q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    final rows = await db.query(
      "select * from suppliers where deleted_at is null ${includeInactive ? '' : 'and is_active = 1'} ${q.isEmpty ? '' : "and (name like ? escape '\\' or phone like ? escape '\\')"} order by name collate nocase limit 300",
      q.isEmpty ? [] : [like, like],
    );
    final out = <SupplierSummary>[];
    for (final r in rows) {
      out.add(SupplierSummary(id: r['id'] as String, name: r['name'] as String, phone: r['phone'] as String?, terms: r['terms'] as String?, isActive: r['is_active'] == 1, owes: await owedToSupplier(r['id'] as String)));
    }
    return onlyOwed ? out.where((s) => s.owes.any((x) => x.amountMinor > 0)).toList() : out;
  }

  /// Every movement on the supplier's account, oldest first, with the running balance per currency.
  Future<List<SupplierStatementLine>> supplierStatement(String supplierId) async {
    final bal = <String, int>{};
    final out = <SupplierStatementLine>[];
    for (final r in await db.query('select * from supplier_ledger where supplier_id = ? order by created_at, rowid', [supplierId])) {
      final cur = r['currency'] as String;
      final b = (bal[cur] ?? 0) + _i(r['amount_minor']);
      bal[cur] = b;
      String? ref;
      if (r['ref_type'] == 'goods_received') {
        ref = (await _get(db, 'select receipt_ref from goods_received where id = ?', [r['ref_id']]))?['receipt_ref'] as String?;
      } else if (r['ref_type'] == 'supplier_payment') {
        ref = (await _get(db, 'select reference from supplier_payments where id = ?', [r['ref_id']]))?['reference'] as String?;
      }
      out.add(SupplierStatementLine(at: _i(r['created_at']), type: r['type'] as String, currency: cur, amountMinor: _i(r['amount_minor']), balanceMinor: b, ref: ref));
    }
    return out;
  }

  Future<LastCost?> lastCost(String supplierId, String productId) async {
    final r = await _get(db, 'select last_cost_minor, cost_currency from supplier_products where supplier_id = ? and product_id = ? and deleted_at is null', [supplierId, productId]);
    return r == null || r['last_cost_minor'] == null ? null : LastCost(_i(r['last_cost_minor']), r['cost_currency'] as String);
  }

  // ---- purchase orders ----

  Future<String> _nextOrderNo(SqlDb tx) async {
    await tx.exec("insert into receipt_counters (kind, last_no) values ('purchase_order', 1) on conflict (kind) do update set last_no = last_no + 1");
    final n = _i((await _get(tx, "select last_no from receipt_counters where kind = 'purchase_order'"))!['last_no']);
    return '$receiptPrefix-PO${n.toString().padLeft(6, '0')}';
  }

  Future<void> _checkPoLines(SqlDb tx, List<PoLineInput> lines) async {
    if (lines.isEmpty) throw SetupError('no_lines', 'Add at least one product.');
    if (lines.length > 200) throw SetupError('too_many_lines', 'An order can have at most 200 lines.');
    final seen = <String>{};
    for (final l in lines) {
      if (!_isQty(l.qtyMilli)) throw SetupError('bad_quantity', 'Quantity must be more than zero.');
      if (!_isMinor(l.costMinor)) throw SetupError('bad_amount', 'The cost must be zero or more.');
      final p = await _get(tx, 'select name, track_stock from products where id = ? and deleted_at is null', [l.productId]);
      if (p == null) throw SetupError('not_found', 'A product on the order was not found.');
      if (!seen.add(l.productId)) throw SetupError('duplicate_line', '${p['name']} is on the order twice.');
    }
  }

  Future<({String orderId, String orderNo})> createPurchaseOrder({required String supplierId, required String branchId, required String currency, int? expectedAt, required List<PoLineInput> lines}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      if (await _get(tx, 'select 1 as x from suppliers where id = ? and deleted_at is null and is_active = 1', [supplierId]) == null) throw SetupError('unknown_supplier', 'That supplier was not found.');
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      await _currency(tx, currency);
      await _checkPoLines(tx, lines);
      final no = await _nextOrderNo(tx);
      final id = await _add(tx, 'purchase_orders', {'supplier_id': supplierId, 'branch_id': branchId, 'order_no': no, 'status': 'draft', 'currency': currency, 'ordered_at': null, 'expected_at': expectedAt}, now, versioned: true);
      for (final l in lines) {
        await _add(tx, 'purchase_order_lines', {'purchase_order_id': id, 'product_id': l.productId, 'unit_id': null, 'qty_milli': l.qtyMilli, 'cost_minor': l.costMinor}, now, versioned: true);
      }
      return (orderId: id, orderNo: no);
    });
  }

  /// Changes a draft order: the expected date and/or the whole list of lines.
  Future<void> updatePurchaseOrder(String orderId, {List<PoLineInput>? lines, bool setExpected = false, int? expectedAt}) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final po = await _get(tx, 'select * from purchase_orders where id = ? and deleted_at is null', [orderId]);
      if (po == null) throw SetupError('not_found', 'That order was not found.');
      if (po['status'] != 'draft') throw SetupError('order_locked', 'Only a draft order can be changed.');
      if (lines != null) {
        await _checkPoLines(tx, lines);
        for (final old in await tx.query('select id from purchase_order_lines where purchase_order_id = ? and deleted_at is null', [orderId])) {
          await _edit(tx, 'purchase_order_lines', old['id'] as String, {'deleted_at': now}, now);
        }
        for (final l in lines) {
          await _add(tx, 'purchase_order_lines', {'purchase_order_id': orderId, 'product_id': l.productId, 'unit_id': null, 'qty_milli': l.qtyMilli, 'cost_minor': l.costMinor}, now, versioned: true);
        }
      }
      if (setExpected) await _edit(tx, 'purchase_orders', orderId, {'expected_at': expectedAt}, now);
    });
  }

  Future<void> _setStatus(String orderId, List<String> from, String to, String msg, _Row extra) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final po = await _get(tx, 'select status from purchase_orders where id = ? and deleted_at is null', [orderId]);
      if (po == null) throw SetupError('not_found', 'That order was not found.');
      if (!from.contains(po['status'])) throw SetupError('bad_status', msg);
      await _edit(tx, 'purchase_orders', orderId, {'status': to, ...extra}, now);
    });
  }

  Future<void> sendPurchaseOrder(String orderId) => _setStatus(orderId, ['draft'], 'sent', 'Only a draft order can be sent.', {'ordered_at': _clock()});

  /// Cancels an order that has received nothing.
  Future<void> cancelPurchaseOrder(String orderId) async {
    if (await _get(db, 'select 1 as x from goods_received where purchase_order_id = ? limit 1', [orderId]) != null) {
      throw SetupError('already_received', 'Some of this order was already received. Close it instead.');
    }
    await _setStatus(orderId, ['draft', 'sent'], 'cancelled', 'This order cannot be cancelled.', {});
  }

  /// Closes an order that will not be delivered in full: what arrived is all there will be.
  Future<void> closePurchaseOrder(String orderId) => _setStatus(orderId, ['partly_received'], 'received', 'Only a partly received order can be closed.', {});

  Future<Map<String, int>> _receivedByProduct(SqlDb tx, String orderId) async {
    final rows = await tx.query('select l.product_id, sum(l.qty_milli) as q from goods_received_lines l join goods_received g on g.id = l.goods_received_id where g.purchase_order_id = ? group by l.product_id', [orderId]);
    return {for (final r in rows) r['product_id'] as String: _i(r['q'])};
  }

  Future<PoDetail> purchaseOrder(String orderId, [SqlDb? tx]) async {
    final d = tx ?? db;
    final po = await _get(d, 'select o.*, s.name as supplier from purchase_orders o join suppliers s on s.id = o.supplier_id where o.id = ? and o.deleted_at is null', [orderId]);
    if (po == null) throw SetupError('not_found', 'That order was not found.');
    final got = await _receivedByProduct(d, orderId);
    final lines = <PoLine>[];
    var total = 0;
    for (final l in await d.query('select l.id, l.product_id, p.name as product, l.qty_milli, l.cost_minor from purchase_order_lines l join products p on p.id = l.product_id where l.purchase_order_id = ? and l.deleted_at is null order by p.name, l.rowid', [orderId])) {
      final r = got[l['product_id']] ?? 0;
      final qty = _i(l['qty_milli']);
      final cost = l['cost_minor'] == null ? 0 : _i(l['cost_minor']);
      final lt = lineAmount(qty, cost);
      total += lt;
      lines.add(PoLine(lineId: l['id'] as String, productId: l['product_id'] as String, product: l['product'] as String, qtyMilli: qty, receivedMilli: r, remainingMilli: qty - r < 0 ? 0 : qty - r, costMinor: cost, lineTotalMinor: lt));
    }
    return PoDetail(
      id: po['id'] as String, orderNo: po['order_no'] as String, supplierId: po['supplier_id'] as String, supplier: po['supplier'] as String, branchId: po['branch_id'] as String?,
      status: po['status'] as String, currency: po['currency'] as String, orderedAt: po['ordered_at'] == null ? null : _i(po['ordered_at']), expectedAt: po['expected_at'] == null ? null : _i(po['expected_at']),
      totalMinor: total, lines: lines);
  }

  Future<List<PoRow>> listPurchaseOrders({List<String>? statuses, String? supplierId}) async {
    final where = <String>['o.deleted_at is null'];
    final args = <Object?>[];
    if (statuses != null && statuses.isNotEmpty) {
      where.add('o.status in (${statuses.map((_) => '?').join(',')})');
      args.addAll(statuses);
    }
    if (supplierId != null) {
      where.add('o.supplier_id = ?');
      args.add(supplierId);
    }
    final rows = await db.query('select o.id, o.order_no, s.name as supplier, o.status, o.currency, o.ordered_at, o.expected_at, o.created_at from purchase_orders o join suppliers s on s.id = o.supplier_id where ${where.join(' and ')} order by o.created_at desc, o.rowid desc limit 300', args);
    final out = <PoRow>[];
    for (final r in rows) {
      out.add(PoRow(
        id: r['id'] as String, orderNo: r['order_no'] as String, supplier: r['supplier'] as String, status: r['status'] as String, currency: r['currency'] as String,
        totalMinor: (await purchaseOrder(r['id'] as String)).totalMinor, orderedAt: r['ordered_at'] == null ? null : _i(r['ordered_at']), expectedAt: r['expected_at'] == null ? null : _i(r['expected_at'])));
    }
    return out;
  }

  // ---- goods received ----

  Future<String?> _findOrCreateBatch(SqlDb tx, String branch, String productId, String? code, String? expiry, int now) async {
    if (code == null && expiry == null) return null;
    final f = await _get(tx, "select id from stock_batches where product_id = ? and branch_id = ? and coalesce(batch_code, '') = ? and coalesce(expiry_date, '') = ? and deleted_at is null", [productId, branch, code ?? '', expiry ?? '']);
    if (f != null) return f['id'] as String;
    return _add(tx, 'stock_batches', {'product_id': productId, 'branch_id': branch, 'batch_code': code, 'expiry_date': expiry, 'received_at': now}, now, versioned: true);
  }

  /// The inside of SetupRepository.receiveStock for a caller that already holds a transaction (port of stockIn in setup.ts).
  Future<void> _stockIn(SqlDb tx, {required String branch, required String productId, required int qty, int? unitCost, String? batchId, String? refType, String? refId, required int now}) async {
    final p = await _get(tx, 'select * from products where id = ? and deleted_at is null', [productId]);
    if (p == null) throw SetupError('not_found', 'That product was not found.');
    final base = await _base(tx);
    final onHand = _i((await _get(tx, 'select coalesce(sum(qty_milli), 0) as q from stock_levels where product_id = ?', [productId]))!['q']);
    await _add(tx, 'stock_movements', {
      'branch_id': branch, 'product_id': productId, 'batch_id': batchId, 'type': 'purchase', 'qty_milli': qty, 'unit_cost_minor': unitCost, 'cost_currency': base,
      'ref_type': refType, 'ref_id': refId, 'reason': null,
    }, now);
    if (unitCost != null) {
      final costing = (await _get(tx, "select value from settings where scope = 'shop' and key = 'costing' and deleted_at is null"))?['value'];
      final old = p['cost_minor'] == null ? null : _i(p['cost_minor']);
      var next = unitCost;
      if (costing != 'latest' && onHand > 0 && old != null) {
        final sum = onHand * old + qty * unitCost;
        final den = onHand + qty;
        next = (sum * 2 + den) ~/ (den * 2); // half up, whole cents
      }
      if (next != old) await _edit(tx, 'products', productId, {'cost_minor': next, 'cost_currency': base}, now);
    }
  }

  /// Goods arrive from a supplier, with or without an order. Stock goes up (by batch when a batch code or expiry is given),
  /// the product's cost moves, what we owe the supplier goes up by the value, and the order (if any) is updated.
  Future<ReceiveResult> receiveGoods({
    required String supplierId, required String branchId, String? purchaseOrderId, String? receiptRef, required String currency,
    required List<ReceiveLine> lines, String? invoiceNo, String? dueDate,
  }) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      if (lines.isEmpty) throw SetupError('no_lines', 'Add at least one product.');
      if (lines.length > 200) throw SetupError('too_many_lines', 'A receipt can have at most 200 lines.');
      if (dueDate != null && dueDate.isNotEmpty && !_validDate(dueDate)) throw SetupError('bad_date', 'The due date is not valid.');
      if (await _get(tx, 'select 1 as x from suppliers where id = ? and deleted_at is null', [supplierId]) == null) throw SetupError('unknown_supplier', 'That supplier was not found.');
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      await _currency(tx, currency);
      final base = await _base(tx);
      _Row? po;
      final poLines = <String, int>{};
      var got = <String, int>{};
      if (purchaseOrderId != null) {
        po = await _get(tx, 'select * from purchase_orders where id = ? and deleted_at is null', [purchaseOrderId]);
        if (po == null) throw SetupError('not_found', 'That order was not found.');
        if (po['supplier_id'] != supplierId) throw SetupError('wrong_supplier', 'That order is for a different supplier.');
        if (!['sent', 'partly_received'].contains(po['status'])) throw SetupError('order_not_open', 'That order is not waiting for goods. Send it first.');
        if (po['currency'] != currency) throw SetupError('wrong_currency', 'That order is in ${po['currency']}.');
        for (final l in await tx.query('select product_id, qty_milli from purchase_order_lines where purchase_order_id = ? and deleted_at is null', [po['id']])) {
          poLines[l['product_id'] as String] = _i(l['qty_milli']);
        }
        got = await _receivedByProduct(tx, po['id'] as String);
      }
      final asked = <String, int>{};
      var total = 0;
      final prepared = <({ReceiveLine l, String? code, String? expiry})>[];
      for (final l in lines) {
        if (!_isQty(l.qtyMilli)) throw SetupError('bad_quantity', 'Quantity must be more than zero.');
        if (!_isMinor(l.costMinor)) throw SetupError('bad_amount', 'The cost must be zero or more.');
        final p = await _get(tx, 'select name, track_stock from products where id = ? and deleted_at is null', [l.productId]);
        if (p == null) throw SetupError('not_found', 'A product on the receipt was not found.');
        if (p['track_stock'] != 1) throw SetupError('not_tracked', '${p['name']} does not keep stock.');
        final code = _clean(l.batchCode, 40);
        final expiry = (l.expiryDate == null || l.expiryDate!.isEmpty) ? null : l.expiryDate;
        if (expiry != null && !_validDate(expiry)) throw SetupError('bad_date', 'The expiry date for ${p['name']} is not valid.');
        if (po != null) {
          final ordered = poLines[l.productId];
          if (ordered == null) throw SetupError('not_on_order', '${p['name']} is not on that order.');
          final remaining = ordered - (got[l.productId] ?? 0) - (asked[l.productId] ?? 0);
          if (l.qtyMilli > remaining) throw SetupError('over_received', 'Only ${_qtyText(remaining < 0 ? 0 : remaining)} of ${p['name']} still to come on this order.');
          asked[l.productId] = (asked[l.productId] ?? 0) + l.qtyMilli;
        }
        total += lineAmount(l.qtyMilli, l.costMinor);
        prepared.add((l: l, code: code, expiry: expiry));
      }
      final ref = _clean(receiptRef, 60);
      final grn = await _add(tx, 'goods_received', {'supplier_id': supplierId, 'branch_id': branchId, 'purchase_order_id': po?['id'], 'receipt_ref': ref, 'currency': currency, 'received_at': now}, now);
      for (final x in prepared) {
        final l = x.l;
        await _add(tx, 'goods_received_lines', {'goods_received_id': grn, 'product_id': l.productId, 'batch_code': x.code, 'expiry_date': x.expiry, 'qty_milli': l.qtyMilli, 'cost_minor': l.costMinor}, now);
        final batch = await _findOrCreateBatch(tx, branchId, l.productId, x.code, x.expiry, now);
        await _stockIn(tx, branch: branchId, productId: l.productId, qty: l.qtyMilli, unitCost: await _toBaseCost(tx, l.costMinor, currency, base, now), batchId: batch, refType: 'goods_received', refId: grn, now: now);
        final sp = await _get(tx, 'select id from supplier_products where supplier_id = ? and product_id = ? and deleted_at is null', [supplierId, l.productId]);
        if (sp != null) {
          await _edit(tx, 'supplier_products', sp['id'] as String, {'last_cost_minor': l.costMinor, 'cost_currency': currency}, now);
        } else {
          await _add(tx, 'supplier_products', {'supplier_id': supplierId, 'product_id': l.productId, 'supplier_code': null, 'last_cost_minor': l.costMinor, 'cost_currency': currency}, now, versioned: true);
        }
      }
      if (total > 0) await _add(tx, 'supplier_ledger', {'supplier_id': supplierId, 'type': 'purchase', 'currency': currency, 'amount_minor': total, 'ref_type': 'goods_received', 'ref_id': grn}, now);
      final invNo = _clean(invoiceNo, 60);
      final due = (dueDate == null || dueDate.isEmpty) ? null : dueDate;
      if (invNo != null || due != null) {
        await _add(tx, 'supplier_invoices', {'supplier_id': supplierId, 'goods_received_id': grn, 'invoice_no': invNo, 'currency': currency, 'amount_minor': total, 'due_date': due}, now, versioned: true);
      }
      String? orderStatus;
      if (po != null) {
        final after = await _receivedByProduct(tx, po['id'] as String);
        final done = poLines.entries.every((e) => (after[e.key] ?? 0) >= e.value);
        orderStatus = done ? 'received' : 'partly_received';
        if (orderStatus != po['status']) await _edit(tx, 'purchase_orders', po['id'] as String, {'status': orderStatus}, now);
      }
      await _add(tx, 'audit_log', {'user_id': userId, 'action': 'goods_received', 'table_name': 'goods_received', 'row_id': grn, 'after': jsonEncode({'supplier_id': supplierId, 'total_minor': total, 'currency': currency, 'lines': prepared.length})}, now);
      return ReceiveResult(grn, total, orderStatus);
    });
  }

  // ---- supplier returns ----

  /// Goods go back to the supplier. Stock goes down; unless [credit] is false the value comes off what we owe.
  Future<({String returnId, int totalMinor})> returnToSupplier({
    required String supplierId, required String branchId, required String currency, required List<SupplierReturnLine> lines, required String reason, bool credit = true,
  }) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx);
      final why = _clean(reason, 200);
      if (why == null) throw SetupError('reason_needed', 'Give a reason.');
      if (lines.isEmpty) throw SetupError('no_lines', 'Add at least one product.');
      if (await _get(tx, 'select 1 as x from suppliers where id = ? and deleted_at is null', [supplierId]) == null) throw SetupError('unknown_supplier', 'That supplier was not found.');
      if (await _get(tx, 'select 1 as x from branches where id = ? and deleted_at is null', [branchId]) == null) throw SetupError('unknown_branch', 'That branch was not found.');
      await _currency(tx, currency);
      final base = await _base(tx);
      final returnId = _newId();
      final asked = <String, int>{};
      var total = 0;
      for (final l in lines) {
        if (!_isQty(l.qtyMilli)) throw SetupError('bad_quantity', 'Quantity must be more than zero.');
        if (!_isMinor(l.costMinor)) throw SetupError('bad_amount', 'The cost must be zero or more.');
        final p = await _get(tx, 'select name from products where id = ? and deleted_at is null', [l.productId]);
        if (p == null) throw SetupError('not_found', 'A product on the return was not found.');
        final batch = l.batchId;
        if (batch != null && await _get(tx, 'select 1 as x from stock_batches where id = ? and product_id = ? and deleted_at is null', [batch, l.productId]) == null) {
          throw SetupError('unknown_batch', 'That batch was not found.');
        }
        final key = '${l.productId}|${batch ?? ''}';
        final have = _i((await _get(tx, 'select coalesce(sum(qty_milli), 0) as q from stock_levels where branch_id = ? and product_id = ? and batch_key = ?', [branchId, l.productId, batch ?? '']))!['q']) - (asked[key] ?? 0);
        if (l.qtyMilli > have) throw SetupError('not_enough_stock', 'Only ${_qtyText(have < 0 ? 0 : have)} of ${p['name']} on the shelf${batch != null ? ' in that batch' : ''}.');
        asked[key] = (asked[key] ?? 0) + l.qtyMilli;
        await _add(tx, 'stock_movements', {
          'branch_id': branchId, 'product_id': l.productId, 'batch_id': batch, 'type': 'supplier_return', 'qty_milli': -l.qtyMilli,
          'unit_cost_minor': await _toBaseCost(tx, l.costMinor, currency, base, now), 'cost_currency': base, 'ref_type': 'supplier_return', 'ref_id': returnId, 'reason': why,
        }, now);
        total += lineAmount(l.qtyMilli, l.costMinor);
      }
      if (credit && total > 0) {
        await _add(tx, 'supplier_ledger', {'supplier_id': supplierId, 'type': 'return', 'currency': currency, 'amount_minor': -total, 'ref_type': 'supplier_return', 'ref_id': returnId}, now);
      }
      await _add(tx, 'audit_log', {
        'user_id': userId, 'action': 'supplier_return', 'table_name': 'stock_movements', 'row_id': returnId,
        'after': jsonEncode({'supplier_id': supplierId, 'total_minor': total, 'currency': currency, 'credit': credit, 'reason': why}),
      }, now);
      return (returnId: returnId, totalMinor: total);
    });
  }

  // ---- paying suppliers ----

  /// Pays what we owe a supplier in [debtCurrency]. The money may be handed over in another currency; it is converted at today's rate.
  /// Paying more than is owed is refused (the same rule as customer payments). A cash payment made by someone with an open shift
  /// is also written to that shift as cash out, so the cash-up still adds up. Port of paySupplier (and applyPayment) in the TS reference.
  Future<SupplierPayResult> paySupplier({required String supplierId, required String debtCurrency, required String methodCode, required String currency, required int amountMinor, String? reference}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx, 'supplier.pay');
      final sup = await _get(tx, 'select name from suppliers where id = ? and deleted_at is null', [supplierId]);
      if (sup == null) throw SetupError('unknown_supplier', 'That supplier was not found.');
      final owed = _i((await _get(tx, 'select coalesce(sum(amount_minor), 0) as b from supplier_ledger where supplier_id = ? and currency = ?', [supplierId, debtCurrency]))!['b']);

      if (amountMinor <= 0) throw SetupError('bad_payment', 'A payment must be more than zero.');
      final m = await _get(tx, 'select * from payment_methods where code = ? and deleted_at is null', [methodCode]);
      if (m == null) throw SetupError('unknown_method', 'Payment method $methodCode is not set up.');
      if (m['requires_reference'] == 1 && (reference ?? '').trim().isEmpty) throw SetupError('reference_needed', '${m['name']} needs the confirmation reference.');
      final payCur = await _currency(tx, currency);
      final tgtCur = await _currency(tx, debtCurrency);
      if (owed <= 0) throw SetupError('nothing_owed', 'There is nothing to pay.');
      final rate = await _rate(tx, currency, debtCurrency, now);
      final converted = currency == debtCurrency ? amountMinor : convertMinor(amountMinor, rate, _i(payCur['minor_units']), _i(tgtCur['minor_units']));
      if (converted <= 0) throw SetupError('bad_payment', 'That amount is too small to count.');
      var applied = converted;
      if (converted > owed) {
        final back = currency == debtCurrency
            ? converted - owed
            : convertMinor(converted - owed, await _rate(tx, debtCurrency, currency, now), _i(tgtCur['minor_units']), _i(payCur['minor_units']));
        final inc = payCur['rounding_increment_minor'] == null ? 0 : _i(payCur['rounding_increment_minor']);
        final step = inc < 1 ? 1 : inc;
        if (back >= step) throw SetupError('overpaid', 'That is more than is owed.');
        applied = owed;
      }

      final pid = await _add(tx, 'supplier_payments', {
        'supplier_id': supplierId, 'currency': currency, 'amount_minor': amountMinor, 'method_code': methodCode, 'reference': _clean(reference, 60),
        'target_currency': debtCurrency, 'applied_minor': applied, 'rate_to_target_micro': rate, 'user_id': userId,
      }, now);
      await _add(tx, 'supplier_ledger', {'supplier_id': supplierId, 'type': 'payment', 'currency': debtCurrency, 'amount_minor': -applied, 'ref_type': 'supplier_payment', 'ref_id': pid}, now);
      var cashOut = false;
      final shift = userId == null ? null : await _get(tx, "select id from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1", [userId]);
      if (m['kind'] == 'cash' && shift != null) {
        await _add(tx, 'cash_events', {'shift_id': shift['id'], 'currency': currency, 'type': 'cash_out', 'amount_minor': amountMinor, 'reason': 'Supplier: ${sup['name']}'}, now);
        cashOut = true;
      }
      await _add(tx, 'audit_log', {'user_id': userId, 'action': 'supplier_payment', 'table_name': 'supplier_payments', 'row_id': pid, 'after': jsonEncode({'supplier_id': supplierId, 'applied_minor': applied, 'currency': debtCurrency})}, now);
      return SupplierPayResult(paymentId: pid, appliedMinor: applied, debtCurrency: debtCurrency, balanceAfterMinor: owed - applied, cashOutRecorded: cashOut);
    });
  }
}
