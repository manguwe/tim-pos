/// Money arithmetic in whole numbers. Port of tools/src/money.ts; both are checked against the same vectors.
/// Amounts are minor units (cents), quantities thousandths, rates millionths (rate_micro) or basis points (rate_bp).
library;

const int maxMinor = 10000000000;
const int maxRateMicro = 100000000;

class MoneyError implements Exception {
  MoneyError(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'MoneyError($code): $message';
}

/// n / d rounded half away from zero. d must be positive.
int divRound(int n, int d) {
  if (d <= 0) throw MoneyError('bad_number', 'cannot divide $n by $d');
  final a = n.abs();
  final q = a ~/ d;
  final r = a - q * d;
  final v = q + (r * 2 >= d ? 1 : 0);
  return n < 0 ? -v : v;
}

void _checkAmount(int n, String what) {
  if (n.abs() > maxMinor) throw MoneyError('amount_too_large', '$what is out of range');
}

int lineAmount(int qtyMilli, int unitPriceMinor) {
  _checkAmount(unitPriceMinor, 'price');
  if (qtyMilli.abs() > 1000000000) throw MoneyError('amount_too_large', 'quantity is out of range');
  return divRound(qtyMilli * unitPriceMinor, 1000);
}

class TaxSplit {
  const TaxSplit(this.net, this.tax, this.total);
  final int net, tax, total;
}

TaxSplit taxSplit(int amountMinor, int rateBp, bool inclusive) {
  _checkAmount(amountMinor, 'amount');
  if (rateBp < 0 || rateBp > 100000) throw MoneyError('bad_rate', 'tax rate is out of range');
  if (inclusive) {
    final net = divRound(amountMinor * 10000, 10000 + rateBp);
    return TaxSplit(net, amountMinor - net, amountMinor);
  }
  final tax = divRound(amountMinor * rateBp, 10000);
  return TaxSplit(amountMinor, tax, amountMinor + tax);
}

int _pow10(int n) {
  var r = 1;
  for (var i = 0; i < n; i++) {
    r *= 10;
  }
  return r;
}

int convertMinor(int amountMinor, int rateMicro, int fromMinorUnits, int toMinorUnits) {
  _checkAmount(amountMinor, 'amount');
  if (rateMicro <= 0 || rateMicro > maxRateMicro) throw MoneyError('bad_rate', 'exchange rate is out of range');
  var num = amountMinor * rateMicro;
  var den = 1000000;
  if (toMinorUnits >= fromMinorUnits) {
    num *= _pow10(toMinorUnits - fromMinorUnits);
  } else {
    den *= _pow10(fromMinorUnits - toMinorUnits);
  }
  return divRound(num, den);
}

int invertRate(int rateMicro) => divRound(1000000000000, rateMicro);

int roundDownTo(int amountMinor, int incrementMinor) {
  if (incrementMinor <= 1) return amountMinor;
  return (amountMinor / incrementMinor).floor() * incrementMinor;
}
