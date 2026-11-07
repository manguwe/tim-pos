import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/customers/customer_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/reports/report_repository.dart';
import 'package:tim_pos/returns/return_repository.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/shifts/shift_repository.dart';

import 'support/ffi_db.dart';

const day = 86400000;
final d1 = DateTime.utc(2026, 11, 2, 6, 0).millisecondsSinceEpoch; // 08:00 local (UTC+2)
final localMidnight = DateTime.utc(2026, 11, 1, 22, 0).millisecondsSinceEpoch;
DateRange dayRange(int i) => DateRange(localMidnight + i * day, localMidnight + (i + 1) * day);

void main() {
  late SqlDb db;
  late ReportRepository rep;
  var now = 0;
  var n = 0;

  Future<void> put(String table, Map<String, Object?> row, {bool versioned = true}) async {
    final o = <String, Object?>{
      'id': 'seed-${(++n).toString().padLeft(6, '0')}', 'shop_id': 's', 'created_at': d1 - 1000,
      if (versioned) ...{'updated_at': d1 - 1000, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await db.exec('insert into "$table" (${k.map((x) => '"$x"').join(',')}) values (${List.filled(k.length, '?').join(',')})', k.map((x) => o[x]).toList());
  }

  SellingEngine engineAt() => SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now);
  ReturnRepository returns() => ReturnRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', clock: () => now);
  CustomerRepository customers() => CustomerRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', clock: () => now);
  ShiftRepository shifts() => ShiftRepository(db: db, shopId: 's', deviceId: 'd', clock: () => now);

  setUp(() async {
    db = await openTestDb();
    rep = ReportRepository(db);
    n = 0;
    now = d1;
    await put('shops', {'name': 'T', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('currencies', {'code': 'ZiG', 'name': 'ZiG', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100, 'is_active': 1});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': d1 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('payment_methods', {'code': 'ecocash', 'name': 'EcoCash', 'kind': 'mobile_money', 'requires_reference': 1, 'opens_drawer': 0});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('tax_classes', {'id': 'vat', 'name': 'Standard rated', 'rate_bp': 1500, 'is_inclusive': 1});
    for (final p in [('bread', 'Bread', 150, 'vat', 50000), ('radio', 'Radio', 4000, null, 5000)]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'tax_class_id': p.$4, 'is_active': 1, 'track_stock': 1, 'kind': 'simple', 'cost_minor': p.$1 == 'bread' ? 90 : 2500, 'cost_currency': 'USD'});
      await put('product_prices', {'product_id': p.$1, 'currency': 'USD', 'price_minor': p.$3, 'effective_from': d1 - 9000});
      await put('stock_movements', {'branch_id': 'branch', 'product_id': p.$1, 'type': 'purchase', 'qty_milli': p.$5, 'unit_cost_minor': p.$1 == 'bread' ? 90 : 2500, 'cost_currency': 'USD'}, versioned: false);
    }
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["sale.create","sale.refund","sale.void","shift.manage","report.view"]'});
  });

  Future<SaleResult> sale(int at, List<(String, int)> lines, List<CartPayment> pay, {String cur = 'USD', String? customerId, bool onCredit = false}) async {
    now = at;
    return engineAt().sell(Cart(
      branchId: 'branch', saleCurrency: cur, customerId: customerId, onCredit: onCredit,
      lines: [for (final l in lines) CartLine(productId: l.$1, qtyMilli: l.$2)], payments: pay,
    ));
  }

  CartPayment cash(String cur, int a) => CartPayment(methodCode: 'cash', currency: cur, amountMinor: a);
  Payout pcash(int a) => Payout(methodCode: 'cash', currency: 'USD', amountMinor: a);

  test('sales summary: counts, totals per currency, base-currency revenue, cost and profit', () async {
    final a = await sale(d1, [('bread', 4000)], [cash('USD', 600)]);
    final b = await sale(d1 + 1000, [('radio', 1000)], [cash('ZiG', 106000)], cur: 'ZiG');
    final s = await rep.salesSummary(dayRange(0));
    expect(s.sales, 2);
    expect(s.byCurrency.map((c) => [c.currency, c.sales, c.grossMinor]), [['USD', 1, 600], ['ZiG', 1, 106000]]);
    expect(s.revenueMinor, 4600);
    expect(s.costMinor, 4 * 90 + 2500);
    expect(s.taxMinor, a.taxMinor + b.taxMinor);
    expect(s.profitMinor, 4600 - s.taxMinor - 2860);
    expect(s.averageSaleMinor, 2300);
    expect((await rep.salesSummary(dayRange(1))).sales, 0);
    expect((await rep.salesSummary(dayRange(0), const ReportFilter(branchId: 'other'))).sales, 0);
  });

  test('a return reduces the sales of the day it was made, and a damaged item keeps its cost', () async {
    final a = await sale(d1, [('bread', 4000)], [cash('USD', 600)]);
    final line = (await returns().returnableLines(a.saleId)).single;
    now = d1 + day;
    await returns().processReturn(saleId: a.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash(150)]);
    await returns().processReturn(saleId: a.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000, restock: false)], reason: 'damaged', payouts: [pcash(150)]);
    expect((await rep.salesSummary(dayRange(0))).revenueMinor, 600);
    final d1s = await rep.salesSummary(dayRange(1));
    expect([d1s.sales, d1s.returns, d1s.revenueMinor, d1s.costMinor], [0, 2, -300, -90]);
    final whole = await rep.salesSummary(DateRange(dayRange(0).from, dayRange(1).to));
    expect([whole.sales, whole.revenueMinor, whole.costMinor], [1, 300, 270]);
    expect(whole.byCurrency.single.netMinor, 300);
  });

  test('a voided sale and the returns made on it disappear from every figure', () async {
    await sale(d1, [('radio', 1000)], [cash('USD', 4000)]);
    final v = await sale(d1 + 10, [('bread', 2000)], [cash('USD', 300)]);
    final l = (await returns().returnableLines(v.saleId)).single;
    now = d1 + 20;
    await returns().processReturn(saleId: v.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash(150)]);
    await returns().voidSale(saleId: v.saleId, reason: 'x', payouts: [pcash(150)]);
    final s = await rep.salesSummary(dayRange(0));
    expect([s.sales, s.returns, s.revenueMinor, s.costMinor], [1, 0, 4000, 2500]);
    expect((await rep.topProducts(dayRange(0))).map((p) => p.name), ['Radio']);
  });

  test('a layby is open money until collected, then counts as a sale on the day of hand-over', () async {
    await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name) values ('mai', 's', 1, 1, 1, 'Mai')");
    now = d1;
    final l = await engineAt().sell(Cart(branchId: 'branch', saleCurrency: 'USD', customerId: 'mai', layby: true, lines: const [CartLine(productId: 'radio', qtyMilli: 1000)], payments: [cash('USD', 1000)]));
    var s = await rep.salesSummary(dayRange(0));
    expect([s.sales, s.revenueMinor], [0, 0]);
    expect([s.openLayby.single.count, s.openLayby.single.valueMinor, s.openLayby.single.paidMinor], [1, 4000, 1000]);
    now = d1 + day;
    await customers().payLayby(saleId: l.saleId, payment: cash('USD', 3000));
    now = d1 + day + 5;
    await customers().collectLayby(l.saleId);
    s = await rep.salesSummary(dayRange(1));
    expect([s.sales, s.revenueMinor, s.openLayby.length], [1, 4000, 0]);
    expect((await rep.salesSummary(dayRange(0))).sales, 0);
  });

  test('daily sales use the shop clock, fill empty days, and split at local midnight', () async {
    await sale(DateTime.utc(2026, 11, 2, 21, 30).millisecondsSinceEpoch, [('bread', 2000)], [cash('USD', 300)]);
    await sale(DateTime.utc(2026, 11, 2, 22, 30).millisecondsSinceEpoch, [('bread', 1000)], [cash('USD', 150)]);
    final rows = await rep.dailySales(DateRange(localMidnight, localMidnight + 4 * day), 120);
    expect(rows.map((r) => [r.day, r.sales, r.revenueMinor]), [['2026-11-02', 1, 300], ['2026-11-03', 1, 150], ['2026-11-04', 0, 0], ['2026-11-05', 0, 0]]);
    expect(dayOf(DateTime.utc(2026, 11, 2, 22, 30).millisecondsSinceEpoch, 120), '2026-11-03');
  });

  test('best sellers are net of returns and can be ranked by quantity, revenue or profit', () async {
    final a = await sale(d1, [('bread', 10000)], [cash('USD', 1500)]);
    await sale(d1 + 1, [('radio', 1000)], [cash('USD', 4000)]);
    final l = (await returns().returnableLines(a.saleId)).single;
    now = d1 + 2;
    await returns().processReturn(saleId: a.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 4000)], reason: 'x', payouts: [pcash(600)]);
    expect((await rep.topProducts(dayRange(0), by: 'qty')).map((p) => [p.name, p.qtyMilli]), [['Bread', 6000], ['Radio', 1000]]);
    final byRev = await rep.topProducts(dayRange(0));
    expect(byRev.map((p) => [p.name, p.revenueMinor]), [['Radio', 4000], ['Bread', 900]]);
    expect([byRev.first.costMinor, byRev.first.profitMinor], [2500, 1500]);
    expect((await rep.topProducts(dayRange(0), limit: 1)).length, 1);
    expect((await rep.topProducts(dayRange(0), by: 'profit')).first.name, 'Radio');
  });

  test('takings by method: sales less change, account payments, and refunds', () async {
    await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name, credit_limit_minor, credit_currency) values ('mai', 's', 1, 1, 1, 'Mai', 10000, 'USD')");
    final a = await sale(d1, [('bread', 2000)], [cash('USD', 500)]);
    await sale(d1 + 1, [('bread', 2000)], [const CartPayment(methodCode: 'ecocash', currency: 'USD', amountMinor: 300, reference: 'MP1')]);
    await sale(d1 + 2, [('bread', 2000)], [cash('USD', 100)], customerId: 'mai', onCredit: true);
    now = d1 + 3;
    await customers().receiveAccountPayment(customerId: 'mai', debtCurrency: 'USD', payment: cash('USD', 150));
    final l = (await returns().returnableLines(a.saleId)).single;
    now = d1 + 4;
    await returns().processReturn(saleId: a.saleId, items: [ReturnItem(saleLineId: l.saleLineId, qtyMilli: 1000)], reason: 'x', payouts: [pcash(150)]);
    final t = await rep.takings(dayRange(0));
    final c = t.firstWhere((x) => x.method == 'Cash');
    expect([c.receivedMinor, c.paidBackMinor, c.netMinor], [750, 350, 400]);
    final e = t.firstWhere((x) => x.method == 'EcoCash');
    expect([e.receivedMinor, e.paidBackMinor, e.netMinor], [300, 0, 300]);
    expect(await rep.takings(dayRange(1)), isEmpty);
  });

  test('stock value, out-of-stock items and expiring batches', () async {
    expect((await rep.stockValue()).totalMinor, 50 * 90 + 5 * 2500);
    expect((await rep.stockValue()).products, 2);
    expect((await rep.stockValue()).rows.first.name, 'Radio');
    expect(await rep.outOfStock(), isEmpty);
    await db.exec("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, type, qty_milli) values ('m-out', 's', 1, 'branch', 'radio', 'loss', -5000)");
    expect((await rep.outOfStock()).map((x) => x.name), ['Radio']);
    expect((await rep.stockValue()).totalMinor, 50 * 90);
    await db.exec("insert into stock_batches (id, shop_id, created_at, updated_at, version, product_id, branch_id, batch_code, expiry_date, received_at) values ('b1', 's', 1, 1, 1, 'bread', 'branch', 'L1', '2026-11-05', 1)");
    await db.exec("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, batch_id, type, qty_milli) values ('m-b1', 's', 1, 'branch', 'bread', 'b1', 'purchase', 3000)");
    final exp = await rep.expiringBatches('2026-11-02', 7);
    expect(exp.map((e) => [e.name, e.batchCode, e.qtyMilli, e.expired]), [['Bread', 'L1', 3000, false]]);
    expect(await rep.expiringBatches('2026-11-02', 1), isEmpty);
    expect((await rep.expiringBatches('2026-11-10', 1)).first.expired, isTrue);
  });

  test('receivables list who owes what, and cash-ups list closed shifts with their differences', () async {
    for (final c in [('c1', 'Mai', '0772'), ('c2', 'Baba', null)]) {
      await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name, phone, credit_limit_minor, credit_currency) values (?, 's', 1, 1, 1, ?, ?, 10000, 'USD')", [c.$1, c.$2, c.$3]);
    }
    await sale(d1, [('bread', 2000)], [], customerId: 'c1', onCredit: true);
    await sale(d1, [('bread', 4000)], [], customerId: 'c2', onCredit: true);
    final r = await rep.receivables();
    expect(r.byCurrency.map((t) => [t.currency, t.owedMinor, t.customers]), [['USD', 900, 2]]);
    expect(r.debtors.map((d) => [d.name, d.owedMinor]), [['Baba', 600], ['Mai', 300]]);

    now = d1;
    final id = await shifts().openShift(branchId: 'branch', float: {'USD': 1000});
    now = d1 + 1000;
    await shifts().closeShift(id, {'USD': 900, 'ZiG': 0});
    final cu = await rep.cashUps(dayRange(0));
    expect(cu.length, 1);
    final usd = cu.single.currencies.firstWhere((c) => c.currency == 'USD');
    expect([usd.expectedMinor, usd.countedMinor, usd.differenceMinor], [1000, 900, -100]);
    expect(await rep.cashUps(dayRange(1)), isEmpty);
  });

  test('items sold with no cost are counted, not guessed', () async {
    await put('products', {'id': 'free', 'name': 'Mystery', 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 0, 'kind': 'simple'});
    await put('product_prices', {'product_id': 'free', 'currency': 'USD', 'price_minor': 100, 'effective_from': d1 - 9000});
    await sale(d1, [('free', 2000)], [cash('USD', 200)]);
    final s = await rep.salesSummary(dayRange(0));
    expect([s.linesWithoutCost, s.costMinor, s.revenueMinor], [1, 0, 200]);
  });
}
