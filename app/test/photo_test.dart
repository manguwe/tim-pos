import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/photos/photo_store.dart';
import 'package:tim_pos/ui/product_pic.dart';

void main() {
  test('only the phone\'s own picture names are accepted, so a name from the server cannot point elsewhere', () {
    expect(PhotoStore.isValid('17640000000001234.jpg'), true);
    expect(PhotoStore.isValid('../secret.jpg'), false);
    expect(PhotoStore.isValid('a/b.jpg'), false);
    expect(PhotoStore.isValid('123.jpg'), false);
    expect(PhotoStore.isValid('17640000000001234.png'), false);
    expect(PhotoStore.isValid(null), false);
    expect(PhotoStore.isValid(''), false);
  });

  test('a product without a picture shows its first letters', () {
    expect(ProductPic.initials('Mr Rice 5kg'), 'MR');
    expect(ProductPic.initials('Sugar'), 'SU');
    expect(ProductPic.initials('  x '), 'X');
    expect(ProductPic.initials(''), '?');
  });
}
