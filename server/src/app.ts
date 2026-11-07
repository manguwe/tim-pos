import type { IncomingMessage, ServerResponse } from 'node:http';
import type { Ctx } from './context.ts';
import { HttpError, asObject, ok, optStr, readBody, send, str, type Reply, type Req } from './http.ts';
import * as licensing from './services/licensing.ts';
import * as sync from './services/sync.ts';
import * as billing from './services/billing.ts';
import * as vendor from './services/vendor.ts';
import * as owners from './services/owners.ts';
import { serveDashboard } from './static.ts';

type Auth = 'none' | 'device' | 'vendor' | 'owner';
type Handler = (req: Req, ctx: Ctx, who: { device?: licensing.DeviceAuth; vendor?: vendor.VendorUser; owner?: owners.OwnerUser }) => Reply | Promise<Reply>;

interface Route {
  method: string;
  parts: string[];
  auth: Auth;
  handler: Handler;
}

const routes: Route[] = [];
const route = (method: string, path: string, auth: Auth, handler: Handler): void => {
  routes.push({ method, parts: path.split('/').filter(Boolean), auth, handler });
};

const v = (req: Req) => req.headers.authorization;
const dev = (w: { device?: licensing.DeviceAuth }) => w.device as licensing.DeviceAuth;
const usr = (w: { vendor?: vendor.VendorUser }) => w.vendor as vendor.VendorUser;

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
route('GET', '/v1/vendor/tenants/:id', 'vendor', (req, ctx) => ok(vendor.tenantDetail(ctx, req.params.id as string)));
route('PATCH', '/v1/vendor/tenants/:id', 'vendor', (req, ctx, w) => ok(vendor.updateTenant(ctx, usr(w), req.params.id as string, req.body)));
route('GET', '/v1/vendor/plans', 'vendor', (_r, ctx) => ok({ plans: vendor.listPlans(ctx) }));
route('POST', '/v1/vendor/plans', 'vendor', (req, ctx, w) => ok(vendor.createPlan(ctx, usr(w), req.body), 201));
route('POST', '/v1/vendor/tenants/:id/licences', 'vendor', (req, ctx, w) =>
  ok(vendor.issueLicence(ctx, usr(w), req.params.id as string, req.body), 201));
route('POST', '/v1/vendor/licences/:id/extend', 'vendor', (req, ctx, w) =>
  ok(vendor.extendLicence(ctx, usr(w), req.params.id as string, req.body)));
route('POST', '/v1/vendor/licences/:id/suspend', 'vendor', (req, ctx, w) =>
  ok(vendor.setLicenceStatus(ctx, usr(w), req.params.id as string, 'suspended')));
route('POST', '/v1/vendor/licences/:id/resume', 'vendor', (req, ctx, w) =>
  ok(vendor.setLicenceStatus(ctx, usr(w), req.params.id as string, 'active')));
route('POST', '/v1/vendor/licences/:id/limits', 'vendor', (req, ctx, w) =>
  ok(vendor.updateLimits(ctx, usr(w), req.params.id as string, req.body)));
route('POST', '/v1/vendor/licences/:id/rotate-key', 'vendor', (req, ctx, w) =>
  ok(vendor.rotateKey(ctx, usr(w), req.params.id as string), 201));
route('POST', '/v1/vendor/devices/:id/release', 'vendor', (req, ctx, w) =>
  ok(vendor.releaseDevice(ctx, usr(w), req.params.id as string, req.body)));
route('POST', '/v1/vendor/releases', 'vendor', (req, ctx, w) => ok(vendor.publishRelease(ctx, usr(w), req.body), 201));
route('GET', '/v1/vendor/releases', 'vendor', (_r, ctx) =>
  ok({ releases: ctx.db.all('select * from app_releases order by build_number desc') }));
route('GET', '/v1/vendor/billing/profile', 'vendor', (_r, ctx) => ok(billing.getProfile(ctx)));
route('PUT', '/v1/vendor/billing/profile', 'vendor', (req, ctx, w) => ok(billing.saveProfile(ctx, usr(w), req.body)));
route('POST', '/v1/vendor/billing/run', 'vendor', (req, ctx, w) => ok(billing.monthlyRun(ctx, usr(w), req.body)));
route('GET', '/v1/vendor/invoices', 'vendor', (req, ctx) => ok({ invoices: billing.listInvoices(ctx, req.query) }));
route('GET', '/v1/vendor/invoices/:id', 'vendor', (req, ctx) => ok(billing.invoiceDetail(ctx, req.params.id as string)));
route('POST', '/v1/vendor/invoices/:id/void', 'vendor', (req, ctx, w) => ok(billing.voidInvoice(ctx, usr(w), req.params.id as string, req.body)));
route('POST', '/v1/vendor/invoices/:id/payments', 'vendor', (req, ctx, w) => {
  const r = billing.recordPayment(ctx, usr(w), req.params.id as string, req.body);
  return ok(r, r.duplicate ? 200 : 201);
});
route('GET', '/v1/vendor/payments', 'vendor', (req, ctx) => ok({ payments: billing.listPayments(ctx, req.query) }));
route('POST', '/v1/vendor/payments/:id/reverse', 'vendor', (req, ctx, w) => ok(billing.reversePayment(ctx, usr(w), req.params.id as string, req.body)));
route('POST', '/v1/vendor/tenants/:id/invoices', 'vendor', (req, ctx, w) => ok(billing.createInvoice(ctx, usr(w), req.params.id as string, req.body), 201));
route('GET', '/v1/vendor/tenants/:id/statement', 'vendor', (req, ctx) => ok(billing.statement(ctx, req.params.id as string)));
route('GET', '/v1/vendor/audit', 'vendor', (req, ctx) => ok({ entries: vendor.listAudit(ctx, req.query) }));

