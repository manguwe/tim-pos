/**
 * Shifts and cash-up. Reference implementation; app/lib/shifts/shift_repository.dart is a port.
 *
 * A shift is one cashier's session at a till. It starts with a float (cash already in the drawer, per currency).
 * Cash moves in and out of the drawer during the shift by sales, change, account and layby payments in cash, and
 * cash events (cash in, cash out, bank drop). At the end the cashier counts each currency; the app shows the
 * difference from what the drawer should hold. Closing never blocks on a difference: it is recorded, and the owner sees it.
 *
 * Expected cash per currency =
 *     float + cash taken on this shift's sales + cash taken on account/layby payments by this cashier during the shift
 *           - change given - cash refunded to customers - cash out - bank drops + cash in
 * Only payment methods of kind 'cash' count; mobile money and card are listed separately as takings.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission } from './auth.ts';

type Row = Record<string, any>;

function allow(db: DatabaseSync, ctx: SetupContext) {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, 'shift.manage')) throw new SetupError('forbidden', 'You are not allowed to do that.');
}
const isMinor = (n: unknown) => Number.isSafeInteger(n) && (n as number) >= 0 && (n as number) <= 10_000_000_000;

export function currentShift(db: DatabaseSync, userId: string | null): Row | undefined {
  const r = db.prepare("select * from shifts where user_id is ? and status = 'open' and deleted_at is null order by opened_at desc limit 1").get(userId) as Row | undefined;
  return r ? { ...r } : undefined;
}

/** Starts a shift. `float` is the cash in the drawer per currency; currencies not listed start at zero. */
export function openShift(db: DatabaseSync, ctx: SetupContext, input: { branch_id: string; float: Record<string, number> }, newId: () => string = randomUUID): string {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from branches where id = ? and deleted_at is null', input.branch_id)) throw new SetupError('unknown_branch', 'That branch was not found.');
    if (currentShift(db, ctx.user_id)) throw new SetupError('shift_open', 'You already have a shift open. Close it first.');
    const currencies = w.all('select code from currencies where deleted_at is null and is_active = 1 order by code').map((c) => c.code as string);
    for (const [code, amt] of Object.entries(input.float)) {
      if (!currencies.includes(code)) throw new SetupError('unknown_currency', `Currency ${code} is not set up.`);
      if (!isMinor(amt)) throw new SetupError('bad_amount', 'The float must be zero or more.');
    }
    const id = w.addVersioned('shifts', { branch_id: input.branch_id, user_id: ctx.user_id, opened_at: ctx.now, closed_at: null, status: 'open' });
    for (const code of currencies) w.addVersioned('shift_cash', { shift_id: id, currency: code, opening_float_minor: input.float[code] ?? 0, expected_minor: null, counted_minor: null, difference_minor: null });
    return id;
  });
}

export type CashEventType = 'cash_in' | 'cash_out' | 'bank_drop';

/** Money put into or taken out of the drawer outside a sale. The amount is always positive; the type says which way it goes. */
export function addCashEvent(db: DatabaseSync, ctx: SetupContext, input: { shift_id: string; currency: string; type: CashEventType; amount_minor: number; reason?: string | null }, newId: () => string = randomUUID): string {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const sh = w.get('select * from shifts where id = ?', input.shift_id);
    if (!sh || sh.status !== 'open') throw new SetupError('shift_closed', 'That shift is not open.');
    if (!['cash_in', 'cash_out', 'bank_drop'].includes(input.type)) throw new SetupError('bad_type', 'Unknown cash movement.');
    if (!Number.isSafeInteger(input.amount_minor) || input.amount_minor <= 0) throw new SetupError('bad_amount', 'The amount must be more than zero.');
    if (!w.get('select 1 as x from shift_cash where shift_id = ? and currency = ?', input.shift_id, input.currency)) throw new SetupError('unknown_currency', `Currency ${input.currency} is not set up.`);
    const reason = input.reason?.trim() || null;
    if (input.type !== 'bank_drop' && !reason) throw new SetupError('reason_needed', 'Say why the cash is moving.');
    if (input.type !== 'cash_in') {
      const have = expectedCash(db, input.shift_id)[input.currency] ?? 0;
      if (input.amount_minor > have) throw new SetupError('not_enough_cash', 'There is not that much cash in the drawer.');
    }
    return w.add('cash_events', { shift_id: input.shift_id, currency: input.currency, type: input.type, amount_minor: input.amount_minor, reason });
  });
}

/** What the drawer should hold now, per currency. */
export function expectedCash(db: DatabaseSync, shiftId: string): Record<string, number> {
  const sh = db.prepare('select * from shifts where id = ?').get(shiftId) as Row | undefined;
  if (!sh) throw new SetupError('unknown_shift', 'That shift was not found.');
  const out: Record<string, number> = {};
  for (const r of db.prepare('select currency, opening_float_minor from shift_cash where shift_id = ?').all(shiftId) as Row[]) out[r.currency] = r.opening_float_minor ?? 0;
  const add = (cur: string, v: number) => { out[cur] = (out[cur] ?? 0) + v; };
  const until = sh.closed_at ?? Number.MAX_SAFE_INTEGER;
  for (const r of db.prepare(`select sp.currency, sp.amount_minor, sp.is_change from sale_payments sp join sales s on s.id = sp.sale_id join payment_methods pm on pm.code = sp.method_code
      where s.shift_id = ? and pm.kind = 'cash'`).all(shiftId) as Row[]) add(r.currency, r.is_change ? -r.amount_minor : r.amount_minor);
  for (const r of db.prepare(`select ap.currency, ap.amount_minor from account_payments ap join payment_methods pm on pm.code = ap.method_code
      where ap.user_id is ? and ap.created_at >= ? and ap.created_at <= ? and pm.kind = 'cash'`).all(sh.user_id, sh.opened_at, until) as Row[]) add(r.currency, r.amount_minor);
  for (const r of db.prepare(`select rp.currency, rp.amount_minor from return_payouts rp join sale_returns r on r.id = rp.return_id join payment_methods pm on pm.code = rp.method_code
      where r.shift_id = ? and pm.kind = 'cash'`).all(shiftId) as Row[]) add(r.currency, -r.amount_minor);
  for (const r of db.prepare('select currency, type, amount_minor from cash_events where shift_id = ?').all(shiftId) as Row[]) add(r.currency, r.type === 'cash_in' ? r.amount_minor : -r.amount_minor);
  return out;
}

