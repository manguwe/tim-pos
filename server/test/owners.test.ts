import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { DAY, START, activateDevice, boot, change, makeShop, push, type Harness } from './helpers.ts';
import { TABLES } from '../src/tables.ts';

let h: Harness;
before(async () => { h = await boot({ vendorTokenTtlMs: 5000 * DAY }); });
after(async () => { await h.close(); });

const bearer = (t: string) => `Bearer ${t}`;
async function makeOwner(shop: { vendor: string; tenantId: string }, email = `owner-${Math.random().toString(16).slice(2)}@example.com`) {
  const r = await h.call('POST', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor, body: { name: 'Mrs Moyo', email } });
  assert.equal(r.status, 201, JSON.stringify(r.json));
  return { id: r.json.owner.id as string, email, temp: r.json.temporary_password as string };
}
async function signIn(email: string, password: string) {
  return h.call('POST', '/v1/owner/login', { body: { email, password } });
}
/** An owner who has already chosen their own password. */
async function readyOwner(shop: { vendor: string; tenantId: string }) {
  const o = await makeOwner(shop);
  const first = await signIn(o.email, o.temp);
  const changed = await h.call('POST', '/v1/owner/password', { auth: bearer(first.json.token), body: { current_password: o.temp, new_password: 'my-own-password-1' } });
  assert.equal(changed.status, 200, JSON.stringify(changed.json));
  return { ...o, token: changed.json.token as string, password: 'my-own-password-1' };
}
const range = (from = START, to = START + DAY) => `from=${from}&to=${to}`;

test('a vendor makes an owner login with a one-time password that must be changed before reports open', async () => {
  const shop = await makeShop(h);
  const o = await makeOwner(shop);
  assert.match(o.temp, /^[a-z2-9]{4}(-[a-z2-9]{4}){3}$/);
  const list = await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor });
  assert.equal(list.json.owners.length, 1);
  assert.equal(JSON.stringify(list.json).includes('password_hash'), false, 'hashes never leave the server');
  const s = await signIn(o.email, o.temp);
  assert.equal(s.status, 200);
  assert.equal(s.json.user.must_change_password, true);
  const blocked = await h.call('GET', `/v1/owner/reports/summary?${range()}`, { auth: bearer(s.json.token) });
  assert.equal(blocked.status, 403);
  assert.equal(blocked.json.error.code, 'password_change_required');
  const weak = await h.call('POST', '/v1/owner/password', { auth: bearer(s.json.token), body: { current_password: o.temp, new_password: 'short' } });
  assert.equal(weak.status, 400);
  const wrong = await h.call('POST', '/v1/owner/password', { auth: bearer(s.json.token), body: { current_password: 'nope', new_password: 'a-long-new-password' } });
  assert.equal(wrong.status, 403);
  const good = await h.call('POST', '/v1/owner/password', { auth: bearer(s.json.token), body: { current_password: o.temp, new_password: 'a-long-new-password' } });
  assert.equal(good.status, 200);
  const old = await h.call('GET', '/v1/owner/me', { auth: bearer(s.json.token) });
  assert.equal(old.status, 401, 'the old session ends when the password changes');
  const me = await h.call('GET', '/v1/owner/me', { auth: bearer(good.json.token) });
  assert.equal(me.json.shop.name, 'Mbare Mini Market');
  assert.equal(me.json.must_change_password, false);
  assert.equal((await signIn(o.email, o.temp)).status, 401, 'the temporary password stops working');
  assert.equal((await signIn(o.email, 'a-long-new-password')).status, 200);
});

test('duplicate emails, bad emails and unknown shops are refused', async () => {
  const shop = await makeShop(h);
  const o = await makeOwner(shop);
  const dup = await h.call('POST', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor, body: { name: 'X', email: o.email.toUpperCase() } });
  assert.equal(dup.status, 409);
  const bad = await h.call('POST', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor, body: { name: 'X', email: 'not-an-email' } });
  assert.equal(bad.status, 400);
  const none = await h.call('POST', '/v1/vendor/tenants/no-such-shop/owners', { auth: shop.vendor, body: { name: 'X', email: 'x@example.com' } });
  assert.equal(none.status, 404);
});

test('wrong passwords are limited, and unknown emails look the same as wrong passwords', async () => {
  const shop = await makeShop(h);
  const o = await makeOwner(shop);
  const unknown = await signIn('nobody@example.com', 'whatever-whatever');
  const wrong = await signIn(o.email, 'whatever-whatever');
  assert.equal(unknown.status, 401);
  assert.deepEqual(unknown.json, wrong.json);
  for (let i = 0; i < 4; i++) await signIn(o.email, 'whatever-whatever');
  const locked = await signIn(o.email, o.temp);
  assert.equal(locked.status, 429, 'five failures from one address block that email there');
});

