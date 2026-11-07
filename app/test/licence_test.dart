import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/core/b64url.dart';
import 'package:tim_pos/licence/licence.dart';

/// These vectors are made by the real server code (npm run -s gen in tools/), so passing here means
/// the phone and the server agree on the signature format and on every date rule.
void main() {
  final v = jsonDecode(File('test/fixtures/licence_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final key = b64uDecode(v['public_key_raw'] as String);
  final token = v['token'] as String;

  test('a token signed by the server verifies offline, including non-ASCII shop names', () {
    final p = verifyLicenceToken(token, key);
    expect(p, isNotNull);
    expect(p!.shopName, 'Mbare Mini Market — Café');
    expect(p.receiptPrefix, 'D1');
    expect(p.deviceId, 'dev-00000001');
    expect(p.features, ['multi_currency', 'credit']);
    expect(p.hasFeature('credit'), isTrue);
    expect(p.checkBy, (v['payload'] as Map)['check_by']);
  });

  test('a token is refused under another key, or if any part was touched', () {
    expect(verifyLicenceToken(token, b64uDecode(v['other_public_key_raw'] as String)), isNull);
    for (final e in (v['bad_tokens'] as Map<String, dynamic>).entries) {
      expect(verifyLicenceToken(e.value as String, key), isNull, reason: e.key);
    }
  });

  test('a key of the wrong length is a refusal, not a crash', () {
    expect(verifyLicenceToken(token, Uint8List(5)), isNull);
    expect(verifyLicenceToken(token, Uint8List(0)), isNull);
  });

  test('every date rule gives the same answer as the server', () {
    final p = verifyLicenceToken(token, key)!;
    for (final e in (v['evaluations'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final want = e['expected'] as Map<String, dynamic>;
      final got = evaluateLicence(p, e['now'] as int);
      final name = e['name'];
      switch (want['state']) {
        case 'active':
          expect(got.status, LicenceStatus.active, reason: '$name');
          expect(got.daysLeft, want['days_left'], reason: '$name');
          expect(got.expiresSoon, want['expires_soon'], reason: '$name');
        case 'grace':
          expect(got.status, LicenceStatus.grace, reason: '$name');
          expect(got.graceDaysLeft, want['grace_days_left'], reason: '$name');
        case 'locked':
          expect(got.status, LicenceStatus.locked, reason: '$name');
          expect(got.reason, want['reason'] == 'expired' ? LockReason.expired : LockReason.syncOverdue, reason: '$name');
        default:
          fail('unknown state in vectors: ${want['state']}');
      }
      expect(got.canWork, want['state'] != 'locked', reason: '$name');
    }
  });
}
