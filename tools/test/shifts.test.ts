import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer, receiveAccountPayment } from '../src/customers.ts';
import { openShift, closeShift, addCashEvent, expectedCash, shiftReport, currentShift } from '../src/shifts.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `shf-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 1, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const stock = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  receiveStock(db, base, { branch_id, product_id: stock, qty_milli: 100_000, unit_cost_minor: 90, opening: true }, uid);
  const ctx = { ...base, user_id: cashier };
  const sale = (shift_id: string | null, payments: any[], qty = 2000, extra: any = {}) =>
    sell(db, { shop_id: ctx.shop_id, device_id: ctx.device_id, receipt_prefix: 'D1', now: T + 1000 }, { branch_id, user_id: null, shift_id, sale_currency: 'USD', lines: [{ product_id: stock, qty_milli: qty }], payments, ...extra }, uid);
  return { db, base, ctx, branch_id, owner_id: owner_id!, cashier, q, sale };
}
const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });

test('a shift opens once per cashier with a float per currency', () => {
  const { db, ctx, branch_id, q } = world();
  assert.equal(currentShift(db, ctx.user_id), undefined);
  const id = openShift(db, ctx, { branch_id, float: { USD: 2000, ZiG: 50_000 } }, uid);
  assert.equal(currentShift(db, ctx.user_id)!.id, id);
  assert.deepEqual(expectedCash(db, id), { USD: 2000, ZiG: 50_000 });
  assert.throws(() => openShift(db, ctx, { branch_id, float: {} }, uid), /already have a shift/);
  assert.equal(q('select count(*) as c from shift_cash')[0].c, 2);
});

test('opening needs real branches and sensible floats', () => {
  const { db, ctx } = world();
  assert.throws(() => openShift(db, ctx, { branch_id: 'nope', float: {} }, uid), /branch/);
  const b = db.prepare('select id from branches').get() as any;
  assert.throws(() => openShift(db, ctx, { branch_id: b.id, float: { GBP: 5 } }, uid), /not set up/);
  assert.throws(() => openShift(db, ctx, { branch_id: b.id, float: { USD: -5 } }, uid), /zero or more/);
});

