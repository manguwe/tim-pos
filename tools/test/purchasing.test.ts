import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { openShift, expectedCash } from '../src/shifts.ts';
import {
  saveSupplier, listSuppliers, owedToSupplier, supplierStatement, lastCost, createPurchaseOrder, updatePurchaseOrder, sendPurchaseOrder, cancelPurchaseOrder,
  closePurchaseOrder, purchaseOrder, listPurchaseOrders, receiveGoods, returnToSupplier, paySupplier,
} from '../src/purchasing.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `pur-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 3, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: Ctx = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  const oil = saveProduct(db, base, { name: 'Cooking oil', price_minor: 400, cost_minor: 300 }, uid);
  const svc = saveProduct(db, base, { name: 'Airtime', price_minor: 100, track_stock: false }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 10_000, unit_cost_minor: 90, opening: true }, uid);
  const mgr = createUser(db, base, owner_id!, { name: 'Mary', role_id: q("select id from roles where name = 'Manager'")[0].id, pin: '4826' }, uid);
  const clerk = createUser(db, base, owner_id!, { name: 'Sam', role_id: q("select id from roles where name = 'Stock clerk'")[0].id, pin: '1357' }, uid);
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const ctx: Ctx = { ...base, user_id: mgr, now: T + 1000 };
  const sup = saveSupplier(db, ctx, { name: 'Bakers Inn', phone: '0242 000', terms: '30 days' }, uid);
  const level = (p: string, batch = '') => q('select coalesce(sum(qty_milli),0) as s from stock_levels where product_id = ? and batch_key = ?', p, batch)[0].s as number;
  const cost = (p: string) => q('select cost_minor from products where id = ?', p)[0].cost_minor as number;
  return { db, base, ctx, branch_id, mgr, clerk, cashier, bread, oil, svc, sup, q, level, cost };
}
type Ctx = SetupContext & { receipt_prefix: string };

test('suppliers: add, edit, duplicate names refused, search and inactive hidden', () => {
  const { db, ctx } = world();
  const b = saveSupplier(db, ctx, { name: '  Delta   Beverages ', address: 'Harare' }, uid);
  assert.throws(() => saveSupplier(db, ctx, { name: 'delta beverages' }, uid), /already have a supplier/);
  assert.throws(() => saveSupplier(db, ctx, { name: ' ' }, uid), /name/);
  saveSupplier(db, ctx, { id: b, name: 'Delta Beverages', phone: '0772', is_active: true }, uid);
  assert.deepEqual(listSuppliers(db).map((s) => s.name), ['Bakers Inn', 'Delta Beverages']);
  assert.deepEqual(listSuppliers(db, { search: 'delta' }).map((s) => [s.name, s.phone]), [['Delta Beverages', '0772']]);
  saveSupplier(db, ctx, { id: b, name: 'Delta Beverages', is_active: false }, uid);
  assert.equal(listSuppliers(db).length, 1);
  assert.equal(listSuppliers(db, { include_inactive: true }).length, 2);
});

test('only people with stock.receive manage suppliers and orders', () => {
  const { db, base, cashier, clerk, branch_id, sup, bread } = world();
  assert.throws(() => saveSupplier(db, { ...base, user_id: cashier }, { name: 'X' }, uid), /not allowed/);
  saveSupplier(db, { ...base, user_id: clerk }, { name: 'Y' }, uid);
  assert.throws(() => createPurchaseOrder(db, { ...base, user_id: cashier }, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 90 }] }, uid), /not allowed/);
});

