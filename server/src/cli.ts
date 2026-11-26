import { createInterface } from 'node:readline';
import { generateSecrets, loadConfig } from './config.ts';
import { rawPublicKey } from './crypto.ts';
import { makeCtx } from './context.ts';
import { openDb } from './db.ts';
import { backupNow } from './backup.ts';
import { createVendorUser } from './services/vendor.ts';

const [cmd, ...args] = process.argv.slice(2);

function flag(name: string): string | undefined {
  const i = args.indexOf(`--${name}`);
  return i >= 0 ? args[i + 1] : undefined;
}

async function readPassword(): Promise<string> {
  if (process.env.VENDOR_PASSWORD) return process.env.VENDOR_PASSWORD;
  const rl = createInterface({ input: process.stdin, output: process.stderr });
  const answer = await new Promise<string>((resolve) => rl.question('Password (at least 12 characters): ', resolve));
  rl.close();
  return answer;
}

switch (cmd) {
  case 'backup': {
    const config = loadConfig();
    const db = openDb(config.dbPath);
    const dir = flag('to') ?? config.backupDir ?? './data/backups';
    console.log(`Backup written: ${backupNow(db, dir, config.backupKeep ?? 14, Date.now())}`);
    db.close();
    break;
  }
  case 'gen-secrets': {
    const s = generateSecrets();
    const pem = (x: string) => x.trim().replace(/\n/g, '\\n');
    console.log('# Put these in the server environment. Keep LICENCE_PRIVATE_KEY secret and backed up.');
    console.log('# If it is lost, no new licence tokens can be signed. If it leaks, anyone can forge licences.');
    console.log(`LICENCE_PRIVATE_KEY="${pem(s.licencePrivateKey)}"`);
    console.log(`LICENCE_PUBLIC_KEY="${pem(s.licencePublicKey)}"`);
    console.log(`VENDOR_TOKEN_SECRET=${s.vendorTokenSecret}`);
    console.log(`LICENCE_KEY_PEPPER=${s.keyPepper}`);
    break;
  }
  case 'public-key': {
    const pem = loadConfig().licencePublicKey.trim();
    // --raw prints the 32-byte key in the form the phone app embeds.
    console.log(args.includes('--raw') ? rawPublicKey(pem) : pem);
    break;
  }
  case 'create-vendor': {
    const name = flag('name');
    const email = flag('email');
    if (!name || !email) {
      console.error('Usage: create-vendor --name "Your Name" --email you@example.com   (password via VENDOR_PASSWORD or prompt)');
      process.exit(2);
    }
    const config = loadConfig();
    const ctx = makeCtx(openDb(config.dbPath), config);
    const user = await createVendorUser(ctx, { name, email, password: await readPassword() });
    console.log(`Vendor account created for ${user.email}. Turn on two-factor sign-in after the first login.`);
    ctx.db.close();
    break;
  }
  case 'backup': {
    const file = args[0];
    if (!file) {
      console.error('Usage: backup <file>');
      process.exit(2);
    }
    const config = loadConfig();
    const db = openDb(config.dbPath);
    db.run('vacuum into ?', file);
    db.close();
    console.log(`Backup written to ${file}. Encrypt it and copy it off the server.`);
    break;
  }
  case 'reset-2fa': {
    // For a vendor who lost their authenticator, or after VENDOR_TOKEN_SECRET was changed. Needs access to the server.
    const email = flag('email');
    if (!email) {
      console.error('Usage: reset-2fa --email you@example.com');
      process.exit(2);
    }
    const config = loadConfig();
    const db = openDb(config.dbPath);
    const n = db.run(
      'update vendor_users set totp_enabled = 0, totp_secret_sealed = null, totp_pending_sealed = null, totp_last_step = 0 where email = ?',
      email.trim().toLowerCase(),
    );
    console.log(n === 1 ? 'Two-factor turned off. Sign in and set it up again.' : 'No vendor account with that email.');
    db.close();
    break;
  }
  case 'new-sync-epoch': {
    // Run this after restoring the database from a backup. Every phone then pulls again from the start.
    const config = loadConfig();
    const db = openDb(config.dbPath);
    db.run("update meta set value = lower(hex(randomblob(16))) where key = 'sync_epoch'");
    console.log('Sync epoch changed. Phones will pull again from the start the next time they sync.');
    db.close();
    break;
  }
  default:
    console.log('Commands: gen-secrets | public-key [--raw] | create-vendor --name N --email E | backup <file> | reset-2fa --email E | new-sync-epoch');
}
