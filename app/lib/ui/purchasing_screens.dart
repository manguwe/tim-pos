import 'package:flutter/material.dart';

import '../barcodes/barcode_repository.dart' show BarcodeRepository, ScanStatus;
import '../purchasing/purchasing_repository.dart';
import '../selling/catalog.dart';
import '../setup/setup_repository.dart' show SetupError;
import 'barcode_screens.dart' show scanOnce;
import 'setup_screens.dart' show parseQty;
import 'theme.dart';

String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

String _day(int ms, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms + offsetMin * 60000, isUtc: true);
  String p(int v) => v.toString().padLeft(2, '0');
  return '${d.year}-${p(d.month)}-${p(d.day)}';
}

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const _statusNames = {'draft': 'Draft', 'sent': 'Sent', 'partly_received': 'Partly received', 'received': 'Received', 'cancelled': 'Cancelled'};
const _ledgerNames = {'purchase': 'Goods received', 'payment': 'Payment', 'return': 'Goods returned', 'adjustment': 'Adjustment'};

class _Money {
  _Money(this.currencies, this.base);
  final Map<String, CurrencyInfo> currencies;
  final String base;
  CurrencyInfo info(String code) => currencies[code] ?? CurrencyInfo(code, code, 2);
  String fmt(int minor, String code) => info(code).format(minor);
  List<CurrencyInfo> get list => currencies.values.toList();
}

Future<_Money> _loadMoney(PurchasingRepository repo) async {
  final rows = await repo.db.query('select code, symbol, minor_units from currencies where deleted_at is null and is_active = 1 order by code');
  final base = (await repo.db.query('select base_currency from shops where deleted_at is null limit 1')).first['base_currency'] as String;
  return _Money({for (final r in rows) r['code'] as String: CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, (r['minor_units'] as num).toInt())}, base);
}

String _owedText(List<Owed> owes, _Money m) => owes.where((o) => o.amountMinor != 0).map((o) => m.fmt(o.amountMinor, o.currency)).join(' + ');

Future<DateTime?> _pickDate(BuildContext context, {DateTime? first, DateTime? initial}) {
  final now = DateTime.now();
  return showDatePicker(context: context, initialDate: initial ?? now, firstDate: first ?? DateTime(now.year - 1), lastDate: DateTime(now.year + 5));
}

// ============================================================ suppliers and orders

class SuppliersScreen extends StatefulWidget {
  const SuppliersScreen({super.key, required this.repo, required this.canPay});
  final PurchasingRepository repo;
  final bool canPay;
  @override
  State<SuppliersScreen> createState() => _SuppliersScreenState();
}

class _SuppliersScreenState extends State<SuppliersScreen> {
  PurchasingRepository get repo => widget.repo;
  _Money? _m;
  List<SupplierSummary> _suppliers = [];
  List<PoRow> _orders = [];
  final _search = TextEditingController();
  bool _onlyOwed = false;

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

  Future<void> _load() async {
    final m = await _loadMoney(repo);
    final s = await repo.listSuppliers(search: _search.text, onlyOwed: _onlyOwed);
    final o = await repo.listPurchaseOrders(statuses: ['draft', 'sent', 'partly_received']);
    if (mounted) setState(() { _m = m; _suppliers = s; _orders = o; });
  }

