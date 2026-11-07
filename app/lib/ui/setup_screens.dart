import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../auth/auth_repository.dart' show AuthError;
import '../selling/catalog.dart';
import '../setup/setup_repository.dart';
import 'barcode_screens.dart';
import 'theme.dart';

String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3);

/// Turns a typed quantity like "2" or "1.5" into thousandths, or null. No floating point.
int? parseQty(String text) {
  final m = RegExp(r'^(\d{1,7})(?:[.,](\d{0,3}))?$').firstMatch(text.trim());
  if (m == null) return null;
  return int.parse(m.group(1)!) * 1000 + int.parse((m.group(2) ?? '').padRight(3, '0'));
}

/// First-run set-up: the shop's name and country. Creates the branch, currencies, payment methods and taxes.
class ShopSetupScreen extends StatefulWidget {
  const ShopSetupScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ShopSetupScreen> createState() => _ShopSetupScreenState();
}

class _ShopSetupScreenState extends State<ShopSetupScreen> {
  late final _name = TextEditingController(text: widget.controller.licence.payload?.shopName ?? '');
  final _branch = TextEditingController(text: 'Main branch');
  final _taxNo = TextEditingController();
  final _owner = TextEditingController();
  final _pin = TextEditingController();
  String _country = 'ZW';
  bool _vat = false;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _branch.dispose();
    _taxNo.dispose();
    _owner.dispose();
    _pin.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() { _busy = true; _error = null; });
    try {
      final r = await widget.controller.setupRepository()!.seedShop(
          name: _name.text, countryCode: _country, branchName: _branch.text, taxRegistered: _vat,
          taxNumber: _taxNo.text.trim().isEmpty ? null : _taxNo.text.trim(), ownerName: _owner.text, ownerPin: _pin.text);
      if (r.ownerId != null) await widget.controller.signIn(r.ownerId!, _pin.text);
      if (mounted) Navigator.of(context).pop(true);
    } on SetupError catch (e) {
      setState(() => _error = e.message);
    } on AuthError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Set up your shop'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
        body: ListView(padding: const EdgeInsets.all(16), children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Shop name')),
          const SizedBox(height: 12),
          TextField(controller: _branch, decoration: const InputDecoration(labelText: 'First branch name')),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            initialValue: _country,
            decoration: const InputDecoration(labelText: 'Country', helperText: 'Sets the currencies, payment methods and tax rates to start with. You can change them later.'),
            items: const [DropdownMenuItem(value: 'ZW', child: Text('Zimbabwe (USD, ZiG)')), DropdownMenuItem(value: 'ZM', child: Text('Zambia (ZMW, USD)'))],
            onChanged: (v) => setState(() => _country = v ?? 'ZW'),
          ),
          const SizedBox(height: 12),
          TextField(controller: _owner, decoration: const InputDecoration(labelText: 'Owner name')),
          const SizedBox(height: 12),
          TextField(controller: _pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Owner PIN (4 to 8 digits)', helperText: 'The owner uses this PIN to sign in and to add staff.')),
          SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Registered for VAT'), value: _vat, onChanged: (v) => setState(() => _vat = v)),
          if (_vat) TextField(controller: _taxNo, decoration: const InputDecoration(labelText: 'VAT / BP number')),
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.coral))),
          const SizedBox(height: 20),
          FilledButton(onPressed: _busy ? null : _save, child: const Text('Create shop')),
        ]),
      );
}

/// The catalogue: every product with its stock, search, add and edit.
class ProductsScreen extends StatefulWidget {
  const ProductsScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<ProductsScreen> createState() => _ProductsScreenState();
}

