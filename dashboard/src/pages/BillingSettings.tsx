import { useEffect, useState } from 'react';
import { api, type BillingProfile } from '../api.ts';
import { Button, ErrorBox, Field, Loading, Page, errorText, useAsync, useToast } from '../ui.tsx';

export function BillingSettings() {
  const q = useAsync(() => api<BillingProfile>('GET', '/billing/profile'), []);
  const toast = useToast();
  const [f, setF] = useState<BillingProfile | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { if (q.data) setF(q.data); }, [q.data]);
  if (q.error && !f) return <Page title="Billing details"><ErrorBox error={q.error} retry={q.reload} /></Page>;
  if (!f) return <Page title="Billing details"><Loading /></Page>;
  const set = <K extends keyof BillingProfile>(k: K, v: BillingProfile[K]) => setF({ ...f, [k]: v });
  const text = (k: 'business_name' | 'address' | 'phone' | 'email' | 'tax_number' | 'payment_instructions' | 'footer') => (id: string) => (
    k === 'address' || k === 'payment_instructions'
      ? <textarea id={id} rows={3} maxLength={k === 'address' ? 300 : 1000} value={f[k]} onChange={(e) => set(k, e.target.value)} />
      : <input id={id} maxLength={k === 'footer' ? 300 : 120} value={f[k]} onChange={(e) => set(k, e.target.value)} />
  );
  return (
    <Page title="Billing details">
      <p className="muted">These appear on every invoice and receipt you print.</p>
      <form className="card form-narrow" onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true); setError(null);
        try {
          const taxBp = Math.round(Number(f.default_tax_bp));
          await api('PUT', '/billing/profile', { ...f, default_tax_bp: taxBp });
          toast('Billing details saved.'); q.reload();
        } catch (err) { setError(errorText(err)); } finally { setBusy(false); }
      }}>
        <Field label="Business name">{text('business_name')}</Field>
        <Field label="Address">{text('address')}</Field>
        <div className="grid2">
          <Field label="Phone">{text('phone')}</Field>
          <Field label="Email">{text('email')}</Field>
        </div>
        <Field label="Tax or VAT number (optional)">{text('tax_number')}</Field>
        <Field label="How to pay" hint="Printed on unpaid invoices, for example your EcoCash number or bank details.">{text('payment_instructions')}</Field>
        <Field label="Footer line">{text('footer')}</Field>
        <div className="grid2">
          <Field label="Tax added to invoices (%)" hint="0 if you do not charge tax. You can change it on each invoice.">
            {(id) => <input id={id} inputMode="decimal" value={String(f.default_tax_bp / 100)} onChange={(e) => set('default_tax_bp', Math.round(Number(e.target.value) * 100))} />}
          </Field>
          <Field label="Days to pay">{(id) => <input id={id} type="number" min={0} max={365} value={f.default_due_days} onChange={(e) => set('default_due_days', Number(e.target.value))} />}</Field>
          <Field label="Invoice number prefix" hint="Letters and digits. Numbers run per year: INV-2026-0001.">{(id) => <input id={id} maxLength={8} value={f.invoice_prefix} onChange={(e) => set('invoice_prefix', e.target.value.toUpperCase())} />}</Field>
          <Field label="Receipt number prefix">{(id) => <input id={id} maxLength={8} value={f.receipt_prefix} onChange={(e) => set('receipt_prefix', e.target.value.toUpperCase())} />}</Field>
        </div>
        {error && <div className="alert alert-bad" role="alert">{error}</div>}
        <Button type="submit" kind="primary" busy={busy}>Save</Button>
      </form>
    </Page>
  );
}
