-- Golis, ZAAD and EVC Plus withdrawals sent automatically from Sahal.
--
-- The golis-merchant function already keeps a signed-in Sahal session. It
-- now also sends waiting withdrawals the way the portal's Customer Fund
-- Transfer page does (mymerchant.golis.so js/bundle.js, b2pfundTransferCtrl):
--   POST /api/account/find {type: 'internetwork', mobileNo}  -> ReceiverInfo.NAME, ISINTERNETWORKRECEIVER
--   POST /api/money/b2p {receiverMobile, receiverName, pin, amount, description, isInterNetwork}
--        resultCode 2001 -> transferInfo["Transfer-Id"]
-- The merchant PIN is the function's secret GOLIS_MERCHANT_PIN, never stored here.
--
-- Safeguards, like the phone's automatic payouts:
--   * Off by default. Test sends only a $0.10 withdrawal; Live opens once a
--     test transfer succeeded. A daily limit.
--   * One attempt per withdrawal, ever, and one transfer at a time. Refused
--     by Sahal before anything was sent: the withdrawal stays pending for an
--     agent. No clear answer: it is held "processing" and never resent; the
--     feed completes it when the transfer shows in Sahal's list, otherwise a
--     manager decides.
--   * A transfer the feed later reads back (same Sahal id) completes only
--     the withdrawal it was sent for, never another one with the same
--     number and amount.
-- While Sahal sends a method (not Off), the agent phone does not pay it
-- (payout_block), so no withdrawal is paid twice; eDahab stays with the
-- phone (*110).
CREATE TABLE IF NOT EXISTS public.sahal_payout_settings (
  id                BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  mode              TEXT NOT NULL DEFAULT 'off' CHECK (mode IN ('off', 'test', 'live')),
  methods           public.order_method[] NOT NULL DEFAULT ARRAY['golis', 'telesom', 'evc_plus']::public.order_method[],
  daily_limit_cents BIGINT NOT NULL DEFAULT 50000 CHECK (daily_limit_cents >= 0),
  test_amount_cents BIGINT NOT NULL DEFAULT 10 CHECK (test_amount_cents > 0),
  test_started_at   TIMESTAMPTZ,
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.sahal_payout_settings (id) VALUES (true) ON CONFLICT DO NOTHING;
ALTER TABLE public.sahal_payout_settings ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.sahal_payout_attempts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        UUID NOT NULL REFERENCES public.orders(id) ON DELETE CASCADE,
  status          TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'success', 'failed', 'ambiguous')),
  mode            TEXT NOT NULL,
  receiver_mobile TEXT NOT NULL,
  receiver_name   TEXT,
  amount_cents    BIGINT NOT NULL,
  transfer_id     TEXT,
  result_code     TEXT,
  reply           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS sahal_payout_attempts_order ON public.sahal_payout_attempts (order_id);
CREATE INDEX IF NOT EXISTS sahal_payout_attempts_transfer ON public.sahal_payout_attempts (transfer_id) WHERE transfer_id IS NOT NULL;
ALTER TABLE public.sahal_payout_attempts ENABLE ROW LEVEL SECURITY;

