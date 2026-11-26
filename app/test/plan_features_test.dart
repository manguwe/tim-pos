import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/licence/licence.dart';

Map<String, dynamic> _json({List<String> features = const [], Object? maxUsers = 'absent'}) => {
      'licence_id': 'l', 'shop_id': 's', 'shop_name': 'Shop', 'device_id': 'd', 'receipt_prefix': 'A', 'plan': null,
      'features': features, 'max_devices': 1, 'max_branches': 1, 'issued_at': 1, 'expires_at': 2, 'grace_days': 3,
      'max_offline_days': 4, 'check_by': 5,
      if (maxUsers != 'absent') 'max_users': maxUsers,
    };

void main() {
  test('a plan decides which features a phone has', () {
    final p = LicencePayload.fromJson(_json(features: ['ai'], maxUsers: 3));
    expect(p.hasFeature('ai'), true);
    expect(p.hasFeature('customers'), false);
    expect(p.hasFeature('purchasing'), false);
    expect(p.maxUsers, 3);
    expect(p.legacy, false);
  });

  test('an older licence keeps customers and suppliers until it refreshes', () {
    final p = LicencePayload.fromJson(_json());
    expect(p.legacy, true);
    expect(p.hasFeature('customers'), true);
    expect(p.hasFeature('purchasing'), true);
    expect(p.hasFeature('ai'), false);
    expect(p.maxUsers, 0);
  });
}
