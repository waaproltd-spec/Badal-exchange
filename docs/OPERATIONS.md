# Badal Exchange: operations, monitoring and self-healing

Production is **Supabase** (Postgres, Auth, Edge Functions, cron, Realtime, managed by Supabase) plus the two
Flutter apps and the Telegram bots. There is no application server of our own (no PM2, Nginx, Caddy or SSH
access to run): the old test server `203.161.38.33` is shared with other apps and is no longer used by
production. Supabase looks after the operating system, disk, PostgreSQL service, TLS certificates, DNS and the
firewall; what we watch and repair is everything above that.

## What watches the platform (24/7, nothing to start)

`private.health_scan()` runs **every minute** from pg_cron (`baari-health`). It checks:

| Incident key | Watches | Level | Safe repair it makes | Never |
| --- | --- | --- | --- | --- |
| `sahal_feed` | Sahal feed reads fresh, sign-in state | critical after 15 min | wakes the worker; restarts a sign-in stuck for 5 min | |
| `cron_failed:<job>` | pg_cron jobs that failed in 15 min | warning | | |
| `edge_calls_failing` | database → Edge Function calls (403/5xx/timeout) | warning | | |
| `withdrawals_stuck_processing` | withdrawals "processing" > 30 min | critical, money | | pay or fail it by itself |
| `withdrawals_waiting_long` | withdrawals pending > 3 h | warning | | |
| `sms_device_rejected` | payment SMS refused by the wallet phone/SIM check | critical, money | | |
| `ledger_wallet_mismatch`, `ledger_held_mismatch`, `ledger_negative_balance`, `ledger_double_credit` | wallet = last ledger balance, held = open withdrawals, no negative balance, no deposit credited twice | critical, money | | **change any balance, ledger entry or order** |
| `db_connections`, `db_long_queries`, `db_lock_waits` | connections > 80 %, queries > 3 min, lock waits > 60 s | warning | | |
| `push_failing` | push notifications failing (a gone FCM token is not counted) | warning | | |
| `broadcast_stuck` | scheduled messages stuck "sending" > 15 min | warning | puts them back in the queue | |
| `integration:<method>` | the latest CashdeskBot balance read of each platform | warning | | |
| `owner_chat_not_linked`, `withdrawal_alerts_bot` | can the owner be told | warning | | |
| `agent_sms_reader` | any phone reading SMS in 24 h (Agent SIM fallback) | info | | |
| `security_tables_without_rls`, `security_definer_without_search_path` | the security posture of every new migration | critical | | |
| `webhook:support-bot`, `telegram_support_bot_token`, `webhook:cashier:<brand>`, `telegram_cashier_token:<brand>` | Telegram webhooks and tokens (every 5 min, by the Edge Functions) | critical / warning | registers the webhook again (without dropping pending updates) | |

Rules of the monitor: **one incident per problem** (a second sighting only counts it); a flicker shorter than
2 minutes is not reported; a repair is tried **at most 3 times, 5 minutes apart**, is judged by the next scan
("worked: the condition is gone"), and after the third that did not help the incident is handed to the
developer instead of being retried for ever. A check that crashes becomes its own incident and never stops the
others. The Sahal feed also signs in again by itself (`merchant_feed_auto_recover`, limited to 4 an hour), and the
Agent App reads Sahal's access code while the app is closed.

## How the owner is told

The support bot sends the alert to the admin chat (`support_admin`, set by `/start` from @Badalexchangeadmin or
`/linkgroup`), in Somali: problem, system, details, cause, repair tried and its result, whether customers or
money are affected, whether a developer is needed. Once when it starts (after 2 minutes), again every 6 hours
while a critical one is open (24 for a warning), and once when it is resolved. Info items are never sent.
The same list is in the Agent App: **Dashboard card** and **Account > System Health** (managers).

## What is NOT automatic, by design

* Money is never repaired automatically. A failed wallet/ledger check only raises a critical incident; a
  person finds the cause first. Pending payments stay pending until verified.
* The monitor cannot change a Telegram token, a CashdeskBot key, a Sahal password or the wallet phone/SIM
  setting: those incidents tell the owner exactly what to change.
* A permanent failure is not retried for ever (3 repairs, then the developer).

## Backups and recovery

See `DISASTER_RECOVERY.md`. A nightly encrypted dump is restored into a scratch database and compared with the
source before it is kept (`.github/workflows/backup.yml`).

## Where to look

* Agent App: Dashboard card, Account > System Health.
* Read-only report from the repository: Actions > "Deploy Supabase" > mode `diagnose` (sections 5-32: feed,
  cron, edge calls, stuck orders, integrity, database health, security posture, health monitor).
* Supabase dashboard: Edge Functions logs, Database > Backups.


## The BADAL AGENT group: daily report and live notices

The Telegram chat linked to the BADAL AGENT bot (the one that already receives the withdrawal alerts) is the monitoring centre.

- **The day** runs 00:00 -> 23:59:59 Africa/Mogadishu (it was 21:00). At 00:00 the day that ended is *closed* into `public.daily_reports`
  (a saved, final snapshot, kept for good; `pg_cron` job `baari-daily-report` at 21:00 UTC, and the group worker closes a missed day by itself).
  In the morning (08:00, setting `daily_report_hour`) the worker sends the closed report once. Nothing in orders, wallets, ledger or commission is changed by closing.
- **The report** has: deposits, withdrawals, payouts (paid to customers), transactions, pending, failed, agent earnings, the top 5 customers (masked phone),
  the agents, and an errors section (failed orders with code / amount / provider / time / reason, refused attempts, system incidents, insufficient balance, stuck orders).
  Deposits = deposit orders completed in the day; withdrawals = withdrawal orders completed in the day; payouts = what the customers received (net of fee).
- **`/report`** in the linked chat shows today so far; `/report 2026-11-10` shows a saved day.
- **Live notices** (once each, remembered in `public.group_notified`): a credited deposit, a failed deposit or platform payout, the Sahal balance below
  `sahal_low_balance_usd` ($50 until set). The withdrawal, payment-incident, security, stuck-order and health alerts were already sent there.
- **Telegram failures:** 429 (it says how long to wait) and 5xx are retried; a report that could not be sent is claimed again after 2 minutes and resumes after the
  parts that already went (10 attempts at most; the last error is kept in `daily_reports.last_error` and the run is reported as a bot error).
- Check: the diagnostics report (section 33).
