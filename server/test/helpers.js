import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { createHandler } from '../src/app.ts';
import { generateSecrets } from '../src/config.ts';
import { makeCtx } from '../src/context.ts';
import { openDb } from '../src/db.ts';
import { createVendorUser } from '../src/services/vendor.ts';
export const DAY = 86400000;
export const START = Date.UTC(2026, 10, 1); // 1 Nov 2026
export async function boot(overrides = {}) {
    const config = {
        port: 0, host: '127.0.0.1', dbPath: ':memory:', ...generateSecrets(), trustProxy: false,
        vendorTokenTtlMs: 12 * 3600000, syncPageSize: 500, maxBatchChanges: 1000, maxBodyBytes: 8 * 1024 * 1024,
        log: false, ...overrides,
    };
    const clock = { t: START };
    const ctx = makeCtx(openDb(':memory:'), config, () => clock.t);
    const server = createServer(createHandler(ctx));
    await new Promise((r) => server.listen(0, '127.0.0.1', r));
    const addr = server.address();
    const url = `http://127.0.0.1:${typeof addr === 'object' && addr ? addr.port : 0}`;
    const call = async (method, path, opts = {}) => {
        const headers = { ...(opts.headers ?? {}) };
        if (opts.auth)
            headers.authorization = opts.auth;
        let body = opts.rawBody;
        if (opts.body !== undefined && method !== 'GET') {
            body = JSON.stringify(opts.body);
            headers['content-type'] = 'application/json';
            if (opts.gzip) {
                body = gzipSync(body);
                headers['content-encoding'] = 'gzip';
            }
        }
        const res = await fetch(url + path, { method, headers, body: typeof body === 'string' || body === undefined ? body : new Uint8Array(body) });
        const text = await res.text();
        return { status: res.status, json: text ? JSON.parse(text) : undefined };
    };
    return {
        url, ctx, clock, call,
        close: async () => {
            await new Promise((r) => server.close(() => r()));
            ctx.db.close();
        },
    };
}
export const VENDOR_PASSWORD = 'a-long-test-password';
export async function vendorToken(h) {
    if (!h.ctx.db.get('select 1 as x from vendor_users')) {
        await createVendorUser(h.ctx, { name: 'Tim', email: 'tim@example.com', password: VENDOR_PASSWORD });
    }
    const r = await h.call('POST', '/v1/vendor/login', { body: { email: 'tim@example.com', password: VENDOR_PASSWORD } });
    if (r.status !== 200)
        throw new Error(`login failed: ${JSON.stringify(r.json)}`);
    return `Bearer ${r.json.token}`;
}
export async function makeShop(h, opts = {}) {
    const vendor = await vendorToken(h);
    const t = await h.call('POST', '/v1/vendor/tenants', {
        auth: vendor, body: { name: opts.name ?? 'Mbare Mini Market', country_code: 'zw' },
    });
    if (t.status !== 201)
        throw new Error(`tenant failed: ${JSON.stringify(t.json)}`);
    const l = await h.call('POST', `/v1/vendor/tenants/${t.json.id}/licences`, {
        auth: vendor,
        body: {
            months: opts.months ?? 1, max_devices: opts.max_devices ?? 2,
            ...(opts.grace_days !== undefined ? { grace_days: opts.grace_days } : {}),
            ...(opts.max_offline_days !== undefined ? { max_offline_days: opts.max_offline_days } : {}),
        },
    });
    if (l.status !== 201)
        throw new Error(`licence failed: ${JSON.stringify(l.json)}`);
    return { vendor, tenantId: t.json.id, licenceId: l.json.id, key: l.json.key };
}
export async function activateDevice(h, key, fingerprint = randomUUID()) {
    const r = await h.call('POST', '/v1/activate', {
        body: { licence_key: key, fingerprint, device_name: 'Till 1', platform: 'android', app_version: '1.0.0' },
    });
    if (r.status !== 201)
        throw new Error(`activate failed: ${r.status} ${JSON.stringify(r.json)}`);
    return {
        id: r.json.device_id, secret: r.json.device_secret, token: r.json.licence_token, fingerprint,
        auth: `Device ${r.json.device_id}.${r.json.device_secret}`,
    };
}
export const change = (table, data = {}, o = {}) => ({
    table, row_id: o.id ?? randomUUID(), op: o.op ?? 'insert', version: o.version ?? 1,
    updated_at: o.updated_at ?? START, data,
});
export const push = (h, d, changes, batchId = randomUUID()) => h.call('POST', '/v1/sync/push', { auth: d.auth, body: { batch_id: batchId, changes } });
