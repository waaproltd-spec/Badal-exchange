-- Fully automatic withdrawals: safeguards and a production switch.
--
-- Sahal (mymerchant.golis.so) has no official payout API, so Badal Exchange
-- does not send money from the Sahal merchant account. Automatic payouts stay
-- on the Agent App's EVC Plus / eDahab payout phone (20261008000100): the
-- phone dials the carrier's own transfer (number + amount, then the PIN from
-- Vault), the carrier shows the receiver's name and confirms, and the
-- withdrawal completes only on the carrier's success screen or its "you
-- transferred" SMS; anything unclear goes to manager review and is never
-- refunded or sent again on its own.
--
-- Added here, per method (payout_auto_settings):
--   mode         'off' (default) | 'test' | 'live'. Off: nothing is dialed.
--                Test: only withdrawals of at most $0.10 (net) are dialed.
--                Live: everything within the limits below. Live can only be
--                switched on after a $0.10 test payout from the current
--                payout wallet and phone completed AND its "you transferred"
--                SMS arrived; changing the wallet or phone needs a new test.
--   daily limit  total paid automatically per day (Mogadishu time).
--   min balance  the payout wallet must keep at least this much after the
--                payout. The balance is read from the wallet's own SMS
--                ("Haraagaagu waa $X") on the payout phone/SIM, less every
--                payout dialed since; a manager may enter it by hand. Live
--                payouts wait while the balance is unknown.
-- A withdrawal held by a safeguard is not dialed and stays pending: its
-- funds stay reserved and it can still be paid by hand.

