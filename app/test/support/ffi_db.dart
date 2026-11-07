import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart' as ffi;
import 'package:tim_pos/data/local_db.dart' show splitSchema;
import 'package:tim_pos/data/sql_db.dart';

/// Plain (unencrypted) SQLite on the desktop, with the app's real schema file, for tests.
class FfiSqlDb implements SqlDb {
  FfiSqlDb(this._e);
  final ffi.DatabaseExecutor _e;

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]) async {
    final rows = await _e.rawQuery(sql, args);
    return rows.map((r) => Map<String, Object?>.of(r)).toList();
  }

  @override
  Future<void> exec(String sql, [List<Object?> args = const []]) => _e.execute(sql, args);

  @override
  Future<T> transaction<T>(Future<T> Function(SqlDb tx) action) {
    final e = _e;
    if (e is ffi.Database) return e.transaction((txn) => action(FfiSqlDb(txn)));
    return action(this);
  }
}

Future<FfiSqlDb> openTestDb() async {
  ffi.sqfliteFfiInit();
  final schema = File('assets/sql/local_schema.sql').readAsStringSync();
  final db = await ffi.databaseFactoryFfi.openDatabase(
    ffi.inMemoryDatabasePath,
    options: ffi.OpenDatabaseOptions(
      singleInstance: false,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: (db, v) async {
        for (final s in splitSchema(schema)) {
          await db.execute(s);
        }
      },
      version: 1,
    ),
  );
  return FfiSqlDb(db);
}
