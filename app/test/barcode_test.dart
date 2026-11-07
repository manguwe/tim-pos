import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/barcodes/barcode_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/printing/receipt.dart';
import 'package:tim_pos/settings/settings_repository.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  late SqlDb db;
  var now = t0 + 1000;
  var n = 0;

  Future<void> put(String table, Map<String, Object?> row, {bool versioned = true}) async {
    final o = <String, Object?>{
      'id': 'seed-${(++n).toString().padLeft(6, '0')}', 'shop_id': 's', 'created_at': t0 - 1000,
      if (versioned) ...{'updated_at': t0 - 1000, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await db.exec('insert into "$table" (${k.map((x) => '"$x"').join(',')}) values (${List.filled(k.length, '?').join(',')})', k.map((x) => o[x]).toList());
  }

  BarcodeRepository repo([String? user = 'u-mgr']) => BarcodeRepository(db: db, shopId: 's', deviceId: 'd', userId: user, clock: () => now);
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));
  Future<void> scalePrefix(String v) => SettingsRepository(db: db, shopId: 's', deviceId: 'd', userId: 'u-mgr', clock: () => now).save({'scale_prefix': v});

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0 + 1000;
    await put('shops', {'name': 'Shop', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('units', {'id': 'kg', 'name': 'Kilogram', 'code': 'kg', 'kind': 'weight'});
    for (final p in [('bread', 'Bread', 'pcs'), ('milk', 'Milk', 'pcs'), ('beef', 'Beef', 'kg')]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': p.$3, 'is_active': 1, 'track_stock': 1, 'kind': 'simple'});
    }
    await put('product_prices', {'product_id': 'bread', 'currency': 'USD', 'price_minor': 150, 'effective_from': t0 - 5000});
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["product.edit","settings.edit"]'});
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create"]'});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
  });

  test('cleaning and check digits', () {
    expect(cleanBarcode(' 5901234123457\r\n'), '5901234123457');
    expect(checkDigit('590123412345'), 7);
    expect(describeBarcode('5901234123457'), (kind: BarcodeKind.ean13, valid: true));
    expect(describeBarcode('5901234123458'), (kind: BarcodeKind.ean13, valid: false));
    expect(describeBarcode('96385074'), (kind: BarcodeKind.ean8, valid: true));
    expect(describeBarcode('036000291452'), (kind: BarcodeKind.upcA, valid: true));
    expect(describeBarcode('ABC-123'), (kind: BarcodeKind.other, valid: true));
    expect(describeBarcode('12345'), (kind: BarcodeKind.other, valid: true));
    expect(makeEan13('590123412345'), '5901234123457');
  });

  test('UPC-A, EAN-13 and GTIN-14 are the same number', () {
    const all = ['00036000291452', '0036000291452', '036000291452'];
    expect(lookupForms('036000291452').toList()..sort(), all);
    expect(lookupForms('0036000291452').toList()..sort(), all);
    expect(lookupForms('5901234123457').toList()..sort(), ['05901234123457', '5901234123457']);
    expect(lookupForms('96385074'), ['96385074']);
    expect(lookupForms('ABC-123'), ['ABC-123']);
  });

  test('a scan finds the product however the code was written', () async {
    await repo().add('bread', '036000291452');
    for (final raw in ['036000291452', '0036000291452', ' 036000291452\n']) {
      final r = await repo().resolve(raw);
      expect([r.status, r.productId, r.qtyMilli, r.weighed], [ScanStatus.found, 'bread', null, false]);
    }
    expect((await repo().resolve('   ')).status, ScanStatus.empty);
    final u = await repo().resolve('5901234123457');
    expect([u.status, u.kind, u.valid], [ScanStatus.unknown, BarcodeKind.ean13, true]);
    expect((await repo().resolve('5901234123458')).valid, false);
  });

  test('an exact match wins over an equivalent form', () async {
    await repo().add('bread', '036000291452');
    await put('product_barcodes', {'product_id': 'milk', 'barcode': '0036000291452'});
    expect((await repo().resolve('0036000291452')).productId, 'milk');
    expect((await repo().resolve('036000291452')).productId, 'bread');
  });

  test('adding: checks, one owner, repeat is harmless, permission', () async {
    final a = await repo().add('bread', '5901234123457');
    expect(a.created, true);
    expect((await repo().add('bread', '5901234123457')), (id: a.id, created: false));
    expect((await repo().add('bread', '05901234123457')), (id: a.id, created: false));
    await expectLater(repo().add('milk', '5901234123457'), throwsA(isA<SetupError>().having((e) => e.message, 'message', contains('already belongs to Bread'))));
    await expectLater(repo().add('milk', '5901234123458'), failsWith('bad_check_digit'));
    expect((await repo().add('milk', '5901234123458', allowInvalid: true)).created, true);
    await expectLater(repo().add('milk', 'ab'), failsWith('bad_barcode'));
    await expectLater(repo().add('nope', 'ABC-1'), failsWith('not_found'));
    await expectLater(repo('u-cash').add('milk', 'ABC-1'), failsWith('forbidden'));
    expect((await repo().list('milk')).map((b) => b.barcode), ['5901234123458']);
    expect((await db.query("select count(*) as c from audit_log where action = 'barcode_add'")).single['c'], 2);
  });

  test('removing frees the code for another product', () async {
    final a = await repo().add('bread', 'ABC-123');
    now += 1000;
    await repo().remove(a.id);
    expect((await repo().resolve('ABC-123')).status, ScanStatus.unknown);
    expect(await repo().list('bread'), isEmpty);
    expect((await repo().add('milk', 'ABC-123')).created, true);
    await expectLater(repo().remove(a.id), failsWith('not_found'));
    final row = (await db.query('select version, deleted_at from product_barcodes where id = ?', [a.id])).single;
    expect([row['version'], row['deleted_at']], [2, t0 + 2000]);
    expect((await db.query("select count(*) as c from audit_log where action = 'barcode_remove'")).single['c'], 1);
  });

  test('a scan of an inactive product is reported, not sold', () async {
    await repo().add('bread', 'ABC-123');
    await db.exec('update products set is_active = 0 where id = ?', ['bread']);
    final r = await repo().resolve('ABC-123');
    expect([r.status, r.productId, r.productName], [ScanStatus.inactive, 'bread', 'Bread']);
  });

  test('scale labels give the weight', () async {
    String label(String item, int grams) => makeEan13('21$item${grams.toString().padLeft(5, '0')}');
    await repo().add('beef', '2100123');
    await repo().add('bread', '2100456');
    expect((await repo().resolve(label('00123', 1250))).status, ScanStatus.unknown); // scale not switched on
    await scalePrefix('21');
    final r = await repo().resolve(label('00123', 1250));
    expect([r.status, r.productId, r.qtyMilli, r.weighed], [ScanStatus.found, 'beef', 1250, true]);
    expect((await repo().resolve(label('00123', 0))).message, contains('no weight'));
    expect((await repo().resolve(label('00456', 500))).message, contains('not sold by weight'));
    expect((await repo().resolve(label('00999', 500))).status, ScanStatus.unknown);
    expect((await repo().resolve('2100123012508')).status, ScanStatus.unknown); // wrong check digit
  });

  test('the scale prefix must be two digits or empty', () async {
    await expectLater(scalePrefix('2'), failsWith('bad_setting'));
    await expectLater(scalePrefix('ab'), failsWith('bad_setting'));
    await scalePrefix('21');
    await scalePrefix('');
  });

  test('shop codes are valid EAN-13, unused, and avoid the scale prefix', () async {
    var i = 0;
    int pick(int m) => (i++ * 7) % m;
    final a = await repo().newShopCode(pick: pick);
    expect(RegExp(r'^20\d{11}$').hasMatch(a), true);
    expect(describeBarcode(a).valid, true);
    await scalePrefix('20');
    expect(RegExp(r'^22\d{11}$').hasMatch(await repo().newShopCode(pick: pick)), true);
    await scalePrefix('');
    final taken = await repo().newShopCode(pick: (_) => 3);
    await repo().add('bread', taken);
    var calls = 0;
    final next = await repo().newShopCode(pick: (_) => calls++ < 10 ? 3 : 4);
    expect(next, isNot(taken));
    expect(calls > 10, true);
    final given = await repo().giveShopCode('milk');
    expect((await repo().list('milk')).map((b) => b.barcode), [given]);
  });

  test('shelf labels: layout, preview and printer bytes', () async {
    await repo().add('bread', '5901234123457');
    final lab = await repo().loadLabel('bread');
    expect([lab.name, lab.priceText, lab.code], ['Bread', r'$1.50', '5901234123457']);
    final items = layoutLabel(lab, width: 32, copies: 2);
    expect(items.where((i) => i.kind == ItemKind.barcode).length, 2);
    expect(items.where((i) => i.kind == ItemKind.cut).length, 2);
    expect(toText(items, 32), contains('|||| 5901234123457 ||||'));
    final bytes = toEscPos(items, 32).toList();
    var at = -1;
    for (var k = 0; k < bytes.length - 3; k++) {
      if (bytes[k] == 0x1d && bytes[k + 1] == 0x6b && bytes[k + 2] == 2) {
        at = k;
        break;
      }
    }
    expect(at > 0, true);
    expect(String.fromCharCodes(bytes.sublist(at + 3, at + 15)), '590123412345');
    expect(bytes[at + 15], 0);
    final c128 = toEscPos(layoutLabel(const LabelData(name: 'X', code: 'ABC-123'), width: 32), 32).toList();
    final k = [for (var j = 0; j < c128.length - 3; j++) if (c128[j] == 0x1d && c128[j + 1] == 0x6b && c128[j + 2] == 73) j].first;
    expect([c128[k + 3], c128[k + 4], c128[k + 5]], [9, 0x7b, 0x42]);
    expect(layoutLabel(LabelData(name: 'X', code: 'A' * 30), width: 32).any((i) => i.kind == ItemKind.barcode), false);
    await expectLater(repo().loadLabel('nope'), failsWith('not_found'));
    await expectLater(repo().loadLabel('milk'), failsWith('no_barcode'));
  });
}
