// End-to-end check of the dashboard in a real browser against a real server.
//   node --disable-warning=ExperimentalWarning e2e/smoke.mjs            (after `npm run build`)
// Needs Playwright with Chromium (npm i -D playwright && npx playwright install chromium). Set PLAYWRIGHT_DIR if it lives elsewhere.
import { spawn, spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const server = join(root, 'server');
const { totpCode } = await import(join(server, 'src', 'crypto.ts'));
const req = createRequire(process.env.PLAYWRIGHT_DIR ? join(process.env.PLAYWRIGHT_DIR, 'x.js') : import.meta.url);
const { chromium } = req('playwright');

const data = mkdtempSync(join(tmpdir(), 'tim-e2e-'));
const shots = process.env.SHOTS ?? join(data, 'shots');
mkdirSync(shots, { recursive: true });
const PORT = 18080 + Math.floor(Math.random() * 500);
const env = { ...process.env, DATA_DIR: data, PORT: String(PORT), HOST: '127.0.0.1', LOG: '0', DASHBOARD_DIR: join(here, '..', 'dist'), VENDOR_PASSWORD: 'a-long-test-password', NODE_NO_WARNINGS: '1' };
const made = spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', 'src/cli.ts', 'create-vendor', '--name', 'Tim', '--email', 'tim@example.com'], { cwd: server, env, encoding: 'utf8' });
assert.equal(made.status, 0, made.stderr);
const made2 = spawnSync(process.execPath, ['--disable-warning=ExperimentalWarning', 'src/cli.ts', 'create-vendor', '--name', 'Api', '--email', 'api@example.com'], { cwd: server, env, encoding: 'utf8' });
assert.equal(made2.status, 0, made2.stderr);
const srv = spawn(process.execPath, ['--disable-warning=ExperimentalWarning', 'src/server.ts'], { cwd: server, env, stdio: 'inherit' });
const base = `http://127.0.0.1:${PORT}`;
for (let i = 0; i < 50; i++) { try { if ((await fetch(`${base}/health`)).ok) break; } catch { /* starting */ } await new Promise((r) => setTimeout(r, 100)); }

const browser = await chromium.launch();
const problems = [];
let step = 'start';
const ok = (m) => console.log(`ok  ${m}`);
try {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 850 } });
  const page = await ctx.newPage();
  page.on('pageerror', (e) => problems.push(`pageerror: ${e.message}`));
  page.on('console', (m) => { if (m.type() === 'error' && !/status of 401/.test(m.text())) problems.push(`console: ${m.text()}`); });
  page.on('requestfailed', (r) => problems.push(`request failed: ${r.url()}`));

  step = 'login';
  await page.goto(`${base}/dashboard/`);
  await page.getByLabel('Email').fill('tim@example.com');
  await page.getByLabel('Password').fill('wrong-password-here');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('alert').waitFor();
  assert.match(await page.getByRole('alert').innerText(), /not correct/);
  await page.getByLabel('Password').fill('a-long-test-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('heading', { name: 'Overview' }).waitFor();
  ok('sign in (wrong password refused, right one works)');
  await page.screenshot({ path: join(shots, '1-overview-empty.png') });

  step = 'create shop';
  await page.getByRole('link', { name: 'Shops', exact: true }).click();
  await page.getByRole('button', { name: 'New shop' }).click();
  await page.getByLabel('Shop name').fill('Mbare Mini Market');
  await page.getByLabel('Contact (optional)').fill('Mrs Moyo 0772 000 111');
  await page.getByRole('button', { name: 'Create shop' }).click();
  await page.getByRole('heading', { name: 'Mbare Mini Market' }).waitFor();
  ok('create shop');

  step = 'create plan';
  await page.getByRole('link', { name: 'Plans' }).click();
  await page.getByRole('button', { name: 'New plan' }).click();
  await page.getByLabel('Plan name').fill('Standard');
  await page.getByLabel('Once-off fee').fill('120');
  await page.getByLabel('Monthly fee').fill('15.50');
  await page.getByLabel('Phones').fill('2');
  await page.getByLabel('Features').fill('zimra, loyalty');
  await page.getByRole('button', { name: 'Create plan' }).click();
  await page.getByRole('cell', { name: 'Standard' }).waitFor();
  assert.match(await page.locator('tbody').innerText(), /USD 15\.50/);
  ok('create plan (money shown correctly)');

  step = 'issue licence';
  await page.getByRole('link', { name: 'Shops', exact: true }).click();
  await page.getByRole('link', { name: 'Mbare Mini Market' }).click();
  await page.getByRole('button', { name: 'Issue licence' }).click();
  await page.getByLabel('Plan').selectOption({ label: 'Standard' });
  await page.getByRole('button', { name: 'Issue licence' }).last().click();
  const key = (await page.getByTestId('secret').innerText()).trim();
  assert.ok(key.length >= 10, 'licence key shown');
  await page.screenshot({ path: join(shots, '2-key-once.png') });
  await page.getByRole('button', { name: 'I have saved it' }).click();
  await page.getByText('Key ending').waitFor();
  assert.match(await page.locator('.card', { hasText: 'Key ending' }).first().innerText(), /2 \/ 1/);
  ok('issue licence from a plan (key shown once, limits from plan)');

  step = 'activate a phone and see it';
  const act = await fetch(`${base}/v1/activate`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ licence_key: key, fingerprint: 'e2e-fingerprint-0001', device_name: 'Till 1', platform: 'android', app_version: '1.0.0' }) });
  assert.equal(act.status, 201);
  await page.reload();
  await page.getByRole('cell', { name: /Till 1/ }).waitFor();
  await page.screenshot({ path: join(shots, '3-shop-detail.png'), fullPage: true });
  ok('activated phone appears');

  step = 'licence actions';
  await page.getByRole('button', { name: 'Extend' }).click();
  await page.getByRole('spinbutton', { name: 'Months' }).fill('3');
  await page.getByRole('button', { name: 'Extend' }).last().click();
  await page.getByText('Licence extended.').waitFor();
  await page.getByRole('button', { name: 'Limits' }).click();
  await page.getByLabel('Phones').fill('5');
  await page.getByRole('button', { name: 'Save limits' }).click();
  await page.getByText('Limits saved.').waitFor();
  assert.match(await page.locator('.card', { hasText: 'Key ending' }).first().innerText(), /5 \/ 1/);
  await page.getByRole('button', { name: 'Suspend', exact: true }).click();
  await page.getByRole('button', { name: 'Suspend licence' }).click();
  await page.getByText('Licence suspended.').waitFor();
  await page.getByRole('button', { name: 'Resume', exact: true }).click();
  await page.getByRole('button', { name: 'Resume licence' }).click();
  await page.getByText('Licence resumed.').waitFor();
  await page.getByRole('button', { name: 'New key' }).click();
  await page.getByRole('button', { name: 'Make new key' }).click();
  const key2 = (await page.getByTestId('secret').innerText()).trim();
  assert.notEqual(key2, key);
  await page.getByRole('button', { name: 'I have saved it' }).click();
  ok('extend, limits, suspend, resume, new key');

  step = 'release phone';
  await page.getByRole('button', { name: 'Release' }).click();
  await page.getByRole('button', { name: 'Release phone' }).click();
  await page.getByText('Phone released.').waitFor();
  await page.getByText(/Released/).first().waitFor();
  ok('release phone');

  step = 'suspend shop and filters';
  await page.getByRole('button', { name: 'Suspend shop' }).click();
  await page.getByRole('button', { name: 'Suspend shop' }).last().click();
  await page.getByText('This shop is suspended').waitFor();
  await page.getByRole('link', { name: 'Shops', exact: true }).first().click();
  await page.getByLabel('Filter').selectOption('suspended');
  await page.getByRole('link', { name: 'Mbare Mini Market' }).waitFor();
  await page.getByLabel('Search shops').fill('zzz');
  await page.getByText('No shop matches.').waitFor();
  ok('shop suspend, list filters');

  step = 'releases';
  await page.getByRole('link', { name: 'App releases' }).click();
  await page.getByRole('button', { name: 'Publish release' }).click();
  await page.getByLabel('Version').fill('1.0.1');
  await page.getByLabel('Build number').fill('2');
  await page.getByLabel('File size (bytes)').fill('21000000');
  await page.getByLabel('Download address').fill('https://example.com/tim-pos.apk');
  await page.getByLabel('SHA-256 checksum').fill('abc');
  await page.getByRole('button', { name: 'Publish', exact: true }).click();
  await page.getByRole('alert').waitFor();
  assert.match(await page.getByRole('alert').innerText(), /64 letters/);
  await page.getByLabel('SHA-256 checksum').fill('a'.repeat(64));
  await page.getByRole('button', { name: 'Publish', exact: true }).click();
  await page.getByRole('link', { name: '1.0.1' }).waitFor();
  ok('publish release (bad checksum refused)');

  step = 'audit';
  await page.getByRole('link', { name: 'Audit log' }).click();
  await page.getByRole('cell', { name: 'licence.rotate_key' }).waitFor();
  assert.match(await page.locator('tbody').innerText(), /Tim/);
  await page.getByLabel('Filter', { exact: true }).fill('release.publish');
  assert.equal(await page.locator('tbody tr').count(), 1);
  ok('audit log shows who did what');

  step = 'overview with data';
  await page.getByRole('link', { name: 'Overview' }).click();
  await page.getByRole('heading', { name: 'Needs attention' }).waitFor();
  await page.getByRole('cell', { name: /Shop suspended/ }).waitFor();
  await page.screenshot({ path: join(shots, '4-overview.png'), fullPage: true });
  ok('overview lists the suspended shop');

  step = 'phone layout';
  const phone = await browser.newContext({ viewport: { width: 390, height: 800 } });
  const p2 = await phone.newPage();
  p2.on('pageerror', (e) => problems.push(`phone pageerror: ${e.message}`));
  await p2.goto(`${base}/dashboard/`);
  await p2.getByLabel('Email').fill('tim@example.com');
  await p2.getByLabel('Password').fill('a-long-test-password');
  await p2.getByRole('button', { name: 'Sign in' }).click();
  await p2.getByRole('heading', { name: 'Overview' }).waitFor();
  const overflow = await p2.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  assert.ok(overflow <= 1, `no sideways page scroll on a phone (was ${overflow}px)`);
  await p2.screenshot({ path: join(shots, '5-phone.png') });
  ok('phone layout has no sideways scroll');

  step = 'two-factor';
  await page.getByRole('link', { name: 'My account' }).click();
  await page.getByRole('button', { name: 'Turn on two-factor' }).click();
  const secret = (await page.getByTestId('totp-secret').innerText()).replace(/\s/g, '');
  const stepNow = Math.floor(Date.now() / 30000);
  await page.getByLabel('Then enter the 6-digit code it shows').fill(totpCode(secret, stepNow));
  await page.getByRole('button', { name: 'Turn on', exact: true }).click();
  await page.getByText('Two-factor sign-in is on.').waitFor();
  await page.getByRole('button', { name: 'Sign out' }).first().click();
  await page.getByLabel('Email').fill('tim@example.com');
  await page.getByLabel('Password').fill('a-long-test-password');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByLabel('Code from your authenticator app').waitFor();
  await page.getByLabel('Code from your authenticator app').fill(totpCode(secret, stepNow + 1)); // the first code was used already
  await page.getByRole('button', { name: 'Verify and sign in' }).click();
  await page.getByRole('heading', { name: 'My account' }).or(page.getByRole('heading', { name: 'Overview' })).waitFor();
  ok('two-factor setup and sign-in with a code');

  step = 'billing details';
  await page.getByRole('link', { name: 'Billing details' }).click();
  await page.getByLabel('Business name').fill('TIM-POS Africa');
  await page.getByLabel('Address').fill('12 Samora Machel Ave\nHarare');
  await page.getByLabel('How to pay').fill('EcoCash 0772 000 222');
  await page.getByLabel('Tax added to invoices (%)').fill('15');
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await page.getByText('Billing details saved.').waitFor();
  ok('billing details saved');

  step = 'create invoice';
  await page.getByRole('link', { name: 'Invoices', exact: true }).click();
  await page.getByRole('button', { name: 'New invoice' }).click();
  await page.getByLabel('Shop', { exact: true }).selectOption({ label: 'Mbare Mini Market' });
  await page.getByLabel('Plan', { exact: true }).selectOption({ label: 'Standard (USD 15.50 / month)' });
  await page.getByLabel('Months to bill').fill('2');
  await page.getByRole('button', { name: 'Set-up fee and months' }).click();
  assert.match(await page.locator('.totals').innerText(), /USD 151\.00[\s\S]*USD 22\.65[\s\S]*USD 173\.65/);
  await page.getByRole('button', { name: 'Create invoice' }).last().click();
  await page.getByRole('heading', { name: /INV-\d{4}-0001/ }).waitFor();
  assert.match(await page.locator('.sheet').innerText(), /Balance due\s*USD 173\.65/);
  await page.screenshot({ path: join(shots, '4-invoice.png'), fullPage: true });
  ok('invoice from a plan, tax and totals correct');

  step = 'part payment and receipt';
  await page.getByRole('button', { name: 'Record payment' }).click();
  await page.getByLabel(/^Amount/).fill('100');
  await page.getByLabel('Paid by').selectOption('ecocash');
  await page.getByRole('button', { name: 'Record payment' }).last().click();
  await page.getByText('Reference is required').or(page.locator('input:invalid')).first().waitFor();
  await page.getByLabel('Reference').fill('MP2611.0001');
  await page.getByRole('button', { name: 'Record payment' }).last().click();
  await page.getByText(/Payment recorded\. Receipt RCT-\d{4}-0001/).waitFor();
  assert.match(await page.locator('.sheet').innerText(), /Balance due\s*USD 73\.65/);
  assert.match(await page.locator('.sheet').innerText(), /Partly paid/);
  await page.getByRole('link', { name: /RCT-\d{4}-0001/ }).click();
  await page.getByRole('heading', { name: /RCT-/ }).waitFor();
  assert.match(await page.locator('.sheet').innerText(), /USD 100\.00[\s\S]*MP2611\.0001[\s\S]*USD 73\.65/);
  await page.screenshot({ path: join(shots, '5-receipt.png'), fullPage: true });
  ok('part payment, receipt, balance');

  step = 'overpay refused, settle, reverse';
  await page.goBack();
  await page.getByRole('button', { name: 'Record payment' }).first().click();
  await page.getByLabel(/^Amount/).fill('500');
  await page.getByRole('button', { name: 'Record payment' }).last().click();
  await page.getByText(/more than the balance/).waitFor();
  await page.getByLabel(/^Amount/).fill('73.65');
  await page.getByLabel('Paid by').selectOption('cash');
  await page.getByRole('button', { name: 'Record payment' }).last().click();
  await page.getByText(/Receipt RCT-\d{4}-0002/).waitFor();
  assert.match(await page.locator('.sheet').innerText(), /Paid/);
  await page.getByRole('button', { name: 'Reverse' }).last().click();
  await page.getByLabel('Why is it being reversed?').fill('Counted wrong');
  await page.getByRole('button', { name: 'Reverse payment' }).click();
  await page.getByText('Payment reversed.').waitFor();
  assert.match(await page.locator('.sheet').innerText(), /Balance due\s*USD 73\.65/);
  ok('overpayment refused, settled, reversal restores balance');

  step = 'lists and overview';
  await page.getByRole('link', { name: 'Invoices', exact: true }).first().click();
  await page.getByRole('link', { name: /INV-\d{4}-0001/ }).waitFor();
  await page.getByRole('tab', { name: 'Payments received' }).click();
  await page.getByRole('link', { name: /RCT-\d{4}-0002/ }).waitFor();
  await page.getByRole('link', { name: 'Overview' }).click();
  await page.getByText('Owed by shops').waitFor();
  assert.match(await page.locator('.stats').nth(1).innerText(), /USD 73\.65/);
  await page.getByRole('link', { name: 'Shops', exact: true }).first().click();
  await page.getByRole('link', { name: 'Mbare Mini Market' }).click();
  await page.getByText(/Owes USD 73\.65/).waitFor();
  ok('invoice and payment lists, overview owed, shop statement');

  step = 'void and monthly run';
  await page.getByRole('link', { name: 'Invoices', exact: true }).first().click();
  await page.getByRole('button', { name: 'Run monthly billing' }).click();
  await page.getByRole('button', { name: 'Preview' }).click();
  await page.getByText(/Nothing to bill|shop\(s\) already billed/).or(page.getByRole('button', { name: /Create \d+ invoices?/ })).first().waitFor();
  await page.getByRole('button', { name: 'Close' }).first().click();
  ok('monthly run preview');

  await page.getByRole('button', { name: 'New invoice' }).click();
  await page.getByLabel('Shop', { exact: true }).selectOption({ label: 'Mbare Mini Market' });
  await page.getByLabel('Description 1').fill('Training visit');
  await page.getByLabel('Unit price 1').fill('30');
  await page.getByRole('button', { name: 'Create invoice' }).last().click();
  await page.getByRole('heading', { name: /INV-\d{4}-0002/ }).waitFor();
  await page.getByRole('button', { name: 'Void', exact: true }).click();
  await page.getByLabel('Reason').fill('Wrong shop');
  await page.getByRole('button', { name: 'Void invoice' }).click();
  await page.getByText('Invoice voided.').waitFor();
  await page.getByText('VOID', { exact: true }).waitFor();
  ok('void an unpaid invoice');

  step = 'owner: set-up through the API';
  const call = async (method, path, token, body) => {
    const r = await fetch(`${base}${path}`, { method, headers: { 'content-type': 'application/json', ...(token ? { authorization: token } : {}) }, body: body ? JSON.stringify(body) : undefined });
    const j = await r.json(); assert.ok(r.ok, `${method} ${path}: ${JSON.stringify(j)}`); return j;
  };
  const vt = `Bearer ${(await call('POST', '/v1/vendor/login', null, { email: 'api@example.com', password: 'a-long-test-password' })).token}`;
  const demo = await call('POST', '/v1/vendor/tenants', vt, { name: 'Owner Demo Shop', country_code: 'zw' });
  const lic = await call('POST', `/v1/vendor/tenants/${demo.id}/licences`, vt, { months: 3, max_devices: 2 });
  const oact = await call('POST', '/v1/activate', null, { licence_key: lic.key, fingerprint: 'e2e-owner-device-01', device_name: 'Till', platform: 'android', app_version: '1.0.0' });
  const devAuth = `Device ${oact.device_id}.${oact.device_secret}`;
  const { DatabaseSync } = await import('node:sqlite');
  const { readFileSync } = await import('node:fs');
  const T = (f) => import(join(root, 'tools', 'src', f));
  const { seedShop, saveProduct, receiveStock } = await T('setup.ts');
  const { sell } = await T('selling.ts');
  const tillDb = new DatabaseSync(':memory:');
  tillDb.exec(readFileSync(join(root, 'app', 'assets', 'sql', 'local_schema.sql'), 'utf8'));
  let n = 0; const uid = () => `e2e-${String(++n).padStart(8, '0')}`;
  const T0 = Date.now() - 2 * 86_400_000;
  const ctx0 = { shop_id: demo.id, device_id: 'dev-00001', user_id: null, now: T0, receipt_prefix: 'D1' };
  const { branch_id } = seedShop(tillDb, ctx0, { name: 'Owner Demo Shop', country_code: 'ZW', tax_registered: false }, uid);
  const bread = saveProduct(tillDb, ctx0, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  const radio = saveProduct(tillDb, ctx0, { name: 'Radio', price_minor: 4000, cost_minor: 2500 }, uid);
  receiveStock(tillDb, ctx0, { branch_id, product_id: bread, qty_milli: 50_000, unit_cost_minor: 90, opening: true }, uid);
  receiveStock(tillDb, ctx0, { branch_id, product_id: radio, qty_milli: 5_000, unit_cost_minor: 2500, opening: true }, uid);
  const cashp = (amount_minor) => [{ method_code: 'cash', currency: 'USD', amount_minor }];
  const sale = (at, p, q, pay) => sell(tillDb, { ...ctx0, now: at }, { branch_id, user_id: null, sale_currency: 'USD', lines: [{ product_id: p, qty_milli: q }], payments: cashp(pay) }, uid);
  sale(T0 + 1000, bread, 4000, 600); sale(T0 + 2000, radio, 1000, 4000); sale(T0 + 3000, bread, 2000, 300);
  const { TABLES } = await import(join(server, 'src', 'tables.ts'));
  const changes = [];
  for (const table of Object.keys(TABLES)) {
    let rows = []; try { rows = tillDb.prepare(`select * from "${table}"`).all(); } catch { continue; }
    for (const r of rows) changes.push({ table, row_id: r.id, op: 'insert', version: r.version ?? 1, updated_at: r.updated_at ?? r.created_at ?? T0, data: { ...r } });
  }
  for (let i = 0; i < changes.length; i += 500) {
    const res = await call('POST', '/v1/sync/push', devAuth, { batch_id: `e2e-batch-${i}-${Date.now()}`.padEnd(36, '0').slice(0, 36), changes: changes.slice(i, i + 500) });
    assert.deepEqual(res.rejected, [], JSON.stringify(res.rejected.slice(0, 3)));
  }
  ok('owner demo shop with real sales synced');

  step = 'owner: vendor adds a login';
  await page.getByRole('link', { name: 'Shops', exact: true }).first().click();
  await page.getByRole('link', { name: 'Owner Demo Shop' }).click();
  await page.getByRole('button', { name: 'Add owner login' }).click();
  await page.getByLabel("Owner's name").fill('Mrs Moyo');
  await page.getByLabel('Email', { exact: true }).fill('moyo@example.com');
  await page.getByRole('button', { name: 'Create login' }).click();
  const temp = (await page.getByTestId('secret').innerText()).trim();
  assert.match(temp, /^[a-z2-9]{4}(-[a-z2-9]{4}){3}$/);
  await page.getByRole('button', { name: 'I have saved it' }).click();
  await page.getByRole('cell', { name: 'moyo@example.com' }).waitFor();
  await page.getByText('Waiting for first sign-in').waitFor();
  ok('vendor creates owner login (temporary password shown once)');

  step = 'owner: sign in and choose password';
  await page.getByRole('button', { name: 'Sign out' }).first().click();
  await page.getByRole('link', { name: 'Shop owner sign-in' }).click();
  await page.getByText('Shop owner sign-in. See your sales').waitFor();
  await page.getByLabel('Email').fill('moyo@example.com');
  await page.getByLabel('Password').fill('wrong-wrong-wrong');
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('alert').waitFor();
  await page.getByLabel('Password').fill(temp);
  await page.getByRole('button', { name: 'Sign in' }).click();
  await page.getByRole('heading', { name: 'Choose your password' }).waitFor();
  await page.getByLabel('Temporary password').fill(temp);
  await page.getByLabel('New password', { exact: true }).fill('moyo-own-password-1');
  await page.getByLabel('New password again').fill('moyo-own-password-1');
  await page.getByRole('button', { name: 'Change password' }).click();
  await page.getByText('Password changed.').waitFor();
  await page.getByRole('link', { name: 'Sales', exact: true }).click();
  await page.getByRole('heading', { name: 'Sales', exact: true }).waitFor();
  ok('owner signs in, must choose own password, then reaches reports');

  step = 'owner: reports';
  await page.getByLabel('Period').selectOption('7d');
  await page.locator('.stat', { hasText: 'Sales made' }).getByText('3', { exact: true }).waitFor();
  assert.match(await page.locator('.stats').first().innerText(), /USD 49\.00[\s\S]*USD 18\.60/);
  await page.getByText('A shop phone last sent its sales').waitFor();
  await page.screenshot({ path: join(shots, '6-owner-sales.png'), fullPage: true });
  await page.getByRole('link', { name: 'Best sellers' }).click();
  await page.getByRole('cell', { name: 'Radio' }).waitFor();
  await page.getByRole('cell', { name: 'Bread' }).waitFor();
  await page.getByRole('link', { name: 'Stock', exact: true }).click();
  await page.getByText('Stock value at cost').waitFor();
  await page.getByRole('link', { name: 'Customers who owe' }).click();
  await page.getByText('No customer owes the shop anything.').waitFor();
  await page.getByRole('link', { name: 'Cash-ups' }).click();
  await page.getByText('No shifts were closed in this range.').or(page.getByRole('table')).first().waitFor();
  ok('owner sales, best sellers, stock, owed and cash-ups pages');

  step = 'owner: phone layout and sign out';
  await page.setViewportSize({ width: 390, height: 800 });
  await page.getByRole('link', { name: 'Sales', exact: true }).or(page.getByRole('button', { name: 'Menu' })).first().waitFor();
  await page.getByRole('button', { name: 'Menu' }).click();
  await page.getByRole('link', { name: 'Sales', exact: true }).click();
  await page.getByLabel('Period').waitFor();
  assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth + 1), 'no sideways scroll on a phone');
  await page.screenshot({ path: join(shots, '7-owner-phone.png') });
  await page.getByRole('button', { name: 'Menu' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await page.getByRole('heading', { name: 'TIM-POS' }).waitFor();
  await page.getByLabel('Email').waitFor();
  ok('owner phone layout, sign out');

  assert.deepEqual(problems, [], 'browser problems: ' + problems.join(' | '));
  ok('no console errors, failed requests or CSP violations');
  console.log(`\nAll dashboard checks passed. Screenshots: ${shots}`);
} catch (e) {
  console.error(`\nFAILED at "${step}":`, e.message);
  console.error(problems.join('\n'));
  try { const pages = browser.contexts().flatMap((c) => c.pages()); await pages[0]?.screenshot({ path: join(shots, 'failure.png') }); } catch { /* ignore */ }
  process.exitCode = 1;
} finally {
  await browser.close();
  srv.kill();
}
