import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'theme.dart';

/// Who built TIM-POS and how to reach him. Needs no sign-in rights and works offline (the buttons need a connection or a signal).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const whatsappUrl = 'https://wa.me/260768648291';
  static const callNumber = '+263774348204';
  static const supportPhone = '+260768648291';
  static const webUrl = 'https://timtiml-website.vercel.app';
  static const email = 'anotida30manguwe12@gmail.com';

  Future<void> _open(BuildContext context, String url, String fallbackText) async {
    var ok = false;
    try {
      ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
    if (!ok && context.mounted) {
      await Clipboard.setData(ClipboardData(text: fallbackText));
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open it. Copied: $fallbackText')));
      }
    }
  }

  Widget _row(BuildContext context, IconData icon, Color color, String title, String sub, String url, String copy) => Card(
        margin: const EdgeInsets.only(bottom: 10),
        child: ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          leading: CircleAvatar(backgroundColor: color.withValues(alpha: 0.15), child: Icon(icon, color: color)),
          title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          subtitle: Text(sub),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _open(context, url, copy),
        ),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Help and contact')),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          const Center(child: BrandLogo(size: 72)),
          const SizedBox(height: 10),
          const Text('TIM-POS', textAlign: TextAlign.center, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          const Text('Point of sale for shops', textAlign: TextAlign.center),
          const SizedBox(height: 20),
          const Text('About the developer', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'TIM-POS is built by Anotida Manguwe (timtiml), a BSc ICT student at Eden University in Zambia. '
            'He builds practical software and works on security, cloud and AI-assisted solutions. '
            'His tagline: "Building ideas into practical technology solutions."',
          ),
          const SizedBox(height: 20),
          const Text('Need help?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text('WhatsApp is the best way: you get the quickest reply and can send a screenshot of the problem.'),
          const SizedBox(height: 12),
          _row(context, Icons.chat_outlined, Brand.green, 'WhatsApp', '+260 768 648 291', whatsappUrl, '+260768648291'),
          _row(context, Icons.language, Brand.teal, 'Website', 'timtiml-website.vercel.app', webUrl, webUrl),
          _row(context, Icons.email_outlined, Brand.navy, 'Email', email, 'mailto:$email?subject=TIM-POS%20help', email),
          const SizedBox(height: 8),
          Card(
            color: Brand.orange.withValues(alpha: 0.12),
            margin: const EdgeInsets.only(bottom: 10),
            child: const Padding(
              padding: EdgeInsets.all(14),
              child: Text('Calls and SMS: +263 774 348 204. This number is not answered all the time, so if nobody picks up, send a WhatsApp message instead.'),
            ),
          ),
          _row(context, Icons.call_outlined, Brand.navy, 'Call', '+263 774 348 204 (not always available)', 'tel:$callNumber', callNumber),
          _row(context, Icons.sms_outlined, Brand.navy, 'SMS', '+263 774 348 204 (not always available)', 'sms:$callNumber', callNumber),
          const SizedBox(height: 8),
          const Text('When you write, please say your shop name and what you were doing when the problem happened.', style: TextStyle(color: Colors.grey)),
        ]),
      );
}
