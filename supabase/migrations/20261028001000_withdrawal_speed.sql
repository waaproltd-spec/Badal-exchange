-- Withdrawals: no silent waiting.
--
-- Diagnosed on production (supabase/diagnostics/payments.sql, 2026-10-28):
-- EX8N5NPM (EVC Plus) and EXUPECC7 (ZAAD) waited because Sahal refused
-- every transfer with ER0654 "Session data is not found, please sign in
-- again" while the feed still read Sahal's list. The retry (20261028000700)
-- tried again with the same dead session, and nobody was told: the customer
-- saw "Waa socotaa", the agent nothing. Nothing was sent and no money moved
-- twice (all consistency checks 0).
--
-- Now:
--   * golis-merchant signs in again by itself as soon as Sahal refuses a
--     transfer for its session (functions/golis-merchant); a refused
--     withdrawal is retried at once with the new session
--     (sahal_payout_retry_now). When Sahal asks for its SMS code, the old
--     session keeps reading Sahal's list (deposits still credited) while a
--     manager types the code, and the Telegram alert chat is told at once.
--   * A new Sahal withdrawal wakes golis-merchant at once, and it runs every
--     30 seconds instead of every minute.
--   * Every waiting withdrawal older than 30 seconds says why
--     (private.withdrawal_delay): to the customer (customer_order_json
--     'delay') and to the agent's Telegram alert, which now reminds after
--     30 seconds instead of 15 minutes. A run that could not reach Sahal
--     (timeout, network) is tried again after a minute; nothing is ever
--     refunded while a transfer may have gone out (held, as before).

-- 1. The session that still reads while a new sign-in waits for its code.
ALTER TABLE private.merchant_feed_sessions
  ADD COLUMN IF NOT EXISTS read_session_id TEXT,
  ADD COLUMN IF NOT EXISTS read_cookies TEXT;

