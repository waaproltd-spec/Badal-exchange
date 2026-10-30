-- Betting Platform Management (Agent App > Account > Betting Platforms).
--
-- Built on what exists: every betting platform is a payment method of kind
-- 'platform' (public.payment_methods, its enum value in public.order_method)
-- and is driven by an adapter in the Edge Functions. Today there is one
-- adapter, the CashdeskBot partner API, used by all eight platforms
-- (_shared/cashdeskbot.ts). Their credentials were Edge Function secrets
-- (CASHDESKBOT_<BRAND>_*); a manager can now keep them here instead:
--
--   * public.payment_integrations gets a row per platform (kind 'betting'),
--     its secrets in Supabase Vault (private.store_secret) -- never returned
--     to the apps, never written to the audit log (only which fields changed).
--   * Saving changes the config version; a Test connection (Edge Function
--     cashdeskbot /platform-test, which calls the provider and reports here
--     with the service key) marks that version as tested.
--   * Credentials are used for real money only when their version passed
--     a test (betting_platform_config); until then a built-in platform keeps
--     its Edge Function secrets, and a new one cannot be switched on.
--   * A new platform adds its order_method value; it starts off. Removing one
--     switches it off and hides it, keeping every order that used it.

ALTER TABLE public.payment_integrations
  ADD COLUMN IF NOT EXISTS kind TEXT NOT NULL DEFAULT 'payment',
  ADD COLUMN IF NOT EXISTS adapter TEXT,
  ADD COLUMN IF NOT EXISTS method_key TEXT,
  ADD COLUMN IF NOT EXISTS api_url TEXT,
  ADD COLUMN IF NOT EXISTS account_id TEXT,
  ADD COLUMN IF NOT EXISTS hash_secret_id UUID,
  ADD COLUMN IF NOT EXISTS api_key_secret_id UUID,
  ADD COLUMN IF NOT EXISTS config_version UUID,
  ADD COLUMN IF NOT EXISTS tested_version UUID,
  ADD COLUMN IF NOT EXISTS last_ok_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS built_in BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS created_by UUID REFERENCES public.users(id),
  ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;
CREATE UNIQUE INDEX IF NOT EXISTS payment_integrations_betting_method
  ON public.payment_integrations (method_key) WHERE kind = 'betting';

-- The platforms that existed before this screen: their adapter is known.
CREATE OR REPLACE FUNCTION private.built_in_platforms()
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT ARRAY['888starz', 'onexbet', 'winwin', 'betwinner', 'dbbet', 'betjam', 'betongame', 'melbet']
$$;

-- What each adapter needs. Only these can be driven automatically; another
-- provider's API needs its own adapter written from its documentation.
CREATE OR REPLACE FUNCTION private.betting_adapters()
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_array(jsonb_build_object(
    'adapter', 'cashdeskbot',
    'label', 'CashdeskBot partner API (1XBET, MELBET, 888STARZ, WinWin, ...)',
    'defaultApiUrl', 'https://partners.servcul.com/CashdeskBotAPI',
    'fields', jsonb_build_array(
      jsonb_build_object('key', 'apiUrl', 'label', 'API URL', 'required', false, 'secret', false),
      jsonb_build_object('key', 'login', 'label', 'Login / Username', 'required', true, 'secret', false),
      jsonb_build_object('key', 'password', 'label', 'Cashier password', 'required', true, 'secret', true),
      jsonb_build_object('key', 'accountId', 'label', 'Cashdesk ID (World / Wallet ID)', 'required', true, 'secret', false),
      jsonb_build_object('key', 'apiSecret', 'label', 'Hash (API secret / signature key)', 'required', true, 'secret', true),
      jsonb_build_object('key', 'apiKey', 'label', 'API key (not used by this API)', 'required', false, 'secret', true))))
$$;

