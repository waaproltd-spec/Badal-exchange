# BADAL EXCHANGE – Performance & Resource Audit (Phase 1, read-only)

Date of the measurements: 2026-11-11 00:38 UTC. Source: `supabase/diagnostics/performance.sql`
(run from the *Deploy to Supabase* workflow, mode `performance`; it only reads, it deploys nothing) plus a read of
the migrations, Edge Functions and both apps. **Nothing in production was changed.** Statistics are cumulative
since 2026-09-29 unless a "since" date is given.

What cannot be read from SQL: the real Supabase **Disk I/O budget %** and the **Edge Function invocation count**
for the month. Both are on the dashboard (*Reports → Database* and *Usage*); please look at them once and tell me,
so the estimates below can be checked.

## 1. Summary

| | Finding | Size of the problem |
|---|---|---|
| 1 | The load is **writes**, not reads: cache hit 100 %, only 1,959 disk block reads in total, but 618,581 buffers written by checkpoints and ~2 GB of WAL from a handful of statements | main Disk I/O driver |
| 2 | **Write amplification** (same value written again): `resweep_unmatched_sms` 522 MB WAL, 723,750 updates on a 1,181-row table; Sahal feed worker ~230 MB WAL (status, cookies, balance rewritten every 10 s); `company_balance_record` 415 MB WAL | ~75 % of the tracked WAL |
| 3 | **pg_cron run history** never pruned: 307,000 rows, 57 MB (half of the 115 MB database), ~300 MB WAL to log the runs. The housekeeping job I added on 5 Nov has **never run** (0 runs, 245,743 rows older than 3 days still there) | disk + I/O |
| 4 | **Edge Function invocations** by cron alone ≈ 350–410 k / month of the 500 k free limit (10 s feed 259 k, withdrawal alerts 86 k, broadcast 43 k, health 17 k, balances 9 k), before any customer, agent or Telegram traffic | quota risk |
| 5 | `health_tick` (every minute) averages 1.98 s, p95 4.9 s, max 23.7 s = ~33 min of database time a day; 5,376 incident updates | CPU + I/O |
| 6 | `platform_kick_if_work` (every minute) 167 ms average × 29,695 runs; `payment_integrations` had 8.3 million sequential scans | CPU |
| 7 | 74 GB of temporary files written since 29 Sep (32,513 files). **Not attributable**: no tracked statement writes temp files now. Needs a before/after measurement (section 6) | unknown |
| 8 | 37 payment SMS in the last 24 h are *Rejected by the wallet phone/SIM check* and are re-checked every minute. This is also a **business** item, see section 5 | functional |

Healthy: 15 of 60 connections in use, cache hit 100 %, no table scanned in full more than by index (section 5 of
the report is empty), storage buckets unused, realtime schema 312 kB, only 8 realtime tables, no debug logging
(0 `console.log` in the Edge Functions, only error/warn), no `select *` and no table reads from the apps (they call
RPCs), no N+1 pattern found.

## 2. Resource consumption (measured)

Database 115 MB of 500 MB. Biggest: `cron.job_run_details` 57 MB, `cashdesk_balances` 13 MB (58,981 insert-only rows),
`audit_logs` 9.4 MB (financial/security audit, keep), `net._http_response` 5.2 MB (self-cleaning).

Most WAL written by one statement (tracked since the statistics reset):

| WAL | Calls | Statement | Cause |
|---|---|---|---|
| 522 MB | 49,477 | `resweep_unmatched_sms()` | re-writes `match_failure_reason` of every unmatched SMS (24 h window) each minute with the same text |
| 415 MB | 58,992 | `company_balance_record` | inserts a balance row every 5 min per method even when nothing changed |
| 108 MB | 116,755 | merchant feed `set_state` | 10 s worker rewrites the status row |
| ~300 MB | 307,022 × 5 | `cron.job_run_details` insert/update ×5 | each cron run is logged with 5 writes; 10 s feed job = 8,640 runs a day |
| 89 MB | 14,796 | Sahal balance record | rewritten every run |
| 35 MB | 116,801 | merchant feed cookies | rewritten every run |

Rows written to one-row tables: `sahal_payout_settings` 109,443 updates, `merchant_feed_sessions` 234,073,
`merchant_feed_status` 120,426, `withdrawal_alert_chat` 47,134, `merchant_transactions` 75,397 updates on 381 rows.

Cron jobs (11): feed every 10 s (111,084 runs), withdrawal alerts every 30 s (38,242), resweep every minute (49,471),
platform orders / push / broadcast / broadcast-push / health every minute, company balances every 5 min, dev bot
every minute (gated, 82 HTTP calls), housekeeping daily (0 runs). No failures in any job.

## 3. Root causes

