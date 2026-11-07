/// Slips: the cash-up slip, the refund slip and the payment receipt. Port of tools/src/slips.ts.
/// Each slip becomes plain data (money and dates already text), then one layout makes the same styled lines as a receipt.
library;

import '../data/sql_db.dart';
import '../selling/money.dart';
import '../shifts/shift_repository.dart' show ShiftReport;
import 'receipt.dart';

enum SlipKind { row, text, big, rule, gap }

class SlipLine {
  const SlipLine.row(this.l, this.r, {this.bold = false}) : kind = SlipKind.row, align = Align.left;
  const SlipLine.text(this.l, {this.align = Align.left, this.bold = false}) : kind = SlipKind.text, r = '';
  const SlipLine.big(this.l, this.r) : kind = SlipKind.big, bold = true, align = Align.left;
  const SlipLine.rule() : kind = SlipKind.rule, l = '', r = '', bold = false, align = Align.left;
  const SlipLine.gap() : kind = SlipKind.gap, l = '', r = '', bold = false, align = Align.left;
  final SlipKind kind;
  final String l, r;
  final bool bold;
  final Align align;
}

class SlipData {
  SlipData({required this.shopName, this.branchName, this.branchAddress, this.branchPhone, required this.title});
  final String shopName;
  final String? branchName, branchAddress, branchPhone;
  final String title;
  final List<SlipLine> lines = [];
  List<String> signatures = [];
  String? footer;
  bool openDrawer = false;
}

bool _has(String? s) => s != null && s.isNotEmpty;

List<Item> layoutSlip(SlipData d, {required int width, bool openDrawer = false, bool cut = true}) {
  final w = width;
  final items = <Item>[];
  void text(String s, {Align align = Align.left, bool bold = false, bool big = false}) {
    for (final l in wrap(s, big ? w ~/ 2 : w)) {
      items.add(Item.text(l, align: align, bold: bold, big: big));
    }
  }

  void rows(String l, String r, {bool bold = false}) {
    for (final s in row(l, r, w)) {
      items.add(Item.text(s, bold: bold));
    }
  }

  if (openDrawer) items.add(const Item.drawer());
  text(d.shopName, align: Align.center, bold: true, big: true);
  if (_has(d.branchName)) text(d.branchName!, align: Align.center);
  if (_has(d.branchAddress)) text(d.branchAddress!, align: Align.center);
  if (_has(d.branchPhone)) text('Tel ${d.branchPhone}', align: Align.center);
  items.add(const Item.rule());
  text(d.title, align: Align.center, bold: true);
  items.add(const Item.rule());
  for (final l in d.lines) {
    switch (l.kind) {
      case SlipKind.row:
        rows(l.l, l.r, bold: l.bold);
      case SlipKind.text:
        text(l.l, align: l.align, bold: l.bold);
      case SlipKind.big:
        for (final s in row(l.l, l.r, w ~/ 2)) {
          items.add(Item.text(s, bold: true, big: true));
        }
      case SlipKind.rule:
        items.add(const Item.rule());
      case SlipKind.gap:
        items.add(const Item.feed(1));
    }
  }
  for (final s in d.signatures) {
    items.add(const Item.feed(2));
    items.add(Item.text('_' * (w * 2 ~/ 3)));
    text(s);
  }
  if (_has(d.footer)) {
    items.add(const Item.rule());
    text(d.footer!, align: Align.center);
  }
  items.add(const Item.feed(3));
  if (cut) items.add(const Item.cut());
  return items;
}

// ---- reading saved records ----

typedef _Row = Map<String, Object?>;
int _i(Object? v) => (v as num).toInt();

class _Ctx {
  _Ctx(this.db, this.shop, this.branch, this.cur, this.names);
  final SqlDb db;
  final _Row shop;
  final _Row? branch;
  final Map<String, Money> cur;
  final Map<String, String> names;

