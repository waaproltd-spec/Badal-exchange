-- Cash-desk deposits (888STARZ, 1XBET) by withdrawal code alone: the
-- customer gives their account ID and the code, not an amount; the platform
-- says how much when the code is paid out, and that is what is credited.
-- Until then the order's amount is unknown (amount_unknown): it is stored
-- as a 1-cent placeholder and shown to the apps as 0.00 with
-- amountPending = true. A payout that comes back without an amount is left
-- for an agent instead of guessing.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS amount_unknown BOOLEAN NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.customer_create_deposit(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL,
  p_platform_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text := NULLIF(btrim(COALESCE(p_platform_code, '')), '');
  v_amount text := NULLIF(btrim(COALESCE(p_amount, '')), '');
  v_unknown boolean;
  v_result jsonb;
BEGIN
  PERFORM private.check_len(v_code, 'platformCode', 1, 64, false);
  -- A withdrawal code for a cash-desk platform says the amount itself: the
  -- order is created with a 1-cent placeholder, flagged, until the
  -- platform pays it out.
  v_unknown := v_amount IS NULL AND v_code IS NOT NULL AND private.is_cashdesk_method(private.parse_method(p_method));
  v_result := private.customer_order_request('deposit', p_method, COALESCE(v_amount, CASE WHEN v_unknown THEN '0.01' END),
    private.customer_own_phone(p_method, p_phone_number), p_account_id, p_winwin_id, p_idempotency_key);
  IF v_unknown THEN
    -- Only on the first call (a replay finds the code already set).
    UPDATE public.orders SET amount_unknown = true
    WHERE id = (v_result ->> 'id')::uuid AND status = 'pending' AND NOT amount_unknown AND platform_code IS NULL;
  END IF;
  IF v_code IS NOT NULL AND private.is_cashdesk_method(private.parse_method(p_method)) THEN
    -- Only on the first call: a replayed request leaves the order as it is.
    UPDATE public.orders SET platform_code = v_code
    WHERE id = (v_result ->> 'id')::uuid AND platform_code IS NULL AND auto_claimed_at IS NULL AND status = 'pending';
    IF FOUND THEN
      PERFORM private.platform_kick();
    END IF;
  END IF;
  IF v_unknown THEN
    -- The order as it is now, not the stored first response (1-cent placeholder).
    v_result := private.customer_order_json((SELECT o FROM public.orders o WHERE o.id = (v_result ->> 'id')::uuid));
  END IF;
  RETURN v_result;
END
$$;

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

CREATE OR REPLACE FUNCTION private.customer_order_json(o public.orders)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'status', o.status,
    'statusMessage', private.order_status_message(o.status),
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.amount_cents) END,
    'fee', private.money(o.fee_cents),
    'netAmount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.net_cents) END,
    'amountPending', o.amount_unknown,
    'transactionRef', o.transaction_ref,
    'failureReason', CASE WHEN o.status = 'failed' OR NOT private.is_cashdesk_method(o.method) THEN o.failure_reason END,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.agent_order_json(o public.orders)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'status', o.status,
    'customerId', o.customer_id,
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.amount_cents) END,
    'fee', private.money(o.fee_cents),
    'netAmount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.net_cents) END,
    'walletDelta', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.wallet_delta_cents) END,
    'amountPending', o.amount_unknown,
    'transactionRef', o.transaction_ref,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;