CREATE OR REPLACE FUNCTION private.betting_adapter(p_adapter text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT a FROM jsonb_array_elements(private.betting_adapters()) a WHERE a ->> 'adapter' = p_adapter
$$;

-- Platforms whose deposits and withdrawals use a cash desk: the built-in
-- ones and those added here (and not removed).
CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_method::text = ANY (private.built_in_platforms())
      OR EXISTS (SELECT 1 FROM public.payment_integrations i
                 WHERE i.kind = 'betting' AND i.method_key = p_method::text AND i.deleted_at IS NULL)
$$;

-- The catalog says which methods are cash desks, so a new platform works in
-- the Customer App without a new release.
CREATE OR REPLACE FUNCTION public.payment_method_catalog()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'method', method, 'label', label, 'kind', kind, 'color', color, 'initials', initials,
    'order', sort_order, 'enabled', enabled, 'updatedAt', updated_at,
    'cashdesk', private.is_cashdesk_method(method)
  ) ORDER BY sort_order), '[]'::jsonb)
  FROM public.payment_methods
  WHERE NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                    WHERE i.kind = 'betting' AND i.method_key = method::text AND i.deleted_at IS NOT NULL)
$$;

CREATE OR REPLACE FUNCTION private.betting_row(p_method text)
RETURNS public.payment_integrations LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT * FROM public.payment_integrations WHERE kind = 'betting' AND method_key = p_method
$$;

-- "ab••••yz": enough to recognise a login, never the whole of it.
CREATE OR REPLACE FUNCTION private.mask(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_value IS NULL OR p_value = '' THEN NULL
              WHEN length(p_value) <= 4 THEN repeat('•', length(p_value))
              ELSE left(p_value, 2) || '••••' || right(p_value, 2) END
$$;

CREATE OR REPLACE FUNCTION private.betting_platform_json(p_method text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  m public.payment_methods;
  i public.payment_integrations := private.betting_row(p_method);
  v_status text;
BEGIN
  SELECT * INTO m FROM public.payment_methods WHERE method::text = p_method;
  v_status := CASE
    WHEN i.id IS NULL OR NOT i.has_credentials THEN CASE WHEN p_method = ANY (private.built_in_platforms()) THEN 'server' ELSE 'not_configured' END
    WHEN i.tested_version IS NOT NULL AND i.tested_version = i.config_version THEN 'connected'
    WHEN i.last_test_result = 'error' THEN 'error'
    ELSE 'not_tested' END;
  RETURN jsonb_build_object(
    'method', p_method,
    'name', COALESCE(m.label, i.config_json ->> 'name', p_method),
    'adapter', COALESCE(i.adapter, 'cashdeskbot'),
    'builtIn', p_method = ANY (private.built_in_platforms()),
    'active', COALESCE(m.enabled, false),
    'status', v_status,
    'apiUrl', i.api_url,
    'accountId', i.account_id,
    'login', private.mask((SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = i.username_secret_id)),
    'hasPassword', i.password_secret_id IS NOT NULL,
    'hasApiSecret', i.hash_secret_id IS NOT NULL,
    'hasApiKey', i.api_key_secret_id IS NOT NULL,
    'lastTestAt', i.last_test_at, 'lastOkAt', i.last_ok_at, 'lastMessage', i.last_test_message,
    'updatedAt', i.updated_at,
    'updatedBy', (SELECT u.name FROM public.users u WHERE u.id = i.updated_by));
END $$;

-- Agent App: every betting platform, built-in and added, with its status.
CREATE OR REPLACE FUNCTION public.manage_betting_platforms()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'adapters', private.betting_adapters(),
    'platforms', COALESCE((
      SELECT jsonb_agg(private.betting_platform_json(m.method::text) ORDER BY m.sort_order, m.method)
      FROM public.payment_methods m
      WHERE m.kind = 'platform'
        AND NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                        WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL)), '[]'::jsonb)
      || COALESCE((
      -- Added, but not saved yet (its payment method row comes with the first save).
      SELECT jsonb_agg(private.betting_platform_json(i.method_key))
      FROM public.payment_integrations i
      WHERE i.kind = 'betting' AND i.deleted_at IS NULL
        AND NOT EXISTS (SELECT 1 FROM public.payment_methods m WHERE m.method::text = i.method_key)), '[]'::jsonb));
END $$;

