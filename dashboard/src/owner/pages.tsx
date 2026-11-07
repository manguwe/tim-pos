import { useState } from 'react';
import { ApiError } from '../api.ts';
import { fmtDate, fmtTime, money, qty, relative } from '../format.ts';
import { Link } from '../router.tsx';
import { Button, Empty, ErrorBox, Field, Loading, Page, errorText, useAsync, useToast } from '../ui.tsx';
import { PERIODS, localIso, offsetMinutes, rangeFor, type PeriodId, type Range } from './period.ts';
import {
  ownerApi, setOwnerSession, type CashUpRow, type DayRow, type ExpiringBatch, type Meta, type OutOfStock, type OwnerSession, type ProductRow,
  type Receivables, type SalesSummary, type StockValue, type TakingRow,
} from './api.ts';
import { createContext, useContext } from 'react';

export interface Filters { period: PeriodId; from: string; to: string; branch: string }
export const FilterCtx = createContext<{ f: Filters; set: (f: Filters) => void }>({ f: { period: 'today', from: '', to: '', branch: '' }, set: () => {} });
const useRange = (): Range | null => { const { f } = useContext(FilterCtx); return rangeFor(f.period, { from: f.from, to: f.to }); };

function useReport<T>(name: string, extra: Record<string, string | number> = {}, withRange = true) {
  const { f } = useContext(FilterCtx);
  const r = useRange();
  const qs = new URLSearchParams();
  if (withRange && r) { qs.set('from', String(r.from)); qs.set('to', String(r.to)); }
  if (f.branch) qs.set('branch_id', f.branch);
  for (const [k, v] of Object.entries(extra)) qs.set(k, String(v));
  const key = qs.toString();
  return useAsync(() => (withRange && !r ? Promise.reject(new Error('Choose a start and end date first.')) : ownerApi<T & Meta>('GET', `/reports/${name}?${key}`)), [name, key]);
}

function Freshness({ meta }: { meta: Meta | undefined }) {
  if (!meta) return null;
  const seen = meta.phones_last_seen_at;
  return (
    <p className="muted small fresh">
      {seen ? `A shop phone last sent its sales ${relative(seen)} (${fmtTime(seen)}).` : 'No shop phone has sent its sales yet.'}{' '}
      Sales made since then appear after the phone next connects to the internet.
      {meta.skipped_rows > 0 && <> {meta.skipped_rows} record(s) could not be read and are left out.</>}
    </p>
  );
}

