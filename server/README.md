# TIM-POS server

Licensing, device activation, sync and the vendor API for TIM-POS. It needs **Node 22.18 or newer** and no npm packages at run time.

## Status

Built and tested: shop and licence management, device activation, signed offline licence tokens, suspension and device release, sync push and pull, vendor sign-in with two-factor, audit log, app release checks, backups.

The vendor web dashboard (in `../dashboard`) is built and served by this server at `/dashboard/`.

Also built: product pictures (`POST /v1/photos` and `GET /v1/photos/:name`, phone sign-in, small JPEGs only, kept per shop), shop invoices and payments, shop-owner logins with sales reports, ZIMRA fiscal logic (without signing and QR).

Not built yet: a PostgreSQL version, ZIMRA signing/QR and the secure gateway client, and loyalty.

The server stores its data in SQLite for now. The package registry was not reachable when this was written, so the PostgreSQL version in the specification is a planned step. The tables and columns are the same, and all database calls go through `src/db.ts`.

## Run it

```
npm run -s cli -- gen-secrets > secrets.env      # once; keep this file safe and backed up
set -a; . ./secrets.env; set +a
export NODE_ENV=production DATA_DIR=/var/lib/tim-pos
VENDOR_PASSWORD='a long password' npm run -s cli -- create-vendor --name "Your Name" --email you@example.com
npm start
```

Without `NODE_ENV=production`, missing secrets are created for you in `data/dev-secrets.json`. In production the server refuses to start without them.

**The licence private key is the most important secret.** If it is lost, no new licence tokens can be signed. If it leaks, anyone can forge licences. Back it up away from the server. `npm run -s cli -- public-key` prints the matching public key, which goes inside the phone app.

| Variable | Meaning |
| --- | --- |
| `PORT`, `HOST` | Where to listen. Default 8080 on all addresses. |
| `DASHBOARD_DIR` | Folder with the built dashboard. Default: `../dashboard/dist` if it exists. Empty turns the dashboard off. |
| `DATA_DIR`, `DB_PATH` | Where the database lives. Default `./data`. |
| `LICENCE_PRIVATE_KEY`, `LICENCE_PUBLIC_KEY` | Ed25519 key pair for signing licence tokens. |
| `VENDOR_TOKEN_SECRET` | Signs vendor sign-ins and encrypts two-factor secrets. Changing it signs everyone out and makes stored two-factor secrets unreadable, so run `reset-2fa` for each vendor afterwards. |
| `LICENCE_KEY_PEPPER` | Used to hash licence keys. Changing it makes every issued key stop working. |
| `TRUST_PROXY=1` | Set when running behind HTTPS proxy, so the client address comes from `X-Forwarded-For`. |

## Put HTTPS in front

Do not expose the server directly. Run it behind Caddy (see `Caddyfile.example`), which gets and renews certificates by itself, and keep port 8080 closed to the internet. A `Dockerfile` is included; it has not been built yet.

## How licensing works

1. The vendor creates a shop and a licence. The licence key is shown **once**; only a keyed hash is stored.
2. The phone sends the key and gets back a device ID, a device secret and a **signed licence token**.
3. The phone checks the token's signature offline with the public key, then works out its state with the same rules as `evaluateLicence()` in `src/licence.ts`: active, in grace, or locked.
4. Every sync refreshes the token. The token's `check_by` time forces a phone that never connects to lock after `max_offline_days`.
5. A suspended shop, a released device or a licence past its grace period gets `403` or `402` with `"locked": true`, and the app should lock at once.

The phone app should also remember the latest time it has seen, and treat a clock set backwards as a locked state. It can compare `server_time` from any reply with its own clock.

## API

Phones send `Authorization: Device <device_id>.<device_secret>`. The vendor dashboard sends `Authorization: Bearer <token>`. Request bodies may be gzip-compressed (`Content-Encoding: gzip`).

