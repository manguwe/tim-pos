import 'dart:convert';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import 'money.dart';

/// The selling engine. Port of tools/src/selling.ts, which is tested against the real database schema.
/// If you change one, change the other. Conventions are described at the top of that file.

class CartLine {
  const CartLine({required this.productId, required this.qtyMilli, this.unitPriceMinor, this.discountMinor = 0});
  final String productId;
  final int qtyMilli;

  /// Set only when someone with the price.edit permission typed a different price. It is written to the audit log.
  final int? unitPriceMinor;
  final int discountMinor;
}

class CartPayment {
  const CartPayment({required this.methodCode, required this.currency, required this.amountMinor, this.reference});
  final String methodCode;
  final String currency;
  final int amountMinor;
  final String? reference;
}

class Cart {
  const Cart({
    required this.branchId,
    required this.saleCurrency,
    required this.lines,
    required this.payments,
    this.userId,
    this.shiftId,
    this.customerId,
    this.priceTierId,
    this.onCredit = false,
    this.layby = false,
    this.changeCurrency,
    this.note,
    this.approvedBy,
  });
  final String branchId;
  final String? userId;
  final String? shiftId;
  final String? customerId;
  final String? priceTierId;
  final String saleCurrency;
  final List<CartLine> lines;
  final List<CartPayment> payments;
  final bool onCredit;

  /// Hold the goods for the customer and take what is paid now as a deposit. The rest is paid later (customer_repository.dart).
  final bool layby;
  final String? changeCurrency;
  final String? note;

  /// A manager who approved the discounts or typed prices in this cart by PIN. Their permissions count instead of the cashier's.
  final String? approvedBy;
}

class SaleContext {
  const SaleContext({required this.shopId, required this.deviceId, required this.receiptPrefix});
  final String shopId;
  final String deviceId;
  final String receiptPrefix;
}

class Change {
  const Change(this.currency, this.amountMinor);
  final String currency;
  final int amountMinor;
}

class SaleResult {
  const SaleResult({
    required this.saleId,
    required this.receiptNo,
    required this.status,
    required this.subtotalMinor,
    required this.discountMinor,
    required this.taxMinor,
    required this.totalMinor,
    required this.paidMinor,
    required this.creditMinor,
    this.laybyBalanceMinor = 0,
    required this.change,
    required this.opensDrawer,
  });
  final String saleId, receiptNo, status;
  final int subtotalMinor, discountMinor, taxMinor, totalMinor, paidMinor, creditMinor;
  final int laybyBalanceMinor;
  final Change? change;
  final bool opensDrawer;
}

/// A refusal the cashier can read: [message] is for the screen, [code] for logic, [detail] for numbers.
class SaleError implements Exception {
  SaleError(this.code, this.message, [this.detail = const {}]);
  final String code;
  final String message;
  final Map<String, Object?> detail;
  @override
  String toString() => 'SaleError($code): $message';
}

typedef Row = Map<String, Object?>;

