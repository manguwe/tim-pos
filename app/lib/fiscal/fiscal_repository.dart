/// ZIMRA fiscalisation, everything except the cryptographic signing and the QR code. Port of tools/src/fiscal.ts, which is tested.
///
/// Here: building ZIMRA receipts (FiscalInvoice, CreditNote) from sales and returns, the fiscal day, the queue of receipts waiting
/// to be sent, retries and failures, and the day counters for closing the day.
/// Not here, on purpose: the signature and hash (API section 13) and the QR code (section 11) sit behind [Signer]; the HTTPS
/// mutual-TLS client sits behind [Gateway]. Until a real signer written from ZIMRA's official text is installed, [UnavailableSigner]
/// is used and receipts simply stay queued.
///
/// Assumptions A1 to A7 are listed at the top of tools/src/fiscal.ts and must be confirmed in ZIMRA's test environment.
/// Receipts are plain maps with the API's field names. Amounts are doubles with at most two decimals, so a whole amount
/// encodes as 6.0 here where the TypeScript version writes 6; ZIMRA's schema calls them decimals.
library;

import 'dart:convert';
import 'dart:math' as math;

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/money.dart' show convertMinor;

typedef Json = Map<String, Object?>;

class FiscalError implements Exception {
  FiscalError(this.code, this.message);
  final String code, message;
  @override
  String toString() => 'FiscalError($code): $message';
}

/// Thrown by a [Gateway]. [retryable] means try again later (no connection, timeout, HTTP 500 or 502).
class GatewayError implements Exception {
  GatewayError(this.message, {this.status = 0, this.code, this.retryable = false});
  final String message;
  final int status;
  final String? code;
  final bool retryable;
  @override
  String toString() => 'GatewayError($status ${code ?? ''}): $message';
}

class SubmitResult {
  SubmitResult({required this.receiptId, this.serverDate, this.serverSignature, this.validationErrors = const []});
  final int receiptId;
  final String? serverDate;
  final Object? serverSignature;

  /// Each: {validationErrorCode, validationErrorColor} with colours Grey, Red or Yellow (assumption A6).
  final List<Json> validationErrors;
}

abstract class Gateway {
  Future<int> openDay({required String fiscalDayOpened}); // returns fiscalDayNo
  Future<SubmitResult> submitReceipt(Json receipt);
  Future<({bool ok, List<String> errors})> closeDay({required int fiscalDayNo, required List<Json> counters, required Json signature, required int receiptCounter});
}

class SignerUnavailable implements Exception {
  @override
  String toString() => 'Receipt signing is not set up on this phone yet.';
}

abstract class Signer {
  /// False when no real signer is installed: receipts then stay queued and no fiscal day is opened.
  bool get isReady;

  /// The caller has already set receiptCounter and receiptGlobalNo. [previousHash] is null for the first receipt of a day.
  /// Returns {hash, signature}.
  Json signReceipt(Json receipt, String? previousHash);
  Json signDay({required int fiscalDayNo, required String fiscalDayDate, required List<Json> counters});
}

class UnavailableSigner implements Signer {
  const UnavailableSigner();
  @override
  bool get isReady => false;
  @override
  Json signReceipt(Json receipt, String? previousHash) => throw SignerUnavailable();
  @override
  Json signDay({required int fiscalDayNo, required String fiscalDayDate, required List<Json> counters}) => throw SignerUnavailable();
}

class FiscalDevice {
  FiscalDevice(this.deviceId, this.serial, this.registeredAt);
  final int deviceId;
  final String serial;
  final int registeredAt;
}

class FiscalState {
  FiscalState({this.dayNo = 0, this.status = 'closed', this.openedAt, this.date, this.receiptCounter = 0, this.globalNo = 0, this.lastHash, this.lastCloseError});
  final int dayNo, receiptCounter, globalNo;
  final String status; // closed | opened | close_failed
  final int? openedAt;
  final String? date, lastHash, lastCloseError;

  FiscalState copy({int? dayNo, String? status, int? openedAt, String? date, int? receiptCounter, int? globalNo, String? lastHash, bool clearHash = false, String? lastCloseError, bool clearError = false}) => FiscalState(
        dayNo: dayNo ?? this.dayNo,
        status: status ?? this.status,
        openedAt: openedAt ?? this.openedAt,
        date: date ?? this.date,
        receiptCounter: receiptCounter ?? this.receiptCounter,
        globalNo: globalNo ?? this.globalNo,
        lastHash: clearHash ? null : (lastHash ?? this.lastHash),
        lastCloseError: clearError ? null : (lastCloseError ?? this.lastCloseError),
      );

  Json toJson() => {'day_no': dayNo, 'status': status, 'opened_at': openedAt, 'date': date, 'receipt_counter': receiptCounter, 'global_no': globalNo, 'last_hash': lastHash, 'last_close_error': lastCloseError};
  static FiscalState fromJson(Json j) => FiscalState(
        dayNo: (j['day_no'] as num?)?.toInt() ?? 0,
        status: (j['status'] as String?) ?? 'closed',
        openedAt: (j['opened_at'] as num?)?.toInt(),
        date: j['date'] as String?,
        receiptCounter: (j['receipt_counter'] as num?)?.toInt() ?? 0,
        globalNo: (j['global_no'] as num?)?.toInt() ?? 0,
        lastHash: j['last_hash'] as String?,
        lastCloseError: j['last_close_error'] as String?,
      );
}

