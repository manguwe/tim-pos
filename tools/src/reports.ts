/**
 * Reports for the owner and manager. Reference implementation; app/lib/reports/report_repository.dart is a port.
 * Everything is read from the saved records, so the figures always agree with the till, and nothing here writes.
 *
 * Counting rules (the same on every report):
 *  - A voided sale is left out completely, and so are returns made on it.
 *  - A layby counts as a sale on the day the goods are handed over; until then it is listed as "open laybys", not as sales.
 *  - A return reduces the sales of the day it was made, not of the day of the original sale.
 *  - Money in other currencies is converted to the shop's base currency at the rate saved with the sale.
 *  - Profit = sales - tax - cost of goods. Items sold without a cost are counted and shown, not guessed.
 * Ranges are [from, to) in UTC milliseconds; the screen turns "today" or "this month" into a range using the shop's clock.
 */
import { DatabaseSync } from 'node:sqlite';
import { convertMinor, divRound, invertRate } from './money.ts';

type Row = Record<string, any>;
export interface Range { from: number; to: number }
export interface Filter { branch_id?: string | null; user_id?: string | null }

const ids = (f: Filter): any[] => [f.branch_id, f.user_id].filter((x) => x);
const one = (x: string | null | undefined): any[] => (x ? [x] : []);

const NOT_VOIDED = 'not exists (select 1 from sale_voids v where v.sale_id = s.id)';

interface SaleRow extends Row { eff_at: number }

function baseCurrency(db: DatabaseSync): string {
  return ((db.prepare('select base_currency from shops where deleted_at is null limit 1').get() as Row | undefined)?.base_currency as string | undefined) ?? 'USD';
}
function minorUnits(db: DatabaseSync, cache: Map<string, number>, code: string): number {
  let v = cache.get(code);
  if (v === undefined) { v = ((db.prepare('select minor_units from currencies where code = ?').get(code) as Row | undefined)?.minor_units as number | undefined) ?? 2; cache.set(code, v); }
  return v;
}

/** Converts an amount of a sale into the base currency using the rates saved with that sale. */
class Converter {
  db: DatabaseSync; base: string; units = new Map<string, number>();
  constructor(db: DatabaseSync) { this.db = db; this.base = baseCurrency(db); }
  toBase(amount: number, cur: string, sale: Row): number {
    if (cur === this.base || amount === 0) return amount;
    let used: Record<string, number> = {};
    try { used = JSON.parse(sale.rates_used ?? '{}'); } catch { used = {}; }
    let rate = used[`${cur}>${this.base}`];
    if (rate === undefined && used[`${this.base}>${cur}`] !== undefined) rate = invertRate(used[`${this.base}>${cur}`] as number);
    if (rate === undefined) {
      const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
      const d = this.db.prepare(q).get(cur, this.base, sale.completed_at) as Row | undefined;
      const i = d ? undefined : (this.db.prepare(q).get(this.base, cur, sale.completed_at) as Row | undefined);
      if (d) rate = d.rate_micro; else if (i) rate = invertRate(i.rate_micro); else return 0; // no rate known: left out rather than guessed
    }
    return convertMinor(amount, rate as number, minorUnits(this.db, this.units, cur), minorUnits(this.db, this.units, this.base));
  }
}

/** Sales that count, with the date they count on. */
function eligibleSales(db: DatabaseSync, r: Range, f: Filter): SaleRow[] {
  const rows = db.prepare(`select * from (
      select s.*, case when s.status = 'layby'
        then (select min(lp.created_at) from layby_payments lp where lp.sale_id = s.id and lp.payment_id is null and lp.due_note = 'collected')
        else s.completed_at end as eff_at
      from sales s where ${NOT_VOIDED} ${f.branch_id ? 'and s.branch_id = ?' : ''} ${f.user_id ? 'and s.user_id = ?' : ''}
    ) where eff_at is not null and eff_at >= ? and eff_at < ? order by eff_at`).all(...ids(f), r.from, r.to) as Row[];
  return rows.map((x) => ({ ...x })) as SaleRow[];
}