CREATE TABLE IF NOT EXISTS public.payout_auto_settings (
  method              public.order_method PRIMARY KEY CHECK (method IN ('evc_plus', 'edahab')),
  mode                TEXT NOT NULL DEFAULT 'off' CHECK (mode IN ('off', 'test', 'live')),
  daily_limit_cents   BIGINT NOT NULL DEFAULT 50000 CHECK (daily_limit_cents >= 0),
  min_balance_cents   BIGINT NOT NULL DEFAULT 500 CHECK (min_balance_cents >= 0),
  test_amount_cents   BIGINT NOT NULL DEFAULT 10 CHECK (test_amount_cents > 0),
  test_started_at     TIMESTAMPTZ,
  live_wallet_id      UUID,
  live_device_id      TEXT,
  live_test_order_id  UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  live_at             TIMESTAMPTZ,
  updated_by          UUID REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payout_auto_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payout_auto_settings FROM PUBLIC, anon, authenticated;
INSERT INTO public.payout_auto_settings (method) VALUES ('evc_plus'), ('edahab') ON CONFLICT DO NOTHING;

-- Balance readings of the payout wallets.
CREATE TABLE IF NOT EXISTS public.payout_wallet_balances (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id      UUID NOT NULL REFERENCES public.payout_wallets(id) ON DELETE CASCADE,
  balance_cents  BIGINT NOT NULL,
  seen_at        TIMESTAMPTZ NOT NULL,
  source         TEXT NOT NULL CHECK (source IN ('sms', 'payout_sms', 'manager')),
  created_by     UUID REFERENCES public.users(id) ON DELETE SET NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payout_wallet_balances_wallet ON public.payout_wallet_balances (wallet_id, seen_at DESC);
ALTER TABLE public.payout_wallet_balances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payout_wallet_balances FROM PUBLIC, anon, authenticated;

-- The phone that uploaded a payout SMS (its balance only counts from the
-- payout wallet's own phone).
ALTER TABLE public.payout_confirmations ADD COLUMN IF NOT EXISTS device_id TEXT;
ALTER TABLE public.payout_confirmations ADD COLUMN IF NOT EXISTS received_at TIMESTAMPTZ;

-- "Haraagaagu waa $4.95." / "Haraagagu waa $2.50" / "Balance: $3" -> cents.
CREATE OR REPLACE FUNCTION private.balance_from_text(p_text text)
RETURNS bigint LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT round(replace(m[1], ',', '.')::numeric * 100)::bigint
  FROM (SELECT COALESCE(
      regexp_match(p_text, 'haraag[a-z]*\s+(?:waa|wa)\s*:?\s*\$?\s*([0-9]+(?:[.,][0-9]{1,4})?)', 'i'),
      regexp_match(p_text, 'balance\s*(?:is|:)?\s*\$?\s*([0-9]+(?:[.,][0-9]{1,4})?)', 'i')) AS m) x
  WHERE m IS NOT NULL
$$;

-- Keeps a balance reading when the SMS came from the method's payout wallet
-- (its phone, and its SIM when both are known).
CREATE OR REPLACE FUNCTION private.note_payout_balance(
  p_method public.order_method, p_device_id text, p_sim_slot int, p_text text, p_at timestamptz, p_source text
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w public.payout_wallets;
  v_cents bigint := private.balance_from_text(p_text);
BEGIN
  IF p_method IS NULL OR v_cents IS NULL OR p_device_id IS NULL THEN
    RETURN;
  END IF;
  w := private.payout_wallet(p_method);
  IF w.id IS NULL OR w.device_id IS DISTINCT FROM p_device_id
     OR (w.sim_slot IS NOT NULL AND p_sim_slot IS NOT NULL AND w.sim_slot <> p_sim_slot) THEN
    RETURN;
  END IF;
  INSERT INTO public.payout_wallet_balances (wallet_id, balance_cents, seen_at, source)
  VALUES (w.id, v_cents, COALESCE(p_at, now()), p_source);
END $$;

CREATE OR REPLACE FUNCTION private.sms_method(p_sender text, p_body text, p_provider text)
RETURNS public.order_method LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT COALESCE(private.provider_method(p_provider),
    CASE WHEN upper(COALESCE(p_sender, '')) IN ('192', 'EVCPLUS', '740') OR p_body ILIKE '%evcplus%' OR p_body ILIKE '%evc plus%' THEN 'evc_plus'
         WHEN p_sender ILIKE 'edahab%' OR p_body ILIKE '%edahab%' THEN 'edahab' END::public.order_method)
$$;

CREATE OR REPLACE FUNCTION private.sms_logs_note_balance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.note_payout_balance(private.sms_method(NEW.sender, NEW.body, NEW.parsed_provider),
    NEW.device_id, NEW.sim_slot, NEW.body, NEW.received_at, 'sms');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS sms_logs_note_balance ON public.sms_logs;
CREATE TRIGGER sms_logs_note_balance AFTER INSERT ON public.sms_logs
  FOR EACH ROW EXECUTE FUNCTION private.sms_logs_note_balance();

CREATE OR REPLACE FUNCTION private.payout_confirmations_note_balance()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.note_payout_balance(private.sms_method(NULL, NEW.raw_text, NEW.provider),
    NEW.device_id, NULL, NEW.raw_text, least(COALESCE(NEW.received_at, NEW.created_at), NEW.created_at), 'payout_sms');
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS payout_confirmations_note_balance ON public.payout_confirmations;
CREATE TRIGGER payout_confirmations_note_balance AFTER INSERT ON public.payout_confirmations
  FOR EACH ROW EXECUTE FUNCTION private.payout_confirmations_note_balance();

-- The payout wallet's balance: the last reading, less what was dialed after
-- it (withdrawals not failed). NULL when there is no reading.
CREATE OR REPLACE FUNCTION private.payout_balance(p_method public.order_method)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w public.payout_wallets := private.payout_wallet(p_method);
  b public.payout_wallet_balances;
  v_spent bigint;
BEGIN
  IF w.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO b FROM public.payout_wallet_balances WHERE wallet_id = w.id ORDER BY seen_at DESC, created_at DESC LIMIT 1;
  IF b.id IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(sum(o.net_cents), 0) INTO v_spent FROM public.orders o
  WHERE o.method = p_method AND o.direction = 'withdraw' AND o.status IN ('processing', 'completed')
    AND EXISTS (SELECT 1 FROM public.payout_dial_attempts a
                WHERE a.order_id = o.id AND a.wallet_phone = w.phone_number AND a.created_at > b.seen_at);
  RETURN jsonb_build_object('readingCents', b.balance_cents, 'seenAt', b.seen_at, 'source', b.source,
    'estimatedCents', b.balance_cents - v_spent);
END $$;

-- Paid automatically today (Mogadishu day): withdrawals first dialed today
-- that were not failed, other than p_except.
CREATE OR REPLACE FUNCTION private.payout_paid_today(p_method public.order_method, p_except uuid DEFAULT NULL)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(sum(o.net_cents), 0)::bigint FROM public.orders o
  WHERE o.method = p_method AND o.direction = 'withdraw' AND o.status IN ('processing', 'completed')
    AND o.id IS DISTINCT FROM p_except
    AND (SELECT min(a.created_at) FROM public.payout_dial_attempts a WHERE a.order_id = o.id)
        >= (date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu')
$$;

-- The $0.10 test that allows going live: a test-mode payout from the
-- current payout wallet and phone that completed, and whose "you
-- transferred" SMS (same receiver and amount) arrived after it was dialed.
CREATE OR REPLACE FUNCTION private.payout_test_order(p_method public.order_method)
RETURNS uuid LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT o.id
  FROM public.payout_auto_settings s
  CROSS JOIN LATERAL (SELECT * FROM private.payout_wallet(p_method)) w
  JOIN public.orders o ON o.method = p_method AND o.direction = 'withdraw' AND o.status = 'completed'
                       AND o.net_cents <= s.test_amount_cents
  JOIN public.payout_dial_attempts a ON a.order_id = o.id AND a.status = 'success'
                       AND a.created_at >= s.test_started_at
                       AND a.device_id = w.device_id AND a.wallet_phone = w.phone_number
  WHERE s.method = p_method AND s.test_started_at IS NOT NULL AND w.id IS NOT NULL
    AND EXISTS (SELECT 1 FROM public.payout_confirmations c
                WHERE private.phone_key(c.receiver_phone) = private.phone_key(o.phone_number)
                  AND round(c.amount * 100) = o.net_cents AND c.created_at >= a.created_at
                  AND COALESCE(private.provider_method(c.provider), p_method) = p_method)
  ORDER BY a.completed_at DESC
  LIMIT 1
$$;

-- Why a withdrawal must not be dialed now ({code, message}), else NULL.
CREATE OR REPLACE FUNCTION private.payout_block(o public.orders)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.payout_auto_settings;
  w public.payout_wallets := private.payout_wallet(o.method);
  v_label text := CASE o.method WHEN 'edahab' THEN 'eDahab' ELSE 'EVC Plus' END;
  v_bal jsonb;
BEGIN
  SELECT * INTO s FROM public.payout_auto_settings WHERE method = o.method;
  IF s.method IS NULL OR s.mode = 'off' THEN
    RETURN jsonb_build_object('code', 'AUTO_PAYOUT_OFF', 'message', 'Automatic ' || v_label || ' payouts are switched off');
  END IF;
  IF s.mode = 'test' AND o.net_cents > s.test_amount_cents THEN
    RETURN jsonb_build_object('code', 'TEST_MODE', 'message',
      format('Test mode: only a $%s test withdrawal is paid automatically', private.money(s.test_amount_cents)));
  END IF;
  IF s.mode = 'live' AND (s.live_wallet_id IS DISTINCT FROM w.id OR s.live_device_id IS DISTINCT FROM w.device_id) THEN
    RETURN jsonb_build_object('code', 'RETEST_NEEDED', 'message',
      'The payout wallet or phone changed after the test payout. Switch to Test and send a new $0.10 test.');
  END IF;
  IF private.payout_paid_today(o.method, o.id) + o.net_cents > s.daily_limit_cents THEN
    RETURN jsonb_build_object('code', 'DAILY_LIMIT', 'message',
      format('Daily automatic payout limit reached ($%s)', private.money(s.daily_limit_cents)));
  END IF;
  v_bal := private.payout_balance(o.method);
  IF v_bal IS NULL THEN
    IF s.mode = 'live' THEN
      RETURN jsonb_build_object('code', 'BALANCE_UNKNOWN', 'message',
        'The payout wallet''s balance is not known yet (no balance SMS on the payout phone)');
    END IF;
  ELSIF (v_bal ->> 'estimatedCents')::bigint - o.net_cents < s.min_balance_cents THEN
    RETURN jsonb_build_object('code', 'LOW_BALANCE', 'message',
      format('The payout wallet would go below its minimum balance ($%s)', private.money(s.min_balance_cents)));
  END IF;
  RETURN NULL;
END $$;

-- ---------------------------------------------------------------------------
-- The payout phone: only withdrawals the safeguards allow
-- ---------------------------------------------------------------------------
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
      AND private.payout_block(o) IS NULL
  ), '[]'::jsonb);
END
$$;

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
  v_ussd := '*' || private.payout_dial_prefix(o.method) || '*' || private.phone_key(o.phone_number)
            || '*' || private.ussd_amount(o.net_cents / 100.0) || '#';
  v_next := COALESCE(v_latest.attempt_number, 0) + 1;
  INSERT INTO public.payout_dial_attempts (order_id, agent_id, device_id, sim_slot, wallet_phone, attempt_number, step1_ussd_string)
  VALUES (o.id, v_agent, p_device_id, w.sim_slot, w.phone_number, v_next, v_ussd)
  RETURNING id INTO v_id;
  PERFORM private.order_audit(o.id, 'withdrawal_payout_dial_started', NULL,
    jsonb_build_object('attempt', v_next, 'payoutProvider', o.method, 'payoutAmount', private.money(o.net_cents),
      'payoutDestination', o.phone_number, 'payoutWallet', w.phone_number, 'deviceId', p_device_id, 'simSlot', w.sim_slot,
      'mode', (SELECT mode FROM public.payout_auto_settings WHERE method = o.method)), v_agent);
  RETURN jsonb_build_object('id', v_id, 'step1UssdString', v_ussd, 'simSlot', w.sim_slot, 'isNew', true,
    'pin', private.payout_pin(o.method));
END
$$;

-- The payout SMS now says which phone uploaded it (for the balance).
DROP FUNCTION IF EXISTS public.agent_payout_confirmation(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.agent_payout_confirmation(
  p_receiver_phone text, p_amount text, p_raw_text text DEFAULT NULL, p_provider text DEFAULT NULL,
  p_reference text DEFAULT NULL, p_received_at text DEFAULT NULL, p_device_id text DEFAULT NULL
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
    v_result := 'ignored_no_dial_attempt';
    PERFORM private.order_audit(o.id, 'withdrawal_payout_sms_ignored_no_attempt', NULL, jsonb_build_object('text', left(p_raw_text, 500)), v_agent);
  ELSE
    o := private.complete_withdraw_by_payout_sms(o.id, p_raw_text, p_provider, p_reference, v_agent);
    v_result := 'completed';
  END IF;

  INSERT INTO public.payout_confirmations (agent_id, provider, receiver_phone, amount, raw_text, order_id, result, device_id, received_at)
  VALUES (v_agent, p_provider, p_receiver_phone, v_cents / 100.0, left(p_raw_text, 2000), o.id, v_result,
          NULLIF(p_device_id, ''), v_received);
  RETURN jsonb_build_object('matched', o.id IS NOT NULL, 'orderId', o.id, 'result', v_result);
END
$$;

-- ---------------------------------------------------------------------------
-- Management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.auto_payout_json(p_method public.order_method)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'method', s.method, 'mode', s.mode,
    'dailyLimit', private.money(s.daily_limit_cents), 'minBalance', private.money(s.min_balance_cents),
    'testAmount', private.money(s.test_amount_cents),
    'paidToday', private.money(private.payout_paid_today(s.method)),
    'balance', CASE WHEN bb.b IS NOT NULL THEN private.money((bb.b ->> 'estimatedCents')::bigint) END,
    'balanceSeenAt', bb.b ->> 'seenAt', 'balanceSource', bb.b ->> 'source',
    'hasWallet', w.id IS NOT NULL, 'walletPhone', w.phone_number, 'walletDeviceId', w.device_id,
    'testStartedAt', s.test_started_at,
    'testPassed', t.id IS NOT NULL, 'testOrderCode', t.order_code,
    'liveAt', s.live_at,
    'liveNeedsRetest', s.mode = 'live' AND (s.live_wallet_id IS DISTINCT FROM w.id OR s.live_device_id IS DISTINCT FROM w.device_id),
    'waiting', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.method = s.method
                AND o.status = 'pending' AND NOT o.payout_review),
    'heldReason', (SELECT private.payout_block(o) ->> 'message' FROM public.orders o
                   WHERE o.direction = 'withdraw' AND o.method = s.method AND o.status = 'pending' AND NOT o.payout_review
                   ORDER BY o.created_at LIMIT 1))
  FROM public.payout_auto_settings s
  LEFT JOIN LATERAL (SELECT * FROM private.payout_wallet(s.method)) w ON true
  LEFT JOIN LATERAL (SELECT private.payout_balance(s.method) AS b) bb ON true
  LEFT JOIN LATERAL (SELECT oo.id, oo.order_code FROM public.orders oo WHERE oo.id = private.payout_test_order(s.method)) t ON true
  WHERE s.method = p_method
$$;

CREATE OR REPLACE FUNCTION public.manage_auto_payouts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.auto_payout_json(s.method) ORDER BY s.method)
                   FROM public.payout_auto_settings s), '[]'::jsonb);