  Future<void> _addSupplier() async {
    final id = await showSupplierDialog(context, repo);
    if (id != null) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Suppliers and orders'),
          backgroundColor: Brand.navy,
          foregroundColor: Colors.white,
          bottom: const TabBar(labelColor: Colors.white, unselectedLabelColor: Colors.white70, indicatorColor: Brand.amber, tabs: [Tab(text: 'Suppliers'), Tab(text: 'Open orders')]),
        ),
        floatingActionButton: FloatingActionButton.extended(onPressed: _addSupplier, icon: const Icon(Icons.add), label: const Text('Supplier')),
        body: m == null
            ? const Center(child: CircularProgressIndicator())
            : TabBarView(children: [
                Column(children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                    child: TextField(controller: _search, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), labelText: 'Find a supplier', border: OutlineInputBorder()), onChanged: (_) => _load()),
                  ),
                  SwitchListTile(title: const Text('Only suppliers I owe'), value: _onlyOwed, onChanged: (v) { _onlyOwed = v; _load(); }),
                  Expanded(
                    child: _suppliers.isEmpty
                        ? const Center(child: Text('No suppliers yet. Tap Supplier to add one.'))
                        : ListView.separated(
                            itemCount: _suppliers.length,
                            separatorBuilder: (_, __) => const Divider(height: 1),
                            itemBuilder: (_, i) {
                              final s = _suppliers[i];
                              final owed = _owedText(s.owes, m);
                              return ListTile(
                                title: Text(s.name),
                                subtitle: Text([if (s.phone != null) s.phone!, if (s.terms != null) s.terms!].join(' - ')),
                                trailing: owed.isEmpty ? null : Text('Owe $owed', style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w700)),
                                onTap: () async {
                                  await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SupplierDetailScreen(repo: repo, supplierId: s.id, canPay: widget.canPay)));
                                  await _load();
                                },
                              );
                            },
                          ),
                  ),
                ]),
                _orders.isEmpty
                    ? const Center(child: Text('No open orders.'))
                    : ListView.separated(
                        itemCount: _orders.length,
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (_, i) {
                          final o = _orders[i];
                          return ListTile(
                            title: Text('${o.orderNo} - ${o.supplier}'),
                            subtitle: Text(_statusNames[o.status] ?? o.status),
                            trailing: Text(m.fmt(o.totalMinor, o.currency), style: const TextStyle(fontWeight: FontWeight.w600)),
                            onTap: () async {
                              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => PurchaseOrderScreen(repo: repo, orderId: o.id)));
                              await _load();
                            },
                          );
                        },
                      ),
              ]),
      ),
    );
  }
}

