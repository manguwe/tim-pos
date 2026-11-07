import type { Ctx } from '../context.ts';
import { HttpError, asObject, str } from '../http.ts';
import { hashPassword, newId, randomSecret, signToken, verifyPassword, verifyToken } from '../crypto.ts';
import { audit, type VendorUser } from './vendor.ts';
import { shopView } from '../reports/engine.ts';
import * as R from '../reports/reports.ts';

export interface OwnerUser {
  id: string; tenant_id: string; name: string; email: string; password_hash: string; is_active: number;
  must_change_password: number; token_version: number; created_at: number; last_login_at: number | null;
}
type Obj = Record<string, unknown>;

const publicOwner = (o: OwnerUser): Obj => ({
  id: o.id, tenant_id: o.tenant_id, name: o.name, email: o.email, is_active: !!o.is_active,
  must_change_password: !!o.must_change_password, created_at: o.created_at, last_login_at: o.last_login_at,
});

/** A password the vendor can read out or send: 4 groups of letters and digits, no look-alike characters. */
function temporaryPassword(): string {
  const alphabet = 'abcdefghjkmnpqrstuvwxyz23456789';
  const bytes = Buffer.from(randomSecret(24), 'base64url');
  const pick = (n: number) => Array.from({ length: 4 }, (_, i) => alphabet[(bytes[n * 4 + i] as number) % alphabet.length]).join('');
  return [pick(0), pick(1), pick(2), pick(3)].join('-');
}
const validEmail = (e: string) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(e);

// ---- vendor side: manage a shop's owner logins ----

export function listOwners(ctx: Ctx, tenantId: string): Obj[] {
  return ctx.db.all<OwnerUser>('select * from owner_users where tenant_id = ? order by created_at', tenantId).map(publicOwner);
}

export async function createOwner(ctx: Ctx, vendor: VendorUser, tenantId: string, body: unknown): Promise<{ owner: Obj; temporary_password: string }> {
  if (!ctx.db.get('select 1 as x from tenants where id = ?', tenantId)) throw new HttpError(404, 'not_found', 'Shop not found');
  const o = asObject(body);
  const name = str(o, 'name', { max: 120, min: 1 });
  const email = str(o, 'email', { max: 200 }).toLowerCase();
  if (!validEmail(email)) throw new HttpError(400, 'invalid_request', 'email is not valid');
  if (ctx.db.get('select 1 as x from owner_users where email = ?', email)) throw new HttpError(409, 'email_taken', 'That email already has an owner login');
  const temp = temporaryPassword();
  const id = newId();
  ctx.db.run(
    'insert into owner_users (id, tenant_id, name, email, password_hash, created_at) values (?, ?, ?, ?, ?, ?)',
    id, tenantId, name, email, await hashPassword(temp), ctx.now(),
  );
  audit(ctx, vendor.id, 'owner.create', tenantId, { owner_id: id, email });
  return { owner: publicOwner(ctx.db.get<OwnerUser>('select * from owner_users where id = ?', id) as OwnerUser), temporary_password: temp };
}

export async function resetOwnerPassword(ctx: Ctx, vendor: VendorUser, ownerId: string): Promise<{ temporary_password: string }> {
  const owner = ctx.db.get<OwnerUser>('select * from owner_users where id = ?', ownerId);
  if (!owner) throw new HttpError(404, 'not_found', 'Owner login not found');
  const temp = temporaryPassword();
  // Bumping token_version signs the owner out everywhere.
  ctx.db.run('update owner_users set password_hash = ?, must_change_password = 1, token_version = token_version + 1 where id = ?', await hashPassword(temp), ownerId);
  audit(ctx, vendor.id, 'owner.reset_password', owner.tenant_id, { owner_id: ownerId });
  return { temporary_password: temp };
}

