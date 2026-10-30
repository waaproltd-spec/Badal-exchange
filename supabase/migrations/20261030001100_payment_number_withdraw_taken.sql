-- Another customer's login number: a deposit from it would be credited to
-- that customer (the SMS is matched to the number's owner), so an authorized
-- customer still cannot deposit from it. A withdrawal only pays out to the
-- number, nothing is matched, so an authorized customer may receive on it.
-- Everything else of 20261030001000 stays.

DROP FUNCTION IF EXISTS private.payment_number_register(uuid, public.order_method, text, text, uuid, boolean, boolean);

CREATE OR REPLACE FUNCTION private.payment_number_register(
  p_customer uuid, p_method public.order_method, p_phone text, p_label text, p_by uuid, p_by_customer boolean, p_use boolean,
  p_allow_taken boolean DEFAULT false)
RETURNS public.customer_payment_numbers LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_phone text := private.payment_number_clean(p_phone);
  v_key text := private.phone_key(v_phone);
  n public.customer_payment_numbers;
BEGIN
  -- Another customer's login number stays theirs for deposits (a payment from it is credited to them).
  IF NOT p_allow_taken AND EXISTS (
       SELECT 1 FROM public.users u WHERE u.id <> p_customer AND u.role = 'customer' AND private.phone_key(u.phone) = v_key) THEN
    PERFORM private.raise_api(400, 'PAYMENT_NUMBER_TAKEN', 'This phone number belongs to another account. Use a different number.');
  END IF;
  SELECT * INTO n FROM public.customer_payment_numbers
  WHERE customer_id = p_customer AND method = p_method AND phone_key = v_key FOR UPDATE;
  IF n.id IS NOT NULL THEN
    IF n.blocked_at IS NOT NULL THEN
      PERFORM private.raise_api(400, 'PAYMENT_NUMBER_BLOCKED', 'This phone number is blocked for your account. Contact the admin.');
    END IF;
    IF p_use THEN
      UPDATE public.customer_payment_numbers SET last_used_at = now(), uses = uses + 1 WHERE id = n.id RETURNING * INTO n;
    END IF;
    RETURN n;
  END IF;
  IF (SELECT count(*) FROM public.customer_payment_numbers WHERE customer_id = p_customer AND method = p_method) >= 20 THEN
    PERFORM private.raise_api(400, 'PAYMENT_NUMBER_LIMIT', 'Too many phone numbers for this network. Ask the admin to remove one.');
  END IF;
  INSERT INTO public.customer_payment_numbers (customer_id, method, phone, phone_key, label, added_by, added_by_customer, last_used_at, uses)
  VALUES (p_customer, p_method, v_phone, v_key, NULLIF(btrim(COALESCE(p_label, '')), ''), p_by, p_by_customer,
          CASE WHEN p_use THEN now() END, CASE WHEN p_use THEN 1 ELSE 0 END)
  RETURNING * INTO n;
  RETURN n;
END $$;

DROP FUNCTION IF EXISTS private.customer_own_phone(text, text);

-- p_withdraw: a withdrawal (a payout), which may go to another customer's number.
CREATE OR REPLACE FUNCTION private.customer_own_phone(p_method text, p_phone text, p_withdraw boolean DEFAULT false)
RETURNS text LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_m public.order_method := private.parse_method(p_method);
  v_own text;
  v_given text := NULLIF(regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g'), '');
  n public.customer_payment_numbers;
BEGIN
  IF private.method_kind(v_m) <> 'mobile_money' THEN
    RETURN p_phone;
  END IF;
  SELECT phone INTO v_own FROM public.users WHERE id = v_id;
  IF v_given IS NULL OR right(v_given, 9) = right(regexp_replace(v_own, '\D', '', 'g'), 9) THEN
    RETURN v_own;
  END IF;
  IF NOT private.payment_number_allowed(v_id, v_m) THEN
    PERFORM private.raise_api(400, 'PHONE_NOT_OWN',
      'Deposits and withdrawals use your registered phone number. Pay from and receive to that number.');
  END IF;
  n := private.payment_number_register(v_id, v_m, v_given, NULL, v_id, true, true, p_withdraw);
  RETURN n.phone;
END $$;

CREATE OR REPLACE FUNCTION public.customer_create_withdrawal(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb := private.customer_order_request('withdraw', p_method, p_amount,
    private.customer_own_phone(p_method, p_phone_number, true), p_account_id, p_winwin_id, p_idempotency_key);
BEGIN
  IF private.is_cashdesk_method(private.parse_method(p_method)) THEN
    PERFORM private.platform_kick();
  END IF;
  RETURN v_result;
END
$$;