class TaxSetup {
  TaxSetup(this.taxes, this.map, this.hsDefault);

  /// ZIMRA's taxes from the device's getConfig: {taxID, taxCode, taxName, taxPercent (null = exempt)}.
  final List<Json> taxes;

  /// Tax class id -> ZIMRA taxID.
  final Map<String, int> map;
  final String hsDefault;
}

class QueueDoc {
  QueueDoc({required this.id, required this.saleId, required this.kind, required this.status, required this.attempts, required this.authorityRef, required this.payload, required this.updatedAt});
  final String id, kind, status;
  final String? saleId, authorityRef;
  final int attempts, updatedAt;
  final Json payload;
}

class RunResult {
  int sent = 0, failed = 0, waiting = 0;
  String? stopped; // disabled | no_device | signing_unavailable | offline | day_open_failed
  bool dayTooLong = false;
  final List<({String docId, String code, String message})> problems = [];
  final List<String> validationColors = [];
}

class CloseCheck {
  CloseCheck(this.ok, this.reasons);
  final bool ok;
  final List<String> reasons;
}

String _pad(int n) => n.toString().padLeft(2, '0');

/// A1: local time without a zone.
String zimraDate(int ms, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms + offsetMin * 60000, isUtc: true);
  return '${d.year.toString().padLeft(4, '0')}-${_pad(d.month)}-${_pad(d.day)}T${_pad(d.hour)}:${_pad(d.minute)}:${_pad(d.second)}';
}

/// A1: a decimal number with at most two decimals.
double amt(int minor, int minorUnits) => (minor / math.pow(10, minorUnits) * 100).round() / 100;

const _moneyByKind = {'cash': 'Cash', 'card': 'Card', 'mobile_money': 'MobileWallet', 'bank': 'BankTransfer'};
const _counterOrder = ['SaleByTax', 'CreditNoteByTax', 'DebitNoteByTax', 'SaleTaxByTax', 'CreditNoteTaxByTax', 'DebitNoteTaxByTax', 'BalanceByMoneyType'];
const _moneyOrder = ['Cash', 'Card', 'MobileWallet', 'Coupon', 'Credit', 'BankTransfer', 'Other'];

/// Counters for closing a day, from the receipts sent that day. Zero values are left out. Sorted by type, currency, tax, money type.
List<Json> dayCounters(List<Json> receipts) {
  final m = <String, Json>{};
  void add(Json c, double v) {
    final k = jsonEncode([c['fiscalCounterType'], c['fiscalCounterCurrency'], c['fiscalCounterTaxID'], c['fiscalCounterMoneyType']]);
    final cur = m.putIfAbsent(k, () => {...c, 'fiscalCounterValue': 0.0});
    cur['fiscalCounterValue'] = (((cur['fiscalCounterValue'] as double) + v) * 100).round() / 100;
  }

  for (final r in receipts) {
    final credit = r['receiptType'] == 'CreditNote';
    final cur = r['receiptCurrency'] as String;
    for (final t in (r['receiptTaxes'] as List).cast<Json>()) {
      final base = {'fiscalCounterCurrency': cur, 'fiscalCounterTaxID': t['taxID'], 'fiscalCounterTaxPercent': t['taxPercent']};
      final sales = (t['salesAmountWithTax'] as num).toDouble(), tax = (t['taxAmount'] as num).toDouble();
      add({'fiscalCounterType': credit ? 'CreditNoteByTax' : 'SaleByTax', ...base}, credit ? -sales.abs() : sales);
      add({'fiscalCounterType': credit ? 'CreditNoteTaxByTax' : 'SaleTaxByTax', ...base}, credit ? -tax.abs() : tax);
    }
    for (final p in (r['receiptPayments'] as List).cast<Json>()) {
      final v = (p['paymentAmount'] as num).toDouble();
      add({'fiscalCounterType': 'BalanceByMoneyType', 'fiscalCounterCurrency': cur, 'fiscalCounterMoneyType': p['moneyTypeCode']}, credit ? -v.abs() : v);
    }
  }
  final out = m.values.where((c) => (c['fiscalCounterValue'] as double) != 0).toList();
  int cmp(Json a, Json b) {
    var c = _counterOrder.indexOf(a['fiscalCounterType'] as String).compareTo(_counterOrder.indexOf(b['fiscalCounterType'] as String));
    if (c != 0) return c;
    c = (a['fiscalCounterCurrency'] as String).compareTo(b['fiscalCounterCurrency'] as String);
    if (c != 0) return c;
    c = ((a['fiscalCounterTaxID'] as int?) ?? 0).compareTo((b['fiscalCounterTaxID'] as int?) ?? 0);
    if (c != 0) return c;
    return _moneyOrder.indexOf((a['fiscalCounterMoneyType'] as String?) ?? 'Cash').compareTo(_moneyOrder.indexOf((b['fiscalCounterMoneyType'] as String?) ?? 'Cash'));
  }

  out.sort(cmp);
  return out;
}

class FiscalRepository {
  FiscalRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  static const _hour = 3600000;

