-- The phone check now passes for the reinstalled agent phone, but a real
-- $1 EVC payment from 0610...  was still ambiguous: six pending deposits of
-- different customers fit it. Before deposits were limited to the login
-- number, other accounts could place deposits naming this number too.
--
-- A number belongs to the customer registered with it, so when deposits of
-- several customers fit, that customer's deposits take the payment (the
-- oldest first). If the paying number is no customer's login number, or two
-- customers share it, it still goes to a manager.

-- Tries to match one stored SMS to a pending wallet deposit. When deposits
-- of several customers fit, the customer registered with the paying number
-- takes it; otherwise it goes to a manager. With several deposits of one
-- customer for the same amount, the oldest one is paid.
CREATE OR REPLACE FUNCTION private.match_sms_log(p_sms_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sms_logs;
  v_method public.order_method;
  v_key text;
  v_cents bigint;
  v_dep uuid[];
  v_customers int;
  v_owner uuid[];
  v_owner_customers int;
  v_reason text;
  v_ref text;
  d public.orders;
BEGIN
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id FOR UPDATE;
  IF s.id IS NULL OR s.match_status <> 'unmatched' THEN
    RETURN jsonb_build_object('status', COALESCE(s.match_status, 'missing'), 'orderId', s.matched_order_id);
  END IF;

  v_method := private.provider_method(s.parsed_provider);
  v_key := private.phone_key(s.parsed_phone);
  IF s.parsed_amount IS NULL OR v_key IS NULL OR v_method IS NULL THEN
    UPDATE public.sms_logs SET match_status = 'ignored',
      match_failure_reason = 'SMS did not parse a usable provider, amount and sender phone number'
    WHERE id = s.id;
    RETURN jsonb_build_object('status', 'ignored');
  END IF;
  IF s.received_at < now() - interval '24 hours' THEN
    UPDATE public.sms_logs SET match_failure_reason = 'Received more than 24h ago: outside the matching window' WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', 'outside the matching window');
  END IF;
  v_reason := private.sms_device_reason(s, v_method);
  IF v_reason IS NOT NULL THEN
    UPDATE public.sms_logs SET match_failure_reason = 'Rejected by the wallet phone/SIM check: ' || v_reason WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', v_reason);
  END IF;
  v_cents := round(s.parsed_amount * 100);

  -- Locked, so two SMS can't both take the same order.
  SELECT COALESCE(array_agg(id ORDER BY created_at), '{}'), count(DISTINCT customer_id) INTO v_dep, v_customers FROM (
    SELECT o2.id, o2.created_at, o2.customer_id FROM public.orders o2
    WHERE o2.direction = 'deposit' AND o2.status = 'pending' AND o2.method = v_method
      AND o2.amount_cents = v_cents AND private.phone_key(o2.phone_number) = v_key
      AND o2.updated_at > now() - interval '24 hours'
    FOR UPDATE
  ) x;

  IF COALESCE(array_length(v_dep, 1), 0) = 0 THEN
    v_reason := format('No pending deposit for $%s from ...%s on %s in the last 24h', s.parsed_amount, v_key, v_method);
    UPDATE public.sms_logs SET match_failure_reason = v_reason WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', v_reason);
  END IF;

  -- Deposits of several customers (some placed from a number that was not
  -- their own, before deposits were limited to the login number): the
  -- customer whose login number paid takes the payment.
  IF array_length(v_dep, 1) > 1 AND v_customers > 1 THEN
    SELECT COALESCE(array_agg(o.id ORDER BY o.created_at), '{}'), count(DISTINCT o.customer_id) INTO v_owner, v_owner_customers
    FROM public.orders o JOIN public.users u ON u.id = o.customer_id
    WHERE o.id = ANY(v_dep) AND private.phone_key(u.phone) = v_key;
    IF v_owner_customers = 1 THEN
      v_dep := v_owner;
      v_customers := 1;
    END IF;
  END IF;

  -- Several deposits of one customer (a retry after paying once): the same
  -- wallet is credited whichever is paid, so the oldest is. Deposits of
  -- different customers stay for a manager.
  IF array_length(v_dep, 1) > 1 AND v_customers > 1 THEN
    v_reason := format('Ambiguous: %s deposits of different customers fit this payment (%s) -- needs a manager',
      array_length(v_dep, 1), array_to_string(v_dep, ', '));
    UPDATE public.sms_logs SET match_status = 'ambiguous', match_failure_reason = v_reason WHERE id = s.id;
    PERFORM private.audit(NULL, NULL, 'payment_sms_ambiguous', 'sms_log', s.id::text, NULL,
      jsonb_build_object('candidates', to_jsonb(v_dep), 'amount', s.parsed_amount, 'phone', v_key));
    RETURN jsonb_build_object('status', 'ambiguous', 'reason', v_reason);
  END IF;

  v_ref := COALESCE(s.transaction_ref, 'SMS-' || s.id::text);
  d := private.complete_deposit_order(v_dep[1], v_ref, s.agent_id, 'agent');
  UPDATE public.sms_logs SET match_status = 'matched', matched_order_id = d.id, match_failure_reason = NULL WHERE id = s.id;
  INSERT INTO public.sms_transactions (agent_id, device_id, provider, sender, amount_cents, transaction_ref, occurred_at, matched_order_id, match_status)
  VALUES (s.agent_id, s.device_id, v_method::text, s.parsed_phone, v_cents, v_ref, s.received_at, d.id, 'matched')
  ON CONFLICT (provider, transaction_ref) DO NOTHING;
  PERFORM private.order_audit(d.id, 'deposit_verified_by_sms', jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', d.status, 'smsLogId', s.id, 'customerPhone', d.phone_number, 'provider', s.parsed_provider,
      'amount', s.parsed_amount, 'smsReceivedAt', s.received_at, 'transactionRef', s.transaction_ref, 'verifiedAt', now()),
    s.agent_id);
  RETURN jsonb_build_object('status', 'matched', 'orderId', d.id);
END
$$;

-- Payments of the last 24 hours marked ambiguous are matched again now.
UPDATE public.sms_logs
SET match_status = 'unmatched',
    match_failure_reason = 'Re-checked: the customer registered with the paying number takes it'
WHERE match_status = 'ambiguous' AND matched_order_id IS NULL
  AND received_at > now() - interval '24 hours';

SELECT private.resweep_unmatched_sms();
