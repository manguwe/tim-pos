import { DAY_MS, signLicenceToken, type LicencePayload } from '../licence.ts';
import { HttpError } from '../http.ts';
import type { Ctx } from '../context.ts';
import { generateLicenceKey, hashLicenceKey, licenceKeyHint, newId, randomSecret, safeEqual, sha256hex } from '../crypto.ts';

export interface LicenceRow {
  id: string;
  tenant_id: string;
  plan_id: string | null;
  key_hash: string;
  key_hint: string;
  status: 'active' | 'suspended';
  issued_at: number;
  expires_at: number;
  grace_days: number;
  max_offline_days: number;
  max_devices: number;
  max_branches: number;
  features: string;
  created_at: number;
}

export interface TenantRow {
  id: string;
  name: string;
  country_code: string;
  contact: string | null;
  notes: string | null;
  status: 'active' | 'suspended';
  created_at: number;
}

export interface ActivationRow {
  id: string;
  licence_id: string;
  tenant_id: string;
  fingerprint: string;
  device_name: string;
  platform: string;
  secret_hash: string;
  receipt_prefix: string;
  app_version: string | null;
  activated_at: number;
  last_seen_at: number | null;
  last_pull_seq: number;
  released_at: number | null;
}

export interface DeviceAuth {
  activation: ActivationRow;
  licence: LicenceRow;
  tenant: TenantRow;
}

const lockedError = (status: number, code: string, message: string) =>
  new HttpError(status, code, message, { locked: true });

/** Adds whole calendar months in UTC, keeping the day where possible. */
export function addMonths(ms: number, months: number): number {
  const d = new Date(ms);
  const day = d.getUTCDate();
  d.setUTCDate(1);
  d.setUTCMonth(d.getUTCMonth() + months);
  const lastDay = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 0)).getUTCDate();
  d.setUTCDate(Math.min(day, lastDay));
  return d.getTime();
}