/// Add or edit a supplier. Returns the supplier id, or null when cancelled.
Future<String?> showSupplierDialog(BuildContext context, PurchasingRepository repo, {SupplierSummary? existing, String? address}) async {
  final name = TextEditingController(text: existing?.name);
  final phone = TextEditingController(text: existing?.phone);
  final addr = TextEditingController(text: address);
  final terms = TextEditingController(text: existing?.terms);
  String? err;
  final id = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(existing == null ? 'New supplier' : 'Edit supplier'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
            TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            TextField(controller: addr, decoration: const InputDecoration(labelText: 'Address')),
            TextField(controller: terms, decoration: const InputDecoration(labelText: 'Payment terms (for example 30 days)')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              try {
                final id = await repo.saveSupplier(SupplierInput(id: existing?.id, name: name.text, phone: phone.text, address: addr.text, terms: terms.text, isActive: existing?.isActive ?? true));
                if (ctx.mounted) Navigator.pop(ctx, id);
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
  for (final c in [name, phone, addr, terms]) {
    c.dispose();
  }
  return id;
}

// ============================================================ supplier detail

class SupplierDetailScreen extends StatefulWidget {
  const SupplierDetailScreen({super.key, required this.repo, required this.supplierId, required this.canPay});
  final PurchasingRepository repo;
  final String supplierId;
  final bool canPay;
  @override
  State<SupplierDetailScreen> createState() => _SupplierDetailState();
}

class _SupplierDetailState extends State<SupplierDetailScreen> {
  PurchasingRepository get repo => widget.repo;
  _Money? _m;
  SupplierSummary? _s;
  List<SupplierStatementLine> _statement = [];
  List<PoRow> _orders = [];
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await _loadMoney(repo);
    final all = await repo.listSuppliers(includeInactive: true);
    final s = all.where((x) => x.id == widget.supplierId).firstOrNull;
    final st = await repo.supplierStatement(widget.supplierId);
    final o = await repo.listPurchaseOrders(supplierId: widget.supplierId);
    if (mounted) setState(() { _m = m; _s = s; _statement = st.reversed.toList(); _orders = o; });
  }

  Future<void> _push(Widget w) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    await _load();
  }

  Future<void> _pay() async {
    final s = _s!;
    final debts = s.owes.where((o) => o.amountMinor > 0).toList();
    if (debts.isEmpty) {
      setState(() => _note = 'You do not owe this supplier anything.');
      return;
    }
    final done = await showPaySupplierDialog(context, repo, supplierId: s.id, debts: debts, money: _m!);
    if (done != null) setState(() => _note = done);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m, s = _s;
    return Scaffold(
      appBar: AppBar(
        title: Text(s?.name ?? 'Supplier'),
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        actions: [if (s != null) IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () async { if (await showSupplierDialog(context, repo, existing: s) != null) await _load(); })],
      ),
      body: m == null || s == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (s.phone != null) Text('Phone ${s.phone}'),
              if (s.terms != null) Text('Terms: ${s.terms}'),
              const SizedBox(height: 8),
              Text(_owedText(s.owes, m).isEmpty ? 'You owe nothing.' : 'You owe ${_owedText(s.owes, m)}', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: _owedText(s.owes, m).isEmpty ? Brand.teal : Brand.coral)),
              if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: const TextStyle(color: Brand.teal, fontWeight: FontWeight.w600))),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                FilledButton.icon(icon: const Icon(Icons.local_shipping_outlined), label: const Text('Receive goods'), onPressed: () => _push(ReceiveGoodsScreen(repo: repo, supplierId: s.id, supplierName: s.name))),
                OutlinedButton.icon(icon: const Icon(Icons.note_add_outlined), label: const Text('New order'), onPressed: () => _push(OrderFormScreen(repo: repo, supplierId: s.id, supplierName: s.name))),
                OutlinedButton.icon(icon: const Icon(Icons.undo), label: const Text('Return goods'), onPressed: () => _push(SupplierReturnScreen(repo: repo, supplierId: s.id, supplierName: s.name))),
                if (widget.canPay) OutlinedButton.icon(icon: const Icon(Icons.payments_outlined), label: const Text('Pay supplier'), onPressed: _pay),
              ]),
              if (_orders.isNotEmpty) ...[
                const Padding(padding: EdgeInsets.only(top: 20, bottom: 4), child: Text('Orders', style: TextStyle(fontWeight: FontWeight.w700))),
                for (final o in _orders.take(10))
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(o.orderNo),
                    subtitle: Text(_statusNames[o.status] ?? o.status),
                    trailing: Text(m.fmt(o.totalMinor, o.currency)),
                    onTap: () => _push(PurchaseOrderScreen(repo: repo, orderId: o.id)),
                  ),
              ],
              const Padding(padding: EdgeInsets.only(top: 20, bottom: 4), child: Text('Account', style: TextStyle(fontWeight: FontWeight.w700))),
              if (_statement.isEmpty) const Text('Nothing yet.'),
              for (final l in _statement)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${_ledgerNames[l.type] ?? l.type}${l.ref == null ? '' : ' (${l.ref})'}'),
                  subtitle: Text(_day(l.at, DateTime.now().timeZoneOffset.inMinutes)),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(m.fmt(l.amountMinor, l.currency), style: TextStyle(fontWeight: FontWeight.w700, color: l.amountMinor < 0 ? Brand.green : Brand.coral)),
                    Text('Owe ${m.fmt(l.balanceMinor, l.currency)}', style: const TextStyle(fontSize: 11, color: Colors.black54)),
                  ]),
                ),
            ]),
    );
  }
}

