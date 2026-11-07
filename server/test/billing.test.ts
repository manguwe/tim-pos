import test from 'node:test';
import assert from 'node:assert/strict';
import { boot, makeShop, DAY, START, vendorToken, type Harness } from './helpers.ts';

const line = (description: string, quantity: number, unit_price_minor: number, extra: Record<string, unknown> = {}) => ({ description, quantity, unit_price_minor, ...extra });

async function setup(o: { tax_bp?: number } = {}) {
  const h = await boot({ vendorTokenTtlMs: 3000 * DAY }); // the test moves the clock by months
  const shop = await makeShop(h, { months: 3 });
  const A = shop.vendor;
  if (o.tax_bp !== undefined) await h.call('PUT', '/v1/vendor/billing/profile', { auth: A, body: { default_tax_bp: o.tax_bp } });
  const invoice = (body: Record<string, unknown> = {}, tenant = shop.tenantId) =>
    h.call('POST', `/v1/vendor/tenants/${tenant}/invoices`, { auth: A, body: { currency: 'USD', lines: [line('Set-up fee', 1, 12000)], ...body } });
  const pay = (id: string, body: Record<string, unknown>) =>
    h.call('POST', `/v1/vendor/invoices/${id}/payments`, { auth: A, body: { method: 'cash', ...body } });
  const get = async (id: string) => (await h.call('GET', `/v1/vendor/invoices/${id}`, { auth: A })).json;
  return { h, shop, A, invoice, pay, get };
}

test('every billing route needs a vendor sign-in', async () => {
  const h = await boot({ vendorTokenTtlMs: 3000 * DAY }); // the test moves the clock by months
  try {
    for (const [m, p] of [['GET', '/billing/profile'], ['PUT', '/billing/profile'], ['POST', '/billing/run'], ['GET', '/invoices'], ['GET', '/invoices/x'], ['POST', '/invoices/x/void'],
      ['POST', '/invoices/x/payments'], ['GET', '/payments'], ['POST', '/payments/x/reverse'], ['POST', '/tenants/x/invoices'], ['GET', '/tenants/x/statement']] as const) {
      const r = await h.call(m, `/v1/vendor${p}`, { body: {} });
      assert.equal(r.status, 401, `${m} ${p}`);
    }
  } finally { await h.close(); }
});

test('an invoice adds up, rounds tax, and numbers run without gaps', async () => {
  const { h, invoice, get } = await setup({ tax_bp: 1500 }); // 15%
  try {
    const a = await invoice({ lines: [line('Set-up fee', 1, 12000), line('Training', 3, 999)] });
    assert.equal(a.status, 201);
    assert.equal(a.json.number, 'INV-2026-0001');
    // subtotal 12000 + 2997 = 14997; tax 15% = 2249.55 -> 2250; total 17247
    const d = await get(a.json.id);
    assert.deepEqual([d.subtotal_minor, d.tax_bp, d.tax_minor, d.total_minor, d.balance_minor, d.state, d.overdue], [14997, 1500, 2250, 17247, 17247, 'unpaid', false]);
    assert.deepEqual(d.lines.map((l: any) => l.line_total_minor), [12000, 2997]);
    const b = await invoice({ tax_bp: 0 });
    assert.equal(b.json.number, 'INV-2026-0002');
    assert.equal((await get(b.json.id)).tax_minor, 0);
    h.clock.t = Date.UTC(2027, 0, 5);
    assert.equal((await invoice()).json.number, 'INV-2027-0001'); // a new year starts again at 1
  } finally { await h.close(); }
});

test('bad invoices are refused', async () => {
  const { h, shop, invoice } = await setup();
  try {
    const other = await h.call('POST', '/v1/vendor/tenants', { auth: shop.vendor, body: { name: 'Other', country_code: 'ZW' } });
    const otherLic = await h.call('POST', `/v1/vendor/tenants/${other.json.id}/licences`, { auth: shop.vendor, body: { months: 1 } });
    for (const body of [
      { lines: [] }, { lines: [line('x', 0, 100)] }, { lines: [line('x', 1, -1)] }, { lines: [line('x', 1.5, 100)] }, { lines: [line('', 1, 100)] },
      { lines: [line('free', 1, 0)] }, { currency: 'dollars' }, { currency: 'US1' }, { tax_bp: 10001 }, { due_at: h.clock.t - 5 * DAY },
      { lines: [line('x', 1, 100, { kind: 'weekly' })] }, { lines: [line('x', 1, 100, { licence_id: otherLic.json.id })] }, { lines: [line('x', 10_000, 100_000_000_000)] },
      { lines: Array.from({ length: 51 }, () => line('x', 1, 1)) },
    ]) {
      assert.equal((await invoice(body)).status, 400, JSON.stringify(body).slice(0, 80));
    }
    assert.equal((await invoice({}, 'nope')).status, 404);
    assert.equal((await h.call('GET', '/v1/vendor/invoices', { auth: shop.vendor })).json.invoices.length, 0); // nothing half-saved
  } finally { await h.close(); }
});

