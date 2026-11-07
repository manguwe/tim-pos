/**
 * Suppliers, purchase orders, goods received, supplier returns and supplier payments.
 * Reference implementation; app/lib/purchasing/purchasing_repository.dart is a port.
 *
 * What we owe a supplier is kept in the currency it was agreed in (supplier_ledger, positive = we owe).
 *   goods received  adds the value of the goods to the debt       (ledger type 'purchase')
 *   supplier return takes the value of what went back off it      (ledger type 'return')
 *   payment         reduces it; it may be paid in another currency at today's rate (ledger type 'payment')
 * Stock cost is kept in the shop's base currency: a cost paid in another currency is converted at the rate of the day,
 * and the product's cost moves to the weighted average like any other purchase (see stockIn in setup.ts).
 *
 * A purchase order is a plan, not a debt: nothing is owed and no stock moves until the goods are received.
 * Orders go draft -> sent -> partly_received -> received. A line cannot be over-received; receive extra on a new receipt without an order.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, stockIn, type SetupContext } from './setup.ts';
import { hasPermission, type Permission } from './auth.ts';
import { lineAmount, convertMinor } from './money.ts';
import { rateBetween, currencyRow, applyPayment } from './customers.ts';

type Row = Record<string, any>;
type Ctx = SetupContext & { receipt_prefix: string };

function allow(db: DatabaseSync, ctx: SetupContext, p: Permission = 'stock.receive') {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, p)) throw new SetupError('forbidden', 'You are not allowed to do that.');
}
const isMinor = (n: unknown) => Number.isSafeInteger(n) && (n as number) >= 0 && (n as number) <= 10_000_000_000;
const isQty = (n: unknown) => Number.isSafeInteger(n) && (n as number) > 0 && (n as number) <= 1_000_000_000;
const clean = (v: unknown, max = 200) => { const t = typeof v === 'string' ? v.replace(/\s+/g, ' ').trim() : ''; return t === '' ? null : t.slice(0, max); };

function validDate(s: unknown): s is string {
  if (typeof s !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
  const d = new Date(s + 'T00:00:00Z');
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === s && d.getUTCFullYear() >= 2000;
}

// ---- suppliers ----

export interface SupplierInput { id?: string; name: string; phone?: string | null; address?: string | null; terms?: string | null; is_active?: boolean }

export function saveSupplier(db: DatabaseSync, ctx: SetupContext, s: SupplierInput, newId: () => string = randomUUID): string {
  allow(db, ctx);
  const name = clean(s.name, 100);
  if (!name) throw new SetupError('name_needed', 'Enter the supplier\'s name.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const dup = w.get('select id from suppliers where deleted_at is null and lower(name) = lower(?) and id is not ?', name, s.id ?? null);
    if (dup) throw new SetupError('duplicate_supplier', 'You already have a supplier with that name.');
    const row = { name, phone: clean(s.phone, 40), address: clean(s.address, 200), terms: clean(s.terms, 120), is_active: s.is_active === false ? 0 : 1 };
    if (s.id) {
      if (!w.get('select 1 as x from suppliers where id = ? and deleted_at is null', s.id)) throw new SetupError('not_found', 'That supplier was not found.');
      w.edit('suppliers', s.id, row);
      return s.id;
    }
    return w.addVersioned('suppliers', row);
  });
}

export function owedToSupplier(db: DatabaseSync, supplierId: string): { currency: string; amount_minor: number }[] {
  return (db.prepare('select currency, sum(amount_minor) as a from supplier_ledger where supplier_id = ? group by currency having a <> 0 order by currency').all(supplierId) as Row[])
    .map((r) => ({ currency: r.currency, amount_minor: r.a }));
}

export interface SupplierSummary { id: string; name: string; phone: string | null; terms: string | null; is_active: boolean; owes: { currency: string; amount_minor: number }[] }

export function listSuppliers(db: DatabaseSync, o: { search?: string; only_owed?: boolean; include_inactive?: boolean } = {}): SupplierSummary[] {
  const q = (o.search ?? '').trim();
  const like = `%${q.replace(/[\\%_]/g, (m) => '\\' + m)}%`;
  const rows = db.prepare(`select * from suppliers where deleted_at is null ${o.include_inactive ? '' : 'and is_active = 1'} ${q ? "and (name like ? escape '\\' or phone like ? escape '\\')" : ''} order by name collate nocase limit 300`)
    .all(...(q ? [like, like] : [])) as Row[];
  const out = rows.map((r) => ({ id: r.id, name: r.name, phone: r.phone ?? null, terms: r.terms ?? null, is_active: r.is_active === 1, owes: owedToSupplier(db, r.id) }));
  return o.only_owed ? out.filter((s) => s.owes.some((x) => x.amount_minor > 0)) : out;
}

export interface SupplierStatementLine { at: number; type: string; currency: string; amount_minor: number; balance_minor: number; ref: string | null }

/** Every movement on the supplier's account, oldest first, with the running balance per currency. */
export function supplierStatement(db: DatabaseSync, supplierId: string): SupplierStatementLine[] {
  const bal = new Map<string, number>();
  return (db.prepare('select * from supplier_ledger where supplier_id = ? order by created_at, rowid').all(supplierId) as Row[]).map((r) => {
    const b = (bal.get(r.currency) ?? 0) + r.amount_minor;
    bal.set(r.currency, b);
    let ref: string | null = null;
    if (r.ref_type === 'goods_received') ref = (db.prepare('select receipt_ref from goods_received where id = ?').get(r.ref_id) as Row | undefined)?.receipt_ref ?? null;
    else if (r.ref_type === 'supplier_payment') ref = (db.prepare('select reference from supplier_payments where id = ?').get(r.ref_id) as Row | undefined)?.reference ?? null;
    return { at: r.created_at, type: r.type, currency: r.currency, amount_minor: r.amount_minor, balance_minor: b, ref };
  });
}

