import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { seedShop, saveProduct, receiveStock, setExchangeRate } from '../src/setup.ts';
import { sell } from '../src/selling.ts';
import { saveCustomer } from '../src/customers.ts';
import { processReturn, voidSale, returnableLines } from '../src/returns.ts';
import {
  GatewayError, UnavailableSigner, buildInvoice, canCloseDay, closeDay, dayCounters, getDevice, getState, listQueue, queuedCount, requeue, saveDevice, saveTaxSetup,
  sendQueued, setEnabled, zimraDate, type DayCounter, type Gateway, type Receipt, type Signer, type SubmitResult,
} from '../src/fiscal.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `fis-${String(++n).padStart(8, '0')}`;
const T0 = Date.UTC(2026, 10, 2, 6, 0);
const OFF = 120;
const TAXES = [{ taxID: 1, taxCode: 'A', taxName: 'Exempt', taxPercent: null }, { taxID: 2, taxCode: 'B', taxName: 'Zero rated', taxPercent: 0 }, { taxID: 3, taxCode: 'C', taxName: 'Standard rated 15%', taxPercent: 15 }];

class FakeGateway implements Gateway {
  calls: string[] = []; receipts: Receipt[] = []; nextDay = 100; closed: any[] = [];
  failOpen: GatewayError | null = null; failSubmit: ((r: Receipt) => GatewayError | null) | null = null; colors: ((r: Receipt) => SubmitResult['validationErrors']) | null = null;
  closeAnswer: { ok: boolean; errors?: string[] } = { ok: true }; closeError: GatewayError | null = null;
  async openDay() { this.calls.push('open'); if (this.failOpen) throw this.failOpen; return { fiscalDayNo: this.nextDay++ }; }
  async submitReceipt(r: Receipt) {
    this.calls.push('submit'); const e = this.failSubmit?.(r); if (e) throw e;
    this.receipts.push(r); return { receiptID: 5000 + this.receipts.length, serverDate: '2026-11-02T08:00:00', receiptServerSignature: { hash: 'srv', signature: 'srv' }, validationErrors: this.colors?.(r) };
  }
  async closeDay(req: any) { this.calls.push('close'); if (this.closeError) throw this.closeError; this.closed.push(req); return this.closeAnswer; }
}
/** Only proves the phone chains and numbers receipts consistently. It is NOT ZIMRA's signature. */
const fakeSigner: Signer = {
  signReceipt: (r, prev) => ({ hash: createHash('sha256').update(JSON.stringify(r) + (prev ?? '')).digest('base64'), signature: 'fake-sig' }),
  signDay: (d) => ({ hash: createHash('sha256').update(JSON.stringify(d)).digest('base64'), signature: 'fake-day-sig' }),
};

function world(opts: { fiscal?: boolean } = {}) {
  const db = new DatabaseSync(':memory:');
  db.exec(SQL);
  const base = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T0, receipt_prefix: 'D1' };
  const { branch_id } = seedShop(db, base, { name: 'Shop', country_code: 'ZW', tax_registered: true, tax_number: '1' }, uid);
  setExchangeRate(db, base, 'USD', 'ZiG', 26_500_000, uid);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const cls = (name: string) => q('select id from tax_classes where name = ?', name)[0].id as string;
  const bread = saveProduct(db, base, { name: 'Bread', price_minor: 150, cost_minor: 90, tax_class_id: cls('Standard rated') }, uid);
  const milk = saveProduct(db, base, { name: 'Milk', price_minor: 200, cost_minor: 120, tax_class_id: cls('Zero rated') }, uid);
  const salt = saveProduct(db, base, { name: 'Salt', price_minor: 100, cost_minor: 50, tax_class_id: cls('Exempt') }, uid);
  for (const p of [bread, milk, salt]) receiveStock(db, base, { branch_id, product_id: p, qty_milli: 100_000, unit_cost_minor: 90, opening: true }, uid);
  if (opts.fiscal !== false) setEnabled(db, base, true, uid);
  saveTaxSetup(db, base, { taxes: TAXES, map: { [cls('Standard rated')]: 3, [cls('Zero rated')]: 2, [cls('Exempt')]: 1 } }, uid);
  saveDevice(db, T0, { device_id: 187, serial: 'SN-001' });
  const cash = (currency: string, amount_minor: number) => ({ method_code: 'cash', currency, amount_minor });
  const sale = (at: number, lines: [string, number][], payments: any[], extra: any = {}) =>
    sell(db, { ...base, now: at }, { branch_id, user_id: null, sale_currency: 'USD', lines: lines.map(([product_id, qty_milli]) => ({ product_id, qty_milli })), payments, ...extra }, uid);
  const ctx = (now = T0) => ({ ...base, now });
  return { db, base, ctx, branch_id, bread, milk, salt, cash, sale, q, cls };
}
const RUN = { offset_min: OFF };

