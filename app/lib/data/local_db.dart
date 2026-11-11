import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';

import 'key_value_store.dart';
import 'sql_db.dart';

/// Opens the phone's encrypted database. The key is made once, on first run, and kept in the Android Keystore.
/// Without it the file is unreadable, so copying the database off the phone gets a thief nothing.
class LocalDatabase {
  LocalDatabase._(this.raw) : sql = SqlcipherDb(raw);

  final Database raw;
  final SqlDb sql;

  static const int schemaVersion = 1;
  static const String _file = 'tim_pos.db';

  static Future<LocalDatabase> open(KeyValueStore store) async {
    var key = await store.read(Keys.dbKey);
    if (key == null) {
      final r = Random.secure();
      key = List.generate(32, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
      await store.write(Keys.dbKey, key);
    }
    final path = p.join(await getDatabasesPath(), _file);
    final schema = await rootBundle.loadString('assets/sql/local_schema.sql');
    final db = await openDatabase(
      path,
      password: key,
      version: schemaVersion,
      onConfigure: (db) async {
        // Links between tables are checked when a transaction commits, so a page of synced rows may arrive in any order.
        await db.execute('PRAGMA foreign_keys = ON');
      },
      onCreate: (db, version) async {
        for (final statement in splitSchema(schema)) {
          await db.execute(statement);
        }
      },
      // Later versions: add onUpgrade here with migration scripts, one per schemaVersion step.
    );
    return LocalDatabase._(db);
  }

  Future<void> close() => raw.close();
}

/// The schema file holds one statement per block. A block starts at a line that is exactly "-- ##".
/// (Triggers contain semicolons, so the file cannot simply be split on them.)
List<String> splitSchema(String file) => file
    .split(RegExp(r'^-- ##$', multiLine: true))
    .map((s) => s.trim())
    .where((s) => s.isNotEmpty && !s.startsWith('--'))
    .toList();