/// Pays a supplier. Returns a one-line result to show, or null when cancelled.
Future<String?> showPaySupplierDialog(BuildContext context, PurchasingRepository repo, {required String supplierId, required List<Owed> debts, required _Money money}) async {
  final methods = await repo.db.query('select code, name, requires_reference from payment_methods where deleted_at is null and is_active = 1 order by name');
  if (!context.mounted) return null;
  var debt = debts.first.currency;
  var method = methods.any((x) => x['code'] == 'cash') ? 'cash' : methods.first['code'] as String;
  var payCur = debt;
  final amount = TextEditingController();
  final ref = TextEditingController();
  String? err;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) {
        final owed = debts.firstWhere((d) => d.currency == debt).amountMinor;
        final needsRef = methods.where((x) => x['code'] == method).any((x) => x['requires_reference'] == 1);
        return AlertDialog(
          title: const Text('Pay supplier'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (debts.length > 1) Wrap(spacing: 8, children: [for (final d in debts) ChoiceChip(label: Text('Owe ${money.fmt(d.amountMinor, d.currency)}'), selected: debt == d.currency, onSelected: (_) => setS(() { debt = d.currency; payCur = d.currency; }))]),
              Text('You owe ${money.fmt(owed, debt)}'),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [for (final x in methods) ChoiceChip(label: Text(x['name'] as String), selected: method == x['code'], onSelected: (_) => setS(() => method = x['code'] as String))]),
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [for (final c in money.list) ChoiceChip(label: Text(c.code), selected: payCur == c.code, onSelected: (_) => setS(() => payCur = c.code))]),
              TextField(controller: amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount in $payCur')),
              if (payCur == debt)
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton(
                    onPressed: () => amount.text = _plainAmount(owed, money.info(debt).minorUnits),
                    child: const Text('Pay all'),
                  ),
                ),
              if (needsRef) TextField(controller: ref, decoration: const InputDecoration(labelText: 'Confirmation reference')),
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final minor = money.info(payCur).parse(amount.text);
                if (minor == null || minor <= 0) {
                  setS(() => err = 'Enter the amount.');
                  return;
                }
                try {
                  final r = await repo.paySupplier(supplierId: supplierId, debtCurrency: debt, methodCode: method, currency: payCur, amountMinor: minor, reference: ref.text);
                  final left = r.balanceAfterMinor > 0 ? '${money.fmt(r.balanceAfterMinor, r.debtCurrency)} still owed.' : 'Paid in full.';
                  if (ctx.mounted) Navigator.pop(ctx, 'Paid ${money.fmt(r.appliedMinor, r.debtCurrency)}. $left${r.cashOutRecorded ? ' Recorded as cash out on your shift.' : ''}');
                } on SetupError catch (e) {
                  setS(() => err = e.message);
                }
              },
              child: const Text('Pay'),
            ),
          ],
        );
      },
    ),
  );
  amount.dispose();
  ref.dispose();
  return result;
}

String _plainAmount(int minor, int minorUnits) {
  if (minorUnits == 0) return '$minor';
  var p = 1;
  for (var i = 0; i < minorUnits; i++) {
    p *= 10;
  }
  return '${minor ~/ p}.${(minor % p).toString().padLeft(minorUnits, '0')}';
}

// ============================================================ lines editor (orders, receipts, returns)

class _Line {
  _Line({required this.productId, required this.name, required this.qtyMilli, required this.costMinor, this.batchCode, this.expiry, this.maxMilli});
  final String productId, name;
  int qtyMilli, costMinor;
  String? batchCode, expiry;
  final int? maxMilli; // most that can be received on an order
}

class _LinesEditor extends StatefulWidget {
  const _LinesEditor({required this.repo, required this.lines, required this.currency, required this.money, required this.onChanged, this.supplierId, this.withBatch = false, this.canAdd = true});
  final PurchasingRepository repo;
  final List<_Line> lines;
  final String currency;
  final _Money money;
  final VoidCallback onChanged;
  final String? supplierId;
  final bool withBatch, canAdd;
  @override
  State<_LinesEditor> createState() => _LinesEditorState();
}

class _LinesEditorState extends State<_LinesEditor> {
  CurrencyInfo get _cur => widget.money.info(widget.currency);
  BarcodeRepository get _barcodes => BarcodeRepository(db: widget.repo.db, shopId: widget.repo.shopId, deviceId: widget.repo.deviceId, userId: widget.repo.userId);

  Future<void> _add() async {
    final p = await _pickProduct();
    if (p == null || !mounted) return;
    int cost = 0;
    if (widget.supplierId != null) {
      final lc = await widget.repo.lastCost(widget.supplierId!, p.id);
      if (lc != null && lc.currency == widget.currency) cost = lc.costMinor;
    }
    if (cost == 0 && p.costMinor != null && widget.currency == widget.money.base) cost = p.costMinor!;
    final line = _Line(productId: p.id, name: p.name, qtyMilli: 1000, costMinor: cost);
    if (await _edit(line, isNew: true) == true) {
      final i = widget.lines.indexWhere((l) => l.productId == line.productId && l.batchCode == line.batchCode && l.expiry == line.expiry);
      setState(() {
        if (i >= 0) {
          widget.lines[i].qtyMilli += line.qtyMilli;
          widget.lines[i].costMinor = line.costMinor;
        } else {
          widget.lines.add(line);
        }
      });
      widget.onChanged();
    }
  }