test('a sale made while fiscalisation is on is queued, and not queued when it is off', () => {
  const on = world(); const off = world({ fiscal: false });
  on.sale(T0, [[on.bread, 1000]], [on.cash('USD', 150)]);
  off.sale(T0, [[off.bread, 1000]], [off.cash('USD', 150)]);
  assert.equal(queuedCount(on.db), 1);
  assert.equal(queuedCount(off.db), 0);
});

test('invoice: lines, tax groups, totals and payments follow the sale (change taken off)', () => {
  const w = world();
  const s = w.sale(T0, [[w.bread, 4000], [w.milk, 1000], [w.salt, 2000]], [w.cash('USD', 2000)]); // 6.00 + 2.00 + 2.00 = 10.00, paid 20.00, change 10.00
  const r = buildInvoice(w.db, s.sale_id, { offset_min: OFF });
  assert.equal(r.receiptType, 'FiscalInvoice');
  assert.equal(r.invoiceNo, s.receipt_no);
  assert.equal(r.receiptDate, '2026-11-02T08:00:00', 'local time, no zone');
  assert.equal(r.receiptTotal, 10);
  assert.deepEqual(r.receiptLines.map((l) => [l.receiptLineName, l.receiptLinePrice, l.receiptLineQuantity, l.receiptLineTotal, l.taxID]), [['Bread', 1.5, 4, 6, 3], ['Milk', 2, 1, 2, 2], ['Salt', 1, 2, 2, 1]]);
  assert.deepEqual(r.receiptTaxes.map((t) => [t.taxID, t.salesAmountWithTax, t.taxAmount]), [[1, 2, 0], [2, 2, 0], [3, 6, 0.78]]);
  assert.deepEqual(r.receiptPayments, [{ moneyTypeCode: 'Cash', paymentAmount: 10 }]);
  assert.equal(r.receiptLinesTaxInclusive, true);
  assert.equal(r.receiptLines.map((l) => l.receiptLineNo).join(), '1,2,3');
});

test('invoice: a credit sale shows the unpaid part as Credit and names the customer as buyer', () => {
  const w = world();
  const c = saveCustomer(w.db, w.base, { name: 'Mai Tendai', phone: '0772 111 222', credit_limit_minor: 10_000, credit_currency: 'USD' }, uid);
  const s = w.sale(T0, [[w.milk, 2000]], [w.cash('USD', 100)], { customer_id: c, on_credit: true });
  const r = buildInvoice(w.db, s.sale_id, { offset_min: OFF });
  assert.equal(r.receiptTotal, 4);
  assert.deepEqual(r.receiptPayments, [{ moneyTypeCode: 'Cash', paymentAmount: 1 }, { moneyTypeCode: 'Credit', paymentAmount: 3 }]);
  assert.deepEqual(r.buyerData, { buyerRegisterName: 'Mai Tendai' });
});

test('invoice: a line discount becomes a Discount line after its Sale line, and the totals still agree', () => {
  const w = world();
  const s = sell(w.db, { ...w.base, now: T0 }, { branch_id: w.branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: w.bread, qty_milli: 2000, discount_minor: 50 }], payments: [w.cash('USD', 250)] }, uid);
  const r = buildInvoice(w.db, s.sale_id, { offset_min: OFF });
  assert.deepEqual(r.receiptLines.map((l) => [l.receiptLineType, l.receiptLineNo, l.receiptLineTotal]), [['Sale', 1, 3], ['Discount', 2, -0.5]]);
  assert.equal(r.receiptTotal, 2.5);
  assert.equal(r.receiptTaxes[0]!.salesAmountWithTax, 2.5);
});

