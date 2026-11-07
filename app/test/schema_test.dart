import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tim_pos/data/local_db.dart';

import 'support/ffi_db.dart';

void main() {
  test('the schema file splits into statements and loads', () async {
    final statements = splitSchema(File('assets/sql/local_schema.sql').readAsStringSync());
    expect(statements.length, greaterThan(250));
    expect(statements.every((s) => !s.startsWith('--')), isTrue);
    await openTestDb(); // runs them all
  });

  test('every table in the manifest exists, and the database logs and guards changes by itself', () async {
    final db = await openTestDb();
    final manifest = jsonDecode(File('assets/sql/schema_manifest.json').readAsStringSync()) as Map<String, dynamic>;
    expect(manifest.length, 55);
    for (final t in manifest.keys) {
      final cols = (await db.query('pragma table_info("$t")')).map((r) => r['name']).toSet();
      expect(cols, containsAll(['id', 'shop_id', 'created_at']), reason: t);
    }

    await db.exec("insert into products (id, shop_id, created_at, updated_at, version, name) values ('p1', 's', 1, 1, 1, 'Bread')");
    expect((await db.query('select op from change_log')).map((r) => r['op']), ['insert']);

    // version must rise on every edit
    await expectLater(db.exec("update products set name = 'x' where id = 'p1'"), throwsA(anything));
    // movements keep the stock cache
    await db.exec("insert into branches (id, shop_id, created_at, updated_at, name) values ('b1', 's', 1, 1, 'Main')");
    await db.exec("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, type, qty_milli) values ('m1', 's', 1, 'b1', 'p1', 'purchase', 5000)");
    await db.exec("insert into stock_movements (id, shop_id, created_at, branch_id, product_id, type, qty_milli) values ('m2', 's', 2, 'b1', 'p1', 'sale', -1500)");
    expect((await db.query('select qty_milli from stock_levels')).single['qty_milli'], 3500);
    // a sale cannot be edited later
    await expectLater(db.exec("update stock_movements set qty_milli = 9 where id = 'm1'"), throwsA(anything));
  });
}
