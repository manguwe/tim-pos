import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Names of the values this app keeps in secure storage.
class Keys {
  static const dbKey = 'db_key';
  static const fingerprint = 'device_fingerprint';
  static const deviceId = 'device_id';
  static const deviceSecret = 'device_secret';
  static const licenceToken = 'licence_token';
  static const lastSeenMs = 'last_seen_ms';
  static const serverLock = 'server_lock';
}

/// Small private storage for secrets. The real one is the Android Keystore; tests use memory.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureKeyValueStore implements KeyValueStore {
  const SecureKeyValueStore([this._s = const FlutterSecureStorage()]);
  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> values = {};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}
