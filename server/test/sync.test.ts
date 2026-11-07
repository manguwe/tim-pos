import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DAY, START, activateDevice, boot, change, makeShop, push, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

const feedCount = (shop: string) =>
  h.ctx.db.get<{ n: number }>('select count(*) as n from change_feed where shop_id = ?', shop)!.n;

test('new sales and stock movements are accepted and land in the change feed', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const r = await push(h, d, [
    change('sales', { total_minor: 1250, sale_currency: 'USD' }),
    change('stock_movements', { product_id: 'p1', qty_milli: -2000, type: 'sale' }),
  ]);
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted, 2);
  assert.deepEqual(r.json.rejected, []);
  assert.equal(feedCount(shop.tenantId), 2);
});

test('resending the same batch after a dropped connection changes nothing', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const batch = [change('sales', { total_minor: 500 }), change('sale_payments', { amount_minor: 500 })];
  const id = randomUUID();
  const first = await push(h, d, batch, id);
  const again = await push(h, d, batch, id);
  assert.equal(first.json.accepted, 2);
  assert.equal(again.json.duplicate, true);
  assert.equal(again.json.accepted, 2, 'it reports what the first attempt did');
  assert.equal(feedCount(shop.tenantId), 2, 'no duplicates');
});

test('the same row sent in a different batch is skipped, not doubled', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const sale = change('sales', { total_minor: 900 });
  await push(h, d, [sale]);
  const r = await push(h, d, [sale]);
  assert.equal(r.json.accepted, 0);
  assert.equal(r.json.skipped, 1);
  assert.equal(feedCount(shop.tenantId), 1);
});

test('twenty identical pushes at the same moment apply exactly once', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const body = { batch_id: randomUUID(), changes: [change('sales', { total_minor: 100 }), change('sales', { total_minor: 200 })] };
  const results = await Promise.all(Array.from({ length: 20 }, () => h.call('POST', '/v1/sync/push', { auth: d.auth, body })));
  assert.ok(results.every((r) => r.status === 200));
  assert.equal(results.filter((r) => !r.json.duplicate).length, 1);
  assert.equal(feedCount(shop.tenantId), 2);
});

test('sales and other history cannot be edited or deleted through sync', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const sale = change('sales', { total_minor: 700 });
  await push(h, d, [sale]);
  const r = await push(h, d, [
    { ...sale, op: 'update', version: 2, data: { total_minor: 1 } },
    { ...sale, op: 'delete', version: 3 },
  ]);
  assert.equal(r.json.accepted, 0);
  assert.deepEqual(r.json.rejected.map((x: any) => x.reason), ['append_only', 'append_only']);
  const stored = h.ctx.db.get<{ data: string }>('select data from records where shop_id = ? and row_id = ?', shop.tenantId, sale.row_id)!;
  assert.equal(JSON.parse(stored.data).total_minor, 700);
});

test('one bad row is rejected with a reason and does not block the good rows around it', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const r = await push(h, d, [
    change('sales', { total_minor: 1 }),
    change('held_sales', { x: 1 }),
    change('not_a_table', { x: 1 }),
    { table: 'sales', row_id: 'short', op: 'insert', version: 1, updated_at: START, data: {} },
    { table: 'sales', row_id: randomUUID(), op: 'insert', version: 0, updated_at: START, data: {} },
    { table: 'sales', row_id: randomUUID(), op: 'insert', version: 1, updated_at: START, data: [] },
    change('sales', { total_minor: 2 }),
  ]);
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted, 2);
  assert.deepEqual(r.json.rejected.map((x: any) => [x.index, x.reason]), [
    [1, 'local_only_table'], [2, 'unknown_table'], [3, 'bad_row_id'], [4, 'bad_version'], [5, 'bad_data'],
  ]);
});

test('a row claiming to belong to another shop is rejected, and the shop id is always set by the server', async () => {
  const shop = await makeShop(h);
  const other = await makeShop(h, { name: 'Other Shop' });
  const d = await activateDevice(h, shop.key);
  const r = await push(h, d, [
    change('sales', { total_minor: 1, shop_id: other.tenantId }),
    change('sales', { total_minor: 2 }),
  ]);
  assert.equal(r.json.rejected[0].reason, 'wrong_shop');
  const row = h.ctx.db.get<{ data: string }>(
    "select data from records where shop_id = ? and table_name = 'sales'", shop.tenantId)!;
  assert.equal(JSON.parse(row.data).shop_id, shop.tenantId);
  assert.equal(h.ctx.db.get<{ n: number }>('select count(*) as n from records where shop_id = ?', other.tenantId)!.n, 0);
});

