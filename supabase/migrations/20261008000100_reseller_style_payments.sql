-- BAARI deposits and withdrawals, Dalab Reseller style.
--
-- Dalab Internet's Reseller (admin-backend-ts migrations 048-060,
-- resellerSmsMatching.ts, the agent-app's ResellerWithdrawal* payout code)
-- applied to Baari's own customer wallet:
--
--   Deposit ("Lacag Ku Shub"): the customer sends money to Baari's number and
--   creates a pending deposit. The carrier's SMS on the agent phone is
--   uploaded (agent_ingest_payment_sms), matched on method + sender phone
--   (last 9 digits) + exact amount + 24h window (+ the agent phone/SIM the
--   wallet is on), and only then is the wallet credited.
--
--   Withdraw ("Lacag Bixi"): the funds are reserved when the customer asks.
--   The agent phone holding Baari's EVC Plus / eDahab SIM dials the payout
--   automatically (USSD + PIN). The wallet is debited only when the payout
--   is confirmed (the carrier's answer, or its "you transferred" SMS). A
--   payout that may have gone out is never released back to the customer
--   without a manager confirming it was not paid.
--
-- The EVC Plus <-> eDahab Exchange added on 2026-10-07 is removed.

-- ---------------------------------------------------------------------------
-- Remove the Exchange
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    WHERE (p.pronamespace = 'public'::regnamespace AND p.proname ~
            '^(exchange_options|exchange_quote|customer_create_exchange_order|customer_exchange_order|customer_exchange_orders|agent_exchange_|manage_exchange_|manage_save_exchange_corridor|manage_resolve_payment_sms)')
       OR (p.pronamespace = 'private'::regnamespace AND p.proname ~
            '^(check_corridor_amount|collection_wallet|exchange_|fail_exchange_order|load_corridor|sms_on_collection_device)')
  LOOP
    EXECUTE format('DROP FUNCTION %s CASCADE', f.sig);
  END LOOP;
END
$$;

DROP INDEX IF EXISTS public.idx_sms_logs_one_per_exchange_order;
ALTER TABLE public.sms_logs DROP COLUMN IF EXISTS matched_exchange_order_id;
DROP TABLE IF EXISTS public.exchange_payout_confirmations;
DROP TABLE IF EXISTS public.exchange_dial_attempts;
DROP TABLE IF EXISTS public.exchange_orders;
DROP TABLE IF EXISTS public.exchange_corridors;

-- ---------------------------------------------------------------------------
-- Baari's wallets on the agent phone (Dalab: reseller_deposit_methods'
-- device/SIM + reseller_withdrawal_sim_routing + the payout PIN).
-- Payment SMS for a wallet must arrive on its phone/SIM once one is set;
-- withdrawals of its method are paid out from it.
-- ---------------------------------------------------------------------------
ALTER TABLE IF EXISTS public.exchange_payout_wallets RENAME TO payout_wallets;
CREATE TABLE IF NOT EXISTS public.payout_wallets (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method         public.order_method NOT NULL CHECK (method IN ('evc_plus', 'edahab')),
  phone_number   TEXT NOT NULL,
  device_id      TEXT,
  sim_slot       INTEGER CHECK (sim_slot IN (1, 2)),
  pin_secret_id  UUID,
  created_by     UUID REFERENCES public.users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payout_wallets ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.payout_dial_prefix(p_method public.order_method)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_method WHEN 'evc_plus' THEN '712' WHEN 'edahab' THEN '110' END
$$;

-- The wallet a method's withdrawals are paid from: the oldest one on an
-- agent phone with a PIN.
CREATE OR REPLACE FUNCTION private.payout_wallet(p_method public.order_method)
RETURNS public.payout_wallets LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT * FROM public.payout_wallets
  WHERE method = p_method AND pin_secret_id IS NOT NULL AND device_id IS NOT NULL
  ORDER BY created_at ASC, id ASC LIMIT 1
$$;

-- ---------------------------------------------------------------------------
-- Withdrawal payouts
-- ---------------------------------------------------------------------------
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payout_requested_at TIMESTAMPTZ;
-- A payout attempt reached the PIN step without a confirmed result: the
-- money may have gone out. Reserved funds stay reserved until a manager
-- decides (retry or fail, both only after confirming it was not paid).
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS payout_review BOOLEAN NOT NULL DEFAULT false;

-- Dalab 057 reseller_withdrawal_dial_attempts.
CREATE TABLE IF NOT EXISTS public.payout_dial_attempts (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id           UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  agent_id           UUID REFERENCES public.users(id) ON DELETE SET NULL,
  device_id          TEXT,
  sim_slot           INTEGER,
  wallet_phone       TEXT,
  attempt_number     INTEGER NOT NULL,
  step1_ussd_string  TEXT NOT NULL,
  status             TEXT NOT NULL DEFAULT 'pending'
                       CHECK (status IN ('pending', 'step1_success', 'success', 'failed', 'ambiguous')),
  step1_response     TEXT,
  step2_response     TEXT,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at       TIMESTAMPTZ,
  UNIQUE (order_id, attempt_number)
);
-- At most one unfinished attempt per order, and one success.
CREATE UNIQUE INDEX IF NOT EXISTS idx_payout_attempts_one_open
  ON public.payout_dial_attempts (order_id) WHERE status IN ('pending', 'step1_success');
CREATE UNIQUE INDEX IF NOT EXISTS idx_payout_attempts_one_success
  ON public.payout_dial_attempts (order_id) WHERE status = 'success';
ALTER TABLE public.payout_dial_attempts ENABLE ROW LEVEL SECURITY;

-- The carrier's "you transferred $X to NUMBER" SMS, kept whether or not it
-- completed a withdrawal.
CREATE TABLE IF NOT EXISTS public.payout_confirmations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id        UUID REFERENCES public.users(id) ON DELETE SET NULL,
  provider        TEXT,
  receiver_phone  TEXT NOT NULL,
  amount          NUMERIC(10,2) NOT NULL,
  raw_text        TEXT,
  order_id        UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  result          TEXT NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payout_confirmations ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.order_audit(
  p_order_id uuid, p_action text, p_before jsonb, p_after jsonb, p_actor uuid DEFAULT auth.uid()
)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.audit(p_actor, (SELECT role FROM public.users WHERE id = p_actor), p_action, 'order', p_order_id::text, p_before, p_after)
$$;

CREATE OR REPLACE FUNCTION private.payout_pin(p_method public.order_method)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = (private.payout_wallet(p_method)).pin_secret_id
$$;

CREATE OR REPLACE FUNCTION private.scrub_pin(p_text text, p_pin text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_text IS NULL OR p_pin IS NULL OR p_pin = '' THEN p_text ELSE replace(p_text, p_pin, '••••') END
$$;

-- The PIN may have reached the carrier: hold the reserved funds for review.
CREATE OR REPLACE FUNCTION private.payout_to_review(p_order_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE public.orders SET payout_review = true, failure_reason = p_reason, updated_at = now()
  WHERE id = p_order_id AND status = 'processing';
  IF FOUND THEN
    PERFORM private.order_audit(p_order_id, 'withdrawal_payout_needs_review', NULL, jsonb_build_object('reason', p_reason));
  END IF;
END
$$;

-- Whether any attempt for the order got to the PIN step (step2_response is
-- always set there; step 1 never sends the PIN).
CREATE OR REPLACE FUNCTION private.payout_pin_reached(p_order_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = p_order_id AND step2_response IS NOT NULL)
$$;

-- An attempt that never reported (app killed mid-dial, phone died) would
-- block the order forever. After 10 minutes (a dial takes under 90 seconds)
-- it is marked ambiguous and the order goes to review. completed_at is set
-- so the carrier's payout SMS can still complete it.
CREATE OR REPLACE FUNCTION private.expire_interrupted_payouts()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a record;
  n int := 0;
BEGIN
  FOR a IN
    SELECT da.id, da.order_id FROM public.payout_dial_attempts da
    JOIN public.orders o ON o.id = da.order_id
    WHERE da.status IN ('pending', 'step1_success') AND da.created_at < now() - interval '10 minutes'
    FOR UPDATE OF da, o SKIP LOCKED
  LOOP
    UPDATE public.payout_dial_attempts
    SET status = 'ambiguous', completed_at = now(),
        step2_response = 'Interrupted: the phone never reported this payout''s result'
    WHERE id = a.id;
    PERFORM private.payout_to_review(a.order_id, 'Payout interrupted: no result reported by the payout phone');
    n := n + 1;
  END LOOP;
  RETURN n;
END
$$;

-- ---------------------------------------------------------------------------
-- Deposit verification (Dalab findMatchingResellerDeposit)
-- ---------------------------------------------------------------------------

-- Dalab's device/SIM guard: once Baari's wallet for this method is set to an
-- agent phone (and SIM), only SMS that arrived there count.
CREATE OR REPLACE FUNCTION private.sms_device_reason(s public.sms_logs, p_method public.order_method)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w record;
  v_any boolean := false;
  v_slots int;
BEGIN
  FOR w IN SELECT device_id, sim_slot FROM public.payout_wallets WHERE method = p_method AND device_id IS NOT NULL LOOP
    v_any := true;
    IF w.device_id = s.device_id THEN
      IF w.sim_slot IS NULL OR w.sim_slot = s.sim_slot THEN
        RETURN NULL;
      END IF;
      IF s.sim_slot IS NULL THEN
        SELECT count(DISTINCT sim_slot) INTO v_slots FROM public.payout_wallets
        WHERE device_id = w.device_id AND sim_slot IS NOT NULL;
        IF v_slots <= 1 THEN
          RETURN NULL; -- one SIM in use on that phone: the slot can't be confused
        END IF;
      END IF;
    END IF;
  END LOOP;
  IF NOT v_any THEN
    RETURN NULL; -- no phone set yet (Dalab's permissive fallback)
  END IF;
  RETURN format('expects the %s wallet''s phone/SIM, SMS arrived on device %s slot %s',
    p_method, COALESCE(s.device_id, '(unknown)'), COALESCE(s.sim_slot::text, '(unresolved)'));
END
$$;

-- Tries to match one stored SMS to a pending wallet deposit. Never credits
-- unless exactly one order fits.
CREATE OR REPLACE FUNCTION private.match_sms_log(p_sms_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sms_logs;
  v_method public.order_method;
  v_key text;
  v_cents bigint;
  v_dep uuid[];
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
  SELECT COALESCE(array_agg(id ORDER BY created_at), '{}') INTO v_dep FROM (
    SELECT o2.id, o2.created_at FROM public.orders o2
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

  IF array_length(v_dep, 1) > 1 THEN
    v_reason := format('Ambiguous: %s deposits fit this payment (%s) -- needs a manager',
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
  PERFORM private.expire_interrupted_payouts();
  RETURN v_matched;
END
$$;

-- Agent: payment SMS upload (Dalab POST /agent/sms-logs).
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
        'matchStatus', v_existing.match_status, 'orderId', v_existing.matched_order_id);
    END IF;
  END IF;

  INSERT INTO public.sms_logs (agent_id, device_id, sender, body, parsed_provider, parsed_amount, parsed_phone,
                               transaction_ref, sim_slot, received_at)
  VALUES (v_agent, p_device_id, p_sender, p_body, p_parsed_provider, v_amount, p_parsed_phone, v_ref, p_sim_slot, v_received)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  -- Duplicate guard 2: same sender + body in the same minute.
  IF v_id IS NULL THEN
    SELECT * INTO v_existing FROM public.sms_logs
    WHERE (v_ref IS NOT NULL AND transaction_ref = v_ref)
       OR (sender = p_sender AND body = p_body
           AND date_trunc('minute', received_at AT TIME ZONE 'UTC') = date_trunc('minute', v_received AT TIME ZONE 'UTC'))
    LIMIT 1;
    RETURN jsonb_build_object('id', v_existing.id, 'status', 'already_processed',
      'matchStatus', v_existing.match_status, 'orderId', v_existing.matched_order_id);
  END IF;

  v_result := private.match_sms_log(v_id);
  RETURN jsonb_build_object('id', v_id, 'status', 'new', 'matchStatus', v_result ->> 'status',
    'orderId', v_result ->> 'orderId', 'reason', v_result ->> 'reason');
END
$$;

-- ---------------------------------------------------------------------------
-- Agent phone: withdrawal payouts (Dalab ResellerWithdrawal* + exchange
-- payout engine)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.payout_order_json(o public.orders)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', o.id, 'orderCode', o.order_code, 'method', o.method, 'status', o.status,
    'phoneNumber', o.phone_number, 'amount', private.money(o.amount_cents),
    'payoutAmount', private.money(o.net_cents), 'payoutReview', o.payout_review,
    'failureReason', o.failure_reason, 'transactionRef', o.transaction_ref,
    'createdAt', o.created_at, 'completedAt', o.completed_at,
    'customerName', u.name, 'customerPhone', u.phone,
    'payoutDeviceId', w.device_id, 'payoutSimSlot', w.sim_slot, 'payoutWalletPhone', w.phone_number,
    'hasDialAttempt', EXISTS (SELECT 1 FROM public.payout_dial_attempts a WHERE a.order_id = o.id),
    'payoutRequested', o.payout_requested_at IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM public.payout_dial_attempts a WHERE a.order_id = o.id AND a.created_at >= o.payout_requested_at)
  )
  FROM (SELECT 1) one
  LEFT JOIN public.users u ON u.id = o.customer_id
  LEFT JOIN LATERAL (SELECT * FROM private.payout_wallet(o.method)) w ON true
$$;

-- Withdrawals this phone can pay automatically: EVC Plus / eDahab, a payout
-- wallet with a PIN on an agent phone, never dialed (or a manager asked for
-- another try), not in review.
CREATE OR REPLACE FUNCTION public.agent_payout_queue()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.payout_order_json(o) ORDER BY o.created_at ASC)
    FROM public.orders o
    WHERE o.direction = 'withdraw' AND o.method IN ('evc_plus', 'edahab') AND NOT o.payout_review
      AND (o.status = 'pending' OR (o.status = 'processing' AND o.payout_requested_at IS NOT NULL))
      AND (private.payout_wallet(o.method)).id IS NOT NULL
  ), '[]'::jsonb);
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
  v_ussd := '*' || private.payout_dial_prefix(o.method) || '*' || private.phone_key(o.phone_number)
            || '*' || private.ussd_amount(o.net_cents / 100.0) || '#';
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

-- Step 1 (number + amount entered, before the PIN). A failure here sent
-- nothing, so the withdrawal fails and the reserved funds are released.
CREATE OR REPLACE FUNCTION public.agent_payout_report_step1(
  p_attempt_id uuid, p_status text, p_response text DEFAULT NULL, p_is_final boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  a public.payout_dial_attempts;
  o public.orders;
BEGIN
  IF p_status NOT IN ('step1_success', 'failed', 'ambiguous') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be step1_success, failed or ambiguous');
  END IF;
  UPDATE public.payout_dial_attempts SET status = p_status, step1_response = left(p_response, 2000),
    completed_at = CASE WHEN p_status = 'step1_success' THEN NULL ELSE now() END
  WHERE id = p_attempt_id AND status = 'pending'
  RETURNING * INTO a;
  IF a.id IS NULL THEN
    SELECT * INTO a FROM public.payout_dial_attempts WHERE id = p_attempt_id;
    IF a.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Dial attempt not found');
    END IF;
    RETURN to_jsonb(a);
  END IF;
  IF p_status <> 'step1_success' AND p_is_final THEN
    SELECT * INTO o FROM public.orders WHERE id = a.order_id;
    IF o.status IN ('pending', 'processing') AND NOT private.payout_pin_reached(o.id) THEN
      PERFORM private.fail_order(o.id, 'Payout failed before the PIN step: ' || COALESCE(left(p_response, 200), p_status), v_agent, 'agent');
    END IF;
  END IF;
  RETURN to_jsonb(a);
END
$$;

-- Step 2 (PIN submitted; the carrier's answer). Success completes the
-- withdrawal (debit). Anything else may still have sent money: review.
CREATE OR REPLACE FUNCTION public.agent_payout_report_step2(
  p_attempt_id uuid, p_status text, p_response text DEFAULT NULL, p_is_final boolean DEFAULT true
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
  a public.payout_dial_attempts;
  o public.orders;
  v_text text;
BEGIN
  IF p_status NOT IN ('success', 'failed', 'ambiguous') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be success, failed or ambiguous');
  END IF;
  SELECT * INTO a FROM public.payout_dial_attempts WHERE id = p_attempt_id;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Dial attempt not found');
  END IF;
  o := private.lock_order(a.order_id);
  v_text := COALESCE(private.scrub_pin(left(p_response, 2000), private.payout_pin(o.method)), '(no response text)');
  UPDATE public.payout_dial_attempts SET status = p_status, step2_response = v_text, completed_at = now()
  WHERE id = p_attempt_id
    AND (status IN ('pending', 'step1_success')
         -- A late (queued) success for an attempt the 10-minute expiry
         -- marked interrupted, while no newer attempt exists.
         OR (p_status = 'success' AND status = 'ambiguous' AND step2_response LIKE 'Interrupted:%'
             AND attempt_number = (SELECT max(attempt_number) FROM public.payout_dial_attempts WHERE order_id = a.order_id)))
  RETURNING * INTO a;
  IF a.id IS NULL THEN
    SELECT * INTO a FROM public.payout_dial_attempts WHERE id = p_attempt_id;
    RETURN to_jsonb(a);
  END IF;

  IF p_status = 'success' THEN
    IF o.status IN ('pending', 'processing') THEN
      o := private.complete_withdraw_order(o.id, 'USSD-' || left(a.id::text, 8), v_agent, 'agent');
      UPDATE public.orders SET payout_review = false, failure_reason = NULL WHERE id = o.id;
      PERFORM private.order_audit(o.id, 'withdrawal_payout_completed', NULL, jsonb_build_object(
        'status', 'completed', 'payoutProvider', o.method, 'payoutAmount', private.money(o.net_cents),
        'payoutDestination', o.phone_number, 'attempt', a.attempt_number, 'carrierResponse', v_text), v_agent);
    END IF;
  ELSIF p_is_final THEN
    PERFORM private.payout_to_review(o.id, 'Payout ' || p_status || ' after the PIN: ' || left(v_text, 200));
  END IF;
  RETURN to_jsonb(a);
END
$$;

-- The payout phone's own "you transferred $X to NUMBER" SMS. Completes only
-- a withdrawal whose payout was dialed before the SMS arrived.
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
  v_text text;
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
  ELSIF NOT EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id AND completed_at IS NOT NULL) THEN
    v_result := 'ignored_no_dial_attempt';
    PERFORM private.order_audit(o.id, 'withdrawal_payout_sms_ignored_no_attempt', NULL, jsonb_build_object('text', left(p_raw_text, 500)), v_agent);
  ELSE
    v_text := private.scrub_pin(left(p_raw_text, 2000), private.payout_pin(o.method));
    UPDATE public.payout_dial_attempts SET status = 'success', step2_response = COALESCE(v_text, step2_response), completed_at = now()
    WHERE order_id = o.id AND status <> 'success'
      AND attempt_number = (SELECT max(attempt_number) FROM public.payout_dial_attempts WHERE order_id = o.id);
    o := private.complete_withdraw_order(o.id, COALESCE(p_reference, 'SMS-PAYOUT'), v_agent, 'agent');
    UPDATE public.orders SET payout_review = false, failure_reason = NULL WHERE id = o.id;
    PERFORM private.order_audit(o.id, 'withdrawal_completed_via_payout_sms', NULL, jsonb_build_object(
      'status', 'completed', 'payoutProvider', COALESCE(p_provider, o.method::text), 'payoutAmount', private.money(v_cents),
      'payoutDestination', o.phone_number, 'payoutReference', p_reference, 'confirmationText', v_text), v_agent);
    v_result := 'completed';
  END IF;

  INSERT INTO public.payout_confirmations (agent_id, provider, receiver_phone, amount, raw_text, order_id, result)
  VALUES (v_agent, p_provider, p_receiver_phone, v_cents / 100.0, left(p_raw_text, 2000), o.id, v_result);
  RETURN jsonb_build_object('matched', o.id IS NOT NULL, 'orderId', o.id, 'result', v_result);
END
$$;

-- A withdrawal whose payout may have reached the carrier can't be failed
-- (funds released) without confirming the money was not sent.
DROP FUNCTION IF EXISTS public.agent_withdrawal_fail(uuid, text);
CREATE OR REPLACE FUNCTION public.agent_withdrawal_fail(p_order_id uuid, p_reason text, p_confirmed_not_paid boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  o public.orders := private.lock_order(p_order_id);
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  IF EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id AND status IN ('pending', 'step1_success')) THEN
    PERFORM private.raise_api(409, 'PAYOUT_RUNNING', 'An automatic payout for this order is still running');
  END IF;
  IF private.payout_pin_reached(o.id) AND NOT COALESCE(p_confirmed_not_paid, false) THEN
    PERFORM private.raise_api(409, 'CONFIRM_NOT_PAID',
      'An automatic payout may have sent this money. Check the payout wallet''s history, then confirm it was not paid.');
  END IF;
  o := private.fail_order(p_order_id, p_reason, v_id, 'agent');
  UPDATE public.orders SET payout_review = false WHERE id = o.id;
  RETURN private.agent_order_json(o);
END
$$;

-- ---------------------------------------------------------------------------
-- Management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manage_payment_sms(p_status text DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', s.id, 'sender', s.sender, 'body', s.body,
      'provider', s.parsed_provider, 'amount', s.parsed_amount::text, 'phone', s.parsed_phone,
      'transactionRef', s.transaction_ref, 'receivedAt', s.received_at, 'matchStatus', s.match_status,
      'orderId', s.matched_order_id, 'orderCode', o.order_code,
      'reason', s.match_failure_reason, 'deviceId', s.device_id, 'simSlot', s.sim_slot) ORDER BY s.received_at DESC)
    FROM (SELECT * FROM public.sms_logs WHERE p_status IS NULL OR match_status = p_status
          ORDER BY received_at DESC LIMIT least(greatest(COALESCE(p_limit, 100), 1), 500)) s
    LEFT JOIN public.orders o ON o.id = s.matched_order_id), '[]'::jsonb);