test('payments: partly, fully, never more than the balance, receipts numbered', async () => {
  const { h, shop, invoice, pay, get } = await setup();
  try {
    const inv = (await invoice()).json; // 12000
    assert.equal((await pay(inv.id, { amount_minor: 12001 })).status, 400);
    const p1 = await pay(inv.id, { amount_minor: 5000, note: 'deposit' });
    assert.equal(p1.status, 201);
    assert.equal(p1.json.payment.receipt_no, 'RCT-2026-0001');
    assert.deepEqual([p1.json.invoice.state, p1.json.invoice.balance_minor], ['partly_paid', 7000]);
    assert.equal((await pay(inv.id, { amount_minor: 7001 })).json.error.code, 'overpayment');
    const p2 = await pay(inv.id, { amount_minor: 7000 });
    assert.deepEqual([p2.json.payment.receipt_no, p2.json.invoice.state, p2.json.invoice.balance_minor], ['RCT-2026-0002', 'paid', 0]);
    assert.equal((await pay(inv.id, { amount_minor: 1 })).json.error.code, 'already_paid');
    const d = await get(inv.id);
    assert.equal(d.payments.length, 2);
    assert.equal(d.payments[0].recorded_by, 'Tim');
    assert.equal(h.ctx.db.get<{ n: number }>("select count(*) as n from vendor_audit_log where action = 'payment.record'")?.n, 2);
    void shop;
  } finally { await h.close(); }
});

test('payment details: method, reference and date rules', async () => {
  const { h, invoice, pay } = await setup();
  try {
    const inv = (await invoice()).json;
    assert.equal((await pay(inv.id, { amount_minor: 100, method: 'ecocash' })).json.error.message.match(/reference/i)?.length, 1); // mobile money needs a reference
    assert.equal((await pay(inv.id, { amount_minor: 100, method: 'bank' })).status, 400);
    assert.equal((await pay(inv.id, { amount_minor: 100, method: 'ecocash', reference: 'MP261104.1234' })).status, 201);
    assert.equal((await pay(inv.id, { amount_minor: 100, method: 'cheque' })).status, 400);
    for (const bad of [0, -5, 1.5, '100']) assert.equal((await pay(inv.id, { amount_minor: bad })).status, 400);
    assert.equal((await pay(inv.id, { amount_minor: 100, received_at: h.clock.t + 3 * DAY })).status, 400);
    assert.equal((await pay(inv.id, { amount_minor: 100, received_at: h.clock.t - 2 * DAY })).status, 201); // back-dated is fine
    assert.equal((await pay('nope', { amount_minor: 100 })).status, 404);
  } finally { await h.close(); }
});

test('the same request id records a payment only once', async () => {
  const { h, invoice, pay, get } = await setup();
  try {
    const inv = (await invoice()).json;
    const a = await pay(inv.id, { amount_minor: 3000, request_id: 'form-1' });
    const b = await pay(inv.id, { amount_minor: 3000, request_id: 'form-1' });
    assert.deepEqual([a.status, b.status, b.json.duplicate, b.json.payment.id === a.json.payment.id], [201, 200, true, true]);
    assert.equal((await get(inv.id)).balance_minor, 9000);
    assert.equal((await pay(inv.id, { amount_minor: 4000, request_id: 'form-1' })).json.error.code, 'request_reused');
  } finally { await h.close(); }
});