export function FilterBar({ branches, showRange = true }: { branches: { id: string; name: string }[]; showRange?: boolean }) {
  const { f, set } = useContext(FilterCtx);
  return (
    <div className="toolbar filters">
      {showRange && (
        <select aria-label="Period" value={f.period} onChange={(e) => set({ ...f, period: e.target.value as PeriodId, from: f.from || localIso(), to: f.to || localIso() })}>
          {PERIODS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
        </select>
      )}
      {showRange && f.period === 'custom' && (
        <>
          <input type="date" aria-label="From date" value={f.from} max={localIso()} onChange={(e) => set({ ...f, from: e.target.value })} />
          <input type="date" aria-label="To date" value={f.to} max={localIso()} onChange={(e) => set({ ...f, to: e.target.value })} />
        </>
      )}
      {branches.length > 1 && (
        <select aria-label="Branch" value={f.branch} onChange={(e) => set({ ...f, branch: e.target.value })}>
          <option value="">All branches</option>
          {branches.map((b) => <option key={b.id} value={b.id}>{b.name}</option>)}
        </select>
      )}
    </div>
  );
}

function useBranches() {
  const q = useAsync(() => ownerApi<{ branches: { id: string; name: string }[] }>('GET', '/reports/branches'), []);
  return q.data?.branches ?? [];
}

function Tile({ label, value, tone, note }: { label: string; value: string; tone?: 'good' | 'bad'; note?: string }) {
  return <div className={`stat${tone === 'bad' ? ' stat-bad' : ''}`}><div className="stat-n money-n">{value}</div><div className="stat-l">{label}{note && <span className="small muted"> · {note}</span>}</div></div>;
}

// ---- Sales ----

export function Sales() {
  const branches = useBranches();
  const r = useRange();
  const s = useReport<{ summary: SalesSummary }>('summary');
  const d = useReport<{ days: DayRow[] }>('daily', { offset_min: offsetMinutes() });
  const t = useReport<{ takings: TakingRow[] }>('takings');
  const sum = s.data?.summary;
  const base = sum?.base_currency ?? 'USD';
  const max = Math.max(1, ...(d.data?.days ?? []).map((x) => x.net_minor));
  return (
    <Page title="Sales">
      <FilterBar branches={branches} />
      {r && <p className="muted">{r.label}</p>}
      {s.error && <ErrorBox error={s.error} retry={s.reload} />}
      {!sum && !s.error && <Loading />}
      {sum && (
        <>
          <div className="stats">
            <Tile label="Sales made" value={String(sum.sales)} />
            <Tile label={`Takings (${base})`} value={money(sum.revenue_minor, base)} note={sum.returns ? `after ${sum.returns} return${sum.returns === 1 ? '' : 's'}` : undefined} />
            <Tile label="Profit" value={money(sum.profit_minor, base)} tone={sum.profit_minor < 0 ? 'bad' : undefined} />
            <Tile label="Average sale" value={money(sum.average_sale_minor, base)} />
          </div>
          {sum.lines_without_cost > 0 && <div className="alert alert-warn" role="status">{sum.lines_without_cost} item{sum.lines_without_cost === 1 ? ' was' : 's were'} sold without a cost price, so profit may look higher than it is. Set a cost on those products.</div>}
          {sum.by_currency.length > 0 && (
            <>
              <h2 className="section">By currency</h2>
              <div className="card flush scroll-x"><table>
                <thead><tr><th>Currency</th><th className="num">Sales</th><th className="num">Sold</th><th className="num">Discounts</th><th className="num">Tax</th><th className="num">Returned</th><th className="num">Net</th></tr></thead>
                <tbody>{sum.by_currency.map((c) => <tr key={c.currency}><td>{c.currency}</td><td className="num">{c.sales}</td><td className="num">{money(c.gross_minor, c.currency)}</td><td className="num">{money(c.discount_minor, c.currency)}</td><td className="num">{money(c.tax_minor, c.currency)}</td><td className="num">{money(c.returns_minor, c.currency)}</td><td className="num">{money(c.net_minor, c.currency)}</td></tr>)}</tbody>
              </table></div>
            </>
          )}
          {sum.open_layby.length > 0 && <p className="muted">Open laybys not counted above: {sum.open_layby.map((l) => `${l.count} worth ${money(l.value_minor, l.currency)} (${money(l.paid_minor, l.currency)} paid)`).join(', ')}.</p>}
        </>
      )}

      <h2 className="section">Day by day <span className="muted small">({base})</span></h2>
      {d.error && <ErrorBox error={d.error} retry={d.reload} />}
      {d.data && d.data.days.length === 0 && <Empty>No days in this range.</Empty>}
      {d.data && d.data.days.length > 0 && (
        <>
          <div className="bars" role="img" aria-label={`Takings for each of ${d.data.days.length} days. Highest ${money(max, base)}.`}>
            {d.data.days.map((x) => <div className="bar" key={x.day} title={`${x.day}: ${money(x.net_minor, base)} from ${x.sales} sale${x.sales === 1 ? '' : 's'}`}><div className="bar-fill" style={{ height: `${Math.max(0, (x.net_minor / max) * 100)}%` }} /><div className="bar-l">{x.day.slice(8)}</div></div>)}
          </div>
          <details><summary>Show as a table</summary>
            <div className="card flush scroll-x"><table>
              <thead><tr><th>Day</th><th className="num">Sales</th><th className="num">Sold</th><th className="num">Returned</th><th className="num">Net</th></tr></thead>
              <tbody>{[...d.data.days].reverse().map((x) => <tr key={x.day}><td>{x.day}</td><td className="num">{x.sales}</td><td className="num">{money(x.revenue_minor, base)}</td><td className="num">{money(x.returns_minor, base)}</td><td className="num">{money(x.net_minor, base)}</td></tr>)}</tbody>
            </table></div>
          </details>
        </>
      )}

      <h2 className="section">Money in and out</h2>
      {t.error && <ErrorBox error={t.error} retry={t.reload} />}
      {t.data && t.data.takings.length === 0 && <Empty>No money moved in this range.</Empty>}
      {t.data && t.data.takings.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Paid by</th><th>Currency</th><th className="num">Received</th><th className="num">Paid back</th><th className="num">Net</th></tr></thead>
          <tbody>{t.data.takings.map((x) => <tr key={`${x.method}|${x.currency}`}><td>{x.method}</td><td>{x.currency}</td><td className="num">{money(x.received_minor, x.currency)}</td><td className="num">{money(x.paid_back_minor, x.currency)}</td><td className="num">{money(x.net_minor, x.currency)}</td></tr>)}</tbody>
        </table></div>
      )}
      <Freshness meta={s.data} />
    </Page>
  );
}

