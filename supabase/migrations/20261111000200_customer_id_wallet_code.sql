-- One Customer ID, the one the customer sees in the app: the wallet's permanent ID (BE592850, "Aqoonsiga Boorsada").
--
-- Until now the withdrawal approval message (WhatsApp, Telegram) and the admin lists showed a different, derived code (BXB5F22ED0, made from the
-- account's internal id), so an admin could not match it with the customer's wallet. From now on private.account_code() returns the wallet ID, and
-- every place that shows a "Customer ID" (the app's WhatsApp message, the Telegram approval request and its buttons, the BADAL AGENT alerts and
-- report, the Agent App lists and their search) shows that same ID. Nothing is generated: it is read from public.wallets.wallet_code, which is
-- permanent (private.wallet_code_guard). A customer without a wallet row (none exists) would fall back to the old derived code.
-- Old Telegram links in phones that still carry the previous code (fasax_BX...) keep working: the lookup accepts both.
-- No order, wallet, ledger, approval or payment logic changes.

-- The previous derived code, only for finding a customer by an old link.
CREATE OR REPLACE FUNCTION private.legacy_account_code(p_id uuid)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT 'BX' || upper(left(replace(p_id::text, '-', ''), 8))
$$;

-- The Customer ID: the wallet ID.
CREATE OR REPLACE FUNCTION private.account_code(p_id uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT w.wallet_code FROM public.wallets w WHERE w.customer_id = p_id LIMIT 1), private.legacy_account_code(p_id))
$$;
REVOKE ALL ON FUNCTION private.legacy_account_code(uuid), private.account_code(uuid) FROM PUBLIC, anon, authenticated;

-- The approval request by Telegram: the wallet ID (and the old code) finds the customer; the answer carries the wallet ID.
CREATE OR REPLACE FUNCTION public.support_approval_request(p_chat bigint, p_account text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_code text := upper(btrim(COALESCE(p_account, '')));
  u public.users;
  a public.withdrawal_approvals;
  r public.support_approval_requests;
  v_new boolean := false;
BEGIN
  PERFORM private.require_service();
  IF (SELECT count(*) FROM public.support_events
      WHERE chat_id = p_chat AND kind = 'approval' AND created_at > now() - interval '1 hour') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'limited', true);
  END IF;
  INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'approval');
  IF v_code !~ '^(BE[0-9]{6}|BX[0-9A-F]{8})$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO u FROM public.users WHERE role = 'customer'
     AND (private.legacy_account_code(id) = v_code
          OR EXISTS (SELECT 1 FROM public.wallets w WHERE w.customer_id = users.id AND w.wallet_code = v_code));
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO a FROM public.withdrawal_approvals WHERE customer_id = u.id;
  IF private.withdrawals_allowed(u.id) THEN
    RETURN jsonb_build_object('ok', true, 'allowed', true, 'name', u.name, 'phone', u.phone, 'accountId', private.account_code(u.id),
                              'status', COALESCE(a.status, 'pending'));
  END IF;
  IF a.status = 'restricted' THEN
    RETURN jsonb_build_object('ok', true, 'allowed', false, 'restricted', true, 'name', u.name, 'phone', u.phone,
                              'accountId', private.account_code(u.id), 'status', a.status);
  END IF;
  SELECT * INTO r FROM public.support_approval_requests WHERE customer_id = u.id AND status = 'pending';
  IF NOT FOUND THEN
    INSERT INTO public.support_approval_requests (customer_id, customer_chat_id) VALUES (u.id, p_chat) RETURNING * INTO r;
    v_new := true;
  ELSE
    UPDATE public.support_approval_requests SET customer_chat_id = p_chat WHERE id = r.id;
  END IF;
  RETURN jsonb_build_object(
    'ok', true, 'allowed', false, 'name', u.name, 'phone', u.phone, 'accountId', private.account_code(u.id),
    'status', COALESCE(a.status, 'pending'),
    'requestId', r.id, 'new', v_new, 'sent', r.admin_message_id IS NOT NULL);
END $$;

