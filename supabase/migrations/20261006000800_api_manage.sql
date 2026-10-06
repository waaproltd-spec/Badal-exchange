-- Public API (Supabase RPC) for management: the Agent App's Account ->
-- Admin features, i.e. /agent/manage/* (routes/agentConsole.ts), /admin/*
-- (routes/admin.ts). Every function requires private.require_management():
-- an active admin, or an active agent with 'manage_settings'.

-- ---------------------------------------------------------------------------
-- Payment methods, rates, fees, limits
-- ---------------------------------------------------------------------------

-- GET /agent/manage/payment-methods
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
      'maxWithdraw', (SELECT private.money(l.max_cents) FROM public.withdrawal_limits l WHERE l.method = m.method)
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m
  ), '[]'::jsonb);
END
$$;

-- PUT /agent/manage/payment-methods/:method
CREATE OR REPLACE FUNCTION public.manage_set_payment_method(p_method text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  m public.payment_methods;
BEGIN
  IF p_enabled IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'enabled is required');
  END IF;
  UPDATE public.payment_methods SET enabled = p_enabled, updated_by = v_id, updated_at = now()
  WHERE method = v_method RETURNING * INTO m;
  PERFORM private.audit(v_id, private.app_role(), 'payment_method.update', 'payment_method', v_method::text, NULL, to_jsonb(m));
  RETURN jsonb_build_object('method', m.method, 'label', m.label, 'enabled', m.enabled);
END
$$;

CREATE OR REPLACE FUNCTION private.parse_direction(p_direction text)
RETURNS public.order_direction LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_direction IS NULL OR p_direction NOT IN ('deposit', 'withdraw') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'direction must be deposit or withdraw');
  END IF;
  RETURN p_direction::public.order_direction;
END $$;

-- GET /admin/exchange-rates
CREATE OR REPLACE FUNCTION public.admin_exchange_rates()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(r) ORDER BY r.method, r.direction) FROM (
    SELECT DISTINCT ON (method, direction) * FROM public.exchange_rates WHERE active
    ORDER BY method, direction, created_at DESC) r), '[]'::jsonb);
END $$;

-- PUT /admin/exchange-rates: a new active rate; past orders keep theirs.
CREATE OR REPLACE FUNCTION public.admin_set_exchange_rate(p_method text, p_direction text, p_rate numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  v_direction public.order_direction := private.parse_direction(p_direction);
  r public.exchange_rates;
BEGIN
  IF p_rate IS NULL OR p_rate <= 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'rate must be positive');
  END IF;
  UPDATE public.exchange_rates SET active = false WHERE method = v_method AND direction = v_direction AND active;
  INSERT INTO public.exchange_rates (method, direction, rate, created_by)
  VALUES (v_method, v_direction, p_rate, v_id) RETURNING * INTO r;
  PERFORM private.audit(v_id, private.app_role(), 'exchange_rate.update', 'exchange_rate', r.id::text, NULL, to_jsonb(r));
  RETURN to_jsonb(r);
END
$$;

-- GET /admin/fees
CREATE OR REPLACE FUNCTION public.admin_fees()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY f.method, f.direction) FROM (
    SELECT DISTINCT ON (method, direction) * FROM public.fees WHERE active
    ORDER BY method, direction, created_at DESC) f), '[]'::jsonb);
END $$;

-- PUT /admin/fees (flat values in cents, percent values 0-100)
CREATE OR REPLACE FUNCTION public.admin_set_fee(p_method text, p_direction text, p_fee_type text, p_value numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  v_direction public.order_direction := private.parse_direction(p_direction);
  f public.fees;
BEGIN
  IF p_fee_type IS NULL OR p_fee_type NOT IN ('flat', 'percent') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'feeType must be flat or percent');
  END IF;
  IF p_value IS NULL OR p_value < 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'value must be zero or more');
  END IF;
  UPDATE public.fees SET active = false WHERE method = v_method AND direction = v_direction AND active;
  INSERT INTO public.fees (method, direction, fee_type, value, created_by)
  VALUES (v_method, v_direction, p_fee_type::public.fee_type, p_value, v_id) RETURNING * INTO f;
  PERFORM private.audit(v_id, private.app_role(), 'fee.update', 'fee', f.id::text, NULL, to_jsonb(f));
  RETURN to_jsonb(f);
END
$$;

-- GET /admin/withdrawal-limits
CREATE OR REPLACE FUNCTION public.admin_withdrawal_limits()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(l) ORDER BY l.method) FROM public.withdrawal_limits l), '[]'::jsonb);
END $$;

-- PUT /admin/withdrawal-limits (amounts in dollars)
CREATE OR REPLACE FUNCTION public.admin_set_withdrawal_limits(p_method text, p_min_amount numeric, p_max_amount numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  l public.withdrawal_limits;
BEGIN
  IF p_min_amount IS NULL OR p_max_amount IS NULL OR p_min_amount < 0 OR p_max_amount < 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'minAmount and maxAmount must be zero or more');
  END IF;
  INSERT INTO public.withdrawal_limits (method, min_cents, max_cents)
  VALUES (v_method, round(p_min_amount * 100), round(p_max_amount * 100))
  ON CONFLICT (method) DO UPDATE SET min_cents = EXCLUDED.min_cents, max_cents = EXCLUDED.max_cents, updated_at = now()
  RETURNING * INTO l;
  PERFORM private.audit(v_id, private.app_role(), 'withdrawal_limits.update', 'withdrawal_limits', v_method::text, NULL, to_jsonb(l));
  RETURN to_jsonb(l);
END
$$;

-- ---------------------------------------------------------------------------
-- Customer App content: home ads, deposit numbers, notifications, contacts
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.deposit_number_json(n public.deposit_numbers)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('id', n.id, 'method', n.method, 'number', n.number, 'label', n.label,
                            'enabled', n.enabled, 'updatedAt', n.updated_at)
$$;

CREATE OR REPLACE FUNCTION private.check_url(p_value text, p_field text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_value IS NOT NULL AND (char_length(p_value) > 500 OR p_value !~* '^[a-z][a-z0-9+.-]*://[^\s]+$') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', p_field || ' must be a valid URL');
  END IF;
  RETURN p_value;
END $$;

-- GET /agent/manage/home-ads
CREATE OR REPLACE FUNCTION public.manage_home_ads()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.home_ad_json(a) ORDER BY a.sort_order, a.created_at DESC)
                   FROM public.home_ads a), '[]'::jsonb);
END $$;

-- POST /agent/manage/home-ads (p_id NULL) and PUT /agent/manage/home-ads/:id
CREATE OR REPLACE FUNCTION public.manage_save_home_ad(
  p_title text, p_body text DEFAULT NULL, p_image_url text DEFAULT NULL, p_link_url text DEFAULT NULL,
  p_enabled boolean DEFAULT true, p_sort_order int DEFAULT 0, p_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.home_ads;
BEGIN
  PERFORM private.check_len(p_title, 'title', 1, 120);
  PERFORM private.check_len(p_body, 'body', 0, 500, false);
  PERFORM private.check_url(p_image_url, 'imageUrl');
  PERFORM private.check_url(p_link_url, 'linkUrl');
  IF COALESCE(p_sort_order, 0) NOT BETWEEN 0 AND 1000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'sortOrder must be between 0 and 1000');
  END IF;
  IF p_id IS NULL THEN
    INSERT INTO public.home_ads (title, body, image_url, link_url, enabled, sort_order, created_by, updated_by)
    VALUES (p_title, p_body, p_image_url, p_link_url, COALESCE(p_enabled, true), COALESCE(p_sort_order, 0), v_id, v_id)
    RETURNING * INTO a;
    PERFORM private.audit(v_id, private.app_role(), 'home_ad.create', 'home_ad', a.id::text, NULL, to_jsonb(a));
  ELSE
    UPDATE public.home_ads
    SET title = p_title, body = p_body, image_url = p_image_url, link_url = p_link_url,
        enabled = COALESCE(p_enabled, true), sort_order = COALESCE(p_sort_order, 0), updated_by = v_id, updated_at = now()
    WHERE id = p_id RETURNING * INTO a;
    IF a.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Ad not found');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'home_ad.update', 'home_ad', a.id::text, NULL, to_jsonb(a));
  END IF;
  RETURN private.home_ad_json(a);
END
$$;

-- DELETE /agent/manage/home-ads/:id
CREATE OR REPLACE FUNCTION public.manage_delete_home_ad(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.home_ads;
BEGIN
  DELETE FROM public.home_ads WHERE id = p_id RETURNING * INTO a;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Ad not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'home_ad.delete', 'home_ad', p_id::text, to_jsonb(a), NULL);
END $$;

-- GET /agent/manage/deposit-numbers
CREATE OR REPLACE FUNCTION public.manage_deposit_numbers()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.deposit_number_json(n) ORDER BY n.method, n.created_at)
                   FROM public.deposit_numbers n), '[]'::jsonb);
END $$;

-- POST /agent/manage/deposit-numbers (p_id NULL) and PUT .../:id
CREATE OR REPLACE FUNCTION public.manage_save_deposit_number(
  p_method text, p_number text, p_label text DEFAULT NULL, p_enabled boolean DEFAULT true, p_id uuid DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := private.parse_method(p_method);
  v_number text := btrim(COALESCE(p_number, ''));
  n public.deposit_numbers;
BEGIN
  PERFORM private.check_len(p_number, 'number', 3, 40);
  PERFORM private.check_len(p_label, 'label', 0, 80, false);
  IF p_id IS NULL THEN
    INSERT INTO public.deposit_numbers (method, number, label, enabled, created_by, updated_by)
    VALUES (v_method, v_number, p_label, COALESCE(p_enabled, true), v_id, v_id)
    ON CONFLICT (method, number) DO NOTHING
    RETURNING * INTO n;
    IF n.id IS NULL THEN
      PERFORM private.raise_api(409, 'DUPLICATE_DEPOSIT_NUMBER', 'That number is already listed for this method');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'deposit_number.create', 'deposit_number', n.id::text, NULL, to_jsonb(n));
  ELSE
    BEGIN
      UPDATE public.deposit_numbers
      SET method = v_method, number = v_number, label = p_label, enabled = COALESCE(p_enabled, true),
          updated_by = v_id, updated_at = now()
      WHERE id = p_id RETURNING * INTO n;
    EXCEPTION WHEN unique_violation THEN
      PERFORM private.raise_api(409, 'DUPLICATE_DEPOSIT_NUMBER', 'That number is already listed for this method');
    END;
    IF n.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Deposit number not found');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'deposit_number.update', 'deposit_number', n.id::text, NULL, to_jsonb(n));
  END IF;
  RETURN private.deposit_number_json(n);
END
$$;

-- DELETE /agent/manage/deposit-numbers/:id
CREATE OR REPLACE FUNCTION public.manage_delete_deposit_number(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  n public.deposit_numbers;
BEGIN
  DELETE FROM public.deposit_numbers WHERE id = p_id RETURNING * INTO n;
  IF n.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Deposit number not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'deposit_number.delete', 'deposit_number', p_id::text, to_jsonb(n), NULL);
END $$;

-- GET /agent/manage/notifications
CREATE OR REPLACE FUNCTION public.manage_notifications()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.notification_json(n) ORDER BY n.created_at DESC)
                   FROM (SELECT * FROM public.notifications ORDER BY created_at DESC LIMIT 100) n), '[]'::jsonb);
END $$;

-- POST /agent/manage/notifications (customers receive it over Realtime)
CREATE OR REPLACE FUNCTION public.manage_send_notification(p_title text, p_body text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  n public.notifications;
BEGIN
  PERFORM private.check_len(p_title, 'title', 1, 120);
  PERFORM private.check_len(p_body, 'body', 1, 1000);
  INSERT INTO public.notifications (title, body, created_by) VALUES (p_title, p_body, v_id) RETURNING * INTO n;
  PERFORM private.audit(v_id, private.app_role(), 'notification.send', 'notification', n.id::text, NULL, to_jsonb(n));
  RETURN private.notification_json(n);
END $$;

-- PUT /agent/manage/contacts
CREATE OR REPLACE FUNCTION public.manage_set_contacts(p_whatsapp text, p_facebook text, p_telegram text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_values jsonb;
  k text;
BEGIN
  PERFORM private.check_len(p_whatsapp, 'whatsapp', 0, 200);
  PERFORM private.check_len(p_facebook, 'facebook', 0, 200);
  PERFORM private.check_len(p_telegram, 'telegram', 0, 200);
  v_values := jsonb_build_object(
    'contact_whatsapp', btrim(p_whatsapp), 'contact_facebook', btrim(p_facebook), 'contact_telegram', btrim(p_telegram));
  FOR k IN SELECT jsonb_object_keys(v_values) LOOP
    INSERT INTO public.app_settings (key, value, updated_by) VALUES (k, v_values ->> k, v_id)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  END LOOP;
  PERFORM private.audit(v_id, private.app_role(), 'contacts.update', 'app_settings', 'contacts', NULL, v_values);
  RETURN private.contacts_json();
END
$$;

-- ---------------------------------------------------------------------------
-- Agents
-- ---------------------------------------------------------------------------

-- GET /admin/agents
CREATE OR REPLACE FUNCTION public.admin_agents()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', u.id, 'name', u.name, 'phone', u.phone, 'status', u.status, 'created_at', u.created_at,
      'responsibilities', ap.responsibilities, 'last_seen_at', ap.last_seen_at, 'last_device_id', ap.last_device_id
    ) ORDER BY u.created_at DESC)
    FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.role = 'agent'
  ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION private.clean_responsibilities(p_values text[])
RETURNS text[] LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  v text[];
BEGIN
  IF COALESCE(array_length(p_values, 1), 0) > 20
     OR EXISTS (SELECT 1 FROM unnest(p_values) x WHERE x IS NULL OR char_length(x) NOT BETWEEN 1 AND 50) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid responsibilities');
  END IF;
  SELECT COALESCE(array_agg(x ORDER BY first_pos), '{}') INTO v FROM (
    SELECT btrim(x) AS x, min(ord) AS first_pos
    FROM unnest(COALESCE(p_values, '{}')) WITH ORDINALITY t(x, ord)
    WHERE btrim(x) <> '' GROUP BY btrim(x)
  ) s;
  RETURN v;
END $$;

-- POST /admin/agents
CREATE OR REPLACE FUNCTION public.admin_create_agent(
  p_phone text, p_name text, p_password text, p_responsibilities text[] DEFAULT '{}'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  a record;
BEGIN
  PERFORM private.check_len(p_phone, 'phone', 6, 20);
  PERFORM private.check_len(p_name, 'name', 1, 100);
  PERFORM private.check_len(p_password, 'password', 8, 72);
  IF EXISTS (SELECT 1 FROM public.users WHERE phone = p_phone)
     OR EXISTS (SELECT 1 FROM auth.users WHERE email = private.auth_email(p_phone, NULL)) THEN
    PERFORM private.raise_api(409, 'PHONE_TAKEN', 'Phone number already registered');
  END IF;
  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('agent', p_phone, p_name, private.hash_password(p_password))
  RETURNING id, name, phone, status INTO a;
  INSERT INTO public.agent_profiles (user_id, responsibilities)
  VALUES (a.id, private.clean_responsibilities(p_responsibilities));
  PERFORM private.audit(v_id, private.app_role(), 'agent.create', 'user', a.id::text, NULL, to_jsonb(a));
  RETURN to_jsonb(a);
END
$$;

-- POST /admin/agents/:id/enable and /disable
CREATE OR REPLACE FUNCTION public.admin_set_agent_status(p_id uuid, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status public.user_status := CASE WHEN p_enabled THEN 'active' ELSE 'disabled' END;
  before jsonb;
  after jsonb;
BEGIN
  IF NOT p_enabled AND p_id = v_id THEN
    PERFORM private.raise_api(400, 'SELF_LOCKOUT', 'You cannot disable your own account');
  END IF;
  SELECT jsonb_build_object('id', id, 'status', status) INTO before FROM public.users WHERE id = p_id AND role = 'agent';
  IF before IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  UPDATE public.users SET status = v_status, updated_at = now() WHERE id = p_id
  RETURNING jsonb_build_object('id', id, 'status', status) INTO after;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_enabled THEN 'agent.enable' ELSE 'agent.disable' END,
    'user', p_id::text, before, after);
  RETURN after;
END
$$;

-- PUT /admin/agents/:id/responsibilities
CREATE OR REPLACE FUNCTION public.admin_set_agent_responsibilities(p_id uuid, p_responsibilities text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_resp text[] := private.clean_responsibilities(p_responsibilities);
  before jsonb;
  after jsonb;
BEGIN
  IF p_id = v_id AND NOT ('manage_settings' = ANY (v_resp)) THEN
    PERFORM private.raise_api(400, 'SELF_LOCKOUT', 'You cannot remove manage_settings from your own account');
  END IF;
  SELECT jsonb_build_object('user_id', user_id, 'responsibilities', responsibilities) INTO before
  FROM public.agent_profiles WHERE user_id = p_id;
  IF before IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  UPDATE public.agent_profiles SET responsibilities = v_resp WHERE user_id = p_id
  RETURNING jsonb_build_object('user_id', user_id, 'responsibilities', responsibilities) INTO after;
  PERFORM private.audit(v_id, private.app_role(), 'agent.update_responsibilities', 'user', p_id::text, before, after);
  RETURN after;
END
$$;

-- GET /admin/agents/:id/transactions
CREATE OR REPLACE FUNCTION public.admin_agent_transactions(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.admin_order_json(o) ORDER BY o.updated_at DESC)
    FROM (SELECT * FROM public.orders WHERE agent_id = p_id ORDER BY updated_at DESC LIMIT 200) o), '[]'::jsonb);
END $$;

-- GET /admin/agents/:id/devices
CREATE OR REPLACE FUNCTION public.admin_agent_devices(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'device_id', d.device_id, 'device_label', d.device_label, 'status', d.status,
      'registered_at', d.registered_at, 'last_seen_at', d.last_seen_at
    ) ORDER BY d.last_seen_at DESC NULLS LAST)
    FROM public.agent_devices d WHERE d.agent_id = p_id), '[]'::jsonb);
END $$;

-- ---------------------------------------------------------------------------
-- Overview, customers, wallets, orders, ledger, audit, reports
-- ---------------------------------------------------------------------------

-- GET /admin/dashboard/summary
CREATE OR REPLACE FUNCTION public.admin_dashboard_summary()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'totalCustomers', (SELECT count(*)::int FROM public.users WHERE role = 'customer'),
    'totalWalletBalance', (SELECT private.money(COALESCE(sum(available_cents), 0)) FROM public.wallets),
    'totalWalletPending', (SELECT private.money(COALESCE(sum(pending_cents), 0)) FROM public.wallets),
    'todaysDeposits', (SELECT private.money(COALESCE(sum(net_cents), 0)) FROM public.orders
                       WHERE direction = 'deposit' AND status = 'completed' AND completed_at::date = now()::date),
    'todaysWithdrawals', (SELECT private.money(COALESCE(sum(wallet_delta_cents), 0)) FROM public.orders
                          WHERE direction = 'withdraw' AND status = 'completed' AND completed_at::date = now()::date),
    'pendingDeposits', (SELECT count(*)::int FROM public.orders WHERE direction = 'deposit' AND status = 'pending'),
    'pendingWithdrawals', (SELECT count(*)::int FROM public.orders WHERE direction = 'withdraw' AND status IN ('pending', 'processing')),
    'completedTransactions', (SELECT count(*)::int FROM public.orders WHERE status = 'completed'),
    'failedTransactions', (SELECT count(*)::int FROM public.orders WHERE status = 'failed')
  );
END $$;

-- GET /admin/customers
CREATE OR REPLACE FUNCTION public.admin_customers(p_q text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(c.j ORDER BY c.created_at DESC) FROM (
    SELECT u.created_at, jsonb_build_object(
      'id', u.id, 'name', u.name, 'phone', u.phone, 'status', u.status,
      'walletBalance', private.money(COALESCE(w.available_cents, 0)),
      'totalDeposits', private.money(COALESCE(w.total_deposit_cents, 0)),
      'totalWithdrawals', private.money(COALESCE(w.total_withdraw_cents, 0)),
      'registeredAt', u.created_at) AS j
    FROM public.users u LEFT JOIN public.wallets w ON w.customer_id = u.id
    WHERE u.role = 'customer' AND (v_q IS NULL OR u.phone ILIKE '%' || v_q || '%' OR u.name ILIKE '%' || v_q || '%')
    ORDER BY u.created_at DESC LIMIT 200) c), '[]'::jsonb);
END $$;

-- GET /admin/customers/:id
CREATE OR REPLACE FUNCTION public.admin_customer(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v jsonb;
BEGIN
  SELECT jsonb_build_object(
    'id', u.id, 'name', u.name, 'phone', u.phone, 'status', u.status,
    'wallet', jsonb_build_object(
      'availableBalance', private.money(COALESCE(w.available_cents, 0)),
      'pendingBalance', private.money(COALESCE(w.pending_cents, 0)),
      'totalDeposit', private.money(COALESCE(w.total_deposit_cents, 0)),
      'totalWithdraw', private.money(COALESCE(w.total_withdraw_cents, 0))),
    'registeredAt', u.created_at)
  INTO v
  FROM public.users u LEFT JOIN public.wallets w ON w.customer_id = u.id
  WHERE u.id = p_id AND u.role = 'customer';
  IF v IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  RETURN v;
END $$;

-- GET /admin/wallets
CREATE OR REPLACE FUNCTION public.admin_wallets()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(x.j ORDER BY x.updated_at DESC) FROM (
    SELECT w.updated_at, jsonb_build_object(
      'customerId', w.customer_id, 'name', u.name, 'phone', u.phone,
      'availableBalance', private.money(w.available_cents), 'pendingBalance', private.money(w.pending_cents),
      'totalDeposit', private.money(w.total_deposit_cents), 'totalWithdraw', private.money(w.total_withdraw_cents)) AS j
    FROM public.wallets w JOIN public.users u ON u.id = w.customer_id
    ORDER BY w.updated_at DESC LIMIT 200) x), '[]'::jsonb);
END $$;

-- GET /admin/wallets/:customerId/ledger
CREATE OR REPLACE FUNCTION public.admin_wallet_ledger(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', l.id, 'orderId', l.order_id, 'type', l.entry_type, 'amount', private.money(l.amount_cents),
      'balanceAfter', private.money(l.balance_after_cents), 'reason', l.reason, 'createdAt', l.created_at
    ) ORDER BY l.created_at DESC)
    FROM (SELECT le.* FROM public.ledger_entries le JOIN public.wallets w ON w.id = le.wallet_id
          WHERE w.customer_id = p_customer_id ORDER BY le.created_at DESC LIMIT 200) l), '[]'::jsonb);
END $$;

-- GET /admin/deposits, /admin/withdrawals, /admin/orders (p_direction NULL)
CREATE OR REPLACE FUNCTION public.admin_orders(p_direction text DEFAULT NULL, p_status text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  IF p_direction IS NOT NULL THEN
    PERFORM private.parse_direction(p_direction);
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(private.admin_order_json(o) ORDER BY o.created_at DESC) FROM (
    SELECT * FROM public.orders
    WHERE (p_direction IS NULL OR direction::text = p_direction) AND (p_status IS NULL OR status::text = p_status)
    ORDER BY created_at DESC LIMIT 300) o), '[]'::jsonb);
END $$;

-- GET /admin/orders/:id
CREATE OR REPLACE FUNCTION public.admin_order(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.orders;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_id;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Order not found');
  END IF;
  RETURN private.admin_order_json(o);
END $$;

-- GET /admin/transactions (every wallet's ledger)
CREATE OR REPLACE FUNCTION public.admin_transactions()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', l.id, 'customerId', l.customer_id, 'orderId', l.order_id, 'type', l.entry_type,
      'amount', private.money(l.amount_cents), 'balanceAfter', private.money(l.balance_after_cents),
      'reason', l.reason, 'createdAt', l.created_at
    ) ORDER BY l.created_at DESC)
    FROM (SELECT le.*, w.customer_id FROM public.ledger_entries le JOIN public.wallets w ON w.id = le.wallet_id
          ORDER BY le.created_at DESC LIMIT 300) l), '[]'::jsonb);
END $$;

-- GET /admin/audit-logs
CREATE OR REPLACE FUNCTION public.admin_audit_logs()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(to_jsonb(a) ORDER BY a.created_at DESC)
    FROM (SELECT * FROM public.audit_logs ORDER BY created_at DESC LIMIT 300) a), '[]'::jsonb);
END $$;

-- GET /admin/reports/daily
CREATE OR REPLACE FUNCTION public.admin_reports_daily()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'day', r.day, 'direction', r.direction, 'method', r.method, 'status', r.status,
      'count', r.count, 'amount', private.money(r.amount_cents)) ORDER BY r.day DESC)
    FROM (
      SELECT created_at::date AS day, direction, method, status, count(*)::int AS count,
             COALESCE(sum(amount_cents), 0) AS amount_cents
      FROM public.orders WHERE created_at > now() - interval '30 days'
      GROUP BY 1, 2, 3, 4
    ) r), '[]'::jsonb);
END $$;

-- POST /admin/winwin-transactions: a manager confirming a platform top-up.
CREATE OR REPLACE FUNCTION public.admin_submit_platform_transaction(
  p_account_id text, p_amount text, p_reference text, p_occurred_at text, p_idempotency_key text,
  p_method text DEFAULT 'winwin', p_deposit_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_replay jsonb;
  v_method public.order_method;
BEGIN
  v_replay := private.idempotency_begin(p_idempotency_key, 'admin.winwin_transactions', jsonb_build_object(
    'method', p_method, 'winwinId', p_account_id, 'depositCode', p_deposit_code, 'amount', p_amount,
    'mobcashRef', p_reference, 'occurredAt', p_occurred_at));
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_method := private.parse_method(COALESCE(p_method, 'winwin'), 'platform');
  PERFORM private.check_len(p_account_id, 'winwinId', 3, 30);
  PERFORM private.check_len(p_deposit_code, 'depositCode', 3, 10, false);
  PERFORM private.check_len(p_reference, 'mobcashRef', 3, 100);
  RETURN private.idempotency_finish(p_idempotency_key, private.submit_platform_transaction(
    v_id, private.app_role(), v_method, p_account_id, p_deposit_code, private.to_cents(p_amount),
    p_reference, private.parse_ts(p_occurred_at, 'occurredAt')));
END
$$;

-- ---------------------------------------------------------------------------
-- Payment integrations (EVC Plus, MobCash/WinWin). Credentials are kept in
-- Supabase Vault (encrypted at rest); the password is never returned.
-- ---------------------------------------------------------------------------
ALTER TABLE public.payment_integrations
  ADD COLUMN IF NOT EXISTS username_secret_id UUID,
  ADD COLUMN IF NOT EXISTS password_secret_id UUID;

CREATE OR REPLACE FUNCTION private.parse_provider(p_provider text)
RETURNS text LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
BEGIN
  IF p_provider IS NULL OR p_provider NOT IN ('evc_plus', 'mobcash_winwin') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown integration provider');
  END IF;
  RETURN p_provider;
END $$;

CREATE OR REPLACE FUNCTION private.integration_json(r public.payment_integrations)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'provider', r.provider,
    'status', r.status,
    'configJson', COALESCE(r.config_json, '{}'::jsonb),
    'hasCredentials', r.has_credentials,
    'username', (SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = r.username_secret_id),
    'lastTestAt', r.last_test_at,
    'lastTestResult', r.last_test_result,
    'lastTestMessage', r.last_test_message,
    'lastSuccessfulConnectionAt', r.last_successful_connection_at,
    'lastTransactionAt', r.last_transaction_at,
    'updatedAt', r.updated_at,
    'automationMode', COALESCE(r.automation_mode, 'manual'),
    'dryRun', COALESCE(r.dry_run, true),
    'consecutiveFailures', COALESCE(r.consecutive_failures, 0),
    'circuitBreakerTrippedAt', r.circuit_breaker_tripped_at,
    'circuitBreakerReason', r.circuit_breaker_reason
  )
$$;

CREATE OR REPLACE FUNCTION private.integration_or_404(p_provider text)
RETURNS public.payment_integrations LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE r public.payment_integrations;
BEGIN
  SELECT * INTO r FROM public.payment_integrations WHERE provider = private.parse_provider(p_provider) FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Integration not configured yet');
  END IF;
  RETURN r;
END $$;

-- GET /admin/payment-integrations
CREATE OR REPLACE FUNCTION public.admin_payment_integrations()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.integration_json(r) ORDER BY r.provider)
                   FROM public.payment_integrations r), '[]'::jsonb);
END $$;

-- GET /admin/payment-integrations/:provider
CREATE OR REPLACE FUNCTION public.admin_payment_integration(p_provider text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  r public.payment_integrations;
BEGIN
  SELECT * INTO r FROM public.payment_integrations WHERE provider = private.parse_provider(p_provider);
  IF NOT FOUND THEN
    RETURN jsonb_build_object('provider', p_provider, 'status', 'inactive', 'configJson', '{}'::jsonb,
                              'hasCredentials', false, 'username', NULL);
  END IF;
  RETURN private.integration_json(r);
END $$;

CREATE OR REPLACE FUNCTION private.store_secret(p_existing uuid, p_value text, p_name text)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_existing IS NOT NULL AND EXISTS (SELECT 1 FROM vault.secrets WHERE id = p_existing) THEN
    PERFORM vault.update_secret(p_existing, p_value);
    RETURN p_existing;
  END IF;
  DELETE FROM vault.secrets WHERE name = p_name;
  RETURN vault.create_secret(p_value, p_name, 'BAARI payment integration credential');
END $$;

-- PUT /admin/payment-integrations/:provider/credentials
CREATE OR REPLACE FUNCTION public.admin_set_integration_credentials(
  p_provider text, p_username text, p_password text, p_config jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_provider text := private.parse_provider(p_provider);
  before jsonb;
  r public.payment_integrations;
BEGIN
  PERFORM private.check_len(p_username, 'username', 1, 200);
  PERFORM private.check_len(p_password, 'password', 1, 200);
  IF p_config IS NOT NULL AND jsonb_typeof(p_config) <> 'object' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'config must be an object');
  END IF;
  SELECT jsonb_build_object('provider', provider, 'status', status, 'config_json', config_json) INTO before
  FROM public.payment_integrations WHERE provider = v_provider;

  INSERT INTO public.payment_integrations (provider, status, config_json)
  VALUES (v_provider, 'inactive', COALESCE(p_config, '{}'::jsonb))
  ON CONFLICT (provider) DO NOTHING;
  SELECT * INTO r FROM public.payment_integrations WHERE provider = v_provider FOR UPDATE;

  UPDATE public.payment_integrations
  SET config_json = COALESCE(p_config, '{}'::jsonb),
      username_secret_id = private.store_secret(r.username_secret_id, p_username, 'payment_integration:' || v_provider || ':username'),
      password_secret_id = private.store_secret(r.password_secret_id, p_password, 'payment_integration:' || v_provider || ':password'),
      -- Superseded by the Vault copies above.
      encrypted_username = NULL, username_iv = NULL, username_auth_tag = NULL,
      encrypted_password = NULL, password_iv = NULL, password_auth_tag = NULL,
      has_credentials = true, updated_by = v_id, updated_at = now()
  WHERE provider = v_provider
  RETURNING * INTO r;

  PERFORM private.audit(v_id, private.app_role(), 'payment_integration.update_credentials', 'payment_integration', v_provider,
    before, jsonb_build_object('provider', v_provider, 'status', r.status, 'configJson', r.config_json, 'username_changed', true));
  RETURN private.integration_json(r);
END
$$;

-- PUT /admin/payment-integrations/:provider/status
CREATE OR REPLACE FUNCTION public.admin_set_integration_status(p_provider text, p_status text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  r public.payment_integrations := private.integration_or_404(p_provider);
BEGIN
  IF p_status IS NULL OR p_status NOT IN ('active', 'inactive') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be active or inactive');
  END IF;
  UPDATE public.payment_integrations SET status = p_status, updated_by = v_id, updated_at = now()
  WHERE provider = r.provider RETURNING * INTO r;
  PERFORM private.audit(v_id, private.app_role(), 'payment_integration.set_status', 'payment_integration', r.provider,
    NULL, jsonb_build_object('status', p_status));
  RETURN private.integration_json(r);
END $$;

-- POST /admin/payment-integrations/:provider/test-connection. Honest: no
-- verified provider API exists, so this never fabricates a success.
CREATE OR REPLACE FUNCTION public.admin_test_integration_connection(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  r public.payment_integrations := private.integration_or_404(p_provider);
  v_result text := 'not_configured';
  v_message text;
BEGIN
  IF NOT r.has_credentials THEN
    v_message := 'No credentials saved yet.';
  ELSIF COALESCE(r.config_json ->> 'api_base_url', '') = '' THEN
    v_message := CASE WHEN r.provider = 'mobcash_winwin'
      THEN 'No officially documented MobCash/WinWin API is configured. Deposits/withdrawals are verified via authorized agent/admin manual confirmation, not an automated connection.'
      ELSE 'No API base URL configured for this integration yet.' END;
  ELSE
    v_message := 'API base URL is set, but no verified provider adapter is implemented yet.';
  END IF;
  UPDATE public.payment_integrations SET last_test_at = now(), last_test_result = v_result, last_test_message = v_message
  WHERE provider = r.provider RETURNING * INTO r;
  PERFORM private.audit(v_id, private.app_role(), 'payment_integration.test_connection', 'payment_integration', r.provider,
    NULL, jsonb_build_object('result', v_result, 'message', v_message));
  RETURN private.integration_json(r);
END $$;

-- PUT /admin/payment-integrations/:provider/automation
CREATE OR REPLACE FUNCTION public.admin_set_integration_automation(p_provider text, p_mode text, p_dry_run boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  r public.payment_integrations := private.integration_or_404(p_provider);
  before jsonb := jsonb_build_object('automationMode', r.automation_mode, 'dryRun', r.dry_run);
BEGIN
  IF p_mode IS NULL OR p_mode NOT IN ('manual', 'automatic') OR p_dry_run IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'mode must be manual or automatic, and dryRun is required');
  END IF;
  IF p_mode = 'automatic' AND NOT r.has_credentials THEN
    PERFORM private.raise_api(400, 'CREDENTIALS_REQUIRED', 'Save manager credentials before enabling automatic processing');
  END IF;
  IF p_mode = 'automatic' AND r.circuit_breaker_tripped_at IS NOT NULL AND NOT p_dry_run THEN
    PERFORM private.raise_api(409, 'CIRCUIT_BREAKER_TRIPPED',
      'Circuit breaker is tripped -- reset it before enabling live (non-dry-run) automation');
  END IF;
  UPDATE public.payment_integrations SET automation_mode = p_mode, dry_run = p_dry_run, updated_by = v_id, updated_at = now()
  WHERE provider = r.provider RETURNING * INTO r;
  PERFORM private.audit(v_id, private.app_role(), 'payment_integration.set_automation_mode', 'payment_integration', r.provider,
    before, jsonb_build_object('automationMode', p_mode, 'dryRun', p_dry_run));
  RETURN private.integration_json(r);
END $$;

-- POST /admin/payment-integrations/:provider/reset-circuit-breaker
CREATE OR REPLACE FUNCTION public.admin_reset_circuit_breaker(p_provider text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  r public.payment_integrations := private.integration_or_404(p_provider);
BEGIN
  UPDATE public.payment_integrations
  SET circuit_breaker_tripped_at = NULL, circuit_breaker_reason = NULL, consecutive_failures = 0,
      updated_by = v_id, updated_at = now()
  WHERE provider = r.provider RETURNING * INTO r;
  PERFORM private.audit(v_id, private.app_role(), 'payment_integration.reset_circuit_breaker', 'payment_integration', r.provider);
  RETURN private.integration_json(r);
END $$;

-- GET /admin/payment-integrations/:provider/automation-runs
CREATE OR REPLACE FUNCTION public.admin_automation_runs(p_provider text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_provider text := private.parse_provider(p_provider);
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', a.id, 'run_type', a.run_type, 'order_id', a.order_id, 'status', a.status, 'message', a.message,
      'has_screenshot', a.screenshot_base64 IS NOT NULL, 'started_at', a.started_at, 'finished_at', a.finished_at
    ) ORDER BY a.finished_at DESC)
    FROM (SELECT * FROM public.automation_runs WHERE provider = v_provider ORDER BY finished_at DESC LIMIT 100) a), '[]'::jsonb);
END $$;

-- GET /admin/payment-integrations/:provider/automation-runs/:runId/screenshot
CREATE OR REPLACE FUNCTION public.admin_automation_run_screenshot(p_provider text, p_run_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_shot text;
BEGIN
  SELECT screenshot_base64 INTO v_shot FROM public.automation_runs
  WHERE id = p_run_id AND provider = private.parse_provider(p_provider);
  IF v_shot IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'No screenshot for this run');
  END IF;
  RETURN jsonb_build_object('screenshotBase64', v_shot);
END $$;

-- Used by the cashdeskbot Edge Function to check the caller.
CREATE OR REPLACE FUNCTION public.session_can_manage()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.can_manage()
$$;
