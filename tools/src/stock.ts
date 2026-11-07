/**
 * Stock adjustments and stock take. Reference implementation; app/lib/stock/stock_repository.dart is a port.
 *
 * Adjustments remove (or add) stock with a reason: damaged, expired, lost or stolen, found, or any other removal.
 * A removal can never take more than is on the shelf. Each one is valued at the product's cost when it is made.
 *
 * Stock take: a snapshot of what the app thinks is on the shelf, then the shelves are counted line by line, then a manager approves.
 * Approval writes one 'count_correction' movement per counted line for (counted - expected at the start), so sales made while
 * counting are kept. Lines that were not counted are left alone. Nothing is changed before approval, and an approved take is final.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission } from './auth.ts';
import { lineAmount } from './money.ts';

type Row = Record<string, any>;

function allow(db: DatabaseSync, ctx: SetupContext) {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, 'stock.adjust')) throw new SetupError('forbidden', 'You are not allowed to adjust stock.');
}

export type AdjustKind = 'damaged' | 'expired' | 'loss' | 'found' | 'other_out';
export const ADJUST_KINDS: { kind: AdjustKind; label: string; type: string; sign: 1 | -1 }[] = [
  { kind: 'damaged', label: 'Damaged', type: 'damaged', sign: -1 },
  { kind: 'expired', label: 'Expired', type: 'expired', sign: -1 },
  { kind: 'loss', label: 'Lost or stolen', type: 'loss', sign: -1 },
  { kind: 'other_out', label: 'Other removal', type: 'adjustment', sign: -1 },
  { kind: 'found', label: 'Found or extra stock', type: 'adjustment', sign: 1 },
];

export interface Bucket { batch_id: string | null; batch_code: string | null; expiry_date: string | null; qty_milli: number }

/** What is on the shelf for a product at a branch, split by batch ('' bucket = no batch). */
export function stockBuckets(db: DatabaseSync, branchId: string, productId: string): Bucket[] {
  return (db.prepare(`select l.batch_key, l.qty_milli, b.batch_code, b.expiry_date from stock_levels l left join stock_batches b on b.id = l.batch_key
      where l.branch_id = ? and l.product_id = ? order by (b.expiry_date is null), b.expiry_date, l.batch_key`).all(branchId, productId) as Row[])
    .map((r) => ({ batch_id: r.batch_key === '' ? null : r.batch_key, batch_code: r.batch_code ?? null, expiry_date: r.expiry_date ?? null, qty_milli: r.qty_milli }));
}

const levelOf = (db: DatabaseSync, branchId: string, productId: string, batchId: string | null): number =>
  (db.prepare('select coalesce(sum(qty_milli), 0) as q from stock_levels where branch_id = ? and product_id = ? and batch_key = ?').get(branchId, productId, batchId ?? '') as Row).q;

export interface AdjustResult { movement_id: string; qty_milli: number; value_minor: number }

export function adjustStock(
  db: DatabaseSync, ctx: SetupContext,
  i: { branch_id: string; product_id: string; batch_id?: string | null; kind: AdjustKind; qty_milli: number; reason: string },
  newId: () => string = randomUUID,
): AdjustResult {
  allow(db, ctx);
  const def = ADJUST_KINDS.find((k) => k.kind === i.kind);
  if (!def) throw new SetupError('bad_kind', 'Choose what happened to the stock.');
  if (!Number.isSafeInteger(i.qty_milli) || i.qty_milli <= 0) throw new SetupError('bad_quantity', 'Quantity must be more than zero.');
  const reason = (i.reason ?? '').trim();
  if (!reason) throw new SetupError('reason_needed', 'Give a reason.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const p = w.get('select * from products where id = ? and deleted_at is null', i.product_id);
    if (!p) throw new SetupError('not_found', 'That product was not found.');
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', i.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    const batch = i.batch_id ?? null;
    if (batch && !w.get('select 1 as x from stock_batches where id = ? and product_id = ? and deleted_at is null', batch, i.product_id)) throw new SetupError('unknown_batch', 'That batch was not found.');
    const have = levelOf(db, i.branch_id, i.product_id, batch);
    if (def.sign < 0 && i.qty_milli > have) throw new SetupError('not_enough_stock', `Only ${qtyText(Math.max(have, 0))} of ${p.name} on the shelf${batch ? ' in that batch' : ''}.`);
    const base = w.get('select base_currency from shops where deleted_at is null limit 1')?.base_currency as string;
    const qty = def.sign * i.qty_milli;
    const movement_id = w.add('stock_movements', { branch_id: i.branch_id, product_id: i.product_id, batch_id: batch, type: def.type, qty_milli: qty, unit_cost_minor: p.cost_minor ?? null, cost_currency: base, ref_type: null, ref_id: null, reason });
    w.add('audit_log', { user_id: ctx.user_id, action: 'stock_adjust', table_name: 'stock_movements', row_id: movement_id, after: JSON.stringify({ kind: i.kind, qty_milli: qty, reason }) });
    return { movement_id, qty_milli: qty, value_minor: p.cost_minor == null ? 0 : lineAmount(qty, p.cost_minor) };
  });
}

