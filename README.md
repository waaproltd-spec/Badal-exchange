# Badal Exchange

EVC Plus &harr; Wallet &harr; WinWin exchange system for the Somali market.

The **Customer Wallet** is the single source of balance. Every deposit and
withdrawal, on either rail, passes through it and creates an auditable
order + ledger entry. The backend is the only thing that can ever change a
wallet balance — the mobile apps only ever display what the backend
computed and confirmed.

## Structure

- `supabase/`: **the backend.** Postgres schema, Supabase Auth, the API as
  Postgres functions, row level security, Realtime and the `cashdeskbot`
  Edge Function. Includes end-to-end tests. Start with `supabase/README.md`:
  it has the architecture, the endpoint-by-endpoint migration map and the
  deploy steps.
- `customer-app/`: Flutter app for customers (deposit, withdraw, orders,
  profile). Talks to Supabase.
- `agent-app/`: Flutter app for agents, and the management interface
  (there is no separate admin dashboard). Tabs: Dashboard, Users
  (customers), Reports, History, Account. Agents with the `manage_settings`
  responsibility also get Account → Admin features:
  - payment methods (ON/OFF, rates, fees, limits);
  - deposit numbers and payment integrations;
  - home ads, notifications and app settings;
  - agents and audit logs.
- `backend/`: the original Node.js + Express API.
  - Kept as a fallback while the Supabase backend settles in. It works
    against the same schema.
  - Hosts the optional MobCash automation worker (`npm run worker`), the
    one piece that needs a headless browser.
- `docs/`: architecture notes.

## Backend: Supabase

The apps sign in with Supabase Auth and call the backend through
`supabase.rpc(...)`. Every REST endpoint has a Postgres function returning
the same JSON. Order and wallet changes reach the apps live through
Supabase Realtime. Existing accounts keep their passwords. The old server
(203.161.38.33) and its local database are no longer used.

To deploy:

1. Run the *Deploy to Supabase* action, or merge to `main` and let the
   Supabase GitHub integration apply `supabase/migrations`.
2. Add the `SUPABASE_ANON_KEY` repository secret.
3. Run *Build Customer & Agent APKs*.

Details are in `supabase/README.md`.

## Core flows

```
EVC Plus  --> Customer Wallet --> WinWin
WinWin    --> Customer Wallet --> EVC Plus
```

Deposits never credit the wallet on the customer's say-so. An authorized
agent (EVC Plus: reads the payment SMS on a registered device; WinWin:
observes the confirmed result in the real WinWin Manager app) submits the
verified transaction to the backend, which matches it against the pending
order (phone/WinWin ID + deposit code + amount, dedup'd by provider
transaction reference) before crediting the wallet.

Withdrawals reserve funds out of `available` into `pending` immediately
(so the same balance can never be double-spent), and only move to a
permanent deduction once an agent/admin confirms the payout actually went
out. A failed payout releases the reservation — the customer is never
charged for a withdrawal that didn't happen.

## MobCash / WinWin integration note

WinWin/MobCash has no published public API — only a manager-role login on
the real MobCash Business Web portal (`businessweb-mobi.com`), used to
manually top up a WebUser ID (deposit) or pay out against a withdrawal
code (withdrawal). Two integration modes exist, both behind
Admin &rarr; Payment Integrations &rarr; MobCash Manager:

- **Manual (default)**: an admin/agent operates the real portal directly
  and keys the confirmed result into Badal Exchange, which verifies and
  matches it before crediting/debiting the wallet.
- **Automatic (opt-in, explicitly authorized)**: `backend/src/services/mobcashAutomation.ts`
  drives the same portal via backend-side Playwright browser automation —
  not an official API, since none is confirmed to exist. It defaults to
  **off**, and once turned on, defaults to **dry-run** (drafts every
  withdrawal but stops before the final confirmation) until an admin
  explicitly disables dry-run after reviewing the automation run log. A
  circuit breaker auto-disables live automation after 3 consecutive
  failures rather than retrying blindly. This was built without the
  ability to test against the real portal (network-blocked in the build
  environment) except for the login step, which was verified against a
  real screenshot — everything past login needs live calibration before
  being trusted with real money. See the comment at the top of
  `mobcashAutomation.ts` for the full rationale.
- If MobCash ever publishes an official API, only the adapter functions
  in `mobcashAutomation.ts` need to change — the credential vault, order
  lifecycle, and safety rails around it stay the same.