-- The receiver as typed in the portal: Golis numbers as is (905999914),
-- other networks' with their 0 (0610346060, 0638882065).
CREATE OR REPLACE FUNCTION private.sahal_mobile(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN left(private.phone_key(p_phone), 2) = '90' THEN '' ELSE '0' END || private.phone_key(p_phone)
$$;

-- "2", "0.1", "1.5": the amount as typed in the portal.
CREATE OR REPLACE FUNCTION private.sahal_amount(p_cents bigint)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_cents % 100 = 0 THEN (p_cents / 100)::text
              ELSE rtrim(to_char(p_cents / 100.0, 'FM999999990.00'), '0') END
$$;

-- Sent (or possibly sent) today, Mogadishu day.
CREATE OR REPLACE FUNCTION private.sahal_paid_today()
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(sum(amount_cents), 0)::bigint FROM public.sahal_payout_attempts
  WHERE status IN ('pending', 'success', 'ambiguous')
    AND created_at >= (date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu')
$$;

CREATE OR REPLACE FUNCTION private.sahal_test_passed()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.sahal_payout_attempts a, public.sahal_payout_settings s
    WHERE a.status = 'success' AND a.mode = 'test' AND a.amount_cents <= s.test_amount_cents
      AND s.test_started_at IS NOT NULL AND a.created_at >= s.test_started_at)
$$;

-- Holds a withdrawal whose transfer may have gone out: processing, never resent.
CREATE OR REPLACE FUNCTION private.sahal_hold(a public.sahal_payout_attempts, p_reply text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.orders := private.lock_order(a.order_id);
BEGIN
  UPDATE public.sahal_payout_attempts SET status = 'ambiguous', reply = left(p_reply, 1000), completed_at = now()
  WHERE id = a.id;
  IF o.status = 'pending' THEN
    PERFORM private.start_processing_withdraw(o.id, NULL, NULL);
  END IF;
  PERFORM private.order_audit(o.id, 'withdrawal_sahal_unclear', NULL,
    jsonb_build_object('attempt', a.id, 'receiver', a.receiver_mobile, 'amount', private.money(a.amount_cents),
                       'reply', left(p_reply, 500)), NULL);
END $$;

-- The next withdrawal to send, claimed for one attempt; NULL when none may go.
CREATE OR REPLACE FUNCTION public.sahal_payout_next()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sahal_payout_settings;
  o public.orders;
  a public.sahal_payout_attempts;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id FOR UPDATE;
  -- A run that died after claiming: its transfer may have gone out.
  FOR a IN SELECT * FROM public.sahal_payout_attempts WHERE status = 'pending' AND created_at < now() - interval '5 minutes' LOOP
    PERFORM private.sahal_hold(a, 'No result was reported for this transfer.');
  END LOOP;
  IF s.mode = 'off' OR (s.mode = 'live' AND NOT private.sahal_test_passed()) THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM public.sahal_payout_attempts WHERE status = 'pending') THEN
    RETURN NULL;
  END IF;
  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'withdraw' AND x.method = ANY (s.methods) AND x.status = 'pending'
    AND NOT COALESCE(x.payout_review, false) AND x.created_at > now() - interval '3 days'
    AND (s.mode = 'live' OR x.net_cents <= s.test_amount_cents)
    AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = x.id)
    AND NOT EXISTS (SELECT 1 FROM public.payout_dial_attempts y WHERE y.order_id = x.id)
  ORDER BY x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL OR private.sahal_paid_today() + o.net_cents > s.daily_limit_cents THEN
    RETURN NULL;
  END IF;
  INSERT INTO public.sahal_payout_attempts (order_id, mode, receiver_mobile, amount_cents)
  VALUES (o.id, s.mode, private.sahal_mobile(o.phone_number), o.net_cents)
  RETURNING * INTO a;
  PERFORM private.order_audit(o.id, 'withdrawal_sahal_started', NULL,
    jsonb_build_object('attempt', a.id, 'receiver', a.receiver_mobile, 'amount', private.money(a.amount_cents), 'mode', s.mode), NULL);
  RETURN jsonb_build_object('attemptId', a.id, 'orderCode', o.order_code, 'receiverMobile', a.receiver_mobile,
    'amount', private.sahal_amount(a.amount_cents), 'description', o.order_code);
END $$;

