import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/printing/receipt.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/settings/settings_repository.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;

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

  SettingsRepository repo([String? user = 'u-own']) => SettingsRepository(db: db, shopId: 's', deviceId: 'd', userId: user, clock: () => now);
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));
  Future<SaleResult> sell(int qty) => SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now).sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', lines: [CartLine(productId: 'bread', qtyMilli: qty)],
        payments: [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 150 * qty ~/ 1000)],
      ));

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0;
    await put('shops', {'name': 'Shop', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('products', {'id': 'bread', 'name': 'Bread', 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple', 'cost_minor': 90, 'cost_currency': 'USD'});
    await put('product_prices', {'product_id': 'bread', 'currency': 'USD', 'price_minor': 150, 'effective_from': t0 - 9000});
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'bread', 'type': 'purchase', 'qty_milli': 10000, 'unit_cost_minor': 90, 'cost_currency': 'USD'}, versioned: false);
    await put('roles', {'id': 'r-own', 'name': 'Owner', 'permissions': '["settings.edit","sale.create"]'});
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create"]'});
    await put('users', {'id': 'u-own', 'name': 'Tim', 'role_id': 'r-own', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
  });

  test('every setting has a default', () async {
    final s = await repo().load();
    expect(s.keys.toSet(), shopSettings.map((d) => d.key).toSet());
    expect([s['require_shift'], s['layby_min_deposit_pct'], s['receipt_footer']], ['0', '0', '']);
  });

  test('saving changes only what differs, bumps the version and writes the audit log', () async {
    now = t0 + 1000;
    expect(await repo().save({'require_shift': '1', 'allow_negative_stock': '0', 'layby_min_deposit_pct': ' 20 '}), ['require_shift', 'layby_min_deposit_pct']);
    final s = await repo().load();
    expect([s['require_shift'], s['layby_min_deposit_pct']], ['1', '20']);
    expect(await repo().save({'require_shift': '1'}), isEmpty);
    now = t0 + 2000;
    await repo().save({'require_shift': '0'});
    final row = (await db.query("select value, version from settings where key = 'require_shift'")).single;
    expect([row['value'], row['version']], ['0', 2]);
    final log = await db.query("select before, after from audit_log where action = 'setting_change' and row_id = 'require_shift' order by rowid");
    expect(log.map((l) => [l['before'], l['after']]), [['0', '1'], ['1', '0']]);
    expect((await db.query("select count(*) as c from settings where key = 'require_shift' and deleted_at is null")).single['c'], 1);
  });

  test('bad values are refused and nothing at all is saved', () async {
    final r = repo();
    await expectLater(r.save({'require_shift': '1', 'layby_min_deposit_pct': '101'}), failsWith('bad_setting'));
    await expectLater(r.save({'layby_min_deposit_pct': '-5'}), failsWith('bad_setting'));
    await expectLater(r.save({'layby_min_deposit_pct': '12.5'}), failsWith('bad_setting'));
    await expectLater(r.save({'require_shift': 'yes'}), failsWith('bad_setting'));
    await expectLater(r.save({'receipt_footer': 'x' * 121}), failsWith('bad_setting'));
    await expectLater(r.save({'costing': 'fifo'}), failsWith('unknown_setting'));
    expect((await r.load())['require_shift'], '0');
  });

  test('only someone with settings.edit can change settings', () async {
    await expectLater(repo('u-cash').save({'require_shift': '1'}), failsWith('forbidden'));
    expect((await repo().load())['require_shift'], '0');
  });

  test('receipt text is trimmed to one line, and it reaches the receipt', () async {
    await repo().save({'receipt_header': '  Wholesale\n and retail  ', 'receipt_footer': 'No refunds without receipt'});
    expect((await repo().load())['receipt_header'], 'Wholesale and retail');
    now = t0 + 5;
    final s = await sell(1000);
    final r = await loadReceipt(db, s.saleId);
    expect([r.header, r.footer], ['Wholesale and retail', 'No refunds without receipt']);
    await repo().save({'receipt_footer': ''});
    expect((await loadReceipt(db, s.saleId)).footer, '');
  });

  test('the settings change how selling behaves', () async {
    now = t0 + 5;
    await expectLater(sell(11000), throwsA(predicate((e) => e.toString().contains('Only 10'))));
    await repo().save({'allow_negative_stock': '1', 'require_shift': '1'});
    await expectLater(sell(1000), throwsA(predicate((e) => e.toString().toLowerCase().contains('shift'))));
    await repo().save({'require_shift': '0'});
    expect((await sell(11000)).saleId, isNotEmpty);
  });
}
