-- The automatic Sahal reconnect asked for "a phone reading SMS in the last 3 minutes". That heartbeat only runs
-- while the Agent App is open, so with the app closed (when Sahal's session ends by itself) it never signed in
-- again and the feed stayed blind. The Agent App now reads the access code in the background too, so a phone
-- that was seen reading SMS in the last 24 hours counts: it is installed, signed in and allowed to read SMS.
-- (The Dashboard card keeps the strict 3 minutes: it says what is provably reading right now.)

CREATE OR REPLACE FUNCTION private.agent_phone_alive()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.agent_devices d WHERE d.status = 'active' AND d.sms_listening_at > now() - interval '24 hours')
$$;

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
  IF NOT private.agent_phone_alive() THEN RETURN 'no_phone_reading_sms'; END IF;
  SELECT max(at), count(*) FILTER (WHERE at > now() - interval '1 hour'), count(*) FILTER (WHERE at > now() - interval '1 day')
    INTO v_last, v_hour, v_day
  FROM private.merchant_feed_events WHERE provider = p_provider AND event = 'auto_reconnect';
  IF v_last > now() - interval '5 minutes' THEN RETURN 'too_soon'; END IF;
  IF v_hour >= 4 THEN RETURN 'hourly_limit'; END IF;
  IF v_day >= 12 THEN RETURN 'daily_limit'; END IF;
  RETURN NULL;
END $$;

REVOKE ALL ON FUNCTION private.agent_phone_alive(), private.merchant_feed_recover_block(text) FROM PUBLIC, anon, authenticated;
