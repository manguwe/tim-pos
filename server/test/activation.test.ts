import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { verifyLicenceToken, evaluateLicence } from '../src/licence.ts';
import { DAY, activateDevice, boot, makeShop, vendorToken, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

test('activation returns a signed token for this shop and device, checkable offline with the public key', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const p = verifyLicenceToken(d.token, h.ctx.config.licencePublicKey);
  assert.ok(p);
  assert.equal(p.shop_id, shop.tenantId);
  assert.equal(p.device_id, d.id);
  assert.equal(evaluateLicence(p, h.clock.t).state, 'active');
});

test('the licence key is only stored as a hash, and cannot be read back from the vendor API', async () => {
  const shop = await makeShop(h, { name: 'Hashed Shop' });
  const rows = h.ctx.db.all<Record<string, unknown>>('select * from licences where id = ?', shop.licenceId);
  const stored = JSON.stringify(rows);
  const bare = shop.key.replace(/-/g, '').replace(/^TIM/, '');
  assert.ok(!stored.includes(shop.key) && !stored.includes(bare), 'plain key must not be stored');
  const detail = await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}`, { auth: shop.vendor });
  assert.ok(!JSON.stringify(detail.json).includes(bare), 'plain key must not be returned again');
  assert.equal(detail.json.licences[0].key, undefined);
  assert.equal(detail.json.licences[0].key_hash, undefined);
});

test('a key typed in lower case with spaces still activates', async () => {
  const shop = await makeShop(h);
  const sloppy = shop.key.toLowerCase().replace(/-/g, ' ');
  await activateDevice(h, sloppy);
});

test('a wrong key is refused, and repeated failures from one address are blocked', async () => {
  const shop = await makeShop(h);
  const bad = { licence_key: 'TIM-AAAA-BBBB-CCCC-DDDD', fingerprint: 'fingerprint-1', device_name: 'x', platform: 'android' };
  for (let i = 0; i < 10; i++) {
    const r = await h.call('POST', '/v1/activate', { body: bad });
    assert.equal(r.status, 401);
    assert.equal(r.json.error.code, 'invalid_key');
  }
  const blocked = await h.call('POST', '/v1/activate', { body: bad });
  assert.equal(blocked.status, 429);
  // Even the right key is refused while blocked, so the limit cannot be used to test keys.
  const right = await h.call('POST', '/v1/activate', { body: { ...bad, licence_key: shop.key } });
  assert.equal(right.status, 429);
  h.clock.t += 16 * 60_000;
  const later = await h.call('POST', '/v1/activate', { body: { ...bad, licence_key: shop.key } });
  assert.equal(later.status, 201);
});

test('a licence cannot be shared past its device limit, and the same phone can re-activate', async () => {
  const shop = await makeShop(h, { max_devices: 1 });
  const first = await activateDevice(h, shop.key, 'phone-aaaaaaaa');
  const second = await h.call('POST', '/v1/activate', {
    body: { licence_key: shop.key, fingerprint: 'phone-bbbbbbbb', device_name: 'Other phone', platform: 'android' },
  });
  assert.equal(second.status, 409);
  assert.equal(second.json.error.code, 'device_limit');

  const again = await activateDevice(h, shop.key, 'phone-aaaaaaaa');
  assert.equal(again.id, first.id, 'same phone keeps its slot');
  const old = await h.call('POST', '/v1/licence/refresh', { auth: first.auth });
  assert.equal(old.status, 401, 'the old secret stops working after re-activation');
  const fresh = await h.call('POST', '/v1/licence/refresh', { auth: again.auth });
  assert.equal(fresh.status, 200);
});

test('releasing a device frees its slot and locks that phone out', async () => {
  const shop = await makeShop(h, { max_devices: 1 });
  const lost = await activateDevice(h, shop.key, 'lost-phone-1');
  const rel = await h.call('POST', `/v1/vendor/devices/${lost.id}/release`, { auth: shop.vendor });
  assert.equal(rel.status, 200);
  const r = await h.call('POST', '/v1/licence/refresh', { auth: lost.auth });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'device_released');
  assert.equal(r.json.error.locked, true);
  await activateDevice(h, shop.key, 'replacement-1'); // slot is free again
});

test('a suspended licence locks the phone the next time it connects, and resuming restores it', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/suspend`, { auth: shop.vendor });
  const r = await h.call('POST', '/v1/licence/refresh', { auth: d.auth });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'licence_suspended');
  assert.equal(r.json.error.locked, true);
  const act = await h.call('POST', '/v1/activate', {
    body: { licence_key: shop.key, fingerprint: 'new-phone-1', device_name: 'x', platform: 'android' },
  });
  assert.equal(act.status, 403);
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/resume`, { auth: shop.vendor });
  assert.equal((await h.call('POST', '/v1/licence/refresh', { auth: d.auth })).status, 200);
});

test('suspending the whole shop blocks its phones too', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  await h.call('PATCH', `/v1/vendor/tenants/${shop.tenantId}`, { auth: shop.vendor, body: { status: 'suspended' } });
  assert.equal((await h.call('POST', '/v1/licence/refresh', { auth: d.auth })).status, 403);
  await h.call('PATCH', `/v1/vendor/tenants/${shop.tenantId}`, { auth: shop.vendor, body: { status: 'active' } });
  assert.equal((await h.call('POST', '/v1/licence/refresh', { auth: d.auth })).status, 200);
});

test('after expiry the phone works through the grace period, then is refused for good until renewed', async () => {
  const shop = await makeShop(h, { months: 1, grace_days: 10 });
  const d = await activateDevice(h, shop.key);
  h.clock.t += 35 * DAY; // 1 month + 4 days: in grace
  const inGrace = await h.call('POST', '/v1/licence/refresh', { auth: d.auth });
  assert.equal(inGrace.status, 200);
  const p = verifyLicenceToken(inGrace.json.licence_token, h.ctx.config.licencePublicKey);
  assert.equal(p && evaluateLicence(p, h.clock.t).state, 'grace');

  h.clock.t += 20 * DAY; // past grace
  const out = await h.call('POST', '/v1/licence/refresh', { auth: d.auth });
  assert.equal(out.status, 402);
  assert.equal(out.json.error.locked, true);
  const newPhone = await h.call('POST', '/v1/activate', {
    body: { licence_key: shop.key, fingerprint: 'late-phone-1', device_name: 'x', platform: 'android' },
  });
  assert.equal(newPhone.status, 402);

  // Renewing a lapsed licence restarts from today, not from the old end date.
  // (The vendor's own sign-in lasts 12 hours, so after weeks have passed they sign in again.)
  const vendor = await vendorToken(h);
  const ext = await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/extend`, { auth: vendor, body: { months: 1 } });
  assert.equal(ext.status, 200);
  const oneMonthFromToday = new Date(h.clock.t);
  oneMonthFromToday.setUTCMonth(oneMonthFromToday.getUTCMonth() + 1);
  assert.equal(ext.json.expires_at, oneMonthFromToday.getTime());
  assert.equal((await h.call('POST', '/v1/licence/refresh', { auth: d.auth })).status, 200);
});