test('invoice: money paid in another currency is expressed in the sale currency', () => {
  const w = world();
  const s = w.sale(T0, [[w.bread, 4000]], [w.cash('ZiG', 15_900)]); // USD 6.00 = ZiG 159.00 at 26.5
  const r = buildInvoice(w.db, s.sale_id, { offset_min: OFF });
  assert.equal(r.receiptCurrency, 'USD');
  assert.equal(r.receiptPayments.reduce((a, p) => a + p.paymentAmount, 0), 6);
});

test('a tax class that is not matched to a ZIMRA tax fails that receipt with a clear reason, and can be sent again after it is fixed', async () => {
  const w = world();
  const extra = w.q("select id from tax_classes where name = 'Standard rated'")[0].id;
  saveTaxSetup(w.db, w.base, { map: { [extra]: 3 } }, uid); // keep
  w.db.prepare("update settings set value = '{}', version = version + 1 where key = 'fiscal_tax_map'").run();
  const s = w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]); void s;
  const gw = new FakeGateway();
  const r = await sendQueued(w.db, w.ctx(), gw, fakeSigner, RUN);
  assert.equal(r.failed, 1);
  assert.equal(r.problems[0]!.code, 'tax_not_mapped');
  assert.equal(gw.receipts.length, 0);
  const failed = listQueue(w.db, 'failed');
  assert.equal(failed.length, 1);
  assert.match(failed[0]!.payload.error, /tax class/i);
  saveTaxSetup(w.db, w.base, { map: { [extra]: 3 } }, uid);
  requeue(w.db, w.ctx(), failed[0]!.id);
  const again = await sendQueued(w.db, w.ctx(), gw, fakeSigner, RUN);
  assert.equal(again.sent, 1);
});

test('sending: receipts go in order with day counters, global numbers and a hash chain; a second run sends nothing new', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  w.sale(T0 + 1000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  w.sale(T0 + 2000, [[w.salt, 1000]], [w.cash('USD', 100)]);
  const gw = new FakeGateway();
  const r = await sendQueued(w.db, w.ctx(T0 + 5000), gw, fakeSigner, RUN);
  assert.deepEqual([r.sent, r.failed, r.waiting, r.stopped], [3, 0, 0, null]);
  assert.deepEqual(gw.calls, ['open', 'submit', 'submit', 'submit']);
  assert.deepEqual(gw.receipts.map((x) => [x.receiptCounter, x.receiptGlobalNo]), [[1, 1], [2, 2], [3, 3]]);
  const h = gw.receipts.map((x) => x.receiptDeviceSignature!.hash);
  assert.equal(new Set(h).size, 3);
  assert.equal(gw.receipts[1]!.receiptDeviceSignature!.hash, fakeSigner.signReceipt({ ...gw.receipts[1]!, receiptDeviceSignature: undefined } as any, h[0]!).hash, 'each signature uses the one before it');
  const st = getState(w.db);
  assert.deepEqual([st.status, st.day_no, st.receipt_counter, st.global_no, st.last_hash], ['opened', 100, 3, 3, h[2]]);
  const sent = listQueue(w.db, 'sent');
  assert.equal(sent.length, 3);
  assert.deepEqual(sent.map((d) => d.authority_ref).sort(), ['5001', '5002', '5003']);
  const again = await sendQueued(w.db, w.ctx(T0 + 6000), gw, fakeSigner, RUN);
  assert.equal(again.sent, 0);
  assert.equal(gw.receipts.length, 3);
});

test('no connection: nothing is lost and no numbers are used up; the next run continues exactly where it stopped', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  w.sale(T0 + 1000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  const gw = new FakeGateway();
  gw.failSubmit = () => new GatewayError('timeout', { retryable: true });
  const r = await sendQueued(w.db, w.ctx(), gw, fakeSigner, RUN);
  assert.deepEqual([r.sent, r.stopped, r.waiting], [0, 'offline', 2]);
  assert.equal(getState(w.db).receipt_counter, 0);
  assert.equal(queuedCount(w.db), 2);
  gw.failSubmit = null;
  const ok = await sendQueued(w.db, w.ctx(), gw, fakeSigner, RUN);
  assert.equal(ok.sent, 2);
  assert.deepEqual(gw.receipts.map((x) => x.receiptCounter), [1, 2]);
  const dayNo = new FakeGateway(); dayNo.failOpen = new GatewayError('no network', { retryable: true });
  const w2 = world(); w2.sale(T0, [[w2.bread, 1000]], [w2.cash('USD', 150)]);
  const r2 = await sendQueued(w2.db, w2.ctx(), dayNo, fakeSigner, RUN);
  assert.deepEqual([r2.stopped, r2.waiting], ['offline', 1]);
});

