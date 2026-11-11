/// Customers, credit accounts and laybys. Port of tools/src/customers.ts (read the notes at the top of that file).
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/catalog.dart' show CurrencyInfo;
import '../selling/money.dart';
import '../selling/selling.dart' show CartPayment;
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

const _collected = 'collected';

class CustomerInput {
  const CustomerInput({
    this.id, required this.name, this.phone, this.address, this.taxNumber, this.priceTierId,
    this.creditLimitMinor, this.creditCurrency, this.isActive = true,
  });
  final String? id;
  final String name;
  final String? phone, address, taxNumber, priceTierId;
  final int? creditLimitMinor;
  final String? creditCurrency;
  final bool isActive;
}

class Owed {
  const Owed(this.currency, this.amountMinor);
  final String currency;
  final int amountMinor;
  @override
  bool operator ==(Object o) => o is Owed && o.currency == currency && o.amountMinor == amountMinor;
  @override
  int get hashCode => Object.hash(currency, amountMinor);
  @override
  String toString() => 'Owed($currency, $amountMinor)';
}

class CustomerSummary {
  const CustomerSummary({required this.id, required this.name, this.phone, this.creditLimitMinor, this.creditCurrency, required this.owes, required this.laybyOpen});
  final String id, name;
  final String? phone, creditCurrency;
  final int? creditLimitMinor;
  final List<Owed> owes;
  final int laybyOpen;
}

/// A payment taken against a customer's account or layby. It is the same shape as a payment taken at the till.
typedef PaymentInput = CartPayment;

class PaymentResult {
  const PaymentResult({required this.paymentId, required this.receiptNo, required this.appliedMinor, required this.targetCurrency, required this.balanceAfterMinor, required this.opensDrawer});
  final String paymentId, receiptNo, targetCurrency;
  final int appliedMinor, balanceAfterMinor;
  final bool opensDrawer;
}

class LaybySummary {
  const LaybySummary({
    required this.saleId, required this.receiptNo, required this.customerId, required this.customer, required this.currency,
    required this.totalMinor, required this.paidMinor, required this.balanceMinor, required this.startedAt, required this.collected,
  });
  final String saleId, receiptNo, customerId, customer, currency;
  final int totalMinor, paidMinor, balanceMinor, startedAt;
  final bool collected;
}

class StatementLine {
  const StatementLine({required this.at, required this.type, required this.currency, required this.amountMinor, required this.balanceMinor, this.ref});
  final int at;
  final String type, currency;
  final int amountMinor, balanceMinor;
  final String? ref;
}

class CustomerRepository {
  CustomerRepository({
    required this.db, required this.shopId, required this.deviceId, required this.receiptPrefix, this.userId,
    int Function()? clock, String Function()? idMaker,
  })  : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId, receiptPrefix;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<void> _allow(SqlDb tx, String permission) async {
    final uid = userId;
    if (uid == null) return; // internal callers; screens check permissions before offering the action
    final r = await _get(tx, 'select r.permissions from users u join roles r on r.id = u.role_id where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null', [uid]);
    var ok = false;
    if (r != null) {
      try {
        final list = jsonDecode(r['permissions'] as String);
        ok = list is List && list.contains(permission);
      } on FormatException {
        ok = false;
      }
    }
    if (!ok) throw SetupError('forbidden', 'You are not allowed to do that.');
  }

