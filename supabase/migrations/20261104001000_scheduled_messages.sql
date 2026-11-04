-- Scheduled mass messages on the Telegram support bot (@Badalaisupportbot).
--
-- Managers (the Agent App) create messages that go out by themselves every day,
-- every week or every month, in Mogadishu time (GMT+3), to every active customer
-- who linked their Telegram chat with the bot (a bot can only write to chats that
-- started it). The schedules live in the database, so they keep working after a
-- restart; a worker (the support-bot function, woken every minute) sends them.
--
--   * one run per schedule and moment (UNIQUE): never two runs for the same time;
--     one delivery per run and chat (UNIQUE): never two messages to one customer;
--   * the worker sends about 25 messages a second (Telegram allows ~30) and waits
--     out Telegram's own "retry after";
--   * a moment missed for more than 6 hours (the system was down) is skipped, not
--     sent late;
--   * only managers can read or change schedules; the worker functions are for
--     the service role only; a Test message goes to the team chat only.

CREATE TABLE IF NOT EXISTS public.broadcast_schedules (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message     TEXT NOT NULL CHECK (char_length(message) BETWEEN 1 AND 4000),
  kind        TEXT NOT NULL CHECK (kind IN ('daily', 'weekly', 'monthly')),
  send_time   TIME NOT NULL,
  weekday     SMALLINT CHECK (weekday BETWEEN 1 AND 7),   -- 1 = Monday ... 7 = Sunday
  month_day   SMALLINT CHECK (month_day BETWEEN 1 AND 31),  -- a shorter month: its last day
  status      TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'paused')),
  next_run_at TIMESTAMPTZ,
  last_run_at TIMESTAMPTZ,
  created_by  UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS broadcast_schedules_due ON public.broadcast_schedules (next_run_at) WHERE status = 'active' AND deleted_at IS NULL;
ALTER TABLE public.broadcast_schedules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.broadcast_schedules FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.broadcast_runs (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  schedule_id   UUID REFERENCES public.broadcast_schedules(id) ON DELETE SET NULL,
  scheduled_for TIMESTAMPTZ,
  is_test       BOOLEAN NOT NULL DEFAULT false,
  message       TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'sending' CHECK (status IN ('sending', 'done')),
  total         INT NOT NULL DEFAULT 0,
  sent          INT NOT NULL DEFAULT 0,
  failed        INT NOT NULL DEFAULT 0,
  created_by    UUID REFERENCES public.users(id) ON DELETE SET NULL,
  started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  UNIQUE (schedule_id, scheduled_for)
);
CREATE INDEX IF NOT EXISTS broadcast_runs_recent ON public.broadcast_runs (started_at DESC);
ALTER TABLE public.broadcast_runs ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.broadcast_runs FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.broadcast_deliveries (
  id         BIGSERIAL PRIMARY KEY,
  run_id     UUID NOT NULL REFERENCES public.broadcast_runs(id) ON DELETE CASCADE,
  chat_id    BIGINT NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'sending', 'sent', 'failed')),
  error      TEXT,
  claimed_at TIMESTAMPTZ,
  sent_at    TIMESTAMPTZ,
  UNIQUE (run_id, chat_id)
);
CREATE INDEX IF NOT EXISTS broadcast_deliveries_todo ON public.broadcast_deliveries (status, id) WHERE status IN ('pending', 'sending');
ALTER TABLE public.broadcast_deliveries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.broadcast_deliveries FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------ time

-- The next moment (after p_from) that a schedule fires, in Mogadishu time.
CREATE OR REPLACE FUNCTION private.broadcast_next(p_kind text, p_time time, p_weekday int, p_month_day int, p_from timestamptz)
RETURNS timestamptz LANGUAGE plpgsql STABLE SET search_path = '' AS $$
DECLARE
  v_now timestamp := p_from AT TIME ZONE 'Africa/Mogadishu';
  v_day date := (p_from AT TIME ZONE 'Africa/Mogadishu')::date;
  v_cand timestamp;
  v_first date;
  v_last int;
