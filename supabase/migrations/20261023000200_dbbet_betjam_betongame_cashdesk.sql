-- DBbet, BetJam and BetOnGame orders through their own CashdeskBot cash
-- registers, exactly like WinWin and Betwinner (20261022000300/0400), with
-- the @Badaldbbetbot, @Badalbetjambot and @Badalbetongamebot Telegram bots.
-- Orders created before this migration stay manual; until a brand's
-- CASHDESKBOT_<BRAND>_* secrets are set, the worker hands its orders back to
-- the agents (not_sent).

-- BetJam and BetOnGame join the catalog after Betwinner, with Betwinner's
-- current rates, fees and withdrawal limits (editable in the Agent App).
INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order)
VALUES ('betjam', 'BetJam', 'platform', '#F5B301', 'BJ', 9),
       ('betongame', 'BetOnGame', 'platform', '#2EE6C5', 'BG', 10)
ON CONFLICT (method) DO NOTHING;
UPDATE public.payment_methods SET sort_order = 11 WHERE method = '888starz';

INSERT INTO public.exchange_rates (method, direction, rate)
SELECT n.method, r.direction, r.rate
FROM public.exchange_rates r
CROSS JOIN (VALUES ('betjam'::public.order_method), ('betongame'::public.order_method)) n(method)
WHERE r.method = 'betwinner' AND r.active
  AND NOT EXISTS (SELECT 1 FROM public.exchange_rates x WHERE x.method = n.method AND x.direction = r.direction AND x.active);

INSERT INTO public.fees (method, direction, fee_type, value)
SELECT n.method, f.direction, f.fee_type, f.value
FROM public.fees f
CROSS JOIN (VALUES ('betjam'::public.order_method), ('betongame'::public.order_method)) n(method)
WHERE f.method = 'betwinner' AND f.active
  AND NOT EXISTS (SELECT 1 FROM public.fees x WHERE x.method = n.method AND x.direction = f.direction AND x.active);

INSERT INTO public.withdrawal_limits (method, min_cents, max_cents)
SELECT n.method, l.min_cents, l.max_cents
FROM public.withdrawal_limits l
CROSS JOIN (VALUES ('betjam'::public.order_method), ('betongame'::public.order_method)) n(method)
WHERE l.method = 'betwinner'
ON CONFLICT (method) DO NOTHING;

INSERT INTO public.app_settings (key, value)
VALUES ('platform_auto_since:dbbet', now()::text),
       ('platform_auto_since:betjam', now()::text),
       ('platform_auto_since:betongame', now()::text)
ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_method::text IN ('888starz', 'onexbet', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame')
$$;

-- As before; each bot's deposits and payouts move its own register.
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
  v_method public.order_method := CASE p_audit->>'brand'
    WHEN '1xbet' THEN 'onexbet' WHEN 'winwin' THEN 'winwin' WHEN 'betwinner' THEN 'betwinner'
    WHEN 'dbbet' THEN 'dbbet' WHEN 'betjam' THEN 'betjam' WHEN 'betongame' THEN 'betongame'
    ELSE '888starz' END;
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
    PERFORM private.raise_api(400, 'VALIDATION_ERROR',
      'Payment Location is only for 1XBET, 888STARZ, WinWin, Betwinner, DBbet, BetJam and BetOnGame');
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
