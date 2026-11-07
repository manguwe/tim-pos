/** Test vectors for the Dart money code, made by the TypeScript reference.  ->  app/test/fixtures/money_vectors.json */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { divRound, lineAmount, taxSplit, convertMinor, invertRate, roundDownTo } from './src/money.ts';

const nums = [0, 1, 2, 3, 5, 7, 99, 100, 101, 115, 199, 999, 1234, 12345, 99999, 1_000_000];
const out = {
  div_round: [] as unknown[], line_amount: [] as unknown[], tax_split: [] as unknown[], convert: [] as unknown[], invert: [] as unknown[], round_down: [] as unknown[],
};
for (const n of [...nums, ...nums.map((x) => -x)]) for (const d of [1, 2, 3, 7, 1000, 10_000]) out.div_round.push({ n, d, r: divRound(n, d) });
for (const q of [1, 333, 500, 1000, 1500, 2750, 100_000]) for (const p of [1, 99, 100, 199, 12_345]) out.line_amount.push({ qty: q, price: p, r: lineAmount(q, p) });
for (const a of [0, 1, 99, 115, 999, 12_345]) for (const bp of [0, 750, 1500]) for (const inc of [true, false]) out.tax_split.push({ amount: a, bp, inclusive: inc, r: taxSplit(a, bp, inc) });
for (const a of [1, 99, 1000, 26_500, 123_456]) for (const [rate, f, t] of [[26_500_000, 2, 2], [37_736, 2, 2], [1_000_000, 2, 0], [1_000_000, 0, 2], [18_500_000, 2, 2]] as const) out.convert.push({ amount: a, rate, from: f, to: t, r: convertMinor(a, rate, f, t) });
for (const r of [26_500_000, 37_736, 1_000_000, 18_500_000, 3]) out.invert.push({ rate: r, r: invertRate(r) });
for (const a of [0, 4, 5, 643, 99, 100, 101]) for (const i of [0, 1, 5, 100]) out.round_down.push({ amount: a, inc: i, r: roundDownTo(a, i) });
const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'test', 'fixtures');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'money_vectors.json'), JSON.stringify(out) + '\n');
console.log('wrote money vectors');
