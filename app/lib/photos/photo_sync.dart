import 'dart:convert';

import '../data/sql_db.dart';
import '../sync/api_client.dart';
import 'photo_store.dart';

/// Sends this phone's product pictures to the server and fetches the ones other phones took.
/// It runs after a normal sync. It never stops the sync: if anything goes wrong the pictures simply wait for the next time.
class PhotoSync {
  PhotoSync({required this.api, required this.db, this.perRun = 20});
  final ApiTransport api;
  final SqlDb db;

  /// A few pictures per sync keeps a data bundle safe. The rest follow on the next syncs.
  final int perRun;

  static const _sentPref = 'photos_sent';

  Future<Set<String>> _sent() async => ((await PhonePrefs.read(_sentPref)) ?? '').split('\n').where((s) => s.isNotEmpty).toSet();

  Future<void> run() async {
    final rows = await db.query('select distinct image_ref from products where image_ref is not null and image_ref <> \'\' and deleted_at is null');
    final refs = [for (final r in rows) r['image_ref'] as String].where(PhotoStore.isValid).toList();
    if (refs.isEmpty) return;
    final sent = await _sent();
    var changed = false;
    var budget = perRun;
    for (final ref in refs) {
      if (budget <= 0) break;
      final bytes = await PhotoStore.instance.bytesOf(ref);
      if (bytes != null) {
        if (sent.contains(ref)) continue;
        budget--;
        final res = await api.send('POST', '/v1/photos', body: {'name': ref, 'data': base64Encode(bytes)});
        // 200 means the server has it. Any other answer (too large, not a picture) is not worth trying again every time.
        if (res.status == 200 || res.status == 400 || res.status == 413) {
          sent.add(ref);
          changed = true;
        }
      } else {
        budget--;
        final res = await api.send('GET', '/v1/photos/$ref');
        final data = res.json['data'];
        if (res.status == 200 && data is String) {
          await PhotoStore.instance.saveBytes(ref, base64Decode(data));
          sent.add(ref);
          changed = true;
        }
        // 404: the phone that took it has not sent it yet. Try again next time.
      }
    }
    if (changed) await PhonePrefs.write(_sentPref, sent.join('\n'));
  }
}