test('edited reference data: the higher version wins and the loser is kept in the conflict log', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  const id = randomUUID();
  const product = (price: number, version: number, t: number) =>
    change('products', { name: 'Sugar 2kg', price_minor: price }, { id, op: version === 1 ? 'insert' : 'update', version, updated_at: t });

  await push(h, a, [product(300, 1, START)]);
  await push(h, b, [product(350, 3, START + 3000)]); // another phone edited it twice
  const stale = await push(h, a, [product(320, 2, START + 5000)]); // late arrival with a lower version
  assert.equal(stale.json.accepted, 0);
  assert.equal(stale.json.skipped, 1);
  const kept = h.ctx.db.get<{ data: string; version: number }>(
    "select data, version from records where shop_id = ? and table_name = 'products' and row_id = ?", shop.tenantId, id)!;
  assert.equal(kept.version, 3);
  assert.equal(JSON.parse(kept.data).price_minor, 350);
  const lost = h.ctx.db.all<{ incoming_version: number; kept_version: number }>(
    'select incoming_version, kept_version from sync_conflicts where shop_id = ?', shop.tenantId);
  assert.deepEqual(lost.map((r) => ({ ...r })), [{ incoming_version: 2, kept_version: 3 }]);
});

test('on an equal version, the later edit wins; deletes are soft and stay in the feed', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const id = randomUUID();
  await push(h, a, [change('customers', { name: 'Old' }, { id, version: 2, updated_at: START })]);
  await push(h, a, [change('customers', { name: 'Newer' }, { id, op: 'update', version: 2, updated_at: START + 10 })]);
  await push(h, a, [change('customers', { name: 'Older' }, { id, op: 'update', version: 2, updated_at: START + 5 })]);
  const row = () => h.ctx.db.get<{ data: string; deleted_at: number | null }>(
    "select data, deleted_at from records where shop_id = ? and table_name = 'customers' and row_id = ?", shop.tenantId, id)!;
  assert.equal(JSON.parse(row().data).name, 'Newer');
  await push(h, a, [change('customers', { name: 'Newer' }, { id, op: 'delete', version: 3, updated_at: START + 20 })]);
  assert.equal(row().deleted_at, START + 20);
  assert.ok(feedCount(shop.tenantId) >= 3);
});

test('another phone receives changes; the sender does not get its own back unless restoring', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  await push(h, a, [change('products', { name: 'Rice 5kg' }), change('sales', { total_minor: 800 })]);

  const forB = await h.call('GET', '/v1/sync/pull?since=0', { auth: b.auth });
  assert.equal(forB.json.changes.length, 2);
  assert.deepEqual(forB.json.changes.map((c: any) => c.table), ['products', 'sales']);

  const forA = await h.call('GET', '/v1/sync/pull?since=0', { auth: a.auth });
  assert.equal(forA.json.changes.length, 0);
  assert.equal(forA.json.next_seq, forB.json.next_seq, 'its cursor still moves forward');

  const restore = await h.call('GET', '/v1/sync/pull?since=0&include_own=1', { auth: a.auth });
  assert.equal(restore.json.changes.length, 2, 'a reinstalled phone gets its own history back');
});

test('pulling in pages resumes from the cursor and never skips or repeats a row', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  await push(h, a, Array.from({ length: 7 }, (_, i) => change('sales', { n: i })));
  const seen: number[] = [];
  let since = 0;
  let pages = 0;
  for (;;) {
    const r = await h.call('GET', `/v1/sync/pull?since=${since}&limit=3`, { auth: b.auth });
    seen.push(...r.json.changes.map((c: any) => c.data.n));
    since = r.json.next_seq;
    pages += 1;
    if (!r.json.has_more) break;
  }
  assert.deepEqual(seen, [0, 1, 2, 3, 4, 5, 6]);
  assert.equal(pages, 3);
});

test('two phones selling offline: every stock movement from both is kept, so stock adds up correctly', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  // Both sold the last 3 units without knowing about each other.
  await push(h, a, [change('stock_movements', { product_id: 'oil', qty_milli: 3000, type: 'opening' })]);
  await push(h, a, [change('stock_movements', { product_id: 'oil', qty_milli: -3000, type: 'sale' })]);
  await push(h, b, [change('stock_movements', { product_id: 'oil', qty_milli: -3000, type: 'sale' })]);
  const total = h.ctx.db.all<{ data: string }>(
    "select data from records where shop_id = ? and table_name = 'stock_movements'", shop.tenantId)
    .reduce((n, r) => n + (JSON.parse(r.data).qty_milli as number), 0);
  assert.equal(total, -3000, 'stock is negative and can be flagged, and nothing was lost or overwritten');
});

