import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/selling/money.dart';

void main() {
  final v = jsonDecode(File('test/fixtures/money_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String k) => (v[k] as List<dynamic>).cast<Map<String, dynamic>>();

  test('rounding and arithmetic agree with the reference on every vector', () {
    for (final e in list('div_round')) {
      expect(divRound(e['n'] as int, e['d'] as int), e['r'], reason: '$e');
    }
    for (final e in list('line_amount')) {
      expect(lineAmount(e['qty'] as int, e['price'] as int), e['r'], reason: '$e');
    }
    for (final e in list('tax_split')) {
      final t = taxSplit(e['amount'] as int, e['bp'] as int, e['inclusive'] as bool);
      final r = e['r'] as Map<String, dynamic>;
      expect([t.net, t.tax, t.total], [r['net'], r['tax'], r['total']], reason: '$e');
    }
    for (final e in list('convert')) {
      expect(convertMinor(e['amount'] as int, e['rate'] as int, e['from'] as int, e['to'] as int), e['r'], reason: '$e');
    }
    for (final e in list('invert')) {
      expect(invertRate(e['rate'] as int), e['r'], reason: '$e');
    }
    for (final e in list('round_down')) {
      expect(roundDownTo(e['amount'] as int, e['inc'] as int), e['r'], reason: '$e');
    }
  });

  test('absurd values are refused', () {
    expect(() => lineAmount(1, 1000000000000), throwsA(isA<MoneyError>()));
    expect(() => convertMinor(100, 0, 2, 2), throwsA(isA<MoneyError>()));
    expect(() => divRound(1, 0), throwsA(isA<MoneyError>()));
  });
}
