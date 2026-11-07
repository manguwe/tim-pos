/**
 * Receipts. Reference implementation; app/lib/printing/receipt.dart is a port, checked against shared vectors.
 *
 * The pipeline has three steps so each can be tested alone:
 *   1. loadReceipt(db, saleId)       reads a saved sale into plain data (ReceiptData)
 *   2. layoutReceipt(data, options)  turns the data into a list of styled lines for a paper width
 *   3. toText(lines) / toEscPos(lines)   the on-screen preview, or the bytes a thermal printer understands
 *
 * Printers: 58 mm paper holds 32 characters per line, 80 mm holds 48 (the usual size 'A' font). Text is plain ASCII;
 * accented letters are reduced to their base letter, and anything else becomes '?', so every printer prints something readable.
 */
import { DatabaseSync } from 'node:sqlite';
import { lineAmount } from './money.ts';

export interface Money { code: string; symbol: string; minor_units: number }
export interface ReceiptLine { description: string; qty_milli: number; unit_price_minor: number; discount_minor: number; tax_rate_bp: number; line_total_minor: number }
export interface ReceiptPayment { method_name: string; currency: string; amount_minor: number; rate_to_sale_micro: number; reference: string | null; is_change: boolean }
export interface ReceiptData {
  shop_name: string; branch_name: string | null; branch_address: string | null; branch_phone: string | null; tax_number: string | null;
  receipt_no: string; kind: 'sale' | 'copy'; completed_at: number; cashier: string | null; customer: string | null; status: string;
  sale_currency: string; subtotal_minor: number; discount_minor: number; tax_minor: number; total_minor: number;
  lines: ReceiptLine[]; payments: ReceiptPayment[]; credit_minor: number;
  currencies: Record<string, Money>;
  header: string | null; footer: string | null;
}
export interface LayoutOptions { width: number; utc_offset_minutes: number; open_drawer?: boolean; cut?: boolean }

export type Align = 'left' | 'center' | 'right';
export type Item =
  | { t: 'text'; text: string; align: Align; bold: boolean; big: boolean }
  | { t: 'rule' }
  | { t: 'feed'; n: number }
  | { t: 'drawer' }
  | { t: 'barcode'; code: string }
  | { t: 'cut' };

export const WIDTH_58 = 32;
export const WIDTH_80 = 48;

// ---- text helpers ----

// An explicit list (the Dart port has the same one) so both give identical output on every phone.
const ACCENT_FROM = 'ÀÁÂÃÄÅàáâãäåÇçÈÉÊËèéêëÌÍÎÏìíîïÑñÒÓÔÕÖØòóôõöøÙÚÛÜùúûüÝýÿŠšŽžČčĆćĐđĚěŘřŇňŤťŮůŁłŃńŚśŹźŻżĄąĘęŐőŰű';
const ACCENT_TO = 'AAAAAAaaaaaaCcEEEEeeeeIIIIiiiiNnOOOOOOooooooUUUUuuuuYyySsZzCcCcDdEeRrNnTtUuLlNnSsZzZzAaEeOoUu';

export function ascii(s: string): string {
  let out = '';
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i); const ch = s[i]!;
    const k = c > 0x7e ? ACCENT_FROM.indexOf(ch) : -1;
    if (k >= 0) out += ACCENT_TO[k];
    else if (c === 0x2018 || c === 0x2019) out += "'";
    else if (c === 0x201c || c === 0x201d) out += '"';
    else if (c === 0x2013 || c === 0x2014) out += '-';
    else if (c >= 0x20 && c <= 0x7e) out += ch;
    else out += '?';
  }
  return out;
}

export function wrap(text: string, width: number): string[] {
  const out: string[] = [];
  for (const para of text.split('\n').map(ascii)) {
    let line = '';
    for (const word of para.split(/\s+/).filter(Boolean)) {
      let w = word;
      while (w.length > width) { // a word longer than the paper is cut
        if (line) { out.push(line); line = ''; }
        out.push(w.slice(0, width)); w = w.slice(width);
      }
      if (!line) line = w;
      else if (line.length + 1 + w.length <= width) line += ' ' + w;
      else { out.push(line); line = w; }
    }
    out.push(line);
  }
  return out;
}

