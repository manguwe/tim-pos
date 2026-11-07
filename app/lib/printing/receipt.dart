/// Receipts. Port of tools/src/receipt.ts; both are checked against the same vectors (test/fixtures/receipt_vectors.json).
///
/// loadReceipt  reads a saved sale into plain data
/// layoutReceipt  turns the data into styled lines for a paper width
/// toText / toEscPos  the on-screen preview, or the bytes a thermal printer understands
library;

import 'dart:typed_data';

import '../data/sql_db.dart';
import '../selling/money.dart';

const int width58 = 32;
const int width80 = 48;

class Money {
  const Money(this.code, this.symbol, this.minorUnits);
  final String code;
  final String symbol;
  final int minorUnits;
}

class ReceiptLine {
  const ReceiptLine({required this.description, required this.qtyMilli, required this.unitPriceMinor, required this.discountMinor, required this.taxRateBp, required this.lineTotalMinor});
  final String description;
  final int qtyMilli;
  final int unitPriceMinor;
  final int discountMinor;
  final int taxRateBp;
  final int lineTotalMinor;
}

class ReceiptPayment {
  const ReceiptPayment({required this.methodName, required this.currency, required this.amountMinor, required this.rateToSaleMicro, required this.reference, required this.isChange});
  final String methodName;
  final String currency;
  final int amountMinor;
  final int rateToSaleMicro;
  final String? reference;
  final bool isChange;
}

class ReceiptData {
  const ReceiptData({
    required this.shopName, this.branchName, this.branchAddress, this.branchPhone, this.taxNumber,
    required this.receiptNo, this.kind = 'sale', required this.completedAt, this.cashier, this.customer, required this.status,
    required this.saleCurrency, required this.subtotalMinor, required this.discountMinor, required this.taxMinor, required this.totalMinor,
    required this.lines, required this.payments, this.creditMinor = 0, required this.currencies, this.header, this.footer,
  });
  final String shopName;
  final String? branchName, branchAddress, branchPhone, taxNumber;
  final String receiptNo;
  final String kind; // 'sale' or 'copy'
  final int completedAt;
  final String? cashier, customer;
  final String status;
  final String saleCurrency;
  final int subtotalMinor, discountMinor, taxMinor, totalMinor;
  final List<ReceiptLine> lines;
  final List<ReceiptPayment> payments;
  final int creditMinor;
  final Map<String, Money> currencies;
  final String? header, footer;

  ReceiptData asCopy() => ReceiptData(
        shopName: shopName, branchName: branchName, branchAddress: branchAddress, branchPhone: branchPhone, taxNumber: taxNumber,
        receiptNo: receiptNo, kind: 'copy', completedAt: completedAt, cashier: cashier, customer: customer, status: status,
        saleCurrency: saleCurrency, subtotalMinor: subtotalMinor, discountMinor: discountMinor, taxMinor: taxMinor, totalMinor: totalMinor,
        lines: lines, payments: payments, creditMinor: creditMinor, currencies: currencies, header: header, footer: footer,
      );

  /// Reads the JSON shape the test vectors use (same field names as the TypeScript reference).
  factory ReceiptData.fromJson(Map<String, dynamic> j) {
    String? s(String k) => j[k] as String?;
    return ReceiptData(
      shopName: j['shop_name'] as String, branchName: s('branch_name'), branchAddress: s('branch_address'), branchPhone: s('branch_phone'), taxNumber: s('tax_number'),
      receiptNo: j['receipt_no'] as String, kind: j['kind'] as String, completedAt: j['completed_at'] as int, cashier: s('cashier'), customer: s('customer'), status: j['status'] as String,
      saleCurrency: j['sale_currency'] as String, subtotalMinor: j['subtotal_minor'] as int, discountMinor: j['discount_minor'] as int, taxMinor: j['tax_minor'] as int, totalMinor: j['total_minor'] as int,
      lines: (j['lines'] as List<dynamic>).cast<Map<String, dynamic>>().map((l) => ReceiptLine(
            description: l['description'] as String, qtyMilli: l['qty_milli'] as int, unitPriceMinor: l['unit_price_minor'] as int,
            discountMinor: l['discount_minor'] as int, taxRateBp: l['tax_rate_bp'] as int, lineTotalMinor: l['line_total_minor'] as int)).toList(),
      payments: (j['payments'] as List<dynamic>).cast<Map<String, dynamic>>().map((p) => ReceiptPayment(
            methodName: p['method_name'] as String, currency: p['currency'] as String, amountMinor: p['amount_minor'] as int,
            rateToSaleMicro: p['rate_to_sale_micro'] as int, reference: p['reference'] as String?, isChange: p['is_change'] as bool)).toList(),
      creditMinor: j['credit_minor'] as int,
      currencies: (j['currencies'] as Map<String, dynamic>).map((k, v) {
        final m = v as Map<String, dynamic>;
        return MapEntry(k, Money(m['code'] as String, m['symbol'] as String, m['minor_units'] as int));
      }),
      header: s('header'), footer: s('footer'),
    );
  }
}

