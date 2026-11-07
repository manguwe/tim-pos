import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import {
  adjustStock, stockBuckets, adjustmentHistory, startStockTake, currentStockTake, stockTakeLines, recordCount, finishCounting, reopenCounting,
  approveStockTake, cancelStockTake, stockTakeReport,
} from '../src/stock.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `stk-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 3, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  const radio = saveProduct(db, base, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  const svc = saveProduct(db, base, { name: 'Airtime', price_minor: 100, track_stock: false }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(db, base, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const mgr = createUser(db, base, owner_id!, { name: 'Mary', role_id: q("select id from roles where name = 'Manager'")[0].id, pin: '4826' }, uid);
  const ctx = { ...base, user_id: mgr, now: T + 1000 };
  const level = (p: string, batch = '') => (q('select coalesce(sum(qty_milli),0) as s from stock_levels where product_id = ? and batch_key = ?', p, batch)[0].s as number);
  const sale = (product_id: string, qty_milli: number, price: number) => sell(db, { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: T + 500 },
    { branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id, qty_milli }], payments: [{ method_code: 'cash', currency: 'USD', amount_minor: price * qty_milli / 1000 }] }, uid);
  return { db, base, ctx, branch_id, owner: owner_id!, cashier, mgr, bread, radio, svc, q, level, sale };
}

test('damaged, expired and lost stock is removed with a reason and valued at cost', () => {
  const { db, ctx, branch_id, bread, radio, level, q } = world();
  const a = adjustStock(db, ctx, { branch_id, product_id: bread, kind: 'damaged', qty_milli: 2500, reason: 'Dropped crate' }, uid);
  assert.deepEqual([a.qty_milli, a.value_minor], [-2500, -225]);
  assert.equal(level(bread), 47_500);
  adjustStock(db, ctx, { branch_id, product_id: bread, kind: 'expired', qty_milli: 1000, reason: 'Past date' }, uid);
  adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 1000, reason: 'Stolen' }, uid);
  adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'found', qty_milli: 2000, reason: 'Found in storeroom' }, uid);
  assert.equal(level(radio), 6000);
  assert.deepEqual(q("select type, qty_milli, reason from stock_movements where type in ('damaged','expired','loss','adjustment') order by rowid").map((r) => [r.type, r.qty_milli]),
    [['damaged', -2500], ['expired', -1000], ['loss', -1000], ['adjustment', 2000]]);
  assert.equal(q("select count(*) as c from audit_log where action = 'stock_adjust'")[0].c, 4);
});

test('a removal cannot take more than is on the shelf; reasons and quantities are required', () => {
  const { db, ctx, branch_id, radio, svc } = world();
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 5001, reason: 'x' }, uid), /Only 5 of Radio/);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 1000, reason: '  ' }, uid), /reason/i);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 0, reason: 'x' }, uid), /more than zero/);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 1.5 as any, reason: 'x' }, uid), /more than zero/);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: 'nope', kind: 'loss', qty_milli: 1, reason: 'x' }, uid), /not found/);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: radio, kind: 'loss', qty_milli: 1, batch_id: 'nope', reason: 'x' }, uid), /batch/);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: svc, kind: 'loss', qty_milli: 1000, reason: 'x' }, uid), /Only 0/);
});

test('only people with stock.adjust may adjust', () => {
  const { db, base, cashier, branch_id, bread } = world();
  assert.throws(() => adjustStock(db, { ...base, user_id: cashier }, { branch_id, product_id: bread, kind: 'loss', qty_milli: 1000, reason: 'x' }, uid), /not allowed/);
});

test('batches are adjusted on their own', () => {
  const { db, ctx, base, branch_id, bread, q, level } = world();
  db.prepare("insert into stock_batches (id, shop_id, created_at, updated_at, version, product_id, branch_id, batch_code, expiry_date) values ('b1','shop-0001',1,1,1,?,?,'L1','2026-11-05')").run(bread, branch_id);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 3000, unit_cost_minor: 90, batch_id: 'b1' }, uid);
  assert.deepEqual(stockBuckets(db, branch_id, bread).map((b) => [b.batch_id, b.batch_code, b.qty_milli]), [['b1', 'L1', 3000], [null, null, 50_000]]);
  assert.throws(() => adjustStock(db, ctx, { branch_id, product_id: bread, batch_id: 'b1', kind: 'expired', qty_milli: 3001, reason: 'x' }, uid), /in that batch/);
  adjustStock(db, ctx, { branch_id, product_id: bread, batch_id: 'b1', kind: 'expired', qty_milli: 3000, reason: 'Expired' }, uid);
  assert.equal(level(bread, 'b1'), 0);
  assert.equal(level(bread), 50_000);
  assert.equal(q("select batch_id from stock_movements where type = 'expired'")[0].batch_id, 'b1');
});

test('adjustment history totals by type, newest first, within the date range', () => {
  const { db, ctx, base, branch_id, bread, radio } = world();
  adjustStock(db, { ...ctx, now: T + 10 }, { branch_id, product_id: bread, kind: 'damaged', qty_milli: 2000, reason: 'a' }, uid);
  adjustStock(db, { ...ctx, now: T + 20 }, { branch_id, product_id: radio, kind: 'loss', qty_milli: 1000, reason: 'b' }, uid);
  adjustStock(db, { ...ctx, now: T + 30 }, { branch_id, product_id: bread, kind: 'damaged', qty_milli: 1000, reason: 'c' }, uid);
  adjustStock(db, { ...ctx, now: T + 99_999 }, { branch_id, product_id: radio, kind: 'found', qty_milli: 1000, reason: 'later' }, uid);
  const h = adjustmentHistory(db, { from: T, to: T + 1000 });
  assert.deepEqual(h.rows.map((r) => r.reason), ['c', 'b', 'a']);
  assert.deepEqual(h.rows.map((r) => r.user), ['Mary', 'Mary', 'Mary']);
  assert.deepEqual(h.summary, [{ type: 'damaged', count: 2, qty_milli: -3000, value_minor: -270 }, { type: 'loss', count: 1, qty_milli: -1000, value_minor: -2500 }]);
  assert.equal(adjustmentHistory(db, { from: T, to: T + 1000, branch_id: 'other' }).rows.length, 0);
  void base;
});