class SellingEngine {
  SellingEngine({required this.db, required this.context, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final SaleContext context;
  final int Function() _clock;
  final String Function() _newId;

  /// Saves the whole sale in one transaction, or nothing at all.
  Future<SaleResult> sell(Cart cart) async {
    final now = _clock();
    try {
      return await db.transaction((tx) => _sell(tx, cart, now));
    } on MoneyError catch (e) {
      throw SaleError(e.code, e.message);
    }
  }

  Future<Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<String> _insert(SqlDb tx, String table, Row row, int now, Cart cart) async {
    final o = <String, Object?>{
      'id': _newId(),
      'shop_id': context.shopId,
      'created_at': now,
      'created_by': cart.userId,
      'device_id': context.deviceId,
      ...row,
    };
    final keys = o.keys.toList();
    await tx.exec(
      'insert into "$table" (${keys.map((k) => '"$k"').join(', ')}) values (${List.filled(keys.length, '?').join(', ')})',
      keys.map((k) => o[k]).toList(),
    );
    return o['id']! as String;
  }

  int _i(Object? v) => (v as num).toInt();

  Future<bool> _can(SqlDb tx, String? userId, String permission) async {
    if (userId == null) return false;
    final r = await _get(
      tx,
      'select r.permissions from users u join roles r on r.id = u.role_id '
      'where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null',
      [userId],
    );
    if (r == null) return false;
    try {
      final list = jsonDecode(r['permissions'] as String);
      return list is List && list.contains(permission);
    } on FormatException {
      return false;
    }
  }

  Future<SaleResult> _sell(SqlDb tx, Cart cart, int now) async {
    if (cart.lines.isEmpty) throw SaleError('empty_cart', 'Add at least one item.');
    // A signed-in user must be allowed to sell; discounts and typed prices need their own switch, or a manager's approval.
    final who = cart.userId;
    if (who != null) {
      Future<bool> can(String p) async => await _can(tx, who, p) || (cart.approvedBy != null && await _can(tx, cart.approvedBy, p));
      if (!await _can(tx, who, 'sale.create')) throw SaleError('forbidden', 'You are not allowed to make sales.', {'permission': 'sale.create'});
      if (cart.lines.any((l) => l.discountMinor > 0) && !await can('sale.discount')) {
        throw SaleError('forbidden', "A discount needs a manager's approval.", {'permission': 'sale.discount'});
      }
      if (cart.lines.any((l) => l.unitPriceMinor != null) && !await can('price.edit')) {
        throw SaleError('forbidden', "Changing a price needs a manager's approval.", {'permission': 'price.edit'});
      }
    }
    final currencies = <String, Row>{};
    Future<Row> currency(String code) async {
      final cached = currencies[code];
      if (cached != null) return cached;
      final c = await _get(tx, 'select * from currencies where code = ? and deleted_at is null', [code]);
      if (c == null) throw SaleError('unknown_currency', 'Currency $code is not set up.');
      return currencies[code] = c;
    }

    await currency(cart.saleCurrency);
    final base = (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String?;
    if (base == null) throw SaleError('shop_not_set_up', 'The shop has no base currency yet.');
    if (cart.shiftId == null && (await _get(tx, "select value from settings where scope = 'shop' and key = 'require_shift' and deleted_at is null"))?['value'] == '1') {
      throw SaleError('shift_needed', 'Open a shift before selling.');
    }
    if (cart.shiftId != null) {
      final sh = await _get(tx, 'select status from shifts where id = ?', [cart.shiftId]);
      if (sh == null || sh['status'] != 'open') throw SaleError('shift_closed', 'Open a shift before selling.');
    }

    final ratesUsed = <String, int>{};
    const rateSql = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? '
        'order by effective_from desc, created_at desc limit 1';
    Future<int> rate(String from, String to) async {
      if (from == to) return 1000000;
      final d = await _get(tx, rateSql, [from, to, now]);
      int rv;
      if (d != null) {
        rv = _i(d['rate_micro']);
      } else {
        final inv = await _get(tx, rateSql, [to, from, now]);
        if (inv == null) throw SaleError('no_rate', 'No exchange rate between $from and $to.');
        rv = invertRate(_i(inv['rate_micro']));
      }
      ratesUsed['$from>$to'] = rv;
      return rv;
    }

    Future<int> convert(int amount, String from, String to) async {
      if (from == to) return amount;
      final f = await currency(from);
      final t = await currency(to);
      return convertMinor(amount, await rate(from, to), _i(f['minor_units']), _i(t['minor_units']));
    }

    final allowNegativeShop =
        (await _get(tx, "select value from settings where scope = 'shop' and key = 'allow_negative_stock' and deleted_at is null"))?['value'] == '1';
    Row? customer;
    if (cart.customerId != null) {
      customer = await _get(tx, 'select * from customers where id = ? and deleted_at is null', [cart.customerId]);
      if (customer == null) throw SaleError('unknown_customer', 'That customer was not found.');
    }
    final tierId = cart.priceTierId ??
        customer?['price_tier_id'] as String? ??
        (await _get(tx, 'select id from price_tiers where is_default = 1 and deleted_at is null'))?['id'] as String?;

    final saleId = _newId();
    var subtotal = 0, discountTotal = 0, taxTotal = 0, total = 0;

    for (final l in cart.lines) {
      if (l.qtyMilli <= 0) throw SaleError('bad_quantity', 'Quantity must be more than zero.');
      final p = await _get(tx, 'select * from products where id = ? and deleted_at is null', [l.productId]);
      if (p == null || p['is_active'] == 0) throw SaleError('unknown_product', 'That product cannot be sold.', {'product_id': l.productId});
      if (p['kind'] == 'variant_parent') throw SaleError('choose_variant', 'Choose a variant of ${p['name']}.', {'product_id': p['id']});

      int unit;
      if (l.unitPriceMinor != null) {
        if (l.unitPriceMinor! < 0) throw SaleError('bad_price', 'Price must be zero or more.');
        unit = l.unitPriceMinor!;
        await _insert(tx, 'audit_log', {
          'user_id': cart.userId,
          'action': 'price_override',
          'table_name': 'products',
          'row_id': p['id'],
          'after': jsonEncode({'unit_price_minor': unit, 'sale_id': saleId}),
        }, now, cart);
      } else {
        Future<int?> findPrice(String cur) async {
          final rows = await tx.query(
            'select price_minor, tier_id from product_prices where product_id = ? and currency = ? and effective_from <= ? and deleted_at is null '
            'order by effective_from desc, created_at desc',
            [p['id'], cur, now],
          );
          for (final r in rows) {
            if (r['tier_id'] == tierId) return _i(r['price_minor']);
          }
          for (final r in rows) {
            if (r['tier_id'] == null) return _i(r['price_minor']);
          }
          return rows.isEmpty ? null : _i(rows.first['price_minor']);
        }

        final direct = await findPrice(cart.saleCurrency);
        if (direct != null) {
          unit = direct;
        } else {
          final inBase = cart.saleCurrency == base ? null : await findPrice(base);
          if (inBase == null) throw SaleError('no_price', '${p['name']} has no price in ${cart.saleCurrency}.', {'product_id': p['id']});
          unit = await convert(inBase, base, cart.saleCurrency);
        }
        // Quantity price: from the break quantity upwards every unit is at the break price (the highest break reached wins).
        Future<int?> findBreak(String cur) async {
          final rows = await tx.query(
            'select price_minor, tier_id from price_breaks where product_id = ? and currency = ? and min_qty_milli <= ? and deleted_at is null '
            'order by min_qty_milli desc, created_at desc',
            [p['id'], cur, l.qtyMilli],
          );
          for (final r in rows) {
            if (r['tier_id'] == tierId) return _i(r['price_minor']);
          }
          for (final r in rows) {
            if (r['tier_id'] == null) return _i(r['price_minor']);
          }
          return null;
        }

        final brk = await findBreak(cart.saleCurrency);
        if (brk != null) {
          unit = brk;
        } else if (cart.saleCurrency != base) {
          final inBase = await findBreak(base);
          if (inBase != null) unit = await convert(inBase, base, cart.saleCurrency);
        }
      }

      final discount = l.discountMinor;
      if (discount < 0) throw SaleError('bad_discount', 'Discount must be zero or more.');
      final gross = lineAmount(l.qtyMilli, unit);
      if (discount > gross) throw SaleError('discount_too_big', 'The discount is more than the price.', {'product_id': p['id']});
      final tc = p['tax_class_id'] == null ? null : await _get(tx, 'select * from tax_classes where id = ?', [p['tax_class_id']]);
      final t = taxSplit(gross - discount, tc == null ? 0 : _i(tc['rate_bp']), tc == null ? true : tc['is_inclusive'] == 1);

      subtotal += t.net;
      discountTotal += discount;
      taxTotal += t.tax;
      total += t.total;

      final movements = <Row>[];
      Future<void> take(Row prod, int qty) async {
        if (prod['track_stock'] != 1) return;
        final rows = await tx.query(
          'select l.batch_key, l.qty_milli from stock_levels l left join stock_batches b on b.id = l.batch_key '
          'where l.branch_id = ? and l.product_id = ? and l.qty_milli > 0 '
          'order by (b.expiry_date is null), b.expiry_date, l.batch_key',
          [cart.branchId, prod['id']],
        );
        var left = qty;
        for (final r in rows) {
          if (left == 0) break;
          final avail = _i(r['qty_milli']);
          final use = left < avail ? left : avail;
          movements.add({'product_id': prod['id'], 'batch_id': r['batch_key'] == '' ? null : r['batch_key'], 'qty_milli': -use, 'unit_cost_minor': prod['cost_minor']});
          left -= use;
        }
        if (left > 0) {
          if (prod['allow_negative_stock'] != 1 && !allowNegativeShop) {
            throw SaleError('insufficient_stock', 'Only ${_qtyText(qty - left)} of ${prod['name']} left.', {'product_id': prod['id'], 'available_milli': qty - left});
          }
          movements.add({'product_id': prod['id'], 'batch_id': null, 'qty_milli': -left, 'unit_cost_minor': prod['cost_minor']});
        }
      }

      if (p['kind'] == 'bundle') {
        final items = await tx.query('select component_product_id, qty_milli from bundle_items where bundle_product_id = ? and deleted_at is null', [p['id']]);
        for (final bi in items) {
          final comp = await _get(tx, 'select * from products where id = ? and deleted_at is null', [bi['component_product_id']]);
          if (comp != null) await take(comp, divRound(_i(bi['qty_milli']) * l.qtyMilli, 1000));
        }
      } else {
        await take(p, l.qtyMilli);
      }

      // Written now, so the next line for the same product sees the stock already taken.
      await _insert(tx, 'sale_lines', {
        'sale_id': saleId,
        'product_id': p['id'],
        'description': p['name'],
        'unit_id': p['base_unit_id'],
        'qty_milli': l.qtyMilli,
        'unit_price_minor': unit,
        'price_currency': cart.saleCurrency,
        'discount_minor': discount,
        'tax_rate_bp': tc == null ? 0 : _i(tc['rate_bp']),
        'tax_minor': t.tax,
        'line_total_minor': t.total,
        'unit_cost_minor': p['cost_minor'],
      }, now, cart);
      for (final m in movements) {
        await _insert(tx, 'stock_movements', {
          'branch_id': cart.branchId,
          'type': 'sale',
          'ref_type': 'sale',
          'ref_id': saleId,
          'cost_currency': base,
          ...m,
        }, now, cart);
      }
    }

    // ---- payments ----
    var paid = 0, cashPaid = 0;
    final payRows = <Row>[];
    var opensDrawer = false;
    for (final pay in cart.payments) {
      if (pay.amountMinor <= 0) throw SaleError('bad_payment', 'A payment must be more than zero.');
      final m = await _get(tx, 'select * from payment_methods where code = ? and deleted_at is null', [pay.methodCode]);
      final isCash = m != null ? m['kind'] == 'cash' : pay.methodCode == 'cash';
      if (m == null && pay.methodCode != 'cash') throw SaleError('unknown_method', 'Payment method ${pay.methodCode} is not set up.');
      if (m != null && m['requires_reference'] == 1 && (pay.reference ?? '').trim().isEmpty) {
        throw SaleError('reference_needed', '${m['name']} needs the confirmation reference.');
      }
      await currency(pay.currency);
      final credited = await convert(pay.amountMinor, pay.currency, cart.saleCurrency);
      paid += credited;
      if (isCash) cashPaid += credited;
      if (m != null ? m['opens_drawer'] == 1 : isCash) opensDrawer = true;
      payRows.add({
        'method_code': pay.methodCode,
        'currency': pay.currency,
        'amount_minor': pay.amountMinor,
        'rate_to_sale_micro': pay.currency == cart.saleCurrency ? 1000000 : await rate(pay.currency, cart.saleCurrency),
        'reference': pay.reference,
        'is_change': 0,
      });
    }

    var credit = 0;
    Change? change;
    var laybyBalance = 0;
    if (paid < total && cart.layby) {
      if (cart.onCredit) throw SaleError('layby_or_credit', 'Choose either layby or credit, not both.');
      if (customer == null) throw SaleError('customer_needed', 'Choose the customer for the layby.');
      if (paid <= 0) throw SaleError('deposit_needed', 'A layby needs a deposit.');
      final pctRow = await _get(tx, "select value from settings where scope = 'shop' and key = 'layby_min_deposit_pct' and deleted_at is null");
      final pct = num.tryParse('${pctRow?['value'] ?? 0}') ?? 0;
      if (pct > 0 && paid * 100 < total * pct) {
        throw SaleError('deposit_too_small', 'The deposit must be at least ${pct == pct.truncate() ? pct.truncate() : pct}% of the total.', {'min_minor': (total * pct / 100).ceil()});
      }
      laybyBalance = total - paid;
    } else if (paid < total) {
      credit = total - paid;
      if (!cart.onCredit) throw SaleError('underpaid', 'The payments do not cover the total.', {'short_minor': credit});
      if (customer == null) throw SaleError('customer_needed', 'Choose the customer to put this on account.');
      final limit = customer['credit_limit_minor'] == null ? 0 : _i(customer['credit_limit_minor']);
      final limitCur = customer['credit_currency'] as String? ?? cart.saleCurrency;
      if (limit <= 0) throw SaleError('no_credit', 'This customer has no credit limit.');
      final owedRow = await _get(tx, 'select coalesce(sum(amount_minor), 0) as b from customer_ledger where customer_id = ? and currency = ?', [customer['id'], limitCur]);
      final after = _i(owedRow!['b']) + await convert(credit, cart.saleCurrency, limitCur);
      if (after > limit) {
        throw SaleError('credit_limit', 'This would take the customer over their credit limit.', {'limit_minor': limit, 'would_owe_minor': after, 'currency': limitCur});
      }
    } else if (paid > total) {
      final excess = paid - total;
      if (excess > cashPaid) throw SaleError('overpaid_non_cash', 'Only cash can be more than the total. Change cannot be given from mobile money or card.');
      final cc = cart.changeCurrency ?? cart.saleCurrency;
      final ccRow = await currency(cc);
      final given = roundDownTo(await convert(excess, cart.saleCurrency, cc), ccRow['rounding_increment_minor'] == null ? 0 : _i(ccRow['rounding_increment_minor']));
      if (given > 0) change = Change(cc, given);
    }

    final receiptNo = await _nextReceiptNo(tx);
    final status = laybyBalance > 0 ? 'layby' : credit > 0 ? 'on_credit' : 'completed';
    await _insert(tx, 'sales', {
      'id': saleId,
      'branch_id': cart.branchId,
      'shift_id': cart.shiftId,
      'user_id': cart.userId,
      'customer_id': cart.customerId,
      'price_tier_id': tierId,
      'receipt_no': receiptNo,
      'status': status,
      'sale_currency': cart.saleCurrency,
      'subtotal_minor': subtotal,
      'discount_minor': discountTotal,
      'tax_minor': taxTotal,
      'total_minor': total,
      'rates_used': jsonEncode(ratesUsed),
      'note': cart.note,
      'completed_at': now,
    }, now, cart);
    for (final r in payRows) {
      await _insert(tx, 'sale_payments', {'sale_id': saleId, ...r}, now, cart);
    }
    if (change != null) {
      await _insert(tx, 'sale_payments', {
        'sale_id': saleId,
        'method_code': 'cash',
        'currency': change.currency,
        'amount_minor': change.amountMinor,
        'rate_to_sale_micro': change.currency == cart.saleCurrency ? 1000000 : await rate(change.currency, cart.saleCurrency),
        'is_change': 1,
      }, now, cart);
    }
    if (credit > 0) {
      await _insert(tx, 'customer_ledger', {
        'customer_id': customer!['id'],
        'type': 'credit_sale',
        'currency': cart.saleCurrency,
        'amount_minor': credit,
        'ref_type': 'sale',
        'ref_id': saleId,
      }, now, cart);
    }
    final fiscal = await _get(tx, "select value from settings where scope = 'shop' and key = 'fiscal_enabled' and deleted_at is null");
    if (fiscal?['value'] == '1') {
      await _insert(tx, 'fiscal_documents', {
        'sale_id': saleId,
        'kind': 'invoice',
        'payload': jsonEncode({'sale_id': saleId, 'receipt_no': receiptNo}),
        'status': 'queued',
        'attempts': 0,
        'updated_at': now,
        'version': 1,
      }, now, cart);
    }
    return SaleResult(
      saleId: saleId, receiptNo: receiptNo, status: status, subtotalMinor: subtotal, discountMinor: discountTotal, taxMinor: taxTotal,
      totalMinor: total, paidMinor: paid, creditMinor: credit, laybyBalanceMinor: laybyBalance, change: change, opensDrawer: opensDrawer,
    );
  }

  /// D1-000001, D1-000002 ... The counter is local to this phone and the prefix is unique to it, so numbers never clash.
  Future<String> _nextReceiptNo(SqlDb tx) async {
    await tx.exec("insert into receipt_counters (kind, last_no) values ('sale', 1) on conflict (kind) do update set last_no = last_no + 1");
    final r = await tx.query("select last_no from receipt_counters where kind = 'sale'");
    return '${context.receiptPrefix}-${_i(r.first['last_no']).toString().padLeft(6, '0')}';
  }
}

/// 10000 -> "10", 2500 -> "2.5" (quantities are kept in thousandths).
String _qtyText(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');
