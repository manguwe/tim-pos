import { useEffect, useState } from 'react';
import { ApiError } from '../api.ts';
import { Link, navigate } from '../router.tsx';
import { Button, Field, errorText } from '../ui.tsx';
import { OWNER_EVENT, getOwnerSession, ownerApi, setOwnerSession, type OwnerSession } from './api.ts';
import { Ask, Catalogue, CashUps, FilterCtx, OwnerAccount, Owed, Products, Sales, Stock, type Filters } from './pages.tsx';

const NAV = [
  { to: '/owner', label: 'Sales' },
  { to: '/owner/products', label: 'Best sellers' },
  { to: '/owner/catalogue', label: 'Products' },
  { to: '/owner/stock', label: 'Stock' },
  { to: '/owner/owed', label: 'Customers who owe' },
  { to: '/owner/cash-ups', label: 'Cash-ups' },
  { to: '/owner/ask', label: 'Ask' },
  { to: '/owner/account', label: 'My account' },
];

function useOwnerSession(): OwnerSession | null {
  const [s, setS] = useState(getOwnerSession);
  useEffect(() => {
    const f = () => setS(getOwnerSession());
    window.addEventListener(OWNER_EVENT, f);
    return () => window.removeEventListener(OWNER_EVENT, f);
  }, []);
  useEffect(() => {
    if (!s) return;
    const t = window.setTimeout(() => setOwnerSession(null), Math.max(0, s.expires_at - Date.now()));
    return () => window.clearTimeout(t);
  }, [s]);
  return s;
}

function OwnerLogin() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <main className="login">
      <form className="card login-card" onSubmit={async (e) => {
        e.preventDefault(); setBusy(true); setError(null);
        try {
          const r = await ownerApi<{ token: string; expires_at: number; user: OwnerSession['user'] }>('POST', '/login', { email: email.trim(), password });
          setOwnerSession(r);
          navigate(r.user.must_change_password ? '/owner/account' : '/owner');
        } catch (err) { setError(err instanceof ApiError ? errorText(err) : 'Something went wrong.'); } finally { setBusy(false); }
      }}>
        <div className="brand-mark" aria-hidden="true">T</div>
        <h1>TIM-POS</h1>
        <p className="muted">Shop owner sign-in. See your sales, stock and cash-ups from anywhere.</p>
        <Field label="Email">{(id) => <input id={id} type="email" autoComplete="username" required value={email} onChange={(e) => setEmail(e.target.value)} />}</Field>
        <Field label="Password">{(id) => <input id={id} type="password" autoComplete="current-password" required value={password} onChange={(e) => setPassword(e.target.value)} />}</Field>
        {error && <div className="alert alert-bad" role="alert">{error}</div>}
        <Button type="submit" kind="primary" busy={busy} className="wide">Sign in</Button>
        <p className="muted small center-text"><Link to="/">Vendor sign-in</Link></p>
      </form>
    </main>
  );
}

export function OwnerApp({ path }: { path: string }) {
  const session = useOwnerSession();
  const [menu, setMenu] = useState(false);
  const [f, setF] = useState<Filters>({ period: 'today', from: '', to: '', branch: '' });
  useEffect(() => setMenu(false), [path]);
  if (!session) return <OwnerLogin />;
  const must = session.user.must_change_password;
  let page;
  if (must || path === '/owner/account') page = <OwnerAccount session={session} />;
  else if (path === '/owner') page = <Sales />;
  else if (path === '/owner/products') page = <Products />;
  else if (path === '/owner/catalogue') page = <Catalogue />;
  else if (path === '/owner/ask') page = <Ask />;
  else if (path === '/owner/stock') page = <Stock />;
  else if (path === '/owner/owed') page = <Owed />;
  else if (path === '/owner/cash-ups') page = <CashUps />;
  else page = <div className="empty">That page does not exist. <Link to="/owner">Go to sales</Link></div>;
  return (
    <FilterCtx.Provider value={{ f, set: setF }}>
      <div className={`shell${menu ? ' menu-open' : ''}`}>
        <aside className="side">
          <div className="brand"><span className="brand-mark small-mark" aria-hidden="true">T</span> {session.user.shop.name}</div>
          <nav aria-label="Main">
            {NAV.map((n) => <Link key={n.to} to={n.to} className={path === n.to ? 'active' : ''}>{n.label}</Link>)}
          </nav>
          <div className="side-foot">
            <div className="who">{session.user.name}</div>
            <button className="linkish" onClick={() => { setOwnerSession(null); navigate('/owner'); }}>Sign out</button>
          </div>
        </aside>
        <div className="main">
          <div className="topbar"><button className="icon-btn" aria-label="Menu" onClick={() => setMenu((m) => !m)}>☰</button><strong>{session.user.shop.name}</strong></div>
          <main>{page}</main>
        </div>
      </div>
    </FilterCtx.Provider>
  );
}
