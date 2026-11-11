# TEAM BADAL CONTROL – Phase 1: audit of what exists, gap list and implementation plan

Status: **plan only, nothing built, nothing changed in production.** Written before any new service, as the
brief asks (steps 1–7). The rule that shapes everything: **do not build a second copy of a service that already runs.**

## 1. The 12 services against what already exists

| # | Service | Already in production (where) | Missing | Verdict |
|---|---|---|---|---|
| 1 | Master Control | BADAL AGENT bot (`withdrawal-alerts`): `/start`, `/report`, `/movehere`; group linked (TEAM BADAL CONTROL) | one `/status` overview, `/bots` list, on/off per notice type | **extend** `withdrawal-alerts` |
| 2 | Payment Verification | SMS matcher (`match_sms_log`), Sahal merchant feed (`golis-merchant`), wallet phone/SIM check, `transaction_ref` unique, one SMS ↔ one order unique indexes | EVC/ZAAD/eDahab already via SMS; nothing to add | **exists** – do not duplicate |
| 3 | Payment Backup | **Sahal SMS fallback** (`sahal_sms_fallback`, takes over after 90 s), auto reconnect (`sahal_auto_reconnect`), `paired_merchant_id`/`paired_sms_id` stop a double credit, health incident `sahal_feed` + alert | a clear "Sahal down → backup active" Telegram notice with the time it switched | **tiny addition** (one notice) |
| 4 | Withdrawal Monitoring | `withdrawal-alerts`: new / changed / failed / reminder after 15 min / stray Sahal transfers; health `withdrawals_stuck_processing` | – | **exists** |
| 5 | Deposit Monitoring | live notices for credited and failed deposits, unmatched SMS list, health `sms_device_rejected`, `deposits_waiting` style checks | "deposit not confirmed after N min" notice | **small addition** |
| 6 | Fraud Detection | rate limits (Wallet ID lookup 10/min, 40/h), PIN lock escalation, SIM check, duplicate blocks (`duplicate_blocked`), audit log | rules over transactions: repeated withdrawals to one number, many accounts one phone, burst of transfers, unusual amounts | **new (rules in SQL, read-only, alert only – never blocks money by itself)** |
| 7 | System Health | `private.health_scan` (every 2 min): Sahal feed, cron failures, Edge call failures, stuck withdrawals, wallet integrity, … + alert delivery | Supabase usage (DB size, connections, Edge invocations) as a check | **extend** health scan |
| 8 | Database Backup | `backup.yml` + restore test (`DISASTER_RECOVERY.md`) | Telegram report of the result (success / failure) | **small addition** (workflow step) |
| 9 | Smart Finance | daily financial report (00:00 Mogadishu close, 08:00 send), Company Balances, Sahal low-balance notice | expenses/profit-loss need an expenses input that does not exist | **extend report** only with data that exists |
| 10 | Customer Support | `support-bot` (@Badalaisupportbot): link account, deposit/withdraw status, Somali/English, broadcasts | Wallet ID / transfer help, complaints queue | **extend** `support-bot` |
| 11 | Business Analytics | `report_rankings`, agent dashboard, top-5 customers in the daily report | weekly business report to the group | **extend report** |
| 12 | AI Developer | `dev-bot` + `dev-agent.yml` (Haiku, PRs only, approvals, deploy gate) | – | **exists** (needs API credit to run end to end) |

Result: of 12, **5 exist**, **5 need a small extension**, **1 is a real new build (Fraud rules)**, 1 (Smart Finance
expenses) needs a data source first. This is not twelve new bots.

## 2. Architecture decision: one group, a few bots, one set of RPCs

Telegram allows many bots in one group, but twelve tokens means twelve webhooks/pollers and twelve sets of secrets to
guard, and on the free plan every poll is an Edge invocation (500,000 a month limit; we already use ~280–410 k).
So:

- **Roles, not processes.** "Master", "Payment", "Withdrawal", "Deposit", "Fraud", "Health", "Backup", "Finance",
  "Analytics" are **notice categories** sent by the one BADAL AGENT bot (`withdrawal-alerts`), each with its own
  `#tag`, its own on/off switch and its own permission. The group shows them as separate streams by tag.
