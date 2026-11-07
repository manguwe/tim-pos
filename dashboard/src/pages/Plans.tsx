import { useState } from 'react';
import { api, type Plan } from '../api.ts';
import { money, parseMoney, splitList } from '../format.ts';
import { Button, Empty, ErrorBox, Field, FormModal, Loading, Page, useAsync, useToast } from '../ui.tsx';

export function Plans() {
  const list = useAsync(() => api<{ plans: Plan[] }>('GET', '/plans'), []);
  const [open, setOpen] = useState(false);
  const toast = useToast();
  return (
    <Page title="Plans" actions={<Button kind="primary" onClick={() => setOpen(true)}>New plan</Button>}>
      <p className="muted">A plan is a price and a set of limits. Issuing a licence from a plan fills in its limits; the price is for your records until invoices are built.</p>
      {list.error && <ErrorBox error={list.error} retry={list.reload} />}
      {!list.data && !list.error && <Loading />}
      {list.data && list.data.plans.length === 0 && <Empty>No plans yet.</Empty>}
      {list.data && list.data.plans.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Plan</th><th className="num">Once-off fee</th><th className="num">Monthly fee</th><th className="num">Phones</th><th className="num">Branches</th><th>Features</th></tr></thead>
          <tbody>{list.data.plans.map((p) => (
            <tr key={p.id}><td>{p.name}</td><td className="num">{money(p.one_time_fee_minor, p.currency)}</td><td className="num">{money(p.monthly_fee_minor, p.currency)}</td><td className="num">{p.max_devices}</td><td className="num">{p.max_branches}</td><td>{p.features.join(', ') || '—'}</td></tr>
          ))}</tbody>
        </table></div>
      )}
      {open && <NewPlan onClose={() => setOpen(false)} onDone={() => { setOpen(false); toast('Plan created.'); list.reload(); }} />}
    </Page>
  );
}

function NewPlan({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [name, setName] = useState('');
  const [currency, setCurrency] = useState('USD');
  const [once, setOnce] = useState('0');
  const [monthly, setMonthly] = useState('0');
  const [devices, setDevices] = useState('1');
  const [branches, setBranches] = useState('1');
  const [features, setFeatures] = useState('');
  return (
    <FormModal title="New plan" submit="Create plan" wide onClose={onClose}
      onSubmit={async () => {
        const o = parseMoney(once), m = parseMoney(monthly);
        if (o === null || m === null) throw new Error('Fees must be amounts like 25 or 25.50.');
        await api('POST', '/plans', { name, currency, one_time_fee_minor: o, monthly_fee_minor: m, max_devices: Number(devices), max_branches: Number(branches), features: splitList(features) });
        onDone();
      }}>
      <Field label="Plan name">{(id) => <input id={id} required maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
      <div className="grid2">
        <Field label="Currency">{(id) => <input id={id} required minLength={3} maxLength={3} value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} />}</Field>
        <span />
        <Field label="Once-off fee">{(id) => <input id={id} inputMode="decimal" required value={once} onChange={(e) => setOnce(e.target.value)} />}</Field>
        <Field label="Monthly fee">{(id) => <input id={id} inputMode="decimal" required value={monthly} onChange={(e) => setMonthly(e.target.value)} />}</Field>
        <Field label="Phones">{(id) => <input id={id} type="number" min={1} max={1000} required value={devices} onChange={(e) => setDevices(e.target.value)} />}</Field>
        <Field label="Branches">{(id) => <input id={id} type="number" min={1} max={1000} required value={branches} onChange={(e) => setBranches(e.target.value)} />}</Field>
      </div>
      <Field label="Features" hint="Comma separated, for example zimra, loyalty.">{(id) => <input id={id} value={features} onChange={(e) => setFeatures(e.target.value)} />}</Field>
    </FormModal>
  );
}
