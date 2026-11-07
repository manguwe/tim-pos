/**
 * Returns, refunds and voids. Reference implementation; app/lib/returns/return_repository.dart is a port.
 *
 * Nothing already written is changed (sales and payments are append-only). A return adds rows:
 *   sale_returns + sale_return_lines   what came back, and its value in the sale's currency
 *   stock_movements                    goods put back on the shelf (unless marked damaged)
 *   customer_ledger 'refund_credit'    the part taken off what the customer owes on account
 *   return_payouts                     the money handed back (cash, mobile money ...), counted in the cash-up of the shift it was paid out in
 * A void is a return of everything left on the sale plus a sale_voids row; a voided sale drops out of sales figures.
 *
 * Value of a returned part of a line = line total x qty returned / qty sold; the last part takes the remainder so lines always add up.
 * A sale put partly or wholly on account is first taken off the customer's debt (as much as they still owe from it);
 * only the rest is paid back. An uncollected layby can only be voided, and the customer gets back what they have paid.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission, type Permission } from './auth.ts';
import { convertMinor, divRound, invertRate } from './money.ts';
import { laybyPaid } from './customers.ts';

type Row = Record<string, any>;
type Ctx = SetupContext & { receipt_prefix: string };

export interface ReturnItem { sale_line_id: string; qty_milli: number; restock?: boolean }
export interface Payout { method_code: string; currency: string; amount_minor: number; reference?: string | null }

export interface ReturnableLine { sale_line_id: string; description: string; qty_milli: number; returned_milli: number; remaining_milli: number; line_total_minor: number; remaining_value_minor: number }
export interface ReturnPreview { currency: string; value_minor: number; credit_part_minor: number; payout_due_minor: number; layby: boolean; items: { sale_line_id: string; qty_milli: number; amount_minor: number }[] }
export interface ReturnResult { return_id: string; receipt_no: string; kind: 'return' | 'void'; value_minor: number; credit_part_minor: number; payout_minor: number; opens_drawer: boolean }

const err = (code: string, message: string) => new SetupError(code, message);

function isVoided(db: DatabaseSync, saleId: string): boolean {
  return !!db.prepare('select 1 as x from sale_voids where sale_id = ?').get(saleId);
}

function lineState(db: DatabaseSync, saleId: string): ReturnableLine[] {
  const lines = db.prepare('select * from sale_lines where sale_id = ? order by created_at, rowid').all(saleId) as Row[];
  return lines.map((l) => {
    const r = db.prepare('select coalesce(sum(qty_milli), 0) as q, coalesce(sum(amount_minor), 0) as a from sale_return_lines where sale_line_id = ?').get(l.id) as Row;
    return {
      sale_line_id: l.id, description: l.description ?? '', qty_milli: l.qty_milli, returned_milli: r.q, remaining_milli: l.qty_milli - r.q,
      line_total_minor: l.line_total_minor, remaining_value_minor: l.line_total_minor - r.a,
    };
  });
}

export function returnableLines(db: DatabaseSync, saleId: string): ReturnableLine[] {
  if (isVoided(db, saleId)) return lineState(db, saleId).map((l) => ({ ...l, remaining_milli: 0, remaining_value_minor: 0 }));
  return lineState(db, saleId);
}

function rate(db: DatabaseSync, from: string, to: string, now: number): number {
  if (from === to) return 1_000_000;
  const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
  const d = db.prepare(q).get(from, to, now) as Row | undefined;
  if (d) return d.rate_micro;
  const i = db.prepare(q).get(to, from, now) as Row | undefined;
  if (!i) throw err('no_rate', `No exchange rate between ${from} and ${to}.`);
  return invertRate(i.rate_micro);
}
function currencyRow(db: DatabaseSync, code: string): Row {
  const c = db.prepare('select * from currencies where code = ? and deleted_at is null').get(code) as Row | undefined;
  if (!c) throw err('unknown_currency', `Currency ${code} is not set up.`);
  return c;
}

function plan(db: DatabaseSync, ctx: Ctx, saleId: string, items: ReturnItem[], kind: 'return' | 'void'): ReturnPreview & { sale: Row; lines: Map<string, ReturnableLine> } {
  const sale = db.prepare('select * from sales where id = ?').get(saleId) as Row | undefined;
  if (!sale) throw err('unknown_sale', 'That sale was not found.');
  if (isVoided(db, saleId)) throw err('already_voided', 'That sale was already voided.');
  const layby = sale.status === 'layby';
  const collected = layby && !!db.prepare("select 1 as x from layby_payments where sale_id = ? and payment_id is null and due_note = 'collected'").get(saleId);
  const openLayby = layby && !collected;
  if (openLayby && kind !== 'void') throw err('layby_void_only', 'A layby that has not been collected can only be cancelled (voided).');
  if (kind === 'void' && collected) throw err('collected', 'The goods were already handed over. Use a return instead.');
  const state = new Map(lineState(db, saleId).map((l) => [l.sale_line_id, l]));
  if (items.length === 0) throw err('nothing_to_return', 'Choose what is coming back.');
  const seen = new Set<string>();
  const out: ReturnPreview['items'] = [];
  let value = 0;
  for (const it of items) {
    const l = state.get(it.sale_line_id);
    if (!l) throw err('unknown_line', 'That item is not on this sale.');
    if (seen.has(it.sale_line_id)) throw err('duplicate_line', 'An item is listed twice.');
    seen.add(it.sale_line_id);
    if (!Number.isSafeInteger(it.qty_milli) || it.qty_milli <= 0) throw err('bad_quantity', 'Quantity must be more than zero.');
    if (it.qty_milli > l.remaining_milli) throw err('too_many', `Only ${l.remaining_milli / 1000} of ${l.description} can still be returned.`);
    const amount = it.qty_milli === l.remaining_milli ? l.remaining_value_minor : divRound(l.line_total_minor * it.qty_milli, l.qty_milli);
    out.push({ sale_line_id: it.sale_line_id, qty_milli: it.qty_milli, amount_minor: amount });
    value += amount;
  }
  if (kind === 'void' && [...state.values()].some((l) => l.remaining_milli > 0 && !seen.has(l.sale_line_id))) throw err('void_all', 'A void takes back everything on the sale.');

  const cur = sale.sale_currency as string;
  let credit = 0;
  if (!openLayby && sale.customer_id) {
    const remain = (db.prepare(`select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ? and type in ('credit_sale', 'refund_credit')
        and ((ref_type = 'sale' and ref_id = ?) or (ref_type = 'return' and ref_id in (select id from sale_returns where original_sale_id = ?)))`).get(sale.customer_id, cur, saleId, saleId) as Row).s as number;
    const owedNow = (db.prepare('select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ?').get(sale.customer_id, cur) as Row).s as number;
    credit = Math.max(0, Math.min(value, remain, owedNow));
  }
  let due = value - credit;
  if (openLayby) due = Math.min(value, laybyPaid(db, saleId, cur, ctx.now)); // they get back what they have paid
  return { currency: cur, value_minor: value, credit_part_minor: credit, payout_due_minor: due, layby: openLayby, items: out, sale, lines: state };
}

/** What a return would come to, without saving anything. */
export function previewReturn(db: DatabaseSync, ctx: Ctx, saleId: string, items: ReturnItem[], kind: 'return' | 'void' = 'return'): ReturnPreview {
  const { sale: _s, lines: _l, ...p } = plan(db, ctx, saleId, items, kind);
  return p;
}

