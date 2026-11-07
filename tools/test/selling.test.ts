import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { sell, SaleError, type Cart, type SaleContext } from '../src/selling.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
const T = 1_800_000_000_000;
const ctx: SaleContext = { shop_id: 'shop-0001', device_id: 'dev-00001', receipt_prefix: 'D1', now: T };

let n = 0;
const uid = () => `gen-${String(++n).padStart(8, '0')}`;

function shop() {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = on');
  for (const s of SQL.split(/^-- ##$/m).map((x) => x.trim()).filter((x) => x && !x.startsWith('--'))) db.exec(s);
  const put = (table: string, row: Record<string, unknown>, versioned = true) => {
    const o = { id: uid(), shop_id: ctx.shop_id, created_at: T - 1000, ...(versioned ? { updated_at: T - 1000, version: 1 } : {}), ...row };
    db.prepare(`insert into "${table}" (${Object.keys(o).map((k) => `"${k}"`)}) values (${Object.keys(o).map(() => '?')})`).run(...Object.values(o) as any[]);
    return o.id as string;
  };
  const ids: Record<string, string> = {} as Record<string, string>;
  ids.shop = put('shops', { name: 'Test Shop', country_code: 'ZW', base_currency: 'USD' });
  put('currencies', { code: 'USD', name: 'US dollar', symbol: '$', minor_units: 2, rounding_increment_minor: 5 });
  put('currencies', { code: 'ZiG', name: 'Zimbabwe Gold', symbol: 'ZiG', minor_units: 2, rounding_increment_minor: 100 });
  put('exchange_rates', { from_currency: 'USD', to_currency: 'ZiG', rate_micro: 26_500_000, effective_from: T - 5000 }, false);
  put('payment_methods', { code: 'cash', name: 'Cash', kind: 'cash', opens_drawer: 1 });
  put('payment_methods', { code: 'ecocash', name: 'EcoCash', kind: 'mobile_money', requires_reference: 1, opens_drawer: 0 });
  ids.vat = put('tax_classes', { name: 'VAT 15%', rate_bp: 1500, is_inclusive: 1 });
  ids.vatx = put('tax_classes', { name: 'VAT 15% added', rate_bp: 1500, is_inclusive: 0 });
  ids.retail = put('price_tiers', { name: 'Retail', is_default: 1 });
  ids.wholesale = put('price_tiers', { name: 'Wholesale', is_default: 0 });
  ids.branch = put('branches', { name: 'Main' });
  ids.pcs = put('units', { name: 'Piece', code: 'pcs', kind: 'count' });
  const product = (name: string, price: number | null, extra: Record<string, unknown> = {}) => {
    const id = put('products', { name, base_unit_id: ids.pcs, tax_class_id: ids.vat, is_active: 1, track_stock: 1, cost_minor: 60, kind: 'simple', ...extra });
    if (price !== null) put('product_prices', { product_id: id, tier_id: ids.retail, currency: 'USD', price_minor: price, effective_from: T - 9000 });
    return id;
  };
  const stock = (productId: string, qty: number, batch: string | null = null) =>
    put('stock_movements', { branch_id: ids.branch, product_id: productId, batch_id: batch, type: 'purchase', qty_milli: qty }, false);
  const cart = (over: Partial<Cart> = {}): Cart => ({ branch_id: ids.branch as string, user_id: null, sale_currency: 'USD', lines: [], payments: [], ...over });
  const count = (table: string, where = '1=1') => (db.prepare(`select count(*) c from "${table}" where ${where}`).get() as any).c as number;
  const level = (productId: string) => (db.prepare('select coalesce(sum(qty_milli),0) q from stock_levels where product_id = ?').get(productId) as any).q as number;
  return { db, put, ids, product, stock, cart, count, level };
}
const cash = (amount: number, currency = 'USD') => ({ method_code: 'cash', currency, amount_minor: amount });

test('a cash sale writes the sale, its line, payment and stock movement together', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 20_000);
  const r = sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 3_000 }], payments: [cash(300)] }));
  assert.equal(r.receipt_no, 'D1-000001');
  assert.equal(r.status, 'completed');
  assert.equal(r.total_minor, 300);
  assert.equal(r.change, null);
  assert.equal(r.opens_drawer, true);
  assert.equal(s.level(bread), 17_000);
  assert.equal(s.count('sales'), 1); assert.equal(s.count('sale_lines'), 1); assert.equal(s.count('sale_payments'), 1);
  assert.equal(s.count('stock_movements', "type = 'sale'"), 1);
  const line = s.db.prepare('select * from sale_lines').get() as any;
  assert.equal(line.description, 'Bread'); assert.equal(line.unit_cost_minor, 60); assert.equal(line.price_currency, 'USD');
  assert.ok(s.count('change_log', "table_name = 'sales'") === 1, 'the sale is queued to sync');
});

