-- Agent App "Send to all customers" also reaches customers' phones.
--
-- Each notification an admin sends (public.notifications, shown in the
-- Customer App's Notifications screen) now queues one push of kind
-- 'broadcast' with the same title and text. It goes to the FCM topic
-- 'customers', which every signed-in Customer App device joins (and leaves
-- on logout) -- one message for everyone instead of one per device. Same
-- queue, sender, retries and one-day expiry as the order notifications.

ALTER TABLE public.push_notifications ALTER COLUMN order_id DROP NOT NULL;
ALTER TABLE public.push_notifications ALTER COLUMN customer_id DROP NOT NULL;
ALTER TABLE public.push_notifications
  ADD COLUMN IF NOT EXISTS notification_id UUID UNIQUE REFERENCES public.notifications(id) ON DELETE CASCADE;
ALTER TABLE public.push_notifications DROP CONSTRAINT IF EXISTS push_notifications_kind_check;
ALTER TABLE public.push_notifications ADD CONSTRAINT push_notifications_kind_check
  CHECK (kind IN ('deposit_completed', 'withdraw_completed', 'broadcast'));
ALTER TABLE public.push_notifications DROP CONSTRAINT IF EXISTS push_notifications_target_check;
ALTER TABLE public.push_notifications ADD CONSTRAINT push_notifications_target_check CHECK (
  CASE WHEN kind = 'broadcast'
    THEN notification_id IS NOT NULL AND order_id IS NULL AND customer_id IS NULL
    ELSE notification_id IS NULL AND order_id IS NOT NULL AND customer_id IS NOT NULL END);

CREATE OR REPLACE FUNCTION private.push_on_notification()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.push_notifications (notification_id, kind) VALUES (NEW.id, 'broadcast')
  ON CONFLICT (notification_id) DO NOTHING;
  PERFORM private.push_kick();
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS notifications_push ON public.notifications;
CREATE TRIGGER notifications_push AFTER INSERT ON public.notifications
FOR EACH ROW EXECUTE FUNCTION private.push_on_notification();

-- As before, plus broadcasts: {id, kind 'broadcast', notificationId, title,
-- body, topic}; they need no device list.
CREATE OR REPLACE FUNCTION public.push_claim(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n public.push_notifications;
  m public.notifications;
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
    IF n.kind = 'broadcast' THEN
      SELECT * INTO m FROM public.notifications WHERE id = n.notification_id;
      UPDATE public.push_notifications SET status = 'sending', attempts = attempts + 1, claimed_at = now() WHERE id = n.id;
      v_out := v_out || jsonb_build_object('id', n.id, 'kind', n.kind, 'notificationId', n.notification_id,
        'title', m.title, 'body', m.body, 'topic', 'customers');
      CONTINUE;
    END IF;
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

REVOKE ALL ON FUNCTION private.push_on_notification() FROM PUBLIC, anon, authenticated;