BEGIN
  IF p_kind = 'daily' THEN
    v_cand := v_day + p_time;
    IF v_cand <= v_now THEN v_cand := v_cand + interval '1 day'; END IF;
  ELSIF p_kind = 'weekly' THEN
    v_cand := (v_day + ((p_weekday - extract(isodow FROM v_day)::int + 7) % 7)) + p_time;
    IF v_cand <= v_now THEN v_cand := v_cand + interval '7 days'; END IF;
  ELSE
    FOR i IN 0..2 LOOP
      v_first := (date_trunc('month', v_now) + make_interval(months => i))::date;
      v_last := extract(day FROM (v_first + interval '1 month' - interval '1 day'))::int;
      v_cand := (v_first + (least(p_month_day, v_last) - 1)) + p_time;
      EXIT WHEN v_cand > v_now;
    END LOOP;
  END IF;
  RETURN v_cand AT TIME ZONE 'Africa/Mogadishu';
END $$;

-- ------------------------------------------------------------- management

CREATE OR REPLACE FUNCTION private.broadcast_json(s public.broadcast_schedules)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', s.id, 'message', s.message, 'kind', s.kind, 'time', to_char(s.send_time, 'HH24:MI'),
    'weekday', s.weekday, 'monthDay', s.month_day, 'status', s.status,
    'nextRunAt', s.next_run_at, 'lastRunAt', s.last_run_at, 'createdAt', s.created_at,
    'lastRun', (SELECT jsonb_build_object('status', r.status, 'total', r.total, 'sent', r.sent, 'failed', r.failed,
                  'startedAt', r.started_at, 'finishedAt', r.finished_at)
                FROM public.broadcast_runs r WHERE r.schedule_id = s.id ORDER BY r.started_at DESC LIMIT 1))
$$;

CREATE OR REPLACE FUNCTION public.manage_broadcasts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  RETURN jsonb_build_object(
    'stats', jsonb_build_object(
      'registeredCustomers', (SELECT count(*) FROM public.users WHERE role = 'customer'),
      'eligibleCustomers', (SELECT count(*) FROM public.support_chats sc JOIN public.users u ON u.id = sc.customer_id
                            WHERE u.role = 'customer' AND u.status = 'active'),
      'sent', COALESCE((SELECT sum(sent) FROM public.broadcast_runs WHERE NOT is_test), 0),
      'failed', COALESCE((SELECT sum(failed) FROM public.broadcast_runs WHERE NOT is_test), 0),
      'activeSchedules', (SELECT count(*) FROM public.broadcast_schedules WHERE status = 'active' AND deleted_at IS NULL),
      'teamChatLinked', EXISTS (SELECT 1 FROM public.support_admin)),
    'schedules', COALESCE((SELECT jsonb_agg(private.broadcast_json(s) ORDER BY s.created_at DESC)
                           FROM public.broadcast_schedules s WHERE s.deleted_at IS NULL), '[]'::jsonb),
    'runs', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'scheduleId', r.schedule_id, 'isTest', r.is_test,
                        'status', r.status, 'total', r.total, 'sent', r.sent, 'failed', r.failed,
                        'startedAt', r.started_at, 'finishedAt', r.finished_at) ORDER BY r.started_at DESC)
                      FROM (SELECT * FROM public.broadcast_runs ORDER BY started_at DESC LIMIT 15) r), '[]'::jsonb));
END $$;

-- Creates (p_id null) or edits a schedule. p_time is "HH:MM" in Mogadishu time.
CREATE OR REPLACE FUNCTION public.manage_save_broadcast(
  p_id uuid, p_message text, p_kind text, p_time text, p_weekday int DEFAULT NULL, p_month_day int DEFAULT NULL,
  p_status text DEFAULT 'active')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_msg text := btrim(COALESCE(p_message, ''));
  v_time time;
  s public.broadcast_schedules;