-- What Sahal answered. success: sent (completes the withdrawal); failed:
-- refused before anything was sent (the withdrawal waits for an agent);
-- ambiguous: unknown (held, never resent).
CREATE OR REPLACE FUNCTION public.sahal_payout_report(
  p_attempt_id uuid, p_status text, p_receiver_name text DEFAULT NULL, p_transfer_id text DEFAULT NULL,
  p_result_code text DEFAULT NULL, p_reply text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.sahal_payout_attempts;
  o public.orders;
  v_id text := NULLIF(btrim(COALESCE(p_transfer_id, '')), '');
BEGIN
  PERFORM private.require_service();
  IF p_status NOT IN ('success', 'failed', 'ambiguous') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be success, failed or ambiguous');
  END IF;
  SELECT * INTO a FROM public.sahal_payout_attempts WHERE id = p_attempt_id FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Attempt not found');
  END IF;
  IF a.status <> 'pending' THEN
    RETURN jsonb_build_object('status', a.status, 'unchanged', true);
  END IF;
  UPDATE public.sahal_payout_attempts
  SET receiver_name = left(p_receiver_name, 200), result_code = left(p_result_code, 50)
  WHERE id = a.id RETURNING * INTO a;

  IF p_status = 'success' AND v_id IS NOT NULL THEN
    UPDATE public.sahal_payout_attempts
    SET status = 'success', transfer_id = v_id, reply = left(p_reply, 1000), completed_at = now()
    WHERE id = a.id;
    o := private.lock_order(a.order_id);
    IF o.status IN ('pending', 'processing') THEN
      o := private.complete_withdraw_order(o.id, 'Sahal ' || v_id, NULL, NULL);
    END IF;
    -- Already read back by the feed: tie that row to this withdrawal.
    UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = a.order_id, matched_at = now()
    WHERE provider = 'golis' AND transaction_id = v_id AND match_status IN ('new', 'unmatched');
  ELSIF p_status = 'failed' THEN
    UPDATE public.sahal_payout_attempts SET status = 'failed', reply = left(p_reply, 1000), completed_at = now()
    WHERE id = a.id;
    PERFORM private.order_audit(a.order_id, 'withdrawal_sahal_refused', NULL,
      jsonb_build_object('attempt', a.id, 'resultCode', p_result_code, 'reply', left(p_reply, 500)), NULL);
  ELSE
    -- Unclear, or "sent" without Sahal's transfer id.
    PERFORM private.sahal_hold(a, COALESCE(p_reply, 'No clear answer from Sahal'));
  END IF;
  SELECT * INTO a FROM public.sahal_payout_attempts WHERE id = a.id;
  RETURN jsonb_build_object('status', a.status);
END $$;

-- As before, except a transfer Sahal sent for one of our attempts completes
-- only that attempt's withdrawal (two identical withdrawals stay apart).
CREATE OR REPLACE FUNCTION private.merchant_match_out(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  o public.orders;
  v_attempt_order uuid;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') OR t.payer_phone IS NULL OR t.amount_cents IS NULL
     OR t.direction IS DISTINCT FROM 'out' THEN
    RETURN;
  END IF;
  SELECT order_id INTO v_attempt_order FROM public.sahal_payout_attempts WHERE transfer_id = t.transaction_id LIMIT 1;
  IF v_attempt_order IS NOT NULL THEN
    UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = v_attempt_order, matched_at = now()
    WHERE id = p_id;
    o := private.lock_order(v_attempt_order);
    IF o.status IN ('pending', 'processing') AND NOT COALESCE(o.payout_review, false) THEN
      PERFORM private.complete_withdraw_order(o.id, 'Sahal ' || t.transaction_id, NULL, NULL);
    END IF;
    RETURN;
  END IF;
  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'withdraw'
    AND x.method IN (SELECT method FROM public.payment_methods WHERE kind = 'mobile_money')
    AND right(regexp_replace(COALESCE(x.phone_number, ''), '\D', '', 'g'), 9) = right(t.payer_phone, 9)
    AND x.net_cents = t.amount_cents
    AND x.status IN ('pending', 'processing')
    AND NOT COALESCE(x.payout_review, false)
    AND x.created_at BETWEEN t.paid_at - interval '3 days' AND t.paid_at + interval '2 minutes'
    AND NOT EXISTS (SELECT 1 FROM public.merchant_transactions m WHERE m.matched_order_id = x.id)
    -- A withdrawal Sahal already paid (its read-back is on its way) is not paid twice.
    AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = x.id AND y.status = 'success')
  ORDER BY x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    UPDATE public.merchant_transactions SET match_status = 'unmatched' WHERE id = p_id;
    RETURN;
  END IF;
  UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = o.id, matched_at = now()
  WHERE id = p_id;
  PERFORM private.complete_withdraw_order(o.id, 'Sahal ' || t.transaction_id, NULL, NULL);
END $$;

-- As before, plus: a method Sahal sends is not paid from the phone.
CREATE OR REPLACE FUNCTION private.payout_block(o public.orders)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.payout_auto_settings;
  w public.payout_wallets := private.payout_wallet(o.method);
  v_label text := CASE o.method WHEN 'edahab' THEN 'eDahab' ELSE 'EVC Plus' END;
  v_bal jsonb;
BEGIN
  -- Sent from Sahal instead (or already tried there): never from the phone too.
  IF EXISTS (SELECT 1 FROM public.sahal_payout_settings x WHERE x.id AND x.mode <> 'off' AND o.method = ANY (x.methods))
     OR EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = o.id) THEN
    RETURN jsonb_build_object('code', 'SENT_FROM_SAHAL', 'message', v_label || ' withdrawals are sent from Sahal');
  END IF;
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
-- Management
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.sahal_payouts_json()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'mode', s.mode,
    'methods', to_jsonb(s.methods),
    'dailyLimit', private.money(s.daily_limit_cents),
    'testAmount', private.money(s.test_amount_cents),
    'paidToday', private.money(private.sahal_paid_today()),
    'testPassed', private.sahal_test_passed(),
    'waiting', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.method = ANY (s.methods)
                  AND o.status = 'pending' AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = o.id)),
    'unclear', (SELECT count(*) FROM public.sahal_payout_attempts a JOIN public.orders o ON o.id = a.order_id
                  WHERE a.status = 'ambiguous' AND o.status IN ('pending', 'processing')),
    'recent', COALESCE((SELECT jsonb_agg(r ORDER BY r ->> 'createdAt' DESC) FROM (
        SELECT jsonb_build_object('orderCode', o.order_code, 'status', a.status, 'receiver', a.receiver_mobile,
                 'receiverName', a.receiver_name, 'amount', private.money(a.amount_cents), 'transferId', a.transfer_id,
                 'reply', a.reply, 'createdAt', a.created_at) AS r
        FROM public.sahal_payout_attempts a JOIN public.orders o ON o.id = a.order_id
        ORDER BY a.created_at DESC LIMIT 10) q), '[]'::jsonb))
  FROM public.sahal_payout_settings s WHERE s.id
