-- Merchant feed, stage 2: credit deposits from the Sahal merchant payments.
--
-- A stored portal row is a merchant payment when it has a credit and its
-- description reads "<payer> paid $<amount> to merchant: ..." (EVC Plus,
-- ZAAD and Golis payments to the merchant all arrive this way). It pays a
-- mobile-money deposit when:
--   * the payer is the order's own number (last 9 digits),
--   * the amount is the order's amount, exactly,
--   * the order is waiting for its payment (pending, or expired unpaid in
--     the last 24 hours: then it is reopened first, as for a late SMS),
--   * the order was made at most 24 hours before the payment, or up to 10
--     minutes after it (paid first, then submitted).
-- The oldest such order is credited, once: each payment credits at most one
-- order (UNIQUE matched_order_id) and an order is credited only while it
-- waits, so a payment that also arrives by SMS never credits twice. Rows
-- without an order stay 'unmatched' and are tried again for 24 hours
-- (the order may come later); nothing is ever credited without a row
-- the portal returned. Switchable: app_settings 'merchant_feed_credit:golis'.

ALTER TABLE public.merchant_transactions
  ADD COLUMN IF NOT EXISTS payer_phone      TEXT,
  ADD COLUMN IF NOT EXISTS amount_cents     BIGINT,
  ADD COLUMN IF NOT EXISTS paid_at          TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS match_status     TEXT NOT NULL DEFAULT 'new'
    CHECK (match_status IN ('new', 'matched', 'unmatched', 'ignored')),
  ADD COLUMN IF NOT EXISTS matched_order_id UUID UNIQUE REFERENCES public.orders(id),
  ADD COLUMN IF NOT EXISTS matched_at       TIMESTAMPTZ;

INSERT INTO public.app_settings (key, value) VALUES ('merchant_feed_credit:golis', 'on')
ON CONFLICT (key) DO NOTHING;

