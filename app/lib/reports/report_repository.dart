/// Reports for the owner and manager. Port of tools/src/reports.ts (read the counting rules at the top of that file).
/// Read-only: nothing here writes to the database.
library;

import 'dart:convert';

import '../data/sql_db.dart';
import '../selling/money.dart';

typedef _Row = Map<String, Object?>;

/// A half-open range [from, to) in UTC milliseconds.
class DateRange {
  const DateRange(this.from, this.to);
  final int from, to;
}

class ReportFilter {
  const ReportFilter({this.branchId, this.userId});
  final String? branchId, userId;
}

class CurrencyTotals {
  CurrencyTotals(this.currency);
  final String currency;
  int sales = 0, grossMinor = 0, discountMinor = 0, taxMinor = 0, returnsMinor = 0, netMinor = 0;
}

class OpenLayby {
  OpenLayby(this.currency);
  final String currency;
  int count = 0, valueMinor = 0, paidMinor = 0;
}

class SalesSummary {
  SalesSummary({
    required this.baseCurrency, required this.byCurrency, required this.sales, required this.returns, required this.revenueMinor, required this.taxMinor,
    required this.costMinor, required this.profitMinor, required this.linesWithoutCost, required this.averageSaleMinor, required this.openLayby,
  });
  final String baseCurrency;
  final List<CurrencyTotals> byCurrency;
  final int sales, returns, revenueMinor, taxMinor, costMinor, profitMinor, linesWithoutCost, averageSaleMinor;
  final List<OpenLayby> openLayby;
}

class DayRow {
  DayRow(this.day);
  final String day;
  int sales = 0, revenueMinor = 0, returnsMinor = 0, netMinor = 0;
}

class ProductRow {
  ProductRow(this.productId, this.name);
  final String? productId;
  final String name;
  int qtyMilli = 0, revenueMinor = 0, costMinor = 0, profitMinor = 0, _tax = 0;
}

class TakingRow {
  TakingRow(this.method, this.currency);
  final String method, currency;
  int receivedMinor = 0, paidBackMinor = 0, netMinor = 0;
}

class StockLine {
  const StockLine({required this.productId, required this.name, required this.qtyMilli, this.costMinor, required this.valueMinor});
  final String productId, name;
  final int qtyMilli, valueMinor;
  final int? costMinor;
}

class StockValue {
  const StockValue({required this.baseCurrency, required this.totalMinor, required this.products, required this.withoutCost, required this.negative, required this.rows});
  final String baseCurrency;
  final int totalMinor, products, withoutCost, negative;
  final List<StockLine> rows;
}

class OutOfStock {
  const OutOfStock(this.productId, this.name, this.qtyMilli);
  final String productId, name;
  final int qtyMilli;
}

class ExpiringBatch {
  const ExpiringBatch({required this.productId, required this.name, this.batchCode, required this.expiryDate, required this.qtyMilli, required this.expired});
  final String productId, name, expiryDate;
  final String? batchCode;
  final int qtyMilli;
  final bool expired;
}

class Debtor {
  const Debtor({required this.customerId, required this.name, this.phone, required this.currency, required this.owedMinor});
  final String customerId, name, currency;
  final String? phone;
  final int owedMinor;
}

class OwedTotal {
  OwedTotal(this.currency);
  final String currency;
  int owedMinor = 0, customers = 0;
}

class Receivables {
  const Receivables(this.byCurrency, this.debtors);
  final List<OwedTotal> byCurrency;
  final List<Debtor> debtors;
}

class CashUpCurrency {
  const CashUpCurrency(this.currency, this.expectedMinor, this.countedMinor, this.differenceMinor);
  final String currency;
  final int expectedMinor, countedMinor, differenceMinor;
}

class CashUpRow {
  const CashUpRow({required this.shiftId, this.user, required this.openedAt, required this.closedAt, required this.currencies});
  final String shiftId;
  final String? user;
  final int openedAt, closedAt;
  final List<CashUpCurrency> currencies;
}

String dayOf(int ms, int offsetMin) {
  final d = DateTime.fromMillisecondsSinceEpoch(ms + offsetMin * 60000, isUtc: true);
  String p(int n) => n.toString().padLeft(2, '0');
  return '${d.year.toString().padLeft(4, '0')}-${p(d.month)}-${p(d.day)}';
}

const _notVoided = 'not exists (select 1 from sale_voids v where v.sale_id = s.id)';
const _day = 86400000;

class ReportRepository {
  ReportRepository(this.db);
  final SqlDb db;

