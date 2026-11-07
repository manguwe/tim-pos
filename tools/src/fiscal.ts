/**
 * ZIMRA fiscalisation: everything except the cryptographic signing and the QR code. Reference implementation;
 * app/lib/fiscal/fiscal_repository.dart is a port.
 *
 * WHAT IS HERE
 *  - building ZIMRA receipts (FiscalInvoice and CreditNote) from sales and returns,
 *  - the fiscal day (open, receipt counters, close), the queue of receipts waiting to be sent, retries and failures,
 *  - day counters for closing the day.
 * WHAT IS NOT HERE (on purpose)
 *  - the signature string and hash (section 13 of ZIMRA's Fiscal Device Gateway API) and the QR code (section 11). They sit behind the `Signer`
 *    interface. Until a real signer written from the official text is plugged in, `UnavailableSigner` is used: receipts stay queued and nothing is lost.
 *  - the HTTPS/mutual-TLS client. It sits behind the `Gateway` interface.
 *
 * ASSUMPTIONS TO CHECK AGAINST ZIMRA'S TEST ENVIRONMENT (each is marked A1, A2... below, and must be confirmed before real use)
 *  A1  Amounts are sent as decimal numbers with two decimals; quantities as decimals; dates as local "YYYY-MM-DDTHH:mm:ss" without a zone.
 *  A2  A line discount is sent as a second line of type Discount (1) with a negative total, after the Sale line.
 *  A3  A credit note has negative line totals, negative tax amounts, negative payments and a negative receiptTotal.
 *  A4  A receipt the gateway rejects does not use up its receiptCounter / receiptGlobalNo.
 *  A5  Tax amounts per tax group are the sum of the sale's own line taxes (not recomputed).
 *  A6  The submitReceipt answer may list validation problems as { validationErrorCode, validationErrorColor } with colours Grey, Red, Yellow.
 *  A7  Laybys are fiscalised when the goods are collected; until then their document waits (not connected yet: see README).
 */
import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';
import { Writer, tx, SetupError, type SetupContext } from './setup.ts';
import { convertMinor } from './money.ts';

type Row = Record<string, any>;
export class FiscalError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

// ---- ZIMRA shapes (names as in the API specification v7.2) ----

export type MoneyType = 'Cash' | 'Card' | 'MobileWallet' | 'Coupon' | 'Credit' | 'BankTransfer' | 'Other';
export interface ApplicableTax { taxID: number; taxName?: string; taxPercent: number | null; taxCode?: string }
export interface ReceiptLine {
  receiptLineType: 'Sale' | 'Discount'; receiptLineNo: number; receiptLineHSCode?: string; receiptLineName: string;
  receiptLinePrice?: number; receiptLineQuantity: number; receiptLineTotal: number; taxCode?: string; taxPercent?: number | null; taxID: number;
}
export interface ReceiptTax { taxCode?: string; taxPercent?: number | null; taxID: number; taxAmount: number; salesAmountWithTax: number }
export interface Receipt {
  receiptType: 'FiscalInvoice' | 'CreditNote'; receiptCurrency: string; receiptCounter: number; receiptGlobalNo: number; invoiceNo: string;
  buyerData?: { buyerRegisterName?: string; buyerTIN?: string };
  receiptNotes?: string; receiptDate: string;
  creditDebitNote?: { receiptID?: number; deviceID?: number; receiptGlobalNo?: number; fiscalDayNo?: number };
  receiptLinesTaxInclusive: boolean; receiptLines: ReceiptLine[]; receiptTaxes: ReceiptTax[];
  receiptPayments: { moneyTypeCode: MoneyType; paymentAmount: number }[]; receiptTotal: number; receiptPrintForm: 'Receipt48' | 'InvoiceA4';
  receiptDeviceSignature?: { hash: string; signature: string };
}
/** What the builder produces before the day's counters and the signature are added. */
export type DraftReceipt = Omit<Receipt, 'receiptCounter' | 'receiptGlobalNo' | 'receiptDeviceSignature'>;

export interface DayCounter { fiscalCounterType: string; fiscalCounterCurrency: string; fiscalCounterTaxID?: number; fiscalCounterTaxPercent?: number | null; fiscalCounterMoneyType?: MoneyType; fiscalCounterValue: number }