-- A new platform: its key (from the name), its enum value, switched off.
-- Its details and credentials are entered next (manage_save_betting_platform).
CREATE OR REPLACE FUNCTION public.manage_create_betting_platform(p_name text, p_adapter text DEFAULT 'cashdeskbot')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_key text := left(regexp_replace(lower(btrim(COALESCE(p_name, ''))), '[^a-z0-9]+', '', 'g'), 30);
BEGIN
  PERFORM private.check_len(p_name, 'name', 2, 40);
  IF private.betting_adapter(p_adapter) IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR',
      'No adapter for this API yet: it has to be written from the provider''s official API documentation');
  END IF;
  IF v_key !~ '^[a-z][a-z0-9]{1,29}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The name must start with a letter and contain letters or digits');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(enum_range(NULL::public.order_method)) e WHERE e::text = v_key)
     OR EXISTS (SELECT 1 FROM public.payment_methods WHERE lower(label) = lower(btrim(p_name))) THEN
    PERFORM private.raise_api(409, 'PLATFORM_EXISTS', 'A payment method with this name already exists');
  END IF;
  EXECUTE format('ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS %L', v_key);
  INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, config_json, created_by, updated_by)
  VALUES ('betting:' || v_key, 'betting', p_adapter, v_key, 'inactive', jsonb_build_object('name', btrim(p_name)), v_id, v_id);
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.create', 'payment_integration', 'betting:' || v_key, NULL,
    jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter));
  RETURN jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter, 'status', 'not_configured', 'active', false);
END $$;

-- Saves a platform's API URL, IDs and credentials. An empty secret keeps the
-- saved one. Any change has to pass a new Test connection before it is used.
CREATE OR REPLACE FUNCTION public.manage_save_betting_platform(
  p_method text, p_api_url text DEFAULT NULL, p_login text DEFAULT NULL, p_password text DEFAULT NULL,
  p_account_id text DEFAULT NULL, p_api_secret text DEFAULT NULL, p_api_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
  v_name text;
  v_adapter jsonb;
  v_url text := NULLIF(btrim(COALESCE(p_api_url, '')), '');
  v_account text := NULLIF(btrim(COALESCE(p_account_id, '')), '');
  v_login text := NULLIF(btrim(COALESCE(p_login, '')), '');
  v_changed text[] := '{}';
BEGIN
  IF i.id IS NULL THEN
    IF NOT (p_method = ANY (private.built_in_platforms())) THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
    END IF;
    INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, built_in, created_by)
    VALUES ('betting:' || p_method, 'betting', 'cashdeskbot', p_method, 'inactive', true, v_id)
    RETURNING * INTO i;
  END IF;
  IF i.deleted_at IS NOT NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  v_adapter := private.betting_adapter(i.adapter);
  -- Required fields of this adapter, counting what is already saved.
  IF v_url IS NOT NULL AND v_url !~ '^https://[^\s/$.?#].[^\s]*$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The API URL must start with https://');
  END IF;
  IF v_login IS NULL AND i.username_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Login / Username is required');
  END IF;
  IF NULLIF(p_password, '') IS NULL AND i.password_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Cashier password is required');
  END IF;
  IF v_account IS NULL AND i.account_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Cashdesk ID (World / Wallet ID) is required');
  END IF;
  IF COALESCE(v_account, i.account_id) !~ '^\d{1,20}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The Cashdesk ID is digits only');
  END IF;
  IF NULLIF(p_api_secret, '') IS NULL AND i.hash_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Hash (API secret / signature key) is required');
  END IF;
  IF length(COALESCE(p_password, '')) > 200 OR length(COALESCE(p_api_secret, '')) > 500 OR length(COALESCE(p_api_key, '')) > 500
     OR length(COALESCE(v_login, '')) > 200 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'A value is too long');
  END IF;

  IF v_url IS DISTINCT FROM i.api_url THEN v_changed := array_append(v_changed, 'apiUrl'); END IF;
  IF v_account IS NOT NULL AND v_account IS DISTINCT FROM i.account_id THEN v_changed := array_append(v_changed, 'accountId'); END IF;
  IF v_login IS NOT NULL THEN v_changed := array_append(v_changed, 'login'); END IF;
  IF NULLIF(p_password, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'password'); END IF;
  IF NULLIF(p_api_secret, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'apiSecret'); END IF;
  IF NULLIF(p_api_key, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'apiKey'); END IF;

  UPDATE public.payment_integrations SET
    api_url = v_url,
    account_id = COALESCE(v_account, account_id),
    username_secret_id = CASE WHEN v_login IS NOT NULL
      THEN private.store_secret(username_secret_id, v_login, 'betting:' || p_method || ':login') ELSE username_secret_id END,
    password_secret_id = CASE WHEN NULLIF(p_password, '') IS NOT NULL
      THEN private.store_secret(password_secret_id, p_password, 'betting:' || p_method || ':password') ELSE password_secret_id END,
    hash_secret_id = CASE WHEN NULLIF(p_api_secret, '') IS NOT NULL
      THEN private.store_secret(hash_secret_id, p_api_secret, 'betting:' || p_method || ':secret') ELSE hash_secret_id END,
    api_key_secret_id = CASE WHEN NULLIF(p_api_key, '') IS NOT NULL
      THEN private.store_secret(api_key_secret_id, p_api_key, 'betting:' || p_method || ':api_key') ELSE api_key_secret_id END,
    has_credentials = true,
    config_version = CASE WHEN cardinality(v_changed) > 0 OR config_version IS NULL THEN gen_random_uuid() ELSE config_version END,
    updated_by = v_id, updated_at = now()
  WHERE id = i.id
  RETURNING * INTO i;

  -- A new platform gets its payment method row (off) on its first save.
  IF NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method) THEN
    v_name := COALESCE(i.config_json ->> 'name', p_method);
    EXECUTE format(
      'INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order, enabled)
       VALUES (%L::public.order_method, %L, ''platform'', ''#6B7280'', %L,
               (SELECT COALESCE(max(sort_order), 0) + 1 FROM public.payment_methods), false)',
      p_method, v_name, upper(left(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'), 2)));
  END IF;
  -- Not switched on until this version passes a test.
  IF NOT (i.tested_version IS NOT NULL AND i.tested_version = i.config_version) AND NOT i.built_in THEN
    UPDATE public.payment_methods SET enabled = false, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.update', 'payment_integration', i.provider, NULL,
    jsonb_build_object('method', p_method, 'changed', to_jsonb(v_changed)));
  RETURN private.betting_platform_json(p_method);
END $$;

-- Service (Edge Functions): a platform's credentials. Only the version that
-- passed its test, unless p_for_test (the Test connection itself).
CREATE OR REPLACE FUNCTION public.betting_platform_config(p_method text, p_for_test boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  i public.payment_integrations;
BEGIN
  PERFORM private.require_service();
  i := private.betting_row(p_method);
  IF i.id IS NULL OR i.deleted_at IS NOT NULL OR NOT i.has_credentials
     OR (NOT p_for_test AND (i.tested_version IS NULL OR i.tested_version <> i.config_version)) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'method', p_method, 'adapter', i.adapter, 'version', i.config_version,
    'name', COALESCE((SELECT label FROM public.payment_methods WHERE method::text = p_method), i.config_json ->> 'name'),
    'baseUrl', COALESCE(i.api_url, private.betting_adapter(i.adapter) ->> 'defaultApiUrl'),
    'login', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = i.username_secret_id),
    'cashierpass', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = i.password_secret_id),
    'hash', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = i.hash_secret_id),
    'cashdeskid', i.account_id);
