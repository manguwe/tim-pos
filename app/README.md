# TIM-POS phone app (Flutter)

This folder holds everything that is app-specific: the Dart code, the database schema, the tests and the notes for the Android project files. It does not hold the generated `android/` folder, because Flutter makes that for you and it differs between Flutter versions.

## What is built

| Part | Where | Notes |
|---|---|---|
| Encrypted local database | `lib/data/local_db.dart`, `assets/sql/local_schema.sql` | SQLCipher. The key is made on first run and kept in the Android Keystore. |
| Schema (55 synced tables + local ones) | `assets/sql/` | **Generated** from `../tools/schema.ts`. Never edit by hand; run `npm run -s gen` in `../tools`. |
| Change logging, append-only rules, stock cache | in the schema, as database triggers | No code path can forget to log a change or edit a sale. |
| Licence check, offline | `lib/licence/` | Signature checked with the public key built into the app. Expiry, grace, sync deadline and clock-tamper rules. |
| Sync engine | `lib/sync/sync_engine.dart` | Port of `../tools/src/phone_sync.ts`, which is tested against the real server. |
| Money and selling engine | `lib/selling/` | Port of `../tools/src/money.ts` and `selling.ts`. One transaction per sale: lines, split-currency payments, change, credit, stock (earliest expiry first, bundles), receipt number, fiscal queue. No screens yet. |
| Till screen | `lib/ui/till_screen.dart`, `lib/selling/catalog.dart`, `cart_controller.dart` | Search and barcode, cart with stock limits, multi-currency payment sheet, change currency, saves through the selling engine. Open it after shop set-up. |
| Shop set-up and catalogue | `lib/setup/`, `lib/ui/setup_screens.dart` | Port of `../tools/src/setup.ts`. First-run set-up from a country preset (Zimbabwe, Zambia), exchange rate dialog, products with price history, barcode, tax class and opening stock, receive stock with weighted-average cost. |
| Staff, PINs and roles | `lib/auth/`, `lib/ui/auth_screens.dart` | Port of `../tools/src/auth.ts`. PBKDF2-SHA256 PIN hashes checked offline (vectors from the reference), lock after 5 wrong PINs on that phone with growing waits, auto-lock after 5 idle minutes, four starter roles with permission switches, manager approval by PIN, the shop always keeps one owner. The selling engine refuses actions the signed-in user may not do. Pure-Dart PBKDF2 takes a moment on cheap phones; if login feels slow, move it to an isolate. |
| Activation, lock and home screens | `lib/ui/`, `lib/app_controller.dart` | The till, stock, customers and reports screens plug in next. |

## Automatic checking (recommended)

The file `../.github/workflows/build.yml` runs everything on every push to GitHub: server and tools tests, `flutter analyze`, `flutter test`, and an APK build. It creates the Android project and applies the required Android settings with `tool/prepare_android.py`, so you do not do the steps below by hand. Add the repository secrets `TIMPOS_SERVER_URL` and `TIMPOS_LICENCE_PUBLIC_KEY` to get a downloadable APK. If a run fails, paste me the log.

## One-time project setup (manual alternative)

You need the Flutter SDK (current stable) and Android Studio's Android SDK.

```bash
# From this folder. Make a throwaway project, take only its android/ folder, and keep our own code untouched.
flutter create --org zw.timpos --project-name tim_pos --platforms android ../tim_pos_shell
cp -r ../tim_pos_shell/android ./android
cp ../tim_pos_shell/.metadata ./.metadata
rm -rf ../tim_pos_shell
flutter pub get
```

Then make these edits in the generated `android/` folder. They matter for security and for the database to work:

1. **`android/app/build.gradle(.kts)`**: set `minSdk = 23` (needed by secure storage). In the `release` build type keep minification on and add the rules file:
   `proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")`.
2. **Copy `android_setup/proguard-rules.pro`** to `android/app/proguard-rules.pro`.
3. **`android/app/src/main/AndroidManifest.xml`**: on the `<application>` tag add `android:allowBackup="false"` and `android:fullBackupContent="false"`. (Without this, restoring a backup to another phone breaks the Keystore key and the app cannot read its own database.) Make sure `<uses-permission android:name="android.permission.INTERNET"/>` and `<uses-permission android:name="android.permission.CAMERA"/>` (barcode scanning) are present, and do **not** add `usesCleartextTraffic`; the server must use HTTPS.
4. **Signing**: create a release keystore once and keep it safe. If you lose it you can never update installed phones. Follow Flutter's "Build and release an Android app" guide.

## Run the tests

```bash
flutter test
```

