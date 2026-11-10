-- BADAL AI Developer Bot: the database side (functions/dev-bot, .github/workflows/dev-agent.yml).
--
-- The owner sends requests on Telegram; the bot plans them with Claude and runs a coding agent in GitHub Actions
-- that works on a BRANCH and opens a PULL REQUEST: it can never merge, deploy, change production data or touch
-- secrets. Production deployments (and anything that moves money) need the owner's explicit approval button,
-- one time, and are audited.
--
-- Everything here is for the service role (the Edge Function) only; no table can be read or written directly.

-- ------------------------------------------------------------------ who may use the bot

CREATE TABLE IF NOT EXISTS public.dev_bot_users (
  telegram_id BIGINT PRIMARY KEY,
  name        TEXT,
  role        TEXT NOT NULL CHECK (role IN ('owner', 'developer')),
  added_by    BIGINT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_at  TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS dev_bot_one_owner ON public.dev_bot_users ((true)) WHERE role = 'owner' AND revoked_at IS NULL;

-- ------------------------------------------------------------------ tasks, their log, memory, audit, approvals

CREATE TABLE IF NOT EXISTS public.dev_tasks (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  number        BIGINT GENERATED ALWAYS AS IDENTITY UNIQUE,
  title         TEXT NOT NULL,
  request       TEXT NOT NULL,
  status        TEXT NOT NULL DEFAULT 'queued' CHECK (status IN
                  ('clarify', 'awaiting_approval', 'queued', 'running', 'review', 'done', 'failed', 'cancelled')),
  risk          TEXT NOT NULL DEFAULT 'medium' CHECK (risk IN ('low', 'medium', 'high')),
  branch        TEXT,
  pr_url        TEXT,
  pr_number     INT,
  summary       TEXT,
  result        JSONB NOT NULL DEFAULT '{}'::jsonb,
  requested_by  BIGINT NOT NULL,
  chat_id       BIGINT NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  started_at    TIMESTAMPTZ,
  last_event_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  finished_at   TIMESTAMPTZ,
  ci_reported   BOOLEAN NOT NULL DEFAULT false
);
CREATE INDEX IF NOT EXISTS dev_tasks_status ON public.dev_tasks (status, created_at);

CREATE TABLE IF NOT EXISTS public.dev_task_events (
  id      BIGSERIAL PRIMARY KEY,
  task_id UUID NOT NULL REFERENCES public.dev_tasks(id) ON DELETE CASCADE,
  at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  kind    TEXT NOT NULL,
  message TEXT NOT NULL,
  detail  JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS dev_task_events_task ON public.dev_task_events (task_id, id DESC);

-- What the developer knows between requests: architecture, decisions, bugs and their fixes, features, deployments.
CREATE TABLE IF NOT EXISTS public.dev_memory (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       TEXT NOT NULL CHECK (kind IN ('architecture', 'decision', 'bug', 'feature', 'deploy', 'note')),
  title      TEXT NOT NULL,
  body       TEXT NOT NULL,
  pinned     BOOLEAN NOT NULL DEFAULT false,
  task_id    UUID REFERENCES public.dev_tasks(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (kind, title)
);

CREATE TABLE IF NOT EXISTS public.dev_audit (
  id     BIGSERIAL PRIMARY KEY,
  at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  actor  BIGINT,
  action TEXT NOT NULL,
  target TEXT,
  ok     BOOLEAN NOT NULL DEFAULT true,
  detail JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS dev_audit_recent ON public.dev_audit (id DESC);

-- An approval button: used once, by the person it was made for, within 15 minutes.
CREATE TABLE IF NOT EXISTS public.dev_pending (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind       TEXT NOT NULL CHECK (kind IN ('task', 'backup', 'deploy', 'deploy_go', 'deploy_nobackup')),
  actor      BIGINT NOT NULL,
  payload    JSONB NOT NULL DEFAULT '{}'::jsonb,
  expires_at TIMESTAMPTZ NOT NULL DEFAULT now() + interval '15 minutes',
  used_at    TIMESTAMPTZ
);

ALTER TABLE public.dev_bot_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_task_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_memory ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.dev_pending ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.dev_bot_users, public.dev_tasks, public.dev_task_events, public.dev_memory, public.dev_audit, public.dev_pending
  FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------ authorization

-- An authorized developer-bot user: on the list, not revoked, AND a linked administrator of the platform.
-- Returns {authorized, role, name, reason}.
CREATE OR REPLACE FUNCTION public.dev_auth(p_tg bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u public.dev_bot_users;
  v_admin boolean;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO u FROM public.dev_bot_users WHERE telegram_id = p_tg AND revoked_at IS NULL;
  IF u.telegram_id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'not_listed',
      'ownerExists', EXISTS (SELECT 1 FROM public.dev_bot_users WHERE role = 'owner' AND revoked_at IS NULL));
  END IF;
  SELECT EXISTS (SELECT 1 FROM public.telegram_operators o JOIN public.users x ON x.id = o.user_id
                  WHERE o.telegram_user_id = p_tg AND x.role = 'admin' AND x.status = 'active') INTO v_admin;
  IF NOT v_admin THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'not_admin');
  END IF;
  RETURN jsonb_build_object('authorized', true, 'role', u.role, 'name', u.name);
END $$;

-- The first start: when there is no owner yet, a Telegram account linked to an ADMIN of the platform (Agent App >
-- Account > Telegram Bot) becomes the owner. Afterwards only the owner adds people.
CREATE OR REPLACE FUNCTION public.dev_claim_owner(p_tg bigint, p_name text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF EXISTS (SELECT 1 FROM public.dev_bot_users WHERE role = 'owner' AND revoked_at IS NULL) THEN
    RETURN false;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.telegram_operators o JOIN public.users x ON x.id = o.user_id
                  WHERE o.telegram_user_id = p_tg AND x.role = 'admin' AND x.status = 'active') THEN
    RETURN false;
  END IF;
  INSERT INTO public.dev_bot_users (telegram_id, name, role, added_by) VALUES (p_tg, left(p_name, 100), 'owner', p_tg)
  ON CONFLICT (telegram_id) DO UPDATE SET role = 'owner', revoked_at = NULL, name = EXCLUDED.name;
  INSERT INTO public.dev_audit (actor, action, target) VALUES (p_tg, 'owner_claimed', p_tg::text);
  RETURN true;
END $$;

-- The owner lists another linked administrator as a developer (or takes the access away). Never the owner role.
CREATE OR REPLACE FUNCTION public.dev_user_set(p_actor bigint, p_tg bigint, p_name text, p_grant boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF NOT EXISTS (SELECT 1 FROM public.dev_bot_users WHERE telegram_id = p_actor AND role = 'owner' AND revoked_at IS NULL) THEN
    INSERT INTO public.dev_audit (actor, action, target, ok) VALUES (p_actor, CASE WHEN p_grant THEN 'authorize' ELSE 'revoke' END, p_tg::text, false);
    RETURN 'not_owner';
  END IF;
  IF p_tg = p_actor THEN RETURN 'self'; END IF;
  IF p_grant THEN
    IF NOT EXISTS (SELECT 1 FROM public.telegram_operators o JOIN public.users x ON x.id = o.user_id
                    WHERE o.telegram_user_id = p_tg AND x.role = 'admin' AND x.status = 'active') THEN
      RETURN 'not_admin';
    END IF;
    INSERT INTO public.dev_bot_users (telegram_id, name, role, added_by) VALUES (p_tg, left(p_name, 100), 'developer', p_actor)
    ON CONFLICT (telegram_id) DO UPDATE SET revoked_at = NULL, role = CASE WHEN dev_bot_users.role = 'owner' THEN 'owner' ELSE 'developer' END;
  ELSE
    UPDATE public.dev_bot_users SET revoked_at = now() WHERE telegram_id = p_tg AND role = 'developer';
  END IF;
  INSERT INTO public.dev_audit (actor, action, target) VALUES (p_actor, CASE WHEN p_grant THEN 'authorize' ELSE 'revoke' END, p_tg::text);
  RETURN 'ok';
END $$;

-- ------------------------------------------------------------------ audit, tasks

CREATE OR REPLACE FUNCTION public.dev_audit_add(p_actor bigint, p_action text, p_target text DEFAULT NULL, p_ok boolean DEFAULT true, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.dev_audit (actor, action, target, ok, detail) VALUES (p_actor, left(p_action, 60), left(p_target, 200), p_ok, COALESCE(p_detail, '{}'::jsonb));
  DELETE FROM public.dev_audit WHERE id < (SELECT max(id) - 20000 FROM public.dev_audit);
END $$;

-- A new request. At most 1 task running at a time (the others wait in the queue) and 10 new tasks in 24 hours.
-- p_status: 'clarify' (a question is open), 'awaiting_approval' (high risk), or 'queued'.
CREATE OR REPLACE FUNCTION public.dev_task_create(p_actor bigint, p_chat bigint, p_title text, p_request text, p_risk text, p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.dev_tasks;
BEGIN
  PERFORM private.require_service();
  IF p_status NOT IN ('clarify', 'awaiting_approval', 'queued') OR p_risk NOT IN ('low', 'medium', 'high') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid task');
  END IF;
  IF (SELECT count(*) FROM public.dev_tasks WHERE created_at > now() - interval '24 hours') >= 10 THEN
    RETURN jsonb_build_object('limited', true);
  END IF;
  INSERT INTO public.dev_tasks (title, request, status, risk, requested_by, chat_id)
  VALUES (left(p_title, 200), left(p_request, 8000), p_status, p_risk, p_actor, p_chat) RETURNING * INTO t;
  INSERT INTO public.dev_task_events (task_id, kind, message) VALUES (t.id, 'created', left(p_title, 200));
  RETURN to_jsonb(t);
END $$;

-- An answer to a clarifying question is added to the request, which is then queued.
CREATE OR REPLACE FUNCTION public.dev_task_refine(p_id uuid, p_more text, p_title text, p_risk text, p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.dev_tasks;
BEGIN
  PERFORM private.require_service();
  UPDATE public.dev_tasks SET request = left(request || E'\n\n' || p_more, 8000), title = COALESCE(NULLIF(left(p_title, 200), ''), title),
    risk = COALESCE(p_risk, risk), status = p_status, last_event_at = now()
  WHERE id = p_id AND status = 'clarify' RETURNING * INTO t;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  INSERT INTO public.dev_task_events (task_id, kind, message) VALUES (t.id, 'refined', left(p_more, 300));
  RETURN to_jsonb(t);
END $$;

CREATE OR REPLACE FUNCTION public.dev_task_event(p_id uuid, p_kind text, p_message text, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.dev_task_events (task_id, kind, message, detail) VALUES (p_id, left(p_kind, 30), left(p_message, 1000), COALESCE(p_detail, '{}'::jsonb));
  UPDATE public.dev_tasks SET last_event_at = now() WHERE id = p_id;
END $$;

-- The fields the agent and the bot may set; the status moves only along the allowed paths.
CREATE OR REPLACE FUNCTION public.dev_task_set(p_id uuid, p_status text, p_fields jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.dev_tasks;
  v_ok boolean;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO t FROM public.dev_tasks WHERE id = p_id FOR UPDATE;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  v_ok := CASE t.status
    WHEN 'clarify' THEN p_status IN ('queued', 'awaiting_approval', 'cancelled', 'clarify')
    WHEN 'awaiting_approval' THEN p_status IN ('queued', 'cancelled', 'awaiting_approval')
    WHEN 'queued' THEN p_status IN ('running', 'cancelled', 'queued', 'failed')
    WHEN 'running' THEN p_status IN ('review', 'done', 'failed', 'cancelled', 'running')
    WHEN 'review' THEN p_status IN ('done', 'failed', 'cancelled', 'review')
    ELSE p_status = t.status -- done, failed and cancelled are final
  END;
  IF NOT v_ok THEN
    RETURN jsonb_build_object('refused', true, 'from', t.status, 'to', p_status);
  END IF;
  UPDATE public.dev_tasks SET
    status = p_status,
    branch = COALESCE(left(p_fields ->> 'branch', 120), branch),
    pr_url = COALESCE(left(p_fields ->> 'prUrl', 300), pr_url),
    pr_number = COALESCE((p_fields ->> 'prNumber')::int, pr_number),
    summary = COALESCE(left(p_fields ->> 'summary', 4000), summary),
    risk = COALESCE(NULLIF(p_fields ->> 'risk', ''), risk),
    result = CASE WHEN p_fields ? 'result' THEN p_fields -> 'result' ELSE result END,
    ci_reported = COALESCE((p_fields ->> 'ciReported')::boolean, ci_reported),
    started_at = CASE WHEN p_status = 'running' AND started_at IS NULL THEN now() ELSE started_at END,
    finished_at = CASE WHEN p_status IN ('done', 'failed', 'cancelled') AND finished_at IS NULL THEN now() ELSE finished_at END,
    last_event_at = now()
  WHERE id = p_id RETURNING * INTO t;
  RETURN to_jsonb(t);
END $$;

CREATE OR REPLACE FUNCTION public.dev_task_get(p_ref text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.dev_tasks;
BEGIN
  PERFORM private.require_service();
  IF p_ref ~ '^[0-9]{1,9}$' THEN
    SELECT * INTO t FROM public.dev_tasks WHERE number = p_ref::bigint;
  ELSIF p_ref ~ '^[0-9a-f-]{36}$' THEN
    SELECT * INTO t FROM public.dev_tasks WHERE id = p_ref::uuid;
  END IF;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  RETURN to_jsonb(t) || jsonb_build_object('events', COALESCE((SELECT jsonb_agg(jsonb_build_object('at', e.at, 'kind', e.kind, 'message', e.message) ORDER BY e.id DESC)
                                                                 FROM (SELECT * FROM public.dev_task_events WHERE task_id = t.id ORDER BY id DESC LIMIT 12) e), '[]'::jsonb));
END $$;

CREATE OR REPLACE FUNCTION public.dev_task_list(p_limit int DEFAULT 10, p_open_only boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x) ORDER BY x.number DESC) FROM (
    SELECT number, id, title, status, risk, branch, pr_url, pr_number, summary, created_at, started_at, finished_at, last_event_at, chat_id, requested_by
      FROM public.dev_tasks WHERE (NOT p_open_only OR status IN ('clarify', 'awaiting_approval', 'queued', 'running', 'review'))
     ORDER BY number DESC LIMIT LEAST(GREATEST(p_limit, 1), 50)) x), '[]'::jsonb);
END $$;

-- The open clarification of this chat (the next message answers it), if any.
CREATE OR REPLACE FUNCTION public.dev_task_open_clarify(p_chat bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN (SELECT to_jsonb(t) FROM public.dev_tasks t WHERE t.chat_id = p_chat AND t.status = 'clarify' AND t.created_at > now() - interval '2 hours'
           ORDER BY t.number DESC LIMIT 1);
END $$;

-- Takes the next queued task when nothing is running (the next one is started only when the last one reported).
CREATE OR REPLACE FUNCTION public.dev_task_claim_next()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.dev_tasks;
BEGIN
  PERFORM private.require_service();
  IF EXISTS (SELECT 1 FROM public.dev_tasks WHERE status = 'running') THEN RETURN NULL; END IF;
  SELECT * INTO t FROM public.dev_tasks WHERE status = 'queued' ORDER BY number LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL THEN RETURN NULL; END IF;
  UPDATE public.dev_tasks SET status = 'running', started_at = now(), last_event_at = now() WHERE id = t.id RETURNING * INTO t;
  INSERT INTO public.dev_task_events (task_id, kind, message) VALUES (t.id, 'started', 'the agent was started');
  RETURN to_jsonb(t);
END $$;

-- A running task that reported nothing for 90 minutes is failed (the Actions job was lost); also tells which ones.
CREATE OR REPLACE FUNCTION public.dev_task_expire_stale()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
BEGIN
  PERFORM private.require_service();
  WITH s AS (UPDATE public.dev_tasks SET status = 'failed', finished_at = now(), last_event_at = now(),
                    summary = COALESCE(summary, 'No news from the agent for 90 minutes: stopped.')
              WHERE status = 'running' AND last_event_at < now() - interval '90 minutes' RETURNING id, number, chat_id, title)
  SELECT COALESCE(jsonb_agg(to_jsonb(s)), '[]'::jsonb) INTO r FROM s;
  INSERT INTO public.dev_task_events (task_id, kind, message) SELECT (x ->> 'id')::uuid, 'stale', 'stopped: no news from the agent for 90 minutes' FROM jsonb_array_elements(r) x;
  RETURN r;
END $$;

-- ------------------------------------------------------------------ memory

CREATE OR REPLACE FUNCTION public.dev_memory_add(p_kind text, p_title text, p_body text, p_pinned boolean DEFAULT false, p_task uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF p_kind NOT IN ('architecture', 'decision', 'bug', 'feature', 'deploy', 'note') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid kind');
  END IF;
  INSERT INTO public.dev_memory (kind, title, body, pinned, task_id) VALUES (p_kind, left(p_title, 200), left(p_body, 6000), p_pinned, p_task)
  ON CONFLICT (kind, title) DO UPDATE SET body = EXCLUDED.body, pinned = public.dev_memory.pinned OR EXCLUDED.pinned, updated_at = now(), task_id = COALESCE(EXCLUDED.task_id, public.dev_memory.task_id);
END $$;

CREATE OR REPLACE FUNCTION public.dev_memory_search(p_query text DEFAULT NULL, p_limit int DEFAULT 8)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (
    SELECT kind, title, left(body, 600) AS body, pinned, updated_at FROM public.dev_memory
     WHERE p_query IS NULL OR title ILIKE '%' || replace(replace(p_query, '%', ''), '_', '') || '%' OR body ILIKE '%' || replace(replace(p_query, '%', ''), '_', '') || '%'
     ORDER BY pinned DESC, updated_at DESC LIMIT LEAST(GREATEST(p_limit, 1), 30)) x), '[]'::jsonb);
END $$;

-- The text given to the coding agent so it does not start from zero: pinned notes first, then the newest, 9,000 characters at most.
CREATE OR REPLACE FUNCTION public.dev_memory_context()
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  v_out text := '';
BEGIN
  PERFORM private.require_service();
  FOR r IN SELECT kind, title, body FROM public.dev_memory ORDER BY pinned DESC, updated_at DESC LIMIT 60 LOOP
    EXIT WHEN length(v_out) > 9000;
    v_out := v_out || '[' || r.kind || '] ' || r.title || E'\n' || left(r.body, 700) || E'\n\n';
  END LOOP;
  RETURN left(v_out, 9000);
END $$;

-- ------------------------------------------------------------------ approvals

CREATE OR REPLACE FUNCTION public.dev_pending_create(p_kind text, p_actor bigint, p_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid;
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.dev_pending WHERE expires_at < now() - interval '1 day';
  INSERT INTO public.dev_pending (kind, actor, payload) VALUES (p_kind, p_actor, COALESCE(p_payload, '{}'::jsonb)) RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- The button was pressed: only by the person it was made for, only once, only before it expires, only an OWNER.
CREATE OR REPLACE FUNCTION public.dev_pending_take(p_id uuid, p_actor bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p public.dev_pending;
BEGIN
  PERFORM private.require_service();
  IF NOT EXISTS (SELECT 1 FROM public.dev_bot_users WHERE telegram_id = p_actor AND role = 'owner' AND revoked_at IS NULL) THEN
    INSERT INTO public.dev_audit (actor, action, target, ok) VALUES (p_actor, 'approval_refused', p_id::text, false);
    RETURN jsonb_build_object('refused', 'not_owner');
  END IF;
  UPDATE public.dev_pending SET used_at = now() WHERE id = p_id AND actor = p_actor AND used_at IS NULL AND expires_at > now() RETURNING * INTO p;
  IF p.id IS NULL THEN
    RETURN jsonb_build_object('refused', 'used_or_expired');
  END IF;
  INSERT INTO public.dev_audit (actor, action, target, detail) VALUES (p_actor, 'approval_' || p.kind, p_id::text, p.payload);
  RETURN jsonb_build_object('kind', p.kind, 'payload', p.payload);
END $$;

-- A backup that was started for a deployment is followed here until it finishes (or 15 minutes pass).
CREATE OR REPLACE FUNCTION public.dev_backup_pending()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', id, 'actor', actor, 'payload', payload))
                     FROM public.dev_pending WHERE kind = 'backup' AND used_at IS NOT NULL AND NOT (payload ? 'done') AND expires_at > now()), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.dev_pending_mark(p_id uuid, p_patch jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.dev_pending SET payload = payload || COALESCE(p_patch, '{}'::jsonb) WHERE id = p_id;
END $$;

-- ------------------------------------------------------------------ what /health, /logs and the tick read

CREATE OR REPLACE FUNCTION public.dev_system_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object(
    'lastScan', (SELECT jsonb_build_object('at', at, 'checks', checks, 'errors', errors) FROM private.health_scans ORDER BY id DESC LIMIT 1),
    'open', COALESCE((SELECT jsonb_agg(jsonb_build_object('key', key, 'severity', severity, 'title', title, 'since', first_seen, 'repairs', repairs,
                                                         'financial', financial_impact, 'developer', needs_developer) ORDER BY (severity = 'critical') DESC, first_seen)
                        FROM private.health_incidents WHERE status = 'open' AND severity <> 'info'), '[]'::jsonb),
    'database', jsonb_build_object('connections', (SELECT count(*) FROM pg_stat_activity), 'max', current_setting('max_connections')::int,
                                   'size', pg_size_pretty(pg_database_size(current_database()))),
    'running', (SELECT count(*) FROM public.dev_tasks WHERE status = 'running'),
    'queued', (SELECT count(*) FROM public.dev_tasks WHERE status = 'queued'));
END $$;

CREATE OR REPLACE FUNCTION public.dev_logs(p_limit int DEFAULT 15)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object(
    'events', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT e.at, t.number AS task, e.kind, left(e.message, 160) AS message
                                                             FROM public.dev_task_events e JOIN public.dev_tasks t ON t.id = e.task_id
                                                            ORDER BY e.id DESC LIMIT LEAST(GREATEST(p_limit, 1), 30)) x), '[]'::jsonb),
    'audit', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT at, action, ok, left(COALESCE(target, ''), 60) AS target FROM public.dev_audit ORDER BY id DESC LIMIT 10) x), '[]'::jsonb),
    'incidents', COALESCE((SELECT jsonb_agg(to_jsonb(x)) FROM (SELECT last_seen, severity, key, left(title, 80) AS title, status FROM private.health_incidents ORDER BY id DESC LIMIT 8) x), '[]'::jsonb));
END $$;

-- Does the database's timer need to wake the bot (a task running or waiting, or an approval waiting for its backup)?
CREATE OR REPLACE FUNCTION public.dev_tick_needed()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN EXISTS (SELECT 1 FROM public.dev_tasks WHERE status IN ('queued', 'running', 'review') AND NOT (status = 'review' AND ci_reported))
      OR EXISTS (SELECT 1 FROM public.dev_pending WHERE kind = 'backup' AND used_at IS NOT NULL AND NOT (payload ? 'done') AND expires_at > now());
END $$;

CREATE OR REPLACE FUNCTION private.devbot_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN RETURN; END IF;
  IF NOT (EXISTS (SELECT 1 FROM public.dev_tasks WHERE status IN ('queued', 'running', 'review') AND NOT (status = 'review' AND ci_reported))
          OR EXISTS (SELECT 1 FROM public.dev_pending WHERE kind = 'backup' AND used_at IS NOT NULL AND expires_at > now()
                      AND NOT (payload ? 'done') AND expires_at > now())) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 50000)'
  USING rtrim(v_url, '/') || '/dev-bot/tick', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'devbot_kick: %', SQLERRM;
END $$;

-- ------------------------------------------------------------------ memory the developer starts with

INSERT INTO public.dev_memory (kind, title, body, pinned) VALUES
 ('architecture', 'Platform', 'Production is Supabase (Postgres + Auth + Edge Functions + pg_cron + Realtime). Apps: customer-app and agent-app (Flutter). Backend logic is in Postgres functions (supabase/migrations) and Edge Functions (supabase/functions). There is no application server of our own: the old server 203.161.38.33 is shared with other apps and unused. Read docs/AI_DEVELOPER_CONTEXT.md first.', true),
 ('decision', 'Money rules', 'Never change a balance, ledger entry or order by hand or by a migration. Deposits are credited once (SMS 898 / Sahal feed are paired). Pending stays pending until the payment is verified. Migrations are append-only and idempotent; every SECURITY DEFINER function sets search_path and is revoked from anon.', true),
 ('decision', 'Delivery rules', 'The coding agent only opens pull requests; it never merges, deploys or touches production. Deploy only after Backend and Customer CI are green and the owner approves. Agent App has 2 known failing e2e tests (payments_e2e_test.dart): baseline.', true)
ON CONFLICT (kind, title) DO NOTHING;

-- ------------------------------------------------------------------ privileges

REVOKE ALL ON FUNCTION public.dev_auth(bigint), public.dev_claim_owner(bigint, text), public.dev_user_set(bigint, bigint, text, boolean),
  public.dev_audit_add(bigint, text, text, boolean, jsonb), public.dev_task_create(bigint, bigint, text, text, text, text),
  public.dev_task_refine(uuid, text, text, text, text), public.dev_task_event(uuid, text, text, jsonb), public.dev_task_set(uuid, text, jsonb),
  public.dev_task_get(text), public.dev_task_list(int, boolean), public.dev_task_open_clarify(bigint), public.dev_task_claim_next(),
  public.dev_task_expire_stale(), public.dev_memory_add(text, text, text, boolean, uuid), public.dev_memory_search(text, int), public.dev_memory_context(),
  public.dev_pending_create(text, bigint, jsonb), public.dev_pending_take(uuid, bigint), public.dev_system_summary(), public.dev_logs(int),
  public.dev_tick_needed(), public.dev_backup_pending(), public.dev_pending_mark(uuid, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.dev_auth(bigint), public.dev_claim_owner(bigint, text), public.dev_user_set(bigint, bigint, text, boolean),
  public.dev_audit_add(bigint, text, text, boolean, jsonb), public.dev_task_create(bigint, bigint, text, text, text, text),
  public.dev_task_refine(uuid, text, text, text, text), public.dev_task_event(uuid, text, text, jsonb), public.dev_task_set(uuid, text, jsonb),
  public.dev_task_get(text), public.dev_task_list(int, boolean), public.dev_task_open_clarify(bigint), public.dev_task_claim_next(),
  public.dev_task_expire_stale(), public.dev_memory_add(text, text, text, boolean, uuid), public.dev_memory_search(text, int), public.dev_memory_context(),
  public.dev_pending_create(text, bigint, jsonb), public.dev_pending_take(uuid, bigint), public.dev_system_summary(), public.dev_logs(int),
  public.dev_tick_needed(), public.dev_backup_pending(), public.dev_pending_mark(uuid, jsonb) TO service_role;
REVOKE ALL ON FUNCTION private.devbot_kick() FROM PUBLIC, anon, authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-devbot';
    PERFORM cron.schedule('baari-devbot', '* * * * *', 'SELECT private.devbot_kick()');
  END IF;
END
$do$;