export function setOwnerActive(ctx: Ctx, vendor: VendorUser, ownerId: string, body: unknown): Obj {
  const owner = ctx.db.get<OwnerUser>('select * from owner_users where id = ?', ownerId);
  if (!owner) throw new HttpError(404, 'not_found', 'Owner login not found');
  const o = asObject(body);
  if (typeof o.is_active !== 'boolean') throw new HttpError(400, 'invalid_request', 'is_active must be true or false');
  ctx.db.run('update owner_users set is_active = ?, token_version = token_version + 1 where id = ?', o.is_active ? 1 : 0, ownerId);
  audit(ctx, vendor.id, o.is_active ? 'owner.enable' : 'owner.disable', owner.tenant_id, { owner_id: ownerId });
  return publicOwner(ctx.db.get<OwnerUser>('select * from owner_users where id = ?', ownerId) as OwnerUser);
}

// ---- owner side: sign in and reports ----

const BAD = () => new HttpError(401, 'invalid_login', 'Email or password is not correct');
const DUMMY = 'scrypt$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const secretFor = (ctx: Ctx) => ctx.config.vendorTokenSecret + '|owner';

export async function ownerLogin(ctx: Ctx, ip: string, body: unknown): Promise<{ token: string; expires_at: number; user: Obj }> {
  const o = asObject(body);
  const email = str(o, 'email', { max: 200 }).toLowerCase();
  const password = str(o, 'password', { max: 500 });
  const pair = `owner|${ip}|${email}`;
  if (ctx.loginPairLimiter.blocked(pair) || ctx.loginIpLimiter.blocked(`owner|${ip}`) || ctx.loginEmailLimiter.blocked(`owner|${email}`)) {
    throw new HttpError(429, 'too_many_attempts', 'Too many failed attempts. Try again later.');
  }
  const owner = ctx.db.get<OwnerUser>('select * from owner_users where email = ?', email);
  const ok = await verifyPassword(password, owner?.password_hash ?? DUMMY);
  const tenant = owner ? ctx.db.get<{ status: string }>('select status from tenants where id = ?', owner.tenant_id) : undefined;
  if (!owner || !owner.is_active || !ok || !tenant) {
    ctx.loginPairLimiter.fail(pair); ctx.loginIpLimiter.fail(`owner|${ip}`); ctx.loginEmailLimiter.fail(`owner|${email}`);
    throw BAD();
  }
  ctx.loginPairLimiter.succeed(pair);
  const now = ctx.now();
  ctx.db.run('update owner_users set last_login_at = ? where id = ?', now, owner.id);
  const expires = now + Math.min(ctx.config.vendorTokenTtlMs, 12 * 3_600_000);
  return {
    token: signToken({ typ: 'owner', sub: owner.id, ver: owner.token_version, exp: expires }, secretFor(ctx)),
    expires_at: expires,
    user: ownerMe(ctx, owner),
  };
}

export function authenticateOwner(ctx: Ctx, authorization: string | undefined): OwnerUser {
  const m = /^Bearer (.+)$/.exec(authorization ?? '');
  const c = m ? verifyToken<{ typ: string; sub: string; ver: number; exp: number }>(m[1] as string, secretFor(ctx)) : null;
  if (!c || c.typ !== 'owner' || c.exp < ctx.now()) throw new HttpError(401, 'unauthorised', 'Sign in to continue');
  const owner = ctx.db.get<OwnerUser>('select * from owner_users where id = ? and is_active = 1', c.sub);
  if (!owner || owner.token_version !== c.ver) throw new HttpError(401, 'unauthorised', 'Sign in to continue');
  return owner;
}

function ownerMe(ctx: Ctx, o: OwnerUser): Obj {
  const t = ctx.db.get<{ name: string; country_code: string; status: string }>('select name, country_code, status from tenants where id = ?', o.tenant_id);
  return { ...publicOwner(o), shop: { id: o.tenant_id, name: t?.name ?? '', country_code: t?.country_code ?? '', status: t?.status ?? 'active' } };
}
export const me = ownerMe;

