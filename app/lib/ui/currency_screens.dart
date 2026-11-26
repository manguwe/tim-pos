import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../rates/rates_service.dart';
import '../selling/catalog.dart' show CurrencyInfo;
import '../setup/setup_repository.dart';
import 'setup_screens.dart' show showRateDialog;
import 'theme.dart';

/// Currencies, today's rates (by hand or from the live rates), and a converter for planning orders across countries.
class CurrenciesScreen extends StatefulWidget {
  const CurrenciesScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<CurrenciesScreen> createState() => _CurrenciesScreenState();
}

class _CurrenciesScreenState extends State<CurrenciesScreen> {
  List<Map<String, Object?>> _cur = [];
  List<Map<String, Object?>> _rates = [];
  LiveRates? _live;
  String? _note;
  bool _busy = false;
  final _amount = TextEditingController(text: '100');
  String _from = 'ZMW';
  String _to = 'USD';

  SetupRepository get repo => widget.controller.setupRepository()!;
  bool get _canEditRates => widget.controller.can('rate.edit');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final cur = await repo.shopCurrencies();
    final rates = await repo.latestRates();
    final live = await widget.controller.ratesService()?.cached();
    if (!mounted) return;
    setState(() {
      _cur = cur;
      _rates = rates;
      _live = live;
      final codes = _codes();
      if (!codes.contains(_from) && codes.isNotEmpty) _from = codes.first;
      if (!codes.contains(_to) && codes.length > 1) _to = codes[1];
    });
  }

  /// Currencies in the converter: the shop's own, plus any the live table can price.
  List<String> _codes() {
    final out = <String>[for (final c in _cur) c['code'] as String];
    for (final k in knownCurrencies) {
      final code = k['code'] as String;
      if (!out.contains(code) && (_live?.has(code) ?? false)) out.add(code);
    }
    return out;
  }

  int _units(String code) {
    for (final c in _cur) {
      if (c['code'] == code) return (c['minor_units'] as num).toInt();
    }
    return 2;
  }

  Future<void> _getLive() async {
    setState(() { _busy = true; _note = null; });
    try {
      final svc = widget.controller.ratesService()!;
      final live = await svc.refresh();
      var changed = 0;
      if (_canEditRates && _cur.length > 1) {
        final base = _cur.first['code'] as String;
        for (final c in _cur.skip(1)) {
          final micro = live.rateMicro(base, c['code'] as String);
          if (micro != null) {
            await repo.setExchangeRate(base, c['code'] as String, micro);
            changed++;
          }
        }
      }
      _note = changed > 0 ? 'Till rates updated from the live rates.' : 'Live rates loaded. They are used for the converter below.';
      await _load();
    } on RatesError catch (e) {
      _note = e.message;
    } on SetupError catch (e) {
      _note = e.message;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _rateText(int micro) {
    final whole = micro ~/ 1000000;
    final frac = (micro % 1000000).toString().padLeft(6, '0').replaceFirst(RegExp(r'0+$'), '');
    return frac.length < 2 ? '$whole.${frac.padRight(2, '0')}' : '$whole.$frac';
  }

  String? _converted() {
    final info = CurrencyInfo(_from, '', _units(_from));
    final minor = info.parse(_amount.text);
    if (minor == null) return null;
    final live = _live;
    if (live != null) {
      final out = live.convertMinor(minor, _from, _to, fromUnits: _units(_from), toUnits: _units(_to));
      if (out != null) return _fmt(out, _to);
    }
    // Fall back to the till's own rates when there are no live ones.
    for (final r in _rates) {
      if (r['from_currency'] == _from && r['to_currency'] == _to) {
        final out = (minor * (r['rate_micro'] as num).toInt() / 1000000).round();
        return _fmt(out, _to);
      }
      if (r['from_currency'] == _to && r['to_currency'] == _from) {
        final out = (minor * 1000000 / (r['rate_micro'] as num).toInt()).round();
        return _fmt(out, _to);
      }
    }
    return null;
  }

  String _fmt(int minor, String code) {
    final u = _units(code);
    var d = 1;
    for (var i = 0; i < u; i++) {
      d *= 10;
    }
    return '$code ${(minor / d).toStringAsFixed(u)}';
  }

  String _ago(int ms) {
    final d = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ms));
    if (d.inHours < 1) return 'less than an hour ago';
    if (d.inHours < 24) return '${d.inHours} hours ago';
    return '${d.inDays} days ago';
  }

  @override
  Widget build(BuildContext context) {
    final codes = _codes();
    final result = _converted();
    final have = {for (final c in _cur) c['code'] as String};
    final addable = [for (final k in knownCurrencies) if (!have.contains(k['code'])) k];
    return Scaffold(
      appBar: AppBar(title: const Text('Currencies and rates'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Your currencies', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (var i = 0; i < _cur.length; i++) Chip(label: Text('${_cur[i]['code']}${i == 0 ? ' (main)' : ''}')),
          if (widget.controller.can('settings.edit') && addable.isNotEmpty)
            PopupMenuButton<String>(
              onSelected: (code) async {
                await repo.addCurrency(code);
                await _load();
              },
              itemBuilder: (_) => [for (final k in addable) PopupMenuItem(value: k['code'] as String, child: Text('${k['code']}  ${k['name']}'))],
              child: const Chip(avatar: Icon(Icons.add, size: 18), label: Text('Add currency')),
            ),
        ]),
        const SizedBox(height: 20),
        const Text('Rates used at the till', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const SizedBox(height: 8),
        if (_rates.isEmpty) const Text('No rate set yet.'),
        for (final r in _rates) Text('1 ${r['from_currency']} = ${_rateText((r['rate_micro'] as num).toInt())} ${r['to_currency']}', style: const TextStyle(fontSize: 16)),
        if (_live != null) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Live rates were fetched ${_ago(_live!.fetchedAt)}. They change about once a day.', style: const TextStyle(color: Colors.black54))),
        const SizedBox(height: 10),
        Wrap(spacing: 8, children: [
          FilledButton.icon(icon: const Icon(Icons.cloud_download), label: const Text('Get live rates'), onPressed: _busy ? null : _getLive),
          if (_canEditRates && _cur.length > 1)
            OutlinedButton(onPressed: () async { await showRateDialog(context, widget.controller); await _load(); }, child: const Text('Set by hand')),
        ]),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!)),
        const Divider(height: 36),
        const Text('Converter', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)),
        const Text('Work out what an order costs in another currency, for example kwacha to dollars, before you pay.', style: TextStyle(color: Colors.black54)),
        const SizedBox(height: 10),
        TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Amount'), onChanged: (_) => setState(() {})),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _pick('From', _from, codes, (v) => setState(() => _from = v))),
          IconButton(onPressed: () => setState(() { final t = _from; _from = _to; _to = t; }), icon: const Icon(Icons.swap_horiz)),
          Expanded(child: _pick('To', _to, codes, (v) => setState(() => _to = v))),
        ]),
        const SizedBox(height: 14),
        Card(
          color: Brand.teal.withValues(alpha: 0.1),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(result ?? (_live == null && _rates.isEmpty ? 'Tap "Get live rates" first.' : 'No rate for that pair.'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
          ),
        ),
        const Text('This is an estimate from the daily rate. Your bank or mobile money agent may charge a different rate and fees.', style: TextStyle(color: Colors.black54, fontSize: 12)),
        const SizedBox(height: 4),
        const Text('Rates By Exchange Rate API (exchangerate-api.com)', style: TextStyle(color: Colors.black45, fontSize: 11)),
      ]),
    );
  }

  Widget _pick(String label, String value, List<String> codes, void Function(String) on) => DropdownButtonFormField<String>(
        key: ValueKey('$label-$value-${codes.length}'),
        initialValue: codes.contains(value) ? value : null,
        decoration: InputDecoration(labelText: label),
        items: [for (final c in codes) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) { if (v != null) on(v); },
      );
}
