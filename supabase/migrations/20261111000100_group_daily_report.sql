-- BADAL AGENT group: the daily report system.
--
-- * The reporting day is 00:00 -> 23:59:59 in Africa/Mogadishu (it was 21:00): every day starts at 00:00.
-- * At 00:00 the finished day is CLOSED into public.daily_reports (a saved, final snapshot that is kept for good);
--   in the morning (08:00, setting daily_report_hour) the worker sends it to the linked Telegram chat, once.
-- * Real figures only: everything is read from orders, commission_entries, payment_incidents and the health
--   incidents. No order, wallet, ledger or commission row is ever changed here; historical records are untouched.
-- * Real-time notices for the group that did not exist yet: a deposit that was credited, a deposit / platform
--   payout that failed, the Sahal balance below its minimum. (New withdrawals, paid/failed edits, delays,
--   payment incidents, security alerts, stuck orders and health alerts already reach the group.)
-- * No duplicates: a report is claimed (2 minutes), sent in numbered parts and marked; a notice is remembered in
--   public.group_notified before it can be sent again.
--
-- Definitions:  Deposits = deposit orders completed in the day (amount paid in).  Withdrawals = withdrawal orders
--   completed in the day (amount asked).  Payouts = what was paid to the customers for those withdrawals (net of fee).
--   Transactions = orders completed.  Pending = orders opened in the day that still wait at the close.
--   Failed = orders that failed in the day.  Earnings = agent commission recorded in the day.

CREATE TABLE IF NOT EXISTS public.daily_reports (
  day           DATE PRIMARY KEY,
  data          JSONB NOT NULL,
  closed_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  claimed_at    TIMESTAMPTZ,
  send_attempts INT NOT NULL DEFAULT 0,
  parts_sent    INT NOT NULL DEFAULT 0,
  sent_at       TIMESTAMPTZ,
  last_error    TEXT
);
CREATE TABLE IF NOT EXISTS public.group_notified (
  kind TEXT NOT NULL,
  key  TEXT NOT NULL,
  at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (kind, key)
);
ALTER TABLE public.daily_reports ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.group_notified ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.daily_reports, public.group_notified FROM PUBLIC, anon, authenticated;

-- Notices start from now: nothing older than the deploy is sent as "new".
INSERT INTO public.app_settings (key, value) VALUES ('group_report_since', now()::text) ON CONFLICT (key) DO NOTHING;
INSERT INTO public.app_settings (key, value) VALUES ('daily_report_hour', '8') ON CONFLICT (key) DO NOTHING;

-- The deposit notice and the daily queries read completed orders by completion time.
CREATE INDEX IF NOT EXISTS idx_orders_completed_at ON public.orders (completed_at) WHERE status = 'completed';

