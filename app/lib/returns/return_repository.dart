/// Returns, refunds and voids. Port of tools/src/returns.ts (read the notes at the top of that file).
library;

import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/money.dart';
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

class ReturnItem {
  const ReturnItem({required this.saleLineId, required this.qtyMilli, this.restock = true});
  final String saleLineId;
  final int qtyMilli;
  final bool restock;
}

class Payout {
  const Payout({required this.methodCode, required this.currency, required this.amountMinor, this.reference});
  final String methodCode, currency;
  final int amountMinor;
  final String? reference;
  @override
  bool operator ==(Object o) => o is Payout && o.methodCode == methodCode && o.currency == currency && o.amountMinor == amountMinor && o.reference == reference;
  @override
  int get hashCode => Object.hash(methodCode, currency, amountMinor, reference);
}

class ReturnableLine {
  const ReturnableLine({required this.saleLineId, required this.description, required this.qtyMilli, required this.returnedMilli, required this.remainingMilli, required this.lineTotalMinor, required this.remainingValueMinor});
  final String saleLineId, description;
  final int qtyMilli, returnedMilli, remainingMilli, lineTotalMinor, remainingValueMinor;
}

class ReturnPreview {
  const ReturnPreview({required this.currency, required this.valueMinor, required this.creditPartMinor, required this.payoutDueMinor, required this.layby});
  final String currency;
  final int valueMinor, creditPartMinor, payoutDueMinor;
  final bool layby;
}

class ReturnResult {
  const ReturnResult({required this.returnId, required this.receiptNo, required this.kind, required this.valueMinor, required this.creditPartMinor, required this.payoutMinor, required this.opensDrawer});
  final String returnId, receiptNo, kind;
  final int valueMinor, creditPartMinor, payoutMinor;
  final bool opensDrawer;
}

class FoundSale {
  const FoundSale({required this.saleId, required this.receiptNo, required this.totalMinor, required this.currency, required this.status, required this.voided, required this.at});
  final String saleId, receiptNo, currency, status;
  final int totalMinor, at;
  final bool voided;
}

class PastReturn {
  const PastReturn({required this.returnId, required this.receiptNo, required this.kind, required this.valueMinor, this.reason, required this.at});
  final String returnId, receiptNo, kind;
  final int valueMinor, at;
  final String? reason;
}

class _Plan {
  _Plan(this.sale, this.preview, this.items);
  final _Row sale;
  final ReturnPreview preview;
  final List<({String lineId, int qty, int amount})> items;
}

