import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { generateKeyPair, randomSecret } from './crypto.ts';
export function generateSecrets() {
    const kp = generateKeyPair();
    return {
        licencePrivateKey: kp.privateKey,
        licencePublicKey: kp.publicKey,
        vendorTokenSecret: randomSecret(48),
        keyPepper: randomSecret(48),
    };
}
/** Secrets come from the environment. Outside production, missing ones are created once and kept in the data folder. */
export function loadConfig(env = process.env) {
    const isProd = env.NODE_ENV === 'production';
    const dataDir = env.DATA_DIR ?? './data';
    const fromEnv = {
        licencePrivateKey: env.LICENCE_PRIVATE_KEY?.replace(/\\n/g, '\n'),
        licencePublicKey: env.LICENCE_PUBLIC_KEY?.replace(/\\n/g, '\n'),
        vendorTokenSecret: env.VENDOR_TOKEN_SECRET,
        keyPepper: env.LICENCE_KEY_PEPPER,
    };
    let secrets = fromEnv;
    const complete = Object.values(fromEnv).every(Boolean);
    if (!complete) {
        if (isProd) {
            throw new Error('Missing secrets. Set LICENCE_PRIVATE_KEY, LICENCE_PUBLIC_KEY, VENDOR_TOKEN_SECRET and LICENCE_KEY_PEPPER (run "npm run -s cli -- gen-secrets").');
        }
        const file = join(dataDir, 'dev-secrets.json');
        if (existsSync(file)) {
            secrets = JSON.parse(readFileSync(file, 'utf8'));
        }
        else {
            mkdirSync(dataDir, { recursive: true, mode: 0o700 });
            secrets = generateSecrets();
            writeFileSync(file, JSON.stringify(secrets, null, 2), { mode: 0o600 });
            console.warn(`Development secrets created in ${file}. Do not use them in production.`);
        }
    }
    return {
        port: Number(env.PORT ?? 8080),
        host: env.HOST ?? '0.0.0.0',
        dbPath: env.DB_PATH ?? join(dataDir, 'tim-pos.db'),
        ...secrets,
        trustProxy: env.TRUST_PROXY === '1',
        vendorTokenTtlMs: 12 * 3600000,
        syncPageSize: 500,
        maxBatchChanges: 1000,
        maxBodyBytes: 8 * 1024 * 1024,
        log: env.LOG !== '0',
    };
}
