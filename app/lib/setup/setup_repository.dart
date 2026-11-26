import 'dart:convert';

import '../auth/auth_repository.dart' show defaultRoles, hashPin, roleNames, validatePin;
import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../selling/money.dart' show divRound;

/// Shop set-up and catalogue writes. Port of tools/src/setup.ts, which is tested against the real schema.
/// Everything is written through normal tables, so database triggers log each row for sync.

class SetupError implements Exception {
  SetupError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'SetupError($code): $message';
}

class CountryPreset {
  const CountryPreset({required this.baseCurrency, required this.currencies, required this.paymentMethods, required this.taxClasses});
  final String baseCurrency;
  final List<Map<String, Object?>> currencies;
  final List<Map<String, Object?>> paymentMethods;
  final List<Map<String, Object?>> taxClasses;
}

Map<String, Object?> _mm(String code, String name) => {'code': code, 'name': name, 'kind': 'mobile_money', 'requires_reference': 1, 'opens_drawer': 0};
const _cash = {'code': 'cash', 'name': 'Cash', 'kind': 'cash', 'requires_reference': 0, 'opens_drawer': 1};
const _card = {'code': 'card', 'name': 'Card', 'kind': 'card', 'requires_reference': 1, 'opens_drawer': 0};
const _bank = {'code': 'bank_transfer', 'name': 'Bank transfer', 'kind': 'bank', 'requires_reference': 1, 'opens_drawer': 0};

/// Starting points per country. Everything can be changed by the shop afterwards. Tax rates are defaults, not advice.
final Map<String, CountryPreset> presets = {
  'ZW': CountryPreset(
    baseCurrency: 'USD',
    currencies: const [
      {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5},
      {'code': 'ZiG', 'name': 'Zimbabwe Gold', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100},
    ],
    paymentMethods: [_cash, _mm('ecocash', 'EcoCash'), _mm('onemoney', 'OneMoney'), _mm('innbucks', 'InnBucks'), _card, _bank],
    taxClasses: const [
      {'name': 'Standard rated', 'rate_bp': 1500, 'is_inclusive': 1},
      {'name': 'Zero rated', 'rate_bp': 0, 'is_inclusive': 1},
      {'name': 'Exempt', 'rate_bp': 0, 'is_inclusive': 1},
    ],
  ),
  'ZM': CountryPreset(
    baseCurrency: 'ZMW',
    currencies: const [
      {'code': 'ZMW', 'name': 'Zambian kwacha', 'symbol': 'K', 'minor_units': 2, 'rounding_increment_minor': 10},
      {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5},
    ],
    paymentMethods: [_cash, _mm('mtn_momo', 'MTN MoMo'), _mm('airtel_money', 'Airtel Money'), _card, _bank],
    taxClasses: const [
      {'name': 'Standard rated', 'rate_bp': 1600, 'is_inclusive': 1},
      {'name': 'Zero rated', 'rate_bp': 0, 'is_inclusive': 1},
      {'name': 'Exempt', 'rate_bp': 0, 'is_inclusive': 1},
    ],
  ),
};

/// Currencies a shop can add with one tap. The provider code for ZiG is ZWG; the app keeps calling it ZiG.
const List<Map<String, Object?>> knownCurrencies = [
  {'code': 'USD', 'name': 'US dollar', 'symbol': r'$', 'minor_units': 2, 'rounding_increment_minor': 5},
  {'code': 'ZiG', 'name': 'Zimbabwe Gold', 'symbol': 'ZiG', 'minor_units': 2, 'rounding_increment_minor': 100},
  {'code': 'ZMW', 'name': 'Zambian kwacha', 'symbol': 'K', 'minor_units': 2, 'rounding_increment_minor': 10},
  {'code': 'ZAR', 'name': 'South African rand', 'symbol': 'R', 'minor_units': 2, 'rounding_increment_minor': 10},
  {'code': 'BWP', 'name': 'Botswana pula', 'symbol': 'P', 'minor_units': 2, 'rounding_increment_minor': 5},
  {'code': 'MZN', 'name': 'Mozambican metical', 'symbol': 'MT', 'minor_units': 2, 'rounding_increment_minor': 10},
];

/// Pass this as the department filter to list only products that have no department yet.
const String noDepartment = '__none__';

