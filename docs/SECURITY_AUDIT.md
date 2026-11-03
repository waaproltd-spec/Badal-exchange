# BADAL Exchange — Security audit and hardening (2026-10-31)

Scope: the Supabase backend (Postgres, RLS, RPC functions, Edge Functions), the
Customer App, the Agent App / admin dashboard, the payment and wallet engine
(Sahal, EVC Plus, Golis, ZAAD, eDahab), and the Telegram bots (@Badalaisupportbot
and @Badalexchangeadmin; @Badaln8nbot's own code was not changed — see 7).

Method: a static review of every migration (509 functions, 66 tables, 16 policies),
every Edge Function and the two apps' storage and configuration code, followed
by fixes, new automated tests and the full CI suite. What could not be checked
from the code alone (the live Supabase dashboard settings, the production
database contents, the carriers' systems) is listed as such. **Nothing has been
deployed to production, and no production setting has been changed.**

## What was already strong (checked, no change needed)

* Every one of the 509 SQL functions that run with elevated rights
  (`SECURITY DEFINER`) pins its `search_path` — no search-path hijacking.
* Row level security is on for every public table; apps have **no** write
  privilege on any table (all changes go through functions that check the
  caller, audit and are idempotent); `anon` can read only the public payment
  catalog; passwords are never selectable (`password_hash` is outside the column
  grant).
* New functions are closed by default (default privileges revoke execute from
  PUBLIC and anon); the service-only functions (Telegram, workers, support bot)
  also check the service role inside.
* SQL injection: no function builds SQL from user text; the only dynamic SQL
  is fixed (`format('%I')` on catalog names, REVOKE/GRANT loops). Calls are
  parameterized RPC. XSS: the apps are native Flutter (no HTML); the Telegram
  messages escape every customer-supplied value.
* Money integrity: balances have `CHECK (>= 0)`, every balance change happens
  on a locked wallet row, withdrawals are idempotent (key + duplicate guard),
  a deposit can be completed once, KYC limits, first-withdrawal approval and the
  provider-balance check run in database triggers no app can bypass.
* Secrets: no key, token or password is in the repository; the apps get the
  (public) anon key at build time; the payout PIN is stored in Supabase Vault;
  session tokens are kept in Flutter secure storage in both apps; JWTs last one
  hour with refresh-token rotation; one phone per customer account (a new login
  signs the other phone out); password change signs every other session out.
* Edge Functions: workers check a secret that the database verifies, the
  Telegram bot compares its webhook secret in constant time, the SMS hook stores
  only a hash of its token, customer functions pass the caller's own token to
  the database.

## Findings

Severity: **Critical** = money or accounts can be taken by an outsider or a
low-privilege user; **High** = a logged-in user with limited rights can do
something reserved for others, or move money; **Medium** = weakens a defence or
leaks limited information; **Low** = hygiene.

| # | Sev | Finding | Status |
|---|-----|---------|--------|
| 1 | High | **Agent duties were not enforced by the server.** `evc_deposit` / `evc_withdraw` only changed what the Agent App showed. Any active agent (even one with no duties, or only "view company balances") could complete or fail **any** withdrawal (a failed one refunds the customer), reject any deposit, run payouts, and feed payment SMS. | **Fixed** — each of those 8 payment entry points now requires its duty (managers always pass); switch `app_settings.agent_duty_enforcement`. |
| 2 | High | **Any active agent could add up to $100,000 to any wallet, as often as they liked**, without approval (`agent_wallet_adjust`). A stolen or dishonest agent account could create money. | **Mitigated** — ordinary agents are capped per Somalia day (default $2,000, `wallet_adjust_agent_daily_cap`); deductions are not capped; additions of $500+ alert the admin on Telegram; managers remain uncapped but audited. Remaining risk: see R1. |
| 3 | Medium | The audit log could be edited or emptied by the service role / database owner. | **Fixed** — update, delete and truncate are refused by triggers. |
| 4 | Medium | Support bot: a Wallet ID that existed was answered differently from one that did not (an oracle: Wallet IDs are `BE` + 6 digits). | **Fixed** — both are answered identically; only the owner's own Telegram contact finishes linking; wrong IDs are still counted (5 an hour) and now raise an alert. |
| 5 | Medium | Support bot webhook secret compared with `!==` (not constant time). | **Fixed** — constant-time compare. The one-time setup address carries the secret in its URL: **rotate `SUPPORT_BOT_WEBHOOK_SECRET` after setup** (see R4). |
| 6 | Medium | No alerts for suspicious activity (only payment errors and stuck orders). | **Added** — recorded in `security_events` and said once in Somali to the linked admin chat by the existing alert worker: 8+ withdrawals in 10 minutes by one customer, wallet additions of $500+, deposits of $300+, a change of the payment-number permission, 5+ wrong Wallet IDs on the support bot. |
| 7 | Medium | Sign-ups had a per-IP limit only. | **Fixed** — also 150 sign-ups per 10 minutes service-wide (`signup_limit_per_10min`). |
| 8 | Medium | Customer password attempts are limited only by Supabase Auth's own rate limits; the repository has no account lock-out and local config shows `minimum_password_length = 6` (the server's sign-up and change-password rules require 8). | **Open (needs your authorization)** — dashboard settings, see R2. |
| 9 | Medium | Payment SMS are trusted if they come from a registered agent device: `agent_register_device` accepts any device id and `agent_ingest_payment_sms` does not prove the SMS came from the wallet's phone. An agent **with the deposit duty** could submit a forged SMS and get a deposit credited. | **Partly mitigated** (duty now required; large credited deposits alert). Remaining risk: R3. |
| 10 | Medium | Any agent can read all customers' names, phones, wallets and orders directly (the row policies allow every staff member). | **Open** — changing the policies could break the Agent App's live lists; see R5. |
| 11 | Low | Edge Functions allow any origin (`Access-Control-Allow-Origin: *`); they use bearer tokens, not cookies, so this is not exploitable. | Open (cosmetic). |
| 12 | Low | `support_contacts` is callable without sign-in (the login screen's help numbers). | Intended. |
| 13 | Low | Twelve helper functions in the `private` schema (not exposed by the API) could be executed by a signed-out visitor because they were created without the default revoke (found by the new permission scan in CI). | **Fixed** — `anon` and PUBLIC lose execute; signed-in users and the service keep what they had. |

No Critical finding was identified in the code that was reviewed.

## Fixes made (all in `ccr-5f54e215-r24mey`, not deployed)

* `supabase/migrations/20261030001600_security_hardening.sql` — findings 1, 2,
  3, 4 (database side), 6, 7.
* `supabase/functions/support-bot` — 4, 5; `withdrawal-alerts` — sends the new
  alerts (additive; the existing alerts and @Badaln8nbot are unchanged).
* `supabase/diagnostics/security.sql` — read-only checks to run **before**
  deploying (which agents the duty check will refuse, who added money lately).

## Security tests added

`supabase/tests/security_hardening.test.mjs`:

* an agent with no duty / only "view company balances" is refused on all four
  entry points; each duty opens only its own calls; managers pass; the kill
  switch works both ways;
* the guard is present in the 8 entry point definitions and in `register_customer`
  (a later migration that rewrites one must keep it);
* the daily wallet cap (exact to the cent), managers uncapped, deductions uncapped;
* the audit log refuses update, delete and truncate;
* the sign-up limit, and its lifting (run in a rolled-back transaction);
* every alert kind is recorded once, contains no secrets, and is unreadable to customers;
* database permission scan: every public table has RLS, `anon` can only read the
  payment catalog and call nothing sensitive, the apps can write no table, every
  definer function pins its search path.

`support_bot.test.mjs` now also proves a non-existent Wallet ID is answered
exactly like a real one and can never be linked.

## Remaining risks and recommendations

* **R1 — managers can still add unlimited money to wallets.** Recommend a
  second-person approval for additions above a threshold (a pending state a
  different manager confirms), and the Telegram alert already added.
* **R2 — login brute force and password policy (Supabase dashboard,
  requires your authorization; nothing was changed):** Authentication →
  Rate limits (keep sign-ins low per IP), Attack Protection → CAPTCHA, minimum
  password length ≥ 8, "Secure password change", session time-box / inactivity
  timeout, and require re-authentication to change the phone password.
* **R3 — SMS authenticity.** Credit a mobile-money deposit only when the SMS
  agrees with the carrier merchant statement (the Sahal merchant feed you already
  read), or when a second agent/manager confirms amounts above a threshold;
  bind a device id to a one-time pairing secret instead of a free-text id.
* **R4 — after the support bot is set up, rotate `SUPPORT_BOT_WEBHOOK_SECRET`**
  (the setup address put it in a URL). Then re-run `…/support-bot/setup?key=<new>`
  once, or remove that route. The bot token was posted in chat: revoke it in
  @BotFather and set the new token (this was already advised).
* **R5 — restrict direct reads** of `users`/`wallets`/`orders` to agents holding
  a duty, and give the Agent App a function for what it needs; test with the
  live Agent App first.
* **R6 — monitoring:** send `security_events` to a dashboard in the Agent App
  (the management function `manage_security_events` already exists), and alert
  on repeated failed manager logins once Supabase auth logs are available to you.
* **R7 — two-person rule for administrative actions** that change limits,
  agent duties and the payment-number permission (they are audited and, for the
  permission, alerted today).

## Before you deploy

1. Run `supabase/diagnostics/security.sql` (sections 1–2) in the Supabase SQL editor.
   Any agent who does payouts, deposits or SMS must have the matching duty (and
   anyone with only "view company balances" will no longer be able to do payment
   work — that is the intent). Give duties in the Agent App first.
2. Or set `agent_duty_enforcement` to `off` after deploying and turn it on once
   the list is right (the setting is in `app_settings`).
3. Nothing in the migration changes a customer record, a balance or an order.

## CI results

Run 226 (commit b3e1496, "Supabase tests"):

* Backend tests (Auth, RPC, RLS, Realtime, Edge Functions, security and
  permission scan, support bot, dynamic betting platforms): **passed, no failures**.
* Customer App against Supabase: **passed**.
* Agent App against Supabase: **141 passed, 2 failed**. The two failures are the
  known baseline in `payments_e2e_test.dart`; they fail the same way on the
  branch without any of the security changes and are unrelated to them.
  Every new security, payment-number, platform and logo test passes.

Earlier runs on older commits (223–225) failed only because of tests that
polluted the shared test database; those tests were rewritten to run in
rolled-back transactions and the failures are gone in run 226.
