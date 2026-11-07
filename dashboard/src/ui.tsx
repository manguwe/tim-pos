import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, type ReactNode } from 'react';
import { ApiError } from './api.ts';
import { STATE_LABEL, type LicenceState } from './format.ts';

// ---- loading data ----

export interface Loaded<T> { data?: T; error?: Error; loading: boolean; reload: () => void }

export function useAsync<T>(fn: () => Promise<T>, deps: readonly unknown[]): Loaded<T> {
  const [state, setState] = useState<{ data?: T; error?: Error; loading: boolean }>({ loading: true });
  const [tick, setTick] = useState(0);
  useEffect(() => {
    let live = true;
    setState((s) => ({ data: s.data, loading: true }));
    fn().then(
      (data) => { if (live) setState({ data, loading: false }); },
      (error: Error) => { if (live) setState({ error, loading: false }); },
    );
    return () => { live = false; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick]);
  const reload = useCallback(() => setTick((t) => t + 1), []);
  return { ...state, reload };
}

export const errorText = (e: unknown): string => (e instanceof ApiError || e instanceof Error ? e.message : 'Something went wrong.');

export function Loading({ what = 'Loading' }: { what?: string }) {
  return <div className="muted pad" role="status">{what}…</div>;
}

export function ErrorBox({ error, retry }: { error: Error; retry?: () => void }) {
  return (
    <div className="alert alert-bad" role="alert">
      <span>{errorText(error)}</span>
      {retry && <button className="btn btn-small" onClick={retry}>Try again</button>}
    </div>
  );
}

export function Empty({ children }: { children: ReactNode }) {
  return <div className="empty">{children}</div>;
}

// ---- toasts ----

interface Toast { id: number; text: string; bad?: boolean }
const ToastCtx = createContext<(text: string, bad?: boolean) => void>(() => {});
export const useToast = () => useContext(ToastCtx);

export function ToastHost({ children }: { children: ReactNode }) {
  const [list, setList] = useState<Toast[]>([]);
  const next = useRef(1);
  const push = useCallback((text: string, bad?: boolean) => {
    const id = next.current++;
    setList((l) => [...l, { id, text, bad }]);
    window.setTimeout(() => setList((l) => l.filter((t) => t.id !== id)), bad ? 7000 : 3500);
  }, []);
  return (
    <ToastCtx.Provider value={push}>
      {children}
      <div className="toasts" aria-live="polite">
        {list.map((t) => <div key={t.id} className={`toast${t.bad ? ' toast-bad' : ''}`}>{t.text}</div>)}
      </div>
    </ToastCtx.Provider>
  );
}

// ---- buttons, badges, fields ----

export function Button({ kind = 'plain', small, busy, ...p }: React.ButtonHTMLAttributes<HTMLButtonElement> & { kind?: 'primary' | 'plain' | 'danger'; small?: boolean; busy?: boolean }) {
  return <button {...p} disabled={p.disabled || busy} className={`btn btn-${kind}${small ? ' btn-small' : ''}${p.className ? ` ${p.className}` : ''}`}>{busy ? 'Working…' : p.children}</button>;
}

export function Badge({ tone, children }: { tone: 'good' | 'warn' | 'bad' | 'off'; children: ReactNode }) {
  return <span className={`badge badge-${tone}`}>{children}</span>;
}

const STATE_TONE: Record<LicenceState, 'good' | 'warn' | 'bad' | 'off'> = {
  active: 'good', expiring: 'warn', grace: 'warn', expired: 'bad', suspended: 'bad', none: 'off',
};
export const StateBadge = ({ state }: { state: LicenceState }) => <Badge tone={STATE_TONE[state]}>{STATE_LABEL[state]}</Badge>;

export function Field({ label, hint, children }: { label: string; hint?: string; children: (id: string) => ReactNode }) {
  const id = useId();
  return (
    <div className="field">
      <label htmlFor={id}>{label}</label>
      {children(id)}
      {hint && <div className="hint">{hint}</div>}
    </div>
  );
}

// ---- modal ----

export function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  const ref = useRef<HTMLDivElement>(null);
  const titleId = useId();
  useEffect(() => {
    const before = document.activeElement as HTMLElement | null;
    const first = ref.current?.querySelector<HTMLElement>('input, select, textarea, button');
    first?.focus();
    const key = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.stopPropagation(); onClose(); }
      if (e.key === 'Tab' && ref.current) {
        const items = Array.from(ref.current.querySelectorAll<HTMLElement>('input, select, textarea, button, a[href]')).filter((x) => !x.hasAttribute('disabled'));
        const a = items[0], z = items[items.length - 1];
        if (!a || !z) return;
        if (e.shiftKey && document.activeElement === a) { e.preventDefault(); z.focus(); }
        else if (!e.shiftKey && document.activeElement === z) { e.preventDefault(); a.focus(); }
      }
    };
    document.addEventListener('keydown', key);
    return () => { document.removeEventListener('keydown', key); before?.focus(); };
  }, [onClose]);
  return (
    <div className="scrim" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }}>
      <div className={`modal${wide ? ' modal-wide' : ''}`} role="dialog" aria-modal="true" aria-labelledby={titleId} ref={ref}>
        <div className="modal-head"><h2 id={titleId}>{title}</h2><button className="icon-btn" aria-label="Close" onClick={onClose}>×</button></div>
        {children}
      </div>
    </div>
  );
}

