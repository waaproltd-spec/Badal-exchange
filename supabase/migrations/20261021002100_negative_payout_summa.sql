-- 1XBET / 888STARZ payment-code deposits: CashdeskBot reports the paid-out
-- amount ("summa") as negative -- money leaving the player's account, e.g.
-- -5 for a $5 payout. platform_finish refused that as an invalid amount, so
-- the payout went through at the platform but the customer was never
-- credited, and after 10 minutes the order said "did not answer".
--
-- platform_finish now credits the absolute amount. Deposits already paid out
-- this way are completed from the worker's own recorded answers (pg_net
-- keeps the last hours of them): only orders still open, whose recorded
-- answer was "done" with an amount and failed with "Invalid amount".

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
    ELSIF before.amount_unknown AND COALESCE(p_summa, 0) = 0 THEN
      -- Paid out, but without an amount there is nothing safe to credit.
      UPDATE public.orders SET failure_reason = private.method_label(before.method) ||
          ' paid out the code but did not say how much. Check the player''s account and credit it by hand.',
        updated_at = now()
      WHERE id = before.id RETURNING * INTO o;
    ELSE
      -- Credit what the platform actually paid out.
      -- CashdeskBot reports a payout as money leaving the player: negative.
      v_cents := round(abs(COALESCE(p_summa, before.net_cents / 100.0)) * 100)::bigint;
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

DO $do$
DECLARE
  r record;
  o public.orders;
BEGIN
  IF to_regclass('net._http_response') IS NULL THEN
    RETURN;
  END IF;
  PERFORM set_config('request.jwt.claims', '{"role":"service_role"}', true);
  FOR r IN EXECUTE $q$
    SELECT DISTINCT ON (p->>'order') p->>'order' AS code, p->>'reference' AS reference, (p->>'summa')::numeric AS summa
    FROM net._http_response h, jsonb_array_elements(
      CASE WHEN h.content ~ '^\s*\{' THEN (h.content::jsonb)->'processed' ELSE '[]'::jsonb END) p
    WHERE p->>'outcome' = 'done' AND p->>'error' LIKE '%Invalid amount%' AND (p->>'summa') IS NOT NULL
      AND (p->>'summa')::numeric <> 0
    ORDER BY p->>'order', h.created DESC
  $q$
  LOOP
    SELECT * INTO o FROM public.orders
    WHERE order_code = r.code AND direction = 'deposit' AND status IN ('pending', 'processing')
      AND auto_claimed_at IS NOT NULL AND private.is_cashdesk_method(method);
    IF o.id IS NOT NULL THEN
      PERFORM public.platform_finish(o.id, 'done', r.reference, NULL, r.summa);
      RAISE NOTICE 'credited % with %', r.code, abs(r.summa);
    END IF;
  END LOOP;
END
$do$;
