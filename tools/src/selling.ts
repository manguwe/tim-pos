/**
 * The selling engine: turns a cart into one sale, written in one transaction with its lines, payments,
 * stock movements and any customer credit. Reference implementation; the Dart port in app/lib/selling follows it.
 *
 * Conventions (also in the database design document):
 *  - Prices come from product_prices in the sale currency, else are converted from the shop's base currency.
 *  - Tax: line_total_minor includes tax; tax_minor is the tax part. sales.subtotal_minor is the total without tax.
 *  - Customers can overpay only in cash. Change is given in the currency chosen, rounded DOWN to that currency's
 *    smallest coin (rounding_increment_minor); the shop keeps the remainder.
 *  - Change is stored as a sale_payments row with is_change = 1 and a positive amount.
 *  - customer_ledger: positive = the customer owes more; payments are negative.
 *  - Stock is blocked at zero unless the product, or the shop setting allow_negative_stock, says otherwise.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { convertMinor, invertRate, lineAmount, roundDownTo, taxSplit, MoneyError } from './money.ts';
import { hasPermission, type Permission } from './auth.ts';

export interface CartLine {
  product_id: string;
  qty_milli: number;
  /** Only when someone with the price.edit permission typed a different price. Recorded in the audit log. */
  unit_price_minor?: number;
  discount_minor?: number;
}
export interface CartPayment { method_code: string; currency: string; amount_minor: number; reference?: string }
export interface Cart {
  branch_id: string;
  user_id: string | null;
  shift_id?: string | null;
  customer_id?: string | null;
  price_tier_id?: string | null;
  sale_currency: string;
  lines: CartLine[];
  payments: CartPayment[];
  /** Put what is not paid on the customer's account. Needs customer_id and a credit limit. */
  on_credit?: boolean;
  /** Hold the goods for the customer and take what they pay now as a deposit. Needs customer_id. The rest is paid later with payLayby. */
  layby?: boolean;
  /** Currency the change is handed back in. Default: the sale currency. */
  change_currency?: string;
  note?: string;
  /** A manager who approved the discounts or price changes in this cart, by PIN. Their permissions are used instead of the cashier's. */
  approved_by?: string | null;
}
export interface SaleContext { shop_id: string; device_id: string; receipt_prefix: string; now: number }

export interface SaleResult {
  sale_id: string;
  receipt_no: string;
  status: 'completed' | 'on_credit' | 'layby';
  subtotal_minor: number; discount_minor: number; tax_minor: number; total_minor: number;
  paid_minor: number;
  credit_minor: number;
  /** What is still to pay on a layby (0 otherwise). */
  layby_balance_minor: number;
  change: { currency: string; amount_minor: number } | null;
  opens_drawer: boolean;
}

export class SaleError extends Error {
  code: string;
  detail: Record<string, unknown>;
  constructor(code: string, message: string, detail: Record<string, unknown> = {}) { super(message); this.code = code; this.detail = detail; }
}

type Row = Record<string, any>;

export function sell(db: DatabaseSync, ctx: SaleContext, cart: Cart, newId: () => string = randomUUID): SaleResult {
  db.exec('begin');
  try {
    const r = sellInTransaction(db, ctx, cart, newId);
    db.exec('commit');
    return r;
  } catch (e) {
    db.exec('rollback');
    if (e instanceof MoneyError) throw new SaleError(e.code, e.message);
    throw e;
  }
}

