import 'package:flutter/material.dart';

import '../customers/customer_repository.dart';
import '../printing/print_service.dart';
import '../selling/catalog.dart';
import '../setup/setup_repository.dart' show SetupError;
import 'slip_print.dart';
import 'theme.dart';

String _owes(List<Owed> owes, Map<String, CurrencyInfo> cur) {
  final parts = [for (final o in owes.where((o) => o.amountMinor != 0)) (cur[o.currency] ?? CurrencyInfo(o.currency, o.currency, 2)).format(o.amountMinor)];
  return parts.isEmpty ? 'Nothing owed' : 'Owes ${parts.join(' + ')}';
}

/// Chooses a customer at the till. Returns null when closed without choosing.
Future<CustomerSummary?> pickCustomer(BuildContext context, CustomerRepository repo) {
  return showModalBottomSheet<CustomerSummary>(
    context: context,
    isScrollControlled: true,
    builder: (_) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SizedBox(height: MediaQuery.of(context).size.height * 0.7, child: _CustomerList(repo: repo, canEdit: true, onPick: (c) => Navigator.of(context).pop(c))),
    ),
  );
}

class CustomersScreen extends StatelessWidget {
  const CustomersScreen({super.key, required this.repo, required this.canEdit, this.printing});
  final PrintService? printing;
  final CustomerRepository repo;
  final bool canEdit;
  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Customers'), backgroundColor: Brand.navy, foregroundColor: Colors.white),
        body: _CustomerList(
          repo: repo,
          canEdit: canEdit,
          onPick: (c) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => CustomerDetailScreen(repo: repo, customerId: c.id, canEdit: canEdit, printing: printing))),
        ),
      );
}

class _CustomerList extends StatefulWidget {
  const _CustomerList({required this.repo, required this.canEdit, required this.onPick});
  final CustomerRepository repo;
  final bool canEdit;
  final void Function(CustomerSummary) onPick;
  @override
  State<_CustomerList> createState() => _CustomerListState();
}

class _CustomerListState extends State<_CustomerList> {
  final _q = TextEditingController();
  List<CustomerSummary> _rows = [];
  Map<String, CurrencyInfo> _cur = {};
  bool _owing = false;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final t = ++_token;
    final cur = {for (final c in await widget.repo.currencies()) c.code: c};
    final rows = await widget.repo.listCustomers(search: _q.text, onlyOwing: _owing);
    if (!mounted || t != _token) return;
    setState(() {
      _cur = cur;
      _rows = rows;
    });
  }

  @override
  Widget build(BuildContext context) => Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(children: [
            Expanded(child: TextField(controller: _q, onChanged: (_) => _load(), decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or phone'))),
            const SizedBox(width: 8),
            FilterChip(label: const Text('Owing'), selected: _owing, onSelected: (v) {
              setState(() => _owing = v);
              _load();
            }),
          ]),
        ),
        if (widget.canEdit)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.person_add_alt),
              label: const Text('New customer'),
              onPressed: () async {
                final id = await showCustomerForm(context, widget.repo);
                if (id != null) await _load();
              },
            ),
          ),
        Expanded(
          child: _rows.isEmpty
              ? const Center(child: Text('No customers'))
              : ListView.separated(
                  itemCount: _rows.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (_, i) {
                    final c = _rows[i];
                    return ListTile(
                      title: Text(c.name),
                      subtitle: Text([if (c.phone != null) c.phone!, _owes(c.owes, _cur), if (c.laybyOpen > 0) '${c.laybyOpen} layby'].join(' · ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => widget.onPick(c),
                    );
                  },
                ),
        ),
      ]);
}