export const qtyText = (milli: number) => (milli % 1000 === 0 ? String(milli / 1000) : (milli / 1000).toFixed(3).replace(/0+$/, ''));

// ---- history ----

export interface AdjustmentRow { id: string; at: number; product: string; type: string; qty_milli: number; value_minor: number; reason: string | null; user: string | null }
export interface AdjustmentSummary { type: string; count: number; qty_milli: number; value_minor: number }

/** Adjustments and count corrections in [from, to), newest first, with totals by type. Values are at cost, in the base currency. */
export function adjustmentHistory(db: DatabaseSync, o: { from: number; to: number; branch_id?: string }): { rows: AdjustmentRow[]; summary: AdjustmentSummary[] } {
  const rows = (db.prepare(`select m.id, m.created_at as at, p.name as product, m.type, m.qty_milli, m.unit_cost_minor, m.reason, u.name as user
      from stock_movements m join products p on p.id = m.product_id left join users u on u.id = m.created_by
      where m.type in ('damaged', 'expired', 'loss', 'adjustment', 'count_correction') and m.created_at >= ? and m.created_at < ? ${o.branch_id ? 'and m.branch_id = ?' : ''}
      order by m.created_at desc, m.rowid desc`).all(...[o.from, o.to, ...(o.branch_id ? [o.branch_id] : [])]) as Row[])
    .map((r) => ({ id: r.id, at: r.at, product: r.product, type: r.type, qty_milli: r.qty_milli, value_minor: r.unit_cost_minor == null ? 0 : lineAmount(r.qty_milli, r.unit_cost_minor), reason: r.reason ?? null, user: r.user ?? null }));
  const by = new Map<string, AdjustmentSummary>();
  for (const r of rows) {
    const s = by.get(r.type) ?? { type: r.type, count: 0, qty_milli: 0, value_minor: 0 };
    s.count += 1; s.qty_milli += r.qty_milli; s.value_minor += r.value_minor;
    by.set(r.type, s);
  }
  return { rows, summary: [...by.values()].sort((a, b) => a.type.localeCompare(b.type)) };
}

// ---- stock take ----

export interface TakeLine { id: string; product_id: string; product: string; batch_id: string | null; batch_code: string | null; expected_milli: number; counted_milli: number | null }
export interface TakeInfo { id: string; branch_id: string; scope: string; status: string; started_at: number; closed_at: number | null; approved_by: string | null }

export function startStockTake(db: DatabaseSync, ctx: SetupContext, i: { branch_id: string; product_ids?: string[] }, newId: () => string = randomUUID): { take_id: string; lines: number } {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', i.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    if (w.get("select 1 as x from stock_takes where branch_id = ? and status in ('open', 'counted') and deleted_at is null", i.branch_id)) {
      throw new SetupError('take_open', 'A stock take is already in progress for this branch. Finish or cancel it first.');
    }
    const partial = !!i.product_ids && i.product_ids.length > 0;
    const products = w.all('select id, name from products where deleted_at is null and is_active = 1 and track_stock = 1 order by name')
      .filter((p) => !partial || i.product_ids!.includes(p.id));
    if (products.length === 0) throw new SetupError('nothing_to_count', 'There are no stock-keeping products to count.');
    const take_id = w.addVersioned('stock_takes', { branch_id: i.branch_id, scope: partial ? 'partial' : 'full', status: 'open', started_at: ctx.now, closed_at: null, approved_by: null });
    let lines = 0;
    for (const p of products) {
      const buckets = stockBuckets(db, i.branch_id, p.id).filter((b) => b.qty_milli !== 0 || b.batch_id !== null);
      if (buckets.length === 0) buckets.push({ batch_id: null, batch_code: null, expiry_date: null, qty_milli: 0 });
      for (const b of buckets) {
        w.addVersioned('stock_take_lines', { stock_take_id: take_id, product_id: p.id, batch_id: b.batch_id, expected_qty_milli: b.qty_milli, counted_qty_milli: null });
        lines += 1;
      }
    }
    return { take_id, lines };
  });
}