enum Align { left, center, right }

enum ItemKind { text, rule, feed, drawer, cut, barcode }

class Item {
  const Item.text(this.text, {this.align = Align.left, this.bold = false, this.big = false})
      : kind = ItemKind.text,
        n = 0;
  const Item.rule()
      : kind = ItemKind.rule, text = '', align = Align.left, bold = false, big = false, n = 0;
  const Item.feed(this.n)
      : kind = ItemKind.feed, text = '', align = Align.left, bold = false, big = false;
  const Item.drawer()
      : kind = ItemKind.drawer, text = '', align = Align.left, bold = false, big = false, n = 0;
  const Item.barcode(this.text)
      : kind = ItemKind.barcode, align = Align.left, bold = false, big = false, n = 0;
  const Item.cut()
      : kind = ItemKind.cut, text = '', align = Align.left, bold = false, big = false, n = 0;
  final ItemKind kind;
  final String text;
  final Align align;
  final bool bold;
  final bool big;
  final int n;
}

// ---- text helpers ----

// Dart has no built-in accent stripping, so the common Latin letters are listed. Anything else becomes '?'.
const String _accentFrom = 'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿŠšŽžČčĆćĐđĚěŘřŇňŤťŮůŁłŃńŚśŹźŻżĄąĘęŐőŰű';
const String _accentTo = 'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOOooooooUUUUuuuuYyySsZzCcCcDdEeRrNnTtUuLlNnSsZzZzAaEeOoUu';

String ascii(String s) {
  final b = StringBuffer();
  for (final u in s.codeUnits) {
    final i = u > 0x7e ? _accentFrom.indexOf(String.fromCharCode(u)) : -1;
    if (i >= 0) {
      b.write(_accentTo[i]);
    } else if (u == 0x2018 || u == 0x2019) {
      b.write("'");
    } else if (u == 0x201c || u == 0x201d) {
      b.write('"');
    } else if (u == 0x2013 || u == 0x2014) {
      b.write('-');
    } else if (u >= 0x20 && u <= 0x7e) {
      b.writeCharCode(u);
    } else {
      b.write('?');
    }
  }
  return b.toString();
}

List<String> wrap(String text, int width) {
  final out = <String>[];
  for (final para in text.split('\n').map(ascii)) {
    var line = '';
    for (final word in para.split(RegExp(r'\s+')).where((w) => w.isNotEmpty)) {
      var w = word;
      while (w.length > width) {
        if (line.isNotEmpty) {
          out.add(line);
          line = '';
        }
        out.add(w.substring(0, width));
        w = w.substring(width);
      }
      if (line.isEmpty) {
        line = w;
      } else if (line.length + 1 + w.length <= width) {
        line += ' $w';
      } else {
        out.add(line);
        line = w;
      }
    }
    out.add(line);
  }
  return out;
}

/// Left text and right text on one row; the left wraps when it does not fit and the right sits on its last line.
List<String> row(String left, String right, int width) {
  final r = ascii(right);
  final room = width - r.length - 1;
  if (room < 4) return [...wrap(left, width), r.padLeft(width)];
  final l = wrap(left, room);
  final last = l.isEmpty ? '' : l.removeLast();
  return [...l, last.padRight(width - r.length) + r];
}

String _group(int whole) {
  final s = whole.toString();
  final b = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) b.write(',');
    b.write(s[i]);
  }
  return b.toString();
}