  Future<String> _add(SqlDb tx, String table, _Row row, int now, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  // ---- lists for the screens ----

  Future<List<CurrencyInfo>> currencies() async => [
        for (final r in await db.query('select code, symbol, minor_units from currencies where deleted_at is null and is_active = 1 order by code'))
          CurrencyInfo(r['code'] as String, (r['symbol'] as String?) ?? r['code'] as String, _i(r['minor_units'])),
      ];

  Future<List<({String code, String name, bool needsReference})>> paymentMethods() async => [
        for (final r in await db.query('select code, name, requires_reference from payment_methods where deleted_at is null and is_active = 1 order by rowid'))
          (code: r['code'] as String, name: r['name'] as String, needsReference: r['requires_reference'] == 1),
      ];

  // ---- customers ----

  Future<String> saveCustomer(CustomerInput c) async {
    final name = c.name.trim();
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx, 'customer.manage');
      if (name.isEmpty) throw SetupError('missing', 'Enter the customer\'s name.');
      final limit = c.creditLimitMinor;
      if (limit != null && limit < 0) throw SetupError('bad_limit', 'The credit limit must be zero or more.');
      if (limit != null && limit > 0 && c.creditCurrency != null && await _get(tx, 'select 1 as x from currencies where code = ? and deleted_at is null', [c.creditCurrency]) == null) {
        throw SetupError('unknown_currency', 'That currency is not set up.');
      }
      final phone = (c.phone ?? '').trim().isEmpty ? null : c.phone!.trim();
      if (phone != null) {
        final dup = await _get(tx, 'select id, name from customers where phone = ? and deleted_at is null and id is not ?', [phone, c.id]);
        if (dup != null) throw SetupError('duplicate_phone', '${dup['name']} already has that phone number.');
      }
      String? clean(String? v) => (v ?? '').trim().isEmpty ? null : v!.trim();
      final fields = <String, Object?>{
        'name': name, 'phone': phone, 'address': clean(c.address), 'tax_number': clean(c.taxNumber), 'price_tier_id': c.priceTierId,
        'credit_limit_minor': limit, 'credit_currency': (limit ?? 0) > 0 ? c.creditCurrency : null, 'is_active': c.isActive ? 1 : 0,
      };
      if (c.id != null) {
        final cur = await _get(tx, 'select version from customers where id = ?', [c.id]);
        if (cur == null) throw SetupError('not_found', 'That record was not found.');
        final o = <String, Object?>{...fields, 'version': _i(cur['version']) + 1, 'updated_at': now};
        final k = o.keys.toList();
        await tx.exec('update customers set ${k.map((x) => '"$x" = ?').join(', ')} where id = ?', [...k.map((x) => o[x]), c.id]);
        return c.id!;
      }
      return _add(tx, 'customers', fields, now, versioned: true);
    });
  }

  Future<List<Owed>> owedBy(String customerId, [SqlDb? tx]) async {
    final rows = await (tx ?? db).query(
      'select currency, sum(amount_minor) as amount_minor from customer_ledger where customer_id = ? group by currency having sum(amount_minor) <> 0 order by currency',
      [customerId],
    );
    return [for (final r in rows) Owed(r['currency'] as String, _i(r['amount_minor']))];
  }

  Future<List<CustomerSummary>> listCustomers({String search = '', bool onlyOwing = false}) async {
    final q = search.trim();
    final like = '%${q.replaceAllMapped(RegExp(r'[\\%_]'), (m) => '\\${m[0]}')}%';
    final rows = await db.query(
      "select * from customers where deleted_at is null and is_active = 1 ${q.isEmpty ? '' : "and (name like ? escape '\\' or phone like ? escape '\\')"} order by name collate nocase limit 200",
      q.isEmpty ? [] : [like, like],
    );
    final out = <CustomerSummary>[];
    for (final r in rows) {
      final id = r['id'] as String;
      out.add(CustomerSummary(
        id: id, name: r['name'] as String, phone: r['phone'] as String?, creditLimitMinor: r['credit_limit_minor'] == null ? null : _i(r['credit_limit_minor']),
        creditCurrency: r['credit_currency'] as String?, owes: await owedBy(id), laybyOpen: (await laybys(customerId: id, openOnly: true)).length,
      ));
    }
    return onlyOwing ? out.where((c) => c.owes.any((x) => x.amountMinor > 0)).toList() : out;
  }

  // ---- payments ----

  Future<int> _rate(SqlDb tx, String from, String to, int now) async {
    if (from == to) return 1000000;
    const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
    final d = await _get(tx, q, [from, to, now]);
    if (d != null) return _i(d['rate_micro']);
    final i = await _get(tx, q, [to, from, now]);
    if (i == null) throw SetupError('no_rate', 'No exchange rate between $from and $to.');
    return invertRate(_i(i['rate_micro']));
  }

  Future<_Row> _currency(SqlDb tx, String code) async {
    final c = await _get(tx, 'select * from currencies where code = ? and deleted_at is null', [code]);
    if (c == null) throw SetupError('unknown_currency', 'Currency $code is not set up.');
    return c;
  }

  Future<String> _nextPaymentNo(SqlDb tx) async {
    await tx.exec("insert into receipt_counters (kind, last_no) values ('payment', 1) on conflict (kind) do update set last_no = last_no + 1");
    final n = _i((await _get(tx, "select last_no from receipt_counters where kind = 'payment'"))!['last_no']);
    return '$receiptPrefix-P${n.toString().padLeft(6, '0')}';
  }

  Future<({int applied, int rate, bool opensDrawer})> _apply(SqlDb tx, PaymentInput p, String target, int owed, int now) async {
    if (p.amountMinor <= 0) throw SetupError('bad_payment', 'A payment must be more than zero.');
    final m = await _get(tx, 'select * from payment_methods where code = ? and deleted_at is null', [p.methodCode]);
    if (m == null) throw SetupError('unknown_method', 'Payment method ${p.methodCode} is not set up.');
    if (m['requires_reference'] == 1 && (p.reference ?? '').trim().isEmpty) throw SetupError('reference_needed', '${m['name']} needs the confirmation reference.');
    final payCur = await _currency(tx, p.currency);
    final tgtCur = await _currency(tx, target);
    if (owed <= 0) throw SetupError('nothing_owed', 'There is nothing to pay.');
    final rate = await _rate(tx, p.currency, target, now);
    final converted = p.currency == target ? p.amountMinor : convertMinor(p.amountMinor, rate, _i(payCur['minor_units']), _i(tgtCur['minor_units']));
    if (converted <= 0) throw SetupError('bad_payment', 'That amount is too small to count.');
    var applied = converted;
    if (converted > owed) {
      final back = p.currency == target
          ? converted - owed
          : convertMinor(converted - owed, await _rate(tx, target, p.currency, now), _i(tgtCur['minor_units']), _i(payCur['minor_units']));
      final inc = payCur['rounding_increment_minor'] == null ? 0 : _i(payCur['rounding_increment_minor']);
      final step = inc < 1 ? 1 : inc;
      if (back >= step) throw SetupError('overpaid', 'That is more than is owed.');
      applied = owed;
    }
    return (applied: applied, rate: rate, opensDrawer: m['opens_drawer'] == 1);
  }

  /// A payment on the customer's account, against the debt in [debtCurrency].
  Future<PaymentResult> receiveAccountPayment({required String customerId, required String debtCurrency, required PaymentInput payment}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx, 'sale.create');
      if (await _get(tx, 'select 1 as x from customers where id = ? and deleted_at is null', [customerId]) == null) throw SetupError('unknown_customer', 'That customer was not found.');
      final owed = _i((await _get(tx, 'select coalesce(sum(amount_minor), 0) as b from customer_ledger where customer_id = ? and currency = ?', [customerId, debtCurrency]))!['b']);
      final a = await _apply(tx, payment, debtCurrency, owed, now);
      final receiptNo = await _nextPaymentNo(tx);
      final pid = await _add(tx, 'account_payments', {
        'customer_id': customerId, 'sale_id': null, 'receipt_no': receiptNo, 'method_code': payment.methodCode, 'currency': payment.currency,
        'amount_minor': payment.amountMinor, 'target_currency': debtCurrency, 'rate_to_target_micro': a.rate, 'applied_minor': a.applied,
        'reference': (payment.reference ?? '').trim().isEmpty ? null : payment.reference!.trim(), 'user_id': userId,
      }, now);
      await _add(tx, 'customer_ledger', {'customer_id': customerId, 'type': 'payment', 'currency': debtCurrency, 'amount_minor': -a.applied, 'ref_type': 'account_payment', 'ref_id': pid}, now);
      return PaymentResult(paymentId: pid, receiptNo: receiptNo, appliedMinor: a.applied, targetCurrency: debtCurrency, balanceAfterMinor: owed - a.applied, opensDrawer: a.opensDrawer);
    });
  }

  // ---- layby ----

  Future<int> _laybyPaid(SqlDb tx, String saleId, String saleCurrency) async {
    var paid = 0;
    final cur = await _currency(tx, saleCurrency);
    for (final p in await tx.query('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?', [saleId])) {
      final c = p['currency'] as String;
      final v = c == saleCurrency
          ? _i(p['amount_minor'])
          : convertMinor(_i(p['amount_minor']), _i(p['rate_to_sale_micro']), _i((await _currency(tx, c))['minor_units']), _i(cur['minor_units']));
      paid += p['is_change'] == 1 ? -v : v;
    }
    final inst = await _get(tx, 'select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?', [saleId]);
    return paid + _i(inst!['s']);
  }

  Future<List<LaybySummary>> laybys({String? customerId, bool openOnly = false, SqlDb? tx}) async {
    final d = tx ?? db;
    final rows = await d.query(
      "select s.*, c.name as customer_name from sales s join customers c on c.id = s.customer_id where s.status = 'layby' ${customerId != null ? 'and s.customer_id = ?' : ''} order by s.completed_at desc",
      customerId != null ? [customerId] : [],
    );
    final out = <LaybySummary>[];
    for (final s in rows) {
      final id = s['id'] as String;
      final total = _i(s['total_minor']);
      final paid = await _laybyPaid(d, id, s['sale_currency'] as String);
      final done = await _get(d, 'select 1 as x from layby_payments where sale_id = ? and payment_id is null and due_note = ?', [id, _collected]) != null;
      out.add(LaybySummary(
        saleId: id, receiptNo: s['receipt_no'] as String, customerId: s['customer_id'] as String, customer: s['customer_name'] as String, currency: s['sale_currency'] as String,
        totalMinor: total, paidMinor: paid, balanceMinor: total - paid < 0 ? 0 : total - paid, startedAt: _i(s['completed_at']), collected: done,
      ));
    }
    return openOnly ? out.where((l) => !l.collected).toList() : out;
  }

  /// An instalment on a layby, paid in any currency.
  Future<PaymentResult> payLayby({required String saleId, required PaymentInput payment}) async {
    final now = _clock();
    return db.transaction((tx) async {
      await _allow(tx, 'sale.create');
      final sale = await _get(tx, "select * from sales where id = ? and status = 'layby'", [saleId]);
      if (sale == null) throw SetupError('not_layby', 'That is not a layby.');
      final l = (await laybys(tx: tx)).firstWhere((x) => x.saleId == saleId);
      if (l.collected) throw SetupError('already_collected', 'This layby was already collected.');
      final cur = sale['sale_currency'] as String;
      final a = await _apply(tx, payment, cur, l.balanceMinor, now);
      final receiptNo = await _nextPaymentNo(tx);
      final pid = await _add(tx, 'account_payments', {
        'customer_id': sale['customer_id'], 'sale_id': saleId, 'receipt_no': receiptNo, 'method_code': payment.methodCode, 'currency': payment.currency,
        'amount_minor': payment.amountMinor, 'target_currency': cur, 'rate_to_target_micro': a.rate, 'applied_minor': a.applied,
        'reference': (payment.reference ?? '').trim().isEmpty ? null : payment.reference!.trim(), 'user_id': userId,
      }, now);
      await _add(tx, 'layby_payments', {'sale_id': saleId, 'payment_id': pid, 'due_note': null}, now);
      return PaymentResult(paymentId: pid, receiptNo: receiptNo, appliedMinor: a.applied, targetCurrency: cur, balanceAfterMinor: l.balanceMinor - a.applied, opensDrawer: a.opensDrawer);
    });
  }

  /// Hands the goods over. Only when the layby is fully paid.
  Future<void> collectLayby(String saleId) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx, 'sale.create');
      final all = await laybys(tx: tx);
      final l = all.where((x) => x.saleId == saleId).firstOrNull;
      if (l == null) throw SetupError('not_layby', 'That is not a layby.');
      if (l.collected) throw SetupError('already_collected', 'This layby was already collected.');
      if (l.balanceMinor > 0) throw SetupError('balance_due', 'The layby is not fully paid yet.');
      await _add(tx, 'layby_payments', {'sale_id': saleId, 'payment_id': null, 'due_note': _collected}, now);
    });
  }

  // ---- statement ----

  Future<List<StatementLine>> statement(String customerId) async {
    final rows = await db.query('select * from customer_ledger where customer_id = ? order by created_at, rowid', [customerId]);
    final run = <String, int>{};
    final out = <StatementLine>[];
    for (final r in rows) {
      final cur = r['currency'] as String;
      final amt = _i(r['amount_minor']);
      run[cur] = (run[cur] ?? 0) + amt;
      String? ref;
      if (r['ref_type'] == 'sale') {
        ref = (await _get(db, 'select receipt_no from sales where id = ?', [r['ref_id']]))?['receipt_no'] as String?;
      } else if (r['ref_type'] == 'account_payment') {
        ref = (await _get(db, 'select receipt_no from account_payments where id = ?', [r['ref_id']]))?['receipt_no'] as String?;
      }
      out.add(StatementLine(at: _i(r['created_at']), type: r['type'] as String, currency: cur, amountMinor: amt, balanceMinor: run[cur]!, ref: ref));
    }
    return out;
  }
}