export interface SubmitResult {
  receiptID: number; serverDate?: string; receiptServerSignature?: unknown;
  validationErrors?: { validationErrorCode: string; validationErrorColor: 'Grey' | 'Red' | 'Yellow' | string }[];
}
/** Thrown by a Gateway. `retryable` means the phone should try again later (no connection, timeout, HTTP 500/502). */
export class GatewayError extends Error {
  status: number; code: string | null; retryable: boolean;
  constructor(message: string, o: { status?: number; code?: string | null; retryable?: boolean } = {}) {
    super(message); this.status = o.status ?? 0; this.code = o.code ?? null; this.retryable = o.retryable ?? false;
  }
}
export interface Gateway {
  openDay(req: { fiscalDayOpened: string; fiscalDayNo?: number }): Promise<{ fiscalDayNo: number }>;
  submitReceipt(receipt: Receipt): Promise<SubmitResult>;
  closeDay(req: { fiscalDayNo: number; fiscalDayCounters: DayCounter[]; fiscalDayDeviceSignature: { hash: string; signature: string }; receiptCounter: number }): Promise<{ ok: boolean; errors?: string[] }>;
}
export interface Signer {
  /** False when no real signer is installed. The phone then leaves receipts queued without even opening a fiscal day. */
  isReady?(): boolean;
  /** Signs a receipt (the caller has already set receiptCounter and receiptGlobalNo). `previousHash` is null for the first receipt of a day. */
  signReceipt(receipt: Omit<Receipt, 'receiptDeviceSignature'>, previousHash: string | null): { hash: string; signature: string };
  signDay(day: { fiscalDayNo: number; fiscalDayDate: string; counters: DayCounter[] }): { hash: string; signature: string };
}
export class SignerUnavailable extends Error { constructor() { super('Receipt signing is not set up on this phone yet.'); } }
export const UnavailableSigner: Signer = {
  isReady: () => false,
  signReceipt() { throw new SignerUnavailable(); },
  signDay() { throw new SignerUnavailable(); },
};

// ---- device and shop settings ----

export interface FiscalDevice { device_id: number; serial: string; registered_at: number }
export interface FiscalState {
  day_no: number; status: 'closed' | 'opened' | 'close_failed'; opened_at: number | null; date: string | null;
  receipt_counter: number; global_no: number; last_hash: string | null; last_close_error: string | null;
}
const EMPTY_STATE: FiscalState = { day_no: 0, status: 'closed', opened_at: null, date: null, receipt_counter: 0, global_no: 0, last_hash: null, last_close_error: null };

function ds(db: DatabaseSync, key: string): any {
  const r = db.prepare('select value from device_state where key = ?').get(key) as Row | undefined;
  if (!r) return null;
  try { return JSON.parse(r.value); } catch { return null; }
}
function setDs(db: DatabaseSync, key: string, v: unknown): void {
  db.prepare('insert into device_state (key, value) values (?, ?) on conflict (key) do update set value = excluded.value').run(key, JSON.stringify(v));
}
export const getDevice = (db: DatabaseSync): FiscalDevice | null => ds(db, 'fiscal_device');
export const getState = (db: DatabaseSync): FiscalState => ({ ...EMPTY_STATE, ...(ds(db, 'fiscal_state') ?? {}) });
const putState = (db: DatabaseSync, s: FiscalState) => setDs(db, 'fiscal_state', s);

/** Remembers this phone's ZIMRA device (each till is registered with ZIMRA on its own). The certificate and key live in the phone's secure storage, not here. */
export function saveDevice(db: DatabaseSync, now: number, input: { device_id: number; serial: string }): FiscalDevice {
  if (!Number.isInteger(input.device_id) || input.device_id <= 0) throw new FiscalError('bad_device', 'Enter the device ID ZIMRA gave you.');
  const serial = String(input.serial ?? '').trim();
  if (!serial || serial.length > 60) throw new FiscalError('bad_device', 'Enter the device serial number.');
  const cur = getDevice(db);
  if (cur && cur.device_id !== input.device_id && (getState(db).status === 'opened' || queuedCount(db) > 0)) {
    throw new FiscalError('device_busy', 'Close the fiscal day and send all waiting receipts before changing the device.');
  }
  const d = { device_id: input.device_id, serial, registered_at: cur?.device_id === input.device_id ? cur.registered_at : now };
  setDs(db, 'fiscal_device', d);
  if (!cur || cur.device_id !== input.device_id) putState(db, { ...EMPTY_STATE });
  return d;
}

export const isEnabled = (db: DatabaseSync): boolean =>
  (db.prepare("select value from settings where scope = 'shop' and key = 'fiscal_enabled' and deleted_at is null").get() as Row | undefined)?.value === '1';

/** Turn fiscalisation on or off for the shop. Only allowed when the shop's licence carries the ZIMRA feature, which the caller checks. */
export function setEnabled(db: DatabaseSync, ctx: SetupContext, on: boolean, newId: () => string = randomUUID): void {
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const row = w.get("select id, value from settings where scope = 'shop' and key = 'fiscal_enabled' and deleted_at is null");
    if (row && row.value === (on ? '1' : '0')) return;
    if (row) w.edit('settings', row.id, { value: on ? '1' : '0' });
    else w.addVersioned('settings', { scope: 'shop', key: 'fiscal_enabled', value: on ? '1' : '0' });
    w.add('audit_log', { user_id: ctx.user_id, action: 'fiscal_toggle', table_name: 'settings', row_id: 'fiscal_enabled', before: on ? '0' : '1', after: on ? '1' : '0' });
  });
}

