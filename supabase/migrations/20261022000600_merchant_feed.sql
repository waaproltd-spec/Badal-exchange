-- Merchant transaction feed, stage 1: READ ONLY. The golis-merchant Edge
-- Function signs in to the Sahal merchant portal (mymerchant.golis.so) with
-- the merchant's own login (GOLIS_MERCHANT_USERNAME / _PASSWORD secrets),
-- reads its transaction list, and stores each transaction once, as the
-- portal returned it. Nothing is matched or credited here: that is stage 2,
-- once the stored rows show the portal's real format.
--
-- Safety: a sign-in the portal does not accept outright (wrong password, an
-- SMS/second code, a password change) stops the feed; it is not tried
-- again until a manager asks for a retry, so it never floods the merchant
-- phone with codes or locks the account. The portal session is kept and
-- reused while it lasts.

CREATE TABLE IF NOT EXISTS public.merchant_feed_status (
  provider        TEXT PRIMARY KEY,
  state           TEXT NOT NULL DEFAULT 'ready' CHECK (state IN ('ready', 'ok', 'stopped', 'not_configured')),
  result_code     TEXT,
  message         TEXT,
  checked_at      TIMESTAMPTZ,
  last_ok_at      TIMESTAMPTZ,
  rows_seen       INT NOT NULL DEFAULT 0,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.merchant_feed_status ENABLE ROW LEVEL SECURITY;
INSERT INTO public.merchant_feed_status (provider) VALUES ('golis') ON CONFLICT DO NOTHING;

-- The portal session (sensitive): only the service role reads it.
CREATE TABLE IF NOT EXISTS private.merchant_feed_sessions (
  provider    TEXT PRIMARY KEY,
  session_id  TEXT,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Each portal transaction once, keyed by the portal's own transaction id.
CREATE TABLE IF NOT EXISTS public.merchant_transactions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider        TEXT NOT NULL,
  transaction_id  TEXT NOT NULL,
  raw             JSONB NOT NULL,
  first_seen_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (provider, transaction_id)
);
ALTER TABLE public.merchant_transactions ENABLE ROW LEVEL SECURITY;

-- The worker's view: state and the saved session.
CREATE OR REPLACE FUNCTION public.merchant_feed_get(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object(
    'state', (SELECT state FROM public.merchant_feed_status WHERE provider = p_provider),
    'sessionId', (SELECT session_id FROM private.merchant_feed_sessions WHERE provider = p_provider));
END $$;

-- The worker reports a run: the state, the portal's code and message, the
-- session to keep (NULL clears it) and the transactions it read.
CREATE OR REPLACE FUNCTION public.merchant_feed_report(
  p_provider text, p_state text, p_result_code text, p_message text, p_session_id text, p_rows jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
  v_new int := 0;
  v_id text;
BEGIN
  PERFORM private.require_service();
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
    v_id := NULLIF(btrim(r->>'_id'), '');
    CONTINUE WHEN v_id IS NULL;
    INSERT INTO public.merchant_transactions (provider, transaction_id, raw)
    VALUES (p_provider, v_id, r - '_id') ON CONFLICT (provider, transaction_id) DO NOTHING;
    IF FOUND THEN v_new := v_new + 1; END IF;
  END LOOP;
  INSERT INTO private.merchant_feed_sessions (provider, session_id, updated_at) VALUES (p_provider, p_session_id, now())
  ON CONFLICT (provider) DO UPDATE SET session_id = EXCLUDED.session_id, updated_at = now();
  UPDATE public.merchant_feed_status SET state = p_state, result_code = left(p_result_code, 20),
    message = left(p_message, 300), checked_at = now(),
    last_ok_at = CASE WHEN p_state = 'ok' THEN now() ELSE last_ok_at END,
    rows_seen = rows_seen + v_new, updated_at = now()
  WHERE provider = p_provider;
  RETURN jsonb_build_object('new', v_new);
END $$;

-- A manager clears a stop after fixing its cause (password, code, ...).
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_retry(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  UPDATE public.merchant_feed_status SET state = 'ready', updated_at = now() WHERE provider = p_provider;
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.retry', 'merchant_feed', p_provider, NULL, NULL);
  RETURN (SELECT to_jsonb(s) FROM public.merchant_feed_status s WHERE provider = p_provider);
END $$;

-- Every minute while the feed is not stopped.
CREATE OR REPLACE FUNCTION private.merchant_feed_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
     OR NOT EXISTS (SELECT 1 FROM public.merchant_feed_status WHERE provider = 'golis' AND state IN ('ready', 'ok')) THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/golis-merchant', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'merchant_feed_kick: %', SQLERRM;
END $$;

REVOKE ALL ON public.merchant_feed_status, public.merchant_transactions FROM anon, authenticated;
REVOKE ALL ON private.merchant_feed_sessions FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.merchant_feed_get(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.merchant_feed_report(text, text, text, text, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_retry(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION private.merchant_feed_kick() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_get(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.merchant_feed_report(text, text, text, text, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_retry(text) TO authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-golis-merchant';
    PERFORM cron.schedule('baari-golis-merchant', '* * * * *', 'SELECT private.merchant_feed_kick()');
  END IF;
END
$do$;
