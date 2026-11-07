import test from 'node:test';
import assert from 'node:assert/strict';
import { DatabaseSync } from 'node:sqlite';
import { readFileSync } from 'node:fs';
import {
  hashPin, verifyPin, validatePin, login, createUser, changeRole, setActive, resetPin, changeOwnPin, approve, hasPermission, listLoginUsers,
  lockDuration, AuthError, PERMISSIONS, LOCK_AFTER, BASE_LOCK_MS, MAX_LOCK_MS,
} from '../src/auth.ts';
import { seedShop, saveProduct, receiveStock, setExchangeRate, type SetupContext } from '../src/setup.ts';
import { sell, SaleError } from '../src/selling.ts';

const SQL = readFileSync(new URL('../../app/assets/sql/local_schema.sql', import.meta.url), 'utf8');
let n = 0;
const uid = () => `gen-${String(++n).padStart(8, '0')}`;
const T = 1_800_000_000_000;
const ctx: SetupContext = { shop_id: 'shop-0001', device_id: 'dev-00001', user_id: null, now: T };

function shop() {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = on');
  for (const s of SQL.split(/^-- ##$/m).map((x) => x.trim()).filter((x) => x && !x.startsWith('--'))) db.exec(s);
  const q = (sql: string, ...a: any[]) => db.prepare(sql).all(...a).map((r) => ({ ...r })) as any[];
  const r = seedShop(db, ctx, { name: 'Shop', country_code: 'ZW', owner: { name: 'Tim', pin: '2580' } }, uid);
  const role = (name: string) => q('select id from roles where name = ?', name)[0].id as string;
  return { db, q, owner: r.owner_id!, branch: r.branch_id, role };
}
const code = (fn: () => unknown) => { try { fn(); } catch (e) { return (e as AuthError | SaleError).code; } return 'no error'; };
const at = (ms: number): SetupContext => ({ ...ctx, now: T + ms });

test('PINs are hashed with a salt, verified, and never stored in clear', () => {
  const a = hashPin('2580'); const b = hashPin('2580');
  assert.notEqual(a, b, 'a fresh salt each time');
  assert.match(a, /^pbkdf2-sha256\$10000\$[A-Za-z0-9+/=]+\$[A-Za-z0-9+/=]+$/);
  assert.equal(verifyPin('2580', a), true);
  assert.equal(verifyPin('2581', a), false);
  assert.equal(verifyPin('2580', null), false);
  assert.equal(verifyPin('2580', 'garbage'), false);
  assert.equal(verifyPin('2580', 'pbkdf2-sha256$0$AAAA$AAAA'), false);
  assert.ok(!a.includes('2580'));
});

test('weak PINs are refused', () => {
  for (const bad of ['', '123', '123456789', 'abcd', '1111', '0000', '1234', '4321', '56789', '98765', '12 4']) assert.ok(validatePin(bad), bad);
  for (const good of ['2580', '1357', '9081', '112233', '12345679']) assert.equal(validatePin(good), null, good);
});

test('set-up makes the four roles and an owner who can sign in; the PIN is not in the database', () => {
  const s = shop();
  assert.deepEqual(s.q('select name from roles order by name').map((r) => r.name), ['Cashier', 'Manager', 'Owner', 'Stock clerk']);
  assert.deepEqual(PERMISSIONS.filter((p) => !hasPermission(s.db, s.owner, p)), []);
  assert.deepEqual(listLoginUsers(s.db), [{ id: s.owner, name: 'Tim', role: 'Owner' }]);
  const u = login(s.db, ctx, s.owner, '2580', uid);
  assert.equal(u.name, 'Tim'); assert.ok(u.permissions.includes('user.manage'));
  assert.ok(!JSON.stringify(s.q('select * from users')).includes('2580'));
  assert.deepEqual(s.q("select action from audit_log").map((r) => r.action), ['login']);
});

test('wrong PINs count down, then lock the user on this phone with growing waits, and a right PIN clears it', () => {
  const s = shop();
  const wrong = (ms: number) => { try { login(s.db, at(ms), s.owner, '9999', uid); } catch (e) { return e as AuthError; } throw new Error('should fail'); };
  assert.deepEqual([wrong(1).detail.attempts_left, wrong(2).detail.attempts_left, wrong(3).detail.attempts_left, wrong(4).detail.attempts_left], [4, 3, 2, 1]);
  const fifth = wrong(5);
  assert.equal(fifth.code, 'locked'); assert.equal(fifth.detail.until, T + 5 + BASE_LOCK_MS);
  // while locked even the right PIN is refused, and the count does not grow
  assert.equal(code(() => login(s.db, at(60_000), s.owner, '2580', uid)), 'locked');
  // after the wait, a wrong PIN locks for twice as long
  const sixth = wrong(BASE_LOCK_MS + 10);
  assert.equal(sixth.detail.until, T + BASE_LOCK_MS + 10 + BASE_LOCK_MS * 2);
  // the right PIN after the wait works and clears everything
  assert.equal(login(s.db, at(10 * BASE_LOCK_MS), s.owner, '2580', uid).name, 'Tim');
  assert.equal(wrong(10 * BASE_LOCK_MS + 5).detail.attempts_left, 4);
  assert.deepEqual([lockDuration(4), lockDuration(5), lockDuration(6), lockDuration(7), lockDuration(30)], [0, BASE_LOCK_MS, 2 * BASE_LOCK_MS, 4 * BASE_LOCK_MS, MAX_LOCK_MS]);
  assert.equal(LOCK_AFTER, 5);
  assert.ok(s.q("select count(*) c from audit_log where action = 'login_failed'")[0].c >= 6);
});

test('lockouts are kept on the phone and not synced', () => {
  const s = shop();
  const before = s.q('select count(*) c from change_log')[0].c;
  try { login(s.db, ctx, s.owner, '0000', uid); } catch { /* wrong on purpose */ }
  assert.ok(s.q("select 1 from device_state where key like 'lock:%'").length === 1);
  assert.equal(s.q("select count(*) c from change_log where table_name = 'users'")[0].c, 1, 'only the original insert');
  assert.ok(s.q('select count(*) c from change_log')[0].c >= before, 'only the audit row was added');
});

test('only people with the user.manage permission can add staff, and roles decide what they can do', () => {
  const s = shop();
  const cashier = createUser(s.db, ctx, s.owner, { name: 'Rudo', role_id: s.role('Cashier'), pin: '7391', branch_ids: [s.branch] }, uid);
  assert.equal(hasPermission(s.db, cashier, 'sale.create'), true);
  assert.equal(hasPermission(s.db, cashier, 'sale.discount'), false);
  assert.equal(code(() => createUser(s.db, ctx, cashier, { name: 'X', role_id: s.role('Cashier'), pin: '7392' }, uid)), 'forbidden');
  assert.equal(code(() => createUser(s.db, ctx, s.owner, { name: 'rudo', role_id: s.role('Cashier'), pin: '7392' }, uid)), 'name_taken');
  assert.equal(code(() => createUser(s.db, ctx, s.owner, { name: 'Y', role_id: s.role('Cashier'), pin: '1111' }, uid)), 'weak_pin');
  assert.equal(code(() => createUser(s.db, ctx, s.owner, { name: 'Y', role_id: 'no-such-role', pin: '7392' }, uid)), 'unknown_role');
  assert.equal(code(() => createUser(s.db, ctx, s.owner, { name: '  ', role_id: s.role('Cashier'), pin: '7392' }, uid)), 'missing');
  assert.equal(s.q('select count(*) c from users')[0].c, 2, 'refused attempts left nothing behind');
  assert.ok(s.q("select 1 from audit_log where action = 'user_created'").length === 1);
});

test('the shop always keeps one active owner', () => {
  const s = shop();
  const mgr = createUser(s.db, ctx, s.owner, { name: 'Mai', role_id: s.role('Manager'), pin: '4826' }, uid);
  assert.equal(code(() => changeRole(s.db, ctx, s.owner, s.owner, s.role('Manager'), uid)), 'last_owner');
  assert.equal(code(() => setActive(s.db, ctx, s.owner, s.owner, false, uid)), 'self');
  const second = createUser(s.db, ctx, s.owner, { name: 'Baba', role_id: s.role('Owner'), pin: '6204' }, uid);
  changeRole(s.db, ctx, s.owner, s.owner, s.role('Manager'), uid);       // fine: Baba is also an owner
  assert.equal(code(() => setActive(s.db, ctx, second, second, false, uid)), 'self');
  assert.equal(code(() => changeRole(s.db, ctx, second, second, s.role('Cashier'), uid)), 'last_owner');
  setActive(s.db, ctx, second, mgr, false, uid);
  assert.equal(code(() => login(s.db, ctx, mgr, '4826', uid)), 'inactive');
  assert.deepEqual(listLoginUsers(s.db).map((u) => u.name), ['Baba', 'Tim']);
});

test('a forgotten PIN is reset by a manager of users, a known PIN is changed by its owner, and either clears the lock', () => {
  const s = shop();
  const rudo = createUser(s.db, ctx, s.owner, { name: 'Rudo', role_id: s.role('Cashier'), pin: '7391' }, uid);
  for (let i = 0; i < 5; i++) try { login(s.db, ctx, rudo, '0001', uid); } catch { /* locking */ }
  assert.equal(code(() => login(s.db, ctx, rudo, '7391', uid)), 'locked');
  resetPin(s.db, ctx, s.owner, rudo, '8153', uid);
  assert.equal(login(s.db, ctx, rudo, '8153', uid).name, 'Rudo');
  assert.equal(code(() => resetPin(s.db, ctx, rudo, s.owner, '8153', uid)), 'forbidden');
  assert.equal(code(() => changeOwnPin(s.db, ctx, rudo, '0000', '9264', uid)), 'wrong_pin');
  changeOwnPin(s.db, ctx, rudo, '8153', '9264', uid);
  assert.equal(code(() => login(s.db, ctx, rudo, '8153', uid)), 'wrong_pin');
  assert.equal(login(s.db, ctx, rudo, '9264', uid).name, 'Rudo');
  assert.deepEqual(s.q("select action from audit_log where action in ('pin_reset','pin_changed') order by created_at, rowid").map((r) => r.action), ['pin_reset', 'pin_changed']);
});

test('a cashier cannot give a discount or type a price alone, but can with a manager approving by PIN', () => {
  const s = shop();
  setExchangeRate(s.db, ctx, 'USD', 'ZiG', 26_500_000, uid);
  const bread = saveProduct(s.db, ctx, { name: 'Bread', price_minor: 150, cost_minor: 90 }, uid);
  receiveStock(s.db, ctx, { branch_id: s.branch, product_id: bread, qty_milli: 10_000, unit_cost_minor: 90, opening: true }, uid);
  const cashier = createUser(s.db, ctx, s.owner, { name: 'Rudo', role_id: s.role('Cashier'), pin: '7391' }, uid);
  const manager = createUser(s.db, ctx, s.owner, { name: 'Mai', role_id: s.role('Manager'), pin: '4826' }, uid);
  const sctx = { shop_id: ctx.shop_id, device_id: ctx.device_id, receipt_prefix: 'D1', now: T + 1000 };
  const cart = (extra: object = {}, line: object = {}) => ({
    branch_id: s.branch, user_id: cashier, sale_currency: 'USD',
    lines: [{ product_id: bread, qty_milli: 1_000, ...line }], payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 150 }], ...extra,
  });
  assert.equal(sell(s.db, sctx, cart(), uid).total_minor, 150, 'an ordinary sale is fine');
  assert.equal(code(() => sell(s.db, sctx, cart({}, { discount_minor: 10 }), uid)), 'forbidden');
  assert.equal(code(() => sell(s.db, sctx, cart({}, { unit_price_minor: 100 }), uid)), 'forbidden');
  // the manager approves in person by PIN
  const approval = approve(s.db, ctx, { action: 'sale.discount', requested_by: cashier, approver_id: manager, pin: '4826' }, uid);
  assert.ok(approval);
  const ok = sell(s.db, sctx, cart({ approved_by: manager, payments: [{ method_code: 'cash', currency: 'USD', amount_minor: 140 }] }, { discount_minor: 10 }), uid);
  assert.equal(ok.total_minor, 140);
  assert.deepEqual(s.q('select action, requested_by, approved_by from approvals').map((r) => [r.action, r.requested_by, r.approved_by]), [['sale.discount', cashier, manager]]);
  // a cashier cannot approve for another cashier; a wrong approver PIN is refused
  const cashier2 = createUser(s.db, ctx, s.owner, { name: 'Tino', role_id: s.role('Cashier'), pin: '3947' }, uid);
  assert.equal(code(() => approve(s.db, ctx, { action: 'sale.discount', requested_by: cashier, approver_id: cashier2, pin: '3947' }, uid)), 'forbidden');
  assert.equal(code(() => approve(s.db, ctx, { action: 'sale.discount', requested_by: cashier, approver_id: manager, pin: '0000' }, uid)), 'wrong_pin');
  // a stock clerk cannot sell at all, and a switched-off user cannot either
  const clerk = createUser(s.db, ctx, s.owner, { name: 'Gift', role_id: s.role('Stock clerk'), pin: '5718' }, uid);
  assert.equal(code(() => sell(s.db, sctx, cart({ user_id: clerk }), uid)), 'forbidden');
  setActive(s.db, ctx, s.owner, cashier, false, uid);
  assert.equal(code(() => sell(s.db, sctx, cart(), uid)), 'forbidden');
  assert.equal(s.q('select count(*) c from sales')[0].c, 2);
});

test('set-up with a weak owner PIN is refused and creates nothing', () => {
  const db = new DatabaseSync(':memory:');
  db.exec('pragma foreign_keys = on');
  for (const s of SQL.split(/^-- ##$/m).map((x) => x.trim()).filter((x) => x && !x.startsWith('--'))) db.exec(s);
  assert.throws(() => seedShop(db, ctx, { name: 'X', country_code: 'ZW', owner: { name: 'T', pin: '1111' } }, uid), (e: any) => e.code === 'weak_pin');
  assert.equal((db.prepare('select count(*) c from shops').get() as any).c, 0);
});