export interface TaxSetup { taxes: ApplicableTax[]; map: Record<string, number>; hs_default: string }
/** The shop's tax classes tied to ZIMRA's tax IDs (from the device's getConfig), and a default HS code for items without one. Shared by every till. */
export function getTaxSetup(db: DatabaseSync): TaxSetup {
  const get = (k: string) => (db.prepare("select value from settings where scope = 'shop' and key = ? and deleted_at is null").get(k) as Row | undefined)?.value as string | undefined;
  const parse = (s: string | undefined, d: any) => { try { return s ? JSON.parse(s) : d; } catch { return d; } };
  return { taxes: parse(get('fiscal_taxes'), []), map: parse(get('fiscal_tax_map'), {}), hs_default: get('fiscal_hs_default') ?? '' };
}
export function saveTaxSetup(db: DatabaseSync, ctx: SetupContext, input: { taxes?: ApplicableTax[]; map?: Record<string, number>; hs_default?: string }, newId: () => string = randomUUID): void {
  const w = new Writer(db, ctx, newId);
  const put = (key: string, value: string) => {
    const row = w.get("select id, value from settings where scope = 'shop' and key = ? and deleted_at is null", key);
    if (row?.value === value) return;
    if (row) w.edit('settings', row.id, { value }); else w.addVersioned('settings', { scope: 'shop', key, value });
  };
  if (input.map) {
    const known = new Set((input.taxes ?? getTaxSetup(db).taxes).map((t) => t.taxID));
    for (const [cls, id] of Object.entries(input.map)) {
      if (!db.prepare('select 1 from tax_classes where id = ? and deleted_at is null').get(cls)) throw new FiscalError('bad_tax_map', 'A tax class in the list does not exist.');
      if (known.size > 0 && !known.has(id)) throw new FiscalError('bad_tax_map', 'A tax ID is not one of ZIMRA\'s taxes for this device.');
    }
  }
  if (input.hs_default !== undefined && input.hs_default !== '' && !/^\d{4,8}(\.\d+)?$/.test(input.hs_default)) throw new FiscalError('bad_hs', 'An HS code is 4 to 8 digits.');
  tx(db, () => {
    if (input.taxes) put('fiscal_taxes', JSON.stringify(input.taxes));
    if (input.map) put('fiscal_tax_map', JSON.stringify(input.map));
    if (input.hs_default !== undefined) put('fiscal_hs_default', input.hs_default);
  });
}

// ---- building receipts ----

const MONEY_BY_KIND: Record<string, MoneyType> = { cash: 'Cash', card: 'Card', mobile_money: 'MobileWallet', bank: 'BankTransfer' };
const pad = (n: number) => String(n).padStart(2, '0');
/** A1: local time without a zone. */
export function zimraDate(ms: number, offsetMin: number): string {
  const d = new Date(ms + offsetMin * 60_000);
  return `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}T${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}:${pad(d.getUTCSeconds())}`;
}
const units = (db: DatabaseSync, code: string, cache: Map<string, number>): number => {
  let u = cache.get(code);
  if (u === undefined) { u = ((db.prepare('select minor_units from currencies where code = ?').get(code) as Row | undefined)?.minor_units as number | undefined) ?? 2; cache.set(code, u); }
  return u;
};
/** A1: a decimal number with at most two decimals. */
export const amt = (minor: number, minorUnits: number): number => Math.round((minor / 10 ** minorUnits) * 100) / 100;

interface Tax { taxID: number; taxCode?: string; taxPercent: number | null }
function taxFor(db: DatabaseSync, setup: TaxSetup, product_id: string | null, rate_bp: number | null): Tax {
  const cls = product_id ? (db.prepare('select p.tax_class_id from products p where p.id = ?').get(product_id) as Row | undefined)?.tax_class_id as string | undefined : undefined;
  let id = cls ? setup.map[cls] : undefined;
  if (id === undefined && !cls) {
    // An item with no tax class: use the tax whose percentage equals the line's own rate, if exactly one does.
    const hit = setup.taxes.filter((t) => Math.round((t.taxPercent ?? 0) * 100) === (rate_bp ?? 0));
    if (hit.length === 1) id = hit[0]!.taxID;
  }
  if (id === undefined) throw new FiscalError('tax_not_mapped', 'A tax class is not tied to a ZIMRA tax yet. Open Fiscal settings and match them up.');
  const t = setup.taxes.find((x) => x.taxID === id);
  if (!t) throw new FiscalError('tax_not_mapped', 'The ZIMRA tax chosen for a tax class is not on this device\'s list. Open Fiscal settings.');
  return { taxID: t.taxID, taxCode: t.taxCode, taxPercent: t.taxPercent ?? null };
}

function group(lines: { tax: Tax; total: number; taxMinor: number }[], u: number): ReceiptTax[] {
  const m = new Map<number, { tax: Tax; sales: number; amount: number }>();
  for (const l of lines) {
    const g = m.get(l.tax.taxID) ?? { tax: l.tax, sales: 0, amount: 0 };
    g.sales += l.total; g.amount += l.taxMinor; m.set(l.tax.taxID, g);
  }
  return [...m.values()].sort((a, b) => a.tax.taxID - b.tax.taxID).map((g) => {
    const t: ReceiptTax = { taxID: g.tax.taxID, taxAmount: amt(g.amount, u), salesAmountWithTax: amt(g.sales, u) };
    if (g.tax.taxCode !== undefined) t.taxCode = g.tax.taxCode;
    t.taxPercent = g.tax.taxPercent;
    return t;
  });
}