  Future<_Row?> get(String sql, [List<Object?> a = const []]) async {
    final r = await db.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  String money(int minor, String code) => formatMoney(minor, cur[code] ?? Money(code, code, 2));
  Future<String?> userName(Object? id) async => id == null ? null : (await get('select name from users where id = ?', [id]))?['name'] as String?;
  Future<String?> footer() async => (await get("select value from settings where scope = 'shop' and key = 'receipt_footer' and deleted_at is null"))?['value'] as String?;
  SlipData base(String title) => SlipData(
        shopName: (shop['name'] as String?) ?? '', branchName: branch?['name'] as String?, branchAddress: branch?['address'] as String?,
        branchPhone: branch?['phone'] as String?, title: title);
}

Future<_Ctx> _context(SqlDb db, String? branchId) async {
  Future<_Row?> get(String sql, [List<Object?> a = const []]) async {
    final r = await db.query(sql, a);
    return r.isEmpty ? null : r.first;
  }

  final cur = <String, Money>{
    for (final c in await db.query('select code, symbol, minor_units from currencies')) c['code'] as String: Money(c['code'] as String, (c['symbol'] as String?) ?? c['code'] as String, _i(c['minor_units'])),
  };
  return _Ctx(
    db, await get('select * from shops where deleted_at is null limit 1') ?? <String, Object?>{}, branchId == null ? null : await get('select * from branches where id = ?', [branchId]), cur,
    {for (final m in await db.query('select code, name from payment_methods')) m['code'] as String: m['name'] as String},
  );
}

String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '');

/// The slip printed when a shift is closed (or the figures of a shift still open). `r` comes from ShiftRepository.report.
Future<SlipData> loadCashUpSlip(SqlDb db, ShiftReport r, int offsetMin) async {
  final sh = await db.query('select branch_id from shifts where id = ?', [r.shiftId]);
  if (sh.isEmpty) throw StateError('shift not found');
  final c = await _context(db, sh.first['branch_id'] as String?);
  final d = c.base(r.status == 'closed' ? 'CASH-UP' : 'CASH-UP (shift still open)');
  final L = d.lines;
  if (r.user != null) L.add(SlipLine.row('Cashier', r.user!));
  L.add(SlipLine.row('Opened', dateText(r.openedAt, offsetMin)));
  if (r.closedAt != null) L.add(SlipLine.row('Closed', dateText(r.closedAt!, offsetMin)));
  L.add(const SlipLine.rule());
  L.add(SlipLine.row('Sales', '${r.sales}', bold: true));
  if (r.voided > 0) L.add(SlipLine.row('Voided sales', '${r.voided}'));
  for (final e in r.sold.entries) {
    L.add(SlipLine.row('  Sold ${e.key}', c.money(e.value, e.key)));
  }
  if (r.takings.isNotEmpty) {
    L.add(const SlipLine.rule());
    L.add(const SlipLine.text('Money received', bold: true));
    for (final t in r.takings) {
      L.add(SlipLine.row('  ${t.method} ${t.currency}', c.money(t.amountMinor, t.currency)));
    }
  }
  if (r.refunds.isNotEmpty) {
    L.add(const SlipLine.rule());
    L.add(const SlipLine.text('Paid back to customers', bold: true));
    for (final t in r.refunds) {
      L.add(SlipLine.row('  ${t.method} ${t.currency}', c.money(t.amountMinor, t.currency)));
    }
  }
  if (r.events.isNotEmpty) {
    L.add(const SlipLine.rule());
    L.add(const SlipLine.text('Cash in and out', bold: true));
    for (final e in r.events) {
      final label = e.type == 'cash_in' ? 'Cash in' : e.type == 'cash_out' ? 'Cash out' : 'Bank drop';
      L.add(SlipLine.row('  $label ${e.currency}', c.money(e.amountMinor, e.currency)));
      if (_has(e.reason)) L.add(SlipLine.text('    ${e.reason}'));
    }
  }
  for (final code in r.float.keys) {
    L.add(const SlipLine.rule());
    L.add(SlipLine.text('Cash drawer $code', bold: true));
    L.add(SlipLine.row('  Opening float', c.money(r.float[code]!, code)));
    L.add(SlipLine.row('  Should be', c.money(r.expected[code] ?? 0, code)));
    final counted = r.counted[code];
    if (counted != null) {
      final diff = r.difference[code] ?? 0;
      L.add(SlipLine.row('  Counted', c.money(counted, code)));
      L.add(SlipLine.row(diff == 0 ? '  Correct' : diff > 0 ? '  OVER by' : '  SHORT by', diff == 0 ? 'OK' : c.money(diff.abs(), code), bold: true));
    }
  }
  d.signatures = ['Cashier', 'Checked by'];
  return d;
}