test('ZIMRA rejects one receipt: it fails with the reason, the others still go, and the numbers are not wasted', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  const bad = w.sale(T0 + 1000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  w.sale(T0 + 2000, [[w.salt, 1000]], [w.cash('USD', 100)]);
  const gw = new FakeGateway();
  gw.failSubmit = (r) => (r.invoiceNo === bad.receipt_no ? new GatewayError('Invalid receipt', { status: 422, code: 'RCPT019', retryable: false }) : null);
  const r = await sendQueued(w.db, w.ctx(), gw, fakeSigner, RUN);
  assert.deepEqual([r.sent, r.failed], [2, 1]);
  assert.equal(r.problems[0]!.code, 'RCPT019');
  assert.deepEqual(gw.receipts.map((x) => x.receiptCounter), [1, 2], 'the counter after a rejection is reused');
  assert.equal(canCloseDay(w.db).ok, false);
  assert.match(canCloseDay(w.db).reasons.join(' '), /failed/);
});

test('until a real signer is installed receipts stay queued, no fiscal day is opened and sales are not affected', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  const gw = new FakeGateway();
  const r = await sendQueued(w.db, w.ctx(), gw, UnavailableSigner, RUN);
  assert.deepEqual([r.stopped, r.waiting, r.sent], ['signing_unavailable', 1, 0]);
  assert.deepEqual(gw.calls, []);
  assert.equal(getState(w.db).status, 'closed');
  assert.equal(queuedCount(w.db), 1);
  const noDev = world(); noDev.db.prepare("delete from device_state where key = 'fiscal_device'").run();
  noDev.sale(T0, [[noDev.bread, 1000]], [noDev.cash('USD', 150)]);
  assert.equal((await sendQueued(noDev.db, noDev.ctx(), gw, fakeSigner, RUN)).stopped, 'no_device');
  const off = world({ fiscal: false });
  assert.equal((await sendQueued(off.db, off.ctx(), gw, fakeSigner, RUN)).stopped, 'disabled');
});

test('a return becomes a credit note that points at the original receipt, with negative amounts and the reason', async () => {
  const w = world();
  const a = w.sale(T0, [[w.bread, 4000]], [w.cash('USD', 600)]);
  const gw = new FakeGateway();
  await sendQueued(w.db, w.ctx(T0 + 1000), gw, fakeSigner, RUN);
  const line = returnableLines(w.db, a.sale_id)[0]!;
  processReturn(w.db, w.ctx(T0 + 2000), { sale_id: a.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }], reason: 'Stale', payouts: [w.cash('USD', 150)] }, uid);
  assert.equal(queuedCount(w.db), 1);
  const r = await sendQueued(w.db, w.ctx(T0 + 3000), gw, fakeSigner, RUN);
  assert.equal(r.sent, 1);
  const cn = gw.receipts[1]!;
  assert.equal(cn.receiptType, 'CreditNote');
  assert.equal(cn.receiptNotes, 'Stale');
  assert.deepEqual(cn.creditDebitNote, { receiptID: 5001 });
  assert.equal(cn.receiptTotal, -1.5);
  assert.deepEqual(cn.receiptLines.map((l) => l.receiptLineTotal), [-1.5]);
  assert.deepEqual(cn.receiptTaxes.map((t) => [t.taxID, t.salesAmountWithTax, t.taxAmount]), [[3, -1.5, -0.2]]);
  assert.deepEqual(cn.receiptPayments, [{ moneyTypeCode: 'Cash', paymentAmount: -1.5 }]);
  assert.deepEqual([cn.receiptCounter, cn.receiptGlobalNo], [2, 2]);
});

