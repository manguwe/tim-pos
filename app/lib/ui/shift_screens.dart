import 'package:flutter/material.dart';

import '../printing/print_service.dart';
import '../selling/catalog.dart';
import 'slip_print.dart';
import '../setup/setup_repository.dart' show SetupError;
import '../shifts/shift_repository.dart';
import 'theme.dart';

/// Open a shift with a float, move cash in and out, and close with a count.
class ShiftScreen extends StatefulWidget {
  const ShiftScreen({super.key, required this.repo, this.printing});
  final ShiftRepository repo;
  final PrintService? printing;
  @override
  State<ShiftScreen> createState() => _ShiftScreenState();
}

class _ShiftScreenState extends State<ShiftScreen> {
  ShiftInfo? _shift;
  ShiftReport? _live;
  ShiftReport? _closed;
  List<CurrencyInfo> _cur = [];
  final Map<String, TextEditingController> _float = {};
  String? _note;
  bool _busy = false;
  bool _loaded = false;

  ShiftRepository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in _float.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    final rows = await repo.db.query('select code, symbol, minor_units from currencies where deleted_at is null and is_active = 1 order by code');
    final cur = [for (final r in rows) CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, (r['minor_units'] as num).toInt())];
    final sh = await repo.current();
    final live = sh == null ? null : await repo.report(sh.id);
    if (!mounted) return;
    setState(() {
      _cur = cur;
      _shift = sh;
      _live = live;
      _loaded = true;
      for (final c in cur) {
        _float.putIfAbsent(c.code, () => TextEditingController());
      }
    });
  }

  String _m(int minor, String code) => _cur.firstWhere((c) => c.code == code, orElse: () => CurrencyInfo(code, code, 2)).format(minor);

  Map<String, int>? _parse(Map<String, TextEditingController> fields, {required bool allowBlank}) {
    final out = <String, int>{};
    for (final c in _cur) {
      final t = fields[c.code]!.text.trim();
      if (t.isEmpty) {
        if (allowBlank) continue;
        setState(() => _note = 'Enter the ${c.code} amount (0 if none).');
        return null;
      }
      final v = c.parse(t);
      if (v == null) {
        setState(() => _note = 'The ${c.code} amount is not valid.');
        return null;
      }
      out[c.code] = v;
    }
    return out;
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await action();
    } on SetupError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _open() async {
    final f = _parse(_float, allowBlank: true);
    if (f == null) return;
    final branch = await repo.defaultBranchId();
    if (branch == null) {
      setState(() => _note = 'The shop has no branch yet.');
      return;
    }
    await _run(() async {
      await repo.openShift(branchId: branch, float: f);
      _closed = null;
    });
  }

  Future<void> _cashEvent(String type) async {
    final amount = TextEditingController();
    final reason = TextEditingController();
    var cur = _cur.first.code;
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(type == 'cash_in' ? 'Cash in' : type == 'cash_out' ? 'Cash out' : 'Bank drop'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Wrap(spacing: 8, children: [for (final c in _cur) ChoiceChip(label: Text(c.code), selected: cur == c.code, onSelected: (_) => setS(() => cur = c.code))]),
            TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount in $cur')),
            if (type != 'bank_drop') TextField(controller: reason, decoration: const InputDecoration(labelText: 'Reason')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final info = _cur.firstWhere((c) => c.code == cur);
                final v = info.parse(amount.text);
                if (v == null || v <= 0) {
                  setS(() => err = 'Enter the amount.');
                  return;
                }
                try {
                  await repo.addCashEvent(shiftId: _shift!.id, currency: cur, type: type, amountMinor: v, reason: reason.text);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on SetupError catch (e) {
                  setS(() => err = e.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await _load();
  }

  Future<void> _close() async {
    final counts = {for (final c in _cur) c.code: TextEditingController()};
    String? err;
    final result = await showDialog<ShiftReport>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Count the drawer'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Count the cash you have and enter it for each currency. The expected amount is shown after you close.'),
              for (final c in _cur) TextField(controller: counts[c.code], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cash counted in ${c.code}')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final m = <String, int>{};
                for (final c in _cur) {
                  final v = c.parse(counts[c.code]!.text);
                  if (v == null) {
                    setS(() => err = 'Enter the ${c.code} count (0 if none).');
                    return;
                  }
                  m[c.code] = v;
                }
                try {
                  final r = await repo.closeShift(_shift!.id, m);
                  if (ctx.mounted) Navigator.pop(ctx, r);
                } on SetupError catch (e) {
                  setS(() => err = e.message);
                }
              },
              child: const Text('Close shift'),
            ),
          ],
        ),
      ),
    );
    for (final c in counts.values) {
      c.dispose();
    }
    if (result != null) {
      _closed = result;
      await _load();
      if (mounted) await printSlipSafely(context, widget.printing, (v) => v.cashUpSlip(result));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shift and cash-up'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (_note != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(_note!, style: const TextStyle(color: Brand.coral))),
              if (_closed != null) ..._reportCard(_closed!, title: 'Shift closed'),
              if (_closed != null && widget.printing != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print cash-up slip'),
                    onPressed: () => printSlipSafely(context, widget.printing, (v) => v.cashUpSlip(_closed!), quietWhenNoPrinter: false),
                  ),
                ),
              if (_shift == null) ..._openForm() else ..._openShift(),
            ]),
    );
  }

  List<Widget> _openForm() => [
        const SizedBox(height: 8),
        Text('Open a shift', style: Theme.of(context).textTheme.titleLarge),
        const Text('Enter the cash already in the drawer. Leave blank for none.'),
        for (final c in _cur) TextField(controller: _float[c.code], keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Float in ${c.code}')),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _open, child: const Text('Open shift')),
      ];

  List<Widget> _openShift() {
    final r = _live!;
    return [
      Text('Shift open since ${DateTime.fromMillisecondsSinceEpoch(r.openedAt).toLocal().toString().substring(0, 16)}', style: Theme.of(context).textTheme.titleMedium),
      const SizedBox(height: 6),
      Text('${r.sales} sales${r.voided > 0 ? ' · ${r.voided} voided' : ''}'),
      for (final e in r.sold.entries) Text('Sold ${_m(e.value, e.key)}'),
      const SizedBox(height: 12),
      Text('Takings', style: Theme.of(context).textTheme.titleSmall),
      if (r.takings.isEmpty) const Text('Nothing yet.'),
      for (final t in r.takings) Text('${t.method} ${_m(t.amountMinor, t.currency)}'),
      for (final t in r.refunds) Text('Paid back (${t.method}) ${_m(t.amountMinor, t.currency)}'),
      const SizedBox(height: 14),
      Wrap(spacing: 8, children: [
        OutlinedButton(onPressed: _busy ? null : () => _cashEvent('cash_in'), child: const Text('Cash in')),
        OutlinedButton(onPressed: _busy ? null : () => _cashEvent('cash_out'), child: const Text('Cash out')),
        OutlinedButton(onPressed: _busy ? null : () => _cashEvent('bank_drop'), child: const Text('Bank drop')),
      ]),
      for (final e in r.events) Text('${e.type == 'cash_in' ? 'In' : e.type == 'cash_out' ? 'Out' : 'Bank drop'} ${_m(e.amountMinor, e.currency)}${e.reason == null ? '' : ' · ${e.reason}'}'),
      const SizedBox(height: 18),
      FilledButton.icon(icon: const Icon(Icons.lock), onPressed: _busy ? null : _close, label: const Text('Close shift')),
    ];
  }

  List<Widget> _reportCard(ShiftReport r, {required String title}) => [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              Text('${r.sales} sales'),
              const SizedBox(height: 8),
              for (final code in r.expected.keys) ...[
                Text(code, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text('Float ${_m(r.float[code] ?? 0, code)} · Expected ${_m(r.expected[code] ?? 0, code)} · Counted ${_m(r.counted[code] ?? 0, code)}'),
                Text(
                  (r.difference[code] ?? 0) == 0 ? 'Balanced' : (r.difference[code]! < 0 ? 'Short ${_m(-r.difference[code]!, code)}' : 'Over ${_m(r.difference[code]!, code)}'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: (r.difference[code] ?? 0) == 0 ? Brand.green : Brand.coral),
                ),
                const SizedBox(height: 6),
              ],
            ]),
          ),
        ),
        const SizedBox(height: 12),
      ];
}
