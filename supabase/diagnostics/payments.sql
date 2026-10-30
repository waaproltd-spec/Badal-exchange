-- Read-only report on production deposits and withdrawals (see
-- .github/workflows/diagnose-payments.yml). Run with: psql -v hours=48 -f this.
-- Order codes only; no names or phone numbers.
-- Read only for the whole session; each query stands alone so one error hides nothing.
SET default_transaction_read_only = on;
\echo '== 1. Orders in the window: count and time to completed (minutes) =='
SELECT o.direction, o.method, o.status, count(*) AS n,
       round(percentile_cont(0.5) WITHIN GROUP (ORDER BY extract(epoch FROM o.completed_at - o.created_at) / 60)::numeric, 1) AS p50_min,
       round(percentile_cont(0.9) WITHIN GROUP (ORDER BY extract(epoch FROM o.completed_at - o.created_at) / 60)::numeric, 1) AS p90_min,
       round(max(extract(epoch FROM o.completed_at - o.created_at) / 60)::numeric, 1) AS max_min
FROM public.orders o WHERE o.created_at > now() - make_interval(hours => :hours)
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;

\echo '== 2. Open orders now (pending / processing), oldest first, with why a withdrawal waits =='
SELECT o.order_code, o.direction, o.method, o.status, private.money(o.amount_cents) AS amount,
       round(extract(epoch FROM now() - o.created_at) / 60) AS age_min,
       o.payout_review, o.automation_attempts,
       CASE WHEN o.direction = 'withdraw' AND o.method IN ('evc_plus', 'edahab') THEN private.payout_block(o) ->> 'code' END AS phone_block,
       (SELECT a.status || ' ' || coalesce(a.result_code, '') || ' ' || left(coalesce(a.reply, ''), 90)
          FROM public.sahal_payout_attempts a WHERE a.order_id = o.id) AS sahal,
       left(o.failure_reason, 80) AS note
FROM public.orders o WHERE o.status IN ('pending', 'processing')
ORDER BY o.created_at LIMIT 60;

\echo '== 3. Failed orders in the window and their reasons =='
SELECT o.direction, o.method, left(coalesce(o.failure_reason, '(none)'), 100) AS reason, count(*) AS n
FROM public.orders o WHERE o.status = 'failed' AND o.updated_at > now() - make_interval(hours => :hours)
GROUP BY 1, 2, 3 ORDER BY n DESC LIMIT 40;

\echo '== 4. Sahal payout attempts in the window =='
SELECT a.status, a.mode, coalesce(a.result_code, '') AS code, left(coalesce(a.reply, ''), 110) AS reply, count(*) AS n,
       round(avg(extract(epoch FROM a.completed_at - a.created_at)))::int AS avg_sec
FROM public.sahal_payout_attempts a WHERE a.created_at > now() - make_interval(hours => :hours)
GROUP BY 1, 2, 3, 4 ORDER BY n DESC LIMIT 30;
SELECT mode, private.money(daily_limit_cents) AS daily_limit, methods FROM public.sahal_payout_settings;

\echo '== 5. Sahal merchant feed =='
SELECT provider, state, result_code, left(message, 120) AS message,
       to_char(checked_at, 'MM-DD HH24:MI') AS checked, to_char(last_ok_at, 'MM-DD HH24:MI') AS last_ok, rows_seen
FROM public.merchant_feed_status;

\echo '== 6. Payout phone dials in the window (EVC Plus / eDahab) =='
SELECT d.status, count(*) AS n FROM public.payout_dial_attempts d
WHERE d.created_at > now() - make_interval(hours => :hours) GROUP BY 1 ORDER BY n DESC;
SELECT method, mode, private.money(daily_limit_cents) AS daily_limit, private.money(min_balance_cents) AS min_balance
FROM public.payout_auto_settings ORDER BY method;

\echo '== 7. Payment SMS in the window: matched or not =='
SELECT coalesce(s.parsed_provider, '?') AS provider, s.match_status, count(*) AS n
FROM public.sms_logs s WHERE s.received_at > now() - make_interval(hours => :hours)
GROUP BY 1, 2 ORDER BY 1, n DESC;

\echo '== 8. Edge Function calls from the database that failed (pg_net) =='
SELECT r.status_code, left(coalesce(r.error_msg, r.content::text, ''), 140) AS answer, count(*) AS n,
       to_char(max(r.created), 'MM-DD HH24:MI') AS last
