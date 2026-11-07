/**
 * Vendor billing: invoices to shops, payments received, monthly billing runs and statements.
 *
 * Rules
 *  - Money is whole minor units. An invoice and all its payments share one currency; nothing is converted.
 *  - Invoice numbers run per year with no gaps (INV-2026-0001). Receipts likewise (RCT-2026-0001).
 *  - Status is never stored for payment: an invoice is unpaid, partly paid or paid by adding up its payments that
 *    have not been reversed. "Overdue" is an unpaid balance past the due date.
 *  - A payment may not be more than the balance. The same request_id is accepted only once.
 *  - Nothing is deleted. An invoice with no payments can be voided; a payment can be reversed. Both need a reason.
 *  - Paying can extend the licence in the same step (explicit, chosen per payment). Reversing the payment does not take
 *    that extension back; the dashboard says so.
 *  - The monthly run bills each active licence whose plan has a monthly fee, once per month, and can be repeated safely.
 */
import type { Ctx } from '../context.ts';
import { HttpError, asObject, int, optInt, optStr, str } from '../http.ts';
import { newId } from '../crypto.ts';
import { DAY_MS } from '../licence.ts';
import { audit, extendLicence, type VendorUser } from './vendor.ts';

type Obj = Record<string, unknown>;

export const METHODS = ['cash', 'ecocash', 'onemoney', 'innbucks', 'bank', 'other'] as const;
const NEEDS_REFERENCE = new Set(['ecocash', 'onemoney', 'innbucks', 'bank']);
const KINDS = ['one_time', 'monthly', 'other'] as const;
const MAX_MINOR = 100_000_000_000; // 1,000,000,000.00
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

// ---- profile ----

export interface Profile {
  business_name: string; address: string; phone: string; email: string; tax_number: string; default_tax_bp: number; default_due_days: number;
  invoice_prefix: string; receipt_prefix: string; payment_instructions: string; footer: string; updated_at: number;
}

export function getProfile(ctx: Ctx): Profile {
  const { id: _id, ...p } = ctx.db.get<Profile & { id: number }>('select * from billing_profile where id = 1') as Profile & { id: number };
  return p;
}

export function saveProfile(ctx: Ctx, user: VendorUser, body: unknown): Profile {
  const o = asObject(body);
  const cur = getProfile(ctx);
  const text = (k: keyof Profile, max: number): string => (o[k] === undefined ? (cur[k] as string) : str(o, k, { max, optional: true }));
  const prefix = (k: 'invoice_prefix' | 'receipt_prefix'): string => {
    const v = o[k] === undefined ? cur[k] : str(o, k, { max: 8 }).toUpperCase();
    if (!/^[A-Z0-9]{1,8}$/.test(v)) throw new HttpError(400, 'invalid_request', `${k} may only have letters and digits`);
    return v;
  };
  const next = {
    business_name: text('business_name', 120), address: text('address', 300), phone: text('phone', 60), email: text('email', 120), tax_number: text('tax_number', 60),
    payment_instructions: text('payment_instructions', 1000), footer: text('footer', 300),
    default_tax_bp: o.default_tax_bp === undefined ? cur.default_tax_bp : int(o, 'default_tax_bp', { max: 10000 }),
    default_due_days: o.default_due_days === undefined ? cur.default_due_days : int(o, 'default_due_days', { max: 365 }),
    invoice_prefix: prefix('invoice_prefix'), receipt_prefix: prefix('receipt_prefix'),
  };
  ctx.db.run(
    `update billing_profile set business_name = ?, address = ?, phone = ?, email = ?, tax_number = ?, payment_instructions = ?, footer = ?,
       default_tax_bp = ?, default_due_days = ?, invoice_prefix = ?, receipt_prefix = ?, updated_at = ? where id = 1`,
    next.business_name, next.address, next.phone, next.email, next.tax_number, next.payment_instructions, next.footer,
    next.default_tax_bp, next.default_due_days, next.invoice_prefix, next.receipt_prefix, ctx.now(),
  );
  audit(ctx, user.id, 'billing.profile', null);
  return getProfile(ctx);
}