test('tax: inclusive prices are split, exclusive tax is added, and totals add up', () => {
  const s = shop();
  const inc = s.product('Bread', 100); s.stock(inc, 10_000);
  const exc = s.product('Fuel', 200, { tax_class_id: s.ids.vatx }); s.stock(exc, 10_000);
  const r = sell(s.db, ctx, s.cart({
    lines: [{ product_id: inc, qty_milli: 1_500 }, { product_id: exc, qty_milli: 1_000, discount_minor: 20 }],
    payments: [cash(1000)],
  }));
  // bread: 150 incl 15% -> net 130, tax 20. fuel: 200-20=180 + 15% = 27 on top -> 207
  assert.equal(r.tax_minor, 20 + 27);
  assert.equal(r.discount_minor, 20);
  assert.equal(r.total_minor, 150 + 207);
  assert.equal(r.subtotal_minor, 130 + 180);
  assert.equal(r.subtotal_minor + r.tax_minor, r.total_minor);
  assert.deepEqual(r.change, { currency: "USD", amount_minor: 640 }); // 643 owed back, rounded down to the 5c coin;
});

test('change in another currency is rounded down to the smallest coin the shop gives', () => {
  const s = shop();
  const bread = s.product('Bread', 150); s.stock(bread, 10_000);
  const r = sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(1000)], change_currency: 'ZiG' }));
  // excess 850 cents = $8.50 = 225.25 ZiG, given as 225.00 ZiG (increment 1.00)
  assert.deepEqual(r.change, { currency: 'ZiG', amount_minor: 22_500 });
  const row = s.db.prepare('select * from sale_payments where is_change = 1').get() as any;
  assert.equal(row.amount_minor, 22_500); assert.equal(row.currency, 'ZiG'); assert.equal(row.method_code, 'cash');
  assert.equal(row.rate_to_sale_micro, 37_736); // 1 ZiG is worth 0.037736 USD
});

test('a sale paid part in USD and part in ZiG records each part with its rate', () => {
  const s = shop();
  const bread = s.product('Bread', 1000); s.stock(bread, 10_000);
  const r = sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(500), cash(13_250, 'ZiG')] }));
  assert.equal(r.change, null);
  const rows = s.db.prepare('select currency, amount_minor, rate_to_sale_micro from sale_payments order by currency').all().map((x) => ({ ...x }));
  assert.deepEqual(rows, [{ currency: 'USD', amount_minor: 500, rate_to_sale_micro: 1_000_000 }, { currency: 'ZiG', amount_minor: 13_250, rate_to_sale_micro: 37_736 }]);
  const used = JSON.parse((s.db.prepare('select rates_used from sales').get() as any).rates_used);
  assert.deepEqual(used, { 'ZiG>USD': 37_736 }, 'the rate is remembered, so a later change never alters this sale');
});

test('mobile money must be exact and carry its reference; only cash can be more than the total', () => {
  const s = shop();
  const bread = s.product('Bread', 1000); s.stock(bread, 10_000);
  const line = [{ product_id: bread, qty_milli: 1_000 }];
  const eco = (amount: number, reference?: string) => ({ method_code: 'ecocash', currency: 'USD', amount_minor: amount, reference });
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [eco(1000)] })), (e: any) => e.code === 'reference_needed');
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [eco(2000, 'MP123')] })), (e: any) => e.code === 'overpaid_non_cash');
  const ok = sell(s.db, ctx, s.cart({ lines: line, payments: [eco(1000, 'MP123')] }));
  assert.equal(ok.opens_drawer, false);
  assert.equal((s.db.prepare('select reference from sale_payments').get() as any).reference, 'MP123');
  // part mobile money, part cash with change
  const mixed = sell(s.db, ctx, s.cart({ lines: line, payments: [eco(400, 'MP124'), cash(1000)] }));
  assert.deepEqual(mixed.change, { currency: 'USD', amount_minor: 400 });
});

test('selling on account: needs a customer and a limit, and respects the limit across sales', () => {
  const s = shop();
  const bread = s.product('Bread', 1000); s.stock(bread, 10_000);
  const line = [{ product_id: bread, qty_milli: 1_000 }];
  const withLimit = s.put('customers', { name: 'Mai Tendai', credit_limit_minor: 2500, credit_currency: 'USD', is_active: 1 });
  const noLimit = s.put('customers', { name: 'Walk-in Regular', is_active: 1 });

  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [] })), (e: any) => e.code === 'underpaid');
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [], on_credit: true })), (e: any) => e.code === 'customer_needed');
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [], on_credit: true, customer_id: noLimit })), (e: any) => e.code === 'no_credit');

  const r = sell(s.db, ctx, s.cart({ lines: line, payments: [cash(400)], on_credit: true, customer_id: withLimit }));
  assert.equal(r.status, 'on_credit'); assert.equal(r.credit_minor, 600);
  assert.equal((s.db.prepare('select amount_minor, type, currency from customer_ledger').get() as any).amount_minor, 600);
  sell(s.db, ctx, s.cart({ lines: line, payments: [], on_credit: true, customer_id: withLimit })); // owes 1600
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: line, payments: [], on_credit: true, customer_id: withLimit })), (e: any) => e.code === 'credit_limit' && e.detail.would_owe_minor === 2600);
  assert.equal(s.count('sales', "status = 'on_credit'"), 2);
});