/// The slip for a return or a void.
Future<SlipData> loadRefundSlip(SqlDb db, String returnId, int offsetMin) async {
  final rr = await db.query('select * from sale_returns where id = ?', [returnId]);
  if (rr.isEmpty) throw StateError('return not found');
  final ret = rr.first;
  final sale = (await db.query('select * from sales where id = ?', [ret['original_sale_id']])).first;
  final c = await _context(db, sale['branch_id'] as String?);
  final cur = ret['refund_currency'] as String;
  final isVoid = ret['kind'] == 'void';
  final d = c.base(isVoid ? 'SALE VOIDED' : 'REFUND / RETURN');
  final L = d.lines;
  L.add(SlipLine.row(isVoid ? 'Void no' : 'Refund no', ret['receipt_no'] as String, bold: true));
  L.add(SlipLine.row('Original receipt', sale['receipt_no'] as String));
  L.add(SlipLine.row('Date', dateText(_i(ret['created_at']), offsetMin)));
  final by = await c.userName(ret['created_by']);
  if (by != null) L.add(SlipLine.row('Cashier', by));
  final appr = await c.userName(ret['approved_by']);
  if (appr != null) L.add(SlipLine.row('Approved by', appr));
  final custId = sale['customer_id'];
  final cust = custId == null ? null : (await c.get('select name from customers where id = ?', [custId]))?['name'] as String?;
  if (cust != null) L.add(SlipLine.row('Customer', cust));
  L.add(const SlipLine.rule());
  for (final it in await db.query('select rl.qty_milli, rl.amount_minor, sl.description from sale_return_lines rl join sale_lines sl on sl.id = rl.sale_line_id where rl.return_id = ? order by rl.created_at, rl.rowid', [returnId])) {
    L.add(SlipLine.text((it['description'] as String?) ?? ''));
    L.add(SlipLine.row('  Qty ${_qty(_i(it['qty_milli']))}', c.money(it['amount_minor'] == null ? 0 : _i(it['amount_minor']), cur)));
  }
  L.add(const SlipLine.rule());
  L.add(SlipLine.big('VALUE', c.money(ret['refund_minor'] == null ? 0 : _i(ret['refund_minor']), cur)));
  final pays = await db.query('select * from return_payouts where return_id = ? order by created_at, rowid', [returnId]);
  if (pays.isNotEmpty) {
    L.add(const SlipLine.rule());
    L.add(const SlipLine.text('Paid back', bold: true));
    for (final p in pays) {
      L.add(SlipLine.row('  ${c.names[p['method_code']] ?? p['method_code']} ${p['currency']}', c.money(_i(p['amount_minor']), p['currency'] as String)));
      final ref = p['reference'] as String?;
      if (_has(ref)) L.add(SlipLine.text('    Ref $ref'));
    }
  }
  final credit = -_i((await c.get("select coalesce(sum(amount_minor), 0) as s from customer_ledger where ref_type = 'return' and ref_id = ?", [returnId]))!['s']);
  if (credit > 0) {
    L.add(const SlipLine.rule());
    L.add(SlipLine.row('Taken off account', c.money(credit, cur), bold: true));
  }
  final reason = ret['reason'] as String?;
  if (_has(reason)) {
    L.add(const SlipLine.rule());
    L.add(SlipLine.text('Reason: $reason'));
  }
  var drawer = false;
  for (final p in pays) {
    if ((await c.get('select opens_drawer from payment_methods where code = ?', [p['method_code']]))?['opens_drawer'] == 1) drawer = true;
  }
  d.openDrawer = drawer;
  d.signatures = ['Customer signature'];
  d.footer = await c.footer();
  return d;
}