/** Left text and right text on one row; the left wraps when it does not fit and the right sits on its last line. */
export function row(left: string, right: string, width: number): string[] {
  const r = ascii(right);
  const room = width - r.length - 1;
  if (room < 4) return [...wrap(left, width), r.padStart(width)];
  const l = wrap(left, room);
  const last = l.pop() ?? '';
  return [...l, last.padEnd(width - r.length) + r];
}

export function formatMoney(minor: number, m: Money): string {
  const neg = minor < 0; const a = Math.abs(minor);
  const p = 10 ** m.minor_units;
  const whole = String(Math.floor(a / p)).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
  const frac = m.minor_units === 0 ? '' : '.' + String(a % p).padStart(m.minor_units, '0');
  const sym = m.symbol.length > 1 ? m.symbol + ' ' : m.symbol;
  return `${neg ? '-' : ''}${sym}${whole}${frac}`;
}

const qtyText = (milli: number) => (milli % 1000 === 0 ? String(milli / 1000) : (milli / 1000).toFixed(3).replace(/0+$/, ''));
const rateText = (bp: number) => (bp % 100 === 0 ? String(bp / 100) : (bp / 100).toFixed(2).replace(/0$/, '')) + '%';

export function dateText(ms: number, offsetMin: number): string {
  const d = new Date(ms + offsetMin * 60_000);
  const p = (n: number) => String(n).padStart(2, '0');
  return `${d.getUTCFullYear()}-${p(d.getUTCMonth() + 1)}-${p(d.getUTCDate())} ${p(d.getUTCHours())}:${p(d.getUTCMinutes())}`;
}

// ---- layout ----

export function layoutReceipt(d: ReceiptData, o: LayoutOptions): Item[] {
  const W = o.width;
  const items: Item[] = [];
  const text = (s: string, a: Align = 'left', bold = false, big = false) => {
    // double-size text is twice as wide, so it wraps at half the width
    for (const l of wrap(s, big ? Math.floor(W / 2) : W)) items.push({ t: 'text', text: l, align: a, bold, big });
  };
  const rows = (l: string, r: string, bold = false) => { for (const s of row(l, r, W)) items.push({ t: 'text', text: s, align: 'left', bold, big: false }); };
  const rule = () => items.push({ t: 'rule' });
  const cur = (code: string): Money => d.currencies[code] ?? { code, symbol: code, minor_units: 2 };
  const money = (minor: number, code = d.sale_currency) => formatMoney(minor, cur(code));

  if (o.open_drawer) items.push({ t: 'drawer' });
  text(d.shop_name, 'center', true, true);
  if (d.branch_name) text(d.branch_name, 'center');
  if (d.branch_address) text(d.branch_address, 'center');
  if (d.branch_phone) text('Tel ' + d.branch_phone, 'center');
  if (d.tax_number) text('VAT/BP No: ' + d.tax_number, 'center');
  if (d.header) text(d.header, 'center');
  rule();
  rows('Receipt', d.receipt_no, true);
  rows('Date', dateText(d.completed_at, o.utc_offset_minutes));
  if (d.cashier) rows('Cashier', d.cashier);
  if (d.customer) rows('Customer', d.customer);
  if (d.kind === 'copy') text('*** COPY ***', 'center', true);
  if (d.status === 'voided') text('*** VOIDED ***', 'center', true);
  rule();

  for (const l of d.lines) {
    text(l.description);
    const detail = `${qtyText(l.qty_milli)} x ${money(l.unit_price_minor)}`;
    rows('  ' + detail, money(lineAmount(l.qty_milli, l.unit_price_minor)));
    if (l.discount_minor > 0) rows('  Discount', '-' + money(l.discount_minor));
  }
  rule();

  if (d.tax_minor > 0) {
    rows('Subtotal (excl. tax)', money(d.subtotal_minor));
    const rates = new Set(d.lines.filter((l) => l.tax_rate_bp > 0).map((l) => l.tax_rate_bp));
    rows(rates.size === 1 ? `Tax ${rateText([...rates][0]!)}` : 'Tax', money(d.tax_minor));
  }
  if (d.discount_minor > 0) rows('Discounts given', money(d.discount_minor));
  // the total, big
  const totalLine = row('TOTAL', money(d.total_minor), Math.floor(W / 2));
  for (const s of totalLine) items.push({ t: 'text', text: s, align: 'left', bold: true, big: true });

  const paid = d.payments.filter((p) => !p.is_change);
  const change = d.payments.filter((p) => p.is_change);
  if (paid.length > 0) {
    rule();
    for (const p of paid) {
      const same = p.currency === d.sale_currency;
      rows(p.method_name + (same ? '' : ' ' + p.currency), money(p.amount_minor, p.currency));
      if (!same) {
        const rate = formatRate(p.rate_to_sale_micro, d.sale_currency, p.currency);
        text('  ' + rate);
      }
      if (p.reference) text('  Ref ' + p.reference);
    }
    for (const c of change) rows('Change', money(c.amount_minor, c.currency), true);
  }
  if (d.credit_minor > 0) { rule(); rows('On account', money(d.credit_minor), true); }

  if (d.footer) { rule(); text(d.footer, 'center'); }
  text('Thank you', 'center');
  items.push({ t: 'feed', n: 3 });
  if (o.cut !== false) items.push({ t: 'cut' });
  return items;
}