-- 1. The report of one day (Mogadishu), built from the real records.
CREATE OR REPLACE FUNCTION private.report_build(p_day date)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_from timestamptz := p_day::timestamp AT TIME ZONE 'Africa/Mogadishu';
  v_to timestamptz := (p_day + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu';
  v_open_until timestamptz;
  v_done jsonb;
  v_pending jsonb;
  v_failed jsonb;
  v_other int;
  v_earn jsonb;
  v_agents jsonb;
  v_top jsonb;
  v_failed_list jsonb;
  v_nobalance int;
  v_incidents jsonb;
  v_health jsonb;
  v_stuck jsonb;
BEGIN
  v_open_until := LEAST(v_to, now());
  SELECT jsonb_build_object(
      'deposits', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'deposit'),
                    'total', private.money(COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit'), 0))),
      'withdrawals', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'withdraw'),
                    'total', private.money(COALESCE(sum(amount_cents) FILTER (WHERE direction = 'withdraw'), 0))),
      'payouts', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'withdraw'),
                    'total', private.money(COALESCE(sum(net_cents) FILTER (WHERE direction = 'withdraw'), 0))),
      'transactions', count(*))
    INTO v_done FROM public.orders WHERE status = 'completed' AND completed_at >= v_from AND completed_at < v_to;
  SELECT jsonb_build_object('count', count(*), 'total', private.money(COALESCE(sum(amount_cents), 0)))
    INTO v_pending FROM public.orders WHERE status IN ('pending', 'processing') AND created_at >= v_from AND created_at < v_to;
  SELECT jsonb_build_object('count', count(*), 'total', private.money(COALESCE(sum(amount_cents), 0)))
    INTO v_failed FROM public.orders WHERE status = 'failed' AND updated_at >= v_from AND updated_at < v_to;
  SELECT count(*) INTO v_other FROM public.orders WHERE status IN ('cancelled', 'expired') AND updated_at >= v_from AND updated_at < v_to;
  SELECT count(*) INTO v_nobalance FROM public.orders WHERE status = 'failed' AND updated_at >= v_from AND updated_at < v_to
    AND failure_reason ~* 'balance|insufficient|low funds|WITHDRAWAL_PROVIDER_BALANCE';

  SELECT jsonb_build_object('count', count(*), 'total', private.money_micros(COALESCE(sum(net_micros), 0)::bigint))
    INTO v_earn FROM public.commission_entries WHERE completed_at >= v_from AND completed_at < v_to;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', t.name, 'orders', t.n, 'volume', private.money(t.vol), 'earned', private.money_micros(t.earned::bigint)) ORDER BY t.earned DESC), '[]'::jsonb)
    INTO v_agents
    FROM (SELECT COALESCE(NULLIF(btrim(u.name), ''), 'Otomaatig') AS name, count(*) AS n, sum(c.amount_cents) AS vol, sum(c.net_micros) AS earned
            FROM public.commission_entries c LEFT JOIN public.users u ON u.id = c.agent_id
           WHERE c.completed_at >= v_from AND c.completed_at < v_to
           GROUP BY u.id, u.name ORDER BY sum(c.net_micros) DESC LIMIT 5) t;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', t.name, 'phone', t.phone, 'deposits', private.money(t.dep),
           'withdrawals', private.money(t.wd), 'volume', private.money(t.vol), 'count', t.n) ORDER BY t.vol DESC), '[]'::jsonb)
    INTO v_top
    FROM (SELECT COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil') AS name, private.mask(u.phone) AS phone,
                 COALESCE(sum(o.amount_cents) FILTER (WHERE o.direction = 'deposit'), 0) AS dep,
                 COALESCE(sum(o.amount_cents) FILTER (WHERE o.direction = 'withdraw'), 0) AS wd,
                 sum(o.amount_cents) AS vol, count(*) AS n
            FROM public.orders o JOIN public.users u ON u.id = o.customer_id
           WHERE o.status = 'completed' AND o.completed_at >= v_from AND o.completed_at < v_to
           GROUP BY u.id, u.name, u.phone ORDER BY sum(o.amount_cents) DESC, count(*) DESC LIMIT 5) t;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('code', t.order_code, 'direction', t.direction, 'method', t.method, 'amount', private.money(t.amount_cents),
           'at', t.updated_at, 'reason', left(t.failure_reason, 160)) ORDER BY t.updated_at DESC), '[]'::jsonb)
    INTO v_failed_list
    FROM (SELECT order_code, direction, method, amount_cents, updated_at, failure_reason FROM public.orders
           WHERE status = 'failed' AND updated_at >= v_from AND updated_at < v_to ORDER BY updated_at DESC LIMIT 10) t;
  SELECT jsonb_build_object('count', (SELECT count(*) FROM public.payment_incidents WHERE created_at >= v_from AND created_at < v_to),
      'list', COALESCE((SELECT jsonb_agg(jsonb_build_object('direction', i.direction, 'kind', i.kind, 'code', i.order_code, 'method', i.method,
           'amount', i.amount_text, 'at', i.created_at, 'reason', left(COALESCE(i.error_text, i.error_code), 160)) ORDER BY i.created_at DESC)
         FROM (SELECT * FROM public.payment_incidents WHERE created_at >= v_from AND created_at < v_to ORDER BY created_at DESC LIMIT 6) i), '[]'::jsonb))
    INTO v_incidents;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('severity', h.severity, 'title', left(h.title, 120), 'status', h.status, 'at', h.first_seen) ORDER BY h.first_seen DESC), '[]'::jsonb)
    INTO v_health
    FROM (SELECT severity, title, status, first_seen FROM private.health_incidents WHERE first_seen >= v_from AND first_seen < v_to AND severity <> 'info'
           ORDER BY first_seen DESC LIMIT 8) h;
  SELECT jsonb_build_object('count', count(*),
      'list', COALESCE(jsonb_agg(jsonb_build_object('code', s.order_code, 'direction', s.direction, 'method', s.method, 'amount', private.money(s.amount_cents),
           'status', s.status, 'hours', round(extract(epoch FROM (v_open_until - s.created_at)) / 3600)) ORDER BY s.created_at) FILTER (WHERE s.rn <= 5), '[]'::jsonb))
    INTO v_stuck
    FROM (SELECT order_code, direction, method, amount_cents, status, created_at, row_number() OVER (ORDER BY created_at) AS rn
            FROM public.orders WHERE status IN ('pending', 'processing') AND created_at < v_open_until - interval '3 hours'
             AND created_at > v_open_until - interval '30 days') s;

  RETURN jsonb_build_object('day', p_day, 'live', now() < v_to, 'generatedAt', now(),
    'deposits', v_done -> 'deposits', 'withdrawals', v_done -> 'withdrawals', 'payouts', v_done -> 'payouts',
    'transactions', (v_done ->> 'transactions')::int, 'pending', v_pending, 'failed', v_failed, 'otherClosed', v_other,
    'earnings', v_earn, 'agents', v_agents, 'topCustomers', v_top,
    'errors', jsonb_build_object('failedOrders', v_failed_list, 'insufficientBalance', v_nobalance, 'incidents', v_incidents,
      'health', v_health, 'stuck', v_stuck));