function buyer(db: DatabaseSync, customerId: string | null): DraftReceipt['buyerData'] | undefined {
  if (!customerId) return undefined;
  const c = db.prepare('select name from customers where id = ?').get(customerId) as Row | undefined;
  return c?.name ? { buyerRegisterName: c.name } : undefined;
}

/** A FiscalInvoice for a sale. Throws FiscalError when the sale cannot be fiscalised yet (see code). */
export function buildInvoice(db: DatabaseSync, saleId: string, o: { offset_min: number; setup?: TaxSetup }): DraftReceipt {
  const sale = db.prepare('select * from sales where id = ?').get(saleId) as Row | undefined;
  if (!sale) throw new FiscalError('sale_missing', 'The sale for this receipt was not found.');
  if (sale.status === 'layby') throw new FiscalError('layby_not_collected', 'A layby is fiscalised when the goods are collected.'); // A7
  const setup = o.setup ?? getTaxSetup(db);
  const cache = new Map<string, number>();
  const u = units(db, sale.sale_currency, cache);
  const lines: ReceiptLine[] = [];
  const taxLines: { tax: Tax; total: number; taxMinor: number }[] = [];
  let n = 0;
  for (const l of db.prepare('select * from sale_lines where sale_id = ? order by created_at, id').all(saleId) as Row[]) {
    const tax = taxFor(db, setup, l.product_id, l.tax_rate_bp);
    const inclusive = (db.prepare('select tc.is_inclusive from products p join tax_classes tc on tc.id = p.tax_class_id where p.id = ?').get(l.product_id ?? '') as Row | undefined)?.is_inclusive !== 0;
    const lineTax = l.tax_minor ?? 0;
    const discount = l.discount_minor ?? 0;
    const netOfDiscount = l.line_total_minor + (inclusive ? 0 : lineTax); // what the customer pays for the line, tax included
    const gross = netOfDiscount + discount;                              // before the discount
    const qty = l.qty_milli / 1000;
    const name = String(l.description ?? '').trim() || (db.prepare('select name from products where id = ?').get(l.product_id ?? '') as Row | undefined)?.name || 'Item';
    const hs = setup.hs_default || undefined;
    const base = { receiptLineName: String(name).slice(0, 200), taxCode: tax.taxCode, taxPercent: tax.taxPercent, taxID: tax.taxID };
    lines.push({ receiptLineType: 'Sale', receiptLineNo: ++n, ...(hs ? { receiptLineHSCode: hs } : {}), ...base, receiptLinePrice: amt(l.unit_price_minor, u), receiptLineQuantity: qty, receiptLineTotal: amt(gross, u) });
    if (discount > 0) lines.push({ receiptLineType: 'Discount', receiptLineNo: ++n, ...(hs ? { receiptLineHSCode: hs } : {}), ...base, receiptLineQuantity: 1, receiptLineTotal: -amt(discount, u) }); // A2
    taxLines.push({ tax, total: netOfDiscount, taxMinor: lineTax }); // A5
  }
  if (lines.length === 0) throw new FiscalError('no_lines', 'The sale has no items.');
  const total = taxLines.reduce((s, x) => s + x.total, 0);
  if (total !== sale.total_minor) throw new FiscalError('total_mismatch', 'The sale\'s items do not add up to its total, so it cannot be sent to ZIMRA. Ask support.');

  // Payments in the sale's currency, change taken off, and what was put on the customer's account as Credit.
  const paid = new Map<MoneyType, number>();
  for (const p of db.prepare('select sp.*, pm.kind from sale_payments sp left join payment_methods pm on pm.code = sp.method_code where sp.sale_id = ?').all(saleId) as Row[]) {
    const v = p.currency === sale.sale_currency ? p.amount_minor : convertMinor(p.amount_minor, p.rate_to_sale_micro ?? 1_000_000, units(db, p.currency, cache), u);
    const type: MoneyType = MONEY_BY_KIND[p.kind ?? ''] ?? 'Other';
    paid.set(type, (paid.get(type) ?? 0) + (p.is_change ? -v : v));
  }
  let sum = [...paid.values()].reduce((a, b) => a + b, 0);
  if (sum < total) { paid.set('Credit', (paid.get('Credit') ?? 0) + (total - sum)); sum = total; }
  if (sum > total) { // over-payment through rounding in another currency: take it off the largest payment
    const big = [...paid.entries()].sort((a, b) => b[1] - a[1])[0]!;
    paid.set(big[0], big[1] - (sum - total));
  }
  const payments = [...paid.entries()].filter(([, v]) => v !== 0).map(([moneyTypeCode, v]) => ({ moneyTypeCode, paymentAmount: amt(v, u) }));
  const b = buyer(db, sale.customer_id);
  return {
    receiptType: 'FiscalInvoice', receiptCurrency: sale.sale_currency, invoiceNo: sale.receipt_no, ...(b ? { buyerData: b } : {}),
    receiptDate: zimraDate(sale.completed_at, o.offset_min), receiptLinesTaxInclusive: true, receiptLines: lines, receiptTaxes: group(taxLines, u),
    receiptPayments: payments, receiptTotal: amt(total, u), receiptPrintForm: 'Receipt48',
  };
}