/** A starting point for the payout: the one non-cash method the sale was paid with, otherwise cash in the sale currency. */
export function suggestPayout(db: DatabaseSync, saleId: string, dueMinor: number): Payout[] {
  if (dueMinor <= 0) return [];
  const sale = db.prepare('select sale_currency from sales where id = ?').get(saleId) as Row | undefined;
  if (!sale) return [];
  const methods = db.prepare(`select distinct sp.method_code, pm.kind from sale_payments sp left join payment_methods pm on pm.code = sp.method_code where sp.sale_id = ? and sp.is_change = 0`).all(saleId) as Row[];
  const non = methods.filter((m) => m.kind !== 'cash');
  const one = methods.length === 1 && non.length === 1 ? non[0]! : null;
  const code = one ? one.method_code : 'cash';
  const cur = sale.sale_currency;
  return [{ method_code: code, currency: cur, amount_minor: dueMinor, reference: null }];
}

function checkPayouts(db: DatabaseSync, ctx: Ctx, saleCur: string, due: number, payouts: Payout[]): { rows: (Payout & { rate: number; drawer: boolean })[] } {
  if (due <= 0) {
    if (payouts.length > 0) throw err('nothing_to_pay', 'Nothing is to be paid back for this return.');
    return { rows: [] };
  }
  if (payouts.length === 0) throw err('payout_needed', 'Say how the money is paid back.');
  let total = 0; let tol = 1;
  const rows: (Payout & { rate: number; drawer: boolean })[] = [];
  const saleRow = currencyRow(db, saleCur);
  for (const p of payouts) {
    if (!Number.isSafeInteger(p.amount_minor) || p.amount_minor <= 0) throw err('bad_payment', 'A payment must be more than zero.');
    const m = db.prepare('select * from payment_methods where code = ? and deleted_at is null').get(p.method_code) as Row | undefined;
    if (!m) throw err('unknown_method', `Payment method ${p.method_code} is not set up.`);
    if (m.requires_reference === 1 && !p.reference?.trim()) throw err('reference_needed', `${m.name} needs the confirmation reference.`);
    const c = currencyRow(db, p.currency);
    const r = rate(db, p.currency, saleCur, ctx.now);
    total += p.currency === saleCur ? p.amount_minor : convertMinor(p.amount_minor, r, c.minor_units, saleRow.minor_units);
    const step = Math.max(c.rounding_increment_minor ?? 0, 1);
    tol = Math.max(tol, p.currency === saleCur ? step : convertMinor(step, r, c.minor_units, saleRow.minor_units));
    rows.push({ ...p, rate: r, drawer: m.opens_drawer === 1 });
  }
  if (Math.abs(total - due) >= tol) throw err('payout_mismatch', 'The money paid back does not match what is due.');
  return { rows };
}

