import { HttpError, asObject, int, str } from '../http.ts';
import { LOCAL_ONLY, TABLES } from '../tables.ts';
import { sha256hex } from '../crypto.ts';
import { DAY_MS } from '../licence.ts';
const ID_RE = /^[0-9A-Za-z_-]{8,64}$/;
const MAX_ROW_BYTES = 64 * 1024;
const MAX_VERSION = 2147483647;
const MAX_DEPTH = 32;
/** Checked without recursion, so a hostile row cannot overflow the stack. Real rows are a few levels deep. */
function tooDeep(value) {
    const stack = [[value, 1]];
    while (stack.length > 0) {
        const [v, depth] = stack.pop();
        if (v === null || typeof v !== 'object')
            continue;
        if (depth > MAX_DEPTH)
            return true;
        for (const child of Array.isArray(v) ? v : Object.values(v))
            stack.push([child, depth + 1]);
    }
    return false;
}
function parseChange(raw) {
    const o = raw && typeof raw === 'object' && !Array.isArray(raw) ? raw : {};
    const table = typeof o.table === 'string' ? o.table : '';
    const rowId = typeof o.row_id === 'string' ? o.row_id : '';
    const bad = (error) => ({ error, table, row_id: rowId });
    if (LOCAL_ONLY.has(table))
        return bad('local_only_table');
    if (!Object.hasOwn(TABLES, table))
        return bad('unknown_table');
    if (!ID_RE.test(rowId))
        return bad('bad_row_id');
    if (o.op !== 'insert' && o.op !== 'update' && o.op !== 'delete')
        return bad('bad_op');
    if (typeof o.version !== 'number' || !Number.isSafeInteger(o.version) || o.version < 1 || o.version > MAX_VERSION)
        return bad('bad_version');
    if (typeof o.updated_at !== 'number' || !Number.isSafeInteger(o.updated_at) || o.updated_at < 0)
        return bad('bad_updated_at');
    if (typeof o.data !== 'object' || o.data === null || Array.isArray(o.data))
        return bad('bad_data');
    if (tooDeep(o.data))
        return bad('data_too_deep');
    return {
        table, row_id: rowId, op: o.op, version: o.version, updated_at: o.updated_at,
        data: o.data,
    };
}
/**
 * Applies one batch from a phone. The whole batch runs in one transaction, and a batch ID that was
 * already processed is acknowledged without being applied again, so a resend after a dropped
 * connection is always safe.
 */