test('a void is a credit note of the whole sale; a return of a sale made before fiscalisation was on fails clearly', async () => {
  const w = world();
  const a = w.sale(T0, [[w.bread, 2000]], [w.cash('USD', 300)]);
  const gw = new FakeGateway();
  await sendQueued(w.db, w.ctx(T0 + 1000), gw, fakeSigner, RUN);
  voidSale(w.db, w.ctx(T0 + 2000), { sale_id: a.sale_id, reason: 'Wrong item', payouts: [w.cash('USD', 300)] }, uid);
  await sendQueued(w.db, w.ctx(T0 + 3000), gw, fakeSigner, RUN);
  assert.equal(gw.receipts[1]!.receiptTotal, -3);
  assert.equal(gw.receipts[1]!.receiptNotes, 'Wrong item');

  const old = world({ fiscal: false });
  const b = old.sale(T0, [[old.bread, 1000]], [old.cash('USD', 150)]);
  setEnabled(old.db, old.base, true, uid);
  const line = returnableLines(old.db, b.sale_id)[0]!;
  processReturn(old.db, old.ctx(T0 + 500), { sale_id: b.sale_id, items: [{ sale_line_id: line.sale_line_id, qty_milli: 1000 }], reason: 'x', payouts: [old.cash('USD', 150)] }, uid);
  const r = await sendQueued(old.db, old.ctx(T0 + 1000), new FakeGateway(), fakeSigner, RUN);
  assert.equal(r.failed, 1);
  assert.equal(r.problems[0]!.code, 'original_not_fiscalised');
});

test('a layby waits until the goods are collected and does not stop the day from closing', async () => {
  const w = world();
  const c = saveCustomer(w.db, w.base, { name: 'Mai Tendai', phone: '0772 111 222' }, uid);
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 50)], { layby: true, customer_id: c });
  w.sale(T0 + 1000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  const gw = new FakeGateway();
  const r = await sendQueued(w.db, w.ctx(T0 + 2000), gw, fakeSigner, RUN);
  assert.equal(r.sent, 1, 'the ordinary sale still goes');
  assert.equal(gw.receipts.length, 1);
  assert.equal(queuedCount(w.db), 0, 'the layby is parked, not counted as waiting');
  assert.equal(canCloseDay(w.db).ok, true);
  assert.equal(listQueue(w.db, 'queued')[0]!.payload.deferred, 'layby_not_collected');
});

test('day counters: sales and credit notes by tax and money type, zero values left out, in a fixed order', () => {
  const mk = (type: 'FiscalInvoice' | 'CreditNote', sales: number, tax: number, pay: [any, number][]): Receipt => ({
    receiptType: type, receiptCurrency: 'USD', receiptCounter: 1, receiptGlobalNo: 1, invoiceNo: 'x', receiptDate: '', receiptLinesTaxInclusive: true, receiptLines: [],
    receiptTaxes: [{ taxID: 3, taxPercent: 15, taxAmount: tax, salesAmountWithTax: sales }, { taxID: 2, taxPercent: 0, taxAmount: 0, salesAmountWithTax: 0 }],
    receiptPayments: pay.map(([moneyTypeCode, paymentAmount]) => ({ moneyTypeCode, paymentAmount })), receiptTotal: sales, receiptPrintForm: 'Receipt48',
  });
  const c = dayCounters([mk('FiscalInvoice', 6, 0.78, [['Cash', 4], ['MobileWallet', 2]]), mk('FiscalInvoice', 3, 0.39, [['Cash', 3]]), mk('CreditNote', -1.5, -0.2, [['Cash', -1.5]])]);
  const flat = (x: DayCounter) => [x.fiscalCounterType, x.fiscalCounterTaxID ?? x.fiscalCounterMoneyType, x.fiscalCounterValue];
  assert.deepEqual(c.map(flat), [
    ['SaleByTax', 3, 9], ['CreditNoteByTax', 3, -1.5], ['SaleTaxByTax', 3, 1.17], ['CreditNoteTaxByTax', 3, -0.2],
    ['BalanceByMoneyType', 'Cash', 5.5], ['BalanceByMoneyType', 'MobileWallet', 2],
  ]);
});

