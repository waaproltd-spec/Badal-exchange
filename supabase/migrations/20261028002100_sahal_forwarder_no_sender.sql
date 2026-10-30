-- Sahal SMS code via an SMS-forwarding app: a forwarder that cannot tell the
-- sender (its template has no such field) is accepted on Sahal's words and
-- the token alone. The Agent App's own path still needs sender 898, and
-- every other rule is unchanged (waiting for a code, a newer SMS, one clear
-- code, entered once).

CREATE OR REPLACE FUNCTION private.sahal_sms_enter(
  p_actor uuid, p_sender text, p_body text, p_received timestamptz, p_source text, p_device text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_body text := COALESCE(p_body, '');
  v_sender text := lower(btrim(regexp_replace(COALESCE(p_sender, ''), '^\+', '')));
  v_senders text := lower(COALESCE((SELECT value FROM public.app_settings WHERE key = 'sahal_sms_senders'), ''));
  v_state text;
  s private.merchant_feed_sessions;
  v_code text;
  v_numbers text[];
BEGIN
  IF length(v_body) > 1000 THEN
    RETURN jsonb_build_object('result', 'ignored', 'reason', 'too_long');
  END IF;
  IF COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'sahal_auto_code'), 'on') = 'off' THEN
    RETURN jsonb_build_object('result', 'off');
  END IF;

  -- Sahal's SMS: it says so, and when senders are listed (898) it comes from one of them.
  IF v_body !~* '(sahal|access\s*code)' THEN
    RETURN jsonb_build_object('result', 'ignored', 'reason', 'sender');
  END IF;
  -- (A forwarding app that cannot give the sender sends none: the token already
  -- says it is this merchant phone's forwarder, so Sahal's words decide.)
  IF btrim(v_senders) <> '' AND NOT (p_source = 'forwarder' AND v_sender = '')
     AND NOT (v_sender = ANY (SELECT lower(btrim(x)) FROM unnest(string_to_array(v_senders, ',')) AS x)) THEN
    RETURN jsonb_build_object('result', 'ignored', 'reason', 'sender');
  END IF;

  -- The code: after the word "code", else the only 4-8 digit number.
  v_code := substring(v_body from '(?i)code\D{0,25}(\d{4,8})(?!\d)');
  IF v_code IS NULL THEN
    SELECT array_agg(DISTINCT m[1]) INTO v_numbers FROM regexp_matches(v_body, '(?<!\d)(\d{4,8})(?!\d)', 'g') AS m;
    IF COALESCE(array_length(v_numbers, 1), 0) = 1 THEN
      v_code := v_numbers[1];
    ELSE
      RETURN jsonb_build_object('result', 'ignored', 'reason', 'no_code');
    END IF;
  END IF;

  -- Only while Sahal is waiting for it (and one SMS at a time).
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = 'golis' FOR UPDATE;
  SELECT state INTO v_state FROM public.merchant_feed_status WHERE provider = 'golis';
  IF v_state IS DISTINCT FROM 'needs_code' OR s.second_session_id IS NULL THEN
    RETURN jsonb_build_object('result', 'not_waiting');
  END IF;
  IF s.second_at < now() - interval '10 minutes' THEN
    RETURN jsonb_build_object('result', 'expired');
  END IF;
  -- Sent before Sahal was asked (an old code), or from the future.
  IF p_received < s.second_at - interval '30 seconds' OR p_received > now() + interval '2 minutes' THEN
    RETURN jsonb_build_object('result', 'ignored', 'reason', 'old');
  END IF;

  UPDATE private.merchant_feed_sessions SET code = v_code WHERE provider = 'golis';
  UPDATE public.merchant_feed_status
  SET state = 'code_entered', message = 'Access code read from the SMS, checking it…', updated_at = now()
  WHERE provider = 'golis';
  PERFORM private.audit(p_actor, (SELECT role FROM public.users WHERE id = p_actor), 'merchant_feed.auto_code', 'merchant_feed', 'golis', NULL,
    jsonb_build_object('source', p_source, 'device', left(COALESCE(p_device, ''), 64), 'sender', left(v_sender, 32)));
  PERFORM private.merchant_feed_kick();
  RETURN jsonb_build_object('result', 'submitted');
END $$;