class _ProductsScreenState extends State<ProductsScreen> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _rows = [];
  TillSetup? _setup;

  SetupRepository get repo => widget.controller.setupRepository()!;

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
    final db = widget.controller.database!.sql;
    final setup = await CatalogRepository(db).setup();
    final rows = await repo.listProducts(_search.text);
    if (mounted) setState(() { _setup = setup; _rows = rows; });
  }

  Future<void> _edit(String? id) async {
    final s = _setup;
    if (s == null) return;
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ProductEditorScreen(controller: widget.controller, setup: s, productId: id)));
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cur = _setup?.currency(_setup!.baseCurrency);
    return Scaffold(
      appBar: AppBar(title: const Text('Products'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(null), icon: const Icon(Icons.add), label: const Text('New product')),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(10), child: TextField(controller: _search, onChanged: (_) => _load(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search products'))),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('No products yet. Tap New product.'))
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _rows[i];
                    final tracks = r['track_stock'] == 1;
                    return ListTile(
                      title: Text(r['name'] as String, style: TextStyle(decoration: r['is_active'] == 0 ? TextDecoration.lineThrough : null)),
                      subtitle: Text([if (r['sku'] != null) r['sku'], if (r['barcodes'] != null) r['barcodes']].join(' · ')),
                      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                        Text(tracks ? '${_qty((r['on_hand_milli'] as num).toInt())} in stock' : 'Not counted'),
                        if (r['cost_minor'] != null && cur != null) Text('cost ${cur.format((r['cost_minor'] as num).toInt())}', style: Theme.of(context).textTheme.bodySmall),
                      ]),
                      onTap: () => _edit(r['id'] as String),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

class ProductEditorScreen extends StatefulWidget {
  const ProductEditorScreen({super.key, required this.controller, required this.setup, this.productId});
  final AppController controller;
  final TillSetup setup;
  final String? productId;
  @override
  State<ProductEditorScreen> createState() => _ProductEditorScreenState();
}

class _ProductEditorScreenState extends State<ProductEditorScreen> {
  final _name = TextEditingController();
  final _sku = TextEditingController();
  final _barcode = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _openQty = TextEditingController();
  final _addQty = TextEditingController();
  final _addCost = TextEditingController();
  List<Map<String, Object?>> _taxes = [];
  String? _taxId;
  bool _track = true;
  bool _active = true;
  bool _allowNeg = false;
  String? _error;
  bool _busy = false;

  SetupRepository get repo => widget.controller.setupRepository()!;
  CurrencyInfo get cur => widget.setup.currency(widget.setup.baseCurrency);

  @override
  void initState() {
    super.initState();
    _loadExisting();
  }

  Future<void> _loadExisting() async {
    final taxes = await repo.taxClasses();
    Map<String, Object?>? p;
    int? price;
    String? barcode;
    if (widget.productId != null) {
      final db = widget.controller.database!.sql;
      p = (await db.query('select * from products where id = ?', [widget.productId])).first;
      final base = widget.setup.baseCurrency;
      final pr = await db.query(
        'select price_minor from product_prices where product_id = ? and currency = ? and deleted_at is null order by effective_from desc, created_at desc limit 1',
        [widget.productId, base],
      );
      price = pr.isEmpty ? null : (pr.first['price_minor'] as num).toInt();
      final bc = await db.query('select barcode from product_barcodes where product_id = ? and deleted_at is null limit 1', [widget.productId]);
      barcode = bc.isEmpty ? null : bc.first['barcode'] as String;
    }
    if (!mounted) return;
    setState(() {
      _taxes = taxes;
      if (p != null) {
        _name.text = p['name'] as String;
        _sku.text = (p['sku'] as String?) ?? '';
        _barcode.text = barcode ?? '';
        _price.text = price == null ? '' : _plain(price);
        _cost.text = p['cost_minor'] == null ? '' : _plain((p['cost_minor'] as num).toInt());
        _taxId = p['tax_class_id'] as String?;
        _track = p['track_stock'] == 1;
        _active = p['is_active'] == 1;
        _allowNeg = p['allow_negative_stock'] == 1;
      } else if (taxes.isNotEmpty) {
        _taxId = taxes.first['id'] as String;
      }
    });
  }

  String _plain(int minor) {
    final s = minor.toString().padLeft(cur.minorUnits + 1, '0');
    return cur.minorUnits == 0 ? s : '${s.substring(0, s.length - cur.minorUnits)}.${s.substring(s.length - cur.minorUnits)}';
  }

  Future<void> _save() async {
    final price = _price.text.trim().isEmpty ? null : cur.parse(_price.text);
    final cost = _cost.text.trim().isEmpty ? null : cur.parse(_cost.text);
    if ((_price.text.trim().isNotEmpty && price == null) || (_cost.text.trim().isNotEmpty && cost == null)) {
      setState(() => _error = 'Check the price and cost: numbers only, up to ${cur.minorUnits} decimals.');
      return;
    }
    final openQty = _openQty.text.trim().isEmpty ? null : parseQty(_openQty.text);
    if (_openQty.text.trim().isNotEmpty && openQty == null) {
      setState(() => _error = 'Check the opening stock quantity.');
      return;
    }
    setState(() { _busy = true; _error = null; });
    try {
      final id = await repo.saveProduct(ProductInput(
        id: widget.productId, name: _name.text, sku: _sku.text, barcode: _barcode.text, priceMinor: price, costMinor: cost,
        taxClassId: _taxId, trackStock: _track, allowNegativeStock: _allowNeg, isActive: _active,
      ));
      if (widget.productId == null && openQty != null && openQty > 0) {
        await repo.receiveStock(branchId: widget.setup.branchId, productId: id, qtyMilli: openQty, unitCostMinor: cost, opening: true);
      }
      if (mounted) Navigator.of(context).pop();
    } on SetupError catch (e) {
      setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _receive() async {
    final q = parseQty(_addQty.text);
    final c = _addCost.text.trim().isEmpty ? null : cur.parse(_addCost.text);
    if (q == null || q <= 0 || (_addCost.text.trim().isNotEmpty && c == null)) {
      setState(() => _error = 'Enter the quantity received (and the cost, if you know it).');
      return;
    }
    try {
      await repo.receiveStock(branchId: widget.setup.branchId, productId: widget.productId!, qtyMilli: q, unitCostMinor: c);
      _addQty.clear();
      _addCost.clear();
      await _loadExisting();
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Stock added')));
    } on SetupError catch (e) {
      setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.productId == null;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'New product' : 'Edit product'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _sku, decoration: const InputDecoration(labelText: 'SKU (optional)'))),
          const SizedBox(width: 12),
          if (isNew)
            Expanded(
              child: TextField(
                controller: _barcode,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: 'Barcode (optional)',
                  suffixIcon: IconButton(tooltip: 'Scan', icon: const Icon(Icons.qr_code_scanner), onPressed: () async { final c = await scanOnce(context); if (c != null) setState(() => _barcode.text = c); }),
                ),
              ),
            )
          else
            const Spacer(),
        ]),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(child: TextField(controller: _price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Selling price (${cur.code})'))),
          const SizedBox(width: 12),
          Expanded(child: TextField(controller: _cost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cost (${cur.code})'))),
        ]),
        const SizedBox(height: 12),
        DropdownButtonFormField<String?>(
          initialValue: _taxId,
          decoration: const InputDecoration(labelText: 'Tax'),
          items: [for (final t in _taxes) DropdownMenuItem(value: t['id'] as String, child: Text('${t['name']} (${((t['rate_bp'] as num) / 100).toStringAsFixed(1)}%)'))],
          onChanged: (v) => setState(() => _taxId = v),
        ),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Count stock for this product'), value: _track, onChanged: (v) => setState(() => _track = v)),
        if (_track) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow selling below zero'), subtitle: const Text('Off by default: a sale is blocked when there is no stock.'), value: _allowNeg, onChanged: (v) => setState(() => _allowNeg = v)),
        if (!isNew) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Active (can be sold)'), value: _active, onChanged: (v) => setState(() => _active = v)),
        if (isNew && _track) TextField(controller: _openQty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Opening stock (optional)')),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.coral))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save')),
        if (!isNew && widget.controller.barcodeRepository() != null) ...[
          const Divider(height: 40),
          BarcodeSection(repo: widget.controller.barcodeRepository()!, productId: widget.productId!, printing: widget.controller.printService()),
        ],
        if (!isNew && _track) ...[
          const Divider(height: 40),
          Text('Receive stock', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _addQty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Quantity received'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _addCost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Cost each (${cur.code})'))),
          ]),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _receive, child: const Text('Add to stock')),
        ],
      ]),
    );
  }
}

