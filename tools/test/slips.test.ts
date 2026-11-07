import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer, payLayby, receiveAccountPayment } from '../src/customers.ts';
import { openShift, closeShift, addCashEvent } from '../src/shifts.ts';
import { processReturn, voidSale, returnableLines } from '../src/returns.ts';
import { toText, toEscPos } from '../src/receipt.ts';
import { layoutSlip, loadCashUpSlip, loadRefundSlip, loadPaymentSlip } from '../src/slips.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `slp-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 2, 6, 0);
const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Mbare Mini Market', country_code: 'ZW', tax_registered: true, tax_number: '1', owner: { name: 'Tim', pin: '2580' } }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  const radio = saveProduct(db, base, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(db, base, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const mgr = createUser(db, base, owner_id!, { name: 'Mary', role_id: q("select id from roles where name = 'Manager'")[0].id, pin: '4826' }, uid);
  const ctx = { ...base, user_id: mgr, now: T + 5000 };
  const sctx = { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: T + 1000 };
  const sale = (lines: any[], payments: any[], extra: any = {}) => sell(db, sctx, { branch_id, user_id: mgr, sale_currency: 'USD', lines, payments, ...extra }, uid);
  return { db, base, ctx, branch_id, mgr, bread, radio, q, sale };
}
const text = (d: any, w = 32) => toText(layoutSlip(d, { width: w }), w);

test('cash-up slip lists sales, money received, refunds, cash events and the drawer count', () => {
  const { db, ctx, branch_id, mgr, bread, sale } = world();
  const shift = openShift(db, { ...ctx, now: T }, { branch_id, float: { USD: 1000, ZiG: 0 } }, uid);
  const s = sale([{ product_id: bread, qty_milli: 4000 }], [cash('USD', 600)], { shift_id: shift });
  addCashEvent(db, { ...ctx, now: T + 2000 }, { shift_id: shift, currency: 'USD', type: 'cash_out', amount_minor: 100, reason: 'Bought airtime' }, uid);
  const l = returnableLines(db, s.sale_id)[0]!;
  processReturn(db, { ...ctx, now: T + 3000 }, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  closeShift(db, { ...ctx, now: T + 4000 }, shift, { USD: 1300, ZiG: 0 }, uid);
  const d = loadCashUpSlip(db, shift, 120);
  const t = text(d);
  assert.match(t, /CASH-UP\n/);
  assert.match(t, /Cashier +Mary/);
  assert.match(t, /Sold USD +\$6\.00/);
  assert.match(t, /Cash USD +\$6\.00/);
  assert.match(t, /Paid back to customers/);
  assert.match(t, /Cash out USD +\$1\.00/);
  assert.match(t, /Bought airtime/);
  assert.match(t, /Opening float +\$10\.00/);
  assert.match(t, /Should be +\$13\.50/);
  assert.match(t, /Counted +\$13\.00/);
  assert.match(t, /SHORT by +\$0\.50/);
  assert.match(t, /Checked by/);
  assert.ok(t.split('\n').every((x) => x.length <= 32));
  assert.ok(toText(layoutSlip(d, { width: 48 }), 48).split('\n').every((x) => x.length <= 48));
});

test('an open shift is marked, and a correct count says so', () => {
  const { db, ctx, branch_id } = world();
  const shift = openShift(db, { ...ctx, now: T }, { branch_id, float: { USD: 500 } }, uid);
  assert.match(text(loadCashUpSlip(db, shift, 0)), /still open/);
  closeShift(db, { ...ctx, now: T + 10 }, shift, { USD: 500, ZiG: 0 }, uid);
  assert.match(text(loadCashUpSlip(db, shift, 0)), /Correct +OK/);
});

test('refund slip shows items, value, what was paid back and the reason', () => {
  const { db, ctx, radio, sale, mgr } = world();
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 4000)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  const r = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'Does not work', payouts: [cash('USD', 4000)], approved_by: mgr }, uid);
  const d = loadRefundSlip(db, r.return_id, 120);
  const t = text(d);
  assert.match(t, /REFUND \/ RETURN/);
  assert.match(t, /Refund no +D1-R000001/);
  assert.match(t, new RegExp(`Original receipt +${s.receipt_no}`));
  assert.match(t, /Radio\nQty 1 +\$40\.00/);
  assert.match(t, /VALUE/);
  assert.match(t, /Cash USD +\$40\.00/);
  assert.match(t, /Reason: Does not work/);
  assert.match(t, /Customer signature/);
  assert.equal(d.open_drawer, true);
});