BEGIN
  IF char_length(v_msg) < 1 OR char_length(v_msg) > 4000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The message must be 1 to 4000 characters');
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
    INSERT INTO public.broadcast_schedules (message, kind, send_time, weekday, month_day, status, created_by, next_run_at)
    VALUES (v_msg, p_kind, v_time, CASE WHEN p_kind = 'weekly' THEN p_weekday END, CASE WHEN p_kind = 'monthly' THEN p_month_day END,
            p_status, v_id, private.broadcast_next(p_kind, v_time, p_weekday, p_month_day, now()))
    RETURNING * INTO s;
    PERFORM private.audit(v_id, private.app_role(), 'broadcast.create', 'broadcast_schedule', s.id::text, NULL,
                          jsonb_build_object('kind', s.kind, 'time', p_time, 'status', s.status));
  ELSE
    UPDATE public.broadcast_schedules SET message = v_msg, kind = p_kind, send_time = v_time,
        weekday = CASE WHEN p_kind = 'weekly' THEN p_weekday END, month_day = CASE WHEN p_kind = 'monthly' THEN p_month_day END,
        status = p_status, next_run_at = private.broadcast_next(p_kind, v_time, p_weekday, p_month_day, now()), updated_at = now()
     WHERE id = p_id AND deleted_at IS NULL
     RETURNING * INTO s;
    IF NOT FOUND THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Schedule not found');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'broadcast.update', 'broadcast_schedule', s.id::text, NULL,
                          jsonb_build_object('kind', s.kind, 'time', p_time, 'status', s.status));
  END IF;
  RETURN private.broadcast_json(s);
END $$;

CREATE OR REPLACE FUNCTION public.manage_set_broadcast_status(p_id uuid, p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  s public.broadcast_schedules;
BEGIN
  IF p_status NOT IN ('active', 'paused') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid status');
  END IF;
  -- Resuming starts from the next moment: nothing missed while it was paused is sent.
  UPDATE public.broadcast_schedules
     SET status = p_status, updated_at = now(),
         next_run_at = private.broadcast_next(kind, send_time, weekday, month_day, now())
   WHERE id = p_id AND deleted_at IS NULL
   RETURNING * INTO s;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Schedule not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_status = 'paused' THEN 'broadcast.pause' ELSE 'broadcast.resume' END,
                        'broadcast_schedule', s.id::text);
  RETURN private.broadcast_json(s);
END $$;

CREATE OR REPLACE FUNCTION public.manage_delete_broadcast(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  UPDATE public.broadcast_schedules SET deleted_at = now(), status = 'paused', updated_at = now()
   WHERE id = p_id AND deleted_at IS NULL;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Schedule not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'broadcast.delete', 'broadcast_schedule', p_id::text);
  RETURN jsonb_build_object('deleted', true);
END $$;

-- A test message: sent to the team chat only (never to customers), within a minute.
CREATE OR REPLACE FUNCTION public.manage_test_broadcast(p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_msg text := btrim(COALESCE(p_message, ''));
  v_chat bigint := (SELECT chat_id FROM public.support_admin WHERE id);
  r public.broadcast_runs;
BEGIN
  IF char_length(v_msg) < 1 OR char_length(v_msg) > 4000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The message must be 1 to 4000 characters');
  END IF;
  IF v_chat IS NULL THEN
    PERFORM private.raise_api(409, 'TEAM_CHAT_NOT_LINKED', 'The Telegram team chat is not linked yet');
  END IF;
  INSERT INTO public.broadcast_runs (is_test, message, total, created_by) VALUES (true, v_msg, 1, v_id) RETURNING * INTO r;
  INSERT INTO public.broadcast_deliveries (run_id, chat_id) VALUES (r.id, v_chat);
  PERFORM private.audit(v_id, private.app_role(), 'broadcast.test', 'broadcast_run', r.id::text);
  RETURN jsonb_build_object('runId', r.id);
END $$;

-- ----------------------------------------------------------------- worker

-- Starts the runs that are due. Called by the worker every minute.
CREATE OR REPLACE FUNCTION public.broadcast_tick()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.broadcast_schedules;
  v_run uuid;
  v_started int := 0;
BEGIN
  PERFORM private.require_service();
  FOR s IN SELECT * FROM public.broadcast_schedules
            WHERE status = 'active' AND deleted_at IS NULL AND next_run_at <= now()
            ORDER BY next_run_at FOR UPDATE SKIP LOCKED LOOP
    v_run := NULL;
    -- Late by more than 6 hours (the system was down): skipped, the next moment is kept.
    IF now() - s.next_run_at <= interval '6 hours' THEN
      INSERT INTO public.broadcast_runs (schedule_id, scheduled_for, message, created_by)
      VALUES (s.id, s.next_run_at, s.message, s.created_by)
      ON CONFLICT (schedule_id, scheduled_for) DO NOTHING
      RETURNING id INTO v_run;
      IF v_run IS NOT NULL THEN
        INSERT INTO public.broadcast_deliveries (run_id, chat_id)
        SELECT v_run, sc.chat_id FROM public.support_chats sc JOIN public.users u ON u.id = sc.customer_id
         WHERE u.role = 'customer' AND u.status = 'active'
        ON CONFLICT DO NOTHING;
        UPDATE public.broadcast_runs r SET total = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id),
               status = CASE WHEN EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id) THEN 'sending' ELSE 'done' END,
               finished_at = CASE WHEN EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id) THEN NULL ELSE now() END
         WHERE r.id = v_run;
        v_started := v_started + 1;
      END IF;
    END IF;
    UPDATE public.broadcast_schedules
       SET last_run_at = CASE WHEN v_run IS NOT NULL THEN s.next_run_at ELSE last_run_at END,
           next_run_at = private.broadcast_next(s.kind, s.send_time, s.weekday, s.month_day, now())
     WHERE id = s.id;
  END LOOP;
  RETURN jsonb_build_object('started', v_started);