export function currentStockTake(db: DatabaseSync, branchId: string): TakeInfo | undefined {
  const r = db.prepare("select * from stock_takes where branch_id = ? and status in ('open', 'counted') and deleted_at is null order by started_at desc limit 1").get(branchId) as Row | undefined;
  return r ? { id: r.id, branch_id: r.branch_id, scope: r.scope, status: r.status, started_at: r.started_at, closed_at: r.closed_at ?? null, approved_by: r.approved_by ?? null } : undefined;
}

export function stockTakeLines(db: DatabaseSync, takeId: string): TakeLine[] {
  return (db.prepare(`select l.id, l.product_id, p.name as product, l.batch_id, b.batch_code, l.expected_qty_milli, l.counted_qty_milli
      from stock_take_lines l join products p on p.id = l.product_id left join stock_batches b on b.id = l.batch_id
      where l.stock_take_id = ? and l.deleted_at is null order by p.name, (b.expiry_date is null), b.expiry_date, l.rowid`).all(takeId) as Row[])
    .map((r) => ({ id: r.id, product_id: r.product_id, product: r.product, batch_id: r.batch_id ?? null, batch_code: r.batch_code ?? null, expected_milli: r.expected_qty_milli, counted_milli: r.counted_qty_milli ?? null }));
}

/** Records (or clears, with null) the count for one line. Only while the take is open. */
export function recordCount(db: DatabaseSync, ctx: SetupContext, lineId: string, counted: number | null, newId: () => string = randomUUID) {
  allow(db, ctx);
  if (counted != null && (!Number.isSafeInteger(counted) || counted < 0 || counted > 1_000_000_000)) throw new SetupError('bad_quantity', 'The count must be zero or more.');
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const l = w.get('select l.id, t.status from stock_take_lines l join stock_takes t on t.id = l.stock_take_id where l.id = ? and l.deleted_at is null and t.deleted_at is null', lineId);
    if (!l) throw new SetupError('not_found', 'That line was not found.');
    if (l.status !== 'open') throw new SetupError('take_closed', 'This stock take is no longer open for counting.');
    w.edit('stock_take_lines', lineId, { counted_qty_milli: counted });
  });
}

export interface TakeReportLine extends TakeLine { difference_milli: number | null; value_minor: number }
export interface TakeReport { take: TakeInfo; lines: TakeReportLine[]; counted_lines: number; uncounted_lines: number; surplus_minor: number; shortage_minor: number }

export function stockTakeReport(db: DatabaseSync, takeId: string): TakeReport {
  const t = db.prepare('select * from stock_takes where id = ? and deleted_at is null').get(takeId) as Row | undefined;
  if (!t) throw new SetupError('not_found', 'That stock take was not found.');
  const cost = new Map((db.prepare('select id, cost_minor from products').all() as Row[]).map((p) => [p.id, p.cost_minor as number | null]));
  const lines = stockTakeLines(db, takeId).map((l): TakeReportLine => {
    const diff = l.counted_milli == null ? null : l.counted_milli - l.expected_milli;
    const c = cost.get(l.product_id);
    return { ...l, difference_milli: diff, value_minor: diff == null || c == null ? 0 : lineAmount(diff, c) };
  });
  let surplus = 0; let shortage = 0;
  for (const l of lines) { if (l.value_minor > 0) surplus += l.value_minor; else shortage += -l.value_minor; }
  return {
    take: { id: t.id, branch_id: t.branch_id, scope: t.scope, status: t.status, started_at: t.started_at, closed_at: t.closed_at ?? null, approved_by: t.approved_by ?? null },
    lines, counted_lines: lines.filter((l) => l.counted_milli != null).length, uncounted_lines: lines.filter((l) => l.counted_milli == null).length, surplus_minor: surplus, shortage_minor: shortage,
  };
}

