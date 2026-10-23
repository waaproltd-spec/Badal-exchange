-- EVC payouts are sent with the agent withdraw code, PIN included:
--   EVC Plus  *736*610625955*1*{PIN}#
--   Golis     *736*0905999914*1*{PIN}#
--   Zaad      *736*0638882065*1*{PIN}#
-- EVC still answers with "Fadlan Geli PIN-kaaga", which the phone fills in
-- as before. {PIN} is a placeholder the agent phone swaps for the PIN right
-- before dialing, so the PIN is never stored in payout_dial_attempts.
-- eDahab keeps *110*number*amount#.

-- The receiver as *736 wants it: Hormuud numbers as is (610625955), other
-- networks' numbers (Zaad 63, Golis 90) with their leading 0.
CREATE OR REPLACE FUNCTION private.agent_withdraw_phone(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN left(private.phone_key(p_phone), 2) IN ('63', '90') THEN '0' ELSE '' END
         || private.phone_key(p_phone)
$$;

CREATE OR REPLACE FUNCTION private.payout_ussd(p_method public.order_method, p_phone text, p_amount numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_method
    WHEN 'evc_plus' THEN '*736*' || private.agent_withdraw_phone(p_phone) || '*' || private.ussd_amount(p_amount) || '*{PIN}#'
    ELSE '*' || private.payout_dial_prefix(p_method) || '*' || private.phone_key(p_phone) || '*' || private.ussd_amount(p_amount) || '#'
  END
$$;

-- Starts (or returns the unfinished) payout attempt. The PIN is returned
-- ONLY for a new attempt, so it is never issued twice for one try.
CREATE OR REPLACE FUNCTION public.agent_payout_start_dial(p_order_id uuid, p_device_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  o public.orders := private.lock_order(p_order_id);
  w public.payout_wallets;
  v_latest public.payout_dial_attempts;
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

  SELECT * INTO v_latest FROM public.payout_dial_attempts WHERE order_id = o.id ORDER BY attempt_number DESC LIMIT 1;
  IF v_latest.id IS NOT NULL AND v_latest.status IN ('pending', 'step1_success') THEN
    RETURN jsonb_build_object('id', v_latest.id, 'step1UssdString', v_latest.step1_ussd_string,
      'simSlot', v_latest.sim_slot, 'isNew', false);
  END IF;
  -- Already dialed and not asked to try again: never dial on its own again.
  IF v_latest.id IS NOT NULL AND (o.payout_requested_at IS NULL OR v_latest.created_at >= o.payout_requested_at) THEN
    PERFORM private.raise_api(409, 'ALREADY_DIALED', 'This payout was already attempted; a manager must retry it');
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
      'payoutDestination', o.phone_number, 'payoutWallet', w.phone_number, 'deviceId', p_device_id, 'simSlot', w.sim_slot), v_agent);
  RETURN jsonb_build_object('id', v_id, 'step1UssdString', v_ussd, 'simSlot', w.sim_slot, 'isNew', true,
    'pin', private.payout_pin(o.method));
END
$$;
