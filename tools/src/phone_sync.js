import { randomUUID } from 'node:crypto';
const BATCH_ROWS = 200;
const PAGE = 500;
const q = (s) => `"${s}"`;
const code = (j) => j?.error?.code ?? '';
export class PhoneSync {
    db;
    http;
    /** from app/assets/sql/schema_manifest.json */
    manifest;
    now;
    constructor(db, http, manifest, now = Date.now) {
        this.db = db;
        this.http = http;
        this.manifest = manifest;
        this.now = now;
    }
    all(sql, ...a) { return this.db.prepare(sql).all(...a).map((r) => ({ ...r })); }
    get(sql, ...a) { const r = this.db.prepare(sql).get(...a); return r ? { ...r } : undefined; }
    run(sql, ...a) { this.db.prepare(sql).run(...a); }
    tx(fn) {
        this.db.exec('begin');
        try {
            const r = fn();
            this.db.exec('commit');
            return r;
        }
        catch (e) {
            this.db.exec('rollback');
            throw e;
        }
    }
    /** Sends everything that is waiting. Safe to call again after any failure. */
    async push() {
        let pushed = 0;
        const rejected = [];
        for (;;) {
            let batch = this.get(`select * from sync_batches where status = 'pending' order by created_at limit 1`);
            if (!batch) {
                batch = this.tx(() => this.makeBatch());
                if (!batch)
                    break;
            }
            this.run('update sync_batches set attempts = attempts + 1 where id = ?', batch.id);
            const res = await this.http('POST', '/v1/sync/push', { batch_id: batch.id, changes: JSON.parse(batch.payload) });
            if (res.status !== 200) {
                this.run('update sync_state set last_error = ? where id = 1', `push ${res.status} ${code(res.json)}`);
                throw new SyncError(res.status, res.json);
            }
            rejected.push(...res.json.rejected);
            pushed += res.json.accepted + res.json.skipped;
            this.tx(() => {
                this.run('update change_log set sent_at = ? where batch_id = ?', this.now(), batch.id);
                this.run(`update sync_batches set status = 'sent', payload = null where id = ?`, batch.id);
                this.run('update sync_state set last_push_at = ?, last_success_at = ?, last_error = null where id = 1', this.now(), this.now());
            });
        }
        return { pushed, rejected };
    }
    /** Freezes the next set of waiting changes into a batch with its own ID. The payload is kept so a resend is identical. */
    makeBatch() {
        const waiting = this.all('select * from change_log where sent_at is null and batch_id is null order by seq limit ?', BATCH_ROWS);
        if (waiting.length === 0)
            return undefined;
        const id = randomUUID();
        // Several edits to one row in the same batch collapse to the latest, which carries the row as it is now.
        const latest = new Map();
        for (const w of waiting)
            latest.set(`${w.table_name}|${w.row_id}`, w);
        const changes = [...latest.values()].map((w) => {
            const row = this.get(`select * from ${q(w.table_name)} where id = ?`, w.row_id);
            return { table: w.table_name, row_id: w.row_id, op: w.op, version: w.version, updated_at: w.updated_at, data: row ?? {} };
        });
        const payload = JSON.stringify(changes);
        this.run('update change_log set batch_id = ? where seq in (' + waiting.map(() => '?').join(',') + ')', id, ...waiting.map((w) => w.seq));
        this.run(`insert into sync_batches (id, from_seq, to_seq, status, bytes, payload, created_at) values (?, ?, ?, 'pending', ?, ?, ?)`, id, waiting[0].seq, waiting[waiting.length - 1].seq, payload.length, payload, this.now());
        return this.get('select * from sync_batches where id = ?', id);
    }
    /** Fetches other phones' changes and applies them. A restore asks for its own changes too (includeOwn). */
    async pull(includeOwn = false) {
        let pulled = 0;
        let resetPull = false;
        let own = includeOwn;
        for (;;) {
            const st = this.get('select last_pull_seq, epoch from sync_state where id = 1');
            const qs = new URLSearchParams({ since: String(st.last_pull_seq), limit: String(PAGE) });
            if (st.epoch)
                qs.set('epoch', st.epoch);
            if (own)
                qs.set('include_own', '1');
            const res = await this.http('GET', `/v1/sync/pull?${qs}`);
            if (res.status === 409 && (code(res.json) === 'epoch_changed' || code(res.json) === 'cursor_ahead')) {
                // The server was restored: start again from the beginning and take our own rows back too (existing ones are skipped).
                this.run('update sync_state set last_pull_seq = 0, epoch = ? where id = 1', res.json.error.epoch ?? null);
                resetPull = true;
                own = true;
                continue;
            }
            if (res.status !== 200) {
                this.run('update sync_state set last_error = ? where id = 1', `pull ${res.status} ${code(res.json)}`);
                throw new SyncError(res.status, res.json);
            }
            this.applyPage(res.json);
            pulled += res.json.changes.length;
            this.run('update sync_state set last_success_at = ?, last_error = null where id = 1', this.now());
            if (!res.json.has_more)
                break;
        }
        return { pulled, resetPull };
    }
    async sync() {
        const p = await this.push();
        const l = await this.pull();
        return { pushed: p.pushed, rejected: p.rejected, pulled: l.pulled, resetPull: l.resetPull };
    }
    columnsOf = new Map();
    cols(table) {
        let c = this.columnsOf.get(table);
        if (!c) {
            c = new Set(this.all(`pragma table_info(${q(table)})`).map((r) => r.name));
            this.columnsOf.set(table, c);
        }
        return c;
    }
    /** Applies one page in one transaction. Foreign keys are checked at commit, so order inside the page does not matter. */
    applyPage(page) {
        // foreign_keys cannot change inside a transaction; deferred constraints stay on, so a broken page rolls back as a whole.
        this.db.exec('begin');
        try {
            this.run('update sync_state set applying = 1 where id = 1');
            for (const c of page.changes)
                this.applyOne(c);
            this.run('update sync_state set applying = 0, last_pull_seq = ?, epoch = ? where id = 1', page.next_seq, page.epoch);
            this.db.exec('commit');
        }
        catch (e) {
            this.db.exec('rollback');
            throw e;
        }
    }
    applyOne(c) {
        const have = this.cols(c.table);
        if (have.size === 0)
            return; // a table this app version does not know yet: skip, never crash
        const kind = this.manifest[c.table]?.kind ?? 'versioned';
        const names = Object.keys(c.data).filter((k) => have.has(k) && k !== 'id');
        const row = { ...Object.fromEntries(names.map((k) => [k, c.data[k]])), id: c.row_id };
        const colList = Object.keys(row).map(q).join(', ');
        const marks = Object.keys(row).map(() => '?').join(', ');
        if (kind === 'append') {
            this.run(`insert or ignore into ${q(c.table)} (${colList}) values (${marks})`, ...Object.values(row));
            return;
        }
        const local = this.get(`select version, updated_at from ${q(c.table)} where id = ?`, c.row_id);
        if (local) {
            const remoteWins = c.version > local.version || (c.version === local.version && (c.data.updated_at ?? 0) > local.updated_at);
            if (!remoteWins)
                return;
            const sets = Object.keys(row).filter((k) => k !== 'id').map((k) => `${q(k)} = ?`).join(', ');
            this.run(`update ${q(c.table)} set ${sets} where id = ?`, ...Object.entries(row).filter(([k]) => k !== 'id').map(([, v]) => v), c.row_id);
        }
        else {
            this.run(`insert into ${q(c.table)} (${colList}) values (${marks})`, ...Object.values(row));
        }
    }
}
export class SyncError extends Error {
    status;
    body;
    constructor(status, body) { super(`sync failed: ${status} ${JSON.stringify(body)}`); this.status = status; this.body = body; }
}
