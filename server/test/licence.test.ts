import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { generateKeyPair, rawPublicKey, signEd25519 } from '../src/crypto.ts';
import { DAY_MS, evaluateLicence, signLicenceToken, verifyLicenceToken, type LicencePayload } from '../src/licence.ts';

const kp = generateKeyPair();
const NOW = Date.UTC(2026, 10, 1);
const payload = (o: Partial<LicencePayload> = {}): LicencePayload => ({
  v: 1, licence_id: 'l1', shop_id: 's1', shop_name: 'Shop', device_id: 'd1', receipt_prefix: 'D1', plan: 'Standard', features: ['loyalty'],
  max_devices: 2, max_branches: 1, issued_at: NOW, expires_at: NOW + 30 * DAY_MS, grace_days: 30,
  max_offline_days: 60, check_by: NOW + 60 * DAY_MS, ...o,
});

test('a signed token verifies with the public key and returns the same payload', () => {
  const p = payload();
  assert.deepEqual(verifyLicenceToken(signLicenceToken(p, kp.privateKey), kp.publicKey), p);
});

test('a token whose payload was edited is rejected', () => {
  const [body, sig] = signLicenceToken(payload(), kp.privateKey).split('.') as [string, string];
  const forged = JSON.parse(Buffer.from(body, 'base64url').toString()) as LicencePayload;
  forged.expires_at += 365 * DAY_MS;
  const forgedBody = Buffer.from(JSON.stringify(forged)).toString('base64url');
  assert.equal(verifyLicenceToken(`${forgedBody}.${sig}`, kp.publicKey), null);
});

test('a token signed with a different key is rejected', () => {
  const other = generateKeyPair();
  assert.equal(verifyLicenceToken(signLicenceToken(payload(), other.privateKey), kp.publicKey), null);
});

test('garbage tokens are rejected without throwing', () => {
  for (const t of ['', 'abc', 'a.b', '....', 'x'.repeat(500)]) assert.equal(verifyLicenceToken(t, kp.publicKey), null);
});

test('a paid licence is active, and warns in the last 14 days', () => {
  assert.deepEqual(evaluateLicence(payload(), NOW), { state: 'active', days_left: 30, expires_soon: false });
  assert.deepEqual(evaluateLicence(payload(), NOW + 20 * DAY_MS), { state: 'active', days_left: 10, expires_soon: true });
});

test('after expiry the app keeps working through the grace period, then locks', () => {
  const p = payload({ check_by: NOW + 365 * DAY_MS });
  const s1 = evaluateLicence(p, NOW + 31 * DAY_MS);
  assert.equal(s1.state, 'grace');
  assert.equal(s1.state === 'grace' && s1.grace_days_left, 29);
  assert.equal(evaluateLicence(p, p.expires_at + 30 * DAY_MS).state, 'grace');
  assert.deepEqual(evaluateLicence(p, p.expires_at + 30 * DAY_MS + 1), { state: 'locked', reason: 'expired' });
});

test('a phone that has not synced before check_by locks even if the licence is paid', () => {
  const p = payload({ expires_at: NOW + 400 * DAY_MS, check_by: NOW + 60 * DAY_MS });
  assert.equal(evaluateLicence(p, NOW + 60 * DAY_MS).state, 'active');
  assert.deepEqual(evaluateLicence(p, NOW + 60 * DAY_MS + 1), { state: 'locked', reason: 'sync_overdue' });
});

test('a zero grace period locks at the moment of expiry', () => {
  const p = payload({ grace_days: 0, check_by: NOW + 365 * DAY_MS });
  assert.equal(evaluateLicence(p, p.expires_at).state, 'active');
  assert.equal(evaluateLicence(p, p.expires_at + 1).state, 'locked');
});

test('the raw public key is the 32 bytes the phone app embeds, and it verifies server signatures', () => {
  const raw = Buffer.from(rawPublicKey(kp.publicKey), 'base64url');
  assert.equal(raw.length, 32);
  // Rebuild a key from the raw bytes the way a phone library would, and check a real signature with it.
  const spkiPrefix = Buffer.from('302a300506032b6570032100', 'hex');
  const rebuilt = crypto.createPublicKey({ key: Buffer.concat([spkiPrefix, raw]), format: 'der', type: 'spki' });
  const sig = Buffer.from(signEd25519('hello', kp.privateKey), 'base64url');
  assert.equal(crypto.verify(null, Buffer.from('hello'), rebuilt, sig), true);
  assert.equal(crypto.verify(null, Buffer.from('hellp'), rebuilt, sig), false);
});
