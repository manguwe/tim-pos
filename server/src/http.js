import { gunzipSync, gzipSync } from 'node:zlib';
export class HttpError extends Error {
    status;
    code;
    extra;
    constructor(status, code, message, extra = {}) {
        super(message);
        this.status = status;
        this.code = code;
        this.extra = extra;
    }
}
export const ok = (body, status = 200) => ({ status, body });
export async function readBody(req, maxBytes) {
    const chunks = [];
    let size = 0;
    for await (const chunk of req) {
        size += chunk.length;
        if (size > maxBytes)
            throw new HttpError(413, 'body_too_large', 'Request body is too large');
        chunks.push(chunk);
    }
    if (size === 0)
        return undefined;
    let raw = Buffer.concat(chunks);
    if (String(req.headers['content-encoding'] ?? '').toLowerCase() === 'gzip') {
        try {
            raw = gunzipSync(raw, { maxOutputLength: maxBytes });
        }
        catch {
            throw new HttpError(400, 'bad_encoding', 'Request body could not be decompressed');
        }
    }
    try {
        return JSON.parse(raw.toString('utf8'));
    }
    catch {
        throw new HttpError(400, 'bad_json', 'Request body is not valid JSON');
    }
}
export function send(req, res, reply) {
    let payload = Buffer.from(JSON.stringify(reply.body ?? {}));
    const headers = {
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
export function asObject(v, what = 'body') {
    if (typeof v !== 'object' || v === null || Array.isArray(v)) {
        throw new HttpError(400, 'invalid_request', `${what} must be a JSON object`);
    }
    return v;
}
export function str(o, key, opts = {}) {
    const v = o[key];
    if (v === undefined || v === null) {
        if (opts.optional)
            return '';
        throw new HttpError(400, 'invalid_request', `${key} is required`);
    }
    if (typeof v !== 'string')
        throw new HttpError(400, 'invalid_request', `${key} must be text`);
    const s = v.trim();
    if (s.length < (opts.min ?? (opts.optional ? 0 : 1)))
        throw new HttpError(400, 'invalid_request', `${key} is too short`);
    if (s.length > (opts.max ?? 200))
        throw new HttpError(400, 'invalid_request', `${key} is too long`);
    return s;
}
export function optStr(o, key, max = 500) {
    if (o[key] === undefined || o[key] === null)
        return undefined;
    return str(o, key, { max, optional: true });
}
export function int(o, key, opts = {}) {
    const v = o[key];
    if (typeof v !== 'number' || !Number.isSafeInteger(v))
        throw new HttpError(400, 'invalid_request', `${key} must be a whole number`);
    if (v < (opts.min ?? 0))
        throw new HttpError(400, 'invalid_request', `${key} must be at least ${opts.min ?? 0}`);
    if (v > (opts.max ?? Number.MAX_SAFE_INTEGER))
        throw new HttpError(400, 'invalid_request', `${key} is too large`);
    return v;
}
export function optInt(o, key, opts = {}) {
    return o[key] === undefined || o[key] === null ? undefined : int(o, key, opts);
}
export function strList(o, key) {
    const v = o[key];
    if (v === undefined || v === null)
        return undefined;
    if (!Array.isArray(v) || v.some((x) => typeof x !== 'string' || x.length > 64) || v.length > 100) {
        throw new HttpError(400, 'invalid_request', `${key} must be a list of short text values`);
    }
    return v;
}
