import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import { boot, makeShop, activateDevice, START } from '../../server/test/helpers.ts';
import { PhoneSync, SyncError } from '../src/phone_sync.ts';
const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
const MANIFEST = JSON.parse(readFileSync(new URL('../../app/assets/sql/schema_manifest.json', import.meta.url), 'utf8'));
class Phone {
    db = new DatabaseSync(':memory:');
    sync;
    clock = START;
    failNext = null;
    h;
    dev;
    shopId;
    constructor(h, dev, shopId) {
        this.h = h;
        this.dev = dev;
        this.shopId = shopId;
        this.db.exec('pragma foreign_keys = on');
        for (const stmt of SQL.split(/^-- ##$/m).map((s) => s.trim()).filter((s) => s && !s.startsWith('--')))
            this.db.exec(stmt);
        const http = async (method, path, body) => {
            if (this.failNext === 'offline') {
                this.failNext = null;
                throw new Error('network down');
            }
            const r = await h.call(method, path, { auth: dev.auth, body });
            if (this.failNext === 'drop_response') {
                this.failNext = null;
                throw new Error('connection lost after the server answered');
            }
            return r;
        };
        this.sync = new PhoneSync(this.db, http, MANIFEST, () => this.clock);
    }
    q(sql, ...a) { return this.db.prepare(sql).all(...a).map((r) => ({ ...r })); }
    insert(table, row) {
        const kind = MANIFEST[table].kind;
        const o = { shop_id: this.shopId, created_at: this.clock, ...(kind === 'versioned' ? { updated_at: this.clock, version: 1 } : {}), ...row };
        this.db.prepare(`insert into "${table}" (${Object.keys(o).map((k) => `"${k}"`)}) values (${Object.keys(o).map(() => '?')})`).run(...Object.values(o));
    }
    edit(table, id, set) {
        const cur = this.q(`select version from "${table}" where id = ?`, id)[0];
        const o = { ...set, version: cur.version + 1, updated_at: this.clock };
        this.db.prepare(`update "${table}" set ${Object.keys(o).map((k) => `"${k}" = ?`)} where id = ?`).run(...Object.values(o), id);
    }
    snapshot() {
        const out = {};
        for (const t of Object.keys(MANIFEST)) {
            const rows = this.q(`select * from "${t}" order by id`);
            if (rows.length)
                out[t] = rows.map(({ shop_id, ...r }) => r); // shop_id is stamped by the server, compare the rest
        }
        return out;
    }
}
const opened = [];
after(async () => { for (const h of opened) {
    try {
        await h.close();
    }
    catch { /* already closed */ }
} });
async function world() {
    const h = await boot();
    opened.push(h);
    const shop = await makeShop(h, { max_devices: 3 });
    const a = new Phone(h, await activateDevice(h, shop.key), shop.tenantId);
    const b = new Phone(h, await activateDevice(h, shop.key), shop.tenantId);
    return { h, shop, a, b };
}
/** A small shop: a branch, a product with stock, and one complete sale as the till writes it. */
function seedShop(p) {
    p.insert('branches', { id: 'branch-01', name: 'Main' });
    p.insert('products', { id: 'product-01', name: 'Bread', cost_minor: 60 });
    p.insert('stock_movements', { id: 'move-000', branch_id: 'branch-01', product_id: 'product-01', type: 'purchase', qty_milli: 20000 });
}
function sell(p, n, qtyMilli = 2000) {
    p.insert('sales', {
        id: `sale-000${n}`, branch_id: 'branch-01', receipt_no: `D1-00000${n}`, status: 'completed', sale_currency: 'USD',
        subtotal_minor: 200, discount_minor: 0, tax_minor: 0, total_minor: 200, completed_at: p.clock,
    });
    p.insert('sale_lines', { id: `line-000${n}`, sale_id: `sale-000${n}`, product_id: 'product-01', qty_milli: qtyMilli, unit_price_minor: 100, line_total_minor: 200 * qtyMilli / 2000, unit_cost_minor: 60 });
    p.insert('sale_payments', { id: `paym-000${n}`, sale_id: `sale-000${n}`, method_code: 'cash', currency: 'USD', amount_minor: 200 });
    p.insert('stock_movements', { id: `move-s00${n}`, branch_id: 'branch-01', product_id: 'product-01', type: 'sale', qty_milli: -qtyMilli, ref_type: 'sale', ref_id: `sale-000${n}` });
}
test('a sale made on one phone appears on the other, with stock to match', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    sell(a, 1);
    const r = await a.sync.sync();
    assert.deepEqual(r.rejected, []);
    assert.equal(r.pulled, 0, 'a phone does not get its own changes back');
    await b.sync.sync();
    assert.deepEqual(b.snapshot(), a.snapshot());
    assert.deepEqual(b.q('select qty_milli from stock_levels'), [{ qty_milli: 18000 }]);
    assert.equal(b.q('select count(*) c from change_log')[0].c, 0, 'applied rows are not queued to be sent back');
    assert.equal(a.q('select count(*) c from change_log where sent_at is null')[0].c, 0);
    await h.close();
});
test('two phones selling at once both end with the same books', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    await a.sync.sync();
    await b.sync.sync();
    sell(a, 1, 2000);
    b.insert('sales', { id: 'sale-000B', branch_id: 'branch-01', receipt_no: 'D2-000001', status: 'completed', sale_currency: 'USD', subtotal_minor: 100, discount_minor: 0, tax_minor: 0, total_minor: 100, completed_at: b.clock });
    b.insert('stock_movements', { id: 'move-s00B', branch_id: 'branch-01', product_id: 'product-01', type: 'sale', qty_milli: -1000, ref_type: 'sale', ref_id: 'sale-000B' });
    await Promise.all([a.sync.sync(), b.sync.sync()]);
    await a.sync.sync();
    await b.sync.sync();
    assert.deepEqual(a.snapshot(), b.snapshot());
    assert.deepEqual(a.q('select qty_milli from stock_levels'), [{ qty_milli: 17000 }]);
    assert.deepEqual(b.q('select qty_milli from stock_levels'), [{ qty_milli: 17000 }]);
    await h.close();
});
test('the same product edited on both phones: the higher version wins, a tie goes to the later edit', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    await a.sync.sync();
    await b.sync.sync();
    a.clock += 1000;
    b.clock += 2000;
    a.edit('products', 'product-01', { name: 'Bread (A)' });
    b.edit('products', 'product-01', { name: 'Bread (B)' }); // same version 2, later time: B wins
    await a.sync.sync();
    await b.sync.sync();
    await a.sync.sync();
    assert.equal(a.q("select name from products where id = 'product-01'")[0].name, 'Bread (B)');
    assert.equal(b.q("select name from products where id = 'product-01'")[0].name, 'Bread (B)');
    a.edit('products', 'product-01', { name: 'v3' });
    a.edit('products', 'product-01', { name: 'v4' }); // two edits offline: version 4
    b.clock += 5000;
    b.edit('products', 'product-01', { name: 'later but only v3' });
    await a.sync.sync();
    await b.sync.sync();
    await a.sync.sync();
    assert.equal(a.q("select name, version from products where id = 'product-01'")[0].name, 'v4');
    assert.equal(b.q("select name, version from products where id = 'product-01'")[0].name, 'v4');
    assert.ok(h.ctx.db.get('select count(*) c from sync_conflicts').c >= 1, 'the loser is kept on the server');
    await h.close();
});
test('a delete reaches the other phone as a soft delete', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    await a.sync.sync();
    await b.sync.sync();
    a.clock += 10;
    a.edit('products', 'product-01', { deleted_at: a.clock });
    await a.sync.sync();
    await b.sync.sync();
    assert.ok(b.q("select deleted_at from products where id = 'product-01'")[0].deleted_at);
    await h.close();
});
test('shop with no signal: work piles up, then goes out in order when the phone gets data', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    await a.sync.sync();
    await b.sync.sync();
    a.failNext = 'offline';
    sell(a, 1);
    await assert.rejects(a.sync.sync(), /network down/);
    sell(a, 2);
    sell(a, 3);
    assert.equal(a.q('select count(*) c from change_log where sent_at is null')[0].c, 12);
    await a.sync.sync();
    await b.sync.sync();
    assert.deepEqual(b.snapshot(), a.snapshot());
    assert.equal(b.q('select count(*) c from sales')[0].c, 3);
    await h.close();
});
test('the answer is lost after the server applied a batch: the resend adds nothing twice, even if the row changed meanwhile', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    a.failNext = 'drop_response';
    await assert.rejects(a.sync.push(), /connection lost/);
    assert.equal(a.q("select count(*) c from sync_batches where status = 'pending'")[0].c, 1);
    a.clock += 50;
    a.edit('products', 'product-01', { name: 'Bread, edited while waiting' }); // new change, new batch later
    const first = await a.sync.push();
    assert.equal(h.ctx.db.get('select count(*) c from change_feed').c, 4, '3 rows from the first batch + 1 edit, nothing doubled');
    assert.ok(first.pushed >= 1);
    await b.sync.sync();
    assert.deepEqual(b.snapshot(), a.snapshot());
    await h.close();
});
test('a new phone, or one that lost its data, restores everything including its own history', async () => {
    const { h, shop, a, b } = await world();
    seedShop(a);
    sell(a, 1);
    sell(a, 2);
    await a.sync.sync();
    await b.sync.sync();
    const fresh = new Phone(h, a.dev, a.shopId); // same licence slot, empty database
    await fresh.sync.pull(true);
    assert.deepEqual(fresh.snapshot(), a.snapshot());
    assert.deepEqual(fresh.q('select qty_milli from stock_levels'), a.q('select qty_milli from stock_levels'));
    void shop;
    await h.close();
});
test('after the server is restored from a backup, phones pull again from the start and lose nothing', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    sell(a, 1);
    await a.sync.sync();
    await b.sync.sync();
    h.ctx.db.run("update meta set value = 'new-epoch-after-restore' where key = 'sync_epoch'");
    h.ctx.db.raw.exec('drop trigger change_feed_no_delete'); // test only: stands in for loading an older backup
    h.ctx.db.run('delete from change_feed'); // the restored backup knows nothing newer
    sell(a, 2); // made after the backup
    const r = await a.sync.sync(); // push still works; pull notices the new epoch
    assert.equal(r.resetPull, true);
    await b.sync.sync();
    assert.equal(b.q('select count(*) c from sales')[0].c, 2, 'B kept sale 1 and received sale 2');
    assert.equal(a.q("select epoch from sync_state")[0].epoch, 'new-epoch-after-restore');
    await h.close();
});
test('data from a newer app version with unknown tables and columns is skipped, not fatal', async () => {
    const { h, a, b } = await world();
    seedShop(a);
    await a.sync.sync();
    h.ctx.db.raw.exec('drop trigger change_feed_no_update'); // test only: stands in for a server that sends newer data
    h.ctx.db.run("update change_feed set data = json_set(data, '$.colour_from_the_future', 'red') where table_name = 'products'");
    await b.sync.sync();
    assert.equal(b.q('select count(*) c from products')[0].c, 1);
    await h.close();
});
test('a suspended licence stops sync with a clear error and keeps the work safe on the phone', async () => {
    const { h, shop, a } = await world();
    seedShop(a);
    sell(a, 1);
    const r = await h.call('POST', `/v1/vendor/licences/${shop.licenceId}/suspend`, { auth: shop.vendor, body: {} });
    assert.equal(r.status, 200, JSON.stringify(r.json));
    await assert.rejects(a.sync.sync(), (e) => e instanceof SyncError && e.status === 403 && e.body.error.locked === true);
    assert.equal(a.q('select count(*) c from sales')[0].c, 1);
    assert.ok(a.q('select count(*) c from change_log where sent_at is null')[0].c > 0);
    await h.close();
});
