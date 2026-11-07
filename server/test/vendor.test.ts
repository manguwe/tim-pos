import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { totpCode } from '../src/crypto.ts';
import { createVendorUser } from '../src/services/vendor.ts';
import { DAY, VENDOR_PASSWORD, activateDevice, boot, makeShop, vendorToken, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

test('every vendor endpoint refuses callers who are not signed in', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const endpoints: [string, string][] = [
    ['GET', '/v1/vendor/overview'], ['GET', '/v1/vendor/tenants'], ['POST', '/v1/vendor/tenants'],
    ['GET', `/v1/vendor/tenants/${shop.tenantId}`], ['PATCH', `/v1/vendor/tenants/${shop.tenantId}`],
    ['GET', '/v1/vendor/plans'], ['POST', '/v1/vendor/plans'], ['POST', `/v1/vendor/tenants/${shop.tenantId}/licences`],
    ['POST', `/v1/vendor/licences/${shop.licenceId}/extend`], ['POST', `/v1/vendor/licences/${shop.licenceId}/suspend`],
    ['POST', `/v1/vendor/licences/${shop.licenceId}/resume`], ['POST', `/v1/vendor/licences/${shop.licenceId}/limits`],
    ['POST', `/v1/vendor/licences/${shop.licenceId}/rotate-key`], ['POST', `/v1/vendor/devices/${d.id}/release`],
    ['POST', '/v1/vendor/releases'], ['GET', '/v1/vendor/releases'], ['GET', '/v1/vendor/audit'],
    ['POST', '/v1/vendor/2fa/setup'], ['POST', '/v1/vendor/2fa/enable'],
  ];
  for (const [method, path] of endpoints) {
    assert.equal((await h.call(method, path, { body: {} })).status, 401, `${method} ${path} with no sign-in`);
    // A shop phone's credentials must not work on vendor routes either.
    assert.equal((await h.call(method, path, { body: {}, auth: d.auth })).status, 401, `${method} ${path} with phone credentials`);
    assert.equal((await h.call(method, path, { body: {}, auth: 'Bearer forged.token' })).status, 401, `${method} ${path} forged`);
  }
});

test('a vendor token does not work on phone endpoints', async () => {
  const shop = await makeShop(h);
  for (const [m, p] of [['POST', '/v1/sync/push'], ['GET', '/v1/sync/pull'], ['POST', '/v1/licence/refresh']] as const) {
    assert.equal((await h.call(m, p, { auth: shop.vendor, body: {} })).status, 401);
  }
});

test('a vendor sign-in expires after 12 hours', async () => {
  const token = await vendorToken(h);
  assert.equal((await h.call('GET', '/v1/vendor/overview', { auth: token })).status, 200);
  h.clock.t += 11 * 3_600_000;
  assert.equal((await h.call('GET', '/v1/vendor/overview', { auth: token })).status, 200);
  h.clock.t += 2 * 3_600_000;
  assert.equal((await h.call('GET', '/v1/vendor/overview', { auth: token })).status, 401);
});

test('a tampered vendor token is refused', async () => {
  const token = (await vendorToken(h)).replace('Bearer ', '');
  const [body, sig] = token.split('.') as [string, string];
  const claims = JSON.parse(Buffer.from(body, 'base64url').toString());
  claims.exp += 10 * DAY;
  const forged = `${Buffer.from(JSON.stringify(claims)).toString('base64url')}.${sig}`;
  assert.equal((await h.call('GET', '/v1/vendor/overview', { auth: `Bearer ${forged}` })).status, 401);
});

