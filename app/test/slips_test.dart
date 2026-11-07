import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/customers/customer_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/printing/receipt.dart';
import 'package:tim_pos/printing/slips.dart';
import 'package:tim_pos/returns/return_repository.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/shifts/shift_repository.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
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

  ReturnRepository returns() => ReturnRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: 'u-mgr', clock: () => now);
  CustomerRepository customers() => CustomerRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: 'u-mgr', clock: () => now);
  ShiftRepository shifts() => ShiftRepository(db: db, shopId: 's', deviceId: 'd', userId: 'u-mgr', clock: () => now);

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0;
    await put('shops', {'name': 'Mbare Mini Market', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('currencies', {'code': 'ZiG', 'name': 'ZiG', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100, 'is_active': 1});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': t0 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('branches', {'id': 'branch', 'name': 'Main branch'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    for (final p in [('bread', 'Bread', 150, 90), ('radio', 'Radio', 4000, 2500)]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple', 'cost_minor': p.$4, 'cost_currency': 'USD'});
      await put('product_prices', {'product_id': p.$1, 'currency': 'USD', 'price_minor': p.$3, 'effective_from': t0 - 9000});
      await put('stock_movements', {'branch_id': 'branch', 'product_id': p.$1, 'type': 'purchase', 'qty_milli': p.$1 == 'bread' ? 50000 : 5000, 'unit_cost_minor': p.$4, 'cost_currency': 'USD'}, versioned: false);
    }
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["sale.create","sale.refund","sale.void","shift.manage","report.view"]'});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
  });

  Future<SaleResult> sale(List<(String, int)> lines, List<CartPayment> pay, {String? customerId, bool onCredit = false, bool layby = false, String? shiftId}) =>
      SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now).sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', customerId: customerId, onCredit: onCredit, layby: layby, shiftId: shiftId, userId: 'u-mgr',
        lines: [for (final l in lines) CartLine(productId: l.$1, qtyMilli: l.$2)], payments: pay,
      ));
  CartPayment cash(String cur, int a) => CartPayment(methodCode: 'cash', currency: cur, amountMinor: a);
  Payout pcash(int a) => Payout(methodCode: 'cash', currency: 'USD', amountMinor: a);
  PaymentInput icash(String cur, int a) => PaymentInput(methodCode: 'cash', currency: cur, amountMinor: a);
  String text(SlipData d, [int w = 32]) => toText(layoutSlip(d, width: w), w);
  Future<String> mai({int limit = 10000}) async {
    await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name, credit_limit_minor, credit_currency) values ('mai', 's', 1, 1, 1, 'Mai Tendai', ?, 'USD')", [limit]);
    return 'mai';
  }

  test('cash-up slip lists sales, money received, refunds, cash events and the drawer count', () async {
    final sh = shifts();
    final shift = await sh.openShift(branchId: 'branch', float: {'USD': 1000, 'ZiG': 0});
    final s = await sale([('bread', 4000)], [cash('USD', 600)], shiftId: shift);
    now = t0 + 2000;
    await sh.addCashEvent(shiftId: shift, currency: 'USD', type: 'cash_out', amountMinor: 100, reason: 'Bought airtime');
    final line = (await returns().returnableLines(s.saleId)).single;
    now = t0 + 3000;
    await returns().processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash(150)]);
    now = t0 + 4000;
    final rep = await sh.closeShift(shift, {'USD': 1300, 'ZiG': 0});
    final d = await loadCashUpSlip(db, rep, 120);
    final t = text(d);
    expect(t, contains('CASH-UP\n'));
    expect(t, matches(RegExp(r'Cashier +Mary')));
    expect(t, matches(RegExp(r'Sold USD +\$6\.00')));
    expect(t, matches(RegExp(r'Cash USD +\$6\.00')));
    expect(t, contains('Paid back to customers'));
    expect(t, matches(RegExp(r'Cash out USD +\$1\.00')));
    expect(t, contains('Bought airtime'));
    expect(t, matches(RegExp(r'Opening float +\$10\.00')));
    expect(t, matches(RegExp(r'Should be +\$13\.50')));
    expect(t, matches(RegExp(r'Counted +\$13\.00')));
    expect(t, matches(RegExp(r'SHORT by +\$0\.50')));
    expect(t, contains('Checked by'));
    expect(t.split('\n').every((x) => x.length <= 32), isTrue);
    expect(text(d, 48).split('\n').every((x) => x.length <= 48), isTrue);
  });

  test('an open shift is marked, and a correct count says so', () async {
    final sh = shifts();
    final shift = await sh.openShift(branchId: 'branch', float: {'USD': 500});
    expect(text(await loadCashUpSlip(db, await sh.report(shift), 0)), contains('still open'));
    final rep = await sh.closeShift(shift, {'USD': 500, 'ZiG': 0});
    expect(text(await loadCashUpSlip(db, rep, 0)), matches(RegExp(r'Correct +OK')));
  });

  test('refund slip shows items, value, what was paid back and the reason', () async {
    final s = await sale([('radio', 1000)], [cash('USD', 4000)]);
    final l = (await returns().returnableLines(s.saleId)).single;
    now = t0 + 5000;
    final r = await returns().processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'Does not work', payouts: [pcash(4000)], approvedBy: 'u-mgr');
    final d = await loadRefundSlip(db, r.returnId, 120);
    final t = text(d);
    expect(t, contains('REFUND / RETURN'));
    expect(t, matches(RegExp(r'Refund no +D1-R000001')));
    expect(t, matches(RegExp('Original receipt +${s.receiptNo}')));
    expect(t, matches(RegExp(r'Radio\nQty 1 +\$40\.00')));
    expect(t, contains('VALUE'));
    expect(t, matches(RegExp(r'Cash USD +\$40\.00')));
    expect(t, contains('Reason: Does not work'));
    expect(t, contains('Customer signature'));
    expect(d.openDrawer, isTrue);
  });

  test('a void slip says so, and shows the amount taken off the account', () async {
    final c = await mai();
    final s = await sale([('bread', 2000)], [], customerId: c, onCredit: true);
    now = t0 + 5000;
    final v = await returns().voidSale(saleId: s.saleId, reason: 'Wrong customer', payouts: []);
    final t = text(await loadRefundSlip(db, v.returnId, 0));
    expect(t, contains('SALE VOIDED'));
    expect(t, matches(RegExp(r'Customer +Mai Tendai')));
    expect(t, matches(RegExp(r'Taken off account +\$3\.00')));
    expect(t, isNot(contains('Paid back')));
  });

  test('account payment receipt shows what was paid, what it counted as and the balance left', () async {
    final c = await mai();
    await sale([('bread', 4000)], [], customerId: c, onCredit: true); // owes 6.00
    now = t0 + 6000;
    final p1 = await customers().receiveAccountPayment(customerId: c, debtCurrency: 'USD', payment: icash('USD', 200));
    now = t0 + 7000;
    final p2 = await customers().receiveAccountPayment(customerId: c, debtCurrency: 'USD', payment: icash('ZiG', 5300));
    var t = text(await loadPaymentSlip(db, p1.paymentId, 120));
    expect(t, contains('PAYMENT RECEIVED'));
    expect(t, matches(RegExp(r'Receipt +D1-P')));
    expect(t, matches(RegExp(r'Customer +Mai Tendai')));
    expect(t, matches(RegExp(r'Balance owing +\$4\.00')));
    t = text(await loadPaymentSlip(db, p2.paymentId, 120));
    expect(t, matches(RegExp(r'Cash ZiG +ZiG 53\.00')));
    expect(t, matches(RegExp(r'Counted as +\$2\.00')));
    expect(t, matches(RegExp(r'Balance owing +\$2\.00')));
    expect(text(await loadPaymentSlip(db, p1.paymentId, 120)), matches(RegExp(r'Balance owing +\$4\.00')));
  });

  test('layby instalment receipt shows the balance left on the layby', () async {
    final c = await mai(limit: 0);
    final l = await sale([('radio', 1000)], [cash('USD', 1000)], customerId: c, layby: true);
    now = t0 + 6000;
    final a = await customers().payLayby(saleId: l.saleId, payment: icash('USD', 1500));
    now = t0 + 7000;
    final b = await customers().payLayby(saleId: l.saleId, payment: icash('USD', 1500));
    final ta = text(await loadPaymentSlip(db, a.paymentId, 0));
    expect(ta, matches(RegExp(r'LAYBY PAYMENT[\s\S]*Layby sale +D1-')));
    expect(ta, matches(RegExp(r'Balance on layby +\$15\.00')));
    expect(text(await loadPaymentSlip(db, b.paymentId, 0)), matches(RegExp(r'Balance on layby +\$0\.00')));
  });

  test('slips print as bytes too, with the drawer pulse only when asked', () async {
    final s = await sale([('radio', 1000)], [cash('USD', 4000)]);
    final l = (await returns().returnableLines(s.saleId)).single;
    final r = await returns().processReturn(saleId: s.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash(4000)]);
    final d = await loadRefundSlip(db, r.returnId, 0);
    final plain = toEscPos(layoutSlip(d, width: 32), 32);
    final drawer = toEscPos(layoutSlip(d, width: 32, openDrawer: true), 32);
    expect(drawer.length, greaterThan(plain.length));
    expect(plain.first, 0x1b);
  });
}