-- The app's withdrawal access: also the customer's name (for the message to the admin).
CREATE OR REPLACE FUNCTION public.customer_withdrawal_access()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  a public.withdrawal_approvals;
BEGIN
  -- A request for the admin, once, only when it is needed.
  IF private.withdrawal_verification_on() AND NOT private.withdrawals_allowed(v_id) THEN
    INSERT INTO public.withdrawal_approvals (customer_id) VALUES (v_id) ON CONFLICT (customer_id) DO NOTHING;
  END IF;
  SELECT * INTO a FROM public.withdrawal_approvals WHERE customer_id = v_id;
  RETURN jsonb_build_object(
    'allowed', private.withdrawals_allowed(v_id),
    'status', CASE WHEN private.withdrawals_allowed(v_id) AND COALESCE(a.status, 'pending') = 'pending' THEN 'approved'
                   ELSE COALESCE(a.status, 'pending') END,
    'reason', CASE WHEN a.status IN ('rejected', 'restricted') THEN a.reason END,
    'message', CASE WHEN NOT private.withdrawals_allowed(v_id) THEN private.withdrawal_verification_message() END,
    'whatsapp', private.admin_whatsapp(),
    'accountId', private.account_code(v_id),
    'phone', (SELECT phone FROM public.users WHERE id = v_id),
    'name', (SELECT name FROM public.users WHERE id = v_id));
END $$;

-- BADAL AGENT: the alerts carry the customer's Customer ID too.
CREATE OR REPLACE FUNCTION private.withdrawal_alert_json(o public.orders)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('orderId', o.id, 'orderCode', o.order_code, 'method', o.method, 'status', o.status,
    'amount', private.money(o.amount_cents), 'payout', private.money(o.net_cents), 'phone', o.phone_number,
    'customerName', u.name, 'customerPhone', u.phone, 'customerId', private.account_code(u.id), 'reference', o.transaction_ref,
    'reason', CASE WHEN o.status IN ('failed', 'cancelled', 'expired') THEN left(o.failure_reason, 200) END,
    'review', o.payout_review, 'createdAt', o.created_at, 'completedAt', o.completed_at,
    'delay', private.withdrawal_delay(o))
  FROM public.users u WHERE u.id = o.customer_id
$$;
CREATE OR REPLACE FUNCTION public.payment_incidents_todo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', i.id, 'direction', i.direction, 'kind', i.kind, 'orderCode', i.order_code, 'method', i.method,
      'amount', i.amount_text, 'code', i.error_code, 'error', i.error_text, 'source', i.source, 'at', i.created_at,
      'customerName', u.name, 'customerPhone', u.phone, 'customerId', CASE WHEN u.id IS NULL THEN NULL ELSE private.account_code(u.id) END) ORDER BY i.created_at)
    FROM (SELECT * FROM public.payment_incidents WHERE alerted_at IS NULL ORDER BY created_at LIMIT 20) i
    LEFT JOIN public.users u ON u.id = i.customer_id), '[]'::jsonb);
END $$;

-- The daily report and the group notices carry it as well.
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

  SELECT COALESCE(jsonb_agg(jsonb_build_object('name', t.name, 'phone', t.phone, 'customerId', t.cid, 'deposits', private.money(t.dep),
           'withdrawals', private.money(t.wd), 'volume', private.money(t.vol), 'count', t.n) ORDER BY t.vol DESC), '[]'::jsonb)
    INTO v_top
    FROM (SELECT COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil') AS name, private.mask(u.phone) AS phone, private.account_code(u.id) AS cid,
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
           'at', o.completed_at, 'customer', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'), 'phone', private.mask(u.phone), 'customerId', private.account_code(u.id), 'reference', o.transaction_ref) ORDER BY o.completed_at), '[]'::jsonb)
    INTO v_deposits
    FROM (SELECT * FROM public.orders WHERE direction = 'deposit' AND status = 'completed' AND completed_at > v_floor
             AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'deposit' AND n.key = orders.id::text)
           ORDER BY completed_at LIMIT 15) o
    JOIN public.users u ON u.id = o.customer_id;
  SELECT COALESCE(jsonb_agg(jsonb_build_object('key', o.id::text, 'code', o.order_code, 'direction', o.direction, 'method', o.method, 'amount', private.money(o.amount_cents),
           'at', o.updated_at, 'customer', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'), 'phone', private.mask(u.phone), 'customerId', private.account_code(u.id), 'reason', left(o.failure_reason, 200)) ORDER BY o.updated_at), '[]'::jsonb)
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

REVOKE ALL ON FUNCTION private.report_build(date) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.support_approval_request(bigint, text), public.group_report_todo(), public.payment_incidents_todo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.support_approval_request(bigint, text), public.group_report_todo(), public.payment_incidents_todo() TO service_role;
