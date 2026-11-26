import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { activateDevice, boot, DAY, makeShop, vendorToken, type Harness } from './helpers.ts';
import { verifyLicenceToken } from '../src/licence.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

test('suggested plans are added once and can be pressed twice', async () => {
  const A = await vendorToken(h);
  const r1 = await h.call('POST', '/v1/vendor/plans/suggested', { auth: A });
  assert.deepEqual(r1.json.added, ['Starter', 'Business', 'Premium']);
  const r2 = await h.call('POST', '/v1/vendor/plans/suggested', { auth: A });
  assert.deepEqual(r2.json.added, []);
  const f = await h.call('GET', '/v1/vendor/features', { auth: A });
  assert.ok(f.json.features.some((x: any) => x.key === 'ai'));
});

test('a free licence is never billed by the monthly run', async () => {
  const A = await vendorToken(h);
  const plan = (await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: 'Paid test', monthly_fee_minor: 1000 } })).json.id;
  const paid = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Pays', country_code: 'ZW' } });
  const free = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Free shop', country_code: 'ZW' } });
  await h.call('POST', `/v1/vendor/tenants/${paid.json.id}/licences`, { auth: A, body: { months: 3, plan_id: plan } });
  const fl = await h.call('POST', `/v1/vendor/tenants/${free.json.id}/licences`, { auth: A, body: { months: 3, plan_id: plan, complimentary: true } });
  assert.equal(fl.json.complimentary, true);
  const dry = await h.call('POST', '/v1/vendor/billing/run', { auth: A, body: { month: '2026-11', dry_run: true } });
  const names = (dry.json.created as any[]).map((c) => c.tenant_name);
  assert.ok(names.includes('Pays'));
  assert.ok(!names.includes('Free shop'));
  // Switching it back to paid makes it billable again.
  await h.call('POST', `/v1/vendor/licences/${fl.json.id}/limits`, { auth: A, body: { complimentary: false } });
  const dry2 = await h.call('POST', '/v1/vendor/billing/run', { auth: A, body: { month: '2026-11', dry_run: true } });
  assert.ok((dry2.json.created as any[]).some((c) => c.tenant_name === 'Free shop'));
});

test('changing a shop\'s plan gives it that plan\'s features and user limit on its phones', async () => {
  const shop = await makeShop(h);
  const A = shop.vendor;
  const basic = (await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: 'Basic X', max_users: 2, features: [] } })).json.id;
  const top = (await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: 'Top X', max_users: 0, features: ['ai', 'customers'] } })).json.id;
  const ch1 = await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/plan`, { auth: A, body: { plan_id: basic } });
  assert.equal(ch1.status, 200);
  const dev = await activateDevice(h, shop.key);
  const tok = (await h.call('POST', '/v1/licence/refresh', { auth: dev.auth })).json.licence_token;
  const p1 = verifyLicenceToken(tok, h.ctx.config.licencePublicKey)!;
  assert.equal(p1.max_users, 2);
  assert.deepEqual(p1.features, []);
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/plan`, { auth: A, body: { plan_id: top } });
  const p2 = verifyLicenceToken((await h.call('POST', '/v1/licence/refresh', { auth: dev.auth })).json.licence_token, h.ctx.config.licencePublicKey)!;
  assert.equal(p2.max_users, 0);
  assert.deepEqual(p2.features, ['ai', 'customers']);
  assert.equal((await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/plan`, { auth: A, body: { plan_id: 'nope' } })).status, 404);
});

test('editing a plan updates the shops on it, unless told not to', async () => {
  const shop = await makeShop(h);
  const A = shop.vendor;
  const plan = (await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: 'Edit me', features: [] } })).json.id;
  await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/plan`, { auth: A, body: { plan_id: plan } });
  const e1 = await h.call('PATCH', `/v1/vendor/plans/${plan}`, { auth: A, body: { features: ['purchasing'], max_devices: 5 } });
  assert.equal(e1.json.licences_updated, 1);
  const row = h.ctx.db.get<{ features: string; max_devices: number }>('select features, max_devices from licences where id = ?', shop.licenceId)!;
  assert.equal(row.features, '["purchasing"]');
  assert.equal(row.max_devices, 5);
  const e2 = await h.call('PATCH', `/v1/vendor/plans/${plan}`, { auth: A, body: { features: ['ai'], apply_to_shops: false } });
  assert.equal(e2.json.licences_updated, 0);
  assert.equal(h.ctx.db.get<{ features: string }>('select features from licences where id = ?', shop.licenceId)!.features, '["purchasing"]');
  assert.equal((await h.call('PATCH', '/v1/vendor/plans/nope', { auth: A, body: {} })).status, 404);
});

