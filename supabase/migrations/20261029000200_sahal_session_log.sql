-- Sahal merchant session: what happens to it, written down.
--
-- Diagnosed from production (supabase/diagnostics/payments.sql section 16/17,
-- 2026-10-29): Sahal ends the session about every 55 minutes (code entered
-- 02:08 -> asked again 03:01; entered 03:02 -> asked again 03:58) and texts a
-- new access code each time; the SMS forwarder enters it within seconds.
-- Nothing in this repository says why it is that long, or whether Sahal
-- offers a longer one, so this records every start, end, code and refusal
-- with the session's age (section 18 of the diagnostics). Nothing about
-- payments changes: the log is write-only for the worker.
--
--   * private.merchant_feed_events: the log (no codes, no passwords, no ids).
--   * Sessions get a start time; its start and end are logged by itself.
--   * app_settings 'sahal_renew_idle' ('on' as before): with 'off', the
--     session is renewed only when a withdrawal needs it, not by the
--     idle check every run (fewer SMS codes; the first withdrawal after an
--     expiry then waits for the code, which the forwarder types in seconds).
--   * A second alert when the code is still not entered after 2 minutes.

CREATE TABLE IF NOT EXISTS private.merchant_feed_events (
  id        BIGSERIAL PRIMARY KEY,
  provider  TEXT NOT NULL,
  at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  event     TEXT NOT NULL,
  detail    JSONB NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS merchant_feed_events_at ON private.merchant_feed_events (provider, id DESC);
REVOKE ALL ON private.merchant_feed_events FROM PUBLIC, anon, authenticated;

ALTER TABLE private.merchant_feed_sessions ADD COLUMN IF NOT EXISTS session_started_at TIMESTAMPTZ;

-- A session id that is new starts a session; one that goes away ends it
-- (a sign-in that waits for its code clears it). An upsert with the same id
-- (every read) changes nothing.
CREATE OR REPLACE FUNCTION private.merchant_feed_session_changed()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- An insert that is about to become an update (ON CONFLICT) is not a new session.
    IF NEW.session_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM private.merchant_feed_sessions WHERE provider = NEW.provider) THEN
      NEW.session_started_at := now();
      INSERT INTO private.merchant_feed_events (provider, event) VALUES (NEW.provider, 'session_started');
    END IF;
    RETURN NEW;
  END IF;
  IF NEW.session_id IS NOT NULL AND NEW.session_id IS DISTINCT FROM OLD.session_id THEN
    NEW.session_started_at := now();
    INSERT INTO private.merchant_feed_events (provider, event, detail)
    VALUES (NEW.provider, 'session_started', jsonb_build_object(
      'previousLifetimeSeconds', CASE WHEN OLD.session_id IS NOT NULL AND OLD.session_started_at IS NOT NULL
                                      THEN extract(epoch FROM now() - OLD.session_started_at)::int END));
  ELSIF NEW.session_id IS NULL AND OLD.session_id IS NOT NULL THEN
    INSERT INTO private.merchant_feed_events (provider, event, detail)
    VALUES (NEW.provider, 'session_cleared', jsonb_build_object(
      'lifetimeSeconds', CASE WHEN OLD.session_started_at IS NOT NULL THEN extract(epoch FROM now() - OLD.session_started_at)::int END));
    NEW.session_started_at := NULL;
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.merchant_feed_session_changed() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS merchant_feed_session_changed_ins ON private.merchant_feed_sessions;
DROP TRIGGER IF EXISTS merchant_feed_session_changed_upd ON private.merchant_feed_sessions;
CREATE TRIGGER merchant_feed_session_changed_ins BEFORE INSERT ON private.merchant_feed_sessions
  FOR EACH ROW EXECUTE FUNCTION private.merchant_feed_session_changed();
CREATE TRIGGER merchant_feed_session_changed_upd BEFORE UPDATE ON private.merchant_feed_sessions
  FOR EACH ROW EXECUTE FUNCTION private.merchant_feed_session_changed();