  Future<({String id, String name, int? costMinor})?> _pickProduct() async {
    final search = TextEditingController();
    var list = await widget.repo.products();
    if (!mounted) return null;
    final r = await showDialog<({String id, String name, int? costMinor})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: const Text('Choose a product'),
          content: SizedBox(
            width: double.maxFinite,
            height: 380,
            child: Column(children: [
              TextField(
                controller: search,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  labelText: 'Search or scan',
                  suffixIcon: IconButton(
                          tooltip: 'Scan',
                          icon: const Icon(Icons.qr_code_scanner),
                          onPressed: () async {
                            final code = await scanOnce(ctx);
                            if (code == null) return;
                            final r = await _barcodes.resolve(code);
                            if (r.status == ScanStatus.found) {
                              final hit = (await widget.repo.products(search: r.productName ?? '')).where((p) => p.id == r.productId).firstOrNull;
                              if (hit != null && ctx.mounted) Navigator.pop(ctx, hit);
                            } else {
                              search.text = code;
                              final l = await widget.repo.products(search: code);
                              setS(() => list = l);
                            }
                          },
                        ),
                ),
                onChanged: (v) async { final l = await widget.repo.products(search: v); setS(() => list = l); },
              ),
              Expanded(child: ListView(children: [for (final p in list) ListTile(dense: true, title: Text(p.name), onTap: () => Navigator.pop(ctx, p))])),
            ]),
          ),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel'))],
        ),
      ),
    );
    search.dispose();
    return r;
  }

  Future<bool?> _edit(_Line l, {bool isNew = false}) async {
    final qty = TextEditingController(text: _qty(l.qtyMilli));
    final cost = TextEditingController(text: l.costMinor == 0 ? '' : _plainAmount(l.costMinor, _cur.minorUnits));
    final batch = TextEditingController(text: l.batchCode);
    var expiry = l.expiry;
    String? err;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(l.name),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: l.maxMilli == null ? 'Quantity' : 'Quantity (up to ${_qty(l.maxMilli!)})')),
              TextField(controller: cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cost each (${widget.currency})')),
              if (widget.withBatch) ...[
                TextField(controller: batch, decoration: const InputDecoration(labelText: 'Batch code (optional)')),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(child: Text(expiry == null ? 'No expiry date' : 'Expires $expiry')),
                  TextButton(onPressed: () async { final d = await _pickDate(ctx); if (d != null) setS(() => expiry = _ymd(d)); }, child: const Text('Set date')),
                  if (expiry != null) TextButton(onPressed: () => setS(() => expiry = null), child: const Text('Clear')),
                ]),
              ],
              if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
            ]),
          ),
          actions: [
            if (!isNew) TextButton(onPressed: () { widget.lines.remove(l); Navigator.pop(ctx, true); }, child: const Text('Remove')),
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final q = parseQty(qty.text);
                final c = cost.text.trim().isEmpty ? 0 : _cur.parse(cost.text);
                if (q == null || q <= 0) {
                  setS(() => err = 'Enter the quantity.');
                  return;
                }
                if (l.maxMilli != null && q > l.maxMilli!) {
                  setS(() => err = 'Only ${_qty(l.maxMilli!)} still to come on this order.');
                  return;
                }
                if (c == null) {
                  setS(() => err = 'Enter the cost.');
                  return;
                }
                l.qtyMilli = q;
                l.costMinor = c;
                l.batchCode = batch.text.trim().isEmpty ? null : batch.text.trim();
                l.expiry = expiry;
                Navigator.pop(ctx, true);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      ),
    );
    qty.dispose();
    cost.dispose();
    batch.dispose();
    if (!isNew && ok == true) {
      setState(() {});
      widget.onChanged();
    }
    return ok;
  }

  @override
  Widget build(BuildContext context) {
    var total = 0;
    for (final l in widget.lines) {
      total += (l.qtyMilli * l.costMinor / 1000).round();
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.lines.isEmpty) const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: Text('No products yet.'))),
      for (final l in widget.lines)
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(l.name),
          subtitle: Text('${_qty(l.qtyMilli)} x ${_cur.format(l.costMinor)}${l.batchCode == null ? '' : ' - batch ${l.batchCode}'}${l.expiry == null ? '' : ' - expires ${l.expiry}'}'),
          trailing: Text(_cur.format((l.qtyMilli * l.costMinor / 1000).round()), style: const TextStyle(fontWeight: FontWeight.w600)),
          onTap: () => _edit(l),
        ),
      if (widget.canAdd) TextButton.icon(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Add product')),
      const Divider(),
      Align(alignment: Alignment.centerRight, child: Text('Total ${_cur.format(total)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
    ]);
  }
}