END
$$;

-- Assign an ambiguous / unmatched payment SMS to a pending deposit by hand.
-- Same method and amount as automatic matching; the phone may differ (the
-- manager may know the customer paid from another number).
CREATE OR REPLACE FUNCTION public.manage_resolve_payment_sms(p_sms_id uuid, p_order_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  s public.sms_logs;
  o public.orders;
  v_ref text;
BEGIN
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id FOR UPDATE;
  IF s.id IS NULL OR s.match_status NOT IN ('unmatched', 'ambiguous') THEN
    PERFORM private.raise_api(409, 'INVALID_STATE', 'This SMS is already matched');
  END IF;
  SELECT * INTO o FROM public.orders WHERE order_code = upper(btrim(p_order_code)) FOR UPDATE;
  IF o.id IS NULL OR o.direction <> 'deposit' OR o.status <> 'pending' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only a pending deposit can take a payment');
  END IF;
  IF s.parsed_amount IS NULL OR round(s.parsed_amount * 100) <> o.amount_cents
     OR private.provider_method(s.parsed_provider) IS DISTINCT FROM o.method THEN
    PERFORM private.raise_api(409, 'PAYMENT_MISMATCH',
      format('This SMS is not a %s payment of $%s', o.method, private.money(o.amount_cents)));
  END IF;
  v_ref := COALESCE(s.transaction_ref, 'SMS-' || s.id::text);
  o := private.complete_deposit_order(o.id, v_ref, v_id, private.app_role());
  UPDATE public.sms_logs SET match_status = 'matched', matched_order_id = o.id, match_failure_reason = NULL WHERE id = s.id;
  PERFORM private.order_audit(o.id, 'deposit_payment_assigned_by_manager', NULL,
    jsonb_build_object('smsLogId', s.id, 'amount', s.parsed_amount, 'transactionRef', s.transaction_ref));
  RETURN private.customer_order_json(o);
END
$$;

-- Withdrawals with automatic payout activity (running, in review, recent).
CREATE OR REPLACE FUNCTION public.manage_payouts(p_review_only boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.payout_order_json(o) ORDER BY o.payout_review DESC, o.updated_at DESC)
    FROM (SELECT * FROM public.orders o2
          WHERE o2.direction = 'withdraw'
            AND (o2.payout_review OR (NOT COALESCE(p_review_only, false)
                 AND EXISTS (SELECT 1 FROM public.payout_dial_attempts a WHERE a.order_id = o2.id)))
          ORDER BY o2.payout_review DESC, o2.updated_at DESC LIMIT 200) o
  ), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_payout(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.orders;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id;
  IF o.id IS NULL OR o.direction <> 'withdraw' THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Withdrawal not found');
  END IF;
  RETURN private.payout_order_json(o) || jsonb_build_object(
    'dialAttempts', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', a.id, 'attemptNumber', a.attempt_number,
        'status', a.status, 'step1UssdString', a.step1_ussd_string, 'step1Response', a.step1_response,
        'step2Response', a.step2_response, 'deviceId', a.device_id, 'simSlot', a.sim_slot, 'walletPhone', a.wallet_phone,
        'createdAt', a.created_at, 'completedAt', a.completed_at) ORDER BY a.attempt_number)
      FROM public.payout_dial_attempts a WHERE a.order_id = o.id), '[]'::jsonb),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object('action', l.action, 'after', l.after_json, 'createdAt', l.created_at)
        ORDER BY l.created_at) FROM public.audit_logs l WHERE l.entity_type = 'order' AND l.entity_id = o.id::text), '[]'::jsonb)
  );
