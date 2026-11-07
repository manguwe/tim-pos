import { b64u, fromB64u, signEd25519, verifyEd25519 } from './crypto.ts';
export const DAY_MS = 86400000;
export function signLicenceToken(payload, privateKeyPem) {
    const body = b64u(JSON.stringify(payload));
    return `${body}.${signEd25519(body, privateKeyPem)}`;
}
export function verifyLicenceToken(token, publicKeyPem) {
    const [body, sig] = token.split('.');
    if (!body || !sig || !verifyEd25519(body, sig, publicKeyPem))
        return null;
    try {
        const p = JSON.parse(fromB64u(body).toString('utf8'));
        return p.v === 1 ? p : null;
    }
    catch {
        return null;
    }
}
export function evaluateLicence(p, now) {
    if (now > p.check_by)
        return { state: 'locked', reason: 'sync_overdue' };
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