  // ---- device and shop settings ----

  Future<Object?> _ds(SqlDb q, String key) async {
    final r = await q.query('select value from device_state where key = ?', [key]);
    if (r.isEmpty) return null;
    try {
      return jsonDecode(r.first['value'] as String);
    } on FormatException {
      return null;
    }
  }

  Future<void> _setDs(SqlDb q, String key, Object? v) =>
      q.exec('insert into device_state (key, value) values (?, ?) on conflict (key) do update set value = excluded.value', [key, jsonEncode(v)]);

  Future<FiscalDevice?> device([SqlDb? q]) async {
    final j = await _ds(q ?? db, 'fiscal_device');
    if (j is! Map) return null;
    return FiscalDevice((j['device_id'] as num).toInt(), j['serial'] as String, (j['registered_at'] as num).toInt());
  }

  Future<FiscalState> state([SqlDb? q]) async {
    final j = await _ds(q ?? db, 'fiscal_state');
    return j is Map ? FiscalState.fromJson(j.cast<String, Object?>()) : FiscalState();
  }

  Future<void> _putState(SqlDb q, FiscalState s) => _setDs(q, 'fiscal_state', s.toJson());

  /// Remembers this phone's ZIMRA device (each till is registered with ZIMRA on its own). The certificate and key live in secure storage, not here.
  Future<FiscalDevice> saveDevice({required int deviceNo, required String serial}) async {
    if (deviceNo <= 0) throw FiscalError('bad_device', 'Enter the device ID ZIMRA gave you.');
    final s = serial.trim();
    if (s.isEmpty || s.length > 60) throw FiscalError('bad_device', 'Enter the device serial number.');
    final now = _clock();
    return db.transaction((tx) async {
      final cur = await device(tx);
      if (cur != null && cur.deviceId != deviceNo && ((await state(tx)).status == 'opened' || await queuedCount(tx) > 0)) {
        throw FiscalError('device_busy', 'Close the fiscal day and send all waiting receipts before changing the device.');
      }
      final d = FiscalDevice(deviceNo, s, cur != null && cur.deviceId == deviceNo ? cur.registeredAt : now);
      await _setDs(tx, 'fiscal_device', {'device_id': d.deviceId, 'serial': d.serial, 'registered_at': d.registeredAt});
      if (cur == null || cur.deviceId != deviceNo) await _putState(tx, FiscalState());
      return d;
    });
  }

  Future<bool> isEnabled([SqlDb? q]) async {
    final r = await (q ?? db).query("select value from settings where scope = 'shop' and key = 'fiscal_enabled' and deleted_at is null");
    return r.isNotEmpty && r.first['value'] == '1';
  }