END
$$;

-- Another automatic try. Needs "confirmed not paid" whenever an earlier
-- attempt reached the PIN step.
CREATE OR REPLACE FUNCTION public.manage_payout_retry(p_order_id uuid, p_confirmed_not_paid boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.orders := private.lock_order(p_order_id);
BEGIN
  IF o.direction <> 'withdraw' OR o.status <> 'processing' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Only a withdrawal being paid out can be retried');
  END IF;
  IF EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id AND status = 'success')
     OR EXISTS (SELECT 1 FROM public.payout_confirmations WHERE order_id = o.id AND result = 'completed') THEN
    PERFORM private.raise_api(409, 'ALREADY_PAID', 'A payout for this order already went through');
  END IF;
  IF EXISTS (SELECT 1 FROM public.payout_dial_attempts WHERE order_id = o.id AND status IN ('pending', 'step1_success')) THEN
    PERFORM private.raise_api(409, 'PAYOUT_RUNNING', 'An automatic payout for this order is still running');
  END IF;
  IF private.payout_pin_reached(o.id) AND NOT COALESCE(p_confirmed_not_paid, false) THEN
    PERFORM private.raise_api(409, 'CONFIRM_NOT_PAID',
      'The last payout attempt had an unclear result. Check the payout wallet''s history first, then confirm it was not paid.');
  END IF;
  UPDATE public.orders SET payout_review = false, failure_reason = NULL, payout_requested_at = now(), updated_at = now()
  WHERE id = o.id RETURNING * INTO o;
  PERFORM private.order_audit(o.id, 'withdrawal_payout_retry', NULL, jsonb_build_object('confirmedNotPaid', p_confirmed_not_paid));
  RETURN private.payout_order_json(o);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_payout_wallets()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', w.id, 'method', w.method, 'phoneNumber', w.phone_number,
      'deviceId', w.device_id, 'simSlot', w.sim_slot, 'hasPin', w.pin_secret_id IS NOT NULL,
      'paysWithdrawals', w.id = (private.payout_wallet(w.method)).id) ORDER BY w.created_at)
    FROM public.payout_wallets w), '[]'::jsonb);
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
  w public.payout_wallets;
