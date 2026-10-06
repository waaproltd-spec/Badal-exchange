-- Public API (Supabase RPC) used by the Customer App, plus the session and
-- catalog calls both apps use. Each function replaces one REST endpoint of
-- the Node backend and returns the same JSON shape it did. Callable through
-- supabase.rpc('<name>', {...}); the matching REST route is noted on each.

-- ---------------------------------------------------------------------------
-- Session / catalog (both apps)
-- ---------------------------------------------------------------------------

-- POST /auth/customer/register. Creates the account and its wallet; the
-- app then signs in with Supabase Auth. Limited to 10 per 15 minutes per IP
-- address, like the REST auth rate limit.
CREATE OR REPLACE FUNCTION public.register_customer(p_phone text, p_name text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
  v_ip text := private.request_ip();
BEGIN
  PERFORM private.check_len(p_phone, 'phone', 6, 20);
  PERFORM private.check_len(p_name, 'name', 1, 100);
  PERFORM private.check_len(p_password, 'password', 8, 72);

  IF v_ip IS NOT NULL AND (
    SELECT count(*) FROM public.audit_logs
    WHERE action = 'user.register' AND ip = v_ip AND created_at > now() - interval '15 minutes'
  ) >= 10 THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many attempts, try again later.');
  END IF;

  IF EXISTS (SELECT 1 FROM public.users WHERE phone = p_phone)
     OR EXISTS (SELECT 1 FROM auth.users WHERE email = private.auth_email(p_phone, NULL)) THEN
    PERFORM private.raise_api(409, 'PHONE_TAKEN', 'Phone number already registered');
  END IF;

  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('customer', p_phone, p_name, private.hash_password(p_password))
  RETURNING id INTO v_id;
  INSERT INTO public.wallets (customer_id) VALUES (v_id);
  PERFORM private.audit(v_id, 'customer', 'user.register', 'user', v_id::text);
  RETURN jsonb_build_object('user', jsonb_build_object('id', v_id, 'role', 'customer'));
END
$$;

-- Called by both apps right after signing in, and on start-up with a saved
-- session: who is this, and may they use this app? Also writes the login
-- audit entry the REST login wrote.
CREATE OR REPLACE FUNCTION public.session_profile(p_record_login boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  u public.users;
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Missing bearer token');
  END IF;
  SELECT * INTO u FROM public.users WHERE id = auth.uid();
  IF NOT FOUND THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Invalid credentials');
  END IF;
  IF u.status <> 'active' THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Account is disabled');
  END IF;
  IF p_record_login THEN
    PERFORM private.audit(u.id, u.role, 'user.login', 'user', u.id::text);
  END IF;
  RETURN jsonb_build_object(
    'id', u.id, 'role', u.role, 'name', u.name, 'phone', u.phone, 'email', u.email, 'status', u.status
  );
END
$$;

-- GET /meta/payment-methods (public): the method catalog both apps load.
CREATE OR REPLACE FUNCTION public.payment_method_catalog()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'method', method, 'label', label, 'kind', kind, 'color', color, 'initials', initials,
    'order', sort_order, 'enabled', enabled, 'updatedAt', updated_at
  ) ORDER BY sort_order), '[]'::jsonb)
  FROM public.payment_methods
$$;