FROM net._http_response r
WHERE r.created > now() - make_interval(hours => :hours) AND (r.status_code IS NULL OR r.status_code >= 400)
GROUP BY 1, 2 ORDER BY n DESC LIMIT 20;
SELECT 'pg_net responses kept: ' || count(*) || ', ok: ' || count(*) FILTER (WHERE status_code < 400)
FROM net._http_response WHERE created > now() - make_interval(hours => :hours);

\echo '== 9. Scheduled jobs: last run and failures =='
SELECT j.jobname, j.schedule, j.active,
       (SELECT to_char(max(d.start_time), 'MM-DD HH24:MI') FROM cron.job_run_details d WHERE d.jobid = j.jobid) AS last_run,
       (SELECT count(*) FROM cron.job_run_details d WHERE d.jobid = j.jobid AND d.status <> 'succeeded'
          AND d.start_time > now() - make_interval(hours => :hours)) AS failed,
       (SELECT left(d.return_message, 120) FROM cron.job_run_details d WHERE d.jobid = j.jobid AND d.status <> 'succeeded'
          ORDER BY d.start_time DESC LIMIT 1) AS last_error
FROM cron.job j ORDER BY j.jobname;

\echo '== 10. Consistency: wallets vs ledger vs open withdrawals (should all be 0) =='
SELECT 'wallets whose balance is not the last ledger balance: ' || count(*)
FROM public.wallets w
JOIN LATERAL (SELECT l.balance_after_cents FROM public.ledger_entries l WHERE l.wallet_id = w.id
              ORDER BY l.created_at DESC, l.id DESC LIMIT 1) last ON true
WHERE last.balance_after_cents <> w.available_cents;
SELECT 'wallets whose held amount is not their open withdrawals: ' || count(*)
FROM public.wallets w
WHERE w.pending_cents <> COALESCE((SELECT sum(o.wallet_delta_cents) FROM public.orders o
                                    WHERE o.customer_id = w.customer_id AND o.direction = 'withdraw'
                                      AND o.status IN ('pending', 'processing')), 0);
SELECT 'negative balances: ' || count(*) FROM public.wallets WHERE available_cents < 0 OR pending_cents < 0;
SELECT 'completed deposits credited more than once: ' || count(*) FROM (
  SELECT l.order_id FROM public.ledger_entries l JOIN public.orders o ON o.id = l.order_id
  WHERE o.direction = 'deposit' AND l.entry_type = 'credit' GROUP BY l.order_id HAVING count(*) > 1) x;
SELECT 'withdrawals with more than one successful Sahal transfer or a Sahal transfer and a phone payout: ' || count(*)
FROM public.orders o
WHERE EXISTS (SELECT 1 FROM public.sahal_payout_attempts a WHERE a.order_id = o.id AND a.status = 'success')
  AND EXISTS (SELECT 1 FROM public.payout_dial_attempts d WHERE d.order_id = o.id AND d.status IN ('success', 'completed'));
SELECT 'merchant transfers matched to two orders: ' || count(*) FROM (
  SELECT matched_order_id FROM public.merchant_transactions WHERE matched_order_id IS NOT NULL
  GROUP BY 1 HAVING count(*) > 1) x;

\echo '== 11. Alerts: is the Telegram withdrawal chat linked, and Sahal alert state =='
SELECT chat_id IS NOT NULL AS linked, checked_at, left(last_error, 120) AS last_error,
       to_jsonb(c) ->> 'sahal_alert_key' AS sahal_alert FROM public.withdrawal_alert_chat c;

\echo '== 12. Open deposits and the payment SMS of the window, one by one (numbers: last 4 digits) =='
SELECT o.order_code, o.method, o.status, private.money(o.amount_cents) AS amount,
       right(regexp_replace(coalesce(o.phone_number, ''), '\D', '', 'g'), 4) AS phone_end,
       to_char(o.created_at, 'MM-DD HH24:MI:SS') AS created, o.via_merchant
FROM public.orders o
WHERE o.direction = 'deposit' AND (o.status IN ('pending', 'processing') OR o.created_at > now() - make_interval(hours => :hours))
ORDER BY o.created_at DESC LIMIT 30;
SELECT to_char(s.received_at, 'MM-DD HH24:MI:SS') AS received, s.sender, coalesce(s.parsed_provider, '?') AS provider,
       s.parsed_amount AS amount, right(regexp_replace(coalesce(s.parsed_phone, ''), '\D', '', 'g'), 4) AS phone_end,
       s.match_status, left(coalesce(s.match_failure_reason, ''), 90) AS reason,
       (SELECT o.order_code FROM public.orders o WHERE o.id = s.matched_order_id) AS matched, left(coalesce(s.device_id, ''), 12) AS device
