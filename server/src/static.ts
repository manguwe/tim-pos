/**
 * Serves the built web dashboard (plain files) from the same address as the API, so no cross-site access is needed.
 * Only GET and HEAD. A path can never leave the dashboard folder. Pages get a strict content-security policy.
 */
import { createReadStream, statSync } from 'node:fs';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { extname, resolve, sep } from 'node:path';
import { HttpError } from './http.ts';

export const DASHBOARD_PREFIX = '/dashboard';

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.json': 'application/json; charset=utf-8',
  '.txt': 'text/plain; charset=utf-8',
};

const CSP = [
  "default-src 'none'", "script-src 'self'", "style-src 'self'", "img-src 'self' data:", "connect-src 'self'",
  "font-src 'self'", "base-uri 'none'", "form-action 'self'", "frame-ancestors 'none'",
].join('; ');

/** True when the request is for the dashboard and was answered here. */
export function serveDashboard(req: IncomingMessage, res: ServerResponse, pathname: string, dir: string | null | undefined): boolean {
  if (pathname !== DASHBOARD_PREFIX && !pathname.startsWith(`${DASHBOARD_PREFIX}/`)) return false;
  if (!dir) throw new HttpError(404, 'not_found', 'The dashboard is not installed on this server');
  if (req.method !== 'GET' && req.method !== 'HEAD') throw new HttpError(405, 'method_not_allowed', 'Use GET');
  if (pathname === DASHBOARD_PREFIX) {
    res.writeHead(301, { location: `${DASHBOARD_PREFIX}/`, 'cache-control': 'no-store' });
    res.end();
    return true;
  }
  let rel: string;
  try {
    rel = decodeURIComponent(pathname.slice(DASHBOARD_PREFIX.length));
  } catch {
    throw new HttpError(400, 'bad_path', 'The address contains an invalid character');
  }
  if (rel.includes('\0') || rel.includes('\\')) throw new HttpError(400, 'bad_path', 'The address is not valid');
  if (rel === '/' || rel === '') rel = '/index.html';
  const root = resolve(dir);
  const file = resolve(root, `.${rel}`);
  if (file !== root && !file.startsWith(root + sep)) throw new HttpError(404, 'not_found', 'Not found');
  const type = TYPES[extname(file).toLowerCase()];
  let size: number;
  try {
    const st = statSync(file);
    if (!st.isFile() || !type) throw new Error('not a file');
    size = st.size;
  } catch {
    throw new HttpError(404, 'not_found', 'Not found');
  }
  const isPage = type.startsWith('text/html');
  const hashed = /-[A-Z0-9]{8}\.[a-z]+$/.test(file); // esbuild names files like app-4F3KQ2XA.js
  res.writeHead(200, {
    'content-type': type,
    'content-length': size,
    'cache-control': hashed ? 'public, max-age=31536000, immutable' : 'no-cache',
    'x-content-type-options': 'nosniff',
    'referrer-policy': 'no-referrer',
    ...(isPage ? { 'content-security-policy': CSP, 'x-frame-options': 'DENY' } : {}),
  });
  if (req.method === 'HEAD') {
    res.end();
    return true;
  }
  createReadStream(file).on('error', () => res.destroy()).pipe(res);
  return true;
}