export async function changeOwnerPassword(ctx: Ctx, owner: OwnerUser, body: unknown): Promise<{ token: string; expires_at: number }> {
  const o = asObject(body);
  const current = str(o, 'current_password', { max: 500 });
  const next = str(o, 'new_password', { max: 500 });
  if (!(await verifyPassword(current, owner.password_hash))) throw new HttpError(403, 'wrong_password', 'The current password is not correct');
  if (next.length < 10) throw new HttpError(400, 'weak_password', 'Use a password of at least 10 characters');
  if (next === current) throw new HttpError(400, 'weak_password', 'Choose a different password from the old one');
  ctx.db.run('update owner_users set password_hash = ?, must_change_password = 0, token_version = token_version + 1 where id = ?', await hashPassword(next), owner.id);
  const expires = ctx.now() + Math.min(ctx.config.vendorTokenTtlMs, 12 * 3_600_000);
  return { token: signToken({ typ: 'owner', sub: owner.id, ver: owner.token_version + 1, exp: expires }, secretFor(ctx)), expires_at: expires };
}

// ---- reports ----

function range(q: URLSearchParams): R.Range {
  const from = Number(q.get('from')), to = Number(q.get('to'));
  if (!Number.isFinite(from) || !Number.isFinite(to) || to <= from) throw new HttpError(400, 'invalid_request', 'from and to must be times in milliseconds, with to after from');
  if (to - from > 400 * 86_400_000) throw new HttpError(400, 'invalid_request', 'Choose a range of at most 400 days');
  return { from, to };
}
const filter = (q: URLSearchParams): R.Filter => ({ branch_id: q.get('branch_id') || null, user_id: q.get('user_id') || null });

export function report(ctx: Ctx, owner: OwnerUser, name: string, q: URLSearchParams): Obj {
  if (owner.must_change_password) throw new HttpError(403, 'password_change_required', 'Choose your own password before viewing reports');
  const view = shopView(ctx.db, owner.tenant_id, ctx.now());
  const db = view.db;
  const meta = { data_as_of_change: view.seq, loaded_rows: view.loaded, skipped_rows: view.skipped, built_at: view.built_at };
  const last = ctx.db.get<{ t: number | null }>('select max(last_seen_at) as t from activations where tenant_id = ?', owner.tenant_id)?.t ?? null;
  const base = { ...meta, phones_last_seen_at: last };
  switch (name) {
    case 'summary': return { ...base, summary: R.salesSummary(db, range(q), filter(q)) };
    case 'daily': return { ...base, days: R.dailySales(db, range(q), Math.trunc(Number(q.get('offset_min') ?? 0)) || 0, filter(q)) };
    case 'products': {
      const by = q.get('by');
      return { ...base, products: R.topProducts(db, range(q), { by: by === 'qty' || by === 'profit' ? by : 'revenue', limit: Math.min(100, Number(q.get('limit') ?? 20) || 20), ...filter(q) }) };
    }
    case 'takings': return { ...base, takings: R.takings(db, range(q), filter(q)) };
    case 'stock': {
      const b = q.get('branch_id') || null;
      return { ...base, value: R.stockValue(db, { branch_id: b, top: 50 }), out_of_stock: R.outOfStock(db, { branch_id: b }) };
    }
    case 'expiring': {
      const today = q.get('today') ?? '';
      if (!/^\d{4}-\d{2}-\d{2}$/.test(today)) throw new HttpError(400, 'invalid_request', 'today must look like 2026-11-05');
      return { ...base, batches: R.expiringBatches(db, today, Math.min(365, Math.max(1, Number(q.get('days') ?? 30) || 30))) };
    }
    case 'receivables': return { ...base, receivables: R.receivables(db, 50) };
    case 'cash-ups': return { ...base, cash_ups: R.cashUps(db, range(q)) };
    case 'branches': {
      const branches = db.prepare('select id, name from branches where deleted_at is null order by name').all();
      const users = db.prepare('select id, name from users where deleted_at is null order by name').all();
      return { ...base, branches, users };
    }
    default: throw new HttpError(404, 'not_found', 'Unknown report');
  }
}