/** What this supplier last charged for a product (in the currency it was charged in), for filling in orders. */
export function lastCost(db: DatabaseSync, supplierId: string, productId: string): { cost_minor: number; currency: string } | undefined {
  const r = db.prepare('select last_cost_minor, cost_currency from supplier_products where supplier_id = ? and product_id = ? and deleted_at is null').get(supplierId, productId) as Row | undefined;
  return r && r.last_cost_minor != null ? { cost_minor: r.last_cost_minor, currency: r.cost_currency } : undefined;
}

// ---- purchase orders ----

export interface PoLineInput { product_id: string; qty_milli: number; cost_minor: number }
export interface PoLine { line_id: string; product_id: string; product: string; qty_milli: number; received_milli: number; remaining_milli: number; cost_minor: number; line_total_minor: number }
export interface PoDetail { id: string; order_no: string; supplier_id: string; supplier: string; branch_id: string | null; status: string; currency: string; ordered_at: number | null; expected_at: number | null; total_minor: number; lines: PoLine[] }

function nextOrderNo(db: DatabaseSync, prefix: string): string {
  db.prepare(`insert into receipt_counters (kind, last_no) values ('purchase_order', 1) on conflict (kind) do update set last_no = last_no + 1`).run();
  const n = (db.prepare("select last_no from receipt_counters where kind = 'purchase_order'").get() as Row).last_no;
  return `${prefix}-PO${String(n).padStart(6, '0')}`;
}

function checkPoLines(w: Writer, lines: PoLineInput[]) {
  if (!Array.isArray(lines) || lines.length === 0) throw new SetupError('no_lines', 'Add at least one product.');
  if (lines.length > 200) throw new SetupError('too_many_lines', 'An order can have at most 200 lines.');
  const seen = new Set<string>();
  for (const l of lines) {
    if (!isQty(l.qty_milli)) throw new SetupError('bad_quantity', 'Quantity must be more than zero.');
    if (!isMinor(l.cost_minor)) throw new SetupError('bad_amount', 'The cost must be zero or more.');
    const p = w.get('select name, track_stock from products where id = ? and deleted_at is null', l.product_id);
    if (!p) throw new SetupError('not_found', 'A product on the order was not found.');
    if (seen.has(l.product_id)) throw new SetupError('duplicate_line', `${p.name} is on the order twice.`);
    seen.add(l.product_id);
  }
}

