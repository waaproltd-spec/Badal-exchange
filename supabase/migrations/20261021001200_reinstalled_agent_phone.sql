-- The Agent App names its phone with a random id kept in the app's data.
-- Reinstalling the app (the test builds are signed with a new key each time,
-- so a new build is installed by uninstalling the old one) loses that data
-- and the phone comes back with a new id. Wallets & Auto Payout still
-- pointed at the old id, so every payment SMS from the phone was rejected
-- by the phone/SIM check and automatic payouts stopped dialing.
--
-- A phone that comes back with a new id is recognised as the same phone
-- when the same agent registers it with the same model name (e.g. "samsung
-- SM-A155F"): its payout wallets move to the new id, and SMS stored under
-- any of its ids count. A different agent, or a different model, is still
-- another phone.

-- Same physical phone: the same id, or two ids one agent registered with
-- the same (non-generic) model name.
CREATE OR REPLACE FUNCTION private.same_agent_phone(p_a text, p_b text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_a = p_b OR EXISTS (
    SELECT 1 FROM public.agent_devices d1
    JOIN public.agent_devices d2 ON d2.agent_id = d1.agent_id AND d2.device_label = d1.device_label
    WHERE d1.device_id = p_a AND d2.device_id = p_b
      AND NULLIF(btrim(d1.device_label), '') IS NOT NULL AND d1.device_label <> 'Agent device'
  )
$$;

CREATE OR REPLACE FUNCTION private.sms_device_reason(s public.sms_logs, p_method public.order_method)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w record;
  v_any boolean := false;
BEGIN
  FOR w IN SELECT device_id, sim_slot FROM public.payout_wallets WHERE method = p_method AND device_id IS NOT NULL LOOP
    v_any := true;
    IF private.same_agent_phone(w.device_id, s.device_id)
       AND (w.sim_slot IS NULL OR s.sim_slot IS NULL OR w.sim_slot = s.sim_slot) THEN
      RETURN NULL;
    END IF;
  END LOOP;
  IF NOT v_any THEN
    RETURN NULL; -- no phone set yet (Dalab's permissive fallback)
  END IF;
  RETURN format('expects the %s wallet''s phone/SIM, SMS arrived on device %s slot %s',
    p_method, COALESCE(s.device_id, '(unknown)'), COALESCE(s.sim_slot::text, '(unresolved)'));
END
$$;

CREATE OR REPLACE FUNCTION public.agent_register_device(p_device_id text, p_device_label text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_new boolean;
  v_moved int;
BEGIN
  PERFORM private.check_len(p_device_id, 'deviceId', 4, 200);
  PERFORM private.check_len(p_device_label, 'deviceLabel', 0, 100, false);
  v_new := NOT EXISTS (SELECT 1 FROM public.agent_devices WHERE agent_id = v_id AND device_id = p_device_id);
  INSERT INTO public.agent_devices (agent_id, device_id, device_label)
  VALUES (v_id, p_device_id, p_device_label)
  ON CONFLICT (agent_id, device_id) DO UPDATE SET last_seen_at = now(), status = 'active';
  UPDATE public.agent_profiles SET last_device_id = p_device_id, last_seen_at = now() WHERE user_id = v_id;

  -- A reinstalled app on a phone that holds payout wallets: move them.
  IF v_new THEN
    UPDATE public.payout_wallets w SET device_id = p_device_id
    WHERE w.device_id IS DISTINCT FROM p_device_id AND private.same_agent_phone(w.device_id, p_device_id);
    GET DIAGNOSTICS v_moved = ROW_COUNT;
    IF v_moved > 0 THEN
      PERFORM private.audit(v_id, 'agent', 'payout_wallet.device_reinstalled', 'agent_device', p_device_id, NULL,
        jsonb_build_object('wallets', v_moved, 'deviceLabel', p_device_label));
    END IF;
  END IF;
END
$$;

REVOKE ALL ON FUNCTION private.same_agent_phone(text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.sms_device_reason(public.sms_logs, public.order_method) FROM PUBLIC, anon, authenticated;

-- Phones already reinstalled: move each wallet to the newest id of its phone.
UPDATE public.payout_wallets w
SET device_id = (
  SELECT d2.device_id FROM public.agent_devices d1
  JOIN public.agent_devices d2 ON d2.agent_id = d1.agent_id AND d2.device_label = d1.device_label
  WHERE d1.device_id = w.device_id
    AND NULLIF(btrim(d1.device_label), '') IS NOT NULL AND d1.device_label <> 'Agent device'
  ORDER BY d2.registered_at DESC LIMIT 1
)
WHERE w.device_id IS NOT NULL AND EXISTS (
  SELECT 1 FROM public.agent_devices d1
  JOIN public.agent_devices d2 ON d2.agent_id = d1.agent_id AND d2.device_label = d1.device_label
  WHERE d1.device_id = w.device_id AND d2.device_id <> w.device_id AND d2.registered_at > d1.registered_at
    AND NULLIF(btrim(d1.device_label), '') IS NOT NULL AND d1.device_label <> 'Agent device'
);

-- Payment SMS rejected in the last 24 hours are checked again now.
SELECT private.resweep_unmatched_sms();
