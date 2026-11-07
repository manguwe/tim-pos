import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readFileSync } from 'node:fs';
import { Db, openDb } from '../src/db.ts';

test('the database file is readable only by the server user', { skip: process.platform === 'win32' && 'Windows has no Unix file modes' }, () => {
  const dir = mkdtempSync(join(tmpdir(), 'timpos-'));
  try {
    const db = openDb(join(dir, 'data', 'tim-pos.db'));
    db.run("insert into tenants (id, name, country_code, created_at) values ('t1', 'x', 'ZW', 1)");
    assert.equal(statSync(join(dir, 'data', 'tim-pos.db')).mode & 0o777, 0o600);
    assert.equal(statSync(join(dir, 'data')).mode & 0o777, 0o700);
    db.close();
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('a failed transaction leaves nothing behind', () => {
  const db = openDb(':memory:');
  assert.throws(() =>
    db.tx(() => {
      db.run("insert into tenants (id, name, country_code, created_at) values ('t1', 'x', 'ZW', 1)");
      db.run("insert into tenants (id, name, country_code, created_at) values ('t1', 'dup', 'ZW', 1)");
    }),
  );
  assert.equal(db.get<{ n: number }>('select count(*) as n from tenants')!.n, 0);
  db.close();
});

test('a database made before receipt prefixes existed is upgraded and numbered in activation order', () => {
  const db = new Db(':memory:');
  const sql = (f: string) => readFileSync(new URL(`../migrations/${f}`, import.meta.url), 'utf8');
  db.raw.exec(sql('001_init.sql'));
  db.run("insert into tenants (id, name, country_code, created_at) values ('t1', 'S', 'ZW', 1), ('t2', 'T', 'ZW', 1)");
  db.run("insert into licences (id, tenant_id, key_hash, key_hint, issued_at, expires_at, created_at) values ('l1', 't1', 'h1', 'k', 1, 9, 1), ('l2', 't2', 'h2', 'k', 1, 9, 1)");
  const act = (id: string, tenant: string, lic: string, at: number) =>
    db.run(`insert into activations (id, licence_id, tenant_id, fingerprint, device_name, platform, secret_hash, activated_at)
            values (?, ?, ?, ?, 'd', 'android', 's', ?)`, id, lic, tenant, `fp-${id}`, at);
  act('b', 't1', 'l1', 200); act('a', 't1', 'l1', 100); act('c', 't2', 'l2', 50);
  db.raw.exec(sql('002_receipt_prefix.sql'));
  const prefixes = db.all<{ id: string; receipt_prefix: string }>('select id, receipt_prefix from activations order by id').map((r) => ({ ...r }));
  assert.deepEqual(prefixes, [
    { id: 'a', receipt_prefix: 'D1' }, { id: 'b', receipt_prefix: 'D2' }, { id: 'c', receipt_prefix: 'D1' },
  ]);
  assert.throws(() => db.run("update activations set receipt_prefix = 'D1' where id = 'b'"), /UNIQUE/);
  db.close();
});