-- POST /agent/account/password (and the same for any signed-in user).
-- Signs out the user's other sessions.
CREATE OR REPLACE FUNCTION public.change_password(p_current_password text, p_new_password text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_user();
  v_role public.user_role := private.app_role();
  v_session uuid;
BEGIN
  PERFORM private.check_len(p_current_password, 'currentPassword', 1, 200);
  PERFORM private.check_len(p_new_password, 'newPassword', 8, 72);
  IF NOT private.verify_password(p_current_password, (SELECT password_hash FROM public.users WHERE id = v_id)) THEN
    PERFORM private.raise_api(400, 'INVALID_PASSWORD', 'Current password is incorrect');
  END IF;
  UPDATE public.users SET password_hash = private.hash_password(p_new_password), updated_at = now() WHERE id = v_id;
  -- Node-backend sessions, and every other Supabase session.
  UPDATE public.refresh_tokens SET revoked_at = now() WHERE user_id = v_id AND revoked_at IS NULL;
  BEGIN
    v_session := NULLIF(auth.jwt() ->> 'session_id', '')::uuid;
  EXCEPTION WHEN others THEN
    v_session := NULL;
  END;
  DELETE FROM auth.sessions WHERE user_id = v_id AND id IS DISTINCT FROM v_session;
  PERFORM private.audit(v_id, v_role, 'user.change_password', 'user', v_id::text);
END
$$;

-- ---------------------------------------------------------------------------
-- Customer
-- ---------------------------------------------------------------------------

-- GET /customer/wallet
CREATE OR REPLACE FUNCTION public.customer_wallet()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  w public.wallets;
BEGIN
  SELECT * INTO w FROM public.wallets WHERE customer_id = v_id;
  IF NOT FOUND THEN
    w := private.lock_wallet(v_id);
  END IF;
  RETURN jsonb_build_object(
    'availableBalance', private.money(w.available_cents),
    'pendingBalance', private.money(w.pending_cents),
    'totalDeposit', private.money(w.total_deposit_cents),
    'totalWithdraw', private.money(w.total_withdraw_cents)
  );
END
$$;

-- POST /customer/quotes
CREATE OR REPLACE FUNCTION public.customer_quote(p_direction text, p_method text, p_amount text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_cents bigint := private.to_cents(p_amount);
  q record;
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('deposit', 'withdraw') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'direction must be deposit or withdraw');
  END IF;
  q := private.compute_quote(v_method, p_direction::public.order_direction, v_cents);
  RETURN jsonb_build_object(
    'quoteId', format('%s:%s:%s', q.rate_id, COALESCE(q.fee_id::text, 'none'), v_cents),
    'method', v_method,
    'direction', p_direction,
    'amount', private.money(v_cents),
    'rate', q.rate::float8,
    'fee', private.money(q.fee_cents),
    'netAmount', private.money(q.net_cents),
    'walletDelta', private.money(q.wallet_delta_cents)
  );
END
$$;

-- Shared by deposits and withdrawals: mobile-money methods take the
-- customer's phone number, betting platforms their account ID (winwinId is
-- accepted for older app versions).
CREATE OR REPLACE FUNCTION private.customer_order_request(
  p_direction public.order_direction, p_method text, p_amount text,
  p_phone_number text, p_account_id text, p_winwin_id text, p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method;
  v_kind text;
  v_cents bigint;
  v_phone text;
  v_account text;
  v_replay jsonb;
  o public.orders;
BEGIN
  v_method := private.parse_method(p_method);
  v_kind := private.method_kind(v_method);
  v_replay := private.idempotency_begin(
    p_idempotency_key,
    format('customer.%s.%s', CASE WHEN p_direction = 'deposit' THEN 'deposits' ELSE 'withdrawals' END, p_method),
    jsonb_build_object('phoneNumber', p_phone_number, 'accountId', p_account_id, 'winwinId', p_winwin_id, 'amount', p_amount)
  );
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  PERFORM private.check_len(p_phone_number, 'phoneNumber', 6, 20, false);
  PERFORM private.check_len(p_account_id, 'accountId', 3, 30, false);
  PERFORM private.check_len(p_winwin_id, 'winwinId', 3, 30, false);
  IF v_kind = 'mobile_money' THEN
    IF p_phone_number IS NULL THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'phoneNumber is required');
    END IF;
    v_phone := p_phone_number;
  ELSE
    v_account := COALESCE(p_account_id, p_winwin_id);
    IF v_account IS NULL THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'accountId is required');
    END IF;
  END IF;
  v_cents := private.to_cents(p_amount);
  PERFORM private.assert_method_enabled(v_method);

  IF p_direction = 'deposit' THEN
    o := private.create_deposit_order(v_id, v_method, v_cents, v_phone, v_account, p_idempotency_key);
  ELSE
    o := private.create_withdraw_order(v_id, v_method, v_cents, v_phone, v_account, p_idempotency_key);
    -- The MobCash automation worker picks up pending WinWin withdrawals.
    IF v_method = 'winwin' THEN
      PERFORM pg_notify('mobcash_withdrawal', o.id::text);
    END IF;
  END IF;
  RETURN private.idempotency_finish(p_idempotency_key, private.customer_order_json(o), 201);
