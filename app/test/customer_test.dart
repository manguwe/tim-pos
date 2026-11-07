import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/customers/customer_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
  late CustomerRepository repo;
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
    await put('products', {'id': 'radio', 'name': 'Radio', 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple'});
    await put('product_prices', {'product_id': 'radio', 'currency': 'USD', 'price_minor': 4000, 'effective_from': t0 - 9000});
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'radio', 'type': 'purchase', 'qty_milli': 5000}, versioned: false);
    engine = SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now);
    repo = CustomerRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', clock: () => now);
  });

  Future<SaleResult> sale({String? customerId, bool onCredit = false, bool layby = false, List<CartPayment> pay = const []}) =>
      engine.sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', customerId: customerId, onCredit: onCredit, layby: layby,
        lines: const [CartLine(productId: 'radio', qtyMilli: 1000)], payments: pay,
      ));
  const usd = 'USD';
  CartPayment cash(String cur, int a) => CartPayment(methodCode: 'cash', currency: cur, amountMinor: a);
  Future<String> customer([String name = 'Mai Tendai']) => repo.saveCustomer(CustomerInput(name: name, creditLimitMinor: 10000, creditCurrency: usd));
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));

  test('customers are saved and found, and a phone number is not used twice', () async {
    final a = await repo.saveCustomer(const CustomerInput(name: ' Mai Tendai ', phone: '0772 111 222', creditLimitMinor: 10000, creditCurrency: usd));
    await repo.saveCustomer(const CustomerInput(name: 'Baba Rudo', phone: '0773 000 111'));
    await expectLater(repo.saveCustomer(const CustomerInput(name: 'Other', phone: '0772 111 222')), failsWith('duplicate_phone'));
    await expectLater(repo.saveCustomer(const CustomerInput(name: ' ')), failsWith('missing'));
    await expectLater(repo.saveCustomer(const CustomerInput(name: 'X', creditLimitMinor: -1)), failsWith('bad_limit'));
    await repo.saveCustomer(CustomerInput(id: a, name: 'Mai Tendai', phone: '0772 111 222', creditLimitMinor: 20000, creditCurrency: usd));
    final all = await repo.listCustomers();
    expect(all[1].creditLimitMinor, 20000);
    expect((await repo.listCustomers(search: '0773')).map((c) => c.name), ['Baba Rudo']);
    expect(await repo.listCustomers(search: '%'), isEmpty);
  });

  test('credit stays in the agreed currency; paying in ZiG converts at today\'s rate', () async {
    final c = await customer();
    final r = await sale(customerId: c, onCredit: true, pay: [cash(usd, 1000)]);
    expect(r.creditMinor, 3000);
    expect(await repo.owedBy(c), [const Owed(usd, 3000)]);

    await db.exec("insert into exchange_rates (id, shop_id, created_at, from_currency, to_currency, rate_micro, effective_from) values ('r2', 's', ?, 'USD', 'ZiG', 30000000, ?)", [t0 + 5000, t0 + 5000]);
    now = t0 + 6000;
    final p = await repo.receiveAccountPayment(customerId: c, debtCurrency: usd, payment: cash('ZiG', 30000));
    expect(p.appliedMinor, 1000);
    expect(p.balanceAfterMinor, 2000);
    expect(p.receiptNo, 'D1-P000001');
    expect(p.opensDrawer, isTrue);
    final row = (await db.query('select * from account_payments')).single;
    expect([row['currency'], row['amount_minor'], row['target_currency'], row['applied_minor'], row['rate_to_target_micro']], ['ZiG', 30000, usd, 1000, 33333]);

    final s = await repo.statement(c);
    expect(s.map((l) => [l.type, l.amountMinor, l.balanceMinor]), [['credit_sale', 3000, 3000], ['payment', -1000, 2000]]);
    expect(s[0].ref, r.receiptNo);
    expect(s[1].ref, p.receiptNo);
  });

  test('paying too much is refused, a rounding sliver is allowed, and mobile money needs a reference', () async {
    final c = await customer('Mai');
    await sale(customerId: c, onCredit: true, pay: [cash(usd, 3900)]);
    Future<PaymentResult> pay({String method = 'cash', String cur = usd, int amount = 100}) =>
        repo.receiveAccountPayment(customerId: c, debtCurrency: usd, payment: PaymentInput(methodCode: method, currency: cur, amountMinor: amount));
    await expectLater(pay(amount: 110), failsWith('overpaid'));
    await expectLater(pay(method: 'ecocash'), failsWith('reference_needed'));
    await expectLater(pay(method: 'nope'), failsWith('unknown_method'));
    await expectLater(pay(amount: 0), failsWith('bad_payment'));
    await expectLater(pay(cur: 'GBP'), failsWith('unknown_currency'));
    final r = await pay(cur: 'ZiG', amount: 2700);
    expect(r.appliedMinor, 100);
    expect(r.balanceAfterMinor, 0);
    await expectLater(pay(), failsWith('nothing_owed'));
    expect(await repo.listCustomers(onlyOwing: true), isEmpty);
  });

  test('a failed payment leaves no trace', () async {
    final c = await customer('Mai');
    await sale(customerId: c, onCredit: true, pay: [cash(usd, 3000)]);
    await expectLater(repo.receiveAccountPayment(customerId: c, debtCurrency: usd, payment: const PaymentInput(methodCode: 'cash', currency: usd, amountMinor: 5000)), failsWith('overpaid'));
    expect(await db.query('select * from account_payments'), isEmpty);
    expect(await db.query("select * from receipt_counters where kind = 'payment'"), isEmpty);
  });

  test('a layby holds the goods, takes a deposit, and is collected only when paid up', () async {
    final c = await customer('Mai');
    Future<void> bad(Future<SaleResult> f, String code) => expectLater(f, throwsA(isA<SaleError>().having((e) => e.code, 'code', code)));
    await bad(sale(layby: true, pay: [cash(usd, 1000)]), 'customer_needed');
    await bad(sale(layby: true, customerId: c), 'deposit_needed');
    await bad(sale(layby: true, onCredit: true, customerId: c, pay: [cash(usd, 1000)]), 'layby_or_credit');

    final r = await sale(layby: true, customerId: c, pay: [cash(usd, 1000)]);
    expect(r.status, 'layby');
    expect(r.laybyBalanceMinor, 3000);
    expect(r.creditMinor, 0);
    expect((await db.query("select sum(qty_milli) as q from stock_movements where product_id = 'radio'")).single['q'], 4000);
    expect(await repo.owedBy(c), isEmpty);

    var l = (await repo.laybys(openOnly: true)).single;
    expect([l.totalMinor, l.paidMinor, l.balanceMinor, l.collected], [4000, 1000, 3000, false]);
    await expectLater(repo.collectLayby(r.saleId), failsWith('balance_due'));

    final i1 = await repo.payLayby(saleId: r.saleId, payment: cash('ZiG', 26500));
    expect(i1.appliedMinor, 1000);
    expect(i1.balanceAfterMinor, 2000);
    await expectLater(repo.payLayby(saleId: r.saleId, payment: cash(usd, 2500)), failsWith('overpaid'));
    final i2 = await repo.payLayby(saleId: r.saleId, payment: cash(usd, 2000));
    expect(i2.balanceAfterMinor, 0);
    await expectLater(repo.payLayby(saleId: r.saleId, payment: cash(usd, 100)), failsWith('nothing_owed'));

    l = (await repo.laybys(customerId: c)).single;
    expect(l.balanceMinor, 0);
    await repo.collectLayby(r.saleId);
    await expectLater(repo.collectLayby(r.saleId), failsWith('already_collected'));
    expect(await repo.laybys(openOnly: true), isEmpty);
    expect((await repo.laybys()).length, 1);
    await expectLater(repo.payLayby(saleId: r.saleId, payment: cash(usd, 100)), failsWith('already_collected'));
    await expectLater(repo.payLayby(saleId: 'nope', payment: cash(usd, 100)), failsWith('not_layby'));
    expect((await db.query('select receipt_no from account_payments order by rowid')).map((x) => x['receipt_no']), ['D1-P000001', 'D1-P000002']);
  });

  test('a minimum deposit can be required, and a fully paid layby is just a sale', () async {
    final c = await customer('Mai');
    await db.exec("insert into settings (id, shop_id, created_at, updated_at, version, scope, key, value) values ('set-lay', 's', 1, 1, 1, 'shop', 'layby_min_deposit_pct', '25')");
    await expectLater(sale(layby: true, customerId: c, pay: [cash(usd, 900)]), throwsA(isA<SaleError>().having((e) => e.code, 'code', 'deposit_too_small')));
    expect((await sale(layby: true, customerId: c, pay: [cash(usd, 1000)])).status, 'layby');
    expect((await sale(layby: true, pay: [cash(usd, 4000)])).status, 'completed');
  });
}