/// Today's exchange rate, for example 1 USD = 26.50 ZiG. Each change is a new row; history is kept.
Future<void> showRateDialog(BuildContext context, AppController c) async {
  final setup = await CatalogRepository(c.database!.sql).setup();
  if (setup == null || setup.currencies.length < 2 || !context.mounted) return;
  final from = setup.baseCurrency;
  final to = setup.currencies.firstWhere((x) => x.code != from).code;
  final ctl = TextEditingController();
  String? error;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: Text('1 $from = ? $to'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: ctl, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Rate (how many $to for 1 $from)', errorText: error)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final m = RegExp(r'^(\d{1,4})(?:[.,](\d{0,6}))?$').firstMatch(ctl.text.trim());
              if (m == null) {
                setState(() => error = 'Enter a number like 26.5');
                return;
              }
              final micro = int.parse(m.group(1)!) * 1000000 + int.parse((m.group(2) ?? '').padRight(6, '0'));
              try {
                await c.setupRepository()!.setExchangeRate(from, to, micro);
                if (ctx.mounted) Navigator.pop(ctx);
              } on SetupError catch (e) {
                setState(() => error = e.message);
              }
            },
            child: const Text('Save rate'),
          ),
        ],
      ),
    ),
  );
  ctl.dispose();
}