- **Customer Support stays a separate bot** (@Badalaisupportbot) – it talks to customers and must never share
  internal data. **AI Developer stays separate** (`dev-bot`) – it has its own approval and deploy gate.
- **Central API = the existing RPC layer**: `SECURITY DEFINER` functions, `private.require_service/require_role`,
  `audit_logs`, REVOKE from anon/authenticated. A bot only ever calls RPCs; no bot has a database password.
- **Webhooks over polling where possible:** Telegram `setWebhook` for support-bot/dev-bot removes `getUpdates`
  polling; BADAL AGENT still polls (commands) at the idle pace set on 11 Nov. Database events (credited deposit,
  failed withdrawal, health incident) are already pushed by the database, not polled.

## 3. Security model for the group (all new commands)

- Only Telegram user IDs listed in an allow-list table (`control_admins`: telegram_user_id, role, enabled) may use
  commands; everyone else in the group is ignored. Roles: `viewer` (reports), `operator` (acknowledge incidents),
  `owner` (switch notices on/off, move the group).
- **No command moves money or changes a balance.** Money actions stay in the Agent App with PIN/approval. A Telegram
  command may only read, acknowledge, mute, or ask a human to act. This answers "no payment or balance change without
  authorization" by construction.
- Every command and every setting change is written to `audit_logs` (who, what, when).
- Customer data in the group: Customer ID (wallet code), name, amount – as agreed on 11 Nov; never PINs, passwords,
  tokens, full cookies.
- Duplicate prevention: every notice has a dedupe key in `group_notified` (already built for the daily report).

## 4. Supabase Free Plan budget for the new work

No new cron job and no new always-on worker. New notices ride on the existing 30 s/60 s BADAL AGENT run and on
database triggers that only *enqueue* a row (one insert). Fraud rules run inside the 2-minute health scan, with
indexed predicates over the last hour only. Target: **0 additional Edge invocations in the idle state**, under 5 % more
WAL (the notices are a few rows a day). Every new query gets an `EXPLAIN` check against the 1,300-row tables before merge.

## 5. Implementation order (each step: backup → local test → CI → your "Deploy" → production check → rollback)

1. **Control foundation (partly done: `/status`, deployed 11 Nov):** `control_admins`, `control_settings` (per category on/off), `/status`, `/bots`, `/mute`,
   audit. Rollback: drop the three objects; BADAL AGENT keeps working as today.
2. **Payment Backup notice** ("Sahal down – SMS backup active", "Sahal back") – **built, awaiting Deploy**: `payment_source_todo()` confirms a change of `private.payment_source()` after 2 minutes, stores it once, BADAL AGENT announces it; no money logic touched.
3. **Money seen, not confirmed** notice – **built, awaiting Deploy**: a payment SMS or incoming Sahal transfer still unmatched after 10 minutes is told once (not the SIM-check refusals, which have their own incident; only payments after switch-on).
4. **Backup result to the group** (workflow step, token from existing secret).
5. **System Health additions** (Supabase usage check) and Health notices in the group with the existing incident keys.
6. **Fraud rules v1** (alert only) – needs your list of rules to approve, see §6.
7. **Support bot:** Wallet ID / transfer help, complaints queue.
8. **Finance and Analytics:** weekly report; expenses only if you give a source.

Each step is one migration + tests; production changes only after your explicit "Deploy" as before.

## 6. Decisions needed from you (nothing starts without them)

1. Who may use group commands: give the Telegram usernames/IDs and a role for each (the group has 5 members).
2. Fraud rules v1: approve or change – (a) 3+ withdrawals to the same number in 1 h, (b) 3+ accounts using one phone,
   (c) 5+ wallet transfers in 10 min by one customer, (d) one transaction over a limit you choose (e.g. $200).
3. Do you want separate bot names for Master/Health/Backup/etc. (more tokens to look after), or the tagged streams
   from one BADAL AGENT bot as recommended in §2?
4. Expenses: where do costs come from (manual entry in the Agent App?) – needed for profit/loss.
5. Staging: there is no staging Supabase project; CI's local stack plays that role. A real staging project (free
   plan allows 2 projects) can be created if you want it.