export function createPurchaseOrder(db: DatabaseSync, ctx: Ctx, i: { supplier_id: string; branch_id: string; currency: string; expected_at?: number | null; lines: PoLineInput[] }, newId: () => string = randomUUID): { order_id: string; order_no: string } {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from suppliers where id = ? and deleted_at is null and is_active = 1', i.supplier_id)) throw new SetupError('unknown_supplier', 'That supplier was not found.');
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', i.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    currencyRow(db, i.currency);
    checkPoLines(w, i.lines);
    const order_no = nextOrderNo(db, ctx.receipt_prefix);
    const order_id = w.addVersioned('purchase_orders', { supplier_id: i.supplier_id, branch_id: i.branch_id, order_no, status: 'draft', currency: i.currency, ordered_at: null, expected_at: i.expected_at ?? null });
    for (const l of i.lines) w.addVersioned('purchase_order_lines', { purchase_order_id: order_id, product_id: l.product_id, unit_id: null, qty_milli: l.qty_milli, cost_minor: l.cost_minor });
    return { order_id, order_no };
  });
}

/** Changes a draft order: the expected date and/or the whole list of lines. */
export function updatePurchaseOrder(db: DatabaseSync, ctx: SetupContext, orderId: string, i: { expected_at?: number | null; lines?: PoLineInput[] }, newId: () => string = randomUUID) {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const po = w.get('select * from purchase_orders where id = ? and deleted_at is null', orderId);
    if (!po) throw new SetupError('not_found', 'That order was not found.');
    if (po.status !== 'draft') throw new SetupError('order_locked', 'Only a draft order can be changed.');
    if (i.lines) {
      checkPoLines(w, i.lines);
      for (const old of w.all('select id from purchase_order_lines where purchase_order_id = ? and deleted_at is null', orderId)) w.edit('purchase_order_lines', old.id, { deleted_at: ctx.now });
      for (const l of i.lines) w.addVersioned('purchase_order_lines', { purchase_order_id: orderId, product_id: l.product_id, unit_id: null, qty_milli: l.qty_milli, cost_minor: l.cost_minor });
    }
    if ('expected_at' in i) w.edit('purchase_orders', orderId, { expected_at: i.expected_at ?? null });
  });
}

function setStatus(db: DatabaseSync, ctx: SetupContext, orderId: string, from: string[], to: string, msg: string, extra: Row, newId: () => string) {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const po = w.get('select status from purchase_orders where id = ? and deleted_at is null', orderId);
    if (!po) throw new SetupError('not_found', 'That order was not found.');
    if (!from.includes(po.status)) throw new SetupError('bad_status', msg);
    w.edit('purchase_orders', orderId, { status: to, ...extra });
  });
}

export const sendPurchaseOrder = (db: DatabaseSync, ctx: SetupContext, orderId: string, newId: () => string = randomUUID) =>
  setStatus(db, ctx, orderId, ['draft'], 'sent', 'Only a draft order can be sent.', { ordered_at: ctx.now }, newId);

/** Cancels an order that has received nothing. */
export function cancelPurchaseOrder(db: DatabaseSync, ctx: SetupContext, orderId: string, newId: () => string = randomUUID) {
  const got = db.prepare('select 1 as x from goods_received where purchase_order_id = ? limit 1').get(orderId);
  if (got) throw new SetupError('already_received', 'Some of this order was already received. Close it instead.');
  setStatus(db, ctx, orderId, ['draft', 'sent'], 'cancelled', 'This order cannot be cancelled.', {}, newId);
}

/** Closes an order that will not be delivered in full: what arrived is all there will be. */
export const closePurchaseOrder = (db: DatabaseSync, ctx: SetupContext, orderId: string, newId: () => string = randomUUID) =>
  setStatus(db, ctx, orderId, ['partly_received'], 'received', 'Only a partly received order can be closed.', {}, newId);

function receivedByProduct(db: DatabaseSync, orderId: string): Map<string, number> {
  return new Map((db.prepare(`select l.product_id, sum(l.qty_milli) as q from goods_received_lines l join goods_received g on g.id = l.goods_received_id where g.purchase_order_id = ? group by l.product_id`).all(orderId) as Row[]).map((r) => [r.product_id, r.q]));
}