test('a stock take snapshots tracked products, takes counts, and changes nothing until approved', () => {
  const { db, ctx, branch_id, bread, radio, level } = world();
  const { take_id, lines } = startStockTake(db, ctx, { branch_id }, uid);
  assert.equal(lines, 2); // Airtime is not tracked
  assert.deepEqual(stockTakeLines(db, take_id).map((l) => [l.product, l.expected_milli, l.counted_milli]), [['Bread', 50_000, null], ['Radio', 5000, null]]);
  assert.throws(() => startStockTake(db, ctx, { branch_id }, uid), /already in progress/);
  assert.equal(currentStockTake(db, branch_id)!.id, take_id);
  assert.throws(() => finishCounting(db, ctx, take_id, uid), /at least one/);
  const [lb, lr] = stockTakeLines(db, take_id);
  recordCount(db, ctx, lb!.id, 49_000, uid); // 1 short
  recordCount(db, ctx, lr!.id, 6000, uid);   // 1 extra
  assert.throws(() => recordCount(db, ctx, lb!.id, -1, uid), /zero or more/);
  const rep = finishCounting(db, ctx, take_id, uid);
  assert.deepEqual([rep.counted_lines, rep.uncounted_lines, rep.surplus_minor, rep.shortage_minor], [2, 0, 2500, 1000 * 90 / 1000]);
  assert.deepEqual(rep.lines.map((l) => l.difference_milli), [-1000, 1000]);
  assert.equal(level(bread), 50_000);
  assert.throws(() => recordCount(db, ctx, lb!.id, 1000, uid), /no longer open/);
  const r = approveStockTake(db, ctx, take_id, null, uid);
  assert.deepEqual([r.corrections, r.surplus_minor, r.shortage_minor], [2, 2500, 90]);
  assert.equal(level(bread), 49_000);
  assert.equal(level(radio), 6000);
  assert.equal(currentStockTake(db, branch_id), undefined);
  assert.throws(() => approveStockTake(db, ctx, take_id, null, uid), /Finish counting/);
  assert.throws(() => cancelStockTake(db, ctx, take_id, uid), /cannot be cancelled/);
});

test('sales made while counting are kept: the correction is counted minus the snapshot', () => {
  const { db, ctx, branch_id, bread, level, sale } = world();
  const { take_id } = startStockTake(db, ctx, { branch_id, product_ids: [bread] }, uid);
  sale(bread, 4000, 150);                        // 46 on the system now
  const [l] = stockTakeLines(db, take_id);
  recordCount(db, ctx, l!.id, 49_000, uid);      // shelf counted 49: it was 50, 1 missing, plus the 4 sold after counting
  finishCounting(db, ctx, take_id, uid);
  approveStockTake(db, ctx, take_id, null, uid);
  assert.equal(level(bread), 45_000);
});

test('uncounted lines are left alone, a partial take only lists the chosen products, and counting can be reopened', () => {
  const { db, ctx, branch_id, bread, radio, level } = world();
  const { take_id, lines } = startStockTake(db, ctx, { branch_id, product_ids: [bread, radio] }, uid);
  assert.equal(lines, 2);
  const [lb] = stockTakeLines(db, take_id);
  recordCount(db, ctx, lb!.id, 48_000, uid);
  finishCounting(db, ctx, take_id, uid);
  reopenCounting(db, ctx, take_id, uid);
  recordCount(db, ctx, lb!.id, 47_000, uid);
  const rep = finishCounting(db, ctx, take_id, uid);
  assert.deepEqual([rep.counted_lines, rep.uncounted_lines], [1, 1]);
  const r = approveStockTake(db, ctx, take_id, null, uid);
  assert.equal(r.corrections, 1);
  assert.deepEqual([level(bread), level(radio)], [47_000, 5000]);
});

test('approval needs a manager; a cashier can be covered by a manager approval; a take can be cancelled', () => {
  const { db, ctx, base, branch_id, bread, cashier, mgr, level } = world();
  const { take_id } = startStockTake(db, ctx, { branch_id }, uid);
  const [l] = stockTakeLines(db, take_id);
  recordCount(db, ctx, l!.id, 40_000, uid);
  finishCounting(db, ctx, take_id, uid);
  assert.throws(() => approveStockTake(db, { ...base, user_id: cashier }, take_id, null, uid), /needs a manager/);
  assert.throws(() => approveStockTake(db, { ...base, user_id: cashier }, take_id, cashier, uid), /needs a manager/);
  approveStockTake(db, { ...base, user_id: cashier, now: T + 5000 }, take_id, mgr, uid);
  assert.equal(level(bread), 40_000);
  const t2 = startStockTake(db, ctx, { branch_id }, uid).take_id;
  cancelStockTake(db, ctx, t2, uid);
  assert.equal(currentStockTake(db, branch_id), undefined);
  assert.equal(level(bread), 40_000);
  assert.throws(() => stockTakeReport(db, t2), /not found/);
});
