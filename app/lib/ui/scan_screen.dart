import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'theme.dart';

/// The camera barcode reader. This is the only file that uses the scanner plugin (`mobile_scanner`);
/// if a plugin version changes its API, fix it here.
///
/// For every code seen, [onCode] is called and the line it returns is shown over the picture (for example "Added Bread").
/// The same code is ignored for a moment so one bar code does not count twice. With [closeOnScan] the screen closes
/// after the first code and returns it. A "Type it" button covers damaged labels.
class ScannerScreen extends StatefulWidget {
  const ScannerScreen({super.key, required this.title, this.onCode, this.closeOnScan = false});
  final String title;
  final Future<String?> Function(String code)? onCode;
  final bool closeOnScan;
  @override
  State<ScannerScreen> createState() => _ScannerScreenState();
}

class _ScannerScreenState extends State<ScannerScreen> {
  final _controller = MobileScannerController();
  String? _last;
  DateTime _lastAt = DateTime.fromMillisecondsSinceEpoch(0);
  String? _message;
  bool _busy = false;
  bool _torch = false;
  Timer? _clear;

  @override
  void dispose() {
    _clear?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _got(String code) async {
    final now = DateTime.now();
    if (_busy || (code == _last && now.difference(_lastAt) < const Duration(milliseconds: 1800))) return;
    _busy = true;
    _last = code;
    _lastAt = now;
    try {
      if (widget.closeOnScan) {
        if (mounted) Navigator.pop(context, code);
        return;
      }
      final msg = await widget.onCode?.call(code);
      if (!mounted) return;
      setState(() => _message = msg);
      _clear?.cancel();
      _clear = Timer(const Duration(seconds: 3), () {
        if (mounted) setState(() => _message = null);
      });
    } finally {
      _busy = false;
      _lastAt = DateTime.now();
    }
  }

  Future<void> _type() async {
    final t = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Type the barcode'),
        content: TextField(controller: t, autofocus: true, autocorrect: false, decoration: const InputDecoration(labelText: 'Barcode'), onSubmitted: (v) => Navigator.pop(ctx, v)),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, t.text), child: const Text('OK'))],
      ),
    );
    t.dispose();
    if (code != null && code.trim().isNotEmpty) await _got(code.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Torch',
            icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
            onPressed: () async {
              await _controller.toggleTorch();
              if (mounted) setState(() => _torch = !_torch);
            },
          ),
          TextButton(onPressed: _type, child: const Text('Type it', style: TextStyle(color: Colors.white))),
        ],
      ),
      body: Stack(children: [
        MobileScanner(
          controller: _controller,
          errorBuilder: (context, error) => const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('The camera could not start. Allow camera access for TIM-POS in the phone settings, or use Type it.', textAlign: TextAlign.center))),
          onDetect: (capture) {
            for (final b in capture.barcodes) {
              final v = b.rawValue;
              if (v != null && v.isNotEmpty) {
                _got(v);
                break;
              }
            }
          },
        ),
        Center(child: Container(width: 280, height: 160, decoration: BoxDecoration(border: Border.all(color: Brand.amber, width: 3), borderRadius: BorderRadius.circular(12)))),
        if (_message != null)
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Material(color: Brand.navy, borderRadius: BorderRadius.circular(10), child: Padding(padding: const EdgeInsets.all(14), child: Text(_message!, style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)))),
          ),
      ]),
    );
  }
}
