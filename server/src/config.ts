import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { generateKeyPair, randomSecret } from './crypto.ts';

export interface Config {
  port: number;
  host: string;
  dbPath: string;
  licencePrivateKey: string;
  licencePublicKey: string;
  vendorTokenSecret: string;
  keyPepper: string;
  trustProxy: boolean;
  vendorTokenTtlMs: number;
  syncPageSize: number;
  maxBatchChanges: number;
  maxBodyBytes: number;
  log: boolean;
  /** Folder with the built web dashboard (dashboard/dist). Empty means the server does not serve one. */
  dashboardDir?: string | null;
}

interface Secrets {
  licencePrivateKey: string;
  licencePublicKey: string;
  vendorTokenSecret: string;
  keyPepper: string;
}

export function generateSecrets(): Secrets {
  const kp = generateKeyPair();
  return {
    licencePrivateKey: kp.privateKey,
    licencePublicKey: kp.publicKey,
    vendorTokenSecret: randomSecret(48),
    keyPepper: randomSecret(48),
  };
}

function dashboardDir(env: NodeJS.ProcessEnv): string | null {
  if (env.DASHBOARD_DIR !== undefined) return env.DASHBOARD_DIR === '' ? null : env.DASHBOARD_DIR;
  const guess = fileURLToPath(new URL('../../dashboard/dist', import.meta.url)); // next to the server in the project folder
  return existsSync(join(guess, 'index.html')) ? guess : null;
}

/** Secrets come from the environment. Outside production, missing ones are created once and kept in the data folder. */
export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const isProd = env.NODE_ENV === 'production';
  const dataDir = env.DATA_DIR ?? './data';
  const fromEnv: Partial<Secrets> = {
    licencePrivateKey: env.LICENCE_PRIVATE_KEY?.replace(/\\n/g, '\n'),
    licencePublicKey: env.LICENCE_PUBLIC_KEY?.replace(/\\n/g, '\n'),
    vendorTokenSecret: env.VENDOR_TOKEN_SECRET,
    keyPepper: env.LICENCE_KEY_PEPPER,
  };
  let secrets = fromEnv as Secrets;
  const complete = Object.values(fromEnv).every(Boolean);
  if (!complete) {
    if (isProd) {
      throw new Error(
        'Missing secrets. Set LICENCE_PRIVATE_KEY, LICENCE_PUBLIC_KEY, VENDOR_TOKEN_SECRET and LICENCE_KEY_PEPPER (run "npm run -s cli -- gen-secrets").',
      );
    }
    const file = join(dataDir, 'dev-secrets.json');
    if (existsSync(file)) {
      secrets = JSON.parse(readFileSync(file, 'utf8')) as Secrets;
    } else {
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
    vendorTokenTtlMs: 12 * 3_600_000,
    syncPageSize: 500,
    maxBatchChanges: 1000,
    maxBodyBytes: 8 * 1024 * 1024,
    log: env.LOG !== '0',
    dashboardDir: dashboardDir(env),
  };
}
