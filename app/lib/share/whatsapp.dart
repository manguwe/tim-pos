import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// Dialling code to put in front of a local number that starts with 0.
String dialCodeFor(String? countryCode) => switch ((countryCode ?? '').toUpperCase()) {
      'ZM' => '260',
      'ZA' => '27',
      'MW' => '265',
      'MZ' => '258',
      'BW' => '267',
      _ => '263',
    };

/// Turns what a person typed ("0771 234 567", "+263 77...", "00263...") into digits with the country code, or null if it is not usable.
String? normalisePhone(String? raw, {String countryCode = 'ZW'}) {
  if (raw == null) return null;
  var d = raw.replaceAll(RegExp(r'[^\d+]'), '');
  if (d.isEmpty) return null;
  if (d.startsWith('+')) {
    d = d.substring(1);
  } else if (d.startsWith('00')) {
    d = d.substring(2);
  } else if (d.startsWith('0')) {
    d = dialCodeFor(countryCode) + d.substring(1);
  }
  d = d.replaceAll('+', '');
  return RegExp(r'^\d{9,15}$').hasMatch(d) ? d : null;
}

/// A link that opens WhatsApp with the text ready to send. With no number, WhatsApp lets the person pick who gets it.
String whatsappLink(String text, {String? phone, String countryCode = 'ZW'}) {
  final n = normalisePhone(phone, countryCode: countryCode);
  return 'https://wa.me/${n ?? ''}?text=${Uri.encodeComponent(text)}';
}

/// Opens [url]. If the phone cannot, the text is copied so nothing is lost.
Future<void> openOrCopy(BuildContext context, String url, String copyText) async {
  var ok = false;
  try {
    ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  } catch (_) {
    ok = false;
  }
  if (!ok && context.mounted) {
    await Clipboard.setData(ClipboardData(text: copyText));
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not open WhatsApp. The message was copied instead.')));
    }
  }
}