/** A CreditNote for a return or a void. `original` is the already sent invoice it refers to. */
export function buildCreditNote(db: DatabaseSync, returnId: string, original: { receiptID?: number; deviceID: number; receiptGlobalNo: number; fiscalDayNo: number } | null, o: { offset_min: number; setup?: TaxSetup }): DraftReceipt {
  const ret = db.prepare('select * from sale_returns where id = ?').get(returnId) as Row | undefined;
  if (!ret) throw new FiscalError('return_missing', 'The return for this credit note was not found.');
  if (!original) throw new FiscalError('original_not_sent', 'The original receipt has not been sent to ZIMRA yet.');
  const sale = db.prepare('select * from sales where id = ?').get(ret.original_sale_id) as Row;
  const setup = o.setup ?? getTaxSetup(db);
  const cache = new Map<string, number>();
  const u = units(db, sale.sale_currency, cache);
  const lines: ReceiptLine[] = [];
  const taxLines: { tax: Tax; total: number; taxMinor: number }[] = [];
  let n = 0;
  for (const rl of db.prepare('select * from sale_return_lines where return_id = ? order by created_at, id').all(returnId) as Row[]) {
    const l = db.prepare('select * from sale_lines where id = ?').get(rl.sale_line_id) as Row;
    const tax = taxFor(db, setup, l.product_id, l.tax_rate_bp);
    const refund = rl.amount_minor as number; // tax included, in the sale's currency
    const rate = tax.taxPercent ?? 0;
    const taxMinor = Math.round((refund * rate) / (100 + rate));
    const name = String(l.description ?? '').trim() || (db.prepare('select name from products where id = ?').get(l.product_id ?? '') as Row | undefined)?.name || 'Item';
    const hs = setup.hs_default || undefined;
    lines.push({
      receiptLineType: 'Sale', receiptLineNo: ++n, ...(hs ? { receiptLineHSCode: hs } : {}), receiptLineName: String(name).slice(0, 200),
      receiptLinePrice: amt(l.unit_price_minor, u), receiptLineQuantity: rl.qty_milli / 1000, receiptLineTotal: -amt(refund, u), taxCode: tax.taxCode, taxPercent: tax.taxPercent, taxID: tax.taxID,
    });
    taxLines.push({ tax, total: -refund, taxMinor: -taxMinor }); // A3
  }
  if (lines.length === 0) throw new FiscalError('no_lines', 'The return has no items.');
  const total = taxLines.reduce((s, x) => s + x.total, 0);
  const paid = new Map<MoneyType, number>();
  for (const p of db.prepare('select rp.*, pm.kind from return_payouts rp left join payment_methods pm on pm.code = rp.method_code where rp.return_id = ?').all(returnId) as Row[]) {
    const v = p.currency === sale.sale_currency ? p.amount_minor : convertMinor(p.amount_minor, p.rate_to_sale_micro ?? 1_000_000, units(db, p.currency, cache), u);
    const type: MoneyType = MONEY_BY_KIND[p.kind ?? ''] ?? 'Other';
    paid.set(type, (paid.get(type) ?? 0) - v);
  }
  let sum = [...paid.values()].reduce((a, b) => a + b, 0);
  if (sum > total) { paid.set('Credit', (paid.get('Credit') ?? 0) + (total - sum)); sum = total; } // refund taken off the customer's account (negative)
  const payments = [...paid.entries()].filter(([, v]) => v !== 0).map(([moneyTypeCode, v]) => ({ moneyTypeCode, paymentAmount: amt(v, u) }));
  const b = buyer(db, sale.customer_id);
  const cn: NonNullable<DraftReceipt['creditDebitNote']> = original.receiptID !== undefined ? { receiptID: original.receiptID } : { deviceID: original.deviceID, receiptGlobalNo: original.receiptGlobalNo, fiscalDayNo: original.fiscalDayNo };
  return {
    receiptType: 'CreditNote', receiptCurrency: sale.sale_currency, invoiceNo: ret.receipt_no, ...(b ? { buyerData: b } : {}),
    receiptNotes: String(ret.reason ?? '').trim() || (ret.kind === 'void' ? 'Sale voided' : 'Goods returned'), receiptDate: zimraDate(ret.created_at, o.offset_min),
    creditDebitNote: cn, receiptLinesTaxInclusive: true, receiptLines: lines, receiptTaxes: group(taxLines, u), receiptPayments: payments, receiptTotal: amt(total, u), receiptPrintForm: 'Receipt48',
  };
}

// ---- day counters (API section 6) ----

