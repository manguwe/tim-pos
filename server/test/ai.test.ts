import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { activateDevice, boot, makeShop, type Harness } from './helpers.ts';
import { anthropicProvider, parseSuggestion, type AiProvider } from '../src/services/ai.ts';

let h: Harness;
const seen: { system: string; text: string; pictures: number }[] = [];
let reply = '{"name":"Cooking oil 2L","brand":"Olivine"}';
let fail = false;
const fake: AiProvider = {
  async complete(o) {
    if (fail) throw new Error('down');
    seen.push({ system: o.system, text: o.content.map((b) => (b.type === 'text' ? b.text : '')).join(''), pictures: o.content.filter((b) => b.type === 'jpeg').length });
    return reply;
  },
};
before(async () => { h = await boot({ aiMonthlyLimit: 3 }); });
after(async () => { await h.close(); });

const jpeg = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(50, 7)]).toString('base64');
const withAi = async () => {
  const shop = await makeShop(h);
  h.ctx.db.run('update licences set features = ? where id = ?', '["ai"]', shop.licenceId);
  return { shop, dev: await activateDevice(h, shop.key) };
};

test('without a key on the server the assistant is off', async () => {
  h.ctx.ai = null;
  const { dev } = await withAi();
  const r = await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'hi' } });
  assert.equal(r.status, 503);
  assert.equal(r.json.error.code, 'ai_unavailable');
  const s = await h.call('GET', '/v1/ai/status', { auth: dev.auth });
  assert.equal(s.json.available, false);
});

test('a shop whose plan does not include the assistant is refused', async () => {
  h.ctx.ai = fake;
  const shop = await makeShop(h);
  const dev = await activateDevice(h, shop.key);
  const r = await h.call('POST', '/v1/ai/suggest-product', { auth: dev.auth, body: { data: jpeg } });
  assert.equal(r.status, 403);
  assert.equal(r.json.error.code, 'ai_not_included');
  assert.equal((await h.call('GET', '/v1/ai/status', { auth: dev.auth })).json.included, false);
});

test('needs a phone sign-in', async () => {
  assert.equal((await h.call('POST', '/v1/ai/ask', { body: { question: 'x' } })).status, 401);
  assert.equal((await h.call('POST', '/v1/ai/suggest-product', { body: { data: jpeg } })).status, 401);
  assert.equal((await h.call('POST', '/v1/owner/ai/ask', { body: { question: 'x' } })).status, 401);
});

test('a photo gives a name and brand, and bad pictures never reach the provider', async () => {
  h.ctx.ai = fake; fail = false; seen.length = 0;
  const { dev } = await withAi();
  const r = await h.call('POST', '/v1/ai/suggest-product', { auth: dev.auth, body: { data: jpeg } });
  assert.equal(r.status, 200);
  assert.deepEqual(r.json, { name: 'Cooking oil 2L', brand: 'Olivine' });
  assert.equal(seen.length, 1);
  assert.equal(seen[0]!.pictures, 1);
  const bad = await h.call('POST', '/v1/ai/suggest-product', { auth: dev.auth, body: { data: Buffer.from('<html>').toString('base64') } });
  assert.equal(bad.json.error.code, 'not_a_jpeg');
  assert.equal(seen.length, 1);
});

test('the answer includes shop facts, and a phone only gets sales figures when it asks for them', async () => {
  h.ctx.ai = fake; fail = false; reply = 'Sugar is 1.50 USD.'; seen.length = 0;
  const { dev } = await withAi();
  const a = await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'how much is sugar' } });
  assert.equal(a.status, 200);
  assert.equal(a.json.answer, 'Sugar is 1.50 USD.');
  assert.match(seen[0]!.text, /PRODUCTS/);
  assert.match(seen[0]!.text, /how much is sugar/);
  assert.doesNotMatch(seen[0]!.text, /SALES:/);
  await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'how did we do', include_sales: true } });
  assert.match(seen[1]!.text, /SALES:/);
});

