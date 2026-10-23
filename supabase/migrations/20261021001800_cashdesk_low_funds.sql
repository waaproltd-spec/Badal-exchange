-- Automatic 888STARZ / 1XBET withdrawals when the cash register is short.
--
-- A withdrawal is paid from BAARI's cash register at the platform; when the
-- register has less than the order needs, the worker reports 'low_funds'
-- instead of failing the order. The order stays 'processing' (the
-- customer's money stays reserved), the worker tries again every minute and
-- pays it as soon as the register is topped up. Managers linked to the
-- Telegram bots are told (at most every 15 minutes per register), and
-- agents see why it waits on the order. After 60 minutes of waiting it
-- fails and the reserved money goes back to the customer.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS low_funds_since TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION private.platform_eligible(o public.orders)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT private.is_cashdesk_method(o.method) AND o.auto_claimed_at IS NULL
    AND (o.status = 'pending' OR (o.status = 'processing' AND o.low_funds_since IS NOT NULL
      AND o.updated_at < now() - interval '50 seconds'))  -- a waiting withdrawal, once a minute
    AND o.winwin_id IS NOT NULL AND o.created_at > now() - interval '1 day'
    AND o.created_at >= COALESCE(
      (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since:' || o.method::text),
      (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since'))
    AND (o.direction = 'withdraw' OR o.platform_code IS NOT NULL)
$$;

CREATE OR REPLACE FUNCTION public.platform_claim_next()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.orders;
  stale public.orders;
BEGIN
  PERFORM private.require_service();

  FOR stale IN
    SELECT * FROM public.orders
    WHERE auto_claimed_at < now() - interval '10 minutes' AND status IN ('pending', 'processing')
      AND private.is_cashdesk_method(method) AND failure_reason IS NULL AND NOT payout_review
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.orders SET
      payout_review = (direction = 'withdraw'),
      failure_reason = private.method_label(stale.method) || ' did not answer. Check the player''s ' || private.method_label(stale.method) || ' account before completing or failing this order.',
      updated_at = now()
    WHERE id = stale.id;
  END LOOP;

  SELECT * INTO o FROM public.orders o2
  WHERE private.platform_eligible(o2)
  ORDER BY o2.created_at ASC LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF o.direction = 'withdraw' AND o.status = 'pending' THEN
    o := private.start_processing_withdraw(o.id, NULL, NULL);
  END IF;
  UPDATE public.orders SET auto_claimed_at = now(), updated_at = now() WHERE id = o.id RETURNING * INTO o;
  RETURN jsonb_build_object(
    'orderId', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'method', o.method,
    'accountId', o.winwin_id, 'amount', private.money(o.net_cents), 'code', o.platform_code);
END $$;

CREATE OR REPLACE FUNCTION public.platform_finish(
  p_order_id uuid, p_outcome text, p_reference text DEFAULT NULL, p_message text DEFAULT NULL, p_summa numeric DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  before public.orders;
  o public.orders;
  q record;
  v_cents bigint;
  v_message text := left(NULLIF(btrim(COALESCE(p_message, '')), ''), 300);
  v_label text;
  v_alert boolean := false;
  v_chats bigint[];
BEGIN
  PERFORM private.require_service();
  before := private.lock_order(p_order_id);
  IF before.auto_claimed_at IS NULL OR NOT private.is_cashdesk_method(before.method) THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Not an automatic betting-platform order');
  END IF;
  IF before.status IN ('completed', 'failed') THEN
    -- An agent finished it meanwhile; keep their result and note ours.
    PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk_late', 'order', before.id::text, NULL,
      jsonb_build_object('outcome', p_outcome, 'reference', p_reference, 'message', v_message, 'summa', p_summa));
    RETURN jsonb_build_object('status', before.status, 'late', true);
  END IF;

  IF p_outcome = 'done' THEN
    IF before.direction = 'withdraw' THEN
      o := private.complete_withdraw_order(before.id, COALESCE(p_reference, private.method_label(before.method)), NULL, NULL);
    ELSIF before.amount_unknown AND p_summa IS NULL THEN
      -- Paid out, but without an amount there is nothing safe to credit.
      UPDATE public.orders SET failure_reason = private.method_label(before.method) ||
          ' paid out the code but did not say how much. Check the player''s account and credit it by hand.',
        updated_at = now()
      WHERE id = before.id RETURNING * INTO o;
    ELSE
      -- Credit what the platform actually paid out.
      v_cents := round(COALESCE(p_summa, before.net_cents / 100.0) * 100)::bigint;
      IF v_cents <= 0 THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount');
      END IF;
      IF v_cents <> before.amount_cents OR before.amount_unknown THEN
        q := private.compute_quote(before.method, 'deposit', v_cents);
        UPDATE public.orders SET amount_cents = v_cents, rate = q.rate, fee_cents = q.fee_cents, net_cents = q.net_cents,
          wallet_delta_cents = q.wallet_delta_cents, exchange_rate_id = q.rate_id, fee_id = q.fee_id,
          amount_unknown = false
        WHERE id = before.id;
      END IF;
      o := private.complete_deposit_order(before.id, COALESCE(p_reference, private.method_label(before.method)), NULL, NULL);
    END IF;
  ELSIF p_outcome = 'low_funds' AND before.direction = 'withdraw' THEN
    v_label := private.method_label(before.method);
    IF before.low_funds_since IS NOT NULL AND before.low_funds_since < now() - interval '60 minutes' THEN
      -- Waited an hour for a top-up: give the customer their money back.
      o := private.fail_order(before.id, v_label || ' could not receive payouts in time. Your balance was not charged; '
        || 'please try again later.', NULL, NULL);
    ELSE
      -- Keep it processing and hand it to the worker again next minute.
      UPDATE public.orders SET auto_claimed_at = NULL, low_funds_since = COALESCE(low_funds_since, now()),
        failure_reason = 'Waiting for the ' || v_label || ' cash register to be topped up (' ||
          COALESCE(v_message, 'not enough balance') || '). Sent automatically once it has enough; '
          || 'failed and refunded after 60 minutes.',
        updated_at = now()
      WHERE id = before.id RETURNING * INTO o;
      -- Tell the managers, at most every 15 minutes per cash register.
      INSERT INTO public.app_settings (key, value) VALUES ('cashdesk_low_alert:' || before.method::text, now()::text)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
        WHERE public.app_settings.value::timestamptz < now() - interval '15 minutes'
      RETURNING true INTO v_alert;
      IF v_alert THEN
        SELECT array_agg(t.telegram_user_id) INTO v_chats
        FROM public.telegram_operators t JOIN public.users u ON u.id = t.user_id
        WHERE u.status = 'active' AND (u.role = 'admin'
          OR (u.role = 'agent' AND EXISTS (SELECT 1 FROM public.agent_profiles p
                WHERE p.user_id = u.id AND 'manage_settings' = ANY(p.responsibilities))));
      END IF;
    END IF;
  ELSIF p_outcome = 'refused' THEN
    o := private.fail_order(before.id, COALESCE(v_message, private.method_label(before.method) || ' refused the request'), NULL, NULL);
  ELSIF p_outcome = 'not_sent' THEN
    -- Nothing reached the platform: back to the agents as a normal order.
    UPDATE public.orders SET status = 'pending', processing_at = NULL,
      failure_reason = COALESCE(v_message, 'Automatic ' || private.method_label(before.method) || ' processing failed'), updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSIF p_outcome = 'unclear' THEN
    UPDATE public.orders SET payout_review = (direction = 'withdraw'),
      failure_reason = private.method_label(before.method) || ' gave no clear answer (' || COALESCE(v_message, 'no details') ||
        '). Check the player''s ' || private.method_label(before.method) || ' account before completing or failing this order.',
      updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSE
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown outcome');
  END IF;

  PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk', 'order', before.id::text, to_jsonb(before),
    to_jsonb(o) || jsonb_build_object('outcome', p_outcome, 'message', v_message, 'summa', p_summa));
  RETURN jsonb_build_object('status', o.status, 'payoutReview', o.payout_review)
    || CASE WHEN v_alert THEN jsonb_build_object('alertTelegramUserIds', COALESCE(to_jsonb(v_chats), '[]'::jsonb)) ELSE '{}'::jsonb END;
END $$;