/// Add or edit a customer. Returns the customer's id, or null when cancelled.
Future<String?> showCustomerForm(BuildContext context, CustomerRepository repo, {String? id}) async {
  final currencies = await repo.currencies();
  String name = '', phone = '', address = '', limit = '';
  String curCode = currencies.isEmpty ? '' : currencies.first.code;
  if (id != null) {
    final r = (await repo.db.query('select * from customers where id = ?', [id])).first;
    name = r['name'] as String;
    phone = (r['phone'] as String?) ?? '';
    address = (r['address'] as String?) ?? '';
    curCode = (r['credit_currency'] as String?) ?? curCode;
    if (r['credit_limit_minor'] != null) {
      final info = currencies.firstWhere((c) => c.code == curCode, orElse: () => const CurrencyInfo('', '', 2));
      limit = (r['credit_limit_minor'] as int) == 0 ? '' : _plain((r['credit_limit_minor'] as num).toInt(), info.minorUnits);
    }
  }
  if (!context.mounted) return null;
  final fName = TextEditingController(text: name), fPhone = TextEditingController(text: phone), fAddr = TextEditingController(text: address), fLimit = TextEditingController(text: limit);
  String? err;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setS) => AlertDialog(
        title: Text(id == null ? 'New customer' : 'Edit customer'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: fName, decoration: const InputDecoration(labelText: 'Name'), textCapitalization: TextCapitalization.words),
            TextField(controller: fPhone, decoration: const InputDecoration(labelText: 'Phone'), keyboardType: TextInputType.phone),
            TextField(controller: fAddr, decoration: const InputDecoration(labelText: 'Address (optional)')),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: TextField(controller: fLimit, decoration: const InputDecoration(labelText: 'Credit limit (blank = none)'), keyboardType: const TextInputType.numberWithOptions(decimal: true))),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: currencies.any((c) => c.code == curCode) ? curCode : null,
                items: [for (final c in currencies) DropdownMenuItem(value: c.code, child: Text(c.code))],
                onChanged: (v) => setS(() => curCode = v ?? curCode),
              ),
            ]),
            if (err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err!, style: const TextStyle(color: Brand.coral))),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              final info = currencies.firstWhere((c) => c.code == curCode, orElse: () => const CurrencyInfo('', '', 2));
              int? lim;
              if (fLimit.text.trim().isNotEmpty) {
                lim = info.parse(fLimit.text);
                if (lim == null) {
                  setS(() => err = 'Enter the credit limit as an amount.');
                  return;
                }
              }
              try {
                final saved = await repo.saveCustomer(CustomerInput(id: id, name: fName.text, phone: fPhone.text, address: fAddr.text, creditLimitMinor: lim, creditCurrency: lim == null ? null : curCode));
                if (ctx.mounted) Navigator.pop(ctx, saved);
              } on SetupError catch (e) {
                setS(() => err = e.message);
              } catch (e) {
                setS(() => err = 'Could not save. Please tell support: $e');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

String _plain(int minor, int units) {
  if (units == 0) return '$minor';
  var p = 1;
  for (var i = 0; i < units; i++) {
    p *= 10;
  }
  return '${minor ~/ p}.${(minor % p).toString().padLeft(units, '0')}';
}

class CustomerDetailScreen extends StatefulWidget {
  const CustomerDetailScreen({super.key, required this.repo, required this.customerId, required this.canEdit, this.printing});
  final PrintService? printing;
  final CustomerRepository repo;
  final String customerId;
  final bool canEdit;
  @override
  State<CustomerDetailScreen> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<CustomerDetailScreen> {
  CustomerSummary? _c;
  List<LaybySummary> _lay = [];
  List<StatementLine> _st = [];
  Map<String, CurrencyInfo> _cur = {};
  String? _note;
  String? _lastPaymentId;

  CustomerRepository get repo => widget.repo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final cur = {for (final c in await repo.currencies()) c.code: c};
    final all = await repo.listCustomers();
    final me = all.where((c) => c.id == widget.customerId).firstOrNull;
    final lay = await repo.laybys(customerId: widget.customerId);
    final st = await repo.statement(widget.customerId);
    if (!mounted) return;
    setState(() {
      _cur = cur;
      _c = me;
      _lay = lay;
      _st = st;
    });
  }

  String _money(int minor, String code) => (_cur[code] ?? CurrencyInfo(code, code, 2)).format(minor);

  Future<void> _pay({required String title, required String target, required int balance, String? saleId}) async {
    final methods = await repo.paymentMethods();
    if (!mounted) return;
    final result = await showDialog<PaymentResult>(
      context: context,
      builder: (_) => _PayDialog(repo: repo, title: title, target: target, balance: balance, methods: methods, currencies: _cur.values.toList(), saleId: saleId, customerId: widget.customerId),
    );
    if (result != null) {
      setState(() => _note = 'Receipt ${result.receiptNo}: ${_money(result.appliedMinor, result.targetCurrency)} received. ${result.balanceAfterMinor > 0 ? '${_money(result.balanceAfterMinor, result.targetCurrency)} still to pay.' : 'Paid in full.'}');
      _lastPaymentId = result.paymentId;
      await _load();
      if (mounted) await printSlipSafely(context, widget.printing, (v) => v.paymentSlip(result.paymentId));
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      appBar: AppBar(
        title: Text(c?.name ?? 'Customer'),
        backgroundColor: Brand.navy,
        foregroundColor: Colors.white,
        actions: [
          if (widget.canEdit && c != null)
            IconButton(icon: const Icon(Icons.edit_outlined), onPressed: () async {
              if (await showCustomerForm(context, repo, id: c.id) != null) await _load();
            }),
        ],
      ),
      body: c == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (c.phone != null) Text(c.phone!),
              if (c.creditLimitMinor != null && c.creditLimitMinor! > 0) Text('Credit limit ${_money(c.creditLimitMinor!, c.creditCurrency ?? '')}'),
              const SizedBox(height: 8),
              Text(_owes(c.owes, _cur), style: Theme.of(context).textTheme.titleLarge),
              for (final o in c.owes.where((o) => o.amountMinor > 0))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: FilledButton.icon(
                    icon: const Icon(Icons.payments_outlined),
                    label: Text('Take payment on ${_money(o.amountMinor, o.currency)}'),
                    onPressed: () => _pay(title: 'Payment on account', target: o.currency, balance: o.amountMinor),
                  ),
                ),
              if (_note != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(_note!, style: const TextStyle(color: Brand.teal, fontWeight: FontWeight.w600))),
              if (_lastPaymentId != null && widget.printing != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    icon: const Icon(Icons.print_outlined),
                    label: const Text('Print receipt'),
                    onPressed: () => printSlipSafely(context, widget.printing, (v) => v.paymentSlip(_lastPaymentId!), copy: true, quietWhenNoPrinter: false),
                  ),
                ),
              if (_lay.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text('Laybys', style: Theme.of(context).textTheme.titleMedium),
                for (final l in _lay)
                  Card(
                    child: ListTile(
                      title: Text('${l.receiptNo} · ${_money(l.totalMinor, l.currency)}'),
                      subtitle: Text(l.collected ? 'Collected' : l.balanceMinor > 0 ? 'Paid ${_money(l.paidMinor, l.currency)} · ${_money(l.balanceMinor, l.currency)} to pay' : 'Paid in full, ready to collect'),
                      trailing: l.collected
                          ? const Icon(Icons.check_circle, color: Brand.green)
                          : l.balanceMinor > 0
                              ? TextButton(onPressed: () => _pay(title: 'Layby ${l.receiptNo}', target: l.currency, balance: l.balanceMinor, saleId: l.saleId), child: const Text('Pay'))
                              : FilledButton(
                                  onPressed: () async {
                                    try {
                                      await repo.collectLayby(l.saleId);
                                      await _load();
                                    } on SetupError catch (e) {
                                      setState(() => _note = e.message);
                                    }
                                  },
                                  child: const Text('Hand over'),
                                ),
                    ),
                  ),
              ],
              const SizedBox(height: 18),
              Text('Account history', style: Theme.of(context).textTheme.titleMedium),
              if (_st.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: Text('No account activity yet.')),
              for (final l in _st.reversed)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${l.type == 'credit_sale' ? 'Sale on account' : l.type == 'payment' ? 'Payment' : l.type}${l.ref == null ? '' : ' · ${l.ref}'}'),
                  subtitle: Text(DateTime.fromMillisecondsSinceEpoch(l.at).toLocal().toString().substring(0, 16)),
                  trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(_money(l.amountMinor, l.currency), style: TextStyle(fontWeight: FontWeight.w700, color: l.amountMinor < 0 ? Brand.green : null)),
                    Text('owes ${_money(l.balanceMinor, l.currency)}', style: Theme.of(context).textTheme.bodySmall),
                  ]),
                ),
            ]),
    );
  }
}

