-- Merchant payment codes for mobile-money deposits (EVC Plus, Golis, ZAAD),
-- behind a per-method switch that is OFF by default. While it is off the
-- method works exactly as before (EVC Plus: the *712* transfer to the
-- deposit number, confirmed automatically from the carrier's SMS).
--
-- When management switches it on for a method, the Customer App's Complete
-- Deposit shows that method's merchant code (e.g. *789*090353102*AMOUNT#)
-- to dial instead. Merchant payments send no SMS and the carriers publish
-- no merchant transaction feed we are authorized to read, so such deposits
-- are confirmed by an agent from the merchant account; nothing is credited
-- from a dial attempt or a screenshot. They are marked via_merchant and
-- wait up to 24 hours for that check instead of expiring after 30 minutes.

ALTER TABLE public.payment_methods
  ADD COLUMN IF NOT EXISTS merchant_ussd TEXT,
  ADD COLUMN IF NOT EXISTS merchant_ussd_enabled BOOLEAN NOT NULL DEFAULT false;
ALTER TABLE public.payment_methods DROP CONSTRAINT IF EXISTS payment_methods_merchant_ussd_check;
ALTER TABLE public.payment_methods ADD CONSTRAINT payment_methods_merchant_ussd_check CHECK (
  (merchant_ussd IS NULL OR merchant_ussd ~ '^\*[0-9]+(\*[0-9]+)*\*\{amount\}#$')
  AND (NOT merchant_ussd_enabled OR merchant_ussd IS NOT NULL));

UPDATE public.payment_methods m SET merchant_ussd = v.code
FROM (VALUES ('evc_plus', '*789*090353102*{amount}#'),
             ('golis', '*884*353102*{amount}#'),
             ('telesom', '*883*090353102*{amount}#')) AS v(method, code)
WHERE m.method::text = v.method AND m.merchant_ussd IS NULL;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS via_merchant BOOLEAN NOT NULL DEFAULT false;

-- A deposit is a merchant one when its method's switch is on as it is made.
CREATE OR REPLACE FUNCTION private.orders_mark_merchant()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'deposit' THEN
    NEW.via_merchant := COALESCE((SELECT merchant_ussd_enabled FROM public.payment_methods
                                  WHERE method = NEW.method AND kind = 'mobile_money'), false);
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS orders_mark_merchant ON public.orders;
CREATE TRIGGER orders_mark_merchant BEFORE INSERT ON public.orders
FOR EACH ROW EXECUTE FUNCTION private.orders_mark_merchant();
REVOKE ALL ON FUNCTION private.orders_mark_merchant() FROM PUBLIC, anon, authenticated;

-- As before, but merchant deposits get 24 hours for an agent to confirm them.
CREATE OR REPLACE FUNCTION private.expire_unpaid_deposits()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.orders;
  n integer := 0;
BEGIN
  FOR o IN
    UPDATE public.orders SET status = 'expired', failure_reason = private.unpaid_deposit_reason(), updated_at = now()
    WHERE direction = 'deposit' AND status = 'pending'
      AND created_at < now() - CASE WHEN via_merchant THEN interval '24 hours' ELSE interval '30 minutes' END
      AND method IN (SELECT method FROM public.payment_methods WHERE kind = 'mobile_money')
    RETURNING *
  LOOP
    PERFORM private.order_audit(o.id, 'deposit_expired_unpaid', jsonb_build_object('status', 'pending'),
      jsonb_build_object('status', 'expired', 'reason', o.failure_reason), NULL);
    n := n + 1;
  END LOOP;
  RETURN n;
END $$;
REVOKE ALL ON FUNCTION private.expire_unpaid_deposits() FROM PUBLIC, anon, authenticated;

-- As before, plus merchantUssd (the code to dial, '{amount}' to fill in)
-- when the method's merchant switch is on.
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
      'paymentLocation', private.payment_location_json(m),
      'merchantUssd', CASE WHEN m.merchant_ussd_enabled THEN m.merchant_ussd END
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m WHERE m.enabled
  ), '[]'::jsonb);
END
$$;

-- As before, plus merchantUssd / merchantUssdEnabled.
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
      'paymentLocation', private.payment_location_json(m),
      'merchantUssd', m.merchant_ussd, 'merchantUssdEnabled', m.merchant_ussd_enabled
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m
  ), '[]'::jsonb);
END
$$;

-- Sets a mobile-money method's merchant code and switch. The code must look
-- like *789*090353102*{amount}#; switching on needs a code.
CREATE OR REPLACE FUNCTION public.manage_set_merchant_ussd(p_method text, p_code text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  v_code text := NULLIF(regexp_replace(COALESCE(p_code, ''), '\s', '', 'g'), '');
  v_before public.payment_methods;
  m public.payment_methods;
BEGIN
  SELECT * INTO v_before FROM public.payment_methods WHERE method = v_method;
  IF v_before.kind IS DISTINCT FROM 'mobile_money' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Merchant codes are only for mobile money');
  END IF;
  IF v_code IS NOT NULL AND v_code !~ '^\*[0-9]+(\*[0-9]+)*\*\{amount\}#$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Write the code like *789*090353102*{amount}#');
  END IF;
  IF COALESCE(p_enabled, false) AND v_code IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the merchant code before switching it on');
  END IF;
  UPDATE public.payment_methods SET merchant_ussd = v_code, merchant_ussd_enabled = COALESCE(p_enabled, false),
    updated_by = v_id, updated_at = now()
  WHERE method = v_method RETURNING * INTO m;
  PERFORM private.audit(v_id, private.app_role(), 'payment_method.merchant_ussd', 'payment_method', v_method::text,
    jsonb_build_object('code', v_before.merchant_ussd, 'enabled', v_before.merchant_ussd_enabled),
    jsonb_build_object('code', m.merchant_ussd, 'enabled', m.merchant_ussd_enabled));
  RETURN jsonb_build_object('method', m.method, 'merchantUssd', m.merchant_ussd, 'merchantUssdEnabled', m.merchant_ussd_enabled);
END
$$;

REVOKE ALL ON FUNCTION public.manage_set_merchant_ussd(text, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_set_merchant_ussd(text, text, boolean) TO authenticated;