test('cash-up: float, cash sales, change, mobile money, account payments and cash events all add up', () => {
  const { db, ctx, base, branch_id, sale, q } = world();
  const id = openShift(db, ctx, { branch_id, float: { USD: 2000, ZiG: 0 } }, uid);

  sale(id, [cash('USD', 500)]);                                                   // total 3.00, pays 5.00 -> change 2.00
  sale(id, [{ method_code: 'ecocash', currency: 'USD', amount_minor: 300, reference: 'MP1' }]); // not cash
  sale(id, [cash('ZiG', 8_000)]);                                                 // ZiG 80 = 3.02 USD -> change 0.00 (below 5c)
  assert.deepEqual(expectedCash(db, id), { USD: 2000 + 500 - 200, ZiG: 8_000 });

  // an account payment taken in cash by this cashier during the shift
  const c = saveCustomer(db, base, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  sale(id, [cash('USD', 100)], 2000, { customer_id: c, on_credit: true });       // 3.00 total, 1.00 paid, 2.00 on account
  receiveAccountPayment(db, { ...ctx, now: T + 5000 }, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid);
  assert.equal(expectedCash(db, id).USD, 2000 + 500 - 200 + 100 + 100);

  addCashEvent(db, { ...ctx, now: T + 6000 }, { shift_id: id, currency: 'USD', type: 'cash_out', amount_minor: 150, reason: 'Bought airtime' }, uid);
  addCashEvent(db, { ...ctx, now: T + 6100 }, { shift_id: id, currency: 'USD', type: 'cash_in', amount_minor: 1000, reason: 'Owner top-up' }, uid);
  addCashEvent(db, { ...ctx, now: T + 6200 }, { shift_id: id, currency: 'USD', type: 'bank_drop', amount_minor: 500 }, uid);
  const expectedUsd = 2000 + 500 - 200 + 100 + 100 - 150 + 1000 - 500;
  assert.equal(expectedCash(db, id).USD, expectedUsd);

  const live = shiftReport(db, id);
  assert.equal(live.sales, 4);
  assert.deepEqual(live.takings.find((t) => t.method === 'EcoCash'), { method: 'EcoCash', currency: 'USD', amount_minor: 300 });
  assert.equal(live.events.length, 3);

  // count 1.00 short in USD and exactly right in ZiG
  const rep = closeShift(db, { ...ctx, now: T + 9000 }, id, { USD: expectedUsd - 100, ZiG: 8_000 }, uid);
  assert.equal(rep.status, 'closed');
  assert.deepEqual(rep.expected, { USD: expectedUsd, ZiG: 8_000 });
  assert.deepEqual(rep.difference, { USD: -100, ZiG: 0 });
  assert.equal(currentShift(db, ctx.user_id), undefined);
  assert.equal(q('select closed_at from shifts')[0].closed_at, T + 9000);

  // a payment after closing does not change the stored figures
  receiveAccountPayment(db, { ...ctx, now: T + 20_000 }, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid);
  assert.deepEqual(shiftReport(db, id).expected, { USD: expectedUsd, ZiG: 8_000 });
  assert.equal(expectedCash(db, id).USD, expectedUsd, 'the live figure also stops at closing time');
});

test('cash events are checked', () => {
  const { db, ctx, branch_id } = world();
  const id = openShift(db, ctx, { branch_id, float: { USD: 1000 } }, uid);
  const ev = (o: any) => addCashEvent(db, ctx, { shift_id: id, currency: 'USD', type: 'cash_out', amount_minor: 100, reason: 'x', ...o }, uid);
  assert.throws(() => ev({ reason: '  ' }), /why/);
  assert.throws(() => ev({ amount_minor: 0 }), /more than zero/);
  assert.throws(() => ev({ amount_minor: 1001 }), /not that much cash/);
  assert.throws(() => ev({ currency: 'GBP' }), /not set up/);
  assert.throws(() => ev({ type: 'steal' }), /Unknown/);
  assert.throws(() => addCashEvent(db, ctx, { shift_id: 'nope', currency: 'USD', type: 'cash_in', amount_minor: 1, reason: 'x' }, uid), /not open/);
  ev({ amount_minor: 1000 });
});

test('closing needs a count for every currency and works once', () => {
  const { db, ctx, branch_id, owner_id, base } = world();
  const id = openShift(db, ctx, { branch_id, float: { USD: 1000 } }, uid);
  assert.throws(() => closeShift(db, ctx, id, { USD: 1000 }, uid), /Count the ZiG/);
  assert.throws(() => closeShift(db, ctx, id, { USD: -1, ZiG: 0 }, uid), /Count the USD/);
  assert.throws(() => closeShift(db, ctx, id, { USD: 1, ZiG: 0, GBP: 1 }, uid), /not part/);
  closeShift(db, ctx, id, { USD: 1000, ZiG: 0 }, uid);
  assert.throws(() => closeShift(db, ctx, id, { USD: 1000, ZiG: 0 }, uid), /already closed/);
  // another cashier cannot close someone else's shift, the owner (who can view reports) can
  const id2 = openShift(db, ctx, { branch_id, float: {} }, uid);
  const other = createUser(db, base, owner_id, { name: 'Tapiwa', role_id: (db.prepare("select id from roles where name = 'Cashier'").get() as any).id, pin: '8642' }, uid);
  assert.throws(() => closeShift(db, { ...ctx, user_id: other }, id2, { USD: 0, ZiG: 0 }, uid), /Only the cashier or a manager/);
  closeShift(db, { ...ctx, user_id: owner_id }, id2, { USD: 0, ZiG: 0 }, uid);
});

test('the shop can insist on an open shift before selling', () => {
  const { db, branch_id, sale } = world();
  const s = openShift(db, { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T }, { branch_id, float: {} }, uid);
  db.prepare("insert into settings (id, shop_id, created_at, updated_at, version, scope, key, value) values ('set-sh', 'shop-0001', 1, 1, 1, 'shop', 'require_shift', '1')").run();
  assert.throws(() => sale(null, [cash('USD', 300)]), /Open a shift/);
  assert.equal(sale(s, [cash('USD', 300)]).status, 'completed');
  closeShift(db, { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T + 10 }, s, { USD: 300, ZiG: 0 }, uid);
  assert.throws(() => sale(s, [cash('USD', 300)]), /Open a shift/);
});
