import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, setExchangeRate, saveProduct, receiveStock, SetupError, type SetupContext } from '../src/setup.ts';
import { sell } from '../src/selling.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `gen-${String(++n).padStart(8, '0')}`;
const T = 1_800_000_000_000;
const ctx: SetupContext = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T };

function phone() {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = on');
  for (const s of SQL.split(/^-- ##$/m).map((x) => x.trim()).filter((x) => x && !x.startsWith('--'))) db.exec(s);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  return { db, q };
}
const code = (fn: () => unknown) => { try { fn(); } catch (e) { return (e as SetupError).code; } return 'no error'; };

test('first-time set-up creates the shop, branch, currencies, payment methods, taxes, tiers and settings', () => {
  const { db, q } = phone();
  const r = seedShop(db, ctx, { name: ' Mbare Mini Market ', country_code: 'zw' }, uid);
  assert.equal(r.created, true);
  assert.deepEqual(q('select id, name, base_currency from shops'), [{ id: 'shop-0001', name: 'Mbare Mini Market', base_currency: 'USD' }]);
  assert.deepEqual(q('select code from currencies order by code').map((c) => c.code), ['USD', 'ZiG']);
  assert.deepEqual(q('select code from payment_methods order by code').map((c) => c.code), ['bank_transfer', 'card', 'cash', 'ecocash', 'innbucks', 'onemoney']);
  assert.equal(q("select rate_bp from tax_classes where name = 'Standard rated'")[0].rate_bp, 1500);
  assert.equal(q('select count(*) c from price_tiers where is_default = 1')[0].c, 1);
  assert.equal(q("select value from settings where key = 'costing'")[0].value, 'weighted_average');
  assert.equal(q("select count(*) c from change_log")[0].c > 20, true, 'all of it is queued to sync to the shop\'s other phones');
});

test('running set-up again, or after the shop arrived by sync, changes nothing', () => {
  const { db, q } = phone();
  seedShop(db, ctx, { name: 'A', country_code: 'ZW' }, uid);
  const before = q('select count(*) c from change_log')[0].c;
  const again = seedShop(db, ctx, { name: 'B', country_code: 'ZM' }, uid);
  assert.equal(again.created, false);
  assert.equal(q('select count(*) c from change_log')[0].c, before);
  assert.equal(q('select name from shops')[0].name, 'A');
});

test('bad set-up input is refused; Zambia has its own preset', () => {
  const { db, q } = phone();
  assert.equal(code(() => seedShop(db, ctx, { name: '  ', country_code: 'ZW' }, uid)), 'missing');
  assert.equal(code(() => seedShop(db, ctx, { name: 'X', country_code: 'XX' }, uid)), 'unknown_country');
  assert.equal(q('select count(*) c from shops')[0].c, 0);
  seedShop(db, ctx, { name: 'Lusaka Shop', country_code: 'ZM' }, uid);
  assert.equal(q('select base_currency from shops')[0].base_currency, 'ZMW');
  assert.equal(q("select rate_bp from tax_classes where name = 'Standard rated'")[0].rate_bp, 1600);
  assert.ok(q("select 1 from payment_methods where code = 'mtn_momo'").length);
});

test('exchange rates are added, never overwritten, and validated', () => {
  const { db, q } = phone();
  seedShop(db, ctx, { name: 'A', country_code: 'ZW' }, uid);
  setExchangeRate(db, ctx, 'USD', 'ZiG', 26_500_000, uid);
  setExchangeRate(db, { ...ctx, now: T + 1000 }, 'USD', 'ZiG', 27_000_000, uid);
  assert.deepEqual(q('select rate_micro from exchange_rates order by effective_from').map((r) => r.rate_micro), [26_500_000, 27_000_000]);
  assert.equal(code(() => setExchangeRate(db, ctx, 'USD', 'USD', 1_000_000, uid)), 'same_currency');
  assert.equal(code(() => setExchangeRate(db, ctx, 'USD', 'ZiG', 0, uid)), 'bad_rate');
  assert.equal(code(() => setExchangeRate(db, ctx, 'USD', 'EUR', 900_000, uid)), 'unknown_currency');
});

test('products: create with price and barcode, edit (version rises), price history is kept', () => {
  const { db, q } = phone();
  seedShop(db, ctx, { name: 'A', country_code: 'ZW' }, uid);
  const vat = q("select id from tax_classes where name = 'Standard rated'")[0].id;
  const id = saveProduct(db, ctx, { name: 'Bread', sku: 'BRD1', barcode: '6001234', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  assert.deepEqual(q('select name, version, track_stock, cost_minor from products'), [{ name: 'Bread', version: 1, track_stock: 1, cost_minor: 90 }]);
  assert.equal(q('select price_minor from product_prices')[0].price_minor, 150);

  saveProduct(db, { ...ctx, now: T + 5000 }, { id, name: 'Brown bread', sku: 'BRD1', barcode: '6001234', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  assert.equal(q('select count(*) c from product_prices')[0].c, 1, 'same price: no new row');
  saveProduct(db, { ...ctx, now: T + 9000 }, { id, name: 'Brown bread', price_minor: 175 }, uid);
  assert.deepEqual(q('select price_minor from product_prices order by effective_from').map((r) => r.price_minor), [150, 175]);
  assert.deepEqual(q('select name, version from products'), [{ name: 'Brown bread', version: 3 }]);
  assert.equal(q("select count(*) c from product_barcodes").at(0).c, 1, 'the barcode is not added twice');
  assert.deepEqual(q("select op, version from change_log where table_name = 'products' order by seq").map((r) => [r.op, r.version]), [['insert', 1], ['update', 2], ['update', 3]]);
});

test('a barcode belongs to one product; bad amounts and missing names are refused', () => {
  const { db, q } = phone();
  seedShop(db, ctx, { name: 'A', country_code: 'ZW' }, uid);
  saveProduct(db, ctx, { name: 'Bread', barcode: '111', price_minor: 100 }, uid);
  assert.equal(code(() => saveProduct(db, ctx, { name: 'Milk', barcode: '111', price_minor: 100 }, uid)), 'barcode_taken');
  assert.equal(q('select count(*) c from products')[0].c, 1, 'the failed save left no half-made product');
  assert.equal(code(() => saveProduct(db, ctx, { name: '', price_minor: 1 }, uid)), 'missing');
  assert.equal(code(() => saveProduct(db, ctx, { name: 'X', price_minor: -5 }, uid)), 'bad_amount');
  assert.equal(code(() => saveProduct(db, ctx, { name: 'X', price_minor: 1.5 }, uid)), 'bad_amount');
});

test('receiving stock keeps a weighted-average cost, or the latest cost if the shop chose that', () => {
  const { db, q } = phone();
  const { branch_id } = seedShop(db, ctx, { name: 'A', country_code: 'ZW' }, uid);
  const id = saveProduct(db, ctx, { name: 'Rice', price_minor: 300, cost_minor: 100 }, uid);
  receiveStock(db, ctx, { branch_id, product_id: id, qty_milli: 10_000, unit_cost_minor: 100, opening: true }, uid);
  receiveStock(db, ctx, { branch_id, product_id: id, qty_milli: 10_000, unit_cost_minor: 120 }, uid);
  assert.equal(q('select cost_minor from products')[0].cost_minor, 110, '(10 x 1.00 + 10 x 1.20) / 20');
  receiveStock(db, ctx, { branch_id, product_id: id, qty_milli: 20_000, unit_cost_minor: 130 }, uid);
  assert.equal(q('select cost_minor from products')[0].cost_minor, 120, '(20 x 1.10 + 20 x 1.30) / 40');
  assert.equal(q('select qty_milli from stock_levels')[0].qty_milli, 40_000);
  assert.deepEqual(q("select type from stock_movements order by created_at, rowid").map((r) => r.type), ['opening', 'purchase', 'purchase']);

  db.prepare("update settings set value = 'latest', version = version + 1 where key = 'costing'").run();
  receiveStock(db, ctx, { branch_id, product_id: id, qty_milli: 1_000, unit_cost_minor: 200 }, uid);
  assert.equal(q('select cost_minor from products')[0].cost_minor, 200);
  assert.equal(code(() => receiveStock(db, ctx, { branch_id, product_id: id, qty_milli: 0 }, uid)), 'bad_quantity');
  assert.equal(code(() => receiveStock(db, ctx, { branch_id, product_id: 'nope', qty_milli: 1000 }, uid)), 'not_found');
});

test('end to end: set up a shop, add stock, change the rate, and sell in both currencies', () => {
  const { db, q } = phone();
  const { branch_id } = seedShop(db, ctx, { name: 'Mbare Mini Market', country_code: 'ZW' }, uid);
  setExchangeRate(db, ctx, 'USD', 'ZiG', 26_500_000, uid);
  const vat = q("select id from tax_classes where name = 'Standard rated'")[0].id;
  const bread = saveProduct(db, ctx, { name: 'Bread', barcode: '6001', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  receiveStock(db, ctx, { branch_id, product_id: bread, qty_milli: 10_000, unit_cost_minor: 90, opening: true }, uid);

  const sctx = { shop_id: ctx.shop_id, device_id: ctx.device_id, receipt_prefix: 'D1', now: T + 60_000 };
  const usd = sell(db, sctx, { branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: bread, qty_milli: 2_000 }], payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 500 }] }, uid);
  assert.equal(usd.total_minor, 300); assert.equal(usd.tax_minor, 39);
  assert.deepEqual(usd.change, { currency: 'USD', amount_minor: 200 });
  const zig = sell(db, sctx, { branch_id, user_id: null, sale_currency: 'ZiG', lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [{ method_code: 'cash', currency: 'ZiG', amount_minor: 4000 }] }, uid);
  assert.equal(zig.total_minor, 3975);
  assert.equal(zig.receipt_no, 'D1-000002');
  assert.equal(q('select qty_milli from stock_levels')[0].qty_milli, 7_000);
});