- `uuid7_test`, `licence_test`, `licence_guard_test` need nothing else.
- `schema_test` and `sync_engine_test` use plain SQLite on your computer through `sqflite_common_ffi`. On Linux install `libsqlite3-dev`; on Windows put `sqlite3.dll` next to your Flutter tools or on PATH; macOS works out of the box.
- `money_test` reads `test/fixtures/money_vectors.json`, made by the reference code, so the Dart rounding and conversion match it on every vector. `selling_test` checks the main selling rules; the full set (credit limits, tax, bundles, batches, rates) is tested in `../tools/test/selling.test.ts` against the same schema.
- `licence_test` and `licence_guard_test` read `test/fixtures/licence_vectors.json`, which the server's own code produced. They prove the phone and the server agree on the signature format and on every date rule. Regenerate with `npm run -s gen` in `../tools` (it makes a new key pair each time, so commit the result).

## Build the APK

```bash
flutter build apk --release \
  --dart-define=TIMPOS_SERVER_URL=https://pos.yourdomain.com \
  --dart-define=TIMPOS_LICENCE_PUBLIC_KEY=$(cd ../server && npm run -s cli public-key --raw)
```

The licence public key must be the one that matches the server's private signing key. A build without it refuses to start, on purpose.
The APK is then at `build/app/outputs/flutter-apk/app-release.apk`. Give shops that file; upload it to the vendor dashboard's releases when that part exists.

## If you change the database

1. Edit `../tools/schema.ts`.
2. `cd ../tools && npm run -s gen && npm test` (this also checks the SQL file is up to date and that two phones still sync correctly against the real server).
3. Raise `LocalDatabase.schemaVersion` and add an `onUpgrade` step in `lib/data/local_db.dart` for phones that already have shop data. New installs get the full schema automatically.

## Not yet checked by a compiler

This code was written in an environment without the Flutter SDK, so it has not been compiled. Everything it relies on is covered two ways: the database and the sync logic by tests that run the same SQL and the same protocol against the real server (`../tools`), and the licence format by vectors made by the server. When you first run `flutter pub get` and `flutter test`, expect a small number of typing or version fixes. Send me the output and I will correct them.

## Receipts and printing

| File | What it does |
| --- | --- |
| `lib/printing/receipt.dart` | Reads a saved sale, lays it out for 58 mm (32 characters) or 80 mm (48), gives the on-screen text and the ESC/POS bytes. Port of `tools/src/receipt.ts`, checked against `test/fixtures/receipt_vectors.json`. |
| `lib/printing/printer_transport.dart` | The small interface between the app and a printer. |
| `lib/printing/bluetooth_transport.dart` | The only file that uses the Bluetooth plugin (`print_bluetooth_thermal`). If a plugin version changes its API, fix it here. |
| `lib/printing/print_service.dart` | Remembers this phone's printer, prints a sale or a COPY, opens the cash drawer on cash sales, prints a test page. |
| `lib/ui/printer_screens.dart` | Receipt preview with Print / Print copy, and the Receipt printer settings page. |

Pair the printer once in Android's Bluetooth settings (PIN is usually 0000 or 1234), then open **Receipt printer** in TIM-POS, press **Find printers**, tap yours, and print a test page.
Receipt wording comes from the shop's `receipt_header` / `receipt_footer` settings.

## Customers, credit and layby

| File | What it does |
| --- | --- |
| `lib/customers/customer_repository.dart` | Customers, credit-account payments, layby instalments and hand-over, account statement. Port of `tools/src/customers.ts`. |
| `lib/ui/customer_screens.dart` | Customer list and picker, customer page (balance, statement, laybys), add/edit form, take-payment dialog. |

- A credit sale is a positive ledger row; the debt stays in the currency it was agreed in. A payment in another currency is converted at today's rate and both amounts are kept in `account_payments`.
- A layby is a sale with status `layby`: the goods leave stock at once, the deposit is a normal sale payment, instalments are `account_payments` rows with `sale_id`. When the balance is zero, **Hand over** writes a `layby_payments` row with no payment and note `collected`.
- Setting `layby_min_deposit_pct` (shop scope) requires a minimum deposit.
- Payment receipts are numbered `D1-P000001`. Printing them is not wired yet.
- Not built yet: cancelling a layby (refund), credit above the limit approval, SMS reminders.

## Shifts and cash-up

| File | What it does |
| --- | --- |
| `lib/shifts/shift_repository.dart` | Open a shift with a float, cash in / out / bank drop, expected cash, close with a count. Port of `tools/src/shifts.ts`. |
| `lib/ui/shift_screens.dart` | The Shift and cash-up screen. The count is blind: the expected figure is shown only after closing. |

