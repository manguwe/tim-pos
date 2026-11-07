import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/core/b64url.dart';
import 'package:tim_pos/data/key_value_store.dart';
import 'package:tim_pos/licence/licence.dart';
import 'package:tim_pos/licence/licence_guard.dart';

void main() {
  final v = jsonDecode(File('test/fixtures/licence_vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final key = b64uDecode(v['public_key_raw'] as String);
  final token = v['token'] as String;
  final payload = v['payload'] as Map<String, dynamic>;
  final issued = payload['issued_at'] as int;
  const day = 86400000;

  late MemoryKeyValueStore store;
  late int now;
  late LicenceGuard guard;

  setUp(() {
    store = MemoryKeyValueStore();
    now = issued + 1000;
    guard = LicenceGuard(store: store, publicKey: key, clock: () => now);
  });

  Future<void> activated() async {
    await store.write(Keys.deviceId, 'dev-00000001');
    expect(await guard.acceptToken(token), isTrue);
  }

  test('a new install is not activated', () async {
    expect((await guard.check()).state.status, LicenceStatus.notActivated);
  });

  test('an activated phone works, offline, until the licence ends, then has a grace period, then locks', () async {
    await activated();
    expect((await guard.check()).state.status, LicenceStatus.active);
    now = issued + 33 * day;
    expect((await guard.check()).state.status, LicenceStatus.grace);
    now = issued + 40 * day;
    final s = (await guard.check()).state;
    expect(s.status, LicenceStatus.locked);
    expect(s.reason, LockReason.expired);
  });

  test('a token made for another device is not accepted', () async {
    await store.write(Keys.deviceId, 'some-other-device');
    expect(await guard.acceptToken(token), isFalse);
    expect((await guard.check()).state.status, LicenceStatus.notActivated);
  });

  test('putting the clock back locks the phone until it reaches the server', () async {
    await activated();
    now = issued + 20 * day;
    expect((await guard.check()).state.status, LicenceStatus.active);
    now = issued + 5 * day; // the clock is moved back to stretch the licence
    final s = (await guard.check()).state;
    expect(s.status, LicenceStatus.locked);
    expect(s.reason, LockReason.clockBehind);
    now = issued + 20 * day - 60000; // a minute of drift is fine
    expect((await guard.check()).state.status, LicenceStatus.active);
  });

  test('a small clock correction does not lock the phone', () async {
    await activated();
    now = issued + 10 * day;
    await guard.check();
    now -= 2 * 60 * 1000;
    expect((await guard.check()).state.status, LicenceStatus.active);
  });

  test('the server refusing the licence locks the phone, and a good token unlocks it', () async {
    await activated();
    await guard.markServerRefused('licence_suspended');
    final s = (await guard.check()).state;
    expect(s.reason, LockReason.serverRefused);
    expect(await guard.acceptToken(token), isTrue);
    expect((await guard.check()).state.status, LicenceStatus.active);
  });

  test('a token that is not signed by us is never stored', () async {
    await store.write(Keys.deviceId, 'dev-00000001');
    final bad = (v['bad_tokens'] as Map<String, dynamic>)['body_changed'] as String;
    expect(await guard.acceptToken(bad), isFalse);
    expect(await store.read(Keys.licenceToken), isNull);
  });
}
