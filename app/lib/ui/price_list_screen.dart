import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../selling/catalog.dart';
import '../setup/setup_repository.dart';
import 'product_pic.dart';
import 'theme.dart';

/// Every product with its selling price on one page. Tap a price to change it. Old prices are kept in the history.
class PriceListScreen extends StatefulWidget {
  const PriceListScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<PriceListScreen> createState() => _PriceListScreenState();
}

class _PriceListScreenState extends State<PriceListScreen> {
  final _search = TextEditingController();
  List<Map<String, Object?>> _rows = [];
  TillSetup? _setup;
  String? _note;

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
    final setup = _setup ?? await CatalogRepository(widget.controller.database!.sql).setup();
    final rows = await repo.listProducts(_search.text);
    if (mounted) setState(() { _setup = setup; _rows = rows; });
  }

  String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Future<void> _change(Map<String, Object?> r) async {
    final setup = _setup;
    if (setup == null) return;
    final cur = setup.currency(setup.baseCurrency);
    final id = r['id'] as String;
    final history = await repo.priceHistory(id);
    if (!mounted) return;
    final now = r['price_minor'] == null ? null : (r['price_minor'] as num).toInt();
    final ctl = TextEditingController();
    String? err;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => AlertDialog(
          title: Text(r['name'] as String),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(now == null ? 'No price yet' : 'Now: ${cur.format(now)}'),
              const SizedBox(height: 12),
              TextField(
                controller: ctl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: 'New price (${cur.code})', errorText: err),
              ),
              if (history.length > 1) ...[
                const SizedBox(height: 16),
                Text('Earlier prices', style: Theme.of(ctx).textTheme.titleSmall),
                for (final h in history.skip(1)) Text('${cur.format(h.priceMinor)}  (from ${_date(h.since)})'),
              ],
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final minor = cur.parse(ctl.text);
                if (minor == null) {
                  setS(() => err = 'Enter the price as a number, like 2.50');
                  return;
                }
                try {
                  await repo.setPrice(id, minor);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } on SetupError catch (e) {
                  setS(() => err = e.message);
                } catch (e) {
                  setS(() => err = 'Could not save. Please tell support: $e');
                }
              },
              child: const Text('Save price'),
            ),
          ],
        ),
      ),
    );
    ctl.dispose();
    if (saved == true) {
      _note = 'Price changed for ${r['name']}';
      await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final setup = _setup;
    final cur = setup?.currency(setup.baseCurrency);
    return Scaffold(
      appBar: AppBar(title: const Text('Price list')),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: TextField(controller: _search, onChanged: (_) => _load(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Find a product')),
        ),
        const Padding(padding: EdgeInsets.fromLTRB(16, 4, 16, 8), child: Align(alignment: Alignment.centerLeft, child: Text('Tap a price to change it.'))),
        if (_note != null) Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Align(alignment: Alignment.centerLeft, child: Text(_note!, style: const TextStyle(color: Brand.green, fontWeight: FontWeight.w600)))),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('No products yet'))
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final r = _rows[i];
                    final price = r['price_minor'] == null || cur == null ? null : cur.format((r['price_minor'] as num).toInt());
                    return ListTile(
                      leading: ProductPic(name: r['name'] as String, imageRef: r['image_ref'] as String?, size: 48),
                      title: Text(r['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: r['brand'] == null ? null : Text(r['brand'] as String),
                      trailing: OutlinedButton(onPressed: () => _change(r), child: Text(price ?? 'Set price', style: const TextStyle(fontWeight: FontWeight.w800))),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}
