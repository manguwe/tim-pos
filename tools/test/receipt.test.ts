import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { ascii, wrap, row, formatMoney, layoutReceipt, toText, toEscPos, loadReceipt, WIDTH_58, WIDTH_80, type ReceiptData } from '../src/receipt.ts';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { createUser } from '../src/auth.ts';
import { sell } from '../src/selling.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `gen-${String(++n).padStart(8, '0')}`;
const T = Date.UTC(2026, 9, 31, 12, 5); // 31 Oct 2026 12:05 UTC
const ctx: SetupContext = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T };

test('text is reduced to plain ASCII and wrapped at the paper width', () => {
  assert.equal(ascii('Café “Mbare” – naïve ZiG €5'), 'Cafe "Mbare" - naive ZiG ?5');
  assert.deepEqual(wrap('Brown bread 700g sliced loaf', 16), ['Brown bread 700g', 'sliced loaf']);
  assert.deepEqual(wrap('Supercalifragilisticexpialidocious', 10), ['Supercalif', 'ragilistic', 'expialidoc', 'ious']);
  assert.deepEqual(wrap('a\nb', 10), ['a', 'b']);
  assert.ok(wrap('x '.repeat(200), 32).every((l) => l.length <= 32));
});

test('a row puts the amount at the right edge, wrapping a long name above it', () => {
  assert.deepEqual(row('Bread', '$1.50', 32), ['Bread                      $1.50']);
  const long = row('Extra long product name that cannot fit on one line', '$12.00', 32);
  assert.ok(long.every((l) => l.length <= 32));
  assert.ok(long.at(-1)!.endsWith('$12.00'));
  assert.deepEqual(row('A very long name', '$1,234,567.89', 20).at(-1)!.length, 20);
});

test('money is shown in whole units with the currency symbol', () => {
  const usd = { code: 'USD', symbol: '$', minor_units: 2 };
  assert.deepEqual([formatMoney(150, usd), formatMoney(5, usd), formatMoney(123456789, usd), formatMoney(-250, usd)], ['$1.50', '$0.05', '$1,234,567.89', '-$2.50']);
  assert.equal(formatMoney(3975, { code: 'ZiG', symbol: 'ZiG', minor_units: 2 }), 'ZiG 39.75');
  assert.equal(formatMoney(500, { code: 'JPY', symbol: 'Y', minor_units: 0 }), 'Y500');
});

function sample(over: Partial<ReceiptData> = {}): ReceiptData {
  return {
    shop_name: 'Mbare Mini Market', branch_name: 'Main branch', branch_address: '12 Market St, Harare', branch_phone: '0772 000 000', tax_number: '1234567',
    receipt_no: 'D1-000042', kind: 'sale', completed_at: T, cashier: 'Rudo', customer: null, status: 'completed', sale_currency: 'USD',
    subtotal_minor: 310, discount_minor: 10, tax_minor: 47, total_minor: 357,
    lines: [
      { description: 'Brown bread 700g', qty_milli: 1_500, unit_price_minor: 100, discount_minor: 0, tax_rate_bp: 1500, line_total_minor: 150 },
      { description: 'Cooking oil 2L', qty_milli: 1_000, unit_price_minor: 220, discount_minor: 10, tax_rate_bp: 1500, line_total_minor: 210 },
    ],
    payments: [
      { method_name: 'Cash', currency: 'USD', amount_minor: 200, rate_to_sale_micro: 1_000_000, reference: null, is_change: false },
      { method_name: 'Cash', currency: 'ZiG', amount_minor: 4_240, rate_to_sale_micro: 37_736, reference: null, is_change: false },
      { method_name: 'EcoCash', currency: 'USD', amount_minor: 100, rate_to_sale_micro: 1_000_000, reference: 'MP260131.1', is_change: false },
      { method_name: 'Cash', currency: 'USD', amount_minor: 5, rate_to_sale_micro: 1_000_000, reference: null, is_change: true },
    ],
    credit_minor: 0,
    currencies: { USD: { code: 'USD', symbol: '$', minor_units: 2 }, ZiG: { code: 'ZiG', symbol: 'ZiG', minor_units: 2 } },
    header: null, footer: 'Goods may be exchanged within 7 days with this receipt.', ...over,
  };
}

test('a receipt reads well on 58 mm paper and never overflows a line', () => {
  const items = layoutReceipt(sample(), { width: WIDTH_58, utc_offset_minutes: 120 });
  const t = toText(items, WIDTH_58);
  for (const line of t.split('\n')) assert.ok(line.length <= WIDTH_58, `too long: "${line}"`);
  assert.match(t, /Mbare Mini\n\s+Market/);
  assert.match(t, /Receipt\s+D1-000042/);
  assert.match(t, /Date\s+2026-10-31 14:05/, 'shown in the shop\'s local time');
  assert.match(t, /1\.5 x \$1\.00\s+\$1\.50/);
  assert.match(t, /Discount\s+-\$0\.10/);
  assert.match(t, /Tax 15%\s+\$0\.47/);
  assert.match(t, /Cash ZiG\s+ZiG 42\.40/);
  assert.match(t, /1 USD = 26\.50 ZiG/);
  assert.match(t, /Ref MP260131\.1/);
  assert.match(t, /Change\s+\$0\.05/);
  assert.match(t, /Thank you/);
});