test('a sale with not enough stock is refused and leaves nothing behind, not even a receipt number', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 2_000);
  const attempt = () => sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 2_500 }], payments: [cash(1000)] }));
  assert.throws(attempt, (e: any) => e instanceof SaleError && e.code === 'insufficient_stock' && e.detail.available_milli === 2_000);
  assert.equal(s.count('sales'), 0); assert.equal(s.count('sale_lines'), 0); assert.equal(s.count('stock_movements', "type = 'sale'"), 0);
  assert.equal(s.level(bread), 2_000);
  assert.equal(s.count('receipt_counters'), 0);
  // the same product twice in one cart counts together
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_500 }, { product_id: bread, qty_milli: 1_500 }], payments: [cash(1000)] })), (e: any) => e.code === 'insufficient_stock');
});

test('selling below zero is allowed only when the product or the shop says so', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 1_000);
  const loose = s.product('Loose sweets', 10, { allow_negative_stock: 1 });
  sell(s.db, ctx, s.cart({ lines: [{ product_id: loose, qty_milli: 5_000 }], payments: [cash(50)] }));
  assert.equal(s.level(loose), -5_000);
  s.put('settings', { scope: 'shop', key: 'allow_negative_stock', value: '1' });
  sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 3_000 }], payments: [cash(300)] }));
  assert.equal(s.level(bread), -2_000);
});

test('products with expiry sell the earliest batch first, across batches', () => {
  const s = shop();
  const milk = s.product('Milk', 200, { track_expiry: 1 });
  const early = s.put('stock_batches', { product_id: milk, branch_id: s.ids.branch, batch_code: 'B1', expiry_date: '2026-12-01' });
  const late = s.put('stock_batches', { product_id: milk, branch_id: s.ids.branch, batch_code: 'B2', expiry_date: '2027-03-01' });
  s.stock(milk, 3_000, late); s.stock(milk, 2_000, early);
  sell(s.db, ctx, s.cart({ lines: [{ product_id: milk, qty_milli: 4_000 }], payments: [cash(800)] }));
  const moved = s.db.prepare("select batch_id, qty_milli from stock_movements where type = 'sale' order by qty_milli").all().map((x) => ({ ...x }));
  assert.deepEqual(moved, [{ batch_id: early, qty_milli: -2_000 }, { batch_id: late, qty_milli: -2_000 }].sort((a, b) => a.qty_milli - b.qty_milli || 0));
  const left = s.db.prepare('select batch_key, qty_milli from stock_levels where product_id = ? order by batch_key').all(milk).map((x) => ({ ...x }));
  assert.deepEqual(left.find((x: any) => x.batch_key === late), { batch_key: late, qty_milli: 1_000 });
  assert.deepEqual(left.find((x: any) => x.batch_key === early), { batch_key: early, qty_milli: 0 });
});

test('a bundle sells as one line and takes its components off the shelf', () => {
  const s = shop();
  const bread = s.product('Bread', 100); const milk = s.product('Milk', 200);
  s.stock(bread, 10_000); s.stock(milk, 10_000);
  const combo = s.product('Breakfast combo', 280, { kind: 'bundle', track_stock: 0 });
  s.put('bundle_items', { bundle_product_id: combo, component_product_id: bread, qty_milli: 2_000 });
  s.put('bundle_items', { bundle_product_id: combo, component_product_id: milk, qty_milli: 1_000 });
  sell(s.db, ctx, s.cart({ lines: [{ product_id: combo, qty_milli: 2_000 }], payments: [cash(560)] }));
  assert.equal(s.count('sale_lines'), 1);
  assert.equal(s.level(bread), 6_000); assert.equal(s.level(milk), 8_000);
});