function nextNumber(ctx: Ctx, kind: 'invoice' | 'receipt'): string {
  const year = new Date(ctx.now()).getUTCFullYear();
  const name = `${kind}:${year}`;
  ctx.db.run('insert into billing_counters (name, value) values (?, 1) on conflict (name) do update set value = value + 1', name);
  const n = (ctx.db.get<{ value: number }>('select value from billing_counters where name = ?', name) as { value: number }).value;
  const p = getProfile(ctx);
  return `${kind === 'invoice' ? p.invoice_prefix : p.receipt_prefix}-${year}-${String(n).padStart(4, '0')}`;
}

// ---- reading ----

interface InvoiceRow {
  id: string; number: string; tenant_id: string; tenant_name: string; currency: string; status: 'issued' | 'void'; issued_at: number; due_at: number;
  subtotal_minor: number; tax_bp: number; tax_minor: number; total_minor: number; notes: string | null; void_reason: string | null; voided_at: number | null;
  created_at: number; paid_minor: number;
}

export type InvoiceState = 'unpaid' | 'partly_paid' | 'paid' | 'void';

function present(r: InvoiceRow, now: number): Obj {
  const balance = r.total_minor - r.paid_minor;
  const state: InvoiceState = r.status === 'void' ? 'void' : balance <= 0 ? 'paid' : r.paid_minor > 0 ? 'partly_paid' : 'unpaid';
  return { ...r, balance_minor: r.status === 'void' ? 0 : balance, state, overdue: state !== 'void' && balance > 0 && r.due_at < now };
}

const INVOICE_SQL = `select i.*, t.name as tenant_name, coalesce((select sum(p.amount_minor) from payments p where p.invoice_id = i.id and p.reversed_at is null), 0) as paid_minor
  from invoices i join tenants t on t.id = i.tenant_id`;

function mustInvoice(ctx: Ctx, id: string): InvoiceRow {
  const r = ctx.db.get<InvoiceRow>(`${INVOICE_SQL} where i.id = ?`, id);
  if (!r) throw new HttpError(404, 'not_found', 'Invoice not found');
  return r;
}

export function listInvoices(ctx: Ctx, query: URLSearchParams): Obj[] {
  const tenant = query.get('tenant_id');
  const rows = tenant
    ? ctx.db.all<InvoiceRow>(`${INVOICE_SQL} where i.tenant_id = ? order by i.issued_at desc, i.rowid desc limit 1000`, tenant)
    : ctx.db.all<InvoiceRow>(`${INVOICE_SQL} order by i.issued_at desc, i.rowid desc limit 1000`);
  const now = ctx.now();
  const want = query.get('status') ?? 'all';
  return rows.map((r) => present(r, now)).filter((r) => {
    switch (want) {
      case 'open': return r.state === 'unpaid' || r.state === 'partly_paid';
      case 'overdue': return r.overdue === true;
      case 'paid': return r.state === 'paid';
      case 'void': return r.state === 'void';
      case 'all': return true;
      default: throw new HttpError(400, 'invalid_request', 'status must be all, open, overdue, paid or void');
    }
  });
}

export function invoiceDetail(ctx: Ctx, id: string): Obj {
  const inv = mustInvoice(ctx, id);
  const lines = ctx.db.all<Obj>('select id, description, quantity, unit_price_minor, line_total_minor, kind, licence_id from invoice_lines where invoice_id = ? order by rowid', id);
  const payments = ctx.db.all<Obj>(
    `select p.id, p.receipt_no, p.amount_minor, p.method, p.reference, p.note, p.received_at, p.created_at, p.extended_licence_id, p.extended_months,
       p.reversed_at, p.reverse_reason, u.name as recorded_by
     from payments p left join vendor_users u on u.id = p.created_by where p.invoice_id = ? order by p.received_at, p.rowid`, id);
  const tenant = ctx.db.get<Obj>('select id, name, country_code, contact from tenants where id = ?', inv.tenant_id);
  const licences = ctx.db.all<Obj>("select id, key_hint, expires_at, status from licences where tenant_id = ? and key_hint <> 'rotd' order by created_at desc", inv.tenant_id);
  return { ...present(inv, ctx.now()), lines, payments, tenant, licences, profile: getProfile(ctx) };
}