test('an empty question is refused and a provider failure does not use up the allowance', async () => {
  h.ctx.ai = fake; reply = 'ok';
  const { shop, dev } = await withAi();
  assert.equal((await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: '   ' } })).status, 400);
  fail = true;
  const r = await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'x' } });
  assert.equal(r.status, 502);
  fail = false;
  assert.equal((await h.call('GET', '/v1/ai/status', { auth: dev.auth })).json.used_ask, 0);
  assert.ok(shop);
});

test('the monthly limit stops further questions and starts again next month', async () => {
  h.ctx.ai = fake; fail = false; reply = 'ok';
  const { dev } = await withAi();
  for (let i = 0; i < 3; i++) assert.equal((await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'q' } })).status, 200);
  const over = await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'q' } });
  assert.equal(over.status, 429);
  assert.equal(over.json.error.code, 'ai_limit_reached');
  // The other feature has its own allowance.
  assert.equal((await h.call('POST', '/v1/ai/suggest-product', { auth: dev.auth, body: { data: jpeg } })).status, 200);
  h.clock.t += 35 * 86_400_000;
  assert.equal((await h.call('POST', '/v1/ai/ask', { auth: dev.auth, body: { question: 'q' } })).status, 200);
});

test('the suggestion parser copes with messy replies', () => {
  assert.deepEqual(parseSuggestion('Sure! {"name": " Rice 5kg ", "brand": "Mama"} hope that helps'), { name: 'Rice 5kg', brand: 'Mama' });
  assert.deepEqual(parseSuggestion('no idea'), { name: '', brand: '' });
  assert.deepEqual(parseSuggestion('{"name": 5}'), { name: '', brand: '' });
});

test('the Anthropic provider sends the key from the server and reads the text back', async () => {
  let got: any;
  const f = (async (url: string, init: any) => {
    got = { url, headers: init.headers, body: JSON.parse(init.body) };
    return { ok: true, status: 200, json: async () => ({ content: [{ type: 'text', text: ' hello ' }] }) };
  }) as unknown as typeof fetch;
  const p = anthropicProvider('sk-test', 'm1', f);
  const out = await p.complete({ system: 's', maxTokens: 10, content: [{ type: 'jpeg', base64: 'AAAA' }, { type: 'text', text: 't' }] });
  assert.equal(out, 'hello');
  assert.equal(got.url, 'https://api.anthropic.com/v1/messages');
  assert.equal(got.headers['x-api-key'], 'sk-test');
  assert.equal(got.body.model, 'm1');
  assert.equal(got.body.messages[0].content[0].source.media_type, 'image/jpeg');
});

test('an owner can ask about the whole shop on the web, only their own', async () => {
  h.ctx.ai = fake; fail = false; reply = 'Fine.'; seen.length = 0;
  const { shop } = await withAi();
  const mk = await h.call('POST', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor, body: { email: 'o@example.com', name: 'Owner' } });
  assert.equal(mk.status, 201);
  const login1 = await h.call('POST', '/v1/owner/login', { body: { email: 'o@example.com', password: mk.json.temporary_password } });
  const tok = `Bearer ${login1.json.token}`;
  assert.equal((await h.call('POST', '/v1/owner/ai/ask', { auth: tok, body: { question: 'x' } })).status, 403); // must change password first
  const ch = await h.call('POST', '/v1/owner/password', { auth: tok, body: { current_password: mk.json.temporary_password, new_password: 'a-new-long-password-1' } });
  assert.equal(ch.status, 200);
  const own = `Bearer ${ch.json.token}`;
  const r = await h.call('POST', '/v1/owner/ai/ask', { auth: own, body: { question: 'summary please' } });
  assert.equal(r.status, 200);
  assert.match(seen[0]!.text, /SALES:/);
  assert.equal((await h.call('GET', '/v1/owner/ai/status', { auth: own })).json.included, true);
});
