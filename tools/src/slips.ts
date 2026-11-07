/**
 * Slips: the cash-up slip, the refund slip and the payment receipt (account payments and layby instalments).
 * Reference implementation; app/lib/printing/slips.dart is a port, checked against shared vectors.
 *
 * Every slip is turned into plain data (SlipData) where money and dates are already text, then one layout
 * function makes the same styled lines as a sale receipt, so toText / toEscPos / the printer code are reused.
 */
import { DatabaseSync } from 'node:sqlite';
import { wrap, row, formatMoney, dateText, type Item, type Align, type Money } from './receipt.ts';
import { shiftReport } from './shifts.ts';
import { laybyPaid } from './customers.ts';

export type SlipLine =
  | { k: 'row'; l: string; r: string; bold?: boolean }
  | { k: 'text'; text: string; align?: Align; bold?: boolean }
  | { k: 'big'; l: string; r: string }
  | { k: 'rule' }
  | { k: 'gap' };

export interface SlipData {
  shop_name: string; branch_name: string | null; branch_address: string | null; branch_phone: string | null;
  title: string; lines: SlipLine[]; signatures: string[]; footer: string | null; open_drawer: boolean;
}
export interface SlipOptions { width: number; cut?: boolean; open_drawer?: boolean }

export function layoutSlip(d: SlipData, o: SlipOptions): Item[] {
  const W = o.width;
  const items: Item[] = [];
  const text = (s: string, a: Align = 'left', bold = false, big = false) => { for (const l of wrap(s, big ? Math.floor(W / 2) : W)) items.push({ t: 'text', text: l, align: a, bold, big }); };
  const rows = (l: string, r: string, bold = false) => { for (const s of row(l, r, W)) items.push({ t: 'text', text: s, align: 'left', bold, big: false }); };
  if (o.open_drawer) items.push({ t: 'drawer' });
  text(d.shop_name, 'center', true, true);
  if (d.branch_name) text(d.branch_name, 'center');
  if (d.branch_address) text(d.branch_address, 'center');
  if (d.branch_phone) text('Tel ' + d.branch_phone, 'center');
  items.push({ t: 'rule' });
  text(d.title, 'center', true);
  items.push({ t: 'rule' });
  for (const l of d.lines) {
    if (l.k === 'row') rows(l.l, l.r, l.bold);
    else if (l.k === 'text') text(l.text, l.align ?? 'left', l.bold ?? false);
    else if (l.k === 'big') for (const s of row(l.l, l.r, Math.floor(W / 2))) items.push({ t: 'text', text: s, align: 'left', bold: true, big: true });
    else if (l.k === 'rule') items.push({ t: 'rule' });
    else items.push({ t: 'feed', n: 1 });
  }
  for (const s of d.signatures) {
    items.push({ t: 'feed', n: 2 });
    items.push({ t: 'text', text: ('_'.repeat(Math.floor(W * 2 / 3))), align: 'left', bold: false, big: false });
    text(s);
  }
  if (d.footer) { items.push({ t: 'rule' }); text(d.footer, 'center'); }
  items.push({ t: 'feed', n: 3 });
  if (o.cut !== false) items.push({ t: 'cut' });
  return items;
}

// ---- reading saved records ----

type Row = Record<string, any>;
interface Ctx { get: (sql: string, ...a: any[]) => Row | undefined; all: (sql: string, ...a: any[]) => Row[]; money: (minor: number, code: string) => string; shop: Row; branch: Row | undefined; names: Record<string, string> }

function context(db: DatabaseSync, branchId: string | null): Ctx {
  const get = (sql: string, ...a: any[]): Row | undefined => { const r = db.prepare(sql).get(...a); return r ? { ...r } : undefined; };
  const all = (sql: string, ...a: any[]): Row[] => db.prepare(sql).all(...a).map((r) => ({ ...r }));
  const cur: Record<string, Money> = {};
  for (const c of all('select code, symbol, minor_units from currencies')) cur[c.code] = { code: c.code, symbol: c.symbol ?? c.code, minor_units: c.minor_units };
  return {
    get, all, shop: get('select * from shops where deleted_at is null limit 1') ?? {}, branch: branchId ? get('select * from branches where id = ?', branchId) : undefined,
    money: (minor, code) => formatMoney(minor, cur[code] ?? { code, symbol: code, minor_units: 2 }),
    names: Object.fromEntries(all('select code, name from payment_methods').map((m) => [m.code, m.name])),
  };
}
const footerOf = (c: Ctx) => (c.get("select value from settings where scope = 'shop' and key = 'receipt_footer' and deleted_at is null")?.value as string | undefined) ?? null;
const userName = (c: Ctx, id: string | null | undefined) => (id ? ((c.get('select name from users where id = ?', id)?.name as string | undefined) ?? null) : null);
function base(c: Ctx, title: string): SlipData {
  return { shop_name: c.shop.name ?? '', branch_name: c.branch?.name ?? null, branch_address: c.branch?.address ?? null, branch_phone: c.branch?.phone ?? null, title, lines: [], signatures: [], footer: null, open_drawer: false };
}