export function listPayments(ctx: Ctx, query: URLSearchParams): Obj[] {
  const n = Number(query.get('limit') ?? 100);
  const limit = Number.isSafeInteger(n) ? Math.min(500, Math.max(1, n)) : 100;
  return ctx.db.all<Obj>(
    `select p.id, p.receipt_no, p.invoice_id, i.number as invoice_number, p.tenant_id, t.name as tenant_name, p.currency, p.amount_minor, p.method, p.reference,
       p.received_at, p.reversed_at, p.reverse_reason
     from payments p join invoices i on i.id = p.invoice_id join tenants t on t.id = p.tenant_id
     order by p.received_at desc, p.rowid desc limit ?`, limit);
}

// ---- invoices ----

function currencyOf(o: Obj): string {
  const c = str(o, 'currency', { max: 3, min: 3 }).toUpperCase();
  if (!/^[A-Z]{3}$/.test(c)) throw new HttpError(400, 'invalid_request', 'currency must be a three-letter code such as USD');
  return c;
}

interface LineInput { description: string; quantity: number; unit_price_minor: number; kind: (typeof KINDS)[number]; licence_id: string | null; period_key: string | null }

function readLines(ctx: Ctx, tenantId: string, raw: unknown): LineInput[] {
  if (!Array.isArray(raw) || raw.length < 1 || raw.length > 50) throw new HttpError(400, 'invalid_request', 'Give 1 to 50 invoice lines');
  return raw.map((x, i) => {
    const o = asObject(x, `line ${i + 1}`);
    const kind = o.kind === undefined ? 'other' : o.kind;
    if (!KINDS.includes(kind as (typeof KINDS)[number])) throw new HttpError(400, 'invalid_request', `line ${i + 1}: kind must be one_time, monthly or other`);
    const licence = optStr(o, 'licence_id', 64) || null;
    if (licence && !ctx.db.get('select 1 as x from licences where id = ? and tenant_id = ?', licence, tenantId)) {
      throw new HttpError(400, 'invalid_request', `line ${i + 1}: that licence does not belong to this shop`);
    }
    return {
      description: str(o, 'description', { max: 200 }), quantity: int(o, 'quantity', { min: 1, max: 10_000 }),
      unit_price_minor: int(o, 'unit_price_minor', { max: MAX_MINOR }), kind: kind as LineInput['kind'], licence_id: licence, period_key: null,
    };
  });
}

