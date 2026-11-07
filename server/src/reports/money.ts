/**
 * Money arithmetic, all in whole numbers. Reference implementation: app/lib/selling/money.dart is a port,
 * and both are checked against the same vectors (tools/gen-selling-vectors.ts).
 *
 * Amounts are minor units (cents). Quantities are thousandths. Rates are millionths (rate_micro) or basis points (rate_bp).
 * Rounding is half away from zero, which for shop prices means "half up".
 */
export const MAX_MINOR = 10_000_000_000; // 100 million major units: far above any shop sale
export const MAX_RATE_MICRO = 100_000_000; // a currency worth up to 100 times another

export class MoneyError extends Error {
  code: string;
  constructor(code: string, message: string) { super(message); this.code = code; }
}

/** n / d rounded half away from zero. d must be positive. */
export function divRound(n: number, d: number): number {
  if (!Number.isSafeInteger(n) || !Number.isSafeInteger(d) || d <= 0) throw new MoneyError('bad_number', `cannot divide ${n} by ${d}`);
  const a = Math.abs(n);
  const q = Math.floor(a / d);
  const r = a - q * d;
  const up = r * 2 >= d ? 1 : 0;
  const v = q + up;
  return n < 0 ? -v : v;
}

function checkAmount(n: number, what: string) {
  if (!Number.isSafeInteger(n) || Math.abs(n) > MAX_MINOR) throw new MoneyError('amount_too_large', `${what} is out of range`);
}

/** Price of a quantity: qty (thousandths) times unit price, to the nearest minor unit. */
export function lineAmount(qtyMilli: number, unitPriceMinor: number): number {
  checkAmount(unitPriceMinor, 'price');
  if (!Number.isSafeInteger(qtyMilli) || Math.abs(qtyMilli) > 1_000_000_000) throw new MoneyError('amount_too_large', 'quantity is out of range');
  return divRound(qtyMilli * unitPriceMinor, 1000);
}

/** Splits a line amount into net, tax and total. Inclusive: the amount already contains tax. Exclusive: tax is added on top. */
export function taxSplit(amountMinor: number, rateBp: number, inclusive: boolean): { net: number; tax: number; total: number } {
  checkAmount(amountMinor, 'amount');
  if (!Number.isSafeInteger(rateBp) || rateBp < 0 || rateBp > 100_000) throw new MoneyError('bad_rate', 'tax rate is out of range');
  if (inclusive) {
    const net = divRound(amountMinor * 10_000, 10_000 + rateBp);
    return { net, tax: amountMinor - net, total: amountMinor };
  }
  const tax = divRound(amountMinor * rateBp, 10_000);
  return { net: amountMinor, tax, total: amountMinor + tax };
}

/**
 * Converts an amount between currencies. rateMicro is how many millionths of one `to` unit one `from` unit is worth,
 * as stored in exchange_rates (from_currency -> to_currency). minorUnits are the decimals of each currency (2 for USD and ZiG).
 */
export function convertMinor(amountMinor: number, rateMicro: number, fromMinorUnits: number, toMinorUnits: number): number {
  checkAmount(amountMinor, 'amount');
  if (!Number.isSafeInteger(rateMicro) || rateMicro <= 0 || rateMicro > MAX_RATE_MICRO) throw new MoneyError('bad_rate', 'exchange rate is out of range');
  let num = amountMinor * rateMicro;
  let den = 1_000_000;
  if (toMinorUnits >= fromMinorUnits) num *= 10 ** (toMinorUnits - fromMinorUnits);
  else den *= 10 ** (fromMinorUnits - toMinorUnits);
  if (!Number.isSafeInteger(num)) throw new MoneyError('amount_too_large', 'conversion is out of range');
  return divRound(num, den);
}

/** The rate for the opposite direction, rounded to the nearest millionth. */
export function invertRate(rateMicro: number): number {
  return divRound(1_000_000_000_000, rateMicro);
}

/** Rounds an amount down to a multiple of the smallest coin or note the shop gives change in (0 or 1 = no rounding). */
export function roundDownTo(amountMinor: number, incrementMinor: number): number {
  if (incrementMinor <= 1) return amountMinor;
  return Math.floor(amountMinor / incrementMinor) * incrementMinor;
}
