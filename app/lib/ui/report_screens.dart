import 'package:flutter/material.dart';

import '../reports/report_repository.dart';
import '../selling/catalog.dart';
import '../l10n/strings.dart';
import '../share/report_text.dart';
import '../share/whatsapp.dart';
import 'theme.dart';

/// Reports for the owner or manager. Days follow the phone's clock (the shop's local time).
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key, required this.repo, this.now, this.shopName});
  final ReportRepository repo;
  final String? shopName;
  final DateTime Function()? now;
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

enum _Preset { today, yesterday, week, month, custom }

class _ReportScreenState extends State<ReportScreen> {
  _Preset _preset = _Preset.today;
  DateTimeRange? _custom;
  Map<String, CurrencyInfo> _cur = {};
  String _base = 'USD';
  bool _loaded = false;
  String? _error;

  SalesSummary? _summary;
  List<DayRow> _days = [];
  List<ProductRow> _top = [];
  String _by = 'revenue';
  List<TakingRow> _takings = [];
  StockValue? _stock;
  List<OutOfStock> _out = [];
  List<ExpiringBatch> _expiring = [];
  Receivables? _recv;
  List<CashUpRow> _cashUps = [];

  DateTime get _now => (widget.now ?? DateTime.now)();
  int get _offsetMin => _now.timeZoneOffset.inMinutes;

  /// Local midnight as UTC ms.
  int _midnight(DateTime d) => DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch - _offsetMin * 60000;

