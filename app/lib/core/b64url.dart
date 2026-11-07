import 'dart:convert';
import 'dart:typed_data';

/// base64url without padding, as the server writes it.
Uint8List b64uDecode(String s) => base64Url.decode(base64Url.normalize(s));