class _CurrencyChips extends StatelessWidget {
  const _CurrencyChips({required this.money, required this.value, required this.onChanged});
  final _Money money;
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 8, children: [for (final c in money.list) ChoiceChip(label: Text(c.code), selected: value == c.code, onSelected: (_) => onChanged(c.code))]);
}

// ============================================================ order form

class OrderFormScreen extends StatefulWidget {
  const OrderFormScreen({super.key, required this.repo, required this.supplierId, required this.supplierName, this.order});
  final PurchasingRepository repo;
  final String supplierId, supplierName;
  final PoDetail? order; // editing a draft
  @override
  State<OrderFormScreen> createState() => _OrderFormState();
}

class _OrderFormState extends State<OrderFormScreen> {
  _Money? _m;
  String _cur = 'USD';
  final List<_Line> _lines = [];
  String? _expected;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final m = await _loadMoney(widget.repo);
    final o = widget.order;
    if (o != null) {
      _cur = o.currency;
      for (final l in o.lines) {
        _lines.add(_Line(productId: l.productId, name: l.product, qtyMilli: l.qtyMilli, costMinor: l.costMinor));
      }
      if (o.expectedAt != null) _expected = _day(o.expectedAt!, DateTime.now().timeZoneOffset.inMinutes);
    } else {
      _cur = m.base;
    }
    if (mounted) setState(() => _m = m);
  }

  int? _expectedMs() {
    if (_expected == null) return null;
    final d = DateTime.parse(_expected!);
    return DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch - DateTime.now().timeZoneOffset.inMinutes * 60000;
  }

  Future<void> _save({required bool send}) async {
    setState(() { _busy = true; _err = null; });
    try {
      final repo = widget.repo;
      final lines = [for (final l in _lines) PoLineInput(productId: l.productId, qtyMilli: l.qtyMilli, costMinor: l.costMinor)];
      String id;
      if (widget.order != null) {
        id = widget.order!.id;
        await repo.updatePurchaseOrder(id, lines: lines, setExpected: true, expectedAt: _expectedMs());
      } else {
        final branch = await repo.branchId();
        if (branch == null) throw SetupError('unknown_branch', 'Set up a branch first.');
        id = (await repo.createPurchaseOrder(supplierId: widget.supplierId, branchId: branch, currency: _cur, expectedAt: _expectedMs(), lines: lines)).orderId;
      }
      if (send) await repo.sendPurchaseOrder(id);
      if (mounted) Navigator.pop(context, id);
    } on SetupError catch (e) {
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text(widget.order == null ? 'Order from ${widget.supplierName}' : 'Edit ${widget.order!.orderNo}'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (widget.order == null) ...[const Text('Currency of this order'), _CurrencyChips(money: m, value: _cur, onChanged: (c) => setState(() { _cur = c; _lines.clear(); }))],
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: Text(_expected == null ? 'No expected date' : 'Expected $_expected')),
                TextButton(onPressed: () async { final d = await _pickDate(context, first: DateTime.now()); if (d != null) setState(() => _expected = _ymd(d)); }, child: const Text('Set date')),
              ]),
              _LinesEditor(repo: widget.repo, lines: _lines, currency: _cur, money: m, supplierId: widget.supplierId, onChanged: () => setState(() {})),
              if (_err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w600))),
              const SizedBox(height: 16),
              Row(children: [
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _save(send: false), child: const Text('Save as draft'))),
                const SizedBox(width: 12),
                Expanded(child: FilledButton(onPressed: _busy ? null : () => _save(send: true), child: const Text('Save and send'))),
              ]),
            ]),
    );
  }
}

// ============================================================ order detail

class PurchaseOrderScreen extends StatefulWidget {
  const PurchaseOrderScreen({super.key, required this.repo, required this.orderId});
  final PurchasingRepository repo;
  final String orderId;
  @override
  State<PurchaseOrderScreen> createState() => _PurchaseOrderState();
}

