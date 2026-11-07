import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/fiscal/fiscal_repository.dart';
import 'package:tim_pos/returns/return_repository.dart';
import 'package:tim_pos/selling/selling.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000; // 15 Jan 2027, around 08:00 UTC
const off = 120;

const taxes = <Map<String, Object?>>[
  {'taxID': 1, 'taxCode': 'A', 'taxName': 'Exempt', 'taxPercent': null},
  {'taxID': 2, 'taxCode': 'B', 'taxName': 'Zero rated', 'taxPercent': 0},
  {'taxID': 3, 'taxCode': 'C', 'taxName': 'Standard rated 15%', 'taxPercent': 15},
];

class FakeGateway implements Gateway {
  final calls = <String>[];
  final receipts = <Map<String, Object?>>[];
  final closed = <Map<String, Object?>>[];
  int nextDay = 100;
  GatewayError? failOpen, closeError;
  GatewayError? Function(Map<String, Object?>)? failSubmit;
  List<Map<String, Object?>> Function(Map<String, Object?>)? colors;
  ({bool ok, List<String> errors}) closeAnswer = (ok: true, errors: const []);

  @override
  Future<int> openDay({required String fiscalDayOpened}) async {
    calls.add('open');
    if (failOpen != null) throw failOpen!;
    return nextDay++;
  }

  @override
  Future<SubmitResult> submitReceipt(Map<String, Object?> r) async {
    calls.add('submit');
    final e = failSubmit?.call(r);
    if (e != null) throw e;
    receipts.add(r);
    return SubmitResult(receiptId: 5000 + receipts.length, serverDate: '2027-01-15T10:00:00', serverSignature: {'hash': 'srv'}, validationErrors: colors?.call(r) ?? const []);
  }

  @override
  Future<({bool ok, List<String> errors})> closeDay({required int fiscalDayNo, required List<Map<String, Object?>> counters, required Map<String, Object?> signature, required int receiptCounter}) async {
    calls.add('close');
    if (closeError != null) throw closeError!;
    closed.add({'fiscalDayNo': fiscalDayNo, 'counters': counters, 'receiptCounter': receiptCounter});
    return closeAnswer;
  }
}

/// Only proves the phone numbers and chains receipts consistently. It is NOT ZIMRA's signature.
class FakeSigner implements Signer {
  @override
  bool get isReady => true;
  @override
  Map<String, Object?> signReceipt(Map<String, Object?> r, String? prev) => {'hash': 'h(${r['receiptGlobalNo']}|${prev ?? '-'})', 'signature': 'fake'};
  @override
  Map<String, Object?> signDay({required int fiscalDayNo, required String fiscalDayDate, required List<Map<String, Object?>> counters}) => {'hash': 'day$fiscalDayNo', 'signature': 'fake'};
}