test('a void slip says so, and a refund on credit shows the amount taken off the account', () => {
  const { db, ctx, bread, sale } = world();
  const cust = saveCustomer(db, ctx, { name: 'Mai Tendai', credit_limit_minor: 10000, credit_currency: 'USD' }, uid);
  const s = sale([{ product_id: bread, qty_milli: 2000 }], [], { customer_id: cust, on_credit: true });
  const v = voidSale(db, ctx, { sale_id: s.sale_id, reason: 'Wrong customer', payouts: [] }, uid);
  const t = text(loadRefundSlip(db, v.return_id, 0));
  assert.match(t, /SALE VOIDED/);
  assert.match(t, /Customer +Mai Tendai/);
  assert.match(t, /Taken off account +\$3\.00/);
  assert.doesNotMatch(t, /Paid back/);
});

test('account payment receipt shows what was paid, what it counted as and the balance left', () => {
  const { db, ctx, bread, sale } = world();
  const cust = saveCustomer(db, ctx, { name: 'Mai Tendai', credit_limit_minor: 10000, credit_currency: 'USD' }, uid);
  sale([{ product_id: bread, qty_milli: 4000 }], [], { customer_id: cust, on_credit: true }); // owes 6.00
  const p1 = receiveAccountPayment(db, { ...ctx, now: T + 6000 }, { customer_id: cust, debt_currency: 'USD', ...cash('USD', 200) }, uid);
  const p2 = receiveAccountPayment(db, { ...ctx, now: T + 7000 }, { customer_id: cust, debt_currency: 'USD', ...cash('ZiG', 5300) }, uid); // 2.00 USD in ZiG
  let t = text(loadPaymentSlip(db, p1.payment_id, 120));
  assert.match(t, /PAYMENT RECEIVED/);
  assert.match(t, /Receipt +D1-P/);
  assert.match(t, /Customer +Mai Tendai/);
  assert.match(t, /Balance owing +\$4\.00/);
  t = text(loadPaymentSlip(db, p2.payment_id, 120));
  assert.match(t, /Cash ZiG +ZiG 53\.00/);
  assert.match(t, /Counted as +\$2\.00/);
  assert.match(t, /Balance owing +\$2\.00/);
  // an older receipt keeps its own balance after later payments
  assert.match(text(loadPaymentSlip(db, p1.payment_id, 120)), /Balance owing +\$4\.00/);
});

test('layby instalment receipt shows the balance left on the layby', () => {
  const { db, ctx, radio, sale } = world();
  const cust = saveCustomer(db, ctx, { name: 'Mai Tendai' }, uid);
  const l = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 1000)], { customer_id: cust, layby: true });
  const a = payLayby(db, { ...ctx, now: T + 6000 }, { sale_id: l.sale_id, ...cash('USD', 1500) }, uid);
  const b = payLayby(db, { ...ctx, now: T + 7000 }, { sale_id: l.sale_id, ...cash('USD', 1500) }, uid);
  assert.match(text(loadPaymentSlip(db, a.payment_id, 0)), /LAYBY PAYMENT[\s\S]*Layby sale +D1-/);
  assert.match(text(loadPaymentSlip(db, a.payment_id, 0)), /Balance on layby +\$15\.00/);
  assert.match(text(loadPaymentSlip(db, b.payment_id, 0)), /Balance on layby +\$0\.00/);
});

test('slips print as bytes too, with the drawer pulse only when asked', () => {
  const { db, ctx, radio, sale } = world();
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 4000)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  const r = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 4000)] }, uid);
  const d = loadRefundSlip(db, r.return_id, 0);
  const plain = toEscPos(layoutSlip(d, { width: 32 }), 32);
  const drawer = toEscPos(layoutSlip(d, { width: 32, open_drawer: true }), 32);
  assert.ok(drawer.length > plain.length);
  assert.equal(plain[0], 0x1b);
});
