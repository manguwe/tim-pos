import 'package:flutter/material.dart';

import '../barcodes/barcode_repository.dart' show BarcodeRepository, ScanStatus;
import '../selling/catalog.dart';
import '../setup/setup_repository.dart' show SetupError;
import '../stock/stock_repository.dart';
import 'barcode_screens.dart' show scanOnce;
import 'scan_screen.dart';
import 'setup_screens.dart' show parseQty;
import 'theme.dart';

const _typeNames = {
  'damaged': 'Damaged', 'expired': 'Expired', 'loss': 'Lost or stolen', 'adjustment': 'Adjustment', 'count_correction': 'Stock take correction',
};

/// Take stock off the shelf with a reason, count the shelves, and see what was lost.
class StockScreen extends StatefulWidget {
  const StockScreen({super.key, required this.repo, this.now, this.barcodes});
  final StockRepository repo;
  final BarcodeRepository? barcodes;
  final DateTime Function()? now;
  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  StockRepository get repo => widget.repo;
  String? _branch;
  CurrencyInfo _money = const CurrencyInfo('USD', r'$', 2);
  bool _loaded = false;
  String? _note;

  // adjust tab
  final _search = TextEditingController();
  List<({String id, String name, int qtyMilli})> _products = [];

  // stock take tab
  TakeInfo? _take;
  List<TakeLine> _lines = [];
  TakeReport? _report;

  // history tab
  AdjustmentHistory? _history;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  DateTime get _clock => (widget.now ?? DateTime.now)();

  Future<void> _load() async {
    final b = await repo.branchId();
    final base = await repo.db.query('select c.code, c.symbol, c.minor_units from currencies c join shops s on s.base_currency = c.code where c.deleted_at is null limit 1');
    if (b == null) {
      if (mounted) setState(() { _loaded = true; _note = 'Set up the shop and a branch first.'; });
      return;
    }
    final money = base.isEmpty ? _money : CurrencyInfo(base.first['code'] as String, (base.first['symbol'] as String?) ?? base.first['code'] as String, (base.first['minor_units'] as num).toInt());
    final prods = await repo.products(b, search: _search.text);
    final take = await repo.currentStockTake(b);
    final lines = take == null ? <TakeLine>[] : await repo.stockTakeLines(take.id);
    final report = take != null && take.status == 'counted' ? await repo.stockTakeReport(take.id) : null;
    final now = _clock;
    final to = now.millisecondsSinceEpoch + 86400000;
    final hist = await repo.history(to - 31 * 86400000, to, branchId: b);
    if (!mounted) return;
    setState(() { _branch = b; _money = money; _products = prods; _take = take; _lines = lines; _report = report; _history = hist; _loaded = true; });
  }

