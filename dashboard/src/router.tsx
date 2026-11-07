import { useEffect, useState, type ReactNode } from 'react';

/** A tiny router on the address hash (#/shops/abc), so the server needs no special rules for page addresses. */
const read = (): string => {
  const h = window.location.hash.replace(/^#/, '');
  return h.startsWith('/') ? h : '/';
};

export function useRoute(): string {
  const [path, setPath] = useState(read);
  useEffect(() => {
    const f = () => setPath(read());
    window.addEventListener('hashchange', f);
    return () => window.removeEventListener('hashchange', f);
  }, []);
  return path;
}

export const navigate = (path: string): void => { window.location.hash = path; };

export function Link({ to, children, className }: { to: string; children: ReactNode; className?: string }) {
  return <a href={`#${to}`} className={className}>{children}</a>;
}
