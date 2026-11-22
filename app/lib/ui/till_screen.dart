import 'dart:async';

import 'package:flutter/material.dart';

import '../barcodes/barcode_repository.dart';
import '../customers/customer_repository.dart';
import '../printing/print_service.dart';
import '../shifts/shift_repository.dart';
import '../selling/cart_controller.dart';
import '../selling/catalog.dart';
import '../selling/selling.dart' hide Row;
import 'customer_screens.dart';
import 'printer_screens.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import '../settings/app_prefs.dart';
import 'product_pic.dart';
import 'scan_screen.dart';
import 'shift_screens.dart';
import 'theme.dart';

/// The till: find products, build the cart, take payment in one or more currencies, and save the sale.
class TillScreen extends StatefulWidget {
  const TillScreen({super.key, required this.cart, this.printing, this.customers, this.shifts, this.barcodes});
  final CartController cart;
  final PrintService? printing;
  final CustomerRepository? customers;
  final ShiftRepository? shifts;
  final BarcodeRepository? barcodes;
  @override
  State<TillScreen> createState() => _TillScreenState();
}

class _TillScreenState extends State<TillScreen> {
  final _search = TextEditingController();
  List<ProductHit> _hits = [];
  int _searchToken = 0;
  bool _grid = true;

  CartController get c => widget.cart;

  void _addTapped(ProductHit h) {
    if (c.add(h) && AppPrefs.instance.tapFeedback) HapticFeedback.selectionClick();
  }

  @override
  void initState() {
    super.initState();
    c.addListener(_refresh);
    _loadShift();
    _run('');
    _grid = AppPrefs.instance.tillGrid;
  }

  /// Ties sales to the cashier's open shift so the cash-up can count them.
  Future<void> _loadShift() async {
    final s = widget.shifts;
    if (s == null) return;
    final cur = await s.current();
    if (mounted) c.shiftId = cur?.id;
  }

  @override
  void dispose() {
    c.removeListener(_refresh);
    _search.dispose();
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  /// Typed text searches by name or SKU. A pasted or scanned code that matches a barcode adds the product at once.
  Future<void> _run(String q) async {
    final token = ++_searchToken;
    final hits = await c.catalog.search(q, branchId: c.setup.branchId, currency: c.currency);
    if (!mounted || token != _searchToken) return; // a newer search replaced this one
    setState(() => _hits = hits);
  }

  /// A scanned or typed code goes in the cart at once. Returns a line to show ("Added Bread"), or null when the code is not a barcode.
  /// UPC-A and EAN-13 are matched either way round, and a scale label adds the weight printed on it.
  Future<String?> _addCode(String raw) async {
    final repo = widget.barcodes;
    final scan = repo != null ? await repo.resolve(raw) : null;
    String? productId = scan?.productId;
    int? qty = scan?.qtyMilli;
    if (scan == null) {
      final hit = await c.catalog.byBarcode(raw, branchId: c.setup.branchId, currency: c.currency);
      productId = hit?.id;
    } else {
      switch (scan.status) {
        case ScanStatus.empty:
          return null;
        case ScanStatus.error:
          return scan.message;
        case ScanStatus.inactive:
          return '${scan.productName} is not for sale any more.';
        case ScanStatus.unknown:
          return null;
        case ScanStatus.found:
          break;
      }
    }
    if (productId == null) return null;
    final hit = await c.catalog.byId(productId, branchId: c.setup.branchId, currency: c.currency);
    if (hit == null) return null;
    final ok = c.add(hit, qtyMilli: qty ?? 1000);
    if (!ok) return c.error ?? 'Could not add ${hit.name}.';
    return qty == null ? 'Added ${hit.name}' : 'Added ${hit.name} (${(qty / 1000).toStringAsFixed(3)} kg)';
  }

  Future<void> _submit(String q) async {
    final msg = await _addCode(q);
    if (!mounted) return;
    if (msg != null) {
      _search.clear();
      await _run('');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
    } else if (RegExp(r'^\d{6,}$').hasMatch(q.trim())) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No product has that barcode.')));
    }
  }

