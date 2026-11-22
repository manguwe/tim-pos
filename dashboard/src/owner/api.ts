/** The shop owner's side of the API: its own sign-in, kept apart from the vendor's. */
import { ApiError } from '../api.ts';

export interface OwnerUser {
  id: string; name: string; email: string; must_change_password: boolean; last_login_at: number | null;
  shop: { id: string; name: string; country_code: string; status: 'active' | 'suspended' };
}
export interface OwnerSession { token: string; expires_at: number; user: OwnerUser }

const KEY = 'tim-pos.owner-session';
export const OWNER_EVENT = 'tim-pos:owner-auth';
let memory: OwnerSession | null = null;

export function getOwnerSession(): OwnerSession | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return memory && memory.expires_at > Date.now() ? memory : null;
    const s = JSON.parse(raw) as OwnerSession;
    return s.expires_at > Date.now() ? s : null;
  } catch { return memory && memory.expires_at > Date.now() ? memory : null; }
}
export function setOwnerSession(s: OwnerSession | null): void {
  memory = s;
  try { if (s) sessionStorage.setItem(KEY, JSON.stringify(s)); else sessionStorage.removeItem(KEY); } catch { /* private window */ }
  window.dispatchEvent(new Event(OWNER_EVENT));
}

export async function ownerApi<T>(method: 'GET' | 'POST', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { accept: 'application/json' };
  const s = getOwnerSession();
  if (s) headers.authorization = `Bearer ${s.token}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(`/v1/owner${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new ApiError(0, 'network', 'Could not reach the server. Check your connection and try again.');
  }
  const text = await res.text();
  let json: any = undefined;
  try { json = text ? JSON.parse(text) : undefined; } catch { /* not JSON */ }
  if (!res.ok) {
    const e = json?.error ?? {};
    if (res.status === 401 && path !== '/login' && s) setOwnerSession(null);
    const { code, message, ...extra } = e;
    throw new ApiError(res.status, code ?? 'error', message ?? `The server answered ${res.status}.`, extra);
  }
  return json as T;
}

// ---- report shapes (the server returns the same figures the phone shows) ----
export interface Meta { data_as_of_change: number; loaded_rows: number; skipped_rows: number; built_at: number; phones_last_seen_at: number | null }
export interface CurrencyTotals { currency: string; sales: number; gross_minor: number; discount_minor: number; tax_minor: number; returns_minor: number; net_minor: number }
export interface SalesSummary {
  base_currency: string; by_currency: CurrencyTotals[]; sales: number; returns: number; revenue_minor: number; tax_minor: number;
  cost_minor: number; profit_minor: number; lines_without_cost: number; average_sale_minor: number;
  open_layby: { count: number; value_minor: number; paid_minor: number; currency: string }[];
}
export interface DayRow { day: string; sales: number; revenue_minor: number; returns_minor: number; net_minor: number }
export interface ProductRow { product_id: string | null; name: string; qty_milli: number; revenue_minor: number; cost_minor: number; profit_minor: number }
export interface TakingRow { method: string; currency: string; received_minor: number; paid_back_minor: number; net_minor: number }
export interface StockValue { base_currency: string; total_minor: number; products: number; without_cost: number; negative: number; rows: { product_id: string; name: string; qty_milli: number; cost_minor: number | null; value_minor: number }[] }
export interface OutOfStock { product_id: string; name: string; qty_milli: number }
export interface ExpiringBatch { product_id: string; name: string; batch_code: string | null; expiry_date: string; qty_milli: number; expired: boolean }
export interface Receivables { by_currency: { currency: string; owed_minor: number; customers: number }[]; debtors: { customer_id: string; name: string; phone: string | null; currency: string; owed_minor: number }[] }
export interface CashUpRow { shift_id: string; user: string | null; opened_at: number; closed_at: number; currencies: { currency: string; expected_minor: number; counted_minor: number; difference_minor: number }[] }

// ---- products with pictures ----
export interface CatalogueRow {
  id: string; name: string; brand: string | null; image_ref: string | null; is_active: number | null; track_stock: number | null;
  price_minor: number | null; on_hand_milli: number;
}

const photoCache = new Map<string, Promise<string | null>>();
/** A product picture as a data: address. The server needs the owner's sign-in for it, so an <img src> cannot fetch it directly. */
export function ownerPhoto(name: string): Promise<string | null> {
  let p = photoCache.get(name);
  if (!p) {
    p = ownerApi<{ data: string }>('GET', `/photos/${encodeURIComponent(name)}`)
      .then((r) => `data:image/jpeg;base64,${r.data}`)
      .catch(() => { photoCache.delete(name); return null; });
    photoCache.set(name, p);
  }
  return p;
}
