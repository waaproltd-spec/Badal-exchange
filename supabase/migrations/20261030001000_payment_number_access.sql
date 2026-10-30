-- Payment-number authorization for selected customers.
--
-- Until now a mobile-money deposit (EVC Plus, Golis, ZAAD, eDahab) is paid
-- from, and a withdrawal paid to, the customer's registered login phone
-- only (private.customer_own_phone). That stays the rule for everyone, with
-- one exception an admin switches on for one customer at a time:
--
--   * an authorized customer may name another phone number for a deposit
--     (the number the money is sent from; the SMS is matched against it) and
--     for a withdrawal (where it is paid out), for the networks the admin
--     allowed (EVC Plus, Golis, ZAAD, eDahab -- all four by default);
--   * a number used this way is registered for the customer
--     (customer_payment_numbers), so management sees every number, can add
--     one, block one and unblock or remove it;
--   * the admin can revoke the permission at any time: from then on the
--     customer is back to the registered number (the numbers stay on file);
--   * a customer without permission is unchanged: another number is refused
--     with the same PHONE_NOT_OWN error as before.
-- The check is made where every deposit / withdrawal request already passes
-- (private.customer_own_phone), so no app version or direct API call can get
-- round it. Betting platforms are not touched (they use the player's ID).

CREATE TABLE IF NOT EXISTS public.payment_number_grants (
  customer_id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  methods     public.order_method[] NOT NULL DEFAULT ARRAY['evc_plus', 'golis', 'telesom', 'edahab']::public.order_method[],
  note        TEXT,
  granted_by  UUID REFERENCES public.users(id) ON DELETE SET NULL,
  granted_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  revoked_by  UUID REFERENCES public.users(id) ON DELETE SET NULL,
  revoked_at  TIMESTAMPTZ,
  CHECK (cardinality(methods) > 0)
);
ALTER TABLE public.payment_number_grants ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_number_grants FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.customer_payment_numbers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  method      public.order_method NOT NULL,
  phone       TEXT NOT NULL,
  phone_key   TEXT NOT NULL,
  label       TEXT,
  added_by    UUID REFERENCES public.users(id) ON DELETE SET NULL,
  added_by_customer BOOLEAN NOT NULL DEFAULT false,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_used_at TIMESTAMPTZ,
  uses        INTEGER NOT NULL DEFAULT 0,
  blocked_at  TIMESTAMPTZ,
  blocked_by  UUID REFERENCES public.users(id) ON DELETE SET NULL,
  UNIQUE (customer_id, method, phone_key)
);
ALTER TABLE public.customer_payment_numbers ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_payment_numbers FROM PUBLIC, anon, authenticated;
CREATE INDEX IF NOT EXISTS customer_payment_numbers_customer_idx ON public.customer_payment_numbers (customer_id);

