import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/expenses/expense_repository.dart';
import 'package:tim_pos/setup/setup_repository.dart';

import 'support/ffi_db.dart';

const t0 = 1800000000000;

void main() {
  test('expenses are recorded in the main currency, totalled, and corrected by an opposite entry', () async {
    final db = await openTestDb();
    var n = 0;
    final setup = SetupRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => t0, idMaker: () => 'gen-s${(++n).toString().padLeft(7, '0')}');
    await setup.seedShop(name: 'A', countryCode: 'ZW');
    final repo = ExpenseRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => t0, idMaker: () => 'gen-e${(++n).toString().padLeft(7, '0')}');
    expect(await repo.addSuggestedCategories(), suggestedExpenseCategories.length);
    expect(await repo.addSuggestedCategories(), 0);
    final rent = (await repo.categories()).firstWhere((c) => c['name'] == 'Rent')['id'] as String;
    await repo.add(amountMinor: 15000, categoryId: rent, payee: 'Landlord', note: 'November');
    await repo.add(amountMinor: 2500);
    expect(await repo.total(t0 - 1000, t0 + 1000), 17500);
    final rows = await repo.list(t0 - 1000, t0 + 1000);
    expect(rows.length, 2);
    expect(rows.map((r) => r.category), containsAll(['Rent', null]));
    await expectLater(repo.add(amountMinor: 0), throwsA(isA<SetupError>()));
    await repo.undo(rows.firstWhere((r) => r.amountMinor == 2500).id);
    expect(await repo.total(t0 - 1000, t0 + 1000), 15000);
    await expectLater(repo.undo(rows.firstWhere((r) => r.amountMinor == 2500).id), throwsA(isA<SetupError>().having((e) => e.code, 'code', 'already_undone')));
    expect(await repo.total(t0 + 5000, t0 + 9000), 0);
  });

  test('low stock lists counted products at or under the level, emptiest first', () async {
    final db = await openTestDb();
    var n = 0;
    final setup = SetupRepository(db: db, shopId: 'shop-0001', deviceId: 'dev-00001', clock: () => t0, idMaker: () => 'gen-${(++n).toString().padLeft(8, '0')}');
    await setup.seedShop(name: 'A', countryCode: 'ZW');
    final branch = (await db.query('select id from branches')).single['id'] as String;
    Future<void> product(String name, int qty) async {
      final id = await setup.saveProduct(ProductInput(name: name, priceMinor: 100));
      if (qty > 0) await setup.receiveStock(branchId: branch, productId: id, qtyMilli: qty);
    }
    await product('Plenty', 20000);
    await product('Few', 3000);
    await product('None', 0);
    final rows = await lowStock(db, branch, 5000);
    expect(rows.map((r) => r.name), ['None', 'Few']);
    expect((await lowStock(db, branch, 0)).map((r) => r.name), ['None']);
  });
}
