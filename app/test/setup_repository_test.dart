import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/cart_controller.dart';
import 'package:tim_pos/selling/catalog.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/setup/setup_repository.dart';
import 'package:tim_pos/ui/setup_screens.dart' show parseQty;

import 'support/ffi_db.dart';

const t0 = 1800000000000;

/// Full rules are tested against the real schema in tools/test/setup.test.ts; these prove the Dart port agrees.
void main() {
  late SqlDb db;
  late SetupRepository repo;
  var n = 0;
  var now = t0;

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0;
    repo = SetupRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => now, idMaker: () => 'gen-${(++n).toString().padLeft(8, '0')}');
  });

  Future<List<Map<String, Object?>>> q(String sql, [List<Object?> a = const []]) => db.query(sql, a);
  Future<String> branch() async => (await q('select id from branches')).single['id'] as String;
  Future<String> vat() async => (await q("select id from tax_classes where name = 'Standard rated'")).single['id'] as String;

  test('set-up creates everything once, and queues it to sync', () async {
    expect(await repo.isSetUp(), isFalse);
    expect((await repo.seedShop(name: ' Mbare Mini Market ', countryCode: 'zw')).created, isTrue);
    expect((await q('select id, name, base_currency from shops')).single, {'id': 'shop-0001', 'name': 'Mbare Mini Market', 'base_currency': 'USD'});
    expect((await q('select code from currencies order by code')).map((r) => r['code']), ['USD', 'ZiG']);
    expect((await q('select code from payment_methods order by code')).map((r) => r['code']), ['bank_transfer', 'card', 'cash', 'ecocash', 'innbucks', 'onemoney']);
    final logged = (await q('select count(*) c from change_log')).single['c'] as int;
    expect(logged, greaterThan(20));
    expect((await repo.seedShop(name: 'Other', countryCode: 'ZM')).created, isFalse);
    expect((await q('select count(*) c from change_log')).single['c'], logged);
  });

  test('bad input is refused and leaves nothing behind', () async {
    await expectLater(repo.seedShop(name: ' ', countryCode: 'ZW'), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'missing')));
    await expectLater(repo.seedShop(name: 'X', countryCode: 'XX'), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'unknown_country')));
    expect((await q('select count(*) c from shops')).single['c'], 0);
  });

  test('exchange rates are added and never overwritten', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    await repo.setExchangeRate('USD', 'ZiG', 26500000);
    now += 1000;
    await repo.setExchangeRate('USD', 'ZiG', 27000000);
    expect((await q('select rate_micro from exchange_rates order by effective_from')).map((r) => r['rate_micro']), [26500000, 27000000]);
    await expectLater(repo.setExchangeRate('USD', 'USD', 1000000), throwsA(isA<SetupError>()));
    await expectLater(repo.setExchangeRate('USD', 'EUR', 900000), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'unknown_currency')));
  });

  test('products: price history kept, version rises, barcode belongs to one product', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    final id = await repo.saveProduct(ProductInput(name: 'Bread', barcode: '6001234', priceMinor: 150, costMinor: 90, taxClassId: await vat()));
    now += 5000;
    await repo.saveProduct(ProductInput(id: id, name: 'Bread', barcode: '6001234', priceMinor: 150, costMinor: 90, taxClassId: await vat()));
    expect((await q('select count(*) c from product_prices')).single['c'], 1, reason: 'same price: no new row');
    now += 5000;
    await repo.saveProduct(ProductInput(id: id, name: 'Brown bread', priceMinor: 175));
    expect((await q('select price_minor from product_prices order by effective_from')).map((r) => r['price_minor']), [150, 175]);
    expect((await q('select version from products')).single['version'], 3);
    expect((await q('select count(*) c from product_barcodes')).single['c'], 1);
    await expectLater(repo.saveProduct(const ProductInput(name: 'Milk', barcode: '6001234', priceMinor: 100)), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'barcode_taken')));
    expect((await q('select count(*) c from products')).single['c'], 1);
  });

  test('receiving stock keeps a weighted-average cost', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    final id = await repo.saveProduct(const ProductInput(name: 'Rice', priceMinor: 300, costMinor: 100));
    final b = await branch();
    await repo.receiveStock(branchId: b, productId: id, qtyMilli: 10000, unitCostMinor: 100, opening: true);
    await repo.receiveStock(branchId: b, productId: id, qtyMilli: 10000, unitCostMinor: 120);
    expect((await q('select cost_minor from products')).single['cost_minor'], 110);
    await repo.receiveStock(branchId: b, productId: id, qtyMilli: 20000, unitCostMinor: 130);
    expect((await q('select cost_minor from products')).single['cost_minor'], 120);
    expect((await q('select qty_milli from stock_levels')).single['qty_milli'], 40000);
  });

  test('end to end: a freshly set-up shop can sell in USD and ZiG', () async {
    await repo.seedShop(name: 'Mbare Mini Market', countryCode: 'ZW');
    await repo.setExchangeRate('USD', 'ZiG', 26500000);
    final bread = await repo.saveProduct(ProductInput(name: 'Bread', barcode: '6001', priceMinor: 150, costMinor: 90, taxClassId: await vat()));
    await repo.receiveStock(branchId: await branch(), productId: bread, qtyMilli: 10000, unitCostMinor: 90, opening: true);

    final catalog = CatalogRepository(db, clock: () => now);
    final setup = (await catalog.setup())!;
    expect(setup.baseCurrency, 'USD');
    final engine = SellingEngine(db: db, context: const SaleContext(shopId: 'shop-0001', deviceId: 'dev-00001', receiptPrefix: 'D1'), clock: () => now + 60000);
    final cart = CartController(engine: engine, catalog: catalog, setup: setup);
    now += 60000;
    cart.add((await catalog.byBarcode('6001', branchId: setup.branchId, currency: 'USD'))!, qtyMilli: 2000);
    cart.addPayment(const CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 500), creditedInSaleCurrency: 500);
    expect(await cart.checkout(), isTrue);
    expect(cart.lastSale?.totalMinor, 300);
    expect(cart.lastSale?.taxMinor, 39);
    expect(cart.lastSale?.change?.amountMinor, 200);
    expect((await q('select qty_milli from stock_levels')).single['qty_milli'], 8000);
  });

  test('typed quantities become thousandths without floating point', () {
    expect(parseQty('2'), 2000);
    expect(parseQty('1.5'), 1500);
    expect(parseQty('0,25'), 250);
    expect(parseQty('1.2345'), isNull);
    expect(parseQty('abc'), isNull);
  });
}