void main() {
  late SqlDb db;
  late SellingEngine engine;
  late FiscalRepository fiscal;
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

  Future<void> boot({bool enabled = true}) async {
    db = await openTestDb();
    n = 0;
    now = t0;
    await put('shops', {'name': 'T', 'country_code': 'ZW', 'base_currency': 'USD'});
    await put('currencies', {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5, 'is_active': 1});
    await put('payment_methods', {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'opens_drawer': 1});
    await put('payment_methods', {'code': 'ecocash', 'name': 'EcoCash', 'kind': 'mobile_money', 'requires_reference': 1, 'opens_drawer': 0});
    await put('branches', {'id': 'branch', 'name': 'Main'});
    await put('units', {'id': 'pcs', 'name': 'Piece', 'code': 'pcs', 'kind': 'count'});
    await put('tax_classes', {'id': 'tc-std', 'name': 'Standard rated', 'rate_bp': 1500, 'is_inclusive': 1});
    await put('tax_classes', {'id': 'tc-zero', 'name': 'Zero rated', 'rate_bp': 0, 'is_inclusive': 1});
    await put('tax_classes', {'id': 'tc-ex', 'name': 'Exempt', 'rate_bp': 0, 'is_inclusive': 1});
    for (final p in [('bread', 'Bread', 150, 'tc-std'), ('milk', 'Milk', 200, 'tc-zero'), ('salt', 'Salt', 100, 'tc-ex')]) {
      await put('products', {'id': p.$1, 'name': p.$2, 'base_unit_id': 'pcs', 'is_active': 1, 'track_stock': 1, 'kind': 'simple', 'cost_minor': 90, 'cost_currency': 'USD', 'tax_class_id': p.$4});
      await put('product_prices', {'product_id': p.$1, 'currency': 'USD', 'price_minor': p.$3, 'effective_from': t0 - 9000});
      await put('stock_movements', {'branch_id': 'branch', 'product_id': p.$1, 'type': 'purchase', 'qty_milli': 100000, 'unit_cost_minor': 90, 'cost_currency': 'USD'}, versioned: false);
    }
    await put('roles', {'id': 'r-mgr', 'name': 'Manager', 'permissions': '["sale.create","sale.refund","sale.void","shift.manage","report.view"]'});
    await put('users', {'id': 'u-mgr', 'name': 'Mary', 'role_id': 'r-mgr', 'pin_hash': 'x', 'is_active': 1});
    await put('settings', {'scope': 'shop', 'key': 'fiscal_enabled', 'value': enabled ? '1' : '0'});
    engine = SellingEngine(db: db, context: const SaleContext(shopId: 's', deviceId: 'd', receiptPrefix: 'D1'), clock: () => now);
    fiscal = FiscalRepository(db: db, shopId: 's', deviceId: 'd', userId: 'u-mgr', clock: () => now);
    await fiscal.saveTaxSetup(taxes: taxes.map((e) => {...e}).toList(), map: {'tc-std': 3, 'tc-zero': 2, 'tc-ex': 1});
    await fiscal.saveDevice(deviceNo: 187, serial: 'SN-001');
  }

  setUp(boot);

  Future<SaleResult> sale(List<(String, int)> lines, int cashMinor, {int? at}) {
    now = at ?? now;
    return engine.sell(Cart(
      branchId: 'branch', saleCurrency: 'USD',
      lines: [for (final l in lines) CartLine(productId: l.$1, qtyMilli: l.$2)],
      payments: [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: cashMinor)],
    ));
  }

  List<Object?> flat(Iterable<Map<String, Object?>> rows, List<String> keys) => [for (final r in rows) [for (final k in keys) r[k]]];
  Future<RunResult> send(FakeGateway gw, {int? at, int? dayMaxHrs}) {
    if (at != null) now = at;
    return fiscal.sendQueued(gw, FakeSigner(), offsetMin: off, dayMaxHrs: dayMaxHrs);
  }

  test('a sale made while fiscalisation is on is queued; not when it is off', () async {
    await sale([('bread', 1000)], 150);
    expect(await fiscal.queuedCount(), 1);
    await boot(enabled: false);
    await sale([('bread', 1000)], 150);
    expect(await fiscal.queuedCount(), 0);
  });

  test('invoice: lines, tax groups, totals and payments follow the sale (change taken off)', () async {
    final s = await sale([('bread', 4000), ('milk', 1000), ('salt', 2000)], 2000);
    final r = await fiscal.buildInvoice(db, s.saleId, offsetMin: off);
    expect(r['receiptType'], 'FiscalInvoice');
    expect(r['invoiceNo'], s.receiptNo);
    expect(r['receiptDate'], '2027-01-15T10:00:00');
    expect(r['receiptTotal'], 10.0);
    expect(flat((r['receiptLines'] as List).cast(), ['receiptLineName', 'receiptLinePrice', 'receiptLineQuantity', 'receiptLineTotal', 'taxID']), [
      ['Bread', 1.5, 4.0, 6.0, 3], ['Milk', 2.0, 1.0, 2.0, 2], ['Salt', 1.0, 2.0, 2.0, 1],
    ]);
    expect(flat((r['receiptTaxes'] as List).cast(), ['taxID', 'salesAmountWithTax', 'taxAmount']), [[1, 2.0, 0.0], [2, 2.0, 0.0], [3, 6.0, 0.78]]);
    expect(r['receiptPayments'], [{'moneyTypeCode': 'Cash', 'paymentAmount': 10.0}]);
  });

  test('a tax class that is not matched fails that receipt clearly, and can be sent again after it is fixed', () async {
    await db.exec("update settings set value = '{}', version = version + 1 where key = 'fiscal_tax_map'");
    await sale([('bread', 1000)], 150);
    final gw = FakeGateway();
    final r = await send(gw);
    expect(r.failed, 1);
    expect(r.problems.single.code, 'tax_not_mapped');
    expect(gw.receipts, isEmpty);
    final failed = await fiscal.listQueue(status: 'failed');
    expect(failed, hasLength(1));
    await fiscal.saveTaxSetup(map: {'tc-std': 3, 'tc-zero': 2, 'tc-ex': 1});
    await fiscal.requeue(failed.single.id);
    expect((await send(gw)).sent, 1);
  });

  test('sending: receipts go in order with day counters, global numbers and a hash chain; a second run sends nothing', () async {
    await sale([('bread', 1000)], 150, at: t0);
    await sale([('milk', 1000)], 200, at: t0 + 1000);
    await sale([('salt', 1000)], 100, at: t0 + 2000);
    final gw = FakeGateway();
    final r = await send(gw, at: t0 + 5000);
    expect([r.sent, r.failed, r.waiting, r.stopped], [3, 0, 0, null]);
    expect(gw.calls, ['open', 'submit', 'submit', 'submit']);
    expect(flat(gw.receipts, ['receiptCounter', 'receiptGlobalNo']), [[1, 1], [2, 2], [3, 3]]);
    expect((gw.receipts[1]['receiptDeviceSignature'] as Map)['hash'], 'h(2|h(1|-))');
    final st = await fiscal.state();
    expect([st.status, st.dayNo, st.receiptCounter, st.globalNo], ['opened', 100, 3, 3]);
    expect((await fiscal.listQueue(status: 'sent')).map((d) => d.authorityRef).toSet(), {'5001', '5002', '5003'});
    expect((await send(gw, at: t0 + 6000)).sent, 0);
    expect(gw.receipts, hasLength(3));
  });

  test('no connection: nothing is lost and no numbers are used up; the next run continues where it stopped', () async {
    await sale([('bread', 1000)], 150, at: t0);
    await sale([('milk', 1000)], 200, at: t0 + 1000);
    final gw = FakeGateway()..failSubmit = (_) => GatewayError('timeout', retryable: true);
    final r = await send(gw);
    expect([r.sent, r.stopped, r.waiting], [0, 'offline', 2]);
    expect((await fiscal.state()).receiptCounter, 0);
    gw.failSubmit = null;
    expect((await send(gw)).sent, 2);
    expect(gw.receipts.map((x) => x['receiptCounter']), [1, 2]);
  });

  test('ZIMRA rejects one receipt: it fails with the reason, the others still go, numbers are not wasted', () async {
    await sale([('bread', 1000)], 150, at: t0);
    final bad = await sale([('milk', 1000)], 200, at: t0 + 1000);
    await sale([('salt', 1000)], 100, at: t0 + 2000);
    final gw = FakeGateway()..failSubmit = (r) => r['invoiceNo'] == bad.receiptNo ? GatewayError('Invalid receipt', status: 422, code: 'RCPT019') : null;
    final r = await send(gw);
    expect([r.sent, r.failed], [2, 1]);
    expect(r.problems.single.code, 'RCPT019');
    expect(gw.receipts.map((x) => x['receiptCounter']), [1, 2]);
    expect((await fiscal.canCloseDay()).ok, isFalse);
  });

  test('until a real signer is installed receipts stay queued and no fiscal day is opened', () async {
    await sale([('bread', 1000)], 150);
    final gw = FakeGateway();
    final r = await fiscal.sendQueued(gw, const UnavailableSigner(), offsetMin: off);
    expect([r.stopped, r.waiting, r.sent], ['signing_unavailable', 1, 0]);
    expect(gw.calls, isEmpty);
    expect((await fiscal.state()).status, 'closed');
    await db.exec("delete from device_state where key = 'fiscal_device'");
    expect((await send(gw)).stopped, 'no_device');
  });

  test('a return becomes a credit note pointing at the original receipt, with negative amounts and the reason', () async {
    final a = await sale([('bread', 4000)], 600, at: t0);
    final gw = FakeGateway();
    await send(gw, at: t0 + 1000);
    final returns = ReturnRepository(db: db, shopId: 's', deviceId: 'd', receiptPrefix: 'D1', userId: 'u-mgr', clock: () => now);
    final line = (await returns.returnableLines(a.saleId)).single;
    now = t0 + 2000;
    await returns.processReturn(saleId: a.saleId, items: [ReturnItem(saleLineId: line.saleLineId, qtyMilli: 1000)], reason: 'Stale', payouts: [const Payout(methodCode: 'cash', currency: 'USD', amountMinor: 150)]);
    expect(await fiscal.queuedCount(), 1);
    expect((await send(gw, at: t0 + 3000)).sent, 1);
    final cn = gw.receipts[1];
    expect(cn['receiptType'], 'CreditNote');
    expect(cn['receiptNotes'], 'Stale');
    expect(cn['creditDebitNote'], {'receiptID': 5001});
    expect(cn['receiptTotal'], -1.5);
    expect(flat((cn['receiptTaxes'] as List).cast(), ['taxID', 'salesAmountWithTax', 'taxAmount']), [[3, -1.5, -0.2]]);
    expect(cn['receiptPayments'], [{'moneyTypeCode': 'Cash', 'paymentAmount': -1.5}]);
    expect([cn['receiptCounter'], cn['receiptGlobalNo']], [2, 2]);
  });

  test('day counters: sales and credit notes by tax and money type, zero values left out, fixed order', () {
    Map<String, Object?> mk(String type, double sales, double tax, List<(String, double)> pay) => {
          'receiptType': type, 'receiptCurrency': 'USD',
          'receiptTaxes': [{'taxID': 3, 'taxPercent': 15, 'taxAmount': tax, 'salesAmountWithTax': sales}, {'taxID': 2, 'taxPercent': 0, 'taxAmount': 0.0, 'salesAmountWithTax': 0.0}],
          'receiptPayments': [for (final p in pay) {'moneyTypeCode': p.$1, 'paymentAmount': p.$2}],
        };
    final c = dayCounters([
      mk('FiscalInvoice', 6, 0.78, [('Cash', 4), ('MobileWallet', 2)]),
      mk('FiscalInvoice', 3, 0.39, [('Cash', 3)]),
      mk('CreditNote', -1.5, -0.2, [('Cash', -1.5)]),
    ]);
    expect([for (final x in c) [x['fiscalCounterType'], x['fiscalCounterTaxID'] ?? x['fiscalCounterMoneyType'], x['fiscalCounterValue']]], [
      ['SaleByTax', 3, 9.0], ['CreditNoteByTax', 3, -1.5], ['SaleTaxByTax', 3, 1.17], ['CreditNoteTaxByTax', 3, -0.2],
      ['BalanceByMoneyType', 'Cash', 5.5], ['BalanceByMoneyType', 'MobileWallet', 2.0],
    ]);
  });

  test('closing the day: blocked while anything is marked by ZIMRA; a refused close can be retried; the next day restarts the counter', () async {
    await sale([('bread', 4000)], 600, at: t0);
    await sale([('milk', 1000)], 200, at: t0 + 1000);
    final gw = FakeGateway();
    expect((await fiscal.closeDay(gw, FakeSigner())).ok, isFalse);
    gw.colors = (r) => (r['invoiceNo'] as String).endsWith('2') ? [{'validationErrorCode': 'RCPT022', 'validationErrorColor': 'Red'}] : [];
    await send(gw, at: t0 + 2000);
    final blocked = await fiscal.closeDay(gw, FakeSigner());
    expect(blocked.ok, isFalse);
    expect(blocked.message, contains('marked by ZIMRA'));
    expect(gw.closed, isEmpty);

    await boot();
    await sale([('bread', 4000)], 600, at: t0);
    await sale([('milk', 1000)], 200, at: t0 + 1000);
    final g2 = FakeGateway();
    await send(g2, at: t0 + 2000);
    g2.closeAnswer = (ok: false, errors: ['CountersMismatch']);
    final refused = await fiscal.closeDay(g2, FakeSigner());
    expect([refused.ok, (await fiscal.state()).status], [false, 'close_failed']);
    g2.closeAnswer = (ok: true, errors: const []);
    expect((await fiscal.closeDay(g2, FakeSigner())).ok, isTrue);
    final req = g2.closed.last;
    expect([req['fiscalDayNo'], req['receiptCounter']], [100, 2]);
    expect([for (final c in (req['counters'] as List).cast<Map<String, Object?>>()) [c['fiscalCounterType'], c['fiscalCounterValue']]], [
      ['SaleByTax', 2.0], ['SaleByTax', 6.0], ['SaleTaxByTax', 0.78], ['BalanceByMoneyType', 8.0],
    ]);
    expect((await fiscal.state()).status, 'closed');
    await sale([('salt', 1000)], 100, at: t0 + 86400000);
    await send(g2, at: t0 + 86401000);
    final last = g2.receipts.last;
    expect([last['receiptCounter'], last['receiptGlobalNo']], [1, 3]);
    expect((await fiscal.state()).dayNo, 101);
    expect((last['receiptDeviceSignature'] as Map)['hash'], 'h(3|-)');
  });

  test('device and set-up checks', () async {
    expect((await fiscal.device())!.deviceId, 187);
    expect(() => fiscal.saveDevice(deviceNo: 0, serial: 'x'), throwsA(isA<FiscalError>()));
    expect(() => fiscal.saveDevice(deviceNo: 5, serial: ' '), throwsA(isA<FiscalError>()));
    await sale([('bread', 1000)], 150);
    expect(() => fiscal.saveDevice(deviceNo: 188, serial: 'SN-2'), throwsA(isA<FiscalError>().having((e) => e.code, 'code', 'device_busy')));
    expect(() => fiscal.saveTaxSetup(map: {'nope': 3}), throwsA(isA<FiscalError>().having((e) => e.code, 'code', 'bad_tax_map')));
    expect(() => fiscal.saveTaxSetup(map: {'tc-std': 99}), throwsA(isA<FiscalError>().having((e) => e.code, 'code', 'bad_tax_map')));
    expect(() => fiscal.saveTaxSetup(hsDefault: 'abc'), throwsA(isA<FiscalError>().having((e) => e.code, 'code', 'bad_hs')));
    expect(zimraDate(1793658605000, 120), '2026-11-03T00:30:05');
  });

  // keeps the import used
  test('payload round-trips as JSON', () async {
    await sale([('bread', 1000)], 150);
    final d = (await fiscal.listQueue()).single;
    expect(jsonDecode(jsonEncode(d.payload)), d.payload);
  });
}