test('the same receipt on 80 mm paper uses the wider line', () => {
  const t80 = toText(layoutReceipt(sample(), { width: WIDTH_80, utc_offset_minutes: 0 }), WIDTH_80);
  assert.ok(t80.split('\n').every((l) => l.length <= WIDTH_80));
  assert.ok(t80.split('\n').some((l) => l.length > WIDTH_58));
});

test('copies, voids, credit sales and customers are marked', () => {
  const t = toText(layoutReceipt(sample({ kind: 'copy', status: 'voided', customer: 'Mai Tendai', credit_minor: 500, footer: null }), { width: WIDTH_58, utc_offset_minutes: 0 }), WIDTH_58);
  assert.match(t, /\*\*\* COPY \*\*\*/); assert.match(t, /\*\*\* VOIDED \*\*\*/); assert.match(t, /Customer\s+Mai Tendai/); assert.match(t, /On account\s+\$5\.00/);
  assert.doesNotMatch(t, /exchanged/);
});

test('printer commands: initialise, styles switch on and off, the drawer kicks first, the paper is cut last', () => {
  const items = layoutReceipt(sample(), { width: WIDTH_58, utc_offset_minutes: 0, open_drawer: true });
  const b = toEscPos(items, WIDTH_58);
  const hex = Buffer.from(b).toString('hex');
  assert.ok(hex.startsWith('1b401b7400' + '1b700019fa'), 'initialise, code page 437, then the drawer pulse');
  assert.ok(hex.includes('1d2111'), 'double size for the shop name and total');
  assert.ok(hex.includes('1b6101'), 'centered text');
  assert.ok(hex.includes('1b4501'), 'bold on');
  assert.ok(hex.includes('1d564203'), 'cut');
  assert.ok(hex.endsWith('1b61001b45001d2100'), 'printer left in its normal state');
  assert.ok(b.every((x) => x < 0x80 || [0xfa].includes(x)), 'no stray high bytes in the text');
  const noCut = toEscPos(layoutReceipt(sample(), { width: WIDTH_58, utc_offset_minutes: 0, cut: false }), WIDTH_58);
  assert.ok(!Buffer.from(noCut).toString('hex').includes('1d564203'));
});

test('a receipt loaded from a real saved sale matches what was sold', () => {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = on');
  for (const s of SQL.split(/^-- ##$/m).map((x) => x.trim()).filter((x) => x && !x.startsWith('--'))) db.exec(s);
  const { branch_id, owner_id } = seedShop(db, ctx, { name: 'Mbare Mini Market', country_code: 'ZW', tax_registered: true, tax_number: '1234567', owner: { name: 'Tim', pin: '2580' } }, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  db.prepare("update branches set address = '12 Market St', phone = '0772 000 000', version = version + 1 where id = ?").run(branch_id);
  db.prepare("insert into settings (id, shop_id, created_at, updated_at, version, scope, key, value) values ('set-footer', 'shop-0001', 1, 1, 1, 'shop', 'receipt_footer', 'Thanks for shopping')").run();
  setExchangeRate(db, ctx, 'USD', 'ZiG', 26_500_000, uid);
  const vat = q("select id from tax_classes where name = 'Standard rated'")[0].id;
  const bread = saveProduct(db, ctx, { name: 'Brown bread', price_minor: 150, cost_minor: 90, tax_class_id: vat }, uid);
  receiveStock(db, ctx, { branch_id, product_id: bread, qty_milli: 10_000, unit_cost_minor: 90, opening: true }, uid);
  const cashier = createUser(db, ctx, owner_id!, { name: 'Rudo', role_id: q("select id from roles where name = 'Cashier'")[0].id, pin: '7391' }, uid);
  const sale = sell(db, { shop_id: ctx.shop_id, device_id: ctx.device_id, receipt_prefix: 'D1', now: T + 1000 },
    { branch_id, user_id: cashier, sale_currency: 'USD', lines: [{ product_id: bread, qty_milli: 2_000 }], payments: [{ method_code: 'cash', currency: 'ZiG', amount_minor: 10_000 }], change_currency: 'USD' }, uid);

  const r = loadReceipt(db, sale.sale_id);
  assert.equal(r.shop_name, 'Mbare Mini Market'); assert.equal(r.tax_number, '1234567'); assert.equal(r.cashier, 'Rudo');
  assert.equal(r.branch_address, '12 Market St'); assert.equal(r.footer, 'Thanks for shopping');
  assert.equal(r.total_minor, 300);
  assert.deepEqual(r.payments.map((p) => [p.method_name, p.currency, p.amount_minor, p.is_change]), [['Cash', 'ZiG', 10_000, false], ['Cash', 'USD', 75, true]]);
  const t = toText(layoutReceipt(r, { width: WIDTH_58, utc_offset_minutes: 120 }), WIDTH_58);
  assert.match(t, /Receipt\s+D1-000001/); assert.match(t, /Cashier\s+Rudo/); assert.match(t, /Tax 15%\s+\$0\.39/);
  assert.match(t, /TOTAL/); assert.match(t, /Change\s+\$0\.75/); assert.match(t, /Thanks for shopping/);
  const copy = loadReceipt(db, sale.sale_id, { kind: 'copy' });
  assert.match(toText(layoutReceipt(copy, { width: WIDTH_58, utc_offset_minutes: 0 }), WIDTH_58), /COPY/);
});