-- Fills payer, amount and time from the portal's own fields; 'ignored' for
-- anything that is not an incoming merchant payment.
CREATE OR REPLACE FUNCTION private.merchant_parse(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  v_desc text;
  v_credit text;
  v_payer text;
  v_paid timestamptz;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id;
  IF t.match_status <> 'new' OR t.payer_phone IS NOT NULL THEN RETURN; END IF;
  v_desc := COALESCE(t.raw->>'description', '');
  v_credit := btrim(COALESCE(t.raw->>'credit', ''));
  v_payer := substring(v_desc FROM '^\s*(\d{9,15})\s+paid\s+\$');
  IF v_credit !~ '^[0-9]+(\.[0-9]+)?$' OR v_payer IS NULL OR v_desc !~* 'to merchant' THEN
    UPDATE public.merchant_transactions SET match_status = 'ignored' WHERE id = p_id;
    RETURN;
  END IF;
  BEGIN
    v_paid := to_timestamp(t.raw->>'tranDate', 'DD/MM/YY HH24:MI:SS')::timestamp AT TIME ZONE 'Africa/Mogadishu';
  EXCEPTION WHEN others THEN
    v_paid := t.first_seen_at;
  END;
  UPDATE public.merchant_transactions
  SET payer_phone = v_payer, amount_cents = round(v_credit::numeric * 100)::bigint, paid_at = COALESCE(v_paid, t.first_seen_at)
  WHERE id = p_id;
END $$;

-- Credits the deposit this payment is for, if there is exactly that one.
CREATE OR REPLACE FUNCTION private.merchant_match(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  o public.orders;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') OR t.payer_phone IS NULL OR t.amount_cents IS NULL THEN
    RETURN;
  END IF;
  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'deposit'
    AND x.method IN (SELECT method FROM public.payment_methods WHERE kind = 'mobile_money')
    AND right(regexp_replace(COALESCE(x.phone_number, ''), '\D', '', 'g'), 9) = right(t.payer_phone, 9)
    AND x.amount_cents = t.amount_cents
    AND (x.status = 'pending'
         OR (x.status = 'expired' AND x.failure_reason = private.unpaid_deposit_reason()))
    AND x.created_at BETWEEN t.paid_at - interval '24 hours' AND t.paid_at + interval '10 minutes'
    AND NOT EXISTS (SELECT 1 FROM public.merchant_transactions m WHERE m.matched_order_id = x.id)
  ORDER BY (x.status = 'pending') DESC, x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    UPDATE public.merchant_transactions SET match_status = 'unmatched' WHERE id = p_id;
    RETURN;
  END IF;
  IF o.status = 'expired' THEN
    -- Paid after it expired: reopened, then credited, like a late SMS.
    UPDATE public.orders SET status = 'pending', failure_reason = NULL, updated_at = now() WHERE id = o.id;
    PERFORM private.order_audit(o.id, 'deposit_reopened_paid', jsonb_build_object('status', 'expired'),
      jsonb_build_object('status', 'pending', 'merchantTransaction', t.transaction_id), NULL);
  END IF;
  UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = o.id, matched_at = now()
  WHERE id = p_id;
  PERFORM private.complete_deposit_order(o.id, 'Sahal merchant ' || t.transaction_id, NULL, NULL);
END $$;

-- New rows parsed; new and still-unmatched payments of the last 24 hours
-- matched (when crediting is on). One row's error never blocks the others.
CREATE OR REPLACE FUNCTION private.merchant_sweep(p_provider text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  n integer := 0;
BEGIN
  FOR r IN SELECT id FROM public.merchant_transactions WHERE provider = p_provider AND match_status = 'new' AND payer_phone IS NULL LOOP
    PERFORM private.merchant_parse(r.id);
  END LOOP;
  IF COALESCE((SELECT value FROM public.app_settings WHERE key = 'merchant_feed_credit:' || p_provider), 'off') <> 'on' THEN
    RETURN 0;
  END IF;
  FOR r IN SELECT id FROM public.merchant_transactions
           WHERE provider = p_provider AND match_status IN ('new', 'unmatched') AND payer_phone IS NOT NULL
             AND paid_at > now() - interval '24 hours'
           ORDER BY paid_at LOOP
    BEGIN
      PERFORM private.merchant_match(r.id);
      IF (SELECT match_status FROM public.merchant_transactions WHERE id = r.id) = 'matched' THEN n := n + 1; END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'merchant_match %: %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN n;
END $$;

-- As before, then sweeps; returns how many were credited.
CREATE OR REPLACE FUNCTION public.merchant_feed_report(
  p_provider text, p_state text, p_result_code text, p_message text, p_session_id text, p_rows jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
  v_new int := 0;
  v_id text;
BEGIN
  PERFORM private.require_service();
  FOR r IN SELECT * FROM jsonb_array_elements(COALESCE(p_rows, '[]'::jsonb)) LOOP
    v_id := NULLIF(btrim(r->>'_id'), '');
    CONTINUE WHEN v_id IS NULL;
    INSERT INTO public.merchant_transactions (provider, transaction_id, raw)
    VALUES (p_provider, v_id, r - '_id') ON CONFLICT (provider, transaction_id) DO NOTHING;
    IF FOUND THEN v_new := v_new + 1; END IF;
  END LOOP;
  INSERT INTO private.merchant_feed_sessions (provider, session_id, updated_at) VALUES (p_provider, p_session_id, now())
  ON CONFLICT (provider) DO UPDATE SET session_id = EXCLUDED.session_id, updated_at = now();
  UPDATE public.merchant_feed_status SET state = p_state, result_code = left(p_result_code, 20),
    message = left(p_message, 300), checked_at = now(),
    last_ok_at = CASE WHEN p_state = 'ok' THEN now() ELSE last_ok_at END,
    rows_seen = rows_seen + v_new, updated_at = now()
  WHERE provider = p_provider;
  RETURN jsonb_build_object('new', v_new, 'credited', private.merchant_sweep(p_provider));
END $$;

-- Managers: switch crediting on or off.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_credit(p_provider text, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  INSERT INTO public.app_settings (key, value) VALUES ('merchant_feed_credit:' || p_provider, CASE WHEN p_on THEN 'on' ELSE 'off' END)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.credit', 'merchant_feed', p_provider, NULL,
    jsonb_build_object('on', p_on));
  RETURN public.manage_merchant_feed_status(p_provider);
END $$;

-- As before, plus the crediting switch and today's counts.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_status(p_provider text DEFAULT 'golis')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_asked timestamptz := (SELECT second_at FROM private.merchant_feed_sessions WHERE provider = p_provider);
BEGIN
  RETURN (SELECT jsonb_build_object('provider', s.provider,
      'state', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes' THEN 'stopped'
                    WHEN s.state = 'signing_in' THEN 'ready' ELSE s.state END,
      'resultCode', s.result_code,
      'message', CASE WHEN s.state = 'needs_code' AND v_asked < now() - interval '10 minutes'
                      THEN 'The access code expired. Sign in again.'
                      WHEN s.state = 'signing_in' THEN 'Signing in…' ELSE s.message END,
      'checkedAt', s.checked_at, 'lastOkAt', s.last_ok_at, 'rowsSeen', s.rows_seen,
      'codeAskedAt', CASE WHEN s.state = 'needs_code' THEN v_asked END,
      'creditOn', COALESCE((SELECT value FROM public.app_settings WHERE key = 'merchant_feed_credit:' || p_provider), 'off') = 'on',
      'creditedToday', (SELECT count(*) FROM public.merchant_transactions m
                        WHERE m.provider = p_provider AND m.match_status = 'matched' AND m.matched_at > now() - interval '24 hours'),
      'unmatchedToday', (SELECT count(*) FROM public.merchant_transactions m
                         WHERE m.provider = p_provider AND m.match_status = 'unmatched' AND m.paid_at > now() - interval '24 hours'))
    FROM public.merchant_feed_status s WHERE s.provider = p_provider);
END $$;

REVOKE ALL ON FUNCTION private.merchant_parse(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.merchant_match(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.merchant_sweep(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_credit(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_credit(text, boolean) TO authenticated;

-- The rows already stored get their payer, amount and time now; the next
-- run matches them.
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.merchant_transactions WHERE match_status = 'new' AND payer_phone IS NULL LOOP
    PERFORM private.merchant_parse(r.id);
  END LOOP;
END $$;