/** "1 USD = 26.50 ZiG" from the stored rate (millionths of the sale currency per one unit of the paid currency). */
function formatRate(rateToSaleMicro: number, saleCur: string, paidCur: string): string {
  if (rateToSaleMicro <= 0) return '';
  const cents = Math.round(1_000_000_000_000 / rateToSaleMicro / 10_000); // hundredths of paidCur per 1 saleCur
  const whole = Math.floor(cents / 100);
  const frac = String(cents % 100).padStart(2, '0');
  return `1 ${saleCur} = ${whole}.${frac} ${paidCur}`;
}

// ---- renderers ----

export function toText(items: Item[], width: number): string {
  const out: string[] = [];
  for (const it of items) {
    if (it.t === 'rule') out.push('-'.repeat(width));
    else if (it.t === 'feed') for (let i = 0; i < it.n; i++) out.push('');
    else if (it.t === 'barcode') out.push(' '.repeat(Math.max(0, Math.floor((width - it.code.length - 10) / 2))) + `|||| ${it.code} ||||`);
    else if (it.t === 'text') {
      const w = it.big ? Math.floor(width / 2) : width;
      const pad = it.align === 'center' ? Math.floor((w - it.text.length) / 2) : it.align === 'right' ? w - it.text.length : 0;
      out.push(' '.repeat(Math.max(0, pad)) + it.text);
    }
  }
  return out.join('\n') + '\n';
}

const ESC = 0x1b, GS = 0x1d, LF = 0x0a;
/** Raw ESC/POS bytes for a thermal printer. */
export function toEscPos(items: Item[], width: number): Uint8Array {
  const b: number[] = [ESC, 0x40, ESC, 0x74, 0x00]; // initialise, code page 437
  const bytes = (s: string) => { for (const ch of s) b.push(ch.charCodeAt(0)); };
  let align: Align = 'left', bold = false, big = false;
  const A = { left: 0, center: 1, right: 2 };
  for (const it of items) {
    if (it.t === 'text') {
      if (it.align !== align) { b.push(ESC, 0x61, A[it.align]); align = it.align; }
      if (it.bold !== bold) { b.push(ESC, 0x45, it.bold ? 1 : 0); bold = it.bold; }
      if (it.big !== big) { b.push(GS, 0x21, it.big ? 0x11 : 0x00); big = it.big; }
      bytes(it.text); b.push(LF);
    } else if (it.t === 'rule') {
      if (align !== 'left') { b.push(ESC, 0x61, 0); align = 'left'; }
      if (big) { b.push(GS, 0x21, 0x00); big = false; }
      bytes('-'.repeat(width)); b.push(LF);
    } else if (it.t === 'feed') for (let i = 0; i < it.n; i++) b.push(LF);
    else if (it.t === 'drawer') b.push(ESC, 0x70, 0x00, 0x19, 0xfa); // pulse pin 2, 50 ms on, 500 ms off
    else if (it.t === 'barcode') {
      if (align !== 'center') { b.push(ESC, 0x61, 1); align = 'center'; }
      b.push(GS, 0x68, 80, GS, 0x48, 2);                            // 80 dots high, number printed under the bars
      const c = it.code;
      if (/^\d{13}$/.test(c)) { b.push(GS, 0x77, 2, GS, 0x6b, 2); bytes(c.slice(0, 12)); b.push(0); }
      else if (/^\d{8}$/.test(c)) { b.push(GS, 0x77, 2, GS, 0x6b, 3); bytes(c.slice(0, 7)); b.push(0); }
      else { const dots = width >= 48 ? 576 : 384; b.push(GS, 0x77, (11 * (c.length + 3) + 13) * 2 <= dots ? 2 : 1, GS, 0x6b, 73, c.length + 2, 0x7b, 0x42); bytes(c); }
      b.push(LF);
    }
    else if (it.t === 'cut') b.push(GS, 0x56, 0x42, 0x03);          // feed 3 dots then partial cut
  }
  b.push(ESC, 0x61, 0, ESC, 0x45, 0, GS, 0x21, 0x00);              // leave the printer in its normal state
  return Uint8Array.from(b);
}