String formatMoney(int minor, Money m) {
  final neg = minor < 0;
  final a = minor.abs();
  var p = 1;
  for (var i = 0; i < m.minorUnits; i++) {
    p *= 10;
  }
  final whole = _group(a ~/ p);
  final frac = m.minorUnits == 0 ? '' : '.${(a % p).toString().padLeft(m.minorUnits, '0')}';
  final sym = m.symbol.length > 1 ? '${m.symbol} ' : m.symbol;
  return '${neg ? '-' : ''}$sym$whole$frac';
}

String _qtyText(int milli) {
  if (milli % 1000 == 0) return (milli ~/ 1000).toString();
  final a = milli.abs();
  final frac = (a % 1000).toString().padLeft(3, '0').replaceFirst(RegExp(r'0+$'), '');
  return '${milli < 0 ? '-' : ''}${a ~/ 1000}.$frac';
}

String _rateText(int bp) {
  if (bp % 100 == 0) return '${bp ~/ 100}%';
  final frac = (bp.abs() % 100).toString().padLeft(2, '0').replaceFirst(RegExp(r'0$'), '');
  return '${bp ~/ 100}.$frac%';
}

String dateText(int ms, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms + offsetMin * 60000, isUtc: true);
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
}

/// "1 USD = 26.50 ZiG" from the stored rate (millionths of the sale currency per one unit of the paid currency).
String _formatRate(int rateToSaleMicro, String saleCur, String paidCur) {
  if (rateToSaleMicro <= 0) return '';
  final cents = (1000000000000 / rateToSaleMicro / 10000).round();
  return '1 $saleCur = ${cents ~/ 100}.${(cents % 100).toString().padLeft(2, '0')} $paidCur';
}

// ---- layout ----

List<Item> layoutReceipt(ReceiptData d, {required int width, required int utcOffsetMinutes, bool openDrawer = false, bool cut = true}) {
  final w = width;
  final items = <Item>[];
  void text(String s, {Align align = Align.left, bool bold = false, bool big = false}) {
    for (final l in wrap(s, big ? w ~/ 2 : w)) {
      items.add(Item.text(l, align: align, bold: bold, big: big));
    }
  }

  void rows(String l, String r, {bool bold = false}) {
    for (final s in row(l, r, w)) {
      items.add(Item.text(s, bold: bold));
    }
  }

  void rule() => items.add(const Item.rule());
  Money cur(String code) => d.currencies[code] ?? Money(code, code, 2);
  String money(int minor, [String? code]) => formatMoney(minor, cur(code ?? d.saleCurrency));

  if (openDrawer) items.add(const Item.drawer());
  text(d.shopName, align: Align.center, bold: true, big: true);
  if (_has(d.branchName)) text(d.branchName!, align: Align.center);
  if (_has(d.branchAddress)) text(d.branchAddress!, align: Align.center);
  if (_has(d.branchPhone)) text('Tel ${d.branchPhone}', align: Align.center);
  if (_has(d.taxNumber)) text('VAT/BP No: ${d.taxNumber}', align: Align.center);
  if (_has(d.header)) text(d.header!, align: Align.center);
  rule();
  rows('Receipt', d.receiptNo, bold: true);
  rows('Date', dateText(d.completedAt, utcOffsetMinutes));
  if (_has(d.cashier)) rows('Cashier', d.cashier!);
  if (_has(d.customer)) rows('Customer', d.customer!);
  if (d.kind == 'copy') text('*** COPY ***', align: Align.center, bold: true);
  if (d.status == 'voided') text('*** VOIDED ***', align: Align.center, bold: true);
  rule();

  for (final l in d.lines) {
    text(l.description);
    rows('  ${_qtyText(l.qtyMilli)} x ${money(l.unitPriceMinor)}', money(lineAmount(l.qtyMilli, l.unitPriceMinor)));
    if (l.discountMinor > 0) rows('  Discount', '-${money(l.discountMinor)}');
  }
  rule();

  if (d.taxMinor > 0) {
    rows('Subtotal (excl. tax)', money(d.subtotalMinor));
    final rates = d.lines.where((l) => l.taxRateBp > 0).map((l) => l.taxRateBp).toSet();
    rows(rates.length == 1 ? 'Tax ${_rateText(rates.first)}' : 'Tax', money(d.taxMinor));
  }
  if (d.discountMinor > 0) rows('Discounts given', money(d.discountMinor));
  for (final s in row('TOTAL', money(d.totalMinor), w ~/ 2)) {
    items.add(Item.text(s, bold: true, big: true));
  }

  final paid = d.payments.where((p) => !p.isChange).toList();
  final change = d.payments.where((p) => p.isChange).toList();
  if (paid.isNotEmpty) {
    rule();
    for (final p in paid) {
      final same = p.currency == d.saleCurrency;
      rows(p.methodName + (same ? '' : ' ${p.currency}'), money(p.amountMinor, p.currency));
      if (!same) text('  ${_formatRate(p.rateToSaleMicro, d.saleCurrency, p.currency)}');
      if (_has(p.reference)) text('  Ref ${p.reference}');
    }
    for (final c in change) {
      rows('Change', money(c.amountMinor, c.currency), bold: true);
    }
  }
  if (d.creditMinor > 0) {
    rule();
    rows('On account', money(d.creditMinor), bold: true);
  }
  if (_has(d.footer)) {
    rule();
    text(d.footer!, align: Align.center);
  }
  text('Thank you', align: Align.center);
  items.add(const Item.feed(3));
  if (cut) items.add(const Item.cut());
  return items;
}

