/** PIN hash vectors made by the reference code (node crypto PBKDF2), so the Dart code can be proven to agree.  ->  app/test/fixtures/auth_vectors.json */
import { mkdirSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { hashPin, validatePin, lockDuration } from './src/auth.ts';

const salts = ['AAAAAAAAAAAAAAAAAAAAAA==', 'q83vASNFZ4mrze8BI0Vniw==', '/////////////////////w=='];
const cases: unknown[] = [];
for (const [pin, saltB64, iterations] of [['2580', salts[0]!, 1], ['2580', salts[1]!, 10_000], ['7391', salts[2]!, 10_000], ['12345679', salts[1]!, 2], ['9081', salts[0]!, 10_000]] as const) {
  cases.push({ pin, iterations, stored: hashPin(pin, Buffer.from(saltB64, 'base64'), iterations) });
}
const out = {
  hashes: cases,
  pins: Object.fromEntries(['', '123', '123456789', 'abcd', '1111', '0000', '1234', '4321', '56789', '98765', '12 4', '2580', '1357', '9081', '112233', '12345679'].map((p) => [p, validatePin(p) === null])),
  lock: [0, 1, 4, 5, 6, 7, 8, 12, 30].map((f) => ({ failed: f, ms: lockDuration(f) })),
};
const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'app', 'test', 'fixtures');
mkdirSync(dir, { recursive: true });
writeFileSync(join(dir, 'auth_vectors.json'), JSON.stringify(out, null, 1) + '\n');
console.log('wrote auth vectors');
