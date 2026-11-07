import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../printing/print_service.dart';
import '../printing/printer_transport.dart';
import 'theme.dart';

/// The receipt on screen, with print and reprint (a reprint is marked COPY).
class ReceiptScreen extends StatefulWidget {
  const ReceiptScreen({super.key, required this.printing, required this.saleId});
  final PrintService printing;
  final String saleId;
  @override
  State<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends State<ReceiptScreen> {
  String? _text;
  String? _note;
  bool _busy = false;
  bool _printedOnce = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final t = await widget.printing.preview(widget.saleId);
      if (mounted) setState(() => _text = t);
    } catch (e) {
      if (mounted) setState(() => _note = 'Could not read the receipt: $e');
    }
  }

  Future<void> _print({required bool copy}) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await widget.printing.print(widget.saleId, copy: copy);
      _printedOnce = true;
      if (mounted) setState(() => _note = 'Sent to the printer.');
    } on PrinterError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } catch (e) {
      if (mounted) setState(() => _note = 'Printing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Colors.white, border: Border.all(color: Colors.black12), borderRadius: BorderRadius.circular(6)),
                  child: SelectableText(_text ?? 'Loading…', style: const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.25, color: Colors.black87)),
                ),
              ),
            ),
          ),
          if (_note != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(_note!, textAlign: TextAlign.center)),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy text'),
                  onPressed: _text == null ? null : () => Clipboard.setData(ClipboardData(text: _text!)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  icon: const Icon(Icons.print),
                  label: Text(_printedOnce ? 'Print copy' : 'Print'),
                  onPressed: _busy || _text == null ? null : () => _print(copy: _printedOnce),
                ),
              ),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Choose the receipt printer, the paper width, and whether it opens the cash drawer.
class PrinterScreen extends StatefulWidget {
  const PrinterScreen({super.key, required this.printing});
  final PrintService printing;
  @override
  State<PrinterScreen> createState() => _PrinterScreenState();
}

class _PrinterScreenState extends State<PrinterScreen> {
  SavedPrinter? _saved;
  List<PrinterDevice> _found = [];
  int _paper = 58;
  bool _drawer = false;
  String? _note;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await widget.printing.printer();
    if (!mounted) return;
    setState(() {
      _saved = p;
      if (p != null) {
        _paper = p.paperWidthMm;
        _drawer = p.opensDrawer;
      }
    });
  }

  Future<void> _search() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final list = await widget.printing.transport.pairedDevices();
      if (!mounted) return;
      setState(() {
        _found = list;
        if (list.isEmpty) _note = 'No paired printers. Pair the printer in the phone\'s Bluetooth settings first (PIN is often 0000 or 1234), then search again.';
      });
    } on PrinterError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } catch (e) {
      if (mounted) setState(() => _note = 'Could not search: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _choose(PrinterDevice d) async {
    await widget.printing.savePrinter(name: d.name, address: d.address, paperWidthMm: _paper, opensDrawer: _drawer);
    await _load();
    if (mounted) setState(() => _note = '${d.name} saved. Print a test page to check it.');
  }

  Future<void> _applyOptions() async {
    final p = _saved;
    if (p == null) return;
    await widget.printing.savePrinter(name: p.name, address: p.address, paperWidthMm: _paper, opensDrawer: _drawer);
    await _load();
  }

  Future<void> _test() async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await widget.printing.printTest();
      if (mounted) setState(() => _note = 'Test page sent.');
    } on PrinterError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } catch (e) {
      if (mounted) setState(() => _note = 'Printing failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final saved = _saved;
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt printer'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        if (saved != null)
          Card(
            child: ListTile(
              leading: const Icon(Icons.print, color: Brand.teal),
              title: Text(saved.name),
              subtitle: Text('${saved.address} · ${saved.paperWidthMm} mm'),
              trailing: TextButton(
                onPressed: () async {
                  await widget.printing.removePrinter();
                  await _load();
                },
                child: const Text('Remove'),
              ),
            ),
          ),
        const SizedBox(height: 8),
        const Text('Paper width'),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          segments: const [ButtonSegment(value: 58, label: Text('58 mm')), ButtonSegment(value: 80, label: Text('80 mm'))],
          selected: {_paper},
          onSelectionChanged: (s) async {
            setState(() => _paper = s.first);
            await _applyOptions();
          },
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Open the cash drawer on cash sales'),
          subtitle: const Text('Only if the drawer is plugged into the printer.'),
          value: _drawer,
          onChanged: (v) async {
            setState(() => _drawer = v);
            await _applyOptions();
          },
        ),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.bluetooth_searching), label: const Text('Find printers'), onPressed: _busy ? null : _search)),
          const SizedBox(width: 10),
          Expanded(child: FilledButton.icon(icon: const Icon(Icons.receipt), label: const Text('Test page'), onPressed: _busy || saved == null ? null : _test)),
        ]),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!)),
        const SizedBox(height: 8),
        for (final d in _found)
          ListTile(
            leading: const Icon(Icons.bluetooth),
            title: Text(d.name),
            subtitle: Text(d.address),
            trailing: saved?.address == d.address ? const Icon(Icons.check_circle, color: Brand.green) : null,
            onTap: () => _choose(d),
          ),
      ]),
    );
  }
}
