-- Scheduled messages also reach the Customer App itself as push notifications (Firebase Cloud Messaging),
-- not only Telegram: every active Customer App customer, even with the app closed.
--
-- A schedule now has channels ('push', 'telegram') and a title; each moment makes one run per channel.
-- A push run has one delivery per active customer (UNIQUE: never two notifications to one customer); the
-- push-notifications function sends it to each of the customer's registered devices. A customer with no
-- device (never allowed notifications, or signed out) is counted as "no device"; a device FCM says is
-- gone (uninstalled) loses its token and is a failure only when it was the customer's only one.
-- Only managers manage schedules; the worker functions are for the service role.

ALTER TABLE public.broadcast_schedules ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE public.broadcast_schedules ADD COLUMN IF NOT EXISTS channels TEXT[] NOT NULL DEFAULT ARRAY['telegram'];
ALTER TABLE public.broadcast_schedules DROP CONSTRAINT IF EXISTS broadcast_schedules_channels_check;
ALTER TABLE public.broadcast_schedules ADD CONSTRAINT broadcast_schedules_channels_check
  CHECK (cardinality(channels) BETWEEN 1 AND 2 AND channels <@ ARRAY['push', 'telegram']);
ALTER TABLE public.broadcast_schedules DROP CONSTRAINT IF EXISTS broadcast_schedules_title_len;
ALTER TABLE public.broadcast_schedules ADD CONSTRAINT broadcast_schedules_title_len CHECK (title IS NULL OR char_length(title) <= 100);

ALTER TABLE public.broadcast_runs ADD COLUMN IF NOT EXISTS channel TEXT NOT NULL DEFAULT 'telegram' CHECK (channel IN ('telegram', 'push'));
ALTER TABLE public.broadcast_runs ADD COLUMN IF NOT EXISTS title TEXT;
ALTER TABLE public.broadcast_runs ADD COLUMN IF NOT EXISTS skipped INT NOT NULL DEFAULT 0;
ALTER TABLE public.broadcast_runs DROP CONSTRAINT IF EXISTS broadcast_runs_schedule_id_scheduled_for_key;
ALTER TABLE public.broadcast_runs DROP CONSTRAINT IF EXISTS broadcast_runs_moment_channel_key;
ALTER TABLE public.broadcast_runs ADD CONSTRAINT broadcast_runs_moment_channel_key UNIQUE (schedule_id, scheduled_for, channel);

ALTER TABLE public.broadcast_deliveries ALTER COLUMN chat_id DROP NOT NULL;
ALTER TABLE public.broadcast_deliveries ADD COLUMN IF NOT EXISTS devices INT NOT NULL DEFAULT 0;
ALTER TABLE public.broadcast_deliveries DROP CONSTRAINT IF EXISTS broadcast_deliveries_status_check;
ALTER TABLE public.broadcast_deliveries ADD CONSTRAINT broadcast_deliveries_status_check
  CHECK (status IN ('pending', 'sending', 'sent', 'failed', 'no_device'));

-- ------------------------------------------------------------------ counts

-- Sent / failed / no-device counts of runs, and finished ones.
CREATE OR REPLACE FUNCTION private.broadcast_refresh_runs(p_runs uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.broadcast_runs r
     SET sent = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status = 'sent'),
         failed = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status = 'failed'),
         skipped = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status = 'no_device')
   WHERE r.id = ANY (COALESCE(p_runs, '{}'));
  UPDATE public.broadcast_runs r SET status = 'done', finished_at = now()
   WHERE r.id = ANY (COALESCE(p_runs, '{}')) AND r.status = 'sending'
     AND NOT EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status IN ('pending', 'sending'));
END $$;

CREATE OR REPLACE FUNCTION public.broadcast_result(p_results jsonb)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_runs uuid[];
BEGIN
  PERFORM private.require_service();
  WITH x AS (SELECT (e->>'id')::bigint AS id, COALESCE((e->>'ok')::boolean, false) AS ok, left(e->>'error', 200) AS error
               FROM jsonb_array_elements(COALESCE(p_results, '[]'::jsonb)) e),
       u AS (UPDATE public.broadcast_deliveries d
                SET status = CASE WHEN x.ok THEN 'sent' ELSE 'failed' END, error = x.error,
                    sent_at = CASE WHEN x.ok THEN now() END
               FROM x WHERE d.id = x.id AND d.status = 'sending'
             RETURNING d.run_id)
  SELECT array_agg(DISTINCT run_id) INTO v_runs FROM u;
  PERFORM private.broadcast_refresh_runs(v_runs);
  RETURN true;