test('a purchase order goes draft, sent, partly received, received; nothing is owed or moved until goods arrive', () => {
  const { db, ctx, branch_id, sup, bread, oil, level, q } = world();
  const { order_id, order_no } = createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 20_000, cost_minor: 95 }, { product_id: oil, qty_milli: 6000, cost_minor: 310 }] }, uid);
  assert.match(order_no, /^D1-PO000001$/);
  let po = purchaseOrder(db, order_id);
  assert.deepEqual([po.status, po.total_minor, po.lines.length], ['draft', 20 * 95 + 6 * 310, 2]);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: order_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 95 }] }, uid), /Send it first/);
  updatePurchaseOrder(db, ctx, order_id, { lines: [{ product_id: bread, qty_milli: 20_000, cost_minor: 95 }, { product_id: oil, qty_milli: 5000, cost_minor: 310 }] }, uid);
  assert.equal(purchaseOrder(db, order_id).lines.length, 2);
  assert.equal(q('select count(*) as c from purchase_order_lines where purchase_order_id = ? and deleted_at is null', order_id)[0].c, 2);
  sendPurchaseOrder(db, ctx, order_id, uid);
  assert.throws(() => updatePurchaseOrder(db, ctx, order_id, { expected_at: 1 }, uid), /draft/);
  assert.equal(level(bread), 10_000);
  assert.deepEqual(owedToSupplier(db, sup), []);

  const r1 = receiveGoods(db, { ...ctx, now: T + 2000 }, { supplier_id: sup, branch_id, purchase_order_id: order_id, receipt_ref: 'DN-77', currency: 'USD', lines: [{ product_id: bread, qty_milli: 12_000, cost_minor: 95 }] }, uid);
  assert.deepEqual([r1.total_minor, r1.order_status], [1140, 'partly_received']);
  po = purchaseOrder(db, order_id);
  assert.deepEqual(po.lines.map((l) => [l.product, l.received_milli, l.remaining_milli]), [['Bread', 12_000, 8000], ['Cooking oil', 0, 5000]]);
  assert.throws(() => cancelPurchaseOrder(db, ctx, order_id, uid), /Close it/);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: order_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 8001, cost_minor: 95 }] }, uid), /Only 8 of Bread still to come/);
  const r2 = receiveGoods(db, { ...ctx, now: T + 3000 }, { supplier_id: sup, branch_id, purchase_order_id: order_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 8000, cost_minor: 95 }, { product_id: oil, qty_milli: 5000, cost_minor: 310 }] }, uid);
  assert.equal(r2.order_status, 'received');
  assert.equal(level(bread), 30_000);
  assert.deepEqual(owedToSupplier(db, sup), [{ currency: 'USD', amount_minor: 1140 + 760 + 1550 }]);
  assert.deepEqual(listPurchaseOrders(db, { statuses: ['received'] }).map((p) => [p.order_no, p.total_minor]), [['D1-PO000001', 20 * 95 + 5 * 310]]);
  assert.throws(() => closePurchaseOrder(db, ctx, order_id, uid), /partly received/);
});

test('an order can be cancelled before anything arrives, or closed short once partly received', () => {
  const { db, ctx, branch_id, sup, bread } = world();
  const a = createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 90 }] }, uid).order_id;
  cancelPurchaseOrder(db, ctx, a, uid);
  assert.equal(purchaseOrder(db, a).status, 'cancelled');
  assert.throws(() => sendPurchaseOrder(db, ctx, a, uid), /draft/);
  const b = createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 10_000, cost_minor: 90 }] }, uid).order_id;
  sendPurchaseOrder(db, ctx, b, uid);
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: b, currency: 'USD', lines: [{ product_id: bread, qty_milli: 4000, cost_minor: 90 }] }, uid);
  closePurchaseOrder(db, ctx, b, uid);
  assert.equal(purchaseOrder(db, b).status, 'received');
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: b, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 90 }] }, uid), /not waiting/);
});

test('order checks: duplicates, quantities, wrong supplier or currency, products not on the order', () => {
  const { db, ctx, branch_id, sup, bread, oil } = world();
  const line = { product_id: bread, qty_milli: 1000, cost_minor: 90 };
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [] }, uid), /at least one/);
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [line, line] }, uid), /twice/);
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ ...line, qty_milli: 0 }] }, uid), /more than zero/);
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ ...line, cost_minor: -1 }] }, uid), /zero or more/);
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: 'nope', branch_id, currency: 'USD', lines: [line] }, uid), /supplier/);
  assert.throws(() => createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'EUR', lines: [line] }, uid), /not set up/);
  const other = saveSupplier(db, ctx, { name: 'Other' }, uid);
  const o = createPurchaseOrder(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [line] }, uid).order_id;
  sendPurchaseOrder(db, ctx, o, uid);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: other, branch_id, purchase_order_id: o, currency: 'USD', lines: [line] }, uid), /different supplier/);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: o, currency: 'ZiG', lines: [line] }, uid), /in USD/);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, purchase_order_id: o, currency: 'USD', lines: [{ ...line, product_id: oil }] }, uid), /not on that order/);
});

