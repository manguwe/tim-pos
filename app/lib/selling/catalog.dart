import '../data/sql_db.dart';
import 'money.dart';

/// A product as the till shows it: name, price in the sale currency, and what is on the shelf.
class ProductHit {
  const ProductHit({
    required this.id,
    required this.name,
    required this.sku,
    required this.unitPriceMinor,
    required this.taxRateBp,
    required this.taxInclusive,
    required this.onHandMilli,
    required this.tracksStock,
    required this.allowNegative,
  });
  final String id;
  final String name;
  final String? sku;

  /// Price per unit in the sale currency, or null when the product has no price in it.
  final int? unitPriceMinor;
  final int taxRateBp;
  final bool taxInclusive;
  final int onHandMilli;
  final bool tracksStock;
  final bool allowNegative;

  bool get canSell => unitPriceMinor != null;
}

/// Reads the catalogue for the till. Price rules are the same as the selling engine's (selling.dart):
/// latest effective price, customer tier then default tier, else the base-currency price converted at the current rate.
class CatalogRepository {
  CatalogRepository(this.db, {int Function()? clock}) : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch);
  final SqlDb db;
  final int Function() _clock;

  static const int maxResults = 40;

  /// Search by name or SKU (any part of it). Short queries still work; an empty query lists the first products by name.
  Future<List<ProductHit>> search(String query, {required String branchId, required String currency, String? tierId}) async {
    final like = '%${query.trim().replaceAll('%', '').replaceAll('_', '')}%';
    final rows = await db.query(
      "select id from products where deleted_at is null and is_active = 1 and kind <> 'variant_parent' "
      "and (name like ? or sku like ?) order by name limit ?",
      [like, like, maxResults],
    );
    return _hits(rows.map((r) => r['id'] as String), branchId, currency, tierId);
  }

  /// A scanned code resolves to one product in a single lookup.
  Future<ProductHit?> byBarcode(String code, {required String branchId, required String currency, String? tierId}) async {
    final rows = await db.query(
      'select b.product_id as id from product_barcodes b join products p on p.id = b.product_id '
      'where b.barcode = ? and b.deleted_at is null and p.deleted_at is null and p.is_active = 1 limit 1',
      [code.trim()],
    );
    if (rows.isEmpty) return null;
    final hits = await _hits([rows.first['id'] as String], branchId, currency, tierId);
    return hits.isEmpty ? null : hits.first;
  }

  /// One product by id (for a scan that has already been resolved).
  Future<ProductHit?> byId(String id, {required String branchId, required String currency, String? tierId}) async {
    final hits = await _hits([id], branchId, currency, tierId);
    return hits.isEmpty ? null : hits.first;
  }

  Future<List<ProductHit>> _hits(Iterable<String> ids, String branchId, String currency, String? tierId) async {
    final now = _clock();
    final base = (await db.query('select base_currency from shops where deleted_at is null limit 1')).firstOrNull?['base_currency'] as String?;
    final out = <ProductHit>[];
    for (final id in ids) {
      final p = (await db.query('select * from products where id = ?', [id])).first;
      final tc = p['tax_class_id'] == null ? null : (await db.query('select rate_bp, is_inclusive from tax_classes where id = ?', [p['tax_class_id']])).firstOrNull;
      final stock = (await db.query(
        'select coalesce(sum(qty_milli), 0) as q from stock_levels where branch_id = ? and product_id = ?',
        [branchId, id],
      ))
          .first['q'] as num;
      out.add(ProductHit(
        id: id,
        name: p['name'] as String,
        sku: p['sku'] as String?,
        unitPriceMinor: await _price(id, currency, base, tierId, now),
        taxRateBp: tc == null ? 0 : (tc['rate_bp'] as num).toInt(),
        taxInclusive: tc == null ? true : tc['is_inclusive'] == 1,
        onHandMilli: stock.toInt(),
        tracksStock: p['track_stock'] == 1,
        allowNegative: p['allow_negative_stock'] == 1,
      ));
    }
    return out;
  }

  Future<int?> _price(String productId, String currency, String? base, String? tierId, int now) async {
    Future<int?> find(String cur) async {
      final rows = await db.query(
        'select price_minor, tier_id from product_prices where product_id = ? and currency = ? and effective_from <= ? and deleted_at is null '
        'order by effective_from desc, created_at desc',
        [productId, cur, now],
      );
      for (final r in rows) {
        if (r['tier_id'] == tierId) return (r['price_minor'] as num).toInt();
      }
      for (final r in rows) {
        if (r['tier_id'] == null) return (r['price_minor'] as num).toInt();
      }
      return rows.isEmpty ? null : (rows.first['price_minor'] as num).toInt();
    }

    final direct = await find(currency);
    if (direct != null || base == null || base == currency) return direct;
    final inBase = await find(base);
    if (inBase == null) return null;
    final rate = await _rate(base, currency, now);
    if (rate == null) return null;
    final from = (await db.query('select minor_units from currencies where code = ?', [base])).firstOrNull;
    final to = (await db.query('select minor_units from currencies where code = ?', [currency])).firstOrNull;
    if (from == null || to == null) return null;
    return convertMinor(inBase, rate, (from['minor_units'] as num).toInt(), (to['minor_units'] as num).toInt());
  }

  Future<int?> _rate(String from, String to, int now) async {
    const sql = 'select rate_micro from exchange_rates where from_currency = ? and to_currency = ? and effective_from <= ? '
        'order by effective_from desc, created_at desc limit 1';
    final d = (await db.query(sql, [from, to, now])).firstOrNull;
    if (d != null) return (d['rate_micro'] as num).toInt();
    final i = (await db.query(sql, [to, from, now])).firstOrNull;
    return i == null ? null : invertRate((i['rate_micro'] as num).toInt());
  }

  /// What [amount] in currency [from] is worth in [to] at today's rate, or null when no rate is set.
  Future<int?> convert(int amount, String from, String to) async {
    if (from == to) return amount;
    final rate = await _rate(from, to, _clock());
    if (rate == null) return null;
    final f = (await db.query('select minor_units from currencies where code = ?', [from])).firstOrNull;
    final t = (await db.query('select minor_units from currencies where code = ?', [to])).firstOrNull;
    if (f == null || t == null) return null;
    return convertMinor(amount, rate, (f['minor_units'] as num).toInt(), (t['minor_units'] as num).toInt());
  }

  /// The first branch, and the currencies the shop sells in, for opening the till.
  Future<TillSetup?> setup() async {
    final shop = (await db.query('select base_currency from shops where deleted_at is null limit 1')).firstOrNull;
    final branch = (await db.query('select id, name from branches where deleted_at is null order by created_at limit 1')).firstOrNull;
    if (shop == null || branch == null) return null;
    final cur = await db.query('select code, symbol, minor_units from currencies where deleted_at is null and is_active = 1 order by code');
    return TillSetup(
      branchId: branch['id'] as String,
      branchName: branch['name'] as String,
      baseCurrency: shop['base_currency'] as String,
      currencies: [for (final c in cur) CurrencyInfo(c['code'] as String, (c['symbol'] as String?) ?? c['code'] as String, (c['minor_units'] as num).toInt())],
    );
  }
}