function process(db: DatabaseSync, ctx: Ctx, req: { sale_id: string; items: ReturnItem[]; reason: string; payouts: Payout[]; approved_by?: string | null; kind: 'return' | 'void' }, newId: () => string): ReturnResult {
  const need: Permission = req.kind === 'void' ? 'sale.void' : 'sale.refund';
  if (ctx.user_id && !hasPermission(db, ctx.user_id, need) && !(req.approved_by && hasPermission(db, req.approved_by, need))) {
    throw err('forbidden', req.kind === 'void' ? 'Voiding a sale needs a manager\'s approval.' : 'A refund needs a manager\'s approval.');
  }
  const reason = req.reason?.trim();
  if (!reason) throw err('reason_needed', 'Give a reason.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const p = plan(db, ctx, req.sale_id, req.items, req.kind);
    const { rows } = checkPayouts(db, ctx, p.currency, p.payout_due_minor, req.payouts);
    const shift = ctx.user_id ? ((db.prepare("select id from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1").get(ctx.user_id) as Row | undefined)?.id ?? null) : null;
    db.prepare(`insert into receipt_counters (kind, last_no) values ('return', 1) on conflict (kind) do update set last_no = last_no + 1`).run();
    const no = (db.prepare("select last_no from receipt_counters where kind = 'return'").get() as Row).last_no as number;
    const receipt_no = `${ctx.receipt_prefix}-R${String(no).padStart(6, '0')}`;
    const return_id = w.add('sale_returns', {
      original_sale_id: req.sale_id, receipt_no, kind: req.kind, shift_id: shift, reason, refund_method: null, refund_currency: p.currency, refund_minor: p.value_minor, approved_by: req.approved_by ?? null,
    });
    const restockOf = new Map(req.items.map((i) => [i.sale_line_id, i.restock !== false]));
    for (const it of p.items) {
      w.add('sale_return_lines', { return_id, sale_line_id: it.sale_line_id, qty_milli: it.qty_milli, restock: restockOf.get(it.sale_line_id) ? 1 : 0, amount_minor: it.amount_minor });
      if (restockOf.get(it.sale_line_id)) restock(db, w, p.sale, it.sale_line_id, it.qty_milli, req.kind);
    }
    if (p.credit_part_minor > 0) {
      w.add('customer_ledger', { customer_id: p.sale.customer_id, type: 'refund_credit', currency: p.currency, amount_minor: -p.credit_part_minor, ref_type: 'return', ref_id: return_id });
    }
    for (const r of rows) {
      w.add('return_payouts', { return_id, method_code: r.method_code, currency: r.currency, amount_minor: r.amount_minor, rate_to_sale_micro: r.rate, reference: r.reference?.trim() || null });
    }
    if (req.kind === 'void') w.add('sale_voids', { sale_id: req.sale_id, reason, approved_by: req.approved_by ?? null, voided_at: ctx.now });
    w.add('audit_log', { user_id: ctx.user_id, action: req.kind === 'void' ? 'sale_void' : 'sale_return', table_name: 'sales', row_id: req.sale_id, after: JSON.stringify({ return_id, receipt_no, value_minor: p.value_minor, reason }) });
    if (db.prepare("select 1 as x from settings where scope = 'shop' and key = 'fiscal_enabled' and value = '1' and deleted_at is null").get()) {
      w.add('fiscal_documents', { sale_id: req.sale_id, kind: 'credit_note', payload: JSON.stringify({ return_id, receipt_no }), status: 'queued', attempts: 0, updated_at: ctx.now, version: 1 });
    }
    return { return_id, receipt_no, kind: req.kind, value_minor: p.value_minor, credit_part_minor: p.credit_part_minor, payout_minor: p.payout_due_minor, opens_drawer: rows.some((r) => r.drawer) };
  });
}