BEGIN
  IF v_method NOT IN ('evc_plus', 'edahab') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Automatic payouts support EVC Plus and eDahab wallets');
  END IF;
  v_phone := private.validate_mobile(p_phone_number, v_method, 'wallet number');
  IF p_sim_slot IS NOT NULL AND p_sim_slot NOT IN (1, 2) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'SIM slot must be 1 or 2');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.payout_wallets (method, phone_number, device_id, sim_slot, created_by)
    VALUES (v_method, v_phone, NULLIF(p_device_id, ''), p_sim_slot, v_id) RETURNING * INTO w;
  ELSE
    UPDATE public.payout_wallets
    SET method = v_method, phone_number = v_phone, device_id = NULLIF(p_device_id, ''), sim_slot = p_sim_slot, updated_at = now()
    WHERE id = p_id RETURNING * INTO w;
    IF w.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet not found');
    END IF;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'payout_wallet.save', 'payout_wallet', w.id::text, NULL,
    jsonb_build_object('method', w.method, 'phoneNumber', w.phone_number, 'deviceId', w.device_id, 'simSlot', w.sim_slot));
  RETURN jsonb_build_object('id', w.id, 'method', w.method, 'phoneNumber', w.phone_number, 'deviceId', w.device_id,
    'simSlot', w.sim_slot, 'hasPin', w.pin_secret_id IS NOT NULL);
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
  IF w.pin_secret_id IS NOT NULL THEN
    DELETE FROM vault.secrets WHERE id = w.pin_secret_id;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'payout_wallet.delete', 'payout_wallet', w.id::text);
END
$$;

CREATE OR REPLACE FUNCTION public.manage_set_payout_wallet_pin(p_id uuid, p_pin text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  w public.payout_wallets;
BEGIN
  IF p_pin IS NULL OR p_pin !~ '^\d{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The PIN must be 4 to 8 digits');
  END IF;
  SELECT * INTO w FROM public.payout_wallets WHERE id = p_id FOR UPDATE;
  IF w.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet not found');
  END IF;
  UPDATE public.payout_wallets
  SET pin_secret_id = private.store_secret(w.pin_secret_id, p_pin, 'payout_wallet:' || w.id || ':pin'), updated_at = now()
  WHERE id = w.id;
  PERFORM private.audit(v_id, private.app_role(), 'payout_wallet.set_pin', 'payout_wallet', w.id::text);
  RETURN jsonb_build_object('id', w.id, 'hasPin', true);
END
$$;

-- Grants: signed-in users only, as for every other API function.
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      AND p.proname ~ '^(agent_ingest_payment_sms|agent_payout_|agent_withdrawal_fail|manage_payment_sms|manage_resolve_payment_sms|manage_payout|manage_save_payout_wallet|manage_delete_payout_wallet|manage_set_payout_wallet_pin)'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.app_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_staff() TO anon, authenticated;
