import 'dart:convert';

import '../auth/auth_repository.dart' show defaultRoles, hashPin, roleNames, validatePin;
import '../core/uuid7.dart';
import '../data/sql_db.dart';

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
  });
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
  Future<({bool created, String? ownerId})> seedShop({required String name, required String countryCode, String? branchName, bool taxRegistered = false, String? taxNumber, String? ownerName, String? ownerPin}) async {
    final shopName = _need(name, 'Enter the shop name.');
    final preset = presets[countryCode.toUpperCase()];
    if (preset == null) throw SetupError('unknown_country', 'That country has no preset yet.');
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
        'id': shopId, 'name': shopName, 'country_code': countryCode.toUpperCase(), 'base_currency': preset.baseCurrency,
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
  Future<List<Map<String, Object?>>> listProducts(String query) async {
    final like = '%${query.trim().replaceAll('%', '').replaceAll('_', '')}%';
    return db.query(
      'select p.id, p.name, p.sku, p.brand, p.image_ref, p.cost_minor, p.track_stock, p.is_active, '
      '(select pp.price_minor from product_prices pp where pp.product_id = p.id and pp.deleted_at is null and pp.tier_id is (select id from price_tiers where is_default = 1 and deleted_at is null) '
      'and pp.currency = (select base_currency from shops where deleted_at is null limit 1) order by pp.effective_from desc, pp.created_at desc limit 1) as price_minor, '
      '(select coalesce(sum(qty_milli), 0) from stock_levels l where l.product_id = p.id) as on_hand_milli, '
      "(select group_concat(barcode) from product_barcodes b where b.product_id = p.id and b.deleted_at is null) as barcodes "
      'from products p where p.deleted_at is null and (p.name like ? or p.sku like ?) order by p.name limit 200',
      [like, like],
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

  Future<List<Map<String, Object?>>> taxClasses() => db.query('select id, name, rate_bp from tax_classes where deleted_at is null order by name');
}