$$;

CREATE OR REPLACE FUNCTION public.manage_sahal_payouts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN private.sahal_payouts_json();
END $$;

CREATE OR REPLACE FUNCTION public.manage_set_sahal_payouts(p_mode text DEFAULT NULL, p_daily_limit numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  s public.sahal_payout_settings;
BEGIN
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id FOR UPDATE;
  IF p_mode IS NOT NULL AND p_mode NOT IN ('off', 'test', 'live') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'mode must be off, test or live');
  END IF;
  IF p_daily_limit IS NOT NULL AND p_daily_limit < 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The daily limit cannot be negative');
  END IF;
  IF p_mode = 'live' AND s.mode <> 'live' AND NOT private.sahal_test_passed() THEN
    PERFORM private.raise_api(409, 'TEST_REQUIRED',
      format('Send a $%s test withdrawal in Test mode first: it must go out from Sahal', private.money(s.test_amount_cents)));
  END IF;
  UPDATE public.sahal_payout_settings
  SET mode = COALESCE(p_mode, mode),
      daily_limit_cents = COALESCE(round(p_daily_limit * 100)::bigint, daily_limit_cents),
      test_started_at = CASE WHEN p_mode = 'test' AND mode <> 'test' THEN now() ELSE test_started_at END,
      updated_at = now()
  WHERE id RETURNING * INTO s;
  PERFORM private.audit(v_id, private.app_role(), 'sahal_payouts.update', 'sahal_payout_settings', 'golis', NULL,
    jsonb_build_object('mode', s.mode, 'dailyLimit', private.money(s.daily_limit_cents)));
  RETURN private.sahal_payouts_json();
END $$;

REVOKE ALL ON FUNCTION private.sahal_mobile(text), private.sahal_amount(bigint), private.sahal_paid_today(),
  private.sahal_test_passed(), private.sahal_hold(public.sahal_payout_attempts, text), private.sahal_payouts_json(),
  private.merchant_match_out(uuid), private.payout_block(public.orders) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sahal_payout_next(), public.sahal_payout_report(uuid, text, text, text, text, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sahal_payout_next(), public.sahal_payout_report(uuid, text, text, text, text, text)
  TO service_role;
REVOKE ALL ON FUNCTION public.manage_sahal_payouts(), public.manage_set_sahal_payouts(text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_payouts(), public.manage_set_sahal_payouts(text, numeric)
  TO authenticated, service_role;
