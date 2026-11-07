import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/cart_controller.dart';
import 'package:tim_pos/selling/catalog.dart';
import 'package:tim_pos/selling/selling.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
  late CartController cart;
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
    await put('shops', {'name': 'T', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('currencies', {'code': 'ZiG', 'name': 'ZiG', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100, 'is_active': 1});
    await put('exchange_rates', {'from_currency': 'USD', 'to_currency': 'ZiG', 'rate_micro': 26500000, 'effective_from': t0 - 5000}, versioned: false);
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('products', {'id': 'bread', 'name': 'Bread', 'sku': 'BRD1', 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple'});
    await put('product_prices', {'product_id': 'bread', 'currency': 'USD', 'price_minor': 150, 'effective_from': t0 - 9000});
    await put('product_barcodes', {'product_id': 'bread', 'barcode': '6001234'});
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'bread', 'type': 'purchase', 'qty_milli': 3000}, versioned: false);
    final catalog = CatalogRepository(db, clock: () => t0);
    final setup = (await catalog.setup())!;
    final engine = SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => t0);
    cart = CartController(engine: engine, catalog: catalog, setup: setup);
  });

  test('search finds by name, SKU and barcode, with price and stock', () async {
    final byName = await cart.catalog.search('bre', branchId: 'branch', currency: 'USD');
    expect(byName.single.unitPriceMinor, 150);
    expect(byName.single.onHandMilli, 3000);
    expect((await cart.catalog.search('BRD', branchId: 'branch', currency: 'USD')).length, 1);
    expect((await cart.catalog.byBarcode('6001234', branchId: 'branch', currency: 'USD'))?.name, 'Bread');
    expect(await cart.catalog.byBarcode('nope', branchId: 'branch', currency: 'USD'), isNull);
    final zig = await cart.catalog.search('bre', branchId: 'branch', currency: 'ZiG');
    expect(zig.single.unitPriceMinor, 3975);
  });

  test('the cart will not take more than is on the shelf', () async {
    final hit = (await cart.catalog.search('bread', branchId: 'branch', currency: 'USD')).single;
    expect(cart.add(hit, qtyMilli: 2000), isTrue);
    expect(cart.add(hit, qtyMilli: 2000), isFalse);
    expect(cart.error, contains('Only 3'));
    expect(cart.total, 300);
  });

  test('pay part in ZiG and the rest in USD, then save', () async {
    final hit = (await cart.catalog.search('bread', branchId: 'branch', currency: 'USD')).single;
    cart.add(hit, qtyMilli: 2000); // 3.00
    cart.addPayment(const CartPayment(methodCode: 'cash', currency: 'ZiG', amountMinor: 3975), creditedInSaleCurrency: 150);
    expect(cart.due, 150);
    cart.addPayment(const CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 150), creditedInSaleCurrency: 150);
    expect(cart.due, 0);
    expect(await cart.checkout(), isTrue);
    expect(cart.lastSale?.receiptNo, 'D1-000001');
    expect(cart.items, isEmpty);
    expect((await db.query('select qty_milli from stock_levels')).single['qty_milli'], 1000);
  });

  test('amounts are typed and shown without floating point', () {
    const usd = CurrencyInfo('USD', r'$', 2);
    expect(usd.parse('12.5'), 1250);
    expect(usd.parse('12,50'), 1250);
    expect(usd.parse('7'), 700);
    expect(usd.parse('1.234'), isNull);
    expect(usd.parse('abc'), isNull);
    expect(usd.format(123456), r'$1,234.56');
    expect(usd.format(5), r'$0.05');
    expect(const CurrencyInfo('ZiG', 'ZiG', 2).format(3975), 'ZiG 39.75');
    expect(const CurrencyInfo('JPY', '¥', 0).format(500), '¥500');
  });
}
