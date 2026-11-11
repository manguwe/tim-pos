import 'package:sqflite_sqlcipher/sqflite.dart';

/// The few database calls the sync engine needs. The app uses the encrypted database below;
/// the tests use plain SQLite on a desktop through another implementation of the same interface.
abstract class SqlDb {
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]);
  Future<void> exec(String sql, [List<Object?> args = const []]);

  /// Runs [action] in one transaction: all of it is saved, or none of it.
  Future<T> transaction<T>(Future<T> Function(SqlDb tx) action);
}

class SqlcipherDb implements SqlDb {
  SqlcipherDb(this._e);
  final DatabaseExecutor _e;

  @override
  Future<List<Map<String, Object?>>> query(String sql, [List<Object?> args = const []]) => _e.rawQuery(sql, args);

  @override
  Future<void> exec(String sql, [List<Object?> args = const []]) => _e.execute(sql, args);

  @override
  Future<T> transaction<T>(Future<T> Function(SqlDb tx) action) {
    final e = _e;
    if (e is Database) return e.transaction((txn) => action(SqlcipherDb(txn)));
    return action(this); // already inside a transaction
  }
}
