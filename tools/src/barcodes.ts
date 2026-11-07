/**
 * Barcodes: cleaning, check digits, finding a product from a scan, adding and removing codes, making shop codes,
 * and shelf labels. Reference implementation; app/lib/barcodes/barcode_repository.dart is a port.
 *
 * Rules
 *  - A scan is cleaned first (scanners add line ends and spaces). Codes are 3 to 48 printable characters, no spaces.
 *  - UPC-A (12 digits), EAN-13 and GTIN-14 are the same number written with leading zeros, so a scan finds the product
 *    whichever way it was stored. An exact match always wins.
 *  - Shop codes: a code that is the right length for EAN-8/UPC-A/EAN-13/GTIN-14 must have a correct check digit, unless the
 *    user insists (some suppliers print wrong codes). Other lengths are taken as they are.
 *  - One code belongs to one product only.
 *  - Scale labels (shops with a deli or butchery scale): setting `scale_prefix` (two digits, empty = off). A label is 13 digits:
 *    prefix(2) + item(5) + weight in grams(5) + check digit. The product is stored with the 7-digit code prefix+item.
 *    Only weight labels are read (not price labels). The product must be sold in kg or g.
 *  - Our own codes are EAN-13 starting 20, 22, 23 ... (never the scale prefix) with 10 random digits, so phones that are
 *    offline do not make the same code.
 */