END $$;
REVOKE ALL ON FUNCTION private.report_build(date) FROM PUBLIC, anon, authenticated;

-- 2. Close the finished days (idempotent: a closed day is never rebuilt). Only yesterday on the first run, and at most 7 missed days.
CREATE OR REPLACE FUNCTION private.daily_report_close()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_yesterday date := (now() AT TIME ZONE 'Africa/Mogadishu')::date - 1;
  v_first date := COALESCE((SELECT max(day) FROM public.daily_reports) + 1, (now() AT TIME ZONE 'Africa/Mogadishu')::date - 1);
  d date;
  n integer := 0;
BEGIN
  FOR d IN SELECT g::date FROM generate_series(GREATEST(v_first, v_yesterday - 6), v_yesterday, interval '1 day') g LOOP
    INSERT INTO public.daily_reports (day, data) VALUES (d, private.report_build(d)) ON CONFLICT (day) DO NOTHING;
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION private.daily_report_close() FROM PUBLIC, anon, authenticated;

-- 3. What the group worker should send now: the claimed report (if due) and the real-time notices.
CREATE OR REPLACE FUNCTION public.group_report_todo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.withdrawal_alert_chat;
  v_floor timestamptz;
  v_hour int := COALESCE((SELECT NULLIF(btrim(value), '')::int FROM public.app_settings WHERE key = 'daily_report_hour' AND btrim(value) ~ '^\d{1,2}$'), 8);
  v_local timestamp := now() AT TIME ZONE 'Africa/Mogadishu';
  v_day date;
  v_report jsonb;
  v_deposits jsonb;
  v_failed jsonb;
  v_sahal jsonb;
  -- The Sahal balance that is called low (cents): setting sahal_low_balance_usd, $50 until it is set.
  v_low bigint := COALESCE((SELECT (NULLIF(btrim(value), '')::numeric * 100)::bigint FROM public.app_settings
                             WHERE key = 'sahal_low_balance_usd' AND btrim(value) ~ '^\d{1,7}(\.\d{1,2})?$'), 5000);