class _PurchaseOrderState extends State<PurchaseOrderScreen> {
  PurchasingRepository get repo => widget.repo;
  _Money? _m;
  PoDetail? _po;
  String? _note;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final m = await _loadMoney(repo);
    final po = await repo.purchaseOrder(widget.orderId);
    if (mounted) setState(() { _m = m; _po = po; });
  }

  Future<void> _do(Future<void> Function() a) async {
    try {
      await a();
      _note = null;
    } on SetupError catch (e) {
      _note = e.message;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final m = _m, po = _po;
    return Scaffold(
      appBar: AppBar(title: Text(po?.orderNo ?? 'Order'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: m == null || po == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              Text('${po.supplier} - ${_statusNames[po.status] ?? po.status}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              if (po.expectedAt != null) Text('Expected ${_day(po.expectedAt!, DateTime.now().timeZoneOffset.inMinutes)}'),
              const SizedBox(height: 8),
              for (final l in po.lines)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(l.product),
                  subtitle: Text('Ordered ${_qty(l.qtyMilli)} x ${m.fmt(l.costMinor, po.currency)} - received ${_qty(l.receivedMilli)}'),
                  trailing: Text(m.fmt(l.lineTotalMinor, po.currency)),
                ),
              const Divider(),
              Align(alignment: Alignment.centerRight, child: Text('Total ${m.fmt(po.totalMinor, po.currency)}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 16))),
              if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!, style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w600))),
              const SizedBox(height: 16),
              Wrap(spacing: 8, runSpacing: 8, children: [
                if (po.status == 'draft') ...[
                  OutlinedButton(onPressed: () async { await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => OrderFormScreen(repo: repo, supplierId: po.supplierId, supplierName: po.supplier, order: po))); await _load(); }, child: const Text('Edit')),
                  FilledButton(onPressed: () => _do(() => repo.sendPurchaseOrder(po.id)), child: const Text('Send')),
                ],
                if (po.status == 'sent' || po.status == 'partly_received')
                  FilledButton.icon(
                    icon: const Icon(Icons.local_shipping_outlined),
                    label: const Text('Receive goods'),
                    onPressed: () async { await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReceiveGoodsScreen(repo: repo, supplierId: po.supplierId, supplierName: po.supplier, order: po))); await _load(); },
                  ),
                if (po.status == 'partly_received') OutlinedButton(onPressed: () => _do(() => repo.closePurchaseOrder(po.id)), child: const Text('Close (nothing more coming)')),
                if (po.status == 'draft' || po.status == 'sent') TextButton(onPressed: () => _do(() => repo.cancelPurchaseOrder(po.id)), child: const Text('Cancel order')),
              ]),
            ]),
    );
  }
}

// ============================================================ receive goods

class ReceiveGoodsScreen extends StatefulWidget {
  const ReceiveGoodsScreen({super.key, required this.repo, required this.supplierId, required this.supplierName, this.order});
  final PurchasingRepository repo;
  final String supplierId, supplierName;
  final PoDetail? order;
  @override
  State<ReceiveGoodsScreen> createState() => _ReceiveGoodsState();
}