/** Counters for closing a day, from the receipts sent that day. Zero values are left out. Sorted by type, currency, tax, money type. */
export function dayCounters(receipts: Receipt[]): DayCounter[] {
  const m = new Map<string, DayCounter>();
  const add = (c: Omit<DayCounter, 'fiscalCounterValue'>, v: number) => {
    const k = JSON.stringify([c.fiscalCounterType, c.fiscalCounterCurrency, c.fiscalCounterTaxID ?? null, c.fiscalCounterMoneyType ?? null]);
    const cur = m.get(k) ?? { ...c, fiscalCounterValue: 0 };
    cur.fiscalCounterValue = Math.round((cur.fiscalCounterValue + v) * 100) / 100; m.set(k, cur);
  };
  for (const r of receipts) {
    const credit = r.receiptType === 'CreditNote';
    for (const t of r.receiptTaxes) {
      const base = { fiscalCounterCurrency: r.receiptCurrency, fiscalCounterTaxID: t.taxID, fiscalCounterTaxPercent: t.taxPercent ?? null };
      add({ fiscalCounterType: credit ? 'CreditNoteByTax' : 'SaleByTax', ...base }, credit ? -Math.abs(t.salesAmountWithTax) : t.salesAmountWithTax);
      add({ fiscalCounterType: credit ? 'CreditNoteTaxByTax' : 'SaleTaxByTax', ...base }, credit ? -Math.abs(t.taxAmount) : t.taxAmount);
    }
    for (const p of r.receiptPayments) {
      add({ fiscalCounterType: 'BalanceByMoneyType', fiscalCounterCurrency: r.receiptCurrency, fiscalCounterMoneyType: p.moneyTypeCode }, credit ? -Math.abs(p.paymentAmount) : p.paymentAmount);
    }
  }
  const order = ['SaleByTax', 'CreditNoteByTax', 'DebitNoteByTax', 'SaleTaxByTax', 'CreditNoteTaxByTax', 'DebitNoteTaxByTax', 'BalanceByMoneyType'];
  const money = ['Cash', 'Card', 'MobileWallet', 'Coupon', 'Credit', 'BankTransfer', 'Other'];
  return [...m.values()].filter((c) => c.fiscalCounterValue !== 0).sort((a, b) =>
    order.indexOf(a.fiscalCounterType) - order.indexOf(b.fiscalCounterType) || a.fiscalCounterCurrency.localeCompare(b.fiscalCounterCurrency)
    || (a.fiscalCounterTaxID ?? 0) - (b.fiscalCounterTaxID ?? 0) || money.indexOf(a.fiscalCounterMoneyType ?? 'Cash') - money.indexOf(b.fiscalCounterMoneyType ?? 'Cash'));
}

// ---- the queue ----

export interface QueueDoc { id: string; sale_id: string | null; kind: 'invoice' | 'credit_note'; status: 'queued' | 'sent' | 'failed'; attempts: number; authority_ref: string | null; payload: Row; updated_at: number }
const parse = (s: string): Row => { try { return JSON.parse(s); } catch { return {}; } };
function docs(db: DatabaseSync, where: string, ...a: any[]): QueueDoc[] {
  return (db.prepare(`select * from fiscal_documents where deleted_at is null and ${where} order by created_at, id`).all(...a) as Row[]).map((r) => ({
    id: r.id, sale_id: r.sale_id, kind: r.kind, status: r.status, attempts: r.attempts ?? 0, authority_ref: r.authority_ref ?? null, payload: parse(r.payload), updated_at: r.updated_at,
  }));
}
export const queuedCount = (db: DatabaseSync): number => docs(db, "status = 'queued'").filter((d) => !d.payload.deferred).length;
export const listQueue = (db: DatabaseSync, status?: 'queued' | 'sent' | 'failed', limit = 100): QueueDoc[] => (status ? docs(db, 'status = ?', status) : docs(db, '1 = 1')).slice(-limit).reverse();

function setDoc(db: DatabaseSync, ctx: SetupContext, id: string, set: Row): void {
  const cur = db.prepare('select version from fiscal_documents where id = ?').get(id) as Row;
  const o: Row = { ...set, version: cur.version + 1, updated_at: ctx.now };
  const k = Object.keys(o);
  db.prepare(`update fiscal_documents set ${k.map((x) => `"${x}" = ?`).join(', ')} where id = ?`).run(...k.map((x) => o[x]), id);
}

/** A failed document goes back to the queue after the cause is fixed (for example a tax class was matched up). */
export function requeue(db: DatabaseSync, ctx: SetupContext, docId: string): void {
  const d = docs(db, 'id = ?', docId)[0];
  if (!d) throw new FiscalError('not_found', 'That document was not found.');
  if (d.status !== 'failed') throw new FiscalError('not_failed', 'Only a failed document can be sent again.');
  const { error, error_code, ...rest } = d.payload;
  void error; void error_code;
  setDoc(db, ctx, docId, { status: 'queued', payload: JSON.stringify(rest) });
}