  Future<void> _guard(Future<void> Function() run) async {
    try {
      await run();
      if (mounted) setState(() => _note = null);
    } on SetupError catch (e) {
      if (mounted) setState(() => _note = e.message);
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Stock'),
          backgroundColor: Brand.navy,
          foregroundColor: Colors.white,
          bottom: const TabBar(labelColor: Colors.white, unselectedLabelColor: Colors.white70, indicatorColor: Brand.amber, tabs: [Tab(text: 'Adjust'), Tab(text: 'Stock take'), Tab(text: 'History')]),
        ),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : Column(children: [
                if (_note != null) Padding(padding: const EdgeInsets.all(12), child: Text(_note!, style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w600))),
                if (_branch != null) Expanded(child: TabBarView(children: [_adjustTab(), _takeTab(), _historyTab()])),
              ]),
      ),
    );
  }

  // ---- scanning ----

  /// Scan a product on the shelf to jump to it in the adjust list.
  Future<void> _scanToFind() async {
    final code = await scanOnce(context);
    if (code == null || widget.barcodes == null) return;
    final r = await widget.barcodes!.resolve(code);
    if (!mounted) return;
    if (r.status == ScanStatus.found || r.status == ScanStatus.inactive) {
      _search.text = r.productName ?? '';
      await _load();
    } else {
      setState(() => _note = 'No product has the barcode $code.');
    }
  }

  /// Scan-to-count: every scan of a product adds one to its counted figure (a scale label adds its weight).
  Future<void> _scanToCount(TakeInfo t) async {
    final bc = widget.barcodes;
    if (bc == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ScannerScreen(
        title: 'Scan to count',
        onCode: (code) async {
          final r = await bc.resolve(code);
          if (r.status == ScanStatus.error) return r.message;
          if (r.status != ScanStatus.found && r.status != ScanStatus.inactive) return 'No product has the barcode $code.';
          final lines = (await repo.stockTakeLines(t.id)).where((l) => l.productId == r.productId).toList();
          if (lines.isEmpty) return '${r.productName} is not in this stock take.';
          if (lines.length > 1) return '${r.productName} has several batches. Tap it in the list and count each batch.';
          final l = lines.first;
          final add = r.qtyMilli ?? 1000;
          final total = (l.countedMilli ?? 0) + add;
          await repo.recordCount(l.id, total);
          return '${l.product}: ${qtyText(total)} counted';
        },
      ),
    ));
    await _load();
  }

  // ---- adjust ----

  Widget _adjustTab() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: TextField(
          controller: _search,
          decoration: InputDecoration(
            prefixIcon: const Icon(Icons.search),
            labelText: 'Find a product',
            border: const OutlineInputBorder(),
            suffixIcon: widget.barcodes == null ? null : IconButton(tooltip: 'Scan', icon: const Icon(Icons.qr_code_scanner), onPressed: _scanToFind),
          ),
          onChanged: (_) => _load(),
        ),
      ),
      Expanded(
        child: _products.isEmpty
            ? const Center(child: Text('No stock-keeping products found.'))
            : ListView.separated(
                itemCount: _products.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = _products[i];
                  return ListTile(
                    title: Text(p.name),
                    subtitle: Text('${qtyText(p.qtyMilli)} on the shelf'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _adjust(p),
                  );
                },
              ),
      ),
    ]);
  }

  Future<void> _adjust(({String id, String name, int qtyMilli}) p) async {
    final buckets = await repo.buckets(_branch!, p.id);
    if (!mounted) return;
    var kind = AdjustKind.damaged;
    String? batch;
    final qty = TextEditingController();
    final why = TextEditingController();
    String? err;
    final done = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(p.name),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, children: [for (final k in adjustKinds) ChoiceChip(label: Text(k.label), selected: kind == k.kind, onSelected: (_) => setS(() => kind = k.kind))]),
              if (buckets.any((b) => b.batchId != null)) ...[
                const SizedBox(height: 8),
                DropdownButtonFormField<String?>(
                  initialValue: batch,
                  decoration: const InputDecoration(labelText: 'Batch'),
                  items: [
                    for (final b in buckets)
                      DropdownMenuItem(value: b.batchId, child: Text('${b.batchCode ?? 'No batch'}${b.expiryDate == null ? '' : ' (expires ${b.expiryDate})'}: ${qtyText(b.qtyMilli)}')),
                  ],
                  onChanged: (v) => batch = v,
                ),
              ],
              TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'How many')),
              TextField(controller: why, decoration: const InputDecoration(labelText: 'Reason')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final q = parseQty(qty.text);
                if (q == null || q <= 0) {
                  setS(() => err = 'Enter how many.');
                  return;
                }
                try {
                  await repo.adjustStock(branchId: _branch!, productId: p.id, batchId: batch, kind: kind, qtyMilli: q, reason: why.text);
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
    qty.dispose();
    why.dispose();
    if (done == true) {
      if (mounted) setState(() => _note = null);
      await _load();
    }
  }

  // ---- stock take ----

  Widget _takeTab() {
    final t = _take;
    if (t == null) {
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('A stock take counts every item on the shelves and fixes the figures in the app. Count with the shop quiet if you can; the app keeps sales made while you count.'),
        const SizedBox(height: 12),
        FilledButton.icon(icon: const Icon(Icons.fact_check_outlined), label: const Text('Start a stock take of everything'), onPressed: () => _guard(() async { await repo.startStockTake(branchId: _branch!); })),
      ]);
    }
    if (t.status == 'counted') return _review();
    final counted = _lines.where((l) => l.countedMilli != null).length;
    return Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Counting: $counted of ${_lines.length} lines counted. Tap a line to enter what you see on the shelf.', style: const TextStyle(fontWeight: FontWeight.w600))),
      if (widget.barcodes != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Align(alignment: Alignment.centerLeft, child: OutlinedButton.icon(onPressed: () => _scanToCount(t), icon: const Icon(Icons.qr_code_scanner), label: const Text('Scan to count')))),
      Expanded(
        child: ListView.separated(
          itemCount: _lines.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final l = _lines[i];
            return ListTile(
              title: Text(l.product),
              subtitle: l.batchCode == null ? null : Text('Batch ${l.batchCode}'),
              trailing: l.countedMilli == null ? const Text('Not counted', style: TextStyle(color: Colors.black45)) : Text(qtyText(l.countedMilli!), style: const TextStyle(fontWeight: FontWeight.w700, color: Brand.teal)),
              onTap: () => _count(l),
            );
          },
        ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          TextButton(onPressed: () => _confirm('Throw this stock take away? Nothing in stock is changed.', () => repo.cancelStockTake(t.id)), child: const Text('Cancel take')),
          const Spacer(),
          FilledButton(onPressed: counted == 0 ? null : () => _guard(() async { await repo.finishCounting(t.id); }), child: const Text('Finish counting')),
        ]),
      ),
    ]);
  }

  Future<void> _count(TakeLine l) async {
    final c = TextEditingController(text: l.countedMilli == null ? '' : qtyText(l.countedMilli!));
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(l.batchCode == null ? l.product : '${l.product} (batch ${l.batchCode})'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: c, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Counted on the shelf')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
          actions: [
            if (l.countedMilli != null) TextButton(onPressed: () async { await repo.recordCount(l.id, null); if (ctx.mounted) Navigator.pop(ctx, true); }, child: const Text('Clear')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final q = parseQty(c.text);
                if (q == null) {
                  setS(() => err = 'Enter a number (0 if none).');
                  return;
                }
                try {
                  await repo.recordCount(l.id, q);
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
    c.dispose();
    if (ok == true) await _load();
  }

  Widget _review() {
    final r = _report!;
    final diffs = [for (final l in r.lines) if (l.differenceMilli != null && l.differenceMilli != 0) l];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Check the differences, then approve to fix the figures in the app.', style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text('${r.countedLines} counted, ${r.uncountedLines} not counted (left unchanged).'),
          Text('Missing: ${_money.format(r.shortageMinor)} at cost.   Extra: ${_money.format(r.surplusMinor)} at cost.'),
        ]),
      ),
      Expanded(
        child: diffs.isEmpty
            ? const Center(child: Text('Every counted line matches.'))
            : ListView.separated(
                itemCount: diffs.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final d = diffs[i];
                  final up = d.differenceMilli! > 0;
                  return ListTile(
                    title: Text(d.line.batchCode == null ? d.line.product : '${d.line.product} (batch ${d.line.batchCode})'),
                    subtitle: Text('App said ${qtyText(d.line.expectedMilli)}, counted ${qtyText(d.line.countedMilli!)}'),
                    trailing: Text('${up ? '+' : ''}${qtyText(d.differenceMilli!)}', style: TextStyle(fontWeight: FontWeight.w700, color: up ? Brand.green : Brand.coral)),
                  );
                },
              ),
      ),
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(children: [
          TextButton(onPressed: () => _guard(() => repo.reopenCounting(r.take.id)), child: const Text('Back to counting')),
          const Spacer(),
          FilledButton(onPressed: () => _confirm('Approve this stock take? The stock figures will be corrected and this cannot be undone.', () async { await repo.approveStockTake(r.take.id); }), child: const Text('Approve')),
        ]),
      ),
    ]);
  }

  Future<void> _confirm(String text, Future<void> Function() action) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(text),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')), FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes'))],
      ),
    );
    if (ok == true) await _guard(action);
  }

  // ---- history ----

  Widget _historyTab() {
    final h = _history!;
    if (h.rows.isEmpty) return const Center(child: Text('No adjustments in the last 31 days.'));
    String when(int ms) {
      final d = DateTime.fromMillisecondsSinceEpoch(ms + _clock.timeZoneOffset.inMinutes * 60000, isUtc: true);
      String p(int v) => v.toString().padLeft(2, '0');
      return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
    }

    return ListView(children: [
      const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Last 31 days, valued at cost', style: TextStyle(fontWeight: FontWeight.w700))),
      for (final s in h.summary) ListTile(dense: true, title: Text(_typeNames[s.type] ?? s.type), subtitle: Text('${s.count} time(s)'), trailing: Text(_money.format(s.valueMinor), style: TextStyle(fontWeight: FontWeight.w700, color: s.valueMinor < 0 ? Brand.coral : Brand.green))),
      const Divider(),
      for (final r in h.rows)
        ListTile(
          dense: true,
          title: Text('${r.product}: ${r.qtyMilli > 0 ? '+' : ''}${qtyText(r.qtyMilli)}'),
          subtitle: Text('${_typeNames[r.type] ?? r.type} - ${r.reason ?? ''}\n${when(r.at)}${r.user == null ? '' : ' by ${r.user}'}'),
          isThreeLine: true,
          trailing: Text(_money.format(r.valueMinor)),
        ),
    ]);
  }
}