-- The four networks the permission covers (ZAAD is Telesom's).
CREATE OR REPLACE FUNCTION private.payment_number_methods()
RETURNS public.order_method[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['evc_plus', 'golis', 'telesom', 'edahab']::public.order_method[]
$$;

-- A network named by an app or an admin: evc_plus, golis, telesom (or zaad), edahab.
CREATE OR REPLACE FUNCTION private.payment_number_method(p_method text)
RETURNS public.order_method LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := lower(btrim(COALESCE(p_method, '')));
BEGIN
  v := CASE v WHEN 'zaad' THEN 'telesom' WHEN 'evc' THEN 'evc_plus' ELSE v END;
  IF v NOT IN ('evc_plus', 'golis', 'telesom', 'edahab') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Network must be EVC Plus, Golis, ZAAD or eDahab');
  END IF;
  RETURN v::public.order_method;
END $$;

-- A phone number as it is kept: 252 + the last 9 digits.
CREATE OR REPLACE FUNCTION private.payment_number_clean(p_phone text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE v text := regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g');
BEGIN
  IF length(v) < 9 OR length(v) > 15 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter a valid phone number (9 digits, with or without 252)');
  END IF;
  RETURN '252' || right(v, 9);
END $$;

-- Is this customer allowed to use another number for this network?
CREATE OR REPLACE FUNCTION private.payment_number_allowed(p_customer uuid, p_method public.order_method)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.payment_number_grants g
                 WHERE g.customer_id = p_customer AND g.enabled AND p_method = ANY (g.methods))
$$;

-- Registers (or finds) a number for a customer; refuses a blocked one and
-- more than 20 numbers a network.
CREATE OR REPLACE FUNCTION private.payment_number_register(
  p_customer uuid, p_method public.order_method, p_phone text, p_label text, p_by uuid, p_by_customer boolean, p_use boolean)
RETURNS public.customer_payment_numbers LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_phone text := private.payment_number_clean(p_phone);
  v_key text := private.phone_key(v_phone);
  n public.customer_payment_numbers;
BEGIN
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
  -- Another customer's login number stays theirs: a payment from it is credited to them.
  IF EXISTS (SELECT 1 FROM public.users u WHERE u.id <> p_customer AND u.role = 'customer' AND private.phone_key(u.phone) = v_key) THEN
    PERFORM private.raise_api(400, 'PAYMENT_NUMBER_TAKEN', 'This phone number belongs to another account. Use a different number.');
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

-- The one place the phone of a mobile-money order is decided. Own number as
-- before; another number only for a customer an admin authorized for the network.
CREATE OR REPLACE FUNCTION private.customer_own_phone(p_method text, p_phone text)
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
  n := private.payment_number_register(v_id, v_m, v_given, NULL, v_id, true, true);
  RETURN n.phone;
END $$;

-- ---------------------------------------------------------------- customer

-- What the customer may do: allowed or not, the networks, and the numbers on file.
CREATE OR REPLACE FUNCTION public.customer_payment_numbers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  g public.payment_number_grants;
BEGIN
  SELECT * INTO g FROM public.payment_number_grants WHERE customer_id = v_id AND enabled;
  IF g.customer_id IS NULL THEN
    RETURN jsonb_build_object('allowed', false, 'methods', '[]'::jsonb, 'numbers', '[]'::jsonb);
  END IF;
  RETURN jsonb_build_object('allowed', true, 'methods', to_jsonb(g.methods), 'numbers', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', n.id, 'method', n.method, 'phone', n.phone, 'label', n.label,
                                        'lastUsedAt', n.last_used_at) ORDER BY n.last_used_at DESC NULLS LAST, n.created_at DESC)
    FROM public.customer_payment_numbers n
    WHERE n.customer_id = v_id AND n.blocked_at IS NULL AND n.method = ANY (g.methods)), '[]'::jsonb));
END $$;

-- An authorized customer saves a number for later (it is also saved the first time they use it).
CREATE OR REPLACE FUNCTION public.customer_add_payment_number(p_method text, p_phone text, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_m public.order_method := private.payment_number_method(p_method);
  n public.customer_payment_numbers;
BEGIN
  IF NOT private.payment_number_allowed(v_id, v_m) THEN
    PERFORM private.raise_api(403, 'PAYMENT_NUMBER_NOT_ALLOWED', 'You are not allowed to use another phone number for this network.');
  END IF;
  n := private.payment_number_register(v_id, v_m, p_phone, p_label, v_id, true, false);
  RETURN jsonb_build_object('id', n.id, 'method', n.method, 'phone', n.phone, 'label', n.label);
END $$;

-- -------------------------------------------------------------- management

CREATE OR REPLACE FUNCTION private.payment_number_access_json(p_customer uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT jsonb_build_object('enabled', g.enabled, 'methods', to_jsonb(g.methods), 'note', g.note,
                      'grantedAt', g.granted_at, 'grantedBy', (SELECT u.name FROM public.users u WHERE u.id = g.granted_by),
                      'revokedAt', g.revoked_at, 'revokedBy', (SELECT u.name FROM public.users u WHERE u.id = g.revoked_by))
                   FROM public.payment_number_grants g WHERE g.customer_id = p_customer),
                  jsonb_build_object('enabled', false, 'methods', '[]'::jsonb))
$$;