/** A form inside a modal: shows the error from the server, and a busy button while saving. */
export function FormModal({ title, onClose, onSubmit, submit, children, danger, wide }: {
  title: string; onClose: () => void; onSubmit: () => Promise<void>; submit: string; children: ReactNode; danger?: boolean; wide?: boolean;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <Modal title={title} onClose={onClose} wide={wide}>
      <form
        onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          setError(null);
          try { await onSubmit(); } catch (err) { setError(errorText(err)); } finally { setBusy(false); }
        }}
      >
        <div className="modal-body">{children}</div>
        {error && <div className="alert alert-bad" role="alert">{error}</div>}
        <div className="modal-foot">
          <Button type="button" onClick={onClose}>Cancel</Button>
          <Button type="submit" kind={danger ? 'danger' : 'primary'} busy={busy}>{submit}</Button>
        </div>
      </form>
    </Modal>
  );
}

export function CopyButton({ text, label = 'Copy' }: { text: string; label?: string }) {
  const [done, setDone] = useState(false);
  return (
    <Button
      type="button"
      small
      onClick={async () => {
        try { await navigator.clipboard.writeText(text); setDone(true); window.setTimeout(() => setDone(false), 1800); } catch { /* clipboard blocked: the text is selectable */ }
      }}
    >
      {done ? 'Copied' : label}
    </Button>
  );
}

/** Shows a secret that the server will never show again. */
export function SecretModal({ title, secret, note, onClose }: { title: string; secret: string; note: string; onClose: () => void }) {
  return (
    <Modal title={title} onClose={onClose}>
      <div className="modal-body">
        <div className="alert alert-warn">{note}</div>
        <div className="secret"><code data-testid="secret">{secret}</code><CopyButton text={secret} /></div>
      </div>
      <div className="modal-foot"><Button kind="primary" onClick={onClose}>I have saved it</Button></div>
    </Modal>
  );
}

export function Page({ title, actions, children }: { title: string; actions?: ReactNode; children: ReactNode }) {
  useEffect(() => { document.title = `${title} · TIM-POS`; }, [title]);
  return (
    <section>
      <header className="page-head"><h1>{title}</h1><div className="page-actions">{actions}</div></header>
      {children}
    </section>
  );
}

const INVOICE_TONE = { unpaid: 'warn', partly_paid: 'warn', paid: 'good', void: 'off' } as const;
const INVOICE_LABEL = { unpaid: 'Unpaid', partly_paid: 'Partly paid', paid: 'Paid', void: 'Void' } as const;
export function InvoiceBadge({ state, overdue }: { state: keyof typeof INVOICE_TONE; overdue: boolean }) {
  return overdue ? <Badge tone="bad">{state === 'partly_paid' ? 'Overdue, part paid' : 'Overdue'}</Badge> : <Badge tone={INVOICE_TONE[state]}>{INVOICE_LABEL[state]}</Badge>;
}