test('goods without an order: stock up, weighted-average cost, batch and expiry, owed and last cost remembered', () => {
  const { db, ctx, branch_id, sup, bread, oil, svc, level, cost, q } = world();
  const r = receiveGoods(db, ctx, {
    supplier_id: sup, branch_id, receipt_ref: 'INV-1', currency: 'USD', invoice: { invoice_no: 'INV-1', due_date: '2026-12-03' },
    lines: [{ product_id: bread, qty_milli: 10_000, cost_minor: 110, batch_code: 'L7', expiry_date: '2026-11-10' }, { product_id: oil, qty_milli: 2000, cost_minor: 300 }],
  }, uid);
  assert.deepEqual([r.total_minor, r.order_status], [1100 + 600, null]);
  assert.equal(cost(bread), 100); // (10 x 0.90 + 10 x 1.10) / 20
  const b = q('select id, batch_code, expiry_date from stock_batches')[0];
  assert.deepEqual([b.batch_code, b.expiry_date], ['L7', '2026-11-10']);
  assert.equal(level(bread, b.id), 10_000);
  assert.equal(level(bread), 10_000);
  assert.equal(level(oil), 2000);
  assert.deepEqual(lastCost(db, sup, bread), { cost_minor: 110, currency: 'USD' });
  assert.deepEqual(q('select invoice_no, amount_minor, due_date from supplier_invoices').map((x) => [x.invoice_no, x.amount_minor, x.due_date]), [['INV-1', 1700, '2026-12-03']]);
  // the same batch again lands in the same batch row
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 110, batch_code: 'L7', expiry_date: '2026-11-10' }] }, uid);
  assert.equal(q('select count(*) as c from stock_batches')[0].c, 1);
  assert.equal(level(bread, b.id), 11_000);
  assert.equal(lastCost(db, sup, svc), undefined);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: svc, qty_milli: 1000, cost_minor: 10 }] }, uid), /does not keep stock/);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 10, expiry_date: '2026-02-30' }] }, uid), /expiry date/);
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', invoice: { due_date: 'soon' }, lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 10 }] }, uid), /due date/);
});

test('a delivery priced in ZiG is owed in ZiG, and its cost is converted to USD at the day rate', () => {
  const { db, ctx, branch_id, sup, oil, cost } = world();
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'ZiG', lines: [{ product_id: oil, qty_milli: 4000, cost_minor: 7950 }] }, uid); // ZiG 79.50 = USD 3.00
  assert.deepEqual(owedToSupplier(db, sup), [{ currency: 'ZiG', amount_minor: 31_800 }]);
  assert.equal(cost(oil), 300);
});

test('a failed receipt changes nothing', () => {
  const { db, ctx, branch_id, sup, bread, oil, level, q } = world();
  assert.throws(() => receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 90 }, { product_id: oil, qty_milli: 0, cost_minor: 1 }] }, uid), /more than zero/);
  assert.equal(level(bread), 10_000);
  assert.equal(q('select count(*) as c from goods_received')[0].c, 0);
  assert.deepEqual(owedToSupplier(db, sup), []);
});

