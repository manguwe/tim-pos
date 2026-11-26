import 'dart:convert';
import 'dart:typed_data';

import 'package:ed25519_edwards/ed25519_edwards.dart' as ed;

import '../core/b64url.dart';

const int dayMs = 86400000;

/// What the server signs into the licence. Field names match server/src/licence.ts exactly.
class LicencePayload {
  const LicencePayload({
    required this.licenceId,
    required this.shopId,
    required this.shopName,
    required this.deviceId,
    required this.receiptPrefix,
    required this.plan,
    required this.features,
    required this.maxDevices,
    required this.maxBranches,
    required this.issuedAt,
    required this.expiresAt,
    required this.graceDays,
    required this.maxOfflineDays,
    required this.checkBy,
    this.maxUsers = 0,
    this.legacy = false,
    this.trial = false,
    this.recoveryKey = '',
  });

  final String licenceId;
  final String shopId;
  final String shopName;
  final String deviceId;

  /// Put in front of every receipt number this phone issues, so numbers never clash between phones.
  final String receiptPrefix;
  final String? plan;
  final List<String> features;
  final int maxDevices;
  final int maxBranches;
  final int issuedAt;
  final int expiresAt;
  final int graceDays;
  final int maxOfflineDays;

  /// The phone must reach the server before this time, or it locks.
  final int checkBy;

  /// How many people may be set up to sign in. 0 means no limit.
  final int maxUsers;

  /// True while this is a free trial.
  final bool trial;

  /// Secret that checks PIN reset codes. Empty on a token issued before the feature; the next online refresh brings it.
  final String recoveryKey;

  /// True for a licence issued before plans could switch customers and suppliers on or off. Those shops keep both.
  final bool legacy;

  bool hasFeature(String name) => features.contains(name) || (legacy && (name == 'customers' || name == 'purchasing'));

  factory LicencePayload.fromJson(Map<String, dynamic> j) => LicencePayload(
        licenceId: j['licence_id'] as String,
        shopId: j['shop_id'] as String,
        shopName: j['shop_name'] as String,
        deviceId: j['device_id'] as String,
        receiptPrefix: j['receipt_prefix'] as String,
        plan: j['plan'] as String?,
        features: (j['features'] as List<dynamic>).map((e) => e as String).toList(),
        maxDevices: (j['max_devices'] as num).toInt(),
        maxBranches: (j['max_branches'] as num).toInt(),
        issuedAt: (j['issued_at'] as num).toInt(),
        expiresAt: (j['expires_at'] as num).toInt(),
        graceDays: (j['grace_days'] as num).toInt(),
        maxOfflineDays: (j['max_offline_days'] as num).toInt(),
        checkBy: (j['check_by'] as num).toInt(),
        maxUsers: (j['max_users'] as num?)?.toInt() ?? 0,
        legacy: !j.containsKey('max_users'),
        trial: j['trial'] == true,
        recoveryKey: (j['recovery_key'] as String?) ?? '',
      );
}

enum LicenceStatus { notActivated, active, grace, locked }

enum LockReason { expired, syncOverdue, clockBehind, invalidToken, serverRefused }

class LicenceState {
  const LicenceState._(this.status, {this.reason, this.daysLeft = 0, this.graceDaysLeft = 0, this.expiresSoon = false});

  const LicenceState.notActivated() : this._(LicenceStatus.notActivated);
  const LicenceState.active({required int daysLeft, required bool expiresSoon})
      : this._(LicenceStatus.active, daysLeft: daysLeft, expiresSoon: expiresSoon);
  const LicenceState.grace({required int graceDaysLeft}) : this._(LicenceStatus.grace, graceDaysLeft: graceDaysLeft);
  const LicenceState.locked(LockReason reason) : this._(LicenceStatus.locked, reason: reason);

  final LicenceStatus status;
  final LockReason? reason;
  final int daysLeft;
  final int graceDaysLeft;
  final bool expiresSoon;

  /// Selling and other work is allowed only while active or in grace.
  bool get canWork => status == LicenceStatus.active || status == LicenceStatus.grace;
}

/// Checks the signature with the public key built into the app and returns the payload, or null if
/// anything is wrong. Works fully offline. A token has the form `<body>.<signature>`, both base64url,
/// and the signature is over the body text exactly as written.
LicencePayload? verifyLicenceToken(String token, Uint8List publicKey) {
  try {
    final parts = token.split('.');
    if (parts.length != 2 || parts[0].isEmpty || parts[1].isEmpty) return null;
    final signature = b64uDecode(parts[1]);
    if (signature.length != 64) return null;
    final ok = ed.verify(ed.PublicKey(publicKey), Uint8List.fromList(utf8.encode(parts[0])), signature);
    if (!ok) return null;
    final json = jsonDecode(utf8.decode(b64uDecode(parts[0])));
    if (json is! Map<String, dynamic> || json['v'] != 1) return null;
    return LicencePayload.fromJson(json);
  } catch (_) {
    // A wrong key length, bad base64, bad JSON or a missing field all mean "not a valid licence".
    return null;
  }
}

/// Same rules as evaluateLicence() on the server (server/src/licence.ts).
LicenceState evaluateLicence(LicencePayload p, int nowMs) {
  if (nowMs > p.checkBy) return const LicenceState.locked(LockReason.syncOverdue);
  if (nowMs <= p.expiresAt) {
    final daysLeft = ((p.expiresAt - nowMs) / dayMs).ceil();
    return LicenceState.active(daysLeft: daysLeft, expiresSoon: daysLeft <= 14);
  }
  final graceEnd = p.expiresAt + p.graceDays * dayMs;
  if (nowMs <= graceEnd) {
    return LicenceState.grace(graceDaysLeft: ((graceEnd - nowMs) / dayMs).ceil());
  }
  return const LicenceState.locked(LockReason.expired);
}