test('vendor and owner sign-ins cannot be used on each other\'s routes', async () => {
  const shop = await makeShop(h);
  const o = await readyOwner(shop);
  assert.equal((await h.call('GET', '/v1/owner/me', { auth: shop.vendor })).status, 401);
  assert.equal((await h.call('GET', '/v1/vendor/overview', { auth: bearer(o.token) })).status, 401);
  assert.equal((await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: bearer(o.token) })).status, 401);
  assert.equal((await h.call('GET', '/v1/owner/me')).status, 401);
});

test('turning a login off, or resetting its password, ends open sessions at once', async () => {
  const shop = await makeShop(h);
  const o = await readyOwner(shop);
  assert.equal((await h.call('GET', '/v1/owner/me', { auth: bearer(o.token) })).status, 200);
  const off = await h.call('PATCH', `/v1/vendor/owners/${o.id}`, { auth: shop.vendor, body: { is_active: false } });
  assert.equal(off.json.is_active, false);
  assert.equal((await h.call('GET', '/v1/owner/me', { auth: bearer(o.token) })).status, 401);
  assert.equal((await signIn(o.email, o.password)).status, 401);
  await h.call('PATCH', `/v1/vendor/owners/${o.id}`, { auth: shop.vendor, body: { is_active: true } });
  const again = await signIn(o.email, o.password);
  assert.equal(again.status, 200);
  const reset = await h.call('POST', `/v1/vendor/owners/${o.id}/reset-password`, { auth: shop.vendor });
  assert.equal(reset.status, 200);
  assert.equal((await h.call('GET', '/v1/owner/me', { auth: bearer(again.json.token) })).status, 401);
  const next = await signIn(o.email, reset.json.temporary_password);
  assert.equal(next.json.user.must_change_password, true);
  const log = (await h.call('GET', '/v1/vendor/audit?limit=50', { auth: shop.vendor })).json.entries.map((e: any) => e.action);
  for (const a of ['owner.create', 'owner.disable', 'owner.enable', 'owner.reset_password']) assert.ok(log.includes(a), a);
});

test('an owner sees only their own shop, and a shop with no data gives empty reports', async () => {
  const a = await makeShop(h, { name: 'Shop A' });
  const b = await makeShop(h, { name: 'Shop B' });
  const da = await activateDevice(h, a.key);
  const oa = await readyOwner(a);
  const ob = await readyOwner(b);
  await push(h, da, [
    change('shops', { shop_id: a.tenantId, created_at: START, updated_at: START, version: 1, name: 'Shop A', country_code: 'ZW', base_currency: 'USD' }, { id: a.tenantId }),
    change('branches', { shop_id: a.tenantId, created_at: START, updated_at: START, version: 1, name: 'Main', is_active: 1 }, { id: 'branch-a-0001' }),
  ]);
  const ra = await h.call('GET', '/v1/owner/reports/branches', { auth: bearer(oa.token) });
  const rb = await h.call('GET', '/v1/owner/reports/branches', { auth: bearer(ob.token) });
  assert.deepEqual(ra.json.branches.map((x: any) => x.name), ['Main']);
  assert.deepEqual(rb.json.branches, []);
  const empty = await h.call('GET', `/v1/owner/reports/summary?${range()}`, { auth: bearer(ob.token) });
  assert.equal(empty.status, 200);
  assert.equal(empty.json.summary.sales, 0);
});

test('bad report requests are refused politely', async () => {
  const shop = await makeShop(h);
  const o = await readyOwner(shop);
  const get = (p: string) => h.call('GET', `/v1/owner/reports/${p}`, { auth: bearer(o.token) });
  assert.equal((await get('summary')).status, 400);
  assert.equal((await get(`summary?from=5&to=1`)).status, 400);
  assert.equal((await get(`summary?from=0&to=${500 * DAY}`)).status, 400);
  assert.equal((await get('expiring?today=tomorrow')).status, 400);
  assert.equal((await get('nonsense')).status, 404);
  assert.equal((await get(`products?${range()}&by=revenue&limit=9999`)).status, 200);
});

// ---- the main promise: what the owner sees is what the till shows ----

