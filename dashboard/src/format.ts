import type { Licence } from './api.ts';

export const DAY = 86_400_000;

const dateFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
const timeFmt = new Intl.DateTimeFormat(undefined, { year: 'numeric', month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit' });

export const fmtDate = (ms: number | null | undefined): string => (ms ? dateFmt.format(new Date(ms)) : '—');
export const fmtTime = (ms: number | null | undefined): string => (ms ? timeFmt.format(new Date(ms)) : '—');

/** "3 days ago", "in 12 days", "today". */
export function relative(ms: number | null | undefined, now = Date.now()): string {
  if (!ms) return 'never';
  const days = Math.round((ms - now) / DAY);
  if (Math.abs(ms - now) < 3_600_000) return 'just now';
  if (days === 0) return ms > now ? 'later today' : 'today';
  if (days > 0) return days === 1 ? 'tomorrow' : `in ${days} days`;
  return days === -1 ? 'yesterday' : `${-days} days ago`;
}

export function money(minor: number, currency: string): string {
  const neg = minor < 0 ? '-' : '';
  const a = Math.abs(minor);
  return `${neg}${currency} ${Math.floor(a / 100).toLocaleString()}.${String(a % 100).padStart(2, '0')}`;
}

/** "12" or "12.5" -> 1250. Null when it is not a plain amount. */
export function parseMoney(text: string): number | null {
  const m = /^(\d{1,9})(?:[.,](\d{1,2}))?$/.exec(text.trim());
  if (!m) return null;
  return Number(m[1]) * 100 + Number((m[2] ?? '').padEnd(2, '0'));
}

export type LicenceState = 'active' | 'expiring' | 'grace' | 'expired' | 'suspended' | 'none';

/** What a shop's phones are doing right now, from the licence dates and the server's rules (a grace period after expiry). */
export function licenceState(expiresAt: number | null, status: 'active' | 'suspended' | undefined, graceDays: number, now = Date.now()): LicenceState {
  if (expiresAt === null || status === undefined) return 'none';
  if (status === 'suspended') return 'suspended';
  if (expiresAt >= now) return expiresAt - now < 14 * DAY ? 'expiring' : 'active';
  return expiresAt + graceDays * DAY >= now ? 'grace' : 'expired';
}

export const STATE_LABEL: Record<LicenceState, string> = {
  active: 'Active', expiring: 'Expiring soon', grace: 'In grace period', expired: 'Expired', suspended: 'Suspended', none: 'No licence',
};

/** The licence that counts for a shop: an active one that ends last, otherwise the newest. */
export function mainLicence(ls: Licence[]): Licence | undefined {
  const live = ls.filter((l) => l.status === 'active');
  const pool = live.length ? live : ls;
  return [...pool].sort((a, b) => b.expires_at - a.expires_at)[0];
}

export const countryName = (code: string): string => {
  try { return new Intl.DisplayNames(undefined, { type: 'region' }).of(code) ?? code; } catch { return code; }
};

/** Local end of a day, for "valid until" dates picked in a date box. */
export function endOfDay(isoDate: string): number | null {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  if (!m) return null;
  const t = new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 23, 59, 59).getTime();
  return Number.isFinite(t) ? t : null;
}

export const todayIso = (): string => {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
};

export function bytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / 1024 / 1024).toFixed(1)} MB`;
}

export const splitList = (s: string): string[] => s.split(',').map((x) => x.trim()).filter(Boolean);

export const METHOD_LABEL: Record<string, string> = { cash: 'Cash', ecocash: 'EcoCash', onemoney: 'OneMoney', innbucks: 'InnBucks', bank: 'Bank transfer', other: 'Other' };
export const NEEDS_REFERENCE = new Set(['ecocash', 'onemoney', 'innbucks', 'bank']);
export const pct = (bp: number): string => `${(bp / 100).toFixed(bp % 100 === 0 ? 0 : 2)}%`;
/** 1250 -> "12.50", for filling an amount box. */
export const plainAmount = (minor: number): string => `${Math.floor(minor / 100)}.${String(minor % 100).padStart(2, '0')}`;
/** "2026-11" for the month of a moment. */
export const monthOf = (ms: number): string => { const d = new Date(ms); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}`; };
export const newRequestId = (): string => (globalThis.crypto?.randomUUID?.() ?? `${Date.now()}-${Math.random().toString(16).slice(2)}`);
export const dayStart = (isoDate: string): number | null => {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(isoDate);
  return m ? new Date(Number(m[1]), Number(m[2]) - 1, Number(m[3]), 12, 0, 0).getTime() : null;
};
export const isoOf = (ms: number): string => { const d = new Date(ms); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };

/** Quantities are stored in thousandths: 1500 is 1.5. */
export const qty = (milli: number): string => (milli / 1000).toLocaleString(undefined, { maximumFractionDigits: 3 });
