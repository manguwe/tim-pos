import 'dart:io';
import 'dart:math';

import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

/// Product pictures. A photo is shrunk when it is taken and kept as a small file on this phone.
/// The product row stores only the file name (`products.image_ref`). Sending pictures to the server comes later.
class PhotoStore {
  PhotoStore._();
  static final PhotoStore instance = PhotoStore._();

  Directory? _dir;
  final Map<String, File?> _seen = {};

  Future<Directory> _photos() async {
    final d = _dir;
    if (d != null) return d;
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/product_photos');
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  /// Opens the camera (or the gallery) and returns the saved file name, or null if the person cancelled.
  Future<String?> take({bool gallery = false}) async {
    final x = await ImagePicker().pickImage(
      source: gallery ? ImageSource.gallery : ImageSource.camera,
      maxWidth: 640,
      maxHeight: 640,
      imageQuality: 72,
    );
    if (x == null) return null;
    final dir = await _photos();
    final name = '${DateTime.now().microsecondsSinceEpoch}${Random().nextInt(9999)}.jpg';
    await File(x.path).copy('${dir.path}/$name');
    return name;
  }

  /// Picture names are digits plus .jpg. Anything else is refused, because names also arrive from the server.
  static bool isValid(String? ref) => ref != null && RegExp(r'^[0-9]{10,30}\.jpg$').hasMatch(ref);

  /// Keeps a picture that came from another phone (through the server) under its own name.
  Future<void> saveBytes(String ref, List<int> bytes) async {
    if (!isValid(ref)) return;
    await File('${(await _photos()).path}/$ref').writeAsBytes(bytes, flush: true);
    _seen.remove(ref);
  }

  /// The raw bytes of a picture on this phone, or null.
  Future<List<int>?> bytesOf(String ref) async => (await file(ref))?.readAsBytes();

  /// The picture file for a product, or null when there is none on this phone.
  Future<File?> file(String? ref) async {
    if (!isValid(ref)) return null;
    if (_seen.containsKey(ref) && _seen[ref] != null) return _seen[ref];
    final f = File('${(await _photos()).path}/$ref');
    final found = await f.exists() ? f : null;
    _seen[ref!] = found;
    return found;
  }
}

/// Small preferences that belong to this phone, not to the shop (for example picture grid or list in the till).
class PhonePrefs {
  PhonePrefs._();
  static Future<File> _file(String name) async => File('${(await getApplicationDocumentsDirectory()).path}/pref_$name.txt');

  static Future<String?> read(String name) async {
    try {
      final f = await _file(name);
      return await f.exists() ? (await f.readAsString()).trim() : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String name, String value) async {
    try {
      await (await _file(name)).writeAsString(value);
    } catch (_) {
      // A preference that cannot be saved is not worth stopping the till for.
    }
  }
}