/// The receipt for money received after the sale: an account payment, or a layby instalment.
Future<SlipData> loadPaymentSlip(SqlDb db, String paymentId, int offsetMin) async {
  final pr = await db.query('select rowid as rid, * from account_payments where id = ?', [paymentId]);
  if (pr.isEmpty) throw StateError('payment not found');
  final p = pr.first;
  final saleId = p['sale_id'] as String?;
  final sale = saleId == null ? null : (await db.query('select * from sales where id = ?', [saleId])).first;
  String? branchId = sale?['branch_id'] as String?;
  if (branchId == null) {
    final uid = p['user_id'];
    if (uid != null) {
      final ub = await db.query('select branch_id from user_branches where user_id = ? and deleted_at is null limit 1', [uid]);
      if (ub.isNotEmpty) branchId = ub.first['branch_id'] as String?;
    }
    if (branchId == null) {
      final b = await db.query('select id from branches where deleted_at is null order by created_at limit 1');
      if (b.isNotEmpty) branchId = b.first['id'] as String?;
    }
  }
  final c = await _context(db, branchId);
  final d = c.base(sale != null ? 'LAYBY PAYMENT' : 'PAYMENT RECEIVED');
  final L = d.lines;
  final tgt = p['target_currency'] as String;
  final curr = p['currency'] as String;
  L.add(SlipLine.row('Receipt', p['receipt_no'] as String, bold: true));
  L.add(SlipLine.row('Date', dateText(_i(p['created_at']), offsetMin)));
  final by = await c.userName(p['user_id']);
  if (by != null) L.add(SlipLine.row('Cashier', by));
  final cust = (await c.get('select name from customers where id = ?', [p['customer_id']]))?['name'] as String?;
  if (cust != null) L.add(SlipLine.row('Customer', cust));
  if (sale != null) L.add(SlipLine.row('Layby sale', sale['receipt_no'] as String));
  L.add(const SlipLine.rule());
  final method = c.names[p['method_code']] ?? p['method_code'] as String;
  L.add(SlipLine.big('PAID', c.money(_i(p['amount_minor']), curr)));
  L.add(SlipLine.row(curr == tgt ? method : '$method $curr', c.money(_i(p['amount_minor']), curr)));
  final ref = p['reference'] as String?;
  if (_has(ref)) L.add(SlipLine.text('  Ref $ref'));
  if (curr != tgt) L.add(SlipLine.row('Counted as', c.money(_i(p['applied_minor']), tgt)));
  int after;
  if (sale != null) {
    final later = _i((await c.get('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ? and rowid > ?', [saleId, p['rid']]))!['s']);
    after = _i(sale['total_minor']) - (await _laybyPaid(c, saleId!, sale['sale_currency'] as String) - later);
    if (after < 0) after = 0;
  } else {
    final led = await c.get("select rowid as rid from customer_ledger where ref_type = 'account_payment' and ref_id = ?", [paymentId]);
    after = _i((await c.get('select coalesce(sum(amount_minor), 0) as s from customer_ledger where customer_id = ? and currency = ? and rowid <= ?', [p['customer_id'], tgt, led == null ? 0x7fffffff : led['rid']]))!['s']);
  }
  L.add(const SlipLine.rule());
  L.add(SlipLine.row(sale != null ? 'Balance on layby' : 'Balance owing', c.money(after < 0 ? 0 : after, tgt), bold: true));
  d.openDrawer = (await c.get('select opens_drawer from payment_methods where code = ?', [p['method_code']]))?['opens_drawer'] == 1;
  d.footer = await c.footer();
  return d;
}

Future<int> _laybyPaid(_Ctx c, String saleId, String saleCurrency) async {
  var paid = 0;
  for (final p in await c.db.query('select currency, amount_minor, rate_to_sale_micro, is_change from sale_payments where sale_id = ?', [saleId])) {
    final code = p['currency'] as String;
    final v = code == saleCurrency
        ? _i(p['amount_minor'])
        : convertMinor(_i(p['amount_minor']), _i(p['rate_to_sale_micro']), (c.cur[code] ?? Money(code, code, 2)).minorUnits, (c.cur[saleCurrency] ?? Money(saleCurrency, saleCurrency, 2)).minorUnits);
    paid += p['is_change'] == 1 ? -v : v;
  }
  final inst = await c.get('select coalesce(sum(applied_minor), 0) as s from account_payments where sale_id = ?', [saleId]);
  return paid + _i(inst!['s']);
}
