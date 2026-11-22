import 'package:flutter/material.dart';

import '../settings/app_prefs.dart';
import 'about_screen.dart';
import 'theme.dart';

/// Settings for this phone only: how it looks and a few things that save data or help at the till.
/// (Shop settings such as the receipt text are on the other Settings screen and are shared by every phone.)
class AppSettingsScreen extends StatelessWidget {
  const AppSettingsScreen({super.key});

  Widget _heading(String t) => Padding(
        padding: const EdgeInsets.only(top: 22, bottom: 8),
        child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
      );

  @override
  Widget build(BuildContext context) {
    final p = AppPrefs.instance;
    return Scaffold(
      appBar: AppBar(title: const Text('App settings')),
      body: ListenableBuilder(
        listenable: p,
        builder: (context, _) => ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
          _heading('Colours'),
          SegmentedButton<ThemeMode>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('Phone'), icon: Icon(Icons.phone_android)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode_outlined)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode_outlined)),
            ],
            selected: {p.themeMode},
            onSelectionChanged: (s) => p.setThemeMode(s.first),
          ),
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('"Phone" follows your phone\'s own light or dark setting.', style: TextStyle(color: Colors.grey))),
          _heading('Text size'),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'small', label: Text('Small')),
              ButtonSegment(value: 'normal', label: Text('Normal')),
              ButtonSegment(value: 'large', label: Text('Large')),
              ButtonSegment(value: 'xlarge', label: Text('Huge')),
            ],
            selected: {p.textSize},
            onSelectionChanged: (s) => p.setTextSize(s.first),
          ),
          _heading('Font'),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final e in AppPrefs.fonts.entries)
              ChoiceChip(
                label: Text(e.value.label, style: TextStyle(fontFamily: e.value.family)),
                selected: p.font == e.key,
                onSelected: (_) => p.setFont(e.key),
              ),
          ]),
          const SizedBox(height: 14),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Row(children: const [
                Expanded(child: Text('Rice 5kg', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                Text('USD 6.50', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: Brand.teal)),
              ]),
            ),
          ),
          const Padding(padding: EdgeInsets.only(top: 6), child: Text('This is how prices will look.', style: TextStyle(color: Colors.grey))),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: p.resetLook, icon: const Icon(Icons.restart_alt), label: const Text('Back to the normal look')),
          ),
          _heading('Till'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Show products as pictures'),
            subtitle: const Text('Off shows a plain list. You can also change this on the till.'),
            value: p.tillGrid,
            onChanged: p.setTillGrid,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Small buzz when an item is added'),
            subtitle: const Text('Helps you feel that the tap worked.'),
            value: p.tapFeedback,
            onChanged: p.setTapFeedback,
          ),
          _heading('Data'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Send and get product pictures'),
            subtitle: const Text('Turn off to save mobile data. Sales still sync as normal.'),
            value: p.sendPictures,
            onChanged: p.setSendPictures,
          ),
          _heading('Help'),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.support_agent_outlined),
            title: const Text('Help and contact'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const AboutScreen())),
          ),
        ]),
      ),
    );
  }
}
