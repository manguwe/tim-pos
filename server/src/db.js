import { DatabaseSync } from 'node:sqlite';
import { chmodSync, mkdirSync, readdirSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';
/**
 * Thin wrapper over node:sqlite. All calls are synchronous, so a handler that does its database
 * work inside tx() can never be interleaved with another request.
 */
export class Db {
    raw;
    cache = new Map();
    inTx = false;
    constructor(path) {
        if (path !== ':memory:')
            mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
        this.raw = new DatabaseSync(path);
        // The file holds licence hashes, vendor logins and every shop's data: only the server's own user may read it.
        // SQLite gives its -wal and -shm files the same permissions as the main file.
        if (path !== ':memory:')
            chmodSync(path, 0o600);
        this.raw.exec('PRAGMA journal_mode = WAL; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 5000;');
    }
    stmt(sql) {
        let s = this.cache.get(sql);
        if (!s) {
            s = this.raw.prepare(sql);
            this.cache.set(sql, s);
        }
        return s;
    }
    get(sql, ...params) {
        return this.stmt(sql).get(...params);
    }
    all(sql, ...params) {
        return this.stmt(sql).all(...params);
    }
    /** Returns the number of rows changed. */
    run(sql, ...params) {
        return Number(this.stmt(sql).run(...params).changes);
    }
    /** Runs fn in one transaction. It saves completely or not at all. */
    tx(fn) {
        if (this.inTx)
            return fn();
        this.raw.exec('BEGIN IMMEDIATE');
        this.inTx = true;
        try {
            const result = fn();
            this.raw.exec('COMMIT');
            return result;
        }
        catch (err) {
            this.raw.exec('ROLLBACK');
            throw err;
        }
        finally {
            this.inTx = false;
        }
    }
    migrate(dir) {
        this.raw.exec('create table if not exists schema_migrations (name text primary key, applied_at integer not null)');
        const files = readdirSync(dir).filter((f) => f.endsWith('.sql')).sort();
        for (const file of files) {
            if (this.get('select 1 as x from schema_migrations where name = ?', file))
                continue;
            const sql = readFileSync(new URL(file, dir), 'utf8');
            this.tx(() => {
                this.raw.exec(sql);
                this.run('insert into schema_migrations (name, applied_at) values (?, ?)', file, Date.now());
            });
        }
    }
    close() {
        this.raw.close();
    }
}
export function openDb(path) {
    const db = new Db(path);
    db.migrate(new URL('../migrations/', import.meta.url));
    return db;
}
