-- Sahal signs the merchant in again by itself.
--
-- Until now a feed that stopped (a refused sign-in, a code that was not accepted, an access code that
-- was never entered) stayed stopped until a manager pressed Sign in. Now the worker asks this function
-- at the start of every run; when it says yes the feed goes back to "ready" and the normal run signs in
-- (Sahal texts an access code, the Agent App phone enters it by itself).
--
-- Safety, because every sign-in makes Sahal text a code and a wrong password can lock the account:
--   * only when a phone is reading SMS right now (private.agent_sim_up): otherwise nobody could enter the
--     code and the merchant phone would only be flooded;
--   * never after a wrong password or a password change request (4001 / 6054) or when nothing is
--     configured: that needs a person;
--   * a pending access code is given 10 minutes before a new sign-in;
--   * at least 5 minutes between two automatic sign-ins, at most 4 an hour and 12 a day;
--   * every automatic sign-in and every refusal is logged (private.merchant_feed_events, no codes).

-- Why the feed may NOT sign in again by itself right now (NULL: it may).
CREATE OR REPLACE FUNCTION private.merchant_feed_recover_block(p_provider text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f public.merchant_feed_status;
  s private.merchant_feed_sessions;
  v_hour int;
  v_day int;
  v_last timestamptz;
BEGIN
  SELECT * INTO f FROM public.merchant_feed_status WHERE provider = p_provider;
  IF f.provider IS NULL OR f.state NOT IN ('stopped', 'needs_code') THEN RETURN 'running'; END IF;
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = p_provider;
  IF f.state = 'needs_code' AND (s.second_at IS NULL OR s.second_at > now() - interval '10 minutes') THEN
    RETURN 'waiting_for_code';
  END IF;
  IF f.state = 'stopped' AND (COALESCE(f.result_code, '') IN ('4001', '6054') OR f.message ~* 'password|credentials') THEN
    RETURN 'needs_a_person';
  END IF;
  IF NOT private.agent_sim_up() THEN RETURN 'no_phone_reading_sms'; END IF;
  SELECT max(at), count(*) FILTER (WHERE at > now() - interval '1 hour'), count(*) FILTER (WHERE at > now() - interval '1 day')
    INTO v_last, v_hour, v_day
  FROM private.merchant_feed_events WHERE provider = p_provider AND event = 'auto_reconnect';
  IF v_last > now() - interval '5 minutes' THEN RETURN 'too_soon'; END IF;
  IF v_hour >= 4 THEN RETURN 'hourly_limit'; END IF;
  IF v_day >= 12 THEN RETURN 'daily_limit'; END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.merchant_feed_auto_recover(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  f public.merchant_feed_status;
  v_why text;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO f FROM public.merchant_feed_status WHERE provider = p_provider FOR UPDATE;
  v_why := private.merchant_feed_recover_block(p_provider);
  IF v_why = 'running' THEN
    RETURN jsonb_build_object('recover', false, 'why', 'running');
  END IF;
  IF v_why IS NOT NULL THEN
    -- Said once per reason (not every run) so the log stays readable.
    IF v_why <> 'waiting_for_code' AND NOT EXISTS (SELECT 1 FROM private.merchant_feed_events e WHERE e.provider = p_provider
         AND e.event = 'auto_reconnect_held' AND e.at > now() - interval '30 minutes' AND e.detail ->> 'why' = v_why) THEN
      INSERT INTO private.merchant_feed_events (provider, event, detail)
      VALUES (p_provider, 'auto_reconnect_held', jsonb_build_object('why', v_why, 'state', f.state, 'code', f.result_code));
    END IF;
    RETURN jsonb_build_object('recover', false, 'why', v_why);
  END IF;
  UPDATE public.merchant_feed_status SET state = 'ready', message = 'Signing in again by itself…', updated_at = now()
  WHERE provider = p_provider;
  UPDATE private.merchant_feed_sessions
  SET read_session_id = COALESCE(session_id, read_session_id),
      read_cookies = CASE WHEN session_id IS NOT NULL THEN cookies ELSE read_cookies END,
      session_id = NULL, second_session_id = NULL, code = NULL
  WHERE provider = p_provider;
  INSERT INTO private.merchant_feed_events (provider, event, detail)
  VALUES (p_provider, 'auto_reconnect', jsonb_build_object('from', f.state, 'code', f.result_code));
  RETURN jsonb_build_object('recover', true);
END $$;

-- The database's timer wakes the worker for a stopped feed too, when it may sign in again by itself
-- (as before otherwise).
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
                         OR (state IN ('needs_code', 'stopped') AND (
                               EXISTS (SELECT 1 FROM private.merchant_feed_sessions x
                                       WHERE x.provider = 'golis' AND x.read_session_id IS NOT NULL)
                               OR private.merchant_feed_recover_block('golis') IS NULL)))) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/golis-merchant', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'merchant_feed_kick: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION private.merchant_feed_kick(), private.merchant_feed_recover_block(text) FROM PUBLIC, anon, authenticated;

-- What the dashboard and the diagnostics can show about it.
CREATE OR REPLACE FUNCTION public.manage_sahal_connection()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'autoReconnectsToday', (SELECT count(*) FROM private.merchant_feed_events
                             WHERE provider = 'golis' AND event = 'auto_reconnect' AND at > now() - interval '1 day'),
    'lastAutoReconnectAt', (SELECT max(at) FROM private.merchant_feed_events WHERE provider = 'golis' AND event = 'auto_reconnect'),
    'codesEnteredToday', (SELECT count(*) FROM private.merchant_feed_events
                           WHERE provider = 'golis' AND event = 'code_sent' AND at > now() - interval '1 day'),
    'held', (SELECT e.detail ->> 'why' FROM private.merchant_feed_events e
              WHERE e.provider = 'golis' AND e.event = 'auto_reconnect_held' AND e.at > now() - interval '30 minutes'
              ORDER BY e.id DESC LIMIT 1));
END $$;

REVOKE ALL ON FUNCTION public.merchant_feed_auto_recover(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_auto_recover(text) TO service_role;
REVOKE ALL ON FUNCTION public.manage_sahal_connection() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_connection() TO authenticated, service_role;
