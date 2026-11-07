/**
 * Staff, roles and PINs. Reference implementation; app/lib/auth/auth_repository.dart is a port.
 *
 *  - A PIN is checked on the phone against a salted PBKDF2-SHA256 hash, so login works offline. The PIN itself is never stored.
 *  - Failed-attempt counts and lockouts are kept on each phone (device_state), not synced: they describe this phone's till,
 *    and syncing them would make two phones fight over the same row.
 *  - A role is a list of permission switches. Owners can do everything.
 *  - Every login, failure and staff change is written to the append-only audit log.
 */
import { DatabaseSync } from 'node:sqlite';
import { pbkdf2Sync, randomBytes, randomUUID, timingSafeEqual } from 'node:crypto';
import { Writer, tx, type SetupContext } from './setup.ts';

export const PBKDF2_ITERATIONS = 10_000;
export const LOCK_AFTER = 5;
export const BASE_LOCK_MS = 5 * 60_000;
export const MAX_LOCK_MS = 60 * 60_000;

export const PERMISSIONS = [
  'sale.create', 'sale.discount', 'sale.void', 'sale.refund', 'price.edit', 'cost.view', 'stock.receive', 'stock.adjust',
  'product.edit', 'customer.manage', 'shift.manage', 'report.view', 'data.export', 'user.manage', 'settings.edit', 'rate.edit', 'supplier.pay',
] as const;
export type Permission = (typeof PERMISSIONS)[number];

export const ROLE_NAMES = { owner: 'Owner', manager: 'Manager', cashier: 'Cashier', stock_clerk: 'Stock clerk' } as const;
export const DEFAULT_ROLES: Record<keyof typeof ROLE_NAMES, Permission[]> = {
  owner: [...PERMISSIONS],
  manager: ['sale.create', 'sale.discount', 'sale.void', 'sale.refund', 'price.edit', 'cost.view', 'stock.receive', 'stock.adjust', 'product.edit', 'customer.manage', 'shift.manage', 'report.view', 'rate.edit', 'supplier.pay'],
  cashier: ['sale.create', 'shift.manage'],
  stock_clerk: ['stock.receive', 'product.edit', 'cost.view'],
};

export class AuthError extends Error {
  code: string;
  detail: Record<string, unknown>;
  constructor(code: string, message: string, detail: Record<string, unknown> = {}) { super(message); this.code = code; this.detail = detail; }
}

// ---- PIN hashing ----

/** Returns null if the PIN is acceptable, else the reason in words. */
export function validatePin(pin: string): string | null {
  if (!/^\d{4,8}$/.test(pin)) return 'A PIN is 4 to 8 digits.';
  if (/^(\d)\1+$/.test(pin)) return 'Choose a PIN that is not all the same digit.';
  const d = [...pin].map(Number);
  const step = d[1]! - d[0]!;
  if ((step === 1 || step === -1) && d.every((x, i) => i === 0 || x - d[i - 1]! === step)) return 'Choose a PIN that is not a simple run of digits.';
  return null;
}

/** pbkdf2-sha256$<iterations>$<salt b64>$<hash b64> */
export function hashPin(pin: string, salt: Buffer = randomBytes(16), iterations: number = PBKDF2_ITERATIONS): string {
  const h = pbkdf2Sync(pin, salt, iterations, 32, 'sha256');
  return `pbkdf2-sha256$${iterations}$${salt.toString('base64')}$${h.toString('base64')}`;
}

export function verifyPin(pin: string, stored: string | null): boolean {
  if (!stored) return false;
  const [alg, iter, salt, hash] = stored.split('$');
  const n = Number(iter);
  if (alg !== 'pbkdf2-sha256' || !Number.isSafeInteger(n) || n < 1 || n > 10_000_000 || !salt || !hash) return false;
  const want = Buffer.from(hash, 'base64');
  const got = pbkdf2Sync(pin, Buffer.from(salt, 'base64'), n, want.length, 'sha256');
  return want.length === got.length && timingSafeEqual(want, got);
}

// ---- permissions ----

export function permissionsOf(db: DatabaseSync, userId: string): Set<string> {
  const r = db.prepare(
    `select r.permissions from users u join roles r on r.id = u.role_id
     where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null`).get(userId) as { permissions: string } | undefined;
  if (!r) return new Set();
  try { const list = JSON.parse(r.permissions); return new Set(Array.isArray(list) ? list.filter((x) => typeof x === 'string') : []); } catch { return new Set(); }
}
export const hasPermission = (db: DatabaseSync, userId: string, p: Permission): boolean => permissionsOf(db, userId).has(p);

