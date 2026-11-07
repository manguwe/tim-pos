import { HttpError, asObject, int, optInt, optStr, str, strList, } from '../http.ts';
import { hashPassword, newId, newTotpSecret, seal, signToken, unseal, verifyPassword, verifyToken, verifyTotp, } from '../crypto.ts';
import { DAY_MS } from '../licence.ts';
import { addMonths, newLicence } from './licensing.ts';
export function audit(ctx, vendorId, action, tenantId, detail = {}) {
    ctx.db.run('insert into vendor_audit_log (id, vendor_user_id, action, tenant_id, detail, created_at) values (?, ?, ?, ?, ?, ?)', newId(), vendorId, action, tenantId, JSON.stringify(detail), ctx.now());
}
// ---- Accounts and sign-in ----
export async function createVendorUser(ctx, input) {
    if (input.password.length < 12)
        throw new HttpError(400, 'weak_password', 'Use a password of at least 12 characters');
    const email = input.email.trim().toLowerCase();
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email))
        throw new HttpError(400, 'invalid_request', 'email is not valid');
    const id = newId();
    ctx.db.run('insert into vendor_users (id, name, email, password_hash, created_at) values (?, ?, ?, ?, ?)', id, input.name, email, await hashPassword(input.password), ctx.now());
    audit(ctx, id, 'vendor_user.create', null, { email });
    return ctx.db.get('select * from vendor_users where id = ?', id);
}
const BAD_LOGIN = () => new HttpError(401, 'invalid_login', 'Email, password or code is not correct');
export async function login(ctx, ip, body) {
    const o = asObject(body);
    const email = str(o, 'email', { max: 200 }).toLowerCase();
    const password = str(o, 'password', { max: 500 });
    const code = optStr(o, 'code', 12);
    const pair = `${ip}|${email}`;
    if (ctx.loginPairLimiter.blocked(pair) || ctx.loginIpLimiter.blocked(ip) || ctx.loginEmailLimiter.blocked(email)) {
        throw new HttpError(429, 'too_many_attempts', 'Too many failed attempts. Try again later.');
    }
    const fail = () => {
        ctx.loginPairLimiter.fail(pair);
        ctx.loginIpLimiter.fail(ip);
        ctx.loginEmailLimiter.fail(email);
        throw BAD_LOGIN();
    };
    const user = ctx.db.get('select * from vendor_users where email = ?', email);
    // Hash even for unknown emails so response time does not reveal which emails exist.
    const passwordOk = await verifyPassword(password, user?.password_hash ?? 'scrypt$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA');
    if (!user || !user.is_active || !passwordOk)
        return fail();
    if (user.totp_enabled) {
        const secret = user.totp_secret_sealed ? unseal(user.totp_secret_sealed, ctx.config.vendorTokenSecret) : null;
        const step = secret && code ? verifyTotp(secret, code, ctx.now()) : null;
        if (step === null) {
            if (!code)
                throw new HttpError(401, 'code_required', 'Enter the code from your authenticator app', { code_required: true });
            return fail();
        }
        // A code works once. The check and the update are one statement, so two sign-ins at the same moment cannot both pass.
        if (ctx.db.run('update vendor_users set totp_last_step = ? where id = ? and totp_last_step < ?', step, user.id, step) !== 1) {
            return fail();
        }
    }
    ctx.loginPairLimiter.succeed(pair);
    const expiresAt = ctx.now() + ctx.config.vendorTokenTtlMs;
    audit(ctx, user.id, 'vendor.login', null, { ip });
    return {
        token: signToken({ typ: 'vendor', sub: user.id, exp: expiresAt }, ctx.config.vendorTokenSecret),
        expires_at: expiresAt,
        user: { id: user.id, name: user.name, email: user.email, two_factor: !!user.totp_enabled },
    };
}
export function authenticateVendor(ctx, authorization) {
    const m = /^Bearer (.+)$/.exec(authorization ?? '');
    const claims = m ? verifyToken(m[1], ctx.config.vendorTokenSecret) : null;
    if (!claims || claims.typ !== 'vendor' || claims.exp < ctx.now()) {
        throw new HttpError(401, 'unauthorised', 'Sign in to continue');
    }
    const user = ctx.db.get('select * from vendor_users where id = ? and is_active = 1', claims.sub);
    if (!user)
        throw new HttpError(401, 'unauthorised', 'Sign in to continue');
    return user;
}
export function twoFactorSetup(ctx, user, body) {
    if (user.totp_enabled) {
        // Replacing two-factor needs a current code, so a stolen sign-in token alone cannot weaken the account.
        const o = body === undefined ? {} : asObject(body);
        const code = optStr(o, 'code', 12);
        const current = user.totp_secret_sealed ? unseal(user.totp_secret_sealed, ctx.config.vendorTokenSecret) : null;
        const step = current && code ? verifyTotp(current, code, ctx.now()) : null;
        if (step === null)
            throw new HttpError(401, 'code_required', 'Enter a current code from your authenticator app to replace it');
        if (ctx.db.run('update vendor_users set totp_last_step = ? where id = ? and totp_last_step < ?', step, user.id, step) !== 1) {
            throw new HttpError(401, 'code_required', 'That code was already used. Wait for the next one.');
        }
    }
    const secret = newTotpSecret();
    // The new secret waits in a separate column. The working one stays in force until the new one is confirmed.
    ctx.db.run('update vendor_users set totp_pending_sealed = ? where id = ?', seal(secret, ctx.config.vendorTokenSecret), user.id);
    const label = encodeURIComponent(`TIM-POS:${user.email}`);
    return { secret, otpauth_url: `otpauth://totp/${label}?secret=${secret}&issuer=TIM-POS` };
}
export function twoFactorEnable(ctx, user, body) {
    const code = str(asObject(body), 'code', { max: 12 });
    const secret = user.totp_pending_sealed ? unseal(user.totp_pending_sealed, ctx.config.vendorTokenSecret) : null;
    const step = secret ? verifyTotp(secret, code, ctx.now()) : null;
    if (step === null)
        throw new HttpError(400, 'invalid_code', 'That code is not correct. Run setup again if it keeps failing.');
    ctx.db.run('update vendor_users set totp_secret_sealed = totp_pending_sealed, totp_pending_sealed = null, totp_enabled = 1, totp_last_step = ? where id = ?', step, user.id);
    audit(ctx, user.id, 'vendor.2fa_enabled', null);
    return { two_factor: true };
}
// ---- Shops (tenants) ----
const publicLicence = (l) => ({
    id: l.id, tenant_id: l.tenant_id, plan_id: l.plan_id, key_hint: l.key_hint, status: l.status,
    issued_at: l.issued_at, expires_at: l.expires_at, grace_days: l.grace_days, max_offline_days: l.max_offline_days,
    max_devices: l.max_devices, max_branches: l.max_branches, features: JSON.parse(l.features),
});
export function createTenant(ctx, user, body) {
    const o = asObject(body);
    const t = {
        id: newId(),
        name: str(o, 'name', { max: 120 }),
        country_code: str(o, 'country_code', { max: 2, min: 2 }).toUpperCase(),
        contact: optStr(o, 'contact', 300) ?? null,
        notes: optStr(o, 'notes', 2000) ?? null,
        status: 'active',
        created_at: ctx.now(),
    };
    ctx.db.run('insert into tenants (id, name, country_code, contact, notes, status, created_at) values (?, ?, ?, ?, ?, ?, ?)', t.id, t.name, t.country_code, t.contact, t.notes, t.status, t.created_at);
    audit(ctx, user.id, 'tenant.create', t.id, { name: t.name });
    return t;
}
function mustTenant(ctx, id) {
    const t = ctx.db.get('select * from tenants where id = ?', id);
    if (!t)
        throw new HttpError(404, 'not_found', 'Shop not found');
    return t;
}
export function updateTenant(ctx, user, id, body) {
    const o = asObject(body);
    const t = mustTenant(ctx, id);
    const name = o.name === undefined ? t.name : str(o, 'name', { max: 120 });
    const contact = o.contact === undefined ? t.contact : optStr(o, 'contact', 300) ?? null;
    const notes = o.notes === undefined ? t.notes : optStr(o, 'notes', 2000) ?? null;
    let status = t.status;
    if (o.status !== undefined) {
        if (o.status !== 'active' && o.status !== 'suspended')
            throw new HttpError(400, 'invalid_request', 'status must be active or suspended');
        status = o.status;
    }
    ctx.db.run('update tenants set name = ?, contact = ?, notes = ?, status = ? where id = ?', name, contact, notes, status, id);
    audit(ctx, user.id, status !== t.status ? `tenant.${status === 'suspended' ? 'suspend' : 'resume'}` : 'tenant.update', id);
    return mustTenant(ctx, id);
}
export function listTenants(ctx) {
    return ctx.db.all(`select t.id, t.name, t.country_code, t.status, t.created_at,
       (select max(expires_at) from licences l where l.tenant_id = t.id) as licence_expires_at,
       (select count(*) from activations a where a.tenant_id = t.id and a.released_at is null) as devices,
       (select max(last_seen_at) from activations a where a.tenant_id = t.id) as last_seen_at
     from tenants t order by t.created_at desc`);
}
export function tenantDetail(ctx, id) {
    const t = mustTenant(ctx, id);
    const licences = ctx.db.all('select * from licences where tenant_id = ? order by created_at desc', id);
    const devices = ctx.db.all(`select id, licence_id, device_name, platform, app_version, activated_at, last_seen_at, last_pull_seq, released_at
     from activations where tenant_id = ? order by activated_at`, id);
    const head = ctx.db.get('select max(seq) as seq from change_feed where shop_id = ?', id)?.seq ?? 0;
    return { ...t, licences: licences.map(publicLicence), devices, sync_head_seq: head };
}
// ---- Plans ----
export function createPlan(ctx, user, body) {
    const o = asObject(body);
    const id = newId();
    const row = {
        id,
        name: str(o, 'name', { max: 80 }),
        one_time_fee_minor: optInt(o, 'one_time_fee_minor') ?? 0,
        monthly_fee_minor: optInt(o, 'monthly_fee_minor') ?? 0,
        currency: (optStr(o, 'currency', 3) || 'USD').toUpperCase(),
        max_devices: optInt(o, 'max_devices', { min: 1, max: 1000 }) ?? 1,
        max_branches: optInt(o, 'max_branches', { min: 1, max: 1000 }) ?? 1,
        features: strList(o, 'features') ?? [],
    };
    try {
        ctx.db.run(`insert into plans (id, name, one_time_fee_minor, monthly_fee_minor, currency, max_devices, max_branches, features, created_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?)`, id, row.name, row.one_time_fee_minor, row.monthly_fee_minor, row.currency, row.max_devices, row.max_branches, JSON.stringify(row.features), ctx.now());
    }
    catch {
        throw new HttpError(409, 'plan_exists', 'A plan with that name already exists');
    }
    audit(ctx, user.id, 'plan.create', null, { name: row.name });
    return row;
}
export function listPlans(ctx) {
    return ctx.db.all('select * from plans order by name').map((p) => ({
        ...p, features: JSON.parse(p.features),
    }));
}
// ---- Licences ----
export function issueLicence(ctx, user, tenantId, body) {
    mustTenant(ctx, tenantId);
    const o = asObject(body);
    const planId = optStr(o, 'plan_id', 64) || null;
    const plan = planId
        ? ctx.db.get('select max_devices, max_branches, features from plans where id = ?', planId)
        : undefined;
    if (planId && !plan)
        throw new HttpError(404, 'not_found', 'Plan not found');
    const months = optInt(o, 'months', { min: 1, max: 120 });
    const until = optInt(o, 'expires_at', { min: 1 });
    if ((months === undefined) === (until === undefined)) {
        throw new HttpError(400, 'invalid_request', 'Give either months or expires_at');
    }
    const { licence, key } = ctx.db.tx(() => newLicence(ctx, {
        tenantId,
        planId,
        expiresAt: until ?? addMonths(ctx.now(), months),
        graceDays: optInt(o, 'grace_days', { max: 365 }),
        maxOfflineDays: optInt(o, 'max_offline_days', { min: 1, max: 365 }),
        maxDevices: optInt(o, 'max_devices', { min: 1, max: 1000 }) ?? plan?.max_devices ?? 1,
        maxBranches: optInt(o, 'max_branches', { min: 1, max: 1000 }) ?? plan?.max_branches ?? 1,
        features: strList(o, 'features') ?? (plan ? JSON.parse(plan.features) : []),
    }));
    audit(ctx, user.id, 'licence.issue', tenantId, { licence_id: licence.id, expires_at: licence.expires_at });
    // The key is shown here once. Only a keyed hash is stored, so it cannot be shown again.
    return { ...publicLicence(licence), key };
}
function mustLicence(ctx, id) {
    const l = ctx.db.get('select * from licences where id = ?', id);
    if (!l)
        throw new HttpError(404, 'not_found', 'Licence not found');
    return l;
}
export function extendLicence(ctx, user, id, body) {
    const l = mustLicence(ctx, id);
    const o = asObject(body);
    const months = optInt(o, 'months', { min: 1, max: 120 });
    const until = optInt(o, 'expires_at', { min: 1 });
    if ((months === undefined) === (until === undefined))
        throw new HttpError(400, 'invalid_request', 'Give either months or expires_at');
    // Renewing early adds to the current end date. A licence that already lapsed restarts from today.
    const next = until ?? addMonths(Math.max(l.expires_at, ctx.now()), months);
    ctx.db.run('update licences set expires_at = ? where id = ?', next, id);
    audit(ctx, user.id, 'licence.extend', l.tenant_id, { licence_id: id, from: l.expires_at, to: next });
    return publicLicence(mustLicence(ctx, id));
}
export function setLicenceStatus(ctx, user, id, status) {
    const l = mustLicence(ctx, id);
    ctx.db.run('update licences set status = ? where id = ?', status, id);
    audit(ctx, user.id, status === 'suspended' ? 'licence.suspend' : 'licence.resume', l.tenant_id, { licence_id: id });
    return publicLicence(mustLicence(ctx, id));
}
export function updateLimits(ctx, user, id, body) {
    const l = mustLicence(ctx, id);
    const o = asObject(body);
    const next = {
        max_devices: optInt(o, 'max_devices', { min: 1, max: 1000 }) ?? l.max_devices,
        max_branches: optInt(o, 'max_branches', { min: 1, max: 1000 }) ?? l.max_branches,
        grace_days: optInt(o, 'grace_days', { max: 365 }) ?? l.grace_days,
        max_offline_days: optInt(o, 'max_offline_days', { min: 1, max: 365 }) ?? l.max_offline_days,
        features: JSON.stringify(strList(o, 'features') ?? JSON.parse(l.features)),
    };
    ctx.db.run('update licences set max_devices = ?, max_branches = ?, grace_days = ?, max_offline_days = ?, features = ? where id = ?', next.max_devices, next.max_branches, next.grace_days, next.max_offline_days, next.features, id);
    audit(ctx, user.id, 'licence.limits', l.tenant_id, { licence_id: id });
    return publicLicence(mustLicence(ctx, id));
}
/** Replaces a leaked key. Phones already activated keep working; new activations need the new key. */
export function rotateKey(ctx, user, id) {
    const l = mustLicence(ctx, id);
    const { licence: fresh, key } = ctx.db.tx(() => {
        const created = newLicence(ctx, {
            tenantId: l.tenant_id, planId: l.plan_id, expiresAt: l.expires_at, graceDays: l.grace_days,
            maxOfflineDays: l.max_offline_days, maxDevices: l.max_devices, maxBranches: l.max_branches,
            features: JSON.parse(l.features),
        });
        // Move the device slots to the replacement and retire the old row.
        ctx.db.run('update activations set licence_id = ? where licence_id = ?', created.licence.id, id);
        ctx.db.run('update licence_tokens set licence_id = ? where licence_id = ?', created.licence.id, id);
        ctx.db.run("update licences set status = 'suspended', key_hash = ?, key_hint = 'rotd' where id = ?", `rotated:${newId()}`, id);
        ctx.db.run('update licences set status = ? where id = ?', l.status, created.licence.id);
        return created;
    });
    audit(ctx, user.id, 'licence.rotate_key', l.tenant_id, { old: id, new: fresh.id });
    return { ...publicLicence(mustLicence(ctx, fresh.id)), key };
}
/** A released phone is blocked from activating again with the same key, unless the vendor says block: false. */
export function releaseDevice(ctx, user, id, body) {
    const o = body === undefined ? {} : asObject(body);
    const block = o.block === undefined ? true : o.block === true;
    if (o.block !== undefined && typeof o.block !== 'boolean')
        throw new HttpError(400, 'invalid_request', 'block must be true or false');
    const a = ctx.db.get('select id, tenant_id, released_at from activations where id = ?', id);
    if (!a)
        throw new HttpError(404, 'not_found', 'Device not found');
    ctx.db.run('update activations set released_at = coalesce(released_at, ?), blocked = ? where id = ?', ctx.now(), block ? 1 : 0, id);
    audit(ctx, user.id, 'device.release', a.tenant_id, { device_id: id, blocked: block });
    return { id, released: true, blocked: block };
}
// ---- Releases, overview, audit ----
export function publishRelease(ctx, user, body) {
    const o = asObject(body);
    const sha = str(o, 'sha256', { max: 64, min: 64 }).toLowerCase();
    if (!/^[0-9a-f]{64}$/.test(sha))
        throw new HttpError(400, 'invalid_request', 'sha256 must be 64 hex characters');
    const url = str(o, 'apk_url', { max: 500 });
    if (!/^https:\/\//.test(url))
        throw new HttpError(400, 'invalid_request', 'apk_url must be an https address');
    const row = {
        id: newId(),
        version: str(o, 'version', { max: 40 }),
        build_number: int(o, 'build_number', { min: 1 }),
        min_supported_build: optInt(o, 'min_supported_build', { min: 0 }) ?? 0,
        sha256: sha,
        size_bytes: int(o, 'size_bytes', { min: 1 }),
        apk_url: url,
        notes: optStr(o, 'notes', 4000) ?? null,
        published_at: ctx.now(),
    };
    try {
        ctx.db.run(`insert into app_releases (id, version, build_number, min_supported_build, sha256, size_bytes, apk_url, notes, published_at)
       values (?, ?, ?, ?, ?, ?, ?, ?, ?)`, row.id, row.version, row.build_number, row.min_supported_build, row.sha256, row.size_bytes, row.apk_url, row.notes, row.published_at);
    }
    catch {
        throw new HttpError(409, 'release_exists', 'A release with that build number already exists');
    }
    audit(ctx, user.id, 'release.publish', null, { version: row.version, build: row.build_number });
    return row;
}
export function latestRelease(ctx, currentBuild) {
    const r = ctx.db.get('select * from app_releases order by build_number desc limit 1');
    if (!r)
        return { update_available: false, must_update: false };
    // The newest release decides the minimum, so raising it forces older phones to update.
    return {
        update_available: r.build_number > currentBuild,
        must_update: currentBuild < r.min_supported_build,
        release: r,
    };
}
export function overview(ctx) {
    const now = ctx.now();
    const n = (sql, ...p) => ctx.db.get(sql, ...p)?.n ?? 0;
    return {
        shops: n('select count(*) as n from tenants'),
        shops_suspended: n("select count(*) as n from tenants where status = 'suspended'"),
        active_licences: n("select count(*) as n from licences l join tenants t on t.id = l.tenant_id where l.status = 'active' and t.status = 'active' and l.expires_at >= ?", now),
        expiring_in_14_days: n("select count(*) as n from licences where status = 'active' and expires_at >= ? and expires_at < ?", now, now + 14 * DAY_MS),
        in_grace: n("select count(*) as n from licences where status = 'active' and expires_at < ? and expires_at + grace_days * 86400000 >= ?", now, now),
        devices: n('select count(*) as n from activations where released_at is null'),
        not_seen_7_days: n('select count(*) as n from activations where released_at is null and (last_seen_at is null or last_seen_at < ?)', now - 7 * DAY_MS),
        server_time: now,
    };
}
export function listAudit(ctx, query) {
    const n = Number(query.get('limit') ?? 100);
    const limit = Number.isSafeInteger(n) ? Math.min(500, Math.max(1, n)) : 100;
    return ctx.db.all('select * from vendor_audit_log order by created_at desc, rowid desc limit ?', limit).map((r) => ({ ...r, detail: JSON.parse(r.detail) }));
}
