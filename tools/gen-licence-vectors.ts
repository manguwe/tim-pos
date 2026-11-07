/**
 * Writes test vectors made by the real server code, so the Dart licence check can be proven to agree with it.
 *   node tools/gen-licence-vectors.ts   ->  app/test/fixtures/licence_vectors.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { generateKeyPair, rawPublicKey } from '../server/src/crypto.ts';
import { signLicenceToken, evaluateLicence, DAY_MS, type LicencePayload } from '../server/src/licence.ts';

const T0 = Date.UTC(2026, 10, 1);
const kp = generateKeyPair();
const other = generateKeyPair();
const payload: LicencePayload = {
  v: 1, licence_id: 'lic-00000001', shop_id: 'shop-0000001', shop_name: 'Mbare Mini Market \u2014 Caf\u00e9', device_id: 'dev-00000001', receipt_prefix: 'D1',
  plan: 'Standard', features: ['multi_currency', 'credit'], max_devices: 2, max_branches: 1,
  issued_at: T0, expires_at: T0 + 30 * DAY_MS, grace_days: 7, max_offline_days: 60, check_by: T0 + 60 * DAY_MS,
};
const token = signLicenceToken(payload, kp.privateKey);
const [body, sig] = token.split('.') as [string, string];
const flip = (s: string) => (s[0] === 'A' ? 'B' : 'A') + s.slice(1);

const times: [string, number][] = [
  ['issued', T0], ['mid', T0 + 10 * DAY_MS], ['expires_soon', T0 + 20 * DAY_MS], ['exactly_expires', T0 + 30 * DAY_MS],
  ['one_ms_into_grace', T0 + 30 * DAY_MS + 1], ['grace_middle', T0 + 33 * DAY_MS], ['exactly_grace_end', T0 + 37 * DAY_MS],
  ['expired', T0 + 37 * DAY_MS + 1], ['expired_long', T0 + 59 * DAY_MS], ['exactly_check_by', T0 + 60 * DAY_MS], ['sync_overdue', T0 + 60 * DAY_MS + 1],
];
const out = {
  public_key_raw: rawPublicKey(kp.publicKey),
  other_public_key_raw: rawPublicKey(other.publicKey),
  payload,
  token,
  bad_tokens: {
    body_changed: `${flip(body)}.${sig}`,
    signature_changed: `${body}.${flip(sig)}`,
    signature_cut: `${body}.${sig.slice(0, 40)}`,
    no_dot: body,
    empty: '',
    three_parts: `${token}.x`,
    not_base64: '!!!.???',
  },
  evaluations: times.map(([name, now]) => ({ name, now, expected: evaluateLicence(payload, now) })),
};
const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'test', 'fixtures');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'licence_vectors.json'), JSON.stringify(out, null, 1) + '\n');
console.log('wrote', join(dir, 'licence_vectors.json'));
