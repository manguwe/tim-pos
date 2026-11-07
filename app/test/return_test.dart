import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/customers/customer_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/printing/receipt.dart';
import 'package:tim_pos/returns/return_repository.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;
import 'package:tim_pos/shifts/shift_repository.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
  late SellingEngine engine;
  var now = t0;
  var n = 0;

  Future<void> put(String table, Map<String, Object?> row, {bool versioned = true}) async {
    final o = <String, Object?>{
      'id': 'seed-${(++n).toString().padLeft(6, '0')}', 'shop_id': 's', 'created_at': t0 - 1000,
      if (versioned) ...{'updated_at': t0 - 1000, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await db.exec('insert into "$table" (${k.map((x) => '"$x"').join(',')}) values (${List.filled(k.length, '?').join(',')})', k.map((x) => o[x]).toList());
  }

  ReturnRepository returns([String? user = 'u-mgr']) => ReturnRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: user, clock: () => now);
  CustomerRepository customers() => CustomerRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', clock: () => now);
  ShiftRepository shifts(String? user) => ShiftRepository(db: db, shopId: 's', deviceId: 'd', userId: user, clock: () => now);

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0;
    await put('shops', {'name': 'T', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('currencies', {'code': 'ZiG', 'name': 'ZiG', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100, 'is_active': 1});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': t0 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('payment_methods', {'code': 'ecocash', 'name': 'EcoCash', 'kind': 'mobile_money', 'requires_reference': 1, 'opens_drawer': 0});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    for (final p in [('bread', 'Bread', 150), ('radio', 'Radio', 4000)]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple', 'cost_minor': 90, 'cost_currency': 'USD'});
      await put('product_prices', {'product_id': p.$1, 'currency': 'USD', 'price_minor': p.$3, 'effective_from': t0 - 9000});
      await put('stock_movements', {'branch_id': 'branch', 'product_id': p.$1, 'type': 'purchase', 'qty_milli': p.$1 == 'bread' ? 50000 : 5000, 'unit_cost_minor': 90, 'cost_currency': 'USD'}, versioned: false);
    }
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create","shift.manage"]'});
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["sale.create","sale.refund","sale.void","shift.manage","report.view"]'});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
    engine = SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now);
  });

  Future<SaleResult> sale(List<(String, int)> lines, List<CartPayment> pay, {String? customerId, bool onCredit = false, bool layby = false, String? shiftId}) => engine.sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', customerId: customerId, onCredit: onCredit, layby: layby, shiftId: shiftId,
        lines: [for (final l in lines) CartLine(productId: l.$1, qtyMilli: l.$2)], payments: pay,
      ));
  CartPayment cash(String cur, int a) => CartPayment(methodCode: 'cash', currency: cur, amountMinor: a);
  Payout pcash(String cur, int a) => Payout(methodCode: 'cash', currency: cur, amountMinor: a);
  Future<int> onHand(String p) async => (await db.query('select coalesce(sum(qty_milli),0) as q from stock_movements where product_id = ?', [p])).single['q'] as int;
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));
  Future<String> mai({int limit = 10000}) async {
    await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name, credit_limit_minor, credit_currency) values ('mai', 's', 1, 1, 1, 'Mai', ?, 'USD')", [limit]);
    return 'mai';
  }

  test('a partial return restocks the goods and pays the customer back; the remainder adds up exactly', () async {
    final s = await sale([('bread', 4000)], [cash('USD', 600)]);
    expect(await onHand('bread'), 46000);
    final r = returns();
    final line = (await r.returnableLines(s.saleId)).single;
    expect([line.qtyMilli, line.remainingMilli, line.remainingValueMinor], [4000, 4000, 600]);
    final pv = await r.previewReturn(s.saleId, [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000)]);
    expect([pv.valueMinor, pv.creditPartMinor, pv.payoutDueMinor], [150, 0, 150]);
    expect(await r.suggestPayout(s.saleId, 150), [const Payout(methodCode: 'cash', currency: 'USD', amountMinor: 150)]);

    final r1 = await r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000)], reason: 'Wrong loaf', payouts: [pcash('USD', 150)]);
    expect(r1.receiptNo, 'D1-R000001');
    expect(r1.opensDrawer, isTrue);
    expect(await onHand('bread'), 47000);
    expect((await db.query("select unit_cost_minor from stock_movements where type = 'sale_return'")).single['unit_cost_minor'], 90);

    final r2 = await r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 3000)], reason: 'Rest', payouts: [pcash('USD', 450)]);
    expect(r2.valueMinor, 450);
    expect((await r.returnableLines(s.saleId)).single.remainingMilli, 0);
    await expectLater(r.previewReturn(s.saleId, [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1)]), failsWith('too_many'));
    expect((await r.returnsForSale(s.saleId)).length, 2);
    expect((await r.findSaleByReceipt(s.receiptNo.toLowerCase()))!.saleId, s.saleId);
  });

  test('damaged goods are refunded but not put back on the shelf', () async {
    final s = await sale([('radio', 1000)], [cash('USD', 4000)]);
    final l = (await returns().returnableLines(s.saleId)).single;
    await returns().processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000, restock: false)], reason: 'Broken', payouts: [pcash('USD', 4000)]);
    expect(await onHand('radio'), 4000);
  });

  test('payouts must match what is due; mobile money needs a reference; ZiG may be rounded', () async {
    final s = await sale([('radio', 1000)], [const CartPayment(methodCode: 'ecocash', currency: 'USD', amountMinor: 4000, reference: 'MP9')]);
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    Future<ReturnResult> go(List<Payout> p) => r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: p);
    expect(await r.suggestPayout(s.saleId, 4000), [const Payout(methodCode: 'ecocash', currency: 'USD', amountMinor: 4000)]);
    await expectLater(go([]), failsWith('payout_needed'));
    await expectLater(go([pcash('USD', 3000)]), failsWith('payout_mismatch'));
    await expectLater(go([pcash('USD', 5000)]), failsWith('payout_mismatch'));
    await expectLater(go([const Payout(methodCode: 'ecocash', currency: 'USD', amountMinor: 4000)]), failsWith('reference_needed'));
    await expectLater(go([pcash('USD', 0)]), failsWith('bad_payment'));
    await expectLater(go([const Payout(methodCode: 'nope', currency: 'USD', amountMinor: 4000)]), failsWith('unknown_method'));
    expect((await go([pcash('ZiG', 105950)])).payoutMinor, 4000);
  });

  test('a cashier needs a manager\'s approval to refund or void', () async {
    final s = await sale([('bread', 2000)], [cash('USD', 300)]);
    final l = (await returns().returnableLines(s.saleId)).single;
    final c = returns('u-cash');
    expect(await c.canWithoutApproval('sale.refund'), isFalse);
    expect(await returns().canWithoutApproval('sale.refund'), isTrue);
    final items = [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)];
    await expectLater(c.processReturn(saleId: s.saleId, items: items, reason: 'x', payouts: [pcash('USD', 150)]), failsWith('forbidden'));
    await expectLater(c.voidSale(saleId: s.saleId, reason: 'x', payouts: [pcash('USD', 300)]), failsWith('forbidden'));
    await c.processReturn(saleId: s.saleId, items: items, reason: 'x', payouts: [pcash('USD', 150)], approvedBy: 'u-mgr');
  });

  test('voiding a sale restocks everything, drops it from figures, and cannot be repeated', () async {
    final s = await sale([('bread', 2000), ('radio', 1000)], [cash('USD', 4300)]);
    expect(await onHand('radio'), 4000);
    final r = returns();
    final v = await r.voidSale(saleId: s.saleId, reason: 'Rung up twice', payouts: [pcash('USD', 4300)]);
    expect(v.kind, 'void');
    expect(await onHand('bread'), 50000);
    expect(await onHand('radio'), 5000);
    expect((await db.query('select count(*) as c from sale_voids')).single['c'], 1);
    expect((await loadReceipt(db, s.saleId)).status, 'voided');
    await expectLater(r.voidSale(saleId: s.saleId, reason: 'again', payouts: []), failsWith('already_voided'));
  });

  test('a void after a part-return only takes back what is left', () async {
    final s = await sale([('bread', 2000)], [cash('USD', 300)]);
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    await r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'one', payouts: [pcash('USD', 150)]);
    expect((await r.voidSale(saleId: s.saleId, reason: 'rest', payouts: [pcash('USD', 150)])).valueMinor, 150);
  });

  test('a return on a credit sale first reduces what the customer owes', () async {
    final c = await mai();
    final s = await sale([('radio', 1000)], [cash('USD', 1000)], customerId: c, onCredit: true);
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    final res = await r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'Changed mind', payouts: [pcash('USD', 1000)]);
    expect([res.valueMinor, res.creditPartMinor, res.payoutMinor], [4000, 3000, 1000]);
    expect(await customers().owedBy(c), isEmpty);
  });

  test('if the customer already settled the debt, the return is paid out in full', () async {
    final c = await mai();
    final s = await sale([('radio', 1000)], [], customerId: c, onCredit: true);
    await customers().receiveAccountPayment(customerId: c, debtCurrency: 'USD', payment: cash('USD', 4000));
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    final pv = await r.previewReturn(s.saleId, [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)]);
    expect([pv.creditPartMinor, pv.payoutDueMinor], [0, 4000]);
  });

  test('a layby can only be cancelled, and the customer gets back what they paid; a collected layby can be returned', () async {
    final c = await mai();
    final s = await sale([('radio', 1000)], [cash('USD', 1000)], customerId: c, layby: true);
    await customers().payLayby(saleId: s.saleId, payment: cash('USD', 500));
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    final items = [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)];
    await expectLater(r.previewReturn(s.saleId, items), failsWith('layby_void_only'));
    final pv = await r.previewReturn(s.saleId, items, kind: 'void');
    expect([pv.valueMinor, pv.payoutDueMinor, pv.layby], [4000, 1500, true]);
    expect((await r.voidSale(saleId: s.saleId, reason: 'Cancelled', payouts: [pcash('USD', 1500)])).payoutMinor, 1500);
    expect(await onHand('radio'), 5000);

    final s2 = await sale([('radio', 1000)], [cash('USD', 1000)], customerId: c, layby: true);
    await customers().payLayby(saleId: s2.saleId, payment: cash('USD', 3000));
    await customers().collectLayby(s2.saleId);
    final l2 = (await r.returnableLines(s2.saleId)).single;
    await expectLater(r.voidSale(saleId: s2.saleId, reason: 'x', payouts: [pcash('USD', 4000)]), failsWith('collected'));
    expect((await r.processReturn(saleId: s2.saleId, items: [ReturnItem(saleLineId: l2.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash('USD', 4000)])).payoutMinor, 4000);
  });

  test('refunds paid in cash come out of the shift cash-up, and voided sales leave the shift totals', () async {
    final sh = shifts('u-mgr');
    final id = await sh.openShift(branchId: 'branch', float: {'USD': 1000});
    final s1 = await sale([('bread', 2000)], [cash('USD', 300)], shiftId: id);
    final s2 = await sale([('bread', 2000)], [cash('USD', 300)], shiftId: id);
    expect((await sh.expectedCash(id))['USD'], 1600);
    final r = returns();
    final l = (await r.returnableLines(s1.saleId)).single;
    await r.processReturn(saleId: s1.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash('USD', 150)]);
    expect((await sh.expectedCash(id))['USD'], 1450);
    await r.voidSale(saleId: s2.saleId, reason: 'x', payouts: [pcash('USD', 300)]);
    expect((await sh.expectedCash(id))['USD'], 1150);
    final rep = await sh.report(id);
    expect([rep.sales, rep.voided], [1, 1]);
    expect(rep.refunds.single.amountMinor, 450);
    now = t0 + 5000;
    expect((await sh.closeShift(id, {'USD': 1150, 'ZiG': 0})).difference, {'USD': 0, 'ZiG': 0});
  });

  test('a failed return leaves no trace', () async {
    final s = await sale([('bread', 2000)], [cash('USD', 300)]);
    final r = returns();
    final l = (await r.returnableLines(s.saleId)).single;
    await expectLater(r.processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash('USD', 999)]), failsWith('payout_mismatch'));
    expect(await db.query('select * from sale_returns'), isEmpty);
    expect(await db.query("select * from stock_movements where type = 'sale_return'"), isEmpty);
    expect(await db.query("select * from receipt_counters where kind = 'return'"), isEmpty);
    expect(await onHand('bread'), 48000);
  });
}
