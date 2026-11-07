# TIM-POS: run everything, step by step

Follow the parts in order. Each step says what to do, what you should see, and what to do if you do not see it. Do not skip a step. Where something can go wrong there is an **If that fails** line with an alternative.

Your system is three pieces:

| Piece | What it is | Where it runs |
|---|---|---|
| **Server** (`server/`) | Licences, activation, sync, billing, owner reports | Your computer first, a VPS later |
| **Dashboard** (`dashboard/`) | The website you (vendor) and shop owners use. The server serves it at `/dashboard/` | Inside the server, nothing extra to run |
| **Phone app** (`app/`) | The till, built into an APK | The shop's Android phone |

The order is: **Part A** accounts and installs, **Part B** server and dashboard on your computer, **Part C** put the server on the internet with HTTPS, **Part D** build the APK, **Part E** install on the phone and sell, **Part F** check everything works.

Parts A and B need no money and no phone. If you only want to see the system working today, do A and B, stop, and continue later.

---

## Part A. What you need, and the accounts to create

### A1. Accounts (all free to start)

| Account | Needed for | Required? |
|---|---|---|
| **GitHub** (github.com) | Builds the APK for you in the cloud, so you do not have to install Flutter | Yes (recommended path) |
| **An authenticator app** on your phone (Google Authenticator, Microsoft Authenticator or Aegis) | Two-factor sign-in for your vendor login | Yes |
| **A domain name** (about USD 1 to 15 a year, any registrar, or a free one from a DNS provider) | A real HTTPS address for the server | Needed in Part C for real shops |
| **A VPS** (a small Linux server, USD 4 to 6 a month, for example Hetzner, DigitalOcean, Contabo, Vultr) | Runs the server day and night | Needed in Part C for real shops |
| **Cloudflare** (free) | Alternative to a VPS: a tunnel from your own computer, and free DNS | Optional |
| **ZIMRA test device** | Fiscalisation | Not now. See Part G |

Write down every username and password in a password manager or a notebook that stays with you. Never send them to anyone, including me.

### A2. Install on your computer

You need **Node.js 22.18 or newer** and **Git**. Check what you have first.

**Windows** (open PowerShell: Start menu, type `powershell`, press Enter):

```powershell
node --version
git --version
```

**Linux or Mac** (open a terminal):

```bash
node --version
git --version
```

- If `node --version` prints `v22.18.0` or higher (v22.x with x of 18 or more, or v23, v24 and so on), Node is fine.
- If it says "not recognized", "command not found", or a lower number, install it:
  - **Windows:** download the "LTS" installer from nodejs.org (choose the newest LTS, it must be 22.18 or newer). Run it with the default options. **Close PowerShell and open it again**, then run `node --version`.
  - **Linux/Mac, recommended:** install nvm from github.com/nvm-sh/nvm, close and reopen the terminal, then `nvm install 22 && nvm use 22`.
  - **Alternative on any system:** if the nodejs.org LTS is older than 22.18, use `nvm install 24` instead of 22.
- Git: install from git-scm.com (Windows, default options) or `sudo apt install git` (Ubuntu/Debian) or `brew install git` (Mac).

**If that fails:** if you cannot install Node at all on this computer (locked-down school or work machine), use Part C's VPS route and do Part B on the VPS instead (the same commands work on a Linux server).

### A3. Unzip the project

Put the latest zip (`tim-pos-zimra.zip`, or newer if I have sent one) in a folder such as `Documents`. Unzip it so you get a folder called `tim-pos` containing `app`, `dashboard`, `server`, `tools`, `RUNBOOK.md`.

- **Windows:** right-click the zip, Extract All.
- **Linux/Mac:** `unzip tim-pos-zimra.zip`

Then in the terminal go into it:

```bash
cd path/to/tim-pos
```

(Windows example: `cd $HOME\Documents\tim-pos`.)

**If that fails:** if you see a `tim-pos/tim-pos` double folder, go one level deeper. You are in the right place when `ls` (or `dir`) shows `server` and `dashboard`.

---

## Part B. Run the server and dashboard on your computer

