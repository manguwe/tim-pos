import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/printing/print_service.dart';
import 'package:tim_pos/printing/printer_transport.dart';
import 'package:tim_pos/selling/cart_controller.dart';
import 'package:tim_pos/selling/catalog.dart';
import 'package:tim_pos/selling/selling.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

class FakeTransport implements PrinterTransport {
  final sent = <(String, Uint8List)>[];
  String? failWith;
  @override
  Future<List<PrinterDevice>> pairedDevices() async => const [PrinterDevice(name: 'RPP02N', address: 'AA:BB:CC:00:11:22')];
  @override
  Future<void> send(String address, Uint8List bytes) async {
    if (failWith != null) throw PrinterError(failWith!);
    sent.add((address, bytes));
  }
}

void main() {
  late SqlDb db;
  late CartController cart;
  late FakeTransport transport;
  late PrintService svc;
  late String saleId;
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
    transport = FakeTransport();
    svc = PrintService(db: db, transport: transport, deviceId: 'd', utcOffset: 120);
    final hit = (await catalog.search('bread', branchId: 'branch', currency: 'USD')).single;
    cart.add(hit, qtyMilli: 2000);
    cart.addPayment(const CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 300), creditedInSaleCurrency: 300);
    expect(await cart.checkout(), isTrue);
    saleId = cart.lastSale!.saleId;
  });


  test('without a printer there is a clear message and a preview still works', () async {
    expect(await svc.printer(), isNull);
    await expectLater(svc.print(saleId), throwsA(isA<PrinterError>()));
    final text = await svc.preview(saleId);
    expect(text, contains('D1-000001'));
    expect(text, contains(r'$3.00'));
  });

  test('a saved printer is remembered, replaced, and used at its paper width', () async {
    await svc.savePrinter(name: 'RPP02N', address: 'AA:BB:CC:00:11:22', paperWidthMm: 58, opensDrawer: false);
    await svc.savePrinter(name: 'RPP02N', address: 'AA:BB:CC:00:11:22', paperWidthMm: 80, opensDrawer: true);
    final p = (await svc.printer())!;
    expect([p.paperWidthMm, p.opensDrawer, p.chars], [80, true, 48]);
    expect((await db.query('select count(*) as c from printers')).single['c'], 1);
    final text = await svc.preview(saleId);
    expect(text.split('\n').every((l) => l.length <= 48), isTrue);
    expect(text.split('\n').any((l) => l.length > 32), isTrue);
  });

  test('printing sends the receipt to the saved printer; cash opens the drawer once, a copy does not', () async {
    await svc.savePrinter(name: 'RPP02N', address: 'AA:BB:CC:00:11:22', paperWidthMm: 58, opensDrawer: true);
    await svc.print(saleId);
    await svc.print(saleId, copy: true);
    expect(transport.sent.length, 2);
    expect(transport.sent.first.$1, 'AA:BB:CC:00:11:22');
    final drawerKick = [0x1b, 0x70, 0x00, 0x19, 0xfa];
    bool has(Uint8List b) {
      for (var i = 0; i + 5 <= b.length; i++) {
        if (List.generate(5, (j) => b[i + j]).join(',') == drawerKick.join(',')) return true;
      }
      return false;
    }

    expect(has(transport.sent[0].$2), isTrue);
    expect(has(transport.sent[1].$2), isFalse);
    expect(String.fromCharCodes(transport.sent[1].$2), contains('*** COPY ***'));
  });

  test('a printer failure is reported and never touches the saved sale', () async {
    await svc.savePrinter(name: 'RPP02N', address: 'AA:BB:CC:00:11:22', paperWidthMm: 58, opensDrawer: false);
    transport.failWith = 'Printer is switched off';
    await expectLater(svc.print(saleId), throwsA(isA<PrinterError>()));
    expect((await db.query("select status from sales where id = ?", [saleId])).single['status'], 'completed');
  });

  test('the test page fits the paper', () async {
    await svc.savePrinter(name: 'RPP02N', address: 'AA:BB:CC:00:11:22', paperWidthMm: 58, opensDrawer: false);
    await svc.printTest();
    expect(String.fromCharCodes(transport.sent.single.$2), contains('Printer test'));
  });
}
