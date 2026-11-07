import 'dart:typed_data';

import '../data/key_value_store.dart';
import 'licence.dart';

/// What the app knows about its licence right now.
class LicenceView {
  const LicenceView(this.state, {this.payload});
  final LicenceState state;
  final LicencePayload? payload;
}

/// Decides whether this phone may work. Everything here runs offline.
///
/// Rules: the token must be signed by us and made for this phone; its dates are checked against the
/// clock; and if the clock has been put back (to stretch an expired licence) the app locks until it
/// next reaches the server and gets a freshly signed token.
class LicenceGuard {
  LicenceGuard({required this.store, required this.publicKey, int Function()? clock})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);

  final KeyValueStore store;
  final Uint8List publicKey;
  final int Function() _clock;

  /// How far behind the last time the app saw the clock is still accepted (clocks drift, time zones are fixed up).
  static const int clockSlackMs = 5 * 60 * 1000;

  Future<LicenceView> check() async {
    final token = await store.read(Keys.licenceToken);
    final deviceId = await store.read(Keys.deviceId);
    if (token == null || deviceId == null) return const LicenceView(LicenceState.notActivated());

    final payload = verifyLicenceToken(token, publicKey);
    if (payload == null || payload.deviceId != deviceId) {
      return const LicenceView(LicenceState.locked(LockReason.invalidToken));
    }

    final now = _clock();
    final lastSeen = int.tryParse(await store.read(Keys.lastSeenMs) ?? '') ?? 0;
    if (now < lastSeen - clockSlackMs) {
      return LicenceView(const LicenceState.locked(LockReason.clockBehind), payload: payload);
    }
    if (now > lastSeen) await store.write(Keys.lastSeenMs, '$now');

    if (await store.read(Keys.serverLock) != null) {
      return LicenceView(const LicenceState.locked(LockReason.serverRefused), payload: payload);
    }
    return LicenceView(evaluateLicence(payload, now), payload: payload);
  }

  /// Keeps a token the server just sent, if it is genuine, for this phone, and not older than the one we hold.
  /// The token's own issue time becomes the new "last seen" time, because it is signed and cannot be faked,
  /// which is what lets a phone with a wrong clock recover once it reaches the server.
  Future<bool> acceptToken(String token) async {
    final deviceId = await store.read(Keys.deviceId);
    final payload = verifyLicenceToken(token, publicKey);
    if (payload == null || deviceId == null || payload.deviceId != deviceId) return false;
    final current = await store.read(Keys.licenceToken);
    final held = current == null ? null : verifyLicenceToken(current, publicKey);
    if (held != null && payload.issuedAt < held.issuedAt) return false;
    await store.write(Keys.licenceToken, token);
    await store.write(Keys.lastSeenMs, '${payload.issuedAt}');
    await store.delete(Keys.serverLock);
    return true;
  }

  /// The server said no (suspended, expired, device removed). Lock until a good token arrives.
  Future<void> markServerRefused(String code) => store.write(Keys.serverLock, code);
}
