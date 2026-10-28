-- Sahal sign-in with the SMS access code. The portal texts a new code to
-- the merchant phone at every sign-in, so a manager completes it from the
-- Agent App:
--   1. "Sign in to Sahal" (manage_merchant_feed_sign_in): the worker signs
--      in; Sahal answers 1001 and texts the code. The feed waits
--      (needs_code) with Sahal's pending session.
--   2. The manager types the code (manage_merchant_feed_code) within 10
--      minutes; the worker sends it (/api/account/2auth) with that pending
--      session, then keeps the session alive by reading every minute.
-- A wrong or late code stops the feed again; nothing ever asks Sahal for a
-- new code on its own.

ALTER TABLE public.merchant_feed_status DROP CONSTRAINT IF EXISTS merchant_feed_status_state_check;
ALTER TABLE public.merchant_feed_status ADD CONSTRAINT merchant_feed_status_state_check
  CHECK (state IN ('ready', 'ok', 'stopped', 'not_configured', 'needs_code', 'code_entered'));

ALTER TABLE private.merchant_feed_sessions
  ADD COLUMN IF NOT EXISTS second_session_id TEXT,
  ADD COLUMN IF NOT EXISTS second_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS code TEXT;

-- Worker: Sahal asked for the SMS code; keep its pending session.
CREATE OR REPLACE FUNCTION public.merchant_feed_wait_code(p_provider text, p_second_session_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO private.merchant_feed_sessions (provider, session_id, second_session_id, second_at, code)
  VALUES (p_provider, NULL, p_second_session_id, now(), NULL)
  ON CONFLICT (provider) DO UPDATE SET session_id = NULL, second_session_id = EXCLUDED.second_session_id,
    second_at = now(), code = NULL, updated_at = now();
  UPDATE public.merchant_feed_status SET state = 'needs_code', result_code = '1001',
    message = 'Sahal sent an access code to the merchant phone. Enter it in the Agent App within 10 minutes.',
    checked_at = now(), updated_at = now()
  WHERE provider = p_provider;
END $$;

-- Worker: the code the manager entered, with Sahal's pending session (once).
CREATE OR REPLACE FUNCTION public.merchant_feed_take_code(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s private.merchant_feed_sessions;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = p_provider FOR UPDATE;
  UPDATE private.merchant_feed_sessions SET code = NULL WHERE provider = p_provider;
  RETURN jsonb_build_object('secondSessionId', s.second_session_id, 'code', s.code);
END $$;

-- Managers: what the feed is doing (no session or code). A code asked for
-- more than 10 minutes ago shows as stopped: it can no longer be used.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_status(p_provider text DEFAULT 'golis')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_asked timestamptz := (SELECT second_at FROM private.merchant_feed_sessions WHERE provider = p_provider);
BEGIN
  RETURN (SELECT jsonb_build_object('provider', s.provider,
      'state', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes' THEN 'stopped' ELSE s.state END,
      'resultCode', s.result_code,
      'message', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes'
                      THEN 'The access code expired. Sign in again.' ELSE s.message END,
      'checkedAt', s.checked_at, 'lastOkAt', s.last_ok_at, 'rowsSeen', s.rows_seen,
      'codeAskedAt', CASE WHEN s.state = 'needs_code' THEN v_asked END)
    FROM public.merchant_feed_status s WHERE s.provider = p_provider);
END $$;

-- Managers: start a sign-in now (Sahal will text a new code).
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_sign_in(p_provider text DEFAULT 'golis')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  UPDATE public.merchant_feed_status SET state = 'ready', message = 'Signing in…', updated_at = now()
  WHERE provider = p_provider;
  UPDATE private.merchant_feed_sessions SET session_id = NULL, second_session_id = NULL, code = NULL WHERE provider = p_provider;
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.sign_in', 'merchant_feed', p_provider, NULL, NULL);
  PERFORM private.merchant_feed_kick();
  RETURN public.manage_merchant_feed_status(p_provider);
END $$;

-- Managers: the SMS access code, within 10 minutes of Sahal sending it.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_code(p_provider text, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_code text := regexp_replace(COALESCE(p_code, ''), '\s', '', 'g');
  s private.merchant_feed_sessions;
BEGIN
  IF v_code !~ '^[0-9]{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the code from the SMS (numbers only)');
  END IF;
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = p_provider;
  IF (SELECT state FROM public.merchant_feed_status WHERE provider = p_provider) IS DISTINCT FROM 'needs_code'
     OR s.second_session_id IS NULL THEN
    PERFORM private.raise_api(409, 'NO_CODE_ASKED', 'Sahal is not waiting for a code. Tap Sign in to Sahal first.');
  END IF;
  IF s.second_at < now() - interval '10 minutes' THEN
    PERFORM private.raise_api(409, 'CODE_EXPIRED', 'That code has expired. Tap Sign in to Sahal for a new one.');
  END IF;
  UPDATE private.merchant_feed_sessions SET code = v_code WHERE provider = p_provider;
  UPDATE public.merchant_feed_status SET state = 'code_entered', message = 'Checking the code…', updated_at = now()
  WHERE provider = p_provider;
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.code', 'merchant_feed', p_provider, NULL, NULL);
  PERFORM private.merchant_feed_kick();
  RETURN public.manage_merchant_feed_status(p_provider);
END $$;

-- As before; also wakes the worker to send an entered code.
CREATE OR REPLACE FUNCTION private.merchant_feed_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM public.merchant_feed_status WHERE provider = 'golis'
                    AND state IN ('ready', 'ok', 'not_configured', 'code_entered')) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/golis-merchant', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'merchant_feed_kick: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION public.merchant_feed_wait_code(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.merchant_feed_take_code(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_status(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_sign_in(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_code(text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.merchant_feed_kick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_wait_code(text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.merchant_feed_take_code(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_status(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_sign_in(text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_code(text, text) TO authenticated;
