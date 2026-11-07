import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import net from 'node:net';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { loadConfig } from '../src/config.ts';
import { totpCode } from '../src/crypto.ts';
import { VENDOR_PASSWORD, activateDevice, boot, change, makeShop, push, vendorToken, START, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

// ---- Found by independent review ----

test('a malformed request line cannot crash the server', async () => {
  const port = Number(new URL(h.url).port);
  for (const line of ['GET //[ HTTP/1.1', 'GET http://[::1 HTTP/1.1', 'GET /%zz%ff HTTP/1.1']) {
    await new Promise<void>((resolve) => {
      const s = net.connect(port, '127.0.0.1', () => s.write(`${line}\r\nHost: x\r\nConnection: close\r\n\r\n`));
      s.on('data', () => {});
      s.on('close', () => resolve());
      s.on('error', () => resolve());
    });
  }
  await new Promise((r) => setTimeout(r, 100));
  assert.equal((await h.call('GET', '/health')).status, 200, 'the server is still up');
});

test('huge or non-integer version and updated_at numbers are rejected, so they cannot poison a shop\'s sync', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const row = (o: Record<string, unknown>) => ({ ...change('products', { n: 1 }), ...o });
  const r = await push(h, d, [
    row({ version: 2 ** 53 + 2 }),
    row({ version: 1e300 }),
    row({ version: 2 ** 31 }),
    row({ updated_at: 2 ** 53 + 2 }),
    row({ updated_at: 1e300 }),
    row({ version: 1.5 }),
    row({ version: 5 }),
  ]);
  assert.equal(r.status, 200);
  assert.deepEqual(r.json.rejected.map((x: any) => x.reason), ['bad_version', 'bad_version', 'bad_version', 'bad_updated_at', 'bad_updated_at', 'bad_version']);
  assert.equal(r.json.accepted, 1);
  const other = await activateDevice(h, shop.key);
  assert.equal((await h.call('GET', '/v1/sync/pull?since=0', { auth: other.auth })).status, 200, 'pull still works');
});

test('a phone with its clock set far ahead cannot win every future tie', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const id = randomUUID();
  await push(h, d, [change('customers', { name: 'Future' }, { id, version: 2, updated_at: START + 400 * 86_400_000 })]);
  await push(h, d, [change('customers', { name: 'Honest' }, { id, op: 'update', version: 2, updated_at: START + 1000 })]);
  const stored = h.ctx.db.get<{ data: string; updated_at: number }>(
    "select data, updated_at from records where shop_id = ? and table_name = 'customers'", shop.tenantId)!;
  assert.ok(stored.updated_at <= START + 86_400_000, 'the stored tie-break time is capped at one day ahead');
});

test('two phones of one shop may use the same batch id; a batch id is never silently dropped', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  const ra = await push(h, a, [change('sales', { n: 'from A' })], 'batch-0001');
  const rb = await push(h, b, [change('sales', { n: 'from B' })], 'batch-0001');
  assert.equal(ra.json.accepted, 1);
  assert.equal(rb.json.duplicate, false);
  assert.equal(rb.json.accepted, 1, "B's rows were stored");
  // The same phone reusing an id for different content is a bug in the app, and it must be told.
  const bad = await push(h, a, [change('sales', { n: 'different' })], 'batch-0001');
  assert.equal(bad.status, 409);
  assert.equal(bad.json.error.code, 'batch_id_reused');
  // An exact resend is still fine.
  const same = await h.call('POST', '/v1/sync/push', { auth: a.auth, body: { batch_id: 'batch-0001', changes: [] } });
  assert.equal(same.status, 409, 'different content (here: none) under a used id is refused too');
});

test('non-integer limits give a clear 400 or a safe default, never a 500', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  for (const q of ['limit=1.5', 'limit=abc', 'limit=-1', 'limit=0', 'limit=1e300']) {
    const r = await h.call('GET', `/v1/sync/pull?since=0&${q}`, { auth: d.auth });
    assert.ok(r.status === 400, `pull ${q} gave ${r.status}`);
  }
  for (const q of ['limit=1.5', 'limit=abc', 'limit=-1', 'limit=1e300']) {
    const r = await h.call('GET', `/v1/vendor/audit?${q}`, { auth: shop.vendor });
    assert.equal(r.status, 200, `audit ${q}`);
  }
  assert.equal((await h.call('GET', '/v1/sync/pull?since=1e300', { auth: d.auth })).status, 400);
  assert.equal((await h.call('GET', '/v1/sync/pull?since=1.5', { auth: d.auth })).status, 400);
});

