import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer, owedBy, payLayby, collectLayby, receiveAccountPayment } from '../src/customers.ts';
import { openShift, closeShift, expectedCash, shiftReport } from '../src/shifts.ts';
import { processReturn, voidSale, previewReturn, returnableLines, suggestPayout, returnsForSale, findSaleByReceipt } from '../src/returns.ts';
import { loadReceipt } from '../src/receipt.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `ret-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 2, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', tax_registered: true, tax_number: '1', owner: { name: 'Tim', pin: '2580' } }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const vat = q("select id from tax_classes where name = 'Standard rated'")[0].id;
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  const radio = saveProduct(db, base, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(db, base, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const manager = createUser(db, base, owner_id!, { name: 'Mary', role_id: q("select id from roles where name = 'Manager'")[0].id, pin: '4826' }, uid);
  const ctx = { ...base, user_id: manager };
  const sale = (lines: { product_id: string; qty_milli: number }[], payments: any[], extra: any = {}) =>
    sell(db, { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: T + 1000 }, { branch_id, user_id: null, sale_currency: 'USD', lines, payments, ...extra }, uid);
  const onHand = (p: string) => q('select coalesce(sum(qty_milli),0) as q from stock_movements where product_id = ?', p)[0].q as number;
  return { db, base, ctx, branch_id, owner_id: owner_id!, cashier, manager, bread, radio, q, sale, onHand };
}
const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });

test('a partial return restocks the goods and pays the customer back', () => {
  const { db, ctx, bread, sale, onHand, q } = world();
  const s = sale([{ product_id: bread, qty_milli: 4000 }], [cash('USD', 600)]); // 4 x 1.50 = 6.00
  assert.equal(onHand(bread), 46_000);
  const line = returnableLines(db, s.sale_id)[0]!;
  assert.deepEqual([line.qty_milli, line.remaining_milli, line.remaining_value_minor], [4000, 4000, 600]);

  const pv = previewReturn(db, ctx, s.sale_id, [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }]);
  assert.deepEqual([pv.value_minor, pv.credit_part_minor, pv.payout_due_minor], [150, 0, 150]);
  assert.deepEqual(suggestPayout(db, s.sale_id, 150), [{ method_code: 'cash', currency: 'USD', amount_minor: 150, reference: null }]);

  const r = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }], reason: 'Wrong loaf', payouts: [cash('USD', 150)] }, uid);
  assert.match(r.receipt_no, /^D1-R000001$/);
  assert.equal(r.opens_drawer, true);
  assert.equal(onHand(bread), 47_000);
  assert.equal(q('select type, qty_milli, unit_cost_minor from stock_movements where type = ?', 'sale_return')[0].unit_cost_minor, 90);

  // the rest, including the remainder, adds up exactly
  const r2 = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 3000 }], reason: 'Rest', payouts: [cash('USD', 450)] }, uid);
  assert.equal(r2.value_minor, 450);
  assert.equal(returnableLines(db, s.sale_id)[0]!.remaining_milli, 0);
  assert.throws(() => previewReturn(db, ctx, s.sale_id, [{ sale_line_id: line.sale_line_id, qty_milli: 1 }]), /Only 0 of Bread/);
  assert.equal(returnsForSale(db, s.sale_id).length, 2);
  assert.equal(findSaleByReceipt(db, s.receipt_no.toLowerCase())!.sale_id, s.sale_id);
});

test('damaged goods are refunded but not put back on the shelf', () => {
  const { db, ctx, radio, sale, onHand } = world();
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 4000)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000, restock: false }], reason: 'Broken', payouts: [cash('USD', 4000)] }, uid);
  assert.equal(onHand(radio), 4000);
});