END $$;

-- Service: the result of a Test connection for the version it tested.
CREATE OR REPLACE FUNCTION public.betting_platform_record_test(
  p_method text, p_version uuid, p_ok boolean, p_message text, p_tested_by uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  i public.payment_integrations;
BEGIN
  PERFORM private.require_service();
  i := private.betting_row(p_method);
  IF i.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  UPDATE public.payment_integrations SET
    last_test_at = now(),
    last_test_result = CASE WHEN p_ok THEN 'ok' ELSE 'error' END,
    last_test_message = left(p_message, 300),
    -- A result for an older version (saved again meanwhile) proves nothing.
    tested_version = CASE WHEN p_ok AND p_version = config_version THEN p_version
                          WHEN NOT p_ok AND p_version = config_version THEN NULL ELSE tested_version END,
    last_ok_at = CASE WHEN p_ok AND p_version = config_version THEN now() ELSE last_ok_at END
  WHERE id = i.id;
  PERFORM private.audit(p_tested_by, CASE WHEN p_tested_by IS NULL THEN NULL ELSE 'agent'::public.user_role END,
    'betting_platform.test', 'payment_integration', i.provider, NULL,
    jsonb_build_object('method', p_method, 'ok', p_ok, 'message', left(p_message, 300)));
  RETURN private.betting_platform_json(p_method);
END $$;

-- On / off. On needs the saved credentials to have passed their test
-- (a built-in platform without saved credentials keeps its server secrets).
CREATE OR REPLACE FUNCTION public.manage_set_betting_platform_active(p_method text, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method AND kind = 'platform')
     OR i.deleted_at IS NOT NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  IF p_active AND NOT (
       (i.id IS NULL AND p_method = ANY (private.built_in_platforms()))
       OR (i.id IS NOT NULL AND NOT i.has_credentials AND i.built_in)
       OR (i.tested_version IS NOT NULL AND i.tested_version = i.config_version)) THEN
    PERFORM private.raise_api(409, 'NOT_TESTED', 'Test the connection first: only a platform whose credentials passed can be switched on');
  END IF;
  UPDATE public.payment_methods SET enabled = p_active, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_active THEN 'betting_platform.activate' ELSE 'betting_platform.deactivate' END,
    'payment_integration', 'betting:' || p_method, NULL, jsonb_build_object('method', p_method));
  RETURN private.betting_platform_json(p_method);
