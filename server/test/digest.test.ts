import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { DAY, START, boot, makeShop, type Harness } from './helpers.ts';
import { buildDigest, getSettings, runDue, saveSettings, sendTest, type Sender } from '../src/services/digest.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

test('settings are validated and saved', async () => {
  const shop = await makeShop(h);
  assert.equal(getSettings(h.ctx, shop.tenantId).frequency, 'off');
  assert.throws(() => saveSettings(h.ctx, shop.tenantId, { frequency: 'daily', recipient: '' }));
  assert.throws(() => saveSettings(h.ctx, shop.tenantId, { frequency: 'weekly', recipient: '12', channel: 'whatsapp' }));
  assert.throws(() => saveSettings(h.ctx, shop.tenantId, { frequency: 'hourly', recipient: '+263771234567' }));
  const s = saveSettings(h.ctx, shop.tenantId, { frequency: 'weekly', recipient: '+263 77 123 4567', send_hour: 18, weekday: 0 });
  assert.equal(s.recipient, '+263771234567');
  assert.equal(s.send_hour, 18);
});

test('a due report is sent once a day, at the right hour and weekday, and a failure is kept and retried', async () => {
  const shop = await makeShop(h);
  saveSettings(h.ctx, shop.tenantId, { frequency: 'daily', recipient: '+263771234567', send_hour: 20, utc_offset_min: 120 });
  const sent: string[] = [];
  const ok: Sender = async (_c, ch, to, text) => { sent.push(`${ch}:${to}:${text.split('\n')[0]}`); };
  const realNow = h.ctx.now;
  // 19:00 local (17:00 UTC): too early.
  const at = (hourUtc: number) => ({ ...h.ctx, now: () => START + 3 * DAY + hourUtc * 3_600_000 });
  assert.equal(await runDue(at(17), ok), 0);
  // 20:30 local: sends, then not again the same day.
  assert.equal(await runDue(at(18.5 as number), ok), 1);
  assert.equal(await runDue(at(19), ok), 0);
  assert.equal(sent.length, 1);
  assert.match(sent[0]!, /^whatsapp:\+263771234567:/);
  // Next day, provider fails: error saved, then succeeds on retry.
  const next = { ...h.ctx, now: () => START + 4 * DAY + 19 * 3_600_000 };
  assert.equal(await runDue(next, async () => { throw new Error('boom'); }), 0);
  assert.equal(getSettings(h.ctx, shop.tenantId).last_error, 'boom');
  assert.equal(await runDue(next, ok), 1);
  assert.equal(getSettings(h.ctx, shop.tenantId).last_error, '');
  void realNow;
});

test('weekly reports go only on the chosen weekday', async () => {
  const shop = await makeShop(h);
  // START is 1 Nov 2026, a Sunday. Weekday 0 = Sunday.
  saveSettings(h.ctx, shop.tenantId, { frequency: 'weekly', recipient: '12345678', channel: 'telegram', send_hour: 8, weekday: 0, utc_offset_min: 0 });
  const sent: string[] = [];
  const ok: Sender = async (_c, ch) => { sent.push(ch); };
  assert.equal(await runDue({ ...h.ctx, now: () => START + 1 * DAY + 9 * 3_600_000 }, ok), 0); // Monday
  assert.equal(await runDue({ ...h.ctx, now: () => START + 7 * DAY + 9 * 3_600_000 }, ok), 1); // next Sunday
  assert.deepEqual(sent, ['telegram']);
});

test('the report text names the shop and its figures', async () => {
  const shop = await makeShop(h);
  const text = buildDigest(h.ctx, shop.tenantId, 'daily', 120);
  assert.match(text, /report/);
  assert.match(text, /Sales: 0/);
  assert.match(text, /Revenue: /);
});

test('the test button reports a sending failure as an error, not a crash', async () => {
  const shop = await makeShop(h);
  saveSettings(h.ctx, shop.tenantId, { frequency: 'daily', recipient: '+263771234567' });
  await assert.rejects(() => sendTest(h.ctx, shop.tenantId, async () => { throw new Error('nope'); }), /nope/);
  await sendTest(h.ctx, shop.tenantId, async () => {});
});
