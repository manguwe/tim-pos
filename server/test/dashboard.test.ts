import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { request } from 'node:http';
import { boot, vendorToken } from './helpers.ts';
import { loadConfig } from '../src/config.ts';

function site() {
  const dir = mkdtempSync(join(tmpdir(), 'dash-'));
  writeFileSync(join(dir, 'index.html'), '<!doctype html><title>TIM-POS</title><script type="module" src="app-ABCD1234.js"></script>');
  writeFileSync(join(dir, 'app-ABCD1234.js'), 'console.log(1)');
  writeFileSync(join(dir, 'app.css'), 'body{}');
  writeFileSync(join(dir, 'secret.exe'), 'x');
  mkdirSync(join(dir, 'sub'));
  writeFileSync(join(dir, '..', `${basename(dir)}-outside.txt`), 'outside');
  return dir;
}

const raw = (url: string, path: string, method = 'GET') =>
  new Promise<{ status: number; headers: Record<string, any>; body: string }>((ok, bad) => {
    const u = new URL(url);
    const r = request({ host: u.hostname, port: u.port, path, method }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => ok({ status: res.statusCode ?? 0, headers: res.headers, body }));
    });
    r.on('error', bad);
    r.end();
  });

test('the dashboard is served with strict headers and sensible caching', async () => {
  const h = await boot({ dashboardDir: site() });
  try {
    const page = await raw(h.url, '/dashboard/');
    assert.equal(page.status, 200);
    assert.match(page.headers['content-type'], /text\/html/);
    assert.match(page.headers['content-security-policy'], /script-src 'self'/);
    assert.match(page.headers['content-security-policy'], /frame-ancestors 'none'/);
    assert.equal(page.headers['x-frame-options'], 'DENY');
    assert.equal(page.headers['cache-control'], 'no-cache');
    assert.match(page.body, /TIM-POS/);
    const js = await raw(h.url, '/dashboard/app-ABCD1234.js');
    assert.equal(js.status, 200);
    assert.match(js.headers['content-type'], /javascript/);
    assert.match(js.headers['cache-control'], /immutable/);
    assert.equal(js.headers['content-security-policy'], undefined);
    assert.equal((await raw(h.url, '/dashboard/app.css')).headers['cache-control'], 'no-cache');
    assert.equal((await raw(h.url, '/dashboard/index.html', 'HEAD')).body, '');
    const bare = await raw(h.url, '/dashboard');
    assert.deepEqual([bare.status, bare.headers.location], [301, '/dashboard/']);
  } finally { await h.close(); }
});

test('only real web files are served, and nothing outside the folder', async () => {
  const dir = site();
  const h = await boot({ dashboardDir: dir });
  try {
    for (const p of ['/dashboard/secret.exe', '/dashboard/nope.js', '/dashboard/sub', '/dashboard/%2e%2e/x.txt', '/dashboard/..%2f..%2fetc/passwd', '/dashboard/../../etc/passwd']) {
      assert.equal((await raw(h.url, p)).status, 404, p);
    }
    assert.equal((await raw(h.url, '/dashboard/%00.js')).status, 400);
    assert.equal((await raw(h.url, '/dashboard/a%5Cb.js')).status, 400);
    assert.equal((await raw(h.url, '/dashboard/%E0%A4%A')).status, 400);
    assert.equal((await raw(h.url, '/dashboard/', 'POST')).status, 405);
    assert.equal((await raw(h.url, '/dashboard/', 'DELETE')).status, 405);
  } finally { await h.close(); }
});

test('without a dashboard folder the API still works and /dashboard is a 404', async () => {
  const h = await boot({ dashboardDir: null });
  try {
    assert.equal((await raw(h.url, '/dashboard/')).status, 404);
    assert.equal((await h.call('GET', '/health')).status, 200);
  } finally { await h.close(); }
});

test('the folder comes from DASHBOARD_DIR, and an empty value turns it off', () => {
  assert.equal(loadConfig({ NODE_ENV: 'production', LICENCE_PRIVATE_KEY: 'a', LICENCE_PUBLIC_KEY: 'b', VENDOR_TOKEN_SECRET: 'c', LICENCE_KEY_PEPPER: 'd', DASHBOARD_DIR: '/srv/dash' }).dashboardDir, '/srv/dash');
  assert.equal(loadConfig({ NODE_ENV: 'production', LICENCE_PRIVATE_KEY: 'a', LICENCE_PUBLIC_KEY: 'b', VENDOR_TOKEN_SECRET: 'c', LICENCE_KEY_PEPPER: 'd', DASHBOARD_DIR: '' }).dashboardDir, null);
});

test('the audit log names the vendor who did each action', async () => {
  const h = await boot();
  try {
    const auth = await vendorToken(h);
    const t = await h.call('POST', '/v1/vendor/tenants', { auth, body: { name: 'Shop A', country_code: 'ZW' } });
    assert.equal(t.status, 201);
    const log = await h.call('GET', '/v1/vendor/audit?limit=5', { auth });
    const e = log.json.entries.find((x: any) => x.action === 'tenant.create');
    assert.ok(e.vendor_name && e.vendor_email);
  } finally { await h.close(); }
});

test('the bare address sends people to the dashboard', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'tim-dash-'));
  writeFileSync(join(dir, 'index.html'), '<!doctype html><title>x</title>');
  const hh = await boot({ dashboardDir: dir });
  try {
    const res = await fetch(`${hh.url}/`, { redirect: 'manual' });
    assert.equal(res.status, 302);
    assert.equal(res.headers.get('location'), '/dashboard/');
  } finally { await hh.close(); }
});