FROM public.sms_logs s WHERE s.received_at > now() - make_interval(hours => :hours)
ORDER BY s.received_at DESC LIMIT 40;
\echo '-- SMS phones: last payment SMS sent in'
SELECT left(coalesce(s.device_id, '?'), 12) AS device, to_char(max(s.received_at), 'MM-DD HH24:MI:SS') AS last_sms,
       to_char(max(s.created_at), 'MM-DD HH24:MI:SS') AS last_upload, count(*) FILTER (WHERE s.received_at > now() - interval '24 hours') AS last_24h
FROM public.sms_logs s GROUP BY 1 ORDER BY max(s.created_at) DESC LIMIT 10;

\echo '== 13. Largest completed orders, all time (to check report figures; numbers: last 4 digits) =='
SELECT o.order_code, o.direction, o.method, private.money(o.amount_cents) AS amount, private.money(o.fee_cents) AS fee,
       u.role, left(coalesce(u.name, ''), 20) AS customer, right(u.phone, 4) AS phone_end,
       to_char(o.created_at, 'YYYY-MM-DD HH24:MI') AS created, left(coalesce(o.transaction_ref, ''), 30) AS ref,
       (SELECT count(*) FROM public.ledger_entries l WHERE l.order_id = o.id) AS ledger_rows
FROM public.orders o JOIN public.users u ON u.id = o.customer_id
WHERE o.status = 'completed' ORDER BY o.amount_cents DESC LIMIT 12;
\echo '-- completed orders by amount band'
SELECT CASE WHEN amount_cents >= 10000000 THEN '>= $100,000' WHEN amount_cents >= 100000 THEN '$1,000 - $99,999'
            WHEN amount_cents >= 10000 THEN '$100 - $999' ELSE '< $100' END AS band, count(*) AS n, private.money(sum(amount_cents)) AS total
FROM public.orders WHERE status = 'completed' GROUP BY 1 ORDER BY min(amount_cents) DESC;

\echo '== 14. Customers by phone network (read-only; accounts outside 61/77/90/63/62 are only listed, never changed; numbers: last 4 digits) =='
SELECT coalesce(private.customer_network(u.phone), 'NOT APPROVED') AS network, left(right(regexp_replace(u.phone, '\D', '', 'g'), 9), 2) AS prefix,
       count(*) AS customers, count(*) FILTER (WHERE w.available_cents <> 0) AS with_balance
FROM public.users u LEFT JOIN public.wallets w ON w.customer_id = u.id
WHERE u.role = 'customer' GROUP BY 1, 2 ORDER BY 1, 2;
\echo '-- customers whose number starts with another prefix'
SELECT right(u.phone, 4) AS phone_end, left(coalesce(u.name, ''), 20) AS name, to_char(u.created_at, 'YYYY-MM-DD') AS registered,
       private.money(coalesce(w.available_cents, 0)) AS balance,
       (SELECT count(*) FROM public.orders o WHERE o.customer_id = u.id AND o.status = 'completed') AS completed_orders
FROM public.users u LEFT JOIN public.wallets w ON w.customer_id = u.id
WHERE u.role = 'customer' AND private.customer_network(u.phone) IS NULL ORDER BY u.created_at DESC LIMIT 50;

\echo '== 15. Orders that are not final: how many, how old, and why (read-only; numbers: last 4 digits) =='
\echo '-- pending / processing by direction, method and age'
SELECT o.direction, o.method, o.status, count(*) AS n,
       count(*) FILTER (WHERE o.created_at > now() - interval '30 minutes') AS under_30m,
       count(*) FILTER (WHERE o.created_at <= now() - interval '30 minutes' AND o.created_at > now() - interval '2 hours') AS m30_2h,
       count(*) FILTER (WHERE o.created_at <= now() - interval '2 hours' AND o.created_at > now() - interval '24 hours') AS h2_24h,
       count(*) FILTER (WHERE o.created_at <= now() - interval '24 hours') AS over_24h,
       to_char(min(o.created_at), 'MM-DD HH24:MI') AS oldest
