import { test, after, before } from 'node:test';
import assert from 'node:assert/strict';
import { activateDevice, boot, makeShop, type Harness } from './helpers.ts';

let h: Harness;
before(async () => { h = await boot(); });
after(async () => { await h.close(); });

// The smallest thing that starts like a JPEG. The server only checks the first bytes and the size.
const jpeg = (extra = 20) => Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(extra, 7)]).toString('base64');
const NAME = '17640000000001234.jpg';

test('every picture route needs a phone sign-in', async () => {
  assert.equal((await h.call('POST', '/v1/photos', { body: { name: NAME, data: jpeg() } })).status, 401);
  assert.equal((await h.call('GET', `/v1/photos/${NAME}`)).status, 401);
});

test('a picture goes up and comes back the same, and sending it twice is harmless', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const data = jpeg(500);
  const up = await h.call('POST', '/v1/photos', { auth: d.auth, body: { name: NAME, data } });
  assert.equal(up.status, 200);
  assert.equal(up.json.stored, true);
  const again = await h.call('POST', '/v1/photos', { auth: d.auth, body: { name: NAME, data } });
  assert.equal(again.status, 200);
  const down = await h.call('GET', `/v1/photos/${NAME}`, { auth: d.auth });
  assert.equal(down.json.data, data);
  assert.equal(h.ctx.db.get<{ n: number }>('select count(*) as n from product_photos')!.n >= 1, true);
});

test('another phone of the same shop gets the picture, a different shop does not', async () => {
  const a = await makeShop(h);
  const b = await makeShop(h);
  const a1 = await activateDevice(h, a.key);
  const a2 = await activateDevice(h, a.key);
  const b1 = await activateDevice(h, b.key);
  await h.call('POST', '/v1/photos', { auth: a1.auth, body: { name: NAME, data: jpeg() } });
  assert.equal((await h.call('GET', `/v1/photos/${NAME}`, { auth: a2.auth })).status, 200);
  assert.equal((await h.call('GET', `/v1/photos/${NAME}`, { auth: b1.auth })).status, 404);
});

test('only small JPEG pictures with sensible names are accepted', async () => {
  const shop = await makeShop(h);
  const d = await activateDevice(h, shop.key);
  const post = (name: string, data: string) => h.call('POST', '/v1/photos', { auth: d.auth, body: { name, data } });
  assert.equal((await post('../../etc/passwd.jpg', jpeg())).status, 400);
  assert.equal((await post('abc.jpg', jpeg())).status, 400);
  assert.equal((await post(NAME, Buffer.from('<html>not a picture</html>').toString('base64'))).json.error.code, 'not_a_jpeg');
  assert.equal((await post(NAME, 'not base64 !!')).status, 400);
  assert.equal((await post(NAME, jpeg(450 * 1024))).status, 413);
  assert.equal((await h.call('GET', '/v1/photos/..%2Fsecret.jpg', { auth: d.auth })).status, 400);
  assert.equal((await h.call('GET', '/v1/photos/17640000000009999.jpg', { auth: d.auth })).status, 404);
});

test('a shop owner sees the shop\'s product list with pictures, and only their own pictures', async () => {
  const a = await makeShop(h);
  const b = await makeShop(h);
  const d = await activateDevice(h, a.key);
  await h.call('POST', '/v1/photos', { auth: d.auth, body: { name: NAME, data: jpeg() } });
  const mk = async (shop: typeof a, email: string) => {
    const r = await h.call('POST', `/v1/vendor/tenants/${shop.tenantId}/owners`, { auth: shop.vendor, body: { name: 'Owner', email } });
    const login = await h.call('POST', '/v1/owner/login', { body: { email, password: r.json.temporary_password } });
    const changed = await h.call('POST', '/v1/owner/password', { auth: `Bearer ${login.json.token}`, body: { current_password: r.json.temporary_password, new_password: 'a-new-long-password-1' } });
    return `Bearer ${changed.json.token}`;
  };
  const ownerA = await mk(a, 'a@shop.test');
  const ownerB = await mk(b, 'b@shop.test');
  assert.equal((await h.call('GET', `/v1/owner/photos/${NAME}`, { auth: ownerA })).status, 200);
  assert.equal((await h.call('GET', `/v1/owner/photos/${NAME}`, { auth: ownerB })).status, 404);
  const cat = await h.call('GET', '/v1/owner/reports/catalogue', { auth: ownerA });
  assert.equal(cat.status, 200);
  assert.deepEqual(cat.json.products, []);
});