// ---- Products ----

export function Products() {
  const branches = useBranches();
  const [by, setBy] = useState<'revenue' | 'qty' | 'profit'>('revenue');
  const p = useReport<{ products: ProductRow[] }>('products', { by, limit: 30 });
  const base = 'USD';
  void base;
  return (
    <Page title="Best sellers">
      <FilterBar branches={branches} />
      <div className="toolbar">
        <select aria-label="Rank by" value={by} onChange={(e) => setBy(e.target.value as typeof by)}>
          <option value="revenue">Most money</option><option value="qty">Most sold</option><option value="profit">Most profit</option>
        </select>
      </div>
      {p.error && <ErrorBox error={p.error} retry={p.reload} />}
      {!p.data && !p.error && <Loading />}
      {p.data && p.data.products.length === 0 && <Empty>Nothing was sold in this range.</Empty>}
      {p.data && p.data.products.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>#</th><th>Product</th><th className="num">Sold</th><th className="num">Takings</th><th className="num">Cost</th><th className="num">Profit</th></tr></thead>
          <tbody>{p.data.products.map((x, i) => <tr key={x.product_id ?? x.name}><td>{i + 1}</td><td>{x.name || 'Unnamed item'}</td><td className="num">{qty(x.qty_milli)}</td><td className="num">{(x.revenue_minor / 100).toFixed(2)}</td><td className="num">{(x.cost_minor / 100).toFixed(2)}</td><td className="num">{(x.profit_minor / 100).toFixed(2)}</td></tr>)}</tbody>
        </table></div>
      )}
      <p className="muted small">Amounts are in the shop's main currency. Items sold without a cost price show a profit equal to their takings.</p>
      <Freshness meta={p.data} />
    </Page>
  );
}

// ---- Stock ----