CREATE OR REPLACE FUNCTION public.merchant_feed_get(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s private.merchant_feed_sessions;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = p_provider;
  RETURN jsonb_build_object(
    'state', (SELECT state FROM public.merchant_feed_status WHERE provider = p_provider),
    'sessionId', s.session_id, 'cookies', s.cookies,
    'readSessionId', s.read_session_id, 'readCookies', s.read_cookies);
END $$;

-- Worker: keep this session for reading while a new sign-in is under way.
CREATE OR REPLACE FUNCTION public.merchant_feed_keep_reading(p_provider text, p_session_id text, p_cookies text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO private.merchant_feed_sessions (provider, read_session_id, read_cookies)
  VALUES (p_provider, p_session_id, left(p_cookies, 4000))
  ON CONFLICT (provider) DO UPDATE SET read_session_id = EXCLUDED.read_session_id,
    read_cookies = EXCLUDED.read_cookies, updated_at = now();
END $$;

-- Worker: rows read with the kept session. Stored and matched like any
-- others; the feed's state and message (the sign-in under way) stay.
CREATE OR REPLACE FUNCTION public.merchant_feed_store_rows(p_provider text, p_rows jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
  v_new int := 0;
  v_id text;
BEGIN
  PERFORM private.require_service();
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
    v_id := NULLIF(btrim(r->>'_id'), '');
    CONTINUE WHEN v_id IS NULL;
    INSERT INTO public.merchant_transactions (provider, transaction_id, raw)
    VALUES (p_provider, v_id, r - '_id') ON CONFLICT (provider, transaction_id) DO NOTHING;
    IF FOUND THEN v_new := v_new + 1; END IF;
  END LOOP;
  UPDATE public.merchant_feed_status SET checked_at = now(), rows_seen = rows_seen + v_new
  WHERE provider = p_provider;
  RETURN jsonb_build_object('new', v_new, 'credited', private.merchant_sweep(p_provider));
END $$;

-- As before; a session that reads fine again ends the kept one.
CREATE OR REPLACE FUNCTION public.merchant_feed_report(
  p_provider text, p_state text, p_result_code text, p_message text, p_session_id text, p_rows jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
  v_new int := 0;
  v_id text;
BEGIN
  PERFORM private.require_service();
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
    v_id := NULLIF(btrim(r->>'_id'), '');
    CONTINUE WHEN v_id IS NULL;
    INSERT INTO public.merchant_transactions (provider, transaction_id, raw)
    VALUES (p_provider, v_id, r - '_id') ON CONFLICT (provider, transaction_id) DO NOTHING;
    IF FOUND THEN v_new := v_new + 1; END IF;
  END LOOP;
  INSERT INTO private.merchant_feed_sessions (provider, session_id, updated_at) VALUES (p_provider, p_session_id, now())
  ON CONFLICT (provider) DO UPDATE SET session_id = EXCLUDED.session_id, updated_at = now(),
    read_session_id = CASE WHEN p_state = 'ok' THEN NULL ELSE merchant_feed_sessions.read_session_id END,
    read_cookies = CASE WHEN p_state = 'ok' THEN NULL ELSE merchant_feed_sessions.read_cookies END;
  UPDATE public.merchant_feed_status SET state = p_state, result_code = left(p_result_code, 20),
    message = left(p_message, 300), checked_at = now(),
    last_ok_at = CASE WHEN p_state = 'ok' THEN now() ELSE last_ok_at END,
    rows_seen = rows_seen + v_new, updated_at = now()
  WHERE provider = p_provider;
  RETURN jsonb_build_object('new', v_new, 'credited', private.merchant_sweep(p_provider));
END $$;

-- Woken also while a sign-in waits for its code, when a kept session can
-- still read (deposits keep being credited meanwhile).
CREATE OR REPLACE FUNCTION private.merchant_feed_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM public.merchant_feed_status WHERE provider = 'golis'
                    AND (state IN ('ready', 'ok', 'not_configured', 'code_entered')
                         OR (state = 'signing_in' AND updated_at < now() - interval '2 minutes')
                         OR (state IN ('needs_code', 'stopped') AND EXISTS (
                               SELECT 1 FROM private.merchant_feed_sessions x
                               WHERE x.provider = 'golis' AND x.read_session_id IS NOT NULL)))) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/golis-merchant', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'merchant_feed_kick: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION private.merchant_feed_kick() FROM PUBLIC, anon, authenticated;

-- A manager's "Sign in again": as before, and the current session keeps
-- reading (deposits) until the new one is in.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_sign_in(p_provider text DEFAULT 'golis')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  UPDATE public.merchant_feed_status SET state = 'ready', message = 'Signing in…', updated_at = now()
  WHERE provider = p_provider;
  UPDATE private.merchant_feed_sessions
  SET read_session_id = COALESCE(session_id, read_session_id),
      read_cookies = CASE WHEN session_id IS NOT NULL THEN cookies ELSE read_cookies END,
      session_id = NULL, second_session_id = NULL, code = NULL
  WHERE provider = p_provider;
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.sign_in', 'merchant_feed', p_provider, NULL, NULL);
  PERFORM private.merchant_feed_kick();
  RETURN public.manage_merchant_feed_status(p_provider);
END $$;

-- 2. Retries. Refused for the session (ER0654) or Sahal not reached
-- (NETWORK, before anything was sent): tried again by itself, after 2
-- minutes / 1 minute, or at once after a new sign-in.
CREATE OR REPLACE FUNCTION private.sahal_retryable(a public.sahal_payout_attempts)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT a.status = 'failed'
     AND (a.result_code IN ('ER0654', 'NETWORK') OR a.reply ILIKE '%session data is not found%')
$$;

CREATE OR REPLACE FUNCTION private.sahal_retry(p_now boolean)
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.sahal_payout_attempts;
  n int := 0;
BEGIN
  FOR a IN SELECT y.* FROM public.sahal_payout_attempts y JOIN public.orders x ON x.id = y.order_id
           WHERE private.sahal_retryable(y) AND x.status = 'pending'
             AND (p_now OR y.completed_at < now() - CASE WHEN y.result_code = 'NETWORK' THEN interval '1 minute'
                                                         ELSE interval '2 minutes' END)
           FOR UPDATE OF y SKIP LOCKED LOOP
    DELETE FROM public.sahal_payout_attempts WHERE id = a.id;
    PERFORM private.order_audit(a.order_id, 'withdrawal_sahal_retry', jsonb_build_object('attempt', a.id, 'reply', a.reply),
      jsonb_build_object('automatic', true, 'afterSignIn', p_now), NULL);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;

-- Worker: signed in again just now; what the old session was refused goes again.
CREATE OR REPLACE FUNCTION public.sahal_payout_retry_now()
RETURNS int LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN private.sahal_retry(true);
END $$;

CREATE OR REPLACE FUNCTION public.sahal_payout_next(p_balance numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sahal_payout_settings;
  o public.orders;
  a public.sahal_payout_attempts;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id FOR UPDATE;
  IF p_balance IS NOT NULL THEN
    UPDATE public.sahal_payout_settings SET balance_cents = round(p_balance * 100)::bigint, balance_seen_at = now()
    WHERE id RETURNING * INTO s;
  END IF;
  -- A run that died after claiming: its transfer may have gone out.
  FOR a IN SELECT * FROM public.sahal_payout_attempts WHERE status = 'pending' AND created_at < now() - interval '5 minutes' LOOP
    PERFORM private.sahal_hold(a, 'No result was reported for this transfer.');
  END LOOP;
  PERFORM private.sahal_retry(false);
  IF s.mode = 'off' OR (s.mode = 'live' AND NOT private.sahal_test_passed()) THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.sahal_payout_attempts WHERE status = 'pending') THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'withdraw' AND x.method = ANY (s.methods) AND x.status = 'pending'
    AND NOT COALESCE(x.payout_review, false) AND x.created_at > now() - interval '3 days'
    AND (s.mode = 'live' OR x.net_cents <= s.test_amount_cents)
    -- Not enough in Sahal: it waits (its one attempt is not used).
    AND (p_balance IS NULL OR x.net_cents <= round(p_balance * 100))
    AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = x.id)
    AND NOT EXISTS (SELECT 1 FROM public.payout_dial_attempts y WHERE y.order_id = x.id)
  ORDER BY x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL OR private.sahal_paid_today() + o.net_cents > s.daily_limit_cents THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.sahal_payout_attempts (order_id, mode, receiver_mobile, amount_cents)
  VALUES (o.id, s.mode, private.sahal_mobile(o.phone_number), o.net_cents)
  RETURNING * INTO a;
  PERFORM private.order_audit(o.id, 'withdrawal_sahal_started', NULL,
    jsonb_build_object('attempt', a.id, 'receiver', a.receiver_mobile, 'amount', private.money(a.amount_cents), 'mode', s.mode), NULL);
  RETURN jsonb_build_object('attemptId', a.id, 'orderCode', o.order_code, 'receiverMobile', a.receiver_mobile,
    'amount', private.sahal_amount(a.amount_cents), 'description', o.order_code);
END $$;

-- 3. Why a withdrawal still waits after 30 seconds; NULL when it is not late.
--   provider_unavailable  Sahal refuses or cannot be reached (session, sign-in, network)
--   provider_balance      Sahal's balance is below the amount
--   confirming            sent or maybe sent: being confirmed, never resent
--   manual                an agent pays it (refused with a reason, method paid by hand, daily limit)
--   waiting               in the queue
CREATE OR REPLACE FUNCTION private.withdrawal_delay(o public.orders)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sahal_payout_settings;
  f public.merchant_feed_status;
  a public.sahal_payout_attempts;
  v_code text;
  v_note text;
BEGIN
  IF o.direction <> 'withdraw' OR o.status NOT IN ('pending', 'processing') OR o.created_at > now() - interval '30 seconds' THEN
    RETURN NULL;
  END IF;
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id;
  SELECT * INTO f FROM public.merchant_feed_status WHERE provider = 'golis';
  SELECT * INTO a FROM public.sahal_payout_attempts WHERE order_id = o.id;
  v_note := CASE WHEN a.status = 'failed' THEN left(a.reply, 200) END;
  IF o.status = 'processing' OR a.status IN ('ambiguous', 'pending') THEN
    v_code := 'confirming';
  ELSIF COALESCE(o.payout_review, false) THEN
    v_code := 'manual';
  ELSIF s.id IS NOT NULL AND s.mode <> 'off' AND o.method = ANY (s.methods) THEN
    IF private.sahal_retryable(a) OR f.state IN ('needs_code', 'code_entered', 'signing_in', 'stopped', 'not_configured')
       OR f.result_code IN ('ER0654', 'error') OR f.checked_at < now() - interval '3 minutes' THEN
      v_code := 'provider_unavailable';
    ELSIF a.status = 'failed' THEN
      v_code := 'manual';
    ELSIF s.balance_cents IS NOT NULL AND s.balance_cents < o.net_cents THEN
      v_code := 'provider_balance';
    ELSIF private.sahal_paid_today() + o.net_cents > s.daily_limit_cents
       OR (s.mode = 'test' AND o.net_cents > s.test_amount_cents) THEN
      v_code := 'manual';
    ELSE
      v_code := 'waiting';
    END IF;
  ELSE
    v_code := 'manual';
  END IF;
  RETURN jsonb_build_object('code', v_code, 'note', v_note,
    'seconds', floor(extract(epoch FROM now() - o.created_at))::int);
END $$;
REVOKE ALL ON FUNCTION private.withdrawal_delay(public.orders) FROM PUBLIC, anon, authenticated;

-- The customer sees why (the agent-side note stays out).
CREATE OR REPLACE FUNCTION private.customer_order_json(o public.orders)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'status', o.status,
    'statusMessage', private.order_status_message(o.status),
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.amount_cents) END,
    'fee', private.money(o.fee_cents),
    'netAmount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.net_cents) END,
    'amountPending', o.amount_unknown,
    'transactionRef', o.transaction_ref,
    'failureReason', CASE WHEN o.status = 'failed' THEN o.failure_reason END,
    'delay', private.withdrawal_delay(o) ->> 'code',
    'balanceBefore', CASE WHEN b.after_cents IS NOT NULL THEN private.money(b.before_cents) END,
    'balanceAfter', CASE WHEN b.after_cents IS NOT NULL THEN private.money(b.after_cents) END,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
  FROM (SELECT NULL::int AS x) _
  LEFT JOIN LATERAL (
    SELECT l.balance_after_cents AS after_cents,
           CASE WHEN l.entry_type = 'credit' THEN l.balance_after_cents - l.amount_cents
                ELSE l.balance_after_cents + l.amount_cents END AS before_cents
    FROM public.ledger_entries l
    WHERE l.order_id = o.id
      AND ((o.direction = 'deposit' AND l.entry_type = 'credit')
        OR (o.direction = 'withdraw' AND l.entry_type = 'reserve' AND o.status NOT IN ('failed', 'cancelled')))
    ORDER BY l.created_at
    LIMIT 1
  ) b ON true
$$;

-- 4. Alerts: why, after 30 seconds; and Sahal needing a person, at once.
CREATE OR REPLACE FUNCTION private.withdrawal_alert_json(o public.orders)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('orderId', o.id, 'orderCode', o.order_code, 'method', o.method, 'status', o.status,
    'amount', private.money(o.amount_cents), 'payout', private.money(o.net_cents), 'phone', o.phone_number,
    'customerName', u.name, 'customerPhone', u.phone, 'reference', o.transaction_ref,
    'reason', CASE WHEN o.status IN ('failed', 'cancelled', 'expired') THEN left(o.failure_reason, 200) END,
    'review', o.payout_review, 'createdAt', o.created_at, 'completedAt', o.completed_at,
    'delay', private.withdrawal_delay(o))
  FROM public.users u WHERE u.id = o.customer_id
$$;

ALTER TABLE public.withdrawal_alert_chat ADD COLUMN IF NOT EXISTS sahal_alert_key TEXT;

-- What about Sahal needs a person now: a key per situation (alerted once),
-- NULL when all is well.
CREATE OR REPLACE FUNCTION private.sahal_alert()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f public.merchant_feed_status;
  s public.sahal_payout_settings;
  v_asked timestamptz := (SELECT second_at FROM private.merchant_feed_sessions WHERE provider = 'golis');
  v_kind text;
BEGIN
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id;
  SELECT * INTO f FROM public.merchant_feed_status WHERE provider = 'golis';
  IF f.provider IS NULL OR s.mode IS NULL OR s.mode = 'off' THEN
    RETURN NULL;
  END IF;
  v_kind := CASE
    WHEN f.state = 'needs_code' AND v_asked >= now() - interval '10 minutes' THEN 'code'
    WHEN f.state IN ('needs_code', 'stopped') THEN 'stopped'
    WHEN f.result_code = 'ER0654' THEN 'refused'
    WHEN f.result_code = 'error' AND f.last_ok_at < now() - interval '3 minutes' THEN 'unreachable'
  END;
  IF v_kind IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('kind', v_kind,
    'key', v_kind || ':' || COALESCE(CASE WHEN v_kind = 'code' THEN v_asked::text END, ''),
    'message', f.message,
    'waitingCount', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.status = 'pending'
                     AND o.method = ANY (s.methods) AND o.created_at > now() - interval '3 days'));