/// Departments a shop can add with one tap, then rename or remove.
const List<String> suggestedDepartments = [
  'Groceries', 'Beverages', 'Fresh produce', 'Butchery', 'Bakery', 'Frozen foods', 'Snacks and sweets',
  'Toiletries and cosmetics', 'Household and cleaning', 'Stationery', 'Electronics', 'Phone accessories',
  'Clothing', 'Hardware', 'Airtime and services',
];

class ProductInput {
  const ProductInput({
    this.id,
    required this.name,
    this.sku,
    this.barcode,
    this.priceMinor,
    this.priceCurrency,
    this.costMinor,
    this.taxClassId,
    this.trackStock = true,
    this.allowNegativeStock = false,
    this.isActive = true,
    this.brand,
    this.imageRef,
    this.categoryId,
  });
  /// The department. Null leaves it as it is; an empty text removes the product from its department.
  final String? categoryId;
  /// Brand (for example the name on the packet). Null leaves it as it is; empty clears it.
  final String? brand;
  /// File name of the product picture. Null leaves the picture as it is.
  final String? imageRef;
  final String? id;
  final String name;
  final String? sku;
  final String? barcode;
  final int? priceMinor;
  final String? priceCurrency;
  final int? costMinor;
  final String? taxClassId;
  final bool trackStock;
  final bool allowNegativeStock;
  final bool isActive;
}

typedef _Row = Map<String, Object?>;

class SetupRepository {
  SetupRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId;
  final String deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();

