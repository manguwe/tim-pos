import 'package:flutter/material.dart';

import '../auth/auth_repository.dart';
import '../returns/return_repository.dart';
import '../printing/print_service.dart';
import '../selling/catalog.dart';
import '../setup/setup_repository.dart' show SetupError;
import 'slip_print.dart';
import 'theme.dart';

/// Asks a manager to approve an action with their PIN. Returns the approver's user id, or null when cancelled.
Future<String?> askApproval(BuildContext context, AuthRepository auth, {required String permission, required String why, String? requestedBy, String? refId}) async {
  final users = await auth.listLoginUsers();
  if (!context.mounted) return null;
  var chosen = users.isEmpty ? null : users.first.id;
  final pin = TextEditingController();
  String? err;
  final r = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: const Text('Manager approval'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(why),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: chosen,
            decoration: const InputDecoration(labelText: 'Approved by'),
            items: [for (final u in users) DropdownMenuItem(value: u.id, child: Text(u.role == null ? u.name : '${u.name} (${u.role})'))],
            onChanged: (v) => chosen = v,
          ),
          TextField(controller: pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Their PIN')),
          if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              if (chosen == null) return;
              try {
                await auth.approve(action: permission, requestedBy: requestedBy, approverId: chosen!, pin: pin.text, refType: refId == null ? null : 'sale', refId: refId);
                if (ctx.mounted) Navigator.pop(ctx, chosen);
              } on AuthError catch (e) {
                setS(() => err = e.message);
              }
            },
            child: const Text('Approve'),
          ),
        ],
      ),
    ),
  );
  pin.dispose();
  return r;
}

/// Find a sale by its receipt number, then take items back or void it.
class ReturnScreen extends StatefulWidget {
  const ReturnScreen({super.key, required this.repo, required this.auth, this.userId, this.printing});
  final PrintService? printing;
  final ReturnRepository repo;
  final AuthRepository auth;
  final String? userId;
  @override
  State<ReturnScreen> createState() => _ReturnScreenState();
}

class _ReturnScreenState extends State<ReturnScreen> {
  final _receipt = TextEditingController();
  final _reason = TextEditingController();
  final _ref = TextEditingController();
  final _amount = TextEditingController();
  FoundSale? _sale;
  List<ReturnableLine> _lines = [];
  List<PastReturn> _past = [];
  final Map<String, int> _qty = {};
  final Set<String> _damaged = {};
  Map<String, CurrencyInfo> _cur = {};
  List<({String code, String name, bool needsReference})> _methods = [];
  String _method = 'cash';
  String? _payCur;
  ReturnPreview? _preview;
  String? _note;
  String? _done;
  String? _lastReturnId;
  bool _busy = false;

  ReturnRepository get repo => widget.repo;

  @override
  void dispose() {
    _receipt.dispose();
    _reason.dispose();
    _ref.dispose();
    _amount.dispose();
    super.dispose();
  }

  String _m(int minor, String code) => (_cur[code] ?? CurrencyInfo(code, code, 2)).format(minor);