class _ReceiveGoodsState extends State<ReceiveGoodsScreen> {
  _Money? _m;
  String _cur = 'USD';
  final List<_Line> _lines = [];
  final _ref = TextEditingController();
  final _inv = TextEditingController();
  String? _due;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _ref.dispose();
    _inv.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final m = await _loadMoney(widget.repo);
    final o = widget.order;
    if (o != null) {
      _cur = o.currency;
      for (final l in o.lines.where((l) => l.remainingMilli > 0)) {
        _lines.add(_Line(productId: l.productId, name: l.product, qtyMilli: l.remainingMilli, costMinor: l.costMinor, maxMilli: l.remainingMilli));
      }
    } else {
      _cur = m.base;
    }
    if (mounted) setState(() => _m = m);
  }

  Future<void> _save() async {
    setState(() { _busy = true; _err = null; });
    try {
      final repo = widget.repo;
      final branch = await repo.branchId();
      if (branch == null) throw SetupError('unknown_branch', 'Set up a branch first.');
      final r = await repo.receiveGoods(
        supplierId: widget.supplierId, branchId: branch, purchaseOrderId: widget.order?.id, receiptRef: _ref.text, currency: _cur,
        lines: [for (final l in _lines) ReceiveLine(productId: l.productId, qtyMilli: l.qtyMilli, costMinor: l.costMinor, batchCode: l.batchCode, expiryDate: l.expiry)],
        invoiceNo: _inv.text, dueDate: _due,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Received. You now owe ${_m!.fmt(r.totalMinor, _cur)} more to ${widget.supplierName}.')));
        Navigator.pop(context, r.goodsReceivedId);
      }
    } on SetupError catch (e) {
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text('Receive from ${widget.supplierName}'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (widget.order != null) Text('Against ${widget.order!.orderNo}. Change a quantity if less arrived.', style: const TextStyle(fontWeight: FontWeight.w600))
              else ...[const Text('Currency of the supplier\'s invoice'), _CurrencyChips(money: m, value: _cur, onChanged: (c) => setState(() { _cur = c; _lines.clear(); }))],
              TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Delivery note number (optional)')),
              TextField(controller: _inv, decoration: const InputDecoration(labelText: 'Invoice number (optional)')),
              Row(children: [
                Expanded(child: Text(_due == null ? 'No due date' : 'Invoice due $_due')),
                TextButton(onPressed: () async { final d = await _pickDate(context, first: DateTime.now()); if (d != null) setState(() => _due = _ymd(d)); }, child: const Text('Set due date')),
              ]),
              const SizedBox(height: 8),
              _LinesEditor(repo: widget.repo, lines: _lines, currency: _cur, money: m, supplierId: widget.supplierId, withBatch: true, canAdd: widget.order == null, onChanged: () => setState(() {})),
              if (_err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w600))),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy || _lines.isEmpty ? null : _save, child: Text(_busy ? 'Saving...' : 'Receive into stock')),
            ]),
    );
  }
}

// ============================================================ supplier return

class SupplierReturnScreen extends StatefulWidget {
  const SupplierReturnScreen({super.key, required this.repo, required this.supplierId, required this.supplierName});
  final PurchasingRepository repo;
  final String supplierId, supplierName;
  @override
  State<SupplierReturnScreen> createState() => _SupplierReturnState();
}

class _SupplierReturnState extends State<SupplierReturnScreen> {
  _Money? _m;
  String _cur = 'USD';
  final List<_Line> _lines = [];
  final _reason = TextEditingController();
  bool _credit = true;
  String? _err;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _loadMoney(widget.repo).then((m) { if (mounted) setState(() { _m = m; _cur = m.base; }); });
  }

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _busy = true; _err = null; });
    try {
      final repo = widget.repo;
      final branch = await repo.branchId();
      if (branch == null) throw SetupError('unknown_branch', 'Set up a branch first.');
      await repo.returnToSupplier(
        supplierId: widget.supplierId, branchId: branch, currency: _cur, reason: _reason.text, credit: _credit,
        lines: [for (final l in _lines) SupplierReturnLine(productId: l.productId, qtyMilli: l.qtyMilli, costMinor: l.costMinor)],
      );
      if (mounted) Navigator.pop(context, true);
    } on SetupError catch (e) {
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = _m;
    return Scaffold(
      appBar: AppBar(title: Text('Return to ${widget.supplierName}'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: m == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Text('Currency the supplier charged in'),
              _CurrencyChips(money: m, value: _cur, onChanged: (c) => setState(() { _cur = c; _lines.clear(); })),
              TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason')),
              SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Take the value off what I owe'), subtitle: const Text('Turn off if the supplier swaps the goods instead.'), value: _credit, onChanged: (v) => setState(() => _credit = v)),
              _LinesEditor(repo: widget.repo, lines: _lines, currency: _cur, money: m, supplierId: widget.supplierId, onChanged: () => setState(() {})),
              if (_err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_err!, style: const TextStyle(color: Brand.coral, fontWeight: FontWeight.w600))),
              const SizedBox(height: 16),
              FilledButton(onPressed: _busy || _lines.isEmpty ? null : _save, child: Text(_busy ? 'Saving...' : 'Send goods back')),
            ]),
    );
  }
}