  Future<void> _insert(SqlDb tx, String table, Json row, int now) async {
    final o = <String, Object?>{'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId, ...row};
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
  }

  Future<bool> _putSetting(SqlDb tx, String key, String value, int now) async {
    final row = await tx.query("select id, value, version from settings where scope = 'shop' and key = ? and deleted_at is null", [key]);
    if (row.isNotEmpty) {
      if (row.first['value'] == value) return false;
      await tx.exec('update settings set value = ?, version = ?, updated_at = ? where id = ?', [value, (row.first['version'] as num).toInt() + 1, now, row.first['id']]);
    } else {
      await _insert(tx, 'settings', {'scope': 'shop', 'key': key, 'value': value, 'updated_at': now, 'version': 1}, now);
    }
    return true;
  }

  /// Turn fiscalisation on or off for the shop. The caller checks that the licence carries the ZIMRA feature.
  Future<void> setEnabled(bool on) async {
    final now = _clock();
    await db.transaction((tx) async {
      final before = await isEnabled(tx);
      if (before == on) return;
      await _putSetting(tx, 'fiscal_enabled', on ? '1' : '0', now);
      await _insert(tx, 'audit_log', {'user_id': userId, 'action': 'fiscal_toggle', 'table_name': 'settings', 'row_id': 'fiscal_enabled', 'before': before ? '1' : '0', 'after': on ? '1' : '0'}, now);
    });
  }

  Future<TaxSetup> taxSetup([SqlDb? q]) async {
    Future<String?> get(String k) async {
      final r = await (q ?? db).query("select value from settings where scope = 'shop' and key = ? and deleted_at is null", [k]);
      return r.isEmpty ? null : r.first['value'] as String?;
    }

    Object? parse(String? s, Object? d) {
      try {
        return s == null ? d : jsonDecode(s);
      } on FormatException {
        return d;
      }
    }

    final taxes = parse(await get('fiscal_taxes'), []);
    final map = parse(await get('fiscal_tax_map'), {});
    return TaxSetup(
      taxes is List ? taxes.whereType<Map>().map((e) => e.cast<String, Object?>()).toList() : [],
      map is Map ? {for (final e in map.entries) e.key as String: (e.value as num).toInt()} : {},
      (await get('fiscal_hs_default')) ?? '',
    );
  }

  /// The shop's own tax classes, for matching them up with ZIMRA's taxes.
  Future<List<({String id, String name, int rateBp})>> taxClasses() async => [
        for (final r in await db.query('select id, name, rate_bp from tax_classes where deleted_at is null order by name'))
          (id: r['id'] as String, name: r['name'] as String, rateBp: (r['rate_bp'] as num).toInt())
      ];

  Future<void> saveTaxSetup({List<Json>? taxes, Map<String, int>? map, String? hsDefault}) async {
    final now = _clock();
    await db.transaction((tx) async {
      if (map != null) {
        final known = {for (final t in (taxes ?? (await taxSetup(tx)).taxes)) (t['taxID'] as num).toInt()};
        for (final e in map.entries) {
          if ((await tx.query('select 1 as x from tax_classes where id = ? and deleted_at is null', [e.key])).isEmpty) throw FiscalError('bad_tax_map', 'A tax class in the list does not exist.');
          if (known.isNotEmpty && !known.contains(e.value)) throw FiscalError('bad_tax_map', "A tax ID is not one of ZIMRA's taxes for this device.");
        }
      }
      if (hsDefault != null && hsDefault != '' && !RegExp(r'^\d{4,8}(\.\d+)?$').hasMatch(hsDefault)) throw FiscalError('bad_hs', 'An HS code is 4 to 8 digits.');
      if (taxes != null) await _putSetting(tx, 'fiscal_taxes', jsonEncode(taxes), now);
      if (map != null) await _putSetting(tx, 'fiscal_tax_map', jsonEncode(map), now);
      if (hsDefault != null) await _putSetting(tx, 'fiscal_hs_default', hsDefault, now);
    });
  }

  // ---- building receipts ----

  Future<int> _units(SqlDb q, String code, Map<String, int> cache) async {
    final c = cache[code];
    if (c != null) return c;
    final r = await q.query('select minor_units from currencies where code = ?', [code]);
    final u = r.isEmpty ? 2 : (r.first['minor_units'] as num).toInt();
    cache[code] = u;
    return u;
  }

  Future<({int taxId, String? taxCode, double? taxPercent})> _taxFor(SqlDb q, TaxSetup setup, String? productId, int? rateBp) async {
    String? cls;
    if (productId != null) {
      final r = await q.query('select tax_class_id from products where id = ?', [productId]);
      cls = r.isEmpty ? null : r.first['tax_class_id'] as String?;
    }
    int? id = cls == null ? null : setup.map[cls];
    if (id == null && cls == null) {
      final hit = setup.taxes.where((t) => ((((t['taxPercent'] as num?) ?? 0).toDouble()) * 100).round() == (rateBp ?? 0)).toList();
      if (hit.length == 1) id = (hit.first['taxID'] as num).toInt();
    }
    if (id == null) throw FiscalError('tax_not_mapped', 'A tax class is not tied to a ZIMRA tax yet. Open Fiscal settings and match them up.');
    final t = setup.taxes.where((x) => (x['taxID'] as num).toInt() == id).toList();
    if (t.isEmpty) throw FiscalError('tax_not_mapped', "The ZIMRA tax chosen for a tax class is not on this device's list. Open Fiscal settings.");
    return (taxId: id, taxCode: t.first['taxCode'] as String?, taxPercent: (t.first['taxPercent'] as num?)?.toDouble());
  }

  List<Json> _group(List<({({int taxId, String? taxCode, double? taxPercent}) tax, int total, int taxMinor})> lines, int u) {
    final m = <int, ({({int taxId, String? taxCode, double? taxPercent}) tax, int sales, int amount})>{};
    for (final l in lines) {
      final g = m[l.tax.taxId];
      m[l.tax.taxId] = (tax: l.tax, sales: (g?.sales ?? 0) + l.total, amount: (g?.amount ?? 0) + l.taxMinor);
    }
    final ids = m.keys.toList()..sort();
    return [
      for (final id in ids)
        {
          'taxID': id,
          'taxAmount': amt(m[id]!.amount, u),
          'salesAmountWithTax': amt(m[id]!.sales, u),
          if (m[id]!.tax.taxCode != null) 'taxCode': m[id]!.tax.taxCode,
          'taxPercent': m[id]!.tax.taxPercent,
        }
    ];
  }

  Future<Json?> _buyer(SqlDb q, String? customerId) async {
    if (customerId == null) return null;
    final r = await q.query('select name from customers where id = ?', [customerId]);
    final n = r.isEmpty ? null : r.first['name'];
    return n is String && n.isNotEmpty ? {'buyerRegisterName': n} : null;
  }

  Future<String> _itemName(SqlDb q, Json line) async {
    final d = ((line['description'] as String?) ?? '').trim();
    var name = d;
    if (name.isEmpty && line['product_id'] != null) {
      final r = await q.query('select name from products where id = ?', [line['product_id']]);
      if (r.isNotEmpty) name = (r.first['name'] as String?) ?? '';
    }
    if (name.isEmpty) name = 'Item';
    return name.length > 200 ? name.substring(0, 200) : name;
  }

  /// A FiscalInvoice for a sale. Throws [FiscalError] when the sale cannot be fiscalised yet (see code).
  Future<Json> buildInvoice(SqlDb q, String saleId, {required int offsetMin, TaxSetup? setup}) async {
    final sr = await q.query('select * from sales where id = ?', [saleId]);
    if (sr.isEmpty) throw FiscalError('sale_missing', 'The sale for this receipt was not found.');
    final sale = sr.first;
    if (sale['status'] == 'layby') throw FiscalError('layby_not_collected', 'A layby is fiscalised when the goods are collected.'); // A7
    final st = setup ?? await taxSetup(q);
    final cache = <String, int>{};
    final cur = sale['sale_currency'] as String;
    final u = await _units(q, cur, cache);
    final lines = <Json>[];
    final taxLines = <({({int taxId, String? taxCode, double? taxPercent}) tax, int total, int taxMinor})>[];
    var n = 0;
    final hs = st.hsDefault.isEmpty ? null : st.hsDefault;
    for (final l in await q.query('select * from sale_lines where sale_id = ? order by created_at, id', [saleId])) {
      final pid = l['product_id'] as String?;
      final tax = await _taxFor(q, st, pid, (l['tax_rate_bp'] as num?)?.toInt());
      var inclusive = true;
      if (pid != null) {
        final r = await q.query('select tc.is_inclusive from products p join tax_classes tc on tc.id = p.tax_class_id where p.id = ?', [pid]);
        if (r.isNotEmpty) inclusive = (r.first['is_inclusive'] as num?)?.toInt() != 0;
      }
      final lineTax = (l['tax_minor'] as num?)?.toInt() ?? 0;
      final discount = (l['discount_minor'] as num?)?.toInt() ?? 0;
      final netOfDiscount = (l['line_total_minor'] as num).toInt() + (inclusive ? 0 : lineTax);
      final gross = netOfDiscount + discount;
      final name = await _itemName(q, l);
      final base = <String, Object?>{'receiptLineName': name, 'taxCode': tax.taxCode, 'taxPercent': tax.taxPercent, 'taxID': tax.taxId};
      lines.add({'receiptLineType': 'Sale', 'receiptLineNo': ++n, if (hs != null) 'receiptLineHSCode': hs, ...base, 'receiptLinePrice': amt((l['unit_price_minor'] as num).toInt(), u), 'receiptLineQuantity': (l['qty_milli'] as num).toInt() / 1000, 'receiptLineTotal': amt(gross, u)});
      if (discount > 0) lines.add({'receiptLineType': 'Discount', 'receiptLineNo': ++n, if (hs != null) 'receiptLineHSCode': hs, ...base, 'receiptLineQuantity': 1, 'receiptLineTotal': -amt(discount, u)}); // A2
      taxLines.add((tax: tax, total: netOfDiscount, taxMinor: lineTax)); // A5
    }
    if (lines.isEmpty) throw FiscalError('no_lines', 'The sale has no items.');
    final total = taxLines.fold<int>(0, (s, x) => s + x.total);
    if (total != (sale['total_minor'] as num).toInt()) throw FiscalError('total_mismatch', "The sale's items do not add up to its total, so it cannot be sent to ZIMRA. Ask support.");

    final paid = <String, int>{};
    for (final p in await q.query('select sp.*, pm.kind from sale_payments sp left join payment_methods pm on pm.code = sp.method_code where sp.sale_id = ?', [saleId])) {
      final pc = p['currency'] as String;
      final amount = (p['amount_minor'] as num).toInt();
      final v = pc == cur ? amount : convertMinor(amount, (p['rate_to_sale_micro'] as num?)?.toInt() ?? 1000000, await _units(q, pc, cache), u);
      final type = _moneyByKind[p['kind']] ?? 'Other';
      paid[type] = (paid[type] ?? 0) + ((p['is_change'] as num?)?.toInt() == 1 ? -v : v);
    }
    var sum = paid.values.fold<int>(0, (a, b) => a + b);
    if (sum < total) {
      paid['Credit'] = (paid['Credit'] ?? 0) + (total - sum);
      sum = total;
    }
    if (sum > total) {
      final big = (paid.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first;
      paid[big.key] = big.value - (sum - total);
    }
    final payments = [for (final e in paid.entries) if (e.value != 0) {'moneyTypeCode': e.key, 'paymentAmount': amt(e.value, u)}];
    final b = await _buyer(q, sale['customer_id'] as String?);
    return {
      'receiptType': 'FiscalInvoice',
      'receiptCurrency': cur,
      'invoiceNo': sale['receipt_no'],
      if (b != null) 'buyerData': b,
      'receiptDate': zimraDate((sale['completed_at'] as num).toInt(), offsetMin),
      'receiptLinesTaxInclusive': true,
      'receiptLines': lines,
      'receiptTaxes': _group(taxLines, u),
      'receiptPayments': payments,
      'receiptTotal': amt(total, u),
      'receiptPrintForm': 'Receipt48',
    };
  }

  /// A CreditNote for a return or a void. [original] is the already sent invoice it refers to: {receiptID, deviceID, receiptGlobalNo, fiscalDayNo}.
  Future<Json> buildCreditNote(SqlDb q, String returnId, Json? original, {required int offsetMin, TaxSetup? setup}) async {
    final rr = await q.query('select * from sale_returns where id = ?', [returnId]);
    if (rr.isEmpty) throw FiscalError('return_missing', 'The return for this credit note was not found.');
    if (original == null) throw FiscalError('original_not_sent', 'The original receipt has not been sent to ZIMRA yet.');
    final ret = rr.first;
    final sale = (await q.query('select * from sales where id = ?', [ret['original_sale_id']])).first;
    final st = setup ?? await taxSetup(q);
    final cache = <String, int>{};
    final cur = sale['sale_currency'] as String;
    final u = await _units(q, cur, cache);
    final hs = st.hsDefault.isEmpty ? null : st.hsDefault;
    final lines = <Json>[];
    final taxLines = <({({int taxId, String? taxCode, double? taxPercent}) tax, int total, int taxMinor})>[];
    var n = 0;
    for (final rl in await q.query('select * from sale_return_lines where return_id = ? order by created_at, id', [returnId])) {
      final l = (await q.query('select * from sale_lines where id = ?', [rl['sale_line_id']])).first;
      final tax = await _taxFor(q, st, l['product_id'] as String?, (l['tax_rate_bp'] as num?)?.toInt());
      final refund = (rl['amount_minor'] as num).toInt();
      final rate = tax.taxPercent ?? 0;
      final taxMinor = ((refund * rate) / (100 + rate)).round();
      lines.add({
        'receiptLineType': 'Sale',
        'receiptLineNo': ++n,
        if (hs != null) 'receiptLineHSCode': hs,
        'receiptLineName': await _itemName(q, l),
        'receiptLinePrice': amt((l['unit_price_minor'] as num).toInt(), u),
        'receiptLineQuantity': (rl['qty_milli'] as num).toInt() / 1000,
        'receiptLineTotal': -amt(refund, u),
        'taxCode': tax.taxCode,
        'taxPercent': tax.taxPercent,
        'taxID': tax.taxId,
      });
      taxLines.add((tax: tax, total: -refund, taxMinor: -taxMinor)); // A3
    }
    if (lines.isEmpty) throw FiscalError('no_lines', 'The return has no items.');
    final total = taxLines.fold<int>(0, (s, x) => s + x.total);
    final paid = <String, int>{};
    for (final p in await q.query('select rp.*, pm.kind from return_payouts rp left join payment_methods pm on pm.code = rp.method_code where rp.return_id = ?', [returnId])) {
      final pc = p['currency'] as String;
      final amount = (p['amount_minor'] as num).toInt();
      final v = pc == cur ? amount : convertMinor(amount, (p['rate_to_sale_micro'] as num?)?.toInt() ?? 1000000, await _units(q, pc, cache), u);
      final type = _moneyByKind[p['kind']] ?? 'Other';
      paid[type] = (paid[type] ?? 0) - v;
    }
    final sum = paid.values.fold<int>(0, (a, b) => a + b);
    if (sum > total) paid['Credit'] = (paid['Credit'] ?? 0) + (total - sum);
    final payments = [for (final e in paid.entries) if (e.value != 0) {'moneyTypeCode': e.key, 'paymentAmount': amt(e.value, u)}];
    final b = await _buyer(q, sale['customer_id'] as String?);
    final reason = ((ret['reason'] as String?) ?? '').trim();
    final cn = original['receiptID'] != null ? {'receiptID': original['receiptID']} : {'deviceID': original['deviceID'], 'receiptGlobalNo': original['receiptGlobalNo'], 'fiscalDayNo': original['fiscalDayNo']};
    return {
      'receiptType': 'CreditNote',
      'receiptCurrency': cur,
      'invoiceNo': ret['receipt_no'],
      if (b != null) 'buyerData': b,
      'receiptNotes': reason.isNotEmpty ? reason : (ret['kind'] == 'void' ? 'Sale voided' : 'Goods returned'),
      'receiptDate': zimraDate((ret['created_at'] as num).toInt(), offsetMin),
      'creditDebitNote': cn,
      'receiptLinesTaxInclusive': true,
      'receiptLines': lines,
      'receiptTaxes': _group(taxLines, u),
      'receiptPayments': payments,
      'receiptTotal': amt(total, u),
      'receiptPrintForm': 'Receipt48',
    };
  }

  // ---- the queue ----

  Json _parse(Object? s) {
    try {
      final j = jsonDecode(s as String);
      return j is Map ? j.cast<String, Object?>() : {};
    } on Object {
      return {};
    }
  }

  Future<List<QueueDoc>> _docs(SqlDb q, String where, [List<Object?> args = const []]) async {
    final rows = await q.query('select * from fiscal_documents where deleted_at is null and $where order by created_at, id', args);
    return [
      for (final r in rows)
        QueueDoc(
          id: r['id'] as String,
          saleId: r['sale_id'] as String?,
          kind: r['kind'] as String,
          status: r['status'] as String,
          attempts: (r['attempts'] as num?)?.toInt() ?? 0,
          authorityRef: r['authority_ref'] as String?,
          payload: _parse(r['payload']),
          updatedAt: (r['updated_at'] as num).toInt(),
        )
    ];
  }

  Future<int> queuedCount([SqlDb? q]) async => (await _docs(q ?? db, "status = 'queued'")).where((d) => d.payload['deferred'] == null).length;

  /// Newest first.
  Future<List<QueueDoc>> listQueue({String? status, int limit = 100}) async {
    final all = status != null ? await _docs(db, 'status = ?', [status]) : await _docs(db, '1 = 1');
    final tail = all.length > limit ? all.sublist(all.length - limit) : all;
    return tail.reversed.toList();
  }

  Future<void> _setDoc(SqlDb q, String id, Map<String, Object?> set, int now) async {
    final cur = await q.query('select version from fiscal_documents where id = ?', [id]);
    final o = <String, Object?>{...set, 'version': (cur.first['version'] as num).toInt() + 1, 'updated_at': now};
    final k = o.keys.toList();
    await q.exec('update fiscal_documents set ${k.map((x) => '"$x" = ?').join(', ')} where id = ?', [...k.map((x) => o[x]), id]);
  }

  /// A failed document goes back to the queue after the cause is fixed (for example a tax class was matched up).
  Future<void> requeue(String docId) async {
    final now = _clock();
    await db.transaction((tx) async {
      final d = (await _docs(tx, 'id = ?', [docId])).firstOrNull;
      if (d == null) throw FiscalError('not_found', 'That document was not found.');
      if (d.status != 'failed') throw FiscalError('not_failed', 'Only a failed document can be sent again.');
      final rest = {...d.payload}..remove('error')..remove('error_code');
      await _setDoc(tx, docId, {'status': 'queued', 'payload': jsonEncode(rest)}, now);
    });
  }

  // ---- the work: open day, send queue, close day ----

  Future<List<Json>> _dayReceipts(SqlDb q, int dayNo) async => [
        for (final d in await _docs(q, "status = 'sent'"))
          if (d.payload['receipt'] is Map && d.payload['fiscalDayNo'] == dayNo) (d.payload['receipt'] as Map).cast<String, Object?>()
      ];

  /// Makes sure a fiscal day is open (asks ZIMRA to open one if not).
  Future<FiscalState> ensureDayOpen(Gateway gw, {required int offsetMin}) async {
    final s = await state();
    if (s.status == 'opened' || s.status == 'close_failed') return s; // a failed close leaves the day open at ZIMRA
    final now = _clock();
    final opened = zimraDate(now, offsetMin);
    final no = await gw.openDay(fiscalDayOpened: opened);
    // A new day restarts the day's receipt counter and the hash chain; the global number keeps counting.
    final next = s.copy(dayNo: no, status: 'opened', openedAt: now, date: opened.substring(0, 10), receiptCounter: 0, clearHash: true, clearError: true);
    await _putState(db, next);
    return next;
  }

  /// Sends the waiting receipts in the order they were made. Reports expected trouble instead of throwing. Sales are never blocked by any of this.
  Future<RunResult> sendQueued(Gateway gw, Signer signer, {required int offsetMin, int? dayMaxHrs}) async {
    final res = RunResult();
    if (!await isEnabled()) return res..stopped = 'disabled';
    final dev = await device();
    if (dev == null) return res..stopped = 'no_device';
    if (!signer.isReady) {
      res.stopped = 'signing_unavailable';
      res.waiting = await queuedCount();
      return res;
    }
    Future<List<QueueDoc>> todo() async => (await _docs(db, "status = 'queued'")).where((d) => d.payload['deferred'] == null).toList();
    final pending = await todo();
    if (pending.isEmpty) return res;
    FiscalState st;
    try {
      st = await ensureDayOpen(gw, offsetMin: offsetMin);
    } on GatewayError catch (e) {
      res.stopped = !e.retryable ? 'day_open_failed' : 'offline';
      res.waiting = pending.length;
      if (!e.retryable) res.problems.add((docId: '', code: e.code ?? 'open_day_failed', message: e.message));
      return res;
    }
    final now0 = _clock();
    if (dayMaxHrs != null && st.openedAt != null && now0 - st.openedAt! > dayMaxHrs * _hour) res.dayTooLong = true;
    final setup = await taxSetup();
    for (final d in pending) {
      final now = _clock();
      Json draft;
      try {
        if (d.kind == 'invoice') {
          if (d.saleId == null) throw FiscalError('sale_missing', 'This receipt has no sale.');
          draft = await buildInvoice(db, d.saleId!, offsetMin: offsetMin, setup: setup);
        } else {
          final retId = '${d.payload['return_id'] ?? ''}';
          final rr = await db.query('select original_sale_id from sale_returns where id = ?', [retId]);
          final orig = rr.isEmpty ? null : (await _docs(db, "kind = 'invoice' and sale_id = ?", [rr.first['original_sale_id']])).firstOrNull;
          if (orig == null) throw FiscalError('original_not_fiscalised', 'The original sale was never sent to ZIMRA (it was made before fiscalisation was switched on), so a credit note cannot be issued.');
          if (orig.status == 'failed') throw FiscalError('original_failed', 'The original receipt failed. Fix it first.');
          final sentRcp = orig.payload['receipt'];
          final ref = orig.status == 'sent' && sentRcp is Map
              ? <String, Object?>{'receiptID': int.tryParse(orig.authorityRef ?? ''), 'deviceID': dev.deviceId, 'receiptGlobalNo': sentRcp['receiptGlobalNo'], 'fiscalDayNo': orig.payload['fiscalDayNo']}
              : null;
          draft = await buildCreditNote(db, retId, ref, offsetMin: offsetMin, setup: setup);
        }
      } on FiscalError catch (e) {
        if (e.code == 'layby_not_collected' || e.code == 'original_not_sent') {
          await _setDoc(db, d.id, {'payload': jsonEncode({...d.payload, 'deferred': e.code})}, now);
          continue;
        }
        await _setDoc(db, d.id, {'status': 'failed', 'attempts': d.attempts + 1, 'payload': jsonEncode({...d.payload, 'error': e.message, 'error_code': e.code})}, now);
        res.failed++;
        res.problems.add((docId: d.id, code: e.code, message: e.message));
        continue;
      }
      // number and sign
      final numbered = <String, Object?>{...draft, 'receiptCounter': st.receiptCounter + 1, 'receiptGlobalNo': st.globalNo + 1};
      Json sig;
      try {
        sig = signer.signReceipt(numbered, st.lastHash);
      } on SignerUnavailable {
        res.stopped = 'signing_unavailable';
        res.waiting = (await todo()).length;
        return res;
      }
      final receipt = <String, Object?>{...numbered, 'receiptDeviceSignature': sig};
      // send
      try {
        final r = await gw.submitReceipt(receipt);
        st = st.copy(receiptCounter: numbered['receiptCounter'] as int, globalNo: numbered['receiptGlobalNo'] as int, lastHash: sig['hash'] as String);
        await _putState(db, st);
        res.validationColors.addAll([for (final v in r.validationErrors) '${v['validationErrorColor']}:${v['validationErrorCode']}']);
        await _setDoc(db, d.id, {
          'status': 'sent',
          'attempts': d.attempts + 1,
          'authority_ref': '${r.receiptId}',
          'sent_at': now,
          'payload': jsonEncode({
            ...d.payload,
            'receipt': receipt,
            'fiscalDayNo': st.dayNo,
            'server': {'date': r.serverDate, 'signature': r.serverSignature},
            'validation': r.validationErrors,
          }),
        }, now);
        res.sent++;
      } on GatewayError catch (e) {
        if (e.retryable) {
          // A4: nothing was used up, so the same numbers are used next time.
          await _setDoc(db, d.id, {'attempts': d.attempts + 1}, now);
          res.stopped = 'offline';
          res.waiting = (await todo()).length;
          return res;
        }
        await _setDoc(db, d.id, {'status': 'failed', 'attempts': d.attempts + 1, 'payload': jsonEncode({...d.payload, 'error': e.message, 'error_code': e.code ?? 'rejected'})}, now);
        res.failed++;
        res.problems.add((docId: d.id, code: e.code ?? 'rejected', message: e.message));
      }
    }
    res.waiting = (await todo()).length;
    return res;
  }

  /// Whether the day can be closed now: it is open, nothing waits or has failed, and no receipt carries a Grey or Red validation mark.
  Future<CloseCheck> canCloseDay([SqlDb? q]) async {
    final c = q ?? db;
    final s = await state(c);
    final reasons = <String>[];
    if (s.status == 'closed') reasons.add('There is no open fiscal day.');
    final waiting = (await _docs(c, "status = 'queued'")).where((d) => d.payload['deferred'] == null).length;
    if (waiting > 0) reasons.add('$waiting receipt${waiting == 1 ? ' is' : 's are'} still waiting to be sent.');
    final failed = (await _docs(c, "status = 'failed'")).length;
    if (failed > 0) reasons.add('$failed receipt${failed == 1 ? ' has' : 's have'} failed. Fix or ask support.');
    final bad = (await _docs(c, "status = 'sent'")).where((d) {
      if (d.payload['fiscalDayNo'] != s.dayNo) return false;
      final v = d.payload['validation'];
      return v is List && v.any((e) => e is Map && (e['validationErrorColor'] == 'Grey' || e['validationErrorColor'] == 'Red'));
    }).length;
    if (bad > 0) reasons.add('$bad receipt${bad == 1 ? ' was' : 's were'} marked by ZIMRA as having a problem. The day cannot be closed until that is dealt with.');
    return CloseCheck(reasons.isEmpty, reasons);
  }

  Future<({bool ok, String message})> closeDay(Gateway gw, Signer signer) async {
    final check = await canCloseDay();
    if (!check.ok) return (ok: false, message: check.reasons.join(' '));
    final s = await state();
    final counters = dayCounters(await _dayReceipts(db, s.dayNo));
    Json sig;
    try {
      sig = signer.signDay(fiscalDayNo: s.dayNo, fiscalDayDate: s.date ?? '', counters: counters);
    } on SignerUnavailable catch (e) {
      return (ok: false, message: '$e');
    }
    try {
      final r = await gw.closeDay(fiscalDayNo: s.dayNo, counters: counters, signature: sig, receiptCounter: s.receiptCounter);
      if (!r.ok) {
        final msg = (r.errors.isEmpty ? ['ZIMRA did not accept the day'] : r.errors).join('; ');
        await _putState(db, s.copy(status: 'close_failed', lastCloseError: msg));
        return (ok: false, message: msg);
      }
      await _putState(db, s.copy(status: 'closed', clearError: true));
      return (ok: true, message: 'Fiscal day ${s.dayNo} closed.');
    } on GatewayError catch (e) {
      if (!e.retryable) await _putState(db, s.copy(status: 'close_failed', lastCloseError: e.message));
      return (ok: false, message: e.retryable ? 'Could not reach ZIMRA. Try again when you have a connection.' : e.message);
    }
  }
}