class _PayDialog extends StatefulWidget {
  const _PayDialog({required this.repo, required this.title, required this.target, required this.balance, required this.methods, required this.currencies, required this.customerId, this.saleId});
  final CustomerRepository repo;
  final String title, target, customerId;
  final String? saleId;
  final int balance;
  final List<({String code, String name, bool needsReference})> methods;
  final List<CurrencyInfo> currencies;
  @override
  State<_PayDialog> createState() => _PayDialogState();
}

class _PayDialogState extends State<_PayDialog> {
  final _amount = TextEditingController();
  final _ref = TextEditingController();
  late String _method = widget.methods.isEmpty ? 'cash' : widget.methods.first.code;
  late String _cur = widget.target;
  String? _err;
  bool _busy = false;

  CurrencyInfo get _info => widget.currencies.firstWhere((c) => c.code == _cur, orElse: () => CurrencyInfo(_cur, _cur, 2));
  CurrencyInfo get _target => widget.currencies.firstWhere((c) => c.code == widget.target, orElse: () => CurrencyInfo(widget.target, widget.target, 2));

  Future<void> _submit() async {
    final minor = _info.parse(_amount.text);
    if (minor == null || minor <= 0) {
      setState(() => _err = 'Enter the amount.');
      return;
    }
    setState(() {
      _busy = true;
      _err = null;
    });
    final p = PaymentInput(methodCode: _method, currency: _cur, amountMinor: minor, reference: _ref.text);
    try {
      final r = widget.saleId == null
          ? await widget.repo.receiveAccountPayment(customerId: widget.customerId, debtCurrency: widget.target, payment: p)
          : await widget.repo.payLayby(saleId: widget.saleId!, payment: p);
      if (mounted) Navigator.pop(context, r);
    } on SetupError catch (e) {
      if (mounted) setState(() => _err = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final needsRef = widget.methods.where((m) => m.code == _method).any((m) => m.needsReference);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('To pay: ${_target.format(widget.balance)}'),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [for (final m in widget.methods) ChoiceChip(label: Text(m.name), selected: _method == m.code, onSelected: (_) => setState(() => _method = m.code))]),
          const SizedBox(height: 8),
          Wrap(spacing: 8, children: [for (final c in widget.currencies) ChoiceChip(label: Text(c.code), selected: _cur == c.code, onSelected: (_) => setState(() => _cur = c.code))]),
          TextField(controller: _amount, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: InputDecoration(labelText: 'Amount in $_cur')),
          if (_cur == widget.target) Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () => _amount.text = _plain(widget.balance, _target.minorUnits), child: const Text('Pay all'))),
          if (needsRef) TextField(controller: _ref, decoration: const InputDecoration(labelText: 'Confirmation reference')),
          if (_err != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_err!, style: const TextStyle(color: Brand.coral))),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _busy ? null : _submit, child: Text(_busy ? 'Saving…' : 'Receive payment')),
      ],
    );
  }
}