class ReturnRepository {
  ReturnRepository({required this.db, required this.shopId, required this.deviceId, required this.receiptPrefix, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId, receiptPrefix;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();
  SetupError _err(String code, String msg) => SetupError(code, msg);

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<bool> _has(SqlDb tx, String? uid, String permission) async {
    if (uid == null) return false;
    final r = await _get(tx, 'select r.permissions from users u join roles r on r.id = u.role_id where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null', [uid]);
    if (r == null) return false;
    try {
      final list = jsonDecode(r['permissions'] as String);
      return list is List && list.contains(permission);
    } on FormatException {
      return false;
    }
  }

  /// Whether the signed-in user may do this without a manager's approval (screens use this to decide to ask for a PIN).
  Future<bool> canWithoutApproval(String permission) async => userId == null || await _has(db, userId, permission);

  Future<String> _add(SqlDb tx, String table, _Row row, int now) async {
    final o = <String, Object?>{'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId, ...row};
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  Future<bool> _isVoided(SqlDb tx, String saleId) async => await _get(tx, 'select 1 as x from sale_voids where sale_id = ?', [saleId]) != null;

  Future<List<ReturnableLine>> _lineState(SqlDb tx, String saleId) async {
    final out = <ReturnableLine>[];
    for (final l in await tx.query('select * from sale_lines where sale_id = ? order by created_at, rowid', [saleId])) {
      final r = (await _get(tx, 'select coalesce(sum(qty_milli), 0) as q, coalesce(sum(amount_minor), 0) as a from sale_return_lines where sale_line_id = ?', [l['id']]))!;
      out.add(ReturnableLine(
        saleLineId: l['id'] as String, description: (l['description'] as String?) ?? '', qtyMilli: _i(l['qty_milli']), returnedMilli: _i(r['q']),
        remainingMilli: _i(l['qty_milli']) - _i(r['q']), lineTotalMinor: _i(l['line_total_minor']), remainingValueMinor: _i(l['line_total_minor']) - _i(r['a']),
      ));
    }
    return out;
  }

  Future<List<ReturnableLine>> returnableLines(String saleId, [SqlDb? tx]) async {
    final d = tx ?? db;
    final s = await _lineState(d, saleId);
    if (!await _isVoided(d, saleId)) return s;
    return [for (final l in s) ReturnableLine(saleLineId: l.saleLineId, description: l.description, qtyMilli: l.qtyMilli, returnedMilli: l.returnedMilli, remainingMilli: 0, lineTotalMinor: l.lineTotalMinor, remainingValueMinor: 0)];
  }

  Future<int> _rate(SqlDb tx, String from, String to, int now) async {
    if (from == to) return 1000000;
    const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
    final d = await _get(tx, q, [from, to, now]);
    if (d != null) return _i(d['rate_micro']);
    final i = await _get(tx, q, [to, from, now]);
    if (i == null) throw _err('no_rate', 'No exchange rate between $from and $to.');
    return invertRate(_i(i['rate_micro']));
  }

  Future<_Row> _currency(SqlDb tx, String code) async {
    final c = await _get(tx, 'select * from currencies where code = ? and deleted_at is null', [code]);
    if (c == null) throw _err('unknown_currency', 'Currency $code is not set up.');
    return c;
  }

  /// What a layby customer has paid so far, in the sale currency (deposit, instalments, minus change).
  Future<int> _laybyPaid(SqlDb tx, String saleId, String saleCurrency) async {
    var paid = 0;
    final cur = await _currency(tx, saleCurrency);
    for (final p in await tx.query('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?', [saleId])) {
      final c = p['currency'] as String;
      final v = c == saleCurrency ? _i(p['amount_minor']) : convertMinor(_i(p['amount_minor']), _i(p['rate_to_sale_micro']), _i((await _currency(tx, c))['minor_units']), _i(cur['minor_units']));
      paid += p['is_change'] == 1 ? -v : v;
    }
    final inst = await _get(tx, 'select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?', [saleId]);
    return paid + _i(inst!['s']);
  }

  Future<_Plan> _plan(SqlDb tx, String saleId, List<ReturnItem> items, String kind, int now) async {
    final sale = await _get(tx, 'select * from sales where id = ?', [saleId]);
    if (sale == null) throw _err('unknown_sale', 'That sale was not found.');
    if (await _isVoided(tx, saleId)) throw _err('already_voided', 'That sale was already voided.');
    final layby = sale['status'] == 'layby';
    final collected = layby && await _get(tx, "select 1 as x from layby_payments where sale_id = ? and payment_id is null and due_note = 'collected'", [saleId]) != null;
    final openLayby = layby && !collected;
    if (openLayby && kind != 'void') throw _err('layby_void_only', 'A layby that has not been collected can only be cancelled (voided).');
    if (kind == 'void' && collected) throw _err('collected', 'The goods were already handed over. Use a return instead.');
    final state = {for (final l in await _lineState(tx, saleId)) l.saleLineId: l};
    if (items.isEmpty) throw _err('nothing_to_return', 'Choose what is coming back.');
    final seen = <String>{};
    final out = <({String lineId, int qty, int amount})>[];
    var value = 0;
    for (final it in items) {
      final l = state[it.saleLineId];
      if (l == null) throw _err('unknown_line', 'That item is not on this sale.');
      if (!seen.add(it.saleLineId)) throw _err('duplicate_line', 'An item is listed twice.');
      if (it.qtyMilli <= 0) throw _err('bad_quantity', 'Quantity must be more than zero.');
      if (it.qtyMilli > l.remainingMilli) throw _err('too_many', 'Only ${l.remainingMilli / 1000} of ${l.description} can still be returned.');
      final amount = it.qtyMilli == l.remainingMilli ? l.remainingValueMinor : divRound(l.lineTotalMinor * it.qtyMilli, l.qtyMilli);
      out.add((lineId: it.saleLineId, qty: it.qtyMilli, amount: amount));
      value += amount;
    }
    if (kind == 'void' && state.values.any((l) => l.remainingMilli > 0 && !seen.contains(l.saleLineId))) throw _err('void_all', 'A void takes back everything on the sale.');

    final cur = sale['sale_currency'] as String;
    var credit = 0;
    if (!openLayby && sale['customer_id'] != null) {
      final remain = _i((await _get(
          tx,
          "select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ? and type in ('credit_sale', 'refund_credit') and ((ref_type = 'sale' and ref_id = ?) or (ref_type = 'return' and ref_id in (select id from sale_returns where original_sale_id = ?)))",
          [sale['customer_id'], cur, saleId, saleId]))!['s']);
      final owedNow = _i((await _get(tx, 'select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ?', [sale['customer_id'], cur]))!['s']);
      credit = [value, remain, owedNow].reduce((a, b) => a < b ? a : b);
      if (credit < 0) credit = 0;
    }
    var due = value - credit;
    if (openLayby) {
      final paid = await _laybyPaid(tx, saleId, cur);
      due = value < paid ? value : paid;
    }
    return _Plan(sale, ReturnPreview(currency: cur, valueMinor: value, creditPartMinor: credit, payoutDueMinor: due, layby: openLayby), out);
  }

  /// What a return would come to, without saving anything.
  Future<ReturnPreview> previewReturn(String saleId, List<ReturnItem> items, {String kind = 'return'}) async => (await _plan(db, saleId, items, kind, _clock())).preview;

  /// A starting point for the payout: the one non-cash method the sale was paid with, otherwise cash in the sale currency.
  Future<List<Payout>> suggestPayout(String saleId, int dueMinor) async {
    if (dueMinor <= 0) return [];
    final sale = await _get(db, 'select sale_currency from sales where id = ?', [saleId]);
    if (sale == null) return [];
    final methods = await db.query('select distinct sp.method_code, pm.kind from sale_payments sp left join payment_methods pm on pm.code = sp.method_code where sp.sale_id = ? and sp.is_change = 0', [saleId]);
    final non = methods.where((m) => m['kind'] != 'cash').toList();
    final code = methods.length == 1 && non.length == 1 ? non.first['method_code'] as String : 'cash';
    return [Payout(methodCode: code, currency: sale['sale_currency'] as String, amountMinor: dueMinor)];
  }

  Future<List<({Payout p, int rate, bool drawer})>> _checkPayouts(SqlDb tx, String saleCur, int due, List<Payout> payouts, int now) async {
    if (due <= 0) {
      if (payouts.isNotEmpty) throw _err('nothing_to_pay', 'Nothing is to be paid back for this return.');
      return [];
    }
    if (payouts.isEmpty) throw _err('payout_needed', 'Say how the money is paid back.');
    var total = 0;
    var tol = 1;
    final rows = <({Payout p, int rate, bool drawer})>[];
    final saleRow = await _currency(tx, saleCur);
    for (final p in payouts) {
      if (p.amountMinor <= 0) throw _err('bad_payment', 'A payment must be more than zero.');
      final m = await _get(tx, 'select * from payment_methods where code = ? and deleted_at is null', [p.methodCode]);
      if (m == null) throw _err('unknown_method', 'Payment method ${p.methodCode} is not set up.');
      if (m['requires_reference'] == 1 && (p.reference ?? '').trim().isEmpty) throw _err('reference_needed', '${m['name']} needs the confirmation reference.');
      final c = await _currency(tx, p.currency);
      final r = await _rate(tx, p.currency, saleCur, now);
      total += p.currency == saleCur ? p.amountMinor : convertMinor(p.amountMinor, r, _i(c['minor_units']), _i(saleRow['minor_units']));
      final inc = c['rounding_increment_minor'] == null ? 0 : _i(c['rounding_increment_minor']);
      final step = inc < 1 ? 1 : inc;
      final stepInSale = p.currency == saleCur ? step : convertMinor(step, r, _i(c['minor_units']), _i(saleRow['minor_units']));
      if (stepInSale > tol) tol = stepInSale;
      rows.add((p: p, rate: r, drawer: m['opens_drawer'] == 1));
    }
    if ((total - due).abs() >= tol) throw _err('payout_mismatch', 'The money paid back does not match what is due.');
    return rows;
  }

  Future<ReturnResult> _process({required String saleId, required List<ReturnItem> items, required String reason, required List<Payout> payouts, String? approvedBy, required String kind}) async {
    final now = _clock();
    final need = kind == 'void' ? 'sale.void' : 'sale.refund';
    return db.transaction((tx) async {
      if (userId != null && !await _has(tx, userId, need) && !(approvedBy != null && await _has(tx, approvedBy, need))) {
        throw _err('forbidden', kind == 'void' ? 'Voiding a sale needs a manager\'s approval.' : 'A refund needs a manager\'s approval.');
      }
      final why = reason.trim();
      if (why.isEmpty) throw _err('reason_needed', 'Give a reason.');
      final p = await _plan(tx, saleId, items, kind, now);
      final rows = await _checkPayouts(tx, p.preview.currency, p.preview.payoutDueMinor, payouts, now);
      final shift = userId == null ? null : (await _get(tx, "select id from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1", [userId]))?['id'];
      await tx.exec("insert into receipt_counters (kind, last_no) values ('return', 1) on conflict (kind) do update set last_no = last_no + 1");
      final no = _i((await _get(tx, "select last_no from receipt_counters where kind = 'return'"))!['last_no']);
      final receiptNo = '$receiptPrefix-R${no.toString().padLeft(6, '0')}';
      final returnId = await _add(tx, 'sale_returns', {
        'original_sale_id': saleId, 'receipt_no': receiptNo, 'kind': kind, 'shift_id': shift, 'reason': why, 'refund_method': null,
        'refund_currency': p.preview.currency, 'refund_minor': p.preview.valueMinor, 'approved_by': approvedBy,
      }, now);
      final restockOf = {for (final i in items) i.saleLineId: i.restock};
      for (final it in p.items) {
        await _add(tx, 'sale_return_lines', {'return_id': returnId, 'sale_line_id': it.lineId, 'qty_milli': it.qty, 'restock': restockOf[it.lineId]! ? 1 : 0, 'amount_minor': it.amount}, now);
        if (restockOf[it.lineId]!) await _restock(tx, p.sale, it.lineId, it.qty, kind, now);
      }
      if (p.preview.creditPartMinor > 0) {
        await _add(tx, 'customer_ledger', {'customer_id': p.sale['customer_id'], 'type': 'refund_credit', 'currency': p.preview.currency, 'amount_minor': -p.preview.creditPartMinor, 'ref_type': 'return', 'ref_id': returnId}, now);
      }
      for (final r in rows) {
        await _add(tx, 'return_payouts', {
          'return_id': returnId, 'method_code': r.p.methodCode, 'currency': r.p.currency, 'amount_minor': r.p.amountMinor, 'rate_to_sale_micro': r.rate,
          'reference': (r.p.reference ?? '').trim().isEmpty ? null : r.p.reference!.trim(),
        }, now);
      }
      if (kind == 'void') await _add(tx, 'sale_voids', {'sale_id': saleId, 'reason': why, 'approved_by': approvedBy, 'voided_at': now}, now);
      await _add(tx, 'audit_log', {
        'user_id': userId, 'action': kind == 'void' ? 'sale_void' : 'sale_return', 'table_name': 'sales', 'row_id': saleId,
        'after': jsonEncode({'return_id': returnId, 'receipt_no': receiptNo, 'value_minor': p.preview.valueMinor, 'reason': why}),
      }, now);
      if (await _get(tx, "select 1 as x from settings where scope = 'shop' and key = 'fiscal_enabled' and value = '1' and deleted_at is null") != null) {
        await _add(tx, 'fiscal_documents', {
          'sale_id': saleId, 'kind': 'credit_note', 'payload': jsonEncode({'return_id': returnId, 'receipt_no': receiptNo}), 'status': 'queued', 'attempts': 0, 'updated_at': now, 'version': 1,
        }, now);
      }
      return ReturnResult(
        returnId: returnId, receiptNo: receiptNo, kind: kind, valueMinor: p.preview.valueMinor, creditPartMinor: p.preview.creditPartMinor,
        payoutMinor: p.preview.payoutDueMinor, opensDrawer: rows.any((r) => r.drawer),
      );
    });
  }

  /// Puts goods back on the shelf, in the batches and at the cost they left it. Bundles put their parts back.
  Future<void> _restock(SqlDb tx, _Row sale, String lineId, int qty, String kind, int now) async {
    final line = (await _get(tx, 'select * from sale_lines where id = ?', [lineId]))!;
    final prod = await _get(tx, 'select * from products where id = ?', [line['product_id']]);
    if (prod == null) return;
    final parts = <({String productId, int qty})>[];
    if (prod['kind'] == 'bundle') {
      for (final bi in await tx.query('select component_product_id, qty_milli from bundle_items where bundle_product_id = ? and deleted_at is null', [prod['id']])) {
        parts.add((productId: bi['component_product_id'] as String, qty: _round(_i(bi['qty_milli']) * qty / 1000)));
      }
    } else {
      parts.add((productId: prod['id'] as String, qty: qty));
    }
    for (final part in parts) {
      final tracked = await _get(tx, 'select track_stock from products where id = ?', [part.productId]);
      if (tracked == null || tracked['track_stock'] == 0) continue;
      final taken = await tx.query("select batch_id, -qty_milli as q, unit_cost_minor, cost_currency from stock_movements where ref_type = 'sale' and ref_id = ? and product_id = ? and qty_milli < 0 order by rowid", [sale['id'], part.productId]);
      var back = _i((await _get(tx, "select coalesce(sum(qty_milli), 0) as q from stock_movements where ref_type = 'sale' and ref_id = ? and product_id = ? and qty_milli > 0", [sale['id'], part.productId]))!['q']);
      var left = part.qty;
      for (final t in taken) {
        var avail = _i(t['q']);
        final skip = avail < back ? avail : back;
        avail -= skip;
        back -= skip;
        final give = avail < left ? avail : left;
        if (give <= 0) continue;
        await _add(tx, 'stock_movements', {
          'branch_id': sale['branch_id'], 'product_id': part.productId, 'batch_id': t['batch_id'], 'type': kind == 'void' ? 'void' : 'sale_return', 'qty_milli': give,
          'unit_cost_minor': t['unit_cost_minor'], 'cost_currency': t['cost_currency'], 'ref_type': 'sale', 'ref_id': sale['id'],
        }, now);
        left -= give;
      }
      if (left > 0) {
        await _add(tx, 'stock_movements', {
          'branch_id': sale['branch_id'], 'product_id': part.productId, 'batch_id': null, 'type': kind == 'void' ? 'void' : 'sale_return', 'qty_milli': left,
          'unit_cost_minor': null, 'cost_currency': null, 'ref_type': 'sale', 'ref_id': sale['id'],
        }, now);
      }
    }
  }

  int _round(double v) => v.round();

  /// Takes back some items from a completed sale. A manager's approval is needed for cashiers.
  Future<ReturnResult> processReturn({required String saleId, required List<ReturnItem> items, required String reason, required List<Payout> payouts, String? approvedBy}) =>
      _process(saleId: saleId, items: items, reason: reason, payouts: payouts, approvedBy: approvedBy, kind: 'return');

  /// Cancels a sale or an uncollected layby completely.
  Future<ReturnResult> voidSale({required String saleId, required String reason, required List<Payout> payouts, String? approvedBy}) async {
    final items = [for (final l in await returnableLines(saleId)) if (l.remainingMilli > 0) ReturnItem(saleLineId: l.saleLineId, qtyMilli: l.remainingMilli)];
    return _process(saleId: saleId, items: items, reason: reason, payouts: payouts, approvedBy: approvedBy, kind: 'void');
  }

  Future<List<PastReturn>> returnsForSale(String saleId) async => [
        for (final r in await db.query('select id, receipt_no, kind, refund_minor, reason, created_at from sale_returns where original_sale_id = ? order by created_at, rowid', [saleId]))
          PastReturn(returnId: r['id'] as String, receiptNo: r['receipt_no'] as String, kind: r['kind'] as String, valueMinor: _i(r['refund_minor']), reason: r['reason'] as String?, at: _i(r['created_at'])),
      ];

  Future<FoundSale?> findSaleByReceipt(String receiptNo) async {
    final s = await _get(db, 'select * from sales where receipt_no = ? collate nocase', [receiptNo.trim()]);
    if (s == null) return null;
    return FoundSale(
      saleId: s['id'] as String, receiptNo: s['receipt_no'] as String, totalMinor: _i(s['total_minor']), currency: s['sale_currency'] as String,
      status: s['status'] as String, voided: await _isVoided(db, s['id'] as String), at: _i(s['completed_at']),
    );
  }

  Future<List<({String code, String name, bool needsReference})>> paymentMethods() async => [
        for (final r in await db.query('select code, name, requires_reference from payment_methods where deleted_at is null and is_active = 1 order by rowid'))
          (code: r['code'] as String, name: r['name'] as String, needsReference: r['requires_reference'] == 1),
      ];
}
