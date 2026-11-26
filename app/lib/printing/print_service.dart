import 'dart:typed_data';

import '../core/uuid7.dart';
import '../data/sql_db.dart';
import 'printer_transport.dart';
import '../shifts/shift_repository.dart' show ShiftReport;
import 'receipt.dart';
import '../barcodes/barcode_repository.dart' show LabelData, layoutLabel;
import 'slips.dart';

class SavedPrinter {
  const SavedPrinter({required this.id, required this.name, required this.address, required this.paperWidthMm, required this.opensDrawer});
  final String id;
  final String name;
  final String address;
  final int paperWidthMm;
  final bool opensDrawer;

  int get chars => paperWidthMm >= 80 ? width80 : width58;
}

/// Looks after this phone's printer and turns saved sales into paper.
class PrintService {
  PrintService({required this.db, required this.transport, required this.deviceId, this.utcOffset});
  final SqlDb db;
  final PrinterTransport transport;
  final Uuid7Generator _ids = Uuid7Generator();
  final String deviceId;

  /// Minutes east of UTC for the shop's clock; null uses the phone's own clock setting.
  final int? utcOffset;

  int get _offset => utcOffset ?? DateTime.now().timeZoneOffset.inMinutes;

  Future<SavedPrinter?> printer() async {
    final rows = await db.query('select * from printers where device_id is ? order by rowid limit 1', [deviceId]);
    if (rows.isEmpty) return null;
    final r = rows.first;
    return SavedPrinter(
      id: r['id'] as String, name: r['name'] as String, address: r['address'] as String,
      paperWidthMm: r['paper_width_mm'] as int, opensDrawer: r['opens_drawer'] == 1,
    );
  }

  /// One printer per phone: saving replaces the previous one.
  Future<void> savePrinter({required String name, required String address, required int paperWidthMm, required bool opensDrawer}) async {
    if (paperWidthMm != 58 && paperWidthMm != 80) throw ArgumentError('paper must be 58 or 80 mm');
    await db.transaction((tx) async {
      await tx.exec('delete from printers where device_id is ?', [deviceId]);
      await tx.exec(
        'insert into printers (id, device_id, name, address, paper_width_mm, opens_drawer) values (?, ?, ?, ?, ?, ?)',
        [_ids.next(), deviceId, name, address, paperWidthMm, opensDrawer ? 1 : 0],
      );
    });
  }

  Future<void> removePrinter() => db.exec('delete from printers where device_id is ?', [deviceId]);

  /// The receipt as text for the screen, at the saved paper width (58 mm when no printer is set).
  Future<String> preview(String saleId, {bool copy = false}) async {
    final p = await printer();
    final w = p?.chars ?? width58;
    final data = await loadReceipt(db, saleId, kind: copy ? 'copy' : 'sale');
    return toText(layoutReceipt(data, width: w, utcOffsetMinutes: _offset, cut: false), w);
  }

  /// The phone number and shop country for a sale's customer, so the receipt can be sent to them on WhatsApp.
  Future<({String? phone, String country})> shareTarget(String saleId) async {
    final r = await db.query(
      'select c.phone as phone from sales s left join customers c on c.id = s.customer_id where s.id = ?', [saleId]);
    final shop = await db.query('select country_code from shops where deleted_at is null limit 1');
    final phone = r.isEmpty ? null : r.first['phone'] as String?;
    return (phone: (phone ?? '').trim().isEmpty ? null : phone, country: shop.isEmpty ? 'ZW' : (shop.first['country_code'] as String? ?? 'ZW'));
  }

  /// The bytes for the printer. The drawer opens only for a first print of a sale paid with a drawer method (cash).
  Future<Uint8List> bytes(String saleId, {bool copy = false}) async {
    final p = await printer();
    final w = p?.chars ?? width58;
    final data = await loadReceipt(db, saleId, kind: copy ? 'copy' : 'sale');
    final drawer = !copy && (p?.opensDrawer ?? false) && await _paidWithDrawerMethod(saleId);
    return toEscPos(layoutReceipt(data, width: w, utcOffsetMinutes: _offset, openDrawer: drawer), w);
  }

  Future<void> print(String saleId, {bool copy = false}) async {
    final p = await printer();
    if (p == null) throw PrinterError('No printer is set up on this phone yet.');
    await transport.send(p.address, await bytes(saleId, copy: copy));
  }

  // ---- slips (cash-up, refund, payment receipt) ----

  Future<SlipData> cashUpSlip(ShiftReport r) => loadCashUpSlip(db, r, _offset);
  Future<SlipData> refundSlip(String returnId) => loadRefundSlip(db, returnId, _offset);
  Future<SlipData> paymentSlip(String paymentId) => loadPaymentSlip(db, paymentId, _offset);

  /// The slip as text for the screen, at the saved paper width.
  Future<String> slipPreview(SlipData d) async {
    final w = (await printer())?.chars ?? width58;
    return toText(layoutSlip(d, width: w, cut: false), w);
  }

  /// Prints a slip. The drawer opens only when the slip says money moved through it and the printer has a drawer.
  /// A copy never opens the drawer.
  Future<void> printSlip(SlipData d, {bool copy = false}) async {
    final p = await printer();
    if (p == null) throw PrinterError('No printer is set up on this phone yet.');
    final drawer = !copy && p.opensDrawer && d.openDrawer;
    await transport.send(p.address, toEscPos(layoutSlip(d, width: p.chars, openDrawer: drawer), p.chars));
  }

  /// Prints [copies] shelf labels (name, price, barcode), each cut off the roll.
  Future<void> printLabel(LabelData d, {int copies = 1}) async {
    final p = await printer();
    if (p == null) throw PrinterError('No printer is set up on this phone yet.');
    await transport.send(p.address, toEscPos(layoutLabel(d, width: p.chars, copies: copies), p.chars));
  }

  /// Prints a short test page so a new printer can be checked.
  Future<void> printTest() async {
    final p = await printer();
    if (p == null) throw PrinterError('No printer is set up on this phone yet.');
    final w = p.chars;
    final items = <Item>[
      const Item.text('TIM-POS', align: Align.center, bold: true, big: true),
      const Item.text('Printer test', align: Align.center),
      const Item.rule(),
      Item.text('Paper ${p.paperWidthMm} mm, $w characters'),
      Item.text(('1234567890' * 5).substring(0, w)),
      const Item.rule(),
      const Item.feed(3),
      const Item.cut(),
    ];
    await transport.send(p.address, toEscPos(items, w));
  }

  Future<bool> _paidWithDrawerMethod(String saleId) async {
    final rows = await db.query(
      'select 1 from sale_payments sp join payment_methods pm on pm.code = sp.method_code where sp.sale_id = ? and sp.is_change = 0 and pm.opens_drawer = 1 limit 1',
      [saleId],
    );
    return rows.isNotEmpty;
  }
}