// ---- the work: open day, send queue, close day ----

export interface RunOptions { offset_min: number; day_max_hrs?: number }
export interface RunResult {
  sent: number; failed: number; waiting: number; stopped: null | 'disabled' | 'no_device' | 'signing_unavailable' | 'offline' | 'day_open_failed';
  day_too_long: boolean; problems: { doc_id: string; code: string; message: string }[]; validation_colors: string[];
}

const HOUR = 3_600_000;
const dayReceipts = (db: DatabaseSync, dayNo: number): Receipt[] =>
  docs(db, "status = 'sent'").filter((d) => d.payload.receipt && d.payload.fiscalDayNo === dayNo).map((d) => d.payload.receipt as Receipt);

/** Makes sure a fiscal day is open (asks ZIMRA to open one if not). */
export async function ensureDayOpen(db: DatabaseSync, ctx: SetupContext, gw: Gateway, o: RunOptions): Promise<FiscalState> {
  const s = getState(db);
  if (s.status === 'opened' || s.status === 'close_failed') return s; // a failed close leaves the day open at ZIMRA
  const opened = zimraDate(ctx.now, o.offset_min);
  const r = await gw.openDay({ fiscalDayOpened: opened });
  // A new day restarts the day's receipt counter; the global number keeps counting. The hash chain restarts as well.
  const next: FiscalState = { ...s, day_no: r.fiscalDayNo, status: 'opened', opened_at: ctx.now, date: opened.slice(0, 10), receipt_counter: 0, last_hash: null, last_close_error: null };
  putState(db, next);
  return next;
}

/** Sends the waiting receipts in the order they were made. Never throws for expected trouble; it reports. Sales are never blocked by any of this. */
export async function sendQueued(db: DatabaseSync, ctx: SetupContext, gw: Gateway, signer: Signer, o: RunOptions): Promise<RunResult> {
  const res: RunResult = { sent: 0, failed: 0, waiting: 0, stopped: null, day_too_long: false, problems: [], validation_colors: [] };
  if (!isEnabled(db)) { res.stopped = 'disabled'; return res; }
  const dev = getDevice(db);
  if (!dev) { res.stopped = 'no_device'; return res; }
  if (signer.isReady && !signer.isReady()) { res.stopped = 'signing_unavailable'; res.waiting = queuedCount(db); return res; }
  const todo = () => docs(db, "status = 'queued'").filter((d) => !d.payload.deferred);
  const pending = todo();
  if (pending.length === 0) return res;
  let state: FiscalState;
  try { state = await ensureDayOpen(db, ctx, gw, o); } catch (e) {
    res.stopped = e instanceof GatewayError && !e.retryable ? 'day_open_failed' : 'offline';
    res.waiting = pending.length;
    if (e instanceof GatewayError && !e.retryable) res.problems.push({ doc_id: '', code: e.code ?? 'open_day_failed', message: e.message });
    return res;
  }
  if (o.day_max_hrs && state.opened_at !== null && ctx.now - state.opened_at > o.day_max_hrs * HOUR) res.day_too_long = true;
  const setup = getTaxSetup(db);
  for (const d of pending) {
    // 1. build
    let draft: DraftReceipt;
    try {
      if (d.kind === 'invoice') {
        if (!d.sale_id) throw new FiscalError('sale_missing', 'This receipt has no sale.');
        draft = buildInvoice(db, d.sale_id, { offset_min: o.offset_min, setup });
      } else {
        const retId = String(d.payload.return_id ?? '');
        const ret = db.prepare('select original_sale_id from sale_returns where id = ?').get(retId) as Row | undefined;
        const orig = ret ? docs(db, "kind = 'invoice' and sale_id = ?", ret.original_sale_id)[0] : undefined;
        if (!orig) throw new FiscalError('original_not_fiscalised', 'The original sale was never sent to ZIMRA (it was made before fiscalisation was switched on), so a credit note cannot be issued.');
        if (orig.status === 'failed') throw new FiscalError('original_failed', 'The original receipt failed. Fix it first.');
        const sentRcp = orig.payload.receipt as Receipt | undefined;
        const ref = orig.status === 'sent' && sentRcp ? { receiptID: Number(orig.authority_ref), deviceID: dev.device_id, receiptGlobalNo: sentRcp.receiptGlobalNo, fiscalDayNo: Number(orig.payload.fiscalDayNo) } : null;
        draft = buildCreditNote(db, retId, ref, { offset_min: o.offset_min, setup });
      }
    } catch (e) {
      if (!(e instanceof FiscalError)) throw e;
      if (e.code === 'layby_not_collected' || e.code === 'original_not_sent') {
        setDoc(db, ctx, d.id, { payload: JSON.stringify({ ...d.payload, deferred: e.code }) });
        continue;
      }
      setDoc(db, ctx, d.id, { status: 'failed', attempts: d.attempts + 1, payload: JSON.stringify({ ...d.payload, error: e.message, error_code: e.code }) });
      res.failed++; res.problems.push({ doc_id: d.id, code: e.code, message: e.message });
      continue;
    }
    // 2. number and sign
    const numbered = { ...draft, receiptCounter: state.receipt_counter + 1, receiptGlobalNo: state.global_no + 1 };
    let sig: { hash: string; signature: string };
    try { sig = signer.signReceipt(numbered, state.last_hash); } catch (e) {
      if (e instanceof SignerUnavailable) { res.stopped = 'signing_unavailable'; res.waiting = todo().length; return res; }
      throw e;
    }
    const receipt: Receipt = { ...numbered, receiptDeviceSignature: sig };
    // 3. send
    try {
      const r = await gw.submitReceipt(receipt);
      state = { ...state, receipt_counter: receipt.receiptCounter, global_no: receipt.receiptGlobalNo, last_hash: sig.hash };
      putState(db, state);
      const colors = (r.validationErrors ?? []).map((v) => `${v.validationErrorColor}:${v.validationErrorCode}`);
      res.validation_colors.push(...colors);
      setDoc(db, ctx, d.id, {
        status: 'sent', attempts: d.attempts + 1, authority_ref: String(r.receiptID), sent_at: ctx.now,
        payload: JSON.stringify({ ...d.payload, receipt, fiscalDayNo: state.day_no, server: { date: r.serverDate ?? null, signature: r.receiptServerSignature ?? null }, validation: r.validationErrors ?? [] }),
      });
      res.sent++;
    } catch (e) {
      if (!(e instanceof GatewayError)) throw e;
      if (e.retryable) { // A4: nothing was used up, so the same numbers are used next time
        setDoc(db, ctx, d.id, { attempts: d.attempts + 1 });
        res.stopped = 'offline'; res.waiting = todo().length; return res;
      }
      setDoc(db, ctx, d.id, { status: 'failed', attempts: d.attempts + 1, payload: JSON.stringify({ ...d.payload, error: e.message, error_code: e.code ?? 'rejected' }) });
      res.failed++; res.problems.push({ doc_id: d.id, code: e.code ?? 'rejected', message: e.message });
    }
  }
  res.waiting = todo().length;
  return res;
}