  DateRange _range() {
    final n = _now;
    final today = _midnight(n);
    const day = 86400000;
    switch (_preset) {
      case _Preset.today:
        return DateRange(today, today + day);
      case _Preset.yesterday:
        return DateRange(today - day, today);
      case _Preset.week:
        return DateRange(today - 6 * day, today + day);
      case _Preset.month:
        return DateRange(_midnight(DateTime(n.year, n.month, 1)), today + day);
      case _Preset.custom:
        final c = _custom ?? DateTimeRange(start: n, end: n);
        return DateRange(_midnight(c.start), _midnight(c.end) + day);
    }
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final repo = widget.repo;
      final rows = await repo.db.query('select code, symbol, minor_units from currencies where deleted_at is null order by code');
      final cur = {for (final r in rows) r['code'] as String: CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, (r['minor_units'] as num).toInt())};
      final r = _range();
      final today = _now;
      final todayStr = '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
      final base = await repo.baseCurrency();
      final s = await repo.salesSummary(r);
      final d = await repo.dailySales(r, _offsetMin);
      final t = await repo.topProducts(r, by: _by);
      final tk = await repo.takings(r);
      final sv = await repo.stockValue();
      final oos = await repo.outOfStock();
      final ex = await repo.expiringBatches(todayStr, 14);
      final rc = await repo.receivables();
      final cu = await repo.cashUps(r);
      if (!mounted) return;
      setState(() {
        _cur = cur; _base = base; _summary = s; _days = d; _top = t; _takings = tk; _stock = sv; _out = oos; _expiring = ex; _recv = rc; _cashUps = cu;
        _loaded = true; _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() { _error = 'Could not build the report: $e'; _loaded = true; });
    }
  }

  CurrencyInfo _info(String code) => _cur[code] ?? CurrencyInfo(code, code, 2);
  String _m(int minor, [String? code]) => _info(code ?? _base).format(minor);
  String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
  String _time(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms + _offsetMin * 60000, isUtc: true);
    String p(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${p(d.month)}-${p(d.day)} ${p(d.hour)}:${p(d.minute)}';
  }

  Future<void> _pick(_Preset p) async {
    if (p == _Preset.custom) {
      final n = _now;
      final r = await showDateRangePicker(context: context, firstDate: DateTime(n.year - 5), lastDate: DateTime(n.year, n.month, n.day), initialDateRange: _custom);
      if (r == null) return;
      _custom = r;
    }
    setState(() { _preset = p; _loaded = false; });
    await _load();
  }

  String _shareText() => reportText(shopName: widget.shopName ?? 'My shop', periodLabel: _labels[_preset]!, summary: _summary!, top: _top);

  static const _labels = {_Preset.today: 'Today', _Preset.yesterday: 'Yesterday', _Preset.week: 'Last 7 days', _Preset.month: 'This month', _Preset.custom: 'Pick dates'};

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Reports'),
          actions: [
            IconButton(
              tooltip: 'Send this report on WhatsApp',
              icon: const Icon(Icons.chat),
              onPressed: _summary == null ? null : () => openOrCopy(context, whatsappLink(_shareText()), _shareText()),
            ),
          ],
          bottom: TabBar(isScrollable: true, tabs: [
            Tab(text: tr('Sales')), Tab(text: tr('Best sellers')), Tab(text: tr('Takings')), Tab(text: tr('Stock')), Tab(text: tr('Owed')), Tab(text: tr('Cash-ups')),
          ]),
        ),
        body: Column(children: [
          SizedBox(
            height: 52,
            child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), children: [
              for (final p in _Preset.values)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(label: Text(tr(_labels[p]!)), selected: _preset == p, onSelected: (_) => _pick(p)),
                ),
            ]),
          ),
          Expanded(
            child: !_loaded
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
                    : TabBarView(children: [_sales(), _best(), _takingsTab(), _stockTab(), _owed(), _cashUpTab()]),
          ),
        ]),
      ),
    );
  }

  Widget _stat(String label, String value, {Color? color}) => Expanded(
        child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: const TextStyle(fontSize: 12, color: Colors.black54)),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        ]))),
      );

  Widget _head(String t) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 6), child: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)));
  Widget _empty(String t) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(t, textAlign: TextAlign.center)));

  Widget _sales() {
    final s = _summary!;
    if (s.sales == 0 && s.returns == 0 && s.openLayby.isEmpty) return _empty('No sales in this period.');
    return ListView(padding: const EdgeInsets.all(8), children: [
      Row(children: [_stat('Sales (${s.sales})', _m(s.revenueMinor)), _stat('Average sale', _m(s.averageSaleMinor))]),
      Row(children: [_stat('Tax in sales', _m(s.taxMinor)), _stat('Profit', _m(s.profitMinor), color: s.profitMinor < 0 ? Brand.coral : Brand.green)]),
      if (s.returns > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('${s.returns} return(s) already taken off these figures.', style: const TextStyle(color: Colors.black54))),
      if (s.linesWithoutCost > 0)
        Padding(padding: const EdgeInsets.fromLTRB(8, 4, 8, 0), child: Text('${s.linesWithoutCost} item line(s) have no cost price, so profit is higher than it really is. Add costs to the products to fix this.', style: const TextStyle(color: Brand.orange))),
      _head('By currency (base: $_base)'),
      for (final c in s.byCurrency)
        ListTile(dense: true, title: Text(c.currency), subtitle: Text('${c.sales} sale(s), returns ${_m(c.returnsMinor, c.currency)}'), trailing: Text(_m(c.netMinor, c.currency), style: const TextStyle(fontWeight: FontWeight.w700))),
      if (s.openLayby.isNotEmpty) ...[
        _head('Laybys not collected yet'),
        for (final l in s.openLayby)
          ListTile(dense: true, title: Text('${l.count} layby(s) in ${l.currency}'), subtitle: Text('Paid so far ${_m(l.paidMinor, l.currency)}'), trailing: Text(_m(l.valueMinor, l.currency))),
      ],
      if (_days.length > 1) ...[
        _head('Day by day'),
        for (final d in _days)
          ListTile(dense: true, title: Text(d.day), subtitle: Text('${d.sales} sale(s)'), trailing: Text(_m(d.netMinor), style: const TextStyle(fontWeight: FontWeight.w600))),
      ],
    ]);
  }

  Widget _best() {
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
        child: Row(children: [
          for (final b in const [('revenue', 'Money'), ('qty', 'Quantity'), ('profit', 'Profit')])
            Padding(padding: const EdgeInsets.only(right: 8), child: ChoiceChip(label: Text(b.$2), selected: _by == b.$1, onSelected: (_) async { _by = b.$1; setState(() => _loaded = false); await _load(); })),
        ]),
      ),
      Expanded(
        child: _top.isEmpty
            ? _empty('Nothing sold in this period.')
            : ListView.separated(
                itemCount: _top.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final p = _top[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(radius: 14, child: Text('${i + 1}', style: const TextStyle(fontSize: 12))),
                    title: Text(p.name),
                    subtitle: Text('${_qty(p.qtyMilli)} sold, profit ${_m(p.profitMinor)}'),
                    trailing: Text(_m(p.revenueMinor), style: const TextStyle(fontWeight: FontWeight.w600)),
                  );
                },
              ),
      ),
    ]);
  }

  Widget _takingsTab() {
    if (_takings.isEmpty) return _empty('No money moved in this period.');
    return ListView(children: [
      _head('Money received, minus money paid back'),
      for (final t in _takings)
        ListTile(
          dense: true,
          title: Text('${t.method} (${t.currency})'),
          subtitle: Text('In ${_m(t.receivedMinor, t.currency)}, paid back ${_m(t.paidBackMinor, t.currency)}'),
          trailing: Text(_m(t.netMinor, t.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
    ]);
  }

  Widget _stockTab() {
    final s = _stock!;
    return ListView(padding: const EdgeInsets.all(8), children: [
      Row(children: [_stat('Stock value (at cost)', _m(s.totalMinor)), _stat('Products in stock', '${s.products}')]),
      if (s.withoutCost > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('${s.withoutCost} product(s) have no cost price and are not in the total.', style: const TextStyle(color: Brand.orange))),
      if (s.negative > 0) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('${s.negative} product(s) show negative stock. Check them.', style: const TextStyle(color: Brand.coral))),
      _head('Where the money is'),
      for (final r in s.rows) ListTile(dense: true, title: Text(r.name), subtitle: Text('${_qty(r.qtyMilli)} in stock'), trailing: Text(_m(r.valueMinor))),
      _head('Out of stock (${_out.length})'),
      if (_out.isEmpty) const ListTile(dense: true, title: Text('Nothing is out of stock.')),
      for (final o in _out) ListTile(dense: true, title: Text(o.name), trailing: Text(_qty(o.qtyMilli))),
      _head('Expired or expiring in 14 days (${_expiring.length})'),
      if (_expiring.isEmpty) const ListTile(dense: true, title: Text('No batches close to expiry.')),
      for (final e in _expiring)
        ListTile(
          dense: true,
          title: Text(e.name),
          subtitle: Text('${e.batchCode == null ? 'No batch code' : 'Batch ${e.batchCode}'}, ${_qty(e.qtyMilli)} left'),
          trailing: Text(e.expired ? 'EXPIRED ${e.expiryDate}' : e.expiryDate, style: TextStyle(color: e.expired ? Brand.coral : Brand.orange, fontWeight: FontWeight.w600)),
        ),
    ]);
  }

  Widget _owed() {
    final r = _recv!;
    if (r.debtors.isEmpty) return _empty('Nobody owes the shop money.');
    return ListView(children: [
      _head('Total owed'),
      for (final t in r.byCurrency) ListTile(dense: true, title: Text('${t.customers} customer(s)'), trailing: Text(_m(t.owedMinor, t.currency), style: const TextStyle(fontWeight: FontWeight.w700))),
      _head('Who owes'),
      for (final d in r.debtors)
        ListTile(dense: true, title: Text(d.name), subtitle: d.phone == null ? null : Text(d.phone!), trailing: Text(_m(d.owedMinor, d.currency), style: const TextStyle(fontWeight: FontWeight.w600))),
    ]);
  }

  Widget _cashUpTab() {
    if (_cashUps.isEmpty) return _empty('No shifts were closed in this period.');
    return ListView(children: [
      for (final c in _cashUps)
        Card(
          margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${c.user ?? 'Cashier'}, closed ${_time(c.closedAt)}', style: const TextStyle(fontWeight: FontWeight.w700)),
            Text('Opened ${_time(c.openedAt)}', style: const TextStyle(color: Colors.black54, fontSize: 12)),
            const SizedBox(height: 6),
            for (final x in c.currencies)
              Row(children: [
                Expanded(child: Text('${x.currency}: expected ${_m(x.expectedMinor, x.currency)}, counted ${_m(x.countedMinor, x.currency)}')),
                Text(
                  x.differenceMinor == 0 ? 'Correct' : (x.differenceMinor > 0 ? 'Over ${_m(x.differenceMinor, x.currency)}' : 'Short ${_m(-x.differenceMinor, x.currency)}'),
                  style: TextStyle(fontWeight: FontWeight.w700, color: x.differenceMinor == 0 ? Brand.green : (x.differenceMinor < 0 ? Brand.coral : Brand.orange)),
                ),
              ]),
          ])),
        ),
    ]);
  }
}
