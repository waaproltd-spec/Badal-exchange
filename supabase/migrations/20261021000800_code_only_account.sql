-- 1XBET / 888STARZ deposits by payment code only.
--
-- CashdeskBot cashes a code only for a given player ID (Deposit/{userId}/
-- Payout), so the app no longer asks for it on the deposit page: the
-- backend uses the ID the customer last used with that platform (any
-- deposit or withdrawal). Only a customer who has never used the platform
-- here gets ACCOUNT_ID_REQUIRED, and the app then asks for it that once.

CREATE OR REPLACE FUNCTION private.last_platform_account(p_customer uuid, p_method public.order_method)
RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT o.winwin_id FROM public.orders o
  WHERE o.customer_id = p_customer AND o.method = p_method AND NULLIF(btrim(o.winwin_id), '') IS NOT NULL
  ORDER BY o.created_at DESC LIMIT 1
$$;

-- The customer's saved account ID for a platform, or null.
CREATE OR REPLACE FUNCTION public.customer_platform_account(p_method text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('customer');
BEGIN
  RETURN jsonb_build_object('accountId', private.last_platform_account(v_id, private.parse_method(p_method)));
END $$;

REVOKE ALL ON FUNCTION public.customer_platform_account(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_platform_account(text) TO authenticated, service_role;

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
  v_account text := COALESCE(NULLIF(btrim(COALESCE(p_account_id, '')), ''), NULLIF(btrim(COALESCE(p_winwin_id, '')), ''));
BEGIN
  IF v_account IS NULL AND private.is_cashdesk_method(private.parse_method(p_method)) THEN
    -- Payment code only: the player ID CashdeskBot needs is the one this
    -- customer used before with this platform.
    v_account := private.last_platform_account(private.require_role('customer'), private.parse_method(p_method));
    IF v_account IS NULL THEN
      PERFORM private.raise_api(400, 'ACCOUNT_ID_REQUIRED',
        'Enter your ' || private.method_label(private.parse_method(p_method)) || ' account ID once');
    END IF;
  END IF;
  PERFORM private.check_len(v_code, 'platformCode', 1, 64, false);
  -- A withdrawal code for a cash-desk platform says the amount itself: the
  -- order is created with a 1-cent placeholder, flagged, until the
  -- platform pays it out.
  v_unknown := v_amount IS NULL AND v_code IS NOT NULL AND private.is_cashdesk_method(private.parse_method(p_method));
  v_result := private.customer_order_request('deposit', p_method, COALESCE(v_amount, CASE WHEN v_unknown THEN '0.01' END),
    private.customer_own_phone(p_method, p_phone_number), v_account, NULL, p_idempotency_key);
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