export function purchaseOrder(db: DatabaseSync, orderId: string): PoDetail {
  const po = db.prepare('select o.*, s.name as supplier from purchase_orders o join suppliers s on s.id = o.supplier_id where o.id = ? and o.deleted_at is null').get(orderId) as Row | undefined;
  if (!po) throw new SetupError('not_found', 'That order was not found.');
  const got = receivedByProduct(db, orderId);
  const lines = (db.prepare(`select l.id, l.product_id, p.name as product, l.qty_milli, l.cost_minor from purchase_order_lines l join products p on p.id = l.product_id
      where l.purchase_order_id = ? and l.deleted_at is null order by p.name, l.rowid`).all(orderId) as Row[]).map((l): PoLine => {
    const r = got.get(l.product_id) ?? 0;
    return { line_id: l.id, product_id: l.product_id, product: l.product, qty_milli: l.qty_milli, received_milli: r, remaining_milli: Math.max(0, l.qty_milli - r), cost_minor: l.cost_minor ?? 0, line_total_minor: lineAmount(l.qty_milli, l.cost_minor ?? 0) };
  });
  return { id: po.id, order_no: po.order_no, supplier_id: po.supplier_id, supplier: po.supplier, branch_id: po.branch_id ?? null, status: po.status, currency: po.currency, ordered_at: po.ordered_at ?? null, expected_at: po.expected_at ?? null, total_minor: lines.reduce((a, l) => a + l.line_total_minor, 0), lines };
}

export interface PoRow { id: string; order_no: string; supplier: string; status: string; currency: string; total_minor: number; ordered_at: number | null; expected_at: number | null }

export function listPurchaseOrders(db: DatabaseSync, o: { statuses?: string[]; supplier_id?: string } = {}): PoRow[] {
  const where: string[] = ['o.deleted_at is null']; const args: any[] = [];
  if (o.statuses?.length) { where.push(`o.status in (${o.statuses.map(() => '?').join(',')})`); args.push(...o.statuses); }
  if (o.supplier_id) { where.push('o.supplier_id = ?'); args.push(o.supplier_id); }
  return (db.prepare(`select o.id, o.order_no, s.name as supplier, o.status, o.currency, o.ordered_at, o.expected_at, o.created_at
      from purchase_orders o join suppliers s on s.id = o.supplier_id where ${where.join(' and ')} order by o.created_at desc, o.rowid desc limit 300`).all(...args) as Row[])
    .map((r) => ({ id: r.id, order_no: r.order_no, supplier: r.supplier, status: r.status, currency: r.currency, total_minor: purchaseOrder(db, r.id).total_minor, ordered_at: r.ordered_at ?? null, expected_at: r.expected_at ?? null }));
}

// ---- goods received ----

export interface ReceiveLine { product_id: string; qty_milli: number; cost_minor: number; batch_code?: string | null; expiry_date?: string | null }
export interface ReceiveResult { goods_received_id: string; total_minor: number; order_status: string | null }

/** Cost per unit in the shop's base currency, from a cost in `currency`. */
function toBaseCost(db: DatabaseSync, cost: number, currency: string, base: string, now: number): number {
  if (currency === base) return cost;
  return convertMinor(cost, rateBetween(db, currency, base, now), currencyRow(db, currency).minor_units, currencyRow(db, base).minor_units);
}

function findOrCreateBatch(w: Writer, branchId: string, productId: string, code: string | null, expiry: string | null): string | null {
  if (!code && !expiry) return null;
  const found = w.get("select id from stock_batches where product_id = ? and branch_id = ? and coalesce(batch_code, '') = ? and coalesce(expiry_date, '') = ? and deleted_at is null", productId, branchId, code ?? '', expiry ?? '');
  if (found) return found.id;
  return w.addVersioned('stock_batches', { product_id: productId, branch_id: branchId, batch_code: code, expiry_date: expiry, received_at: w.ctx.now });
}

/**
 * Goods arrive from a supplier, with or without an order. Stock goes up (by batch when a batch code or expiry is given),
 * the product's cost moves, what we owe the supplier goes up by the value, and the order (if any) is updated.
 */