1. Several workers and the matcher write the same value again instead of only on change.
2. The 10-second feed job and the 30-second alert job are logged by pg_cron (5 writes per run) and call the Edge
   Function every time, even when nothing is waiting (`withdrawal_alerts_kick` and `broadcast_kick` have no
   "is there work" check; the push and platform kicks do).
3. ~~The housekeeping job did not run~~ **Correction (second measurement, 2026-11-11 12:33 UTC):** it did run, once, at 03:11 UTC
   that day (4.5 s, one 245k-row delete; history now 70k rows). My first reading was taken at 00:38 UTC, before its first
   scheduled moment. What remains is that one big delete is slow and the table keeps 3 days.
4. `platform_eligible()` is evaluated for every order row each minute before any status filter.
5. `cashdesk_balances` is an insert-only history written on every refresh.

## 4. Recommendations (each needs your approval; nothing is applied yet)

Risk legend: **L** no financial code touched, **M** touches code next to payments but not matching/crediting
logic, tests required, **H** changes payment timing (not recommended without a decision).

| # | Change | Saves | Risk |
|---|---|---|---|
| A1 | Prune `cron.job_run_details` older than 3 days **in batches of 20,000** (never one huge delete) and find why the housekeeping job never ran; check it fires at the next 03:11 UTC | −45 MB, less vacuum I/O | L |
| A2 | Drop the duplicate index `dev_audit_recent` (same columns as the primary key) | trivial | L |
| A3 | Drop `idx_cashdesk_balances_requested_by` (0 scans, adds write cost to a table written every 5 min; I added it on 5 Nov, my mistake) | write overhead | L |
| B1 | `withdrawal_alerts_kick`: call the function only when `withdrawal_alerts_todo()` has something (the function does this check itself first, so behaviour is identical) | −86 k invocations/month, 2,880 cron runs a day | L |
| B2 | `broadcast_kick`: call only when a schedule is due or deliveries are pending (same gate the push kick already uses) | −43 k invocations/month | L |
| B3 | Health scan every 2 minutes instead of 1 (heavy checks every 5), update an open incident only when it changed or every 10 min | −50 % of ~33 min/day DB time and incident writes; alert delay +1 min | L |
| B4 | Feed worker writes status / cookies / balance **only when they changed** (plus a heartbeat every minute); the 10 s polling and the payment flow stay as they are | ~−230 MB WAL sample, −460 k row updates | M |
| C1 | `resweep_unmatched_sms` / `match_sahal_sms` / `match_sms_log`: skip an UPDATE that would write the same `match_failure_reason` (`... WHERE column IS DISTINCT FROM new value`). Matching results and crediting are untouched | −522 MB WAL (largest single item), −720 k updates | M |
| C2 | `company_balance_record`: insert a new row only when the balance or the limit changed, plus one row an hour. Needs a check of what the Company Balances screen charts (it reads per period) | −415 MB WAL, table stops growing | M |
| C3 | `platform_kick_if_work`: filter `status IN ('pending','processing') AND created_at > now() - 1 day` before calling `platform_eligible()` | 167 ms → a few ms per minute, −8 M heap reads | M |
| D1 | Customer App account check every 20 s → 60 s plus an immediate check when the app comes to the foreground. **Balances, deposits, withdrawals and payment status stay live (Realtime); no financial value is cached** | fewer calls as customers grow | L |
| E1 | Slow the 10 s feed polling when no deposit/withdrawal is waiting | −up to 70 % of feed invocations | **H** (adds up to ~30 s to a Sahal payment that arrives with no open order; the SMS 898 fallback still works). **Not recommended**; only if B1–B4 are not enough |

Not recommended (the data says no): new indexes. The five foreign keys without an index (`orders.agent_id`,
`exchange_rate_id`, `fee_id`, `sms_logs.agent_id`, `push_notifications.customer_id`) are on tables of ~1,200 rows
with no scan problem; an index would only add write cost (orders already has 8 indexes). Re-check when a table
passes ~20,000 rows. No changes to `audit_logs`, `ledger_entries`, `orders`, wallets or any financial table's data.

**Expected result of A1 + B1–B4 + C1–C3 together:** about 70–80 % less WAL from the measured top statements,
~130 k fewer Edge Function invocations a month (≈ 410 k → ≈ 280 k worst case), ~45 MB less database size, roughly
half of the health-scan database time, and no change in how a deposit or withdrawal is matched, credited or paid.

## 5. Business finding (not a performance change)

37 SMS received in the last 24 h were rejected with *"Rejected by the wallet phone/SIM check: expects the evc_plus
wallet's…"*. If some of them are real customer payments, those deposits are waiting. This is the wallet SIM check
setting, which needs your decision in the Agent App (Settings): whether the check should stay strict. I did not touch it.

## 6. Verification plan (Phase 4, after approval)