test('reversing a payment puts the balance back, and cannot be done twice', async () => {
  const { h, A, invoice, pay, get } = await setup();
  try {
    const inv = (await invoice()).json;
    const p = (await pay(inv.id, { amount_minor: 12000 })).json.payment;
    assert.equal((await h.call('POST', `/v1/vendor/payments/${p.id}/reverse`, { auth: A, body: { reason: 'x' } })).status, 400); // reason too short
    const r = await h.call('POST', `/v1/vendor/payments/${p.id}/reverse`, { auth: A, body: { reason: 'Cheque bounced' } });
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.invoice.state, r.json.invoice.balance_minor], ['unpaid', 12000]);
    assert.equal((await h.call('POST', `/v1/vendor/payments/${p.id}/reverse`, { auth: A, body: { reason: 'again' } })).json.error.code, 'already_reversed');
    const d = await get(inv.id);
    assert.equal(d.payments[0].reverse_reason, 'Cheque bounced');
    assert.equal((await pay(inv.id, { amount_minor: 12000 })).status, 201); // can be paid again; receipt numbers keep counting
    assert.equal((await h.call('POST', '/v1/vendor/payments/nope/reverse', { auth: A, body: { reason: 'abc' } })).status, 404);
  } finally { await h.close(); }
});

test('voiding: only with no live payments, needs a reason, frees the month', async () => {
  const { h, A, invoice, pay, get } = await setup();
  try {
    const inv = (await invoice()).json;
    const p = (await pay(inv.id, { amount_minor: 100 })).json.payment;
    assert.equal((await h.call('POST', `/v1/vendor/invoices/${inv.id}/void`, { auth: A, body: { reason: 'Wrong shop' } })).json.error.code, 'has_payments');
    await h.call('POST', `/v1/vendor/payments/${p.id}/reverse`, { auth: A, body: { reason: 'Entered in error' } });
    assert.equal((await h.call('POST', `/v1/vendor/invoices/${inv.id}/void`, { auth: A, body: {} })).status, 400);
    const v = await h.call('POST', `/v1/vendor/invoices/${inv.id}/void`, { auth: A, body: { reason: 'Wrong shop' } });
    assert.deepEqual([v.status, v.json.state, v.json.balance_minor], [200, 'void', 0]);
    assert.equal((await h.call('POST', `/v1/vendor/invoices/${inv.id}/void`, { auth: A, body: { reason: 'again' } })).json.error.code, 'already_void');
    assert.equal((await pay(inv.id, { amount_minor: 100 })).json.error.code, 'already_void');
    assert.equal((await get(inv.id)).void_reason, 'Wrong shop');
  } finally { await h.close(); }
});

test('records cannot be edited or deleted underneath the app', async () => {
  const { h, invoice, pay } = await setup();
  try {
    const inv = (await invoice()).json;
    const p = (await pay(inv.id, { amount_minor: 100 })).json.payment;
    const run = (sql: string) => assert.throws(() => h.ctx.db.run(sql), /never deleted|cannot be changed|only reversed|only voided/, sql);
    run('delete from invoices');
    run('delete from invoice_lines');
    run('delete from payments');
    run("update invoices set total_minor = 1");
    run("update invoices set number = 'X'");
    run("update invoice_lines set quantity = 9");
    run("update payments set amount_minor = 1");
    run(`update payments set currency = 'ZAR'`);
    h.ctx.db.run("update payments set reversed_at = 1, reverse_reason = 'ok', reversed_by = null where id = ?", p.id);
    run("update payments set reversed_at = null, reverse_reason = null");
    run("update payments set amount_minor = 5");
  } finally { await h.close(); }
});

test('overdue is an unpaid balance past the due date', async () => {
  const { h, A, invoice, pay } = await setup();
  try {
    const a = (await invoice({ due_at: h.clock.t + 2 * DAY })).json;
    const b = (await invoice({ due_at: h.clock.t + 2 * DAY })).json;
    await pay(b.id, { amount_minor: 12000 });
    const list = async (q: string) => (await h.call('GET', `/v1/vendor/invoices?status=${q}`, { auth: A })).json.invoices.map((i: any) => i.id);
    assert.deepEqual([await list('overdue'), (await list('open')).length, (await list('paid')).length], [[], 1, 1]);
    h.clock.t += 5 * DAY;
    assert.deepEqual([await list('overdue'), await list('paid')], [[a.id], [b.id]]); // a paid invoice is never overdue
    assert.equal((await h.call('GET', '/v1/vendor/invoices?status=bogus', { auth: A })).status, 400);
  } finally { await h.close(); }
});

