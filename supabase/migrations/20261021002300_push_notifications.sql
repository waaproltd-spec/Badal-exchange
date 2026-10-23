-- Customer App push notifications (Firebase Cloud Messaging), in Somali,
-- for exactly two events:
--   deposit_completed   a deposit order became completed
--   withdraw_completed  a withdrawal order became completed
-- Nothing is sent for pending, processing, failed, cancelled or expired
-- orders.
--
--   push_tokens          the FCM token of each signed-in customer device
--                        (customer_register_push_token / _unregister_)
--   push_notifications   one row per completed order, queued by a trigger
--                        on orders in the transaction that completes it;
--                        UNIQUE (order_id, kind), so a completed order is
--                        notified once however often it is touched again.
-- The push-notifications Edge Function claims queued rows (push_claim),
-- sends them through FCM and reports back (push_finish). It is woken right
-- after an order completes (pg_net) and by pg_cron every minute while rows
-- wait. A notification still undelivered after a day is dropped (expired)
-- rather than sent late. The message carries only the event type and the
-- order id (to open its details) -- no amount, number or account.

CREATE TABLE IF NOT EXISTS public.push_tokens (
  token        TEXT PRIMARY KEY,
  customer_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  platform     TEXT NOT NULL DEFAULT 'android',
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_push_tokens_customer ON public.push_tokens (customer_id, updated_at DESC);
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_tokens FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.push_notifications (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  order_id     UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('deposit_completed', 'withdraw_completed')),
  status       TEXT NOT NULL DEFAULT 'pending'
               CHECK (status IN ('pending', 'sending', 'sent', 'no_device', 'failed', 'expired')),
  attempts     INT NOT NULL DEFAULT 0,
  devices      INT NOT NULL DEFAULT 0,
  last_error   TEXT,
  claimed_at   TIMESTAMPTZ,
  sent_at      TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (order_id, kind)
);
CREATE INDEX IF NOT EXISTS idx_push_notifications_open ON public.push_notifications (status, created_at)
  WHERE status IN ('pending', 'sending');
ALTER TABLE public.push_notifications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.push_notifications FROM PUBLIC, anon, authenticated;

-- Wakes the push-notifications function (same worker secret and URL as the
-- platform-orders worker).
CREATE OR REPLACE FUNCTION private.push_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/push-notifications', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'push_kick: %', SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION private.push_kick_if_work()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.push_notifications WHERE status = 'pending'
             OR (status = 'sending' AND claimed_at < now() - interval '5 minutes')) THEN
    PERFORM private.push_kick();
  END IF;
END $$;

-- Queues the notification when an order becomes completed -- never for any
-- other status.
CREATE OR REPLACE FUNCTION private.push_on_order_completed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NEW.status <> 'completed' OR (TG_OP = 'UPDATE' AND OLD.status = 'completed') OR NEW.customer_id IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.push_notifications (customer_id, order_id, kind)
  VALUES (NEW.customer_id, NEW.id, CASE WHEN NEW.direction = 'deposit' THEN 'deposit_completed' ELSE 'withdraw_completed' END)
  ON CONFLICT (order_id, kind) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    PERFORM private.push_kick(); -- pg_net sends it after this transaction commits
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS orders_push_completed ON public.orders;
CREATE TRIGGER orders_push_completed AFTER INSERT OR UPDATE OF status ON public.orders
FOR EACH ROW WHEN (NEW.status = 'completed')
EXECUTE FUNCTION private.push_on_order_completed();

-- Customer App: this device's FCM token, for the signed-in customer. A token
-- that was another account's (same phone, other login) moves to this one.
CREATE OR REPLACE FUNCTION public.customer_register_push_token(p_token text, p_platform text DEFAULT 'android')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_token text := btrim(COALESCE(p_token, ''));
BEGIN
  IF char_length(v_token) NOT BETWEEN 20 AND 4096 OR v_token ~ '\s' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid push token');
  END IF;
  INSERT INTO public.push_tokens (token, customer_id, platform)
  VALUES (v_token, v_id, CASE WHEN p_platform IN ('android', 'ios') THEN p_platform ELSE 'android' END)
  ON CONFLICT (token) DO UPDATE SET customer_id = EXCLUDED.customer_id, platform = EXCLUDED.platform, updated_at = now();
  -- At most 10 devices per customer: the most recently seen.
  DELETE FROM public.push_tokens WHERE customer_id = v_id AND token IN (
    SELECT token FROM public.push_tokens WHERE customer_id = v_id ORDER BY updated_at DESC OFFSET 10);
  RETURN jsonb_build_object('registered', true);
