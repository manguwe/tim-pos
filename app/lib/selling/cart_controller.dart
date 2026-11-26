import 'package:flutter/foundation.dart';

import 'catalog.dart';
import 'money.dart';
import 'selling.dart';

class CartItem {
  CartItem({required this.hit, required this.qtyMilli, this.discountMinor = 0});
  final ProductHit hit;
  int qtyMilli;
  int discountMinor;

  int get unitPrice => hit.unitPriceFor(qtyMilli) ?? 0;
  int get gross => lineAmount(qtyMilli, unitPrice);
  TaxSplit get split => taxSplit(gross - discountMinor, hit.taxRateBp, hit.taxInclusive);
}

/// The cart on the till. It only previews totals as the cashier works; the selling engine recalculates and saves the real sale.
class CartController extends ChangeNotifier {
  CartController({required this.engine, required this.catalog, required this.setup, this.userId})
      : _currency = setup.baseCurrency;

  final SellingEngine engine;
  final CatalogRepository catalog;
  final TillSetup setup;
  final String? userId;

  final List<CartItem> items = [];
  final List<CartPayment> payments = [];
  String _currency;
  bool busy = false;
  String? error;
  SaleResult? lastSale;

  /// How the sale is settled: 'full' (paid now), 'account' (the rest goes on the customer's account) or 'layby' (deposit now, goods held).
  String mode = 'full';

  /// The cashier's open shift; set by the till screen. Sales are tied to it so the cash-up can count them.
  String? shiftId;
  String? customerId;
  String? customerName;

  void setCustomer(String? id, String? name) {
    customerId = id;
    customerName = name;
    if (id == null) mode = 'full';
    notifyListeners();
  }

  void setMode(String m) {
    mode = customerId == null ? 'full' : m;
    notifyListeners();
  }

  /// Whether the Complete button may be pressed. Account sales may be unpaid; a layby needs some deposit.
  bool get canComplete {
    if (items.isEmpty) return false;
    if (mode == 'account') return customerId != null;
    if (mode == 'layby') return customerId != null && payments.isNotEmpty;
    return due <= 0;
  }

  String get currency => _currency;
  CurrencyInfo get cur => setup.currency(_currency);

  int get total => items.fold(0, (s, i) => s + i.split.total);
  int get tax => items.fold(0, (s, i) => s + i.split.tax);
  int get discount => items.fold(0, (s, i) => s + i.discountMinor);

  /// Payments counted in the sale currency (needs the same rates the engine will use, so this is an estimate until saved).
  int paidInSaleCurrency = 0;
  int get due => total - paidInSaleCurrency;

  /// Changing currency re-prices the cart, so it clears payments.
  Future<void> setCurrency(String code) async {
    if (code == _currency) return;
    _currency = code;
    payments.clear();
    paidInSaleCurrency = 0;
    for (final i in List.of(items)) {
      final fresh = await catalog.search(i.hit.sku ?? i.hit.name, branchId: setup.branchId, currency: code);
      final match = fresh.where((h) => h.id == i.hit.id);
      if (match.isEmpty || !match.first.canSell) {
        items.remove(i);
        error = '${i.hit.name} has no price in $code and was removed.';
      } else {
        items[items.indexOf(i)] = CartItem(hit: match.first, qtyMilli: i.qtyMilli, discountMinor: 0);
      }
    }
    notifyListeners();
  }

  /// Adds one unit, or [qtyMilli]. Returns false (and sets [error]) if it cannot be sold.
  bool add(ProductHit hit, {int qtyMilli = 1000}) {
    error = null;
    if (!hit.canSell) {
      error = '${hit.name} has no price in $_currency.';
      notifyListeners();
      return false;
    }
    final existing = items.where((i) => i.hit.id == hit.id).firstOrNull;
    final want = (existing?.qtyMilli ?? 0) + qtyMilli;
    if (hit.tracksStock && !hit.allowNegative && want > hit.onHandMilli) {
      error = 'Only ${_qty(hit.onHandMilli)} of ${hit.name} left.';
      notifyListeners();
      return false;
    }
    if (existing != null) {
      existing.qtyMilli = want;
    } else {
      items.add(CartItem(hit: hit, qtyMilli: qtyMilli));
    }
    _paymentsChanged();
    return true;
  }

  void setQty(CartItem item, int qtyMilli) {
    if (qtyMilli <= 0) {
      items.remove(item);
    } else if (!(item.hit.tracksStock && !item.hit.allowNegative && qtyMilli > item.hit.onHandMilli)) {
      item.qtyMilli = qtyMilli;
      error = null;
    } else {
      error = 'Only ${_qty(item.hit.onHandMilli)} of ${item.hit.name} left.';
    }
    _paymentsChanged();
  }

  void remove(CartItem item) {
    items.remove(item);
    _paymentsChanged();
  }

  void clear() {
    items.clear();
    payments.clear();
    paidInSaleCurrency = 0;
    error = null;
    notifyListeners();
  }

  void _paymentsChanged() => notifyListeners();

  String _qty(int milli) => milli % 1000 == 0 ? '${milli ~/ 1000}' : (milli / 1000).toStringAsFixed(3);

  /// Adds a payment part. [creditedInSaleCurrency] is what it is worth in the sale currency, for the "still to pay" figure.
  void addPayment(CartPayment p, {required int creditedInSaleCurrency}) {
    payments.add(p);
    paidInSaleCurrency += creditedInSaleCurrency;
    notifyListeners();
  }

  void clearPayments() {
    payments.clear();
    paidInSaleCurrency = 0;
    notifyListeners();
  }

  /// Saves the sale. On success the cart is emptied and [lastSale] holds the receipt details.
  Future<bool> checkout({String? changeCurrency, String? approvedBy}) async {
    if (busy || items.isEmpty) return false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      lastSale = await engine.sell(Cart(
        branchId: setup.branchId,
        userId: userId,
        shiftId: shiftId,
        saleCurrency: _currency,
        customerId: customerId,
        onCredit: mode == 'account',
        layby: mode == 'layby',
        changeCurrency: changeCurrency,
        approvedBy: approvedBy,
        lines: [for (final i in items) CartLine(productId: i.hit.id, qtyMilli: i.qtyMilli, discountMinor: i.discountMinor)],
        payments: List.of(payments),
      ));
      items.clear();
      payments.clear();
      paidInSaleCurrency = 0;
      customerId = null;
      customerName = null;
      mode = 'full';
      return true;
    } on SaleError catch (e) {
      error = e.message;
      return false;
    } finally {
      busy = false;
      notifyListeners();
    }
  }
}