test('returning goods to a supplier takes stock off the shelf and the value off the debt', () => {
  const { db, ctx, branch_id, sup, bread, level, q } = world();
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: bread, qty_milli: 10_000, cost_minor: 100 }] }, uid);
  const r = returnToSupplier(db, { ...ctx, now: T + 5000 }, { supplier_id: sup, branch_id, currency: 'USD', reason: 'Stale', lines: [{ product_id: bread, qty_milli: 3000, cost_minor: 100 }] }, uid);
  assert.equal(r.total_minor, 300);
  assert.equal(level(bread), 17_000);
  assert.deepEqual(owedToSupplier(db, sup), [{ currency: 'USD', amount_minor: 700 }]);
  assert.deepEqual(q("select qty_milli, reason from stock_movements where type = 'supplier_return'").map((x) => [x.qty_milli, x.reason]), [[-3000, 'Stale']]);
  returnToSupplier(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', reason: 'Swap for fresh', credit: false, lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 100 }] }, uid);
  assert.deepEqual(owedToSupplier(db, sup), [{ currency: 'USD', amount_minor: 700 }]);
  assert.throws(() => returnToSupplier(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', reason: 'x', lines: [{ product_id: bread, qty_milli: 99_000, cost_minor: 100 }] }, uid), /Only 16 of Bread/);
  assert.throws(() => returnToSupplier(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', reason: ' ', lines: [{ product_id: bread, qty_milli: 1000, cost_minor: 100 }] }, uid), /reason/i);
});

test('paying a supplier reduces the debt; another currency is converted; overpaying is refused', () => {
  const { db, ctx, base, branch_id, sup, oil, mgr } = world();
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: oil, qty_milli: 10_000, cost_minor: 300 }] }, uid); // owes 30.00
  const p1 = paySupplier(db, { ...ctx, now: T + 6000 }, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 1000 }, uid);
  assert.deepEqual([p1.applied_minor, p1.balance_after_minor, p1.cash_out_recorded], [1000, 2000, false]);
  const p2 = paySupplier(db, { ...ctx, now: T + 7000 }, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'ZiG', amount_minor: 26_500 }, uid); // USD 10.00
  assert.deepEqual([p2.applied_minor, p2.balance_after_minor], [1000, 1000]);
  assert.throws(() => paySupplier(db, ctx, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 1500 }, uid), /more than is owed/);
  assert.throws(() => paySupplier(db, ctx, { supplier_id: sup, debt_currency: 'USD', method_code: 'ecocash', currency: 'USD', amount_minor: 100 }, uid), /reference/);
  paySupplier(db, { ...ctx, now: T + 8000 }, { supplier_id: sup, debt_currency: 'USD', method_code: 'ecocash', currency: 'USD', amount_minor: 1000, reference: 'MP1' }, uid);
  assert.deepEqual(owedToSupplier(db, sup), []);
  assert.throws(() => paySupplier(db, ctx, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid), /nothing to pay/i);
  const st = supplierStatement(db, sup);
  assert.deepEqual(st.map((l) => [l.type, l.amount_minor, l.balance_minor]), [['purchase', 3000, 3000], ['payment', -1000, 2000], ['payment', -1000, 1000], ['payment', -1000, 0]]);
  assert.equal(st[3]!.ref, 'MP1');
  void base; void mgr;
});

test('paying suppliers needs supplier.pay; a stock clerk cannot', () => {
  const { db, base, ctx, clerk, branch_id, sup, oil } = world();
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: oil, qty_milli: 1000, cost_minor: 300 }] }, uid);
  assert.throws(() => paySupplier(db, { ...base, user_id: clerk }, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 100 }, uid), /not allowed/);
  assert.deepEqual(owedToSupplier(db, sup), [{ currency: 'USD', amount_minor: 300 }]);
});

test('a cash payment made during a shift is recorded as cash out, so the cash-up adds up', () => {
  const { db, ctx, branch_id, sup, oil, q } = world();
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: oil, qty_milli: 10_000, cost_minor: 300 }] }, uid);
  const shift = openShift(db, { ...ctx, now: T + 2000 }, { branch_id, float: { USD: 5000 } }, uid);
  assert.equal(expectedCash(db, shift).USD, 5000);
  const p = paySupplier(db, { ...ctx, now: T + 3000 }, { supplier_id: sup, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 1200 }, uid);
  assert.equal(p.cash_out_recorded, true);
  assert.equal(expectedCash(db, shift).USD, 3800);
  assert.deepEqual(q('select type, amount_minor, reason from cash_events').map((e) => [e.type, e.amount_minor, e.reason]), [['cash_out', 1200, 'Supplier: Bakers Inn']]);
  paySupplier(db, { ...ctx, now: T + 4000 }, { supplier_id: sup, debt_currency: 'USD', method_code: 'ecocash', currency: 'USD', amount_minor: 500, reference: 'MP2' }, uid);
  assert.equal(expectedCash(db, shift).USD, 3800);
});

test('suppliers owed: the list shows balances and can be limited to those we owe', () => {
  const { db, ctx, branch_id, sup, oil } = world();
  saveSupplier(db, ctx, { name: 'Zebra Traders' }, uid);
  receiveGoods(db, ctx, { supplier_id: sup, branch_id, currency: 'USD', lines: [{ product_id: oil, qty_milli: 1000, cost_minor: 300 }] }, uid);
  assert.deepEqual(listSuppliers(db, { only_owed: true }).map((s) => [s.name, s.owes]), [['Bakers Inn', [{ currency: 'USD', amount_minor: 300 }]]]);
});
