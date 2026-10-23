-- A real EVC withdrawal was paid ("[-EVCPLUS-] $1 ayaad uwareejisay ...
-- (610346060)") but stayed in review. After the PIN the Agent App waits up
-- to 25 seconds for the carrier's final screen; the "you transferred" SMS
-- arrived during that wait, while the dial attempt was still open, and was
-- ignored ("ignored_no_dial_attempt": only finished attempts counted). The
-- app then reported "no final confirmation" and the order went to review.
--
-- The SMS now counts as soon as a dial for the order has started (before
-- the SMS arrived): it is the carrier's own proof the money left. The
-- app's later report for that attempt changes nothing (the attempt is
-- already a success). Payout SMS ignored this way in the last 24 hours, for
-- withdrawals still not completed, complete them now.

-- Completes a withdrawal from its payout SMS (the dial attempt it answers
-- becomes the success).
CREATE OR REPLACE FUNCTION private.complete_withdraw_by_payout_sms(
  p_order_id uuid, p_raw_text text, p_provider text, p_reference text, p_agent uuid
)
RETURNS public.orders LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.orders := private.lock_order(p_order_id);
  v_text text := private.scrub_pin(left(p_raw_text, 2000), private.payout_pin(o.method));
BEGIN
  UPDATE public.payout_dial_attempts SET status = 'success', step2_response = COALESCE(v_text, step2_response),
    completed_at = COALESCE(completed_at, now())
  WHERE order_id = o.id AND status <> 'success'
    AND attempt_number = (SELECT max(attempt_number) FROM public.payout_dial_attempts WHERE order_id = o.id);
  o := private.complete_withdraw_order(o.id, COALESCE(p_reference, 'SMS-PAYOUT'), p_agent, 'agent');
  UPDATE public.orders SET payout_review = false, failure_reason = NULL WHERE id = o.id RETURNING * INTO o;
  PERFORM private.order_audit(o.id, 'withdrawal_completed_via_payout_sms', NULL, jsonb_build_object(
    'status', 'completed', 'payoutProvider', COALESCE(p_provider, o.method::text), 'payoutAmount', private.money(o.net_cents),
    'payoutDestination', o.phone_number, 'payoutReference', p_reference, 'confirmationText', v_text), p_agent);
  RETURN o;
END $$;
REVOKE ALL ON FUNCTION private.complete_withdraw_by_payout_sms(uuid, text, text, text, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.agent_payout_confirmation(
  p_receiver_phone text, p_amount text, p_raw_text text DEFAULT NULL, p_provider text DEFAULT NULL,
  p_reference text DEFAULT NULL, p_received_at text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  v_cents bigint := private.to_cents(p_amount);
  v_key text := private.phone_key(p_receiver_phone);
  v_method public.order_method := private.provider_method(p_provider);
  v_received timestamptz := CASE WHEN p_received_at IS NULL THEN NULL ELSE private.parse_ts(p_received_at, 'receivedAt') END;
  o public.orders;
  v_result text;
BEGIN
  IF v_key IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'receiverPhone is not a valid phone number');
  END IF;
  SELECT * INTO o FROM public.orders
  WHERE direction = 'withdraw' AND status = 'processing' AND net_cents = v_cents
    AND private.phone_key(phone_number) = v_key
    AND (v_method IS NULL OR method = v_method)
    AND (v_received IS NULL OR EXISTS (
      SELECT 1 FROM public.payout_dial_attempts a WHERE a.order_id = orders.id AND a.created_at <= v_received + interval '2 minutes'))
  ORDER BY updated_at DESC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF o.id IS NULL THEN
    v_result := 'no_matching_order';
  ELSIF NOT EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id) THEN
    -- Never dialed: a transfer made some other way, not this payout.
    v_result := 'ignored_no_dial_attempt';
    PERFORM private.order_audit(o.id, 'withdrawal_payout_sms_ignored_no_attempt', NULL, jsonb_build_object('text', left(p_raw_text, 500)), v_agent);
  ELSE
    o := private.complete_withdraw_by_payout_sms(o.id, p_raw_text, p_provider, p_reference, v_agent);
    v_result := 'completed';
  END IF;

  INSERT INTO public.payout_confirmations (agent_id, provider, receiver_phone, amount, raw_text, order_id, result)
  VALUES (v_agent, p_provider, p_receiver_phone, v_cents / 100.0, left(p_raw_text, 2000), o.id, v_result);
  RETURN jsonb_build_object('matched', o.id IS NOT NULL, 'orderId', o.id, 'result', v_result);
END
$$;

-- Payout SMS ignored while the dial was still open, last 24 hours.
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN
    SELECT DISTINCT ON (pc.order_id) pc.*
    FROM public.payout_confirmations pc
    JOIN public.orders o ON o.id = pc.order_id
    WHERE pc.result = 'ignored_no_dial_attempt' AND pc.created_at > now() - interval '24 hours'
      AND o.status = 'processing' AND o.direction = 'withdraw'
      AND EXISTS (SELECT 1 FROM public.payout_dial_attempts a WHERE a.order_id = o.id AND a.created_at <= pc.created_at)
    ORDER BY pc.order_id, pc.created_at
  LOOP
    PERFORM private.complete_withdraw_by_payout_sms(c.order_id, c.raw_text, c.provider, NULL, c.agent_id);
    UPDATE public.payout_confirmations SET result = 'completed_on_recheck' WHERE id = c.id;
  END LOOP;
END
$$;