- Backend tests (Auth, RPC, RLS, Realtime) and Customer App tests on every change; Agent App baseline unchanged.
- The existing financial integrity section of the diagnostics must stay at 0 (completed deposits without a
  reference, double credit, wallet delta, orders without ledger) before and after.
- `sahal_sms_fallback`, `sahal_auto_reconnect`, `golis_merchant`, `health_monitor` and company balance tests must pass.
- Re-run `performance.sql` the next day and compare: WAL by statement, rows updated per table, cron run count,
  `temp_bytes` (74 GB at this measurement) and the invocation count on the dashboard.
- Every migration is shown to you as SQL first; deployment only after your explicit "Deploy" and green CI,
  with the backup and restore test unchanged.


---

## 7. Phase 2 – what was changed (migration `20261111000500_performance_optimizations.sql`)

Second baseline (production, 2026-11-11 12:33 UTC, `performance` run 43021388745): `health_tick` 8,408 calls × 1.54 s;
`platform_kick_if_work` 30,411 × 174 ms; `resweep_unmatched_sms` 50,191 calls, **543 MB WAL**, 66,389 blocks dirtied;
`company_balance_record` 60,636 calls, **427 MB WAL**, 124,914 blocks dirtied; feed `set_state` 121,018 calls 113 MB;
cron run history 317,850 runs logged (5 writes each, ~310 MB WAL); `withdrawal_alerts_kick` 48,298 and
`broadcast_kick` ~4,900/3 days of empty Edge calls; `cron.job_run_details` scanned in full 9,488 times (2.2 billion
rows read) by the health scan's "failed cron jobs" check.

| Change | Mechanism | Not touched |
|---|---|---|
| Housekeeping every 6 h, keeps 1 day, deletes in batches of 20,000 | `private.housekeeping()` | any customer or financial data |
| Drop `dev_audit_recent` (duplicate of the primary key) and `idx_cashdesk_balances_requested_by` (0 scans) | `DROP INDEX` | constraints, data |
| `sms_logs`, `merchant_transactions`: an UPDATE that changes nothing is skipped | PostgreSQL's `suppress_redundant_updates_trigger()` (BEFORE UPDATE) | matching logic: every real change goes through |
| Feed session/cookies saved at most every 5 min when unchanged; feed status heartbeat 30 s (readers use 2–3 min limits); alert-chat poll time 5 min | `private.skip_heartbeat_update()` | state, message, result code, rows seen: written at once |
| Company balance: 3rd identical read only moves the newest row's time | `company_balance_record` | first/last row of a steady period kept; a change, error or person's read = new row; freshness checks read max(checked_at) |
| Broadcast worker woken only when a schedule is due or a message waits | `broadcast_kick` | |
| BADAL AGENT worker: every 30 s while a withdrawal is open or touched in the last 30 min, once a minute when idle | `withdrawal_alerts_kick` | the function still reads Telegram commands, sends reports and notices |
| Platform kick filters `status='pending'`, `auto_claimed_at IS NULL`, last day first | `platform_kick_if_work` | same eligibility rule (`platform_eligible`) |
| Health scan every 2 minutes | cron schedule | every check and alert |
| Customer App account check 20 s → 60 s (also checked when the app returns to the foreground, as before) | `auth_provider.dart` | a blocked account is still refused by every call at once |
| APK: `--target-platform android-arm,android-arm64` (no x86 build), unused `cupertino_icons` and `http` removed | `build-apks.yml`, pubspecs | R8 shrinking is already on by default in `flutter build apk --release` |

Not done, with the reason: `company_balance_record` change-only *inserts* were done as above, but the feed status
heartbeat is kept at 30 s and `sahal_payout_settings.balance_seen_at` is untouched (it gates payouts); slowing the 10 s
feed (E1) stays rejected; no new indexes (tables under 1,300 rows); PNG/WAV assets are only 950 KB in total.

### Measured result of the APK change (build 145 → 146, same code except the build flag and the removed dependencies)

| APK | Before | After | Change |
|---|---|---|---|
| Customer App | 55,763,703 B (53.2 MiB) | 36,643,937 B (34.9 MiB) | −34 % |
| Agent App | 59,626,260 B (56.9 MiB) | 39,064,549 B (37.3 MiB) | −34.5 % |

Tests on commit eee7fc0 (CI run 43023387511): Backend (Auth, RPC, RLS, Realtime) passed, including the new
`performance.test.mjs` (5 tests); Customer App passed (347 tests; local run 347 passed, analyzer unchanged at 52 existing
infos); the *Agent App against Supabase* step fails as on every earlier run of this branch (not caused by this change; local
Agent App run: all tests passed, analyzer unchanged). Database before/after numbers come from re-running
`performance.sql` one day after deployment (cumulative counters are compared by delta).