/** The slip printed when a shift is closed (or a copy of an open shift's figures). */
export function loadCashUpSlip(db: DatabaseSync, shiftId: string, offsetMin: number): SlipData {
  const r = shiftReport(db, shiftId);
  const sh = db.prepare('select branch_id from shifts where id = ?').get(shiftId) as Row;
  const c = context(db, sh.branch_id);
  const d = base(c, r.status === 'closed' ? 'CASH-UP' : 'CASH-UP (shift still open)');
  const L = d.lines;
  if (r.user) L.push({ k: 'row', l: 'Cashier', r: r.user });
  L.push({ k: 'row', l: 'Opened', r: dateText(r.opened_at, offsetMin) });
  if (r.closed_at != null) L.push({ k: 'row', l: 'Closed', r: dateText(r.closed_at, offsetMin) });
  L.push({ k: 'rule' });
  L.push({ k: 'row', l: 'Sales', r: String(r.sales), bold: true });
  if (r.voided > 0) L.push({ k: 'row', l: 'Voided sales', r: String(r.voided) });
  for (const s of r.sold) L.push({ k: 'row', l: '  Sold ' + s.currency, r: c.money(s.total_minor, s.currency) });
  if (r.takings.length > 0) {
    L.push({ k: 'rule' }, { k: 'text', text: 'Money received', bold: true });
    for (const t of r.takings) L.push({ k: 'row', l: `  ${t.method} ${t.currency}`, r: c.money(t.amount_minor, t.currency) });
  }
  if (r.refunds.length > 0) {
    L.push({ k: 'rule' }, { k: 'text', text: 'Paid back to customers', bold: true });
    for (const t of r.refunds) L.push({ k: 'row', l: `  ${t.method} ${t.currency}`, r: c.money(t.amount_minor, t.currency) });
  }
  if (r.events.length > 0) {
    L.push({ k: 'rule' }, { k: 'text', text: 'Cash in and out', bold: true });
    for (const e of r.events) {
      const label = e.type === 'cash_in' ? 'Cash in' : e.type === 'cash_out' ? 'Cash out' : 'Bank drop';
      L.push({ k: 'row', l: `  ${label} ${e.currency}`, r: c.money(e.amount_minor, e.currency) });
      if (e.reason) L.push({ k: 'text', text: '    ' + e.reason });
    }
  }
  for (const code of Object.keys(r.float)) {
    L.push({ k: 'rule' }, { k: 'text', text: 'Cash drawer ' + code, bold: true });
    L.push({ k: 'row', l: '  Opening float', r: c.money(r.float[code]!, code) });
    L.push({ k: 'row', l: '  Should be', r: c.money(r.expected[code] ?? 0, code) });
    const counted = r.counted[code];
    if (counted != null) {
      const diff = r.difference[code] ?? 0;
      L.push({ k: 'row', l: '  Counted', r: c.money(counted, code) });
      L.push({ k: 'row', l: diff === 0 ? '  Correct' : diff > 0 ? '  OVER by' : '  SHORT by', r: diff === 0 ? 'OK' : c.money(Math.abs(diff), code), bold: true });
    }
  }
  d.signatures = ['Cashier', 'Checked by'];
  return d;
}

