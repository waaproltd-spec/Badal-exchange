-- Mobile-money deposits and withdrawals (EVC Plus, eDahab, Golis, ZAAD)
-- use only the customer's registered login phone number: a deposit is
-- paid from it and verified against it, and a withdrawal is paid out to
-- it. The number is taken from the account, whatever the app sends; a
-- different number is refused, so no app version or direct API call can
-- deposit for, or withdraw to, someone else's number. Betting platforms are
-- unchanged (they use the player's account ID).

-- The customer's registered phone for a mobile-money order, or p_phone
-- unchanged for other methods. A number given must be that same number
-- (compared by its last 9 digits, so 2526..., 06... and 6... all match).
CREATE OR REPLACE FUNCTION private.customer_own_phone(p_method text, p_phone text)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_own text;
  v_given text := NULLIF(regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g'), '');
BEGIN
  IF private.method_kind(private.parse_method(p_method)) <> 'mobile_money' THEN
    RETURN p_phone;
  END IF;
  SELECT phone INTO v_own FROM public.users WHERE id = v_id;
  IF v_given IS NOT NULL AND right(v_given, 9) <> right(regexp_replace(v_own, '\D', '', 'g'), 9) THEN
    PERFORM private.raise_api(400, 'PHONE_NOT_OWN',
      'Deposits and withdrawals use your registered phone number. Pay from and receive to that number.');
  END IF;
  RETURN v_own;
END $$;

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
  v_result jsonb;
BEGIN
  PERFORM private.check_len(v_code, 'platformCode', 1, 64, false);
  v_result := private.customer_order_request('deposit', p_method, p_amount,
    private.customer_own_phone(p_method, p_phone_number), p_account_id, p_winwin_id, p_idempotency_key);
  IF v_code IS NOT NULL AND private.is_cashdesk_method(private.parse_method(p_method)) THEN
    -- Only on the first call: a replayed request leaves the order as it is.
    UPDATE public.orders SET platform_code = v_code
    WHERE id = (v_result ->> 'id')::uuid AND platform_code IS NULL AND auto_claimed_at IS NULL AND status = 'pending';
    IF FOUND THEN
      PERFORM private.platform_kick();
    END IF;
  END IF;
  RETURN v_result;
END
$$;

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
    private.customer_own_phone(p_method, p_phone_number), p_account_id, p_winwin_id, p_idempotency_key);
BEGIN
  IF private.is_cashdesk_method(private.parse_method(p_method)) THEN
    PERFORM private.platform_kick();
  END IF;
  RETURN v_result;
END
$$;