/** Returns made in the range on sales that are not voided. */
function returnsIn(db: DatabaseSync, r: Range, f: Filter): Row[] {
  return (db.prepare(`select rt.*, s.rates_used, s.completed_at, s.sale_currency from sale_returns rt join sales s on s.id = rt.original_sale_id
      where rt.kind = 'return' and rt.created_at >= ? and rt.created_at < ? and ${NOT_VOIDED} ${f.branch_id ? 'and s.branch_id = ?' : ''} ${f.user_id ? 'and s.user_id = ?' : ''}
      order by rt.created_at`).all(r.from, r.to, ...ids(f)) as Row[]).map((x) => ({ ...x }));
}

// ---- sales summary ----

export interface CurrencyTotals { currency: string; sales: number; gross_minor: number; discount_minor: number; tax_minor: number; returns_minor: number; net_minor: number }
export interface SalesSummary {
  base_currency: string;
  by_currency: CurrencyTotals[];
  /** Everything below is in the base currency. */
  sales: number; returns: number; revenue_minor: number; tax_minor: number; cost_minor: number; profit_minor: number; lines_without_cost: number;
  average_sale_minor: number;
  open_layby: { count: number; value_minor: number; paid_minor: number; currency: string }[];
}

export function salesSummary(db: DatabaseSync, r: Range, f: Filter = {}): SalesSummary {
  const cv = new Converter(db);
  const sales = eligibleSales(db, r, f);
  const rets = returnsIn(db, r, f);
  const per = new Map<string, CurrencyTotals>();
  const slot = (c: string) => { let t = per.get(c); if (!t) { t = { currency: c, sales: 0, gross_minor: 0, discount_minor: 0, tax_minor: 0, returns_minor: 0, net_minor: 0 }; per.set(c, t); } return t; };
  let revenue = 0, tax = 0, cost = 0, noCost = 0;
  for (const s of sales) {
    const t = slot(s.sale_currency);
    t.sales++; t.gross_minor += s.total_minor; t.discount_minor += s.discount_minor; t.tax_minor += s.tax_minor;
    revenue += cv.toBase(s.total_minor, s.sale_currency, s); tax += cv.toBase(s.tax_minor, s.sale_currency, s);
    for (const l of db.prepare('select qty_milli, unit_cost_minor from sale_lines where sale_id = ?').all(s.id) as Row[]) {
      if (l.unit_cost_minor == null) noCost++; else cost += divRound(l.unit_cost_minor * l.qty_milli, 1000);
    }
  }
  for (const rt of rets) {
    slot(rt.sale_currency).returns_minor += rt.refund_minor;
    revenue -= cv.toBase(rt.refund_minor, rt.sale_currency, rt);
    for (const rl of db.prepare(`select rl.qty_milli, rl.restock, rl.amount_minor, sl.qty_milli as sold_qty, sl.tax_minor, sl.line_total_minor, sl.unit_cost_minor
        from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ?`).all(rt.id) as Row[]) {
      if (rl.line_total_minor > 0) {
        const tx = divRound(rl.tax_minor * rl.amount_minor, rl.line_total_minor);
        tax -= cv.toBase(tx, rt.sale_currency, rt); slot(rt.sale_currency).tax_minor -= tx;
      }
      if (rl.restock === 1 && rl.unit_cost_minor != null) cost -= divRound(rl.unit_cost_minor * rl.qty_milli, 1000);
    }
  }
  const totals = [...per.values()].sort((a, b) => a.currency.localeCompare(b.currency));
  for (const t of totals) t.net_minor = t.gross_minor - t.returns_minor;
  const count = sales.length;
  const openL = db.prepare(`select s.id, s.sale_currency, s.total_minor from sales s where s.status = 'layby' and ${NOT_VOIDED}
      and not exists (select 1 from layby_payments lp where lp.sale_id = s.id and lp.payment_id is null and lp.due_note = 'collected') ${f.branch_id ? 'and s.branch_id = ?' : ''}`).all(...one(f.branch_id)) as Row[];
  const lay = new Map<string, { count: number; value_minor: number; paid_minor: number; currency: string }>();
  for (const l of openL) {
    const e = lay.get(l.sale_currency) ?? { count: 0, value_minor: 0, paid_minor: 0, currency: l.sale_currency };
    e.count++; e.value_minor += l.total_minor; e.paid_minor += laybyPaidSimple(db, l.id, l.sale_currency); lay.set(l.sale_currency, e);
  }
  return {
    base_currency: cv.base, by_currency: totals, sales: count, returns: rets.length, revenue_minor: revenue, tax_minor: tax, cost_minor: cost,
    profit_minor: revenue - tax - cost, lines_without_cost: noCost, average_sale_minor: count ? divRound(revenue, count) : 0, open_layby: [...lay.values()],
  };
}