export function Stock() {
  const branches = useBranches();
  const s = useReport<{ value: StockValue; out_of_stock: OutOfStock[] }>('stock', {}, false);
  const e = useReport<{ batches: ExpiringBatch[] }>('expiring', { today: localIso(), days: 30 }, false);
  const v = s.data?.value;
  return (
    <Page title="Stock">
      <FilterBar branches={branches} showRange={false} />
      {s.error && <ErrorBox error={s.error} retry={s.reload} />}
      {!v && !s.error && <Loading />}
      {v && (
        <>
          <div className="stats">
            <Tile label="Stock value at cost" value={money(v.total_minor, v.base_currency)} />
            <Tile label="Products in stock" value={String(v.products)} />
            <Tile label="Out of stock" value={String(s.data?.out_of_stock.length ?? 0)} tone={(s.data?.out_of_stock.length ?? 0) > 0 ? 'bad' : undefined} />
          </div>
          {v.without_cost > 0 && <div className="alert alert-warn" role="status">{v.without_cost} product{v.without_cost === 1 ? ' has' : 's have'} no cost price, so {v.without_cost === 1 ? 'it is' : 'they are'} not counted in the value.</div>}
          {v.negative > 0 && <div className="alert alert-warn" role="status">{v.negative} product{v.negative === 1 ? ' shows' : 's show'} less than zero in stock. Check recent sales and deliveries on the phone.</div>}
          <h2 className="section">Most valuable stock</h2>
          {v.rows.length === 0 ? <Empty>No stock counted yet.</Empty> : (
            <div className="card flush scroll-x"><table>
              <thead><tr><th>Product</th><th className="num">On hand</th><th className="num">Cost each</th><th className="num">Value</th></tr></thead>
              <tbody>{v.rows.filter((r) => r.qty_milli > 0).slice(0, 25).map((r) => <tr key={r.product_id}><td>{r.name}</td><td className="num">{qty(r.qty_milli)}</td><td className="num">{r.cost_minor === null ? '—' : money(r.cost_minor, v.base_currency)}</td><td className="num">{money(r.value_minor, v.base_currency)}</td></tr>)}</tbody>
            </table></div>
          )}
          <h2 className="section">Out of stock</h2>
          {s.data && s.data.out_of_stock.length === 0 ? <Empty>Nothing is out of stock.</Empty> : (
            <div className="card flush scroll-x"><table>
              <thead><tr><th>Product</th><th className="num">On hand</th></tr></thead>
              <tbody>{(s.data?.out_of_stock ?? []).slice(0, 100).map((r) => <tr key={r.product_id}><td>{r.name}</td><td className="num">{qty(r.qty_milli)}</td></tr>)}</tbody>
            </table></div>
          )}
        </>
      )}
      <h2 className="section">Expiring within 30 days</h2>
      {e.error && <ErrorBox error={e.error} retry={e.reload} />}
      {e.data && e.data.batches.length === 0 && <Empty>No batches expire in the next 30 days.</Empty>}
      {e.data && e.data.batches.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Product</th><th>Batch</th><th>Expires</th><th className="num">Left</th></tr></thead>
          <tbody>{e.data.batches.map((b) => <tr key={`${b.product_id}|${b.batch_code}|${b.expiry_date}`}><td>{b.name}</td><td>{b.batch_code ?? '—'}</td><td>{b.expiry_date} {b.expired && <span className="badge badge-bad">Expired</span>}</td><td className="num">{qty(b.qty_milli)}</td></tr>)}</tbody>
        </table></div>
      )}
      <Freshness meta={s.data} />
    </Page>
  );
}

// ---- Owed, cash-ups ----

export function Owed() {
  const q = useReport<{ receivables: Receivables }>('receivables', {}, false);
  const rc = q.data?.receivables;
  return (
    <Page title="Customers who owe">
      {q.error && <ErrorBox error={q.error} retry={q.reload} />}
      {!rc && !q.error && <Loading />}
      {rc && rc.debtors.length === 0 && <Empty>No customer owes the shop anything.</Empty>}
      {rc && rc.debtors.length > 0 && (
        <>
          <div className="stats">{rc.by_currency.map((c) => <Tile key={c.currency} label={`Owed in ${c.currency}`} value={money(c.owed_minor, c.currency)} note={`${c.customers} customer${c.customers === 1 ? '' : 's'}`} />)}</div>
          <div className="card flush scroll-x"><table>
            <thead><tr><th>Customer</th><th>Phone</th><th className="num">Owes</th></tr></thead>
            <tbody>{rc.debtors.map((d) => <tr key={`${d.customer_id}|${d.currency}`}><td>{d.name}</td><td>{d.phone ?? '—'}</td><td className="num">{money(d.owed_minor, d.currency)}</td></tr>)}</tbody>
          </table></div>
        </>
      )}
      <Freshness meta={q.data} />
    </Page>
  );
}

