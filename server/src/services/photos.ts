import { HttpError, asObject, str, type Reply } from '../http.ts';
import { ok } from '../http.ts';
import type { Ctx } from '../context.ts';
import type { DeviceAuth } from './licensing.ts';

/** The phone shrinks pictures to about 640 pixels, so a real one is far below this. */
const MAX_BYTES = 400 * 1024;
/** More than this many pictures for one shop is refused, so a faulty phone cannot fill the disk. */
const MAX_PER_SHOP = 5000;
/** The phone names a picture by the time it was taken plus a few digits, for example 17640000000001234.jpg. */
const NAME = /^[0-9]{10,30}\.jpg$/;

function checkName(name: string): string {
  if (!NAME.test(name)) throw new HttpError(400, 'bad_photo_name', 'That picture name is not valid');
  return name;
}

/** Stores one picture. Sending the same picture again is fine and changes nothing. */
export function put(ctx: Ctx, dev: DeviceAuth, body: unknown): Reply {
  const o = asObject(body);
  const name = checkName(str(o, 'name', { max: 60 }));
  const b64 = str(o, 'data', { max: Math.ceil((MAX_BYTES * 8) / 3) + 8 });
  if (!/^[A-Za-z0-9+/]+={0,2}$/.test(b64)) throw new HttpError(400, 'bad_photo', 'The picture data is not valid');
  const bytes = Buffer.from(b64, 'base64');
  if (bytes.length === 0 || bytes.length > MAX_BYTES) throw new HttpError(413, 'photo_too_large', 'The picture is too large');
  // A JPEG starts with FF D8 FF. Nothing else is accepted, so this cannot be used to store other files.
  if (!(bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff)) throw new HttpError(400, 'not_a_jpeg', 'Only JPEG pictures are accepted');
  const shop = dev.tenant.id;
  const have = ctx.db.get<{ n: number }>('select count(*) as n from product_photos where shop_id = ?', shop)!.n;
  const exists = ctx.db.get('select 1 as x from product_photos where shop_id = ? and name = ?', shop, name);
  if (!exists && have >= MAX_PER_SHOP) throw new HttpError(409, 'too_many_photos', 'This shop has reached its picture limit');
  if (!exists) ctx.db.run('insert into product_photos (shop_id, name, bytes, size, created_at) values (?, ?, ?, ?, ?)', shop, name, new Uint8Array(bytes), bytes.length, ctx.now());
  return ok({ stored: true, size: bytes.length });
}

/** Returns one picture of this shop. A shop can only ever read its own pictures. */
export function get(ctx: Ctx, dev: DeviceAuth, nameParam: string): Reply {
  const name = checkName(nameParam);
  const row = ctx.db.get<{ bytes: Uint8Array }>('select bytes from product_photos where shop_id = ? and name = ?', dev.tenant.id, name);
  if (!row) throw new HttpError(404, 'not_found', 'No such picture');
  return ok({ name, data: Buffer.from(row.bytes).toString('base64') });
}

/** The same picture, for a shop owner signed in on the web. An owner can only read their own shop's pictures. */
export function getForShop(ctx: Ctx, shopId: string, nameParam: string): Reply {
  const name = checkName(nameParam);
  const row = ctx.db.get<{ bytes: Uint8Array }>('select bytes from product_photos where shop_id = ? and name = ?', shopId, name);
  if (!row) throw new HttpError(404, 'not_found', 'No such picture');
  return ok({ name, data: Buffer.from(row.bytes).toString('base64') });
}
