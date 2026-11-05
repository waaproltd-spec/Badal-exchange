-- The receiver name on Confirm Withdrawal is for the number the money goes to.
-- It was always the customer's registered number, so a customer authorized to
-- withdraw to another number saw the registered number's name. A number other
-- than the registered one is looked up only for a customer an admin
-- authorized for that network; for anyone else it is refused, as a payout is.
DROP FUNCTION IF EXISTS public.customer_begin_receiver_lookup(text);

CREATE OR REPLACE FUNCTION public.customer_begin_receiver_lookup(p_method text, p_phone text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_phone text;
  v_given text := NULLIF(regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g'), '');
BEGIN
  IF v_method::text NOT IN ('golis', 'telesom', 'evc_plus') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The receiver name is only for Golis, ZAAD and EVC Plus');
  END IF;
  SELECT phone INTO v_phone FROM public.users WHERE id = v_id;
  IF v_given IS NOT NULL AND right(v_given, 9) <> right(regexp_replace(v_phone, '\D', '', 'g'), 9) THEN
    IF NOT private.payment_number_allowed(v_id, v_method) THEN
      PERFORM private.raise_api(400, 'PHONE_NOT_OWN',
        'Deposits and withdrawals use your registered phone number. Pay from and receive to that number.');
    END IF;
    v_phone := private.payment_number_clean(v_given);
  END IF;
  IF (SELECT count(*) FROM public.player_lookups
      WHERE customer_id = v_id AND created_at > now() - interval '1 hour') >= 30 THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many searches. Try again later.');
  END IF;
  INSERT INTO public.player_lookups (customer_id, method, account_id) VALUES (v_id, v_method, private.phone_key(v_phone));
  RETURN jsonb_build_object('method', v_method, 'mobile', private.sahal_mobile(v_phone));
END $$;

REVOKE ALL ON FUNCTION public.customer_begin_receiver_lookup(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_begin_receiver_lookup(text, text) TO authenticated, service_role;
