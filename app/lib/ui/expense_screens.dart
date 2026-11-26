import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../expenses/expense_repository.dart';
import '../l10n/strings.dart';
import '../selling/catalog.dart' show CatalogRepository, CurrencyInfo;
import '../setup/setup_repository.dart' show SetupError;
import 'theme.dart';

/// Money spent on running the shop, with a total for today, this week or this month.
class ExpensesScreen extends StatefulWidget {
  const ExpensesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ExpensesScreen> createState() => _ExpensesScreenState();
}

class _ExpensesScreenState extends State<ExpensesScreen> {
  ExpenseRepository get repo => widget.controller.expenseRepository()!;
  String _range = 'week';
  List<ExpenseRow> _rows = [];
  int _total = 0;
  CurrencyInfo _cur = const CurrencyInfo('USD', r'$', 2);
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  (int, int) _bounds() {
    final n = DateTime.now();
    final today = DateTime(n.year, n.month, n.day);
    final from = switch (_range) {
      'today' => today,
      'month' => DateTime(n.year, n.month, 1),
      _ => today.subtract(const Duration(days: 6)),
    };
    return (from.millisecondsSinceEpoch, today.add(const Duration(days: 1)).millisecondsSinceEpoch);
  }

  Future<void> _load() async {
    final setup = await CatalogRepository(widget.controller.database!.sql).setup();
    final (from, to) = _bounds();
    final rows = await repo.list(from, to);
    final total = await repo.total(from, to);
    if (!mounted) return;
    setState(() {
      if (setup != null) _cur = setup.currency(setup.baseCurrency);
      _rows = rows;
      _total = total;
    });
  }

  Future<void> _add() async {
    await repo.addSuggestedCategories();
    final cats = await repo.categories();
    if (!mounted) return;
    final amount = TextEditingController();
    final payee = TextEditingController();
    final note = TextEditingController();
    String? cat;
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(tr('Add expense')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: amount, autofocus: true, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount (${_cur.code})')),
              DropdownButtonFormField<String>(
                initialValue: cat,
                decoration: const InputDecoration(labelText: 'What was it for?'),
                items: [for (final c in cats) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String))],
                onChanged: (v) => setD(() => cat = v),
              ),
              TextField(controller: payee, decoration: const InputDecoration(labelText: 'Paid to - optional')),
              TextField(controller: note, decoration: const InputDecoration(labelText: 'Note - optional')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('Cancel'))),
            FilledButton(
              onPressed: () async {
                final minor = _cur.parse(amount.text);
                if (minor == null || minor <= 0) {
                  setD(() => err = 'Enter the amount spent.');
                  return;
                }
                try {
                  await repo.add(amountMinor: minor, categoryId: cat, payee: payee.text, note: note.text);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on SetupError catch (e) {
                  setD(() => err = e.message);
                }
              },
              child: Text(tr('Save')),
            ),
          ],
        ),
      ),
    );
    amount.dispose();
    payee.dispose();
    note.dispose();
    if (ok == true) await _load();
  }

  Future<void> _undo(ExpenseRow r) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Cancel this entry?'),
        content: const Text('A matching entry is added to cancel it out. The original stays in the history.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('No')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Yes, cancel it')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await repo.undo(r.id);
      setState(() => _note = null);
    } on SetupError catch (e) {
      setState(() => _note = e.message);
    }
    await _load();
  }

  String _day(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Expenses')), backgroundColor: Brand.navy, foregroundColor: Colors.white),
        floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: Text(tr('Add expense'))),
        body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 90), children: [
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [ButtonSegment(value: 'today', label: Text('Today')), ButtonSegment(value: 'week', label: Text('7 days')), ButtonSegment(value: 'month', label: Text('This month'))],
            selected: {_range},
            onSelectionChanged: (s) {
              setState(() => _range = s.first);
              _load();
            },
          ),
          const SizedBox(height: 12),
          Card(
            color: Brand.coral.withValues(alpha: 0.1),
            child: Padding(padding: const EdgeInsets.all(16), child: Text('Spent: ${_cur.format(_total)}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
          ),
          if (_note != null) Text(_note!, style: const TextStyle(color: Brand.coral)),
          if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing recorded for this period.', textAlign: TextAlign.center)),
          for (final r in _rows)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('${r.category ?? 'Expense'}${r.payee == null ? '' : ' - ${r.payee}'}'),
              subtitle: Text('${_day(r.spentAt)}${r.note == null || r.note!.startsWith('Correction of') ? '' : '  ${r.note}'}${r.note != null && r.note!.startsWith('Correction of') ? '  (correction)' : ''}'),
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Text(_cur.format(r.amountMinor), style: const TextStyle(fontWeight: FontWeight.w700)),
                if (r.amountMinor > 0) IconButton(tooltip: 'Cancel this entry', icon: const Icon(Icons.undo), onPressed: () => _undo(r)),
              ]),
            ),
        ]),
      );
}

/// Products that are running out, so you know what to buy.
class LowStockScreen extends StatefulWidget {
  const LowStockScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LowStockScreen> createState() => _LowStockScreenState();
}

class _LowStockScreenState extends State<LowStockScreen> {
  List<LowStockRow> _rows = [];
  int _levelMilli = 5000;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final db = widget.controller.database!.sql;
    final setup = await CatalogRepository(db).setup();
    final settings = await widget.controller.settingsRepository()?.load() ?? const <String, String>{};
    final level = (int.tryParse(settings['low_stock_level'] ?? '5') ?? 5) * 1000;
    final rows = setup == null ? <LowStockRow>[] : await lowStock(db, setup.branchId, level);
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _levelMilli = level;
      _loaded = true;
    });
  }

  String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(tr('Low stock')), backgroundColor: Brand.navy, foregroundColor: Colors.white),
        body: !_loaded
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                Text('Showing items with ${_qty(_levelMilli)} or fewer left. You can change this in Shop settings, Stock.', style: const TextStyle(color: Colors.black54)),
                if (_rows.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Text('Nothing is running low.', textAlign: TextAlign.center, style: TextStyle(fontSize: 16))),
                for (final r in _rows)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(r.name),
                    trailing: Text(r.onHandMilli <= 0 ? 'Out of stock' : '${_qty(r.onHandMilli)} left', style: TextStyle(fontWeight: FontWeight.w800, color: r.onHandMilli <= 0 ? Brand.coral : Brand.orange)),
                  ),
              ]),
      );
}
