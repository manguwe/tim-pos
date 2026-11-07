import { useMemo, useState } from 'react';
import { api, type AuditEntry, type ShopRow } from '../api.ts';
import { fmtTime } from '../format.ts';
import { Link } from '../router.tsx';
import { Empty, ErrorBox, Loading, Page, useAsync } from '../ui.tsx';

export function Audit() {
  const [limit, setLimit] = useState(100);
  const [q, setQ] = useState('');
  const log = useAsync(() => api<{ entries: AuditEntry[] }>('GET', `/audit?limit=${limit}`), [limit]);
  const shops = useAsync(() => api<{ tenants: ShopRow[] }>('GET', '/tenants'), []);
  const names = useMemo(() => new Map((shops.data?.tenants ?? []).map((s) => [s.id, s.name])), [shops.data]);
  const rows = useMemo(() => {
    const n = q.trim().toLowerCase();
    return (log.data?.entries ?? []).filter((e) => !n || `${e.action} ${e.vendor_name ?? ''} ${names.get(e.tenant_id ?? '') ?? ''} ${JSON.stringify(e.detail)}`.toLowerCase().includes(n));
  }, [log.data, q, names]);
  return (
    <Page title="Audit log">
      <p className="muted">Every change made through this dashboard or the command line. Entries cannot be edited or deleted.</p>
      <div className="toolbar">
        <input type="search" placeholder="Filter by action, person or shop" aria-label="Filter" value={q} onChange={(e) => setQ(e.target.value)} />
        <select aria-label="How many" value={limit} onChange={(e) => setLimit(Number(e.target.value))}>
          <option value={100}>Latest 100</option><option value={250}>Latest 250</option><option value={500}>Latest 500</option>
        </select>
      </div>
      {log.error && <ErrorBox error={log.error} retry={log.reload} />}
      {!log.data && !log.error && <Loading />}
      {log.data && rows.length === 0 && <Empty>No entries.</Empty>}
      {rows.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>When</th><th>Who</th><th>Action</th><th>Shop</th><th>Details</th></tr></thead>
          <tbody>{rows.map((e) => (
            <tr key={e.id}>
              <td className="nowrap">{fmtTime(e.created_at)}</td>
              <td>{e.vendor_name ?? <span className="muted">system</span>}</td>
              <td><code>{e.action}</code></td>
              <td>{e.tenant_id ? <Link to={`/shops/${e.tenant_id}`}>{names.get(e.tenant_id) ?? 'Shop'}</Link> : '—'}</td>
              <td className="small muted">{Object.keys(e.detail).length ? JSON.stringify(e.detail) : ''}</td>
            </tr>
          ))}</tbody>
        </table></div>
      )}
    </Page>
  );
}