/** Writes an invoice and its lines. Called inside a transaction. */
function writeInvoice(ctx: Ctx, user: VendorUser, tenantId: string, a: { currency: string; lines: LineInput[]; taxBp: number; dueAt: number; notes: string | null }): Obj {
  const subtotal = a.lines.reduce((s, l) => s + l.quantity * l.unit_price_minor, 0);
  if (!Number.isSafeInteger(subtotal) || subtotal > MAX_MINOR) throw new HttpError(400, 'invalid_request', 'The invoice total is too large');
  const tax = Math.floor((subtotal * a.taxBp + 5000) / 10000); // half a cent rounds up
  const total = subtotal + tax;
  if (total <= 0) throw new HttpError(400, 'invalid_request', 'An invoice must be for more than zero');
  const now = ctx.now();
  if (a.dueAt < now - DAY_MS) throw new HttpError(400, 'invalid_request', 'The due date is already in the past');
  const id = newId();
  const number = nextNumber(ctx, 'invoice');
  ctx.db.run(
    `insert into invoices (id, number, tenant_id, currency, issued_at, due_at, subtotal_minor, tax_bp, tax_minor, total_minor, notes, created_by, created_at)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    id, number, tenantId, a.currency, now, a.dueAt, subtotal, a.taxBp, tax, total, a.notes, user.id, now,
  );
  for (const l of a.lines) {
    ctx.db.run(
      'insert into invoice_lines (id, invoice_id, description, quantity, unit_price_minor, line_total_minor, kind, licence_id, period_key) values (?, ?, ?, ?, ?, ?, ?, ?, ?)',
      newId(), id, l.description, l.quantity, l.unit_price_minor, l.quantity * l.unit_price_minor, l.kind, l.licence_id, l.period_key,
    );
  }
  audit(ctx, user.id, 'invoice.create', tenantId, { invoice_id: id, number, total_minor: total, currency: a.currency });
  return { id, number, total_minor: total, currency: a.currency };
}

export function createInvoice(ctx: Ctx, user: VendorUser, tenantId: string, body: unknown): Obj {
  if (!ctx.db.get('select 1 as x from tenants where id = ?', tenantId)) throw new HttpError(404, 'not_found', 'Shop not found');
  const o = asObject(body);
  const profile = getProfile(ctx);
  const dueAt = optInt(o, 'due_at', { min: 1 }) ?? ctx.now() + profile.default_due_days * DAY_MS;
  return ctx.db.tx(() => writeInvoice(ctx, user, tenantId, {
    currency: currencyOf(o), lines: readLines(ctx, tenantId, o.lines), taxBp: optInt(o, 'tax_bp', { max: 10000 }) ?? profile.default_tax_bp, dueAt, notes: optStr(o, 'notes', 1000) || null,
  }));
}

export function voidInvoice(ctx: Ctx, user: VendorUser, id: string, body: unknown): Obj {
  const reason = str(asObject(body), 'reason', { min: 3, max: 300 });
  return ctx.db.tx(() => {
    const inv = mustInvoice(ctx, id);
    if (inv.status === 'void') throw new HttpError(409, 'already_void', 'This invoice is already void');
    if (inv.paid_minor > 0) throw new HttpError(409, 'has_payments', 'This invoice has payments. Reverse them first, then void it.');
    ctx.db.run("update invoices set status = 'void', voided_at = ?, void_reason = ? where id = ?", ctx.now(), reason, id);
    ctx.db.run('update invoice_lines set period_key = null where invoice_id = ?', id); // the month can be billed again
    audit(ctx, user.id, 'invoice.void', inv.tenant_id, { invoice_id: id, number: inv.number, reason });
    return present(mustInvoice(ctx, id), ctx.now());
  });
}

// ---- payments ----

export function recordPayment(ctx: Ctx, user: VendorUser, invoiceId: string, body: unknown): Obj {
  const o = asObject(body);
  const amount = int(o, 'amount_minor', { min: 1, max: MAX_MINOR });
  const method = str(o, 'method', { max: 20 });
  if (!(METHODS as readonly string[]).includes(method)) throw new HttpError(400, 'invalid_request', `method must be one of ${METHODS.join(', ')}`);
  const reference = optStr(o, 'reference', 100)?.trim() || null;
  if (NEEDS_REFERENCE.has(method) && !reference) throw new HttpError(400, 'invalid_request', 'Enter the transaction reference so the payment can be checked later');
  const note = optStr(o, 'note', 500) || null;
  const requestId = optStr(o, 'request_id', 64) || null;
  const receivedAt = optInt(o, 'received_at', { min: 1 }) ?? ctx.now();
  if (receivedAt > ctx.now() + DAY_MS) throw new HttpError(400, 'invalid_request', 'The payment date cannot be in the future');
  let extend: { licence_id: string; months: number } | null = null;
  if (o.extend_licence !== undefined && o.extend_licence !== null) {
    const e = asObject(o.extend_licence, 'extend_licence');
    extend = { licence_id: str(e, 'licence_id', { max: 64 }), months: int(e, 'months', { min: 1, max: 120 }) };
  }

  return ctx.db.tx(() => {
    if (requestId) {
      const dup = ctx.db.get<{ id: string; invoice_id: string; amount_minor: number }>('select id, invoice_id, amount_minor from payments where request_id = ?', requestId);
      if (dup) {
        if (dup.invoice_id !== invoiceId || dup.amount_minor !== amount) throw new HttpError(409, 'request_reused', 'That request id was already used for a different payment');
        return { payment: paymentRow(ctx, dup.id), invoice: present(mustInvoice(ctx, invoiceId), ctx.now()), duplicate: true };
      }
    }
    const inv = mustInvoice(ctx, invoiceId);
    if (inv.status === 'void') throw new HttpError(409, 'already_void', 'This invoice is void');
    const balance = inv.total_minor - inv.paid_minor;
    if (balance <= 0) throw new HttpError(409, 'already_paid', 'This invoice is already paid in full');
    if (amount > balance) throw new HttpError(400, 'overpayment', `That is more than the balance. The most you can record is ${(balance / 100).toFixed(2)} ${inv.currency}.`);
    if (extend && !ctx.db.get('select 1 as x from licences where id = ? and tenant_id = ?', extend.licence_id, inv.tenant_id)) {
      throw new HttpError(400, 'invalid_request', 'That licence does not belong to this shop');
    }
    const id = newId();
    const receiptNo = nextNumber(ctx, 'receipt');
    ctx.db.run(
      `insert into payments (id, receipt_no, invoice_id, tenant_id, currency, amount_minor, method, reference, note, received_at, request_id, extended_licence_id, extended_months, created_by, created_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      id, receiptNo, invoiceId, inv.tenant_id, inv.currency, amount, method, reference, note, receivedAt, requestId, extend?.licence_id ?? null, extend?.months ?? null, user.id, ctx.now(),
    );
    audit(ctx, user.id, 'payment.record', inv.tenant_id, { payment_id: id, receipt_no: receiptNo, invoice: inv.number, amount_minor: amount, currency: inv.currency, method });
    if (extend) extendLicence(ctx, user, extend.licence_id, { months: extend.months });
    return { payment: paymentRow(ctx, id), invoice: present(mustInvoice(ctx, invoiceId), ctx.now()), duplicate: false };
  });
}

