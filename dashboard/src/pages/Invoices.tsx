import { useMemo, useState } from 'react';
import { api, type Invoice, type PaymentRow, type RunResult } from '../api.ts';
import { METHOD_LABEL, fmtDate, money, monthOf } from '../format.ts';
import { Link } from '../router.tsx';
import { Button, Empty, ErrorBox, Field, FormModal, InvoiceBadge, Loading, Page, useAsync, useToast } from '../ui.tsx';
import { NewInvoice } from './NewInvoice.tsx';

type Tab = 'invoices' | 'payments';
const FILTERS = [['open', 'Unpaid'], ['overdue', 'Overdue'], ['paid', 'Paid'], ['void', 'Void'], ['all', 'All']] as const;

export function Invoices() {
  const [tab, setTab] = useState<Tab>('invoices');
  const [status, setStatus] = useState<(typeof FILTERS)[number][0]>('open');
  const [q, setQ] = useState('');
  const [creating, setCreating] = useState(false);
  const [running, setRunning] = useState(false);
  const inv = useAsync(() => api<{ invoices: Invoice[] }>('GET', `/invoices?status=${status}`), [status]);
  const pay = useAsync(() => api<{ payments: PaymentRow[] }>('GET', '/payments?limit=200'), []);
  const needle = q.trim().toLowerCase();
  const invRows = useMemo(() => (inv.data?.invoices ?? []).filter((i) => !needle || `${i.number} ${i.tenant_name}`.toLowerCase().includes(needle)), [inv.data, needle]);
  const payRows = useMemo(() => (pay.data?.payments ?? []).filter((p) => !needle || `${p.receipt_no} ${p.invoice_number} ${p.tenant_name} ${p.reference ?? ''}`.toLowerCase().includes(needle)), [pay.data, needle]);

  return (
    <Page title="Invoices and payments" actions={<><Button onClick={() => setRunning(true)}>Run monthly billing</Button><Button kind="primary" onClick={() => setCreating(true)}>New invoice</Button></>}>
      <div className="tabs" role="tablist">
        <button role="tab" aria-selected={tab === 'invoices'} className={tab === 'invoices' ? 'on' : ''} onClick={() => setTab('invoices')}>Invoices</button>
        <button role="tab" aria-selected={tab === 'payments'} className={tab === 'payments' ? 'on' : ''} onClick={() => setTab('payments')}>Payments received</button>
      </div>
      <div className="toolbar">
        <input type="search" placeholder={tab === 'invoices' ? 'Search by number or shop' : 'Search by receipt, invoice, shop or reference'} aria-label="Search" value={q} onChange={(e) => setQ(e.target.value)} />
        {tab === 'invoices' && (
          <select aria-label="Show" value={status} onChange={(e) => setStatus(e.target.value as typeof status)}>
            {FILTERS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
          </select>
        )}
      </div>

      {tab === 'invoices' && (
        <>
          {inv.error && <ErrorBox error={inv.error} retry={inv.reload} />}
          {!inv.data && !inv.error && <Loading />}
          {inv.data && invRows.length === 0 && <Empty>{status === 'open' ? 'Nothing is waiting to be paid.' : 'No invoices match.'}</Empty>}
          {invRows.length > 0 && (
            <div className="card flush scroll-x"><table>
              <thead><tr><th>Invoice</th><th>Shop</th><th>Issued</th><th>Due</th><th>Status</th><th className="num">Total</th><th className="num">Balance</th></tr></thead>
              <tbody>{invRows.map((i) => (
                <tr key={i.id}>
                  <td><Link to={`/invoices/${i.id}`}>{i.number}</Link></td>
                  <td><Link to={`/shops/${i.tenant_id}`}>{i.tenant_name}</Link></td>
                  <td>{fmtDate(i.issued_at)}</td><td>{fmtDate(i.due_at)}</td>
                  <td><InvoiceBadge state={i.state} overdue={i.overdue} /></td>
                  <td className="num">{money(i.total_minor, i.currency)}</td>
                  <td className="num">{i.state === 'void' ? '—' : money(i.balance_minor, i.currency)}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </>
      )}

      {tab === 'payments' && (
        <>
          {pay.error && <ErrorBox error={pay.error} retry={pay.reload} />}
          {!pay.data && !pay.error && <Loading />}
          {pay.data && payRows.length === 0 && <Empty>No payments recorded yet.</Empty>}
          {payRows.length > 0 && (
            <div className="card flush scroll-x"><table>
              <thead><tr><th>Receipt</th><th>Received</th><th>Shop</th><th>Invoice</th><th>Method</th><th className="num">Amount</th></tr></thead>
              <tbody>{payRows.map((p) => (
                <tr key={p.id} className={p.reversed_at ? 'dim' : ''}>
                  <td><Link to={`/invoices/${p.invoice_id}/receipt/${p.id}`}>{p.receipt_no}</Link>{p.reversed_at && <> <span className="badge badge-off">Reversed</span></>}</td>
                  <td>{fmtDate(p.received_at)}</td>
                  <td><Link to={`/shops/${p.tenant_id}`}>{p.tenant_name}</Link></td>
                  <td><Link to={`/invoices/${p.invoice_id}`}>{p.invoice_number}</Link></td>
                  <td>{METHOD_LABEL[p.method] ?? p.method}{p.reference && <span className="muted small"> · {p.reference}</span>}</td>
                  <td className="num">{money(p.amount_minor, p.currency)}</td>
                </tr>
              ))}</tbody>
            </table></div>
          )}
        </>
      )}
      {creating && <NewInvoice onClose={() => setCreating(false)} onDone={() => { inv.reload(); }} />}
      {running && <MonthlyRun onClose={() => setRunning(false)} onDone={() => { inv.reload(); }} />}
    </Page>
  );
}

function MonthlyRun({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const toast = useToast();
  const now = new Date();
  const next = monthOf(new Date(now.getFullYear(), now.getMonth() + 1, 1).getTime());
  const [month, setMonth] = useState(monthOf(now.getTime()));
  const [preview, setPreview] = useState<RunResult | null>(null);
  const run = (dry: boolean) => api<RunResult>('POST', '/billing/run', { month, dry_run: dry });
  return (
    <FormModal
      title="Run monthly billing"
      submit={preview ? (preview.created.length === 0 ? 'Close' : `Create ${preview.created.length} invoice${preview.created.length === 1 ? '' : 's'}`) : 'Preview'}
      wide
      onClose={onClose}
      onSubmit={async () => {
        if (!preview) { setPreview(await run(true)); return; }
        if (preview.created.length === 0) { onClose(); return; }
        const r = await run(false);
        toast(`${r.created.length} invoice${r.created.length === 1 ? '' : 's'} created for ${month}.`);
        onDone();
        onClose();
      }}
    >
      <p className="muted">Creates one invoice for each shop with an active licence on a plan that has a monthly fee. A shop already billed for the month is skipped, so it is safe to run twice.</p>
      <Field label="Month" hint="This month or next month.">
        {(id) => <input id={id} type="month" required max={next} min="2024-01" value={month} onChange={(e) => { setMonth(e.target.value); setPreview(null); }} />}
      </Field>
      {preview && (
        <div className="card flush">
          {preview.created.length === 0 ? <div className="pad-in">Nothing to bill for {preview.month}{preview.already_billed ? `: ${preview.already_billed} shop(s) already billed.` : '.'}</div> : (
            <table><tbody>
              {preview.created.map((c) => <tr key={c.tenant_id}><td>{c.tenant_name}</td><td className="num">{money(c.total_minor, c.currency)}</td></tr>)}
            </tbody></table>
          )}
          {preview.already_billed > 0 && preview.created.length > 0 && <div className="pad-in muted">{preview.already_billed} shop(s) already billed for this month are skipped. Tax is added when the invoices are made.</div>}
        </div>
      )}
    </FormModal>
  );
}
