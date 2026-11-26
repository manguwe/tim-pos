import 'package:flutter/material.dart';

import '../printing/receipt.dart' show sampleReceiptText;
import '../settings/settings_repository.dart';
import '../setup/setup_repository.dart' show SetupError;
import 'theme.dart';

/// Shop settings: switches, a number and two lines of receipt text. Changes are saved together with one button.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.repo, this.shopName = 'Your shop'});
  final SettingsRepository repo;
  final String shopName;
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final Map<String, String> _saved = {};
  final Map<String, String> _draft = {};
  final Map<String, TextEditingController> _fields = {};
  String? _note;
  bool _ok = false;
  bool _busy = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final s = await widget.repo.load();
    if (!mounted) return;
    setState(() {
      _saved
        ..clear()
        ..addAll(s);
      _draft
        ..clear()
        ..addAll(s);
      for (final d in shopSettings.where((d) => d.kind != SettingKind.bool)) {
        (_fields[d.key] ??= TextEditingController()).text = s[d.key]!;
      }
      _loaded = true;
    });
  }

  Map<String, String> get _changes => {for (final e in _draft.entries) if (e.value != _saved[e.key]) e.key: e.value};

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _note = null;
      _ok = false;
    });
    try {
      final changed = await widget.repo.save(_changes);
      await _load();
      if (mounted) setState(() { _ok = true; _note = changed.isEmpty ? 'Nothing to save.' : 'Saved.'; });
    } on SetupError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groups = <String>[for (final d in shopSettings) if (!shopSettings.takeWhile((x) => x != d).any((x) => x.group == d.group)) d.group];
    return Scaffold(
      appBar: AppBar(title: const Text('Settings'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              for (final g in groups) ...[
                Padding(padding: const EdgeInsets.only(top: 8, bottom: 4), child: Text(g, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                for (final d in shopSettings.where((d) => d.group == g)) _row(d),
                if (g == 'Receipts') _preview(),
              ],
              if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!, style: TextStyle(color: _ok ? Brand.teal : Brand.coral, fontWeight: FontWeight.w600))),
              const SizedBox(height: 12),
              FilledButton(onPressed: _busy || _changes.isEmpty ? null : _save, child: Text(_busy ? 'Saving...' : 'Save changes')),
            ]),
    );
  }

  /// What a receipt will look like with the values typed above, before anything is saved.
  Widget _preview() => Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.black26)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Preview of your receipt', style: TextStyle(color: Colors.black54, fontWeight: FontWeight.w700)),
            const SizedBox(height: 8),
            Text(sampleReceiptText(_draft, shopName: widget.shopName), style: const TextStyle(fontFamily: 'monospace', fontSize: 12, height: 1.25, color: Colors.black)),
          ]),
        ),
      );

  Widget _row(SettingDef d) {
    if (d.kind == SettingKind.bool) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(d.label),
        subtitle: Text(d.help),
        value: _draft[d.key] == '1',
        onChanged: (v) => setState(() => _draft[d.key] = v ? '1' : '0'),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: TextField(
        controller: _fields[d.key],
        keyboardType: d.kind == SettingKind.int ? TextInputType.number : TextInputType.text,
        maxLength: d.maxLen,
        decoration: InputDecoration(labelText: d.label, helperText: d.help, helperMaxLines: 3, border: const OutlineInputBorder()),
        onChanged: (v) => setState(() => _draft[d.key] = v),
      ),
    );
  }
}