test('one shop can never read, collide with or overwrite another shop\'s data', async () => {
  const s1 = await makeShop(h, { name: 'Shop One' });
  const s2 = await makeShop(h, { name: 'Shop Two' });
  const d1 = await activateDevice(h, s1.key);
  const d2 = await activateDevice(h, s2.key);
  const shared = randomUUID(); // both shops happen to use the same row id
  await push(h, d1, [change('products', { name: 'Shop One secret' }, { id: shared })]);
  const r2 = await push(h, d2, [change('products', { name: 'Shop Two product' }, { id: shared })]);
  assert.equal(r2.json.accepted, 1, 'no collision across shops');

  const pulled = await h.call('GET', '/v1/sync/pull?since=0&include_own=1', { auth: d2.auth });
  assert.equal(pulled.json.changes.length, 1);
  assert.ok(!JSON.stringify(pulled.json).includes('Shop One secret'));
  const one = h.ctx.db.get<{ data: string }>('select data from records where shop_id = ? and row_id = ?', s1.tenantId, shared)!;
  assert.equal(JSON.parse(one.data).name, 'Shop One secret');
});

test('compressed request bodies are accepted; broken or oversized ones are refused', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const ok = await h.call('POST', '/v1/sync/push', {
    auth: d.auth, gzip: true, body: { batch_id: randomUUID(), changes: Array.from({ length: 50 }, () => change('sales', { x: 'y'.repeat(100) })) },
  });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.accepted, 50);

  const bad = await h.call('POST', '/v1/sync/push', {
    auth: d.auth, headers: { 'content-encoding': 'gzip', 'content-type': 'application/json' }, rawBody: Buffer.from('not gzip'),
  });
  assert.equal(bad.status, 400);

  const tooMany = await push(h, d, Array.from({ length: 1001 }, () => change('sales')));
  assert.equal(tooMany.status, 413);
  assert.equal(tooMany.json.error.code, 'batch_too_large');
  assert.equal(feedCount(shop.tenantId), 50, 'a refused batch writes nothing');
});

test('bad batch ids and bodies get clear errors', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  assert.equal((await h.call('POST', '/v1/sync/push', { auth: d.auth, body: { batch_id: 'x', changes: [] } })).status, 400);
  assert.equal((await h.call('POST', '/v1/sync/push', { auth: d.auth, body: { batch_id: randomUUID(), changes: 'nope' } })).status, 400);
  assert.equal((await h.call('POST', '/v1/sync/push', { auth: d.auth, body: [] })).status, 400);
  assert.equal((await h.call('POST', '/v1/sync/push', { auth: d.auth, rawBody: '{broken', headers: { 'content-type': 'application/json' } })).status, 400);
  assert.equal((await h.call('GET', '/v1/sync/pull?since=-5', { auth: d.auth })).status, 400);
  assert.equal((await h.call('GET', '/v1/sync/pull?since=abc', { auth: d.auth })).status, 400);
});

test('sync works during the grace period and stops once it ends, while old data stays safe on the server', async () => {
  const shop = await makeShop(h, { months: 1, grace_days: 5 });
  const d = await activateDevice(h, shop.key);
  await push(h, d, [change('sales', { total_minor: 100 })]);
  h.clock.t += 33 * DAY; // 3 days into grace
  assert.equal((await push(h, d, [change('sales', { total_minor: 200 })])).status, 200);
  h.clock.t += 10 * DAY; // grace over
  const r = await push(h, d, [change('sales', { total_minor: 300 })]);
  assert.equal(r.status, 402);
  assert.equal(r.json.error.locked, true);
  assert.equal(feedCount(shop.tenantId), 2);
});

test('the sync cursor each phone reports is recorded, so the vendor can see which phones are behind', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  await push(h, a, [change('sales', { n: 1 }), change('sales', { n: 2 })]);
  const pulled = await h.call('GET', '/v1/sync/pull?since=0', { auth: b.auth });
  await h.call('GET', `/v1/sync/pull?since=${pulled.json.next_seq}`, { auth: b.auth });
  const detail = await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}`, { auth: shop.vendor });
  const bRow = detail.json.devices.find((x: any) => x.id === b.id);
  assert.equal(bRow.last_pull_seq, pulled.json.next_seq);
  assert.equal(detail.json.sync_head_seq, pulled.json.next_seq);
});