test('wrong passwords are refused with one message for any reason, and repeated failures lock the account for a while', async () => {
  await vendorToken(h);
  const wrongPw = await h.call('POST', '/v1/vendor/login', { body: { email: 'tim@example.com', password: 'nope-nope-nope-1' } });
  const noUser = await h.call('POST', '/v1/vendor/login', { body: { email: 'nobody@example.com', password: 'nope-nope-nope-1' } });
  assert.equal(wrongPw.status, 401);
  assert.deepEqual(wrongPw.json, noUser.json, 'does not reveal which emails exist');
  for (let i = 0; i < 4; i++) await h.call('POST', '/v1/vendor/login', { body: { email: 'tim@example.com', password: 'nope-nope-nope-1' } });
  const locked = await h.call('POST', '/v1/vendor/login', { body: { email: 'tim@example.com', password: VENDOR_PASSWORD } });
  assert.equal(locked.status, 429, 'even the right password is refused while locked');
  h.clock.t += 16 * 60_000;
  assert.equal((await h.call('POST', '/v1/vendor/login', { body: { email: 'tim@example.com', password: VENDOR_PASSWORD } })).status, 200);
});

test('two-factor sign-in: code required, wrong codes refused, and a code cannot be used twice', async () => {
  const h2 = await boot();
  try {
    const token = await vendorToken(h2);
    const setup = await h2.call('POST', '/v1/vendor/2fa/setup', { auth: token });
    assert.equal(setup.status, 200);
    const secret: string = setup.json.secret;
    assert.match(setup.json.otpauth_url, /^otpauth:\/\/totp\//);
    const pending = h2.ctx.db.get<{ totp_pending_sealed: string; totp_enabled: number }>('select totp_pending_sealed, totp_enabled from vendor_users')!;
    assert.equal(pending.totp_enabled, 0, 'setup alone does not turn two-factor on');
    assert.ok(!pending.totp_pending_sealed.includes(secret), 'the waiting secret is encrypted at rest');

    const step = () => Math.floor(h2.clock.t / 30_000);
    assert.equal((await h2.call('POST', '/v1/vendor/2fa/enable', { auth: token, body: { code: '000000' } })).status, 400);
    assert.equal((await h2.call('POST', '/v1/vendor/2fa/enable', { auth: token, body: { code: totpCode(secret, step()) } })).status, 200);
    const active = h2.ctx.db.get<{ totp_secret_sealed: string; totp_pending_sealed: string | null }>('select totp_secret_sealed, totp_pending_sealed from vendor_users')!;
    assert.ok(!active.totp_secret_sealed.includes(secret), 'the active secret is encrypted at rest');
    assert.equal(active.totp_pending_sealed, null, 'the waiting secret moves to active once confirmed');

    const creds = { email: 'tim@example.com', password: VENDOR_PASSWORD };
    const noCode = await h2.call('POST', '/v1/vendor/login', { body: creds });
    assert.equal(noCode.status, 401);
    assert.equal(noCode.json.error.code, 'code_required');

    h2.clock.t += 60_000; // next code window
    const wrong = await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: '123456' } });
    assert.equal(wrong.status, 401);
    const good = totpCode(secret, step());
    assert.equal((await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: good } })).status, 200);
    const replay = await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: good } });
    assert.equal(replay.status, 401, 'the same code is refused the second time');
  } finally {
    await h2.close();
  }
});

test('weak vendor passwords and bad emails are refused when the account is created', async () => {
  const h2 = await boot();
  try {
    await assert.rejects(createVendorUser(h2.ctx, { name: 'x', email: 'a@b.co', password: 'short' }), /12 characters/);
    await assert.rejects(createVendorUser(h2.ctx, { name: 'x', email: 'not-an-email', password: 'long-enough-password' }), /email/);
  } finally {
    await h2.close();
  }
});