test('paying can extend a licence in the same step, only a licence of that shop', async () => {
  const { h, shop, A, invoice, pay } = await setup();
  try {
    const before = h.ctx.db.get<{ expires_at: number }>('select expires_at from licences where id = ?', shop.licenceId)?.expires_at as number;
    const inv = (await invoice()).json;
    const other = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Other', country_code: 'ZW' } });
    const otherLic = await h.call('POST', `/v1/vendor/tenants/${other.json.id}/licences`, { auth: A, body: { months: 1 } });
    assert.equal((await pay(inv.id, { amount_minor: 100, extend_licence: { licence_id: otherLic.json.id, months: 1 } })).status, 400);
    assert.equal((await pay(inv.id, { amount_minor: 100, extend_licence: { licence_id: shop.licenceId, months: 0 } })).status, 400);
    const r = await pay(inv.id, { amount_minor: 100, extend_licence: { licence_id: shop.licenceId, months: 2 } });
    assert.equal(r.status, 201);
    const after = h.ctx.db.get<{ expires_at: number }>('select expires_at from licences where id = ?', shop.licenceId)?.expires_at as number;
    assert.ok(after > before + 55 * DAY);
    assert.equal(r.json.payment.extended_months, 2);
    const rev = await h.call('POST', `/v1/vendor/payments/${r.json.payment.id}/reverse`, { auth: A, body: { reason: 'Bounced' } });
    assert.equal(rev.json.licence_still_extended, true);
    assert.equal(h.ctx.db.get<{ expires_at: number }>('select expires_at from licences where id = ?', shop.licenceId)?.expires_at, after);
    // a refused payment must not extend anything
    const e2 = await pay(inv.id, { amount_minor: 999_999, extend_licence: { licence_id: shop.licenceId, months: 5 } });
    assert.equal(e2.status, 400);
    assert.equal(h.ctx.db.get<{ expires_at: number }>('select expires_at from licences where id = ?', shop.licenceId)?.expires_at, after);
  } finally { await h.close(); }
});

async function withPlan(h: Harness, A: string, fee = 1500, currency = 'USD') {
  const p = await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: `Plan ${fee}${currency}`, monthly_fee_minor: fee, currency, max_devices: 2 } });
  return p.json.id as string;
}

test('the monthly run bills each active licence once, safely repeatable', async () => {
  const h = await boot({ vendorTokenTtlMs: 3000 * DAY }); // the test moves the clock by months
  try {
    const A = await vendorToken(h);
    const planId = await withPlan(h, A);
    const mk = async (name: string) => {
      const t = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name, country_code: 'ZW' } });
      const l = await h.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, { auth: A, body: { months: 6, plan_id: planId } });
      return { tenant: t.json.id as string, licence: l.json.id as string };
    };
    const s1 = await mk('Alpha'), s2 = await mk('Beta'), s3 = await mk('Gamma');
    await h.call('POST', `/v1/vendor/licences/${s2.licence}/suspend`, { auth: A }); // not billed
    await h.call('PATCH', `/v1/vendor/tenants/${s3.tenant}`, { auth: A, body: { status: 'suspended' } }); // not billed
    const noPlan = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Delta', country_code: 'ZW' } });
    await h.call('POST', `/v1/vendor/tenants/${noPlan.json.id}/licences`, { auth: A, body: { months: 6 } }); // no plan: not billed
    const run = (b: Record<string, unknown>) => h.call('POST', '/v1/vendor/billing/run', { auth: A, body: b });

    const dry = await run({ month: '2026-11', dry_run: true });
    assert.deepEqual([dry.json.created.length, dry.json.dry_run, dry.json.created[0].tenant_name], [1, true, 'Alpha']);
    assert.equal((await h.call('GET', '/v1/vendor/invoices', { auth: A })).json.invoices.length, 0);

    const r = await run({ month: '2026-11' });
    assert.equal(r.status, 200);
    assert.deepEqual([r.json.created.length, r.json.already_billed, r.json.created[0].total_minor, r.json.created[0].number], [1, 0, 1500, 'INV-2026-0001']);
    const again = await run({ month: '2026-11' });
    assert.deepEqual([again.json.created.length, again.json.already_billed], [0, 1]);
    const d = (await h.call('GET', `/v1/vendor/invoices/${r.json.created[0].id}`, { auth: A })).json;
    assert.match(d.lines[0].description, /November 2026/);
    assert.equal(d.lines[0].kind, 'monthly');
    assert.equal((await run({ month: '2026-12' })).json.created.length, 1); // next month is allowed

    // voiding frees the month to be billed again
    await h.call('POST', `/v1/vendor/invoices/${r.json.created[0].id}/void`, { auth: A, body: { reason: 'Billed in error' } });
    assert.equal((await run({ month: '2026-11' })).json.created.length, 1);
    for (const month of ['2027-02', '2023-12', '2026-13', '2026-1', 'nov', 5]) assert.equal((await run({ month })).status, 400, String(month));
    void s1;
  } finally { await h.close(); }
});

