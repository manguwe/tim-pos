import { useState } from 'react';
import { api, type FeatureInfo, type Plan } from '../api.ts';
import { money, parseMoney } from '../format.ts';
import { Button, Empty, ErrorBox, Field, FormModal, Loading, Page, useAsync, useToast } from '../ui.tsx';
import { FeaturePicker } from './FeaturePicker.tsx';

export function Plans() {
  const list = useAsync(() => api<{ plans: Plan[] }>('GET', '/plans'), []);
  const feats = useAsync(() => api<{ features: FeatureInfo[] }>('GET', '/features'), []);
  const [dlg, setDlg] = useState<'new' | Plan | null>(null);
  const toast = useToast();
  const label = (k: string) => feats.data?.features.find((f) => f.key === k)?.label ?? k;
  return (
    <Page title="Plans" actions={<>
      <Button onClick={async () => { const r = await api<{ added: string[] }>('POST', '/plans/suggested', {}); toast(r.added.length ? `Added ${r.added.join(', ')}. Edit the prices to suit you.` : 'The suggested plans are already there.'); list.reload(); }}>Add suggested plans</Button>
      <Button kind="primary" onClick={() => setDlg('new')}>New plan</Button>
    </>}>
      <p className="muted">A plan is a price plus what the shop gets: phones, branches, staff and features. Tick the features here. Change a plan and every shop on it gets the change the next time its phones connect. Moving a shop to another plan is done on the shop's page.</p>
      {list.error && <ErrorBox error={list.error} retry={list.reload} />}
      {!list.data && !list.error && <Loading />}
      {list.data && list.data.plans.length === 0 && <Empty>No plans yet. Press "Add suggested plans" for Starter, Business and Premium, then change them as you like.</Empty>}
      <div className="plan-grid">
        {(list.data?.plans ?? []).map((p) => (
          <div className="card" key={p.id}>
            <div className="row between"><h3 style={{ margin: 0 }}>{p.name}</h3><Button small onClick={() => setDlg(p)}>Edit</Button></div>
            {p.description && <p className="muted">{p.description}</p>}
            <div className="plan-price">{money(p.monthly_fee_minor, p.currency)} <span className="muted small">per month</span></div>
            {p.one_time_fee_minor > 0 && <div className="muted small">Plus {money(p.one_time_fee_minor, p.currency)} once-off</div>}
            <ul className="plan-list">
              <li>{p.max_devices} phone(s), {p.max_branches} branch(es)</li>
              <li>{p.max_users === 0 ? 'Any number of staff' : `Up to ${p.max_users} staff`}</li>
              {p.features.length === 0 ? <li className="muted">Selling, stock and reports only</li> : p.features.map((f) => <li key={f}>{label(f)}</li>)}
            </ul>
          </div>
        ))}
      </div>
      {dlg && <PlanForm plan={dlg === 'new' ? null : dlg} onClose={() => setDlg(null)} onDone={(m) => { setDlg(null); toast(m); list.reload(); }} />}
    </Page>
  );
}

function PlanForm({ plan, onClose, onDone }: { plan: Plan | null; onClose: () => void; onDone: (m: string) => void }) {
  const plain = (minor: number) => (minor / 100).toFixed(2);
  const [name, setName] = useState(plan?.name ?? '');
  const [desc, setDesc] = useState(plan?.description ?? '');
  const [currency, setCurrency] = useState(plan?.currency ?? 'USD');
  const [once, setOnce] = useState(plan ? plain(plan.one_time_fee_minor) : '0');
  const [monthly, setMonthly] = useState(plan ? plain(plan.monthly_fee_minor) : '0');
  const [devices, setDevices] = useState(String(plan?.max_devices ?? 1));
  const [branches, setBranches] = useState(String(plan?.max_branches ?? 1));
  const [users, setUsers] = useState(String(plan?.max_users ?? 0));
  const [features, setFeatures] = useState<string[]>(plan?.features ?? []);
  const [apply, setApply] = useState(true);
  return (
    <FormModal title={plan ? `Edit ${plan.name}` : 'New plan'} submit={plan ? 'Save plan' : 'Create plan'} wide onClose={onClose}
      onSubmit={async () => {
        const o = parseMoney(once), m = parseMoney(monthly);
        if (o === null || m === null) throw new Error('Fees must be amounts like 25 or 25.50.');
        const body = { name, description: desc, currency, one_time_fee_minor: o, monthly_fee_minor: m, max_devices: Number(devices), max_branches: Number(branches), max_users: Number(users), features };
        if (plan) {
          const r = await api<{ licences_updated: number }>('PATCH', `/plans/${plan.id}`, { ...body, apply_to_shops: apply });
          onDone(r.licences_updated ? `Plan saved. ${r.licences_updated} licence(s) updated.` : 'Plan saved.');
        } else {
          await api('POST', '/plans', body);
          onDone('Plan created.');
        }
      }}>
      <Field label="Plan name">{(id) => <input id={id} required maxLength={80} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
      <Field label="Short description" hint="One line you can show to shop owners.">{(id) => <input id={id} maxLength={300} value={desc} onChange={(e) => setDesc(e.target.value)} />}</Field>
      <div className="grid2">
        <Field label="Currency">{(id) => <input id={id} required minLength={3} maxLength={3} value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())} />}</Field>
        <span />
        <Field label="Once-off fee">{(id) => <input id={id} inputMode="decimal" required value={once} onChange={(e) => setOnce(e.target.value)} />}</Field>
        <Field label="Monthly fee">{(id) => <input id={id} inputMode="decimal" required value={monthly} onChange={(e) => setMonthly(e.target.value)} />}</Field>
        <Field label="Phones">{(id) => <input id={id} type="number" min={1} max={1000} required value={devices} onChange={(e) => setDevices(e.target.value)} />}</Field>
        <Field label="Branches">{(id) => <input id={id} type="number" min={1} max={1000} required value={branches} onChange={(e) => setBranches(e.target.value)} />}</Field>
        <Field label="Staff who can sign in" hint="0 means any number.">{(id) => <input id={id} type="number" min={0} max={1000} required value={users} onChange={(e) => setUsers(e.target.value)} />}</Field>
      </div>
      <FeaturePicker value={features} onChange={setFeatures} />
      {plan && <label className="check"><input type="checkbox" checked={apply} onChange={(e) => setApply(e.target.checked)} /> Also update the shops already on this plan</label>}
    </FormModal>
  );
}