END $$;

-- The Telegram worker only takes Telegram deliveries (they have a chat).
CREATE OR REPLACE FUNCTION public.broadcast_claim(p_limit int DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM private.require_service();
  UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL
   WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes';
  WITH c AS (
    UPDATE public.broadcast_deliveries d SET status = 'sending', claimed_at = now()
     WHERE d.id IN (SELECT id FROM public.broadcast_deliveries WHERE status = 'pending' AND chat_id IS NOT NULL ORDER BY id
                     LIMIT GREATEST(1, LEAST(p_limit, 50)) FOR UPDATE SKIP LOCKED)
     RETURNING d.id, d.chat_id, d.run_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', c.id, 'chatId', c.chat_id, 'text', r.message)), '[]'::jsonb)
    INTO v FROM c JOIN public.broadcast_runs r ON r.id = c.run_id;
  RETURN v;
END $$;

-- ---------------------------------------------------------------- the runs

CREATE OR REPLACE FUNCTION public.broadcast_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.broadcast_schedules;
  v_run uuid;
  v_ch text;
  v_started int := 0;
  v_any boolean;
BEGIN
  PERFORM private.require_service();
  FOR s IN SELECT * FROM public.broadcast_schedules
            WHERE status = 'active' AND deleted_at IS NULL AND next_run_at <= now()
            ORDER BY next_run_at FOR UPDATE SKIP LOCKED LOOP
    v_any := false;
    -- Late by more than 6 hours (the system was down): skipped, the next moment is kept.
    IF now() - s.next_run_at <= interval '6 hours' THEN
      FOREACH v_ch IN ARRAY s.channels LOOP
        v_run := NULL;
        INSERT INTO public.broadcast_runs (schedule_id, scheduled_for, channel, title, message, created_by)
        VALUES (s.id, s.next_run_at, v_ch, s.title, s.message, s.created_by)
        ON CONFLICT (schedule_id, scheduled_for, channel) DO NOTHING
        RETURNING id INTO v_run;
        IF v_run IS NULL THEN CONTINUE; END IF;
        IF v_ch = 'push' THEN
          -- Every active Customer App customer, once.
          INSERT INTO public.broadcast_deliveries (run_id, customer_id)
          SELECT v_run, u.id FROM public.users u WHERE u.role = 'customer' AND u.status = 'active'
          ON CONFLICT DO NOTHING;
        ELSE
          -- Every active customer who linked Telegram with the bot, once (the newest chat if they linked two).
          INSERT INTO public.broadcast_deliveries (run_id, chat_id, customer_id)
          SELECT DISTINCT ON (sc.customer_id) v_run, sc.chat_id, sc.customer_id
            FROM public.support_chats sc JOIN public.users u ON u.id = sc.customer_id
           WHERE u.role = 'customer' AND u.status = 'active'
           ORDER BY sc.customer_id, sc.linked_at DESC NULLS LAST, sc.updated_at DESC
          ON CONFLICT DO NOTHING;
        END IF;
        UPDATE public.broadcast_runs r SET total = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id),
               status = CASE WHEN EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id) THEN 'sending' ELSE 'done' END,
               finished_at = CASE WHEN EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id) THEN NULL ELSE now() END
         WHERE r.id = v_run;
        v_any := true;
        v_started := v_started + 1;
      END LOOP;
    END IF;
    UPDATE public.broadcast_schedules
       SET last_run_at = CASE WHEN v_any THEN s.next_run_at ELSE last_run_at END,
           next_run_at = private.broadcast_next(s.kind, s.send_time, s.weekday, s.month_day, now())
     WHERE id = s.id;
  END LOOP;
  RETURN jsonb_build_object('started', v_started);
END $$;

-- ------------------------------------------------------------- push worker