export function push(ctx, auth, body) {
    const o = asObject(body);
    const batchId = str(o, 'batch_id', { max: 64, min: 8 });
    if (!ID_RE.test(batchId))
        throw new HttpError(400, 'invalid_request', 'batch_id has an invalid format');
    if (!Array.isArray(o.changes))
        throw new HttpError(400, 'invalid_request', 'changes must be a list');
    if (o.changes.length > ctx.config.maxBatchChanges) {
        throw new HttpError(413, 'batch_too_large', `A batch may hold at most ${ctx.config.maxBatchChanges} changes`);
    }
    const shopId = auth.tenant.id;
    const deviceId = auth.activation.id;
    const changes = o.changes;
    // A fingerprint of which rows the batch holds. It is cheap, and it lets a reused batch ID with other content be caught.
    const contentHash = sha256hex(changes
        .map((c) => {
        const r = c && typeof c === 'object' ? c : {};
        return `${String(r.table)}|${String(r.row_id)}|${String(r.op)}|${String(r.version)}`;
    })
        .join('\n'));
    return ctx.db.tx(() => {
        const prior = ctx.db.get('select accepted, content_hash from processed_batches where shop_id = ? and device_id = ? and batch_id = ?', shopId, deviceId, batchId);
        const now = ctx.now();
        if (prior) {
            if (prior.content_hash !== contentHash) {
                throw new HttpError(409, 'batch_id_reused', 'This batch ID was already used for different changes. Use a new ID for new changes.');
            }
            return { batch_id: batchId, duplicate: true, accepted: prior.accepted, skipped: 0, rejected: [], server_time: now };
        }
        let accepted = 0;
        let skipped = 0;
        const rejected = [];
        changes.forEach((raw, index) => {
            const c = parseChange(raw);
            if ('error' in c) {
                rejected.push({ index, table: c.table, row_id: c.row_id, reason: c.error });
                return;
            }
            if (c.data.shop_id !== undefined && c.data.shop_id !== shopId) {
                rejected.push({ index, table: c.table, row_id: c.row_id, reason: 'wrong_shop' });
                return;
            }
            const data = JSON.stringify({ ...c.data, shop_id: shopId });
            // A phone's clock can be wrong. For tie-breaking, a time more than a day ahead counts as one day ahead.
            const at = Math.min(c.updated_at, now + DAY_MS);
            if (data.length > MAX_ROW_BYTES) {
                rejected.push({ index, table: c.table, row_id: c.row_id, reason: 'row_too_large' });
                return;
            }
            const kind = TABLES[c.table];
            const existing = ctx.db.get('select version, updated_at, deleted_at from records where shop_id = ? and table_name = ? and row_id = ?', shopId, c.table, c.row_id);
            if (kind === 'append') {
                if (c.op !== 'insert') {
                    rejected.push({ index, table: c.table, row_id: c.row_id, reason: 'append_only' });
                    return;
                }
                if (existing) {
                    skipped += 1;
                    return;
                }
                ctx.db.run('insert into records (shop_id, table_name, row_id, version, data, deleted_at, updated_at) values (?, ?, ?, 1, ?, null, ?)', shopId, c.table, c.row_id, data, at);
                feed(ctx, shopId, c, 1, data, deviceId, now);
                accepted += 1;
                return;
            }
            // versioned reference data: the higher version wins, a tie goes to the later updated_at
            const deletedAt = c.op === 'delete' ? at : null;
            if (!existing) {
                ctx.db.run('insert into records (shop_id, table_name, row_id, version, data, deleted_at, updated_at) values (?, ?, ?, ?, ?, ?, ?)', shopId, c.table, c.row_id, c.version, data, deletedAt, at);
                feed(ctx, shopId, c, c.version, data, deviceId, now);
                accepted += 1;
                return;
            }
            const wins = c.version > existing.version || (c.version === existing.version && at > existing.updated_at);
            if (!wins) {
                ctx.db.run(`insert into sync_conflicts (shop_id, table_name, row_id, device_id, incoming_version, incoming_data, kept_version, received_at)
           values (?, ?, ?, ?, ?, ?, ?, ?)`, shopId, c.table, c.row_id, deviceId, c.version, data, existing.version, now);
                skipped += 1;
                return;
            }
            ctx.db.run('update records set version = ?, data = ?, deleted_at = ?, updated_at = ? where shop_id = ? and table_name = ? and row_id = ?', c.version, data, deletedAt, at, shopId, c.table, c.row_id);
            feed(ctx, shopId, c, c.version, data, deviceId, now);
            accepted += 1;
        });
        ctx.db.run('insert into processed_batches (shop_id, device_id, batch_id, content_hash, processed_at, accepted) values (?, ?, ?, ?, ?, ?)', shopId, deviceId, batchId, contentHash, now, accepted);
        return { batch_id: batchId, duplicate: false, accepted, skipped, rejected, server_time: now };
    });
}
function feed(ctx, shopId, c, version, data, deviceId, now) {
    ctx.db.run('insert into change_feed (shop_id, table_name, row_id, op, version, data, device_id, received_at) values (?, ?, ?, ?, ?, ?, ?, ?)', shopId, c.table, c.row_id, c.op, version, data, deviceId, now);
}
/**
 * Returns changes after `since`, in the order they reached the server. A phone normally does not get
 * its own changes back; a phone restoring itself asks for them with include_own.
 */
export function pull(ctx, auth, query) {
    const since = int({ since: Number(query.get('since') ?? 0) }, 'since');
    const includeOwn = query.get('include_own') === '1';
    let limit = ctx.config.syncPageSize;
    if (query.get('limit') !== null) {
        const n = Number(query.get('limit'));
        if (!Number.isSafeInteger(n) || n < 1)
            throw new HttpError(400, 'invalid_request', 'limit must be a whole number of at least 1');
        limit = Math.min(limit, n);
    }
    const shopId = auth.tenant.id;
    // After a server restore the phones must start again, or they would miss changes made since the backup.
    const epoch = ctx.db.get("select value from meta where key = 'sync_epoch'").value;
    const claimed = query.get('epoch');
    if (claimed !== null && claimed !== epoch) {
        throw new HttpError(409, 'epoch_changed', 'The server was restored. Pull again from the start.', { epoch });
    }
    const head = ctx.db.get('select max(seq) as seq from change_feed where shop_id = ?', shopId)?.seq ?? 0;
    if (since > head) {
        throw new HttpError(409, 'cursor_ahead', 'This phone is ahead of the server. Pull again from the start.', { head_seq: head, epoch });
    }
    const rows = ctx.db.all('select seq, table_name, row_id, op, version, data, device_id from change_feed where shop_id = ? and seq > ? order by seq limit ?', shopId, since, limit);
    const mine = auth.activation.id;
    const visible = rows.filter((r) => includeOwn || r.device_id !== mine);
    const next = rows.length > 0 ? rows[rows.length - 1].seq : since;
    // `since` is what the phone says it has already applied, which is what the vendor sees as "behind".
    ctx.db.run('update activations set last_pull_seq = max(last_pull_seq, ?) where id = ?', since, mine);
    return {
        changes: visible.map((r) => ({
            seq: r.seq, table: r.table_name, row_id: r.row_id, op: r.op, version: r.version, data: JSON.parse(r.data),
        })),
        next_seq: next,
        has_more: rows.length === limit,
        epoch,
        server_time: ctx.now(),
    };
}