test('renewing early adds to the current end date', async () => {
  const shop = await makeShop(h, { months: 1 });
  const before = h.ctx.db.get<{ expires_at: number }>('select expires_at from licences where id = ?', shop.licenceId)!.expires_at;
  const ext = await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/extend`, { auth: shop.vendor, body: { months: 3 } });
  const expected = new Date(before);
  expected.setUTCMonth(expected.getUTCMonth() + 3);
  assert.equal(ext.json.expires_at, expected.getTime());
});

test('token check_by follows max_offline_days, so a shop that never syncs locks on its own', async () => {
  const shop = await makeShop(h, { max_offline_days: 14 });
  const d = await activateDevice(h, shop.key);
  const p = verifyLicenceToken(d.token, h.ctx.config.licencePublicKey)!;
  assert.equal(p.check_by, h.clock.t + 14 * DAY);
  assert.equal(evaluateLicence(p, h.clock.t + 15 * DAY).state, 'locked');
});

test('replacing a leaked key kills the old key but keeps existing phones running', async () => {
  const shop = await makeShop(h, { max_devices: 2 });
  const d = await activateDevice(h, shop.key);
  const rot = await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/rotate-key`, { auth: shop.vendor });
  assert.equal(rot.status, 201);
  assert.notEqual(rot.json.key, shop.key);
  const oldKey = await h.call('POST', '/v1/activate', {
    body: { licence_key: shop.key, fingerprint: 'thief-phone-1', device_name: 'x', platform: 'android' },
  });
  assert.equal(oldKey.status, 401);
  assert.equal((await h.call('POST', '/v1/licence/refresh', { auth: d.auth })).status, 200, 'existing phone keeps working');
  await activateDevice(h, rot.json.key, 'second-phone-1');
});

test('malformed or forged device credentials are refused', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  for (const auth of ['', 'Device', 'Device abc.def', `Device ${d.id}.${'x'.repeat(40)}`, `Bearer ${d.secret}`]) {
    const r = await h.call('POST', '/v1/licence/refresh', auth ? { auth } : {});
    assert.equal(r.status, 401, `auth "${auth.slice(0, 20)}"`);
  }
});

test('every phone gets its own receipt prefix, put in its signed token and never reused', async () => {
  const shop = await makeShop(h, { max_devices: 2 });
  const a = await activateDevice(h, shop.key, 'prefix-phone-a');
  const b = await activateDevice(h, shop.key, 'prefix-phone-b');
  const prefix = (d: { token: string }) => verifyLicenceToken(d.token, h.ctx.config.licencePublicKey)!.receipt_prefix;
  assert.equal(prefix(a), 'D1');
  assert.equal(prefix(b), 'D2');

  const again = await activateDevice(h, shop.key, 'prefix-phone-a');
  assert.equal(prefix(again), 'D1', 'the same phone keeps its prefix when it re-activates');
  const refreshed = await h.call('POST', '/v1/licence/refresh', { auth: again.auth });
  assert.equal(verifyLicenceToken(refreshed.json.licence_token, h.ctx.config.licencePublicKey)!.receipt_prefix, 'D1');

  await h.call('POST', `/v1/vendor/devices/${b.id}/release`, { auth: shop.vendor, body: {} });
  const c = await activateDevice(h, shop.key, 'prefix-phone-c');
  assert.equal(prefix(c), 'D3', 'a released phone\'s prefix is not handed to a new phone');

  const other = await makeShop(h, { name: 'Another Shop' });
  assert.equal(prefix(await activateDevice(h, other.key)), 'D1', 'numbering is per shop');
});
