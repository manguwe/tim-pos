import 'package:flutter/material.dart';

import '../fiscal/fiscal_repository.dart';
import 'theme.dart';

/// ZIMRA fiscal: the device, the tax matching, the queue of receipts and the fiscal day.
/// Until the signing code and ZIMRA connection are installed, receipts wait here and the screen says so.
class FiscalScreen extends StatefulWidget {
  const FiscalScreen({super.key, required this.repo, required this.gateway, required this.signer});
  final FiscalRepository repo;
  final Gateway? gateway;
  final Signer signer;
  @override
  State<FiscalScreen> createState() => _FiscalScreenState();
}

class _FiscalScreenState extends State<FiscalScreen> {
  bool _loaded = false, _busy = false, _enabled = false;
  FiscalDevice? _device;
  FiscalState _state = FiscalState();
  TaxSetup _tax = TaxSetup([], {}, '');
  List<({String id, String name, int rateBp})> _classes = [];
  List<QueueDoc> _waiting = [], _failed = [], _sent = [];
  CloseCheck? _close;
  String? _note;
  bool _ok = false;
  final _deviceNo = TextEditingController();
  final _serial = TextEditingController();
  final _hs = TextEditingController();

  int get _offsetMin => DateTime.now().timeZoneOffset.inMinutes;
  bool get _connected => widget.gateway != null && widget.signer.isReady;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _deviceNo.dispose();
    _serial.dispose();
    _hs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = widget.repo;
    final enabled = await r.isEnabled();
    final dev = await r.device();
    final st = await r.state();
    final tax = await r.taxSetup();
    final cls = await r.taxClasses();
    final queued = await r.listQueue(status: 'queued');
    final failed = await r.listQueue(status: 'failed');
    final sent = await r.listQueue(status: 'sent', limit: 20);
    final close = await r.canCloseDay();
    if (!mounted) return;
    setState(() {
      _enabled = enabled;
      _device = dev;
      _state = st;
      _tax = tax;
      _classes = cls;
      _waiting = queued;
      _failed = failed;
      _sent = sent;
      _close = close;
      if (dev != null) {
        _deviceNo.text = '${dev.deviceId}';
        _serial.text = dev.serial;
      }
      _hs.text = tax.hsDefault;
      _loaded = true;
    });
  }

  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final msg = await action();
      await _load();
      if (mounted) setState(() { _ok = true; _note = msg; });
    } on FiscalError catch (e) {
      if (mounted) setState(() { _ok = false; _note = e.message; });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _statusLine() {
    if (!_enabled) return 'Switched off. Sales are not sent to ZIMRA.';
    if (_device == null) return 'Switched on, but this phone\'s ZIMRA device is not entered yet.';
    if (!widget.signer.isReady) return 'Switched on. Receipt signing and the ZIMRA connection are not installed on this phone yet, so receipts wait in the queue. Selling is not affected.';
    return switch (_state.status) {
      'opened' => 'Fiscal day ${_state.dayNo} is open.',
      'close_failed' => 'Fiscal day ${_state.dayNo} is open. ZIMRA did not accept the last close: ${_state.lastCloseError ?? ''}',
      _ => 'No fiscal day is open. One opens by itself when the next receipt is sent.',
    };
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ZIMRA fiscal'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(_statusLine()))),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Send sales to ZIMRA'),
                subtitle: const Text('Every sale and return made while this is on is queued as a fiscal receipt. Turn it on only when the shop is registered with ZIMRA.'),
                value: _enabled,
                onChanged: _busy ? null : (v) => _run(() async { await widget.repo.setEnabled(v); return null; }),
              ),
              if (_note != null) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(_note!, style: TextStyle(color: _ok ? Brand.teal : Brand.coral, fontWeight: FontWeight.w600))),
              _section('This phone\'s ZIMRA device'),
              const Text('Each till is registered with ZIMRA on its own. Enter the device ID and serial number from your registration.'),
              const SizedBox(height: 8),
              TextField(controller: _deviceNo, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Device ID')),
              const SizedBox(height: 10),
              TextField(controller: _serial, decoration: const InputDecoration(labelText: 'Device serial number')),
              const SizedBox(height: 10),
              OutlinedButton(
                onPressed: _busy ? null : () => _run(() async {
                  await widget.repo.saveDevice(deviceNo: int.tryParse(_deviceNo.text.trim()) ?? 0, serial: _serial.text);
                  return 'Device saved.';
                }),
                child: const Text('Save device'),
              ),
              _section('Taxes'),
              const Text('Match each of your tax classes to the tax ZIMRA knows it by. Add ZIMRA\'s taxes from your device configuration first.'),
              const SizedBox(height: 8),
              for (final t in _tax.taxes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('Tax ${t['taxID']}: ${t['taxName'] ?? t['taxCode'] ?? ''}'),
                  subtitle: Text(t['taxPercent'] == null ? 'Exempt' : '${t['taxPercent']}%'),
                  trailing: IconButton(
                    tooltip: 'Remove',
                    icon: const Icon(Icons.close),
                    onPressed: _busy ? null : () => _run(() async {
                      await widget.repo.saveTaxSetup(taxes: [for (final x in _tax.taxes) if (x != t) x]);
                      return null;
                    }),
                  ),
                ),
              TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add a ZIMRA tax'), onPressed: _busy ? null : _addTax),
              for (final c in _classes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: DropdownButtonFormField<int?>(
                    initialValue: _tax.map[c.id],
                    decoration: InputDecoration(labelText: '${c.name} (${c.rateBp / 100}%)'),
                    items: [
                      const DropdownMenuItem<int?>(value: null, child: Text('Not matched')),
                      for (final t in _tax.taxes) DropdownMenuItem<int?>(value: (t['taxID'] as num).toInt(), child: Text('${t['taxID']}: ${t['taxName'] ?? t['taxCode'] ?? ''}')),
                    ],
                    onChanged: _busy ? null : (v) => _run(() async {
                      final m = {..._tax.map};
                      if (v == null) { m.remove(c.id); } else { m[c.id] = v; }
                      await widget.repo.saveTaxSetup(map: m);
                      return null;
                    }),
                  ),
                ),
              const SizedBox(height: 8),
              TextField(controller: _hs, decoration: const InputDecoration(labelText: 'Default HS code (optional)', helperText: '4 to 8 digits, used for items that have none')),
              const SizedBox(height: 8),
              OutlinedButton(onPressed: _busy ? null : () => _run(() async { await widget.repo.saveTaxSetup(hsDefault: _hs.text.trim()); return 'Saved.'; }), child: const Text('Save HS code')),
              _section('Receipts'),
              Text('${_waiting.where((d) => d.payload['deferred'] == null).length} waiting, ${_failed.length} failed, ${_sent.length} sent (latest 20 shown).'),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _busy || !_enabled || _device == null ? null : () => _run(_sendNow),
                child: Text(_connected ? 'Send waiting receipts now' : 'Send now (not available yet)'),
              ),
              for (final d in _failed)
                Card(
                  color: Brand.coral.withValues(alpha: 0.08),
                  child: ListTile(
                    title: Text('${d.kind == 'invoice' ? 'Sale' : 'Return'} receipt failed'),
                    subtitle: Text('${d.payload['error'] ?? 'Unknown reason'}'),
                    trailing: TextButton(onPressed: _busy ? null : () => _run(() async { await widget.repo.requeue(d.id); return 'Back in the queue.'; }), child: const Text('Send again')),
                  ),
                ),
              for (final d in _waiting.where((d) => d.payload['deferred'] != null))
                ListTile(dense: true, contentPadding: EdgeInsets.zero, title: Text(d.payload['deferred'] == 'layby_not_collected' ? 'Layby, sent when collected' : 'Waiting for the original receipt'), subtitle: Text(d.saleId ?? '')),
              _section('Fiscal day'),
              if (_close != null && !_close!.ok) Text(_close!.reasons.join(' ')),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy || _close == null || !_close!.ok || !_connected ? null : () => _run(() async => (await widget.repo.closeDay(widget.gateway!, widget.signer)).message),
                child: const Text('Close the fiscal day'),
              ),
              const SizedBox(height: 24),
            ]),
    );
  }

  Future<String?> _sendNow() async {
    final gw = widget.gateway;
    if (gw == null || !widget.signer.isReady) return 'Receipt signing and the ZIMRA connection are not installed on this phone yet. The receipts are safe in the queue.';
    final r = await widget.repo.sendQueued(gw, widget.signer, offsetMin: _offsetMin);
    if (r.stopped == 'offline') return 'Could not reach ZIMRA. ${r.sent} sent, ${r.waiting} waiting.';
    if (r.stopped != null) return 'Stopped: ${r.stopped}. ${r.sent} sent.';
    return '${r.sent} sent${r.failed > 0 ? ', ${r.failed} failed' : ''}${r.dayTooLong ? '. This fiscal day has been open too long: close it.' : '.'}';
  }

  Widget _section(String t) => Padding(padding: const EdgeInsets.only(top: 22, bottom: 6), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)));

  Future<void> _addTax() async {
    final id = TextEditingController(), code = TextEditingController(), name = TextEditingController(), pct = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Add a ZIMRA tax'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: id, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Tax ID')),
            TextField(controller: code, decoration: const InputDecoration(labelText: 'Tax code (optional)')),
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: pct, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Percent', helperText: 'Leave empty for an exempt tax')),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Add'))],
      ),
    );
    final tid = int.tryParse(id.text.trim());
    final percent = pct.text.trim().isEmpty ? null : double.tryParse(pct.text.trim());
    if (ok != true) return;
    if (tid == null || tid <= 0 || (pct.text.trim().isNotEmpty && (percent == null || percent < 0 || percent > 100))) {
      if (mounted) setState(() { _ok = false; _note = 'Enter the tax ID, and a percent between 0 and 100 (or leave the percent empty for an exempt tax).'; });
      return;
    }
    await _run(() async {
      final list = [for (final t in _tax.taxes) if ((t['taxID'] as num).toInt() != tid) t, {'taxID': tid, if (code.text.trim().isNotEmpty) 'taxCode': code.text.trim(), 'taxName': name.text.trim(), 'taxPercent': percent}];
      list.sort((a, b) => (a['taxID'] as num).compareTo(b['taxID'] as num));
      await widget.repo.saveTaxSetup(taxes: list);
      return null;
    });
  }
}