test('prices: wholesale tier, converted base price in another currency, and a typed price is audited', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 50_000);
  s.put('product_prices', { product_id: bread, tier_id: s.ids.wholesale, currency: 'USD', price_minor: 80, effective_from: T - 9000 });
  // a newer retail price replaces the old one without erasing it
  s.put('product_prices', { product_id: bread, tier_id: s.ids.retail, currency: 'USD', price_minor: 110, effective_from: T - 100 });
  const wsCustomer = s.put('customers', { name: 'Spaza Shop', price_tier_id: s.ids.wholesale, is_active: 1 });

  const retail = sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(110)] }));
  assert.equal(retail.total_minor, 110);
  const ws = sell(s.db, ctx, s.cart({ customer_id: wsCustomer, lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(80)] }));
  assert.equal(ws.total_minor, 80);
  const zig = sell(s.db, ctx, s.cart({ sale_currency: 'ZiG', lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(3000, 'ZiG')] }));
  assert.equal(zig.total_minor, 2915, 'USD 1.10 x 26.5 = ZiG 29.15');
  assert.equal(zig.change, null, '0.85 ZiG of change is below the 1.00 ZiG coin, so none is given');
  const typed = sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000, unit_price_minor: 90 }], payments: [cash(90)] }));
  assert.equal(typed.total_minor, 90);
  const audit = s.db.prepare("select action, user_id from audit_log").all().map((x) => ({ ...x }));
  assert.deepEqual(audit, [{ action: 'price_override', user_id: null }]);
});

test('receipt numbers run on per phone and never clash between phones', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 50_000);
  const one = () => sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(100)] })).receipt_no;
  assert.deepEqual([one(), one(), one()], ['D1-000001', 'D1-000002', 'D1-000003']);
  const other = shop();
  const b2 = other.product('Bread', 100); other.stock(b2, 50_000);
  const r = sell(other.db, { ...ctx, receipt_prefix: 'D2' }, other.cart({ lines: [{ product_id: b2, qty_milli: 1_000 }], payments: [cash(100)] }));
  assert.equal(r.receipt_no, 'D2-000001');
});

test('bad input is refused with a clear code', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 50_000);
  const noPrice = s.product('Mystery', null); s.stock(noPrice, 1_000);
  const code = (cart: Cart) => { try { sell(s.db, ctx, cart); } catch (e) { return (e as SaleError).code; } return 'no error'; };
  const L = (o: object = {}) => [{ product_id: bread, qty_milli: 1_000, ...o }];
  assert.equal(code(s.cart({ lines: [], payments: [cash(1)] })), 'empty_cart');
  assert.equal(code(s.cart({ lines: L({ qty_milli: 0 }), payments: [cash(100)] })), 'bad_quantity');
  assert.equal(code(s.cart({ lines: L({ qty_milli: 1.5 }), payments: [cash(100)] })), 'bad_quantity');
  assert.equal(code(s.cart({ lines: L({ discount_minor: 500 }), payments: [cash(100)] })), 'discount_too_big');
  assert.equal(code(s.cart({ lines: [{ product_id: noPrice, qty_milli: 1_000 }], payments: [cash(100)] })), 'no_price');
  assert.equal(code(s.cart({ lines: [{ product_id: 'nope-nope-nope', qty_milli: 1_000 }], payments: [cash(100)] })), 'unknown_product');
  assert.equal(code(s.cart({ lines: L(), payments: [cash(0)] })), 'bad_payment');
  assert.equal(code(s.cart({ lines: L(), payments: [{ method_code: 'bitcoin', currency: 'USD', amount_minor: 100 }] })), 'unknown_method');
  assert.equal(code(s.cart({ lines: L(), payments: [cash(100, 'XYZ')] })), 'unknown_currency');
  assert.equal(code(s.cart({ sale_currency: 'ZAR', lines: L(), payments: [cash(100)] })), 'unknown_currency');
  assert.equal(code(s.cart({ lines: L(), payments: [cash(100)], shift_id: 'shift-none' })), 'shift_closed');
  assert.equal(code(s.cart({ lines: L({ unit_price_minor: 1e12 }), payments: [cash(100)] })), 'amount_too_large');
  assert.equal(s.count('sales'), 0);
});

test('a missing exchange rate stops a cross-currency sale instead of guessing', () => {
  const s = shop();
  s.put('currencies', { code: 'ZAR', name: 'Rand', symbol: 'R', minor_units: 2, rounding_increment_minor: 10 });
  const bread = s.product('Bread', 100); s.stock(bread, 10_000);
  assert.throws(() => sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(2000, 'ZAR')] })), (e: any) => e.code === 'no_rate');
  assert.equal(s.count('sales'), 0);
});

test('with fiscalisation on, each sale is queued for the tax authority', () => {
  const s = shop();
  const bread = s.product('Bread', 100); s.stock(bread, 10_000);
  sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(100)] }));
  assert.equal(s.count('fiscal_documents'), 0);
  s.put('settings', { scope: 'shop', key: 'fiscal_enabled', value: '1' });
  sell(s.db, ctx, s.cart({ lines: [{ product_id: bread, qty_milli: 1_000 }], payments: [cash(100)] }));
  assert.equal((s.db.prepare('select status from fiscal_documents').get() as any).status, 'queued');
});
