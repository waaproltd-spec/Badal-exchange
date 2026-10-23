-- WinWin orders through its own CashdeskBot cash register, exactly like
-- 1XBET (20261021000300_onexbet_cashdesk.sql): automatic deposits by the
-- customer's withdrawal code and automatic payouts, Company Balances,
-- player search, the Payment Location setting and the @Badalwinwinbot
-- Telegram bot. WinWin orders created before this migration stay manual:
-- one may already have been handled by hand. Until the CASHDESKBOT_WINWIN_*
-- secrets are set, the worker hands WinWin orders back to the agents
-- (not_sent), as before.

INSERT INTO public.app_settings (key, value) VALUES ('platform_auto_since:winwin', now()::text)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_method::text IN ('888starz', 'onexbet', 'winwin')
$$;

-- As before; the WinWin bot's deposits and payouts move the WinWin register.
CREATE OR REPLACE FUNCTION public.cashdeskbot_finish(
  p_action text, p_user_id text, p_audit jsonb, p_idempotency_key text DEFAULT NULL, p_response jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := CASE p_audit->>'brand' WHEN '1xbet' THEN 'onexbet' WHEN 'winwin' THEN 'winwin' ELSE '888starz' END;
  v_amount numeric;
  v_at timestamptz;
BEGIN
  IF p_action NOT IN ('deposit', 'payout') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown action');
  END IF;
  IF p_idempotency_key IS NOT NULL THEN
    UPDATE public.idempotency_keys SET status_code = 200, response_json = p_response
    WHERE key = p_idempotency_key AND user_id = v_id AND status_code IS NULL;
    SELECT created_at INTO v_at FROM public.idempotency_keys WHERE key = p_idempotency_key;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'cashdeskbot.' || p_action, 'cashdeskbot_user', p_user_id, NULL, p_audit);

  IF p_idempotency_key IS NOT NULL AND COALESCE((p_response->>'success')::boolean, false) THEN
    v_amount := abs(COALESCE(NULLIF(p_response->>'summa', '')::numeric,
      CASE WHEN p_action = 'deposit' THEN NULLIF(p_audit->>'summa', '')::numeric END));
    IF v_amount IS NOT NULL THEN
      PERFORM private.cashdesk_movement(v_method, CASE WHEN p_action = 'deposit' THEN 'sale' ELSE 'payout' END,
        round(v_amount * 100)::bigint, NULL, 'cashdeskbot:' || p_idempotency_key, v_at);
    END IF;
  END IF;
END
$$;

-- Message names WinWin too.
CREATE OR REPLACE FUNCTION public.manage_set_payment_location(p_method text, p_city text, p_street text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  v_city text := NULLIF(btrim(COALESCE(p_city, '')), '');
  v_street text := NULLIF(btrim(COALESCE(p_street, '')), '');
  v_before public.payment_methods;
  m public.payment_methods;
BEGIN
  IF NOT private.is_cashdesk_method(v_method) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Payment Location is only for 1XBET, 888STARZ and WinWin');
  END IF;
  PERFORM private.check_len(v_city, 'city', 1, 60, false);
  PERFORM private.check_len(v_street, 'street', 1, 80, false);
  SELECT * INTO v_before FROM public.payment_methods WHERE method = v_method;
  UPDATE public.payment_methods SET payment_city = v_city, payment_street = v_street, updated_by = v_id, updated_at = now()
  WHERE method = v_method RETURNING * INTO m;
  PERFORM private.audit(v_id, private.app_role(), 'payment_method.location', 'payment_method', v_method::text,
    jsonb_build_object('city', v_before.payment_city, 'street', v_before.payment_street),
    jsonb_build_object('city', m.payment_city, 'street', m.payment_street));
  RETURN jsonb_build_object('method', m.method, 'paymentLocation', private.payment_location_json(m));
END
$$;