function paymentRow(ctx: Ctx, id: string): Obj {
  return ctx.db.get<Obj>(
    `select id, receipt_no, invoice_id, tenant_id, currency, amount_minor, method, reference, note, received_at, extended_licence_id, extended_months, reversed_at, reverse_reason
     from payments where id = ?`, id) as Obj;
}

export function reversePayment(ctx: Ctx, user: VendorUser, id: string, body: unknown): Obj {
  const reason = str(asObject(body), 'reason', { min: 3, max: 300 });
  return ctx.db.tx(() => {
    const p = ctx.db.get<{ id: string; tenant_id: string; invoice_id: string; receipt_no: string; amount_minor: number; reversed_at: number | null; extended_months: number | null }>(
      'select id, tenant_id, invoice_id, receipt_no, amount_minor, reversed_at, extended_months from payments where id = ?', id);
    if (!p) throw new HttpError(404, 'not_found', 'Payment not found');
    if (p.reversed_at) throw new HttpError(409, 'already_reversed', 'This payment was already reversed');
    ctx.db.run('update payments set reversed_at = ?, reverse_reason = ?, reversed_by = ? where id = ?', ctx.now(), reason, user.id, id);
    audit(ctx, user.id, 'payment.reverse', p.tenant_id, { payment_id: id, receipt_no: p.receipt_no, amount_minor: p.amount_minor, reason });
    return { payment: paymentRow(ctx, id), invoice: present(mustInvoice(ctx, p.invoice_id), ctx.now()), licence_still_extended: p.extended_months !== null };
  });
}

// ---- statement ----

export function statement(ctx: Ctx, tenantId: string): Obj {
  const t = ctx.db.get<Obj>('select id, name from tenants where id = ?', tenantId);
  if (!t) throw new HttpError(404, 'not_found', 'Shop not found');
  const now = ctx.now();
  const invoices = ctx.db.all<InvoiceRow>(`${INVOICE_SQL} where i.tenant_id = ? order by i.issued_at desc, i.rowid desc`, tenantId).map((r) => present(r, now));
  const totals = new Map<string, { currency: string; invoiced_minor: number; paid_minor: number; owed_minor: number; overdue_minor: number }>();
  for (const i of invoices as (Obj & InvoiceRow & { balance_minor: number; overdue: boolean; state: InvoiceState })[]) {
    if (i.state === 'void') continue;
    const row = totals.get(i.currency) ?? { currency: i.currency, invoiced_minor: 0, paid_minor: 0, owed_minor: 0, overdue_minor: 0 };
    row.invoiced_minor += i.total_minor;
    row.paid_minor += i.paid_minor;
    row.owed_minor += i.balance_minor;
    if (i.overdue) row.overdue_minor += i.balance_minor;
    totals.set(i.currency, row);
  }
  return { tenant: t, balances: [...totals.values()].sort((a, b) => a.currency.localeCompare(b.currency)), invoices };
}

