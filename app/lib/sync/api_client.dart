import 'dart:convert';
import 'dart:io' show gzip;

import 'package:http/http.dart' as http;

import '../data/key_value_store.dart';

class ApiResponse {
  const ApiResponse(this.status, this.json);
  final int status;
  final Map<String, dynamic> json;

  /// The server's error code, such as `licence_suspended`, or '' when there is none.
  String get errorCode => (json['error'] is Map ? (json['error'] as Map)['code'] : null) as String? ?? '';
  String get errorMessage => (json['error'] is Map ? (json['error'] as Map)['message'] : null) as String? ?? '';

  /// True when the server is telling this phone to stop working (suspended, expired or removed).
  bool get isLocked => json['error'] is Map && (json['error'] as Map)['locked'] == true;
}

/// Thrown when the server cannot be reached at all: no data, no signal, server down.
class NetworkException implements Exception {
  NetworkException(this.cause);
  final Object cause;
  @override
  String toString() => 'NetworkException: $cause';
}

abstract class ApiTransport {
  Future<ApiResponse> send(String method, String path, {Object? body, bool signedIn = true});
}

class ApiClient implements ApiTransport {
  ApiClient({required this.baseUrl, required this.store, http.Client? client}) : _client = client ?? http.Client();

  final String baseUrl;
  final KeyValueStore store;
  final http.Client _client;

  static const _timeout = Duration(seconds: 40);
  static const _gzipOver = 1024;

  @override
  Future<ApiResponse> send(String method, String path, {Object? body, bool signedIn = true}) async {
    final headers = <String, String>{'accept': 'application/json'};
    if (signedIn) {
      final id = await store.read(Keys.deviceId);
      final secret = await store.read(Keys.deviceSecret);
      if (id == null || secret == null) return const ApiResponse(401, {'error': {'code': 'not_activated'}});
      headers['authorization'] = 'Device $id.$secret';
    }
    final uri = Uri.parse('$baseUrl$path');
    try {
      final http.Response res;
      if (method == 'GET') {
        res = await _client.get(uri, headers: headers).timeout(_timeout);
      } else {
        headers['content-type'] = 'application/json';
        var bytes = utf8.encode(jsonEncode(body ?? {}));
        if (bytes.length > _gzipOver) {
          // Small compressed batches are what keep sync cheap on a data bundle.
          bytes = gzip.encode(bytes);
          headers['content-encoding'] = 'gzip';
        }
        res = await _client.post(uri, headers: headers, body: bytes).timeout(_timeout);
      }
      final text = utf8.decode(res.bodyBytes);
      final decoded = text.isEmpty ? <String, dynamic>{} : jsonDecode(text);
      return ApiResponse(res.statusCode, decoded is Map<String, dynamic> ? decoded : <String, dynamic>{});
    } on FormatException catch (e) {
      throw NetworkException(e); // an answer that is not JSON (for example a hotspot login page)
    } catch (e) {
      throw NetworkException(e);
    }
  }
}
