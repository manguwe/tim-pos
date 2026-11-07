import { api, type Overview as OverviewData, type ShopRow } from '../api.ts';
import { money, fmtDate, licenceState, relative, DAY } from '../format.ts';
import { Link } from '../router.tsx';
import { Empty, ErrorBox, Loading, Page, StateBadge, useAsync } from '../ui.tsx';

function Stat({ label, value, tone, to }: { label: string; value: number; tone?: 'warn' | 'bad'; to?: string }) {
  const body = (<><div className="stat-n">{value}</div><div className="stat-l">{label}</div></>);
  const cls = `stat${tone ? ` stat-${tone}` : ''}${value === 0 ? ' stat-zero' : ''}`;
  return to ? <Link to={to} className={cls}>{body}</Link> : <div className={cls}>{body}</div>;
}

export function Overview() {
  const o = useAsync(() => api<OverviewData>('GET', '/overview'), []);
  const shops = useAsync(() => api<{ tenants: ShopRow[] }>('GET', '/tenants'), []);
  const now = o.data?.server_time ?? Date.now();

  const attention = (shops.data?.tenants ?? []).flatMap((s) => {
    const why: string[] = [];
    if (s.status === 'suspended') why.push('Shop suspended');
    const st = licenceState(s.licence_expires_at, 'active', 0, now);
    if (s.licence_expires_at === null) why.push('No licence issued');
    else if (st === 'expired' || (s.licence_expires_at < now)) why.push(`Licence ended ${relative(s.licence_expires_at, now)}`);
    else if (st === 'expiring') why.push(`Licence ends ${relative(s.licence_expires_at, now)} (${fmtDate(s.licence_expires_at)})`);
    if (s.licence_expires_at !== null && s.devices === 0) why.push('No phone activated yet');
    else if (s.devices > 0 && (s.last_seen_at === null || s.last_seen_at < now - 7 * DAY)) why.push(`Not seen ${s.last_seen_at ? relative(s.last_seen_at, now) : 'yet'}`);
    return why.length ? [{ shop: s, why }] : [];
  });

  return (
    <Page title="Overview">
      {o.error && <ErrorBox error={o.error} retry={o.reload} />}
      {!o.data && !o.error && <Loading />}
      {o.data && (
        <div className="stats">
          <Stat label="Shops" value={o.data.shops} to="/shops" />
          <Stat label="Active licences" value={o.data.active_licences} />
          <Stat label="Phones in use" value={o.data.devices} />
          <Stat label="Licences ending within 14 days" value={o.data.expiring_in_14_days} tone="warn" />
          <Stat label="In grace period" value={o.data.in_grace} tone="warn" />
          <Stat label="Phones not seen for 7 days" value={o.data.not_seen_7_days} tone="warn" />
          <Stat label="Suspended shops" value={o.data.shops_suspended} tone="bad" />
        </div>
      )}
      {o.data && (o.data.owed.length > 0 || o.data.overdue_invoices > 0) && (
        <div className="stats">
          <Link to="/invoices" className={`stat${o.data.owed.length ? ' stat-warn' : ''}`}><div className="stat-n money-n">{o.data.owed.length ? o.data.owed.map((m) => money(m.minor, m.currency)).join(' + ') : '0'}</div><div className="stat-l">Owed by shops</div></Link>
          <Link to="/invoices" className={`stat${o.data.overdue_invoices ? ' stat-bad' : ' stat-zero'}`}><div className="stat-n">{o.data.overdue_invoices}</div><div className="stat-l">Overdue invoices{o.data.overdue_minor.length ? ` (${o.data.overdue_minor.map((m) => money(m.minor, m.currency)).join(' + ')})` : ''}</div></Link>
        </div>
      )}
      <h2 className="section">Needs attention</h2>
      {shops.error && <ErrorBox error={shops.error} retry={shops.reload} />}
      {!shops.data && !shops.error && <Loading />}
      {shops.data && attention.length === 0 && <Empty>Nothing needs attention. Every shop has a current licence and phones are checking in.</Empty>}
      {attention.length > 0 && (
        <div className="card flush">
          <table>
            <thead><tr><th>Shop</th><th>Licence</th><th>Why</th></tr></thead>
            <tbody>
              {attention.map(({ shop, why }) => (
                <tr key={shop.id}>
                  <td><Link to={`/shops/${shop.id}`}>{shop.name}</Link></td>
                  <td><StateBadge state={shop.status === 'suspended' ? 'suspended' : licenceState(shop.licence_expires_at, 'active', 0, now)} /></td>
                  <td>{why.join(' · ')}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Page>
  );
}