test('the monthly run skips months a licence does not cover', async () => {
  const h = await boot({ vendorTokenTtlMs: 3000 * DAY }); // the test moves the clock by months
  try {
    const A = await vendorToken(h);
    const planId = await withPlan(h, A);
    const t = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Short', country_code: 'ZW' } });
    await h.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, { auth: A, body: { months: 1, plan_id: planId } }); // issued 1 Nov, ends 1 Dec
    const run = (month: string) => h.call('POST', '/v1/vendor/billing/run', { auth: A, body: { month } });
    h.clock.t = START + 40 * DAY; // 11 Dec: licence has ended
    assert.equal((await run('2026-12')).json.created.length, 0);
  } finally { await h.close(); }
});

test('statements and the overview add up per currency', async () => {
  const { h, shop, A, invoice, pay } = await setup();
  try {
    const usd = (await invoice({ due_at: h.clock.t + DAY })).json; // 12000
    await invoice({ currency: 'ZWG', lines: [line('Fee', 1, 50000)], due_at: h.clock.t + 30 * DAY });
    const voided = (await invoice({ lines: [line('Oops', 1, 777)] })).json;
    await h.call('POST', `/v1/vendor/invoices/${voided.id}/void`, { auth: A, body: { reason: 'Mistake' } });
    await pay(usd.id, { amount_minor: 2000 });
    h.clock.t += 3 * DAY;
    const st = (await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}/statement`, { auth: A })).json;
    assert.deepEqual(st.balances, [
      { currency: 'USD', invoiced_minor: 12000, paid_minor: 2000, owed_minor: 10000, overdue_minor: 10000 },
      { currency: 'ZWG', invoiced_minor: 50000, paid_minor: 0, owed_minor: 50000, overdue_minor: 0 },
    ]);
    assert.equal(st.invoices.length, 3);
    const o = (await h.call('GET', '/v1/vendor/overview', { auth: A })).json;
    assert.deepEqual(o.owed, [{ currency: 'USD', minor: 10000 }, { currency: 'ZWG', minor: 50000 }]);
    assert.equal(o.overdue_invoices, 1);
    assert.deepEqual(o.overdue_minor, [{ currency: 'USD', minor: 10000 }]);
    assert.equal((await h.call('GET', '/v1/vendor/tenants/nope/statement', { auth: A })).status, 404);
    const pays = (await h.call('GET', '/v1/vendor/payments', { auth: A })).json.payments;
    assert.deepEqual([pays.length, pays[0].invoice_number, pays[0].tenant_name], [1, usd.number, 'Mbare Mini Market']);
  } finally { await h.close(); }
});

test('billing details: validated, kept, and used on the invoice', async () => {
  const { h, A, invoice, get } = await setup();
  try {
    const put = (body: Record<string, unknown>) => h.call('PUT', '/v1/vendor/billing/profile', { auth: A, body });
    assert.equal((await put({ invoice_prefix: 'bad prefix' })).status, 400);
    assert.equal((await put({ default_tax_bp: 20000 })).status, 400);
    assert.equal((await put({ default_due_days: -1 })).status, 400);
    const r = await put({ business_name: 'Tim Systems', tax_number: 'BP 123', invoice_prefix: 'tp', default_due_days: 7, payment_instructions: 'EcoCash 0772 000 000' });
    assert.equal(r.status, 200);
    assert.equal(r.json.invoice_prefix, 'TP');
    const inv = (await invoice()).json;
    assert.equal(inv.number, 'TP-2026-0001');
    const d = await get(inv.id);
    assert.equal(d.profile.business_name, 'Tim Systems');
    assert.equal(Math.round((d.due_at - d.issued_at) / DAY), 7);
    assert.equal((await put({})).json.business_name, 'Tim Systems'); // an empty update changes nothing
  } finally { await h.close(); }
});