const TOOLS = new URL('../../tools/src/', import.meta.url);
test('owner reports match the phone\'s own reports on the same sales', { skip: !existsSync(new URL('reports.ts', TOOLS)) }, async () => {
  const { seedShop, saveProduct, receiveStock, setExchangeRate } = await import(new URL('setup.ts', TOOLS).href);
  const { sell } = await import(new URL('selling.ts', TOOLS).href);
  const { processReturn, voidSale, returnableLines } = await import(new URL('returns.ts', TOOLS).href);
  const rep = await import(new URL('reports.ts', TOOLS).href);

  const shop = await makeShop(h, { name: 'Fidelity Shop' });
  const dev = await activateDevice(h, shop.key);
  const owner = await readyOwner(shop);

  const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
  const phone = new DatabaseSync(':memory:');
  phone.exec(SQL);
  let n = 0;
  const uid = () => `fid-${String(++n).padStart(8, '0')}`;
  const T0 = Date.UTC(2026, 10, 2, 6, 0);
  const base = { shop_id: shop.tenantId, device_id: 'dev-00001', user_id: null, now: T0, receipt_prefix: 'D1' };
  const { branch_id } = seedShop(phone, base, { name: 'Fidelity Shop', country_code: 'ZW', tax_registered: true, tax_number: '1' }, uid);
  setExchangeRate(phone, base, 'USD', 'ZiG', 26_500_000, uid);
  const vat = (phone.prepare("select id from tax_classes where name = 'Standard rated'").get() as any).id;
  const bread = saveProduct(phone, base, { name: 'Bread', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  const radio = saveProduct(phone, base, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(phone, base, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(phone, base, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });
  const sale = (at: number, lines: [string, number][], payments: any[], extra: any = {}) =>
    sell(phone, { ...base, now: at }, { branch_id, user_id: null, sale_currency: 'USD', lines: lines.map(([product_id, qty_milli]) => ({ product_id, qty_milli })), payments, ...extra }, uid);
  const a = sale(T0, [[bread, 4000]], [cash('USD', 600)]);
  sale(T0 + 1000, [[radio, 1000]], [cash('ZiG', 106_000)], { sale_currency: 'ZiG' });
  const c = sale(T0 + 2000, [[bread, 2000]], [cash('USD', 300)]);
  sale(T0 + DAY, [[bread, 1000]], [cash('USD', 150)]);
  const line = returnableLines(phone, a.sale_id)[0]!;
  processReturn(phone, { ...base, now: T0 + DAY }, { sale_id: a.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  voidSale(phone, { ...base, now: T0 + 3000 }, { sale_id: c.sale_id, reason: 'mistake', payouts: [cash('USD', 300)] }, uid);

  // Send everything the phone has to the server the way the phone would.
  const changes: any[] = [];
  for (const table of Object.keys(TABLES)) {
    let rows: any[] = [];
    try { rows = phone.prepare(`select * from "${table}"`).all() as any[]; } catch { continue; }
    for (const r of rows) changes.push(change(table, { ...r }, { id: r.id, version: r.version ?? 1, updated_at: r.updated_at ?? r.created_at ?? T0 }));
  }
  assert.ok(changes.length > 20);
  for (let i = 0; i < changes.length; i += 500) {
    const res = await push(h, dev, changes.slice(i, i + 500));
    assert.equal(res.status, 200);
    assert.deepEqual(res.json.rejected, [], JSON.stringify(res.json.rejected.slice(0, 3)));
  }

  const R = { from: T0 - 6 * 3600_000, to: T0 + 2 * DAY };
  const via = async (name: string, extra = '') => (await h.call('GET', `/v1/owner/reports/${name}?from=${R.from}&to=${R.to}${extra}`, { auth: bearer(owner.token) })).json;
  const same = (x: unknown) => JSON.parse(JSON.stringify(x));
  const summary = await via('summary');
  assert.equal(summary.skipped_rows, 0, 'every synced row loads');
  assert.deepEqual(summary.summary, same(rep.salesSummary(phone, R)));
  assert.equal(summary.summary.sales, 3, 'the voided sale is left out');
  assert.deepEqual((await via('daily', '&offset_min=120')).days, same(rep.dailySales(phone, R, 120)));
  assert.deepEqual((await via('products', '&by=profit&limit=10')).products, same(rep.topProducts(phone, R, { by: 'profit', limit: 10 })));
  assert.deepEqual((await via('takings')).takings, same(rep.takings(phone, R)));
  const stock = await via('stock');
  assert.deepEqual(stock.value, same(rep.stockValue(phone, { top: 50 })));
  assert.deepEqual(stock.out_of_stock, same(rep.outOfStock(phone)));
  assert.ok(stock.value.total_minor > 0, 'stock levels are rebuilt from the synced movements');
  assert.deepEqual((await via('receivables')).receivables, same(rep.receivables(phone, 50)));
  assert.deepEqual((await via('cash-ups')).cash_ups, same(rep.cashUps(phone, R)));
});

test('the report copy of the phone code has not drifted from tools/', { skip: !existsSync(new URL('reports.ts', TOOLS)) }, () => {
  const same = (a: URL, b: URL) => assert.equal(readFileSync(a, 'utf8'), readFileSync(b, 'utf8'));
  same(new URL('reports.ts', TOOLS), new URL('../src/reports/reports.ts', import.meta.url));
  same(new URL('money.ts', TOOLS), new URL('../src/reports/money.ts', import.meta.url));
});
