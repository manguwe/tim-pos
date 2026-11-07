/**
 * Writes the phone's database as SQL, one statement per block, separated by lines of "-- ##"
 * (the phone's SQLite driver runs one statement at a time, and triggers contain semicolons).
 *
 *   node tools/gen-local-schema.ts            writes app/assets/sql/local_schema.sql and schema_manifest.json
 */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { SCHEMA, LOCAL_SQL, STANDARD_APPEND, STANDARD_VERSIONED } from './schema.ts';
import { TABLES } from '../server/src/tables.ts';
export const DELIMITER = '-- ##';
const q = (s) => `"${s}"`;
const INT_NAME = /(_at|_minor|_milli|_micro|_bp|_mm|_from|_units|_seq|_attempts|_bytes|_no_int)$|^(is_|allow_|track_|requires_|opens_|restock|tax_registered|points$|sort_order$|attempts$|failed_attempts$|size_bytes$|minor_units$|last_no$)/;
function parseCol(token) {
    const m = /^([a-z_0-9]+)(!)?(?:>([a-z_]+))?(?:\{([^}]*)\})?(?::([is]))?$/.exec(token);
    if (!m)
        throw new Error(`bad column spec: ${token}`);
    const [, name, notNull, ref, enums, force] = m;
    const isInt = force ? force === 'i' : INT_NAME.test(name);
    const isBool = /^(is_|allow_|track_|requires_|opens_)/.test(name) || ['restock', 'tax_registered'].includes(name);
    let sql = `${q(name)} ${isInt ? 'integer' : 'text'}`;
    if (notNull)
        sql += ' not null';
    if (isBool)
        sql += ` check (${q(name)} is null or ${q(name)} in (0, 1))`;
    else if (isInt)
        sql += ` check (${q(name)} is null or typeof(${q(name)}) = 'integer')`;
    if (enums)
        sql += ` check (${q(name)} is null or ${q(name)} in (${enums.split('|').map((e) => `'${e}'`).join(', ')}))`;
    if (ref)
        sql += ` references ${q(ref)} (id) deferrable initially deferred`;
    return { name: name, sql, fk: ref };
}
export function generate() {
    const out = [];
    const manifest = {};
    // 1. every synced table must be defined, and nothing else
    const defined = Object.keys(SCHEMA).sort();
    const synced = Object.keys(TABLES).sort();
    if (JSON.stringify(defined) !== JSON.stringify(synced)) {
        const missing = synced.filter((t) => !SCHEMA[t]);
        const extra = defined.filter((t) => !TABLES[t]);
        throw new Error(`schema and server table list differ. missing: [${missing}] extra: [${extra}]`);
    }
    for (const [table, def] of Object.entries(SCHEMA)) {
        const kind = TABLES[table];
        const std = kind === 'append' ? STANDARD_APPEND : STANDARD_VERSIONED;
        const cols = def.cols.split(/\s+/).filter(Boolean).map(parseCol);
        const stdNames = std.map((s) => s.split(' ')[0]);
        for (const c of cols)
            if (stdNames.includes(c.name))
                throw new Error(`${table}.${c.name} repeats a standard column`);
        const lines = [...std.map((s) => {
                const [n, ...rest] = s.split(' ');
                return `${q(n)} ${rest.join(' ')}`;
            }), ...cols.map((c) => c.sql), ...(def.checks ?? [])];
        out.push(`create table ${q(table)} (\n  ${lines.join(',\n  ')}\n)`);
        manifest[table] = { kind, columns: [...stdNames, ...cols.map((c) => c.name)] };
        for (const [i, ix] of (def.indexes ?? []).entries()) {
            const unique = ix.startsWith('unique ');
            const body = ix.replace(/^unique /, '');
            const [colsPart, where] = body.split(/ where /);
            const colSql = colsPart.split(',').map((c) => c.trim()).map((c) => (/^[a-z_]+$/.test(c) ? q(c) : c)).join(', ');
            out.push(`create ${unique ? 'unique ' : ''}index ${q(`${table}_ix${i + 1}`)} on ${q(table)} (${colSql})${where ? ` where ${where}` : ''}`);
        }
        // sync lookups: nothing extra needed, id is the primary key.
        const notApplying = `(select applying from sync_state where id = 1) = 0`;
        if (kind === 'append') {
            out.push(`create trigger ${q(`${table}_no_update`)} before update on ${q(table)} begin select raise(abort, 'append-only table'); end`);
            out.push(`create trigger ${q(`${table}_no_delete`)} before delete on ${q(table)} begin select raise(abort, 'append-only table'); end`);
            out.push(`create trigger ${q(`${table}_log_ins`)} after insert on ${q(table)} when ${notApplying}
begin insert into change_log (table_name, row_id, op, version, updated_at, created_at) values ('${table}', new.id, 'insert', 1, new.created_at, new.created_at); end`);
        }
        else {
            out.push(`create trigger ${q(`${table}_no_hard_delete`)} before delete on ${q(table)} when ${notApplying} begin select raise(abort, 'soft delete only: set deleted_at'); end`);
            out.push(`create trigger ${q(`${table}_version_guard`)} before update on ${q(table)} when ${notApplying} and new.version <= old.version begin select raise(abort, 'version must increase on every edit'); end`);
            out.push(`create trigger ${q(`${table}_log_ins`)} after insert on ${q(table)} when ${notApplying}
begin insert into change_log (table_name, row_id, op, version, updated_at, created_at) values ('${table}', new.id, 'insert', new.version, new.updated_at, new.created_at); end`);
            out.push(`create trigger ${q(`${table}_log_upd`)} after update on ${q(table)} when ${notApplying}
begin insert into change_log (table_name, row_id, op, version, updated_at, created_at) values ('${table}', new.id,
  case when new.deleted_at is not null and old.deleted_at is null then 'delete' else 'update' end, new.version, new.updated_at, new.updated_at); end`);
        }
    }
    // 2. local-only tables
    out.push(...LOCAL_SQL);
    // 3. the stock cache follows every movement, including ones that arrive from other phones
    out.push(`create trigger "stock_movements_level" after insert on "stock_movements"
begin
  insert into stock_levels (branch_id, product_id, batch_key, qty_milli) values (new.branch_id, new.product_id, coalesce(new.batch_id, ''), new.qty_milli)
  on conflict (branch_id, product_id, batch_key) do update set qty_milli = qty_milli + new.qty_milli;
end`);
    const sql = `-- TIM-POS phone database. Generated by tools/gen-local-schema.ts from tools/schema.ts. Do not edit by hand.\n-- One statement per block; a block starts at a line that holds only the delimiter.\n${out.map((s) => `${DELIMITER}\n${s};`).join('\n')}\n`;
    return { sql, manifest };
}
if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
    const { sql, manifest } = generate();
    const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'assets', 'sql');
    mkdirSync(dir, { recursive: true });
    writeFileSync(join(dir, 'local_schema.sql'), sql);
    writeFileSync(join(dir, 'schema_manifest.json'), JSON.stringify(manifest, null, 1) + '\n');
    console.log(`wrote ${Object.keys(manifest).length} synced tables to ${dir}`);
}