function require_(db: DatabaseSync, userId: string | null, p: Permission) {
  if (!userId || !hasPermission(db, userId, p)) throw new AuthError('forbidden', 'You do not have permission to do that.', { permission: p });
}

// ---- lockout (this phone only) ----

interface Lock { failed: number; until: number }
const lockKey = (userId: string) => `lock:${userId}`;
function readLock(db: DatabaseSync, userId: string): Lock {
  const r = db.prepare('select value from device_state where key = ?').get(lockKey(userId)) as { value: string } | undefined;
  if (!r) return { failed: 0, until: 0 };
  try { const v = JSON.parse(r.value); return { failed: Number(v.failed) || 0, until: Number(v.until) || 0 }; } catch { return { failed: 0, until: 0 }; }
}
function writeLock(db: DatabaseSync, userId: string, l: Lock) {
  if (l.failed === 0 && l.until === 0) db.prepare('delete from device_state where key = ?').run(lockKey(userId));
  else db.prepare('insert into device_state (key, value) values (?, ?) on conflict (key) do update set value = excluded.value').run(lockKey(userId), JSON.stringify(l));
}
/** 5 minutes after the 5th wrong PIN, doubling with each further one, up to an hour. */
export const lockDuration = (failed: number): number => (failed < LOCK_AFTER ? 0 : Math.min(BASE_LOCK_MS * 2 ** (failed - LOCK_AFTER), MAX_LOCK_MS));

// ---- login ----

export interface LoggedIn { id: string; name: string; role_id: string | null; permissions: string[] }

/** The people who can sign in on this phone, for the login screen. */
export function listLoginUsers(db: DatabaseSync): { id: string; name: string; role: string | null }[] {
  return (db.prepare(
    `select u.id, u.name, r.name as role from users u left join roles r on r.id = u.role_id
     where u.deleted_at is null and u.is_active = 1 and u.pin_hash is not null order by u.name`).all() as any[]).map((r) => ({ ...r }));
}

export function login(db: DatabaseSync, ctx: SetupContext, userId: string, pin: string, newId: () => string = randomUUID): LoggedIn {
  const w = new Writer(db, ctx, newId);
  const u = w.get('select * from users where id = ? and deleted_at is null', userId);
  if (!u) throw new AuthError('unknown_user', 'That user was not found.');
  if (u.is_active !== 1) throw new AuthError('inactive', 'This user has been switched off.');
  if (!u.pin_hash) throw new AuthError('no_pin', 'This user has no PIN yet.');
  const lock = readLock(db, userId);
  if (lock.until > ctx.now) throw new AuthError('locked', 'Too many wrong PINs. Try again later.', { until: lock.until });

  if (verifyPin(pin, u.pin_hash)) {
    writeLock(db, userId, { failed: 0, until: 0 });
    audit(w, userId, 'login', userId);
    return { id: u.id, name: u.name, role_id: u.role_id, permissions: [...permissionsOf(db, userId)] };
  }
  const failed = lock.failed + 1;
  const dur = lockDuration(failed);
  writeLock(db, userId, { failed, until: dur ? ctx.now + dur : 0 });
  audit(w, userId, 'login_failed', userId);
  if (dur) throw new AuthError('locked', 'Too many wrong PINs. Try again later.', { until: ctx.now + dur });
  throw new AuthError('wrong_pin', 'Wrong PIN.', { attempts_left: LOCK_AFTER - failed });
}

function audit(w: Writer, actor: string | null, action: string, rowId: string | null, after?: unknown) {
  w.add('audit_log', { user_id: actor, action, table_name: 'users', row_id: rowId, after: after === undefined ? null : JSON.stringify(after) });
}

// ---- managing staff ----

const cleanName = (n: string) => { const t = (n ?? '').trim(); if (!t) throw new AuthError('missing', 'Enter a name.'); return t; };
const ownerRoleId = (db: DatabaseSync) => (db.prepare("select id from roles where name = 'Owner' and deleted_at is null").get() as { id: string } | undefined)?.id;
function activeOwners(db: DatabaseSync, exceptUserId?: string): number {
  const o = ownerRoleId(db);
  if (!o) return 0;
  return (db.prepare('select count(*) c from users where role_id = ? and is_active = 1 and deleted_at is null and id <> ?').get(o, exceptUserId ?? '') as { c: number }).c;
}