END $$;
REVOKE ALL ON FUNCTION private.sahal_alert() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.withdrawal_alerts_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.withdrawal_alert_chat;
  v_day_start timestamptz := date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu';
  v_local timestamp := now() AT TIME ZONE 'Africa/Mogadishu';
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
    -- Once a day after 21:00 Mogadishu.
    'summary', CASE WHEN v_local::time >= time '21:00' AND c.summary_day IS DISTINCT FROM v_local::date THEN
      (SELECT jsonb_build_object('day', v_local::date,
         'paidCount', count(*) FILTER (WHERE o.status = 'completed'),
         'paidTotal', private.money(COALESCE(sum(o.net_cents) FILTER (WHERE o.status = 'completed'), 0)),
         'failedCount', count(*) FILTER (WHERE o.status IN ('failed', 'cancelled', 'expired')),
         'waitingCount', (SELECT count(*) FROM public.orders w WHERE w.direction = 'withdraw'
                          AND private.is_mobile_money(w.method) AND w.status IN ('pending', 'processing')),
         'waitingTotal', (SELECT private.money(COALESCE(sum(w.net_cents), 0)) FROM public.orders w WHERE w.direction = 'withdraw'
                          AND private.is_mobile_money(w.method) AND w.status IN ('pending', 'processing')))
       FROM public.orders o WHERE o.direction = 'withdraw' AND private.is_mobile_money(o.method) AND o.created_at >= v_day_start)
    END);
