-- Withdrawal alerts on Telegram (@Badaln8nbot). The withdrawal-alerts Edge
-- Function, woken every minute by the database, sends the linked chat:
--   - each new mobile-money withdrawal (code, customer, number, exact
--     amount), edited to "Paid" with the payout reference once completed,
--     or to "Failed / Cancelled";
--   - one reminder when a withdrawal still waits after 15 minutes;
--   - a warning for a Sahal transfer that matches no withdrawal (wrong
--     amount or number, or paid twice);
--   - a daily summary after 21:00 Mogadishu time.
-- Alerts only: nothing here sends money or changes an order. Never sends a
-- PIN, password or login. Only one chat receives alerts: the first that
-- sends /start to the bot (or a manager resets it); others are refused.
-- Bot token: Edge Function secret TELEGRAM_N8N_BOT_TOKEN.

CREATE TABLE IF NOT EXISTS public.withdrawal_alert_chat (
  id          BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  chat_id     BIGINT,
  chat_name   TEXT,
  linked_at   TIMESTAMPTZ,
  update_offset BIGINT NOT NULL DEFAULT 0,
  summary_day DATE,
  last_error  TEXT,
  checked_at  TIMESTAMPTZ
);
INSERT INTO public.withdrawal_alert_chat (id) VALUES (true) ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS public.withdrawal_alerts (
  order_id     UUID PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  chat_id      BIGINT NOT NULL,
  message_id   BIGINT NOT NULL,
  shown_status TEXT NOT NULL,
  reminded_at  TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.merchant_transactions ADD COLUMN IF NOT EXISTS alerted_at TIMESTAMPTZ;

ALTER TABLE public.withdrawal_alert_chat ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.withdrawal_alerts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.withdrawal_alert_chat, public.withdrawal_alerts FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.is_mobile_money(p_method public.order_method)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_method IN ('evc_plus', 'golis', 'telesom', 'edahab')
$$;

CREATE OR REPLACE FUNCTION private.withdrawal_alert_json(o public.orders)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('orderId', o.id, 'orderCode', o.order_code, 'method', o.method, 'status', o.status,
    'amount', private.money(o.amount_cents), 'payout', private.money(o.net_cents), 'phone', o.phone_number,
    'customerName', u.name, 'customerPhone', u.phone, 'reference', o.transaction_ref,
    'reason', CASE WHEN o.status IN ('failed', 'cancelled', 'expired') THEN left(o.failure_reason, 200) END,
    'review', o.payout_review, 'createdAt', o.created_at, 'completedAt', o.completed_at)
  FROM public.users u WHERE u.id = o.customer_id
$$;

-- Worker: the chat and the update offset.
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_state()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN (SELECT jsonb_build_object('chatId', chat_id, 'offset', update_offset) FROM public.withdrawal_alert_chat);
END $$;

-- Worker: a /start from p_chat_id. Links it when no chat is linked; true
-- when this chat is (now) the linked one.
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_link(p_chat_id bigint, p_chat_name text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.withdrawal_alert_chat SET chat_id = p_chat_id, chat_name = left(p_chat_name, 100), linked_at = now()
  WHERE id AND chat_id IS NULL;
  IF FOUND THEN
    PERFORM private.audit(NULL, NULL, 'withdrawal_alerts.link', 'withdrawal_alert_chat', p_chat_id::text, NULL,
      jsonb_build_object('chatName', left(p_chat_name, 100)));
  END IF;
  RETURN (SELECT chat_id = p_chat_id FROM public.withdrawal_alert_chat);
END $$;

CREATE OR REPLACE FUNCTION public.withdrawal_alerts_report(p_offset bigint, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.withdrawal_alert_chat
  SET update_offset = greatest(update_offset, COALESCE(p_offset, 0)), last_error = left(p_error, 300), checked_at = now()
  WHERE id;
END $$;

-- Worker: what to send now.
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.withdrawal_alert_chat;
  v_day_start timestamptz := date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu';
  v_local timestamp := now() AT TIME ZONE 'Africa/Mogadishu';
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
    -- Still waiting after 15 minutes, reminded once.
    'remind', COALESCE((SELECT jsonb_agg(private.withdrawal_alert_json(o) || jsonb_build_object('messageId', a.message_id))
      FROM public.withdrawal_alerts a JOIN public.orders o ON o.id = a.order_id
      WHERE a.chat_id = c.chat_id AND a.reminded_at IS NULL AND o.status IN ('pending', 'processing')
        AND o.created_at < now() - interval '15 minutes'), '[]'::jsonb),
    -- Sahal transfers out that completed no withdrawal (read after linking).
    'strays', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', m.id, 'transactionId', m.transaction_id,
        'receiver', m.payer_phone, 'amount', private.money(m.amount_cents), 'paidAt', m.paid_at))
      FROM public.merchant_transactions m
      WHERE m.direction = 'out' AND m.match_status = 'unmatched' AND m.alerted_at IS NULL
        AND m.first_seen_at >= c.linked_at AND m.first_seen_at < now() - interval '2 minutes'), '[]'::jsonb),
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

