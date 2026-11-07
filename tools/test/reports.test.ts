import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer, payLayby, collectLayby, receiveAccountPayment } from '../src/customers.ts';
import { openShift, closeShift } from '../src/shifts.ts';
import { processReturn, voidSale, returnableLines } from '../src/returns.ts';
import { salesSummary, dailySales, topProducts, takings, stockValue, outOfStock, expiringBatches, receivables, cashUps, dayOf } from '../src/reports.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `rep-${String(++n).padStart(8, '0')}`;
const DAY = 86_400_000;
const D1 = Date.UTC(2026, 10, 2, 6, 0);          // 2 Nov 2026 06:00 UTC = 08:00 local (UTC+2)
const LOCAL_MIDNIGHT = Date.UTC(2026, 10, 1, 22, 0); // 2 Nov 00:00 local
const day = (i: number) => ({ from: LOCAL_MIDNIGHT + i * DAY, to: LOCAL_MIDNIGHT + (i + 1) * DAY });

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: D1, receipt_prefix: 'D1' };
  const { branch_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', tax_registered: true, tax_number: '1' }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const vat = q("select id from tax_classes where name = 'Standard rated'")[0].id;
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  const radio = saveProduct(db, base, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(db, base, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const sale = (at: number, lines: [string, number][], payments: any[], extra: any = {}) =>
    sell(db, { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: at }, { branch_id, user_id: null, sale_currency: 'USD', lines: lines.map(([product_id, qty_milli]) => ({ product_id, qty_milli })), payments, ...extra }, uid);
  return { db, base, branch_id, bread, radio, q, sale };
}
const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });

test('sales summary: counts, totals per currency, base-currency revenue, cost and profit', () => {
  const { db, bread, radio, sale } = world();
  const a = sale(D1, [[bread, 4000]], [cash('USD', 600)]);                                  // USD 6.00
  const b = sale(D1 + 1000, [[radio, 1000]], [cash('ZiG', 106_000)], { sale_currency: 'ZiG' }); // ZiG 1060 = USD 40
  const s = salesSummary(db, day(0));
  assert.equal(s.sales, 2);
  assert.deepEqual(s.by_currency.map((c) => [c.currency, c.sales, c.gross_minor]), [['USD', 1, 600], ['ZiG', 1, 106_000]]);
  assert.equal(s.revenue_minor, 600 + 4000);
  assert.equal(s.cost_minor, 4 * 90 + 2500);
  assert.equal(s.tax_minor, a.tax_minor + b.tax_minor);
  assert.equal(s.profit_minor, 4600 - s.tax_minor - 2860);
  assert.equal(s.average_sale_minor, 2300);
  assert.equal(s.lines_without_cost, 0);
  assert.equal(salesSummary(db, day(1)).sales, 0);
  assert.equal(salesSummary(db, day(0), { branch_id: 'other' }).sales, 0);
});

test('a return reduces the sales of the day it was made, and a damaged item keeps its cost', () => {
  const { db, base, bread, sale } = world();
  const a = sale(D1, [[bread, 4000]], [cash('USD', 600)]);
  const line = returnableLines(db, a.sale_id)[0]!;
  const ctx = { ...base, now: D1 + DAY };
  processReturn(db, ctx, { sale_id: a.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  processReturn(db, ctx, { sale_id: a.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000, restock: false }], reason: 'damaged', payouts: [cash('USD', 150)] }, uid);
  const d0 = salesSummary(db, day(0));
  assert.equal(d0.revenue_minor, 600);
  assert.equal(d0.returns, 0);
  const d1 = salesSummary(db, day(1));
  assert.deepEqual([d1.sales, d1.returns, d1.revenue_minor], [0, 2, -300]);
  assert.equal(d1.cost_minor, -90, 'only the restocked item gives its cost back');
  const whole = salesSummary(db, { from: day(0).from, to: day(1).to });
  assert.deepEqual([whole.sales, whole.revenue_minor, whole.cost_minor], [1, 300, 360 - 90]);
  assert.equal(whole.by_currency[0]!.returns_minor, 300);
  assert.equal(whole.by_currency[0]!.net_minor, 300);
});