bool _has(String? s) => s != null && s.isNotEmpty;

// ---- renderers ----

String toText(List<Item> items, int width) {
  final out = <String>[];
  for (final it in items) {
    switch (it.kind) {
      case ItemKind.rule:
        out.add('-' * width);
      case ItemKind.feed:
        for (var i = 0; i < it.n; i++) {
          out.add('');
        }
      case ItemKind.text:
        final w = it.big ? width ~/ 2 : width;
        final pad = it.align == Align.center ? (w - it.text.length) ~/ 2 : it.align == Align.right ? w - it.text.length : 0;
        out.add((pad > 0 ? ' ' * pad : '') + it.text);
      case ItemKind.barcode:
        final pad = (width - it.text.length - 10) ~/ 2;
        out.add('${pad > 0 ? ' ' * pad : ''}|||| ${it.text} ||||');
      case ItemKind.drawer:
      case ItemKind.cut:
        break;
    }
  }
  return '${out.join('\n')}\n';
}

/// Raw ESC/POS bytes for a thermal printer.
Uint8List toEscPos(List<Item> items, int width) {
  const esc = 0x1b, gs = 0x1d, lf = 0x0a;
  final b = <int>[esc, 0x40, esc, 0x74, 0x00]; // initialise, code page 437
  var align = Align.left, bold = false, big = false;
  for (final it in items) {
    switch (it.kind) {
      case ItemKind.text:
        if (it.align != align) {
          b.addAll([esc, 0x61, it.align.index]);
          align = it.align;
        }
        if (it.bold != bold) {
          b.addAll([esc, 0x45, it.bold ? 1 : 0]);
          bold = it.bold;
        }
        if (it.big != big) {
          b.addAll([gs, 0x21, it.big ? 0x11 : 0x00]);
          big = it.big;
        }
        b.addAll(it.text.codeUnits);
        b.add(lf);
      case ItemKind.rule:
        if (align != Align.left) {
          b.addAll([esc, 0x61, 0]);
          align = Align.left;
        }
        if (big) {
          b.addAll([gs, 0x21, 0x00]);
          big = false;
        }
        b.addAll(List.filled(width, 0x2d));
        b.add(lf);
      case ItemKind.feed:
        for (var i = 0; i < it.n; i++) {
          b.add(lf);
        }
      case ItemKind.barcode:
        if (align != Align.center) {
          b.addAll([esc, 0x61, 1]);
          align = Align.center;
        }
        b.addAll([gs, 0x68, 80, gs, 0x48, 2]); // 80 dots high, number printed under the bars
        final c = it.text;
        if (RegExp(r'^\d{13}$').hasMatch(c)) {
          b.addAll([gs, 0x77, 2, gs, 0x6b, 2, ...c.substring(0, 12).codeUnits, 0]);
        } else if (RegExp(r'^\d{8}$').hasMatch(c)) {
          b.addAll([gs, 0x77, 2, gs, 0x6b, 3, ...c.substring(0, 7).codeUnits, 0]);
        } else {
          final dots = width >= 48 ? 576 : 384;
          b.addAll([gs, 0x77, (11 * (c.length + 3) + 13) * 2 <= dots ? 2 : 1, gs, 0x6b, 73, c.length + 2, 0x7b, 0x42, ...c.codeUnits]);
        }
        b.add(lf);
      case ItemKind.drawer:
        b.addAll([esc, 0x70, 0x00, 0x19, 0xfa]);
      case ItemKind.cut:
        b.addAll([gs, 0x56, 0x42, 0x03]);
    }
  }
  b.addAll([esc, 0x61, 0, esc, 0x45, 0, gs, 0x21, 0x00]);
  return Uint8List.fromList(b);
}

