import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { openDb } from '../src/db.ts';
import { backupNow, listBackups } from '../src/backup.ts';

test('a backup is a complete, openable copy and old ones are removed', () => {
  const dir = mkdtempSync(join(tmpdir(), 'bk-'));
  const db = openDb(join(dir, 'live.db'));
  db.raw.exec('create table t (x text); insert into t values (\'hello\')');
  const base = Date.UTC(2026, 10, 1, 3, 0, 0);
  const out = join(dir, 'backups');
  for (let i = 0; i < 5; i++) backupNow(db, out, 3, base + i * 86_400_000);
  assert.equal(listBackups(out).length, 3);
  assert.equal(listBackups(out)[0]!.name, 'tim-pos-20261105-030000.db');
  const copy = new DatabaseSync(join(out, listBackups(out)[0]!.name));
  assert.equal((copy.prepare('select x from t').get() as { x: string }).x, 'hello');
  copy.close();
  // Same second twice does not fail or duplicate.
  backupNow(db, out, 3, base + 4 * 86_400_000);
  assert.equal(readdirSync(out).filter((n) => n.endsWith('.db')).length, 3);
  db.close();
});