test('the invoice logo accepts a small picture only', async () => {
  const A = await vendorToken(h);
  const png = 'data:image/png;base64,iVBORw0KGgo=';
  const ok = await h.call('PUT', '/v1/vendor/billing/profile', { auth: A, body: { logo: png } });
  assert.equal(ok.status, 200);
  assert.equal(ok.json.logo, png);
  const bad = await h.call('PUT', '/v1/vendor/billing/profile', { auth: A, body: { logo: 'data:text/html;base64,PGI+' } });
  assert.equal(bad.status, 400);
  const gone = await h.call('PUT', '/v1/vendor/billing/profile', { auth: A, body: { logo: '' } });
  assert.equal(gone.json.logo, '');
});

test('a trial lasts 10 days with no grace, happens once, and converts to paid', async () => {
  const A = await vendorToken(h);
  const plan = (await h.call('POST', '/v1/vendor/plans', { auth: A, body: { name: 'Trial plan', monthly_fee_minor: 1500, features: ['ai'], max_users: 3 } })).json.id;
  const t = await h.call('POST', '/v1/vendor/tenants', { auth: A, body: { name: 'Trial shop', country_code: 'ZW' } });
  const tr = await h.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, { auth: A, body: { trial: true, plan_id: plan } });
  assert.equal(tr.status, 201);
  assert.equal(tr.json.trial, true);
  assert.equal(tr.json.grace_days, 0);
  assert.equal(tr.json.expires_at - tr.json.issued_at, 10 * DAY);
  assert.deepEqual(tr.json.features, ['ai']);
  // Second trial refused.
  assert.equal((await h.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, { auth: A, body: { trial: true } })).status, 409);
  // The phone sees trial and a recovery key in its signed token.
  const dev = await activateDevice(h, tr.json.key);
  const p = verifyLicenceToken((await h.call('POST', '/v1/licence/refresh', { auth: dev.auth })).json.licence_token, h.ctx.config.licencePublicKey)!;
  assert.equal(p.trial, true);
  assert.match(p.recovery_key ?? '', /^[A-Za-z0-9_-]{16,}$/);
  // Trials are not billed.
  const dry = await h.call('POST', '/v1/vendor/billing/run', { auth: A, body: { month: '2026-11', dry_run: true } });
  assert.ok(!(dry.json.created as any[]).some((c) => c.tenant_name === 'Trial shop'));
  // Convert.
  assert.equal((await h.call('POST', `/v1/vendor/licences/${tr.json.id}/convert`, { auth: A, body: { plan_id: plan } })).status, 400);
  const cv = await h.call('POST', `/v1/vendor/licences/${tr.json.id}/convert`, { auth: A, body: { plan_id: plan, months: 3 } });
  assert.equal(cv.status, 200);
  assert.equal(cv.json.trial, false);
  assert.equal(cv.json.grace_days, 30);
  assert.ok(cv.json.expires_at - h.ctx.now() > 80 * DAY);
  assert.equal((await h.call('POST', `/v1/vendor/licences/${tr.json.id}/convert`, { auth: A, body: { plan_id: plan, months: 3 } })).status, 409);
  const dry2 = await h.call('POST', '/v1/vendor/billing/run', { auth: A, body: { month: '2026-11', dry_run: true } });
  assert.ok((dry2.json.created as any[]).some((c) => c.tenant_name === 'Trial shop'));
});

test('the vendor can give a PIN reset code that matches the phone\'s own calculation, and it is logged', async () => {
  const { pinResetCode } = await import('../src/crypto.ts');
  const shop = await makeShop(h);
  const A = shop.vendor;
  const dev = await activateDevice(h, shop.key);
  const tok = verifyLicenceToken((await h.call('POST', '/v1/licence/refresh', { auth: dev.auth })).json.licence_token, h.ctx.config.licencePublicKey)!;
  const r = await h.call('POST', `/v1/vendor/devices/${dev.id}/pin-reset`, { auth: A, body: { user_id: 'user-1', challenge: '12345678' } });
  assert.equal(r.status, 200);
  assert.equal(r.json.code, pinResetCode(tok.recovery_key!, '12345678', 'user-1'));
  assert.match(r.json.code, /^\d{8}$/);
  assert.notEqual(r.json.code, pinResetCode(tok.recovery_key!, '12345678', 'user-2'));
  assert.equal((await h.call('POST', `/v1/vendor/devices/${dev.id}/pin-reset`, { auth: A, body: { user_id: 'u', challenge: '12' } })).status, 400);
  assert.equal((await h.call('POST', '/v1/vendor/devices/nope/pin-reset', { auth: A, body: { user_id: 'u', challenge: '12345678' } })).status, 404);
  assert.ok(h.ctx.db.get("select 1 as x from vendor_audit_log where action = 'device.pin_reset_code'"));
  assert.equal((await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}/users`, { auth: A })).status, 200);
});