-- Worker: what was sent.
CREATE OR REPLACE FUNCTION public.withdrawal_alerts_sent(p_kind text, p_id uuid, p_chat_id bigint DEFAULT NULL,
  p_message_id bigint DEFAULT NULL, p_status text DEFAULT NULL, p_day date DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF p_kind = 'new' THEN
    INSERT INTO public.withdrawal_alerts (order_id, chat_id, message_id, shown_status)
    VALUES (p_id, p_chat_id, p_message_id, p_status) ON CONFLICT (order_id) DO NOTHING;
  ELSIF p_kind = 'changed' THEN
    UPDATE public.withdrawal_alerts SET shown_status = p_status, updated_at = now() WHERE order_id = p_id;
  ELSIF p_kind = 'remind' THEN
    UPDATE public.withdrawal_alerts SET reminded_at = now() WHERE order_id = p_id;
  ELSIF p_kind = 'stray' THEN
    UPDATE public.merchant_transactions SET alerted_at = now() WHERE id = p_id;
  ELSIF p_kind = 'summary' THEN
    UPDATE public.withdrawal_alert_chat SET summary_day = p_day WHERE id;
  END IF;
END $$;

-- Managers: the linked chat, and unlinking it (the next /start links).
CREATE OR REPLACE FUNCTION public.manage_withdrawal_alerts(p_unlink boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  IF p_unlink THEN
    UPDATE public.withdrawal_alert_chat SET chat_id = NULL, chat_name = NULL, linked_at = NULL WHERE id;
    PERFORM private.audit(v_id, private.app_role(), 'withdrawal_alerts.unlink', 'withdrawal_alert_chat', NULL);
  END IF;
  RETURN (SELECT jsonb_build_object('linked', chat_id IS NOT NULL, 'chatName', chat_name, 'linkedAt', linked_at,
    'checkedAt', checked_at, 'lastError', last_error) FROM public.withdrawal_alert_chat);
END $$;

CREATE OR REPLACE FUNCTION private.withdrawal_alerts_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/withdrawal-alerts', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'withdrawal_alerts_kick: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION private.is_mobile_money(public.order_method), private.withdrawal_alert_json(public.orders),
  private.withdrawal_alerts_kick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.withdrawal_alerts_state(), public.withdrawal_alerts_link(bigint, text),
  public.withdrawal_alerts_report(bigint, text), public.withdrawal_alerts_todo(),
  public.withdrawal_alerts_sent(text, uuid, bigint, bigint, text, date) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.withdrawal_alerts_state(), public.withdrawal_alerts_link(bigint, text),
  public.withdrawal_alerts_report(bigint, text), public.withdrawal_alerts_todo(),
  public.withdrawal_alerts_sent(text, uuid, bigint, bigint, text, date) TO service_role;
REVOKE ALL ON FUNCTION public.manage_withdrawal_alerts(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_withdrawal_alerts(boolean) TO authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-withdrawal-alerts';
    PERFORM cron.schedule('baari-withdrawal-alerts', '* * * * *', 'SELECT private.withdrawal_alerts_kick()');
  END IF;
END
$do$;
