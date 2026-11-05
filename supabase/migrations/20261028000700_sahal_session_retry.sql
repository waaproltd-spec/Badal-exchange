-- Diagnosed on production (supabase/diagnostics/payments.sql, 2026-10-28):
-- Sahal refused transfers with ER0654 "Session data is not found, please
-- sign in again" while the feed still read fine; each such withdrawal then
-- waited for a manager's Try again (EXUPECC7: 7 hours). Sahal sent nothing
-- for these, so sahal_payout_next now retries them by itself.
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
  -- Refused only because Sahal's session had ended (ER0654 "Session data is
  -- not found, please sign in again"): nothing was sent, so after 2 minutes
  -- the withdrawal is tried again by itself instead of waiting for Try again.
  FOR a IN SELECT y.* FROM public.sahal_payout_attempts y JOIN public.orders x ON x.id = y.order_id
           WHERE y.status = 'failed' AND x.status = 'pending'
             AND (y.result_code = 'ER0654' OR y.reply ILIKE '%session data is not found%')
             AND y.completed_at < now() - interval '2 minutes'
           FOR UPDATE OF y SKIP LOCKED LOOP
    DELETE FROM public.sahal_payout_attempts WHERE id = a.id;
    PERFORM private.order_audit(a.order_id, 'withdrawal_sahal_retry', jsonb_build_object('attempt', a.id, 'reply', a.reply),
      jsonb_build_object('automatic', true), NULL);
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