export function CashUps() {
  const branches = useBranches();
  const q = useReport<{ cash_ups: CashUpRow[] }>('cash-ups');
  return (
    <Page title="Cash-ups">
      <FilterBar branches={[]} />
      {branches.length > 1 && <p className="muted small">Cash-ups are per till shift, so they show for all branches.</p>}
      {q.error && <ErrorBox error={q.error} retry={q.reload} />}
      {!q.data && !q.error && <Loading />}
      {q.data && q.data.cash_ups.length === 0 && <Empty>No shifts were closed in this range.</Empty>}
      {q.data && q.data.cash_ups.length > 0 && (
        <div className="card flush scroll-x"><table>
          <thead><tr><th>Closed</th><th>Cashier</th><th>Currency</th><th className="num">Expected</th><th className="num">Counted</th><th className="num">Difference</th></tr></thead>
          <tbody>{q.data.cash_ups.flatMap((c) => c.currencies.map((x, i) => (
            <tr key={`${c.shift_id}|${x.currency}`}>
              <td>{i === 0 ? fmtTime(c.closed_at) : ''}</td><td>{i === 0 ? c.user ?? '—' : ''}</td><td>{x.currency}</td>
              <td className="num">{money(x.expected_minor, x.currency)}</td><td className="num">{money(x.counted_minor, x.currency)}</td>
              <td className={`num${x.difference_minor !== 0 ? ' bad-text' : ''}`}>{money(x.difference_minor, x.currency)}</td>
            </tr>)))}</tbody>
        </table></div>
      )}
      <Freshness meta={q.data} />
    </Page>
  );
}

// ---- Account ----

export function OwnerAccount({ session }: { session: OwnerSession }) {
  const toast = useToast();
  const [cur, setCur] = useState('');
  const [next, setNext] = useState('');
  const [again, setAgain] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const forced = session.user.must_change_password;
  return (
    <Page title={forced ? 'Choose your password' : 'My account'}>
      {forced && <div className="alert alert-warn" role="status">You are using a temporary password. Choose your own before you view reports.</div>}
      <dl className="dl card"><div><dt>Name</dt><dd>{session.user.name}</dd></div><div><dt>Email</dt><dd>{session.user.email}</dd></div><div><dt>Shop</dt><dd>{session.user.shop.name}</dd></div><div><dt>Last sign-in</dt><dd>{fmtDate(session.user.last_login_at)}</dd></div></dl>
      <h2 className="section">Change password</h2>
      <form className="card form-narrow" onSubmit={async (e) => {
        e.preventDefault();
        setError(null);
        if (next !== again) { setError('The two new passwords are not the same.'); return; }
        setBusy(true);
        try {
          const r = await ownerApi<{ token: string; expires_at: number }>('POST', '/password', { current_password: cur, new_password: next });
          setOwnerSession({ token: r.token, expires_at: r.expires_at, user: { ...session.user, must_change_password: false } });
          setCur(''); setNext(''); setAgain('');
          toast('Password changed.');
        } catch (err) { setError(err instanceof ApiError || err instanceof Error ? errorText(err) : 'Something went wrong.'); } finally { setBusy(false); }
      }}>
        <Field label={forced ? 'Temporary password' : 'Current password'}>{(id) => <input id={id} type="password" autoComplete="current-password" required value={cur} onChange={(e) => setCur(e.target.value)} />}</Field>
        <Field label="New password" hint="At least 10 characters.">{(id) => <input id={id} type="password" autoComplete="new-password" required minLength={10} value={next} onChange={(e) => setNext(e.target.value)} />}</Field>
        <Field label="New password again">{(id) => <input id={id} type="password" autoComplete="new-password" required value={again} onChange={(e) => setAgain(e.target.value)} />}</Field>
        {error && <div className="alert alert-bad" role="alert">{error}</div>}
        <Button type="submit" kind="primary" busy={busy}>Change password</Button>
      </form>
      <p className="muted small"><Link to="/">Vendor sign-in</Link> is a different login for the TIM-POS team.</p>
    </Page>
  );
}