FROM public.orders o WHERE o.status IN ('pending', 'processing')
GROUP BY 1, 2, 3 ORDER BY 1, 2, 3;
\echo '-- the 40 oldest (withdrawals: delay = what the customer is told; sahal = the last transfer attempt)'
SELECT o.order_code, o.direction, o.method, o.status, private.money(o.amount_cents) AS amount,
       to_char(o.created_at, 'MM-DD HH24:MI') AS created, round(extract(epoch FROM now() - o.created_at) / 3600, 1) AS hours_old,
       right(coalesce(o.phone_number, ''), 4) AS phone_end,
       CASE WHEN o.direction = 'withdraw' THEN private.withdrawal_delay(o) END AS delay,
       (SELECT a.status || '/' || coalesce(a.result_code, '') FROM public.sahal_payout_attempts a WHERE a.order_id = o.id ORDER BY a.created_at DESC LIMIT 1) AS sahal,
       (SELECT count(*) FROM public.payout_dial_attempts d WHERE d.order_id = o.id) AS dials,
       left(coalesce(o.failure_reason, ''), 40) AS note
FROM public.orders o WHERE o.status IN ('pending', 'processing') ORDER BY o.created_at LIMIT 40;
\echo '-- consistency: money and status that disagree (should all be 0)'
SELECT 'withdrawal failed/cancelled/expired but the reserved money was never released' AS check,
       count(*) AS n
FROM public.orders o
WHERE o.direction = 'withdraw' AND o.status IN ('failed', 'cancelled', 'expired')
  AND EXISTS (SELECT 1 FROM public.ledger_entries l WHERE l.order_id = o.id AND l.entry_type = 'reserve')
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries l WHERE l.order_id = o.id AND l.entry_type = 'release')
UNION ALL
SELECT 'completed deposit with no credit in the ledger', count(*)
FROM public.orders o WHERE o.direction = 'deposit' AND o.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries l WHERE l.order_id = o.id AND l.entry_type = 'credit')
UNION ALL
SELECT 'completed without a completed_at', count(*) FROM public.orders o WHERE o.status = 'completed' AND o.completed_at IS NULL
UNION ALL
SELECT 'pending/processing with a completed_at', count(*) FROM public.orders o WHERE o.status IN ('pending', 'processing') AND o.completed_at IS NOT NULL
UNION ALL
SELECT 'withdrawal completed with no debit/reserve', count(*)
FROM public.orders o WHERE o.direction = 'withdraw' AND o.status = 'completed'
  AND NOT EXISTS (SELECT 1 FROM public.ledger_entries l WHERE l.order_id = o.id AND l.entry_type IN ('debit', 'reserve'));
\echo '-- final statuses over all time'
SELECT direction, status, count(*) AS n FROM public.orders GROUP BY 1, 2 ORDER BY 1, 2;

\echo '== 16. Sahal sign-in code: feed state, SMS forwarder token, and what came in (no tokens, no codes) =='
SELECT s.state, s.result_code, left(coalesce(s.message, ''), 90) AS message, to_char(s.updated_at, 'MM-DD HH24:MI:SS') AS updated,
       to_char(f.second_at, 'MM-DD HH24:MI:SS') AS code_asked_at, (f.code IS NOT NULL) AS code_waiting_to_be_sent
FROM public.merchant_feed_status s LEFT JOIN private.merchant_feed_sessions f ON f.provider = s.provider WHERE s.provider = 'golis';
\echo '-- forwarder tokens (hash never shown)'
SELECT to_char(created_at, 'MM-DD HH24:MI:SS') AS created, to_char(last_used_at, 'MM-DD HH24:MI:SS') AS last_used, to_char(revoked_at, 'MM-DD HH24:MI:SS') AS revoked
FROM private.sahal_sms_hooks ORDER BY created_at DESC LIMIT 5;
\echo '-- settings'
SELECT key, left(value, 30) AS value FROM public.app_settings WHERE key IN ('sahal_auto_code', 'sahal_sms_senders');
\echo '-- sign-ins, typed and automatic codes, forwarder token changes (last 6 hours)'
SELECT to_char(created_at, 'MM-DD HH24:MI:SS') AS at, action, left(coalesce(after_json::text, ''), 90) AS detail
FROM public.audit_logs WHERE action IN ('merchant_feed.sign_in', 'merchant_feed.code', 'merchant_feed.auto_code', 'sahal_sms_hook.rotate', 'sahal_sms_hook.revoke')
  AND created_at > now() - interval '6 hours' ORDER BY created_at DESC LIMIT 20;

\echo '== 17. Latest completed deposits: how long each took, and when the credit and any SMS landed =='
SELECT o.order_code, o.method,
       to_char(o.created_at, 'MM-DD HH24:MI:SS') AS created,
       to_char(o.completed_at, 'MM-DD HH24:MI:SS') AS completed,
       round(extract(epoch FROM o.completed_at - o.created_at)) AS total_sec,
       (SELECT to_char(min(l.created_at), 'HH24:MI:SS') FROM public.ledger_entries l WHERE l.order_id = o.id AND l.entry_type = 'credit') AS credit_at,
       (SELECT to_char(min(s.received_at), 'HH24:MI:SS') || ' / uploaded ' || to_char(min(s.created_at), 'HH24:MI:SS') FROM public.sms_logs s WHERE s.matched_order_id = o.id) AS sms_received_uploaded