export interface ShiftReport {
  shift_id: string; status: string; opened_at: number; closed_at: number | null; user: string | null;
  sales: number; voided: number;
  sold: { currency: string; total_minor: number }[];
  takings: { method: string; currency: string; amount_minor: number }[];
  /** Money paid back to customers during this shift (returns, voids). */
  refunds: { method: string; currency: string; amount_minor: number }[];
  float: Record<string, number>; expected: Record<string, number>; counted: Record<string, number | null>; difference: Record<string, number | null>;
  events: { type: string; currency: string; amount_minor: number; reason: string | null }[];
}

export function shiftReport(db: DatabaseSync, shiftId: string): ShiftReport {
  const sh = db.prepare('select * from shifts where id = ?').get(shiftId) as Row | undefined;
  if (!sh) throw new SetupError('unknown_shift', 'That shift was not found.');
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as Row[];
  const cash = q('select * from shift_cash where shift_id = ? order by currency', shiftId);
  const expectedNow = expectedCash(db, shiftId);
  const closed = sh.status === 'closed';
  const rec = <T>(f: (r: Row) => T) => Object.fromEntries(cash.map((c) => [c.currency, f(c)]));
  return {
    shift_id: shiftId, status: sh.status, opened_at: sh.opened_at, closed_at: sh.closed_at ?? null,
    user: sh.user_id ? (q('select name from users where id = ?', sh.user_id)[0]?.name ?? null) : null,
    sales: q("select count(*) as c from sales s where s.shift_id = ? and not exists (select 1 from sale_voids v where v.sale_id = s.id)", shiftId)[0]!.c,
    voided: q("select count(*) as c from sales s where s.shift_id = ? and exists (select 1 from sale_voids v where v.sale_id = s.id)", shiftId)[0]!.c,
    sold: q("select s.sale_currency as currency, sum(s.total_minor) as total_minor from sales s where s.shift_id = ? and not exists (select 1 from sale_voids v where v.sale_id = s.id) group by s.sale_currency order by s.sale_currency", shiftId) as any,
    takings: q(`select pm.name as method, sp.currency, sum(case when sp.is_change = 1 then -sp.amount_minor else sp.amount_minor end) as amount_minor
        from sale_payments sp join sales s on s.id = sp.sale_id join payment_methods pm on pm.code = sp.method_code where s.shift_id = ?
        group by pm.name, sp.currency order by pm.name, sp.currency`, shiftId) as any,
    refunds: q(`select pm.name as method, rp.currency, sum(rp.amount_minor) as amount_minor from return_payouts rp join sale_returns r on r.id = rp.return_id join payment_methods pm on pm.code = rp.method_code
        where r.shift_id = ? group by pm.name, rp.currency order by pm.name, rp.currency`, shiftId) as any,
    float: rec((c) => c.opening_float_minor ?? 0),
    expected: closed ? rec((c) => c.expected_minor) : expectedNow,
    counted: rec((c) => c.counted_minor ?? null),
    difference: rec((c) => c.difference_minor ?? null),
    events: q('select type, currency, amount_minor, reason from cash_events where shift_id = ? order by created_at, rowid', shiftId) as any,
  };
}

/**
 * Ends the shift. `counted` must list every currency in the drawer (zero is a valid count).
 * The expected amount and difference are stored on the shift so they never change afterwards.
 */
export function closeShift(db: DatabaseSync, ctx: SetupContext, shiftId: string, counted: Record<string, number>, newId: () => string = randomUUID): ShiftReport {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const sh = w.get('select * from shifts where id = ?', shiftId);
    if (!sh) throw new SetupError('unknown_shift', 'That shift was not found.');
    if (sh.status !== 'open') throw new SetupError('shift_closed', 'That shift is already closed.');
    if (ctx.user_id && sh.user_id !== ctx.user_id && !hasPermission(db, ctx.user_id, 'report.view')) throw new SetupError('forbidden', 'Only the cashier or a manager can close this shift.');
    const cash = w.all('select * from shift_cash where shift_id = ?', shiftId);
    for (const c of cash) if (!isMinor(counted[c.currency])) throw new SetupError('count_needed', `Count the ${c.currency} cash in the drawer.`);
    for (const code of Object.keys(counted)) if (!cash.some((c) => c.currency === code)) throw new SetupError('unknown_currency', `Currency ${code} is not part of this shift.`);
    const exp = expectedCash(db, shiftId);
    // closed_at is set first so a late payment can never change the stored expectation
    w.edit('shifts', shiftId, { status: 'closed', closed_at: ctx.now });
    for (const c of cash) {
      const e = exp[c.currency] ?? 0;
      w.edit('shift_cash', c.id, { expected_minor: e, counted_minor: counted[c.currency], difference_minor: counted[c.currency]! - e });
    }
  });
  return shiftReport(db, shiftId);
}