test('names that exist on every JavaScript object are not accepted as table names', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const names = ['constructor', '__proto__', 'toString', 'hasOwnProperty', 'valueOf'];
  const r = await push(h, d, names.map((table) => ({ table, row_id: randomUUID(), op: 'insert', version: 1, updated_at: START, data: {} })));
  assert.equal(r.json.accepted, 0);
  assert.deepEqual(r.json.rejected.map((x: any) => x.reason), names.map(() => 'unknown_table'));
});

test('a deeply nested row is rejected with a reason instead of crashing the batch', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const deep = '{"a":'.repeat(20_000) + '1' + '}'.repeat(20_000); // built as text: stringifying it would overflow the test itself
  const raw = `{"batch_id":"deep-batch-1","changes":[{"table":"sales","row_id":"${randomUUID()}","op":"insert","version":1,"updated_at":1,"data":${deep}},` +
    `{"table":"sales","row_id":"${randomUUID()}","op":"insert","version":1,"updated_at":1,"data":{"ok":true}}]}`;
  const r = await h.call('POST', '/v1/sync/push', { auth: d.auth, rawBody: raw, headers: { 'content-type': 'application/json' } });
  assert.equal(r.status, 200);
  assert.equal(r.json.accepted, 1, 'the good row in the same batch is kept');
  assert.equal(r.json.rejected[0].reason, 'data_too_deep');
  // a row just inside the limit still round-trips through pull
  let ok: unknown = 1;
  for (let i = 0; i < 20; i++) ok = { a: ok };
  const other = await activateDevice(h, shop.key);
  assert.equal((await push(h, d, [change('sales', ok as Record<string, unknown>)])).json.accepted, 1);
  assert.equal((await h.call('GET', '/v1/sync/pull?since=0', { auth: other.auth })).status, 200);
});

test('a phone whose cursor is ahead of the server (server restored from an older backup) is told to start again', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  await push(h, a, [change('sales', { n: 1 })]);
  const r = await h.call('GET', '/v1/sync/pull?since=5000', { auth: b.auth });
  assert.equal(r.status, 409);
  assert.equal(r.json.error.code, 'cursor_ahead');
  assert.equal(typeof r.json.error.head_seq, 'number');
  const detail = await h.call('GET', `/v1/vendor/tenants/${shop.tenantId}`, { auth: shop.vendor });
  assert.ok(detail.json.devices.find((x: any) => x.id === b.id).last_pull_seq <= r.json.error.head_seq, 'a phone cannot fake the vendor\'s "behind" figure');
  const again = await h.call('GET', '/v1/sync/pull?since=0', { auth: b.auth });
  assert.equal(again.json.changes.length, 1);
});

test('a released phone that is blocked cannot simply activate again with the same key', async () => {
  const shop = await makeShop(h, { max_devices: 2 });
  const stolen = await activateDevice(h, shop.key, 'stolen-phone-01');
  await h.call('POST', `/v1/vendor/devices/${stolen.id}/release`, { auth: shop.vendor, body: {} });
  const again = await h.call('POST', '/v1/activate', {
    body: { licence_key: shop.key, fingerprint: 'stolen-phone-01', device_name: 'x', platform: 'android' },
  });
  assert.equal(again.status, 403);
  assert.equal(again.json.error.code, 'device_blocked');

  const kept = await activateDevice(h, shop.key, 'owner-phone-01');
  await h.call('POST', `/v1/vendor/devices/${kept.id}/release`, { auth: shop.vendor, body: { block: false } });
  await activateDevice(h, shop.key, 'owner-phone-01'); // released by mistake: allowed back
});