BEGIN
  PERFORM private.require_service();
  SELECT * INTO c FROM public.withdrawal_alert_chat;
  IF c.chat_id IS NULL THEN
    RETURN jsonb_build_object('chatId', NULL);
  END IF;
  PERFORM private.daily_report_close();

  -- The report: the oldest unsent closed day, from the morning hour on (an older missed day goes at once).
  SELECT r.day INTO v_day FROM public.daily_reports r
   WHERE r.sent_at IS NULL AND r.send_attempts < 10 AND r.day >= v_local::date - 3
     AND (r.claimed_at IS NULL OR r.claimed_at < now() - interval '2 minutes')
     AND (r.day < v_local::date - 1 OR v_local::time >= make_time(LEAST(v_hour, 23), 0, 0))
   ORDER BY r.day LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF v_day IS NOT NULL THEN
    UPDATE public.daily_reports SET claimed_at = now(), send_attempts = send_attempts + 1 WHERE day = v_day;
    SELECT jsonb_build_object('day', r.day, 'data', r.data, 'partsSent', r.parts_sent) INTO v_report FROM public.daily_reports r WHERE r.day = v_day;
  END IF;

  v_floor := GREATEST(c.linked_at, COALESCE((SELECT NULLIF(value, '')::timestamptz FROM public.app_settings WHERE key = 'group_report_since'), now() - interval '3 hours'),
                      now() - interval '3 hours');
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key', o.id::text, 'code', o.order_code, 'method', o.method, 'amount', private.money(o.amount_cents),
           'at', o.completed_at, 'customer', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'), 'phone', private.mask(u.phone), 'reference', o.transaction_ref) ORDER BY o.completed_at), '[]'::jsonb)
    INTO v_deposits
    FROM (SELECT * FROM public.orders WHERE direction = 'deposit' AND status = 'completed' AND completed_at > v_floor
             AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'deposit' AND n.key = orders.id::text)
           ORDER BY completed_at LIMIT 15) o
    JOIN public.users u ON u.id = o.customer_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key', o.id::text, 'code', o.order_code, 'direction', o.direction, 'method', o.method, 'amount', private.money(o.amount_cents),
           'at', o.updated_at, 'customer', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'), 'phone', private.mask(u.phone), 'reason', left(o.failure_reason, 200)) ORDER BY o.updated_at), '[]'::jsonb)
    INTO v_failed
    FROM (SELECT * FROM public.orders WHERE status = 'failed' AND updated_at > v_floor
             AND NOT EXISTS (SELECT 1 FROM public.withdrawal_alerts a WHERE a.order_id = orders.id)
             AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'failed' AND n.key = orders.id::text)
           ORDER BY updated_at LIMIT 15) o
    JOIN public.users u ON u.id = o.customer_id;
  SELECT jsonb_build_object('balance', private.money(b.balance_cents), 'min', private.money(v_low),
           'key', 'sahal_low:' || (extract(epoch FROM now())::bigint / 21600)::text)
    INTO v_sahal
    FROM public.sahal_payout_settings s,
         LATERAL (SELECT balance_cents, checked_at FROM public.sahal_balances WHERE ok ORDER BY checked_at DESC LIMIT 1) b
   WHERE s.id AND s.mode <> 'off' AND b.balance_cents < v_low AND b.checked_at > now() - interval '15 minutes'
     AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'sahal_low' AND n.key = 'sahal_low:' || (extract(epoch FROM now())::bigint / 21600)::text);

  RETURN jsonb_build_object('chatId', c.chat_id, 'report', v_report, 'deposits', v_deposits, 'failed', v_failed, 'sahalLow', v_sahal);
END $$;

