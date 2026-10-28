-- Sahal's SMS access code, read from the merchant phone's SMS.
--
-- When Sahal asks for an access code (merchant_feed_wait_code: state
-- 'needs_code') it texts it to the merchant phone. That phone runs the Agent
-- App, which now sends the SMS here, and this function enters the code the
-- same way a manager typing it would (manage_merchant_feed_code): the code
-- is stored, the state becomes 'code_entered', the worker sends it to Sahal
-- once, and after a successful sign-in the payouts Sahal had refused go
-- again through the existing safe retry (sahal_payout_retry_now).
--
-- Nothing is trusted from the phone beyond the SMS itself; the server decides:
--   * only while Sahal is waiting for a code, asked within the last 10
--     minutes, and only for an SMS received after it was asked (no old
--     code is ever used, and no SMS is used when no code was asked for);
--   * only from an authorized sender: one listed in app_settings
--     sahal_sms_senders (comma separated) or, when none is listed, an SMS
--     that says it is from Sahal ("SAHAL SERVICES", or "access code");
--   * the code is the number after "code", or the only 4-8 digit number;
--     two different numbers and no "code" is refused, not guessed;
--   * once: the code is cleared as the worker takes it, and a second SMS
--     finds the feed no longer waiting.
-- A refused SMS changes nothing: the manual code entry stays available.
-- The code is never written to the audit log, the status or any message.
--   * app_settings sahal_auto_code = 'off' turns the automatic entry off.

INSERT INTO public.app_settings (key, value) VALUES ('sahal_auto_code', 'on') ON CONFLICT (key) DO NOTHING;
INSERT INTO public.app_settings (key, value) VALUES ('sahal_sms_senders', '') ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.agent_sahal_sms_code(
  p_sender text, p_body text, p_received_at text DEFAULT NULL, p_device_id text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  v_body text := COALESCE(p_body, '');
  v_sender text := lower(btrim(regexp_replace(COALESCE(p_sender, ''), '^\+', '')));
  v_received timestamptz := CASE WHEN p_received_at IS NULL THEN now() ELSE private.parse_ts(p_received_at, 'receivedAt') END;
  v_senders text := lower(COALESCE((SELECT value FROM public.app_settings WHERE key = 'sahal_sms_senders'), ''));
  v_state text;
  s private.merchant_feed_sessions;
  v_code text;
  v_numbers text[];
BEGIN
  IF length(v_body) > 1000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'body is too long');
  END IF;
  IF COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'sahal_auto_code'), 'on') = 'off' THEN
    RETURN jsonb_build_object('result', 'off');
  END IF;

  -- The sender.
  IF btrim(v_senders) <> '' THEN
    IF NOT (v_sender = ANY (SELECT lower(btrim(x)) FROM unnest(string_to_array(v_senders, ',')) AS x)) THEN
      RETURN jsonb_build_object('result', 'ignored', 'reason', 'sender');
    END IF;
  ELSIF v_body !~* '(sahal|access\s*code)' THEN
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
  IF v_received < s.second_at - interval '30 seconds' OR v_received > now() + interval '2 minutes' THEN
    RETURN jsonb_build_object('result', 'ignored', 'reason', 'old');
  END IF;

  UPDATE private.merchant_feed_sessions SET code = v_code WHERE provider = 'golis';
  UPDATE public.merchant_feed_status
  SET state = 'code_entered', message = 'Access code read from the SMS, checking it…', updated_at = now()
  WHERE provider = 'golis';
  PERFORM private.audit(v_agent, private.app_role(), 'merchant_feed.auto_code', 'merchant_feed', 'golis', NULL,
    jsonb_build_object('device', left(COALESCE(p_device_id, ''), 64), 'sender', left(v_sender, 32)));
  PERFORM private.merchant_feed_kick();
  RETURN jsonb_build_object('result', 'submitted');
END $$;

REVOKE ALL ON FUNCTION public.agent_sahal_sms_code(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_sahal_sms_code(text, text, text, text) TO authenticated, service_role;
