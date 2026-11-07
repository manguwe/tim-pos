import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/selling.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

/// The full set of selling rules is tested against the real schema in tools/test/selling.test.ts. These tests prove
/// the Dart port gives the same answers on the cases that matter most.
void main() {
  late SqlDb db;
  late SellingEngine engine;
  var n = 0;

  Future<void> put(String table, Map<String, Object?> row, {bool versioned = true}) async {
    final o = <String, Object?>{
      'id': 'seed-${(++n).toString().padLeft(6, '0')}',
      'shop_id': 'shop-0001',
      'created_at': t0 - 1000,
      if (versioned) ...{'updated_at': t0 - 1000, 'version': 1},
      ...row,
    };
    final keys = o.keys.toList();
    await db.exec('insert into "$table" (${keys.map((k) => '"$k"').join(',')}) values (${List.filled(keys.length, '?').join(',')})', keys.map((k) => o[k]).toList());
  }

  setUp(() async {
    db = await openTestDb();
    n = 0;
    engine = SellingEngine(db: db, context: const SaleContext(shopId: 'shop-0001', deviceId: 'dev-00001', receiptPrefix: 'D1'), clock: () => t0, idMaker: () => 'gen-${(++n).toString().padLeft(8, '0')}');
    await put('shops', {'name': 'Test', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5});
    await put('currencies', {'code': 'ZiG', 'name': 'Zimbabwe Gold', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': t0 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('tax_classes', {'id': 'vat', 'name': 'VAT', 'rate_bp': 1500, 'is_inclusive': 1});
    await put('price_tiers', {'id': 'retail', 'name': 'Retail', 'is_default': 1});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('products', {'id': 'bread', 'name': 'Bread', 'base_unit_id': 'pcs', 'tax_class_id': 'vat', 'is_active': 1, 'track_stock': 1, 'cost_minor': 60, 'kind': 'simple'});
    await put('product_prices', {'product_id': 'bread', 'tier_id': 'retail', 'currency': 'USD', 'price_minor': 150, 'effective_from': t0 - 9000});
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'bread', 'type': 'purchase', 'qty_milli': 10000}, versioned: false);
  });

  Cart cart({List<CartPayment>? pay, int qty = 1000, String? changeIn, String cur = 'USD'}) => Cart(
        branchId: 'branch', saleCurrency: cur, changeCurrency: changeIn,
        lines: [CartLine(productId: 'bread', qtyMilli: qty)],
        payments: pay ?? [const CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 150)],
      );

  Future<int> count(String table) async => (await db.query('select count(*) c from "$table"')).single['c'] as int;

  test('a cash sale writes the sale, line, payment and stock movement, and takes stock off', () async {
    final r = await engine.sell(cart());
    expect(r.receiptNo, 'D1-000001');
    expect(r.totalMinor, 150);
    expect(r.taxMinor, 20); // 1.50 incl 15% -> net 1.30, tax 0.20
    expect(r.opensDrawer, isTrue);
    expect(await count('sales'), 1);
    expect(await count('sale_lines'), 1);
    expect(await count('sale_payments'), 1);
    expect((await db.query('select qty_milli from stock_levels')).single['qty_milli'], 9000);
    expect((await db.query("select count(*) c from change_log where table_name = 'sales'")).single['c'], 1);
  });

  test('change in ZiG is rounded down to the coin, and the rate is remembered', () async {
    final r = await engine.sell(cart(pay: const [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 1000)], changeIn: 'ZiG'));
    expect(r.change?.currency, 'ZiG');
    expect(r.change?.amountMinor, 22500); // 8.50 USD = 225.25 ZiG, given as 225.00
  });

  test('a sale with not enough stock is refused and leaves nothing behind', () async {
    await expectLater(engine.sell(cart(qty: 11000, pay: const [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 2000)])),
        throwsA(isA<SaleError>().having((e) => e.code, 'code', 'insufficient_stock')));
    expect(await count('sales'), 0);
    expect(await count('receipt_counters'), 0);
    expect((await db.query('select qty_milli from stock_levels')).single['qty_milli'], 10000);
  });

  test('receipt numbers count up on this phone', () async {
    final a = await engine.sell(cart());
    final b = await engine.sell(cart());
    expect([a.receiptNo, b.receiptNo], ['D1-000001', 'D1-000002']);
  });

  test('underpaying without an account is refused; ZiG price is converted from USD', () async {
    await expectLater(engine.sell(cart(pay: const [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 100)])),
        throwsA(isA<SaleError>().having((e) => e.code, 'code', 'underpaid')));
    final z = await engine.sell(cart(cur: 'ZiG', pay: const [CartPayment(methodCode: 'cash', currency: 'ZiG', amountMinor: 3975)]));
    expect(z.totalMinor, 3975); // 1.50 x 26.5
  });
}