function laybyPaidSimple(db: DatabaseSync, saleId: string, cur: string): number {
  const units = new Map<string, number>();
  let paid = 0;
  for (const p of db.prepare('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?').all(saleId) as Row[]) {
    const v = p.currency === cur ? p.amount_minor : convertMinor(p.amount_minor, p.rate_to_sale_micro, minorUnits(db, units, p.currency), minorUnits(db, units, cur));
    paid += p.is_change ? -v : v;
  }
  return paid + ((db.prepare('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?').get(saleId) as Row).s as number);
}

// ---- by day ----

export interface DayRow { day: string; sales: number; revenue_minor: number; returns_minor: number; net_minor: number }
const pad = (n: number) => String(n).padStart(2, '0');
export function dayOf(ms: number, offsetMin: number): string {
  const d = new Date(ms + offsetMin * 60_000);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}`;
}

/** Sales per local day in the base currency, oldest first. Days with no sales are included so charts have no gaps. */
export function dailySales(db: DatabaseSync, r: Range, offsetMin: number, f: Filter = {}): DayRow[] {
  const cv = new Converter(db);
  const map = new Map<string, DayRow>();
  const get = (day: string) => { let d = map.get(day); if (!d) { d = { day, sales: 0, revenue_minor: 0, returns_minor: 0, net_minor: 0 }; map.set(day, d); } return d; };
  for (let t = r.from; t < r.to; t += 86_400_000) get(dayOf(t, offsetMin));
  for (const s of eligibleSales(db, r, f)) { const d = get(dayOf(s.eff_at, offsetMin)); d.sales++; d.revenue_minor += cv.toBase(s.total_minor, s.sale_currency, s); }
  for (const rt of returnsIn(db, r, f)) get(dayOf(rt.created_at, offsetMin)).returns_minor += cv.toBase(rt.refund_minor, rt.sale_currency, rt);
  const out = [...map.values()].sort((a, b) => a.day.localeCompare(b.day));
  for (const d of out) d.net_minor = d.revenue_minor - d.returns_minor;
  return out;
}

// ---- products ----

export interface ProductRow { product_id: string | null; name: string; qty_milli: number; revenue_minor: number; cost_minor: number; profit_minor: number }
export function topProducts(db: DatabaseSync, r: Range, o: { by?: 'qty' | 'revenue' | 'profit'; limit?: number } & Filter = {}): ProductRow[] {
  const cv = new Converter(db);
  const m = new Map<string, ProductRow & { tax: number }>();
  const slot = (id: string | null, name: string) => { const k = id ?? `name:${name}`; let p = m.get(k); if (!p) { p = { product_id: id, name, qty_milli: 0, revenue_minor: 0, cost_minor: 0, profit_minor: 0, tax: 0 }; m.set(k, p); } return p; };
  for (const s of eligibleSales(db, r, o)) {
    for (const l of db.prepare('select * from sale_lines where sale_id = ?').all(s.id) as Row[]) {
      const p = slot(l.product_id, l.description ?? '');
      p.qty_milli += l.qty_milli; p.revenue_minor += cv.toBase(l.line_total_minor, s.sale_currency, s); p.tax += cv.toBase(l.tax_minor ?? 0, s.sale_currency, s);
      if (l.unit_cost_minor != null) p.cost_minor += divRound(l.unit_cost_minor * l.qty_milli, 1000);
    }
  }
  for (const rt of returnsIn(db, r, o)) {
    for (const rl of db.prepare(`select rl.qty_milli, rl.restock, rl.amount_minor, sl.product_id, sl.description, sl.tax_minor, sl.line_total_minor, sl.unit_cost_minor
        from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ?`).all(rt.id) as Row[]) {
      const p = slot(rl.product_id, rl.description ?? '');
      p.qty_milli -= rl.qty_milli; p.revenue_minor -= cv.toBase(rl.amount_minor, rt.sale_currency, rt);
      if (rl.line_total_minor > 0) p.tax -= cv.toBase(divRound((rl.tax_minor ?? 0) * rl.amount_minor, rl.line_total_minor), rt.sale_currency, rt);
      if (rl.restock === 1 && rl.unit_cost_minor != null) p.cost_minor -= divRound(rl.unit_cost_minor * rl.qty_milli, 1000);
    }
  }
  const key = o.by ?? 'revenue';
  const rows = [...m.values()].map(({ tax, ...p }) => ({ ...p, profit_minor: p.revenue_minor - tax - p.cost_minor }));
  rows.sort((a, b) => (key === 'qty' ? b.qty_milli - a.qty_milli : key === 'profit' ? b.profit_minor - a.profit_minor : b.revenue_minor - a.revenue_minor) || a.name.localeCompare(b.name));
  return rows.filter((p) => p.qty_milli !== 0 || p.revenue_minor !== 0).slice(0, o.limit ?? 20);
}

// ---- takings ----

export interface TakingRow { method: string; currency: string; received_minor: number; paid_back_minor: number; net_minor: number }
/** Money in and out by payment method, by the day it moved: sale payments (less change), account and layby payments, refunds. */
export function takings(db: DatabaseSync, r: Range, f: Filter = {}): TakingRow[] {
  const m = new Map<string, TakingRow>();
  const slot = (code: string, name: string, cur: string) => { const k = `${code}|${cur}`; let t = m.get(k); if (!t) { t = { method: name, currency: cur, received_minor: 0, paid_back_minor: 0, net_minor: 0 }; m.set(k, t); } return t; };
  const name = (c: string) => ((db.prepare('select name from payment_methods where code = ?').get(c) as Row | undefined)?.name as string | undefined) ?? c;
  const br = f.branch_id ? 'and s.branch_id = ?' : ''; const us = f.user_id ? 'and s.user_id = ?' : '';
  const a: any[] = ids(f);
  for (const p of db.prepare(`select sp.method_code, sp.currency, sp.amount_minor, sp.is_change from sale_payments sp join sales s on s.id = sp.sale_id where sp.created_at >= ? and sp.created_at < ? ${br} ${us}`).all(r.from, r.to, ...a) as Row[]) {
    const t = slot(p.method_code, name(p.method_code), p.currency);
    if (p.is_change) t.paid_back_minor += p.amount_minor; else t.received_minor += p.amount_minor;
  }
  for (const p of db.prepare(`select ap.method_code, ap.currency, ap.amount_minor from account_payments ap where ap.created_at >= ? and ap.created_at < ? ${f.user_id ? 'and ap.user_id = ?' : ''}`).all(r.from, r.to, ...one(f.user_id)) as Row[]) {
    slot(p.method_code, name(p.method_code), p.currency).received_minor += p.amount_minor;
  }
  for (const p of db.prepare(`select rp.method_code, rp.currency, rp.amount_minor from return_payouts rp join sale_returns rt on rt.id = rp.return_id join sales s on s.id = rt.original_sale_id where rt.created_at >= ? and rt.created_at < ? ${br} ${us}`).all(r.from, r.to, ...a) as Row[]) {
    slot(p.method_code, name(p.method_code), p.currency).paid_back_minor += p.amount_minor;
  }
  const out = [...m.values()];
  for (const t of out) t.net_minor = t.received_minor - t.paid_back_minor;
  return out.sort((x, y) => x.method.localeCompare(y.method) || x.currency.localeCompare(y.currency));
}

// ---- stock ----

export interface StockValue { base_currency: string; total_minor: number; products: number; without_cost: number; negative: number; rows: { product_id: string; name: string; qty_milli: number; cost_minor: number | null; value_minor: number }[] }
export function stockValue(db: DatabaseSync, f: { branch_id?: string | null; top?: number } = {}): StockValue {
  const rows = db.prepare(`select p.id, p.name, p.cost_minor, coalesce(sum(l.qty_milli), 0) as qty from products p left join stock_levels l on l.product_id = p.id ${f.branch_id ? 'and l.branch_id = ?' : ''}
      where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.kind <> 'variant_parent' group by p.id order by p.name`).all(...one(f.branch_id)) as Row[];
  let total = 0, noCost = 0, neg = 0, n = 0;
  const out = rows.map((r) => {
    const value = r.cost_minor != null && r.qty > 0 ? divRound(r.cost_minor * r.qty, 1000) : 0;
    if (r.qty > 0) { n++; total += value; if (r.cost_minor == null) noCost++; }
    if (r.qty < 0) neg++;
    return { product_id: r.id, name: r.name, qty_milli: r.qty, cost_minor: r.cost_minor ?? null, value_minor: value };
  });
  out.sort((a, b) => b.value_minor - a.value_minor);
  return { base_currency: baseCurrency(db), total_minor: total, products: n, without_cost: noCost, negative: neg, rows: out.slice(0, f.top ?? 50) };
}

export interface OutOfStock { product_id: string; name: string; qty_milli: number }
export function outOfStock(db: DatabaseSync, f: { branch_id?: string | null } = {}): OutOfStock[] {
  return (db.prepare(`select p.id as product_id, p.name, coalesce(sum(l.qty_milli), 0) as qty_milli from products p left join stock_levels l on l.product_id = p.id ${f.branch_id ? 'and l.branch_id = ?' : ''}
      where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.kind not in ('variant_parent', 'bundle') group by p.id having qty_milli <= 0 order by p.name`).all(...one(f.branch_id)) as Row[]).map((x) => ({ ...x })) as OutOfStock[];
}

export interface ExpiringBatch { product_id: string; name: string; batch_code: string | null; expiry_date: string; qty_milli: number; expired: boolean }
/** Batches with stock that expire on or before `today` + days. `today` is a local date, 'YYYY-MM-DD'. */
export function expiringBatches(db: DatabaseSync, today: string, days: number): ExpiringBatch[] {
  const limit = new Date(Date.parse(today + 'T00:00:00Z') + days * 86_400_000).toISOString().slice(0, 10);
  return (db.prepare(`select b.product_id, p.name, b.batch_code, b.expiry_date, sum(l.qty_milli) as qty_milli from stock_batches b join products p on p.id = b.product_id
      join stock_levels l on l.batch_key = b.id and l.product_id = b.product_id where b.deleted_at is null and b.expiry_date is not null and b.expiry_date <= ?
      group by b.id having qty_milli > 0 order by b.expiry_date, p.name`).all(limit) as Row[]).map((x) => ({ ...x, expired: x.expiry_date < today })) as ExpiringBatch[];
}

// ---- money owed, cash-ups ----

export interface Receivables { by_currency: { currency: string; owed_minor: number; customers: number }[]; debtors: { customer_id: string; name: string; phone: string | null; currency: string; owed_minor: number }[] }
export function receivables(db: DatabaseSync, top = 50): Receivables {
  const rows = db.prepare(`select c.id, c.name, c.phone, l.currency, sum(l.amount_minor) as owed from customer_ledger l join customers c on c.id = l.customer_id
      where c.deleted_at is null group by c.id, l.currency having owed > 0 order by owed desc`).all() as Row[];
  const per = new Map<string, { currency: string; owed_minor: number; customers: number }>();
  for (const r of rows) { const e = per.get(r.currency) ?? { currency: r.currency, owed_minor: 0, customers: 0 }; e.owed_minor += r.owed; e.customers++; per.set(r.currency, e); }
  return { by_currency: [...per.values()].sort((a, b) => a.currency.localeCompare(b.currency)), debtors: rows.slice(0, top).map((r) => ({ customer_id: r.id, name: r.name, phone: r.phone ?? null, currency: r.currency, owed_minor: r.owed })) };
}

export interface CashUpRow { shift_id: string; user: string | null; opened_at: number; closed_at: number; currencies: { currency: string; expected_minor: number; counted_minor: number; difference_minor: number }[] }
export function cashUps(db: DatabaseSync, r: Range): CashUpRow[] {
  return (db.prepare("select s.*, u.name as user_name from shifts s left join users u on u.id = s.user_id where s.status = 'closed' and s.closed_at >= ? and s.closed_at < ? order by s.closed_at desc").all(r.from, r.to) as Row[]).map((s) => ({
    shift_id: s.id, user: s.user_name ?? null, opened_at: s.opened_at, closed_at: s.closed_at,
    currencies: (db.prepare('select currency, expected_minor, counted_minor, difference_minor from shift_cash where shift_id = ? order by currency').all(s.id) as Row[]).map((c) => ({ ...c })) as any,
  }));
}