END $$;

-- Mode (off / test / live) and limits (dollars; NULL keeps them).
CREATE OR REPLACE FUNCTION public.manage_set_auto_payout(
  p_method text, p_mode text DEFAULT NULL, p_daily_limit numeric DEFAULT NULL, p_min_balance numeric DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method, 'mobile_money');
  s public.payout_auto_settings;
  w public.payout_wallets;
  v_test uuid;
BEGIN
  SELECT * INTO s FROM public.payout_auto_settings WHERE method = v_method FOR UPDATE;
  IF s.method IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Automatic payouts support EVC Plus and eDahab');
  END IF;
  IF p_mode IS NOT NULL AND p_mode NOT IN ('off', 'test', 'live') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'mode must be off, test or live');
  END IF;
  IF p_daily_limit IS NOT NULL AND (p_daily_limit < 0 OR p_daily_limit > 100000) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The daily limit must be between $0 and $100000');
  END IF;
  IF p_min_balance IS NOT NULL AND (p_min_balance < 0 OR p_min_balance > 100000) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The minimum balance must be between $0 and $100000');
  END IF;

  IF p_mode = 'live' AND s.mode <> 'live' THEN
    w := private.payout_wallet(v_method);
    v_test := private.payout_test_order(v_method);
    IF s.mode <> 'test' OR v_test IS NULL THEN
      PERFORM private.raise_api(409, 'TEST_REQUIRED',
        format('Send a $%s test payout in Test mode first: it must complete and its "you transferred" SMS must arrive',
               private.money(s.test_amount_cents)));
    END IF;
    UPDATE public.payout_auto_settings SET live_wallet_id = w.id, live_device_id = w.device_id,
      live_test_order_id = v_test, live_at = now() WHERE method = v_method;
  ELSIF p_mode = 'test' AND s.mode <> 'test' THEN
    UPDATE public.payout_auto_settings SET test_started_at = now() WHERE method = v_method;
  END IF;

  UPDATE public.payout_auto_settings
  SET mode = COALESCE(p_mode, mode),
      daily_limit_cents = COALESCE(round(p_daily_limit * 100)::bigint, daily_limit_cents),
      min_balance_cents = COALESCE(round(p_min_balance * 100)::bigint, min_balance_cents),
      updated_by = v_id, updated_at = now()
  WHERE method = v_method RETURNING * INTO s;
  PERFORM private.audit(v_id, private.app_role(), 'auto_payout.update', 'payout_auto_settings', v_method::text, NULL,
    jsonb_build_object('mode', s.mode, 'dailyLimit', private.money(s.daily_limit_cents),
      'minBalance', private.money(s.min_balance_cents), 'liveTestOrderId', s.live_test_order_id));
  RETURN private.auto_payout_json(v_method);