-- Worker: one line in the log. The session's age at that moment is added.
-- It never carries a code, a password or a session id.
CREATE OR REPLACE FUNCTION public.merchant_feed_log(p_provider text, p_event text, p_detail jsonb DEFAULT '{}'::jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_started timestamptz;
BEGIN
  PERFORM private.require_service();
  SELECT session_started_at INTO v_started FROM private.merchant_feed_sessions WHERE provider = p_provider;
  INSERT INTO private.merchant_feed_events (provider, event, detail)
  VALUES (p_provider, left(p_event, 40),
          jsonb_strip_nulls(left(COALESCE(p_detail, '{}'::jsonb)::text, 400)::jsonb
            || jsonb_build_object('sessionAgeSeconds', CASE WHEN v_started IS NOT NULL THEN extract(epoch FROM now() - v_started)::int END)));
  -- A month is plenty.
  IF random() < 0.01 THEN
    DELETE FROM private.merchant_feed_events WHERE at < now() - interval '30 days';
  END IF;
EXCEPTION WHEN invalid_text_representation THEN
  INSERT INTO private.merchant_feed_events (provider, event) VALUES (p_provider, left(p_event, 40));
END $$;

INSERT INTO public.app_settings (key, value) VALUES ('sahal_renew_idle', 'on') ON CONFLICT (key) DO NOTHING;

-- Worker: how the idle session check is set.
CREATE OR REPLACE FUNCTION public.merchant_feed_options(p_provider text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object('renewIdle',
    COALESCE((SELECT value FROM public.app_settings WHERE key = 'sahal_renew_idle'), 'on') <> 'off');
END $$;

-- A manager: renew the session by itself when idle (on, as before), or only
-- when a withdrawal needs it (off: fewer SMS codes).
CREATE OR REPLACE FUNCTION public.manage_sahal_session_options(p_renew_idle boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  IF p_renew_idle IS NOT NULL THEN
    UPDATE public.app_settings SET value = CASE WHEN p_renew_idle THEN 'on' ELSE 'off' END WHERE key = 'sahal_renew_idle';
    PERFORM private.audit(v_id, private.app_role(), 'sahal_session.options', 'merchant_feed', 'golis', NULL,
                          jsonb_build_object('renewIdle', p_renew_idle));
  END IF;
  RETURN jsonb_build_object('renewIdle',
    COALESCE((SELECT value FROM public.app_settings WHERE key = 'sahal_renew_idle'), 'on') <> 'off');
END $$;

REVOKE ALL ON FUNCTION public.merchant_feed_log(text, text, jsonb), public.merchant_feed_options(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_log(text, text, jsonb), public.merchant_feed_options(text) TO service_role;
REVOKE ALL ON FUNCTION public.manage_sahal_session_options(boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_session_options(boolean) TO authenticated, service_role;

-- The alert chat: the code is still not in after 2 minutes (the forwarder did
-- not enter it), a clearer message than the first one. Same key rules: once
-- per situation.
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
    WHEN f.state = 'needs_code' AND v_asked >= now() - interval '10 minutes' AND v_asked < now() - interval '2 minutes' THEN 'code_overdue'
    WHEN f.state = 'needs_code' AND v_asked >= now() - interval '10 minutes' THEN 'code'
    WHEN f.state IN ('needs_code', 'stopped') THEN 'stopped'
    WHEN f.result_code = 'ER0654' THEN 'refused'
    WHEN f.result_code = 'error' AND f.last_ok_at < now() - interval '3 minutes' THEN 'unreachable'
  END;
  IF v_kind IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('kind', v_kind,
    'key', v_kind || ':' || COALESCE(CASE WHEN v_kind IN ('code', 'code_overdue') THEN v_asked::text END, ''),
    'message', f.message,
    'waitingCount', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.status = 'pending'
                     AND o.method = ANY (s.methods) AND o.created_at > now() - interval '3 days'));
END $$;
REVOKE ALL ON FUNCTION private.sahal_alert() FROM PUBLIC, anon, authenticated;