// ---- reading a saved sale ----

Future<ReceiptData> loadReceipt(SqlDb db, String saleId, {String kind = 'sale'}) async {
  Future<Map<String, Object?>?> get(String sql, [List<Object?> a = const []]) async {
    final r = await db.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  final s = await get('select * from sales where id = ?', [saleId]);
  if (s == null) throw StateError('sale not found');
  final shop = await get('select * from shops where deleted_at is null limit 1') ?? <String, Object?>{};
  final branch = await get('select * from branches where id = ?', [s['branch_id']]);
  Future<String?> setting(String k) async =>
      (await get("select value from settings where scope = 'shop' and key = ? and deleted_at is null", [k]))?['value'] as String?;
  final methods = {for (final m in await db.query('select code, name from payment_methods')) m['code'] as String: m['name'] as String};
  final currencies = <String, Money>{
    for (final c in await db.query('select code, symbol, minor_units from currencies'))
      c['code'] as String: Money(c['code'] as String, (c['symbol'] as String?) ?? c['code'] as String, c['minor_units'] as int),
  };
  final pays = await db.query('select * from sale_payments where sale_id = ? order by is_change, created_at, rowid', [saleId]);
  final owed = (await get("select coalesce(sum(amount_minor), 0) as c from customer_ledger where ref_type = 'sale' and ref_id = ? and type = 'credit_sale'", [saleId]))?['c'] as int? ?? 0;
  final userId = s['user_id'] as String?;
  final customerId = s['customer_id'] as String?;
  final lines = await db.query('select * from sale_lines where sale_id = ? order by created_at, rowid', [saleId]);
  return ReceiptData(
    shopName: (shop['name'] as String?) ?? '', branchName: branch?['name'] as String?, branchAddress: branch?['address'] as String?, branchPhone: branch?['phone'] as String?,
    taxNumber: shop['tax_registered'] == 1 ? shop['tax_number'] as String? : null,
    receiptNo: s['receipt_no'] as String, kind: kind, completedAt: s['completed_at'] as int,
    cashier: userId == null ? null : (await get('select name from users where id = ?', [userId]))?['name'] as String?,
    customer: customerId == null ? null : (await get('select name from customers where id = ?', [customerId]))?['name'] as String?,
    status: await get('select 1 as x from sale_voids where sale_id = ?', [saleId]) != null ? 'voided' : s['status'] as String, saleCurrency: s['sale_currency'] as String,
    subtotalMinor: s['subtotal_minor'] as int, discountMinor: s['discount_minor'] as int, taxMinor: s['tax_minor'] as int, totalMinor: s['total_minor'] as int,
    lines: [
      for (final l in lines)
        ReceiptLine(
          description: (l['description'] as String?) ?? '', qtyMilli: l['qty_milli'] as int, unitPriceMinor: l['unit_price_minor'] as int,
          discountMinor: (l['discount_minor'] as int?) ?? 0, taxRateBp: (l['tax_rate_bp'] as int?) ?? 0, lineTotalMinor: l['line_total_minor'] as int),
    ],
    payments: [
      for (final p in pays)
        ReceiptPayment(
          methodName: methods[p['method_code']] ?? p['method_code'] as String, currency: p['currency'] as String, amountMinor: p['amount_minor'] as int,
          rateToSaleMicro: (p['rate_to_sale_micro'] as int?) ?? 1000000, reference: p['reference'] as String?, isChange: p['is_change'] == 1),
    ],
    creditMinor: owed, currencies: currencies, header: await setting('receipt_header'), footer: await setting('receipt_footer'),
  );
}