| Endpoint | Who | Purpose |
| --- | --- | --- |
| `POST /v1/activate` | phone | Activate with a licence key. Limited attempts per address. |
| `POST /v1/licence/refresh` | phone | New signed token and server time. |
| `POST /v1/sync/push` | phone | Send a batch of up to 1000 changes with a `batch_id`. Safe to resend. |
| `GET /v1/sync/pull?since=N&limit=N&epoch=E&include_own=1` | phone | Changes after cursor `N`, with the server's `epoch` in the reply. `include_own=1` is for restoring a phone. A `409` with `epoch_changed` or `cursor_ahead` means: pull again from `since=0`. |
| `GET /v1/app/update?build=N` | phone | Newest release and whether this build must update. |
| `GET /dashboard/...` | none | The web dashboard's files (see `../dashboard`). Only GET and HEAD, with a strict content-security policy. |
| `POST /v1/vendor/login` | vendor | Email, password and, once enabled, a two-factor `code`. |
| `POST /v1/vendor/2fa/setup`, `/enable` | vendor | Turn on two-factor sign-in. Replacing it later needs a current code. The new secret only takes over when `/enable` confirms it. |
| `GET /v1/vendor/overview` | vendor | Counts of shops, licences, devices, expiring and in grace. |
| `/v1/vendor/tenants`, `/plans`, `/releases`, `/audit` | vendor | Create and list shops, plans, app releases, the audit log, and shop-owner sign-in and reports (including a check that the owner's figures equal the phone's own report code on the same sales). |
| `POST /v1/vendor/tenants/:id/licences` | vendor | Issue a licence by `months` or `expires_at`. |
| `POST /v1/vendor/licences/:id/extend`, `suspend`, `resume`, `limits`, `rotate-key` | vendor | Manage a licence. |
| `POST /v1/vendor/devices/:id/release` | vendor | Remove a phone and free its slot. It is blocked from activating again unless the body says `{"block": false}`. |
| `GET`/`PUT /v1/vendor/billing/profile` | vendor | Business name, address, tax number, payment instructions, default tax and due days, number prefixes. Printed on invoices and receipts. |
| `POST /v1/vendor/tenants/:id/invoices`, `GET /v1/vendor/tenants/:id/statement` | vendor | Make an invoice for a shop (one currency, lines, tax, due date). The statement shows invoiced, paid, owed and overdue per currency. |
| `GET /v1/vendor/invoices?status=open\|overdue\|paid\|void\|all`, `GET /v1/vendor/invoices/:id` | vendor | List or read an invoice with its lines, payments and your billing details. |
| `POST /v1/vendor/invoices/:id/payments` | vendor | Record a payment (part payments allowed, overpayment refused, `request_id` makes it safe to resend). Optionally extends a licence. Numbers receipts `RCT-YYYY-0001`. |
| `POST /v1/vendor/invoices/:id/void`, `POST /v1/vendor/payments/:id/reverse` | vendor | Need a reason. Nothing is ever deleted; a void invoice or reversed payment stays on record. An invoice with live payments cannot be voided. |
| `GET /v1/vendor/payments` | vendor | Payments received, newest first. |
| `POST /v1/vendor/billing/run` | vendor | `{"month":"2026-12","dry_run":true}` previews, without `dry_run` creates one invoice per shop with an active licence on a monthly plan. Safe to run twice. |
| `GET`/`POST /v1/vendor/tenants/:id/owners`, `POST /v1/vendor/owners/:id/reset-password`, `PATCH /v1/vendor/owners/:id` | vendor | List, add, reset or turn off a shop owner's login. A new or reset login gets a one-time temporary password. |
| `POST /v1/owner/login`, `GET /v1/owner/me`, `POST /v1/owner/password` | owner | Owner sign-in (separate token from the vendor's, same attempt limits). The temporary password must be changed before any report opens. Changing it signs every other session out. |
| `GET /v1/owner/reports/:name` | owner | `summary`, `daily`, `products`, `takings`, `cash-ups` (need `from` and `to` in ms, at most 400 days), `stock`, `expiring` (`today=YYYY-MM-DD`), `receivables`, `branches`. Optional `branch_id`. An owner only ever sees their own shop. |

Errors look like `{"error": {"code": "device_limit", "message": "..."}}`.

### Sync rules

Sales, payments, stock movements, ledgers, expenses and the audit log are **append-only**: the server accepts a new row once, ignores a resend, and refuses edits and deletes. Reference data such as products, prices and customers carries a version: the higher version wins, a tie goes to the later `updated_at`, and the losing edit is kept in `sync_conflicts`. Rows that exist only on the phone (held sales, printers, stock level cache) are never accepted. The server sets `shop_id` on every row itself and rejects rows that name another shop.

## Lost or stolen phone

Release the device (it is blocked by default) and replace the licence key with `rotate-key`. The phone stays usable offline until the `check_by` time in its token, which is at most `max_offline_days` after its last sync (60 by default). For a shop that wants a shorter window, set a smaller `max_offline_days` on its licence. The app should not keep the licence key after activating.

A phone that activates again with a valid key and the same fingerprint takes over that phone's slot and locks out the old secret. That is intended for reinstalling, and it is why the key must be kept private.

## Backups

`npm run -s cli -- backup /path/backup.db` writes a consistent copy while the server is running. Encrypt it and copy it off the server on a schedule, and test a restore. Back up the secrets separately.

### Restoring from a backup

1. Stop the server, put the backup file in place as the database, and start it.
2. Run `npm run -s cli -- new-sync-epoch`.

Without step 2, a phone that had synced after the backup was made would hold a cursor the restored server has not reached, and could miss changes. With it, every phone is told to pull again from the start, and nothing it already holds is duplicated. Sales that were on phones but not in the backup are sent again at their next sync.

### Locked out of two-factor

`npm run -s cli -- reset-2fa --email you@example.com` turns it off for that account. It needs access to the server.

## Tests

`npm test` runs 99 tests covering licence rules, invoices, payments and receipts, activation limits, suspension, expiry and grace, sync (including repeated and simultaneous pushes, shop isolation, conflicts, restores and hostile input), vendor sign-in and two-factor, and the audit log.

The code was also reviewed by a separate reviewer that had not seen it being written. It found a request that could crash the server, a number that could break one shop's sync for good, batch IDs shared between phones, and several smaller sign-in and input problems. All were reproduced, fixed, and given a test. Known limits: `processed_batches` grows with every batch and needs pruning in time, and this has not been load tested or penetration tested. `npm run typecheck` needs `typescript` and `@types/node` installed.

## Owner reports: how they work

Phones sync their rows into `records`. For a report, the server loads that shop's rows into a temporary in-memory copy of the phone's own tables and runs the same report code the phone runs (`src/reports/reports.ts`), so the owner's figures always agree with the till. The copy is rebuilt only when the shop has new changes, and at most six shops are kept in memory.

`src/reports/reports.ts`, `money.ts` and `shop_schema.sql` are copies of `tools/src` and `app/assets/sql/local_schema.sql`. After changing those, run `scripts/copy-shop-schema.sh` from `server/`. A test fails if the copies drift.

This is the simple, correct first version. A shop with years of heavy trading will want typed report tables in PostgreSQL; that comes with the PostgreSQL port. Reports are only as fresh as the phones' last sync, and the pages say so.


## AI assistant
Optional, online only. See `../AI-SETUP.md`. Env: `ANTHROPIC_API_KEY`, `AI_MODEL`, `AI_MONTHLY_LIMIT`; licence feature `ai`; routes `/v1/ai/*` (phone) and `/v1/owner/ai/*` (web).

## Trials, PIN reset, backups, live rates and report messages

**10-day trial.** On a shop's page, Issue licence, tick "10-day free trial" and pick the plan you will sell. The trial has no grace period, is allowed once per shop, and is never invoiced. When the shop pays, press Convert to paid, choose the plan and the months. Nothing the shop entered is lost. On day 11 the phone shows "trial ended, your data is safe" until you convert.

**Forgotten PIN.** On the phone: choose the person, tap Forgot PIN, and send you the 8-digit number (there is a WhatsApp button). On the dashboard: shop page, Phones, PIN reset code, choose the person, type the number, read the code back. Each code only works for that person on that phone, and is logged under Activity. Check it really is the owner or manager first. The phone needs to have connected to the internet once after this update to hold its recovery key.

**Backups.** The server writes a full copy of the database into `data/backups/` at start-up and then daily, keeping the newest 14 (`BACKUP_DIR`, `BACKUP_KEEP`; `BACKUP_DIR=off` turns it off). `node src/cli.ts backup --to <folder>` makes one by hand. Copy the folder off this PC regularly (a USB drive or cloud folder): a backup on the same disk does not survive the disk. The licence signing key (`data/dev-secrets.json` in development) is copied beside the backups.

**Live exchange rates.** The server fetches daily rates from open.er-api.com (no key) and keeps the last copy, so phones can still ask when the internet is down. Phones use them in Currencies, Get live rates. The provider asks for a credit line, which the app shows.

**Report messages.** The owner chooses Report messages in the dashboard: daily or weekly, the hour, and WhatsApp or Telegram.
- Telegram is free and automatic: create a bot with @BotFather and set `TELEGRAM_BOT_TOKEN`. The owner's recipient is their Telegram chat id.
- WhatsApp sent by the server needs a Meta WhatsApp Business account, an approved message template with one text variable, and `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_ID`, `WHATSAPP_TEMPLATE` (and `WHATSAPP_LANG`). Meta may charge per message. Until that is set up, phones can still send any report on WhatsApp by hand with the green WhatsApp button on Reports.
