-- Sahal's balance, read before every transfer (POST /api/account/balance,
-- currentBalance, like the portal's dashboard): a withdrawal larger than it
-- waits instead of being refused, and the balance shows in the Agent App.
-- A refused transfer (nothing was sent) can be tried again by a manager.
ALTER TABLE public.sahal_payout_settings
  ADD COLUMN IF NOT EXISTS balance_cents BIGINT,
  ADD COLUMN IF NOT EXISTS balance_seen_at TIMESTAMPTZ;

DROP FUNCTION IF EXISTS public.sahal_payout_next();
CREATE OR REPLACE FUNCTION public.sahal_payout_next(p_balance numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sahal_payout_settings;
  o public.orders;
  a public.sahal_payout_attempts;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id FOR UPDATE;
  IF p_balance IS NOT NULL THEN
    UPDATE public.sahal_payout_settings SET balance_cents = round(p_balance * 100)::bigint, balance_seen_at = now()
    WHERE id RETURNING * INTO s;
  END IF;
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
    -- Not enough in Sahal: it waits (its one attempt is not used).
    AND (p_balance IS NULL OR x.net_cents <= round(p_balance * 100))
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

CREATE OR REPLACE FUNCTION private.sahal_payouts_json()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'mode', s.mode,
    'methods', to_jsonb(s.methods),
    'dailyLimit', private.money(s.daily_limit_cents),
    'testAmount', private.money(s.test_amount_cents),
    'paidToday', private.money(private.sahal_paid_today()),
    'testPassed', private.sahal_test_passed(),
    'balance', CASE WHEN s.balance_cents IS NULL THEN NULL ELSE private.money(s.balance_cents) END,
    'balanceSeenAt', s.balance_seen_at,
    'needsBalance', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.method = ANY (s.methods)
                  AND o.status = 'pending' AND s.balance_cents IS NOT NULL AND o.net_cents > s.balance_cents
                  AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = o.id)),
    'waiting', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.method = ANY (s.methods)
                  AND o.status = 'pending' AND NOT EXISTS (SELECT 1 FROM public.sahal_payout_attempts y WHERE y.order_id = o.id)),
    'unclear', (SELECT count(*) FROM public.sahal_payout_attempts a JOIN public.orders o ON o.id = a.order_id
                  WHERE a.status = 'ambiguous' AND o.status IN ('pending', 'processing')),
    'recent', COALESCE((SELECT jsonb_agg(r ORDER BY r ->> 'createdAt' DESC) FROM (
        SELECT jsonb_build_object('orderId', o.id, 'orderCode', o.order_code, 'orderStatus', o.status, 'status', a.status, 'receiver', a.receiver_mobile,
                 'receiverName', a.receiver_name, 'amount', private.money(a.amount_cents), 'transferId', a.transfer_id,
                 'reply', a.reply, 'createdAt', a.created_at) AS r
        FROM public.sahal_payout_attempts a JOIN public.orders o ON o.id = a.order_id
        ORDER BY a.created_at DESC LIMIT 10) q), '[]'::jsonb))
  FROM public.sahal_payout_settings s WHERE s.id
$$;

-- Sahal refused it before anything was sent: it may go again.
CREATE OR REPLACE FUNCTION public.manage_sahal_retry(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.sahal_payout_attempts;
  o public.orders := private.lock_order(p_order_id);
BEGIN
  SELECT * INTO a FROM public.sahal_payout_attempts WHERE order_id = o.id FOR UPDATE;
  IF a.id IS NULL OR a.status <> 'failed' OR o.status <> 'pending' THEN
    PERFORM private.raise_api(409, 'INVALID_STATE', 'Only a refused transfer of a waiting withdrawal can be tried again');
  END IF;
  DELETE FROM public.sahal_payout_attempts WHERE id = a.id;
  PERFORM private.order_audit(o.id, 'withdrawal_sahal_retry', jsonb_build_object('attempt', a.id, 'reply', a.reply), NULL, v_id);
  RETURN private.sahal_payouts_json();
END $$;

REVOKE ALL ON FUNCTION public.sahal_payout_next(numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sahal_payout_next(numeric) TO service_role;
REVOKE ALL ON FUNCTION private.sahal_payouts_json() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_sahal_retry(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_retry(uuid) TO authenticated, service_role;
