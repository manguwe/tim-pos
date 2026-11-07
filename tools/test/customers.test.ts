import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer, listCustomers, owedBy, receiveAccountPayment, payLayby, collectLayby, laybys, statement } from '../src/customers.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `cus-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 1, 8, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const ctx: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, ctx, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  setExchangeRate(db, ctx, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const radio = saveProduct(db, ctx, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(db, ctx, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const sale = (cart: any, now = T + 1000) => sell(db, { shop_id: ctx.shop_id, device_id: ctx.device_id, receipt_prefix: 'D1', now }, { branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: radio, qty_milli: 1000 }], payments: [], ...cart }, uid);
  return { db, ctx, branch_id, owner_id: owner_id!, radio, q, sale };
}

test('customers are saved, found, and phone numbers are not duplicated', () => {
  const { db, ctx } = world();
  const a = saveCustomer(db, ctx, { name: ' Mai Tendai ', phone: '0772 111 222', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  saveCustomer(db, ctx, { name: 'Baba Rudo', phone: '0773 000 111' }, uid);
  assert.throws(() => saveCustomer(db, ctx, { name: 'Other', phone: '0772 111 222' }, uid), /already has that phone/);
  assert.throws(() => saveCustomer(db, ctx, { name: ' ' }, uid), /name/);
  assert.throws(() => saveCustomer(db, ctx, { name: 'X', credit_limit_minor: -1 }, uid), /limit/);
  saveCustomer(db, ctx, { id: a, name: 'Mai Tendai', phone: '0772 111 222', credit_limit_minor: 20_000, credit_currency: 'USD' }, uid);
  assert.equal(listCustomers(db)[1]!.credit_limit_minor, 20_000);
  assert.deepEqual(listCustomers(db, { search: '0773' }).map((c) => c.name), ['Baba Rudo']);
  assert.deepEqual(listCustomers(db, { search: '%' }).map((c) => c.name), []);
});

test('a cashier may take payments but not edit customers', () => {
  const { db, ctx, owner_id, q } = world();
  const cashier = createUser(db, ctx, owner_id, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  assert.throws(() => saveCustomer(db, { ...ctx, user_id: cashier }, { name: 'New' }, uid), /not allowed/);
});

test('credit stays in the agreed currency; paying in ZiG converts at today\'s rate', () => {
  const { db, ctx, q, sale } = world();
  const c = saveCustomer(db, ctx, { name: 'Mai Tendai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const r = sale({ customer_id: c, on_credit: true, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 1000 }] });
  assert.equal(r.credit_minor, 3000);
  assert.deepEqual(owedBy(db, c), [{ currency: 'USD', amount_minor: 3000 }]);

  // the rate moves; the debt does not
  setExchangeRate(db, { ...ctx, now: T + 5000 }, 'USD', 'ZiG', 30_000_000, uid);
  const p = receiveAccountPayment(db, { ...ctx, now: T + 6000 }, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'ZiG', amount_minor: 30_000 }, uid);
  assert.equal(p.applied_minor, 1000); // ZiG 300 at 30 = USD 10
  assert.equal(p.balance_after_minor, 2000);
  assert.match(p.receipt_no, /^D1-P000001$/);
  assert.equal(p.opens_drawer, true);
  assert.deepEqual(owedBy(db, c), [{ currency: 'USD', amount_minor: 2000 }]);

  const row = q('select * from account_payments')[0];
  assert.deepEqual([row.currency, row.amount_minor, row.target_currency, row.applied_minor, row.rate_to_target_micro], ['ZiG', 30_000, 'USD', 1000, 33_333]);

  const s = statement(db, c);
  assert.deepEqual(s.map((l) => [l.type, l.amount_minor, l.balance_minor]), [['credit_sale', 3000, 3000], ['payment', -1000, 2000]]);
  assert.equal(s[0]!.ref, r.receipt_no);
  assert.equal(s[1]!.ref, p.receipt_no);
});

test('paying too much is refused, a rounding sliver is allowed, and mobile money needs a reference', () => {
  const { db, ctx, sale } = world();
  const c = saveCustomer(db, ctx, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  sale({ customer_id: c, on_credit: true, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 3900 }] }); // owes USD 1.00
  const pay = (over: any) => receiveAccountPayment(db, ctx, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 100, ...over }, uid);
  assert.throws(() => pay({ amount_minor: 110 }), /more than is owed/);
  assert.throws(() => pay({ method_code: 'ecocash' }), /reference/);
  assert.throws(() => pay({ method_code: 'nope' }), /not set up/);
  assert.throws(() => pay({ amount_minor: 0 }), /more than zero/);
  assert.throws(() => pay({ currency: 'GBP' }), /not set up/);
  // ZiG 26.50 = exactly USD 1.00 ; ZiG 27 is USD 1.0189, a sliver under one ZiG rounding step (100 minor)
  const r = pay({ currency: 'ZiG', amount_minor: 2700 });
  assert.equal(r.applied_minor, 100);
  assert.equal(r.balance_after_minor, 0);
  assert.throws(() => pay({}), /nothing to pay/);
  assert.equal(listCustomers(db, { only_owing: true }).length, 0);
});

test('a failed payment leaves no trace', () => {
  const { db, ctx, q, sale } = world();
  const c = saveCustomer(db, ctx, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  sale({ customer_id: c, on_credit: true, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 3000 }] });
  assert.throws(() => receiveAccountPayment(db, ctx, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 5000 }, uid));
  assert.equal(q('select count(*) as c from account_payments')[0].c, 0);
  assert.equal(q("select last_no from receipt_counters where kind = 'payment'").length, 0);
});

