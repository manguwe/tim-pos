/// Barcodes: cleaning, check digits, finding a product from a scan, adding and removing codes, making shop codes, shelf labels.
/// Port of tools/src/barcodes.ts (read the notes at the top of that file for the rules).
library;

import 'dart:convert';
import 'dart:math';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import '../printing/receipt.dart';
import '../setup/setup_repository.dart' show SetupError;

typedef _Row = Map<String, Object?>;

String cleanBarcode(String raw) => raw.replaceAll(RegExp(r'[\s\u0000-\u001f\u007f]'), '');

/// GS1 check digit for the digits in front of it (the right-most digit of [body] gets weight 3).
int checkDigit(String body) {
  var sum = 0;
  for (var i = 0; i < body.length; i++) {
    sum += int.parse(body[body.length - 1 - i]) * (i % 2 == 0 ? 3 : 1);
  }
  return (10 - (sum % 10)) % 10;
}

enum BarcodeKind { ean13, ean8, upcA, gtin14, other }

extension BarcodeKindName on BarcodeKind {
  String get label => const {BarcodeKind.ean13: 'EAN-13', BarcodeKind.ean8: 'EAN-8', BarcodeKind.upcA: 'UPC-A', BarcodeKind.gtin14: 'GTIN-14', BarcodeKind.other: 'Other'}[this]!;
}

({BarcodeKind kind, bool valid}) describeBarcode(String code) {
  const kinds = {8: BarcodeKind.ean8, 12: BarcodeKind.upcA, 13: BarcodeKind.ean13, 14: BarcodeKind.gtin14};
  final kind = RegExp(r'^\d+$').hasMatch(code) ? kinds[code.length] : null;
  if (kind == null) return (kind: BarcodeKind.other, valid: true);
  return (kind: kind, valid: checkDigit(code.substring(0, code.length - 1)) == int.parse(code[code.length - 1]));
}

/// The code and the same number written with more or fewer leading zeros.
List<String> lookupForms(String code) {
  if (!RegExp(r'^\d{12,14}$').hasMatch(code)) return [code];
  final g14 = code.padLeft(14, '0');
  final out = <String>[code];
  for (final f in [g14, g14.substring(1), g14.substring(2)]) {
    final ok = f.length == 14 || (f.length == 13 && g14.startsWith('0')) || (f.length == 12 && g14.startsWith('00'));
    if (ok && !out.contains(f)) out.add(f);
  }
  return out;
}

String makeEan13(String body12) {
  if (!RegExp(r'^\d{12}$').hasMatch(body12)) throw SetupError('bad_barcode', 'A code body needs 12 digits.');
  return '$body12${checkDigit(body12)}';
}

enum ScanStatus { empty, unknown, inactive, error, found }

class Scan {
  const Scan(this.status, {this.code = '', this.productId, this.productName, this.barcodeId, this.qtyMilli, this.weighed = false, this.kind, this.valid = true, this.message});
  final ScanStatus status;
  final String code;
  final String? productId, productName, barcodeId, message;
  final int? qtyMilli;
  final bool weighed, valid;
  final BarcodeKind? kind;
}

class BarcodeRow {
  const BarcodeRow(this.id, this.barcode, this.kind);
  final String id, barcode;
  final BarcodeKind kind;
}

class LabelData {
  const LabelData({required this.name, this.priceText, required this.code});
  final String name, code;
  final String? priceText;
}

const int maxLabelCode = 20;

List<Item> layoutLabel(LabelData d, {required int width, int copies = 1, bool cut = true}) {
  final items = <Item>[];
  final n = copies.clamp(1, 200);
  final code = ascii(d.code);
  for (var i = 0; i < n; i++) {
    for (final l in wrap(ascii(d.name), width).take(2)) {
      items.add(Item.text(l, align: Align.center, bold: true));
    }
    if (d.priceText != null) {
      for (final l in wrap(ascii(d.priceText!), width ~/ 2).take(1)) {
        items.add(Item.text(l, align: Align.center, bold: true, big: true));
      }
    }
    if (code.length <= maxLabelCode) {
      items.add(Item.barcode(code));
    } else {
      items.add(Item.text(code.substring(0, min(code.length, width)), align: Align.center));
    }
    items.add(const Item.feed(1));
    if (cut) items.add(const Item.cut());
  }
  return items;
}

class BarcodeRepository {
  BarcodeRepository({required this.db, required this.shopId, required this.deviceId, this.userId, int Function()? clock, String Function()? idMaker})
      : _clock = clock ?? (() => DateTime.now().millisecondsSinceEpoch),
        _newId = idMaker ?? newId;