END $$;

-- Removes an added platform: off, hidden, its secrets deleted; every order
-- that used it is kept. Built-in platforms can only be switched off.
CREATE OR REPLACE FUNCTION public.manage_delete_betting_platform(p_method text, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  IF p_method = ANY (private.built_in_platforms()) THEN
    PERFORM private.raise_api(400, 'BUILT_IN', 'A built-in platform can be switched off, not removed');
  END IF;
  IF i.id IS NULL OR i.deleted_at IS NOT NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  UPDATE public.payment_methods SET enabled = false, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  DELETE FROM vault.secrets WHERE id IN (i.username_secret_id, i.password_secret_id, i.hash_secret_id, i.api_key_secret_id);
  UPDATE public.payment_integrations SET deleted_at = now(), has_credentials = false, tested_version = NULL,
    username_secret_id = NULL, password_secret_id = NULL, hash_secret_id = NULL, api_key_secret_id = NULL,
    updated_by = v_id, updated_at = now()
  WHERE id = i.id;
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.delete', 'payment_integration', i.provider, NULL,
    jsonb_build_object('method', p_method, 'reason', btrim(p_reason),
                       'orders', (SELECT count(*) FROM public.orders o WHERE o.method::text = p_method)));
END $$;

-- Payment Integrations (EVC Plus, MobCash) stays as it was: betting rows are on their own screen.
CREATE OR REPLACE FUNCTION public.admin_payment_integrations()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(private.integration_json(r) ORDER BY r.provider)
                   FROM public.payment_integrations r WHERE r.kind = 'payment'), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION private.built_in_platforms(), private.betting_adapters(), private.betting_adapter(text),
  private.betting_row(text), private.mask(text), private.betting_platform_json(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_betting_platforms(), public.manage_create_betting_platform(text, text),
  public.manage_save_betting_platform(text, text, text, text, text, text, text),
  public.manage_set_betting_platform_active(text, boolean), public.manage_delete_betting_platform(text, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_betting_platforms(), public.manage_create_betting_platform(text, text),
  public.manage_save_betting_platform(text, text, text, text, text, text, text),
  public.manage_set_betting_platform_active(text, boolean), public.manage_delete_betting_platform(text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.betting_platform_config(text, boolean), public.betting_platform_record_test(text, uuid, boolean, text, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.betting_platform_config(text, boolean), public.betting_platform_record_test(text, uuid, boolean, text, uuid)
  TO service_role;

-- Payment Methods (ON/OFF, rates, fees) leaves removed platforms out, and
-- its switch cannot turn on a platform whose credentials have not passed
-- their test: for a managed platform it goes through the same check.
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
    WHERE NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                      WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL)
  ), '[]'::jsonb);
END
$$;

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
  IF (private.betting_row(v_method::text)).id IS NOT NULL THEN
    PERFORM public.manage_set_betting_platform_active(v_method::text, p_enabled);
    SELECT * INTO m FROM public.payment_methods WHERE method = v_method;
    RETURN jsonb_build_object('method', m.method, 'label', m.label, 'enabled', m.enabled);
  END IF;
  UPDATE public.payment_methods SET enabled = p_enabled, updated_by = v_id, updated_at = now()
  WHERE method = v_method RETURNING * INTO m;
  PERFORM private.audit(v_id, private.app_role(), 'payment_method.update', 'payment_method', v_method::text, NULL, to_jsonb(m));
  RETURN jsonb_build_object('method', m.method, 'label', m.label, 'enabled', m.enabled);
END
$$;