/** What shops owe in total, per currency, and how many invoices are overdue. Used by the overview. */
export function outstanding(ctx: Ctx): { owed: { currency: string; minor: number }[]; overdue_invoices: number; overdue_minor: { currency: string; minor: number }[] } {
  const now = ctx.now();
  const rows = ctx.db.all<InvoiceRow>(`${INVOICE_SQL} where i.status = 'issued'`).map((r) => present(r, now) as Obj & InvoiceRow & { balance_minor: number; overdue: boolean });
  const owed = new Map<string, number>();
  const late = new Map<string, number>();
  let overdue = 0;
  for (const r of rows) {
    if (r.balance_minor <= 0) continue;
    owed.set(r.currency, (owed.get(r.currency) ?? 0) + r.balance_minor);
    if (r.overdue) { overdue++; late.set(r.currency, (late.get(r.currency) ?? 0) + r.balance_minor); }
  }
  const list = (m: Map<string, number>) => [...m.entries()].sort(([a], [b]) => a.localeCompare(b)).map(([currency, minor]) => ({ currency, minor }));
  return { owed: list(owed), overdue_invoices: overdue, overdue_minor: list(late) };
}

// ---- monthly run ----

export function monthlyRun(ctx: Ctx, user: VendorUser, body: unknown): Obj {
  const o = asObject(body);
  const month = str(o, 'month', { max: 7, min: 7 });
  const m = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(month);
  if (!m) throw new HttpError(400, 'invalid_request', 'month must look like 2026-11');
  const year = Number(m[1]), mon = Number(m[2]);
  const start = Date.UTC(year, mon - 1, 1), end = Date.UTC(year, mon, 1);
  const nowD = new Date(ctx.now());
  const limit = Date.UTC(nowD.getUTCFullYear(), nowD.getUTCMonth() + 2, 1); // up to next month
  if (year < 2024 || end > limit) throw new HttpError(400, 'invalid_request', 'Bill this month or next month at the latest');
  const dry = o.dry_run === true;
  const label = `${MONTHS[mon - 1]} ${year}`;
  const profile = getProfile(ctx);
  const dueAt = Math.max(ctx.now(), start) + profile.default_due_days * DAY_MS;

  return ctx.db.tx(() => {
    const due = ctx.db.all<{ id: string; tenant_id: string; tenant_name: string; plan_name: string; monthly_fee_minor: number; currency: string }>(
      `select l.id, l.tenant_id, t.name as tenant_name, p.name as plan_name, p.monthly_fee_minor, p.currency
       from licences l join tenants t on t.id = l.tenant_id join plans p on p.id = l.plan_id
       where l.status = 'active' and t.status = 'active' and p.monthly_fee_minor > 0 and l.expires_at > ? and l.issued_at < ?
       order by t.name, l.id`, start, end);
    const created: Obj[] = [];
    let already = 0;
    for (const l of due) {
      if (ctx.db.get('select 1 as x from invoice_lines where licence_id = ? and period_key = ?', l.id, `monthly:${month}`)) { already++; continue; }
      if (dry) { created.push({ tenant_id: l.tenant_id, tenant_name: l.tenant_name, total_minor: l.monthly_fee_minor, currency: l.currency }); continue; }
      const inv = writeInvoice(ctx, user, l.tenant_id, {
        currency: l.currency, taxBp: profile.default_tax_bp, dueAt, notes: null,
        lines: [{ description: `Monthly licence fee, ${label} (${l.plan_name})`, quantity: 1, unit_price_minor: l.monthly_fee_minor, kind: 'monthly', licence_id: l.id, period_key: `monthly:${month}` }],
      });
      created.push({ ...inv, tenant_id: l.tenant_id, tenant_name: l.tenant_name });
    }
    if (!dry) audit(ctx, user.id, 'billing.run', null, { month, invoices: created.length, already_billed: already });
    return { month, dry_run: dry, created, already_billed: already };
  });
}
