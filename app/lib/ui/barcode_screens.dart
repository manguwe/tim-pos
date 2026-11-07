import 'package:flutter/material.dart';

import '../barcodes/barcode_repository.dart';
import '../printing/print_service.dart';
import '../printing/printer_transport.dart' show PrinterError;
import '../setup/setup_repository.dart' show SetupError;
import 'scan_screen.dart';
import 'theme.dart';

/// Scans one barcode with the camera and returns it (null if the person backed out).
Future<String?> scanOnce(BuildContext context, {String title = 'Scan a barcode'}) =>
    Navigator.of(context).push<String>(MaterialPageRoute(builder: (_) => ScannerScreen(title: title, closeOnScan: true)));

/// The barcodes of one product: add by camera or typing, make a shop code, remove, and print shelf labels.
class BarcodeSection extends StatefulWidget {
  const BarcodeSection({super.key, required this.repo, required this.productId, this.printing});
  final BarcodeRepository repo;
  final String productId;
  final PrintService? printing;
  @override
  State<BarcodeSection> createState() => _BarcodeSectionState();
}

class _BarcodeSectionState extends State<BarcodeSection> {
  List<BarcodeRow> _rows = [];
  String? _note;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.repo.list(widget.productId);
    if (mounted) setState(() => _rows = r);
  }

  void _say(String m, {bool error = false}) => setState(() { _note = m; _error = error; });

  Future<void> _add(String raw) async {
    try {
      final r = await widget.repo.add(widget.productId, raw);
      _say(r.created ? 'Barcode added.' : 'The product already has that barcode.');
    } on SetupError catch (e) {
      if (e.code == 'bad_check_digit' && mounted) {
        final yes = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Check the barcode'),
            content: Text('${e.message}\n\n$raw'),
            actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Re-enter')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add anyway'))],
          ),
        );
        if (yes == true) {
          try {
            await widget.repo.add(widget.productId, raw, allowInvalid: true);
            _say('Barcode added.');
          } on SetupError catch (e2) {
            _say(e2.message, error: true);
          }
        }
      } else {
        _say(e.message, error: true);
      }
    }
    await _load();
  }

  Future<void> _scan() async {
    final code = await scanOnce(context);
    if (code != null) await _add(code);
  }

  Future<void> _type() async {
    final t = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type the barcode'),
        content: TextField(controller: t, autofocus: true, autocorrect: false, decoration: const InputDecoration(labelText: 'Barcode'), onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, t.text), child: const Text('Add'))],
      ),
    );
    t.dispose();
    if (code != null && code.trim().isNotEmpty) await _add(code);
  }

  Future<void> _shopCode() async {
    try {
      final code = await widget.repo.giveShopCode(widget.productId);
      _say('Made the shop code $code. Print a label and stick it on the product.');
    } on SetupError catch (e) {
      _say(e.message, error: true);
    }
    await _load();
  }

  Future<void> _remove(BarcodeRow r) async {
    try {
      await widget.repo.remove(r.id);
    } on SetupError catch (e) {
      _say(e.message, error: true);
    }
    await _load();
  }

  Future<void> _print(BarcodeRow r) async {
    final pr = widget.printing;
    if (pr == null) {
      _say('No printer is set up on this phone yet.', error: true);
      return;
    }
    final copies = TextEditingController(text: '1');
    final n = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Print labels'),
        content: TextField(controller: copies, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'How many labels')),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(copies.text.trim())), child: const Text('Print'))],
      ),
    );
    copies.dispose();
    if (n == null || n < 1) return;
    try {
      await pr.printLabel(await widget.repo.loadLabel(widget.productId, code: r.barcode), copies: n);
      _say('Printed $n label${n == 1 ? '' : 's'}.');
    } on SetupError catch (e) {
      _say(e.message, error: true);
    } on PrinterError catch (e) {
      _say(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Barcodes', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 4),
      if (_rows.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 8), child: Text('No barcode yet. Scan the pack, or make a shop code for products without one.')),
      for (final r in _rows)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(r.barcode, style: const TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w600)),
          subtitle: Text(r.kind.label),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(tooltip: 'Print label', icon: const Icon(Icons.print_outlined), onPressed: () => _print(r)),
            IconButton(tooltip: 'Remove', icon: const Icon(Icons.delete_outline), onPressed: () => _remove(r)),
          ]),
        ),
      if (_note != null) Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(_note!, style: TextStyle(color: _error ? Brand.coral : Brand.teal, fontWeight: FontWeight.w600))),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton.icon(onPressed: _scan, icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan')),
        OutlinedButton.icon(onPressed: _type, icon: const Icon(Icons.keyboard_outlined), label: const Text('Type')),
        OutlinedButton.icon(onPressed: _shopCode, icon: const Icon(Icons.auto_fix_high), label: const Text('Make shop code')),
      ]),
    ]);
  }
}