END $$;

-- The next messages to send (marked as being sent so no second worker sends them too).
CREATE OR REPLACE FUNCTION public.broadcast_claim(p_limit int DEFAULT 25)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v jsonb;
BEGIN
  PERFORM private.require_service();
  -- A worker that died while sending: its messages are offered again after five minutes.
  UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL
   WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes';
  WITH c AS (
    UPDATE public.broadcast_deliveries d SET status = 'sending', claimed_at = now()
     WHERE d.id IN (SELECT id FROM public.broadcast_deliveries WHERE status = 'pending' ORDER BY id
                     LIMIT GREATEST(1, LEAST(p_limit, 50)) FOR UPDATE SKIP LOCKED)
     RETURNING d.id, d.chat_id, d.run_id)
  SELECT COALESCE(jsonb_agg(jsonb_build_object('id', c.id, 'chatId', c.chat_id, 'text', r.message)), '[]'::jsonb)
    INTO v FROM c JOIN public.broadcast_runs r ON r.id = c.run_id;
  RETURN v;
END $$;

-- Results: [{"id":1,"ok":true}, {"id":2,"ok":false,"error":"blocked"}]. Counts and finished runs follow.
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
  UPDATE public.broadcast_runs r
     SET sent = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status = 'sent'),
         failed = (SELECT count(*) FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status = 'failed')
   WHERE r.id = ANY (COALESCE(v_runs, '{}'));
  UPDATE public.broadcast_runs r SET status = 'done', finished_at = now()
   WHERE r.id = ANY (COALESCE(v_runs, '{}')) AND r.status = 'sending'
     AND NOT EXISTS (SELECT 1 FROM public.broadcast_deliveries d WHERE d.run_id = r.id AND d.status IN ('pending', 'sending'));
  RETURN true;
END $$;

-- Telegram asked to slow down: those messages wait and are sent later.
CREATE OR REPLACE FUNCTION public.broadcast_release(p_ids bigint[])
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL
   WHERE id = ANY (COALESCE(p_ids, '{}')) AND status = 'sending';
  RETURN true;
END $$;

-- Wakes the worker (the support-bot function) every minute, like the other workers.
CREATE OR REPLACE FUNCTION private.broadcast_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 55000)'
  USING rtrim(v_url, '/') || '/support-bot/broadcast', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'broadcast_kick: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION private.broadcast_next(text, time, int, int, timestamptz), private.broadcast_json(public.broadcast_schedules),
  private.broadcast_kick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.broadcast_tick(), public.broadcast_claim(int), public.broadcast_result(jsonb),
  public.broadcast_release(bigint[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.broadcast_tick(), public.broadcast_claim(int), public.broadcast_result(jsonb),
  public.broadcast_release(bigint[]) TO service_role;
REVOKE ALL ON FUNCTION public.manage_broadcasts(), public.manage_save_broadcast(uuid, text, text, text, int, int, text),
  public.manage_set_broadcast_status(uuid, text), public.manage_delete_broadcast(uuid), public.manage_test_broadcast(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_broadcasts(), public.manage_save_broadcast(uuid, text, text, text, int, int, text),
  public.manage_set_broadcast_status(uuid, text), public.manage_delete_broadcast(uuid), public.manage_test_broadcast(text) TO authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-broadcast';
    PERFORM cron.schedule('baari-broadcast', '* * * * *', 'SELECT private.broadcast_kick()');
  END IF;
END
$do$;