### B1. Run the automatic tests (proves your Node works with the code)

```bash
cd tools
npm test
```

Expected: the last lines show `# pass 170` and `# fail 0` (the number may be a little different if I have added tests).

```bash
cd ../server
npm test
```

Expected: `# pass 99` and `# fail 0`.

You do not need `npm install`. The server has no runtime packages on purpose.

**If that fails:**

- *`SyntaxError` or "unknown file extension .ts"*: your Node is too old. Go back to A2 and install 22.18 or newer.
- *"ExperimentalWarning" text*: harmless, ignore it.
- *Some tests fail*: copy the output starting from the first `not ok` line and send it to me. Do not continue to the app part until the server tests pass, but you can still continue with B2 to look around.

### B2. Start the server

In the `server` folder:

```bash
npm start
```

Expected: a line saying the server is listening on port 8080, and a warning that development secrets were created in `data/dev-secrets.json`. That is normal for your own computer. **Leave this terminal open.** The server runs as long as this window is open. (Press Ctrl+C to stop it.)

**If that fails:**

- *"EADDRINUSE", port in use*: something else uses 8080. Stop it, or start on another port: Windows `$env:PORT=8081; npm start`, Linux/Mac `PORT=8081 npm start`. Then use 8081 everywhere below.
- *Windows firewall popup*: click Allow on private networks.

Check it is alive: open a browser and go to `http://localhost:8080/dashboard/`. You should see the TIM-POS sign-in page. If you see a blank page or "not found", the dashboard build is missing: see the dashboard section in Part H (rebuild).

### B3. Create your vendor (owner of the whole system) account

Open a **second** terminal (leave the first running), go to `tim-pos/server`, and run:

```bash
npm run -s cli -- create-vendor --name "Tim" --email you@example.com
```

Use your real email. It asks for a password: use at least 12 characters. Expected: `Vendor account created for ...`.

If the password prompt does not behave in your terminal, give it through an environment variable instead:

- Windows: `$env:VENDOR_PASSWORD="YourLongPassword12"; npm run -s cli -- create-vendor --name "Tim" --email you@example.com`
- Linux/Mac: `VENDOR_PASSWORD='YourLongPassword12' npm run -s cli -- create-vendor --name "Tim" --email you@example.com`

### B4. Sign in and switch on two-factor

1. Go to `http://localhost:8080/dashboard/` and sign in with the email and password.
2. Open the security or two-factor page (menu). Start setup. It shows a secret code (text). Type it into your authenticator app (add account, enter a setup key, name it TIM-POS). The app starts showing 6-digit codes.
3. Type the current 6-digit code to confirm.

If you ever lose the authenticator, on the server computer run `npm run -s cli -- reset-2fa --email you@example.com` and set it up again.

**If that fails:** "invalid code" almost always means your phone's clock is wrong. Set the phone to automatic date and time and try the next code.

### B5. Create your first plan, shop and licence

All in the dashboard:

1. **Plans**: create a plan (for example "Standard", monthly price USD 15.50, a number of devices, a number of branches). Save.
2. **Shops**: create a shop (name, contact, country, which plan). Open the shop.
3. In the shop page, create a **licence key**. It is shown **once**. Copy it into a text file now. It looks like several groups of letters and numbers. This is what you type into the phone to activate it. If you lose it, create a new one.
4. **Billing details** (menu): fill in your business name, address, payment instructions. Then in the shop page create an **invoice**, and **record a payment** to see the receipt.
5. In the shop page, **Owner logins**: add the shop owner (name and email). It shows a temporary password once. Copy it.

### B6. See what the shop owner sees

Open a private/incognito window and go to `http://localhost:8080/dashboard/#/owner`. Sign in with the owner's email and temporary password. It forces a new password. After sales happen on the phone (Part E), the owner screens (Summary, Daily, Products, Takings, Stock, Expiring, Receivables, Cash-ups, Branches) fill with that shop's figures.

At this point **the server and dashboard are running**. Everything after this connects a phone.

### B7. Optional

The browser test in `dashboard/e2e/smoke.mjs` is for me to run; you can skip it.

---

## Part C. Put the server on the internet with HTTPS

