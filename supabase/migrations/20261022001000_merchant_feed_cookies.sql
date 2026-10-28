-- The Sahal portal's cookies, kept like a browser keeps them and sent back
-- with every request (the portal page relies on the browser for this).
ALTER TABLE private.merchant_feed_sessions ADD COLUMN IF NOT EXISTS cookies TEXT;

CREATE OR REPLACE FUNCTION public.merchant_feed_get(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object(
    'state', (SELECT state FROM public.merchant_feed_status WHERE provider = p_provider),
    'sessionId', (SELECT session_id FROM private.merchant_feed_sessions WHERE provider = p_provider),
    'cookies', (SELECT cookies FROM private.merchant_feed_sessions WHERE provider = p_provider));
END $$;

CREATE OR REPLACE FUNCTION public.merchant_feed_save_cookies(p_provider text, p_cookies text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO private.merchant_feed_sessions (provider, cookies) VALUES (p_provider, left(p_cookies, 4000))
  ON CONFLICT (provider) DO UPDATE SET cookies = left(EXCLUDED.cookies, 4000), updated_at = now();
END $$;

REVOKE ALL ON FUNCTION public.merchant_feed_save_cookies(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.merchant_feed_save_cookies(text, text) TO service_role;
