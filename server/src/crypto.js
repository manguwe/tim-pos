import crypto from 'node:crypto';
export const b64u = (v) => Buffer.from(v).toString('base64url');
export const fromB64u = (s) => Buffer.from(s, 'base64url');
export const sha256hex = (s) => crypto.createHash('sha256').update(s).digest('hex');
export const newId = () => crypto.randomUUID();
export const randomSecret = (bytes = 32) => crypto.randomBytes(bytes).toString('base64url');
export function safeEqual(a, b) {
    const ba = Buffer.from(a);
    const bb = Buffer.from(b);
    return ba.length === bb.length && crypto.timingSafeEqual(ba, bb);
}
export function generateKeyPair() {
    const { publicKey, privateKey } = crypto.generateKeyPairSync('ed25519');
    return {
        publicKey: publicKey.export({ type: 'spki', format: 'pem' }).toString(),
        privateKey: privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
    };
}
export function signEd25519(data, privateKeyPem) {
    return b64u(crypto.sign(null, Buffer.from(data), crypto.createPrivateKey(privateKeyPem)));
}
export function verifyEd25519(data, signature, publicKeyPem) {
    try {
        return crypto.verify(null, Buffer.from(data), crypto.createPublicKey(publicKeyPem), fromB64u(signature));
    }
    catch {
        return false;
    }
}
// ---- Passwords (scrypt) ----
function scrypt(password, salt, keylen) {
    return new Promise((resolve, reject) => {
        crypto.scrypt(password, salt, keylen, (err, key) => (err ? reject(err) : resolve(key)));
    });
}
export async function hashPassword(password) {
    const salt = crypto.randomBytes(16);
    const key = await scrypt(password, salt, 64);
    return `scrypt$${b64u(salt)}$${b64u(key)}`;
}
export async function verifyPassword(password, stored) {
    const [alg, salt, hash] = stored.split('$');
    if (alg !== 'scrypt' || !salt || !hash)
        return false;
    const key = await scrypt(password, fromB64u(salt), 64);
    const expected = fromB64u(hash);
    return key.length === expected.length && crypto.timingSafeEqual(key, expected);
}
// ---- Licence keys ----
// Crockford base32 without I, L, O, U, so keys are easy to read out and type.
const KEY_ALPHABET = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
export function generateLicenceKey() {
    const bytes = crypto.randomBytes(16);
    let s = '';
    for (const byte of bytes)
        s += KEY_ALPHABET[byte % 32];
    return `TIM-${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}-${s.slice(12, 16)}`;
}
export function normaliseLicenceKey(key) {
    let k = key.toUpperCase().replace(/[^0-9A-Z]/g, '').replace(/O/g, '0').replace(/[IL]/g, '1');
    if (k.length === 19 && k.startsWith('TIM'))
        k = k.slice(3);
    return k;
}
/** Only this keyed hash of a licence key is ever stored. */
export function hashLicenceKey(key, pepper) {
    return crypto.createHmac('sha256', pepper).update(normaliseLicenceKey(key)).digest('hex');
}
export function licenceKeyHint(key) {
    return normaliseLicenceKey(key).slice(-4);
}
// ---- Vendor session tokens (HMAC) ----
export function signToken(payload, secret) {
    const body = b64u(JSON.stringify(payload));
    const sig = crypto.createHmac('sha256', secret).update(body).digest('base64url');
    return `${body}.${sig}`;
}
export function verifyToken(token, secret) {
    const [body, sig] = token.split('.');
    if (!body || !sig)
        return null;
    const expected = crypto.createHmac('sha256', secret).update(body).digest('base64url');
    if (!safeEqual(sig, expected))
        return null;
    try {
        return JSON.parse(fromB64u(body).toString('utf8'));
    }
    catch {
        return null;
    }
}
// ---- Sealing small secrets at rest (AES-256-GCM) ----
function sealKey(secret) {
    return Buffer.from(crypto.hkdfSync('sha256', secret, 'tim-pos-seal', 'v1', 32));
}
export function seal(plain, secret) {
    const iv = crypto.randomBytes(12);
    const c = crypto.createCipheriv('aes-256-gcm', sealKey(secret), iv);
    const enc = Buffer.concat([c.update(plain, 'utf8'), c.final()]);
    return `${b64u(iv)}.${b64u(enc)}.${b64u(c.getAuthTag())}`;
}
export function unseal(sealed, secret) {
    try {
        const [iv, enc, tag] = sealed.split('.');
        if (!iv || !enc || !tag)
            return null;
        const d = crypto.createDecipheriv('aes-256-gcm', sealKey(secret), fromB64u(iv));
        d.setAuthTag(fromB64u(tag));
        return Buffer.concat([d.update(fromB64u(enc)), d.final()]).toString('utf8');
    }
    catch {
        return null;
    }
}
// ---- TOTP (RFC 6238, SHA-1, 6 digits, 30 s) for vendor two-factor sign-in ----
const B32 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
export function base32Encode(buf) {
    let bits = 0;
    let value = 0;
    let out = '';
    for (const byte of buf) {
        value = (value << 8) | byte;
        bits += 8;
        while (bits >= 5) {
            out += B32[(value >>> (bits - 5)) & 31];
            bits -= 5;
        }
    }
    if (bits > 0)
        out += B32[(value << (5 - bits)) & 31];
    return out;
}
export function base32Decode(s) {
    let bits = 0;
    let value = 0;
    const out = [];
    for (const ch of s.toUpperCase().replace(/=+$/, '')) {
        const idx = B32.indexOf(ch);
        if (idx < 0)
            continue;
        value = (value << 5) | idx;
        bits += 5;
        if (bits >= 8) {
            out.push((value >>> (bits - 8)) & 255);
            bits -= 8;
        }
    }
    return Buffer.from(out);
}
export function newTotpSecret() {
    return base32Encode(crypto.randomBytes(20));
}
export function totpCode(secret, step) {
    const counter = Buffer.alloc(8);
    counter.writeBigUInt64BE(BigInt(step));
    const h = crypto.createHmac('sha1', base32Decode(secret)).update(counter).digest();
    const off = (h[h.length - 1] ?? 0) & 15;
    const n = (h.readUInt32BE(off) & 0x7fffffff) % 1000000;
    return String(n).padStart(6, '0');
}
/** Returns the matching time step (so a code can be used only once), or null. Allows one step either side. */
export function verifyTotp(secret, code, nowMs) {
    if (!/^\d{6}$/.test(code))
        return null;
    const step = Math.floor(nowMs / 30000);
    for (const s of [step, step - 1, step + 1]) {
        if (safeEqual(totpCode(secret, s), code))
            return s;
    }
    return null;
}
/** The 32 raw bytes of an Ed25519 public key, base64url. The phone app embeds this, so it never has to parse PEM. */
export function rawPublicKey(publicKeyPem) {
    const der = crypto.createPublicKey(publicKeyPem).export({ type: 'spki', format: 'der' });
    return b64u(der.subarray(der.length - 32));
}
