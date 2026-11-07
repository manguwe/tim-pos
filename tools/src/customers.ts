/**
 * Customers, credit accounts and laybys. Reference implementation; app/lib/customers/customer_repository.dart is a port.
 *
 *  - A credit sale puts a positive row in customer_ledger (the customer owes). A payment adds a negative row.
 *    The debt stays in the currency it was agreed in: a customer who owes USD 50 owes USD 50, whatever the ZiG rate does.
 *    A payment in another currency is converted at today's rate and the row records both amounts (account_payments).
 *  - A layby is a sale with status 'layby'. The goods leave stock when it is made and the deposit is an ordinary sale payment.
 *    Instalments are account_payments rows with sale_id set. Nothing on the sale changes; the balance is worked out from
 *    the sale total and the payments. When it is fully paid the goods are handed over and a marker row is written to
 *    layby_payments (payment_id empty, due_note 'collected').
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission, type Permission } from './auth.ts';
import { convertMinor, invertRate } from './money.ts';

type Row = Record<string, any>;
const COLLECTED = 'collected';

export interface CustomerInput {
  id?: string; name: string; phone?: string | null; address?: string | null; tax_number?: string | null;
  price_tier_id?: string | null; credit_limit_minor?: number | null; credit_currency?: string | null; is_active?: boolean;
}

function allow(db: DatabaseSync, ctx: SetupContext, perm: Permission) {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, perm)) throw new SetupError('forbidden', 'You are not allowed to do that.');
}

export function saveCustomer(db: DatabaseSync, ctx: SetupContext, c: CustomerInput, newId: () => string = randomUUID): string {
  allow(db, ctx, 'customer.manage');
  const name = (c.name ?? '').trim();
  if (!name) throw new SetupError('missing', 'Enter the customer\'s name.');
  const limit = c.credit_limit_minor ?? null;
  if (limit !== null && (!Number.isSafeInteger(limit) || limit < 0)) throw new SetupError('bad_limit', 'The credit limit must be zero or more.');
  const w = new Writer(db, ctx, newId);
  if (limit && c.credit_currency && !w.get('select 1 as x from currencies where code = ? and deleted_at is null', c.credit_currency)) throw new SetupError('unknown_currency', 'That currency is not set up.');
  const phone = c.phone?.trim() || null;
  if (phone) {
    const dup = w.get('select id, name from customers where phone = ? and deleted_at is null and id is not ?', phone, c.id ?? null);
    if (dup) throw new SetupError('duplicate_phone', `${dup.name} already has that phone number.`);
  }
  const fields = {
    name, phone, address: c.address?.trim() || null, tax_number: c.tax_number?.trim() || null, price_tier_id: c.price_tier_id ?? null,
    credit_limit_minor: limit, credit_currency: limit ? c.credit_currency ?? null : null, is_active: c.is_active === false ? 0 : 1,
  };
  return tx(db, () => {
    if (c.id) { w.edit('customers', c.id, fields); return c.id; }
    return w.addVersioned('customers', fields);
  });
}

export interface CustomerSummary { id: string; name: string; phone: string | null; credit_limit_minor: number | null; credit_currency: string | null; owes: { currency: string; amount_minor: number }[]; layby_open: number }

/** What a customer owes, per currency (only amounts above zero). */
export function owedBy(db: DatabaseSync, customerId: string): { currency: string; amount_minor: number }[] {
  return (db.prepare('select currency, sum(amount_minor) as amount_minor from customer_ledger where customer_id = ? group by currency having sum(amount_minor) <> 0 order by currency').all(customerId) as Row[])
    .map((r) => ({ currency: r.currency, amount_minor: r.amount_minor }));
}

export function listCustomers(db: DatabaseSync, o: { search?: string; only_owing?: boolean } = {}): CustomerSummary[] {
  const q = (o.search ?? '').trim();
  const like = `%${q.replace(/[\\%_]/g, (m) => '\\' + m)}%`;
  const rows = db.prepare(`select * from customers where deleted_at is null and is_active = 1 ${q ? "and (name like ? escape '\\' or phone like ? escape '\\')" : ''} order by name collate nocase limit 200`)
    .all(...(q ? [like, like] : [])) as Row[];
  const out = rows.map((r) => ({
    id: r.id, name: r.name, phone: r.phone ?? null, credit_limit_minor: r.credit_limit_minor ?? null, credit_currency: r.credit_currency ?? null,
    owes: owedBy(db, r.id), layby_open: laybys(db, { customer_id: r.id, open_only: true }).length,
  }));
  return o.only_owing ? out.filter((c) => c.owes.some((x) => x.amount_minor > 0)) : out;
}

// ---- exchange ----