function sellInTransaction(db: DatabaseSync, ctx: SaleContext, cart: Cart, newId: () => string): SaleResult {
  const get = (sql: string, ...a: any[]): Row | undefined => { const r = db.prepare(sql).get(...a); return r ? { ...r } : undefined; };
  const all = (sql: string, ...a: any[]): Row[] => db.prepare(sql).all(...a).map((r) => ({ ...r }));
  const run = (sql: string, ...a: any[]) => db.prepare(sql).run(...a);
  const insert = (table: string, row: Row) => {
    const o: Row = { id: newId(), shop_id: ctx.shop_id, created_at: ctx.now, created_by: cart.user_id, device_id: ctx.device_id, ...row };
    const ks = Object.keys(o);
    run(`insert into "${table}" (${ks.map((k) => `"${k}"`).join(', ')}) values (${ks.map(() => '?').join(', ')})`, ...ks.map((k) => o[k]));
    return o.id as string;
  };

  if (cart.lines.length === 0) throw new SaleError('empty_cart', 'Add at least one item.');
  // Permissions: a signed-in user must be allowed to sell; discounts and typed prices need their own switch (or a manager's approval).
  if (cart.user_id) {
    const can = (p: Permission) => hasPermission(db, cart.user_id!, p) || (cart.approved_by != null && hasPermission(db, cart.approved_by, p));
    if (!hasPermission(db, cart.user_id, 'sale.create')) throw new SaleError('forbidden', 'You are not allowed to make sales.', { permission: 'sale.create' });
    if (cart.lines.some((l) => (l.discount_minor ?? 0) > 0) && !can('sale.discount')) throw new SaleError('forbidden', 'A discount needs a manager\'s approval.', { permission: 'sale.discount' });
    if (cart.lines.some((l) => l.unit_price_minor !== undefined) && !can('price.edit')) throw new SaleError('forbidden', 'Changing a price needs a manager\'s approval.', { permission: 'price.edit' });
  }
  const saleCur = get('select * from currencies where code = ? and deleted_at is null', cart.sale_currency);
  if (!saleCur) throw new SaleError('unknown_currency', `Currency ${cart.sale_currency} is not set up.`);
  const base = get("select base_currency from shops where deleted_at is null limit 1")?.base_currency as string | undefined;
  if (!base) throw new SaleError('shop_not_set_up', 'The shop has no base currency yet.');
  if (!cart.shift_id && get("select value from settings where scope = 'shop' and key = 'require_shift' and deleted_at is null")?.value === '1') {
    throw new SaleError('shift_needed', 'Open a shift before selling.');
  }
  if (cart.shift_id) {
    const sh = get('select status from shifts where id = ?', cart.shift_id);
    if (!sh || sh.status !== 'open') throw new SaleError('shift_closed', 'Open a shift before selling.');
  }

  // ---- exchange rates (the latest at or before now), remembered for the sale ----
  const ratesUsed: Record<string, number> = {};
  const currencyRow = (code: string): Row => {
    const c = get('select * from currencies where code = ? and deleted_at is null', code);
    if (!c) throw new SaleError('unknown_currency', `Currency ${code} is not set up.`);
    return c;
  };
  /** Millionths of `to` that one `from` is worth. Uses the opposite pair, inverted, when only that one is set. */
  const rate = (from: string, to: string): number => {
    if (from === to) return 1_000_000;
    const d = get('select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1', from, to, ctx.now);
    const rv = d ? d.rate_micro as number : (() => {
      const i = get('select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1', to, from, ctx.now);
      if (!i) throw new SaleError('no_rate', `No exchange rate between ${from} and ${to}.`);
      return invertRate(i.rate_micro as number);
    })();
    ratesUsed[`${from}>${to}`] = rv;
    return rv;
  };
  const convert = (amount: number, from: string, to: string): number =>
    from === to ? amount : convertMinor(amount, rate(from, to), currencyRow(from).minor_units, currencyRow(to).minor_units);

  const allowNegativeShop = get("select value from settings where scope = 'shop' and key = 'allow_negative_stock' and deleted_at is null")?.value === '1';
  const customer = cart.customer_id ? get('select * from customers where id = ? and deleted_at is null', cart.customer_id) : undefined;
  if (cart.customer_id && !customer) throw new SaleError('unknown_customer', 'That customer was not found.');
  const tierId = cart.price_tier_id ?? customer?.price_tier_id ?? (get('select id from price_tiers where is_default = 1 and deleted_at is null')?.id as string | undefined) ?? null;

  const saleId = newId();
  let subtotal = 0, discountTotal = 0, taxTotal = 0, total = 0;
  const pending: { line: Row; movements: Row[] }[] = [];

  for (const l of cart.lines) {
    if (!Number.isSafeInteger(l.qty_milli) || l.qty_milli <= 0) throw new SaleError('bad_quantity', 'Quantity must be more than zero.');
    const p = get('select * from products where id = ? and deleted_at is null', l.product_id);
    if (!p || p.is_active === 0) throw new SaleError('unknown_product', 'That product cannot be sold.', { product_id: l.product_id });
    if (p.kind === 'variant_parent') throw new SaleError('choose_variant', `Choose a variant of ${p.name}.`, { product_id: p.id });

    // price: typed price > price in the sale currency (latest effective, tier then default tier) > converted base price
    let unit: number;
    if (l.unit_price_minor !== undefined) {
      if (!Number.isSafeInteger(l.unit_price_minor) || l.unit_price_minor < 0) throw new SaleError('bad_price', 'Price must be zero or more.');
      unit = l.unit_price_minor;
      insert('audit_log', { user_id: cart.user_id, action: 'price_override', table_name: 'products', row_id: p.id, after: JSON.stringify({ unit_price_minor: unit, sale_id: saleId }) });
    } else {
      const findPrice = (cur: string): number | undefined => {
        const rows = all(
          `select price_minor, tier_id from product_prices where product_id = ? and currency = ? and effective_from <= ? and deleted_at is null
           order by effective_from desc, created_at desc`, p.id, cur, ctx.now);
        return (rows.find((r) => r.tier_id === tierId) ?? rows.find((r) => r.tier_id === null) ?? rows[0])?.price_minor as number | undefined;
      };
      const direct = findPrice(cart.sale_currency);
      if (direct !== undefined) unit = direct;
      else {
        const inBase = cart.sale_currency === base ? undefined : findPrice(base);
        if (inBase === undefined) throw new SaleError('no_price', `${p.name} has no price in ${cart.sale_currency}.`, { product_id: p.id });
        unit = convert(inBase, base, cart.sale_currency);
      }
      // quantity price: from min_qty upwards every unit is at the break price (the highest break that the quantity reaches wins)
      const findBreak = (cur: string): number | undefined => {
        const rows = all(
          `select price_minor, tier_id from price_breaks where product_id = ? and currency = ? and min_qty_milli <= ? and deleted_at is null
           order by min_qty_milli desc, created_at desc`, p.id, cur, l.qty_milli);
        return (rows.find((r) => r.tier_id === tierId) ?? rows.find((r) => r.tier_id === null))?.price_minor as number | undefined;
      };
      const brk = findBreak(cart.sale_currency);
      if (brk !== undefined) unit = brk;
      else if (cart.sale_currency !== base) {
        const inBase = findBreak(base);
        if (inBase !== undefined) unit = convert(inBase, base, cart.sale_currency);
      }
    }

    const discount = l.discount_minor ?? 0;
    if (!Number.isSafeInteger(discount) || discount < 0) throw new SaleError('bad_discount', 'Discount must be zero or more.');
    const gross = lineAmount(l.qty_milli, unit);
    if (discount > gross) throw new SaleError('discount_too_big', 'The discount is more than the price.', { product_id: p.id });
    const tc = p.tax_class_id ? get('select * from tax_classes where id = ?', p.tax_class_id) : undefined;
    const t = taxSplit(gross - discount, tc?.rate_bp ?? 0, tc ? tc.is_inclusive === 1 : true);

    const line: Row = {
      id: newId(), sale_id: saleId, product_id: p.id, description: p.name, unit_id: p.base_unit_id, qty_milli: l.qty_milli,
      unit_price_minor: unit, price_currency: cart.sale_currency, discount_minor: discount, tax_rate_bp: tc?.rate_bp ?? 0,
      tax_minor: t.tax, line_total_minor: t.total, unit_cost_minor: p.cost_minor ?? null,
    };
    subtotal += t.net; discountTotal += discount; taxTotal += t.tax; total += t.total;

    // stock: what leaves the shelf. A bundle takes its components; services take nothing.
    const movements: Row[] = [];
    const take = (prod: Row, qty: number) => {
      if (prod.track_stock !== 1) return;
      const rows = all(
        `select l.batch_key, l.qty_milli from stock_levels l left join stock_batches b on b.id = l.batch_key
         where l.branch_id = ? and l.product_id = ? and l.qty_milli > 0
         order by (b.expiry_date is null), b.expiry_date, l.batch_key`, cart.branch_id, prod.id);
      let left = qty;
      for (const r of rows) {
        if (left === 0) break;
        const use = Math.min(left, r.qty_milli);
        movements.push({ product_id: prod.id, batch_id: r.batch_key === '' ? null : r.batch_key, qty_milli: -use, unit_cost_minor: prod.cost_minor ?? null });
        left -= use;
      }
      if (left > 0) {
        if (prod.allow_negative_stock !== 1 && !allowNegativeShop) {
          throw new SaleError('insufficient_stock', `Only ${(qty - left) / 1000} of ${prod.name} left.`, { product_id: prod.id, available_milli: qty - left });
        }
        movements.push({ product_id: prod.id, batch_id: null, qty_milli: -left, unit_cost_minor: prod.cost_minor ?? null });
      }
    };
    if (p.kind === 'bundle') {
      for (const bi of all('select component_product_id, qty_milli from bundle_items where bundle_product_id = ? and deleted_at is null', p.id)) {
        const comp = get('select * from products where id = ? and deleted_at is null', bi.component_product_id);
        if (comp) take(comp, Math.round(bi.qty_milli * l.qty_milli / 1000));
      }
    } else take(p, l.qty_milli);
    pending.push({ line, movements });
    // Write now so the next line of the same product sees the stock already taken.
    insert('sale_lines', line);
    for (const m of movements) {
      insert('stock_movements', { branch_id: cart.branch_id, type: 'sale', ref_type: 'sale', ref_id: saleId, cost_currency: base, ...m });
    }
  }

  // ---- payments ----
  let paid = 0;
  let cashPaid = 0;
  const payRows: Row[] = [];
  for (const pay of cart.payments) {
    if (!Number.isSafeInteger(pay.amount_minor) || pay.amount_minor <= 0) throw new SaleError('bad_payment', 'A payment must be more than zero.');
    const m = get('select * from payment_methods where code = ? and deleted_at is null', pay.method_code);
    const isCash = m ? m.kind === 'cash' : pay.method_code === 'cash';
    if (!m && pay.method_code !== 'cash') throw new SaleError('unknown_method', `Payment method ${pay.method_code} is not set up.`);
    if (m?.requires_reference === 1 && !pay.reference?.trim()) throw new SaleError('reference_needed', `${m.name} needs the confirmation reference.`);
    currencyRow(pay.currency);
    const credited = convert(pay.amount_minor, pay.currency, cart.sale_currency);
    paid += credited;
    if (isCash) cashPaid += credited;
    payRows.push({ method_code: pay.method_code, currency: pay.currency, amount_minor: pay.amount_minor, rate_to_sale_micro: pay.currency === cart.sale_currency ? 1_000_000 : rate(pay.currency, cart.sale_currency), reference: pay.reference ?? null, is_change: 0, _drawer: m ? m.opens_drawer === 1 : isCash });
  }

  let credit = 0;
  let change: SaleResult['change'] = null;
  let laybyBalance = 0;
  if (paid < total && cart.layby) {
    if (cart.on_credit) throw new SaleError('layby_or_credit', 'Choose either layby or credit, not both.');
    if (!customer) throw new SaleError('customer_needed', 'Choose the customer for the layby.');
    if (paid <= 0) throw new SaleError('deposit_needed', 'A layby needs a deposit.');
    const pct = Number(get("select value from settings where scope = 'shop' and key = 'layby_min_deposit_pct' and deleted_at is null")?.value ?? 0);
    if (Number.isFinite(pct) && pct > 0 && paid * 100 < total * pct) {
      throw new SaleError('deposit_too_small', `The deposit must be at least ${pct}% of the total.`, { min_minor: Math.ceil((total * pct) / 100) });
    }
    laybyBalance = total - paid;
  } else if (paid < total) {
    credit = total - paid;
    if (!cart.on_credit) throw new SaleError('underpaid', 'The payments do not cover the total.', { short_minor: credit });
    if (!customer) throw new SaleError('customer_needed', 'Choose the customer to put this on account.');
    const limit = customer.credit_limit_minor as number | null;
    const limitCur = (customer.credit_currency as string | null) ?? cart.sale_currency;
    if (!limit || limit <= 0) throw new SaleError('no_credit', 'This customer has no credit limit.');
    const owed = get(`select coalesce(sum(amount_minor), 0) as b from customer_ledger where customer_id = ? and currency = ?`, customer.id, limitCur)!.b as number;
    const after = owed + convert(credit, cart.sale_currency, limitCur);
    if (after > limit) throw new SaleError('credit_limit', 'This would take the customer over their credit limit.', { limit_minor: limit, would_owe_minor: after, currency: limitCur });
  } else if (paid > total) {
    const excess = paid - total;
    if (excess > cashPaid) throw new SaleError('overpaid_non_cash', 'Only cash can be more than the total. Change cannot be given from mobile money or card.');
    const cc = cart.change_currency ?? cart.sale_currency;
    const ccRow = currencyRow(cc);
    const given = roundDownTo(convert(excess, cart.sale_currency, cc), ccRow.rounding_increment_minor ?? 0);
    if (given > 0) change = { currency: cc, amount_minor: given };
  }

  const receiptNo = nextReceiptNo(db, ctx.receipt_prefix);
  const status = laybyBalance > 0 ? 'layby' : credit > 0 ? 'on_credit' : 'completed';
  insert('sales', {
    id: saleId, branch_id: cart.branch_id, shift_id: cart.shift_id ?? null, user_id: cart.user_id, customer_id: cart.customer_id ?? null,
    price_tier_id: tierId, receipt_no: receiptNo, status, sale_currency: cart.sale_currency, subtotal_minor: subtotal, discount_minor: discountTotal,
    tax_minor: taxTotal, total_minor: total, rates_used: JSON.stringify(ratesUsed), note: cart.note ?? null, completed_at: ctx.now,
  });
  // sale_lines and stock_movements above point at the sale; the sale row must exist before the transaction commits (foreign keys are deferred).
  for (const pr of payRows) { const { _drawer, ...row } = pr; insert('sale_payments', { sale_id: saleId, ...row }); }
  if (change) {
    insert('sale_payments', {
      sale_id: saleId, method_code: 'cash', currency: change.currency, amount_minor: change.amount_minor,
      rate_to_sale_micro: change.currency === cart.sale_currency ? 1_000_000 : rate(change.currency, cart.sale_currency), reference: null, is_change: 1,
    });
  }
  if (credit > 0) {
    insert('customer_ledger', { customer_id: customer!.id, type: 'credit_sale', currency: cart.sale_currency, amount_minor: credit, ref_type: 'sale', ref_id: saleId });
  }
  if (get("select value from settings where scope = 'shop' and key = 'fiscal_enabled' and deleted_at is null")?.value === '1') {
    insert('fiscal_documents', { sale_id: saleId, kind: 'invoice', payload: JSON.stringify({ sale_id: saleId, receipt_no: receiptNo }), status: 'queued', attempts: 0, updated_at: ctx.now, version: 1 });
  }
  return {
    sale_id: saleId, receipt_no: receiptNo, status, subtotal_minor: subtotal, discount_minor: discountTotal, tax_minor: taxTotal, total_minor: total,
    paid_minor: paid, credit_minor: credit, layby_balance_minor: laybyBalance, change, opens_drawer: payRows.some((p) => p._drawer),
  };
}

/** D1-000001, D1-000002 ... The counter is local to this phone, the prefix is unique to it, so numbers never clash. */
export function nextReceiptNo(db: DatabaseSync, prefix: string, kind = 'sale'): string {
  db.prepare(`insert into receipt_counters (kind, last_no) values (?, 1) on conflict (kind) do update set last_no = last_no + 1`).run(kind);
  const n = (db.prepare('select last_no from receipt_counters where kind = ?').get(kind) as { last_no: number }).last_no;
  return `${prefix}-${String(n).padStart(6, '0')}`;
}