test('the development secrets file is private from the moment it is created', { skip: process.platform === 'win32' && 'Windows has no Unix file modes' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'timpos-cfg-'));
  try {
    const warn = console.warn;
    console.warn = () => {};
    try { loadConfig({ DATA_DIR: dir } as NodeJS.ProcessEnv); } finally { console.warn = warn; }
    assert.equal(statSync(join(dir, 'dev-secrets.json')).mode & 0o777, 0o600);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// ---- Vendor sign-in and two-factor ----

test('two-factor cannot be switched off or replaced with only a stolen sign-in token', async () => {
  const h2 = await boot();
  try {
    const token = await vendorToken(h2);
    const step = () => Math.floor(h2.clock.t / 30_000);
    const setup = await h2.call('POST', '/v1/vendor/2fa/setup', { auth: token, body: {} });
    await h2.call('POST', '/v1/vendor/2fa/enable', { auth: token, body: { code: totpCode(setup.json.secret, step()) } });

    // Starting setup again without a current code is refused, and 2FA stays on.
    const sneaky = await h2.call('POST', '/v1/vendor/2fa/setup', { auth: token, body: {} });
    assert.equal(sneaky.status, 401);
    assert.equal(h2.ctx.db.get<{ totp_enabled: number }>('select totp_enabled from vendor_users')!.totp_enabled, 1);

    // With a current code it is allowed, but the old secret keeps working until the new one is confirmed.
    h2.clock.t += 60_000;
    const re = await h2.call('POST', '/v1/vendor/2fa/setup', { auth: token, body: { code: totpCode(setup.json.secret, step()) } });
    assert.equal(re.status, 200);
    h2.clock.t += 60_000;
    const creds = { email: 'tim@example.com', password: VENDOR_PASSWORD };
    const withOld = await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: totpCode(setup.json.secret, step()) } });
    assert.equal(withOld.status, 200, 'an abandoned setup does not lock the vendor out');
    h2.clock.t += 60_000;
    assert.equal((await h2.call('POST', '/v1/vendor/2fa/enable', { auth: token, body: { code: totpCode(re.json.secret, step()) } })).status, 200);
    h2.clock.t += 60_000;
    assert.equal((await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: totpCode(setup.json.secret, step()) } })).status, 401, 'old secret is retired');
    assert.equal((await h2.call('POST', '/v1/vendor/login', { body: { ...creds, code: totpCode(re.json.secret, step()) } })).status, 200);
  } finally {
    await h2.close();
  }
});

test('the same two-factor code used by two sign-ins at the same moment works only once', async () => {
  const h2 = await boot();
  try {
    const token = await vendorToken(h2);
    const step = () => Math.floor(h2.clock.t / 30_000);
    const setup = await h2.call('POST', '/v1/vendor/2fa/setup', { auth: token, body: {} });
    await h2.call('POST', '/v1/vendor/2fa/enable', { auth: token, body: { code: totpCode(setup.json.secret, step()) } });
    h2.clock.t += 60_000;
    const body = { email: 'tim@example.com', password: VENDOR_PASSWORD, code: totpCode(setup.json.secret, step()) };
    const results = await Promise.all(Array.from({ length: 6 }, () => h2.call('POST', '/v1/vendor/login', { body })));
    assert.equal(results.filter((r) => r.status === 200).length, 1);
  } finally {
    await h2.close();
  }
});

test('a stranger failing logins cannot lock the real vendor out from their own address', async () => {
  const h2 = await boot({ trustProxy: true });
  try {
    await vendorToken(h2);
    const from = (ip: string) => ({ 'x-forwarded-for': ip });
    for (let i = 0; i < 8; i++) {
      await h2.call('POST', '/v1/vendor/login', { headers: from('203.0.113.50'), body: { email: 'tim@example.com', password: `guess-number-${i}-xx` } });
    }
    const attacker = await h2.call('POST', '/v1/vendor/login', { headers: from('203.0.113.50'), body: { email: 'tim@example.com', password: VENDOR_PASSWORD } });
    assert.equal(attacker.status, 429, 'the attacker\'s own address is blocked');
    const real = await h2.call('POST', '/v1/vendor/login', { headers: from('198.51.100.9'), body: { email: 'tim@example.com', password: VENDOR_PASSWORD } });
    assert.equal(real.status, 200, 'the vendor, from elsewhere, can still sign in');
  } finally {
    await h2.close();
  }
});

test('after a restore, phones that name the old sync epoch are told to start over', async () => {
  const shop = await makeShop(h);
  const a = await activateDevice(h, shop.key);
  const b = await activateDevice(h, shop.key);
  await push(h, a, [change('sales', { n: 1 })]);
  const first = await h.call('GET', '/v1/sync/pull?since=0', { auth: b.auth });
  const epoch: string = first.json.epoch;
  assert.match(epoch, /^[0-9a-f]{32}$/);
  assert.equal((await h.call('GET', `/v1/sync/pull?since=${first.json.next_seq}&epoch=${epoch}`, { auth: b.auth })).status, 200);
  // what "new-sync-epoch" does after the database is restored from a backup
  h.ctx.db.run("update meta set value = lower(hex(randomblob(16))) where key = 'sync_epoch'");
  const stale = await h.call('GET', `/v1/sync/pull?since=${first.json.next_seq}&epoch=${epoch}`, { auth: b.auth });
  assert.equal(stale.status, 409);
  assert.equal(stale.json.error.code, 'epoch_changed');
  assert.notEqual(stale.json.error.epoch, epoch);
  const restart = await h.call('GET', `/v1/sync/pull?since=0&epoch=${stale.json.error.epoch}`, { auth: b.auth });
  assert.equal(restart.status, 200);
  assert.equal(restart.json.changes.length, 1);
});