test('payouts must match what is due; mobile money refunds need a reference; ZiG may be rounded', () => {
  const { db, ctx, radio, sale } = world();
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [{ method_code: 'ecocash', currency: 'USD', amount_minor: 4000, reference: 'MP9' }]);
  const l = returnableLines(db, s.sale_id)[0]!;
  const go = (payouts: any[]) => processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts }, uid);
  assert.deepEqual(suggestPayout(db, s.sale_id, 4000), [{ method_code: 'ecocash', currency: 'USD', amount_minor: 4000, reference: null }]);
  assert.throws(() => go([]), /how the money/);
  assert.throws(() => go([cash('USD', 3000)]), /does not match/);
  assert.throws(() => go([cash('USD', 5000)]), /does not match/);
  assert.throws(() => go([{ method_code: 'ecocash', currency: 'USD', amount_minor: 4000 }]), /reference/);
  assert.throws(() => go([cash('USD', 0)]), /more than zero/);
  assert.throws(() => go([{ method_code: 'nope', currency: 'USD', amount_minor: 4000 }]), /not set up/);
  // ZiG 1060.00 is exactly USD 40; ZiG 1059.50 is within one ZiG rounding step of it
  assert.doesNotThrow(() => previewReturn(db, ctx, s.sale_id, [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }]));
  const r = go([cash('ZiG', 105_950)]);
  assert.equal(r.payout_minor, 4000);
});

test('a cashier needs a manager\'s approval to refund or void', () => {
  const { db, base, ctx, cashier, manager, bread, sale } = world();
  const s = sale([{ product_id: bread, qty_milli: 2000 }], [cash('USD', 300)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  const req = { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] };
  const cctx = { ...ctx, user_id: cashier };
  assert.throws(() => processReturn(db, cctx, req, uid), /manager's approval/);
  assert.throws(() => voidSale(db, cctx, { sale_id: s.sale_id, reason: 'x', payouts: [cash('USD', 300)] }, uid), /manager's approval/);
  assert.doesNotThrow(() => processReturn(db, cctx, { ...req, approved_by: manager }, uid));
  void base;
});

test('voiding a sale restocks everything, drops it from figures, and cannot be repeated', () => {
  const { db, ctx, bread, radio, sale, onHand, q } = world();
  const s = sale([{ product_id: bread, qty_milli: 2000 }, { product_id: radio, qty_milli: 1000 }], [cash('USD', 4300)]);
  assert.equal(onHand(radio), 4000);
  const pv = previewReturn(db, ctx, s.sale_id, returnableLines(db, s.sale_id).map((l) => ({ sale_line_id: l.sale_line_id, qty_milli: l.remaining_milli })), 'void');
  assert.equal(pv.value_minor, 4300);
  assert.throws(() => processReturn(db, ctx, { sale_id: s.sale_id, items: [], reason: 'x', payouts: [] }, uid), /Choose what/);
  const r = voidSale(db, ctx, { sale_id: s.sale_id, reason: 'Rung up twice', payouts: [cash('USD', 4300)] }, uid);
  assert.equal(r.kind, 'void');
  assert.equal(onHand(bread), 50_000);
  assert.equal(onHand(radio), 5000);
  assert.equal(q('select count(*) as c from sale_voids')[0].c, 1);
  assert.equal(loadReceipt(db, s.sale_id).status, 'voided');
  assert.throws(() => voidSale(db, ctx, { sale_id: s.sale_id, reason: 'again', payouts: [] }, uid), /already voided/);
  assert.throws(() => voidSale(db, ctx, { sale_id: s.sale_id, reason: '  ', payouts: [] }, uid), /reason|already/);
});

test('a void must take everything back', () => {
  const { db, ctx, bread, sale } = world();
  const s = sale([{ product_id: bread, qty_milli: 2000 }], [cash('USD', 300)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'one', payouts: [cash('USD', 150)] }, uid);
  const v = voidSale(db, ctx, { sale_id: s.sale_id, reason: 'rest', payouts: [cash('USD', 150)] }, uid);
  assert.equal(v.value_minor, 150, 'a void after a part-return only takes back what is left');
});

test('a return on a credit sale first reduces what the customer owes', () => {
  const { db, ctx, base, radio, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 1000)], { customer_id: c, on_credit: true }); // paid 10, owes 30
  const l = returnableLines(db, s.sale_id)[0]!;
  const r = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'Changed mind', payouts: [cash('USD', 1000)] }, uid);
  assert.deepEqual([r.value_minor, r.credit_part_minor, r.payout_minor], [4000, 3000, 1000]);
  assert.deepEqual(owedBy(db, c), []);
});

test('if the customer already settled the debt, the return is paid out in full', () => {
  const { db, ctx, base, radio, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [], { customer_id: c, on_credit: true }); // owes 40
  receiveAccountPayment(db, { ...base, user_id: null, now: T + 10 }, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 4000 }, uid);
  const l = returnableLines(db, s.sale_id)[0]!;
  const pv = previewReturn(db, ctx, s.sale_id, [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }]);
  assert.deepEqual([pv.credit_part_minor, pv.payout_due_minor], [0, 4000]);
});