export function createUser(db: DatabaseSync, ctx: SetupContext, actorId: string, input: { name: string; phone?: string; role_id: string; pin: string; branch_ids?: string[] }, newId: () => string = randomUUID): string {
  require_(db, actorId, 'user.manage');
  const name = cleanName(input.name);
  const bad = validatePin(input.pin);
  if (bad) throw new AuthError('weak_pin', bad);
  const w = new Writer(db, ctx, newId);
  return tx(db, () => {
    if (!w.get('select 1 as x from roles where id = ? and deleted_at is null', input.role_id)) throw new AuthError('unknown_role', 'That role was not found.');
    if (w.get('select 1 as x from users where lower(name) = lower(?) and deleted_at is null and is_active = 1', name)) throw new AuthError('name_taken', 'Someone with that name already works here.');
    const id = w.addVersioned('users', { name, phone: input.phone?.trim() || null, role_id: input.role_id, pin_hash: hashPin(input.pin), is_active: 1 });
    for (const b of input.branch_ids ?? []) w.addVersioned('user_branches', { user_id: id, branch_id: b });
    audit(w, actorId, 'user_created', id, { role_id: input.role_id });
    return id;
  });
}

export function changeRole(db: DatabaseSync, ctx: SetupContext, actorId: string, userId: string, roleId: string, newId: () => string = randomUUID): void {
  require_(db, actorId, 'user.manage');
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const u = w.get('select role_id, is_active from users where id = ? and deleted_at is null', userId);
    if (!u) throw new AuthError('unknown_user', 'That user was not found.');
    if (!w.get('select 1 as x from roles where id = ? and deleted_at is null', roleId)) throw new AuthError('unknown_role', 'That role was not found.');
    if (u.role_id === ownerRoleId(db) && roleId !== u.role_id && u.is_active === 1 && activeOwners(db, userId) === 0) {
      throw new AuthError('last_owner', 'The shop must keep at least one owner.');
    }
    w.edit('users', userId, { role_id: roleId });
    audit(w, actorId, 'role_changed', userId, { role_id: roleId });
  });
}

export function setActive(db: DatabaseSync, ctx: SetupContext, actorId: string, userId: string, active: boolean, newId: () => string = randomUUID): void {
  require_(db, actorId, 'user.manage');
  if (!active && userId === actorId) throw new AuthError('self', 'You cannot switch yourself off.');
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    const u = w.get('select role_id, is_active from users where id = ? and deleted_at is null', userId);
    if (!u) throw new AuthError('unknown_user', 'That user was not found.');
    if (!active && u.role_id === ownerRoleId(db) && u.is_active === 1 && activeOwners(db, userId) === 0) throw new AuthError('last_owner', 'The shop must keep at least one owner.');
    w.edit('users', userId, { is_active: active ? 1 : 0 });
    audit(w, actorId, active ? 'user_enabled' : 'user_disabled', userId);
  });
}

/** A manager or owner sets a new PIN for someone (a forgotten PIN). Also clears that person's lockout on this phone. */
export function resetPin(db: DatabaseSync, ctx: SetupContext, actorId: string, userId: string, newPin: string, newId: () => string = randomUUID): void {
  require_(db, actorId, 'user.manage');
  const bad = validatePin(newPin);
  if (bad) throw new AuthError('weak_pin', bad);
  const w = new Writer(db, ctx, newId);
  tx(db, () => {
    w.edit('users', userId, { pin_hash: hashPin(newPin) });
    writeLock(db, userId, { failed: 0, until: 0 });
    audit(w, actorId, 'pin_reset', userId);
  });
}

/** Someone changes their own PIN; the old one must be right. */
export function changeOwnPin(db: DatabaseSync, ctx: SetupContext, userId: string, oldPin: string, newPin: string, newId: () => string = randomUUID): void {
  const bad = validatePin(newPin);
  if (bad) throw new AuthError('weak_pin', bad);
  login(db, ctx, userId, oldPin, newId); // counts failures and locks like any login
  const w = new Writer(db, ctx, newId);
  tx(db, () => { w.edit('users', userId, { pin_hash: hashPin(newPin) }); audit(w, userId, 'pin_changed', userId); });
}

/**
 * A second person approves a risky action on the spot by entering their own PIN (for example a discount or a void by a cashier).
 * The approval is recorded and the approver's id returned. The approver must hold the permission the action needs.
 */
export function approve(db: DatabaseSync, ctx: SetupContext, req: { action: Permission; requested_by: string | null; approver_id: string; pin: string; ref_type?: string; ref_id?: string }, newId: () => string = randomUUID): string {
  login(db, ctx, req.approver_id, req.pin, newId); // wrong PINs count towards the approver's lockout
  if (!hasPermission(db, req.approver_id, req.action)) throw new AuthError('forbidden', 'That person cannot approve this action.', { permission: req.action });
  const w = new Writer(db, ctx, newId);
  return tx(db, () => w.add('approvals', { action: req.action, requested_by: req.requested_by, approved_by: req.approver_id, ref_type: req.ref_type ?? null, ref_id: req.ref_id ?? null }));
}
