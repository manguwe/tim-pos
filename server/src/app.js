import { HttpError, asObject, ok, optStr, readBody, send, str } from './http.ts';
import * as licensing from './services/licensing.ts';
import * as sync from './services/sync.ts';
import * as vendor from './services/vendor.ts';
const routes = [];
const route = (method, path, auth, handler) => {
    routes.push({ method, parts: path.split('/').filter(Boolean), auth, handler });
};
const v = (req) => req.headers.authorization;
const dev = (w) => w.device;
const usr = (w) => w.vendor;
// ---- Public and phone routes ----
route('GET', '/health', 'none', (_req, ctx) => {
    ctx.db.get('select 1 as ok');
    return ok({ ok: true, time: ctx.now() });
});
route('POST', '/v1/activate', 'none', (req, ctx) => {
    const o = asObject(req.body);
    const result = licensing.activate(ctx, req.ip, {
        key: str(o, 'licence_key', { max: 64 }),
        fingerprint: str(o, 'fingerprint', { max: 128, min: 8 }),
        deviceName: str(o, 'device_name', { max: 80 }),
        platform: str(o, 'platform', { max: 20 }),
        appVersion: optStr(o, 'app_version', 40) ?? null,
    });
    return ok(result, 201);
});
route('POST', '/v1/licence/refresh', 'device', (_req, ctx, w) => ok(licensing.refreshToken(ctx, dev(w))));
route('POST', '/v1/sync/push', 'device', (req, ctx, w) => ok(sync.push(ctx, dev(w), req.body)));
route('GET', '/v1/sync/pull', 'device', (req, ctx, w) => ok(sync.pull(ctx, dev(w), req.query)));
route('GET', '/v1/app/update', 'device', (req, ctx) => {
    const build = Number(req.query.get('build') ?? 0);
    return ok(vendor.latestRelease(ctx, Number.isFinite(build) ? build : 0));
});
// ---- Vendor routes ----
route('POST', '/v1/vendor/login', 'none', async (req, ctx) => ok(await vendor.login(ctx, req.ip, req.body)));
route('POST', '/v1/vendor/2fa/setup', 'vendor', (req, ctx, w) => ok(vendor.twoFactorSetup(ctx, usr(w), req.body)));
route('POST', '/v1/vendor/2fa/enable', 'vendor', (req, ctx, w) => ok(vendor.twoFactorEnable(ctx, usr(w), req.body)));
route('GET', '/v1/vendor/overview', 'vendor', (_r, ctx) => ok(vendor.overview(ctx)));
route('GET', '/v1/vendor/tenants', 'vendor', (_r, ctx) => ok({ tenants: vendor.listTenants(ctx) }));
route('POST', '/v1/vendor/tenants', 'vendor', (req, ctx, w) => ok(vendor.createTenant(ctx, usr(w), req.body), 201));
route('GET', '/v1/vendor/tenants/:id', 'vendor', (req, ctx) => ok(vendor.tenantDetail(ctx, req.params.id)));
route('PATCH', '/v1/vendor/tenants/:id', 'vendor', (req, ctx, w) => ok(vendor.updateTenant(ctx, usr(w), req.params.id, req.body)));
route('GET', '/v1/vendor/plans', 'vendor', (_r, ctx) => ok({ plans: vendor.listPlans(ctx) }));
route('POST', '/v1/vendor/plans', 'vendor', (req, ctx, w) => ok(vendor.createPlan(ctx, usr(w), req.body), 201));
route('POST', '/v1/vendor/tenants/:id/licences', 'vendor', (req, ctx, w) => ok(vendor.issueLicence(ctx, usr(w), req.params.id, req.body), 201));
route('POST', '/v1/vendor/licences/:id/extend', 'vendor', (req, ctx, w) => ok(vendor.extendLicence(ctx, usr(w), req.params.id, req.body)));
route('POST', '/v1/vendor/licences/:id/suspend', 'vendor', (req, ctx, w) => ok(vendor.setLicenceStatus(ctx, usr(w), req.params.id, 'suspended')));
route('POST', '/v1/vendor/licences/:id/resume', 'vendor', (req, ctx, w) => ok(vendor.setLicenceStatus(ctx, usr(w), req.params.id, 'active')));
route('POST', '/v1/vendor/licences/:id/limits', 'vendor', (req, ctx, w) => ok(vendor.updateLimits(ctx, usr(w), req.params.id, req.body)));
route('POST', '/v1/vendor/licences/:id/rotate-key', 'vendor', (req, ctx, w) => ok(vendor.rotateKey(ctx, usr(w), req.params.id), 201));
route('POST', '/v1/vendor/devices/:id/release', 'vendor', (req, ctx, w) => ok(vendor.releaseDevice(ctx, usr(w), req.params.id, req.body)));
route('POST', '/v1/vendor/releases', 'vendor', (req, ctx, w) => ok(vendor.publishRelease(ctx, usr(w), req.body), 201));
route('GET', '/v1/vendor/releases', 'vendor', (_r, ctx) => ok({ releases: ctx.db.all('select * from app_releases order by build_number desc') }));
route('GET', '/v1/vendor/audit', 'vendor', (req, ctx) => ok({ entries: vendor.listAudit(ctx, req.query) }));
// ---- Dispatch ----
function match(method, path) {
    const segs = path.split('/').filter(Boolean);
    for (const r of routes) {
        if (r.method !== method || r.parts.length !== segs.length)
            continue;
        const params = {};
        let hit = true;
        for (let i = 0; i < segs.length; i++) {
            const p = r.parts[i];
            const s = segs[i];
            if (p.startsWith(':')) {
                try {
                    params[p.slice(1)] = decodeURIComponent(s);
                }
                catch {
                    throw new HttpError(400, 'bad_path', 'The address contains an invalid character');
                }
            }
            else if (p !== s) {
                hit = false;
                break;
            }
        }
        if (hit)
            return { route: r, params };
    }
    return null;
}
function clientIp(req, trustProxy) {
    if (trustProxy) {
        // The last value is the one our own proxy added. Earlier values can be written by the caller, so they are ignored.
        const fwd = String(req.headers['x-forwarded-for'] ?? '').split(',').at(-1)?.trim();
        if (fwd)
            return fwd;
    }
    return req.socket.remoteAddress ?? 'unknown';
}
export function createHandler(ctx) {
    return async (nodeReq, res) => {
        const started = Date.now();
        let status = 500;
        let logPath = '-';
        try {
            // Parsed inside the try: a malformed address is a 400 for that caller, never a crash.
            let url;
            try {
                url = new URL(nodeReq.url ?? '/', 'http://localhost');
            }
            catch {
                throw new HttpError(400, 'bad_path', 'The address is not valid');
            }
            logPath = url.pathname;
            const m = match(nodeReq.method ?? 'GET', url.pathname);
            if (!m)
                throw new HttpError(404, 'not_found', 'No such endpoint');
            const hasBody = nodeReq.method === 'POST' || nodeReq.method === 'PATCH' || nodeReq.method === 'PUT';
            const req = {
                method: nodeReq.method ?? 'GET',
                path: url.pathname,
                query: url.searchParams,
                headers: nodeReq.headers,
                params: m.params,
                ip: clientIp(nodeReq, ctx.config.trustProxy),
                // Callers who are not signed in may only send small bodies.
                body: hasBody ? await readBody(nodeReq, m.route.auth === 'none' ? 16 * 1024 : ctx.config.maxBodyBytes) : undefined,
            };
            const who = {};
            if (m.route.auth === 'device') {
                who.device = licensing.authenticateDevice(ctx, v(req), req.headers['x-app-version']);
            }
            else if (m.route.auth === 'vendor') {
                who.vendor = vendor.authenticateVendor(ctx, v(req));
            }
            const reply = await m.route.handler(req, ctx, who);
            status = reply.status;
            send(nodeReq, res, reply);
        }
        catch (err) {
            let reply;
            if (err instanceof HttpError) {
                reply = { status: err.status, body: { error: { code: err.code, message: err.message, ...err.extra } } };
            }
            else {
                console.error('Unhandled error', err);
                reply = { status: 500, body: { error: { code: 'server_error', message: 'Something went wrong on the server' } } };
            }
            status = reply.status;
            send(nodeReq, res, reply);
        }
        finally {
            // Method, path and status only. Credentials and bodies are never logged.
            if (ctx.config.log)
                console.log(`${nodeReq.method} ${logPath} ${status} ${Date.now() - started}ms`);
        }
    };
}