import { DatabaseSync } from 'node:sqlite';
import { randomInt, randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { hasPermission } from './auth.ts';
import { getSettings } from './settings.ts';
import { wrap, ascii, formatMoney, type Item, type Money } from './receipt.ts';

type Row = Record<string, any>;

export function cleanBarcode(raw: string): string {
  return String(raw ?? '').replace(/[\s\u0000-\u001f\u007f]/g, '');
}

/** GS1 check digit for the digits in front of it (the right-most digit of body gets weight 3). */
export function checkDigit(body: string): number {
  let sum = 0;
  for (let i = 0; i < body.length; i++) sum += Number(body[body.length - 1 - i]) * (i % 2 === 0 ? 3 : 1);
  return (10 - (sum % 10)) % 10;
}

export type BarcodeKind = 'EAN-13' | 'EAN-8' | 'UPC-A' | 'GTIN-14' | 'Other';
export function describeBarcode(code: string): { kind: BarcodeKind; valid: boolean } {
  const digits = /^\d+$/.test(code);
  const kinds: Record<number, BarcodeKind> = { 8: 'EAN-8', 12: 'UPC-A', 13: 'EAN-13', 14: 'GTIN-14' };
  const kind = digits ? kinds[code.length] : undefined;
  if (!kind) return { kind: 'Other', valid: true };
  return { kind, valid: checkDigit(code.slice(0, -1)) === Number(code[code.length - 1]) };
}

/** The code and the same number written with more or fewer leading zeros. */
export function lookupForms(code: string): string[] {
  if (!/^\d{12,14}$/.test(code)) return [code];
  const g14 = code.padStart(14, '0');
  const out = [code];
  for (const f of [g14, g14.slice(1), g14.slice(2)]) {
    if (f.length === 14 || (f.length === 13 && g14.startsWith('0')) || (f.length === 12 && g14.startsWith('00'))) if (!out.includes(f)) out.push(f);
  }
  return out;
}

export function makeEan13(body12: string): string {
  if (!/^\d{12}$/.test(body12)) throw new SetupError('bad_barcode', 'A code body needs 12 digits.');
  return body12 + checkDigit(body12);
}

const CHARSET = /^[\x21-\x7E]{3,48}$/;

export type Scan =
  | { status: 'empty' }
  | { status: 'unknown'; code: string; kind: BarcodeKind; valid: boolean }
  | { status: 'inactive'; code: string; product_id: string; product_name: string }
  | { status: 'error'; code: string; message: string }
  | { status: 'found'; code: string; product_id: string; product_name: string; barcode_id: string; qty_milli: number | null; weighed: boolean };

function find(db: DatabaseSync, code: string): Row | undefined {
  const forms = lookupForms(code);
  const rows = db.prepare(
    `select b.id as barcode_id, b.barcode, p.id as product_id, p.name, p.is_active, p.base_unit_id from product_barcodes b
     join products p on p.id = b.product_id where b.deleted_at is null and p.deleted_at is null and b.barcode in (${forms.map(() => '?').join(',')})`,
  ).all(...forms) as Row[];
  return rows.find((r) => r.barcode === code) ?? rows[0];
}

/** What a scan means: a product (and a weight, for a scale label), or why not. */
export function resolveScan(db: DatabaseSync, raw: string): Scan {
  const code = cleanBarcode(raw);
  if (!code) return { status: 'empty' };
  const hit = find(db, code);
  if (hit) {
    return hit.is_active === 1
      ? { status: 'found', code, product_id: hit.product_id, product_name: hit.name, barcode_id: hit.barcode_id, qty_milli: null, weighed: false }
      : { status: 'inactive', code, product_id: hit.product_id, product_name: hit.name };
  }
  const prefix = getSettings(db).scale_prefix;
  if (prefix && /^\d{13}$/.test(code) && code.startsWith(prefix) && describeBarcode(code).valid) {
    const item = find(db, code.slice(0, 7));
    if (item) {
      if (item.is_active !== 1) return { status: 'inactive', code, product_id: item.product_id, product_name: item.name };
      const grams = Number(code.slice(7, 12));
      if (grams <= 0) return { status: 'error', code, message: `The label for ${item.name} has no weight.` };
      const unit = (db.prepare('select code from units where id = ?').get(item.base_unit_id) as Row | undefined)?.code;
      const qty = unit === 'kg' ? grams : unit === 'g' ? grams * 1000 : null;
      if (qty === null) return { status: 'error', code, message: `${item.name} is not sold by weight, so the scale label cannot be used.` };
      return { status: 'found', code, product_id: item.product_id, product_name: item.name, barcode_id: item.barcode_id, qty_milli: qty, weighed: true };
    }
  }
  const d = describeBarcode(code);
  return { status: 'unknown', code, kind: d.kind, valid: d.valid };
}

function allow(db: DatabaseSync, ctx: SetupContext) {
  if (ctx.user_id && !hasPermission(db, ctx.user_id, 'product.edit')) throw new SetupError('forbidden', 'You are not allowed to change products.');
}

export function listBarcodes(db: DatabaseSync, productId: string): { id: string; barcode: string; kind: BarcodeKind }[] {
  return (db.prepare('select id, barcode from product_barcodes where product_id = ? and deleted_at is null order by created_at, rowid').all(productId) as Row[])
    .map((r) => ({ id: r.id, barcode: r.barcode, kind: describeBarcode(r.barcode).kind }));
}

/** Adds a code to a product. Adding one the product already has changes nothing. */
export function addBarcode(db: DatabaseSync, ctx: SetupContext, productId: string, raw: string, o: { allow_invalid?: boolean } = {}, newId: () => string = randomUUID): { id: string; created: boolean } {
  allow(db, ctx);
  const code = cleanBarcode(raw);
  if (!CHARSET.test(code)) throw new SetupError('bad_barcode', 'A barcode is 3 to 48 letters or digits, with no spaces.');
  if (!describeBarcode(code).valid && !o.allow_invalid) throw new SetupError('bad_check_digit', 'The last digit of that barcode does not fit the others. Check it, or add it anyway.');
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    const p = w.get('select id from products where id = ? and deleted_at is null', productId);
    if (!p) throw new SetupError('not_found', 'That product was not found.');
    const forms = lookupForms(code);
    const owners = w.all(
      `select b.id, b.product_id, p.name from product_barcodes b join products p on p.id = b.product_id where b.deleted_at is null and b.barcode in (${forms.map(() => '?').join(',')})`, ...forms);
    const other = owners.find((r) => r.product_id !== productId);
    if (other) throw new SetupError('barcode_taken', `That barcode already belongs to ${other.name}.`);
    if (owners.length) return { id: owners[0]!.id as string, created: false };
    const id = w.addVersioned('product_barcodes', { product_id: productId, barcode: code });
    w.add('audit_log', { user_id: ctx.user_id, action: 'barcode_add', table_name: 'product_barcodes', row_id: id, after: code });
    return { id, created: true };
  });
}