class CurrencyInfo {
  const CurrencyInfo(this.code, this.symbol, this.minorUnits);
  final String code;
  final String symbol;
  final int minorUnits;

  /// "12.5" or "12,50" -> 1250. Returns null for anything that is not a plain amount. No floating point.
  int? parse(String text) {
    final t = text.trim().replaceAll(',', '.');
    final m = RegExp(r'^(\d{1,10})(?:\.(\d*))?$').firstMatch(t);
    if (m == null) return null;
    final frac = (m.group(2) ?? '');
    if (frac.length > minorUnits) return null;
    var p = 1;
    for (var i = 0; i < minorUnits; i++) {
      p *= 10;
    }
    final fracValue = minorUnits == 0 ? 0 : int.parse(frac.padRight(minorUnits, '0'));
    return int.parse(m.group(1)!) * p + fracValue;
  }

  /// 1250 -> "$12.50" (or "ZiG 12.50"). Whole numbers only, no floating point.
  String format(int minor) {
    final neg = minor < 0;
    final a = minor.abs();
    var p = 1;
    for (var i = 0; i < minorUnits; i++) {
      p *= 10;
    }
    final whole = (a ~/ p).toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final frac = minorUnits == 0 ? '' : '.${(a % p).toString().padLeft(minorUnits, '0')}';
    final sym = symbol.length > 1 ? '$symbol ' : symbol;
    return '${neg ? '-' : ''}$sym$whole$frac';
  }
}

class TillSetup {
  const TillSetup({required this.branchId, required this.branchName, required this.baseCurrency, required this.currencies});
  final String branchId;
  final String branchName;
  final String baseCurrency;
  final List<CurrencyInfo> currencies;
  CurrencyInfo currency(String code) => currencies.firstWhere((c) => c.code == code, orElse: () => CurrencyInfo(code, code, 2));
}