-- 4. Worker: a part of the report was sent (p_done: all parts); or the sending failed (p_error).
CREATE OR REPLACE FUNCTION public.daily_report_sent(p_day date, p_parts int, p_done boolean, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.daily_reports SET parts_sent = GREATEST(parts_sent, COALESCE(p_parts, 0)), last_error = left(p_error, 300),
         sent_at = CASE WHEN p_done THEN now() ELSE sent_at END,
         claimed_at = CASE WHEN p_done THEN claimed_at ELSE NULL END
   WHERE day = p_day AND sent_at IS NULL;
END $$;

-- Worker: these notices were sent (once each); old memory is dropped after 45 days.
CREATE OR REPLACE FUNCTION public.group_notified_mark(p_kind text, p_keys text[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.group_notified (kind, key) SELECT p_kind, k FROM unnest(p_keys) k ON CONFLICT DO NOTHING;
  DELETE FROM public.group_notified WHERE at < now() - interval '45 days';
END $$;

-- Worker: a saved report, or today so far (for the /report command in the linked chat).
CREATE OR REPLACE FUNCTION public.daily_report_get(p_day date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_day date := COALESCE(p_day, v_today);
  r public.daily_reports;
BEGIN
  PERFORM private.require_service();
  IF v_day > v_today OR v_day < v_today - 400 THEN
    RETURN NULL;
  END IF;
  SELECT * INTO r FROM public.daily_reports WHERE day = v_day;
  IF r.day IS NOT NULL THEN
    RETURN jsonb_build_object('day', r.day, 'data', r.data, 'saved', true);
  END IF;
  RETURN jsonb_build_object('day', v_day, 'data', private.report_build(v_day), 'saved', false);
END $$;

REVOKE ALL ON FUNCTION public.group_report_todo(), public.daily_report_sent(date, int, boolean, text),
  public.group_notified_mark(text, text[]), public.daily_report_get(date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.group_report_todo(), public.daily_report_sent(date, int, boolean, text),
  public.group_notified_mark(text, text[]), public.daily_report_get(date) TO service_role;

-- 5. The old 21:00 withdrawals-only summary is replaced by the daily report (the function is the previous one without that part).
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.withdrawal_alert_chat;
  v_sahal jsonb := private.sahal_alert();
BEGIN
  PERFORM private.require_service();
  SELECT * INTO c FROM public.withdrawal_alert_chat;
  IF c.chat_id IS NULL THEN
    RETURN jsonb_build_object('chatId', NULL);
  END IF;
  RETURN jsonb_build_object(
    'chatId', c.chat_id,
    -- New withdrawals since the chat was linked (oldest first, 20 a run).
    'new', COALESCE((SELECT jsonb_agg(private.withdrawal_alert_json(o) ORDER BY o.created_at)
      FROM (SELECT * FROM public.orders o WHERE o.direction = 'withdraw' AND private.is_mobile_money(o.method)
              AND o.created_at >= c.linked_at
              AND NOT EXISTS (SELECT 1 FROM public.withdrawal_alerts a WHERE a.order_id = o.id)
            ORDER BY o.created_at LIMIT 20) o), '[]'::jsonb),
    -- Sent ones whose status changed.
    'changed', COALESCE((SELECT jsonb_agg(private.withdrawal_alert_json(o) || jsonb_build_object('messageId', a.message_id))
      FROM public.withdrawal_alerts a JOIN public.orders o ON o.id = a.order_id
      WHERE a.chat_id = c.chat_id AND a.shown_status <> (o.status::text || CASE WHEN o.payout_review THEN ':review' ELSE '' END)), '[]'::jsonb),
    -- Still waiting after 30 seconds, reminded once, with why.
    'remind', COALESCE((SELECT jsonb_agg(private.withdrawal_alert_json(o) || jsonb_build_object('messageId', a.message_id))
      FROM public.withdrawal_alerts a JOIN public.orders o ON o.id = a.order_id
      WHERE a.chat_id = c.chat_id AND a.reminded_at IS NULL AND o.status IN ('pending', 'processing')
        AND o.created_at < now() - interval '30 seconds'), '[]'::jsonb),
    -- Sahal transfers out that completed no withdrawal (read after linking).
    'strays', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', m.id, 'transactionId', m.transaction_id,
        'receiver', m.payer_phone, 'amount', private.money(m.amount_cents), 'paidAt', m.paid_at))
      FROM public.merchant_transactions m
      WHERE m.direction = 'out' AND m.match_status = 'unmatched' AND m.alerted_at IS NULL
        AND m.first_seen_at >= c.linked_at AND m.first_seen_at < now() - interval '2 minutes'), '[]'::jsonb),
    -- Sahal needs a person (once per situation), or is fine again.
    'sahal', CASE WHEN v_sahal IS NOT NULL AND (v_sahal ->> 'key') IS DISTINCT FROM c.sahal_alert_key THEN v_sahal
                  WHEN v_sahal IS NULL AND c.sahal_alert_key IS NOT NULL THEN jsonb_build_object('kind', 'ok', 'key', NULL)
             END,
    -- The daily report (00:00 close, morning send) replaced the 21:00 summary: see public.group_report_todo().
    'summary', NULL);
END $$;

-- 6. 00:00 Mogadishu = 21:00 UTC: close the day that just ended (the worker also closes any missed day).
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-daily-report';
    PERFORM cron.schedule('baari-daily-report', '0 21 * * *', 'SELECT private.daily_report_close()');
  END IF;
END
$do$;