**Why:** the phone app refuses plain `http://`. It only talks to an `https://` address, and the APK has that address built in. So you must have an HTTPS address before building the APK. Pick **one** route.

### Route 1 (recommended for real shops): VPS + domain + Caddy

1. **Buy a VPS** with Ubuntu 24.04 (1 GB RAM is enough to start). Note its IP address and how to log in (SSH).
2. **Buy a domain**, and in its DNS settings add an **A record**: name `pos` (so `pos.yourdomain.com`) pointing to the VPS IP. Wait 5 to 30 minutes.
3. **Log in to the VPS** (`ssh root@VPS_IP`; on Windows PowerShell the same command works). Then:

```bash
apt update && apt install -y unzip curl
# Node 22 or newer
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt install -y nodejs
node --version      # must be 22.18 or newer
# Caddy (gets the HTTPS certificate for you)
apt install -y debian-keyring debian-archive-keyring apt-transport-https
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
apt update && apt install -y caddy
```

4. **Copy the project to the VPS.** On your computer: `scp tim-pos-zimra.zip root@VPS_IP:/opt/` then on the VPS `cd /opt && unzip tim-pos-zimra.zip`. You now have `/opt/tim-pos`.
5. **Make the secrets once and keep them forever:**

```bash
cd /opt/tim-pos/server
npm run -s cli -- gen-secrets > /root/secrets.env
cat /root/secrets.env
```

   **Copy `secrets.env` somewhere safe off the server** (password manager attachment, USB). If `LICENCE_PRIVATE_KEY` is lost, no new licences can be signed. If it leaks, anyone can forge licences. Never change these after shops are live.

6. **Run the server as a service** so it survives reboots. Create `/etc/systemd/system/timpos.service`:

```ini
[Unit]
Description=TIM-POS server
After=network.target

[Service]
WorkingDirectory=/opt/tim-pos/server
EnvironmentFile=/root/secrets.env
Environment=NODE_ENV=production
Environment=HOST=127.0.0.1
Environment=PORT=8080
Environment=TRUST_PROXY=1
Environment=DATA_DIR=/var/lib/timpos
ExecStart=/usr/bin/node --disable-warning=ExperimentalWarning src/server.ts
Restart=always

[Install]
WantedBy=multi-user.target
```

   Then:

```bash
mkdir -p /var/lib/timpos
systemctl daemon-reload
systemctl enable --now timpos
systemctl status timpos          # must say active (running)
journalctl -u timpos -n 50       # see messages if not
```

7. **Caddy.** Edit `/etc/caddy/Caddyfile` so it contains only:

```
pos.yourdomain.com {
	encode gzip
	reverse_proxy 127.0.0.1:8080
}
```

   Then `systemctl reload caddy`. Open the firewall: `ufw allow 22 && ufw allow 80 && ufw allow 443 && ufw enable`.

8. Visit `https://pos.yourdomain.com/dashboard/`. You must see the sign-in page with a padlock.
9. Create the vendor account **on the VPS** (it is a separate database from your computer): `cd /opt/tim-pos/server && set -a && . /root/secrets.env && set +a && NODE_ENV=production DATA_DIR=/var/lib/timpos npm run -s cli -- create-vendor --name "Tim" --email you@example.com`. Then repeat B4 and B5 on the real address.
10. Print the public key you will need in Part D:

```bash
set -a && . /root/secrets.env && set +a
NODE_ENV=production DATA_DIR=/var/lib/timpos npm run -s cli -- public-key --raw
```

    Copy the single line it prints.

**If that fails:** certificate not issued means the DNS record has not spread yet or ports 80/443 are closed. Check `journalctl -u caddy -n 50`. Bad gateway means the server service is not running (`systemctl status timpos`).

### Route 2: Cloudflare Tunnel (free, no VPS, your computer must stay on)