export function rateBetween(db: DatabaseSync, from: string, to: string, now: number): number {
  if (from === to) return 1_000_000;
  const q = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? order by effective_from desc, created_at desc limit 1';
  const d = db.prepare(q).get(from, to, now) as Row | undefined;
  if (d) return d.rate_micro;
  const i = db.prepare(q).get(to, from, now) as Row | undefined;
  if (!i) throw new SetupError('no_rate', `No exchange rate between ${from} and ${to}.`);
  return invertRate(i.rate_micro);
}
export function currencyRow(db: DatabaseSync, code: string): Row {
  const c = db.prepare('select * from currencies where code = ? and deleted_at is null').get(code) as Row | undefined;
  if (!c) throw new SetupError('unknown_currency', `Currency ${code} is not set up.`);
  return c;
}

function nextPaymentNo(db: DatabaseSync, prefix: string): string {
  db.prepare(`insert into receipt_counters (kind, last_no) values ('payment', 1) on conflict (kind) do update set last_no = last_no + 1`).run();
  const n = (db.prepare("select last_no from receipt_counters where kind = 'payment'").get() as Row).last_no;
  return `${prefix}-P${String(n).padStart(6, '0')}`;
}

export interface PaymentInput { method_code: string; currency: string; amount_minor: number; reference?: string | null }
export interface PaymentResult { payment_id: string; receipt_no: string; applied_minor: number; target_currency: string; balance_after_minor: number; opens_drawer: boolean }

/**
 * Applies money to a debt in `target`. The amount may be paid in another currency; it is converted at today's rate.
 * Paying more than is owed is refused, except by less than one rounding step of the currency paid in (so "pay it all" works in ZiG).
 */
export function applyPayment(db: DatabaseSync, ctx: SetupContext & { receipt_prefix: string }, p: PaymentInput, target: string, owed: number): { applied: number; rate: number; opens_drawer: boolean } {
  if (!Number.isSafeInteger(p.amount_minor) || p.amount_minor <= 0) throw new SetupError('bad_payment', 'A payment must be more than zero.');
  const m = db.prepare('select * from payment_methods where code = ? and deleted_at is null').get(p.method_code) as Row | undefined;
  if (!m) throw new SetupError('unknown_method', `Payment method ${p.method_code} is not set up.`);
  if (m.requires_reference === 1 && !p.reference?.trim()) throw new SetupError('reference_needed', `${m.name} needs the confirmation reference.`);
  const payCur = currencyRow(db, p.currency); const tgtCur = currencyRow(db, target);
  if (owed <= 0) throw new SetupError('nothing_owed', 'There is nothing to pay.');
  const rate = rateBetween(db, p.currency, target, ctx.now);
  const converted = p.currency === target ? p.amount_minor : convertMinor(p.amount_minor, rate, payCur.minor_units, tgtCur.minor_units);
  if (converted <= 0) throw new SetupError('bad_payment', 'That amount is too small to count.');
  let applied = converted;
  if (converted > owed) {
    // the surplus, valued back in the paying currency, must be below one rounding step
    const back = p.currency === target ? converted - owed : convertMinor(converted - owed, rateBetween(db, target, p.currency, ctx.now), tgtCur.minor_units, payCur.minor_units);
    const step = Math.max(payCur.rounding_increment_minor ?? 0, 1);
    if (back >= step) throw new SetupError('overpaid', 'That is more than is owed.', );
    applied = owed;
  }
  return { applied, rate, opens_drawer: m.opens_drawer === 1 };
}

/** A payment on the customer's account, against the debt in `debt_currency`. */
export function receiveAccountPayment(
  db: DatabaseSync, ctx: SetupContext & { receipt_prefix: string },
  input: PaymentInput & { customer_id: string; debt_currency: string }, newId: () => string = randomUUID,
): PaymentResult {
  allow(db, ctx, 'sale.create');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from customers where id = ? and deleted_at is null', input.customer_id)) throw new SetupError('unknown_customer', 'That customer was not found.');
    const owed = (w.get('select coalesce(sum(amount_minor), 0) as b from customer_ledger where customer_id = ? and currency = ?', input.customer_id, input.debt_currency)!.b) as number;
    const { applied, rate, opens_drawer } = applyPayment(db, ctx, input, input.debt_currency, owed);
    const receipt_no = nextPaymentNo(db, ctx.receipt_prefix);
    const payment_id = w.add('account_payments', {
      customer_id: input.customer_id, sale_id: null, receipt_no, method_code: input.method_code, currency: input.currency, amount_minor: input.amount_minor,
      target_currency: input.debt_currency, rate_to_target_micro: rate, applied_minor: applied, reference: input.reference?.trim() || null, user_id: ctx.user_id,
    });
    w.add('customer_ledger', { customer_id: input.customer_id, type: 'payment', currency: input.debt_currency, amount_minor: -applied, ref_type: 'account_payment', ref_id: payment_id });
    return { payment_id, receipt_no, applied_minor: applied, target_currency: input.debt_currency, balance_after_minor: owed - applied, opens_drawer };
  });
}

// ---- layby ----

export interface LaybySummary {
  sale_id: string; receipt_no: string; customer_id: string; customer: string; currency: string; total_minor: number; paid_minor: number; balance_minor: number;
  started_at: number; collected: boolean;
}

