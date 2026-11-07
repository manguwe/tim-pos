import type { IncomingMessage, ServerResponse } from 'node:http';
import { gunzipSync, gzipSync } from 'node:zlib';

export class HttpError extends Error {
  readonly status: number;
  readonly code: string;
  readonly extra: Record<string, unknown>;
  constructor(status: number, code: string, message: string, extra: Record<string, unknown> = {}) {
    super(message);
    this.status = status;
    this.code = code;
    this.extra = extra;
  }
}

export interface Req {
  method: string;
  path: string;
  query: URLSearchParams;
  headers: IncomingMessage['headers'];
  params: Record<string, string>;
  ip: string;
  body: unknown;
}

export interface Reply {
  status: number;
  body: unknown;
}

export const ok = (body: unknown, status = 200): Reply => ({ status, body });

export async function readBody(req: IncomingMessage, maxBytes: number): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > maxBytes) throw new HttpError(413, 'body_too_large', 'Request body is too large');
    chunks.push(chunk as Buffer);
  }
  if (size === 0) return undefined;
  let raw = Buffer.concat(chunks);
  if (String(req.headers['content-encoding'] ?? '').toLowerCase() === 'gzip') {
    try {
      raw = gunzipSync(raw, { maxOutputLength: maxBytes });
    } catch {
      throw new HttpError(400, 'bad_encoding', 'Request body could not be decompressed');
    }
  }
  try {
    return JSON.parse(raw.toString('utf8'));
  } catch {
    throw new HttpError(400, 'bad_json', 'Request body is not valid JSON');
  }
}

export function send(req: IncomingMessage, res: ServerResponse, reply: Reply): void {
  let payload = Buffer.from(JSON.stringify(reply.body ?? {}));
  const headers: Record<string, string | number> = {
    'content-type': 'application/json; charset=utf-8',
    'cache-control': 'no-store',
    'x-content-type-options': 'nosniff',
  };
  if (payload.length > 1024 && /\bgzip\b/.test(String(req.headers['accept-encoding'] ?? ''))) {
    payload = gzipSync(payload);
    headers['content-encoding'] = 'gzip';
    headers.vary = 'accept-encoding';
  }
  headers['content-length'] = payload.length;
  res.writeHead(reply.status, headers);
  res.end(payload);
}

// ---- Field validation ----

type Obj = Record<string, unknown>;

export function asObject(v: unknown, what = 'body'): Obj {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) {
    throw new HttpError(400, 'invalid_request', `${what} must be a JSON object`);
  }
  return v as Obj;
}

export function str(o: Obj, key: string, opts: { max?: number; min?: number; optional?: boolean } = {}): string {
  const v = o[key];
  if (v === undefined || v === null) {
    if (opts.optional) return '';
    throw new HttpError(400, 'invalid_request', `${key} is required`);
  }
  if (typeof v !== 'string') throw new HttpError(400, 'invalid_request', `${key} must be text`);
  const s = v.trim();
  if (s.length < (opts.min ?? (opts.optional ? 0 : 1))) throw new HttpError(400, 'invalid_request', `${key} is too short`);
  if (s.length > (opts.max ?? 200)) throw new HttpError(400, 'invalid_request', `${key} is too long`);
  return s;
}

export function optStr(o: Obj, key: string, max = 500): string | undefined {
  if (o[key] === undefined || o[key] === null) return undefined;
  return str(o, key, { max, optional: true });
}

export function int(o: Obj, key: string, opts: { min?: number; max?: number } = {}): number {
  const v = o[key];
  if (typeof v !== 'number' || !Number.isSafeInteger(v)) throw new HttpError(400, 'invalid_request', `${key} must be a whole number`);
  if (v < (opts.min ?? 0)) throw new HttpError(400, 'invalid_request', `${key} must be at least ${opts.min ?? 0}`);
  if (v > (opts.max ?? Number.MAX_SAFE_INTEGER)) throw new HttpError(400, 'invalid_request', `${key} is too large`);
  return v;
}

export function optInt(o: Obj, key: string, opts: { min?: number; max?: number } = {}): number | undefined {
  return o[key] === undefined || o[key] === null ? undefined : int(o, key, opts);
}

export function strList(o: Obj, key: string): string[] | undefined {
  const v = o[key];
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || x.length > 64) || v.length > 100) {
    throw new HttpError(400, 'invalid_request', `${key} must be a list of short text values`);
  }
  return v as string[];
}