test('a layby can only be cancelled, and the customer gets back what they paid', () => {
  const { db, ctx, base, radio, sale, onHand } = world();
  const c = saveCustomer(db, base, { name: 'Mai' }, uid);
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 1000)], { customer_id: c, layby: true });
  payLayby(db, { ...base, user_id: null }, { sale_id: s.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 500 }, uid);
  const l = returnableLines(db, s.sale_id)[0]!;
  assert.throws(() => previewReturn(db, ctx, s.sale_id, [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }]), /can only be cancelled/);
  const pv = previewReturn(db, ctx, s.sale_id, [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], 'void');
  assert.deepEqual([pv.value_minor, pv.payout_due_minor, pv.layby], [4000, 1500, true]);
  assert.equal(onHand(radio), 4000);
  const r = voidSale(db, ctx, { sale_id: s.sale_id, reason: 'Customer cancelled', payouts: [cash('USD', 1500)] }, uid);
  assert.equal(r.payout_minor, 1500);
  assert.equal(onHand(radio), 5000, 'the held goods go back on the shelf');
});

test('a collected layby can be returned like any sale, but not voided', () => {
  const { db, ctx, base, radio, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai' }, uid);
  const s = sale([{ product_id: radio, qty_milli: 1000 }], [cash('USD', 1000)], { customer_id: c, layby: true });
  payLayby(db, { ...base, user_id: null }, { sale_id: s.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 3000 }, uid);
  collectLayby(db, base, s.sale_id, uid);
  const l = returnableLines(db, s.sale_id)[0]!;
  assert.throws(() => voidSale(db, ctx, { sale_id: s.sale_id, reason: 'x', payouts: [cash('USD', 4000)] }, uid), /already handed over/);
  const r = processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 4000)] }, uid);
  assert.equal(r.payout_minor, 4000);
});

test('refunds paid in cash come out of the shift cash-up, and voided sales leave the shift totals', () => {
  const { db, base, manager, branch_id, bread, sale } = world();
  const mctx = { ...base, user_id: manager };
  const sh = openShift(db, mctx, { branch_id, float: { USD: 1000 } }, uid);
  const s1 = sale([{ product_id: bread, qty_milli: 2000 }], [cash('USD', 300)], { shift_id: sh });
  const s2 = sale([{ product_id: bread, qty_milli: 2000 }], [cash('USD', 300)], { shift_id: sh });
  assert.equal(expectedCash(db, sh).USD, 1000 + 600);
  const l = returnableLines(db, s1.sale_id)[0]!;
  processReturn(db, mctx, { sale_id: s1.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  assert.equal(expectedCash(db, sh).USD, 1000 + 600 - 150);
  voidSale(db, mctx, { sale_id: s2.sale_id, reason: 'x', payouts: [cash('USD', 300)] }, uid);
  assert.equal(expectedCash(db, sh).USD, 1000 + 600 - 150 - 300);
  const rep = shiftReport(db, sh);
  assert.equal(rep.sales, 1);
  assert.equal(rep.voided, 1);
  assert.deepEqual(rep.refunds, [{ method: 'Cash', currency: 'USD', amount_minor: 450 }]);
  const closed = closeShift(db, { ...mctx, now: T + 5000 }, sh, { USD: 1150, ZiG: 0 }, uid);
  assert.deepEqual(closed.difference, { USD: 0, ZiG: 0 });
});

test('a failed return leaves no trace', () => {
  const { db, ctx, bread, sale, q, onHand } = world();
  const s = sale([{ product_id: bread, qty_milli: 2000 }], [cash('USD', 300)]);
  const l = returnableLines(db, s.sale_id)[0]!;
  assert.throws(() => processReturn(db, ctx, { sale_id: s.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 999)] }, uid));
  assert.equal(q('select count(*) as c from sale_returns')[0].c, 0);
  assert.equal(q("select count(*) as c from stock_movements where type = 'sale_return'")[0].c, 0);
  assert.equal(q("select count(*) as c from receipt_counters where kind = 'return'")[0].c, 0);
  assert.equal(onHand(bread), 48_000);
});
