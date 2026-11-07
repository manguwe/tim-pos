import { useState } from 'react';
import { api, type AuditEntry, type Device, type Licence, type Plan, type Statement, type ShopDetail as Shop, type OwnerLogin } from '../api.ts';
import { DAY, countryName, money, endOfDay, fmtDate, fmtTime, licenceState, mainLicence, relative, splitList, todayIso } from '../format.ts';
import { Link } from '../router.tsx';
import { NewInvoice } from './NewInvoice.tsx';
import { Badge, Button, InvoiceBadge, Empty, ErrorBox, Field, FormModal, Loading, Page, SecretModal, StateBadge, useAsync, useToast } from '../ui.tsx';

type Dialog =
  | { k: 'edit' } | { k: 'issue' } | { k: 'extend'; l: Licence } | { k: 'limits'; l: Licence }
  | { k: 'toggle'; l: Licence } | { k: 'rotate'; l: Licence } | { k: 'release'; d: Device } | { k: 'shop-status' }
  | { k: 'key'; key: string; what: string } | { k: 'invoice' } | { k: 'owner-add' } | { k: 'owner-reset'; o: OwnerLogin };

export function ShopDetail({ id }: { id: string }) {
  const shop = useAsync(() => api<Shop>('GET', `/tenants/${id}`), [id]);
  const owners = useAsync(() => api<{ owners: OwnerLogin[] }>('GET', `/tenants/${id}/owners`), [id]);
  const statement = useAsync(() => api<Statement>('GET', `/tenants/${id}/statement`), [id]);
  const activity = useAsync(async () => (await api<{ entries: AuditEntry[] }>('GET', '/audit?limit=500')).entries.filter((e) => e.tenant_id === id).slice(0, 15), [id]);
  const [dlg, setDlg] = useState<Dialog | null>(null);
  const toast = useToast();
  const s = shop.data;
  const now = Date.now();

  const done = (msg?: string) => { setDlg(null); if (msg) toast(msg); shop.reload(); activity.reload(); };

  if (shop.error && !s) return <Page title="Shop"><ErrorBox error={shop.error} retry={shop.reload} /><p><Link to="/shops">Back to shops</Link></p></Page>;
  if (!s) return <Page title="Shop"><Loading /></Page>;

  const main = mainLicence(s.licences);
  const live = s.devices.filter((d) => !d.released_at);
  const state = s.status === 'suspended' ? 'suspended' : licenceState(main?.expires_at ?? null, main?.status, main?.grace_days ?? 0, now);

  return (
    <Page
      title={s.name}
      actions={<>
        <Button onClick={() => setDlg({ k: 'edit' })}>Edit details</Button>
        <Button kind={s.status === 'active' ? 'danger' : 'primary'} onClick={() => setDlg({ k: 'shop-status' })}>{s.status === 'active' ? 'Suspend shop' : 'Resume shop'}</Button>
      </>}
    >
      <p className="crumbs"><Link to="/shops">Shops</Link> / {s.name}</p>
      {s.status === 'suspended' && <div className="alert alert-bad">This shop is suspended. Its phones cannot get new licence checks.</div>}
      <div className="card facts">
        <div><div className="k">Status</div><StateBadge state={state} /></div>
        <div><div className="k">Country</div>{countryName(s.country_code)}</div>
        <div><div className="k">Phones</div>{live.length}{main ? ` of ${main.max_devices}` : ''}</div>
        <div><div className="k">Added</div>{fmtDate(s.created_at)}</div>
        <div><div className="k">Synced changes</div>{s.sync_head_seq.toLocaleString()}</div>
        {s.contact && <div className="wide-fact"><div className="k">Contact</div>{s.contact}</div>}
        {s.notes && <div className="wide-fact"><div className="k">Notes</div><span className="pre">{s.notes}</span></div>}
      </div>

      <h2 className="section">Licences <Button small kind="primary" onClick={() => setDlg({ k: 'issue' })}>Issue licence</Button></h2>
      {s.licences.length === 0 && <Empty>No licence yet. Issue one so the shop can activate its phones.</Empty>}
      <div className="stack">
        {s.licences.map((l) => {
          const st = licenceState(l.expires_at, l.status, l.grace_days, now);
          const retired = l.key_hint === 'rotd';
          return (
            <div className="card" key={l.id}>
              <div className="row between">
                <div><strong>Key ending {retired ? '(replaced)' : l.key_hint}</strong> <StateBadge state={st} />{retired && <> <Badge tone="off">replaced by a newer key</Badge></>}</div>
                {!retired && (
                  <div className="row gap">
                    <Button small onClick={() => setDlg({ k: 'extend', l })}>Extend</Button>
                    <Button small onClick={() => setDlg({ k: 'limits', l })}>Limits</Button>
                    <Button small onClick={() => setDlg({ k: 'toggle', l })}>{l.status === 'active' ? 'Suspend' : 'Resume'}</Button>
                    <Button small onClick={() => setDlg({ k: 'rotate', l })}>New key</Button>
                  </div>
                )}
              </div>
              <dl className="dl">
                <div><dt>Ends</dt><dd>{fmtDate(l.expires_at)} <span className="muted">({relative(l.expires_at, now)})</span></dd></div>
                <div><dt>Grace after end</dt><dd>{l.grace_days} days</dd></div>
                <div><dt>Works offline for</dt><dd>{l.max_offline_days} days</dd></div>
                <div><dt>Phones / branches</dt><dd>{l.max_devices} / {l.max_branches}</dd></div>
                <div><dt>Issued</dt><dd>{fmtDate(l.issued_at)}</dd></div>
                {l.features.length > 0 && <div><dt>Features</dt><dd>{l.features.join(', ')}</dd></div>}
              </dl>
            </div>
          );
        })}
      </div>

      <h2 className="section">Phones</h2>
      {s.devices.length === 0 ? <Empty>No phone has activated yet. Give the shop its licence key to enter in the app.</Empty> : (
        <div className="card flush scroll-x">
          <table>
            <thead><tr><th>Phone</th><th>App</th><th>Activated</th><th>Last seen</th><th></th></tr></thead>
            <tbody>
              {s.devices.map((d) => {
                const stale = !d.released_at && (!d.last_seen_at || d.last_seen_at < now - 7 * DAY);
                return (
                  <tr key={d.id} className={d.released_at ? 'dim' : ''}>
                    <td>{d.device_name ?? 'Unnamed phone'} <span className="muted">{d.platform ?? ''}</span></td>
                    <td>{d.app_version ?? '—'}</td>
                    <td>{fmtDate(d.activated_at)}</td>
                    <td>{d.released_at ? <Badge tone="off">Released {fmtDate(d.released_at)}</Badge> : <>{relative(d.last_seen_at, now)} {stale && <Badge tone="warn">quiet</Badge>}</>}</td>
                    <td className="right">{!d.released_at && <Button small onClick={() => setDlg({ k: 'release', d })}>Release</Button>}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <h2 className="section">Owner logins <Button small kind="primary" onClick={() => setDlg({ k: 'owner-add' })}>Add owner login</Button></h2>
      <p className="muted small">An owner signs in at <code>/dashboard/#/owner</code> to see this shop's sales, stock and cash-ups. They see only this shop.</p>
      {owners.error && <ErrorBox error={owners.error} retry={owners.reload} />}
      {owners.data && owners.data.owners.length === 0 && <Empty>No owner login yet.</Empty>}
      {owners.data && owners.data.owners.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Name</th><th>Email</th><th>Last sign-in</th><th>Status</th><th /></tr></thead>
          <tbody>{owners.data.owners.map((o) => (
            <tr key={o.id} className={o.is_active ? '' : 'dim'}>
              <td>{o.name}</td><td>{o.email}</td><td>{o.last_login_at ? fmtTime(o.last_login_at) : 'Never'}</td>
              <td>{o.is_active ? (o.must_change_password ? <Badge tone="warn">Waiting for first sign-in</Badge> : <Badge tone="good">Active</Badge>) : <Badge tone="off">Turned off</Badge>}</td>
              <td className="right"><Button small onClick={() => setDlg({ k: 'owner-reset', o })}>New password</Button>{' '}
                <Button small onClick={async () => { await api('PATCH', `/owners/${o.id}`, { is_active: !o.is_active }); owners.reload(); toast(o.is_active ? 'Owner login turned off.' : 'Owner login turned on.'); }}>{o.is_active ? 'Turn off' : 'Turn on'}</Button></td>
            </tr>
          ))}</tbody>
        </table></div>
      )}

      <h2 className="section">Billing <Button small kind="primary" onClick={() => setDlg({ k: 'invoice' })}>New invoice</Button></h2>
      {statement.error && <ErrorBox error={statement.error} retry={statement.reload} />}
      {statement.data && statement.data.invoices.length === 0 && <Empty>Nothing has been invoiced to this shop yet.</Empty>}
      {statement.data && statement.data.balances.some((b) => b.owed_minor > 0) && (
        <p>Owes {statement.data.balances.filter((b) => b.owed_minor > 0).map((b) => money(b.owed_minor, b.currency)).join(' and ')}
          {statement.data.balances.some((b) => b.overdue_minor > 0) && <> (<strong>{statement.data.balances.filter((b) => b.overdue_minor > 0).map((b) => money(b.overdue_minor, b.currency)).join(' and ')} overdue</strong>)</>}.</p>
      )}
      {statement.data && statement.data.invoices.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Invoice</th><th>Issued</th><th>Status</th><th className="num">Total</th><th className="num">Balance</th></tr></thead>
          <tbody>{statement.data.invoices.map((i) => (
            <tr key={i.id}><td><Link to={`/invoices/${i.id}`}>{i.number}</Link></td><td>{fmtDate(i.issued_at)}</td><td><InvoiceBadge state={i.state} overdue={i.overdue} /></td>
              <td className="num">{money(i.total_minor, i.currency)}</td><td className="num">{i.state === 'void' ? '—' : money(i.balance_minor, i.currency)}</td></tr>
          ))}</tbody>
        </table></div>
      )}

      <h2 className="section">Recent activity</h2>
      {activity.error && <ErrorBox error={activity.error} retry={activity.reload} />}
      {activity.data && activity.data.length === 0 && <Empty>No activity recorded for this shop yet.</Empty>}
      {activity.data && activity.data.length > 0 && (
        <div className="card flush"><table><tbody>
          {activity.data.map((e) => <tr key={e.id}><td className="nowrap">{fmtTime(e.created_at)}</td><td>{e.action}</td><td className="muted">{e.vendor_name ?? '—'}</td></tr>)}
        </tbody></table></div>
      )}

      {dlg?.k === 'owner-add' && (
        <AddOwner shopId={s.id} onClose={() => setDlg(null)} onDone={(pw) => { owners.reload(); setDlg({ k: 'key', key: pw, what: 'owner password' }); }} />
      )}
      {dlg?.k === 'owner-reset' && (
        <FormModal title={`New password for ${dlg.o.name}?`} submit="Make new password" danger onClose={() => setDlg(null)}
          onSubmit={async () => { const r = await api<{ temporary_password: string }>('POST', `/owners/${dlg.o.id}/reset-password`, {}); owners.reload(); setDlg({ k: 'key', key: r.temporary_password, what: 'owner password' }); }}>
          <p>The old password stops working and {dlg.o.name} is signed out everywhere. They must choose their own password at the next sign-in.</p>
        </FormModal>
      )}
      {dlg?.k === 'invoice' && <NewInvoice shopId={s.id} onClose={() => setDlg(null)} onDone={() => statement.reload()} />}
      {dlg?.k === 'edit' && <EditShop shop={s} onClose={() => setDlg(null)} onDone={() => done('Details saved.')} />}
      {dlg?.k === 'shop-status' && (
        <FormModal title={s.status === 'active' ? 'Suspend this shop?' : 'Resume this shop?'} submit={s.status === 'active' ? 'Suspend shop' : 'Resume shop'} danger={s.status === 'active'} onClose={() => setDlg(null)}
          onSubmit={async () => { await api('PATCH', `/tenants/${s.id}`, { status: s.status === 'active' ? 'suspended' : 'active' }); done(s.status === 'active' ? 'Shop suspended.' : 'Shop resumed.'); }}>
          <p>{s.status === 'active' ? 'All of this shop\'s phones will be refused new licence checks. Phones keep working until their last check runs out. Use this for non-payment or misuse.' : 'The shop\'s phones will be able to renew their licence checks again.'}</p>
        </FormModal>
      )}
      {dlg?.k === 'issue' && <IssueLicence shopId={s.id} onClose={() => setDlg(null)} onIssued={(key) => { done(); setDlg({ k: 'key', key, what: 'licence' }); }} />}
      {dlg?.k === 'extend' && <ExtendLicence l={dlg.l} onClose={() => setDlg(null)} onDone={() => done('Licence extended.')} />}
      {dlg?.k === 'limits' && <Limits l={dlg.l} onClose={() => setDlg(null)} onDone={() => done('Limits saved.')} />}
      {dlg?.k === 'toggle' && (
        <FormModal title={dlg.l.status === 'active' ? 'Suspend this licence?' : 'Resume this licence?'} submit={dlg.l.status === 'active' ? 'Suspend licence' : 'Resume licence'} danger={dlg.l.status === 'active'} onClose={() => setDlg(null)}
          onSubmit={async () => { await api('POST', `/licences/${dlg.l.id}/${dlg.l.status === 'active' ? 'suspend' : 'resume'}`, {}); done(dlg.l.status === 'active' ? 'Licence suspended.' : 'Licence resumed.'); }}>
          <p>{dlg.l.status === 'active' ? 'Phones using this licence stop being able to renew. This does not delete any shop data.' : 'Phones can renew again.'}</p>
        </FormModal>
      )}
      {dlg?.k === 'rotate' && (
        <FormModal title="Make a new key?" submit="Make new key" danger onClose={() => setDlg(null)}
          onSubmit={async () => { const r = await api<{ key: string }>('POST', `/licences/${dlg.l.id}/rotate-key`, {}); done(); setDlg({ k: 'key', key: r.key, what: 'replacement key' }); }}>
          <p>Use this if the key leaked. Phones already activated keep working. The old key stops working for new activations, and a new key is shown once.</p>
        </FormModal>
      )}
      {dlg?.k === 'release' && <ReleasePhone d={dlg.d} onClose={() => setDlg(null)} onDone={() => done('Phone released. Its slot is free.')} />}
      {dlg?.k === 'key' && <SecretModal title={`New ${dlg.what}`} secret={dlg.key} note={dlg.what === 'owner password' ? 'This temporary password is shown only once. Send it to the owner now. They choose their own password when they first sign in.' : 'This key is shown only once and cannot be looked up later. Copy it and send it to the shop owner now.'} onClose={() => setDlg(null)} />}
    </Page>
  );
}

function EditShop({ shop, onClose, onDone }: { shop: Shop; onClose: () => void; onDone: () => void }) {
  const [name, setName] = useState(shop.name);
  const [contact, setContact] = useState(shop.contact ?? '');
  const [notes, setNotes] = useState(shop.notes ?? '');
  return (
    <FormModal title="Edit shop" submit="Save" onClose={onClose} onSubmit={async () => { await api('PATCH', `/tenants/${shop.id}`, { name, contact, notes }); onDone(); }}>
      <Field label="Shop name">{(id) => <input id={id} required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
      <Field label="Contact">{(id) => <input id={id} maxLength={300} value={contact} onChange={(e) => setContact(e.target.value)} />}</Field>
      <Field label="Notes">{(id) => <textarea id={id} rows={4} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} />}</Field>
    </FormModal>
  );
}

function Term({ months, setMonths, date, setDate, mode, setMode }: { months: string; setMonths: (v: string) => void; date: string; setDate: (v: string) => void; mode: 'months' | 'date'; setMode: (m: 'months' | 'date') => void }) {
  return (
    <fieldset className="field">
      <legend>Valid</legend>
      <label className="check"><input type="radio" checked={mode === 'months'} onChange={() => setMode('months')} /> for a number of months</label>
      {mode === 'months' && <input aria-label="Months" type="number" min={1} max={120} step={1} required value={months} onChange={(e) => setMonths(e.target.value)} />}
      <label className="check"><input type="radio" checked={mode === 'date'} onChange={() => setMode('date')} /> until a date</label>
      {mode === 'date' && <input aria-label="Valid until" type="date" min={todayIso()} required value={date} onChange={(e) => setDate(e.target.value)} />}
    </fieldset>
  );
}

function termBody(mode: 'months' | 'date', months: string, date: string): Record<string, number> {
  if (mode === 'months') {
    const n = Number(months);
    if (!Number.isInteger(n) || n < 1 || n > 120) throw new Error('Enter a whole number of months, 1 to 120.');
    return { months: n };
  }
  const ms = endOfDay(date);
  if (ms === null) throw new Error('Pick a date.');
  return { expires_at: ms };
}

function optNum(label: string, v: string, min: number, max: number): number | undefined {
  if (v.trim() === '') return undefined;
  const n = Number(v);
  if (!Number.isInteger(n) || n < min || n > max) throw new Error(`${label} must be a whole number from ${min} to ${max}.`);
  return n;
}

function IssueLicence({ shopId, onClose, onIssued }: { shopId: string; onClose: () => void; onIssued: (key: string) => void }) {
  const plans = useAsync(() => api<{ plans: Plan[] }>('GET', '/plans'), []);
  const [planId, setPlanId] = useState('');
  const [mode, setMode] = useState<'months' | 'date'>('months');
  const [months, setMonths] = useState('12');
  const [date, setDate] = useState('');
  const [devices, setDevices] = useState('');
  const [branches, setBranches] = useState('');
  const [grace, setGrace] = useState('');
  const [offline, setOffline] = useState('');
  const [features, setFeatures] = useState('');
  const plan = plans.data?.plans.find((p) => p.id === planId);
  return (
    <FormModal
      title="Issue licence"
      submit="Issue licence"
      wide
      onClose={onClose}
      onSubmit={async () => {
        const body: Record<string, unknown> = { ...termBody(mode, months, date) };
        if (planId) body.plan_id = planId;
        const d = optNum('Phones', devices, 1, 1000); if (d !== undefined) body.max_devices = d;
        const b = optNum('Branches', branches, 1, 1000); if (b !== undefined) body.max_branches = b;
        const g = optNum('Grace days', grace, 0, 365); if (g !== undefined) body.grace_days = g;
        const o = optNum('Offline days', offline, 1, 365); if (o !== undefined) body.max_offline_days = o;
        if (features.trim()) body.features = splitList(features);
        const r = await api<{ key: string }>('POST', `/tenants/${shopId}/licences`, body);
        onIssued(r.key);
      }}
    >
      <Field label="Plan" hint={plan ? `Starts from ${plan.max_devices} phone(s), ${plan.max_branches} branch(es).` : 'Optional. A plan fills in the limits below.'}>
        {(id) => (
          <select id={id} value={planId} onChange={(e) => setPlanId(e.target.value)}>
            <option value="">No plan (set limits below)</option>
            {(plans.data?.plans ?? []).map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        )}
      </Field>
      <Term months={months} setMonths={setMonths} date={date} setDate={setDate} mode={mode} setMode={setMode} />
      <details>
        <summary>Change limits for this licence</summary>
        <div className="grid2">
          <Field label="Phones">{(id) => <input id={id} type="number" min={1} max={1000} placeholder={plan ? String(plan.max_devices) : '1'} value={devices} onChange={(e) => setDevices(e.target.value)} />}</Field>
          <Field label="Branches">{(id) => <input id={id} type="number" min={1} max={1000} placeholder={plan ? String(plan.max_branches) : '1'} value={branches} onChange={(e) => setBranches(e.target.value)} />}</Field>
          <Field label="Grace days after the end" hint="Leave empty for the server's default.">{(id) => <input id={id} type="number" min={0} max={365} value={grace} onChange={(e) => setGrace(e.target.value)} />}</Field>
          <Field label="Days a phone may work offline" hint="Leave empty for the server's default.">{(id) => <input id={id} type="number" min={1} max={365} value={offline} onChange={(e) => setOffline(e.target.value)} />}</Field>
        </div>
        <Field label="Features" hint="Comma separated. Empty uses the plan's.">{(id) => <input id={id} value={features} onChange={(e) => setFeatures(e.target.value)} />}</Field>
      </details>
    </FormModal>
  );
}

function ExtendLicence({ l, onClose, onDone }: { l: Licence; onClose: () => void; onDone: () => void }) {
  const [mode, setMode] = useState<'months' | 'date'>('months');
  const [months, setMonths] = useState('12');
  const [date, setDate] = useState('');
  return (
    <FormModal title="Extend licence" submit="Extend" onClose={onClose} onSubmit={async () => { await api('POST', `/licences/${l.id}/extend`, termBody(mode, months, date)); onDone(); }}>
      <p className="muted">Now ends {fmtDate(l.expires_at)}. Months are added to the end date (or to today if it already ended).</p>
      <Term months={months} setMonths={setMonths} date={date} setDate={setDate} mode={mode} setMode={setMode} />
    </FormModal>
  );
}

function Limits({ l, onClose, onDone }: { l: Licence; onClose: () => void; onDone: () => void }) {
  const [devices, setDevices] = useState(String(l.max_devices));
  const [branches, setBranches] = useState(String(l.max_branches));
  const [grace, setGrace] = useState(String(l.grace_days));
  const [offline, setOffline] = useState(String(l.max_offline_days));
  const [features, setFeatures] = useState(l.features.join(', '));
  return (
    <FormModal title="Licence limits" submit="Save limits" onClose={onClose}
      onSubmit={async () => {
        await api('POST', `/licences/${l.id}/limits`, {
          max_devices: optNum('Phones', devices, 1, 1000), max_branches: optNum('Branches', branches, 1, 1000),
          grace_days: optNum('Grace days', grace, 0, 365), max_offline_days: optNum('Offline days', offline, 1, 365), features: splitList(features),
        });
        onDone();
      }}>
      <div className="grid2">
        <Field label="Phones">{(id) => <input id={id} type="number" min={1} max={1000} required value={devices} onChange={(e) => setDevices(e.target.value)} />}</Field>
        <Field label="Branches">{(id) => <input id={id} type="number" min={1} max={1000} required value={branches} onChange={(e) => setBranches(e.target.value)} />}</Field>
        <Field label="Grace days after the end">{(id) => <input id={id} type="number" min={0} max={365} required value={grace} onChange={(e) => setGrace(e.target.value)} />}</Field>
        <Field label="Days a phone may work offline">{(id) => <input id={id} type="number" min={1} max={365} required value={offline} onChange={(e) => setOffline(e.target.value)} />}</Field>
      </div>
      <Field label="Features" hint="Comma separated.">{(id) => <input id={id} value={features} onChange={(e) => setFeatures(e.target.value)} />}</Field>
    </FormModal>
  );
}

function ReleasePhone({ d, onClose, onDone }: { d: Device; onClose: () => void; onDone: () => void }) {
  const [block, setBlock] = useState(true);
  return (
    <FormModal title="Release this phone?" submit="Release phone" danger onClose={onClose} onSubmit={async () => { await api('POST', `/devices/${d.id}/release`, { block }); onDone(); }}>
      <p>{d.device_name ?? 'This phone'} will lose its place. Use this when a phone is lost, stolen or replaced.</p>
      <label className="check"><input type="checkbox" checked={block} onChange={(e) => setBlock(e.target.checked)} /> Stop this phone from activating again with the same key</label>
    </FormModal>
  );
}

function AddOwner({ shopId, onClose, onDone }: { shopId: string; onClose: () => void; onDone: (password: string) => void }) {
  const [name, setName] = useState('');
  const [email, setEmail] = useState('');
  return (
    <FormModal title="Add owner login" submit="Create login" onClose={onClose} onSubmit={async () => {
      const r = await api<{ temporary_password: string }>('POST', `/tenants/${shopId}/owners`, { name: name.trim(), email: email.trim() });
      onDone(r.temporary_password);
    }}>
      <Field label="Owner's name">{(id) => <input id={id} required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
      <Field label="Email" hint="They sign in with this. One email can belong to one shop only.">{(id) => <input id={id} type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Field>
    </FormModal>
  );
}