/** Ends counting. The figures can now be reviewed; nothing in stock changes yet. */
export function finishCounting(db: DatabaseSync, ctx: SetupContext, takeId: string, newId: () => string = randomUUID): TakeReport {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const t = w.get('select * from stock_takes where id = ? and deleted_at is null', takeId);
    if (!t) throw new SetupError('not_found', 'That stock take was not found.');
    if (t.status !== 'open') throw new SetupError('take_closed', 'Counting is already finished.');
    if (!w.get('select 1 as x from stock_take_lines where stock_take_id = ? and counted_qty_milli is not null and deleted_at is null', takeId)) throw new SetupError('nothing_counted', 'Count at least one item first.');
    w.edit('stock_takes', takeId, { status: 'counted' });
  });
  return stockTakeReport(db, takeId);
}

/** Goes back to counting, for example when a figure looks wrong. Only before approval. */
export function reopenCounting(db: DatabaseSync, ctx: SetupContext, takeId: string, newId: () => string = randomUUID) {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const t = w.get('select status from stock_takes where id = ? and deleted_at is null', takeId);
    if (!t || t.status !== 'counted') throw new SetupError('take_not_counted', 'This stock take is not waiting for approval.');
    w.edit('stock_takes', takeId, { status: 'open' });
  });
}

/** Posts the corrections. Needs stock.adjust, or a manager's approval (approved_by) for someone without it. */
export function approveStockTake(db: DatabaseSync, ctx: SetupContext, takeId: string, approvedBy: string | null = null, newId: () => string = randomUUID): { corrections: number; surplus_minor: number; shortage_minor: number } {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, 'stock.adjust') && !(approvedBy && hasPermission(db, approvedBy, 'stock.adjust'))) {
    throw new SetupError('forbidden', 'Approving a stock take needs a manager.');
  }
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const rep = stockTakeReport(db, takeId);
    if (rep.take.status !== 'counted') throw new SetupError('take_not_counted', 'Finish counting before approving.');
    const base = w.get('select base_currency from shops where deleted_at is null limit 1')?.base_currency as string;
    let corrections = 0;
    for (const l of rep.lines) {
      if (l.difference_milli == null || l.difference_milli === 0) continue;
      const cost = (w.get('select cost_minor from products where id = ?', l.product_id)?.cost_minor as number | null) ?? null;
      w.add('stock_movements', {
        branch_id: rep.take.branch_id, product_id: l.product_id, batch_id: l.batch_id, type: 'count_correction', qty_milli: l.difference_milli,
        unit_cost_minor: cost, cost_currency: base, ref_type: 'stock_take', ref_id: takeId, reason: 'Stock take',
      });
      corrections += 1;
    }
    w.edit('stock_takes', takeId, { status: 'approved', closed_at: ctx.now, approved_by: approvedBy ?? ctx.user_id });
    w.add('audit_log', { user_id: ctx.user_id, action: 'stock_take_approved', table_name: 'stock_takes', row_id: takeId, after: JSON.stringify({ corrections, surplus_minor: rep.surplus_minor, shortage_minor: rep.shortage_minor }) });
    return { corrections, surplus_minor: rep.surplus_minor, shortage_minor: rep.shortage_minor };
  });
}

/** Throws a stock take away (nothing was changed in stock). Not possible once approved. */
export function cancelStockTake(db: DatabaseSync, ctx: SetupContext, takeId: string, newId: () => string = randomUUID) {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const t = w.get('select status from stock_takes where id = ? and deleted_at is null', takeId);
    if (!t) throw new SetupError('not_found', 'That stock take was not found.');
    if (t.status === 'approved') throw new SetupError('take_approved', 'An approved stock take cannot be cancelled.');
    w.edit('stock_takes', takeId, { deleted_at: ctx.now });
  });
}