  Future<void> _openCamera() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ScannerScreen(
        title: 'Scan products',
        onCode: (code) async => await _addCode(code) ?? 'No product has the barcode $code.',
      ),
    ));
    if (mounted) await _run(_search.text);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.of(context).size.width >= 720;
    final catalogPane = _catalogPane();
    final cartPane = _cartPane();
    return Scaffold(
      appBar: AppBar(
        title: Text('Till · ${c.setup.branchName}'),
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        actions: [
          if (widget.shifts != null)
            IconButton(
              tooltip: 'Shift and cash-up',
              icon: Icon(c.shiftId == null ? Icons.lock_clock : Icons.account_balance_wallet),
              onPressed: () async {
                await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ShiftScreen(repo: widget.shifts!)));
                await _loadShift();
                if (mounted) setState(() {});
              },
            ),
          for (final cu in c.setup.currencies)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
              child: ChoiceChip(
                label: Text(cu.code),
                selected: cu.code == c.currency,
                onSelected: c.busy ? null : (_) async {
                  await c.setCurrency(cu.code);
                  await _run(_search.text);
                },
              ),
            ),
        ],
      ),
      body: wide
          ? Row(children: [Expanded(flex: 3, child: catalogPane), const VerticalDivider(width: 1), Expanded(flex: 2, child: cartPane)])
          : Column(children: [Expanded(child: catalogPane), const Divider(height: 1), SizedBox(height: MediaQuery.of(context).size.height * 0.42, child: cartPane)]),
    );
  }

  Widget _catalogPane() => Column(children: [
        Padding(
          padding: const EdgeInsets.all(10),
          child: Row(children: [
            Expanded(
              child: TextField(
                controller: _search,
                autocorrect: false,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search or scan barcode',
                  suffixIcon: IconButton(tooltip: 'Scan with the camera', icon: const Icon(Icons.qr_code_scanner), onPressed: _openCamera),
                ),
                onChanged: _run,
                onSubmitted: _submit,
              ),
            ),
            IconButton(
              tooltip: _grid ? 'Show as a list' : 'Show pictures',
              icon: Icon(_grid ? Icons.view_list_outlined : Icons.grid_view_rounded),
              onPressed: () {
                setState(() => _grid = !_grid);
                AppPrefs.instance.setTillGrid(_grid);
              },
            ),
          ]),
        ),
        Expanded(
          child: _hits.isEmpty
              ? const Center(child: Text('No products found'))
              : _grid
              ? GridView.builder(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                  gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(maxCrossAxisExtent: 160, mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 0.78),
                  itemCount: _hits.length,
                  itemBuilder: (_, i) => _tile(_hits[i]),
                )
              : ListView.separated(
                  itemCount: _hits.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final h = _hits[i];
                    final out = h.tracksStock && !h.allowNegative && h.onHandMilli <= 0;
                    return ListTile(
                      enabled: h.canSell && !out,
                      title: Text(h.name),
                      subtitle: Text(h.tracksStock ? (out ? 'Out of stock' : '${_qty(h.onHandMilli)} in stock') : 'Not stock-counted'),
                      trailing: Text(h.canSell ? c.cur.format(h.unitPriceMinor!) : 'No price', style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () => _addTapped(h),
                    );
                  },
                ),
        ),
      ]);

  /// One product as a picture tile: the photo, the name, the price, and a note when it is nearly gone.
  Widget _tile(ProductHit h) {
    final out = h.tracksStock && !h.allowNegative && h.onHandMilli <= 0;
    final low = h.tracksStock && !out && h.onHandMilli <= 5000;
    return Opacity(
      opacity: h.canSell && !out ? 1 : 0.45,
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: h.canSell && !out ? () => _addTapped(h) : null,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(
              child: Stack(fit: StackFit.expand, children: [
                LayoutBuilder(builder: (context, box) => Center(child: ProductPic(name: h.name, imageRef: h.imageRef, size: box.maxWidth, radius: 0))),
                if (out || low)
                  Positioned(
                    left: 6,
                    top: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(color: out ? Brand.coral : Brand.amber, borderRadius: BorderRadius.circular(10)),
                      child: Text(out ? 'Finished' : '${_qty(h.onHandMilli)} left', style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700)),
                    ),
                  ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(h.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                const SizedBox(height: 2),
                Text(h.canSell ? c.cur.format(h.unitPriceMinor!) : 'No price', style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.teal)),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3);

  Widget _cartPane() {
    final last = c.lastSale;
    return Column(children: [
      Expanded(
        child: c.items.isEmpty
            ? Center(
                child: last == null
                    ? const Text('Cart is empty')
                    : Column(mainAxisSize: MainAxisSize.min, children: [
                        const Icon(Icons.check_circle, color: Brand.green, size: 48),
                        Text('Sale ${last.receiptNo} saved', style: Theme.of(context).textTheme.titleMedium),
                        Text('Total ${c.cur.format(last.totalMinor)}'),
                        if (widget.printing != null) Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: FilledButton.icon(
                            icon: const Icon(Icons.receipt_long),
                            label: const Text('Receipt'),
                            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => ReceiptScreen(printing: widget.printing!, saleId: last.saleId))),
                          ),
                        ),
                        if (last.change != null) Text('Give change ${c.setup.currency(last.change!.currency).format(last.change!.amountMinor)}', style: const TextStyle(fontWeight: FontWeight.w800, color: Brand.teal)),
                      ]),
              )
            : ListView(children: [
                for (final i in c.items)
                  ListTile(
                    title: Text(i.hit.name),
                    subtitle: Text('${_qty(i.qtyMilli)} × ${c.cur.format(i.hit.unitPriceMinor!)}'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(c.cur.format(i.split.total), style: const TextStyle(fontWeight: FontWeight.w700)),
                      IconButton(icon: const Icon(Icons.remove_circle_outline), onPressed: () => c.setQty(i, i.qtyMilli - 1000)),
                      IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: () => c.setQty(i, i.qtyMilli + 1000)),
                    ]),
                    onLongPress: () => c.remove(i),
                  ),
              ]),
      ),
      if (c.error != null) Padding(padding: const EdgeInsets.all(8), child: Text(c.error!, style: const TextStyle(color: Brand.coral))),
      Padding(
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
        child: Column(children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('Total', style: TextStyle(fontSize: 18)),
            Text(c.cur.format(c.total), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
          ]),
          if (c.items.isNotEmpty && c.tax > 0) Align(alignment: Alignment.centerRight, child: Text('includes tax ${c.cur.format(c.tax)}', style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: c.items.isEmpty ? null : c.clear, child: const Text('Clear'))),
            const SizedBox(width: 10),
            Expanded(flex: 2, child: FilledButton(onPressed: c.items.isEmpty || c.busy ? null : _pay, child: const Text('Pay'))),
          ]),
        ]),
      ),
    ]);
  }

  /// Prints the receipt of a just-saved sale if this phone has a printer. A failure never undoes the sale.
  Future<void> _autoPrint(String saleId) async {
    final svc = widget.printing;
    if (svc == null || await svc.printer() == null) return;
    try {
      await svc.print(saleId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Sale saved, but the receipt did not print: $e. Use Receipt to try again.')));
    }
  }

  Future<void> _pay() async {
    final before = c.lastSale;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom), child: _PaymentSheet(cart: c, customers: widget.customers)),
    );
    final after = c.lastSale;
    if (after != null && !identical(after, before)) unawaited(_autoPrint(after.saleId));
    await _run(_search.text); // stock figures changed
  }
}

