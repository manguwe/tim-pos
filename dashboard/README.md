# TIM-POS vendor dashboard

A web page for you, the vendor: shops, licences, phones, plans, app releases and the audit log. It is a React app that talks to the TIM-POS server's API (`/v1/vendor/...`) and is **served by that same server at `/dashboard/`**, so there is nothing else to host and no cross-site settings.

## Use it

1. Build the server's vendor account (once): see `server/README.md` (`create-vendor`).
2. Start the server. If `dashboard/dist` exists next to it, the dashboard is at `http://localhost:8080/dashboard/` (or `https://your-domain/dashboard/` behind Caddy). A built `dist/` is included in the zip.
3. Sign in with your vendor email and password. **Turn on two-factor** under My account the first time: this account can issue licences.

Set `DASHBOARD_DIR` to serve the files from another folder, or `DASHBOARD_DIR=` (empty) to turn the dashboard off and run the API only.

## What it does

| Page | What you can do |
| --- | --- |
| Overview | Money owed and overdue invoices. Counts of shops, active licences, phones, licences ending within 14 days, in grace, quiet phones, suspended shops. "Needs attention" lists each shop that has a problem and why. |
| Shops | Search and filter, add a shop. |
| A shop | Billing statement (what is owed and overdue), new invoice. Edit details, suspend or resume the shop. Issue a licence (by plan, for months or until a date, with optional limits), extend it, change limits, suspend or resume it, make a new key. Release a phone. Recent activity. |
| Invoices | Invoices and payments received. Make an invoice (fill from a plan), record part or full payments (cash, EcoCash, OneMoney, InnBucks, bank), optionally extend the licence, print or save an invoice or receipt as PDF, void an invoice or reverse a payment (each needs a reason). Run monthly billing for all shops, with a preview. |
| Billing details | Your business name, address, tax number, how to pay, default tax and due days, number prefixes. |
| Plans | Create plans (prices and limits). |
| App releases | Publish an APK release (checksum, size, https address, oldest build allowed). |
| Audit log | Who did what and when, filterable. Entries cannot be edited or deleted. |
| Owner logins (on a shop) | Add a login for the shop owner (temporary password shown once), give a new password, turn it off. |
| My account | Turn on or replace two-factor sign-in. Sign out. |

A licence key is shown **once**, when it is issued or replaced. It is never stored in a form that can be shown again, so copy it then.

The sign-in lasts 12 hours (the server decides) and is kept only in the browser tab. Closing the tab signs you out.

## Change it

```
cd dashboard
npm install
npm run build        # writes dist/ (one script, one stylesheet, index.html)
npm run watch        # rebuilds when you save a file; reload the page
npm run typecheck
```

It uses React 19 and esbuild. There is no router or UI library: pages are in `src/pages/`, shared pieces in `src/ui.tsx`, the server's data shapes and the one `api()` function in `src/api.ts`, and the look in `src/styles.css` (brand colours at the top, dark mode included).

The server sends a strict content-security policy with the page: scripts and styles only from the dashboard itself, no inline scripts. Keep it that way: do not add inline `<script>` tags, or load fonts or scripts from other sites.

## Test it in a real browser

```
npm run build
npm i -D playwright && npx playwright install chromium
node --disable-warning=ExperimentalWarning e2e/smoke.mjs
```

This starts a throwaway server, then signs in, creates a shop and a plan, issues and extends and suspends and replaces a licence, activates and releases a phone, publishes a release, checks the audit log, turns on two-factor and signs in with a code, and checks a phone-sized screen. It fails on any browser console error or blocked request. Screenshots go to the folder named in `SHOTS` (default: a temp folder).

## For shop owners

Owners sign in at `/dashboard/#/owner` (there is a link on the vendor sign-in page). They see only their own shop: Sales (today, yesterday, last 7 days, this month, last month or chosen dates; by branch; profit; day-by-day chart; money in and out by payment method), Best sellers, Stock (value, out of stock, expiring batches), Customers who owe, Cash-ups. The figures are the same ones the phone's report screens show, built from the sales the phones have synced, and each page says when a phone last sent its sales. A new login must choose its own password first.

## Not built yet

Owner two-factor sign-in, owner export to Excel or PDF, and owner alerts (low stock, big cash differences). The dashboard has no password change or user management page: vendor accounts are made with the server's command line.
