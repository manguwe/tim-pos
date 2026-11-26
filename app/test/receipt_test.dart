import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/printing/receipt.dart';

String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  final v = jsonDecode(File('test/fixtures/receipt_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String k) => (v[k] as List<dynamic>).cast<Map<String, dynamic>>();

  test('text helpers agree with the reference', () {
    for (final e in list('ascii')) {
      expect(ascii(e['s'] as String), e['r'], reason: '$e');
    }
    for (final e in list('wrap')) {
      expect(wrap(e['s'] as String, e['w'] as int), (e['r'] as List<dynamic>).cast<String>(), reason: '$e');
    }
    for (final e in list('row')) {
      expect(row(e['l'] as String, e['r'] as String, e['w'] as int), (e['out'] as List<dynamic>).cast<String>(), reason: '$e');
    }
  });

  test('money text agrees with the reference', () {
    const cur = {'USD': Money('USD', r'$', 2), 'ZiG': Money('ZiG', 'ZiG', 2), 'JPY': Money('JPY', 'Y', 0)};
    for (final e in list('money')) {
      expect(formatMoney(e['a'] as int, cur[e['c']]!), e['r'], reason: '$e');
    }
  });

  test('every layout gives the same preview text and printer bytes as the reference', () {
    final all = list('layouts');
    expect(all.length, greaterThanOrEqualTo(10));
    for (final e in all) {
      final data = ReceiptData.fromJson(e['data'] as Map<String, dynamic>);
      final w = e['width'] as int;
      final items = layoutReceipt(data, width: w, utcOffsetMinutes: e['offset'] as int, openDrawer: e['drawer'] as bool);
      expect(toText(items, w), e['text'], reason: '${e['name']} @ $w');
      expect(hex(toEscPos(items, w)), e['escpos'], reason: '${e['name']} @ $w');
    }
  });

  test('a copy of a receipt is marked as a copy', () {
    final d = ReceiptData.fromJson((list('layouts').first['data']) as Map<String, dynamic>).asCopy();
    expect(toText(layoutReceipt(d, width: width58, utcOffsetMinutes: 0), width58), contains('*** COPY ***'));
  });

  test('the shop can change what the receipt says', () {
    final usual = sampleReceiptText({}, shopName: 'Mbare Mini Market');
    expect(usual.replaceAll(RegExp(r'\s+'), ' '), contains('Mbare Mini Market')); // the name is printed large, so it may wrap
    expect(usual, contains('Cashier'));
    expect(usual, contains('Thank you'));
    final custom = sampleReceiptText(
      {'receipt_shop_name': 'Tendai Store', 'receipt_address': '12 Main St', 'receipt_thanks': 'Come again', 'receipt_show_cashier': '0', 'receipt_show_customer': '0'},
      shopName: 'Mbare Mini Market',
    );
    expect(custom, contains('Tendai Store'));
    expect(custom, contains('12 Main St'));
    expect(custom, contains('Come again'));
    expect(custom, isNot(contains('Mbare Mini Market')));
    expect(custom, isNot(contains('Cashier')));
    expect(custom, isNot(contains('Thank you')));
    expect(sampleReceiptText({'receipt_thanks': ''}, shopName: 'A'), isNot(contains('Thank you')));
  });
}
