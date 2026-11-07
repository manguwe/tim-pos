/**
 * Builds a shop's reports from what its phones have synced.
 *
 * The server keeps every synced row as JSON in `records`. To report on it, this loads that shop's rows into a temporary
 * in-memory copy of the phone's own tables and runs the very same report code the phone runs (reports.ts, copied from
 * tools/). So the figures on the owner's page always agree with the figures at the till.
 *
 * The copy is rebuilt only when the shop has new changes, and at most a few shops are kept at once.
 * A shop with years of heavy trading will want typed report tables in PostgreSQL instead; this is the simple, correct first version.
 */
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import type { Db } from '../db.ts';
import { TABLES } from '../tables.ts';

const SCHEMA = readFileSync(new URL('./shop_schema.sql', import.meta.url), 'utf8')
  .split(/^-- ##\s*$/m).map((b) => b.split('\n').filter((l) => !l.startsWith('-- ')).join('\n').trim()).filter(Boolean);

export interface ShopView { db: DatabaseSync; seq: number; loaded: number; skipped: number; built_at: number }

const MAX_CACHED = 6;
const cache = new Map<string, ShopView>(); // insertion order = least recently used first

function build(server: Db, shopId: string, seq: number, now: number): ShopView {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = off');
  for (const stmt of SCHEMA) db.exec(stmt);
  const columns = new Map<string, Set<string>>();
  const insert = new Map<string, ReturnType<DatabaseSync['prepare']>>();
  let loaded = 0, skipped = 0;
  db.exec('begin');
  const rows = server.all<{ table_name: string; data: string; deleted_at: number | null }>(
    'select table_name, data, deleted_at from records where shop_id = ?', shopId,
  );
  // Tables first, in the order the phone's schema creates them does not matter: foreign keys are off.
  for (const r of rows) {
    if (!Object.hasOwn(TABLES, r.table_name)) continue;
    let cols = columns.get(r.table_name);
    if (!cols) {
      cols = new Set((db.prepare(`pragma table_info("${r.table_name}")`).all() as { name: string }[]).map((c) => c.name));
      columns.set(r.table_name, cols);
    }
    if (cols.size === 0) { skipped++; continue; }
    let obj: Record<string, unknown>;
    try { obj = JSON.parse(r.data) as Record<string, unknown>; } catch { skipped++; continue; }
    if (r.deleted_at !== null && obj.deleted_at == null) obj.deleted_at = r.deleted_at;
    const keys = Object.keys(obj).filter((k) => cols.has(k));
    const sig = `${r.table_name}|${keys.join(',')}`;
    let st = insert.get(sig);
    if (!st) {
      st = db.prepare(`insert or replace into "${r.table_name}" (${keys.map((k) => `"${k}"`).join(',')}) values (${keys.map(() => '?').join(',')})`);
      insert.set(sig, st);
    }
    try {
      st.run(...keys.map((k) => {
        const v = obj[k];
        if (v === undefined) return null;
        if (typeof v === 'boolean') return v ? 1 : 0;
        if (v !== null && typeof v === 'object') return JSON.stringify(v);
        return v as string | number | null;
      }));
      loaded++;
    } catch { skipped++; } // a row the phone's own rules would refuse is left out rather than breaking every report
  }
  db.exec('commit');
  return { db, seq, loaded, skipped, built_at: now };
}

/** The shop's data as of its latest change. Do not close or write to the returned database. */
export function shopView(server: Db, shopId: string, now: number): ShopView {
  const seq = server.get<{ s: number }>('select coalesce(max(seq), 0) as s from change_feed where shop_id = ?', shopId)?.s ?? 0;
  const hit = cache.get(shopId);
  if (hit && hit.seq === seq) { cache.delete(shopId); cache.set(shopId, hit); return hit; }
  if (hit) { hit.db.close(); cache.delete(shopId); }
  const view = build(server, shopId, seq, now);
  cache.set(shopId, view);
  while (cache.size > MAX_CACHED) {
    const [oldest] = cache.keys();
    cache.get(oldest as string)?.db.close();
    cache.delete(oldest as string);
  }
  return view;
}

export function forgetShop(shopId: string): void {
  cache.get(shopId)?.db.close();
  cache.delete(shopId);
}