test('closing the day: blocked while anything is waiting or marked by ZIMRA; sends the counters and signature; a refused close can be retried; the next day restarts the counter', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 4000]], [w.cash('USD', 600)]);
  w.sale(T0 + 1000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  const gw = new FakeGateway();
  assert.match((await closeDay(w.db, w.ctx(), gw, fakeSigner)).message, /no open fiscal day|waiting/);
  gw.colors = (r) => (r.invoiceNo.endsWith('2') ? [{ validationErrorCode: 'RCPT022', validationErrorColor: 'Red' }] : undefined);
  await sendQueued(w.db, w.ctx(T0 + 2000), gw, fakeSigner, RUN);
  const blocked = await closeDay(w.db, w.ctx(T0 + 3000), gw, fakeSigner);
  assert.equal(blocked.ok, false);
  assert.match(blocked.message, /marked by ZIMRA/);
  assert.equal(gw.closed.length, 0);

  const w2 = world();
  w2.sale(T0, [[w2.bread, 4000]], [w2.cash('USD', 600)]);
  w2.sale(T0 + 1000, [[w2.milk, 1000]], [w2.cash('USD', 200)]);
  const g2 = new FakeGateway();
  await sendQueued(w2.db, w2.ctx(T0 + 2000), g2, fakeSigner, RUN);
  g2.closeAnswer = { ok: false, errors: ['CountersMismatch'] };
  const refused = await closeDay(w2.db, w2.ctx(T0 + 3000), g2, fakeSigner);
  assert.deepEqual([refused.ok, getState(w2.db).status], [false, 'close_failed']);
  assert.match(getState(w2.db).last_close_error!, /CountersMismatch/);
  g2.closeAnswer = { ok: true };
  const done = await closeDay(w2.db, w2.ctx(T0 + 4000), g2, fakeSigner);
  assert.equal(done.ok, true);
  const req = g2.closed[1];
  assert.equal(req.fiscalDayNo, 100);
  assert.equal(req.receiptCounter, 2);
  assert.deepEqual(req.fiscalDayCounters.map((c: DayCounter) => [c.fiscalCounterType, c.fiscalCounterValue]), [['SaleByTax', 2], ['SaleByTax', 6], ['SaleTaxByTax', 0.78], ['BalanceByMoneyType', 8]]);
  assert.equal(getState(w2.db).status, 'closed');
  // next day
  w2.sale(T0 + 86_400_000, [[w2.salt, 1000]], [w2.cash('USD', 100)]);
  await sendQueued(w2.db, w2.ctx(T0 + 86_400_000 + 1000), g2, fakeSigner, RUN);
  const last = g2.receipts.at(-1)!;
  assert.deepEqual([last.receiptCounter, last.receiptGlobalNo], [1, 3], 'the day counter restarts, the global number keeps counting');
  assert.equal(getState(w2.db).day_no, 101);
  assert.equal(last.receiptDeviceSignature!.hash, fakeSigner.signReceipt({ ...last, receiptDeviceSignature: undefined } as any, null).hash, 'a new day starts a new hash chain');
});

test('a day open longer than ZIMRA allows is flagged so the shop closes it', async () => {
  const w = world();
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  const gw = new FakeGateway();
  await sendQueued(w.db, w.ctx(T0), gw, fakeSigner, { ...RUN, day_max_hrs: 24 });
  w.sale(T0 + 30 * 3_600_000, [[w.milk, 1000]], [w.cash('USD', 200)]);
  const r = await sendQueued(w.db, w.ctx(T0 + 30 * 3_600_000), gw, fakeSigner, { ...RUN, day_max_hrs: 24 });
  assert.equal(r.day_too_long, true);
});

test('device and set-up checks', () => {
  const w = world();
  assert.deepEqual(getDevice(w.db)!.device_id, 187);
  assert.throws(() => saveDevice(w.db, T0, { device_id: 0, serial: 'x' }), /device ID/);
  assert.throws(() => saveDevice(w.db, T0, { device_id: 5, serial: ' ' }), /serial/);
  w.sale(T0, [[w.bread, 1000]], [w.cash('USD', 150)]);
  assert.throws(() => saveDevice(w.db, T0, { device_id: 188, serial: 'SN-2' }), /Close the fiscal day/, 'cannot swap the device while receipts wait');
  assert.throws(() => saveTaxSetup(w.db, w.base, { map: { nope: 3 } }, uid), /does not exist/);
  assert.throws(() => saveTaxSetup(w.db, w.base, { map: { [w.cls('Standard rated')]: 99 } }, uid), /not one of ZIMRA/);
  assert.throws(() => saveTaxSetup(w.db, w.base, { hs_default: 'abc' }, uid), /HS code/);
  assert.equal(zimraDate(Date.UTC(2026, 10, 2, 22, 30, 5), 120), '2026-11-03T00:30:05');
});
