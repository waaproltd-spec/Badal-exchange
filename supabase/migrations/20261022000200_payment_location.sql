-- Payment Location for cash-desk deposits (1XBET, 888STARZ): the city and
-- street the platform asks for when the customer makes a payment code at
-- a cash desk. Shown on the Customer App's Complete Deposit screen with a
-- Copy button each; set per company by management in the Agent App.
-- No location (both empty) shows no card.

ALTER TABLE public.payment_methods
  ADD COLUMN IF NOT EXISTS payment_city TEXT,
  ADD COLUMN IF NOT EXISTS payment_street TEXT;

UPDATE public.payment_methods SET payment_city = 'Mogadishu', payment_street = 'FURAHA 5'
WHERE method IN ('onexbet', '888starz') AND payment_city IS NULL AND payment_street IS NULL;

CREATE OR REPLACE FUNCTION private.payment_location_json(m public.payment_methods)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN m.payment_city IS NULL AND m.payment_street IS NULL THEN NULL
    ELSE jsonb_build_object('city', m.payment_city, 'street', m.payment_street) END
$$;

-- As before, plus paymentLocation {city, street} or null.
CREATE OR REPLACE FUNCTION public.customer_payment_methods()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'method', m.method, 'label', m.label, 'kind', m.kind, 'color', m.color, 'initials', m.initials,
      'depositNumbers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('number', n.number, 'label', n.label) ORDER BY n.created_at)
        FROM public.deposit_numbers n WHERE n.method = m.method AND n.enabled
      ), '[]'::jsonb),
      'minWithdraw', (SELECT private.money(l.min_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'maxWithdraw', (SELECT private.money(l.max_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'paymentLocation', private.payment_location_json(m)
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m WHERE m.enabled
  ), '[]'::jsonb);
END
$$;

-- As before, plus paymentLocation {city, street} or null.
CREATE OR REPLACE FUNCTION public.manage_payment_methods()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'method', m.method, 'label', m.label, 'kind', m.kind, 'color', m.color, 'initials', m.initials,
      'order', m.sort_order, 'enabled', m.enabled, 'updatedAt', m.updated_at,
      'depositRate', (SELECT r.rate::float8 FROM public.exchange_rates r
                      WHERE r.method = m.method AND r.direction = 'deposit' AND r.active ORDER BY r.created_at DESC LIMIT 1),
      'withdrawRate', (SELECT r.rate::float8 FROM public.exchange_rates r
                       WHERE r.method = m.method AND r.direction = 'withdraw' AND r.active ORDER BY r.created_at DESC LIMIT 1),
      -- flat fees are cents; percent fees 0-100.
      'depositFee', (SELECT jsonb_build_object('type', f.fee_type, 'value', f.value::float8) FROM public.fees f
                     WHERE f.method = m.method AND f.direction = 'deposit' AND f.active ORDER BY f.created_at DESC LIMIT 1),
      'withdrawFee', (SELECT jsonb_build_object('type', f.fee_type, 'value', f.value::float8) FROM public.fees f
                      WHERE f.method = m.method AND f.direction = 'withdraw' AND f.active ORDER BY f.created_at DESC LIMIT 1),
      'minWithdraw', (SELECT private.money(l.min_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'maxWithdraw', (SELECT private.money(l.max_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'paymentLocation', private.payment_location_json(m)
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m
  ), '[]'::jsonb);
END
$$;

-- Sets a cash-desk company's Payment Location. Empty values clear it; both
-- empty hides the card.
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
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Payment Location is only for 1XBET and 888STARZ');
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

REVOKE ALL ON FUNCTION public.manage_set_payment_location(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_set_payment_location(text, text, text) TO authenticated;
