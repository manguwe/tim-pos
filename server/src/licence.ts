import { b64u, fromB64u, signEd25519, verifyEd25519 } from './crypto.ts';

export const DAY_MS = 86_400_000;

/**
 * The signed licence the phone stores. The app checks the signature offline with the public key
 * built into it, then evaluates the state with evaluateLicence(). A Dart port of these two
 * functions is what the mobile app uses.
 */
export interface LicencePayload {
  v: 1;
  licence_id: string;
  shop_id: string;
  shop_name: string;
  device_id: string;
  /** Unique within the shop. The phone puts it in front of every receipt number it issues. */
  receipt_prefix: string;
  plan: string | null;
  features: string[];
  max_devices: number;
  max_branches: number;
  issued_at: number;
  /** End of the paid period. */
  expires_at: number;
  /** Days the app keeps working after expires_at. */
  grace_days: number;
  max_offline_days: number;
  /** The phone must sync before this time or it locks. A suspended shop stops receiving new tokens. */
  check_by: number;
}

export type LicenceState =
  | { state: 'active'; days_left: number; expires_soon: boolean }
  | { state: 'grace'; days_left: number; grace_days_left: number }
  | { state: 'locked'; reason: 'expired' | 'sync_overdue' };

export function signLicenceToken(payload: LicencePayload, privateKeyPem: string): string {
  const body = b64u(JSON.stringify(payload));
  return `${body}.${signEd25519(body, privateKeyPem)}`;
}

export function verifyLicenceToken(token: string, publicKeyPem: string): LicencePayload | null {
  const [body, sig] = token.split('.');
  if (!body || !sig || !verifyEd25519(body, sig, publicKeyPem)) return null;
  try {
    const p = JSON.parse(fromB64u(body).toString('utf8')) as LicencePayload;
    return p.v === 1 ? p : null;
  } catch {
    return null;
  }
}

export function evaluateLicence(p: LicencePayload, now: number): LicenceState {
  if (now > p.check_by) return { state: 'locked', reason: 'sync_overdue' };
  if (now <= p.expires_at) {
    const daysLeft = Math.ceil((p.expires_at - now) / DAY_MS);
    return { state: 'active', days_left: daysLeft, expires_soon: daysLeft <= 14 };
  }
  const graceEnd = p.expires_at + p.grace_days * DAY_MS;
  if (now <= graceEnd) {
    return { state: 'grace', days_left: 0, grace_days_left: Math.ceil((graceEnd - now) / DAY_MS) };
  }
  return { state: 'locked', reason: 'expired' };
}