export function receiveGoods(
  db: DatabaseSync, ctx: SetupContext,
  i: { supplier_id: string; branch_id: string; purchase_order_id?: string | null; receipt_ref?: string | null; currency: string; lines: ReceiveLine[]; invoice?: { invoice_no?: string | null; due_date?: string | null } | null },
  newId: () => string = randomUUID,
): ReceiveResult {
  allow(db, ctx);
  if (!Array.isArray(i.lines) || i.lines.length === 0) throw new SetupError('no_lines', 'Add at least one product.');
  if (i.lines.length > 200) throw new SetupError('too_many_lines', 'A receipt can have at most 200 lines.');
  if (i.invoice?.due_date && !validDate(i.invoice.due_date)) throw new SetupError('bad_date', 'The due date is not valid.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const sup = w.get('select * from suppliers where id = ? and deleted_at is null', i.supplier_id);
    if (!sup) throw new SetupError('unknown_supplier', 'That supplier was not found.');
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', i.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    const cur = currencyRow(db, i.currency);
    void cur;
    const base = w.get('select base_currency from shops where deleted_at is null limit 1')!.base_currency as string;
    let po: Row | undefined; let poLines = new Map<string, number>(); let got = new Map<string, number>();
    if (i.purchase_order_id) {
      po = w.get('select * from purchase_orders where id = ? and deleted_at is null', i.purchase_order_id);
      if (!po) throw new SetupError('not_found', 'That order was not found.');
      if (po.supplier_id !== i.supplier_id) throw new SetupError('wrong_supplier', 'That order is for a different supplier.');
      if (!['sent', 'partly_received'].includes(po.status)) throw new SetupError('order_not_open', 'That order is not waiting for goods. Send it first.');
      if (po.currency !== i.currency) throw new SetupError('wrong_currency', `That order is in ${po.currency}.`);
      poLines = new Map(w.all('select product_id, qty_milli from purchase_order_lines where purchase_order_id = ? and deleted_at is null', po.id).map((l) => [l.product_id, l.qty_milli]));
      got = receivedByProduct(db, po.id);
    }
    const asked = new Map<string, number>();
    let total = 0;
    const prepared: { l: ReceiveLine; batch_code: string | null; expiry: string | null; name: string }[] = [];
    for (const l of i.lines) {
      if (!isQty(l.qty_milli)) throw new SetupError('bad_quantity', 'Quantity must be more than zero.');
      if (!isMinor(l.cost_minor)) throw new SetupError('bad_amount', 'The cost must be zero or more.');
      const p = w.get('select name, track_stock from products where id = ? and deleted_at is null', l.product_id);
      if (!p) throw new SetupError('not_found', 'A product on the receipt was not found.');
      if (p.track_stock !== 1) throw new SetupError('not_tracked', `${p.name} does not keep stock.`);
      const code = clean(l.batch_code, 40); const expiry = l.expiry_date ? l.expiry_date : null;
      if (expiry && !validDate(expiry)) throw new SetupError('bad_date', `The expiry date for ${p.name} is not valid.`);
      if (po) {
        const ordered = poLines.get(l.product_id);
        if (ordered == null) throw new SetupError('not_on_order', `${p.name} is not on that order.`);
        const remaining = ordered - (got.get(l.product_id) ?? 0) - (asked.get(l.product_id) ?? 0);
        if (l.qty_milli > remaining) throw new SetupError('over_received', `Only ${qtyText(Math.max(remaining, 0))} of ${p.name} still to come on this order.`);
        asked.set(l.product_id, (asked.get(l.product_id) ?? 0) + l.qty_milli);
      }
      total += lineAmount(l.qty_milli, l.cost_minor);
      prepared.push({ l, batch_code: code, expiry, name: p.name });
    }
    const receipt_ref = clean(i.receipt_ref, 60);
    const grn = w.add('goods_received', { supplier_id: i.supplier_id, branch_id: i.branch_id, purchase_order_id: po?.id ?? null, receipt_ref, currency: i.currency, received_at: ctx.now });
    for (const { l, batch_code, expiry } of prepared) {
      w.add('goods_received_lines', { goods_received_id: grn, product_id: l.product_id, batch_code, expiry_date: expiry, qty_milli: l.qty_milli, cost_minor: l.cost_minor });
      const batch = findOrCreateBatch(w, i.branch_id, l.product_id, batch_code, expiry);
      stockIn(db, w, { branch_id: i.branch_id, product_id: l.product_id, qty_milli: l.qty_milli, unit_cost_minor: toBaseCost(db, l.cost_minor, i.currency, base, ctx.now), batch_id: batch, ref_type: 'goods_received', ref_id: grn });
      const sp = w.get('select id from supplier_products where supplier_id = ? and product_id = ? and deleted_at is null', i.supplier_id, l.product_id);
      if (sp) w.edit('supplier_products', sp.id, { last_cost_minor: l.cost_minor, cost_currency: i.currency });
      else w.addVersioned('supplier_products', { supplier_id: i.supplier_id, product_id: l.product_id, supplier_code: null, last_cost_minor: l.cost_minor, cost_currency: i.currency });
    }
    if (total > 0) w.add('supplier_ledger', { supplier_id: i.supplier_id, type: 'purchase', currency: i.currency, amount_minor: total, ref_type: 'goods_received', ref_id: grn });
    const invNo = clean(i.invoice?.invoice_no, 60);
    if (invNo || i.invoice?.due_date) w.addVersioned('supplier_invoices', { supplier_id: i.supplier_id, goods_received_id: grn, invoice_no: invNo, currency: i.currency, amount_minor: total, due_date: i.invoice?.due_date ?? null });
    let order_status: string | null = null;
    if (po) {
      const after = receivedByProduct(db, po.id);
      const done = [...poLines].every(([pid, q]) => (after.get(pid) ?? 0) >= q);
      order_status = done ? 'received' : 'partly_received';
      if (order_status !== po.status) w.edit('purchase_orders', po.id, { status: order_status });
    }
    w.add('audit_log', { user_id: ctx.user_id, action: 'goods_received', table_name: 'goods_received', row_id: grn, after: JSON.stringify({ supplier_id: i.supplier_id, total_minor: total, currency: i.currency, lines: prepared.length }) });
    return { goods_received_id: grn, total_minor: total, order_status };
  });
}

