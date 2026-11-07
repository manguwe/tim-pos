import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/customers/customer_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
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

  ShiftRepository shifts([String? user]) => ShiftRepository(db: db, shopId: 's', deviceId: 'd', userId: user, clock: () => now);
  CustomerRepository customers([String? user]) => CustomerRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: user, clock: () => now);

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
    await put('products', {'id': 'bread', 'name': 'Bread', 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple'});
    await put('product_prices', {'product_id': 'bread', 'currency': 'USD', 'price_minor': 150, 'effective_from': t0 - 9000});
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'bread', 'type': 'purchase', 'qty_milli': 100000}, versioned: false);
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create","shift.manage"]'});
    await put('roles', {'id': 'r-own', 'name': 'Owner', 'permissions': '["sale.create","shift.manage","report.view"]'});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-other', 'name': 'Tapiwa', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-own', 'name': 'Tim', 'role_id': 'r-own', 'pin_hash': 'x', 'is_active': 1});
    engine = SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now);
  });

  Future<SaleResult> sale(String? shiftId, List<CartPayment> pay, {int qty = 2000, String? customerId, bool onCredit = false}) => engine.sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', shiftId: shiftId, customerId: customerId, onCredit: onCredit,
        lines: [CartLine(productId: 'bread', qtyMilli: qty)], payments: pay,
      ));
  CartPayment cash(String cur, int a) => CartPayment(methodCode: 'cash', currency: cur, amountMinor: a);
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));

  test('a shift opens once per cashier with a float per currency', () async {
    final s = shifts('u-cash');
    expect(await s.current(), isNull);
    final id = await s.openShift(branchId: 'branch', float: {'USD': 2000, 'ZiG': 50000});
    expect((await s.current())!.id, id);
    expect(await s.expectedCash(id), {'USD': 2000, 'ZiG': 50000});
    await expectLater(s.openShift(branchId: 'branch', float: {}), failsWith('shift_open'));
    expect((await db.query('select count(*) as c from shift_cash')).single['c'], 2);
    expect(await shifts('u-other').current(), isNull);
  });

  test('opening needs real branches and sensible floats', () async {
    final s = shifts('u-cash');
    await expectLater(s.openShift(branchId: 'nope', float: {}), failsWith('unknown_branch'));
    await expectLater(s.openShift(branchId: 'branch', float: {'GBP': 5}), failsWith('unknown_currency'));
    await expectLater(s.openShift(branchId: 'branch', float: {'USD': -5}), failsWith('bad_amount'));
  });

  test('cash-up: float, cash sales, change, mobile money, account payments and cash events all add up', () async {
    final s = shifts('u-cash');
    final id = await s.openShift(branchId: 'branch', float: {'USD': 2000, 'ZiG': 0});
    await sale(id, [cash('USD', 500)]);
    await sale(id, [const CartPayment(methodCode: 'ecocash', currency: 'USD', amountMinor: 300, reference: 'MP1')]);
    await sale(id, [cash('ZiG', 8000)]);
    expect(await s.expectedCash(id), {'USD': 2000 + 500 - 200, 'ZiG': 8000});

    await db.exec("insert into customers (id, shop_id, created_at, updated_at, version, name, credit_limit_minor, credit_currency) values ('mai', 's', 1, 1, 1, 'Mai', 10000, 'USD')");
    await sale(id, [cash('USD', 100)], customerId: 'mai', onCredit: true);
    now = t0 + 5000;
    await customers('u-cash').receiveAccountPayment(customerId: 'mai', debtCurrency: 'USD', payment: cash('USD', 100));
    expect((await s.expectedCash(id))['USD'], 2000 + 500 - 200 + 100 + 100);

    now = t0 + 6000;
    await s.addCashEvent(shiftId: id, currency: 'USD', type: 'cash_out', amountMinor: 150, reason: 'Bought airtime');
    await s.addCashEvent(shiftId: id, currency: 'USD', type: 'cash_in', amountMinor: 1000, reason: 'Owner top-up');
    await s.addCashEvent(shiftId: id, currency: 'USD', type: 'bank_drop', amountMinor: 500);
    const expectedUsd = 2000 + 500 - 200 + 100 + 100 - 150 + 1000 - 500;
    expect((await s.expectedCash(id))['USD'], expectedUsd);

    final live = await s.report(id);
    expect(live.sales, 4);
    expect(live.takings.where((t) => t.method == 'EcoCash').single.amountMinor, 300);
    expect(live.events.length, 3);

    now = t0 + 9000;
    final rep = await s.closeShift(id, {'USD': expectedUsd - 100, 'ZiG': 8000});
    expect(rep.status, 'closed');
    expect(rep.expected, {'USD': expectedUsd, 'ZiG': 8000});
    expect(rep.difference, {'USD': -100, 'ZiG': 0});
    expect(await s.current(), isNull);
    expect((await db.query('select closed_at from shifts')).single['closed_at'], t0 + 9000);

    now = t0 + 20000;
    await customers('u-cash').receiveAccountPayment(customerId: 'mai', debtCurrency: 'USD', payment: cash('USD', 100));
    expect((await s.report(id)).expected, {'USD': expectedUsd, 'ZiG': 8000});
    expect((await s.expectedCash(id))['USD'], expectedUsd);
  });

  test('cash events are checked', () async {
    final s = shifts('u-cash');
    final id = await s.openShift(branchId: 'branch', float: {'USD': 1000});
    Future<String> ev({String cur = 'USD', String type = 'cash_out', int amount = 100, String? reason = 'x', String? shift}) =>
        s.addCashEvent(shiftId: shift ?? id, currency: cur, type: type, amountMinor: amount, reason: reason);
    await expectLater(ev(reason: '  '), failsWith('reason_needed'));
    await expectLater(ev(amount: 0), failsWith('bad_amount'));
    await expectLater(ev(amount: 1001), failsWith('not_enough_cash'));
    await expectLater(ev(cur: 'GBP'), failsWith('unknown_currency'));
    await expectLater(ev(type: 'steal'), failsWith('bad_type'));
    await expectLater(ev(shift: 'nope'), failsWith('shift_closed'));
    await ev(amount: 1000);
  });

  test('closing needs a count for every currency, works once, and only the cashier or a manager may close', () async {
    final s = shifts('u-cash');
    final id = await s.openShift(branchId: 'branch', float: {'USD': 1000});
    await expectLater(s.closeShift(id, {'USD': 1000}), failsWith('count_needed'));
    await expectLater(s.closeShift(id, {'USD': -1, 'ZiG': 0}), failsWith('count_needed'));
    await expectLater(s.closeShift(id, {'USD': 1, 'ZiG': 0, 'GBP': 1}), failsWith('unknown_currency'));
    await s.closeShift(id, {'USD': 1000, 'ZiG': 0});
    await expectLater(s.closeShift(id, {'USD': 1000, 'ZiG': 0}), failsWith('shift_closed'));

    final id2 = await s.openShift(branchId: 'branch', float: {});
    await expectLater(shifts('u-other').closeShift(id2, {'USD': 0, 'ZiG': 0}), failsWith('forbidden'));
    await shifts('u-own').closeShift(id2, {'USD': 0, 'ZiG': 0});
  });

  test('the shop can insist on an open shift before selling', () async {
    final s = shifts('u-cash');
    final id = await s.openShift(branchId: 'branch', float: {});
    await db.exec("insert into settings (id, shop_id, created_at, updated_at, version, scope, key, value) values ('set-sh', 's', 1, 1, 1, 'shop', 'require_shift', '1')");
    await expectLater(sale(null, [cash('USD', 300)]), throwsA(isA<SaleError>().having((e) => e.code, 'code', 'shift_needed')));
    expect((await sale(id, [cash('USD', 300)])).status, 'completed');
    now = t0 + 10;
    await s.closeShift(id, {'USD': 300, 'ZiG': 0});
    await expectLater(sale(id, [cash('USD', 300)]), throwsA(isA<SaleError>().having((e) => e.code, 'code', 'shift_closed')));
  });
}