  Future<void> _find() async {
    setState(() {
      _note = null;
      _done = null;
    });
    final rows = await repo.db.query('select code, symbol, minor_units from currencies where deleted_at is null and is_active = 1 order by code');
    _cur = {for (final r in rows) r['code'] as String: CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, (r['minor_units'] as num).toInt())};
    _methods = await repo.paymentMethods();
    final s = await repo.findSaleByReceipt(_receipt.text);
    if (s == null) {
      setState(() {
        _sale = null;
        _note = 'No sale with that receipt number.';
      });
      return;
    }
    await _loadSale(s);
  }

  Future<void> _loadSale(FoundSale s) async {
    final lines = await repo.returnableLines(s.saleId);
    final past = await repo.returnsForSale(s.saleId);
    if (!mounted) return;
    setState(() {
      _sale = s;
      _lines = lines;
      _past = past;
      _qty.clear();
      _damaged.clear();
      _payCur = s.currency;
      _preview = null;
      _amount.clear();
    });
  }

  bool get _isLayby => _sale?.status == 'layby';

  List<ReturnItem> get _items => [for (final l in _lines) if ((_qty[l.saleLineId] ?? 0) > 0) ReturnItem(saleLineId: l.saleLineId, qtyMilli: _qty[l.saleLineId]!, restock: !_damaged.contains(l.saleLineId))];

  Future<void> _recalc() async {
    final s = _sale;
    if (s == null) return;
    final items = _isLayby ? [for (final l in _lines) if (l.remainingMilli > 0) ReturnItem(saleLineId: l.saleLineId, qtyMilli: l.remainingMilli)] : _items;
    if (items.isEmpty) {
      setState(() => _preview = null);
      return;
    }
    try {
      final pv = await repo.previewReturn(s.saleId, items, kind: _isLayby ? 'void' : 'return');
      final sug = await repo.suggestPayout(s.saleId, pv.payoutDueMinor);
      if (!mounted) return;
      setState(() {
        _preview = pv;
        _note = null;
        if (sug.isNotEmpty) {
          _method = sug.first.methodCode;
          _payCur = pv.currency;
          _amount.text = _plain(pv.payoutDueMinor, (_cur[pv.currency] ?? CurrencyInfo(pv.currency, pv.currency, 2)).minorUnits);
        } else {
          _amount.clear();
        }
      });
    } on SetupError catch (e) {
      if (mounted) setState(() => _note = e.message);
    }
  }

  String _plain(int minor, int units) {
    if (units == 0) return '$minor';
    var p = 1;
    for (var i = 0; i < units; i++) {
      p *= 10;
    }
    return '${minor ~/ p}.${(minor % p).toString().padLeft(units, '0')}';
  }

  Future<void> _submit({required bool voidAll}) async {
    final s = _sale;
    final pv = _preview;
    if (s == null || pv == null) return;
    final need = voidAll ? 'sale.void' : 'sale.refund';
    String? approver;
    if (!await repo.canWithoutApproval(need)) {
      if (!mounted) return;
      approver = await askApproval(context, widget.auth, permission: need, why: voidAll ? 'Voiding ${s.receiptNo} needs a manager.' : 'A refund on ${s.receiptNo} needs a manager.', requestedBy: widget.userId, refId: s.saleId);
      if (approver == null) return;
    }
    final payouts = <Payout>[];
    if (pv.payoutDueMinor > 0) {
      final cur = _cur[_payCur ?? pv.currency] ?? CurrencyInfo(pv.currency, pv.currency, 2);
      final minor = cur.parse(_amount.text);
      if (minor == null || minor <= 0) {
        setState(() => _note = 'Enter the amount paid back.');
        return;
      }
      payouts.add(Payout(methodCode: _method, currency: cur.code, amountMinor: minor, reference: _ref.text));
    }
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      final res = voidAll || _isLayby
          ? await repo.voidSale(saleId: s.saleId, reason: _reason.text, payouts: payouts, approvedBy: approver)
          : await repo.processReturn(saleId: s.saleId, items: _items, reason: _reason.text, payouts: payouts, approvedBy: approver);
      final parts = <String>[
        '${res.kind == 'void' ? 'Voided' : 'Return'} ${res.receiptNo}: ${_m(res.valueMinor, pv.currency)}',
        if (res.creditPartMinor > 0) 'taken off the customer\'s account ${_m(res.creditPartMinor, pv.currency)}',
        if (res.payoutMinor > 0) 'pay back ${_m(res.payoutMinor, pv.currency)}',
      ];
      _done = parts.join(' · ');
      _lastReturnId = res.returnId;
      _reason.clear();
      _ref.clear();
      await _loadSale((await repo.findSaleByReceipt(s.receiptNo))!);
      if (mounted) await printSlipSafely(context, widget.printing, (v) => v.refundSlip(res.returnId));
    } on SetupError catch (e) {
      if (mounted) setState(() => _note = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = _sale;
    final pv = _preview;
    return Scaffold(
      appBar: AppBar(title: const Text('Returns and voids'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Row(children: [
          Expanded(child: TextField(controller: _receipt, textCapitalization: TextCapitalization.characters, decoration: const InputDecoration(labelText: 'Receipt number', hintText: 'D1-000123'), onSubmitted: (_) => _find())),
          const SizedBox(width: 10),
          FilledButton(onPressed: _find, child: const Text('Find')),
        ]),
        if (_done != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_done!, style: const TextStyle(color: Brand.teal, fontWeight: FontWeight.w700))),
        if (_lastReturnId != null && widget.printing != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print slip'),
              onPressed: () => printSlipSafely(context, widget.printing, (v) => v.refundSlip(_lastReturnId!), copy: true, quietWhenNoPrinter: false),
            ),
          ),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(_note!, style: const TextStyle(color: Brand.coral))),
        if (s != null) ...[
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              title: Text('${s.receiptNo} · ${_m(s.totalMinor, s.currency)}'),
              subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(s.at).toLocal().toString().substring(0, 16)} · ${s.voided ? 'VOIDED' : s.status}'),
            ),
          ),
          if (_past.isNotEmpty) ...[
            const Text('Already done on this sale'),
            for (final p in _past) Text('${p.receiptNo} ${p.kind == 'void' ? 'void' : 'return'} ${_m(p.valueMinor, s.currency)}${p.reason == null ? '' : ' · ${p.reason}'}'),
            const SizedBox(height: 8),
          ],
          if (s.voided)
            const Text('This sale was voided. Nothing more can be done on it.')
          else if (_isLayby && _lines.any((l) => l.remainingMilli > 0)) ...[
            const Text('This layby has not been collected. It can be cancelled, and the customer gets back what they have paid.'),
            const SizedBox(height: 8),
            for (final l in _lines) Text('${l.remainingMilli / 1000} × ${l.description}'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _recalc, child: const Text('Work out the refund')),
          ] else ...[
            const Text('Choose what is coming back'),
            for (final l in _lines)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(l.description),
                subtitle: Text('${l.remainingMilli / 1000} of ${l.qtyMilli / 1000} can still be returned'),
                trailing: l.remainingMilli == 0
                    ? const Icon(Icons.check, color: Brand.green)
                    : Row(mainAxisSize: MainAxisSize.min, children: [
                        IconButton(
                          icon: const Icon(Icons.remove_circle_outline),
                          onPressed: (_qty[l.saleLineId] ?? 0) <= 0 ? null : () {
                            final q = (_qty[l.saleLineId] ?? 0) - 1000;
                            setState(() => _qty[l.saleLineId] = q < 0 ? 0 : q);
                            _recalc();
                          },
                        ),
                        Text('${(_qty[l.saleLineId] ?? 0) / 1000}'),
                        IconButton(
                          icon: const Icon(Icons.add_circle_outline),
                          onPressed: () {
                            final q = (_qty[l.saleLineId] ?? 0) + 1000;
                            setState(() => _qty[l.saleLineId] = q > l.remainingMilli ? l.remainingMilli : q);
                            _recalc();
                          },
                        ),
                        Checkbox(
                          value: _damaged.contains(l.saleLineId),
                          onChanged: (v) => setState(() => v == true ? _damaged.add(l.saleLineId) : _damaged.remove(l.saleLineId)),
                        ),
                        const Text('Damaged'),
                      ]),
              ),
          ],
          if (pv != null && !s.voided) ...[
            const Divider(),
            Text('Value of goods ${_m(pv.valueMinor, pv.currency)}', style: Theme.of(context).textTheme.titleMedium),
            if (pv.creditPartMinor > 0) Text('Taken off the customer\'s account ${_m(pv.creditPartMinor, pv.currency)}'),
            Text(pv.payoutDueMinor > 0 ? 'To pay back ${_m(pv.payoutDueMinor, pv.currency)}' : 'Nothing to pay back'),
            if (pv.payoutDueMinor > 0) ...[
              const SizedBox(height: 8),
              Wrap(spacing: 8, children: [for (final m in _methods) ChoiceChip(label: Text(m.name), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code))]),
              Wrap(spacing: 8, children: [for (final c in _cur.values) ChoiceChip(label: Text(c.code), selected: _payCur == c.code, onSelected: (_) => setState(() { _payCur = c.code; _amount.clear(); }))]),
              TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount paid back in ${_payCur ?? pv.currency}')),
              if (_methods.where((m) => m.code == _method).any((m) => m.needsReference)) TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Confirmation reference')),
            ],
            TextField(controller: _reason, decoration: const InputDecoration(labelText: 'Reason (required)')),
            const SizedBox(height: 12),
            Row(children: [
              if (!_isLayby) Expanded(child: FilledButton(onPressed: _busy ? null : () => _submit(voidAll: false), child: const Text('Refund'))),
              if (!_isLayby && _past.isEmpty) const SizedBox(width: 10),
              if (_isLayby || _past.isEmpty)
                Expanded(child: OutlinedButton(onPressed: _busy ? null : () => _submit(voidAll: true), child: Text(_isLayby ? 'Cancel layby' : 'Void whole sale'))),
            ]),
          ],
        ],
      ]),
    );
  }
}