END $$;

-- Worker: the Sahal alert for p_key was sent (NULL: the all-clear was).
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_sahal_sent(p_key text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.withdrawal_alert_chat SET sahal_alert_key = p_key WHERE id;
END $$;

-- 5. A new withdrawal goes out at once: it wakes the Sahal worker and the
-- alerts instead of waiting for their next run.
CREATE OR REPLACE FUNCTION private.withdrawal_wake()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'withdraw' AND NEW.status = 'pending' THEN
    IF EXISTS (SELECT 1 FROM public.sahal_payout_settings s WHERE s.id AND s.mode <> 'off' AND NEW.method = ANY (s.methods)) THEN
      PERFORM private.merchant_feed_kick();
    END IF;
    IF private.is_mobile_money(NEW.method) THEN
      PERFORM private.withdrawal_alerts_kick();
    END IF;
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- Never stands in the way of the withdrawal itself; the next run sends it.
  RAISE WARNING 'withdrawal_wake: %', SQLERRM;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION private.withdrawal_wake() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS orders_withdrawal_wake ON public.orders;
CREATE TRIGGER orders_withdrawal_wake AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.withdrawal_wake();

REVOKE ALL ON FUNCTION public.merchant_feed_keep_reading(text, text, text), public.merchant_feed_store_rows(text, jsonb),
  public.sahal_payout_retry_now(), public.withdrawal_alerts_sahal_sent(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_keep_reading(text, text, text), public.merchant_feed_store_rows(text, jsonb),
  public.sahal_payout_retry_now(), public.withdrawal_alerts_sahal_sent(text) TO service_role;
REVOKE ALL ON FUNCTION private.sahal_retryable(public.sahal_payout_attempts), private.sahal_retry(boolean),
  private.sahal_alert() FROM PUBLIC, anon, authenticated;

-- 6. Every 30 seconds (pg_cron's seconds schedule; every minute where it has none).
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname IN ('baari-golis-merchant', 'baari-withdrawal-alerts');
    BEGIN
      PERFORM cron.schedule('baari-golis-merchant', '30 seconds', 'SELECT private.merchant_feed_kick()');
      PERFORM cron.schedule('baari-withdrawal-alerts', '30 seconds', 'SELECT private.withdrawal_alerts_kick()');
    EXCEPTION WHEN others THEN
      PERFORM cron.schedule('baari-golis-merchant', '* * * * *', 'SELECT private.merchant_feed_kick()');
      PERFORM cron.schedule('baari-withdrawal-alerts', '* * * * *', 'SELECT private.withdrawal_alerts_kick()');
    END;
  END IF;
END
$do$;

-- 7. Company Balances leaves removed betting platforms out (they showed as
-- "not connected").
CREATE OR REPLACE FUNCTION public.agent_company_balances(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now()));
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
  v_items jsonb;
BEGIN
  PERFORM private.require_company_balances();
  IF v_to <= v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period must end after it starts');
  END IF;
  SELECT COALESCE(jsonb_agg(private.company_balance_json(m.method, m.label, v_from, v_to)
           ORDER BY NOT private.is_cashdesk_method(m.method), m.kind DESC, m.sort_order), '[]')
    INTO v_items
  FROM public.payment_methods m
  WHERE NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                    WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL);

  RETURN jsonb_build_object(
    'companies', v_items,
    'total', private.money(COALESCE((SELECT sum((i->>'balance')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low')), 0)),
    'totalLimit', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)
      THEN private.money((SELECT sum((i->>'limit')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)) END,
    'totalCompanies', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('available', 'low')),
    'limitUnknownCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NULL),
    'openWithdrawalAmount', private.money(COALESCE((SELECT sum((i->>'openWithdrawalAmount')::numeric * 100)::bigint
      FROM jsonb_array_elements(v_items) i WHERE (i->>'connected')::boolean), 0)),
    'lowCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'low'),
    'unavailableCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('offline', 'stale')),
    'notConnectedCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'not_connected'),
    'generatedAt', now());
END $$;