END $$;

CREATE OR REPLACE FUNCTION public.customer_unregister_push_token(p_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  DELETE FROM public.push_tokens WHERE token = btrim(COALESCE(p_token, '')) AND customer_id = v_id;
  RETURN jsonb_build_object('unregistered', FOUND);
END $$;

-- Service role: up to p_limit notifications to send now, each with its
-- customer's device tokens. Drops ones older than a day; takes back ones a
-- crashed sender left in 'sending'; marks ones without a device.
CREATE OR REPLACE FUNCTION public.push_claim(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n public.push_notifications;
  v_tokens text[];
  v_out jsonb := '[]'::jsonb;
BEGIN
  PERFORM private.require_service();
  UPDATE public.push_notifications SET status = 'expired', last_error = 'Not delivered within a day'
  WHERE status IN ('pending', 'sending') AND created_at < now() - interval '1 day';
  UPDATE public.push_notifications SET status = 'pending'
  WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes';

  FOR n IN
    SELECT * FROM public.push_notifications WHERE status = 'pending'
    ORDER BY created_at LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    SELECT array_agg(token ORDER BY updated_at DESC) INTO v_tokens FROM public.push_tokens WHERE customer_id = n.customer_id;
    IF v_tokens IS NULL THEN
      UPDATE public.push_notifications SET status = 'no_device', attempts = attempts + 1 WHERE id = n.id;
      CONTINUE;
    END IF;
    UPDATE public.push_notifications SET status = 'sending', attempts = attempts + 1, claimed_at = now() WHERE id = n.id;
    v_out := v_out || jsonb_build_object('id', n.id, 'kind', n.kind, 'orderId', n.order_id, 'tokens', to_jsonb(v_tokens));
  END LOOP;
  RETURN v_out;
END $$;

-- Service role: how a claimed notification went. p_sent = devices reached;
-- p_invalid_tokens are removed (uninstalled apps); p_retry asks for another
-- try (FCM unavailable), up to 5 attempts.
CREATE OR REPLACE FUNCTION public.push_finish(
  p_id uuid, p_sent int, p_error text DEFAULT NULL, p_invalid_tokens text[] DEFAULT '{}', p_retry boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n public.push_notifications;
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.push_tokens WHERE token = ANY (COALESCE(p_invalid_tokens, '{}'));
  UPDATE public.push_notifications SET
    status = CASE
      WHEN COALESCE(p_sent, 0) > 0 THEN 'sent'
      WHEN p_retry AND attempts < 5 THEN 'pending'
      WHEN p_error IS NULL AND COALESCE(p_sent, 0) = 0 THEN 'no_device'
      ELSE 'failed' END,
    devices = GREATEST(devices, COALESCE(p_sent, 0)),
    sent_at = CASE WHEN COALESCE(p_sent, 0) > 0 THEN now() ELSE sent_at END,
    last_error = left(p_error, 300)
  WHERE id = p_id AND status = 'sending'
  RETURNING * INTO n;
  RETURN jsonb_build_object('status', n.status);
END $$;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-push-notifications';
    PERFORM cron.schedule('baari-push-notifications', '* * * * *', 'SELECT private.push_kick_if_work()');
  END IF;
END
$do$;

REVOKE ALL ON FUNCTION private.push_kick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.push_kick_if_work() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.push_on_order_completed() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_register_push_token(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.customer_unregister_push_token(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.push_claim(int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.push_finish(uuid, int, text, text[], boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.customer_register_push_token(text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.customer_unregister_push_token(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.push_claim(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.push_finish(uuid, int, text, text[], boolean) TO service_role;
