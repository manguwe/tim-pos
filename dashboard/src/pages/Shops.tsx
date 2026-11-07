import { useMemo, useState } from 'react';
import { api, type ShopRow } from '../api.ts';
import { countryName, fmtDate, licenceState, relative, type LicenceState } from '../format.ts';
import { Link, navigate } from '../router.tsx';
import { Badge, Button, Empty, ErrorBox, Field, FormModal, Loading, Page, StateBadge, useAsync, useToast } from '../ui.tsx';

type Filter = 'all' | 'active' | 'attention' | 'expired' | 'suspended' | 'none';

export function Shops() {
  const list = useAsync(() => api<{ tenants: ShopRow[] }>('GET', '/tenants'), []);
  const [q, setQ] = useState('');
  const [filter, setFilter] = useState<Filter>('all');
  const [creating, setCreating] = useState(false);
  const now = Date.now();

  const rows = useMemo(() => {
    const needle = q.trim().toLowerCase();
    return (list.data?.tenants ?? []).map((s) => ({ s, st: (s.status === 'suspended' ? 'suspended' : licenceState(s.licence_expires_at, 'active', 0, now)) as LicenceState }))
      .filter(({ s, st }) => {
        if (needle && !`${s.name} ${s.country_code}`.toLowerCase().includes(needle)) return false;
        switch (filter) {
          case 'active': return st === 'active';
          case 'attention': return st === 'expiring' || st === 'grace';
          case 'expired': return st === 'expired';
          case 'suspended': return st === 'suspended';
          case 'none': return st === 'none';
          default: return true;
        }
      });
  }, [list.data, q, filter, now]);

  return (
    <Page title="Shops" actions={<Button kind="primary" onClick={() => setCreating(true)}>New shop</Button>}>
      <div className="toolbar">
        <input type="search" placeholder="Search shops" aria-label="Search shops" value={q} onChange={(e) => setQ(e.target.value)} />
        <select aria-label="Filter" value={filter} onChange={(e) => setFilter(e.target.value as Filter)}>
          <option value="all">All shops</option>
          <option value="active">Active</option>
          <option value="attention">Ending soon</option>
          <option value="expired">Expired</option>
          <option value="suspended">Suspended</option>
          <option value="none">No licence</option>
        </select>
      </div>
      {list.error && <ErrorBox error={list.error} retry={list.reload} />}
      {!list.data && !list.error && <Loading />}
      {list.data && list.data.tenants.length === 0 && <Empty>No shops yet. Add the first one, then issue it a licence.</Empty>}
      {list.data && list.data.tenants.length > 0 && rows.length === 0 && <Empty>No shop matches.</Empty>}
      {rows.length > 0 && (
        <div className="card flush scroll-x">
          <table>
            <thead><tr><th>Shop</th><th>Country</th><th>Licence</th><th>Ends</th><th className="num">Phones</th><th>Last seen</th></tr></thead>
            <tbody>
              {rows.map(({ s, st }) => (
                <tr key={s.id}>
                  <td><Link to={`/shops/${s.id}`}>{s.name}</Link></td>
                  <td>{countryName(s.country_code)}</td>
                  <td><StateBadge state={st} /></td>
                  <td>{s.licence_expires_at ? <>{fmtDate(s.licence_expires_at)} <span className="muted">· {relative(s.licence_expires_at, now)}</span></> : '—'}</td>
                  <td className="num">{s.devices}</td>
                  <td>{s.devices ? relative(s.last_seen_at, now) : <Badge tone="off">no phone</Badge>}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      {creating && <NewShop onClose={() => setCreating(false)} />}
    </Page>
  );
}

function NewShop({ onClose }: { onClose: () => void }) {
  const toast = useToast();
  const [name, setName] = useState('');
  const [country, setCountry] = useState('ZW');
  const [contact, setContact] = useState('');
  const [notes, setNotes] = useState('');
  return (
    <FormModal
      title="New shop"
      submit="Create shop"
      onClose={onClose}
      onSubmit={async () => {
        const t = await api<{ id: string }>('POST', '/tenants', { name, country_code: country, ...(contact.trim() ? { contact } : {}), ...(notes.trim() ? { notes } : {}) });
        toast('Shop created. Now issue it a licence.');
        onClose();
        navigate(`/shops/${t.id}`);
      }}
    >
      <Field label="Shop name">{(id) => <input id={id} required maxLength={120} value={name} onChange={(e) => setName(e.target.value)} />}</Field>
      <Field label="Country" hint="Two-letter code, for example ZW for Zimbabwe or ZM for Zambia.">
        {(id) => <input id={id} required minLength={2} maxLength={2} pattern="[A-Za-z]{2}" value={country} onChange={(e) => setCountry(e.target.value.toUpperCase())} />}
      </Field>
      <Field label="Contact (optional)" hint="Owner name, phone or email.">{(id) => <input id={id} maxLength={300} value={contact} onChange={(e) => setContact(e.target.value)} />}</Field>
      <Field label="Notes (optional)">{(id) => <textarea id={id} rows={3} maxLength={2000} value={notes} onChange={(e) => setNotes(e.target.value)} />}</Field>
    </FormModal>
  );
}
