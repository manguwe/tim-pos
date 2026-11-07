import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { generate } from '../gen-local-schema.ts';
import { TABLES } from '../../server/src/tables.ts';
/** Load the generated SQL file exactly as the phone will: split on the delimiter, run one statement at a time. */
function phoneDb() {
    const sql = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
    const db = new DatabaseSync(':memory:');
    db.exec('pragma foreign_keys = on');
    for (const stmt of sql.split(/^-- ##$/m).map((s) => s.trim()).filter((s) => s && !s.startsWith('--')))
        db.exec(stmt);
    return db;
}
const rows = (db, q, ...a) => db.prepare(q).all(...a).map((r) => ({ ...r }));
let n = 0;
const id = () => `id${++n}`;
const T = 1700000000000;
function ins(db, table, v) {
    const o = { id: id(), shop_id: 's1', created_at: T, ...v };
    db.prepare(`insert into "${table}" (${Object.keys(o).map((k) => `"${k}"`)}) values (${Object.keys(o).map(() => '?')})`).run(...Object.values(o));
    return o.id;
}
const versioned = (v) => ({ updated_at: T, version: 1, ...v });
test('the checked-in SQL file is exactly what the generator produces', () => {
    const onDisk = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
    assert.equal(onDisk, generate().sql, 'run: node tools/gen-local-schema.ts');
});
test('every table the server accepts exists on the phone with the standard columns', () => {
    const db = phoneDb();
    for (const [table, kind] of Object.entries(TABLES)) {
        const cols = rows(db, `pragma table_info("${table}")`).map((c) => c.name);
        for (const c of ['id', 'shop_id', 'created_at', 'created_by', 'device_id'])
            assert.ok(cols.includes(c), `${table}.${c}`);
        for (const c of ['updated_at', 'version', 'deleted_at'])
            assert.equal(cols.includes(c), kind === 'versioned', `${table}.${c}`);
    }
    for (const t of ['change_log', 'sync_state', 'sync_batches', 'stock_levels', 'receipt_counters', 'held_sales', 'printers', 'device_state'])
        assert.ok(rows(db, `select name from sqlite_master where name = ?`, t).length, t);
    assert.equal(rows(db, 'select count(*) c from sync_state')[0].c, 1);
});
test('inserts and edits are written to the change log by the database itself', () => {
    const db = phoneDb();
    const p = ins(db, 'products', versioned({ name: 'Bread' }));
    assert.deepEqual(rows(db, 'select table_name, row_id, op, version from change_log'), [{ table_name: 'products', row_id: p, op: 'insert', version: 1 }]);
    db.prepare('update products set name = ?, version = 2, updated_at = ? where id = ?').run('Brown bread', T + 5, p);
    db.prepare('update products set deleted_at = ?, version = 3, updated_at = ? where id = ?').run(T + 9, T + 9, p);
    const log = rows(db, 'select op, version, updated_at from change_log order by seq');
    assert.deepEqual(log.map((l) => [l.op, l.version]), [['insert', 1], ['update', 2], ['delete', 3]]);
});
test('a versioned row cannot be edited without raising its version, or hard-deleted', () => {
    const db = phoneDb();
    const p = ins(db, 'products', versioned({ name: 'Milk' }));
    assert.throws(() => db.prepare('update products set name = ? where id = ?').run('x', p), /version must increase/);
    assert.throws(() => db.prepare('delete from products where id = ?').run(p), /soft delete only/);
});
test('append-only rows can be added but never changed or removed', () => {
    const db = phoneDb();
    const c = ins(db, 'customers', versioned({ name: 'Mai Tendai' }));
    const l = ins(db, 'customer_ledger', { customer_id: c, type: 'credit_sale', currency: 'USD', amount_minor: 500 });
    assert.throws(() => db.prepare('update customer_ledger set amount_minor = 1 where id = ?').run(l), /append-only/);
    assert.throws(() => db.prepare('delete from customer_ledger where id = ?').run(l), /append-only/);
    assert.deepEqual(rows(db, "select op, version from change_log where table_name = 'customer_ledger'"), [{ op: 'insert', version: 1 }]);
});
test('rows applied from the server are not sent back, and may skip the version rule', () => {
    const db = phoneDb();
    db.exec('update sync_state set applying = 1');
    const p = ins(db, 'products', versioned({ name: 'Remote', version: 7 }));
    db.prepare('update products set name = ?, version = 7 where id = ?').run('Remote 2', p); // same version: allowed while applying
    db.exec('update sync_state set applying = 0');
    assert.equal(rows(db, 'select count(*) c from change_log')[0].c, 0);
});
test('stock levels follow every movement, per batch, and can be rebuilt from movements', () => {
    const db = phoneDb();
    const prod = ins(db, 'products', versioned({ name: 'Rice' }));
    const br = ins(db, 'branches', versioned({ name: 'Main' }));
    const mv = (type, qty, batch = null) => ins(db, 'stock_movements', { branch_id: br, product_id: prod, type, qty_milli: qty, batch_id: batch });
    mv('purchase', 10000);
    mv('sale', -2500);
    mv('purchase', 4000, 'B1');
    mv('loss', -1000, 'B1');
    assert.deepEqual(rows(db, 'select batch_key, qty_milli from stock_levels order by batch_key'), [{ batch_key: '', qty_milli: 7500 }, { batch_key: 'B1', qty_milli: 3000 }]);
    const rebuilt = rows(db, `select coalesce(batch_id, '') batch_key, sum(qty_milli) qty_milli from stock_movements group by 1 order by 1`);
    assert.deepEqual(rebuilt, rows(db, 'select batch_key, qty_milli from stock_levels order by batch_key'));
});
test('a movement whose sign does not match its type is refused', () => {
    const db = phoneDb();
    const prod = ins(db, 'products', versioned({ name: 'Oil' }));
    const br = ins(db, 'branches', versioned({ name: 'Main' }));
    const mv = (type, qty) => () => ins(db, 'stock_movements', { branch_id: br, product_id: prod, type, qty_milli: qty });
    assert.throws(mv('sale', 1000), /CHECK/);
    assert.throws(mv('purchase', -1000), /CHECK/);
    assert.throws(mv('purchase', 0), /CHECK/);
    assert.doesNotThrow(mv('adjustment', -1000));
    assert.doesNotThrow(mv('count_correction', 2000));
});
test('money must be whole numbers and enums only hold allowed values', () => {
    const db = phoneDb();
    const br = ins(db, 'branches', versioned({ name: 'Main' }));
    const sale = (over) => () => ins(db, 'sales', {
        branch_id: br, receipt_no: `D1-${id()}`, status: 'completed', sale_currency: 'USD', subtotal_minor: 100, discount_minor: 0,
        tax_minor: 0, total_minor: 100, completed_at: T, ...over,
    });
    assert.doesNotThrow(sale({}));
    assert.throws(sale({ total_minor: 99.5 }), /CHECK/);
    assert.throws(sale({ total_minor: 'one' }), /CHECK/);
    assert.throws(sale({ status: 'maybe' }), /CHECK/);
});
test('receipt numbers are unique per shop, and a payment of zero is refused', () => {
    const db = phoneDb();
    const br = ins(db, 'branches', versioned({ name: 'Main' }));
    const base = { branch_id: br, status: 'completed', sale_currency: 'USD', subtotal_minor: 100, discount_minor: 0, tax_minor: 0, total_minor: 100, completed_at: T };
    const s = ins(db, 'sales', { ...base, receipt_no: 'D1-000001' });
    assert.throws(() => ins(db, 'sales', { ...base, receipt_no: 'D1-000001' }), /UNIQUE/);
    assert.doesNotThrow(() => ins(db, 'sales', { ...base, receipt_no: 'D1-000001', shop_id: 's2' }));
    assert.throws(() => ins(db, 'sale_payments', { sale_id: s, method_code: 'cash', currency: 'USD', amount_minor: 0 }), /CHECK/);
});
test('a barcode is unique per shop unless the old one was deleted', () => {
    const db = phoneDb();
    const a = ins(db, 'products', versioned({ name: 'A' }));
    const b = ins(db, 'products', versioned({ name: 'B' }));
    const bc = ins(db, 'product_barcodes', versioned({ product_id: a, barcode: '600123' }));
    assert.throws(() => ins(db, 'product_barcodes', versioned({ product_id: b, barcode: '600123' })), /UNIQUE/);
    db.prepare('update product_barcodes set deleted_at = ?, version = 2, updated_at = ? where id = ?').run(T, T, bc);
    assert.doesNotThrow(() => ins(db, 'product_barcodes', versioned({ product_id: b, barcode: '600123' })));
});
test('foreign keys are enforced at commit, so a pull page may deliver a child before its parent', () => {
    const db = phoneDb();
    db.exec('begin');
    const line = ins(db, 'sale_lines', { sale_id: 'sale-from-later-page', qty_milli: 1000, unit_price_minor: 100, line_total_minor: 100 });
    assert.ok(line);
    assert.throws(() => db.exec('commit'), /FOREIGN KEY/);
    db.exec('rollback');
    // parent arrives in the same transaction: fine
    const br = ins(db, 'branches', versioned({ name: 'Main' }));
    db.exec('begin');
    ins(db, 'sale_lines', { sale_id: 'S9', qty_milli: 1000, unit_price_minor: 100, line_total_minor: 100 });
    ins(db, 'sales', { id: 'S9', branch_id: br, receipt_no: 'D1-9', status: 'completed', sale_currency: 'USD', subtotal_minor: 100, discount_minor: 0, tax_minor: 0, total_minor: 100, completed_at: T });
    assert.doesNotThrow(() => db.exec('commit'));
});
test('the settings key is unique per scope', () => {
    const db = phoneDb();
    ins(db, 'settings', versioned({ scope: 'shop', key: 'costing', value: 'weighted' }));
    assert.throws(() => ins(db, 'settings', versioned({ scope: 'shop', key: 'costing', value: 'latest' })), /UNIQUE/);
    assert.doesNotThrow(() => ins(db, 'settings', versioned({ scope: 'branch', scope_id: 'b1', key: 'costing', value: 'latest' })));
});