-- The next push notifications to send, each with the customer's device tokens. A customer without a
-- device is settled here as "no device" (nothing to send).
CREATE OR REPLACE FUNCTION public.broadcast_push_claim(p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_ids bigint[];
  v_runs uuid[];
  v jsonb;
BEGIN
  PERFORM private.require_service();
  UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL
   WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes';
  -- Not delivered within a day (FCM down for long): given up, counted as failed.
  UPDATE public.broadcast_deliveries d SET status = 'failed', error = 'expired'
   FROM public.broadcast_runs r
   WHERE r.id = d.run_id AND r.channel = 'push' AND d.status = 'pending' AND r.started_at < now() - interval '1 day';
  SELECT array_agg(id) INTO v_ids FROM (
    SELECT d.id FROM public.broadcast_deliveries d JOIN public.broadcast_runs r ON r.id = d.run_id
     WHERE d.status = 'pending' AND r.channel = 'push' ORDER BY d.id
     LIMIT GREATEST(1, LEAST(p_limit, 200)) FOR UPDATE OF d SKIP LOCKED) q;
  IF v_ids IS NULL THEN RETURN '[]'::jsonb; END IF;
  WITH nd AS (
    UPDATE public.broadcast_deliveries d SET status = 'no_device', error = 'no_device'
     WHERE d.id = ANY (v_ids) AND NOT EXISTS (SELECT 1 FROM public.push_tokens t WHERE t.customer_id = d.customer_id)
     RETURNING d.run_id)
  SELECT array_agg(DISTINCT run_id) INTO v_runs FROM nd;
  PERFORM private.broadcast_refresh_runs(v_runs);
  WITH c AS (
    UPDATE public.broadcast_deliveries d SET status = 'sending', claimed_at = now()
     WHERE d.id = ANY (v_ids) AND d.status = 'pending'
     RETURNING d.id, d.customer_id, d.run_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', c.id, 'customerId', c.customer_id, 'title', COALESCE(r.title, 'BADAL EXCHANGE'), 'body', r.message,
           'tokens', (SELECT COALESCE(jsonb_agg(t.token ORDER BY t.updated_at DESC), '[]'::jsonb) FROM public.push_tokens t WHERE t.customer_id = c.customer_id))),
         '[]'::jsonb)
    INTO v FROM c JOIN public.broadcast_runs r ON r.id = c.run_id;
  RETURN v;
END $$;

-- Results: [{"id":1,"ok":true,"devices":2}, {"id":2,"ok":false,"error":"..."}] and the tokens FCM said are gone.
CREATE OR REPLACE FUNCTION public.broadcast_push_result(p_results jsonb, p_invalid_tokens text[] DEFAULT '{}')
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_runs uuid[];
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.push_tokens WHERE token = ANY (COALESCE(p_invalid_tokens, '{}'));
  WITH x AS (SELECT (e->>'id')::bigint AS id, COALESCE((e->>'ok')::boolean, false) AS ok,
                    COALESCE((e->>'devices')::int, 0) AS devices, left(e->>'error', 200) AS error
               FROM jsonb_array_elements(COALESCE(p_results, '[]'::jsonb)) e),
       u AS (UPDATE public.broadcast_deliveries d
                SET status = CASE WHEN x.ok THEN 'sent' ELSE 'failed' END, error = x.error, devices = x.devices,
                    sent_at = CASE WHEN x.ok THEN now() END
               FROM x WHERE d.id = x.id AND d.status = 'sending'
             RETURNING d.run_id)
  SELECT array_agg(DISTINCT run_id) INTO v_runs FROM u;
  PERFORM private.broadcast_refresh_runs(v_runs);
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.broadcast_push_release(p_ids bigint[])
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL
   WHERE id = ANY (COALESCE(p_ids, '{}')) AND status = 'sending';
  RETURN true;
END $$;

-- ------------------------------------------------------------- management