const qtyText = (milli: number) => (milli % 1000 === 0 ? String(milli / 1000) : (milli / 1000).toFixed(3).replace(/0+$/, ''));

// ---- supplier returns ----

export interface SupplierReturnLine { product_id: string; qty_milli: number; cost_minor: number; batch_id?: string | null }

/** Goods go back to the supplier. Stock goes down; unless `credit` is false the value comes off what we owe. */
export function returnToSupplier(
  db: DatabaseSync, ctx: SetupContext,
  i: { supplier_id: string; branch_id: string; currency: string; lines: SupplierReturnLine[]; reason: string; credit?: boolean },
  newId: () => string = randomUUID,
): { return_id: string; total_minor: number } {
  allow(db, ctx);
  const reason = clean(i.reason, 200);
  if (!reason) throw new SetupError('reason_needed', 'Give a reason.');
  if (!Array.isArray(i.lines) || i.lines.length === 0) throw new SetupError('no_lines', 'Add at least one product.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from suppliers where id = ? and deleted_at is null', i.supplier_id)) throw new SetupError('unknown_supplier', 'That supplier was not found.');
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', i.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    currencyRow(db, i.currency);
    const base = w.get('select base_currency from shops where deleted_at is null limit 1')!.base_currency as string;
    const return_id = newId();
    const asked = new Map<string, number>();
    let total = 0;
    for (const l of i.lines) {
      if (!isQty(l.qty_milli)) throw new SetupError('bad_quantity', 'Quantity must be more than zero.');
      if (!isMinor(l.cost_minor)) throw new SetupError('bad_amount', 'The cost must be zero or more.');
      const p = w.get('select name from products where id = ? and deleted_at is null', l.product_id);
      if (!p) throw new SetupError('not_found', 'A product on the return was not found.');
      const batch = l.batch_id ?? null;
      if (batch && !w.get('select 1 as x from stock_batches where id = ? and product_id = ? and deleted_at is null', batch, l.product_id)) throw new SetupError('unknown_batch', 'That batch was not found.');
      const key = `${l.product_id}|${batch ?? ''}`;
      const have = (w.get('select coalesce(sum(qty_milli), 0) as q from stock_levels where branch_id = ? and product_id = ? and batch_key = ?', i.branch_id, l.product_id, batch ?? '')!.q as number) - (asked.get(key) ?? 0);
      if (l.qty_milli > have) throw new SetupError('not_enough_stock', `Only ${qtyText(Math.max(have, 0))} of ${p.name} on the shelf${batch ? ' in that batch' : ''}.`);
      asked.set(key, (asked.get(key) ?? 0) + l.qty_milli);
      w.add('stock_movements', { branch_id: i.branch_id, product_id: l.product_id, batch_id: batch, type: 'supplier_return', qty_milli: -l.qty_milli, unit_cost_minor: toBaseCost(db, l.cost_minor, i.currency, base, ctx.now), cost_currency: base, ref_type: 'supplier_return', ref_id: return_id, reason });
      total += lineAmount(l.qty_milli, l.cost_minor);
    }
    if (i.credit !== false && total > 0) w.add('supplier_ledger', { supplier_id: i.supplier_id, type: 'return', currency: i.currency, amount_minor: -total, ref_type: 'supplier_return', ref_id: return_id });
    w.add('audit_log', { user_id: ctx.user_id, action: 'supplier_return', table_name: 'stock_movements', row_id: return_id, after: JSON.stringify({ supplier_id: i.supplier_id, total_minor: total, currency: i.currency, credit: i.credit !== false, reason }) });
    return { return_id, total_minor: total };
  });
}