test('a voided sale and the returns made on it disappear from every figure', () => {
  const { db, base, bread, radio, sale } = world();
  sale(D1, [[radio, 1000]], [cash('USD', 4000)]);
  const v = sale(D1 + 10, [[bread, 2000]], [cash('USD', 300)]);
  const l = returnableLines(db, v.sale_id)[0]!;
  const ctx = { ...base, now: D1 + 20 };
  processReturn(db, ctx, { sale_id: v.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  voidSale(db, ctx, { sale_id: v.sale_id, reason: 'x', payouts: [cash('USD', 150)] }, uid);
  const s = salesSummary(db, day(0));
  assert.deepEqual([s.sales, s.returns, s.revenue_minor, s.cost_minor], [1, 0, 4000, 2500]);
  assert.deepEqual(topProducts(db, day(0)).map((p) => p.name), ['Radio']);
  assert.equal(dailySales(db, day(0), 120)[0]!.sales, 1);
});

test('a layby is open stock-held money until collected, then counts as a sale on the day of hand-over', () => {
  const { db, base, radio, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai' }, uid);
  const l = sale(D1, [[radio, 1000]], [cash('USD', 1000)], { customer_id: c, layby: true });
  let s = salesSummary(db, day(0));
  assert.deepEqual([s.sales, s.revenue_minor], [0, 0]);
  assert.deepEqual(s.open_layby, [{ currency: 'USD', count: 1, value_minor: 4000, paid_minor: 1000 }]);
  payLayby(db, { ...base, now: D1 + DAY }, { sale_id: l.sale_id, method_code: 'cash', currency: 'USD', amount_minor: 3000 }, uid);
  collectLayby(db, { ...base, now: D1 + DAY + 5 }, l.sale_id, uid);
  s = salesSummary(db, day(1));
  assert.deepEqual([s.sales, s.revenue_minor, s.open_layby.length], [1, 4000, 0]);
  assert.equal(salesSummary(db, day(0)).sales, 0);
});

test('daily sales use the shop\'s clock, fill empty days, and split at local midnight', () => {
  const { db, bread, sale } = world();
  sale(Date.UTC(2026, 10, 2, 21, 30), [[bread, 2000]], [cash('USD', 300)]); // 23:30 local on the 2nd
  sale(Date.UTC(2026, 10, 2, 22, 30), [[bread, 1000]], [cash('USD', 150)]); // 00:30 local on the 3rd
  const rows = dailySales(db, { from: LOCAL_MIDNIGHT, to: LOCAL_MIDNIGHT + 4 * DAY }, 120);
  assert.deepEqual(rows.map((r) => [r.day, r.sales, r.revenue_minor]), [['2026-11-02', 1, 300], ['2026-11-03', 1, 150], ['2026-11-04', 0, 0], ['2026-11-05', 0, 0]]);
  assert.equal(dayOf(Date.UTC(2026, 10, 2, 22, 30), 120), '2026-11-03');
});

test('best sellers are net of returns and can be ranked by quantity, revenue or profit', () => {
  const { db, base, bread, radio, sale } = world();
  const a = sale(D1, [[bread, 10_000]], [cash('USD', 1500)]);           // 10 loaves, 15.00
  sale(D1 + 1, [[radio, 1000]], [cash('USD', 4000)]);                   // 1 radio, 40.00
  const l = returnableLines(db, a.sale_id)[0]!;
  processReturn(db, { ...base, now: D1 + 2 }, { sale_id: a.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 4000 }], reason: 'x', payouts: [cash('USD', 600)] }, uid);
  const byQty = topProducts(db, day(0), { by: 'qty' });
  assert.deepEqual(byQty.map((p) => [p.name, p.qty_milli]), [['Bread', 6000], ['Radio', 1000]]);
  const byRev = topProducts(db, day(0), { by: 'revenue' });
  assert.deepEqual(byRev.map((p) => [p.name, p.revenue_minor]), [['Radio', 4000], ['Bread', 900]]);
  const radioRow = byRev[0]!;
  assert.deepEqual([radioRow.cost_minor, radioRow.profit_minor], [2500, 1500]);
  assert.equal(topProducts(db, day(0), { limit: 1 }).length, 1);
  assert.equal(topProducts(db, day(0), { by: 'profit' })[0]!.name, 'Radio');
});

test('takings by method: sales less change, account payments, and refunds', () => {
  const { db, base, bread, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const a = sale(D1, [[bread, 2000]], [cash('USD', 500)]);                          // 3.00 due, 5.00 cash, 2.00 change
  sale(D1 + 1, [[bread, 2000]], [{ method_code: 'ecocash', currency: 'USD', amount_minor: 300, reference: 'MP1' }]);
  sale(D1 + 2, [[bread, 2000]], [cash('USD', 100)], { customer_id: c, on_credit: true });
  receiveAccountPayment(db, { ...base, now: D1 + 3 }, { customer_id: c, debt_currency: 'USD', method_code: 'cash', currency: 'USD', amount_minor: 150 }, uid);
  const l = returnableLines(db, a.sale_id)[0]!;
  processReturn(db, { ...base, now: D1 + 4 }, { sale_id: a.sale_id, items: [{ sale_line_id: l.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [cash('USD', 150)] }, uid);
  const t = takings(db, day(0));
  assert.deepEqual(t.find((x) => x.method === 'Cash'), { method: 'Cash', currency: 'USD', received_minor: 500 + 100 + 150, paid_back_minor: 200 + 150, net_minor: 750 - 350 });
  assert.deepEqual(t.find((x) => x.method === 'EcoCash'), { method: 'EcoCash', currency: 'USD', received_minor: 300, paid_back_minor: 0, net_minor: 300 });
  assert.equal(takings(db, day(1)).length, 0);
});

test('stock value, out-of-stock items and expiring batches', () => {
  const { db, branch_id, bread, radio, q } = world();
  assert.deepEqual([stockValue(db).total_minor, stockValue(db).products], [50 * 90 + 5 * 2500, 2]);
  assert.equal(stockValue(db).rows[0]!.name, 'Radio');
  assert.deepEqual(outOfStock(db), []);
  db.prepare("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, type, qty_milli) values ('m-out', 'shop-0001', 1, ?, ?, 'loss', ?)").run(branch_id, radio, -5000);
  assert.deepEqual(outOfStock(db).map((x) => x.name), ['Radio']);
  assert.equal(stockValue(db).total_minor, 50 * 90);
  // a batch of bread expiring soon
  db.prepare("insert into stock_batches (id, shop_id, created_at, updated_at, version, product_id, branch_id, batch_code, expiry_date, received_at) values ('b1', 'shop-0001', 1, 1, 1, ?, ?, 'L1', '2026-11-05', 1)").run(bread, branch_id);
  db.prepare("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, batch_id, type, qty_milli) values ('m-b1', 'shop-0001', 1, ?, ?, 'b1', 'purchase', 3000)").run(branch_id, bread);
  const exp = expiringBatches(db, '2026-11-02', 7);
  assert.deepEqual(exp.map((e) => [e.name, e.batch_code, e.qty_milli, e.expired]), [['Bread', 'L1', 3000, false]]);
  assert.equal(expiringBatches(db, '2026-11-02', 1).length, 0);
  assert.equal(expiringBatches(db, '2026-11-10', 1)[0]!.expired, true);
  void q;
});

test('receivables list who owes what, and cash-ups list closed shifts with their differences', () => {
  const { db, base, branch_id, bread, sale } = world();
  const c = saveCustomer(db, base, { name: 'Mai', phone: '0772', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const c2 = saveCustomer(db, base, { name: 'Baba', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  sale(D1, [[bread, 2000]], [], { customer_id: c, on_credit: true });
  sale(D1, [[bread, 4000]], [], { customer_id: c2, on_credit: true });
  const r = receivables(db);
  assert.deepEqual(r.by_currency, [{ currency: 'USD', owed_minor: 900, customers: 2 }]);
  assert.deepEqual(r.debtors.map((d) => [d.name, d.owed_minor]), [['Baba', 600], ['Mai', 300]]);

  const sh = openShift(db, base, { branch_id, float: { USD: 1000 } }, uid);
  closeShift(db, { ...base, now: D1 + 1000 }, sh, { USD: 900, ZiG: 0 }, uid);
  const cu = cashUps(db, day(0));
  assert.equal(cu.length, 1);
  assert.deepEqual(cu[0]!.currencies.find((x) => x.currency === 'USD'), { currency: 'USD', expected_minor: 1000, counted_minor: 900, difference_minor: -100 });
  assert.equal(cashUps(db, day(1)).length, 0);
});

test('items sold with no cost are counted, not guessed', () => {
  const { db, base, branch_id, sale } = world();
  const free = saveProduct(db, base, { name: 'Mystery', price_minor: 100 }, uid);
  receiveStock(db, base, { branch_id, product_id: free, qty_milli: 5000, opening: true }, uid);
  sale(D1, [[free, 2000]], [cash('USD', 200)]);
  const s = salesSummary(db, day(0));
  assert.deepEqual([s.lines_without_cost, s.cost_minor, s.revenue_minor], [1, 0, 200]);
});