// ---- reading a saved sale ----

type Row = Record<string, any>;
export function loadReceipt(db: DatabaseSync, saleId: string, o: { kind?: 'sale' | 'copy' } = {}): ReceiptData {
  const get = (sql: string, ...a: any[]): Row | undefined => { const r = db.prepare(sql).get(...a); return r ? { ...r } : undefined; };
  const all = (sql: string, ...a: any[]): Row[] => db.prepare(sql).all(...a).map((r) => ({ ...r }));
  const s = get('select * from sales where id = ?', saleId);
  if (!s) throw new Error('sale not found');
  const shop = get('select * from shops where deleted_at is null limit 1') ?? {};
  const branch = get('select * from branches where id = ?', s.branch_id);
  const setting = (k: string) => (get("select value from settings where scope = 'shop' and key = ? and deleted_at is null", k)?.value as string | undefined) ?? null;
  const methods = Object.fromEntries(all('select code, name from payment_methods').map((m) => [m.code, m.name]));
  const currencies: Record<string, Money> = {};
  for (const c of all('select code, symbol, minor_units from currencies')) currencies[c.code] = { code: c.code, symbol: c.symbol ?? c.code, minor_units: c.minor_units };
  const payments = all('select * from sale_payments where sale_id = ? order by is_change, created_at, rowid', saleId);
  const owed = (get("select coalesce(sum(amount_minor), 0) as c from customer_ledger where ref_type = 'sale' and ref_id = ? and type = 'credit_sale'", saleId)?.c as number) ?? 0;
  return {
    shop_name: shop.name ?? '', branch_name: branch?.name ?? null, branch_address: branch?.address ?? null, branch_phone: branch?.phone ?? null,
    tax_number: shop.tax_registered === 1 ? shop.tax_number ?? null : null,
    receipt_no: s.receipt_no, kind: o.kind ?? 'sale', completed_at: s.completed_at,
    cashier: s.user_id ? (get('select name from users where id = ?', s.user_id)?.name ?? null) : null,
    customer: s.customer_id ? (get('select name from customers where id = ?', s.customer_id)?.name ?? null) : null,
    status: get('select 1 as x from sale_voids where sale_id = ?', saleId) ? 'voided' : s.status, sale_currency: s.sale_currency, subtotal_minor: s.subtotal_minor, discount_minor: s.discount_minor, tax_minor: s.tax_minor, total_minor: s.total_minor,
    lines: all('select * from sale_lines where sale_id = ? order by created_at, rowid', saleId).map((l) => ({
      description: l.description ?? '', qty_milli: l.qty_milli, unit_price_minor: l.unit_price_minor, discount_minor: l.discount_minor ?? 0, tax_rate_bp: l.tax_rate_bp ?? 0, line_total_minor: l.line_total_minor,
    })),
    payments: payments.map((p) => ({ method_name: methods[p.method_code] ?? p.method_code, currency: p.currency, amount_minor: p.amount_minor, rate_to_sale_micro: p.rate_to_sale_micro ?? 1_000_000, reference: p.reference ?? null, is_change: p.is_change === 1 })),
    credit_minor: owed, currencies, header: setting('receipt_header'), footer: setting('receipt_footer'),
  };
}
