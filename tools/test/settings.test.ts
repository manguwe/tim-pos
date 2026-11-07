import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';
import { getSettings, saveSettings, SETTINGS } from '../src/settings.ts';
import { loadReceipt } from '../src/receipt.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `set-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 3, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  receiveStock(db, base, { branch_id, product_id: bread, qty_milli: 10_000, unit_cost_minor: 90, opening: true }, uid);
  return { db, base, owner: owner_id!, cashier, branch_id, bread, q };
}

test('every setting has a default, and unknown rows are ignored', () => {
  const { db } = world();
  const s = getSettings(db);
  assert.deepEqual(Object.keys(s).sort(), SETTINGS.map((d) => d.key).sort());
  assert.equal(s.require_shift, '0');
  assert.equal(s.layby_min_deposit_pct, '0');
  assert.equal(s.receipt_footer, '');
});

test('saving changes only what differs, bumps the version and writes the audit log', () => {
  const { db, base, owner, q } = world();
  const ctx = { ...base, user_id: owner, now: T + 1000 };
  assert.deepEqual(saveSettings(db, ctx, { require_shift: '1', allow_negative_stock: '0', layby_min_deposit_pct: ' 20 ' }, uid), ['require_shift', 'layby_min_deposit_pct']);
  assert.deepEqual([getSettings(db).require_shift, getSettings(db).layby_min_deposit_pct], ['1', '20']);
  assert.deepEqual(saveSettings(db, ctx, { require_shift: '1' }, uid), []);
  saveSettings(db, { ...ctx, now: T + 2000 }, { require_shift: '0' }, uid);
  const row = q("select value, version from settings where key = 'require_shift'")[0];
  assert.deepEqual([row.value, row.version], ['0', 2]);
  const log = q("select before, after from audit_log where action = 'setting_change' and row_id = 'require_shift' order by rowid");
  assert.deepEqual(log.map((l) => [l.before, l.after]), [['0', '1'], ['1', '0']]);
  assert.equal(q("select count(*) as c from settings where key = 'require_shift' and deleted_at is null")[0].c, 1);
});

test('bad values are refused and nothing at all is saved', () => {
  const { db, base, owner } = world();
  const ctx = { ...base, user_id: owner };
  assert.throws(() => saveSettings(db, ctx, { require_shift: '1', layby_min_deposit_pct: '101' }, uid), /from 0 to 100/);
  assert.throws(() => saveSettings(db, ctx, { layby_min_deposit_pct: '-5' }, uid), /whole number/);
  assert.throws(() => saveSettings(db, ctx, { layby_min_deposit_pct: '12.5' }, uid), /whole number/);
  assert.throws(() => saveSettings(db, ctx, { require_shift: 'yes' }, uid), /on or off/);
  assert.throws(() => saveSettings(db, ctx, { receipt_footer: 'x'.repeat(121) }, uid), /at most 120/);
  assert.throws(() => saveSettings(db, ctx, { costing: 'fifo' }, uid), /does not exist/);
  assert.equal(getSettings(db).require_shift, '0');
});

test('only someone with settings.edit can change settings', () => {
  const { db, base, cashier } = world();
  assert.throws(() => saveSettings(db, { ...base, user_id: cashier }, { require_shift: '1' }, uid), /not allowed/);
  assert.equal(getSettings(db).require_shift, '0');
});

test('receipt text is trimmed to one line, and it reaches the receipt', () => {
  const { db, base, owner, branch_id, bread } = world();
  saveSettings(db, { ...base, user_id: owner }, { receipt_header: '  Wholesale\n and retail  ', receipt_footer: 'No refunds without receipt' }, uid);
  assert.equal(getSettings(db).receipt_header, 'Wholesale and retail');
  const s = sell(db, { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: T + 5 }, { branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: bread, qty_milli: 1000 }], payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 150 }] }, uid);
  const r = loadReceipt(db, s.sale_id);
  assert.deepEqual([r.header, r.footer], ['Wholesale and retail', 'No refunds without receipt']);
  saveSettings(db, { ...base, user_id: owner, now: T + 9 }, { receipt_footer: '' }, uid);
  assert.equal(loadReceipt(db, s.sale_id).footer, '');
});

test('the settings change how selling behaves', () => {
  const { db, base, owner, branch_id, bread } = world();
  const sctx = { shop_id: base.shop_id, device_id: base.device_id, receipt_prefix: 'D1', now: T + 5 };
  const cart = (qty: number, extra: any = {}) => ({ branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: bread, qty_milli: qty }], payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 150 * (qty / 1000) }], ...extra });
  assert.throws(() => sell(db, sctx, cart(11_000), uid), /Only 10 of Bread/);
  saveSettings(db, { ...base, user_id: owner }, { allow_negative_stock: '1', require_shift: '1' }, uid);
  assert.throws(() => sell(db, sctx, cart(1000), uid), /shift/i);
  saveSettings(db, { ...base, user_id: owner, now: T + 9 }, { require_shift: '0' }, uid);
  assert.ok(sell(db, sctx, cart(11_000), uid).sale_id);
});