END $$;

-- The payout wallet's balance as a manager read it on the phone.
CREATE OR REPLACE FUNCTION public.manage_set_payout_balance(p_method text, p_balance numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method, 'mobile_money');
  w public.payout_wallets := private.payout_wallet(v_method);
BEGIN
  IF w.id IS NULL THEN
    PERFORM private.raise_api(409, 'NOT_CONFIGURED', 'No payout wallet with a PIN is set up for this method');
  END IF;
  IF p_balance IS NULL OR p_balance < 0 OR p_balance > 1000000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the balance in dollars');
  END IF;
  INSERT INTO public.payout_wallet_balances (wallet_id, balance_cents, seen_at, source, created_by)
  VALUES (w.id, round(p_balance * 100), now(), 'manager', v_id);
  PERFORM private.audit(v_id, private.app_role(), 'auto_payout.set_balance', 'payout_wallet', w.id::text, NULL,
    jsonb_build_object('balance', private.money(round(p_balance * 100)::bigint)));
  RETURN private.auto_payout_json(v_method);
END $$;

REVOKE ALL ON FUNCTION private.balance_from_text(text), private.note_payout_balance(public.order_method, text, int, text, timestamptz, text),
  private.sms_method(text, text, text), private.sms_logs_note_balance(), private.payout_confirmations_note_balance(),
  private.payout_balance(public.order_method), private.payout_paid_today(public.order_method, uuid),
  private.payout_test_order(public.order_method), private.payout_block(public.orders),
  private.auto_payout_json(public.order_method) FROM PUBLIC, anon, authenticated;
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      AND p.proname IN ('agent_payout_queue', 'agent_payout_start_dial', 'agent_payout_confirmation',
                        'manage_auto_payouts', 'manage_set_auto_payout', 'manage_set_payout_balance')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END
$$;