CREATE OR REPLACE FUNCTION private.broadcast_json(s public.broadcast_schedules)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', s.id, 'title', s.title, 'message', s.message, 'kind', s.kind, 'time', to_char(s.send_time, 'HH24:MI'),
    'channels', to_jsonb(s.channels), 'weekday', s.weekday, 'monthDay', s.month_day, 'status', s.status,
    'nextRunAt', s.next_run_at, 'lastRunAt', s.last_run_at, 'createdAt', s.created_at,
    'lastRun', (SELECT jsonb_build_object('status', r.status, 'total', r.total, 'sent', r.sent, 'failed', r.failed,
                  'skipped', r.skipped, 'channel', r.channel, 'startedAt', r.started_at, 'finishedAt', r.finished_at)
                FROM public.broadcast_runs r WHERE r.schedule_id = s.id ORDER BY r.started_at DESC, r.channel LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION public.manage_broadcasts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  RETURN jsonb_build_object(
    'stats', jsonb_build_object(
      'registeredCustomers', (SELECT count(*) FROM public.users WHERE role = 'customer'),
      'activeCustomers', (SELECT count(*) FROM public.users WHERE role = 'customer' AND status = 'active'),
      'pushReachable', (SELECT count(DISTINCT t.customer_id) FROM public.push_tokens t JOIN public.users u ON u.id = t.customer_id
                         WHERE u.role = 'customer' AND u.status = 'active'),
      'eligibleCustomers', (SELECT count(DISTINCT sc.customer_id) FROM public.support_chats sc JOIN public.users u ON u.id = sc.customer_id
                            WHERE u.role = 'customer' AND u.status = 'active'),
      'sent', COALESCE((SELECT sum(sent) FROM public.broadcast_runs WHERE NOT is_test), 0),
      'failed', COALESCE((SELECT sum(failed) FROM public.broadcast_runs WHERE NOT is_test), 0),
      'pushSent', COALESCE((SELECT sum(sent) FROM public.broadcast_runs WHERE NOT is_test AND channel = 'push'), 0),
      'pushFailed', COALESCE((SELECT sum(failed) FROM public.broadcast_runs WHERE NOT is_test AND channel = 'push'), 0),
      'pushNoDevice', COALESCE((SELECT sum(skipped) FROM public.broadcast_runs WHERE NOT is_test AND channel = 'push'), 0),
      'telegramSent', COALESCE((SELECT sum(sent) FROM public.broadcast_runs WHERE NOT is_test AND channel = 'telegram'), 0),
      'telegramFailed', COALESCE((SELECT sum(failed) FROM public.broadcast_runs WHERE NOT is_test AND channel = 'telegram'), 0),
      'activeSchedules', (SELECT count(*) FROM public.broadcast_schedules WHERE status = 'active' AND deleted_at IS NULL),
      'teamChatLinked', EXISTS (SELECT 1 FROM public.support_admin)),
    'schedules', COALESCE((SELECT jsonb_agg(private.broadcast_json(s) ORDER BY s.created_at DESC)
                           FROM public.broadcast_schedules s WHERE s.deleted_at IS NULL), '[]'::jsonb),
    'runs', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'scheduleId', r.schedule_id, 'isTest', r.is_test,
                        'channel', r.channel, 'status', r.status, 'total', r.total, 'sent', r.sent, 'failed', r.failed,
                        'skipped', r.skipped, 'startedAt', r.started_at, 'finishedAt', r.finished_at) ORDER BY r.started_at DESC)
                      FROM (SELECT * FROM public.broadcast_runs ORDER BY started_at DESC LIMIT 15) r), '[]'::jsonb));
END $$;

DROP FUNCTION IF EXISTS public.manage_save_broadcast(uuid, text, text, text, int, int, text);

-- Creates (p_id null) or edits a schedule. p_time is "HH:MM" in Mogadishu time; p_channels: 'push' and / or 'telegram'.
CREATE OR REPLACE FUNCTION public.manage_save_broadcast(
  p_id uuid, p_message text, p_kind text, p_time text, p_weekday int DEFAULT NULL, p_month_day int DEFAULT NULL,
  p_status text DEFAULT 'active', p_title text DEFAULT NULL, p_channels text[] DEFAULT ARRAY['push'])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_msg text := btrim(COALESCE(p_message, ''));
  v_title text := NULLIF(btrim(COALESCE(p_title, '')), '');
  v_channels text[] := (SELECT COALESCE(array_agg(DISTINCT c ORDER BY c), '{}') FROM unnest(COALESCE(p_channels, '{}')) c);
  v_time time;
  s public.broadcast_schedules;
BEGIN
  IF char_length(v_msg) < 1 OR char_length(v_msg) > 4000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The message must be 1 to 4000 characters');
  END IF;
  IF v_title IS NOT NULL AND char_length(v_title) > 100 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The title must be at most 100 characters');
  END IF;
  IF cardinality(v_channels) = 0 OR NOT (v_channels <@ ARRAY['push', 'telegram']) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose push notification, Telegram or both');
  END IF;
  IF p_kind NOT IN ('daily', 'weekly', 'monthly') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The schedule must be daily, weekly or monthly');
  END IF;
  IF p_status NOT IN ('active', 'paused') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid status');
  END IF;
  BEGIN
    v_time := p_time::time;
  EXCEPTION WHEN others THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The time must be HH:MM');
  END;
  IF p_kind = 'weekly' AND (p_weekday IS NULL OR p_weekday NOT BETWEEN 1 AND 7) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose a day of the week');
  END IF;
  IF p_kind = 'monthly' AND (p_month_day IS NULL OR p_month_day NOT BETWEEN 1 AND 31) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose a day of the month');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.broadcast_schedules (title, message, kind, send_time, weekday, month_day, channels, status, created_by, next_run_at)
    VALUES (v_title, v_msg, p_kind, v_time, CASE WHEN p_kind = 'weekly' THEN p_weekday END, CASE WHEN p_kind = 'monthly' THEN p_month_day END,
            v_channels, p_status, v_id, private.broadcast_next(p_kind, v_time, p_weekday, p_month_day, now()))
    RETURNING * INTO s;
    PERFORM private.audit(v_id, private.app_role(), 'broadcast.create', 'broadcast_schedule', s.id::text, NULL,
                          jsonb_build_object('kind', s.kind, 'time', p_time, 'status', s.status, 'channels', s.channels));
  ELSE
    UPDATE public.broadcast_schedules SET title = v_title, message = v_msg, kind = p_kind, send_time = v_time,
        weekday = CASE WHEN p_kind = 'weekly' THEN p_weekday END, month_day = CASE WHEN p_kind = 'monthly' THEN p_month_day END,
        channels = v_channels, status = p_status,
        next_run_at = private.broadcast_next(p_kind, v_time, p_weekday, p_month_day, now()), updated_at = now()
     WHERE id = p_id AND deleted_at IS NULL
     RETURNING * INTO s;
    IF NOT FOUND THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Schedule not found');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'broadcast.update', 'broadcast_schedule', s.id::text, NULL,
                          jsonb_build_object('kind', s.kind, 'time', p_time, 'status', s.status, 'channels', s.channels));
  END IF;
  RETURN private.broadcast_json(s);
