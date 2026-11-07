import test from 'node:test';
import assert from 'node:assert/strict';
import { divRound, lineAmount, taxSplit, convertMinor, invertRate, roundDownTo, MoneyError } from '../src/money.ts';

test('rounding is half away from zero, for both signs', () => {
  assert.deepEqual([divRound(5, 2), divRound(-5, 2), divRound(4, 3), divRound(-4, 3), divRound(1, 2), divRound(0, 7)], [3, -3, 1, -1, 1, 0]);
});
test('quantity times price, to the nearest cent', () => {
  assert.equal(lineAmount(1_500, 199), 299); // 1.5 x 1.99 = 2.985
  assert.equal(lineAmount(333, 100), 33);
  assert.equal(lineAmount(1, 1), 0);
  assert.equal(lineAmount(500, 1), 1);
});
test('tax split always adds back to the total', () => {
  for (const [amt, bp, inc] of [[115, 1500, true], [999, 1500, true], [1, 1500, true], [100, 1500, false], [12345, 750, false], [0, 1500, true]] as const) {
    const t = taxSplit(amt, bp, inc);
    assert.equal(t.net + t.tax, t.total);
    assert.equal(inc ? t.total : t.net, amt);
  }
  assert.deepEqual(taxSplit(115, 1500, true), { net: 100, tax: 15, total: 115 });
});
test('conversion between currencies and back is stable, and rates invert', () => {
  assert.equal(convertMinor(1000, 26_500_000, 2, 2), 26_500);
  assert.equal(convertMinor(26_500, 37_736, 2, 2), 1000);
  assert.equal(convertMinor(1000, 1_000_000, 2, 0), 10, 'to a currency with no minor units');
  assert.equal(invertRate(26_500_000), 37_736);
});
test('absurd values are refused, never wrapped around', () => {
  assert.throws(() => lineAmount(1, 1e12), (e: any) => e instanceof MoneyError);
  assert.throws(() => convertMinor(1e10, 100_000_000, 2, 2), (e: any) => e.code === 'amount_too_large');
  assert.throws(() => convertMinor(100, 0, 2, 2), (e: any) => e.code === 'bad_rate');
  assert.throws(() => divRound(1.5, 2));
});
test('change rounds down to the coin', () => {
  assert.deepEqual([roundDownTo(643, 5), roundDownTo(99, 100), roundDownTo(100, 100), roundDownTo(7, 0), roundDownTo(7, 1)], [640, 0, 100, 7, 7]);
});
