import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { saveSettings } from '../src/settings.ts';
import { toText, toEscPos } from '../src/receipt.ts';
import {
  cleanBarcode, checkDigit, describeBarcode, lookupForms, makeEan13, resolveScan, addBarcode, removeBarcode, listBarcodes,
  newShopCode, giveShopCode, layoutLabel, loadLabel,
} from '../src/barcodes.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `bar-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 10, 4, 6, 0);

function world() {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base: SetupContext & { receipt_prefix: string } = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T, receipt_prefix: 'D1' };
  const { branch_id, owner_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const cashier = createUser(db, base, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  const milk = saveProduct(db, base, { name: 'Milk', price_minor: 200 }, uid);
  const kg = q("select id from units where code = 'kg'")[0].id;
  const beef = saveProduct(db, base, { name: 'Beef', price_minor: 800, base_unit_id: kg }, uid);
  return { db, base, owner: owner_id!, cashier, branch_id, bread, milk, beef, q };
}

test('cleaning and check digits', () => {
  assert.equal(cleanBarcode(' 5901234123457\r\n'), '5901234123457');
  assert.equal(checkDigit('590123412345'), 7);
  assert.deepEqual(describeBarcode('5901234123457'), { kind: 'EAN-13', valid: true });
  assert.deepEqual(describeBarcode('5901234123458'), { kind: 'EAN-13', valid: false });
  assert.deepEqual(describeBarcode('96385074'), { kind: 'EAN-8', valid: true });
  assert.deepEqual(describeBarcode('036000291452'), { kind: 'UPC-A', valid: true });
  assert.deepEqual(describeBarcode('ABC-123'), { kind: 'Other', valid: true });
  assert.deepEqual(describeBarcode('12345'), { kind: 'Other', valid: true });
  assert.equal(makeEan13('590123412345'), '5901234123457');
});

test('UPC-A, EAN-13 and GTIN-14 are the same number', () => {
  assert.deepEqual(lookupForms('036000291452').sort(), ['00036000291452', '0036000291452', '036000291452']);
  assert.deepEqual(lookupForms('0036000291452').sort(), ['00036000291452', '0036000291452', '036000291452']);
  assert.deepEqual(lookupForms('5901234123457').sort(), ['05901234123457', '5901234123457']);
  assert.deepEqual(lookupForms('96385074'), ['96385074']);
  assert.deepEqual(lookupForms('ABC-123'), ['ABC-123']);
});

test('a scan finds the product however the code was written', () => {
  const { db, base, owner, bread } = world();
  const ctx = { ...base, user_id: owner };
  addBarcode(db, ctx, bread, '036000291452', {}, uid);
  for (const raw of ['036000291452', '0036000291452', ' 036000291452\n']) {
    const r = resolveScan(db, raw);
    assert.equal(r.status, 'found');
    if (r.status === 'found') assert.deepEqual([r.product_id, r.qty_milli, r.weighed], [bread, null, false]);
  }
  assert.deepEqual(resolveScan(db, '   '), { status: 'empty' });
  assert.deepEqual(resolveScan(db, '5901234123457'), { status: 'unknown', code: '5901234123457', kind: 'EAN-13', valid: true });
  assert.equal((resolveScan(db, '5901234123458') as any).valid, false);
});

test('an exact match wins over an equivalent form', () => {
  const { db, base, owner, bread, milk } = world();
  const ctx = { ...base, user_id: owner };
  addBarcode(db, ctx, bread, '036000291452', {}, uid);
  // bypass the guard to simulate two codes that arrived from another phone
  db.prepare("insert into product_barcodes (id, shop_id, created_at, device_id, updated_at, version, product_id, barcode) values ('x1','shop-0001',1,'d',1,1,?,?)").run(milk, '0036000291452');
  assert.equal((resolveScan(db, '0036000291452') as any).product_id, milk);
  assert.equal((resolveScan(db, '036000291452') as any).product_id, bread);
});

test('adding: checks, one owner, repeat is harmless, permission', () => {
  const { db, base, owner, cashier, bread, milk, q } = world();
  const ctx = { ...base, user_id: owner };
  const a = addBarcode(db, ctx, bread, '5901234123457', {}, uid);
  assert.equal(a.created, true);
  assert.deepEqual(addBarcode(db, ctx, bread, '5901234123457', {}, uid), { id: a.id, created: false });
  assert.deepEqual(addBarcode(db, ctx, bread, '05901234123457', {}, uid), { id: a.id, created: false }); // same number
  assert.throws(() => addBarcode(db, ctx, milk, '5901234123457', {}, uid), /already belongs to Bread/);
  assert.throws(() => addBarcode(db, ctx, milk, '5901234123458', {}, uid), /last digit/);
  assert.equal(addBarcode(db, ctx, milk, '5901234123458', { allow_invalid: true }, uid).created, true);
  assert.throws(() => addBarcode(db, ctx, milk, 'ab', {}, uid), /3 to 48/);
  assert.throws(() => addBarcode(db, ctx, milk, 'has space1'.replace('', ' ').slice(0, 2), {}, uid), /3 to 48/);
  assert.throws(() => addBarcode(db, ctx, 'nope', 'ABC-1', {}, uid), /not found/);
  assert.throws(() => addBarcode(db, { ...base, user_id: cashier }, milk, 'ABC-1', {}, uid), /not allowed/);
  assert.deepEqual(listBarcodes(db, milk).map((b) => b.barcode), ['5901234123458']);
  assert.equal(q("select count(*) as c from audit_log where action = 'barcode_add'")[0].c, 2);
});

test('removing frees the code for another product', () => {
  const { db, base, owner, bread, milk, q } = world();
  const ctx = { ...base, user_id: owner };
  const a = addBarcode(db, ctx, bread, 'ABC-123', {}, uid);
  removeBarcode(db, { ...ctx, now: T + 1000 }, a.id, uid);
  assert.equal(resolveScan(db, 'ABC-123').status, 'unknown');
  assert.equal(listBarcodes(db, bread).length, 0);
  assert.equal(addBarcode(db, ctx, milk, 'ABC-123', {}, uid).created, true);
  assert.throws(() => removeBarcode(db, ctx, a.id, uid), /not found/);
  const row = q('select version, deleted_at from product_barcodes where id = ?', a.id)[0];
  assert.deepEqual([row.version, row.deleted_at], [2, T + 1000]);
  assert.equal(q("select count(*) as c from audit_log where action = 'barcode_remove'")[0].c, 1);
});

test('a scan of an inactive product is reported, not sold', () => {
  const { db, base, owner, bread } = world();
  addBarcode(db, { ...base, user_id: owner }, bread, 'ABC-123', {}, uid);
  saveProduct(db, base, { id: bread, name: 'Bread', is_active: false }, uid);
  assert.deepEqual(resolveScan(db, 'ABC-123'), { status: 'inactive', code: 'ABC-123', product_id: bread, product_name: 'Bread' });
});

test('scale labels give the weight', () => {
  const { db, base, owner, beef, bread } = world();
  const ctx = { ...base, user_id: owner };
  const label = (item: string, grams: number) => makeEan13(`21${item}${String(grams).padStart(5, '0')}`);
  addBarcode(db, ctx, beef, '2100123', {}, uid);
  addBarcode(db, ctx, bread, '2100456', {}, uid);
  assert.equal(resolveScan(db, label('00123', 1250)).status, 'unknown'); // scale not switched on
  saveSettings(db, ctx, { scale_prefix: '21' }, uid);
  const r = resolveScan(db, label('00123', 1250));
  assert.deepEqual(r.status === 'found' && [r.product_id, r.qty_milli, r.weighed], [beef, 1250, true]); // 1.250 kg
  assert.match((resolveScan(db, label('00123', 0)) as any).message, /no weight/);
  assert.match((resolveScan(db, label('00456', 500)) as any).message, /not sold by weight/);
  assert.equal(resolveScan(db, label('00999', 500)).status, 'unknown');
  assert.equal(resolveScan(db, '2100123012508').status, 'unknown'); // wrong check digit
});

test('the scale prefix must be two digits or empty', () => {
  const { db, base, owner } = world();
  const ctx = { ...base, user_id: owner };
  assert.throws(() => saveSettings(db, ctx, { scale_prefix: '2' }, uid), /exactly 2 digits/);
  assert.throws(() => saveSettings(db, ctx, { scale_prefix: 'ab' }, uid), /exactly 2 digits/);
  assert.deepEqual(saveSettings(db, ctx, { scale_prefix: '21' }, uid), ['scale_prefix']);
  assert.deepEqual(saveSettings(db, ctx, { scale_prefix: '' }, uid), ['scale_prefix']);
});

test('shop codes are valid EAN-13, unused, and avoid the scale prefix', () => {
  const { db, base, owner, bread } = world();
  const ctx = { ...base, user_id: owner };
  let i = 0;
  const pick = (m: number) => (i++ * 7) % m;
  const a = newShopCode(db, pick);
  assert.match(a, /^20\d{11}$/);
  assert.equal(describeBarcode(a).valid, true);
  saveSettings(db, ctx, { scale_prefix: '20' }, uid);
  assert.match(newShopCode(db, pick), /^22\d{11}$/);
  // a code that is already used is skipped: the first try repeats the taken code, the next differs
  saveSettings(db, ctx, { scale_prefix: '' }, uid);
  const taken = newShopCode(db, () => 3);
  addBarcode(db, ctx, bread, taken, {}, uid);
  let calls = 0;
  const next = newShopCode(db, () => (calls++ < 10 ? 3 : 4));
  assert.notEqual(next, taken);
  assert.equal(calls > 10, true);
  const given = giveShopCode(db, ctx, bread, uid);
  assert.equal(listBarcodes(db, bread).some((b) => b.barcode === given), true);
});

test('shelf labels: layout, preview and printer bytes', () => {
  const { db, base, owner, bread } = world();
  addBarcode(db, { ...base, user_id: owner }, bread, '5901234123457', {}, uid);
  const lab = loadLabel(db, bread, T);
  assert.deepEqual(lab, { name: 'Bread', price_text: '$1.50', code: '5901234123457' });
  const items = layoutLabel(lab, { width: 32, copies: 2 });
  assert.equal(items.filter((i) => i.t === 'barcode').length, 2);
  assert.equal(items.filter((i) => i.t === 'cut').length, 2);
  assert.match(toText(items, 32), /Bread[\s\S]*\$1\.50[\s\S]*\|\|\|\| 5901234123457 \|\|\|\|/);
  const bytes = Array.from(toEscPos(items, 32));
  const at = bytes.findIndex((_, k) => bytes[k] === 0x1d && bytes[k + 1] === 0x6b && bytes[k + 2] === 2);
  assert.ok(at > 0);
  assert.equal(String.fromCharCode(...bytes.slice(at + 3, at + 15)), '590123412345'); // 12 digits, the printer adds the check
  assert.equal(bytes[at + 15], 0);
  // Code 128 for other codes, and long codes fall back to plain text
  const c128 = Array.from(toEscPos(layoutLabel({ name: 'X', price_text: null, code: 'ABC-123' }, { width: 32 }), 32));
  const k = c128.findIndex((_, j) => c128[j] === 0x1d && c128[j + 1] === 0x6b && c128[j + 2] === 73);
  assert.deepEqual([c128[k + 3], c128[k + 4], c128[k + 5]], [9, 0x7b, 0x42]);
  const long = layoutLabel({ name: 'X', price_text: null, code: 'A'.repeat(30) }, { width: 32 });
  assert.equal(long.some((i) => i.t === 'barcode'), false);
  assert.throws(() => loadLabel(db, 'nope', T), /not found/);
});

test('a label needs a barcode', () => {
  const { db, milk } = world();
  assert.throws(() => loadLabel(db, milk, T), /no barcode/);
});
