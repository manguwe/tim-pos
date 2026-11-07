import { StrictMode, useEffect, useState } from 'react';
import { createRoot } from 'react-dom/client';
import './styles.css';
import { AUTH_EVENT, getSession, setSession } from './api.ts';
import { Link, navigate, useRoute } from './router.tsx';
import { ToastHost } from './ui.tsx';
import { OwnerApp } from './owner/OwnerApp.tsx';
import { Account } from './pages/Account.tsx';
import { Audit } from './pages/Audit.tsx';
import { BillingSettings } from './pages/BillingSettings.tsx';
import { InvoiceDetail, Receipt } from './pages/InvoiceDetail.tsx';
import { Invoices } from './pages/Invoices.tsx';
import { Login } from './pages/Login.tsx';
import { Overview } from './pages/Overview.tsx';
import { Plans } from './pages/Plans.tsx';
import { Releases } from './pages/Releases.tsx';
import { ShopDetail } from './pages/ShopDetail.tsx';
import { Shops } from './pages/Shops.tsx';

const NAV = [
  { to: '/', label: 'Overview', match: (p: string) => p === '/' },
  { to: '/shops', label: 'Shops', match: (p: string) => p.startsWith('/shops') },
  { to: '/invoices', label: 'Invoices', match: (p: string) => p.startsWith('/invoices') },
  { to: '/plans', label: 'Plans', match: (p: string) => p === '/plans' },
  { to: '/releases', label: 'App releases', match: (p: string) => p === '/releases' },
  { to: '/billing', label: 'Billing details', match: (p: string) => p === '/billing' },
  { to: '/audit', label: 'Audit log', match: (p: string) => p === '/audit' },
  { to: '/account', label: 'My account', match: (p: string) => p === '/account' },
];

function useSession() {
  const [s, setS] = useState(getSession);
  useEffect(() => {
    const f = () => setS(getSession());
    window.addEventListener(AUTH_EVENT, f);
    return () => window.removeEventListener(AUTH_EVENT, f);
  }, []);
  // Sign out by themselves when the token runs out, even if the tab sits idle.
  useEffect(() => {
    if (!s) return;
    const t = window.setTimeout(() => setSession(null), Math.max(0, s.expires_at - Date.now()));
    return () => window.clearTimeout(t);
  }, [s]);
  return s;
}

function Page({ path }: { path: string }) {
  const shop = /^\/shops\/([^/]+)$/.exec(path);
  if (shop) return <ShopDetail id={decodeURIComponent(shop[1] as string)} />;
  const rc = /^\/invoices\/([^/]+)\/receipt\/([^/]+)$/.exec(path);
  if (rc) return <Receipt invoiceId={decodeURIComponent(rc[1] as string)} paymentId={decodeURIComponent(rc[2] as string)} />;
  const iv = /^\/invoices\/([^/]+)$/.exec(path);
  if (iv) return <InvoiceDetail id={decodeURIComponent(iv[1] as string)} />;
  switch (path) {
    case '/invoices': return <Invoices />;
    case '/billing': return <BillingSettings />;
    case '/': return <Overview />;
    case '/shops': return <Shops />;
    case '/plans': return <Plans />;
    case '/releases': return <Releases />;
    case '/audit': return <Audit />;
    case '/account': return <Account />;
    default: return <div className="empty">That page does not exist. <Link to="/">Go to the overview</Link></div>;
  }
}

function App() {
  const session = useSession();
  const path = useRoute();
  const [menu, setMenu] = useState(false);
  useEffect(() => setMenu(false), [path]);
  if (path === '/owner' || path.startsWith('/owner/')) return <OwnerApp path={path} />;
  if (!session) return <Login />;
  return (
    <div className={`shell${menu ? ' menu-open' : ''}`}>
      <aside className="side">
        <div className="brand"><span className="brand-mark small-mark" aria-hidden="true">T</span> TIM-POS</div>
        <nav aria-label="Main">
          {NAV.map((n) => <Link key={n.to} to={n.to} className={n.match(path) ? 'active' : ''}>{n.label}</Link>)}
        </nav>
        <div className="side-foot">
          <div className="who">{session.user.name}</div>
          <button className="linkish" onClick={() => { setSession(null); navigate('/'); }}>Sign out</button>
        </div>
      </aside>
      <div className="main">
        <div className="topbar"><button className="icon-btn" aria-label="Menu" onClick={() => setMenu((m) => !m)}>☰</button><strong>TIM-POS</strong></div>
        <main><Page path={path} /></main>
      </div>
    </div>
  );
}

createRoot(document.getElementById('root') as HTMLElement).render(<StrictMode><ToastHost><App /></ToastHost></StrictMode>);