  final SqlDb db;
  final String shopId, deviceId;
  final String? userId;
  final int Function() _clock;
  final String Function() _newId;

  int _i(Object? v) => (v as num).toInt();

  Future<_Row?> _get(SqlDb tx, String sql, [List<Object?> a = const []]) async {
    final r = await tx.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  Future<void> _allow(SqlDb tx) async {
    if (userId == null) return;
    final r = await _get(tx, 'select r.permissions from users u join roles r on r.id = u.role_id where u.id = ? and u.deleted_at is null and u.is_active = 1 and r.deleted_at is null', [userId]);
    var ok = false;
    if (r != null) {
      try {
        final list = jsonDecode(r['permissions'] as String);
        ok = list is List && list.contains('product.edit');
      } on FormatException {
        ok = false;
      }
    }
    if (!ok) throw SetupError('forbidden', 'You are not allowed to change products.');
  }

  Future<String> _scalePrefix(SqlDb tx) async => ((await _get(tx, "select value from settings where scope = 'shop' and key = 'scale_prefix' and deleted_at is null"))?['value'] as String?) ?? '';

  Future<_Row?> _find(SqlDb tx, String code) async {
    final forms = lookupForms(code);
    final rows = await tx.query(
      'select b.id as barcode_id, b.barcode, p.id as product_id, p.name, p.is_active, p.base_unit_id from product_barcodes b '
      'join products p on p.id = b.product_id where b.deleted_at is null and p.deleted_at is null and b.barcode in (${List.filled(forms.length, '?').join(',')})',
      forms,
    );
    if (rows.isEmpty) return null;
    return rows.firstWhere((r) => r['barcode'] == code, orElse: () => rows.first);
  }

  /// What a scan means: a product (and a weight, for a scale label), or why not.
  Future<Scan> resolve(String raw) async {
    final code = cleanBarcode(raw);
    if (code.isEmpty) return const Scan(ScanStatus.empty);
    final hit = await _find(db, code);
    if (hit != null) {
      return hit['is_active'] == 1
          ? Scan(ScanStatus.found, code: code, productId: hit['product_id'] as String, productName: hit['name'] as String, barcodeId: hit['barcode_id'] as String)
          : Scan(ScanStatus.inactive, code: code, productId: hit['product_id'] as String, productName: hit['name'] as String);
    }
    final prefix = await _scalePrefix(db);
    if (prefix.isNotEmpty && RegExp(r'^\d{13}$').hasMatch(code) && code.startsWith(prefix) && describeBarcode(code).valid) {
      final item = await _find(db, code.substring(0, 7));
      if (item != null) {
        final name = item['name'] as String;
        if (item['is_active'] != 1) return Scan(ScanStatus.inactive, code: code, productId: item['product_id'] as String, productName: name);
        final grams = int.parse(code.substring(7, 12));
        if (grams <= 0) return Scan(ScanStatus.error, code: code, message: 'The label for $name has no weight.');
        final unit = (await _get(db, 'select code from units where id = ?', [item['base_unit_id']]))?['code'];
        final qty = unit == 'kg' ? grams : unit == 'g' ? grams * 1000 : null;
        if (qty == null) return Scan(ScanStatus.error, code: code, message: '$name is not sold by weight, so the scale label cannot be used.');
        return Scan(ScanStatus.found, code: code, productId: item['product_id'] as String, productName: name, barcodeId: item['barcode_id'] as String, qtyMilli: qty, weighed: true);
      }
    }
    final d = describeBarcode(code);
    return Scan(ScanStatus.unknown, code: code, kind: d.kind, valid: d.valid);
  }

  Future<List<BarcodeRow>> list(String productId) async {
    final rows = await db.query('select id, barcode from product_barcodes where product_id = ? and deleted_at is null order by created_at, rowid', [productId]);
    return [for (final r in rows) BarcodeRow(r['id'] as String, r['barcode'] as String, describeBarcode(r['barcode'] as String).kind)];
  }

  Future<String> _add(SqlDb tx, String table, _Row row, int now, {bool versioned = false}) async {
    final o = <String, Object?>{
      'id': _newId(), 'shop_id': shopId, 'created_at': now, 'created_by': userId, 'device_id': deviceId,
      if (versioned) ...{'updated_at': now, 'version': 1}, ...row,
    };
    final k = o.keys.toList();
    await tx.exec('insert into "$table" (${k.map((x) => '"$x"').join(', ')}) values (${List.filled(k.length, '?').join(', ')})', k.map((x) => o[x]).toList());
    return o['id']! as String;
  }

  /// Adds a code to a product. Adding one the product already has changes nothing.
  Future<({String id, bool created})> add(String productId, String raw, {bool allowInvalid = false}) async {
    final now = _clock();
    final code = cleanBarcode(raw);
    if (!RegExp(r'^[\x21-\x7E]{3,48}$').hasMatch(code)) throw SetupError('bad_barcode', 'A barcode is 3 to 48 letters or digits, with no spaces.');
    if (!describeBarcode(code).valid && !allowInvalid) throw SetupError('bad_check_digit', 'The last digit of that barcode does not fit the others. Check it, or add it anyway.');
    return db.transaction((tx) async {
      await _allow(tx);
      if (await _get(tx, 'select id from products where id = ? and deleted_at is null', [productId]) == null) throw SetupError('not_found', 'That product was not found.');
      final forms = lookupForms(code);
      final owners = await tx.query(
        'select b.id, b.product_id, p.name from product_barcodes b join products p on p.id = b.product_id where b.deleted_at is null and b.barcode in (${List.filled(forms.length, '?').join(',')})',
        forms,
      );
      for (final o in owners) {
        if (o['product_id'] != productId) throw SetupError('barcode_taken', 'That barcode already belongs to ${o['name']}.');
      }
      if (owners.isNotEmpty) return (id: owners.first['id'] as String, created: false);
      final id = await _add(tx, 'product_barcodes', {'product_id': productId, 'barcode': code}, now, versioned: true);
      await _add(tx, 'audit_log', {'user_id': userId, 'action': 'barcode_add', 'table_name': 'product_barcodes', 'row_id': id, 'after': code}, now);
      return (id: id, created: true);
    });
  }

  Future<void> remove(String barcodeId) async {
    final now = _clock();
    await db.transaction((tx) async {
      await _allow(tx);
      final b = await _get(tx, 'select barcode, version from product_barcodes where id = ? and deleted_at is null', [barcodeId]);
      if (b == null) throw SetupError('not_found', 'That barcode was not found.');
      await tx.exec('update product_barcodes set deleted_at = ?, version = ?, updated_at = ? where id = ?', [now, _i(b['version']) + 1, now, barcodeId]);
      await _add(tx, 'audit_log', {'user_id': userId, 'action': 'barcode_remove', 'table_name': 'product_barcodes', 'row_id': barcodeId, 'before': b['barcode']}, now);
    });
  }

  /// A new shop code (EAN-13, not used yet). [pick] returns a whole number from 0 to n-1.
  Future<String> newShopCode({int Function(int n)? pick}) async {
    final rnd = Random.secure();
    final p = pick ?? rnd.nextInt;
    final scale = await _scalePrefix(db);
    final prefix = ['20', '22', '23', '24', '25'].firstWhere((x) => x != scale);
    for (var i = 0; i < 100; i++) {
      var body = prefix;
      while (body.length < 12) {
        body += '${p(10)}';
      }
      final code = makeEan13(body);
      if (await _find(db, code) == null) return code;
    }
    throw SetupError('no_code', 'Could not make a new code. Try again.');
  }

  /// Makes a shop code and gives it to the product.
  Future<String> giveShopCode(String productId, {int Function(int n)? pick}) async {
    final code = await newShopCode(pick: pick);
    await add(productId, code);
    return code;
  }

  /// The label for a product: its name, its price in the shop's base currency, and the given code (or its first one).
  Future<LabelData> loadLabel(String productId, {String? code}) async {
    final now = _clock();
    final p = await _get(db, 'select name from products where id = ? and deleted_at is null', [productId]);
    if (p == null) throw SetupError('not_found', 'That product was not found.');
    final c = code != null ? cleanBarcode(code) : (await list(productId)).firstOrNull?.barcode;
    if (c == null) throw SetupError('no_barcode', 'This product has no barcode yet.');
    final base = (await _get(db, 'select base_currency from shops where deleted_at is null limit 1'))?['base_currency'] as String?;
    String? price;
    if (base != null) {
      final cur = await _get(db, 'select code, symbol, minor_units from currencies where code = ?', [base]);
      final pr = await _get(db, 'select price_minor from product_prices where product_id = ? and currency = ? and effective_from <= ? and deleted_at is null order by (tier_id is null), effective_from desc, created_at desc limit 1', [productId, base, now]);
      if (cur != null && pr != null) price = formatMoney(_i(pr['price_minor']), Money(cur['code'] as String, (cur['symbol'] as String?) ?? cur['code'] as String, _i(cur['minor_units'])));
    }
    return LabelData(name: p['name'] as String, priceText: price, code: c);
  }
}
