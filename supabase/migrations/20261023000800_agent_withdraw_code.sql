-- EVC's *736 code carries a number of its own, separate from the wallet PIN
-- that EVC asks for afterwards ("Fadlan Geli PIN-kaaga"):
--   *736*610346060*01*<code>#   then the PIN in the prompt.
-- The code is stored encrypted like the PIN; the dialed string keeps a
-- {CODE} placeholder that the agent phone fills in, so neither is stored in
-- payout_dial_attempts. EVC payouts need the code set before they dial.
ALTER TABLE public.payout_wallets ADD COLUMN IF NOT EXISTS ussd_code_secret_id UUID;

CREATE OR REPLACE FUNCTION private.payout_ussd_code(p_method public.order_method)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = (private.payout_wallet(p_method)).ussd_code_secret_id
$$;

CREATE OR REPLACE FUNCTION private.payout_ussd(p_method public.order_method, p_phone text, p_amount numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_method
    WHEN 'evc_plus' THEN '*736*' || private.agent_withdraw_phone(p_phone) || '*' || private.agent_withdraw_amount(p_amount) || '*{CODE}#'
    ELSE '*' || private.payout_dial_prefix(p_method) || '*' || private.phone_key(p_phone) || '*' || private.ussd_amount(p_amount) || '#'
  END
$$;

CREATE OR REPLACE FUNCTION public.manage_set_payout_wallet_ussd_code(p_id uuid, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  w public.payout_wallets;
BEGIN
  IF p_code IS NULL OR p_code !~ '^\d{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The *736 code must be 4 to 8 digits');
  END IF;
  SELECT * INTO w FROM public.payout_wallets WHERE id = p_id FOR UPDATE;
  IF w.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet not found');
  END IF;
  UPDATE public.payout_wallets
  SET ussd_code_secret_id = private.store_secret(w.ussd_code_secret_id, p_code, 'payout_wallet:' || w.id || ':ussd_code'), updated_at = now()
  WHERE id = w.id;
  PERFORM private.audit(v_id, private.app_role(), 'payout_wallet.set_ussd_code', 'payout_wallet', w.id::text);
  RETURN jsonb_build_object('id', w.id, 'hasCode', true);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_payout_wallets()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', w.id, 'method', w.method, 'phoneNumber', w.phone_number,
      'deviceId', w.device_id, 'simSlot', w.sim_slot, 'hasPin', w.pin_secret_id IS NOT NULL,
      'hasCode', w.ussd_code_secret_id IS NOT NULL,
      'paysWithdrawals', w.id = (private.payout_wallet(w.method)).id) ORDER BY w.created_at)
    FROM public.payout_wallets w), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_delete_payout_wallet(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  w public.payout_wallets;
BEGIN
  DELETE FROM public.payout_wallets WHERE id = p_id RETURNING * INTO w;
  IF w.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet not found');
  END IF;
  DELETE FROM vault.secrets WHERE id IN (w.pin_secret_id, w.ussd_code_secret_id);
  PERFORM private.audit(v_id, private.app_role(), 'payout_wallet.delete', 'payout_wallet', w.id::text);
END
$$;

-- Starts (or returns the unfinished) payout attempt. The PIN and the *736
-- code are returned ONLY for a new attempt.
CREATE OR REPLACE FUNCTION public.agent_payout_start_dial(p_order_id uuid, p_device_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  o public.orders := private.lock_order(p_order_id);
  w public.payout_wallets;
  v_latest public.payout_dial_attempts;
  v_block jsonb;
  v_ussd text;
  v_id uuid;
  v_next int;
BEGIN
  IF o.direction <> 'withdraw' THEN
    PERFORM private.raise_api(400, 'BAD_REQUEST', 'Not a withdrawal order');
  END IF;
  IF EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id AND status = 'success') THEN
    PERFORM private.raise_api(409, 'ALREADY_PAID', 'This payout already succeeded');
  END IF;
  IF o.status NOT IN ('pending', 'processing') THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Order is already ' || o.status);
  END IF;
  IF o.payout_review THEN
    PERFORM private.raise_api(409, 'NEEDS_REVIEW', 'The last payout attempt needs a manager''s review first');
  END IF;
  w := private.payout_wallet(o.method);
  IF w.id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_CONFIGURED', 'No payout wallet with a PIN is set up for this method');
  END IF;
  IF w.device_id IS DISTINCT FROM p_device_id THEN
    PERFORM private.raise_api(409, 'WRONG_DEVICE', 'This payout must be sent from the payout wallet''s own phone');
  END IF;
  IF o.method = 'evc_plus' AND w.ussd_code_secret_id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_CONFIGURED', 'Set the *736 code of the EVC Plus payout wallet first');
  END IF;

  SELECT * INTO v_latest FROM public.payout_dial_attempts WHERE order_id = o.id ORDER BY attempt_number DESC LIMIT 1;
  IF v_latest.id IS NOT NULL AND v_latest.status IN ('pending', 'step1_success') THEN
    RETURN jsonb_build_object('id', v_latest.id, 'step1UssdString', v_latest.step1_ussd_string,
      'simSlot', v_latest.sim_slot, 'isNew', false);
  END IF;
  IF v_latest.id IS NOT NULL AND (o.payout_requested_at IS NULL OR v_latest.created_at >= o.payout_requested_at) THEN
    PERFORM private.raise_api(409, 'ALREADY_DIALED', 'This payout was already attempted; a manager must retry it');
  END IF;
  -- Serialise new payouts of a method, so two phones / passes can't both
  -- fit under the daily limit or minimum balance at the same moment.
  PERFORM 1 FROM public.payout_auto_settings WHERE method = o.method FOR UPDATE;
  v_block := private.payout_block(o);
  IF v_block IS NOT NULL THEN
    PERFORM private.raise_api(409, v_block ->> 'code', v_block ->> 'message');
  END IF;

  IF o.status = 'pending' THEN
    o := private.start_processing_withdraw(o.id, v_agent, 'agent');
  END IF;
  v_ussd := private.payout_ussd(o.method, o.phone_number, o.net_cents / 100.0);
  v_next := COALESCE(v_latest.attempt_number, 0) + 1;
  INSERT INTO public.payout_dial_attempts (order_id, agent_id, device_id, sim_slot, wallet_phone, attempt_number, step1_ussd_string)
  VALUES (o.id, v_agent, p_device_id, w.sim_slot, w.phone_number, v_next, v_ussd)
  RETURNING id INTO v_id;
  PERFORM private.order_audit(o.id, 'withdrawal_payout_dial_started', NULL,
    jsonb_build_object('attempt', v_next, 'payoutProvider', o.method, 'payoutAmount', private.money(o.net_cents),
      'payoutDestination', o.phone_number, 'payoutWallet', w.phone_number, 'deviceId', p_device_id, 'simSlot', w.sim_slot,
      'mode', (SELECT mode FROM public.payout_auto_settings WHERE method = o.method)), v_agent);
  RETURN jsonb_build_object('id', v_id, 'step1UssdString', v_ussd, 'simSlot', w.sim_slot, 'isNew', true,
    'pin', private.payout_pin(o.method), 'code', private.payout_ussd_code(o.method));
END
$$;

REVOKE ALL ON FUNCTION private.payout_ussd_code(public.order_method) FROM PUBLIC, anon, authenticated;
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      AND p.proname IN ('agent_payout_start_dial', 'manage_set_payout_wallet_ussd_code', 'manage_payout_wallets', 'manage_delete_payout_wallet')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END
$$;