export function removeBarcode(db: DatabaseSync, ctx: SetupContext, barcodeId: string, newId: () => string = randomUUID) {
  allow(db, ctx);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const b = w.get('select barcode from product_barcodes where id = ? and deleted_at is null', barcodeId);
    if (!b) throw new SetupError('not_found', 'That barcode was not found.');
    w.edit('product_barcodes', barcodeId, { deleted_at: ctx.now });
    w.add('audit_log', { user_id: ctx.user_id, action: 'barcode_remove', table_name: 'product_barcodes', row_id: barcodeId, before: b.barcode });
  });
}

/** A new shop code (EAN-13, not used yet). `pick(n)` returns a whole number from 0 to n-1. */
export function newShopCode(db: DatabaseSync, pick: (n: number) => number = (n) => randomInt(n)): string {
  const scale = getSettings(db).scale_prefix;
  const prefixes = ['20', '22', '23', '24', '25'].filter((p) => p !== scale);
  for (let i = 0; i < 100; i++) {
    let body: string = prefixes[0]!;
    while (body.length < 12) body += String(pick(10));
    const code = makeEan13(body);
    if (!find(db, code)) return code;
  }
  throw new SetupError('no_code', 'Could not make a new code. Try again.');
}

/** Makes a shop code and gives it to the product. */
export function giveShopCode(db: DatabaseSync, ctx: SetupContext, productId: string, newId: () => string = randomUUID, pick?: (n: number) => number): string {
  const code = newShopCode(db, pick);
  addBarcode(db, ctx, productId, code, {}, newId);
  return code;
}

// ---- shelf labels ----

export interface LabelData { name: string; price_text: string | null; code: string }
export const MAX_LABEL_CODE = 20;

export function layoutLabel(d: LabelData, o: { width: number; copies?: number; cut?: boolean }): Item[] {
  const items: Item[] = [];
  const copies = Math.max(1, Math.min(o.copies ?? 1, 200));
  const code = ascii(d.code);
  for (let i = 0; i < copies; i++) {
    for (const l of wrap(ascii(d.name), o.width).slice(0, 2)) items.push({ t: 'text', text: l, align: 'center', bold: true, big: false });
    if (d.price_text) for (const l of wrap(ascii(d.price_text), Math.floor(o.width / 2)).slice(0, 1)) items.push({ t: 'text', text: l, align: 'center', bold: true, big: true });
    if (code.length <= MAX_LABEL_CODE) items.push({ t: 'barcode', code });
    else items.push({ t: 'text', text: code.slice(0, o.width), align: 'center', bold: false, big: false });
    items.push({ t: 'feed', n: 1 });
    if (o.cut !== false) items.push({ t: 'cut' });
  }
  return items;
}

/** The label for a product: its name, its price in the shop's base currency, and its first code. */
export function loadLabel(db: DatabaseSync, productId: string, now: number, code?: string): LabelData {
  const get = (sql: string, ...a: any[]): Row | undefined => { const r = db.prepare(sql).get(...a); return r ? { ...r } : undefined; };
  const p = get('select name from products where id = ? and deleted_at is null', productId);
  if (!p) throw new SetupError('not_found', 'That product was not found.');
  const c = code ? cleanBarcode(code) : listBarcodes(db, productId)[0]?.barcode;
  if (!c) throw new SetupError('no_barcode', 'This product has no barcode yet.');
  const base = get('select base_currency from shops where deleted_at is null limit 1')?.base_currency as string | undefined;
  let price: string | null = null;
  if (base) {
    const cur = get('select code, symbol, minor_units from currencies where code = ?', base);
    const pr = get('select price_minor from product_prices where product_id = ? and currency = ? and effective_from <= ? and deleted_at is null order by (tier_id is null) , effective_from desc, created_at desc limit 1', productId, base, now);
    if (cur && pr) price = formatMoney(pr.price_minor, { code: cur.code, symbol: cur.symbol ?? cur.code, minor_units: cur.minor_units } as Money);
  }
  return { name: p.name, price_text: price, code: c };
}