// ---- Vendor: owner logins for a shop ----

route('GET', '/v1/vendor/tenants/:id/owners', 'vendor', (req, ctx) => ok({ owners: owners.listOwners(ctx, req.params.id as string) }));
route('POST', '/v1/vendor/tenants/:id/owners', 'vendor', async (req, ctx, w) => ok(await owners.createOwner(ctx, usr(w), req.params.id as string, req.body), 201));
route('POST', '/v1/vendor/owners/:id/reset-password', 'vendor', async (req, ctx, w) => ok(await owners.resetOwnerPassword(ctx, usr(w), req.params.id as string)));
route('PATCH', '/v1/vendor/owners/:id', 'vendor', (req, ctx, w) => ok(owners.setOwnerActive(ctx, usr(w), req.params.id as string, req.body)));

// ---- Shop owner routes ----

const own = (w: { owner?: owners.OwnerUser }) => w.owner as owners.OwnerUser;
route('POST', '/v1/owner/login', 'none', async (req, ctx) => ok(await owners.ownerLogin(ctx, req.ip, req.body)));
route('GET', '/v1/owner/me', 'owner', (_r, ctx, w) => ok(owners.me(ctx, own(w))));
route('POST', '/v1/owner/password', 'owner', async (req, ctx, w) => ok(await owners.changeOwnerPassword(ctx, own(w), req.body)));
route('GET', '/v1/owner/reports/:name', 'owner', (req, ctx, w) => ok(owners.report(ctx, own(w), req.params.name as string, req.query)));

// ---- Dispatch ----

function match(method: string, path: string): { route: Route; params: Record<string, string> } | null {
  const segs = path.split('/').filter(Boolean);
  for (const r of routes) {
    if (r.method !== method || r.parts.length !== segs.length) continue;
    const params: Record<string, string> = {};
    let hit = true;
    for (let i = 0; i < segs.length; i++) {
      const p = r.parts[i] as string;
      const s = segs[i] as string;
      if (p.startsWith(':')) {
        try {
          params[p.slice(1)] = decodeURIComponent(s);
        } catch {
          throw new HttpError(400, 'bad_path', 'The address contains an invalid character');
        }
      }
      else if (p !== s) { hit = false; break; }
    }
    if (hit) return { route: r, params };
  }
  return null;
}

function clientIp(req: IncomingMessage, trustProxy: boolean): string {
  if (trustProxy) {
    // The last value is the one our own proxy added. Earlier values can be written by the caller, so they are ignored.
    const fwd = String(req.headers['x-forwarded-for'] ?? '').split(',').at(-1)?.trim();
    if (fwd) return fwd;
  }
  return req.socket.remoteAddress ?? 'unknown';
}

export function createHandler(ctx: Ctx) {
  return async (nodeReq: IncomingMessage, res: ServerResponse): Promise<void> => {
    const started = Date.now();
    let status = 500;
    let logPath = '-';
    try {
      // Parsed inside the try: a malformed address is a 400 for that caller, never a crash.
      let url: URL;
      try {
        url = new URL(nodeReq.url ?? '/', 'http://localhost');
      } catch {
        throw new HttpError(400, 'bad_path', 'The address is not valid');
      }
      logPath = url.pathname;
      if (serveDashboard(nodeReq, res, url.pathname, ctx.config.dashboardDir)) {
        status = res.statusCode;
        return;
      }
      const m = match(nodeReq.method ?? 'GET', url.pathname);
      if (!m) throw new HttpError(404, 'not_found', 'No such endpoint');
      const hasBody = nodeReq.method === 'POST' || nodeReq.method === 'PATCH' || nodeReq.method === 'PUT';
      const req: Req = {
        method: nodeReq.method ?? 'GET',
        path: url.pathname,
        query: url.searchParams,
        headers: nodeReq.headers,
        params: m.params,
        ip: clientIp(nodeReq, ctx.config.trustProxy),
        // Callers who are not signed in may only send small bodies.
        body: hasBody ? await readBody(nodeReq, m.route.auth === 'none' ? 16 * 1024 : ctx.config.maxBodyBytes) : undefined,
      };
      const who: { device?: licensing.DeviceAuth; vendor?: vendor.VendorUser; owner?: owners.OwnerUser } = {};
      if (m.route.auth === 'device') {
        who.device = licensing.authenticateDevice(ctx, v(req), req.headers['x-app-version'] as string | undefined);
      } else if (m.route.auth === 'vendor') {
        who.vendor = vendor.authenticateVendor(ctx, v(req));
      } else if (m.route.auth === 'owner') {
        who.owner = owners.authenticateOwner(ctx, v(req));
      }
      const reply = await m.route.handler(req, ctx, who);
      status = reply.status;
      send(nodeReq, res, reply);
    } catch (err) {
      let reply: Reply;
      if (err instanceof HttpError) {
        reply = { status: err.status, body: { error: { code: err.code, message: err.message, ...err.extra } } };
      } else {
        console.error('Unhandled error', err);
        reply = { status: 500, body: { error: { code: 'server_error', message: 'Something went wrong on the server' } } };
      }
      status = reply.status;
      send(nodeReq, res, reply);
    } finally {
      // Method, path and status only. Credentials and bodies are never logged.
      if (ctx.config.log) console.log(`${nodeReq.method} ${logPath} ${status} ${Date.now() - started}ms`);
    }
  };
}