export function laybyPaid(db: DatabaseSync, saleId: string, saleCurrency: string, now: number): number {
  let paid = 0;
  for (const p of db.prepare('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?').all(saleId) as Row[]) {
    const v = p.currency === saleCurrency ? p.amount_minor : convertMinor(p.amount_minor, p.rate_to_sale_micro, currencyRow(db, p.currency).minor_units, currencyRow(db, saleCurrency).minor_units);
    paid += p.is_change ? -v : v;
  }
  const inst = db.prepare('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?').get(saleId) as Row;
  void now;
  return paid + inst.s;
}

export function laybys(db: DatabaseSync, o: { customer_id?: string; open_only?: boolean } = {}): LaybySummary[] {
  const rows = db.prepare(`select s.*, c.name as customer_name from sales s join customers c on c.id = s.customer_id where s.status = 'layby' ${o.customer_id ? 'and s.customer_id = ?' : ''} order by s.completed_at desc`)
    .all(...(o.customer_id ? [o.customer_id] : [])) as Row[];
  const out = rows.map((s) => {
    const paid = laybyPaid(db, s.id, s.sale_currency, 0);
    const collected = !!db.prepare("select 1 as x from layby_payments where sale_id = ? and payment_id is null and due_note = ?").get(s.id, COLLECTED);
    return { sale_id: s.id, receipt_no: s.receipt_no, customer_id: s.customer_id, customer: s.customer_name, currency: s.sale_currency, total_minor: s.total_minor, paid_minor: paid, balance_minor: Math.max(0, s.total_minor - paid), started_at: s.completed_at, collected };
  });
  return o.open_only ? out.filter((l) => !l.collected) : out;
}

/** An instalment on a layby, paid in any currency. */
export function payLayby(db: DatabaseSync, ctx: SetupContext & { receipt_prefix: string }, input: PaymentInput & { sale_id: string }, newId: () => string = randomUUID): PaymentResult {
  allow(db, ctx, 'sale.create');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const sale = w.get("select * from sales where id = ? and status = 'layby'", input.sale_id);
    if (!sale) throw new SetupError('not_layby', 'That is not a layby.');
    const l = laybys(db).find((x) => x.sale_id === sale.id)!;
    if (l.collected) throw new SetupError('already_collected', 'This layby was already collected.');
    const { applied, rate, opens_drawer } = applyPayment(db, ctx, input, sale.sale_currency, l.balance_minor);
    const receipt_no = nextPaymentNo(db, ctx.receipt_prefix);
    const payment_id = w.add('account_payments', {
      customer_id: sale.customer_id, sale_id: sale.id, receipt_no, method_code: input.method_code, currency: input.currency, amount_minor: input.amount_minor,
      target_currency: sale.sale_currency, rate_to_target_micro: rate, applied_minor: applied, reference: input.reference?.trim() || null, user_id: ctx.user_id,
    });
    w.add('layby_payments', { sale_id: sale.id, payment_id, due_note: null });
    return { payment_id, receipt_no, applied_minor: applied, target_currency: sale.sale_currency, balance_after_minor: l.balance_minor - applied, opens_drawer };
  });
}

/** Hands the goods over. Only when the layby is fully paid. */
export function collectLayby(db: DatabaseSync, ctx: SetupContext, saleId: string, newId: () => string = randomUUID): void {
  allow(db, ctx, 'sale.create');
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const l = laybys(db).find((x) => x.sale_id === saleId);
    if (!l) throw new SetupError('not_layby', 'That is not a layby.');
    if (l.collected) throw new SetupError('already_collected', 'This layby was already collected.');
    if (l.balance_minor > 0) throw new SetupError('balance_due', 'The layby is not fully paid yet.');
    w.add('layby_payments', { sale_id: saleId, payment_id: null, due_note: COLLECTED });
  });
}

// ---- statement ----

export interface StatementLine { at: number; type: string; currency: string; amount_minor: number; balance_minor: number; ref: string | null }
/** Every ledger entry with a running balance per currency, oldest first. */
export function statement(db: DatabaseSync, customerId: string): StatementLine[] {
  const rows = db.prepare('select * from customer_ledger where customer_id = ? order by created_at, rowid').all(customerId) as Row[];
  const run: Record<string, number> = {};
  return rows.map((r) => {
    run[r.currency] = (run[r.currency] ?? 0) + r.amount_minor;
    let ref: string | null = null;
    if (r.ref_type === 'sale') ref = (db.prepare('select receipt_no from sales where id = ?').get(r.ref_id) as Row | undefined)?.receipt_no ?? null;
    else if (r.ref_type === 'account_payment') ref = (db.prepare('select receipt_no from account_payments where id = ?').get(r.ref_id) as Row | undefined)?.receipt_no ?? null;
    return { at: r.created_at, type: r.type, currency: r.currency, amount_minor: r.amount_minor, balance_minor: run[r.currency]!, ref };
  });
}
