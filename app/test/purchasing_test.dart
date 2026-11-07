import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/purchasing/purchasing_repository.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;
import 'package:tim_pos/shifts/shift_repository.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
  var now = t0 + 1000;
  var n = 0;

  Future<void> put(String table, Map<String, Object?> row, {bool versioned = true}) async {
    final o = <String, Object?>{
      'id': 'seed-${(++n).toString().padLeft(6, '0')}', 'shop_id': 's', 'created_at': t0 - 1000,
      if (versioned) ...{'updated_at': t0 - 1000, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await db.exec('insert into "$table" (${k.map((x) => '"$x"').join(',')}) values (${List.filled(k.length, '?').join(',')})', k.map((x) => o[x]).toList());
  }

  PurchasingRepository repo([String? user = 'u-mgr']) => PurchasingRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: user, clock: () => now);
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));
  Future<int> level(String p, [String batch = '']) async => (await db.query('select coalesce(sum(qty_milli),0) as s from stock_levels where product_id = ? and batch_key = ?', [p, batch])).single['s'] as int;
  Future<int> cost(String p) async => (await db.query('select cost_minor from products where id = ?', [p])).single['cost_minor'] as int;
  late String sup;

  PoLineInput pl(String p, int qty, int cost) => PoLineInput(productId: p, qtyMilli: qty, costMinor: cost);
  ReceiveLine rl(String p, int qty, int cost, {String? code, String? expiry}) => ReceiveLine(productId: p, qtyMilli: qty, costMinor: cost, batchCode: code, expiryDate: expiry);
  Future<ReceiveResult> receive(List<ReceiveLine> lines, {String cur = 'USD', String? order, String? supplier, String? ref, String? invoiceNo, String? due, String? user = 'u-mgr'}) =>
      repo(user).receiveGoods(supplierId: supplier ?? sup, branchId: 'branch', purchaseOrderId: order, receiptRef: ref, currency: cur, lines: lines, invoiceNo: invoiceNo, dueDate: due);
  Future<List<Owed>> owed() => repo().owedToSupplier(sup);

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0 + 1000;
    await put('shops', {'name': 'Shop', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('currencies', {'code': 'ZiG', 'name': 'ZiG', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100, 'is_active': 1});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': t0 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('payment_methods', {'code': 'ecocash', 'name': 'EcoCash', 'kind': 'mobile_money', 'requires_reference': 1, 'opens_drawer': 0});
    await put('branches', {'id': 'branch', 'name': 'Main', 'is_active': 1});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    for (final p in [('bread', 'Bread', 150, 90, 1), ('oil', 'Cooking oil', 400, 300, 1), ('airtime', 'Airtime', 100, null, 0)]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': p.$5, 'kind': 'simple', 'cost_minor': p.$4, 'cost_currency': 'USD'});
    }
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'bread', 'type': 'opening', 'qty_milli': 10000, 'unit_cost_minor': 90, 'cost_currency': 'USD'}, versioned: false);
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["stock.receive","supplier.pay","shift.manage"]'});
    await put('roles', {'id': 'r-clerk', 'name': 'Stock clerk', 'permissions': '["stock.receive"]'});
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create"]'});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-clerk', 'name': 'Sam', 'role_id': 'r-clerk', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
    sup = await repo().saveSupplier(const SupplierInput(name: 'Bakers Inn', phone: '0242 000', terms: '30 days'));
  });

  test('suppliers: add, edit, duplicate names refused, search and inactive hidden', () async {
    final r = repo();
    final b = await r.saveSupplier(const SupplierInput(name: '  Delta   Beverages ', address: 'Harare'));
    await expectLater(r.saveSupplier(const SupplierInput(name: 'delta beverages')), failsWith('duplicate_supplier'));
    await expectLater(r.saveSupplier(const SupplierInput(name: ' ')), failsWith('name_needed'));
    await r.saveSupplier(SupplierInput(id: b, name: 'Delta Beverages', phone: '0772'));
    expect((await r.listSuppliers()).map((s) => s.name), ['Bakers Inn', 'Delta Beverages']);
    expect((await r.listSuppliers(search: 'delta')).map((s) => [s.name, s.phone]), [['Delta Beverages', '0772']]);
    await r.saveSupplier(SupplierInput(id: b, name: 'Delta Beverages', isActive: false));
    expect((await r.listSuppliers()).length, 1);
    expect((await r.listSuppliers(includeInactive: true)).length, 2);
  });

  test('only people with stock.receive manage suppliers and orders', () async {
    await expectLater(repo('u-cash').saveSupplier(const SupplierInput(name: 'X')), failsWith('forbidden'));
    await repo('u-clerk').saveSupplier(const SupplierInput(name: 'Y'));
    await expectLater(repo('u-cash').createPurchaseOrder(supplierId: sup, branchId: 'branch', currency: 'USD', lines: [pl('bread', 1000, 90)]), failsWith('forbidden'));
  });

  test('a purchase order goes draft, sent, partly received, received; nothing is owed or moved until goods arrive', () async {
    final r = repo();
    final o = await r.createPurchaseOrder(supplierId: sup, branchId: 'branch', currency: 'USD', lines: [pl('bread', 20000, 95), pl('oil', 6000, 310)]);
    expect(o.orderNo, 'D1-PO000001');
    var po = await r.purchaseOrder(o.orderId);
    expect([po.status, po.totalMinor, po.lines.length], ['draft', 20 * 95 + 6 * 310, 2]);
    await expectLater(receive([rl('bread', 1000, 95)], order: o.orderId), failsWith('order_not_open'));
    await r.updatePurchaseOrder(o.orderId, lines: [pl('bread', 20000, 95), pl('oil', 5000, 310)]);
    expect((await r.purchaseOrder(o.orderId)).lines.length, 2);
    expect((await db.query('select count(*) as c from purchase_order_lines where purchase_order_id = ? and deleted_at is null', [o.orderId])).single['c'], 2);
    await r.sendPurchaseOrder(o.orderId);
    await expectLater(r.updatePurchaseOrder(o.orderId, setExpected: true, expectedAt: 1), failsWith('order_locked'));
    expect(await level('bread'), 10000);
    expect(await owed(), isEmpty);

    now = t0 + 2000;
    final r1 = await receive([rl('bread', 12000, 95)], order: o.orderId, ref: 'DN-77');
    expect([r1.totalMinor, r1.orderStatus], [1140, 'partly_received']);
    po = await r.purchaseOrder(o.orderId);
    expect(po.lines.map((l) => [l.product, l.receivedMilli, l.remainingMilli]), [['Bread', 12000, 8000], ['Cooking oil', 0, 5000]]);
    await expectLater(r.cancelPurchaseOrder(o.orderId), failsWith('already_received'));
    await expectLater(receive([rl('bread', 8001, 95)], order: o.orderId), failsWith('over_received'));
    now = t0 + 3000;
    final r2 = await receive([rl('bread', 8000, 95), rl('oil', 5000, 310)], order: o.orderId);
    expect(r2.orderStatus, 'received');
    expect(await level('bread'), 30000);
    expect(await owed(), [const Owed('USD', 1140 + 760 + 1550)]);
    expect((await r.listPurchaseOrders(statuses: ['received'])).map((p) => [p.orderNo, p.totalMinor]), [['D1-PO000001', 20 * 95 + 5 * 310]]);
    await expectLater(r.closePurchaseOrder(o.orderId), failsWith('bad_status'));
  });

  test('an order can be cancelled before anything arrives, or closed short once partly received', () async {
    final r = repo();
    final a = (await r.createPurchaseOrder(supplierId: sup, branchId: 'branch', currency: 'USD', lines: [pl('bread', 1000, 90)])).orderId;
    await r.cancelPurchaseOrder(a);
    expect((await r.purchaseOrder(a)).status, 'cancelled');
    await expectLater(r.sendPurchaseOrder(a), failsWith('bad_status'));
    final b = (await r.createPurchaseOrder(supplierId: sup, branchId: 'branch', currency: 'USD', lines: [pl('bread', 10000, 90)])).orderId;
    await r.sendPurchaseOrder(b);
    await receive([rl('bread', 4000, 90)], order: b);
    await r.closePurchaseOrder(b);
    expect((await r.purchaseOrder(b)).status, 'received');
    await expectLater(receive([rl('bread', 1000, 90)], order: b), failsWith('order_not_open'));
  });

  test('order checks: duplicates, quantities, wrong supplier or currency, products not on the order', () async {
    final r = repo();
    Future<void> create(List<PoLineInput> lines, {String cur = 'USD', String? supplier}) => r.createPurchaseOrder(supplierId: supplier ?? sup, branchId: 'branch', currency: cur, lines: lines);
    await expectLater(create([]), failsWith('no_lines'));
    await expectLater(create([pl('bread', 1000, 90), pl('bread', 1000, 90)]), failsWith('duplicate_line'));
    await expectLater(create([pl('bread', 0, 90)]), failsWith('bad_quantity'));
    await expectLater(create([pl('bread', 1000, -1)]), failsWith('bad_amount'));
    await expectLater(create([pl('bread', 1000, 90)], supplier: 'nope'), failsWith('unknown_supplier'));
    await expectLater(create([pl('bread', 1000, 90)], cur: 'EUR'), failsWith('unknown_currency'));
    final other = await r.saveSupplier(const SupplierInput(name: 'Other'));
    final o = (await r.createPurchaseOrder(supplierId: sup, branchId: 'branch', currency: 'USD', lines: [pl('bread', 1000, 90)])).orderId;
    await r.sendPurchaseOrder(o);
    await expectLater(receive([rl('bread', 1000, 90)], order: o, supplier: other), failsWith('wrong_supplier'));
    await expectLater(receive([rl('bread', 1000, 90)], order: o, cur: 'ZiG'), failsWith('wrong_currency'));
    await expectLater(receive([rl('oil', 1000, 90)], order: o), failsWith('not_on_order'));
  });

  test('goods without an order: stock up, weighted-average cost, batch and expiry, owed and last cost remembered', () async {
    final r = await receive([rl('bread', 10000, 110, code: 'L7', expiry: '2026-11-10'), rl('oil', 2000, 300)], ref: 'INV-1', invoiceNo: 'INV-1', due: '2026-12-03');
    expect([r.totalMinor, r.orderStatus], [1700, null]);
    expect(await cost('bread'), 100);
    final b = (await db.query('select id, batch_code, expiry_date from stock_batches')).first;
    expect([b['batch_code'], b['expiry_date']], ['L7', '2026-11-10']);
    expect(await level('bread', b['id'] as String), 10000);
    expect(await level('bread'), 10000);
    expect(await level('oil'), 2000);
    final lc = (await repo().lastCost(sup, 'bread'))!;
    expect([lc.costMinor, lc.currency], [110, 'USD']);
    final inv = (await db.query('select invoice_no, amount_minor, due_date from supplier_invoices')).single;
    expect([inv['invoice_no'], inv['amount_minor'], inv['due_date']], ['INV-1', 1700, '2026-12-03']);
    await receive([rl('bread', 1000, 110, code: 'L7', expiry: '2026-11-10')]);
    expect((await db.query('select count(*) as c from stock_batches')).single['c'], 1);
    expect(await level('bread', b['id'] as String), 11000);
    expect(await repo().lastCost(sup, 'airtime'), isNull);
    await expectLater(receive([rl('airtime', 1000, 10)]), failsWith('not_tracked'));
    await expectLater(receive([rl('bread', 1000, 10, expiry: '2026-02-30')]), failsWith('bad_date'));
    await expectLater(receive([rl('bread', 1000, 10)], due: 'soon'), failsWith('bad_date'));
  });

  test('a delivery priced in ZiG is owed in ZiG, and its cost is converted to USD at the day rate', () async {
    await receive([rl('oil', 4000, 7950)], cur: 'ZiG');
    expect(await owed(), [const Owed('ZiG', 31800)]);
    expect(await cost('oil'), 300);
  });

  test('a failed receipt changes nothing', () async {
    await expectLater(receive([rl('bread', 1000, 90), rl('oil', 0, 1)]), failsWith('bad_quantity'));
    expect(await level('bread'), 10000);
    expect((await db.query('select count(*) as c from goods_received')).single['c'], 0);
    expect(await owed(), isEmpty);
  });

  test('returning goods to a supplier takes stock off the shelf and the value off the debt', () async {
    await receive([rl('bread', 10000, 100)]);
    now = t0 + 5000;
    final r = await repo().returnToSupplier(supplierId: sup, branchId: 'branch', currency: 'USD', reason: 'Stale', lines: [const SupplierReturnLine(productId: 'bread', qtyMilli: 3000, costMinor: 100)]);
    expect(r.totalMinor, 300);
    expect(await level('bread'), 17000);
    expect(await owed(), [const Owed('USD', 700)]);
    final mv = (await db.query("select qty_milli, reason from stock_movements where type = 'supplier_return'")).single;
    expect([mv['qty_milli'], mv['reason']], [-3000, 'Stale']);
    await repo().returnToSupplier(supplierId: sup, branchId: 'branch', currency: 'USD', reason: 'Swap for fresh', credit: false, lines: [const SupplierReturnLine(productId: 'bread', qtyMilli: 1000, costMinor: 100)]);
    expect(await owed(), [const Owed('USD', 700)]);
    await expectLater(repo().returnToSupplier(supplierId: sup, branchId: 'branch', currency: 'USD', reason: 'x', lines: [const SupplierReturnLine(productId: 'bread', qtyMilli: 99000, costMinor: 100)]), failsWith('not_enough_stock'));
    await expectLater(repo().returnToSupplier(supplierId: sup, branchId: 'branch', currency: 'USD', reason: ' ', lines: [const SupplierReturnLine(productId: 'bread', qtyMilli: 1000, costMinor: 100)]), failsWith('reason_needed'));
  });

  test('paying a supplier reduces the debt; another currency is converted; overpaying is refused', () async {
    await receive([rl('oil', 10000, 300)]);
    Future<SupplierPayResult> pay(String method, String cur, int amount, {String? ref}) =>
        repo().paySupplier(supplierId: sup, debtCurrency: 'USD', methodCode: method, currency: cur, amountMinor: amount, reference: ref);
    now = t0 + 6000;
    final p1 = await pay('cash', 'USD', 1000);
    expect([p1.appliedMinor, p1.balanceAfterMinor, p1.cashOutRecorded], [1000, 2000, false]);
    now = t0 + 7000;
    final p2 = await pay('cash', 'ZiG', 26500);
    expect([p2.appliedMinor, p2.balanceAfterMinor], [1000, 1000]);
    await expectLater(pay('cash', 'USD', 1500), failsWith('overpaid'));
    await expectLater(pay('ecocash', 'USD', 100), failsWith('reference_needed'));
    now = t0 + 8000;
    await pay('ecocash', 'USD', 1000, ref: 'MP1');
    expect(await owed(), isEmpty);
    await expectLater(pay('cash', 'USD', 100), failsWith('nothing_owed'));
    final st = await repo().supplierStatement(sup);
    expect(st.map((l) => [l.type, l.amountMinor, l.balanceMinor]), [['purchase', 3000, 3000], ['payment', -1000, 2000], ['payment', -1000, 1000], ['payment', -1000, 0]]);
    expect(st[3].ref, 'MP1');
  });

  test('paying suppliers needs supplier.pay; a stock clerk cannot', () async {
    await receive([rl('oil', 1000, 300)]);
    await expectLater(repo('u-clerk').paySupplier(supplierId: sup, debtCurrency: 'USD', methodCode: 'cash', currency: 'USD', amountMinor: 100), failsWith('forbidden'));
    expect(await owed(), [const Owed('USD', 300)]);
  });

  test('a cash payment made during a shift is recorded as cash out, so the cash-up adds up', () async {
    await receive([rl('oil', 10000, 300)]);
    final shifts = ShiftRepository(db: db, shopId: 's', deviceId: 'd', userId: 'u-mgr', clock: () => now);
    now = t0 + 2000;
    final shift = await shifts.openShift(branchId: 'branch', float: {'USD': 5000});
    expect((await shifts.expectedCash(shift))['USD'], 5000);
    now = t0 + 3000;
    final p = await repo().paySupplier(supplierId: sup, debtCurrency: 'USD', methodCode: 'cash', currency: 'USD', amountMinor: 1200);
    expect(p.cashOutRecorded, isTrue);
    expect((await shifts.expectedCash(shift))['USD'], 3800);
    final ev = (await db.query('select type, amount_minor, reason from cash_events')).single;
    expect([ev['type'], ev['amount_minor'], ev['reason']], ['cash_out', 1200, 'Supplier: Bakers Inn']);
    now = t0 + 4000;
    await repo().paySupplier(supplierId: sup, debtCurrency: 'USD', methodCode: 'ecocash', currency: 'USD', amountMinor: 500, reference: 'MP2');
    expect((await shifts.expectedCash(shift))['USD'], 3800);
  });

  test('suppliers owed: the list shows balances and can be limited to those we owe', () async {
    await repo().saveSupplier(const SupplierInput(name: 'Zebra Traders'));
    await receive([rl('oil', 1000, 300)]);
    final l = await repo().listSuppliers(onlyOwed: true);
    expect(l.map((s) => [s.name, s.owes.single.amountMinor]), [['Bakers Inn', 300]]);
  });
}
