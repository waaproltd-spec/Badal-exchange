# BADAL EXCHANGE: what the AI Developer must know before it changes anything

Read this first, then the code you will change. The platform handles real customer money.

## The platform

* **Production = Supabase** (project `onbezsojnpsrtuxzwsjr`): Postgres, Auth, Edge Functions, pg_cron, Realtime. There is no
  application server of our own; the old Node backend (`backend/`) and the server `203.161.38.33` are NOT in use.
* **Customer App** (`customer-app/`, Flutter, package `com.badalexchange`): wallet, deposits, withdrawals, orders, support.
  Texts are Somali.
* **Agent App** (`agent-app/`, Flutter, package `com.badalexchange.agent`): staff app (Dashboard, Users, Reports, Commission,
  History, Account). Managers use it as the **admin dashboard**. Texts use `tr()` / `Tx` with a Somali entry in
  `lib/l10n/somali.dart` for every new text (`test/translations_test.dart` enforces it; keys must be unique).
* **Backend logic = Postgres functions** in `supabase/migrations/` (append-only, one file per change, named
  `YYYYMMDDHHMMSS_name.sql`) plus **Edge Functions** in `supabase/functions/` (Deno): `support-bot`, `telegram-bot` (cashier
  bots), `golis-merchant` (Sahal feed), `push-notifications`, `withdrawal-alerts`, `dev-bot`, `cashdeskbot`, ...
* Apps call `supabase.rpc('function_name', ...)`; the apps never touch tables (row level security, no grants).

## Money, wallets, payments

* Tables: `users`, `wallets` (`available_cents`, `pending_cents`), `ledger_entries` (credit/debit/reserve/release, `balance_after_cents`),
  `orders` (direction deposit/withdraw, status pending/processing/completed/failed/cancelled/expired, `amount_cents`, `wallet_delta_cents`).
* Money moves only through the functions `private.complete_deposit_order`, `private.complete_withdraw_order` and the order
  functions. **Never write to wallets/ledger/orders money columns directly, never "fix" a balance.**
* Deposits are verified by: carrier SMS (`agent_ingest_payment_sms` -> `private.match_sms_log`), **Sahal merchant feed**
  (`merchant_transactions`, `private.merchant_match`), and **SMS 898** (`private.match_sahal_sms`, paired with the feed row so one
  payment credits once). A payment never credits twice; pending stays pending until verified.
* Withdrawals: agent phone USSD payout engine, Sahal transfers, CashdeskBot platforms (1xBet, WinWin, ...).
* The **health monitor** (`private.health_scan`, every minute) checks wallet = ledger and other invariants; a failing check
  is a critical incident, never auto-repaired.

## Rules for every change

1. Migrations are **new files**, idempotent (`IF NOT EXISTS`, `CREATE OR REPLACE`), never edit an applied one.
2. Every `SECURITY DEFINER` function: `SET search_path = ''`, `private.require_*` guard, `REVOKE ... FROM PUBLIC, anon, authenticated`
   then `GRANT` only what is needed. Every table: row level security on, grants revoked from anon/authenticated.
   (`supabase/tests/security_hardening.test.mjs` and the health monitor check this.)
3. When you copy a function to change it, copy the **latest** definition (a later migration may have added guards, e.g.
   `private.require_agent_duty('evc_deposit')` in `agent_ingest_payment_sms`).
4. Add tests: backend `supabase/tests/*.test.mjs` (node:test, rolled-back transactions), Flutter tests in `agent-app/test` and
   `customer-app/test`. Run `flutter analyze` and `flutter test` in the app you changed.
5. No secrets in the repository, logs or messages. Never print a token.
6. Somali for customer-facing text; the owner may write Somali or English.

## How tests and delivery work

* CI `supabase-test.yml`: throwaway local Supabase, applies every migration, runs the backend tests, then both apps' tests.
  The Agent App has **2 known failing end-to-end tests** (`payments_e2e_test.dart`): accepted baseline.
* Deploy: workflow `supabase-deploy.yml` (mode `deploy` or `diagnose` = read-only report). Release APKs: `build-apks.yml`;
  Play Store AAB (Customer App): `build-play-store.yml`; nightly backup with a restore test: `backup.yml`.
* **You only open pull requests.** The owner reviews; deployment needs the owner's approval in the Developer Bot, after green
  Backend + Customer tests and a verified backup.

## Where things are (start here)

| Topic | Look at |
| --- | --- |
| Operations, monitoring, alerts | `docs/OPERATIONS.md`, `supabase/migrations/*_health_monitor.sql` |
| Recovery | `docs/DISASTER_RECOVERY.md` |
| Security notes | `docs/SECURITY_AUDIT.md` |
| Sahal (merchant feed, access code, auto reconnect) | `supabase/functions/golis-merchant`, `*_sahal_*` migrations, `agent-app/lib/sms/` |
| Telegram bots | `supabase/functions/support-bot`, `telegram-bot`, `dev-bot` |
| Scheduled messages and push | `*_scheduled_messages.sql`, `*_scheduled_push.sql`, `agent-app/lib/screens/admin/broadcast_screens.dart` |
| Agent App dashboard / account | `agent-app/lib/screens/dashboard_screen.dart`, `account_screen.dart` |
