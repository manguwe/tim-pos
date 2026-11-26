import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/auth/auth_repository.dart';
import 'package:tim_pos/data/sql_db.dart';
import 'package:tim_pos/selling/selling.dart';
import 'package:tim_pos/setup/setup_repository.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

Matcher authCode(String c) => isA<AuthError>().having((e) => e.code, 'code', c);

void main() {
  final v = jsonDecode(File('test/fixtures/auth_vectors.json').readAsStringSync()) as Map<String, dynamic>;

  test('PIN hashes made by the reference code verify here, and wrong PINs do not', () {
    for (final h in (v['hashes'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      final stored = h['stored'] as String;
      expect(verifyPin(h['pin'] as String, stored), isTrue, reason: stored);
      expect(verifyPin('${h['pin']}0', stored), isFalse);
      // hashing here with the same salt and iterations gives the identical string
      final parts = stored.split(r'$');
      expect(hashPin(h['pin'] as String, salt: base64.decode(parts[2]), iterations: int.parse(parts[1])), stored);
    }
    expect(verifyPin('2580', null), isFalse);
    expect(verifyPin('2580', 'garbage'), isFalse);
    expect(verifyPin('2580', r'pbkdf2-sha256$0$AAAA$AAAA'), isFalse);
  });

  test('PIN rules and lock times agree with the reference', () {
    (v['pins'] as Map<String, dynamic>).forEach((pin, ok) => expect(validatePin(pin) == null, ok, reason: "'$pin'"));
    for (final l in (v['lock'] as List<dynamic>).cast<Map<String, dynamic>>()) {
      expect(lockDuration(l['failed'] as int), l['ms'], reason: '${l['failed']}');
    }
  });

  group('with a shop', () {
    late SqlDb db;
    late AuthRepository auth;
    late SetupRepository setup;
    late String owner;
    var n = 0;
    var now = t0;

    String uid() => 'gen-${(++n).toString().padLeft(8, '0')}';

    Future<String> role(String name) async => (await db.query('select id from roles where name = ?', [name])).single['id'] as String;

    setUp(() async {
      db = await openTestDb();
      n = 0;
      now = t0;
      setup = SetupRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => now, idMaker: uid);
      auth = AuthRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => now, idMaker: uid);
      owner = (await setup.seedShop(name: 'Shop', countryCode: 'ZW', ownerName: 'Tim', ownerPin: '2580')).ownerId!;
    });

    test('set-up makes four roles and an owner who can sign in; the PIN is not stored', () async {
      expect((await db.query('select name from roles order by name')).map((r) => r['name']), ['Cashier', 'Manager', 'Owner', 'Stock clerk']);
      final me = await auth.login(owner, '2580');
      expect(me.name, 'Tim');
      expect(me.can('user.manage'), isTrue);
      expect(jsonEncode(await db.query('select * from users')), isNot(contains('2580')));
      expect((await auth.listLoginUsers()).single.name, 'Tim');
    });

    test('weak owner PIN at set-up is refused and creates nothing', () async {
      final fresh = await openTestDb();
      final s = SetupRepository(db: fresh, shopId: 's', deviceId: 'd');
      await expectLater(s.seedShop(name: 'X', countryCode: 'ZW', ownerName: 'T', ownerPin: '1111'), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'weak_pin')));
      expect((await fresh.query('select count(*) c from shops')).single['c'], 0);
    });

    test('the PIN reset code matches the server\'s calculation', () {
      expect(pinResetCode('0123456789abcdef', '12345678', 'user-1'), '03290361');
      expect(pinResetCode('k', '00000001', 'u2'), '74036538');
    });

    test('a forgotten PIN is reset with the vendor\'s code, once, and clears the lock', () async {
      const key = 'recovery-key-for-test';
      final challenge = await auth.startPinRecovery();
      expect(challenge, matches(RegExp(r'^\d{8}$')));
      expect(await auth.pendingPinRecovery(), challenge);
      for (var i = 0; i < 5; i++) {
        try { await auth.login(owner, '9999'); } on AuthError catch (_) {}
      }
      final code = pinResetCode(key, challenge, owner);
      // Wrong code, wrong person, weak new PIN: all refused.
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: '00000000', newPin: '4682'), throwsA(authCode('wrong_code')));
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: pinResetCode(key, challenge, 'someone-else'), newPin: '4682'), throwsA(authCode('wrong_code')));
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: code, newPin: '1111'), throwsA(authCode('weak_pin')));
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: '', code: code, newPin: '4682'), throwsA(authCode('no_key')));
      await auth.recoverPin(userId: owner, recoveryKey: key, code: code, newPin: '4682');
      expect((await auth.login(owner, '4682')).name, 'Tim');
      // Used up: the same code cannot be replayed.
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: code, newPin: '7391'), throwsA(authCode('no_request')));
      expect((await db.query("select count(*) c from audit_log where action = 'pin_recovered'")).single['c'], 1);
    });

    test('a recovery request stops after five wrong codes and after a day', () async {
      const key = 'k';
      final c = await auth.startPinRecovery();
      for (var i = 0; i < 5; i++) {
        await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: '00000000', newPin: '4682'), throwsA(authCode('wrong_code')));
      }
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: pinResetCode(key, c, owner), newPin: '4682'), throwsA(authCode('expired')));
      final c2 = await auth.startPinRecovery();
      now = t0 + 25 * 3600000;
      expect(await auth.pendingPinRecovery(), isNull);
      await expectLater(auth.recoverPin(userId: owner, recoveryKey: key, code: pinResetCode(key, c2, owner), newPin: '4682'), throwsA(authCode('expired')));
    });

    test('wrong PINs count down, then lock with growing waits; the right PIN clears it', () async {
      Future<AuthError> wrong() async {
        try {
          await auth.login(owner, '9999');
        } on AuthError catch (e) {
          return e;
        }
        throw StateError('should have failed');
      }

      now = t0 + 1;
      expect([(await wrong()).detail['attempts_left'], (await wrong()).detail['attempts_left'], (await wrong()).detail['attempts_left'], (await wrong()).detail['attempts_left']], [4, 3, 2, 1]);
      final fifth = await wrong();
      expect(fifth.code, 'locked');
      expect(fifth.detail['until'], t0 + 1 + baseLockMs);
      now = t0 + 60000;
      await expectLater(auth.login(owner, '2580'), throwsA(authCode('locked')));
      now = t0 + baseLockMs + 10;
      expect((await wrong()).detail['until'], t0 + baseLockMs + 10 + baseLockMs * 2);
      now = t0 + 10 * baseLockMs;
      expect((await auth.login(owner, '2580')).name, 'Tim');
      expect((await wrong()).detail['attempts_left'], 4);
      expect((await db.query("select count(*) c from audit_log where action = 'login_failed'")).single['c'], greaterThanOrEqualTo(6));
    });

    test('only people with user.manage can add staff; the shop always keeps one owner', () async {
      final rudo = await auth.createUser(owner, name: 'Rudo', roleId: await role('Cashier'), pin: '7391');
      await expectLater(auth.createUser(rudo, name: 'X', roleId: await role('Cashier'), pin: '7392'), throwsA(authCode('forbidden')));
      await expectLater(auth.createUser(owner, name: 'rudo', roleId: await role('Cashier'), pin: '7392'), throwsA(authCode('name_taken')));
      await expectLater(auth.createUser(owner, name: 'Y', roleId: await role('Cashier'), pin: '1111'), throwsA(authCode('weak_pin')));
      expect((await db.query('select count(*) c from users')).single['c'], 2);
      await expectLater(auth.changeRole(owner, owner, await role('Manager')), throwsA(authCode('last_owner')));
      await expectLater(auth.setActive(owner, owner, false), throwsA(authCode('self')));
      final second = await auth.createUser(owner, name: 'Baba', roleId: await role('Owner'), pin: '6204');
      await auth.changeRole(owner, owner, await role('Manager'));
      await expectLater(auth.changeRole(second, second, await role('Cashier')), throwsA(authCode('last_owner')));
      await auth.setActive(second, rudo, false);
      await expectLater(auth.login(rudo, '7391'), throwsA(authCode('inactive')));
    });

    test('a forgotten PIN is reset by a user manager, and either way the lock is cleared', () async {
      final rudo = await auth.createUser(owner, name: 'Rudo', roleId: await role('Cashier'), pin: '7391');
      for (var i = 0; i < 5; i++) {
        try {
          await auth.login(rudo, '0001');
        } on AuthError catch (_) {}
      }
      await expectLater(auth.login(rudo, '7391'), throwsA(authCode('locked')));
      await auth.resetPin(owner, rudo, '8153');
      expect((await auth.login(rudo, '8153')).name, 'Rudo');
      await expectLater(auth.resetPin(rudo, owner, '8153'), throwsA(authCode('forbidden')));
      await expectLater(auth.changeOwnPin(rudo, '0000', '9264'), throwsA(authCode('wrong_pin')));
      await auth.changeOwnPin(rudo, '8153', '9264');
      await expectLater(auth.login(rudo, '8153'), throwsA(authCode('wrong_pin')));
      expect((await auth.login(rudo, '9264')).name, 'Rudo');
    });

    test('a cashier cannot discount or type a price alone, but can with a manager approving by PIN', () async {
      await setup.setExchangeRate('USD', 'ZiG', 26500000);
      final bread = await setup.saveProduct(const ProductInput(name: 'Bread', priceMinor: 150, costMinor: 90));
      final branch = (await db.query('select id from branches')).single['id'] as String;
      await setup.receiveStock(branchId: branch, productId: bread, qtyMilli: 10000, unitCostMinor: 90, opening: true);
      final cashier = await auth.createUser(owner, name: 'Rudo', roleId: await role('Cashier'), pin: '7391');
      final manager = await auth.createUser(owner, name: 'Mai', roleId: await role('Manager'), pin: '4826');
      final engine = SellingEngine(db: db, context: const SaleContext(shopId: 'shop-0001', deviceId: 'dev-00001', receiptPrefix: 'D1'), clock: () => now + 1000, idMaker: uid);
      Cart cart({int discount = 0, int? price, String? approvedBy, String? user, int pay = 150}) => Cart(
            branchId: branch, userId: user ?? cashier, saleCurrency: 'USD', approvedBy: approvedBy,
            lines: [CartLine(productId: bread, qtyMilli: 1000, discountMinor: discount, unitPriceMinor: price)],
            payments: [CartPayment(methodCode: 'cash', currency: 'USD', amountMinor: pay)],
          );
      Matcher forbidden() => isA<SaleError>().having((e) => e.code, 'code', 'forbidden');

      expect((await engine.sell(cart())).totalMinor, 150);
      await expectLater(engine.sell(cart(discount: 10)), throwsA(forbidden()));
      await expectLater(engine.sell(cart(price: 100)), throwsA(forbidden()));

      expect(await auth.approve(action: 'sale.discount', requestedBy: cashier, approverId: manager, pin: '4826'), isNotEmpty);
      expect((await engine.sell(cart(discount: 10, approvedBy: manager, pay: 140))).totalMinor, 140);

      final tino = await auth.createUser(owner, name: 'Tino', roleId: await role('Cashier'), pin: '3947');
      await expectLater(auth.approve(action: 'sale.discount', requestedBy: cashier, approverId: tino, pin: '3947'), throwsA(authCode('forbidden')));
      await expectLater(auth.approve(action: 'sale.discount', requestedBy: cashier, approverId: manager, pin: '0000'), throwsA(authCode('wrong_pin')));

      final clerk = await auth.createUser(owner, name: 'Gift', roleId: await role('Stock clerk'), pin: '5718');
      await expectLater(engine.sell(cart(user: clerk)), throwsA(forbidden()));
      await auth.setActive(owner, cashier, false);
      await expectLater(engine.sell(cart()), throwsA(forbidden()));
      expect((await db.query('select count(*) c from sales')).single['c'], 2);
    });
  });
}