export interface CloseCheck { ok: boolean; reasons: string[] }
/** Whether the day can be closed now: it is open, nothing is waiting or failed, and no receipt carries a Grey or Red validation mark. */
export function canCloseDay(db: DatabaseSync): CloseCheck {
  const s = getState(db);
  const reasons: string[] = [];
  if (s.status === 'closed') reasons.push('There is no open fiscal day.');
  const waiting = docs(db, "status = 'queued'").filter((d) => !d.payload.deferred).length;
  if (waiting > 0) reasons.push(`${waiting} receipt${waiting === 1 ? ' is' : 's are'} still waiting to be sent.`);
  const failed = docs(db, "status = 'failed'").length;
  if (failed > 0) reasons.push(`${failed} receipt${failed === 1 ? ' has' : 's have'} failed. Fix or ask support.`);
  const bad = docs(db, "status = 'sent'").filter((d) => d.payload.fiscalDayNo === s.day_no && (d.payload.validation ?? []).some((v: Row) => v.validationErrorColor === 'Grey' || v.validationErrorColor === 'Red'));
  if (bad.length > 0) reasons.push(`${bad.length} receipt${bad.length === 1 ? ' was' : 's were'} marked by ZIMRA as having a problem. The day cannot be closed until that is dealt with.`);
  return { ok: reasons.length === 0, reasons };
}

export async function closeDay(db: DatabaseSync, ctx: SetupContext, gw: Gateway, signer: Signer): Promise<{ ok: boolean; message: string }> {
  const check = canCloseDay(db);
  if (!check.ok) return { ok: false, message: check.reasons.join(' ') };
  const s = getState(db);
  const counters = dayCounters(dayReceipts(db, s.day_no));
  let sig: { hash: string; signature: string };
  try { sig = signer.signDay({ fiscalDayNo: s.day_no, fiscalDayDate: s.date ?? '', counters }); } catch (e) {
    if (e instanceof SignerUnavailable) return { ok: false, message: e.message };
    throw e;
  }
  try {
    const r = await gw.closeDay({ fiscalDayNo: s.day_no, fiscalDayCounters: counters, fiscalDayDeviceSignature: sig, receiptCounter: s.receipt_counter });
    if (!r.ok) { putState(db, { ...s, status: 'close_failed', last_close_error: (r.errors ?? ['ZIMRA did not accept the day']).join('; ') }); return { ok: false, message: (r.errors ?? ['ZIMRA did not accept the day']).join('; ') }; }
    putState(db, { ...s, status: 'closed', last_close_error: null });
    return { ok: true, message: `Fiscal day ${s.day_no} closed.` };
  } catch (e) {
    if (!(e instanceof GatewayError)) throw e;
    if (!e.retryable) putState(db, { ...s, status: 'close_failed', last_close_error: e.message });
    return { ok: false, message: e.retryable ? 'Could not reach ZIMRA. Try again when you have a connection.' : e.message };
  }
}
void SetupError;