  int _i(Object? v) => (v as num).toInt();

  Future<_Row?> _get(String sql, [List<Object?> a = const []]) async {
    final r = await db.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<String> baseCurrency() async => (await _get('select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String? ?? 'USD';

  final Map<String, int> _units = {};
  Future<int> _unitsOf(String code) async {
    final c = _units[code];
    if (c != null) return c;
    final v = (await _get('select minor_units from currencies where code = ?', [code]))?['minor_units'];
    return _units[code] = v == null ? 2 : _i(v);
  }

  /// Converts an amount of a sale into the base currency using the rates saved with that sale. No known rate: left out, not guessed.
  Future<int> _toBase(int amount, String cur, String base, _Row sale) async {
    if (cur == base || amount == 0) return amount;
    var used = <String, dynamic>{};
    try {
      final raw = sale['rates_used'];
      if (raw is String) used = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      used = {};
    }
    int? rate = (used['$cur>$base'] as num?)?.toInt();
    if (rate == null && used['$base>$cur'] != null) rate = invertRate((used['$base>$cur'] as num).toInt());
    if (rate == null) {
      const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
      final d = await _get(q, [cur, base, sale['completed_at']]);
      final i = d != null ? null : await _get(q, [base, cur, sale['completed_at']]);
      if (d != null) {
        rate = _i(d['rate_micro']);
      } else if (i != null) {
        rate = invertRate(_i(i['rate_micro']));
      } else {
        return 0;
      }
    }
    return convertMinor(amount, rate, await _unitsOf(cur), await _unitsOf(base));
  }

  List<Object?> _ids(ReportFilter f) => [if (f.branchId != null) f.branchId, if (f.userId != null) f.userId];

  Future<List<_Row>> _eligible(DateRange r, ReportFilter f) async => [
        for (final x in await db.query(
            "select * from (select s.*, case when s.status = 'layby' then (select min(lp.created_at) from layby_payments lp where lp.sale_id = s.id and lp.payment_id is null and lp.due_note = 'collected') else s.completed_at end as eff_at from sales s where $_notVoided ${f.branchId != null ? 'and s.branch_id = ?' : ''} ${f.userId != null ? 'and s.user_id = ?' : ''}) where eff_at is not null and eff_at >= ? and eff_at < ? order by eff_at",
            [..._ids(f), r.from, r.to]))
          Map<String, Object?>.of(x),
      ];

  Future<List<_Row>> _returnsIn(DateRange r, ReportFilter f) async => [
        for (final x in await db.query(
            "select rt.*, s.rates_used, s.completed_at, s.sale_currency from sale_returns rt join sales s on s.id = rt.original_sale_id where rt.kind = 'return' and rt.created_at >= ? and rt.created_at < ? and $_notVoided ${f.branchId != null ? 'and s.branch_id = ?' : ''} ${f.userId != null ? 'and s.user_id = ?' : ''} order by rt.created_at",
            [r.from, r.to, ..._ids(f)]))
          Map<String, Object?>.of(x),
      ];

  Future<int> _laybyPaid(String saleId, String cur) async {
    var paid = 0;
    for (final p in await db.query('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?', [saleId])) {
      final c = p['currency'] as String;
      final v = c == cur ? _i(p['amount_minor']) : convertMinor(_i(p['amount_minor']), _i(p['rate_to_sale_micro']), await _unitsOf(c), await _unitsOf(cur));
      paid += p['is_change'] == 1 ? -v : v;
    }
    return paid + _i((await _get('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?', [saleId]))!['s']);
  }

  Future<SalesSummary> salesSummary(DateRange r, [ReportFilter f = const ReportFilter()]) async {
    final base = await baseCurrency();
    final sales = await _eligible(r, f);
    final rets = await _returnsIn(r, f);
    final per = <String, CurrencyTotals>{};
    CurrencyTotals slot(String c) => per.putIfAbsent(c, () => CurrencyTotals(c));
    var revenue = 0, tax = 0, cost = 0, noCost = 0;
    for (final s in sales) {
      final cur = s['sale_currency'] as String;
      final t = slot(cur);
      t.sales++;
      t.grossMinor += _i(s['total_minor']);
      t.discountMinor += _i(s['discount_minor']);
      t.taxMinor += _i(s['tax_minor']);
      revenue += await _toBase(_i(s['total_minor']), cur, base, s);
      tax += await _toBase(_i(s['tax_minor']), cur, base, s);
      for (final l in await db.query('select qty_milli, unit_cost_minor from sale_lines where sale_id = ?', [s['id']])) {
        if (l['unit_cost_minor'] == null) {
          noCost++;
        } else {
          cost += divRound(_i(l['unit_cost_minor']) * _i(l['qty_milli']), 1000);
        }
      }
    }
    for (final rt in rets) {
      final cur = rt['sale_currency'] as String;
      slot(cur).returnsMinor += _i(rt['refund_minor']);
      revenue -= await _toBase(_i(rt['refund_minor']), cur, base, rt);
      for (final rl in await db.query(
          'select rl.qty_milli, rl.restock, rl.amount_minor, sl.tax_minor, sl.line_total_minor, sl.unit_cost_minor from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ?',
          [rt['id']])) {
        if (_i(rl['line_total_minor']) > 0) {
          final tx = divRound(_i(rl['tax_minor'] ?? 0) * _i(rl['amount_minor']), _i(rl['line_total_minor']));
          tax -= await _toBase(tx, cur, base, rt);
          slot(cur).taxMinor -= tx;
        }
        if (rl['restock'] == 1 && rl['unit_cost_minor'] != null) cost -= divRound(_i(rl['unit_cost_minor']) * _i(rl['qty_milli']), 1000);
      }
    }
    final totals = per.values.toList()..sort((a, b) => a.currency.compareTo(b.currency));
    for (final t in totals) {
      t.netMinor = t.grossMinor - t.returnsMinor;
    }
    final openRows = await db.query(
        "select s.id, s.sale_currency, s.total_minor from sales s where s.status = 'layby' and $_notVoided and not exists (select 1 from layby_payments lp where lp.sale_id = s.id and lp.payment_id is null and lp.due_note = 'collected') ${f.branchId != null ? 'and s.branch_id = ?' : ''}",
        [if (f.branchId != null) f.branchId]);
    final lay = <String, OpenLayby>{};
    for (final l in openRows) {
      final cur = l['sale_currency'] as String;
      final e = lay.putIfAbsent(cur, () => OpenLayby(cur));
      e.count++;
      e.valueMinor += _i(l['total_minor']);
      e.paidMinor += await _laybyPaid(l['id'] as String, cur);
    }
    final count = sales.length;
    return SalesSummary(
      baseCurrency: base, byCurrency: totals, sales: count, returns: rets.length, revenueMinor: revenue, taxMinor: tax, costMinor: cost,
      profitMinor: revenue - tax - cost, linesWithoutCost: noCost, averageSaleMinor: count > 0 ? divRound(revenue, count) : 0, openLayby: lay.values.toList(),
    );
  }

  /// Sales per local day in the base currency, oldest first, with empty days included.
  Future<List<DayRow>> dailySales(DateRange r, int offsetMin, [ReportFilter f = const ReportFilter()]) async {
    final base = await baseCurrency();
    final map = <String, DayRow>{};
    DayRow get(String d) => map.putIfAbsent(d, () => DayRow(d));
    for (var t = r.from; t < r.to; t += _day) {
      get(dayOf(t, offsetMin));
    }
    for (final s in await _eligible(r, f)) {
      final d = get(dayOf(_i(s['eff_at']), offsetMin));
      d.sales++;
      d.revenueMinor += await _toBase(_i(s['total_minor']), s['sale_currency'] as String, base, s);
    }
    for (final rt in await _returnsIn(r, f)) {
      get(dayOf(_i(rt['created_at']), offsetMin)).returnsMinor += await _toBase(_i(rt['refund_minor']), rt['sale_currency'] as String, base, rt);
    }
    final out = map.values.toList()..sort((a, b) => a.day.compareTo(b.day));
    for (final d in out) {
      d.netMinor = d.revenueMinor - d.returnsMinor;
    }
    return out;
  }

  /// by: 'qty', 'revenue' or 'profit'.
  Future<List<ProductRow>> topProducts(DateRange r, {String by = 'revenue', int limit = 20, ReportFilter filter = const ReportFilter()}) async {
    final base = await baseCurrency();
    final m = <String, ProductRow>{};
    ProductRow slot(String? id, String name) => m.putIfAbsent(id ?? 'name:$name', () => ProductRow(id, name));
    for (final s in await _eligible(r, filter)) {
      final cur = s['sale_currency'] as String;
      for (final l in await db.query('select * from sale_lines where sale_id = ?', [s['id']])) {
        final p = slot(l['product_id'] as String?, (l['description'] as String?) ?? '');
        p.qtyMilli += _i(l['qty_milli']);
        p.revenueMinor += await _toBase(_i(l['line_total_minor']), cur, base, s);
        p._tax += await _toBase(_i(l['tax_minor'] ?? 0), cur, base, s);
        if (l['unit_cost_minor'] != null) p.costMinor += divRound(_i(l['unit_cost_minor']) * _i(l['qty_milli']), 1000);
      }
    }
    for (final rt in await _returnsIn(r, filter)) {
      final cur = rt['sale_currency'] as String;
      for (final rl in await db.query(
          'select rl.qty_milli, rl.restock, rl.amount_minor, sl.product_id, sl.description, sl.tax_minor, sl.line_total_minor, sl.unit_cost_minor from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ?',
          [rt['id']])) {
        final p = slot(rl['product_id'] as String?, (rl['description'] as String?) ?? '');
        p.qtyMilli -= _i(rl['qty_milli']);
        p.revenueMinor -= await _toBase(_i(rl['amount_minor']), cur, base, rt);
        if (_i(rl['line_total_minor']) > 0) p._tax -= await _toBase(divRound(_i(rl['tax_minor'] ?? 0) * _i(rl['amount_minor']), _i(rl['line_total_minor'])), cur, base, rt);
        if (rl['restock'] == 1 && rl['unit_cost_minor'] != null) p.costMinor -= divRound(_i(rl['unit_cost_minor']) * _i(rl['qty_milli']), 1000);
      }
    }
    final rows = m.values.toList();
    for (final p in rows) {
      p.profitMinor = p.revenueMinor - p._tax - p.costMinor;
    }
    rows.sort((a, b) {
      final c = by == 'qty' ? b.qtyMilli.compareTo(a.qtyMilli) : by == 'profit' ? b.profitMinor.compareTo(a.profitMinor) : b.revenueMinor.compareTo(a.revenueMinor);
      return c != 0 ? c : a.name.compareTo(b.name);
    });
    return rows.where((p) => p.qtyMilli != 0 || p.revenueMinor != 0).take(limit).toList();
  }

  /// Money in and out by payment method, by the day it moved: sale payments (less change), account and layby payments, refunds.
  Future<List<TakingRow>> takings(DateRange r, [ReportFilter f = const ReportFilter()]) async {
    final m = <String, TakingRow>{};
    final names = {for (final x in await db.query('select code, name from payment_methods')) x['code'] as String: x['name'] as String};
    TakingRow slot(String code, String cur) => m.putIfAbsent('$code|$cur', () => TakingRow(names[code] ?? code, cur));
    final br = f.branchId != null ? 'and s.branch_id = ?' : '';
    final us = f.userId != null ? 'and s.user_id = ?' : '';
    for (final p in await db.query('select sp.method_code, sp.currency, sp.amount_minor, sp.is_change from sale_payments sp join sales s on s.id = sp.sale_id where sp.created_at >= ? and sp.created_at < ? $br $us', [r.from, r.to, ..._ids(f)])) {
      final t = slot(p['method_code'] as String, p['currency'] as String);
      if (p['is_change'] == 1) {
        t.paidBackMinor += _i(p['amount_minor']);
      } else {
        t.receivedMinor += _i(p['amount_minor']);
      }
    }
    for (final p in await db.query('select ap.method_code, ap.currency, ap.amount_minor from account_payments ap where ap.created_at >= ? and ap.created_at < ? ${f.userId != null ? 'and ap.user_id = ?' : ''}', [r.from, r.to, if (f.userId != null) f.userId])) {
      slot(p['method_code'] as String, p['currency'] as String).receivedMinor += _i(p['amount_minor']);
    }
    for (final p in await db.query('select rp.method_code, rp.currency, rp.amount_minor from return_payouts rp join sale_returns rt on rt.id = rp.return_id join sales s on s.id = rt.original_sale_id where rt.created_at >= ? and rt.created_at < ? $br $us', [r.from, r.to, ..._ids(f)])) {
      slot(p['method_code'] as String, p['currency'] as String).paidBackMinor += _i(p['amount_minor']);
    }
    final out = m.values.toList();
    for (final t in out) {
      t.netMinor = t.receivedMinor - t.paidBackMinor;
    }
    out.sort((a, b) => a.method != b.method ? a.method.compareTo(b.method) : a.currency.compareTo(b.currency));
    return out;
  }

  Future<StockValue> stockValue({String? branchId, int top = 50}) async {
    final rows = await db.query(
        "select p.id, p.name, p.cost_minor, coalesce(sum(l.qty_milli), 0) as qty from products p left join stock_levels l on l.product_id = p.id ${branchId != null ? 'and l.branch_id = ?' : ''} where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.kind <> 'variant_parent' group by p.id order by p.name",
        [if (branchId != null) branchId]);
    var total = 0, noCost = 0, neg = 0, n = 0;
    final out = <StockLine>[];
    for (final r in rows) {
      final qty = _i(r['qty']);
      final cost = r['cost_minor'] == null ? null : _i(r['cost_minor']);
      final value = cost != null && qty > 0 ? divRound(cost * qty, 1000) : 0;
      if (qty > 0) {
        n++;
        total += value;
        if (cost == null) noCost++;
      }
      if (qty < 0) neg++;
      out.add(StockLine(productId: r['id'] as String, name: r['name'] as String, qtyMilli: qty, costMinor: cost, valueMinor: value));
    }
    out.sort((a, b) => b.valueMinor.compareTo(a.valueMinor));
    return StockValue(baseCurrency: await baseCurrency(), totalMinor: total, products: n, withoutCost: noCost, negative: neg, rows: out.take(top).toList());
  }

  Future<List<OutOfStock>> outOfStock({String? branchId}) async => [
        for (final r in await db.query(
            "select p.id as product_id, p.name, coalesce(sum(l.qty_milli), 0) as qty_milli from products p left join stock_levels l on l.product_id = p.id ${branchId != null ? 'and l.branch_id = ?' : ''} where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.kind not in ('variant_parent', 'bundle') group by p.id having qty_milli <= 0 order by p.name",
            [if (branchId != null) branchId]))
          OutOfStock(r['product_id'] as String, r['name'] as String, _i(r['qty_milli'])),
      ];

  /// Batches with stock that expire on or before [today] + [days]. [today] is a local date, 'YYYY-MM-DD'.
  Future<List<ExpiringBatch>> expiringBatches(String today, int days) async {
    final limit = DateTime.parse('${today}T00:00:00Z').add(Duration(days: days)).toIso8601String().substring(0, 10);
    return [
      for (final r in await db.query(
          'select b.product_id, p.name, b.batch_code, b.expiry_date, sum(l.qty_milli) as qty_milli from stock_batches b join products p on p.id = b.product_id join stock_levels l on l.batch_key = b.id and l.product_id = b.product_id where b.deleted_at is null and b.expiry_date is not null and b.expiry_date <= ? group by b.id having qty_milli > 0 order by b.expiry_date, p.name',
          [limit]))
        ExpiringBatch(
          productId: r['product_id'] as String, name: r['name'] as String, batchCode: r['batch_code'] as String?, expiryDate: r['expiry_date'] as String,
          qtyMilli: _i(r['qty_milli']), expired: (r['expiry_date'] as String).compareTo(today) < 0,
        ),
    ];
  }

  Future<Receivables> receivables({int top = 50}) async {
    final rows = await db.query(
        'select c.id, c.name, c.phone, l.currency, sum(l.amount_minor) as owed from customer_ledger l join customers c on c.id = l.customer_id where c.deleted_at is null group by c.id, l.currency having owed > 0 order by owed desc');
    final per = <String, OwedTotal>{};
    for (final r in rows) {
      final e = per.putIfAbsent(r['currency'] as String, () => OwedTotal(r['currency'] as String));
      e.owedMinor += _i(r['owed']);
      e.customers++;
    }
    final list = per.values.toList()..sort((a, b) => a.currency.compareTo(b.currency));
    return Receivables(list, [
      for (final r in rows.take(top)) Debtor(customerId: r['id'] as String, name: r['name'] as String, phone: r['phone'] as String?, currency: r['currency'] as String, owedMinor: _i(r['owed'])),
    ]);
  }

  Future<List<CashUpRow>> cashUps(DateRange r) async {
    final out = <CashUpRow>[];
    for (final s in await db.query("select s.*, u.name as user_name from shifts s left join users u on u.id = s.user_id where s.status = 'closed' and s.closed_at >= ? and s.closed_at < ? order by s.closed_at desc", [r.from, r.to])) {
      out.add(CashUpRow(
        shiftId: s['id'] as String, user: s['user_name'] as String?, openedAt: _i(s['opened_at']), closedAt: _i(s['closed_at']),
        currencies: [
          for (final c in await db.query('select currency, expected_minor, counted_minor, difference_minor from shift_cash where shift_id = ? order by currency', [s['id']]))
            CashUpCurrency(c['currency'] as String, _i(c['expected_minor'] ?? 0), _i(c['counted_minor'] ?? 0), _i(c['difference_minor'] ?? 0)),
        ],
      ));
    }
    return out;
  }
}