test('every vendor action is recorded, and the record cannot be edited or erased', async () => {
  const shop = await makeShop(h, { name: 'Audited Shop' });
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/suspend`, { auth: shop.vendor });
  const log = await h.call('GET', '/v1/vendor/audit?limit=50', { auth: shop.vendor });
  const actions = log.json.entries.map((e: any) => e.action);
  for (const a of ['tenant.create', 'licence.issue', 'licence.suspend', 'vendor.login']) assert.ok(actions.includes(a), a);
  assert.throws(() => h.ctx.db.run("update vendor_audit_log set action = 'x'"), /append-only/);
  assert.throws(() => h.ctx.db.run('delete from vendor_audit_log'), /append-only/);
  // Row-level triggers only fire when there is a row, so put one in the change feed first.
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/resume`, { auth: shop.vendor });
  const phone = await activateDevice(h, shop.key);
  await h.call('POST', '/v1/sync/push', {
    auth: phone.auth,
    body: { batch_id: 'audit-test-batch', changes: [{ table: 'sales', row_id: 'audit-test-row-1', op: 'insert', version: 1, updated_at: 1, data: {} }] },
  });
  assert.ok(h.ctx.db.get('select 1 as x from change_feed'));
  assert.throws(() => h.ctx.db.run("update change_feed set data = '{}'"), /append-only/);
  assert.throws(() => h.ctx.db.run('delete from change_feed'), /append-only/);
});

test('plans, licence limits and the overview reflect what the vendor sets', async () => {
  const h2 = await boot();
  try {
    const vendor = await vendorToken(h2);
    const plan = await h2.call('POST', '/v1/vendor/plans', {
      auth: vendor, body: { name: 'Standard', one_time_fee_minor: 15000, monthly_fee_minor: 1000, max_devices: 3, max_branches: 2, features: ['loyalty', 'layby'] },
    });
    assert.equal(plan.status, 201);
    assert.equal((await h2.call('POST', '/v1/vendor/plans', { auth: vendor, body: { name: 'Standard' } })).status, 409);

    const t = await h2.call('POST', '/v1/vendor/tenants', { auth: vendor, body: { name: 'Plan Shop', country_code: 'ZW' } });
    const l = await h2.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, { auth: vendor, body: { plan_id: plan.json.id, months: 12 } });
    assert.equal(l.json.max_devices, 3);
    assert.deepEqual(l.json.features, ['loyalty', 'layby']);
    const dev = await activateDevice(h2, l.json.key);
    const lim = await h2.call('POST', `/v1/vendor/licences/${l.json.id}/limits`, { auth: vendor, body: { max_devices: 5, features: ['loyalty'] } });
    assert.equal(lim.json.max_devices, 5);
    assert.equal((await h2.call('POST', '/v1/licence/refresh', { auth: dev.auth })).status, 200);

    const o = await h2.call('GET', '/v1/vendor/overview', { auth: vendor });
    assert.equal(o.json.shops, 1);
    assert.equal(o.json.active_licences, 1);
    assert.equal(o.json.devices, 1);
    h2.clock.t += 12 * 30 * DAY + 10 * DAY; // just past the paid year
    const o2 = await h2.call('GET', '/v1/vendor/overview', { auth: await vendorToken(h2) });
    assert.equal(o2.json.in_grace, 1);
    assert.equal(o2.json.active_licences, 0);
  } finally {
    await h2.close();
  }
});

test('bad licence input is refused with a clear reason', async () => {
  const shop = await makeShop(h);
  const url = `/v1/vendor/tenants/${shop.tenantId}/licences`;
  assert.equal((await h.call('POST', url, { auth: shop.vendor, body: {} })).status, 400, 'needs months or a date');
  assert.equal((await h.call('POST', url, { auth: shop.vendor, body: { months: 1, expires_at: 5 } })).status, 400, 'not both');
  assert.equal((await h.call('POST', url, { auth: shop.vendor, body: { months: 0 } })).status, 400);
  assert.equal((await h.call('POST', url, { auth: shop.vendor, body: { months: 1.5 } })).status, 400);
  assert.equal((await h.call('POST', url, { auth: shop.vendor, body: { months: 1, plan_id: 'missing' } })).status, 404);
  assert.equal((await h.call('POST', '/v1/vendor/tenants/missing/licences', { auth: shop.vendor, body: { months: 1 } })).status, 404);
  assert.equal((await h.call('POST', '/v1/vendor/tenants', { auth: shop.vendor, body: { name: 'X', country_code: 'ZWE' } })).status, 400);
});