  String _need(String? v, String msg) {
    if (v == null || v.trim().isEmpty) throw SetupError('missing', msg);
    return v.trim();
  }

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<String> _add(SqlDb tx, String table, _Row row, int now, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(),
      'shop_id': shopId,
      'created_at': now,
      'created_by': userId,
      'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1},
      ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  /// Edits a versioned row; the version rises by one, as the sync rules require.
  Future<void> _edit(SqlDb tx, String table, String id, _Row set, int now) async {
    final cur = await _get(tx, 'select version from "$table" where id = ?', [id]);
    if (cur == null) throw SetupError('not_found', 'That record was not found.');
    final o = <String, Object?>{...set, 'version': _i(cur['version']) + 1, 'updated_at': now};
    final k = o.keys.toList();
    await tx.exec('update "$table" set ${k.map((x) => '"$x" = ?').join(', ')} where id = ?', [...k.map((x) => o[x]), id]);
  }

  /// True when the shop already exists on this phone (made here, or arrived by sync).
  Future<bool> isSetUp() async => (await db.query('select 1 as x from shops where deleted_at is null limit 1')).isNotEmpty;

  /// First-time set-up. Does nothing if the shop already exists.
  Future<({bool created, String? ownerId})> seedShop({required String name, required String countryCode, String? branchName, bool taxRegistered = false, String? taxNumber, String? ownerName, String? ownerPin, String? baseCurrency}) async {
    final shopName = _need(name, 'Enter the shop name.');
    final preset = presets[countryCode.toUpperCase()];
    if (preset == null) throw SetupError('unknown_country', 'That country has no preset yet.');
    final base = baseCurrency ?? preset.baseCurrency;
    if (!preset.currencies.any((c) => c['code'] == base)) throw SetupError('bad_currency', 'Choose one of the currencies for that country.');
    String? ownerHash;
    if (ownerPin != null) {
      _need(ownerName, 'Enter the owner\'s name.');
      final bad = validatePin(ownerPin);
      if (bad != null) throw SetupError('weak_pin', bad);
      ownerHash = hashPin(ownerPin);
    }
    final now = _clock();
    return db.transaction((tx) async {
      if (await _get(tx, 'select id from shops where deleted_at is null limit 1') != null) return (created: false, ownerId: null);
      await _add(tx, 'shops', {
        'id': shopId, 'name': shopName, 'country_code': countryCode.toUpperCase(), 'base_currency': base,
        'tax_registered': taxRegistered ? 1 : 0, 'tax_number': taxNumber,
      }, now, versioned: true);
      final branchId = await _add(tx, 'branches', {'name': (branchName ?? '').trim().isEmpty ? 'Main branch' : branchName!.trim(), 'is_active': 1}, now, versioned: true);
      for (final c in preset.currencies) {
        await _add(tx, 'currencies', {...c, 'is_active': 1}, now, versioned: true);
      }
      for (final m in preset.paymentMethods) {
        await _add(tx, 'payment_methods', {...m, 'is_active': 1}, now, versioned: true);
      }
      for (final t in preset.taxClasses) {
        await _add(tx, 'tax_classes', t, now, versioned: true);
      }
      await _add(tx, 'price_tiers', {'name': 'Retail', 'is_default': 1}, now, versioned: true);
      await _add(tx, 'price_tiers', {'name': 'Wholesale', 'is_default': 0}, now, versioned: true);
      for (final u in const [('Piece', 'pcs', 'count'), ('Kilogram', 'kg', 'weight'), ('Litre', 'l', 'volume')]) {
        await _add(tx, 'units', {'name': u.$1, 'code': u.$2, 'kind': u.$3}, now, versioned: true);
      }
      for (final s in const [('costing', 'weighted_average'), ('allow_negative_stock', '0'), ('fiscal_enabled', '0')]) {
        await _add(tx, 'settings', {'scope': 'shop', 'key': s.$1, 'value': s.$2}, now, versioned: true);
      }
      final roleIds = <String, String>{};
      for (final key in roleNames.keys) {
        roleIds[key] = await _add(tx, 'roles', {'name': roleNames[key], 'permissions': jsonEncode(defaultRoles[key])}, now, versioned: true);
      }
      String? ownerId;
      if (ownerHash != null) {
        ownerId = await _add(tx, 'users', {'name': ownerName!.trim(), 'role_id': roleIds['owner'], 'pin_hash': ownerHash, 'is_active': 1}, now, versioned: true);
        await _add(tx, 'user_branches', {'user_id': ownerId, 'branch_id': branchId}, now, versioned: true);
      }
      return (created: true, ownerId: ownerId);
    });
  }

  /// The shop's currencies, main one first.
  Future<List<Map<String, Object?>>> shopCurrencies() => db.query(
      'select c.code, c.name, c.symbol, c.minor_units from currencies c where c.deleted_at is null and c.is_active = 1 '
      'order by (c.code = (select base_currency from shops where deleted_at is null limit 1)) desc, c.code');

  /// Adds a currency the shop wants to take or compare. Does nothing if it is already there.
  Future<void> addCurrency(String code) async {
    final known = knownCurrencies.where((c) => c['code'] == code);
    if (known.isEmpty) throw SetupError('unknown_currency', 'That currency is not available yet.');
    final now = _clock();
    await db.transaction((tx) async {
      final have = await _get(tx, 'select id, deleted_at, is_active from currencies where code = ?', [code]);
      if (have == null) {
        await _add(tx, 'currencies', {...known.first, 'is_active': 1}, now, versioned: true);
      } else if (have['deleted_at'] != null || have['is_active'] != 1) {
        await tx.exec('update currencies set is_active = 1, deleted_at = null, version = version + 1, updated_at = ? where id = ?', [now, have['id']]);
      }
    });
  }

  /// Today's rate for each pair, newest per pair: [from, to, rateMicro, since].
  Future<List<Map<String, Object?>>> latestRates() => db.query(
      'select e.from_currency, e.to_currency, e.rate_micro, e.effective_from from exchange_rates e '
      'where e.deleted_at is null and e.effective_from = (select max(x.effective_from) from exchange_rates x '
      'where x.from_currency = e.from_currency and x.to_currency = e.to_currency and x.deleted_at is null) '
      'order by e.from_currency, e.to_currency');

  /// Sets today's rate: how many millionths of [to] one [from] is worth. A new row each time; history is kept.
  Future<void> setExchangeRate(String from, String to, int rateMicro) async {
    if (from == to) throw SetupError('same_currency', 'Choose two different currencies.');
    if (rateMicro <= 0 || rateMicro > 100000000) throw SetupError('bad_rate', 'That rate is not valid.');
    final now = _clock();
    await db.transaction((tx) async {
      for (final c in [from, to]) {
        if (await _get(tx, 'select 1 as x from currencies where code = ? and deleted_at is null', [c]) == null) {
          throw SetupError('unknown_currency', 'Currency $c is not set up.');
        }
      }
      await _add(tx, 'exchange_rates', {'from_currency': from, 'to_currency': to, 'rate_micro': rateMicro, 'set_by': userId, 'effective_from': now}, now);
    });
  }

  /// Creates or edits a product. A changed price becomes a new price row, so earlier prices stay as history.
  Future<String> saveProduct(ProductInput p) async {
    final name = _need(p.name, 'Enter the product name.');
    if ((p.priceMinor ?? 0) < 0 || (p.costMinor ?? 0) < 0) throw SetupError('bad_amount', 'Amounts must be zero or more.');
    final now = _clock();
    return db.transaction((tx) async {
      final base = (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String?;
      if (base == null) throw SetupError('shop_not_set_up', 'Set up the shop first.');
      final unit = (await _get(tx, "select id from units where code = 'pcs' and deleted_at is null"))?['id'];
      final fields = <String, Object?>{
        'name': name, 'sku': (p.sku ?? '').trim().isEmpty ? null : p.sku!.trim(), 'base_unit_id': unit, 'tax_class_id': p.taxClassId,
        'kind': 'simple', 'track_stock': p.trackStock ? 1 : 0, 'allow_negative_stock': p.allowNegativeStock ? 1 : 0,
        'is_active': p.isActive ? 1 : 0, 'cost_minor': p.costMinor, 'cost_currency': base,
        if (p.brand != null) 'brand': p.brand!.trim().isEmpty ? null : p.brand!.trim(),
        if (p.imageRef != null) 'image_ref': p.imageRef,
        if (p.categoryId != null) 'category_id': p.categoryId!.isEmpty ? null : p.categoryId,
      };
      String id;
      if (p.id != null) {
        id = p.id!;
        await _edit(tx, 'products', id, fields, now);
      } else {
        id = await _add(tx, 'products', fields, now, versioned: true);
      }

      final code = (p.barcode ?? '').trim();
      if (code.isNotEmpty) {
        final owner = await _get(tx, 'select product_id from product_barcodes where barcode = ? and deleted_at is null', [code]);
        if (owner != null && owner['product_id'] != id) throw SetupError('barcode_taken', 'That barcode already belongs to another product.');
        if (owner == null) await _add(tx, 'product_barcodes', {'product_id': id, 'barcode': code}, now, versioned: true);
      }
      if (p.priceMinor != null) {
        final cur = p.priceCurrency ?? base;
        final tier = (await _get(tx, 'select id from price_tiers where is_default = 1 and deleted_at is null'))?['id'];
        final last = await _get(
          tx,
          'select price_minor from product_prices where product_id = ? and currency = ? and tier_id is ? and deleted_at is null '
          'order by effective_from desc, created_at desc limit 1',
          [id, cur, tier],
        );
        if (last == null || _i(last['price_minor']) != p.priceMinor) {
          await _add(tx, 'product_prices', {'product_id': id, 'tier_id': tier, 'currency': cur, 'price_minor': p.priceMinor, 'effective_from': now}, now, versioned: true);
        }
      }
      return id;
    });
  }

  /// Stock arriving: opening stock or a purchase. Writes the movement and, at a known cost, moves the product's cost
  /// to the weighted average (or the latest cost, if the shop chose that). Costs are in the shop's base currency.
  Future<void> receiveStock({required String branchId, required String productId, required int qtyMilli, int? unitCostMinor, bool opening = false}) async {
    if (qtyMilli <= 0) throw SetupError('bad_quantity', 'Quantity must be more than zero.');
    if ((unitCostMinor ?? 0) < 0) throw SetupError('bad_amount', 'The cost must be zero or more.');
    final now = _clock();
    await db.transaction((tx) async {
      final p = await _get(tx, 'select * from products where id = ? and deleted_at is null', [productId]);
      if (p == null) throw SetupError('not_found', 'That product was not found.');
      final base = (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))!['base_currency'] as String;
      final onHand = _i((await _get(tx, 'select coalesce(sum(qty_milli), 0) as q from stock_levels where product_id = ?', [productId]))!['q']);
      await _add(tx, 'stock_movements', {
        'branch_id': branchId, 'product_id': productId, 'batch_id': null, 'type': opening ? 'opening' : 'purchase', 'qty_milli': qtyMilli,
        'unit_cost_minor': unitCostMinor, 'cost_currency': base,
      }, now);
      if (unitCostMinor != null) {
        final costing = (await _get(tx, "select value from settings where scope = 'shop' and key = 'costing' and deleted_at is null"))?['value'];
        final old = p['cost_minor'] == null ? null : _i(p['cost_minor']);
        var next = unitCostMinor;
        if (costing != 'latest' && onHand > 0 && old != null) {
          final sum = onHand * old + qtyMilli * unitCostMinor;
          final den = onHand + qtyMilli;
          next = (sum * 2 + den) ~/ (den * 2); // half up, whole cents
        }
        if (next != old) await _edit(tx, 'products', productId, {'cost_minor': next, 'cost_currency': base}, now);
      }
    });
  }

  /// Products for the catalogue list, with what is on the shelf.
  Future<List<Map<String, Object?>>> listProducts(String query, {String? categoryId}) async {
    final like = '%${query.trim().replaceAll('%', '').replaceAll('_', '')}%';
    return db.query(
      'select p.id, p.name, p.sku, p.brand, p.image_ref, p.category_id, p.cost_minor, p.track_stock, p.is_active, '
      '(select pp.price_minor from product_prices pp where pp.product_id = p.id and pp.deleted_at is null and pp.tier_id is (select id from price_tiers where is_default = 1 and deleted_at is null) '
      'and pp.currency = (select base_currency from shops where deleted_at is null limit 1) order by pp.effective_from desc, pp.created_at desc limit 1) as price_minor, '
      '(select coalesce(sum(qty_milli), 0) from stock_levels l where l.product_id = p.id) as on_hand_milli, '
      "(select group_concat(barcode) from product_barcodes b where b.product_id = p.id and b.deleted_at is null) as barcodes "
      'from products p where p.deleted_at is null and (p.name like ? or p.sku like ?)${categoryId == null || categoryId.isEmpty ? '' : categoryId == noDepartment ? ' and p.category_id is null' : ' and p.category_id = ?'} order by p.name limit 200',
      [like, like, if (categoryId != null && categoryId.isNotEmpty && categoryId != noDepartment) categoryId],
    );
  }

  /// Changes the selling price of one product. The old price stays in the history.
  Future<void> setPrice(String productId, int priceMinor) async {
    if (priceMinor < 0) throw SetupError('bad_amount', 'The price must be zero or more.');
    final now = _clock();
    await db.transaction((tx) async {
      final base = (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String?;
      if (base == null) throw SetupError('shop_not_set_up', 'Set up the shop first.');
      if (await _get(tx, 'select 1 as x from products where id = ? and deleted_at is null', [productId]) == null) throw SetupError('not_found', 'That product was not found.');
      final tier = (await _get(tx, 'select id from price_tiers where is_default = 1 and deleted_at is null'))?['id'];
      final last = await _get(
        tx,
        'select price_minor from product_prices where product_id = ? and currency = ? and tier_id is ? and deleted_at is null order by effective_from desc, created_at desc limit 1',
        [productId, base, tier],
      );
      if (last == null || _i(last['price_minor']) != priceMinor) {
        await _add(tx, 'product_prices', {'product_id': productId, 'tier_id': tier, 'currency': base, 'price_minor': priceMinor, 'effective_from': now}, now, versioned: true);
      }
    });
  }

  /// The last few selling prices of a product, newest first, for the price list.
  Future<List<({int priceMinor, int since})>> priceHistory(String productId) async => [
        for (final r in await db.query(
          'select price_minor, effective_from from product_prices where product_id = ? and deleted_at is null and tier_id is (select id from price_tiers where is_default = 1 and deleted_at is null) '
          'and currency = (select base_currency from shops where deleted_at is null limit 1) order by effective_from desc, created_at desc limit 6',
          [productId],
        ))
          (priceMinor: _i(r['price_minor']), since: _i(r['effective_from'])),
      ];

  /// Quantity prices of a product in the shop's main currency, lowest quantity first.
  Future<List<({int minQtyMilli, int priceMinor})>> listBreaks(String productId) async => [
        for (final r in await db.query(
          'select min_qty_milli, price_minor from price_breaks where product_id = ? and deleted_at is null and tier_id is null '
          'and currency = (select base_currency from shops where deleted_at is null limit 1) order by min_qty_milli',
          [productId],
        ))
          (minQtyMilli: _i(r['min_qty_milli']), priceMinor: _i(r['price_minor'])),
      ];

  /// Replaces the product's quantity prices. From each quantity upwards every unit is at that price.
  Future<void> saveBreaks(String productId, List<({int minQtyMilli, int priceMinor})> breaks) async {
    if (breaks.length > 6) throw SetupError('too_many', 'Use at most 6 quantity prices.');
    final seen = <int>{};
    for (final b in breaks) {
      if (b.minQtyMilli <= 1000) throw SetupError('bad_quantity', 'A quantity price starts from 2 or more.');
      if (b.priceMinor < 0) throw SetupError('bad_amount', 'The price must be zero or more.');
      if (!seen.add(b.minQtyMilli)) throw SetupError('duplicate', 'Two quantity prices start at the same quantity.');
    }
    final now = _clock();
    await db.transaction((tx) async {
      final base = (await _get(tx, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String?;
      if (base == null) throw SetupError('shop_not_set_up', 'Set up the shop first.');
      if (await _get(tx, 'select 1 as x from products where id = ? and deleted_at is null', [productId]) == null) throw SetupError('not_found', 'That product was not found.');
      for (final r in await tx.query('select id from price_breaks where product_id = ? and currency = ? and tier_id is null and deleted_at is null', [productId, base])) {
        await _edit(tx, 'price_breaks', r['id'] as String, {'deleted_at': now}, now);
      }
      for (final b in breaks) {
        await _add(tx, 'price_breaks', {'product_id': productId, 'tier_id': null, 'currency': base, 'min_qty_milli': b.minQtyMilli, 'price_minor': b.priceMinor}, now, versioned: true);
      }
    });
  }

  Future<List<Map<String, Object?>>> taxClasses() => db.query('select id, name, rate_bp from tax_classes where deleted_at is null order by name');

  // ---- departments (categories) ----

  /// Departments in the order the shop chose, with how many products each holds.
  Future<List<Map<String, Object?>>> listCategories() => db.query(
        'select c.id, c.name, c.sort_order, '
        '(select count(*) from products p where p.category_id = c.id and p.deleted_at is null) as products '
        'from categories c where c.deleted_at is null order by c.sort_order, c.name',
      );

  /// Adds a department, or renames one when [id] is given. Names are not repeated (capital letters do not count).
  Future<String> saveCategory({String? id, required String name}) async {
    final n = _need(name, 'Enter the department name.').replaceAll(RegExp(r'\s+'), ' ');
    if (n.length > 60) throw SetupError('too_long', 'Use at most 60 characters.');
    final now = _clock();
    return db.transaction((tx) async {
      final dup = await _get(tx, 'select id from categories where deleted_at is null and lower(name) = lower(?) and id <> ?', [n, id ?? '']);
      if (dup != null) throw SetupError('duplicate_department', 'There is already a department called $n.');
      if (id != null) {
        await _edit(tx, 'categories', id, {'name': n}, now);
        return id;
      }
      final next = ((await _get(tx, 'select coalesce(max(sort_order), 0) as m from categories where deleted_at is null'))?['m'] as num? ?? 0).toInt() + 1;
      return _add(tx, 'categories', {'name': n, 'sort_order': next}, now, versioned: true);
    });
  }

  /// Removes a department. Its products stay, with no department.
  Future<void> deleteCategory(String id) async {
    final now = _clock();
    await db.transaction((tx) async {
      for (final p in await tx.query('select id from products where category_id = ? and deleted_at is null', [id])) {
        await _edit(tx, 'products', p['id'] as String, {'category_id': null}, now);
      }
      await _edit(tx, 'categories', id, {'deleted_at': now}, now);
    });
  }

  /// Adds the common departments that do not exist yet. Safe to use twice. Returns how many were added.
  Future<int> addSuggestedCategories() async {
    var added = 0;
    for (final name in suggestedDepartments) {
      try {
        await saveCategory(name: name);
        added++;
      } on SetupError catch (e) {
        if (e.code != 'duplicate_department') rethrow;
      }
    }
    return added;
  }
}

/// The cost of one item when a whole pack was bought: 12 shirts for 36.00 is 3.00 each. Rounded to the nearest cent,
/// so a pack that does not divide evenly is off by less than half a cent per item.
int unitCostFromPack(int packTotalMinor, int packQtyMilli) {
  if (packTotalMinor < 0 || packQtyMilli <= 0) throw SetupError('bad_amount', 'Enter the pack price and how many are in it.');
  return divRound(packTotalMinor * 1000, packQtyMilli);
}
