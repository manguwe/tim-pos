import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/setup/setup_repository.dart' show SetupError;
import 'package:tim_pos/stock/stock_repository.dart';

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

  StockRepository repo([String? user = 'u-mgr']) => StockRepository(db: db, shopId: 's', deviceId: 'd', userId: user, clock: () => now);
  Matcher failsWith(String code) => throwsA(isA<SetupError>().having((e) => e.code, 'code', code));
  Future<int> level(String p, [String batch = '']) async => (await db.query('select coalesce(sum(qty_milli),0) as s from stock_levels where product_id = ? and batch_key = ?', [p, batch])).single['s'] as int;
  Future<void> receive(String product, int qty, {String? batch}) =>
      put('stock_movements', {'branch_id': 'branch', 'product_id': product, 'batch_id': batch, 'type': 'purchase', 'qty_milli': qty, 'unit_cost_minor': 90, 'cost_currency': 'USD'}, versioned: false);
  Future<void> sellBread(int qty) => SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now).sell(Cart(
        branchId: 'branch', saleCurrency: 'USD', lines: [CartLine(productId: 'bread', qtyMilli: qty)],
        payments: [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: 150 * qty ~/ 1000)],
      ));

  setUp(() async {
    db = await openTestDb();
    n = 0;
    now = t0 + 1000;
    await put('shops', {'name': 'Shop', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('branches', {'id': 'branch', 'name': 'Main', 'is_active': 1});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    for (final p in [('bread', 'Bread', 150, 90, 1), ('radio', 'Radio', 4000, 2500, 1), ('airtime', 'Airtime', 100, null, 0)]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': p.$5, 'kind': 'simple', 'cost_minor': p.$4, 'cost_currency': 'USD'});
      await put('product_prices', {'product_id': p.$1, 'currency': 'USD', 'price_minor': p.$3, 'effective_from': t0 - 9000});
    }
    await receive('bread', 50000);
    await put('stock_movements', {'branch_id': 'branch', 'product_id': 'radio', 'type': 'purchase', 'qty_milli': 5000, 'unit_cost_minor': 2500, 'cost_currency': 'USD'}, versioned: false);
    await put('roles', {'id': 'r-cash', 'name': 'Cashier', 'permissions': '["sale.create"]'});
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["sale.create","stock.adjust"]'});
    await put('users', {'id': 'u-cash', 'name': 'Rudo', 'role_id': 'r-cash', 'pin_hash': 'x', 'is_active': 1});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
  });

  test('damaged, expired and lost stock is removed with a reason and valued at cost', () async {
    final r = repo();
    final a = await r.adjustStock(branchId: 'branch', productId: 'bread', kind: AdjustKind.damaged, qtyMilli: 2500, reason: 'Dropped crate');
    expect([a.qtyMilli, a.valueMinor], [-2500, -225]);
    expect(await level('bread'), 47500);
    await r.adjustStock(branchId: 'branch', productId: 'bread', kind: AdjustKind.expired, qtyMilli: 1000, reason: 'Past date');
    await r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 1000, reason: 'Stolen');
    await r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.found, qtyMilli: 2000, reason: 'Found in storeroom');
    expect(await level('radio'), 6000);
    final rows = await db.query("select type, qty_milli from stock_movements where type in ('damaged','expired','loss','adjustment') order by rowid");
    expect(rows.map((x) => [x['type'], x['qty_milli']]), [['damaged', -2500], ['expired', -1000], ['loss', -1000], ['adjustment', 2000]]);
    expect((await db.query("select count(*) as c from audit_log where action = 'stock_adjust'")).single['c'], 4);
  });

  test('a removal cannot take more than is on the shelf; reasons and quantities are required', () async {
    final r = repo();
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 5001, reason: 'x'), failsWith('not_enough_stock'));
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 1000, reason: '  '), failsWith('reason_needed'));
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 0, reason: 'x'), failsWith('bad_quantity'));
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'nope', kind: AdjustKind.loss, qtyMilli: 1, reason: 'x'), failsWith('not_found'));
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 1, batchId: 'nope', reason: 'x'), failsWith('unknown_batch'));
    await expectLater(r.adjustStock(branchId: 'branch', productId: 'airtime', kind: AdjustKind.loss, qtyMilli: 1000, reason: 'x'), failsWith('not_enough_stock'));
    try {
      await r.adjustStock(branchId: 'branch', productId: 'radio', kind: AdjustKind.loss, qtyMilli: 5001, reason: 'x');
    } on SetupError catch (e) {
      expect(e.message, contains('Only 5 of Radio'));
    }
  });

  test('only people with stock.adjust may adjust', () async {
    await expectLater(repo('u-cash').adjustStock(branchId: 'branch', productId: 'bread', kind: AdjustKind.loss, qtyMilli: 1000, reason: 'x'), failsWith('forbidden'));
  });

  test('batches are adjusted on their own', () async {
    await db.exec("insert into stock_batches (id, shop_id, created_at, updated_at, version, product_id, branch_id, batch_code, expiry_date) values ('b1','s',1,1,1,'bread','branch','L1','2026-11-05')");
    await receive('bread', 3000, batch: 'b1');
    final bs = await repo().buckets('branch', 'bread');
    expect(bs.map((b) => [b.batchId, b.batchCode, b.qtyMilli]), [['b1', 'L1', 3000], [null, null, 50000]]);
    await expectLater(repo().adjustStock(branchId: 'branch', productId: 'bread', batchId: 'b1', kind: AdjustKind.expired, qtyMilli: 3001, reason: 'x'), failsWith('not_enough_stock'));
    await repo().adjustStock(branchId: 'branch', productId: 'bread', batchId: 'b1', kind: AdjustKind.expired, qtyMilli: 3000, reason: 'Expired');
    expect(await level('bread', 'b1'), 0);
    expect(await level('bread'), 50000);
    expect((await db.query("select batch_id from stock_movements where type = 'expired'")).single['batch_id'], 'b1');
  });

  test('adjustment history totals by type, newest first, within the date range', () async {
    Future<void> adj(int at, String p, AdjustKind k, int q, String why) async {
      now = at;
      await repo().adjustStock(branchId: 'branch', productId: p, kind: k, qtyMilli: q, reason: why);
    }

    await adj(t0 + 10, 'bread', AdjustKind.damaged, 2000, 'a');
    await adj(t0 + 20, 'radio', AdjustKind.loss, 1000, 'b');
    await adj(t0 + 30, 'bread', AdjustKind.damaged, 1000, 'c');
    await adj(t0 + 99999, 'radio', AdjustKind.found, 1000, 'later');
    final h = await repo().history(t0, t0 + 1000);
    expect(h.rows.map((r) => r.reason), ['c', 'b', 'a']);
    expect(h.rows.map((r) => r.user), ['Mary', 'Mary', 'Mary']);
    expect(h.summary.map((s) => [s.type, s.count, s.qtyMilli, s.valueMinor]), [['damaged', 2, -3000, -270], ['loss', 1, -1000, -2500]]);
    expect((await repo().history(t0, t0 + 1000, branchId: 'other')).rows, isEmpty);
  });

  test('a stock take snapshots tracked products, takes counts, and changes nothing until approved', () async {
    final r = repo();
    final s = await r.startStockTake(branchId: 'branch');
    expect(s.lines, 2);
    var lines = await r.stockTakeLines(s.takeId);
    expect(lines.map((l) => [l.product, l.expectedMilli, l.countedMilli]), [['Bread', 50000, null], ['Radio', 5000, null]]);
    await expectLater(r.startStockTake(branchId: 'branch'), failsWith('take_open'));
    expect((await r.currentStockTake('branch'))!.id, s.takeId);
    await expectLater(r.finishCounting(s.takeId), failsWith('nothing_counted'));
    await r.recordCount(lines[0].id, 49000);
    await r.recordCount(lines[1].id, 6000);
    await expectLater(r.recordCount(lines[0].id, -1), failsWith('bad_quantity'));
    final rep = await r.finishCounting(s.takeId);
    expect([rep.countedLines, rep.uncountedLines, rep.surplusMinor, rep.shortageMinor], [2, 0, 2500, 90]);
    expect(rep.lines.map((l) => l.differenceMilli), [-1000, 1000]);
    expect(await level('bread'), 50000);
    await expectLater(r.recordCount(lines[0].id, 1000), failsWith('take_closed'));
    final a = await r.approveStockTake(s.takeId);
    expect([a.corrections, a.surplusMinor, a.shortageMinor], [2, 2500, 90]);
    expect(await level('bread'), 49000);
    expect(await level('radio'), 6000);
    expect(await r.currentStockTake('branch'), isNull);
    await expectLater(r.approveStockTake(s.takeId), failsWith('take_not_counted'));
    await expectLater(r.cancelStockTake(s.takeId), failsWith('take_approved'));
  });

  test('sales made while counting are kept: the correction is counted minus the snapshot', () async {
    final r = repo();
    final s = await r.startStockTake(branchId: 'branch', productIds: ['bread']);
    await sellBread(4000);
    final l = (await r.stockTakeLines(s.takeId)).single;
    await r.recordCount(l.id, 49000);
    await r.finishCounting(s.takeId);
    await r.approveStockTake(s.takeId);
    expect(await level('bread'), 45000);
  });

  test('uncounted lines are left alone, a partial take only lists the chosen products, and counting can be reopened', () async {
    final r = repo();
    final s = await r.startStockTake(branchId: 'branch', productIds: ['bread', 'radio']);
    expect(s.lines, 2);
    final lb = (await r.stockTakeLines(s.takeId)).first;
    await r.recordCount(lb.id, 48000);
    await r.finishCounting(s.takeId);
    await r.reopenCounting(s.takeId);
    await r.recordCount(lb.id, 47000);
    final rep = await r.finishCounting(s.takeId);
    expect([rep.countedLines, rep.uncountedLines], [1, 1]);
    expect((await r.approveStockTake(s.takeId)).corrections, 1);
    expect([await level('bread'), await level('radio')], [47000, 5000]);
  });

  test('approval needs a manager; a cashier can be covered by a manager approval; a take can be cancelled', () async {
    final s = await repo().startStockTake(branchId: 'branch');
    final l = (await repo().stockTakeLines(s.takeId)).first;
    await repo().recordCount(l.id, 40000);
    await repo().finishCounting(s.takeId);
    await expectLater(repo('u-cash').approveStockTake(s.takeId), failsWith('forbidden'));
    await expectLater(repo('u-cash').approveStockTake(s.takeId, approvedBy: 'u-cash'), failsWith('forbidden'));
    await repo('u-cash').approveStockTake(s.takeId, approvedBy: 'u-mgr');
    expect(await level('bread'), 40000);
    final t2 = await repo().startStockTake(branchId: 'branch');
    await repo().cancelStockTake(t2.takeId);
    expect(await repo().currentStockTake('branch'), isNull);
    await expectLater(repo().stockTakeReport(t2.takeId), failsWith('not_found'));
  });
}
