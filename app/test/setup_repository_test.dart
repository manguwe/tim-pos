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

  test('departments are added, renamed and removed, and products can belong to one', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    final groceries = await repo.saveCategory(name: ' Groceries ');
    await repo.saveCategory(name: 'Accessories');
    await expectLater(repo.saveCategory(name: 'groceries'), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'duplicate_department')));
    await expectLater(repo.saveCategory(name: '  '), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'missing')));
    await repo.saveCategory(id: groceries, name: 'Food and groceries');
    expect((await repo.listCategories()).map((r) => r['name']), ['Food and groceries', 'Accessories']);

    final rice = await repo.saveProduct(ProductInput(name: 'Rice 5kg', priceMinor: 650, categoryId: groceries));
    final cable = await repo.saveProduct(const ProductInput(name: 'Phone cable', priceMinor: 300));
    expect((await repo.listProducts('', categoryId: groceries)).map((r) => r['name']), ['Rice 5kg']);
    expect((await repo.listProducts('', categoryId: noDepartment)).map((r) => r['name']), ['Phone cable']);
    expect((await repo.listProducts('')).length, 2);
    // Saving again without naming a department leaves it as it was.
    await repo.saveProduct(ProductInput(id: rice, name: 'Rice 5kg', priceMinor: 650));
    expect((await repo.listProducts('', categoryId: groceries)).length, 1);
    await repo.saveProduct(ProductInput(id: cable, name: 'Phone cable', priceMinor: 300, categoryId: (await repo.listCategories()).last['id'] as String));
    expect((await repo.listCategories()).last['products'], 1);

    await repo.deleteCategory(groceries);
    expect((await repo.listCategories()).map((r) => r['name']), ['Accessories']);
    expect((await repo.listProducts('', categoryId: noDepartment)).map((r) => r['name']), ['Rice 5kg']);
  });

  test('the common departments can be added twice without repeats', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    final first = await repo.addSuggestedCategories();
    expect(first, suggestedDepartments.length);
    expect(await repo.addSuggestedCategories(), 0);
    expect((await repo.listCategories()).length, suggestedDepartments.length);
  });

  test('a Zambian shop can choose dollars as its main currency, add a currency, and list the latest rates', () async {
    await repo.seedShop(name: 'Lusaka Store', countryCode: 'ZM', baseCurrency: 'USD');
    expect((await q('select base_currency from shops')).single['base_currency'], 'USD');
    expect((await repo.shopCurrencies()).map((c) => c['code']), ['USD', 'ZMW']);
    await repo.addCurrency('ZAR');
    await repo.addCurrency('ZAR'); // twice is fine
    expect((await repo.shopCurrencies()).map((c) => c['code']), ['USD', 'ZAR', 'ZMW']);
    await expectLater(repo.addCurrency('XXX'), throwsA(isA<SetupError>()));
    await repo.setExchangeRate('USD', 'ZMW', 27000000);
    now += 1000;
    await repo.setExchangeRate('USD', 'ZMW', 27500000);
    final latest = await repo.latestRates();
    expect(latest.single['rate_micro'], 27500000);
    final fresh = await openTestDb();
    final r2 = SetupRepository(db: fresh, shopId: 's', deviceId: 'd');
    await expectLater(r2.seedShop(name: 'X', countryCode: 'ZW', baseCurrency: 'ZMW'), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'bad_currency')));
  });

  test('quantity prices are saved as a set, and a pack price becomes a unit cost', () async {
    await repo.seedShop(name: 'A', countryCode: 'ZW');
    final id = await repo.saveProduct(const ProductInput(name: 'T-shirt', priceMinor: 500, costMinor: 300));
    await repo.saveBreaks(id, [(minQtyMilli: 10000, priceMinor: 350), (minQtyMilli: 3000, priceMinor: 400)]);
    expect((await repo.listBreaks(id)).map((b) => (b.minQtyMilli, b.priceMinor)), [(3000, 400), (10000, 350)]);
    await repo.saveBreaks(id, [(minQtyMilli: 2000, priceMinor: 450)]);
    expect((await repo.listBreaks(id)).map((b) => b.priceMinor), [450]);
    expect((await q('select count(*) c from price_breaks where deleted_at is null')).single['c'], 1);
    await expectLater(repo.saveBreaks(id, [(minQtyMilli: 1000, priceMinor: 100)]), throwsA(isA<SetupError>()));
    await expectLater(repo.saveBreaks(id, [(minQtyMilli: 2000, priceMinor: 1), (minQtyMilli: 2000, priceMinor: 2)]), throwsA(isA<SetupError>()));
    await repo.saveBreaks(id, []);
    expect(await repo.listBreaks(id), isEmpty);
    expect(unitCostFromPack(3600, 12000), 300);
    expect(unitCostFromPack(1000, 3000), 333);
    expect(unitCostFromPack(1000, 12000), 83);
    expect(() => unitCostFromPack(1000, 0), throwsA(isA<SetupError>()));
  });
}