export function newLicence(
  ctx: Ctx,
  input: {
    tenantId: string;
    planId?: string | null;
    expiresAt: number;
    graceDays?: number;
    maxOfflineDays?: number;
    maxDevices: number;
    maxBranches: number;
    features: string[];
  },
): { licence: LicenceRow; key: string } {
  const key = generateLicenceKey();
  const now = ctx.now();
  const row: LicenceRow = {
    id: newId(),
    tenant_id: input.tenantId,
    plan_id: input.planId ?? null,
    key_hash: hashLicenceKey(key, ctx.config.keyPepper),
    key_hint: licenceKeyHint(key),
    status: 'active',
    issued_at: now,
    expires_at: input.expiresAt,
    grace_days: input.graceDays ?? 30,
    max_offline_days: input.maxOfflineDays ?? 60,
    max_devices: input.maxDevices,
    max_branches: input.maxBranches,
    features: JSON.stringify(input.features),
    created_at: now,
  };
  ctx.db.run(
    `insert into licences (id, tenant_id, plan_id, key_hash, key_hint, status, issued_at, expires_at, grace_days,
       max_offline_days, max_devices, max_branches, features, created_at)
     values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
    row.id, row.tenant_id, row.plan_id, row.key_hash, row.key_hint, row.status, row.issued_at, row.expires_at,
    row.grace_days, row.max_offline_days, row.max_devices, row.max_branches, row.features, row.created_at,
  );
  return { licence: row, key };
}

/** Builds and signs the token a phone stores. The signing key never leaves the server. */
export function issueToken(ctx: Ctx, a: ActivationRow, lic: LicenceRow, tenant: TenantRow): string {
  const now = ctx.now();
  const plan = lic.plan_id
    ? ctx.db.get<{ name: string }>('select name from plans where id = ?', lic.plan_id)?.name ?? null
    : null;
  const payload: LicencePayload = {
    v: 1,
    licence_id: lic.id,
    shop_id: tenant.id,
    shop_name: tenant.name,
    device_id: a.id,
    receipt_prefix: a.receipt_prefix,
    plan,
    features: JSON.parse(lic.features) as string[],
    max_devices: lic.max_devices,
    max_branches: lic.max_branches,
    issued_at: now,
    expires_at: lic.expires_at,
    grace_days: lic.grace_days,
    max_offline_days: lic.max_offline_days,
    check_by: now + lic.max_offline_days * DAY_MS,
  };
  const token = signLicenceToken(payload, ctx.config.licencePrivateKey);
  ctx.db.run(
    'insert into licence_tokens (id, licence_id, device_id, issued_at, expires_at) values (?, ?, ?, ?, ?)',
    newId(), lic.id, a.id, now, payload.check_by,
  );
  return token;
}

function assertUsable(ctx: Ctx, lic: LicenceRow, tenant: TenantRow): void {
  if (tenant.status === 'suspended' || lic.status === 'suspended') {
    throw lockedError(403, 'licence_suspended', 'This licence is suspended. Contact your TIM-POS vendor.');
  }
  if (ctx.now() > lic.expires_at + lic.grace_days * DAY_MS) {
    throw lockedError(402, 'licence_expired', 'This licence has expired. Renew it to continue.');
  }
}

export interface ActivationResult {
  device_id: string;
  receipt_prefix: string;
  device_secret: string;
  licence_token: string;
  shop: { id: string; name: string; country_code: string };
  server_time: number;
}

export function activate(
  ctx: Ctx,
  ip: string,
  input: { key: string; fingerprint: string; deviceName: string; platform: string; appVersion: string | null },
): ActivationResult {
  if (ctx.activationLimiter.blocked(ip)) {
    throw new HttpError(429, 'too_many_attempts', 'Too many failed attempts. Try again later.');
  }
  const lic = ctx.db.get<LicenceRow>(
    'select * from licences where key_hash = ?',
    hashLicenceKey(input.key, ctx.config.keyPepper),
  );
  if (!lic) {
    ctx.activationLimiter.fail(ip);
    throw new HttpError(401, 'invalid_key', 'That licence key is not valid.');
  }
  const tenant = ctx.db.get<TenantRow>('select * from tenants where id = ?', lic.tenant_id) as TenantRow;
  assertUsable(ctx, lic, tenant);
  if (ctx.db.get('select 1 as x from activations where licence_id = ? and fingerprint = ? and blocked = 1', lic.id, input.fingerprint)) {
    throw new HttpError(403, 'device_blocked', 'This device was removed from the licence. Ask your TIM-POS vendor.');
  }

  return ctx.db.tx(() => {
    const now = ctx.now();
    const secret = randomSecret(32);
    const existing = ctx.db.get<ActivationRow>(
      'select * from activations where licence_id = ? and fingerprint = ? and released_at is null',
      lic.id, input.fingerprint,
    );
    let activation: ActivationRow;
    if (existing) {
      // Same phone activating again (for example after a reinstall): it keeps its slot and gets a new secret.
      ctx.db.run(
        'update activations set secret_hash = ?, device_name = ?, platform = ?, app_version = ?, last_seen_at = ? where id = ?',
        sha256hex(secret), input.deviceName, input.platform, input.appVersion, now, existing.id,
      );
      activation = { ...existing, secret_hash: sha256hex(secret), device_name: input.deviceName };
    } else {
      const used = ctx.db.get<{ n: number }>(
        'select count(*) as n from activations where licence_id = ? and released_at is null', lic.id,
      )?.n ?? 0;
      if (used >= lic.max_devices) {
        throw new HttpError(
          409,
          'device_limit',
          `This licence allows ${lic.max_devices} device(s) and all are in use. Ask your vendor to release one.`,
        );
      }
      // One more than the highest number ever given in this shop, so a released phone's prefix is never reused.
      const next = (ctx.db.get<{ n: number | null }>(
        "select max(cast(substr(receipt_prefix, 2) as integer)) as n from activations where tenant_id = ?", tenant.id,
      )?.n ?? 0) + 1;
      activation = {
        id: newId(), licence_id: lic.id, tenant_id: tenant.id, fingerprint: input.fingerprint,
        device_name: input.deviceName, platform: input.platform, secret_hash: sha256hex(secret),
        receipt_prefix: `D${next}`,
        app_version: input.appVersion, activated_at: now, last_seen_at: now, last_pull_seq: 0, released_at: null,
      };
      ctx.db.run(
        `insert into activations (id, licence_id, tenant_id, fingerprint, device_name, platform, secret_hash,
           receipt_prefix, app_version, activated_at, last_seen_at, last_pull_seq)
         values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)`,
        activation.id, lic.id, tenant.id, input.fingerprint, input.deviceName, input.platform,
        activation.secret_hash, activation.receipt_prefix, input.appVersion, now, now,
      );
    }
    ctx.activationLimiter.succeed(ip);
    return {
      device_id: activation.id,
      receipt_prefix: activation.receipt_prefix,
      device_secret: secret,
      licence_token: issueToken(ctx, activation, lic, tenant),
      shop: { id: tenant.id, name: tenant.name, country_code: tenant.country_code },
      server_time: now,
    };
  });
}

/** Checks the "Authorization: Device <id>.<secret>" header and the state of the licence behind it. */
export function authenticateDevice(
  ctx: Ctx,
  authorization: string | undefined,
  appVersion: string | undefined,
): DeviceAuth {
  const m = /^Device ([0-9a-f-]{36})\.([A-Za-z0-9_-]{20,128})$/.exec(authorization ?? '');
  if (!m) throw new HttpError(401, 'invalid_device', 'Missing or malformed device credentials');
  const [, id, secret] = m as unknown as [string, string, string];
  const a = ctx.db.get<ActivationRow>('select * from activations where id = ?', id);
  if (!a || !safeEqual(a.secret_hash, sha256hex(secret))) {
    throw new HttpError(401, 'invalid_device', 'Device credentials are not valid');
  }
  if (a.released_at !== null) {
    throw lockedError(403, 'device_released', 'This device was removed from the licence.');
  }
  const licence = ctx.db.get<LicenceRow>('select * from licences where id = ?', a.licence_id) as LicenceRow;
  const tenant = ctx.db.get<TenantRow>('select * from tenants where id = ?', a.tenant_id) as TenantRow;
  // Suspended or past the grace period: refused, and the app locks at once. Inside grace everything still works.
  assertUsable(ctx, licence, tenant);
  ctx.db.run(
    'update activations set last_seen_at = ?, app_version = coalesce(?, app_version) where id = ?',
    ctx.now(), appVersion ?? null, a.id,
  );
  return { activation: a, licence, tenant };
}

export function refreshToken(ctx: Ctx, auth: DeviceAuth): { licence_token: string; server_time: number } {
  return { licence_token: issueToken(ctx, auth.activation, auth.licence, auth.tenant), server_time: ctx.now() };
}