// ---- paying suppliers ----

export interface SupplierPayInput { supplier_id: string; debt_currency: string; method_code: string; currency: string; amount_minor: number; reference?: string | null }
export interface SupplierPayResult { payment_id: string; applied_minor: number; debt_currency: string; balance_after_minor: number; cash_out_recorded: boolean }

/**
 * Pays what we owe a supplier in `debt_currency`. The money may be handed over in another currency; it is converted at today's rate.
 * Paying more than is owed is refused (the same rule as customer payments). A cash payment made by someone with an open shift
 * is also written to that shift as cash out, so the cash-up still adds up.
 */
export function paySupplier(db: DatabaseSync, ctx: SetupContext, i: SupplierPayInput, newId: () => string = randomUUID): SupplierPayResult {
  allow(db, ctx, 'supplier.pay');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const sup = w.get('select name from suppliers where id = ? and deleted_at is null', i.supplier_id);
    if (!sup) throw new SetupError('unknown_supplier', 'That supplier was not found.');
    const owed = (w.get('select coalesce(sum(amount_minor), 0) as b from supplier_ledger where supplier_id = ? and currency = ?', i.supplier_id, i.debt_currency)!.b as number);
    const a = applyPayment(db, { ...ctx, receipt_prefix: '' }, { method_code: i.method_code, currency: i.currency, amount_minor: i.amount_minor, reference: i.reference }, i.debt_currency, owed);
    const payment_id = w.add('supplier_payments', {
      supplier_id: i.supplier_id, currency: i.currency, amount_minor: i.amount_minor, method_code: i.method_code, reference: clean(i.reference, 60),
      target_currency: i.debt_currency, applied_minor: a.applied, rate_to_target_micro: a.rate, user_id: ctx.user_id,
    });
    w.add('supplier_ledger', { supplier_id: i.supplier_id, type: 'payment', currency: i.debt_currency, amount_minor: -a.applied, ref_type: 'supplier_payment', ref_id: payment_id });
    let cash_out_recorded = false;
    const method = w.get('select kind from payment_methods where code = ?', i.method_code);
    const shift = ctx.user_id ? w.get("select id from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1", ctx.user_id) : undefined;
    if (method?.kind === 'cash' && shift) {
      w.add('cash_events', { shift_id: shift.id, currency: i.currency, type: 'cash_out', amount_minor: i.amount_minor, reason: `Supplier: ${sup.name}` });
      cash_out_recorded = true;
    }
    w.add('audit_log', { user_id: ctx.user_id, action: 'supplier_payment', table_name: 'supplier_payments', row_id: payment_id, after: JSON.stringify({ supplier_id: i.supplier_id, applied_minor: a.applied, currency: i.debt_currency }) });
    return { payment_id, applied_minor: a.applied, debt_currency: i.debt_currency, balance_after_minor: owed - a.applied, cash_out_recorded };
  });
}
