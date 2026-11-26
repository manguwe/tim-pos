import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../setup/setup_repository.dart' show SetupError;

/// Everyday costs of running the shop (rent, transport, electricity). Entries are never edited or deleted, so the books stay honest:
/// a mistake is corrected by adding an opposite entry (see [undo]).
const List<String> suggestedExpenseCategories = ['Rent', 'Electricity', 'Transport', 'Wages', 'Airtime and data', 'Packaging', 'Repairs', 'Other'];

class ExpenseRow {
  const ExpenseRow({required this.id, required this.amountMinor, required this.currency, required this.category, this.payee, this.note, required this.spentAt});
  final String id;
  final int amountMinor;
  final String currency;
  final String? category, payee, note;
  final int spentAt;
}

class ExpenseRepository {
  ExpenseRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  Future<void> _insert(SqlDb tx, String table, Map<String, Object?> row, int now, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1},
      ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
  }

  Future<List<Map<String, Object?>>> categories() =>
      db.query('select id, name from expense_categories where deleted_at is null and coalesce(is_active, 1) = 1 order by name');

  /// Adds the suggested categories that are not there yet. Returns how many were added.
  Future<int> addSuggestedCategories() async {
    final now = _clock();
    return db.transaction((tx) async {
      var n = 0;
      for (final name in suggestedExpenseCategories) {
        final have = await tx.query('select 1 as x from expense_categories where deleted_at is null and lower(name) = lower(?)', [name]);
        if (have.isNotEmpty) continue;
        await _insert(tx, 'expense_categories', {'name': name, 'is_active': 1}, now, versioned: true);
        n++;
      }
      return n;
    });
  }

  /// Records money spent, in the shop's main currency. [amountMinor] must be more than zero.
  Future<void> add({required int amountMinor, String? categoryId, String? payee, String? note, String methodCode = 'cash', int? spentAt}) async {
    if (amountMinor <= 0) throw SetupError('bad_amount', 'Enter the amount spent.');
    final now = _clock();
    await db.transaction((tx) async {
      final shop = await tx.query('select base_currency from shops where deleted_at is null limit 1');
      if (shop.isEmpty) throw SetupError('shop_not_set_up', 'Set up the shop first.');
      final branch = await tx.query('select id from branches where deleted_at is null order by created_at limit 1');
      await _insert(tx, 'expenses', {
        'branch_id': branch.isEmpty ? null : branch.first['id'], 'category_id': categoryId, 'currency': shop.first['base_currency'],
        'amount_minor': amountMinor, 'payee': (payee ?? '').trim().isEmpty ? null : payee!.trim(), 'method_code': methodCode,
        'note': (note ?? '').trim().isEmpty ? null : note!.trim(), 'spent_at': spentAt ?? now,
      }, now);
    });
  }

  /// Cancels an entry by adding an opposite one. The original stays in the history.
  Future<void> undo(String expenseId) async {
    final now = _clock();
    await db.transaction((tx) async {
      final r = await tx.query('select * from expenses where id = ?', [expenseId]);
      if (r.isEmpty) throw SetupError('not_found', 'That entry was not found.');
      final e = r.first;
      final already = await tx.query("select 1 as x from expenses where note = ?", ['Correction of $expenseId']);
      if (already.isNotEmpty) throw SetupError('already_undone', 'That entry was already corrected.');
      await _insert(tx, 'expenses', {
        'branch_id': e['branch_id'], 'category_id': e['category_id'], 'currency': e['currency'], 'amount_minor': -(e['amount_minor'] as num).toInt(),
        'payee': e['payee'], 'method_code': e['method_code'], 'note': 'Correction of $expenseId', 'spent_at': now,
      }, now);
    });
  }

  Future<List<ExpenseRow>> list(int from, int to) async => [
        for (final r in await db.query(
          'select e.id, e.amount_minor, e.currency, e.payee, e.note, e.spent_at, c.name as category from expenses e '
          'left join expense_categories c on c.id = e.category_id where e.spent_at >= ? and e.spent_at < ? order by e.spent_at desc, e.created_at desc',
          [from, to],
        ))
          ExpenseRow(
            id: r['id'] as String, amountMinor: (r['amount_minor'] as num).toInt(), currency: r['currency'] as String,
            category: r['category'] as String?, payee: r['payee'] as String?, note: r['note'] as String?, spentAt: (r['spent_at'] as num).toInt(),
          ),
      ];

  /// Total spent in the main currency in the period (corrections already taken off).
  Future<int> total(int from, int to) async {
    final r = await db.query(
      'select coalesce(sum(amount_minor), 0) as t from expenses where spent_at >= ? and spent_at < ? and currency = (select base_currency from shops where deleted_at is null limit 1)',
      [from, to],
    );
    return (r.first['t'] as num).toInt();
  }
}

/// One product that is running out.
class LowStockRow {
  const LowStockRow(this.productId, this.name, this.onHandMilli);
  final String productId, name;
  final int onHandMilli;
}

/// Stock-counted products with [levelMilli] or fewer left in a branch, emptiest first. A level of 0 lists only what is out of stock.
Future<List<LowStockRow>> lowStock(SqlDb db, String branchId, int levelMilli) async => [
      for (final r in await db.query(
        "select p.id, p.name, coalesce((select sum(l.qty_milli) from stock_levels l where l.product_id = p.id and l.branch_id = ?), 0) as q "
        "from products p where p.deleted_at is null and p.is_active = 1 and p.track_stock = 1 and p.kind <> 'variant_parent' and q <= ? "
        'order by q, p.name limit 300',
        [branchId, levelMilli],
      ))
        LowStockRow(r['id'] as String, r['name'] as String, (r['q'] as num).toInt()),
    ];