Expected cash per currency = float + cash sales + cash account/layby payments by that cashier during the shift − change − cash out − bank drops + cash in. Mobile money and card are listed as takings but not counted in the drawer. A difference is recorded, never blocked. Set the shop setting `require_shift` to `1` to refuse sales without an open shift. Not yet built: printing the cash-up slip, a setting screen for `require_shift`.

## Returns, refunds and voids

| File | What it does |
| --- | --- |
| `lib/returns/return_repository.dart` | Find a sale by receipt number, preview and process a return, void a sale or cancel a layby. Port of `tools/src/returns.ts`. |
| `lib/ui/return_screens.dart` | The Returns and voids screen and the manager-PIN approval dialog. |

- Nothing already saved is changed. A return adds rows: the goods back in stock (unless marked Damaged), the part taken off the customer's account, and the money paid back (`return_payouts`). Receipt numbers look like `D1-R000001`.
- A refund or void by a cashier needs a manager's PIN (permissions `sale.refund`, `sale.void`); the approval is recorded.
- A sale on account is taken off the customer's debt first, as far as they still owe; only the rest is paid back.
- An uncollected layby can only be cancelled; the customer gets back what they have paid. After hand-over it is returned like any sale.
- Cash paid back comes out of the cash-up of the shift it was paid in. Voided sales drop out of shift sales figures.
- Not yet built: printing a refund slip, a time limit on returns, refunds to store credit.

## Reports
`lib/reports/report_repository.dart` (port of `tools/src/reports.ts`, tested by `test/report_test.dart`), screen in `lib/ui/report_screens.dart`, home button needs `report.view`.
- Tabs: Sales (totals, per currency, day by day, open laybys), Best sellers (by money, quantity or profit), Takings by payment method, Stock (value at cost, out of stock, expiring in 14 days), Owed (who owes), Cash-ups (expected vs counted).
- Periods: Today, Yesterday, Last 7 days, This month, or a picked range. Days follow the phone's clock.
- Rules: voided sales and their returns are left out; a layby counts as a sale on the day it is handed over; returns reduce the day they were made; other currencies convert to base using the rate stored on the sale; profit = revenue - tax - cost; items with no cost are counted and flagged, never guessed.

## Slips (cash-up, refund, payment receipt)
`lib/printing/slips.dart` is a port of `tools/src/slips.ts` (tests: `test/slips_test.dart`). Each slip is loaded into plain data with money and dates already as text, then one layout makes the same lines as a sale receipt, so the 58/80 mm widths, ASCII rules and the drawer pulse work the same.
- Cash-up slip: sales, money received per method, refunds paid back, cash in/out with reasons, and per currency the float, what it should be, what was counted and "SHORT by / OVER by / Correct". Printed automatically when a shift is closed; "Print cash-up slip" prints it again.
- Refund / void slip: items, value, how it was paid back, amount taken off the customer's account, reason, approver, and a customer signature line. Printed automatically; "Print slip" prints a copy (a copy never opens the drawer).
- Payment receipt: account payments and layby instalments, with what was paid, what it counted as when paid in another currency, and the balance left after that payment (older receipts keep their own balance).
- A print failure never undoes what was saved; the person is told and can print again.

## Settings
`lib/settings/settings_repository.dart` (port of `tools/src/settings.ts`, tests in `test/settings_test.dart`), screen `lib/ui/settings_screens.dart`, home button needs `settings.edit`.
- Switches: cashiers must open a shift before selling; allow selling when stock shows zero (off by default). Number: minimum layby deposit %. Text: receipt header and footer (one line, up to 120 characters; shown on receipts and the footer also on slips).
- Only these keys can be changed. Costing and the ZIMRA switch are deliberately not here. Everything is checked before anything is saved, and each change is written to the audit log with the old and new value.

## Stock adjustments and stock take
`lib/stock/stock_repository.dart` (port of `tools/src/stock.ts`, tests in `test/stock_test.dart`), screen `lib/ui/stock_screens.dart`, home button needs `stock.adjust`.
- Adjust: damaged, expired, lost or stolen, other removal, found or extra stock. A reason is required, a removal can never take more than is on the shelf (per batch when a batch is chosen), and each one is valued at the product's cost at that moment and written to the audit log.
- Stock take: start (snapshot of every stock-keeping product, by batch), count line by line (the screen does not show the expected figure while counting), finish, review differences with their value at cost, then approve. Nothing changes in stock before approval. Approval posts one `count_correction` per counted line for (counted - snapshot), so sales made while counting are kept. Lines not counted are left alone. An approved take cannot be changed or cancelled; an open one can be cancelled or reopened for more counting. One take at a time per branch.
- History tab: the last 31 days of adjustments and corrections with totals by type.