1. Create a free Cloudflare account and add your domain to it (follow their steps to change the domain's name servers).
2. In Cloudflare, Zero Trust, Networks, Tunnels: create a tunnel, install `cloudflared` on your computer as shown, and add a public hostname `pos.yourdomain.com` pointing to `http://localhost:8080`.
3. Keep the server (B2) and `cloudflared` running. `https://pos.yourdomain.com/dashboard/` should open.
4. Use the public key from your own computer: in `server`, `npm run -s cli -- public-key --raw`. Because it was created in `server/data/dev-secrets.json`, **back up that file** and do not delete it.

This is good for a pilot with one friendly shop. For paying shops the computer would have to be on all day, so move to Route 1 later. To move, you must keep the same secrets (copy the values out of `dev-secrets.json` into `secrets.env`), otherwise the APK's public key stops matching.

### Route 3: ngrok (free account, test only)

Create an ngrok account, claim the free static domain it offers, run `ngrok http --domain=YOUR-NAME.ngrok-free.app 8080`. Use `https://YOUR-NAME.ngrok-free.app` as the server URL. Fine for testing, not for a business. Do not use random changing tunnel URLs for builds, because the APK has the address inside it, so every change means a new APK.

### Route 4: Docker (alternative to the systemd service)

`server/Dockerfile` exists but I have never built it here. If you prefer Docker, build from the **project root** (not the server folder): `docker build -f server/Dockerfile -t timpos .`, run with `--env-file secrets.env -e NODE_ENV=production -e TRUST_PROXY=1 -p 127.0.0.1:8080:8080 -v timpos-data:/data` (the data folder inside the container is `/data`), and still use Caddy for HTTPS. If it fails, send me the error, or use the systemd route above.

### Quick local-only test with no HTTPS at all

Say so and I will add a debug-only build option that allows `http://192.168.x.x:8080` on your home Wi-Fi for testing. It is not in the build now because it must never ship to shops.

---

## Part D. Build the APK

You need two values:

- **Server URL**: for example `https://pos.yourdomain.com` (no slash at the end, no `/dashboard`).
- **Licence public key**: the single line from `public-key --raw` made **from the same secrets as the server shops will use** (Part C step 10, or B-part on your computer if you use Route 2).

### Route 1 (recommended): build with GitHub Actions, no Flutter install

1. Create a GitHub account (github.com, Sign up). Verify your email.
2. Create a **private** repository named `tim-pos` (New repository, tick Private, do not add a README).
3. On your computer, in the `tim-pos` folder:

```bash
git init
git add .
git commit -m "TIM-POS first push"
git branch -M main
git remote add origin https://github.com/YOUR-USERNAME/tim-pos.git
git push -u origin main
```

   When Git asks for a password, GitHub no longer accepts your account password: make a **Personal access token** (GitHub, Settings, Developer settings, Personal access tokens, Tokens (classic), tick `repo` and `workflow`) and paste that as the password.
   If `git commit` complains "Please tell me who you are", run `git config --global user.email "you@example.com"` and `git config --global user.name "Tim"` and commit again.

   **Alternative with no command line:** on the repository page choose "uploading an existing file" and drag the contents of the `tim-pos` folder in. (The hidden `.github` folder must be included; if your file explorer hides it, use the Git commands instead.)

4. Add the two secrets: repository **Settings, Secrets and variables, Actions, New repository secret**:
   - Name `TIMPOS_SERVER_URL`, value your server URL.
   - Name `TIMPOS_LICENCE_PUBLIC_KEY`, value the public-key line.
5. Open the **Actions** tab. A run called `build` starts on every push. Its jobs are `node` (server and tools tests) then `flutter` (create Android project, analyse, test, build APK). If you added the secrets after the first push, click **Run workflow** on the left under `build`.
6. When it is all green, open the finished run, scroll to **Artifacts**, and download `tim-pos-apk`. Unzip it: inside is `app-release.apk`.

**Important, honest warning:** the Dart code of the app has been written and checked by me against the logic and tests in TypeScript, but **it has never been compiled**, because I do not have Flutter here. The first run will very likely show a few compile or analyze errors (typos, a missing import). That is normal and I fix them quickly. When it goes red:

1. Open the failed run, click the red step (`flutter analyze` or `flutter test`), copy the error lines, and send them to me.
2. I send back corrected files. Replace them, `git add . && git commit -m fix && git push`, and the build runs again.
3. Repeat until green. Expect a few rounds the first time.

**If that fails (other cases):**

- *`node` job fails at "generated files are up to date"*: run `cd tools && npm run -s gen` on your computer, commit and push.
- *No Artifacts shown*: the secrets are missing or misspelled. The APK step is skipped when `TIMPOS_LICENCE_PUBLIC_KEY` is empty.
- *Push rejected*: you used the wrong token scope or username. Create a new token as above.

### Route 2: build on your own computer (needs about 10 GB and some time)

1. Install **Android Studio** (developer.android.com/studio). Run it once, finish the setup wizard so it installs the Android SDK. In its SDK Manager install "Android SDK Command-line Tools" and accept licences: `flutter doctor --android-licenses`.
2. Install **Flutter** (docs.flutter.dev/get-started/install), stable channel, and add it to your PATH.
3. Run `flutter doctor` and fix every red item it lists (it tells you how).
4. In the `tim-pos/app` folder:

```bash
flutter create --org zw.timpos --project-name tim_pos --platforms android ../_shell
# Linux/Mac:  cp -r ../_shell/android ./android && rm -rf ../_shell
# Windows PowerShell:  Copy-Item -Recurse ..\_shell\android .\android ; Remove-Item -Recurse -Force ..\_shell
python3 tool/prepare_android.py        # on Windows use: python tool/prepare_android.py
flutter pub get
flutter analyze
flutter test
flutter build apk --release --dart-define=TIMPOS_SERVER_URL=https://pos.yourdomain.com --dart-define=TIMPOS_LICENCE_PUBLIC_KEY=PASTE_THE_KEY_HERE
```

   The APK is `app/build/app/outputs/flutter-apk/app-release.apk`. Errors from `analyze` and `test` go to me, as above. The `flutter test` step needs the native SQLite library: on Ubuntu `sudo apt install libsqlite3-dev`; on Windows/Mac the tests that need it may fail locally, and that is fine, GitHub Actions runs them properly.

### Later, before real shops: sign the release

Debug-signed or unsigned APKs install fine, but you should make your own release keystore once (`keytool -genkey -v -keystore tim-pos.jks -keyalg RSA -keysize 2048 -validity 10000 -alias timpos`), keep it and its password safe forever (updates must be signed with the same key), and add the four `KEYSTORE_*` secrets listed at the top of `.github/workflows/build.yml`. I will walk you through this when you reach that point.

---

## Part E. Install on the phone and sell

### E1. Install the APK

1. Get `app-release.apk` onto the phone: send it to yourself on WhatsApp Telegram or email, or plug in USB and copy it, or upload to Google Drive and download on the phone.
2. On the phone tap the file. Android asks to allow installs from that app (Chrome, Files, WhatsApp): allow it (Settings, Install unknown apps).
3. If "Google Play Protect" warns about an unknown app, tap **More details, Install anyway**. This is normal for apps outside the Play Store.
4. Open **TIM-POS**.

**If that fails:** "App not installed": remove any older TIM-POS first, free some storage, or the phone is too old (needs Android 6 or higher; if unsure, tell me the model). "Parse error": the download was cut, download it again.

### E2. Activate

1. The first screen asks for the **licence key**. Type or paste the key from step B5.3 (made on the same server whose URL is inside the APK).
2. It needs **internet once** for activation. After that the shop works without internet.
3. It then asks for the shop setup: the **owner name and a PIN** (4 to 8 digits). Remember that PIN.

**If that fails:**

| Message or symptom | Cause | Fix |
|---|---|---|
| Cannot reach the server | No internet on the phone, or wrong server URL in the APK | Open `https://pos.yourdomain.com/dashboard/` in the phone's browser. If it does not load there either, fix Part C. If it loads, the APK has a different URL: rebuild with the right secret |
| Key not valid | Key typed wrongly, or it belongs to a suspended shop | Make a new key in the dashboard shop page |
| Licence signature invalid | The APK was built with a public key from different secrets than the server runs | Rebuild with the public key printed by *this* server's `public-key --raw` |
| Device limit reached | Plan allows fewer phones | Release a device in the shop page or raise the plan |

### E3. Make a first sale

1. Add a product (name, price, optionally stock and barcode). A product can be entered by hand first.
2. Go to Sell, tap the product, take payment (cash, EcoCash, etc.), finish. You should get a receipt screen.
3. Check the sale appears in the day's summary.

### E4. Sync and check the owner dashboard

1. With internet on, the app syncs by itself every little while, or use the sync button.
2. In the vendor dashboard open the shop. It should show the device and a last-sync time.
3. Sign in as owner at `https://pos.yourdomain.com/dashboard/#/owner` and check the sale is in Summary and Daily, and the same figures appear as on the phone.

---

## Part F. Acceptance checklist (tick each)

- [ ] Tools tests: 0 failed
- [ ] Server tests: 0 failed
- [ ] Server running, dashboard page opens at your HTTPS address with a padlock
- [ ] Vendor can sign in with a code from the authenticator
- [ ] Plan, shop, licence key, invoice and a recorded payment with receipt all work
- [ ] GitHub run is green and gave an APK
- [ ] APK installs and activates with the licence key
- [ ] Shop owner PIN set, product added, a sale completed
- [ ] Turn on airplane mode, make another sale (works offline), turn it off, sale syncs
- [ ] Owner sign-in shows the same totals as the phone
- [ ] Suspending the shop in the dashboard is reflected on the phone after a sync (the till shows the licence state; the exact grace behaviour is in the app README)
- [ ] A backup was taken: `npm run -s cli -- backup /safe/place/backup.db` and copied away

---

## Part G. What is not finished (so you are not surprised)

- **ZIMRA fiscal receipts:** the rules, counters, queue and screens are built, but signing and QR codes and the secure connection to ZIMRA are not, because I need ZIMRA's official document sections 11 and 13 and a test device (device ID, serial number, activation key) from ZIMRA. Until then leave fiscalisation switched off. Send me those when you have them.
- **Dart code never compiled** (see Part D). Expect a few error rounds.
- Not yet: loyalty, a PostgreSQL version for very large numbers of shops, iPhone app, a few smaller items listed in the READMEs.

## Part H. Troubleshooting, quick table

| Symptom | Likely cause | Alternative / fix |
|---|---|---|
| `npm` or `node` not recognised | Not installed, or terminal opened before installing | Install, then close and reopen the terminal |
| Tests fail with syntax errors | Node older than 22.18 | Install newer Node (A2) |
| Dashboard page is blank or 404 | `dashboard/dist` missing or the server cannot find it | Start the server with `DASHBOARD_DIR=/full/path/to/tim-pos/dashboard/dist`. To rebuild: in `dashboard` run `npm install` (needs internet) then `npm run build` |
| Cannot sign in after changing secrets | `VENDOR_TOKEN_SECRET` changed | Run `reset-2fa --email you@example.com` and set up the authenticator again. Never change secrets in production |
| Phones all stop syncing after restoring a backup | Sync epoch | Run `npm run -s cli -- new-sync-epoch` |
| Server restarts and forgets everything | `DATA_DIR` points to a temporary folder | Use a permanent folder like `/var/lib/timpos` and back it up |
| Owner reports slow | Very large shop on SQLite | Planned PostgreSQL step |
| GitHub run red on `flutter analyze` | Expected on first run | Send me the lines |

## Part I. What to send me when something fails

Send **text, not a photo** where possible:

1. Which Part and step number.
2. The exact command you typed.
3. The full error text (copy from the terminal or from the red step on GitHub).
4. For the phone: the exact message on screen, and the phone model and Android version.

Never send passwords, the licence **private** key, `secrets.env`, or your keystore. The licence public key is safe to share.

## Daily care (once live)

- Back up the database daily (`cli backup`) and copy it off the server. Back up `secrets.env` once and keep it offline.
- Update the server by unzipping a newer project over `/opt/tim-pos` **without touching** `/var/lib/timpos` or `/root/secrets.env`, then `systemctl restart timpos`. Migrations run themselves.
- Update the phones by installing a newer APK over the old one (same signing key). Data stays.
