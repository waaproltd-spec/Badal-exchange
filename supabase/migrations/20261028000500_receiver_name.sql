-- Customer App, Confirm Withdrawal: the name Sahal has for the customer's
-- own Golis / ZAAD / EVC Plus number (the receiver-name Edge Function asks
-- Sahal's /api/account/find, as a payout does). Checks the caller and the
-- method and counts toward the player-search limit; the number is always the
-- customer's registered phone, so nobody can look up someone else's name.
CREATE OR REPLACE FUNCTION public.customer_begin_receiver_lookup(p_method text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_phone text;
BEGIN
  IF v_method::text NOT IN ('golis', 'telesom', 'evc_plus') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The receiver name is only for Golis, ZAAD and EVC Plus');
  END IF;
  SELECT phone INTO v_phone FROM public.users WHERE id = v_id;
  IF (SELECT count(*) FROM public.player_lookups
      WHERE customer_id = v_id AND created_at > now() - interval '1 hour') >= 30 THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many searches. Try again later.');
  END IF;
  INSERT INTO public.player_lookups (customer_id, method, account_id) VALUES (v_id, v_method, private.phone_key(v_phone));
  RETURN jsonb_build_object('method', v_method, 'mobile', private.sahal_mobile(v_phone));
END $$;

REVOKE ALL ON FUNCTION public.customer_begin_receiver_lookup(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_begin_receiver_lookup(text) TO authenticated, service_role;