END $$;

-- A test push: to one customer's devices (by phone number: the admin's own Customer App account), never to everyone.
CREATE OR REPLACE FUNCTION public.manage_test_push(p_title text, p_message text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_msg text := btrim(COALESCE(p_message, ''));
  v_digits text := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
  v_cust uuid;
  r public.broadcast_runs;
BEGIN
  IF char_length(v_msg) < 1 OR char_length(v_msg) > 4000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The message must be 1 to 4000 characters');
  END IF;
  IF char_length(v_digits) = 9 THEN v_digits := '252' || v_digits; END IF;
  SELECT id INTO v_cust FROM public.users WHERE role = 'customer' AND phone = v_digits;
  IF v_cust IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'No Customer App customer has this phone number');
  END IF;
  INSERT INTO public.broadcast_runs (is_test, channel, title, message, total, created_by)
  VALUES (true, 'push', NULLIF(btrim(COALESCE(p_title, '')), ''), v_msg, 1, v_id) RETURNING * INTO r;
  INSERT INTO public.broadcast_deliveries (run_id, customer_id) VALUES (r.id, v_cust);
  PERFORM private.audit(v_id, private.app_role(), 'broadcast.test_push', 'broadcast_run', r.id::text);
  RETURN jsonb_build_object('runId', r.id, 'hasDevice', EXISTS (SELECT 1 FROM public.push_tokens WHERE customer_id = v_cust));
END $$;

-- ------------------------------------------------------------ waking FCM

-- Wakes the push-notifications function (which also starts the due runs) when a push run is due or waiting.
CREATE OR REPLACE FUNCTION private.broadcast_push_kick_if_work()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.broadcast_schedules WHERE status = 'active' AND deleted_at IS NULL
                     AND 'push' = ANY (channels) AND next_run_at <= now())
          OR EXISTS (SELECT 1 FROM public.broadcast_deliveries d JOIN public.broadcast_runs r ON r.id = d.run_id
                      WHERE r.channel = 'push' AND (d.status = 'pending' OR (d.status = 'sending' AND d.claimed_at < now() - interval '5 minutes')))) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 55000)'
  USING rtrim(v_url, '/') || '/push-notifications', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'broadcast_push_kick_if_work: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION private.broadcast_refresh_runs(uuid[]), private.broadcast_push_kick_if_work() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.broadcast_tick(), public.broadcast_claim(int), public.broadcast_result(jsonb),
  public.broadcast_push_claim(int), public.broadcast_push_result(jsonb, text[]), public.broadcast_push_release(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.broadcast_tick(), public.broadcast_claim(int), public.broadcast_result(jsonb),
  public.broadcast_push_claim(int), public.broadcast_push_result(jsonb, text[]), public.broadcast_push_release(bigint[]) TO service_role;
REVOKE ALL ON FUNCTION public.manage_broadcasts(), public.manage_save_broadcast(uuid, text, text, text, int, int, text, text, text[]),
  public.manage_test_push(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_broadcasts(), public.manage_save_broadcast(uuid, text, text, text, int, int, text, text, text[]),
  public.manage_test_push(text, text, text) TO authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-broadcast-push';
    PERFORM cron.schedule('baari-broadcast-push', '* * * * *', 'SELECT private.broadcast_push_kick_if_work()');
  END IF;
END
$do$;
