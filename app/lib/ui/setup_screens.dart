import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../auth/auth_repository.dart' show AuthError;
import '../selling/catalog.dart';
import '../setup/setup_repository.dart';
import 'barcode_screens.dart';
import 'department_screens.dart';
import 'product_pic.dart';
import '../ai/ai_service.dart';
import '../photos/photo_store.dart';
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
  String? _base;
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
          taxNumber: _taxNo.text.trim().isEmpty ? null : _taxNo.text.trim(), ownerName: _owner.text, ownerPin: _pin.text, baseCurrency: _base);
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
            onChanged: (v) => setState(() { _country = v ?? 'ZW'; _base = null; }),
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            key: ValueKey('base-$_country'),
            initialValue: _base ?? presets[_country]!.baseCurrency,
            decoration: const InputDecoration(labelText: 'Main currency', helperText: 'Prices and reports are kept in this currency. Choose US dollars if you price in dollars.'),
            items: [for (final c in presets[_country]!.currencies) DropdownMenuItem(value: c['code'] as String, child: Text('${c['name']} (${c['code']})'))],
            onChanged: (v) => setState(() => _base = v),
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
  List<Map<String, Object?>> _cats = [];
  String? _dept;
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
    final rows = await repo.listProducts(_search.text, categoryId: _dept);
    final cats = await repo.listCategories();
    if (mounted) setState(() { _setup = setup; _rows = rows; _cats = cats; });
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
        DepartmentChips(departments: _cats, selected: _dept, showNone: true, onSelect: (d) { _dept = d; _load(); }),
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
                      leading: ProductPic(name: r['name'] as String, imageRef: r['image_ref'] as String?, size: 48),
                      title: Text(r['name'] as String, style: TextStyle(decoration: r['is_active'] == 0 ? TextDecoration.lineThrough : null)),
                      subtitle: Text([for (final c in _cats) if (c['id'] == r['category_id']) c['name'], if (r['brand'] != null) r['brand'], if (r['price_minor'] != null && cur != null) cur.format((r['price_minor'] as num).toInt())].join(' · ')),
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
  final _brand = TextEditingController();
  String? _imageRef;
  final _sku = TextEditingController();
  final _barcode = TextEditingController();
  final _price = TextEditingController();
  final _cost = TextEditingController();
  final _openQty = TextEditingController();
  final _addQty = TextEditingController();
  final _addCost = TextEditingController();
  List<Map<String, Object?>> _taxes = [];
  List<Map<String, Object?>> _cats = [];
  List<({int minQtyMilli, int priceMinor})> _breaks = [];
  bool _breaksDirty = false;
  String? _catId;
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
    final cats = await repo.listCategories();
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
    final breaks = widget.productId == null ? <({int minQtyMilli, int priceMinor})>[] : await repo.listBreaks(widget.productId!);
    if (!mounted) return;
    setState(() {
      _taxes = taxes;
      _cats = cats;
      if (p != null) {
        _catId = p['category_id'] as String?;
        _name.text = p['name'] as String;
        _brand.text = (p['brand'] as String?) ?? '';
        _imageRef = p['image_ref'] as String?;
        _sku.text = (p['sku'] as String?) ?? '';
        _barcode.text = barcode ?? '';
        _price.text = price == null ? '' : _plain(price);
        _cost.text = p['cost_minor'] == null ? '' : _plain((p['cost_minor'] as num).toInt());
        _taxId = p['tax_class_id'] as String?;
        _breaks = breaks;
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

  /// Pack total and number of items in it, then fills in the cost of one.
  Future<void> _packHelper(TextEditingController target) async {
    final total = TextEditingController();
    final count = TextEditingController();
    String? err;
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Price for 1 from a pack'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: total, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'What you paid for the whole pack (${cur.code})')),
            TextField(controller: count, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'How many are in the pack')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final t = cur.parse(total.text);
                final n = parseQty(count.text);
                if (t == null || n == null || n <= 0) {
                  setD(() => err = 'Enter the pack price and how many are in it.');
                  return;
                }
                Navigator.pop(ctx, unitCostFromPack(t, n));
              },
              child: const Text('Use this'),
            ),
          ],
        ),
      ),
    );
    total.dispose();
    count.dispose();
    if (result != null && mounted) setState(() => target.text = _plain(result));
  }

  Future<void> _addBreak() async {
    final qty = TextEditingController();
    final price = TextEditingController();
    String? err;
    final r = await showDialog<({int minQtyMilli, int priceMinor})>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Text('Quantity price'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: qty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'When they buy this many or more', hintText: '3')),
            TextField(controller: price, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Price for each (${cur.code})')),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final q = parseQty(qty.text);
                final pr = cur.parse(price.text);
                if (q == null || q <= 1000 || pr == null) {
                  setD(() => err = 'Enter a quantity of 2 or more and the price for each.');
                  return;
                }
                Navigator.pop(ctx, (minQtyMilli: q, priceMinor: pr));
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ),
    );
    qty.dispose();
    price.dispose();
    if (r == null || !mounted) return;
    setState(() {
      _breaks = [..._breaks.where((b) => b.minQtyMilli != r.minQtyMilli), r]..sort((a, b) => a.minQtyMilli.compareTo(b.minQtyMilli));
      _breaksDirty = true;
    });
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
        id: widget.productId, name: _name.text, brand: _brand.text, imageRef: _imageRef, sku: _sku.text, barcode: _barcode.text, priceMinor: price, costMinor: cost,
        taxClassId: _taxId, categoryId: _catId ?? '', trackStock: _track, allowNegativeStock: _allowNeg, isActive: _active,
      ));
      if (_breaksDirty) await repo.saveBreaks(id, _breaks);
      if (widget.productId == null && openQty != null && openQty > 0) {
        await repo.receiveStock(branchId: widget.setup.branchId, productId: id, qtyMilli: openQty, unitCostMinor: cost, opening: true);
      }
      if (mounted) Navigator.of(context).pop();
    } on SetupError catch (e) {
      setState(() => _error = e.message);
    } catch (e) {
      setState(() => _error = 'Could not save. Please send this to support (More, then Help and contact): $e');
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

  bool _suggesting = false;

  /// Online only. Fills the name (and brand if empty) from the photo; the shopkeeper can change both.
  Future<void> _suggest() async {
    final ref = _imageRef;
    if (ref == null) return;
    setState(() { _suggesting = true; _error = null; });
    try {
      final bytes = await PhotoStore.instance.bytesOf(ref);
      if (bytes == null) throw AiError('The photo could not be read. Take it again.');
      final s = await widget.controller.ai.suggestProduct(bytes);
      if (!mounted) return;
      if (s.name.isEmpty) {
        setState(() => _error = 'It could not tell what this is. Type the name yourself.');
      } else {
        setState(() {
          if (_name.text.trim().isEmpty) _name.text = s.name;
          if (_brand.text.trim().isEmpty && s.brand.isNotEmpty) _brand.text = s.brand;
        });
      }
    } on AiError catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'The assistant could not be reached.');
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.productId == null;
    return Scaffold(
      appBar: AppBar(title: Text(isNew ? 'New product' : 'Edit product'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Center(
          child: Column(children: [
            ProductPic(name: _name.text.isEmpty ? 'Product' : _name.text, imageRef: _imageRef, size: 140, radius: 20),
            const SizedBox(height: 8),
            Wrap(spacing: 8, children: [
              FilledButton.tonalIcon(
                icon: const Icon(Icons.photo_camera_outlined),
                label: Text(_imageRef == null ? 'Take photo' : 'New photo'),
                onPressed: () async {
                  try {
                    final ref = await PhotoStore.instance.take();
                    if (ref != null && mounted) setState(() => _imageRef = ref);
                  } catch (e) {
                    if (mounted) setState(() => _error = 'The camera could not open: $e');
                  }
                },
              ),
              TextButton.icon(
                icon: const Icon(Icons.photo_library_outlined),
                label: const Text('Gallery'),
                onPressed: () async {
                  try {
                    final ref = await PhotoStore.instance.take(gallery: true);
                    if (ref != null && mounted) setState(() => _imageRef = ref);
                  } catch (e) {
                    if (mounted) setState(() => _error = 'The gallery could not open: $e');
                  }
                },
              ),
            ]),
          ]),
        ),
        if (_imageRef != null && _name.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Center(
              child: TextButton.icon(
                icon: _suggesting ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_outlined),
                label: const Text('Suggest a name from the photo'),
                onPressed: _suggesting ? null : _suggest,
              ),
            ),
          ),
        const SizedBox(height: 16),
        TextField(controller: _name, onChanged: (_) => setState(() {}), textCapitalization: TextCapitalization.sentences, decoration: const InputDecoration(labelText: 'Product name', hintText: 'For example: Rice 5kg')),
        const SizedBox(height: 16),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: DropdownButtonFormField<String>(
              key: ValueKey('dept-${_catId ?? ''}-${_cats.length}'),
              initialValue: _cats.any((c) => c['id'] == _catId) ? _catId : null,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Department - optional', helperText: 'For example Groceries or Accessories'),
              items: [for (final c in _cats) DropdownMenuItem(value: c['id'] as String, child: Text(c['name'] as String))],
              onChanged: (v) => setState(() => _catId = v),
            ),
          ),
          IconButton(
            tooltip: 'New department',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () async {
              await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => DepartmentsScreen(repo: repo)));
              final cats = await repo.listCategories();
              if (mounted) setState(() => _cats = cats);
            },
          ),
        ]),
        const SizedBox(height: 16),
        TextField(controller: _brand, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Brand - optional', hintText: 'For example: Mr Rice', helperText: 'Helps you tell apart the same item from different brands')),
        const SizedBox(height: 16),
        TextField(
          controller: _price,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Selling price (${cur.code})', helperText: 'What the customer pays for 1', prefixText: '${cur.code} '),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _cost,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: InputDecoration(labelText: 'Buying price (${cur.code}) - optional', helperText: 'What you paid for 1. It lets the app show your profit.', prefixText: '${cur.code} '),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(icon: const Icon(Icons.calculate_outlined), label: const Text('Bought a pack? Work out the price for 1'), onPressed: () => _packHelper(_cost)),
        ),
        const SizedBox(height: 8),
        const Text('Quantity prices', style: TextStyle(fontWeight: FontWeight.w800)),
        const Text('Sell cheaper when a customer buys more, for example 3 or more at 4.00 each. Your profit is worked out from the price actually charged.', style: TextStyle(color: Colors.black54, fontSize: 12)),
        for (var i = 0; i < _breaks.length; i++)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('${_breaks[i].minQtyMilli ~/ 1000}${_breaks[i].minQtyMilli % 1000 == 0 ? '' : '.${(_breaks[i].minQtyMilli % 1000).toString().padLeft(3, '0')}'} or more: ${cur.code} ${_plain(_breaks[i].priceMinor)} each'),
            trailing: IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() { _breaks = [..._breaks]..removeAt(i); _breaksDirty = true; })),
          ),
        if (_breaks.length < 6)
          Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.add), label: const Text('Add quantity price'), onPressed: _addBreak)),
        if (isNew && _track) ...[
          const SizedBox(height: 16),
          TextField(controller: _openQty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'How many do you have now? - optional', helperText: 'The stock on your shelf today')),
        ],
        if (isNew) ...[
          const SizedBox(height: 16),
          TextField(
            controller: _barcode,
            autocorrect: false,
            decoration: InputDecoration(
              labelText: 'Barcode - optional',
              helperText: 'Scan the code on the item, or leave empty',
              suffixIcon: IconButton(tooltip: 'Scan', icon: const Icon(Icons.qr_code_scanner), onPressed: () async { final c = await scanOnce(context); if (c != null) setState(() => _barcode.text = c); }),
            ),
          ),
        ],
        const SizedBox(height: 8),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('More options'),
          subtitle: const Text('Tax, stock counting, product code'),
          children: [
            TextField(controller: _sku, decoration: const InputDecoration(labelText: 'Your own product code - optional')),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: _taxId,
              decoration: const InputDecoration(labelText: 'Tax'),
              items: [for (final t in _taxes) DropdownMenuItem(value: t['id'] as String, child: Text('${t['name']} (${((t['rate_bp'] as num) / 100).toStringAsFixed(1)}%)'))],
              onChanged: (v) => setState(() => _taxId = v),
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Keep count of this product'), subtitle: const Text('Turn off for things you do not count, like a service.'), value: _track, onChanged: (v) => setState(() => _track = v)),
            if (_track) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Allow selling when stock is zero'), subtitle: const Text('Off: the app stops a sale when there is none left.'), value: _allowNeg, onChanged: (v) => setState(() => _allowNeg = v)),
            if (!isNew) SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Can be sold'), subtitle: const Text('Turn off to hide it from the till without deleting it.'), value: _active, onChanged: (v) => setState(() => _active = v)),
          ],
        ),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_error!, style: const TextStyle(color: Brand.coral))),
        const SizedBox(height: 16),
        FilledButton(onPressed: _busy ? null : _save, child: const Text('Save product')),
        if (!isNew && widget.controller.barcodeRepository() != null) ...[
          const Divider(height: 40),
          BarcodeSection(repo: widget.controller.barcodeRepository()!, productId: widget.productId!, printing: widget.controller.printService()),
        ],
        if (!isNew && _track) ...[
          const Divider(height: 40),
          Text('New delivery? Add stock', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Enter what you received now. It is added to what you already have.'),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextField(controller: _addQty, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'How many did you get?'))),
            const SizedBox(width: 12),
            Expanded(child: TextField(controller: _addCost, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Price paid for 1', helperText: cur.code))),
          ]),
          TextButton.icon(icon: const Icon(Icons.calculate_outlined), label: const Text('Bought a pack? Work out the price for 1'), onPressed: () => _packHelper(_addCost)),
          OutlinedButton(onPressed: _receive, child: const Text('Add to my stock')),
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
