import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { activateDevice, boot, makeShop, type Harness } from './helpers.ts';
import { refreshRates } from '../src/services/fx.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

test('rates are fetched, cached for 12 hours, and served to phones', async () => {
  const shop = await makeShop(h);
  const dev = await activateDevice(h, shop.key);
  assert.equal((await h.call('GET', '/v1/rates', { auth: dev.auth })).status, 503);
  let calls = 0;
  const fetcher = async () => { calls++; return { rates: { ZMW: 27.5, ZWG: 26.8, USD: 1 }, updatedAt: 1_700_000_000_000 }; };
  assert.equal(await refreshRates(h.ctx, fetcher), true);
  assert.equal(await refreshRates(h.ctx, fetcher), false);
  assert.equal(calls, 1);
  const r = await h.call('GET', '/v1/rates', { auth: dev.auth });
  assert.equal(r.status, 200);
  assert.equal(r.json.base, 'USD');
  assert.equal(r.json.rates.ZMW, 27.5);
  assert.match(r.json.attribution, /Exchange Rate API/);
  assert.equal((await h.call('GET', '/v1/rates')).status, 401);
});

test('a failing provider leaves the last good rates in place', async () => {
  const shop = await makeShop(h);
  const dev = await activateDevice(h, shop.key);
  const real = h.ctx.now;
  const later = real() + 13 * 3_600_000;
  const ctx2 = { ...h.ctx, now: () => later };
  await assert.rejects(() => refreshRates(ctx2, async () => { throw new Error('down'); }));
  const r = await h.call('GET', '/v1/rates', { auth: dev.auth });
  assert.equal(r.json.rates.ZMW, 27.5);
});