END
$$;

-- POST /customer/deposits/:method
CREATE OR REPLACE FUNCTION public.customer_create_deposit(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.customer_order_request('deposit', p_method, p_amount, p_phone_number, p_account_id, p_winwin_id, p_idempotency_key)
$$;

-- POST /customer/withdrawals/:method
CREATE OR REPLACE FUNCTION public.customer_create_withdrawal(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT private.customer_order_request('withdraw', p_method, p_amount, p_phone_number, p_account_id, p_winwin_id, p_idempotency_key)
$$;

-- GET /customer/orders
CREATE OR REPLACE FUNCTION public.customer_orders()
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
    SELECT jsonb_agg(private.customer_order_json(o) ORDER BY o.created_at DESC)
    FROM (SELECT * FROM public.orders WHERE customer_id = v_id ORDER BY created_at DESC LIMIT 100) o
  ), '[]'::jsonb);
END
$$;

-- GET /customer/orders/:id
CREATE OR REPLACE FUNCTION public.customer_order(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  o public.orders;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_id AND customer_id = v_id;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Order not found');
  END IF;
  RETURN private.customer_order_json(o);
END
$$;

-- GET /customer/payment-methods: enabled methods with their deposit numbers.
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
      ), '[]'::jsonb)
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m WHERE m.enabled
  ), '[]'::jsonb);
END
$$;

CREATE OR REPLACE FUNCTION private.home_ad_json(a public.home_ads)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', a.id, 'title', a.title, 'body', a.body, 'imageUrl', a.image_url, 'linkUrl', a.link_url,
    'enabled', a.enabled, 'sortOrder', a.sort_order, 'updatedAt', a.updated_at
  )
$$;

CREATE OR REPLACE FUNCTION private.notification_json(n public.notifications)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$ SELECT jsonb_build_object('id', n.id, 'title', n.title, 'body', n.body, 'createdAt', n.created_at) $$;

CREATE OR REPLACE FUNCTION private.contacts_json()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'whatsapp', COALESCE((SELECT value FROM public.app_settings WHERE key = 'contact_whatsapp'), ''),
    'facebook', COALESCE((SELECT value FROM public.app_settings WHERE key = 'contact_facebook'), ''),
    'telegram', COALESCE((SELECT value FROM public.app_settings WHERE key = 'contact_telegram'), '')
  )
$$;

-- GET /customer/home-ads
CREATE OR REPLACE FUNCTION public.customer_home_ads()
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
    SELECT jsonb_agg(private.home_ad_json(a) ORDER BY a.sort_order, a.created_at DESC)
    FROM public.home_ads a WHERE a.enabled
  ), '[]'::jsonb);
END
$$;

-- GET /customer/notifications
CREATE OR REPLACE FUNCTION public.customer_notifications()
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
    SELECT jsonb_agg(private.notification_json(n) ORDER BY n.created_at DESC)
    FROM (SELECT * FROM public.notifications ORDER BY created_at DESC LIMIT 50) n
  ), '[]'::jsonb);
END
$$;

-- GET /customer/contacts
CREATE OR REPLACE FUNCTION public.customer_contacts()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN private.contacts_json();
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.app_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_staff() TO anon, authenticated;