/** Puts goods back on the shelf, in the batches and at the cost they left it. Bundles put their parts back. */
function restock(db: DatabaseSync, w: Writer, sale: Row, lineId: string, qty: number, kind: 'return' | 'void') {
  const line = db.prepare('select * from sale_lines where id = ?').get(lineId) as Row;
  const prod = db.prepare('select * from products where id = ?').get(line.product_id) as Row | undefined;
  if (!prod) return;
  const parts: { product_id: string; qty: number }[] = [];
  if (prod.kind === 'bundle') {
    for (const bi of db.prepare('select component_product_id, qty_milli from bundle_items where bundle_product_id = ? and deleted_at is null').all(prod.id) as Row[]) {
      parts.push({ product_id: bi.component_product_id, qty: Math.round(bi.qty_milli * qty / 1000) });
    }
  } else parts.push({ product_id: prod.id, qty });
  for (const part of parts) {
    const tracked = db.prepare('select track_stock from products where id = ?').get(part.product_id) as Row | undefined;
    if (!tracked || tracked.track_stock === 0) continue;
    const taken = db.prepare("select batch_id, -qty_milli as q, unit_cost_minor, cost_currency from stock_movements where ref_type = 'sale' and ref_id = ? and product_id = ? and qty_milli < 0 order by rowid").all(sale.id, part.product_id) as Row[];
    let back = (db.prepare("select coalesce(sum(qty_milli), 0) as q from stock_movements where ref_type = 'sale' and ref_id = ? and product_id = ? and qty_milli > 0").get(sale.id, part.product_id) as Row).q as number;
    let left = part.qty;
    for (const t of taken) {
      let avail = t.q as number;
      const skip = Math.min(avail, back); avail -= skip; back -= skip;
      const give = Math.min(avail, left);
      if (give <= 0) continue;
      w.add('stock_movements', { branch_id: sale.branch_id, product_id: part.product_id, batch_id: t.batch_id, type: kind === 'void' ? 'void' : 'sale_return', qty_milli: give, unit_cost_minor: t.unit_cost_minor, cost_currency: t.cost_currency, ref_type: 'sale', ref_id: sale.id });
      left -= give;
    }
    if (left > 0) { // stock was not counted when it was sold (negative stock allowed): put the rest back without a batch
      w.add('stock_movements', { branch_id: sale.branch_id, product_id: part.product_id, batch_id: null, type: kind === 'void' ? 'void' : 'sale_return', qty_milli: left, unit_cost_minor: null, cost_currency: null, ref_type: 'sale', ref_id: sale.id });
    }
  }
}

/** Takes back some items from a completed sale. A manager's approval is needed for cashiers. */
export function processReturn(db: DatabaseSync, ctx: Ctx, req: { sale_id: string; items: ReturnItem[]; reason: string; payouts: Payout[]; approved_by?: string | null }, newId: () => string = randomUUID): ReturnResult {
  return process(db, ctx, { ...req, kind: 'return' }, newId);
}

/** Cancels a sale or an uncollected layby completely. */
export function voidSale(db: DatabaseSync, ctx: Ctx, req: { sale_id: string; reason: string; payouts: Payout[]; approved_by?: string | null }, newId: () => string = randomUUID): ReturnResult {
  const items = returnableLines(db, req.sale_id).filter((l) => l.remaining_milli > 0).map((l) => ({ sale_line_id: l.sale_line_id, qty_milli: l.remaining_milli, restock: true }));
  return process(db, ctx, { ...req, items, kind: 'void' }, newId);
}

export function returnsForSale(db: DatabaseSync, saleId: string): { return_id: string; receipt_no: string; kind: string; value_minor: number; reason: string | null; at: number }[] {
  return (db.prepare('select id, receipt_no, kind, refund_minor, reason, created_at from sale_returns where original_sale_id = ? order by created_at, rowid').all(saleId) as Row[])
    .map((r) => ({ return_id: r.id, receipt_no: r.receipt_no, kind: r.kind, value_minor: r.refund_minor, reason: r.reason ?? null, at: r.created_at }));
}

/** Find a sale by its receipt number, for the returns screen. */
export function findSaleByReceipt(db: DatabaseSync, receiptNo: string): { sale_id: string; receipt_no: string; total_minor: number; currency: string; status: string; voided: boolean; at: number } | undefined {
  const s = db.prepare('select * from sales where receipt_no = ? collate nocase').get(receiptNo.trim()) as Row | undefined;
  return s ? { sale_id: s.id, receipt_no: s.receipt_no, total_minor: s.total_minor, currency: s.sale_currency, status: s.status, voided: isVoided(db, s.id), at: s.completed_at } : undefined;
}
