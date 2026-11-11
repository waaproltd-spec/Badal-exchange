-- Sahal's SMS access code, read from the merchant phone's SMS (by the Agent
-- App on that phone, or by an SMS-forwarding app that posts it to the
-- sahal-sms-hook function with a token a manager creates).
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
--   * only an SMS that says it is Sahal's ("SAHAL SERVICES", "access code")
--     from an authorized sender: app_settings sahal_sms_senders, comma
--     separated, set to 898 (empty: any sender);
--   * the code is the number after "code", or the only 4-8 digit number;
--     two different numbers and no "code" is refused, not guessed;
--   * once: the code is cleared as the worker takes it, and a second SMS
--     finds the feed no longer waiting.
-- A refused SMS changes nothing: the manual code entry stays available.
-- The code is never written to the audit log, the status or any message.
--   * app_settings sahal_auto_code = 'off' turns the automatic entry off.

INSERT INTO public.app_settings (key, value) VALUES ('sahal_auto_code', 'on') ON CONFLICT (key) DO NOTHING;
-- Sahal's access-code SMS comes from 898: "-SAHAL SERVICES- Access code is 123456 DIGNIIN FADLAN QOFNA HALA WADAAGIN NUMBERADAN".
INSERT INTO public.app_settings (key, value) VALUES ('sahal_sms_senders', '898') ON CONFLICT (key) DO NOTHING;

-- The rules, shared by both ways in. p_actor is whoever the SMS came through
-- (the agent signed in on the phone, or the manager who made the hook's
-- token); only the audit log sees it.
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
  IF btrim(v_senders) <> ''
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

-- The Agent App on the merchant phone.
CREATE OR REPLACE FUNCTION public.agent_sahal_sms_code(
  p_sender text, p_body text, p_received_at text DEFAULT NULL, p_device_id text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
BEGIN
  RETURN private.sahal_sms_enter(v_agent, p_sender, p_body,
    CASE WHEN p_received_at IS NULL THEN now() ELSE private.parse_ts(p_received_at, 'receivedAt') END, 'agent_app', p_device_id);
END $$;

REVOKE ALL ON FUNCTION public.agent_sahal_sms_code(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_sahal_sms_code(text, text, text, text) TO authenticated, service_role;

-- ---- An SMS-forwarding app on the merchant phone ----
-- The phone may not run the Agent App: an app such as "SMS Forwarder" posts
-- the SMS to the sahal-sms-hook function, with a token a manager creates
-- here. Only the token's SHA-256 is stored, the token is shown once when
-- made, a new one replaces (revokes) the old, and the function answers a
-- wrong token with nothing but "forbidden". Same rules as above.
CREATE TABLE IF NOT EXISTS private.sahal_sms_hooks (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text NOT NULL UNIQUE,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_used_at timestamptz,
  revoked_at timestamptz
);

CREATE OR REPLACE FUNCTION public.manage_sahal_sms_hook_rotate()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_token text := 'shk_' || encode(extensions.gen_random_bytes(24), 'hex');
BEGIN
  UPDATE private.sahal_sms_hooks SET revoked_at = now() WHERE revoked_at IS NULL;
  INSERT INTO private.sahal_sms_hooks (token_hash, created_by)
  VALUES (encode(extensions.digest(v_token, 'sha256'), 'hex'), v_id);
  PERFORM private.audit(v_id, private.app_role(), 'sahal_sms_hook.rotate', 'merchant_feed', 'golis', NULL, NULL);
  RETURN jsonb_build_object('token', v_token);
END $$;

CREATE OR REPLACE FUNCTION public.manage_sahal_sms_hook_revoke()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  UPDATE private.sahal_sms_hooks SET revoked_at = now() WHERE revoked_at IS NULL;
  PERFORM private.audit(v_id, private.app_role(), 'sahal_sms_hook.revoke', 'merchant_feed', 'golis', NULL, NULL);
  RETURN public.manage_sahal_sms_hook_status();
END $$;

CREATE OR REPLACE FUNCTION public.manage_sahal_sms_hook_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  h private.sahal_sms_hooks;
BEGIN
  SELECT * INTO h FROM private.sahal_sms_hooks WHERE revoked_at IS NULL ORDER BY created_at DESC LIMIT 1;
  RETURN jsonb_build_object('configured', h.id IS NOT NULL, 'createdAt', h.created_at, 'lastUsedAt', h.last_used_at);
END $$;

-- The function (service role only): the token, and the SMS as the forwarder sent it.
CREATE OR REPLACE FUNCTION public.sahal_sms_hook_code(p_token text, p_sender text, p_body text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  h private.sahal_sms_hooks;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO h FROM private.sahal_sms_hooks
  WHERE token_hash = encode(extensions.digest(COALESCE(p_token, ''), 'sha256'), 'hex') AND revoked_at IS NULL;
  IF h.id IS NULL THEN
    RETURN jsonb_build_object('result', 'forbidden');
  END IF;
  UPDATE private.sahal_sms_hooks SET last_used_at = now() WHERE id = h.id;
  RETURN private.sahal_sms_enter(h.created_by, p_sender, p_body, now(), 'forwarder');
END $$;

REVOKE ALL ON FUNCTION public.manage_sahal_sms_hook_rotate(), public.manage_sahal_sms_hook_revoke(), public.manage_sahal_sms_hook_status() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_sms_hook_rotate(), public.manage_sahal_sms_hook_revoke(), public.manage_sahal_sms_hook_status() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sahal_sms_hook_code(text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sahal_sms_hook_code(text, text, text) TO service_role;
