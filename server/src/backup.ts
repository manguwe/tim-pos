import { existsSync, mkdirSync, readdirSync, statSync, unlinkSync, copyFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import type { Db } from './db.ts';

const NAME = /^tim-pos-\d{8}-\d{6}\.db$/;

function stamp(ms: number): string {
  const d = new Date(ms);
  const p = (n: number, w = 2) => String(n).padStart(w, '0');
  return `${d.getUTCFullYear()}${p(d.getUTCMonth() + 1)}${p(d.getUTCDate())}-${p(d.getUTCHours())}${p(d.getUTCMinutes())}${p(d.getUTCSeconds())}`;
}

export function listBackups(dir: string): { name: string; bytes: number; at: number }[] {
  if (!existsSync(dir)) return [];
  return readdirSync(dir)
    .filter((n) => NAME.test(n))
    .map((name) => {
      const st = statSync(join(dir, name));
      return { name, bytes: st.size, at: st.mtimeMs };
    })
    .sort((a, b) => b.name.localeCompare(a.name));
}

/**
 * Writes a consistent copy of the whole database (safe while the server is running) and removes the
 * oldest copies beyond `keep`. Returns the path written.
 */
export function backupNow(db: Db, dir: string, keep: number, now: number): string {
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = join(dir, `tim-pos-${stamp(now)}.db`);
  if (existsSync(file)) return file;
  db.raw.exec(`VACUUM INTO '${file.replace(/'/g, "''")}'`);
  // The development secrets file holds the licence signing key; keep a copy beside the data.
  const secrets = join(dirname(dir), 'dev-secrets.json');
  if (existsSync(secrets)) copyFileSync(secrets, join(dir, 'dev-secrets.json'));
  for (const old of listBackups(dir).slice(Math.max(1, keep))) unlinkSync(join(dir, old.name));
  return file;
}

/**
 * Makes a backup when the newest one is more than 20 hours old, checks again every hour, and takes one
 * at start-up if due. A failure is logged and tried again next hour; it never stops the server.
 */
export function startBackups(db: Db, dir: string | null | undefined, keep: number, log: (m: string) => void): () => void {
  if (!dir) return () => {};
  const tick = () => {
    try {
      const newest = listBackups(dir)[0];
      if (!newest || Date.now() - newest.at > 20 * 3_600_000) {
        const f = backupNow(db, dir, keep, Date.now());
        log(`Backup written: ${f}`);
      }
    } catch (e) {
      log(`Backup failed: ${(e as Error).message}`);
    }
  };
  tick();
  const t = setInterval(tick, 3_600_000);
  t.unref();
  return () => clearInterval(t);
}
