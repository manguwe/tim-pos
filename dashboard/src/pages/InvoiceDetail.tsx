import { useState } from 'react';
import { api, type InvoiceDetail as Inv, type InvoicePayment, type PayMethod } from '../api.ts';
import { METHOD_LABEL, NEEDS_REFERENCE, countryName, fmtDate, isoOf, money, newRequestId, parseMoney, dayStart, pct, plainAmount, todayIso } from '../format.ts';
import { Link } from '../router.tsx';
import { Badge, Button, ErrorBox, Field, FormModal, InvoiceBadge, Loading, Page, useAsync, useToast } from '../ui.tsx';

function Letterhead({ inv }: { inv: Inv }) {
  const p = inv.profile;
  return (
    <div className="letterhead">
      {p.logo && <img className="logo" src={p.logo} alt="" />}
      <div>
        <div className="biz">{p.business_name || 'Your business name'}</div>
        {p.address && <div className="pre">{p.address}</div>}
        {(p.phone || p.email) && <div>{[p.phone, p.email].filter(Boolean).join(' · ')}</div>}
        {p.tax_number && <div>Tax number: {p.tax_number}</div>}
      </div>
    </div>
  );
}

export function InvoiceDetail({ id }: { id: string }) {
  const q = useAsync(() => api<Inv>('GET', `/invoices/${id}`), [id]);
  const toast = useToast();
  const [dlg, setDlg] = useState<'pay' | 'void' | { reverse: InvoicePayment } | null>(null);
  const inv = q.data;
  if (q.error && !inv) return <Page title="Invoice"><ErrorBox error={q.error} retry={q.reload} /><p><Link to="/invoices">Back to invoices</Link></p></Page>;
  if (!inv) return <Page title="Invoice"><Loading /></Page>;
  const done = (msg: string) => { setDlg(null); toast(msg); q.reload(); };
  const live = inv.payments.filter((p) => !p.reversed_at);

  return (
    <Page
      title={inv.number}
      actions={<>
        <Button onClick={() => window.print()}>Print or save as PDF</Button>
        {inv.state !== 'void' && inv.balance_minor > 0 && <Button kind="primary" onClick={() => setDlg('pay')}>Record payment</Button>}
        {inv.state !== 'void' && live.length === 0 && <Button kind="danger" onClick={() => setDlg('void')}>Void</Button>}
      </>}
    >
      <p className="crumbs noprint"><Link to="/invoices">Invoices</Link> / {inv.number}</p>
      <article className={`sheet${inv.state === 'void' ? ' is-void' : ''}`}>
        {inv.state === 'void' && <div className="stamp">VOID</div>}
        <div className="sheet-top">
          <Letterhead inv={inv} />
          <div className="sheet-meta">
            <div className="sheet-title">INVOICE</div>
            <dl>
              <div><dt>Number</dt><dd>{inv.number}</dd></div>
              <div><dt>Issued</dt><dd>{fmtDate(inv.issued_at)}</dd></div>
              <div><dt>Due</dt><dd>{fmtDate(inv.due_at)}</dd></div>
            </dl>
          </div>
        </div>
        <div className="billto"><div className="k">Bill to</div><strong><Link to={`/shops/${inv.tenant.id}`}>{inv.tenant.name}</Link></strong><div>{countryName(inv.tenant.country_code)}</div>{inv.tenant.contact && <div>{inv.tenant.contact}</div>}</div>
        <table className="sheet-table">
          <thead><tr><th>Description</th><th className="num">Qty</th><th className="num">Unit price</th><th className="num">Amount</th></tr></thead>
          <tbody>{inv.lines.map((l) => <tr key={l.id}><td>{l.description}</td><td className="num">{l.quantity}</td><td className="num">{money(l.unit_price_minor, inv.currency)}</td><td className="num">{money(l.line_total_minor, inv.currency)}</td></tr>)}</tbody>
        </table>
        <div className="sheet-totals">
          <div><span>Subtotal</span><span>{money(inv.subtotal_minor, inv.currency)}</span></div>
          {inv.tax_minor > 0 && <div><span>Tax ({pct(inv.tax_bp)})</span><span>{money(inv.tax_minor, inv.currency)}</span></div>}
          <div className="grand"><span>Total</span><span>{money(inv.total_minor, inv.currency)}</span></div>
          {live.length > 0 && <div><span>Paid</span><span>− {money(inv.paid_minor, inv.currency)}</span></div>}
          <div className="grand due"><span>Balance due</span><span>{money(inv.balance_minor, inv.currency)}</span></div>
        </div>
        <div className="sheet-status"><InvoiceBadge state={inv.state} overdue={inv.overdue} /></div>
        {inv.state === 'void' && <p className="muted">Voided {fmtDate(inv.voided_at)}: {inv.void_reason}</p>}
        {inv.notes && <p className="pre">{inv.notes}</p>}
        {inv.state !== 'void' && inv.balance_minor > 0 && inv.profile.payment_instructions && (
          <div className="how-to-pay"><div className="k">How to pay</div><div className="pre">{inv.profile.payment_instructions}</div></div>
        )}
        {inv.profile.footer && <p className="foot-note">{inv.profile.footer}</p>}
      </article>

      <h2 className="section noprint">Payments</h2>
      {inv.payments.length === 0 ? <div className="empty noprint">No payment recorded yet.</div> : (
        <div className="card flush scroll-x noprint"><table>
          <thead><tr><th>Receipt</th><th>Received</th><th>Method</th><th className="num">Amount</th><th>Recorded by</th><th /></tr></thead>
          <tbody>{inv.payments.map((p) => (
            <tr key={p.id} className={p.reversed_at ? 'dim' : ''}>
              <td><Link to={`/invoices/${inv.id}/receipt/${p.id}`}>{p.receipt_no}</Link></td>
              <td>{fmtDate(p.received_at)}</td>
              <td>{METHOD_LABEL[p.method] ?? p.method}{p.reference && <div className="muted small">{p.reference}</div>}{p.note && <div className="muted small">{p.note}</div>}
                {p.extended_months && <div className="small">Licence extended {p.extended_months} month{p.extended_months === 1 ? '' : 's'}</div>}</td>
              <td className="num">{money(p.amount_minor, inv.currency)}</td>
              <td>{p.recorded_by ?? '—'}</td>
              <td className="right">{p.reversed_at ? <Badge tone="off">Reversed: {p.reverse_reason}</Badge> : <Button small onClick={() => setDlg({ reverse: p })}>Reverse</Button>}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}

      {dlg === 'pay' && <RecordPayment inv={inv} onClose={() => setDlg(null)} onDone={(r) => done(`Payment recorded. Receipt ${r}.`)} />}
      {dlg === 'void' && (
        <FormModal title="Void this invoice?" submit="Void invoice" danger onClose={() => setDlg(null)} onSubmit={async () => { await api('POST', `/invoices/${inv.id}/void`, { reason }); done('Invoice voided.'); }}>
          <p>A voided invoice stays on record but no longer counts as owed. Use it for a mistake; the number is not reused.</p>
          <VoidReason onChange={(v) => { reason = v; }} />
        </FormModal>
      )}
      {dlg && typeof dlg === 'object' && (
        <FormModal title={`Reverse receipt ${dlg.reverse.receipt_no}?`} submit="Reverse payment" danger onClose={() => setDlg(null)} onSubmit={async () => { await api('POST', `/payments/${(dlg as { reverse: InvoicePayment }).reverse.id}/reverse`, { reason }); done('Payment reversed.'); }}>
          <p>The {money(dlg.reverse.amount_minor, inv.currency)} goes back onto the balance. The receipt stays on record, marked reversed.{dlg.reverse.extended_months ? ' This payment also extended the licence; reversing it does not shorten the licence. Change that on the shop page if needed.' : ''}</p>
          <VoidReason onChange={(v) => { reason = v; }} label="Why is it being reversed?" />
        </FormModal>
      )}
    </Page>
  );
}

let reason = '';
function VoidReason({ onChange, label = 'Reason' }: { onChange: (v: string) => void; label?: string }) {
  const [v, setV] = useState('');
  reason = v;
  return <Field label={label}>{(id) => <input id={id} required minLength={3} maxLength={300} value={v} onChange={(e) => { setV(e.target.value); onChange(e.target.value); }} />}</Field>;
}

function RecordPayment({ inv, onClose, onDone }: { inv: Inv; onClose: () => void; onDone: (receipt: string) => void }) {
  const [requestId] = useState(newRequestId);
  const [amount, setAmount] = useState(plainAmount(inv.balance_minor));
  const [method, setMethod] = useState<PayMethod>('cash');
  const [ref, setRef] = useState('');
  const [date, setDate] = useState(todayIso());
  const [note, setNote] = useState('');
  const [extend, setExtend] = useState(false);
  const [licence, setLicence] = useState(inv.licences[0]?.id ?? '');
  const [months, setMonths] = useState(String(inv.lines.filter((l) => l.kind === 'monthly').reduce((s, l) => s + l.quantity, 0) || 1));
  return (
    <FormModal
      title="Record payment"
      submit="Record payment"
      wide
      onClose={onClose}
      onSubmit={async () => {
        const minor = parseMoney(amount);
        if (minor === null || minor <= 0) throw new Error('Enter the amount, like 25 or 25.50.');
        if (minor > inv.balance_minor) throw new Error(`That is more than the balance (${money(inv.balance_minor, inv.currency)}).`);
        const at = dayStart(date);
        const body: Record<string, unknown> = { amount_minor: minor, method, request_id: requestId, ...(ref.trim() ? { reference: ref.trim() } : {}), ...(note.trim() ? { note: note.trim() } : {}), ...(at ? { received_at: Math.min(at, Date.now()) } : {}) };
        if (extend) {
          const n = Number(months);
          if (!licence) throw new Error('Choose the licence to extend.');
          if (!Number.isInteger(n) || n < 1 || n > 120) throw new Error('Months to extend must be a whole number from 1 to 120.');
          body.extend_licence = { licence_id: licence, months: n };
        }
        const r = await api<{ payment: { receipt_no: string } }>('POST', `/invoices/${inv.id}/payments`, body);
        onDone(r.payment.receipt_no);
      }}
    >
      <p className="muted">Balance due: <strong>{money(inv.balance_minor, inv.currency)}</strong>. A part payment is fine.</p>
      <div className="grid2">
        <Field label={`Amount (${inv.currency})`}>{(id) => <input id={id} inputMode="decimal" required value={amount} onChange={(e) => setAmount(e.target.value)} />}</Field>
        <Field label="Date received">{(id) => <input id={id} type="date" required max={todayIso()} min={isoOf(inv.issued_at - 30 * 86_400_000)} value={date} onChange={(e) => setDate(e.target.value)} />}</Field>
        <Field label="Paid by">
          {(id) => <select id={id} value={method} onChange={(e) => setMethod(e.target.value as PayMethod)}>{Object.entries(METHOD_LABEL).map(([v, l]) => <option key={v} value={v}>{l}</option>)}</select>}
        </Field>
        <Field label="Reference" hint={NEEDS_REFERENCE.has(method) ? 'Required: the transaction or receipt number.' : 'Optional.'}>
          {(id) => <input id={id} maxLength={100} required={NEEDS_REFERENCE.has(method)} value={ref} onChange={(e) => setRef(e.target.value)} />}
        </Field>
      </div>
      <Field label="Note (optional)">{(id) => <input id={id} maxLength={500} value={note} onChange={(e) => setNote(e.target.value)} />}</Field>
      {inv.licences.length > 0 && (
        <fieldset className="field">
          <label className="check"><input type="checkbox" checked={extend} onChange={(e) => setExtend(e.target.checked)} /> Also extend the shop's licence</label>
          {extend && (
            <div className="grid2">
              <select aria-label="Licence" value={licence} onChange={(e) => setLicence(e.target.value)}>
                {inv.licences.map((l) => <option key={l.id} value={l.id}>Key ending {l.key_hint}, ends {fmtDate(l.expires_at)}</option>)}
              </select>
              <input aria-label="Months to extend" type="number" min={1} max={120} value={months} onChange={(e) => setMonths(e.target.value)} />
            </div>
          )}
        </fieldset>
      )}
    </FormModal>
  );
}

export function Receipt({ invoiceId, paymentId }: { invoiceId: string; paymentId: string }) {
  const q = useAsync(() => api<Inv>('GET', `/invoices/${invoiceId}`), [invoiceId]);
  const inv = q.data;
  if (q.error && !inv) return <Page title="Receipt"><ErrorBox error={q.error} retry={q.reload} /></Page>;
  if (!inv) return <Page title="Receipt"><Loading /></Page>;
  const p = inv.payments.find((x) => x.id === paymentId);
  if (!p) return <Page title="Receipt"><div className="empty">That payment was not found on this invoice. <Link to={`/invoices/${invoiceId}`}>Back to the invoice</Link></div></Page>;
  return (
    <Page title={p.receipt_no} actions={<Button kind="primary" onClick={() => window.print()}>Print or save as PDF</Button>}>
      <p className="crumbs noprint"><Link to="/invoices">Invoices</Link> / <Link to={`/invoices/${inv.id}`}>{inv.number}</Link> / {p.receipt_no}</p>
      <article className={`sheet${p.reversed_at ? ' is-void' : ''}`}>
        {p.reversed_at && <div className="stamp">REVERSED</div>}
        <div className="sheet-top">
          <Letterhead inv={inv} />
          <div className="sheet-meta">
            <div className="sheet-title">RECEIPT</div>
            <dl><div><dt>Receipt no.</dt><dd>{p.receipt_no}</dd></div><div><dt>Date received</dt><dd>{fmtDate(p.received_at)}</dd></div></dl>
          </div>
        </div>
        <div className="billto"><div className="k">Received from</div><strong>{inv.tenant.name}</strong></div>
        <div className="receipt-amount"><span>Amount received</span><strong>{money(p.amount_minor, inv.currency)}</strong></div>
        <dl className="dl">
          <div><dt>For invoice</dt><dd>{inv.number}</dd></div>
          <div><dt>Paid by</dt><dd>{METHOD_LABEL[p.method] ?? p.method}</dd></div>
          {p.reference && <div><dt>Reference</dt><dd>{p.reference}</dd></div>}
          <div><dt>Invoice total</dt><dd>{money(inv.total_minor, inv.currency)}</dd></div>
          <div><dt>Balance after this payment</dt><dd>{money(Math.max(0, inv.total_minor - inv.payments.filter((x) => !x.reversed_at && (x.received_at < p.received_at || (x.received_at === p.received_at && x.created_at <= p.created_at))).reduce((s, x) => s + x.amount_minor, 0)), inv.currency)}</dd></div>
        </dl>
        {p.note && <p>{p.note}</p>}
        {p.reversed_at && <p className="muted">Reversed {fmtDate(p.reversed_at)}: {p.reverse_reason}</p>}
        {inv.profile.footer && <p className="foot-note">{inv.profile.footer}</p>}
      </article>
    </Page>
  );
}