test('app releases: only https downloads, a checksum is required, and the minimum build forces old phones to update', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const rel = { version: '1.2.0', build_number: 12, min_supported_build: 10, sha256: 'a'.repeat(64), size_bytes: 25_000_000, apk_url: 'https://example.com/tim-pos-1.2.0.apk' };
  assert.equal((await h.call('POST', '/v1/vendor/releases', { auth: shop.vendor, body: { ...rel, apk_url: 'http://example.com/x.apk' } })).status, 400);
  assert.equal((await h.call('POST', '/v1/vendor/releases', { auth: shop.vendor, body: { ...rel, sha256: 'zz' } })).status, 400);
  assert.equal((await h.call('POST', '/v1/vendor/releases', { auth: shop.vendor, body: rel })).status, 201);
  assert.equal((await h.call('POST', '/v1/vendor/releases', { auth: shop.vendor, body: rel })).status, 409, 'build numbers are unique');

  const stale = await h.call('GET', '/v1/app/update?build=9', { auth: d.auth });
  assert.deepEqual([stale.json.update_available, stale.json.must_update], [true, true]);
  const ok = await h.call('GET', '/v1/app/update?build=11', { auth: d.auth });
  assert.deepEqual([ok.json.update_available, ok.json.must_update], [true, false]);
  const current = await h.call('GET', '/v1/app/update?build=12', { auth: d.auth });
  assert.deepEqual([current.json.update_available, current.json.must_update], [false, false]);
  assert.equal((await h.call('GET', '/v1/app/update?build=9')).status, 401, 'updates are for licensed phones only');
});

test('basic server behaviour: health check, unknown routes, bad JSON, and no internals in errors', async () => {
  const health = await h.call('GET', '/health');
  assert.equal(health.status, 200);
  assert.equal(health.json.ok, true);
  assert.equal((await h.call('GET', '/nope')).status, 404);
  const bad = await h.call('POST', '/v1/activate', { rawBody: '{oops', headers: { 'content-type': 'application/json' } });
  assert.equal(bad.status, 400);
  const big = await h.call('POST', '/v1/activate', { rawBody: 'x'.repeat(20_000), headers: { 'content-type': 'application/json' } });
  assert.equal(big.status, 413, 'callers who are not signed in may only send small bodies');
  const err = await h.call('GET', '/v1/vendor/tenants/%00%ff', { auth: await vendorToken(h) });
  assert.equal(err.status, 400, 'a malformed escape is a clean 400, never a 500');
  assert.equal((await h.call('GET', '/v1/vendor/tenants/%ff')).status, 400, 'checked before sign-in too, so strangers cannot trigger errors');
  assert.ok(!JSON.stringify(err.json).includes('/home/'), 'no file paths in errors');
});

test('behind a proxy, a caller cannot dodge the attempt limit by faking the first X-Forwarded-For value', async () => {
  const h2 = await boot({ trustProxy: true });
  try {
    const bad = { licence_key: 'TIM-AAAA-BBBB-CCCC-DDDD', fingerprint: 'fingerprint-1', device_name: 'x', platform: 'android' };
    for (let i = 0; i < 10; i++) {
      await h2.call('POST', '/v1/activate', { body: bad, headers: { 'x-forwarded-for': `1.1.1.${i}, 203.0.113.7` } });
    }
    const r = await h2.call('POST', '/v1/activate', { body: bad, headers: { 'x-forwarded-for': '9.9.9.9, 203.0.113.7' } });
    assert.equal(r.status, 429);
    const other = await h2.call('POST', '/v1/activate', { body: bad, headers: { 'x-forwarded-for': '9.9.9.9, 203.0.113.8' } });
    assert.equal(other.status, 401, 'a genuinely different client is not blocked');
  } finally {
    await h2.close();
  }
});
