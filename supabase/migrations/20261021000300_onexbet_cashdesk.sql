-- 1XBET orders through their own CashdeskBot cash register, exactly like
-- 888STARZ (20261021000200_platform_auto.sql); the worker picks the cash
-- register from the order's method. 1XBET orders created before this
-- migration stay manual, for the same reason as 888STARZ ones: one may
-- already have been handled by hand.

INSERT INTO public.app_settings (key, value) VALUES ('platform_auto_since:onexbet', now()::text)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_method::text IN ('888starz', 'onexbet')
$$;

-- Name customers and agents know the method by (1XBET, 888STARZ).
CREATE OR REPLACE FUNCTION private.method_label(p_method public.order_method)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT label FROM public.payment_methods WHERE method = p_method), p_method::text)
$$;

-- Each method is automatic from its own start time.
CREATE OR REPLACE FUNCTION private.platform_eligible(o public.orders)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT private.is_cashdesk_method(o.method) AND o.status = 'pending' AND o.auto_claimed_at IS NULL
    AND o.winwin_id IS NOT NULL AND o.created_at > now() - interval '1 day'
    AND o.created_at >= COALESCE(
      (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since:' || o.method::text),
      (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since'))
    AND (o.direction = 'withdraw' OR o.platform_code IS NOT NULL)
$$;

-- Messages name the order's platform instead of 888starz.
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

  IF o.direction = 'withdraw' THEN
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
    ELSE
      -- Credit what the platform actually paid out.
      v_cents := round(COALESCE(p_summa, before.net_cents / 100.0) * 100)::bigint;
      IF v_cents <= 0 THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount');
      END IF;
      IF v_cents <> before.amount_cents THEN
        q := private.compute_quote(before.method, 'deposit', v_cents);
        UPDATE public.orders SET amount_cents = v_cents, rate = q.rate, fee_cents = q.fee_cents, net_cents = q.net_cents,
          wallet_delta_cents = q.wallet_delta_cents, exchange_rate_id = q.rate_id, fee_id = q.fee_id
        WHERE id = before.id;
      END IF;
      o := private.complete_deposit_order(before.id, COALESCE(p_reference, private.method_label(before.method)), NULL, NULL);
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
  RETURN jsonb_build_object('status', o.status, 'payoutReview', o.payout_review);
END $$;
