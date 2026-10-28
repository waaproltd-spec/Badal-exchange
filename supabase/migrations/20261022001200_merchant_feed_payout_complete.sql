-- Merchant feed: withdrawals sent by hand from Sahal complete themselves.
--
-- An agent still sends each withdrawal from the Sahal portal (Customer Fund
-- Transfer). The feed reads that outgoing transfer back from the merchant's
-- transaction list (a debit to the receiver's number) and completes the
-- waiting mobile-money withdrawal it pays, with Sahal's transaction id as
-- the reference, when:
--   * the receiver is the withdrawal's own number (last 9 digits),
--   * the debit is exactly what the customer is to receive (net amount),
--   * the withdrawal is pending or processing, not held for a manager's
--     review, made before the transfer (2 minutes' clock leeway) and at most
--     3 days before it.
-- Oldest first, once: a transfer completes at most one withdrawal (UNIQUE
-- matched_order_id), and only a waiting one. This only reads Sahal's list;
-- nothing here sends money. Switchable: app_settings
-- 'merchant_feed_payouts:golis'.

ALTER TABLE public.merchant_transactions
  ADD COLUMN IF NOT EXISTS direction TEXT CHECK (direction IN ('in', 'out'));
UPDATE public.merchant_transactions SET direction = 'in' WHERE payer_phone IS NOT NULL AND direction IS NULL;

INSERT INTO public.app_settings (key, value) VALUES ('merchant_feed_payouts:golis', 'on')
ON CONFLICT (key) DO NOTHING;

-- As before for incoming merchant payments; an outgoing transfer (a debit to
-- a receiver's number) is now kept too, as direction 'out', with the
-- receiver in payer_phone (the other party).
CREATE OR REPLACE FUNCTION private.merchant_parse(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  v_desc text;
  v_credit text;
  v_debit text;
  v_payer text;
  v_receiver text;
  v_paid timestamptz;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id;
  IF t.match_status <> 'new' OR t.payer_phone IS NOT NULL THEN RETURN; END IF;
  v_desc := COALESCE(t.raw->>'description', '');
  v_credit := btrim(COALESCE(t.raw->>'credit', ''));
  v_debit := btrim(COALESCE(t.raw->>'debit', ''));
  v_payer := substring(v_desc FROM '^\s*(\d{9,15})\s+paid\s+\$');
  v_receiver := NULLIF(regexp_replace(COALESCE(t.raw->>'receiver', ''), '\D', '', 'g'), '');
  BEGIN
    v_paid := to_timestamp(t.raw->>'tranDate', 'DD/MM/YY HH24:MI:SS')::timestamp AT TIME ZONE 'Africa/Mogadishu';
  EXCEPTION WHEN others THEN
    v_paid := t.first_seen_at;
  END;
  IF v_credit ~ '^[0-9]+(\.[0-9]+)?$' AND v_payer IS NOT NULL AND v_desc ~* 'to merchant' THEN
    UPDATE public.merchant_transactions
    SET direction = 'in', payer_phone = v_payer, amount_cents = round(v_credit::numeric * 100)::bigint,
        paid_at = COALESCE(v_paid, t.first_seen_at)
    WHERE id = p_id;
  ELSIF v_debit ~ '^[0-9]+(\.[0-9]+)?$' AND length(COALESCE(v_receiver, '')) >= 9 THEN
    UPDATE public.merchant_transactions
    SET direction = 'out', payer_phone = v_receiver, amount_cents = round(v_debit::numeric * 100)::bigint,
        paid_at = COALESCE(v_paid, t.first_seen_at)
    WHERE id = p_id;
  ELSE
    UPDATE public.merchant_transactions SET match_status = 'ignored' WHERE id = p_id;
  END IF;
END $$;

-- As before, for incoming payments only.
CREATE OR REPLACE FUNCTION private.merchant_match(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  o public.orders;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') OR t.payer_phone IS NULL OR t.amount_cents IS NULL
     OR t.direction IS DISTINCT FROM 'in' THEN
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
    UPDATE public.orders SET status = 'pending', failure_reason = NULL, updated_at = now() WHERE id = o.id;
    PERFORM private.order_audit(o.id, 'deposit_reopened_paid', jsonb_build_object('status', 'expired'),
      jsonb_build_object('status', 'pending', 'merchantTransaction', t.transaction_id), NULL);
  END IF;
  UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = o.id, matched_at = now()
  WHERE id = p_id;
  PERFORM private.complete_deposit_order(o.id, 'Sahal merchant ' || t.transaction_id, NULL, NULL);
END $$;

-- Completes the waiting withdrawal an outgoing Sahal transfer paid.
CREATE OR REPLACE FUNCTION private.merchant_match_out(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  o public.orders;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') OR t.payer_phone IS NULL OR t.amount_cents IS NULL
     OR t.direction IS DISTINCT FROM 'out' THEN
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

-- As before, plus outgoing transfers (when their switch is on).
CREATE OR REPLACE FUNCTION private.merchant_sweep(p_provider text)
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  n integer := 0;
  v_in boolean := COALESCE((SELECT value FROM public.app_settings WHERE key = 'merchant_feed_credit:' || p_provider), 'off') = 'on';
  v_out boolean := COALESCE((SELECT value FROM public.app_settings WHERE key = 'merchant_feed_payouts:' || p_provider), 'off') = 'on';
BEGIN
  FOR r IN SELECT id FROM public.merchant_transactions WHERE provider = p_provider AND match_status = 'new' AND payer_phone IS NULL LOOP
    PERFORM private.merchant_parse(r.id);
  END LOOP;
  FOR r IN SELECT id, direction FROM public.merchant_transactions
           WHERE provider = p_provider AND match_status IN ('new', 'unmatched') AND payer_phone IS NOT NULL
             AND paid_at > now() - interval '3 days'
           ORDER BY paid_at LOOP
    CONTINUE WHEN (r.direction = 'in' AND NOT v_in) OR (r.direction = 'out' AND NOT v_out) OR r.direction IS NULL;
    BEGIN
      IF r.direction = 'in' THEN
        CONTINUE WHEN (SELECT paid_at FROM public.merchant_transactions WHERE id = r.id) < now() - interval '24 hours';
        PERFORM private.merchant_match(r.id);
      ELSE
        PERFORM private.merchant_match_out(r.id);
      END IF;
      IF (SELECT match_status FROM public.merchant_transactions WHERE id = r.id) = 'matched' THEN n := n + 1; END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'merchant match %: %', r.id, SQLERRM;
    END;
  END LOOP;
  RETURN n;
END $$;

-- Managers: switch auto-completing withdrawals on or off.
CREATE OR REPLACE FUNCTION public.manage_merchant_feed_payouts(p_provider text, p_on boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  INSERT INTO public.app_settings (key, value) VALUES ('merchant_feed_payouts:' || p_provider, CASE WHEN p_on THEN 'on' ELSE 'off' END)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
  PERFORM private.audit(v_id, private.app_role(), 'merchant_feed.payouts', 'merchant_feed', p_provider, NULL,
    jsonb_build_object('on', p_on));
  RETURN public.manage_merchant_feed_status(p_provider);
END $$;

-- As before, plus the withdrawals switch and today's completed count.
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
      'payoutsOn', COALESCE((SELECT value FROM public.app_settings WHERE key = 'merchant_feed_payouts:' || p_provider), 'off') = 'on',
      'creditedToday', (SELECT count(*) FROM public.merchant_transactions m
                        WHERE m.provider = p_provider AND m.match_status = 'matched' AND m.direction = 'in'
                          AND m.matched_at > now() - interval '24 hours'),
      'unmatchedToday', (SELECT count(*) FROM public.merchant_transactions m
                         WHERE m.provider = p_provider AND m.match_status = 'unmatched' AND m.direction = 'in'
                           AND m.paid_at > now() - interval '24 hours'),
      'payoutsCompletedToday', (SELECT count(*) FROM public.merchant_transactions m
                                WHERE m.provider = p_provider AND m.match_status = 'matched' AND m.direction = 'out'
                                  AND m.matched_at > now() - interval '24 hours'))
    FROM public.merchant_feed_status s WHERE s.provider = p_provider);
END $$;

REVOKE ALL ON FUNCTION private.merchant_match_out(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_merchant_feed_payouts(text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_merchant_feed_payouts(text, boolean) TO authenticated;

-- Outgoing transfers of the last 3 days that were set aside before this
-- existed are parsed again, so a withdrawal already sent today completes.
UPDATE public.merchant_transactions SET match_status = 'new'
WHERE match_status = 'ignored' AND payer_phone IS NULL AND first_seen_at > now() - interval '3 days'
  AND btrim(COALESCE(raw->>'debit', '')) ~ '^[0-9]+(\.[0-9]+)?$';
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT id FROM public.merchant_transactions WHERE match_status = 'new' AND payer_phone IS NULL LOOP
    PERFORM private.merchant_parse(r.id);
  END LOOP;
END $$;