class _PaymentSheet extends StatefulWidget {
  const _PaymentSheet({required this.cart, this.customers});
  final CartController cart;
  final CustomerRepository? customers;
  @override
  State<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends State<_PaymentSheet> {
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  late String _payCurrency = widget.cart.currency;
  String _method = 'cash';
  String? _note;
  String? _changeCurrency;

  CartController get c => widget.cart;

  @override
  void dispose() {
    _amount.dispose();
    _ref.dispose();
    super.dispose();
  }

  Future<void> _add({bool exact = false}) async {
    final payCur = c.setup.currency(_payCurrency);
    int? minor;
    if (exact) {
      // "Exact" pays what is still due, converted into the chosen currency.
      minor = await c.catalog.convert(c.due, c.currency, _payCurrency);
    } else {
      minor = payCur.parse(_amount.text);
    }
    if (minor == null || minor <= 0) {
      setState(() => _note = exact ? 'No exchange rate for $_payCurrency.' : 'Enter the amount.');
      return;
    }
    final credited = await c.catalog.convert(minor, _payCurrency, c.currency);
    if (credited == null) {
      setState(() => _note = 'No exchange rate between $_payCurrency and ${c.currency}.');
      return;
    }
    c.addPayment(CartPayment(methodCode: _method, currency: _payCurrency, amountMinor: minor, reference: _ref.text.trim().isEmpty ? null : _ref.text.trim()), creditedInSaleCurrency: credited);
    _amount.clear();
    _ref.clear();
    setState(() => _note = null);
  }

  Future<void> _save() async {
    final ok = await c.checkout(changeCurrency: _changeCurrency);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop();
    } else {
      setState(() => _note = c.error);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = c.cur;
    final covered = c.canComplete;
    final settled = c.due <= 0;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(settled ? (c.due < 0 ? 'Change due ${cur.format(-c.due)}' : 'Fully paid') : (c.mode == 'full' ? 'Still to pay ${cur.format(c.due)}' : '${c.mode == 'layby' ? 'Layby balance' : 'On account'} ${cur.format(c.due)}'), style: Theme.of(context).textTheme.titleLarge),
          if (widget.customers != null) ...[
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.person_outline),
                  label: Text(c.customerName ?? 'Add customer', overflow: TextOverflow.ellipsis),
                  onPressed: () async {
                    final picked = await pickCustomer(context, widget.customers!);
                    if (picked != null) c.setCustomer(picked.id, picked.name);
                  },
                ),
              ),
              if (c.customerId != null) IconButton(icon: const Icon(Icons.close), onPressed: () => c.setCustomer(null, null)),
            ]),
            if (c.customerId != null)
              Wrap(spacing: 8, children: [
                ChoiceChip(label: const Text('Pay now'), selected: c.mode == 'full', onSelected: (_) => c.setMode('full')),
                ChoiceChip(label: const Text('On account'), selected: c.mode == 'account', onSelected: (_) => c.setMode('account')),
                ChoiceChip(label: const Text('Layby'), selected: c.mode == 'layby', onSelected: (_) => c.setMode('layby')),
              ]),
          ],
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            for (final m in const [('cash', 'Cash'), ('ecocash', 'EcoCash'), ('onemoney', 'OneMoney'), ('innbucks', 'InnBucks'), ('card', 'Card')])
              ChoiceChip(label: Text(m.$2), selected: _method == m.$1, onSelected: (_) => setState(() => _method = m.$1)),
          ]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [
            for (final cu in c.setup.currencies) ChoiceChip(label: Text(cu.code), selected: _payCurrency == cu.code, onSelected: (_) => setState(() => _payCurrency = cu.code)),
          ]),
          const SizedBox(height: 10),
          TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount in $_payCurrency')),
          if (_method != 'cash') ...[const SizedBox(height: 8), TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Confirmation reference'))],
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: OutlinedButton(onPressed: covered ? null : () => _add(exact: true), child: const Text('Exact amount'))),
            const SizedBox(width: 10),
            Expanded(child: FilledButton.tonal(onPressed: () => _add(), child: const Text('Add payment'))),
          ]),
          for (final p in c.payments) Text('${p.methodCode}: ${c.setup.currency(p.currency).format(p.amountMinor)}', textAlign: TextAlign.center),
          if (c.due < 0 && c.setup.currencies.length > 1) ...[
            const SizedBox(height: 6),
            Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              const Text('Give change in'),
              for (final cu in c.setup.currencies) ChoiceChip(label: Text(cu.code), selected: (_changeCurrency ?? c.currency) == cu.code, onSelected: (_) => setState(() => _changeCurrency = cu.code)),
            ]),
          ],
          if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: const TextStyle(color: Brand.coral))),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: TextButton(onPressed: c.payments.isEmpty ? null : () { c.clearPayments(); setState(() {}); }, child: const Text('Reset payments'))),
            Expanded(flex: 2, child: FilledButton(onPressed: covered && !c.busy ? _save : null, child: Text(c.busy ? 'Saving…' : (c.mode == 'layby' ? 'Start layby' : 'Complete sale')))),
          ]),
        ]),
      ),
    );
  }
}