/** The slip for a return or a void: what came back, what was paid back, what was taken off the account. */
export function loadRefundSlip(db: DatabaseSync, returnId: string, offsetMin: number): SlipData {
  const ret = db.prepare('select * from sale_returns where id = ?').get(returnId) as Row | undefined;
  if (!ret) throw new Error('return not found');
  const sale = db.prepare('select * from sales where id = ?').get(ret.original_sale_id) as Row;
  const c = context(db, sale.branch_id);
  const cur = ret.refund_currency as string;
  const isVoid = ret.kind === 'void';
  const d = base(c, isVoid ? 'SALE VOIDED' : 'REFUND / RETURN');
  const L = d.lines;
  L.push({ k: 'row', l: isVoid ? 'Void no' : 'Refund no', r: ret.receipt_no, bold: true });
  L.push({ k: 'row', l: 'Original receipt', r: sale.receipt_no });
  L.push({ k: 'row', l: 'Date', r: dateText(ret.created_at, offsetMin) });
  const by = userName(c, ret.created_by);
  if (by) L.push({ k: 'row', l: 'Cashier', r: by });
  const appr = userName(c, ret.approved_by);
  if (appr) L.push({ k: 'row', l: 'Approved by', r: appr });
  const cust = sale.customer_id ? (c.get('select name from customers where id = ?', sale.customer_id)?.name as string | undefined) : undefined;
  if (cust) L.push({ k: 'row', l: 'Customer', r: cust });
  L.push({ k: 'rule' });
  for (const it of c.all('select rl.qty_milli, rl.amount_minor, sl.description from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ? order by rl.created_at, rl.rowid', returnId)) {
    const q = it.qty_milli % 1000 === 0 ? String(it.qty_milli / 1000) : (it.qty_milli / 1000).toFixed(3).replace(/0+$/, '');
    L.push({ k: 'text', text: it.description ?? '' });
    L.push({ k: 'row', l: '  Qty ' + q, r: c.money(it.amount_minor ?? 0, cur) });
  }
  L.push({ k: 'rule' });
  L.push({ k: 'big', l: 'VALUE', r: c.money(ret.refund_minor ?? 0, cur) });
  const pays = c.all('select * from return_payouts where return_id = ? order by created_at, rowid', returnId);
  if (pays.length > 0) {
    L.push({ k: 'rule' }, { k: 'text', text: 'Paid back', bold: true });
    for (const p of pays) {
      L.push({ k: 'row', l: `  ${c.names[p.method_code] ?? p.method_code} ${p.currency}`, r: c.money(p.amount_minor, p.currency) });
      if (p.reference) L.push({ k: 'text', text: '    Ref ' + p.reference });
    }
  }
  const credit = -((c.get("select coalesce(sum(amount_minor), 0) as s from customer_ledger where ref_type = 'return' and ref_id = ?", returnId)?.s as number) ?? 0);
  if (credit > 0) { L.push({ k: 'rule' }); L.push({ k: 'row', l: 'Taken off account', r: c.money(credit, cur), bold: true }); }
  if (ret.reason) L.push({ k: 'rule' }, { k: 'text', text: 'Reason: ' + ret.reason });
  d.open_drawer = pays.some((p) => c.get('select opens_drawer from payment_methods where code = ?', p.method_code)?.opens_drawer === 1);
  d.signatures = ['Customer signature'];
  d.footer = footerOf(c);
  return d;
}

/** The receipt for money received after the sale: an account payment, or a layby instalment. */
export function loadPaymentSlip(db: DatabaseSync, paymentId: string, offsetMin: number): SlipData {
  const p = db.prepare('select rowid as rid, * from account_payments where id = ?').get(paymentId) as Row | undefined;
  if (!p) throw new Error('payment not found');
  const sale = p.sale_id ? (db.prepare('select * from sales where id = ?').get(p.sale_id) as Row) : undefined;
  const c = context(db, sale?.branch_id ?? (c0(db, p.user_id)));
  const d = base(c, sale ? 'LAYBY PAYMENT' : 'PAYMENT RECEIVED');
  const L = d.lines;
  const tgt = p.target_currency as string;
  L.push({ k: 'row', l: 'Receipt', r: p.receipt_no, bold: true });
  L.push({ k: 'row', l: 'Date', r: dateText(p.created_at, offsetMin) });
  const by = userName(c, p.user_id);
  if (by) L.push({ k: 'row', l: 'Cashier', r: by });
  const cust = c.get('select name from customers where id = ?', p.customer_id)?.name as string | undefined;
  if (cust) L.push({ k: 'row', l: 'Customer', r: cust });
  if (sale) L.push({ k: 'row', l: 'Layby sale', r: sale.receipt_no });
  L.push({ k: 'rule' });
  const method = c.names[p.method_code] ?? p.method_code;
  L.push({ k: 'big', l: 'PAID', r: c.money(p.amount_minor, p.currency) });
  L.push({ k: 'row', l: method + (p.currency === tgt ? '' : ' ' + p.currency), r: c.money(p.amount_minor, p.currency) });
  if (p.reference) L.push({ k: 'text', text: '  Ref ' + p.reference });
  if (p.currency !== tgt) L.push({ k: 'row', l: 'Counted as', r: c.money(p.applied_minor, tgt) });
  let after: number;
  if (sale) {
    const later = (db.prepare('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ? and rowid > ?').get(p.sale_id, p.rid) as Row).s as number;
    after = Math.max(0, sale.total_minor - (laybyPaid(db, p.sale_id, sale.sale_currency, 0) - later));
  } else {
    const led = db.prepare("select rowid as rid from customer_ledger where ref_type = 'account_payment' and ref_id = ?").get(paymentId) as Row | undefined;
    after = (db.prepare('select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ? and rowid <= ?').get(p.customer_id, tgt, led?.rid ?? 0x7fffffff) as Row).s as number;
  }
  L.push({ k: 'rule' });
  L.push({ k: 'row', l: sale ? 'Balance on layby' : 'Balance owing', r: c.money(Math.max(0, after), tgt), bold: true });
  d.open_drawer = c.get('select opens_drawer from payment_methods where code = ?', p.method_code)?.opens_drawer === 1;
  d.footer = footerOf(c);
  return d;
}
function c0(db: DatabaseSync, userId: string | null): string | null {
  const r = userId ? (db.prepare('select branch_id from user_branches where user_id = ? and deleted_at is null limit 1').get(userId) as Row | undefined) : undefined;
  return r?.branch_id ?? ((db.prepare('select id from branches where deleted_at is null order by created_at limit 1').get() as Row | undefined)?.id ?? null);
}
