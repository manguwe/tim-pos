/** Everything the dashboard knows about the server's vendor API: the shapes it returns and one function to call it. */

export interface SessionUser { id: string; name: string; email: string; two_factor: boolean }
export interface Session { token: string; expires_at: number; user: SessionUser }

export interface Overview {
  shops: number; shops_suspended: number; active_licences: number; expiring_in_14_days: number; in_grace: number;
  devices: number; not_seen_7_days: number; server_time: number;
  owed: MoneyTotal[]; overdue_minor: MoneyTotal[]; overdue_invoices: number;
}
export interface MoneyTotal { currency: string; minor: number }
export interface ShopRow {
  id: string; name: string; country_code: string; status: 'active' | 'suspended'; created_at: number;
  licence_expires_at: number | null; devices: number; last_seen_at: number | null;
}
export interface Licence {
  id: string; tenant_id: string; plan_id: string | null; key_hint: string; status: 'active' | 'suspended';
  issued_at: number; expires_at: number; grace_days: number; max_offline_days: number; max_devices: number; max_branches: number;
  features: string[];
}
export interface Device {
  id: string; licence_id: string; device_name: string | null; platform: string | null; app_version: string | null;
  activated_at: number; last_seen_at: number | null; last_pull_seq: number | null; released_at: number | null;
}
export interface ShopDetail {
  id: string; name: string; country_code: string; contact: string | null; notes: string | null; status: 'active' | 'suspended';
  created_at: number; licences: Licence[]; devices: Device[]; sync_head_seq: number;
}
export interface Plan {
  id: string; name: string; one_time_fee_minor: number; monthly_fee_minor: number; currency: string;
  max_devices: number; max_branches: number; features: string[];
}
export interface Release {
  id: string; version: string; build_number: number; min_supported_build: number; sha256: string; size_bytes: number;
  apk_url: string; notes: string | null; published_at: number;
}
export interface AuditEntry {
  id: string; vendor_user_id: string | null; vendor_name: string | null; vendor_email: string | null; action: string;
  tenant_id: string | null; detail: Record<string, unknown>; created_at: number;
}

export type PayMethod = 'cash' | 'ecocash' | 'onemoney' | 'innbucks' | 'bank' | 'other';
export type InvoiceState = 'unpaid' | 'partly_paid' | 'paid' | 'void';
export interface Invoice {
  id: string; number: string; tenant_id: string; tenant_name: string; currency: string; status: 'issued' | 'void'; issued_at: number; due_at: number;
  subtotal_minor: number; tax_bp: number; tax_minor: number; total_minor: number; paid_minor: number; balance_minor: number;
  notes: string | null; void_reason: string | null; voided_at: number | null; state: InvoiceState; overdue: boolean;
}
export interface InvoiceLine { id: string; description: string; quantity: number; unit_price_minor: number; line_total_minor: number; kind: 'one_time' | 'monthly' | 'other'; licence_id: string | null }
export interface InvoicePayment {
  id: string; receipt_no: string; amount_minor: number; method: PayMethod; reference: string | null; note: string | null; received_at: number; created_at: number;
  extended_licence_id: string | null; extended_months: number | null; reversed_at: number | null; reverse_reason: string | null; recorded_by: string | null;
}
export interface BillingProfile {
  business_name: string; address: string; phone: string; email: string; tax_number: string; default_tax_bp: number; default_due_days: number;
  invoice_prefix: string; receipt_prefix: string; payment_instructions: string; footer: string; updated_at: number;
}
export interface InvoiceDetail extends Invoice {
  lines: InvoiceLine[]; payments: InvoicePayment[]; profile: BillingProfile;
  tenant: { id: string; name: string; country_code: string; contact: string | null };
  licences: { id: string; key_hint: string; expires_at: number; status: string }[];
}
export interface PaymentRow {
  id: string; receipt_no: string; invoice_id: string; invoice_number: string; tenant_id: string; tenant_name: string; currency: string; amount_minor: number;
  method: PayMethod; reference: string | null; received_at: number; reversed_at: number | null; reverse_reason: string | null;
}
export interface Statement { tenant: { id: string; name: string }; balances: { currency: string; invoiced_minor: number; paid_minor: number; owed_minor: number; overdue_minor: number }[]; invoices: Invoice[] }
export interface RunResult { month: string; dry_run: boolean; created: { tenant_id: string; tenant_name: string; total_minor: number; currency: string; number?: string; id?: string }[]; already_billed: number }

export class ApiError extends Error {
  status: number;
  code: string;
  extra: Record<string, unknown>;
  constructor(status: number, code: string, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

const KEY = 'tim-pos.session';
export const AUTH_EVENT = 'tim-pos:auth';

/** The sign-in lives in sessionStorage: it ends when the tab closes. */
export function getSession(): Session | null {
  try {
    const raw = sessionStorage.getItem(KEY);
    if (!raw) return null;
    const s = JSON.parse(raw) as Session;
    return s.expires_at > Date.now() ? s : null;
  } catch {
    return null;
  }
}
export function setSession(s: Session | null): void {
  try {
    if (s) sessionStorage.setItem(KEY, JSON.stringify(s));
    else sessionStorage.removeItem(KEY);
  } catch { /* private window: the sign-in just will not survive a reload */ }
  memory = s;
  window.dispatchEvent(new Event(AUTH_EVENT));
}
let memory: Session | null = null;
const current = (): Session | null => memory ?? getSession();

export async function api<T>(method: 'GET' | 'POST' | 'PATCH' | 'PUT', path: string, body?: unknown): Promise<T> {
  const headers: Record<string, string> = { accept: 'application/json' };
  const s = current();
  if (s) headers.authorization = `Bearer ${s.token}`;
  if (body !== undefined) headers['content-type'] = 'application/json';
  let res: Response;
  try {
    res = await fetch(`/v1/vendor${path}`, { method, headers, body: body === undefined ? undefined : JSON.stringify(body) });
  } catch {
    throw new ApiError(0, 'network', 'Could not reach the server. Check your connection and try again.');
  }
  const text = await res.text();
  let json: any = undefined;
  try { json = text ? JSON.parse(text) : undefined; } catch { /* not JSON */ }
  if (!res.ok) {
    const e = json?.error ?? {};
    if (res.status === 401 && path !== '/login' && s) setSession(null); // the sign-in ran out
    const { code, message, ...extra } = e;
    throw new ApiError(res.status, code ?? 'error', message ?? `The server answered ${res.status}.`, extra);
  }
  return json as T;
}

export const login = (email: string, password: string, code?: string) =>
  api<Session>('POST', '/login', { email, password, ...(code ? { code } : {}) });

export interface OwnerLogin { id: string; tenant_id: string; name: string; email: string; is_active: boolean; must_change_password: boolean; created_at: number; last_login_at: number | null }
