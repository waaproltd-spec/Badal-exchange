-- One Sahal sign-in at a time. Before, "Sign in to Sahal" woke the worker
-- and the minute job could wake it again while that sign-in was still
-- running: each run signed in, and Sahal texted a new code each time, so
-- only the last of several codes worked. Now a run must claim the sign-in
-- (state 'signing_in') or the entered code before using it; any other run
-- does nothing. A claim older than 2 minutes (a run that died) can be
-- taken over.

ALTER TABLE public.merchant_feed_status DROP CONSTRAINT IF EXISTS merchant_feed_status_state_check;
ALTER TABLE public.merchant_feed_status ADD CONSTRAINT merchant_feed_status_state_check
  CHECK (state IN ('ready', 'ok', 'stopped', 'not_configured', 'needs_code', 'code_entered', 'signing_in'));

-- Worker: claim the right to sign in now. true = go ahead.
CREATE OR REPLACE FUNCTION public.merchant_feed_claim_sign_in(p_provider text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.merchant_feed_status SET state = 'signing_in', updated_at = now()
  WHERE provider = p_provider
    AND (state IN ('ready', 'ok') OR (state = 'signing_in' AND updated_at < now() - interval '2 minutes'));
  RETURN FOUND;
END $$;

-- Worker: the manager's code with Sahal's pending session, for exactly one
-- run (the state moves on to 'signing_in'); NULLs for any other run.
CREATE OR REPLACE FUNCTION public.merchant_feed_take_code(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s private.merchant_feed_sessions;
BEGIN
  PERFORM private.require_service();
  UPDATE public.merchant_feed_status SET state = 'signing_in', updated_at = now()
  WHERE provider = p_provider AND state = 'code_entered';
  IF NOT FOUND THEN
    RETURN jsonb_build_object('secondSessionId', NULL, 'code', NULL);
  END IF;
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = p_provider FOR UPDATE;
  UPDATE private.merchant_feed_sessions SET code = NULL WHERE provider = p_provider;
  RETURN jsonb_build_object('secondSessionId', s.second_session_id, 'code', s.code);
END $$;

-- The status shows a sign-in in progress as such.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_status(p_provider text DEFAULT 'golis')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_asked timestamptz := (SELECT second_at FROM private.merchant_feed_sessions WHERE provider = p_provider);
BEGIN
  RETURN (SELECT jsonb_build_object('provider', s.provider,
      'state', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes' THEN 'stopped'
                    WHEN s.state = 'signing_in' THEN 'ready' ELSE s.state END,
      'resultCode', s.result_code,
      'message', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes'
                      THEN 'The access code expired. Sign in again.'
                      WHEN s.state = 'signing_in' THEN 'Signing in…' ELSE s.message END,
      'checkedAt', s.checked_at, 'lastOkAt', s.last_ok_at, 'rowsSeen', s.rows_seen,
      'codeAskedAt', CASE WHEN s.state = 'needs_code' THEN v_asked END)
    FROM public.merchant_feed_status s WHERE s.provider = p_provider);
END $$;

-- Also wakes the worker for a sign-in claim left by a run that died.
CREATE OR REPLACE FUNCTION private.merchant_feed_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM public.merchant_feed_status WHERE provider = 'golis'
                    AND (state IN ('ready', 'ok', 'not_configured', 'code_entered')
                         OR (state = 'signing_in' AND updated_at < now() - interval '2 minutes'))) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/golis-merchant', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'merchant_feed_kick: %', SQLERRM;
END $$;

REVOKE ALL ON FUNCTION public.merchant_feed_claim_sign_in(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_claim_sign_in(text) TO service_role;
