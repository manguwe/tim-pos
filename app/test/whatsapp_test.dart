import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/share/whatsapp.dart';

void main() {
  test('numbers are turned into digits with the country code', () {
    expect(normalisePhone('0771 234 567'), '263771234567');
    expect(normalisePhone('+263 77 123 4567'), '263771234567');
    expect(normalisePhone('00263771234567'), '263771234567');
    expect(normalisePhone('0977123456', countryCode: 'ZM'), '260977123456');
    expect(normalisePhone('12'), isNull);
    expect(normalisePhone(''), isNull);
    expect(normalisePhone(null), isNull);
  });

  test('the link carries the text, and works without a number', () {
    expect(whatsappLink('Hi & bye', phone: '0771234567'), 'https://wa.me/263771234567?text=Hi%20%26%20bye');
    expect(whatsappLink('x'), 'https://wa.me/?text=x');
  });
}