FROM public.orders o WHERE o.direction = 'deposit' AND o.status = 'completed'
ORDER BY o.completed_at DESC LIMIT 12;

\echo '== 18. Sahal session log: how long each session lasted, and what ended it (no codes, no ids) =='
\echo '-- setting: idle renewal (on = the session is renewed by itself when idle)'
SELECT key, value FROM public.app_settings WHERE key = 'sahal_renew_idle';
\echo '-- lifetimes of ended sessions (seconds)'
SELECT count(*) AS ended,
       round(min((detail ->> 'lifetimeSeconds')::numeric) / 60, 1) AS min_minutes,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY (detail ->> 'lifetimeSeconds')::numeric))::numeric / 60, 1) AS median_minutes,
       round(max((detail ->> 'lifetimeSeconds')::numeric) / 60, 1) AS max_minutes
FROM private.merchant_feed_events WHERE provider = 'golis' AND event = 'session_cleared' AND detail ? 'lifetimeSeconds';
\echo '-- the last 40 events, newest first'
SELECT to_char(at, 'MM-DD HH24:MI:SS') AS at, event, detail::text AS detail
FROM private.merchant_feed_events WHERE provider = 'golis' ORDER BY id DESC LIMIT 40;

\echo '== 19. Betting platforms: added ones, deleted ones, and whether a name is taken (read-only; no credentials) =='
SELECT i.method_key, i.adapter, i.status, i.built_in, (i.deleted_at IS NOT NULL) AS deleted,
       to_char(i.created_at, 'MM-DD HH24:MI') AS created,
       EXISTS (SELECT 1 FROM public.payment_methods m WHERE m.method::text = i.method_key) AS has_payment_method
FROM public.payment_integrations i WHERE i.kind = 'betting' ORDER BY i.created_at;
\echo '-- payment methods that are betting platforms (label, enabled)'
SELECT m.method::text AS method, m.label, m.enabled FROM public.payment_methods m WHERE m.kind = 'platform' ORDER BY m.sort_order, m.method::text;
\echo '-- order_method values that are not payment methods (a name already used and left behind)'
SELECT e::text AS leftover_enum_value
FROM unnest(enum_range(NULL::public.order_method)) e
WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods m WHERE m.method::text = e::text);

\echo '== 20. Added platforms: the stored logo (size, type, pixels) and what the Customer App catalog sends for it (read-only; no picture shown) =='
SELECT i.method_key,
       (i.logo IS NOT NULL) AS has_logo,
       length(i.logo) AS logo_bytes,
       CASE WHEN substring(i.logo FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea THEN 'png'
            WHEN substring(i.logo FROM 1 FOR 3) = '\xffd8ff'::bytea THEN 'jpeg' END AS logo_type,
       CASE WHEN substring(i.logo FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea
            THEN get_byte(i.logo, 16) * 16777216 + get_byte(i.logo, 17) * 65536 + get_byte(i.logo, 18) * 256 + get_byte(i.logo, 19) END AS png_width,
       CASE WHEN substring(i.logo FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea
            THEN get_byte(i.logo, 20) * 16777216 + get_byte(i.logo, 21) * 65536 + get_byte(i.logo, 22) * 256 + get_byte(i.logo, 23) END AS png_height
FROM public.payment_integrations i WHERE i.kind = 'betting' AND i.deleted_at IS NULL AND NOT i.built_in ORDER BY i.created_at;
\echo '-- the catalog entry each customer phone receives at start (platforms only)'
SELECT e ->> 'method' AS method, e ->> 'label' AS label, (e ->> 'enabled') AS enabled,
       (e ->> 'logo') IS NOT NULL AS logo_in_catalog, length(e ->> 'logo') AS logo_base64_chars
FROM jsonb_array_elements(public.payment_method_catalog()) e WHERE e ->> 'kind' = 'platform' ORDER BY (e ->> 'order')::int;

\echo '== 21. Sahal balance reads (Company Balances): the last ones, newest first (read-only) =='
SELECT to_char(checked_at, 'MM-DD HH24:MI:SS') AS at, ok, round(balance_cents / 100.0, 2) AS balance_usd, error
FROM public.sahal_balances ORDER BY checked_at DESC LIMIT 8;
