/** Test vectors for the Dart receipt code, made by the TypeScript reference.  ->  app/test/fixtures/receipt_vectors.json */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { ascii, wrap, row, formatMoney, layoutReceipt, toText, toEscPos, type ReceiptData } from './src/receipt.ts';

const T = Date.UTC(2026, 9, 31, 12, 5);
const cur = { USD: { code: 'USD', symbol: '$', minor_units: 2 }, ZiG: { code: 'ZiG', symbol: 'ZiG', minor_units: 2 }, JPY: { code: 'JPY', symbol: 'Y', minor_units: 0 } };
const base: ReceiptData = {
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
  credit_minor: 0, currencies: cur, header: null, footer: 'Goods may be exchanged within 7 days with this receipt.',
};
const cases: Record<string, ReceiptData> = {
  basic: base,
  copy_credit: { ...base, kind: 'copy', customer: 'Mai Tendai', header: 'Wholesale and retail', credit_minor: 500, payments: base.payments.slice(0, 1), tax_number: null },
  voided_no_tax: { ...base, status: 'voided', tax_minor: 0, discount_minor: 0, footer: null, cashier: null, lines: [
    { description: 'Café “Mbare” blend – extra long product name that has to wrap over several lines', qty_milli: 250, unit_price_minor: 12_345, discount_minor: 0, tax_rate_bp: 0, line_total_minor: 3086 },
    { description: 'Loose rice', qty_milli: 2_750, unit_price_minor: 199, discount_minor: 0, tax_rate_bp: 0, line_total_minor: 547 },
  ], total_minor: 3633, subtotal_minor: 3633 },
  mixed_rates: { ...base, tax_minor: 60, lines: [
    { description: 'Bread', qty_milli: 1000, unit_price_minor: 100, discount_minor: 0, tax_rate_bp: 1500, line_total_minor: 100 },
    { description: 'Airtime', qty_milli: 1000, unit_price_minor: 100, discount_minor: 0, tax_rate_bp: 750, line_total_minor: 100 },
  ] },
  big_amount: { ...base, total_minor: 123_456_789, subtotal_minor: 123_456_789, tax_minor: 0, discount_minor: 0, payments: [
    { method_name: 'Bank transfer', currency: 'USD', amount_minor: 123_456_789, rate_to_sale_micro: 1_000_000, reference: 'REF 98765432101234567890', is_change: false }] },
};
const out = {
  ascii: ['Café “Mbare” – naïve ZiG €5', 'plain', '', 'tab\there'].map((s) => ({ s, r: ascii(s) })),
  wrap: [['Brown bread 700g sliced loaf', 16], ['Supercalifragilisticexpialidocious', 10], ['a\nb', 10], ['  spaced   out  words ', 8], ['', 5]].map(([s, w]) => ({ s, w, r: wrap(s as string, w as number) })),
  row: [['Bread', '$1.50', 32], ['Extra long product name that cannot fit on one line', '$12.00', 32], ['A very long name', '$1,234,567.89', 20]].map(([l, r, w]) => ({ l, r, w, out: row(l as string, r as string, w as number) })),
  money: [[150, 'USD'], [5, 'USD'], [123456789, 'USD'], [-250, 'USD'], [3975, 'ZiG'], [500, 'JPY']].map(([a, c]) => ({ a, c, r: formatMoney(a as number, cur[c as keyof typeof cur]) })),
  layouts: [] as unknown[],
};
for (const [name, data] of Object.entries(cases)) for (const [width, offset, drawer] of [[32, 120, false], [48, 0, true]] as const) {
  const items = layoutReceipt(data, { width, utc_offset_minutes: offset, open_drawer: drawer });
  out.layouts.push({ name, data, width, offset, drawer, text: toText(items, width), escpos: Buffer.from(toEscPos(items, width)).toString('hex') });
}
const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'test', 'fixtures');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'receipt_vectors.json'), JSON.stringify(out) + '\n');
console.log('wrote receipt vectors');