## Suppliers and purchasing

Home screen, "Suppliers and purchasing" (needs the stock.receive permission; paying needs supplier.pay, which managers have).

- **Suppliers**: name, phone, address, payment terms. Each supplier shows what you owe, per currency. Debts stay in the currency the supplier invoiced in.
- **Orders**: a purchase order is a plan. Draft, send, receive, close or cancel. Nothing is owed and no stock moves until goods arrive.
- **Receive goods**: against an order (quantities default to what is still to come, you can lower them) or without one. Optional batch code, expiry date, invoice number and due date. Stock cost is converted to the base currency at the day's rate and averaged into the product's cost.
- **Return goods**: sends stock back; optionally takes the value off what you owe.
- **Pay supplier**: part or full, in any currency you hold. Overpaying is refused. A cash payment during an open shift is recorded as cash out on that shift.
- The supplier page shows the full account statement with a running balance.

Tests: `test/purchasing_test.dart` (Dart, not yet run) mirrors `tools/test/purchasing.test.ts` (passing).

## Barcodes

- **Scanning**: the till has a camera button in the search box (keeps scanning, one beep line per product, "Type it" for damaged labels). A Bluetooth or USB scanner that types into the search box and presses Enter works too. Stock adjust has a scan button to jump to a product, and a stock take has **Scan to count** (each scan adds one). Receiving and ordering have a scan button in the product picker. The only file that uses the camera plugin is `lib/ui/scan_screen.dart`.
- **Several barcodes per product**: Edit product > Barcodes. Add by scanning or typing, remove, or **Make shop code** for goods that have no barcode (an EAN-13 starting 20; ten random digits so phones that are offline never make the same one). **Print label** prints name, price and barcode on the receipt printer, as many copies as you ask for.
- **UPC-A and EAN-13 are the same number** with different leading zeros, so a scan finds the product whichever way it was saved. A barcode with a wrong last digit is refused unless you choose Add anyway. One barcode belongs to one product only.
- **Scale labels** (butchery or deli scale): Settings > Barcodes > Scale label prefix (two digits, for example 21). The scale prints 13-digit labels: prefix, 5-digit item code, 5-digit weight in grams, check digit. Save the product with the 7-digit code (prefix + item code, for example 2100123) and sell it in kg or g. Scanning the label puts the weight in the cart. Price-embedded labels are not supported yet.
- Tests: `tools/test/barcodes.test.ts` (passing) and `app/test/barcode_test.dart` (not yet run).

## ZIMRA fiscal (partly built)

The **ZIMRA fiscal** button (Settings permission, and the licence must have the `zimra` feature) opens the fiscal screen. Reference logic is `tools/src/fiscal.ts` (tested); the Dart port is `lib/fiscal/fiscal_repository.dart`.

**Built:**
- Every sale and return made while "Send sales to ZIMRA" is on is queued as a fiscal receipt. A sale is never blocked by fiscal trouble.
- ZIMRA receipts are built from sales (FiscalInvoice) and returns and voids (CreditNote), with tax groups, payments by money type, discounts and buyer name.
- The fiscal day: opened on the first send, receipt counter and global number kept per phone, hash chain restarted each day, day counters built for closing, close blocked while anything waits, failed or is marked Grey or Red by ZIMRA.
- Retries: no connection leaves everything queued with no numbers used up. A receipt ZIMRA rejects is marked failed with the reason and can be sent again after fixing. Laybys wait until collected.
- Screen: device ID and serial, ZIMRA taxes matched to your tax classes, default HS code, the queue, send now, close the day.

**Not built, on purpose, so nothing here can be wrong in a way that looks right:**
- The **signature and hash** (ZIMRA API section 13) and the **QR code** (section 11). I could not read these two sections of ZIMRA's Fiscal Device Gateway API v7.2. They sit behind `Signer`; until a real one is installed, receipts stay queued and no fiscal day is opened.
- The **HTTPS client with the device certificate** (mutual TLS), device registration and certificate renewal. It sits behind `Gateway`.
- Receipts printed with the ZIMRA QR code and verification code.

**Assumptions to confirm in ZIMRA's test environment** (A1 to A7 at the top of `tools/src/fiscal.ts`): number and date formats, discount lines, negative amounts on credit notes, that a rejected receipt does not use up its numbers, tax amounts per group, the shape of the validation answer, and laybys. Laybys that are collected later are not yet re-queued (known gap).

To finish: send the official PDF (or sections 11 and 13), and a ZIMRA test device (device ID, serial, activation key). Then the signer and gateway are written from the text and checked against test vectors and the test environment.