test('a layby holds the goods, takes a deposit, and is collected only when paid up', () => {
  const { db, ctx, q, sale, radio, branch_id } = world();
  const c = saveCustomer(db, ctx, { name: 'Mai' }, uid);
  assert.throws(() => sale({ layby: true, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 1000 }] }), /customer/);
  assert.throws(() => sale({ layby: true, customer_id: c, payments: [] }), /deposit/);
  assert.throws(() => sale({ layby: true, on_credit: true, customer_id: c, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 1000 }] }), /either layby or credit/);

  const r = sale({ layby: true, customer_id: c, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 1000 }] });
  assert.equal(r.status, 'layby');
  assert.equal(r.layby_balance_minor, 3000);
  assert.equal(r.credit_minor, 0);
  assert.equal(q("select coalesce(sum(qty_milli),0) as q from stock_movements where product_id = ? and branch_id = ?", radio, branch_id)[0].q, 4_000, 'goods are held aside');
  assert.deepEqual(owedBy(db, c), [], 'a layby is not a debt');

  let l = laybys(db, { open_only: true })[0]!;
  assert.deepEqual([l.total_minor, l.paid_minor, l.balance_minor, l.collected], [4000, 1000, 3000, false]);
  assert.throws(() => collectLayby(db, ctx, r.sale_id, uid), /not fully paid/);

  const i1 = payLayby(db, { ...ctx, now: T + 9000 }, { sale_id: r.sale_id, method_code: 'cash', currency: 'ZiG', amount_minor: 26_500 }, uid); // ZiG 265 = USD 10
  assert.equal(i1.applied_minor, 1000);
  assert.equal(i1.balance_after_minor, 2000);
  assert.throws(() => payLayby(db, ctx, { sale_id: r.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 2500 }, uid), /more than is owed/);
  const i2 = payLayby(db, ctx, { sale_id: r.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 2000 }, uid);
  assert.equal(i2.balance_after_minor, 0);
  assert.throws(() => payLayby(db, ctx, { sale_id: r.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid), /nothing to pay/);

  l = laybys(db, { customer_id: c })[0]!;
  assert.equal(l.balance_minor, 0);
  collectLayby(db, ctx, r.sale_id, uid);
  assert.throws(() => collectLayby(db, ctx, r.sale_id, uid), /already collected/);
  assert.equal(laybys(db, { open_only: true }).length, 0);
  assert.equal(laybys(db).length, 1);
  assert.throws(() => payLayby(db, ctx, { sale_id: r.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid), /collected/);
  assert.throws(() => payLayby(db, ctx, { sale_id: 'nope', method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid), /not a layby/);
  assert.deepEqual(q('select receipt_no from account_payments order by rowid').map((x) => x.receipt_no), ['D1-P000001', 'D1-P000002']);
});

test('a minimum deposit can be required', () => {
  const { db, ctx, sale } = world();
  const c = saveCustomer(db, ctx, { name: 'Mai' }, uid);
  db.prepare("insert into settings (id, shop_id, created_at, updated_at, version, scope, key, value) values ('set-lay', 'shop-0001', 1, 1, 1, 'shop', 'layby_min_deposit_pct', '25')").run();
  assert.throws(() => sale({ layby: true, customer_id: c, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 900 }] }), /at least 25%/);
  assert.equal(sale({ layby: true, customer_id: c, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 1000 }] }).status, 'layby');
});

test('a layby paid in full at the till is simply a sale', () => {
  const { db, sale } = world();
  const r = sale({ layby: true, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 4000 }] });
  assert.equal(r.status, 'completed');
  assert.equal(laybys(db).length, 0);
});