-- Customers with whether they are authorized and how many numbers they have.
-- p_filter: all | authorized | revoked. p_query: name, phone or account ID.
CREATE OR REPLACE FUNCTION public.manage_payment_number_customers(p_query text DEFAULT NULL, p_filter text DEFAULT 'all')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_filter text := COALESCE(NULLIF(btrim(p_filter), ''), 'all');
  v_q text := NULLIF(btrim(COALESCE(p_query, '')), '');
BEGIN
  IF v_filter NOT IN ('all', 'authorized', 'revoked') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid filter');
  END IF;
  RETURN jsonb_build_object('customers', COALESCE((
    SELECT jsonb_agg(row_to_json(r)::jsonb ORDER BY r.enabled DESC NULLS LAST, r.name) FROM (
      SELECT u.id, u.name, u.phone, private.account_code(u.id) AS "accountId",
             COALESCE(g.enabled, false) AS enabled, g.methods, g.granted_at AS "grantedAt", g.revoked_at AS "revokedAt",
             (SELECT count(*) FROM public.customer_payment_numbers n WHERE n.customer_id = u.id)::int AS "numberCount"
      FROM public.users u
      LEFT JOIN public.payment_number_grants g ON g.customer_id = u.id
      WHERE u.role = 'customer'
        AND (v_q IS NULL OR u.name ILIKE '%' || v_q || '%' OR u.phone ILIKE '%' || v_q || '%'
             OR private.account_code(u.id) ILIKE '%' || upper(v_q) || '%'
             OR EXISTS (SELECT 1 FROM public.customer_payment_numbers n WHERE n.customer_id = u.id AND n.phone ILIKE '%' || v_q || '%'))
        AND (v_filter = 'all'
          OR (v_filter = 'authorized' AND COALESCE(g.enabled, false))
          OR (v_filter = 'revoked' AND g.customer_id IS NOT NULL AND NOT g.enabled))
      ORDER BY COALESCE(g.enabled, false) DESC, u.name
      LIMIT 100) r), '[]'::jsonb));
END $$;

-- One customer: the permission and every number on file with its use.
CREATE OR REPLACE FUNCTION public.manage_customer_payment_numbers(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  u public.users;
BEGIN
  SELECT * INTO u FROM public.users WHERE id = p_customer_id AND role = 'customer';
  IF u.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  RETURN jsonb_build_object(
    'customer', jsonb_build_object('id', u.id, 'name', u.name, 'phone', u.phone, 'accountId', private.account_code(u.id)),
    'access', private.payment_number_access_json(u.id),
    'numbers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('id', n.id, 'method', n.method, 'phone', n.phone, 'label', n.label,
               'addedBy', CASE WHEN n.added_by_customer THEN 'customer' ELSE 'admin' END,
               'createdAt', n.created_at, 'lastUsedAt', n.last_used_at, 'uses', n.uses,
               'blocked', n.blocked_at IS NOT NULL, 'blockedAt', n.blocked_at) ORDER BY n.method, n.created_at DESC)
      FROM public.customer_payment_numbers n WHERE n.customer_id = u.id), '[]'::jsonb));
END $$;

