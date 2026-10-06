-- BAARI Exchange: payment-SMS matching and the payout state machine.
--
-- Ported from Dalab Internet admin-backend-ts:
--   smsLogs.routes.ts   ingestPaymentSms, findMatchingExchangeOrder,
--                       resweepUnmatchedSmsLogs, normalizePhone (last 9 digits)
--   exchange.routes.ts  createExchangeOrder, autoAdvanceExchangeOrderToInProgress,
--                       determineExchangeDialAttempt, dial-attempt step1/step2,
--                       completeExchangeOrderByPayoutConfirmation, retry-payout,
--                       reverse
--
-- Matching rules (Dalab's, plus the ones the product added):
--   provider        the SMS's network must be the order's paying method
--   phone           last 9 digits equal (0610346060 = 610346060 = 252610346060)
--   amount          exact (to the cent)
--   time window     order touched in the last 24h; SMS received in the last 24h
--   reference       when the SMS has one it must be unused (unique); not required
--   device/SIM      once Baari's collection wallet has a device/SIM on record the
--                   SMS must arrive there (Dalab's guardrail)
--   ambiguity       more than one possible order -> nothing is matched, the SMS
--                   waits for a manager (Dalab picked the oldest instead)
-- Both event orders match: an SMS that arrives first is kept and matched when
-- the order is created (and by the minute resweep, Dalab's every-15s sweep).

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

-- Dalab normalizePhone(): compare the last 9 digits.
CREATE OR REPLACE FUNCTION private.phone_key(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT NULLIF(right(regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g'), 9), '')
$$;

-- Network named by a parsed SMS -> the payment method it pays with.
CREATE OR REPLACE FUNCTION private.provider_method(p_provider text)
RETURNS public.order_method LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE lower(COALESCE(p_provider, ''))
    WHEN 'hormuud' THEN 'evc_plus'
    WHEN 'somnet' THEN 'evc_plus'
    WHEN 'evc_plus' THEN 'evc_plus'
    WHEN 'hormuud_evc_plus' THEN 'evc_plus'
    WHEN 'somtel' THEN 'edahab'
    WHEN 'edahab' THEN 'edahab'
    WHEN 'somtel_edahab' THEN 'edahab'
  END::public.order_method
$$;

-- Dalab lib/phoneValidation.ts validateMobileNumber(): 9 digits after
-- dropping a 252 country code, no leading 0, and the prefix must belong to
-- the wallet's network. Returns the 9-digit number.
CREATE OR REPLACE FUNCTION private.validate_mobile(p_phone text, p_method public.order_method, p_field text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  d text := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
  prefixes text[];
BEGIN
  IF d LIKE '252%' AND length(d) > 9 THEN
    d := substr(d, 4);
  END IF;
  IF d !~ '^\d{9}$' OR d LIKE '0%' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', format('Invalid %s. Enter exactly 9 digits.', p_field));
  END IF;
  prefixes := CASE p_method WHEN 'evc_plus' THEN ARRAY['61', '77'] WHEN 'edahab' THEN ARRAY['62'] END;
  IF prefixes IS NOT NULL AND NOT (left(d, 2) = ANY (prefixes)) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR',
      format('Invalid %s. %s numbers must start with %s.', p_field,
             CASE p_method WHEN 'evc_plus' THEN 'EVC Plus' ELSE 'eDahab' END, array_to_string(prefixes, ' or ')));
  END IF;
  RETURN d;
END
$$;

CREATE OR REPLACE FUNCTION private.to_amount(p_amount text)
RETURNS numeric LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  RETURN private.to_cents(p_amount) / 100.0;
END
$$;

-- Dalab formatEvcDahabUssdAmount(): "." can't be dialed, so cents go in their
-- own *-segment: 1.98 -> "1*98", 10 -> "10".
CREATE OR REPLACE FUNCTION private.ussd_amount(p_amount numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN round((p_amount - trunc(p_amount)) * 100) = 0 THEN trunc(p_amount)::bigint::text
              ELSE trunc(p_amount)::bigint::text || '*' || lpad(round((p_amount - trunc(p_amount)) * 100)::int::text, 2, '0')
         END
$$;

-- Baari's own wallet for a method: where customers pay in, and (for the
-- opposite corridor) where payouts are dialed from. Oldest first (Dalab
-- loadCollectionPhoneNumber).
CREATE OR REPLACE FUNCTION private.collection_wallet(p_method public.order_method)
RETURNS public.exchange_payout_wallets LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT * FROM public.exchange_payout_wallets WHERE method = p_method ORDER BY created_at ASC LIMIT 1
$$;

CREATE OR REPLACE FUNCTION private.exchange_order_ref()
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v text;
BEGIN
  FOR i IN 1 .. 10 LOOP
    v := 'DEX' || (100000000 + floor(random() * 900000000))::bigint::text;
    IF NOT EXISTS (SELECT 1 FROM public.exchange_orders WHERE id = v) THEN
      RETURN v;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Could not generate a unique exchange order id';
END
$$;

CREATE OR REPLACE FUNCTION private.exchange_status_message(p_status text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_status
    WHEN 'pending' THEN 'Waiting for your payment.'
    WHEN 'in_progress' THEN 'Payment verified. Sending your money.'
    WHEN 'completed' THEN 'Exchange completed. The money was sent.'
    WHEN 'failed' THEN 'Your payment was received but the transfer did not go through yet. Our team will complete or refund it.'
    WHEN 'cancelled' THEN 'Exchange cancelled.'
    ELSE ''
  END
$$;

CREATE OR REPLACE FUNCTION private.exchange_order_json(o public.exchange_orders)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'corridorId', o.corridor_id,
    'fromMethod', o.from_method,
    'toMethod', o.to_method,
    'fromLabel', private.method_label(o.from_method::text),
    'toLabel', private.method_label(o.to_method::text),
    'amountSent', o.amount_sent::text,
    'rate', o.rate_applied::float8,
    'fee', o.fee_applied::text,
    'amountReceived', o.amount_received::text,
    'senderPhone', o.sender_phone,
    'receiverPhone', o.receiver_phone,
    'collectionPhoneNumber', o.collection_phone_number,
    'collectionUssd', CASE WHEN o.collection_phone_number IS NOT NULL THEN
        '*' || private.exchange_dial_prefix(o.from_method) || '*' || private.phone_key(o.collection_phone_number)
        || '*' || private.ussd_amount(o.amount_sent) || '#' END,
    'status', o.status,
    'statusMessage', private.exchange_status_message(o.status),
    'paymentReference', o.payment_reference,
    'paymentVerifiedAt', o.payment_verified_at,
    'payoutReference', o.payout_reference,
    'failureReason', o.failure_reason,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.exchange_audit(
  p_order_id text, p_action text, p_before jsonb, p_after jsonb, p_actor uuid DEFAULT auth.uid()
)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.audit(p_actor, (SELECT role FROM public.users WHERE id = p_actor), p_action, 'exchange_order', p_order_id, p_before, p_after)
$$;

-- ---------------------------------------------------------------------------
-- Matching
-- ---------------------------------------------------------------------------

-- Device/SIM guardrail (Dalab findMatchingExchangeOrder): once Baari's
-- collection wallet for the paying method has a device on record, the SMS
-- must have arrived on it (and on its SIM slot, with Dalab's allowance for
-- Android's unresolved slot on single-SIM-registered devices).
CREATE OR REPLACE FUNCTION private.sms_on_collection_device(s public.sms_logs, p_method public.order_method)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w public.exchange_payout_wallets := private.collection_wallet(p_method);
  v_slots int;
BEGIN
  IF w.id IS NULL OR w.device_id IS NULL THEN
    RETURN NULL; -- nothing on record yet: accepted (Dalab's permissive fallback)
  END IF;
  IF w.device_id IS DISTINCT FROM s.device_id THEN
    RETURN format('expects device %s, SMS arrived on device %s', w.device_id, COALESCE(s.device_id, '(unknown)'));
  END IF;
  IF w.sim_slot IS NOT NULL AND w.sim_slot IS DISTINCT FROM s.sim_slot THEN
    SELECT count(DISTINCT sim_slot) INTO v_slots FROM public.exchange_payout_wallets
    WHERE device_id = w.device_id AND sim_slot IS NOT NULL;
    IF s.sim_slot IS NULL AND v_slots <= 1 THEN
      RETURN NULL;
    END IF;
    RETURN format('expects SIM slot %s, SMS arrived on slot %s', w.sim_slot, COALESCE(s.sim_slot::text, '(unresolved)'));
  END IF;
  RETURN NULL;
END
$$;

-- Tries to match one stored SMS. Returns {status, exchangeOrderId?,
-- orderId?, reason?}. Never moves money unless exactly one order fits.
CREATE OR REPLACE FUNCTION private.match_sms_log(p_sms_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sms_logs;
  v_method public.order_method;
  v_key text;
  v_cents bigint;
  v_ex text[];
  v_dep uuid[];
  v_rejected text[] := '{}';
  v_reason text;
  v_ref text;
  r record;
  o public.exchange_orders;
  d public.orders;
BEGIN
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id FOR UPDATE;
  IF s.id IS NULL OR s.match_status <> 'unmatched' THEN
    RETURN jsonb_build_object('status', COALESCE(s.match_status, 'missing'),
      'exchangeOrderId', s.matched_exchange_order_id, 'orderId', s.matched_order_id);
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
  v_cents := round(s.parsed_amount * 100);

  -- Exchange orders waiting for this payment (locked, so two SMS can't both
  -- take the same order).
  v_ex := '{}';
  FOR r IN
    SELECT eo.id FROM public.exchange_orders eo
    WHERE eo.status = 'pending' AND eo.from_method = v_method
      AND abs(eo.amount_sent - s.parsed_amount) < 0.01
      AND private.phone_key(eo.sender_phone) = v_key
      AND eo.updated_at > now() - interval '24 hours'
    ORDER BY eo.created_at ASC
    FOR UPDATE
  LOOP
    v_reason := private.sms_on_collection_device(s, v_method);
    IF v_reason IS NULL THEN
      v_ex := v_ex || r.id;
    ELSE
      v_rejected := v_rejected || format('order %s: %s', r.id, v_reason);
    END IF;
  END LOOP;

  -- Baari wallet deposits waiting for this payment.
  SELECT COALESCE(array_agg(id ORDER BY created_at), '{}') INTO v_dep FROM (
    SELECT o2.id, o2.created_at FROM public.orders o2
    WHERE o2.direction = 'deposit' AND o2.status = 'pending' AND o2.method = v_method
      AND o2.amount_cents = v_cents AND private.phone_key(o2.phone_number) = v_key
      AND o2.updated_at > now() - interval '24 hours'
    FOR UPDATE
  ) x;

  IF COALESCE(array_length(v_ex, 1), 0) + COALESCE(array_length(v_dep, 1), 0) = 0 THEN
    v_reason := CASE WHEN array_length(v_rejected, 1) > 0
      THEN 'Matched by amount+phone but rejected by collection-wallet device/SIM verification: ' || array_to_string(v_rejected, '; ')
      ELSE format('No pending order for $%s from ...%s on %s in the last 24h', s.parsed_amount, v_key, v_method) END;
    UPDATE public.sms_logs SET match_failure_reason = v_reason WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', v_reason);
  END IF;

  IF COALESCE(array_length(v_ex, 1), 0) + COALESCE(array_length(v_dep, 1), 0) > 1 THEN
    v_reason := format('Ambiguous: %s orders fit this payment (%s) -- needs a manager',
      COALESCE(array_length(v_ex, 1), 0) + COALESCE(array_length(v_dep, 1), 0),
      array_to_string(v_ex || ARRAY(SELECT x::text FROM unnest(v_dep) x), ', '));
    UPDATE public.sms_logs SET match_status = 'ambiguous', match_failure_reason = v_reason WHERE id = s.id;
    PERFORM private.audit(NULL, NULL, 'payment_sms_ambiguous', 'sms_log', s.id::text, NULL,
      jsonb_build_object('candidates', to_jsonb(v_ex || ARRAY(SELECT x::text FROM unnest(v_dep) x)), 'amount', s.parsed_amount, 'phone', v_key));
    RETURN jsonb_build_object('status', 'ambiguous', 'reason', v_reason);
  END IF;

  v_ref := COALESCE(s.transaction_ref, 'SMS-' || s.id::text);

  IF array_length(v_ex, 1) = 1 THEN
    -- Dalab autoAdvanceExchangeOrderToInProgress: pending -> in_progress,
    -- guarded by status so it can never fire twice.
    UPDATE public.exchange_orders
    SET status = 'in_progress', payment_sms_log_id = s.id, payment_reference = s.transaction_ref,
        payment_received_at = s.received_at, payment_verified_at = now(), payment_verified_by = 'sms_match',
        updated_at = now()
    WHERE id = v_ex[1] AND status = 'pending'
    RETURNING * INTO o;
    IF o.id IS NULL THEN
      UPDATE public.sms_logs SET match_failure_reason = 'Order was no longer pending' WHERE id = s.id;
      RETURN jsonb_build_object('status', 'unmatched', 'reason', 'Order was no longer pending');
    END IF;
    UPDATE public.sms_logs SET match_status = 'matched', matched_exchange_order_id = o.id, match_failure_reason = NULL
    WHERE id = s.id;
    PERFORM private.exchange_audit(o.id, 'exchange_payment_verified', jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'in_progress', 'smsLogId', s.id, 'customerPhone', o.sender_phone,
        'provider', s.parsed_provider, 'amount', s.parsed_amount, 'smsReceivedAt', s.received_at,
        'transactionRef', s.transaction_ref, 'verifiedAt', now()), s.agent_id);
    RETURN jsonb_build_object('status', 'matched', 'exchangeOrderId', o.id);
  END IF;

  -- Wallet deposit: credit through Baari's existing deposit completion.
  d := private.complete_deposit_order(v_dep[1], v_ref, s.agent_id, 'agent');
  UPDATE public.sms_logs SET match_status = 'matched', matched_order_id = d.id, match_failure_reason = NULL WHERE id = s.id;
  INSERT INTO public.sms_transactions (agent_id, device_id, provider, sender, amount_cents, transaction_ref, occurred_at, matched_order_id, match_status)
  VALUES (s.agent_id, s.device_id, v_method::text, s.parsed_phone, v_cents, v_ref, s.received_at, d.id, 'matched')
  ON CONFLICT (provider, transaction_ref) DO NOTHING;
  RETURN jsonb_build_object('status', 'matched', 'orderId', d.id);
END
$$;

-- SMS-before-order: try every unmatched payment SMS from this phone for this
-- amount (oldest first) against a newly created order.
CREATE OR REPLACE FUNCTION private.match_waiting_sms(p_phone text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  v jsonb;
BEGIN
  FOR r IN
    SELECT id FROM public.sms_logs
    WHERE match_status = 'unmatched' AND private.phone_key(parsed_phone) = private.phone_key(p_phone)
      AND abs(parsed_amount - p_amount) < 0.01 AND received_at > now() - interval '24 hours'
    ORDER BY received_at ASC
  LOOP
    v := private.match_sms_log(r.id);
    IF v ->> 'status' IN ('matched', 'ambiguous') THEN
      RETURN v;
    END IF;
  END LOOP;
  RETURN NULL;
END
$$;

-- Dalab resweepUnmatchedSmsLogs: every unmatched SMS of the last 24h gets
-- another try (an order created after it, a device/SIM fixed by a manager).
CREATE OR REPLACE FUNCTION private.resweep_unmatched_sms()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  v_matched int := 0;
BEGIN
  FOR r IN
    SELECT id FROM public.sms_logs
    WHERE match_status = 'unmatched' AND received_at > now() - interval '24 hours'
    ORDER BY received_at ASC
  LOOP
    BEGIN
      IF private.match_sms_log(r.id) ->> 'status' = 'matched' THEN
        v_matched := v_matched + 1;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'resweep failed for sms_log %: %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN v_matched;
END
$$;

-- ---------------------------------------------------------------------------
-- Agent: payment SMS upload (Dalab POST /agent/sms-logs -> ingestPaymentSms)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.agent_ingest_payment_sms(
  p_sender text, p_body text, p_received_at text,
  p_parsed_provider text DEFAULT NULL, p_parsed_amount text DEFAULT NULL, p_parsed_phone text DEFAULT NULL,
  p_transaction_ref text DEFAULT NULL, p_sim_slot int DEFAULT NULL, p_device_id text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  v_received timestamptz := private.parse_ts(p_received_at, 'receivedAt');
  v_ref text := NULLIF(btrim(COALESCE(p_transaction_ref, '')), '');
  v_amount numeric;
  v_id uuid;
  v_existing public.sms_logs;
  v_result jsonb;
BEGIN
  PERFORM private.check_len(p_sender, 'sender', 1, 60);
  PERFORM private.check_len(p_body, 'body', 1, 2000);
  IF p_parsed_amount IS NOT NULL THEN
    v_amount := private.to_amount(p_parsed_amount);
  END IF;

  -- Duplicate guard 1: the carrier's reference was already processed.
  IF v_ref IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.sms_logs WHERE transaction_ref = v_ref;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object('id', v_existing.id, 'status', 'already_processed',
        'matchStatus', v_existing.match_status, 'exchangeOrderId', v_existing.matched_exchange_order_id,
        'orderId', v_existing.matched_order_id);
    END IF;
  END IF;

  INSERT INTO public.sms_logs (agent_id, device_id, sender, body, parsed_provider, parsed_amount, parsed_phone,
                               transaction_ref, sim_slot, received_at)
  VALUES (v_agent, p_device_id, p_sender, p_body, p_parsed_provider, v_amount, p_parsed_phone, v_ref, p_sim_slot, v_received)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  -- Duplicate guard 2: same sender + body in the same minute (a redelivered
  -- broadcast, a retry after a dropped response, an inbox rescan).
  IF v_id IS NULL THEN
    SELECT * INTO v_existing FROM public.sms_logs
    WHERE (v_ref IS NOT NULL AND transaction_ref = v_ref)
       OR (sender = p_sender AND body = p_body
           AND date_trunc('minute', received_at AT TIME ZONE 'UTC') = date_trunc('minute', v_received AT TIME ZONE 'UTC'))
    LIMIT 1;
    RETURN jsonb_build_object('id', v_existing.id, 'status', 'already_processed',
      'matchStatus', v_existing.match_status, 'exchangeOrderId', v_existing.matched_exchange_order_id,
      'orderId', v_existing.matched_order_id);
  END IF;

  v_result := private.match_sms_log(v_id);
  RETURN jsonb_build_object('id', v_id, 'status', 'new', 'matchStatus', v_result ->> 'status',
    'exchangeOrderId', v_result ->> 'exchangeOrderId', 'orderId', v_result ->> 'orderId', 'reason', v_result ->> 'reason');
END
$$;

-- ---------------------------------------------------------------------------
-- Customer: corridors, quote, orders
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.exchange_quote(c public.exchange_corridors, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  v_fee numeric;
  v_received numeric;
BEGIN
  v_fee := CASE WHEN c.fee_type = 'percentage' THEN round(p_amount * c.fee_value / 100, 2) ELSE round(c.fee_value, 2) END;
  v_received := round(greatest(0, p_amount * c.rate - v_fee), 2);
  RETURN jsonb_build_object('corridorId', c.id, 'amountSent', round(p_amount, 2)::text, 'rate', c.rate::float8,
    'fee', v_fee::text, 'amountReceived', v_received::text);
END
$$;

CREATE OR REPLACE FUNCTION private.load_corridor(p_id uuid)
RETURNS public.exchange_corridors LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.exchange_corridors;
BEGIN
  SELECT * INTO c FROM public.exchange_corridors WHERE id = p_id;
  IF c.id IS NULL OR NOT c.enabled THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Exchange option not found or disabled');
  END IF;
  RETURN c;
END
$$;

CREATE OR REPLACE FUNCTION private.check_corridor_amount(c public.exchange_corridors, p_amount numeric)
RETURNS void LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    PERFORM private.raise_api(400, 'INVALID_AMOUNT', 'Amount must be greater than zero');
  END IF;
  IF c.min_amount IS NOT NULL AND p_amount < c.min_amount THEN
    PERFORM private.raise_api(400, 'BELOW_MIN', 'Minimum amount is ' || c.min_amount);
  END IF;
  IF c.max_amount IS NOT NULL AND p_amount > c.max_amount THEN
    PERFORM private.raise_api(400, 'ABOVE_MAX', 'Maximum amount is ' || c.max_amount);
  END IF;
END
$$;

-- Enabled exchange directions with Baari's number to pay into.
CREATE OR REPLACE FUNCTION public.exchange_options()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_user();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', c.id, 'fromMethod', c.from_method, 'toMethod', c.to_method,
      'fromLabel', private.method_label(c.from_method::text), 'toLabel', private.method_label(c.to_method::text),
      'rate', c.rate::float8, 'feeType', c.fee_type, 'feeValue', c.fee_value::text,
      'minAmount', c.min_amount::text, 'maxAmount', c.max_amount::text,
      'collectionPhoneNumber', (private.collection_wallet(c.from_method)).phone_number
    ) ORDER BY c.from_method)
    FROM public.exchange_corridors c
    WHERE c.enabled AND c.payout_wallet_id IS NOT NULL AND (private.collection_wallet(c.from_method)).id IS NOT NULL
  ), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.exchange_quote(p_corridor_id uuid, p_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_user();
  c public.exchange_corridors := private.load_corridor(p_corridor_id);
  v_amount numeric := private.to_amount(p_amount);
BEGIN
  PERFORM private.check_corridor_amount(c, v_amount);
  RETURN private.exchange_quote(c, v_amount);
END
$$;

-- Dalab createExchangeOrder (customer_app channel).
CREATE OR REPLACE FUNCTION public.customer_create_exchange_order(
  p_corridor_id uuid, p_amount text, p_sender_phone text, p_receiver_phone text, p_client_request_id uuid
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid := private.require_role('customer');
  c public.exchange_corridors := private.load_corridor(p_corridor_id);
  v_amount numeric := private.to_amount(p_amount);
  v_sender text;
  v_receiver text;
  v_quote jsonb;
  v_collection public.exchange_payout_wallets;
  o public.exchange_orders;
BEGIN
  IF p_client_request_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'clientRequestId is required');
  END IF;
  -- A retried create returns the order the first attempt made.
  SELECT * INTO o FROM public.exchange_orders WHERE client_request_id = p_client_request_id;
  IF o.id IS NOT NULL THEN
    IF o.customer_id IS DISTINCT FROM v_customer THEN
      PERFORM private.raise_api(409, 'IDEMPOTENCY_KEY_REUSED', 'This request id was already used');
    END IF;
    RETURN private.exchange_order_json(o);
  END IF;

  PERFORM private.check_corridor_amount(c, v_amount);
  v_sender := private.validate_mobile(p_sender_phone, c.from_method, 'sender number');
  v_receiver := private.validate_mobile(p_receiver_phone, c.to_method, 'receiver number');
  IF c.payout_wallet_id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_AVAILABLE', 'This exchange is not available right now');
  END IF;
  v_collection := private.collection_wallet(c.from_method);
  IF v_collection.id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_AVAILABLE', 'This exchange is not available right now');
  END IF;
  v_quote := private.exchange_quote(c, v_amount);

  -- Same customer, same corridor, same amount, still unpaid: reuse it with
  -- this visit's numbers instead of creating a sibling (Dalab 046).
  UPDATE public.exchange_orders
  SET sender_phone = v_sender, receiver_phone = v_receiver, collection_phone_number = v_collection.phone_number,
      client_request_id = p_client_request_id, updated_at = now()
  WHERE customer_id = v_customer AND corridor_id = c.id AND amount_sent = v_amount AND status = 'pending'
  RETURNING * INTO o;

  IF o.id IS NULL THEN
    INSERT INTO public.exchange_orders (id, customer_id, corridor_id, from_method, to_method, amount_sent, rate_applied,
      fee_applied, amount_received, sender_phone, receiver_phone, collection_phone_number, client_request_id)
    VALUES (private.exchange_order_ref(), v_customer, c.id, c.from_method, c.to_method, v_amount, c.rate,
      (v_quote ->> 'fee')::numeric, (v_quote ->> 'amountReceived')::numeric, v_sender, v_receiver,
      v_collection.phone_number, p_client_request_id)
    RETURNING * INTO o;
    PERFORM private.exchange_audit(o.id, 'exchange_order_created', NULL, private.exchange_order_json(o));
  END IF;

  -- SMS-before-order: the customer may already have paid.
  PERFORM private.match_waiting_sms(o.sender_phone, o.amount_sent);
  SELECT * INTO o FROM public.exchange_orders WHERE id = o.id;
  RETURN private.exchange_order_json(o);
END
$$;

CREATE OR REPLACE FUNCTION public.customer_exchange_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid := private.require_role('customer');
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.exchange_order_json(o) ORDER BY o.created_at DESC)
    FROM (SELECT * FROM public.exchange_orders WHERE customer_id = v_customer ORDER BY created_at DESC LIMIT 100) o), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.customer_exchange_order(p_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid := private.require_role('customer');
  o public.exchange_orders;
BEGIN
  SELECT * INTO o FROM public.exchange_orders WHERE id = p_id AND customer_id = v_customer;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Exchange order not found');
  END IF;
  RETURN private.exchange_order_json(o);
END
$$;

-- ---------------------------------------------------------------------------
-- Agent device: automatic payout (Dalab dial attempts + ExchangeSelfHealSweeper)
-- ---------------------------------------------------------------------------

-- Verified orders waiting for a payout. hasDialAttempt: once ANY attempt
-- exists the device never auto-dials that order again (Dalab).
CREATE OR REPLACE FUNCTION public.agent_exchange_payout_queue()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.exchange_order_json(eo) || jsonb_build_object(
      'hasDialAttempt', EXISTS (SELECT 1 FROM public.exchange_dial_attempts a WHERE a.exchange_order_id = eo.id),
      -- A manager asked for another attempt after a retry (newer than every attempt).
      'payoutRequested', eo.payout_requested_at IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.exchange_dial_attempts a WHERE a.exchange_order_id = eo.id AND a.created_at >= eo.payout_requested_at),
      'payoutDeviceId', w.device_id, 'payoutSimSlot', w.sim_slot, 'payoutPhoneNumber', w.phone_number,
      'customerName', u.name
    ) ORDER BY eo.created_at ASC)
    FROM public.exchange_orders eo
    JOIN public.exchange_corridors c ON c.id = eo.corridor_id
    LEFT JOIN public.exchange_payout_wallets w ON w.id = c.payout_wallet_id
    LEFT JOIN public.users u ON u.id = eo.customer_id
    WHERE eo.status = 'in_progress'
  ), '[]'::jsonb);
END
$$;

-- Dalab POST /agent/exchange/orders/:id/dial-attempts. Starts (or returns
-- the unfinished) payout attempt. The PIN is returned ONLY for a new
-- attempt, so it can never be issued twice for the same try.
CREATE OR REPLACE FUNCTION public.agent_exchange_start_dial(p_order_id text, p_device_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  o public.exchange_orders;
  c public.exchange_corridors;
  w public.exchange_payout_wallets;
  v_latest public.exchange_dial_attempts;
  v_ussd text;
  v_id uuid;
  v_next int;
  v_pin text;
BEGIN
  -- Serializes concurrent starts for the same order (two taps, the sweeper
  -- racing a manual tap): the second waits, then sees the first's attempt.
  SELECT * INTO o FROM public.exchange_orders WHERE id = p_order_id FOR UPDATE;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Exchange order not found');
  END IF;
  IF o.status <> 'in_progress' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', format('Cannot dial a payout for an order in status ''%s''', o.status));
  END IF;
  IF EXISTS (SELECT 1 FROM public.exchange_dial_attempts WHERE exchange_order_id = o.id AND status = 'success') THEN
    PERFORM private.raise_api(409, 'ALREADY_PAID', 'This payout already succeeded');
  END IF;
  SELECT * INTO c FROM public.exchange_corridors WHERE id = o.corridor_id;
  SELECT * INTO w FROM public.exchange_payout_wallets WHERE id = c.payout_wallet_id;
  IF w.id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_CONFIGURED', 'This exchange has no payout wallet configured');
  END IF;
  IF w.pin_secret_id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_CONFIGURED', 'The payout wallet has no PIN configured');
  END IF;
  IF w.device_id IS NOT NULL AND w.device_id IS DISTINCT FROM p_device_id THEN
    PERFORM private.raise_api(409, 'WRONG_DEVICE', 'This payout must be dialed from the payout wallet''s own phone');
  END IF;

  v_ussd := '*' || private.exchange_dial_prefix(w.method) || '*' || private.phone_key(o.receiver_phone)
            || '*' || private.ussd_amount(o.amount_received) || '#';

  SELECT * INTO v_latest FROM public.exchange_dial_attempts
  WHERE exchange_order_id = o.id ORDER BY attempt_number DESC LIMIT 1;
  IF v_latest.id IS NOT NULL AND v_latest.status IN ('pending', 'step1_success') THEN
    RETURN jsonb_build_object('id', v_latest.id, 'step1UssdString', COALESCE(v_latest.step1_ussd_string, v_ussd),
      'simSlot', w.sim_slot, 'isNew', false);
  END IF;

  v_next := COALESCE(v_latest.attempt_number, 0) + 1;
  INSERT INTO public.exchange_dial_attempts (exchange_order_id, agent_id, device_id, sim_slot, attempt_number, step1_ussd_string)
  VALUES (o.id, v_agent, p_device_id, w.sim_slot, v_next, v_ussd)
  RETURNING id INTO v_id;
  UPDATE public.exchange_orders SET agent_id = v_agent, updated_at = now() WHERE id = o.id;
  PERFORM private.exchange_audit(o.id, 'exchange_payout_dial_started', NULL,
    jsonb_build_object('attempt', v_next, 'payoutProvider', w.method, 'payoutAmount', o.amount_received,
      'payoutDestination', o.receiver_phone, 'deviceId', p_device_id));

  SELECT decrypted_secret INTO v_pin FROM vault.decrypted_secrets WHERE id = w.pin_secret_id;
  RETURN jsonb_build_object('id', v_id, 'step1UssdString', v_ussd, 'simSlot', w.sim_slot, 'isNew', true, 'pin', v_pin);
END
$$;

CREATE OR REPLACE FUNCTION private.exchange_payout_pin(p_order_id text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.decrypted_secret FROM public.exchange_orders o
  JOIN public.exchange_corridors c ON c.id = o.corridor_id
  JOIN public.exchange_payout_wallets w ON w.id = c.payout_wallet_id
  JOIN vault.decrypted_secrets s ON s.id = w.pin_secret_id
  WHERE o.id = p_order_id
$$;

CREATE OR REPLACE FUNCTION private.scrub_pin(p_text text, p_pin text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_text IS NULL OR p_pin IS NULL OR p_pin = '' THEN p_text ELSE replace(p_text, p_pin, '••••') END
$$;

CREATE OR REPLACE FUNCTION private.fail_exchange_order(p_order_id text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.exchange_orders SET status = 'failed', failure_reason = p_reason, updated_at = now()
  WHERE id = p_order_id AND status NOT IN ('completed', 'cancelled');
  IF FOUND THEN
    PERFORM private.exchange_audit(p_order_id, 'exchange_payout_failed', NULL, jsonb_build_object('status', 'failed', 'reason', p_reason));
  END IF;
END
$$;

-- Step 1 (number + amount entered, before the PIN).
CREATE OR REPLACE FUNCTION public.agent_exchange_report_step1(
  p_attempt_id uuid, p_status text, p_response text DEFAULT NULL, p_is_final boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  a public.exchange_dial_attempts;
BEGIN
  IF p_status NOT IN ('step1_success', 'failed', 'ambiguous') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be step1_success, failed or ambiguous');
  END IF;
  UPDATE public.exchange_dial_attempts SET status = p_status, step1_response = left(p_response, 2000)
  WHERE id = p_attempt_id AND status = 'pending'
  RETURNING * INTO a;
  IF a.id IS NULL THEN
    SELECT * INTO a FROM public.exchange_dial_attempts WHERE id = p_attempt_id;
    IF a.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Dial attempt not found');
    END IF;
    RETURN to_jsonb(a);
  END IF;
  -- Step 1 failing means no PIN went to the carrier: nothing was sent.
  IF p_status <> 'step1_success' AND p_is_final THEN
    PERFORM private.fail_exchange_order(a.exchange_order_id, 'Payout step 1 ' || p_status || ': ' || COALESCE(left(p_response, 200), ''));
  END IF;
  RETURN to_jsonb(a);
END
$$;

-- Step 2 (PIN submitted; the carrier's result).
CREATE OR REPLACE FUNCTION public.agent_exchange_report_step2(
  p_attempt_id uuid, p_status text, p_response text DEFAULT NULL, p_is_final boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  a public.exchange_dial_attempts;
  o public.exchange_orders;
  v_text text;
BEGIN
  IF p_status NOT IN ('success', 'failed', 'ambiguous') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be success, failed or ambiguous');
  END IF;
  SELECT * INTO a FROM public.exchange_dial_attempts WHERE id = p_attempt_id;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Dial attempt not found');
  END IF;
  v_text := private.scrub_pin(left(p_response, 2000), private.exchange_payout_pin(a.exchange_order_id));
  UPDATE public.exchange_dial_attempts SET status = p_status, step2_response = v_text, completed_at = now()
  WHERE id = p_attempt_id AND status IN ('pending', 'step1_success')
  RETURNING * INTO a;
  IF a.id IS NULL THEN
    SELECT * INTO a FROM public.exchange_dial_attempts WHERE id = p_attempt_id;
    RETURN to_jsonb(a);
  END IF;

  IF p_status = 'success' THEN
    UPDATE public.exchange_orders SET status = 'completed', completed_at = now(), updated_at = now(), failure_reason = NULL
    WHERE id = a.exchange_order_id AND status <> 'completed'
    RETURNING * INTO o;
    IF o.id IS NOT NULL THEN
      PERFORM private.exchange_audit(o.id, 'exchange_completed', NULL, jsonb_build_object(
        'status', 'completed', 'payoutProvider', o.to_method, 'payoutAmount', o.amount_received,
        'payoutDestination', o.receiver_phone, 'attempt', a.attempt_number, 'carrierResponse', v_text));
    END IF;
  ELSIF p_is_final THEN
    -- 'ambiguous' may still have gone through: the carrier's payout SMS can
    -- still complete it (payout confirmation below, which also accepts
    -- failed orders).
    PERFORM private.fail_exchange_order(a.exchange_order_id, 'Payout ' || p_status || ': ' || COALESCE(left(v_text, 200), ''));
  END IF;
  RETURN to_jsonb(a);
END
$$;

-- Dalab POST /agent/exchange/orders/payout-confirmation: the carrier's own
-- "you transferred $X to NUMBER" SMS on the payout phone. Corroboration of
-- a payout that was actually dialed -- never a substitute for one.
CREATE OR REPLACE FUNCTION public.agent_exchange_payout_confirmation(
  p_receiver_phone text, p_amount text, p_raw_text text DEFAULT NULL, p_provider text DEFAULT NULL, p_reference text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  v_amount numeric := private.to_amount(p_amount);
  v_key text := private.phone_key(p_receiver_phone);
  o public.exchange_orders;
  v_text text;
  v_result text;
BEGIN
  IF v_key IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'receiverPhone is not a valid phone number');
  END IF;
  -- Most recently touched first (Dalab DEX139625920 fix).
  SELECT * INTO o FROM public.exchange_orders
  WHERE status IN ('in_progress', 'failed') AND abs(amount_received - v_amount) < 0.01
    AND private.phone_key(receiver_phone) = v_key
  ORDER BY updated_at DESC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF o.id IS NULL THEN
    v_result := 'no_matching_order';
  ELSIF NOT EXISTS (SELECT 1 FROM public.exchange_dial_attempts WHERE exchange_order_id = o.id AND completed_at IS NOT NULL) THEN
    v_result := 'ignored_no_dial_attempt';
    PERFORM private.exchange_audit(o.id, 'exchange_payout_sms_ignored_no_attempt', NULL, jsonb_build_object('text', left(p_raw_text, 500)), v_agent);
  ELSE
    v_text := private.scrub_pin(left(p_raw_text, 2000), private.exchange_payout_pin(o.id));
    UPDATE public.exchange_orders
    SET status = 'completed', completed_at = now(), updated_at = now(), failure_reason = NULL,
        payout_reference = COALESCE(p_reference, payout_reference), payout_confirmed_at = now()
    WHERE id = o.id AND status IN ('in_progress', 'failed');
    UPDATE public.exchange_dial_attempts SET status = 'success', step2_response = v_text, completed_at = now()
    WHERE exchange_order_id = o.id AND status <> 'success'
      AND attempt_number = (SELECT max(attempt_number) FROM public.exchange_dial_attempts WHERE exchange_order_id = o.id);
    PERFORM private.exchange_audit(o.id, 'exchange_completed_via_payout_sms', jsonb_build_object('status', o.status),
      jsonb_build_object('status', 'completed', 'payoutProvider', COALESCE(p_provider, o.to_method::text),
        'payoutAmount', v_amount, 'payoutDestination', o.receiver_phone, 'payoutReference', p_reference, 'confirmationText', v_text), v_agent);
    v_result := 'completed';
  END IF;

  INSERT INTO public.exchange_payout_confirmations (agent_id, provider, receiver_phone, amount, raw_text, exchange_order_id, result)
  VALUES (v_agent, p_provider, p_receiver_phone, v_amount, left(p_raw_text, 2000), o.id, v_result);
  RETURN jsonb_build_object('matched', o.id IS NOT NULL, 'orderId', o.id, 'result', v_result);
END
$$;

-- ---------------------------------------------------------------------------
-- Management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manage_exchange_orders(p_status text DEFAULT NULL, p_q text DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.exchange_order_json(o) || jsonb_build_object('customerName', u.name, 'customerPhone', u.phone)
      ORDER BY o.created_at DESC)
    FROM (SELECT * FROM public.exchange_orders
          WHERE (p_status IS NULL OR status = p_status)
            AND (v_q IS NULL OR id ILIKE '%' || v_q || '%' OR sender_phone ILIKE '%' || v_q || '%' OR receiver_phone ILIKE '%' || v_q || '%')
          ORDER BY created_at DESC LIMIT least(greatest(COALESCE(p_limit, 100), 1), 500)) o
    LEFT JOIN public.users u ON u.id = o.customer_id), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_exchange_order(p_id text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.exchange_orders;
BEGIN
  SELECT * INTO o FROM public.exchange_orders WHERE id = p_id;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Exchange order not found');
  END IF;
  RETURN private.exchange_order_json(o) || jsonb_build_object(
    'dialAttempts', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'attemptNumber', a.attempt_number,
        'status', a.status, 'step1UssdString', a.step1_ussd_string, 'step1Response', a.step1_response,
        'step2Response', a.step2_response, 'deviceId', a.device_id, 'simSlot', a.sim_slot,
        'createdAt', a.created_at, 'completedAt', a.completed_at) ORDER BY a.attempt_number)
      FROM public.exchange_dial_attempts a WHERE a.exchange_order_id = o.id), '[]'::jsonb),
    'paymentSms', (SELECT jsonb_build_object('id', s.id, 'sender', s.sender, 'body', s.body, 'receivedAt', s.received_at,
        'transactionRef', s.transaction_ref) FROM public.sms_logs s WHERE s.id = o.payment_sms_log_id),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object('action', l.action, 'after', l.after_json, 'createdAt', l.created_at)
        ORDER BY l.created_at) FROM public.audit_logs l WHERE l.entity_type = 'exchange_order' AND l.entity_id = o.id), '[]'::jsonb)
  );
END
$$;

-- Manual verification (Dalab "Verify Payment"), for a payment a manager confirmed.
CREATE OR REPLACE FUNCTION public.manage_exchange_verify(p_id text, p_reference text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.exchange_orders;
BEGIN
  UPDATE public.exchange_orders
  SET status = 'in_progress', payment_verified_at = now(), payment_verified_by = 'manager',
      payment_reference = COALESCE(p_reference, payment_reference), updated_at = now()
  WHERE id = p_id AND status = 'pending'
  RETURNING * INTO o;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only a pending order can be verified');
  END IF;
  PERFORM private.exchange_audit(o.id, 'verify_exchange_order', jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'in_progress', 'source', 'manager', 'reference', p_reference));
  RETURN private.exchange_order_json(o);
END
$$;

-- Assign an ambiguous / unmatched payment SMS to an order by hand.
CREATE OR REPLACE FUNCTION public.manage_resolve_payment_sms(p_sms_id uuid, p_exchange_order_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  s public.sms_logs;
  o public.exchange_orders;
BEGIN
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id FOR UPDATE;
  IF s.id IS NULL OR s.match_status NOT IN ('unmatched', 'ambiguous') THEN
    PERFORM private.raise_api(409, 'INVALID_STATE', 'This SMS is already matched');
  END IF;
  UPDATE public.exchange_orders
  SET status = 'in_progress', payment_sms_log_id = s.id, payment_reference = s.transaction_ref,
      payment_received_at = s.received_at, payment_verified_at = now(), payment_verified_by = 'manager', updated_at = now()
  WHERE id = p_exchange_order_id AND status = 'pending'
  RETURNING * INTO o;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only a pending order can take a payment');
  END IF;
  UPDATE public.sms_logs SET match_status = 'matched', matched_exchange_order_id = o.id, match_failure_reason = NULL WHERE id = s.id;
  PERFORM private.exchange_audit(o.id, 'exchange_payment_assigned_by_manager', NULL,
    jsonb_build_object('smsLogId', s.id, 'amount', s.parsed_amount, 'transactionRef', s.transaction_ref));
  RETURN private.exchange_order_json(o);
END
$$;

-- Dalab retry-payout (failed -> in_progress), with the protection the
-- product asked for: never after a successful attempt or a carrier payout
-- confirmation, and an 'ambiguous' last attempt (the money may have gone
-- out) needs the manager to confirm it was not paid.
CREATE OR REPLACE FUNCTION public.manage_exchange_retry_payout(p_id text, p_confirmed_not_paid boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.exchange_orders;
  v_last public.exchange_dial_attempts;
BEGIN
  SELECT * INTO o FROM public.exchange_orders WHERE id = p_id FOR UPDATE;
  IF o.id IS NULL OR o.status <> 'failed' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only a failed order can be retried');
  END IF;
  IF EXISTS (SELECT 1 FROM public.exchange_dial_attempts WHERE exchange_order_id = o.id AND status = 'success')
     OR EXISTS (SELECT 1 FROM public.exchange_payout_confirmations WHERE exchange_order_id = o.id AND result = 'completed') THEN
    PERFORM private.raise_api(409, 'ALREADY_PAID', 'A payout for this order already went through');
  END IF;
  SELECT * INTO v_last FROM public.exchange_dial_attempts WHERE exchange_order_id = o.id ORDER BY attempt_number DESC LIMIT 1;
  IF v_last.status = 'ambiguous' AND NOT COALESCE(p_confirmed_not_paid, false) THEN
    PERFORM private.raise_api(409, 'CONFIRM_NOT_PAID',
      'The last payout attempt had an unclear result. Check the payout wallet''s history first, then confirm it was not paid.');
  END IF;
  UPDATE public.exchange_orders SET status = 'in_progress', failure_reason = NULL, updated_at = now() WHERE id = o.id
  RETURNING * INTO o;
  PERFORM private.exchange_audit(o.id, 'retry_exchange_payout', jsonb_build_object('status', 'failed'),
    jsonb_build_object('status', 'in_progress', 'confirmedNotPaid', p_confirmed_not_paid));
  RETURN private.exchange_order_json(o);
END
$$;

-- Manager-started payout attempt for a retried order (the device never
-- auto-dials an order that already has an attempt).
CREATE OR REPLACE FUNCTION public.manage_exchange_request_payout(p_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.exchange_orders;
BEGIN
  UPDATE public.exchange_orders SET payout_requested_at = now(), updated_at = now()
  WHERE id = p_id AND status = 'in_progress' RETURNING * INTO o;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only an order waiting for its payout can be sent');
  END IF;
  PERFORM private.exchange_audit(o.id, 'exchange_payout_requested', NULL, NULL);
  RETURN private.exchange_order_json(o);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_exchange_reverse(p_id text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.exchange_orders;
BEGIN
  UPDATE public.exchange_orders SET status = 'cancelled', reversed_at = now(), failure_reason = COALESCE(p_reason, failure_reason),
    updated_at = now()
  WHERE id = p_id AND status IN ('pending', 'in_progress', 'failed')
    AND NOT EXISTS (SELECT 1 FROM public.exchange_dial_attempts a WHERE a.exchange_order_id = p_id AND a.status = 'success')
  RETURNING * INTO o;
  IF o.id IS NULL THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'This order can no longer be cancelled');
  END IF;
  PERFORM private.exchange_audit(o.id, 'reverse_exchange_order', NULL, jsonb_build_object('status', 'cancelled', 'reason', p_reason));
  RETURN private.exchange_order_json(o);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_payment_sms(p_status text DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'sender', s.sender, 'body', s.body,
      'provider', s.parsed_provider, 'amount', s.parsed_amount::text, 'phone', s.parsed_phone,
      'transactionRef', s.transaction_ref, 'receivedAt', s.received_at, 'matchStatus', s.match_status,
      'exchangeOrderId', s.matched_exchange_order_id, 'orderId', s.matched_order_id,
      'reason', s.match_failure_reason, 'deviceId', s.device_id, 'simSlot', s.sim_slot) ORDER BY s.received_at DESC)
    FROM (SELECT * FROM public.sms_logs WHERE p_status IS NULL OR match_status = p_status
          ORDER BY received_at DESC LIMIT least(greatest(COALESCE(p_limit, 100), 1), 500)) s), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_exchange_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'corridors', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'fromMethod', c.from_method, 'toMethod', c.to_method,
        'rate', c.rate::float8, 'feeType', c.fee_type, 'feeValue', c.fee_value::text, 'minAmount', c.min_amount::text,
        'maxAmount', c.max_amount::text, 'payoutWalletId', c.payout_wallet_id, 'enabled', c.enabled) ORDER BY c.from_method)
      FROM public.exchange_corridors c), '[]'::jsonb),
    'payoutWallets', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', w.id, 'method', w.method, 'phoneNumber', w.phone_number,
        'deviceId', w.device_id, 'simSlot', w.sim_slot, 'hasPin', w.pin_secret_id IS NOT NULL) ORDER BY w.created_at)
      FROM public.exchange_payout_wallets w), '[]'::jsonb)
  );
END
$$;

CREATE OR REPLACE FUNCTION public.manage_save_exchange_corridor(
  p_id uuid, p_rate numeric, p_fee_type text, p_fee_value numeric, p_min_amount numeric, p_max_amount numeric,
  p_payout_wallet_id uuid, p_enabled boolean
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  c public.exchange_corridors;
  w public.exchange_payout_wallets;
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 OR p_fee_type NOT IN ('fixed', 'percentage') OR p_fee_value IS NULL OR p_fee_value < 0
     OR (p_min_amount IS NOT NULL AND p_max_amount IS NOT NULL AND p_min_amount > p_max_amount) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid rate, fee or limits');
  END IF;
  SELECT * INTO c FROM public.exchange_corridors WHERE id = p_id;
  IF c.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Exchange option not found');
  END IF;
  IF p_payout_wallet_id IS NOT NULL THEN
    SELECT * INTO w FROM public.exchange_payout_wallets WHERE id = p_payout_wallet_id;
    IF w.id IS NULL OR w.method <> c.to_method THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The payout wallet must be on the network the money is sent to');
    END IF;
  END IF;
  IF p_enabled AND p_payout_wallet_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose a payout wallet before turning this exchange on');
  END IF;
  UPDATE public.exchange_corridors
  SET rate = p_rate, fee_type = p_fee_type, fee_value = p_fee_value, min_amount = p_min_amount, max_amount = p_max_amount,
      payout_wallet_id = p_payout_wallet_id, enabled = COALESCE(p_enabled, false), updated_at = now()
  WHERE id = p_id RETURNING * INTO c;
  PERFORM private.audit(v_id, private.app_role(), 'exchange_corridor.update', 'exchange_corridor', c.id::text, NULL, to_jsonb(c));
  RETURN to_jsonb(c);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_save_payout_wallet(
  p_id uuid, p_method text, p_phone_number text, p_device_id text DEFAULT NULL, p_sim_slot int DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method, 'mobile_money');
  v_phone text;
  w public.exchange_payout_wallets;
BEGIN
  IF v_method NOT IN ('evc_plus', 'edahab') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Exchange supports EVC Plus and eDahab wallets');
  END IF;
  v_phone := private.validate_mobile(p_phone_number, v_method, 'wallet number');
  IF p_sim_slot IS NOT NULL AND p_sim_slot NOT IN (1, 2) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'SIM slot must be 1 or 2');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.exchange_payout_wallets (method, phone_number, device_id, sim_slot, created_by)
    VALUES (v_method, v_phone, NULLIF(p_device_id, ''), p_sim_slot, v_id) RETURNING * INTO w;
  ELSE
    UPDATE public.exchange_payout_wallets
    SET method = v_method, phone_number = v_phone, device_id = NULLIF(p_device_id, ''), sim_slot = p_sim_slot, updated_at = now()
    WHERE id = p_id RETURNING * INTO w;
    IF w.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Payout wallet not found');
    END IF;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'exchange_payout_wallet.save', 'exchange_payout_wallet', w.id::text, NULL,
    jsonb_build_object('method', w.method, 'phoneNumber', w.phone_number, 'deviceId', w.device_id, 'simSlot', w.sim_slot));
  RETURN jsonb_build_object('id', w.id, 'method', w.method, 'phoneNumber', w.phone_number, 'deviceId', w.device_id,
    'simSlot', w.sim_slot, 'hasPin', w.pin_secret_id IS NOT NULL);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_set_payout_wallet_pin(p_id uuid, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  w public.exchange_payout_wallets;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^\d{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The PIN must be 4 to 8 digits');
  END IF;
  SELECT * INTO w FROM public.exchange_payout_wallets WHERE id = p_id FOR UPDATE;
  IF w.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Payout wallet not found');
  END IF;
  UPDATE public.exchange_payout_wallets
  SET pin_secret_id = private.store_secret(w.pin_secret_id, p_pin, 'exchange_payout_wallet:' || w.id || ':pin'), updated_at = now()
  WHERE id = w.id;
  PERFORM private.audit(v_id, private.app_role(), 'exchange_payout_wallet.set_pin', 'exchange_payout_wallet', w.id::text);
  RETURN jsonb_build_object('id', w.id, 'hasPin', true);
END
$$;