-- Grants, changes or revokes the permission. p_methods null: all four networks.
CREATE OR REPLACE FUNCTION public.manage_set_payment_number_access(
  p_customer_id uuid, p_enabled boolean, p_methods text[] DEFAULT NULL, p_note text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_before jsonb;
  v_methods public.order_method[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  IF p_enabled IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'enabled is required');
  END IF;
  v_before := private.payment_number_access_json(p_customer_id);
  IF p_methods IS NULL OR cardinality(p_methods) = 0 THEN
    v_methods := private.payment_number_methods();
  ELSE
    SELECT array_agg(DISTINCT private.payment_number_method(m)) INTO v_methods FROM unnest(p_methods) m;
  END IF;
  IF p_enabled THEN
    INSERT INTO public.payment_number_grants (customer_id, enabled, methods, note, granted_by, granted_at)
    VALUES (p_customer_id, true, v_methods, NULLIF(btrim(COALESCE(p_note, '')), ''), v_id, now())
    ON CONFLICT (customer_id) DO UPDATE SET enabled = true, methods = EXCLUDED.methods,
      note = COALESCE(EXCLUDED.note, public.payment_number_grants.note),
      granted_by = CASE WHEN public.payment_number_grants.enabled THEN public.payment_number_grants.granted_by ELSE v_id END,
      granted_at = CASE WHEN public.payment_number_grants.enabled THEN public.payment_number_grants.granted_at ELSE now() END,
      revoked_by = NULL, revoked_at = NULL;
  ELSE
    UPDATE public.payment_number_grants SET enabled = false, revoked_by = v_id, revoked_at = now(),
      note = COALESCE(NULLIF(btrim(COALESCE(p_note, '')), ''), note)
    WHERE customer_id = p_customer_id AND enabled;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_enabled THEN 'payment_numbers.grant' ELSE 'payment_numbers.revoke' END,
    'customer', p_customer_id::text, v_before, private.payment_number_access_json(p_customer_id));
  RETURN private.payment_number_access_json(p_customer_id);
END $$;

-- Management registers a number for a customer.
CREATE OR REPLACE FUNCTION public.manage_add_payment_number(p_customer_id uuid, p_method text, p_phone text, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_m public.order_method := private.payment_number_method(p_method);
  n public.customer_payment_numbers;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  n := private.payment_number_register(p_customer_id, v_m, p_phone, p_label, v_id, false, false);
  PERFORM private.audit(v_id, private.app_role(), 'payment_numbers.add', 'customer', p_customer_id::text, NULL,
    jsonb_build_object('method', n.method, 'phone', n.phone));
  RETURN jsonb_build_object('id', n.id, 'method', n.method, 'phone', n.phone, 'label', n.label);
END $$;

-- Blocks or unblocks one number (a blocked number is refused for the customer).
CREATE OR REPLACE FUNCTION public.manage_set_payment_number_blocked(p_number_id uuid, p_blocked boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  n public.customer_payment_numbers;
BEGIN
  UPDATE public.customer_payment_numbers
  SET blocked_at = CASE WHEN p_blocked THEN COALESCE(blocked_at, now()) END,
      blocked_by = CASE WHEN p_blocked THEN v_id END
  WHERE id = p_number_id RETURNING * INTO n;
  IF n.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Number not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_blocked THEN 'payment_numbers.block' ELSE 'payment_numbers.unblock' END,
    'customer', n.customer_id::text, NULL, jsonb_build_object('method', n.method, 'phone', n.phone));
  RETURN jsonb_build_object('id', n.id, 'blocked', n.blocked_at IS NOT NULL);
END $$;

-- Removes one number from the customer's list (orders already made keep theirs).
CREATE OR REPLACE FUNCTION public.manage_remove_payment_number(p_number_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  n public.customer_payment_numbers;
BEGIN
  DELETE FROM public.customer_payment_numbers WHERE id = p_number_id RETURNING * INTO n;
  IF n.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Number not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'payment_numbers.remove', 'customer', n.customer_id::text,
    jsonb_build_object('method', n.method, 'phone', n.phone), NULL);
  RETURN jsonb_build_object('id', n.id, 'removed', true);
END $$;

REVOKE ALL ON FUNCTION public.customer_payment_numbers(), public.customer_add_payment_number(text, text, text),
  public.manage_payment_number_customers(text, text), public.manage_customer_payment_numbers(uuid),
  public.manage_set_payment_number_access(uuid, boolean, text[], text), public.manage_add_payment_number(uuid, text, text, text),
  public.manage_set_payment_number_blocked(uuid, boolean), public.manage_remove_payment_number(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_payment_numbers(), public.customer_add_payment_number(text, text, text),
  public.manage_payment_number_customers(text, text), public.manage_customer_payment_numbers(uuid),
  public.manage_set_payment_number_access(uuid, boolean, text[], text), public.manage_add_payment_number(uuid, text, text, text),
  public.manage_set_payment_number_blocked(uuid, boolean), public.manage_remove_payment_number(uuid) TO authenticated;
