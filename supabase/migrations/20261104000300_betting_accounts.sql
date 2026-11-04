-- Several accounts under one betting platform (Agent App > Betting Platforms).
--
-- A platform (888STARZ, 1XBET, ...) is what customers choose; behind it there
-- can now be any number of ACCOUNTS (cash desks): "Account 1", "Account 2", ...
--
--   * each account has its own credentials (in Vault), configuration, connection
--     test and status, and its own ON / OFF switch;
--   * exactly one account is SELECTED: the one customers' deposits and
--     withdrawals go through. The admin selects it; it takes effect at once;
--   * an account can be ON (and so selected) only after its saved credentials
--     passed Test connection; the account in use can not be switched OFF;
--   * every automatic order records which account handled it
--     (orders.betting_account_id), so each account's transactions stay apart;
--   * removing an account deletes its secrets and keeps its orders.
--
-- Nothing changes for a platform that has one account: the account it has now
-- is "Account 1", selected, ON, with the credentials, test state and switch it
-- already had. The platform record (payment_integrations, kind 'betting') keeps
-- what belongs to the platform itself: its name, logo, adapter, built-in flag
-- and removal. The functions the Edge Functions call (betting_platform_config,
-- betting_platform_record_test) work as before for the selected account and
-- take an optional account.

CREATE TABLE IF NOT EXISTS public.betting_accounts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method_key          TEXT NOT NULL,
  label               TEXT NOT NULL,
  api_url             TEXT,
  account_id          TEXT,
  username_secret_id  UUID,
  password_secret_id  UUID,
  hash_secret_id      UUID,
  api_key_secret_id   UUID,
  has_credentials     BOOLEAN NOT NULL DEFAULT false,
  -- A built-in platform's first account keeps using the server's Edge Function
  -- secrets until credentials are saved for it.
  uses_server_secrets BOOLEAN NOT NULL DEFAULT false,
  config_version      UUID,
  tested_version      UUID,
  last_test_at        TIMESTAMPTZ,
  last_test_result    TEXT,
  last_test_message   TEXT,
  last_ok_at          TIMESTAMPTZ,
  enabled             BOOLEAN NOT NULL DEFAULT false,
  is_selected         BOOLEAN NOT NULL DEFAULT false,
  sort_order          INT NOT NULL DEFAULT 0,
  created_by          UUID REFERENCES public.users(id),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by          UUID REFERENCES public.users(id),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  removed_at          TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS betting_accounts_selected ON public.betting_accounts (method_key) WHERE is_selected AND removed_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS betting_accounts_label ON public.betting_accounts (method_key, lower(label)) WHERE removed_at IS NULL;
CREATE INDEX IF NOT EXISTS betting_accounts_method ON public.betting_accounts (method_key);
ALTER TABLE public.betting_accounts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.betting_accounts FROM PUBLIC, anon, authenticated;

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS betting_account_id UUID REFERENCES public.betting_accounts(id);
CREATE INDEX IF NOT EXISTS idx_orders_betting_account ON public.orders (betting_account_id) WHERE betting_account_id IS NOT NULL;

-- Every platform that exists now gets its "Account 1": what it already had.
INSERT INTO public.betting_accounts (
  method_key, label, api_url, account_id, username_secret_id, password_secret_id, hash_secret_id, api_key_secret_id,
  has_credentials, uses_server_secrets, config_version, tested_version, last_test_at, last_test_result, last_test_message, last_ok_at,
  enabled, is_selected, created_by, created_at, updated_by, updated_at)
SELECT i.method_key, 'Account 1', i.api_url, i.account_id, i.username_secret_id, i.password_secret_id, i.hash_secret_id, i.api_key_secret_id,
       i.has_credentials, (NOT i.has_credentials AND (i.built_in OR i.method_key = ANY (private.built_in_platforms()))),
       i.config_version, i.tested_version, i.last_test_at, i.last_test_result, i.last_test_message, i.last_ok_at,
       true, true, i.created_by, i.created_at, i.updated_by, i.updated_at
FROM public.payment_integrations i
WHERE i.kind = 'betting' AND i.deleted_at IS NULL AND i.method_key IS NOT NULL
  AND NOT EXISTS (SELECT 1 FROM public.betting_accounts a WHERE a.method_key = i.method_key AND a.removed_at IS NULL);

-- ---------------------------------------------------------------- helpers

CREATE OR REPLACE FUNCTION private.betting_selected(p_method text)
RETURNS public.betting_accounts LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT * FROM public.betting_accounts WHERE method_key = p_method AND is_selected AND removed_at IS NULL
$$;

-- A platform's account row; built-in platforms (which have no record until
-- they are first used) get their record and "Account 1" here.
CREATE OR REPLACE FUNCTION private.ensure_betting_account(p_method text, p_by uuid DEFAULT NULL)
RETURNS public.betting_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.betting_accounts := private.betting_selected(p_method);
  i public.payment_integrations;
  v_builtin boolean := p_method = ANY (private.built_in_platforms());
BEGIN
  IF a.id IS NOT NULL THEN RETURN a; END IF;
  i := private.betting_row(p_method);
  IF i.id IS NULL THEN
    IF NOT v_builtin THEN RETURN a; END IF;
    INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, built_in, created_by)
    VALUES ('betting:' || p_method, 'betting', 'cashdeskbot', p_method, 'inactive', true, p_by)
    ON CONFLICT (provider) DO NOTHING;
    i := private.betting_row(p_method);
  END IF;
  IF i.id IS NULL OR i.deleted_at IS NOT NULL THEN RETURN a; END IF;
  INSERT INTO public.betting_accounts (method_key, label, enabled, is_selected, uses_server_secrets, has_credentials, created_by, updated_by)
  VALUES (p_method, 'Account 1', true, true, v_builtin AND NOT i.has_credentials, false, p_by, p_by)
  RETURNING * INTO a;
  RETURN a;
END $$;

CREATE OR REPLACE FUNCTION private.betting_account_status(a public.betting_accounts)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN NOT a.has_credentials AND a.uses_server_secrets THEN 'server'
    WHEN NOT a.has_credentials THEN 'not_configured'
    WHEN a.tested_version IS NOT NULL AND a.tested_version = a.config_version THEN 'connected'
    WHEN a.last_test_result = 'error' THEN 'error'
    ELSE 'not_tested' END
$$;

-- One account as the Agent App shows it. Secrets are never returned: a masked
-- login, and only whether the others are saved.
CREATE OR REPLACE FUNCTION private.betting_account_json(a public.betting_accounts)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', a.id, 'label', a.label, 'selected', a.is_selected, 'enabled', a.enabled,
    'status', private.betting_account_status(a),
    'apiUrl', a.api_url, 'accountId', a.account_id,
    'login', private.mask((SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = a.username_secret_id)),
    'hasPassword', a.password_secret_id IS NOT NULL,
    'hasApiSecret', a.hash_secret_id IS NOT NULL,
    'hasApiKey', a.api_key_secret_id IS NOT NULL,
    'lastTestAt', a.last_test_at, 'lastOkAt', a.last_ok_at, 'lastMessage', a.last_test_message,
    'updatedAt', a.updated_at,
    'updatedBy', (SELECT u.name FROM public.users u WHERE u.id = a.updated_by),
    'orders', (SELECT count(*) FROM public.orders o WHERE o.betting_account_id = a.id),
    'lastOrderAt', (SELECT max(o.created_at) FROM public.orders o WHERE o.betting_account_id = a.id),
    'virtual', false)
$$;

-- A cash desk platform for customers: as before, but a platform that was live
-- before it had a cash desk counts once its SELECTED account passed its test.
CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_method::text = ANY (private.built_in_platforms())
      OR EXISTS (SELECT 1 FROM public.payment_integrations i
                 LEFT JOIN public.betting_accounts a ON a.method_key = i.method_key AND a.is_selected AND a.removed_at IS NULL
                 WHERE i.kind = 'betting' AND i.method_key = p_method::text AND i.deleted_at IS NULL
                   AND (NOT i.legacy_manual
                        OR (a.has_credentials AND a.tested_version IS NOT NULL AND a.tested_version = a.config_version)))
$$;

-- A platform that has none gets its connection record, and its Account 1.
CREATE OR REPLACE FUNCTION private.adopt_betting_platform(p_method text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  m public.payment_methods;
BEGIN
  SELECT * INTO m FROM public.payment_methods WHERE method::text = p_method AND kind = 'platform';
  IF m.method IS NULL OR p_method = ANY (private.built_in_platforms())
     OR EXISTS (SELECT 1 FROM public.payment_integrations WHERE kind = 'betting' AND method_key = p_method) THEN
    RETURN;
  END IF;
  INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, config_json, legacy_manual)
  VALUES ('betting:' || p_method, 'betting', 'cashdeskbot', p_method, 'inactive', jsonb_build_object('name', m.label), true)
  ON CONFLICT (provider) DO NOTHING;
  PERFORM private.ensure_betting_account(p_method);
  PERFORM private.audit(NULL, NULL, 'betting_platform.adopt', 'payment_integration', 'betting:' || p_method, NULL,
    jsonb_build_object('method', p_method, 'name', m.label, 'active', m.enabled));
END $$;

-- The platform as the Agent App shows it. The credentials, test state and status
-- are those of the selected account (so an older Agent App keeps working), and
-- "accounts" lists every account.
CREATE OR REPLACE FUNCTION private.betting_platform_json(p_method text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  m public.payment_methods;
  i public.payment_integrations := private.betting_row(p_method);
  a public.betting_accounts := private.betting_selected(p_method);
  v_builtin boolean := p_method = ANY (private.built_in_platforms());
  v_status text;
  v_accounts jsonb;
BEGIN
  SELECT * INTO m FROM public.payment_methods WHERE method::text = p_method;
  v_status := CASE
    WHEN a.id IS NULL THEN CASE WHEN v_builtin THEN 'server' ELSE 'not_configured' END
    ELSE private.betting_account_status(a) END;
  SELECT COALESCE(jsonb_agg(private.betting_account_json(x) ORDER BY x.sort_order, x.created_at), '[]'::jsonb)
    INTO v_accounts FROM public.betting_accounts x WHERE x.method_key = p_method AND x.removed_at IS NULL;
  -- A built-in platform that has not been touched yet shows its one account: the server's secrets.
  IF jsonb_array_length(v_accounts) = 0 AND v_builtin THEN
    v_accounts := jsonb_build_array(jsonb_build_object(
      'id', NULL, 'label', 'Account 1', 'selected', true, 'enabled', true, 'status', 'server',
      'hasPassword', false, 'hasApiSecret', false, 'hasApiKey', false, 'orders', 0, 'virtual', true));
  END IF;
  RETURN jsonb_build_object(
    'method', p_method,
    'name', COALESCE(m.label, i.config_json ->> 'name', p_method),
    'adapter', COALESCE(i.adapter, 'cashdeskbot'),
    'builtIn', v_builtin,
    'active', COALESCE(m.enabled, false),
    'status', v_status,
    'mode', CASE WHEN private.is_cashdesk_method(p_method::public.order_method) THEN 'cashdesk' ELSE 'manual' END,
    'apiUrl', a.api_url,
    'accountId', a.account_id,
    'login', private.mask((SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = a.username_secret_id)),
    'hasPassword', a.password_secret_id IS NOT NULL,
    'hasApiSecret', a.hash_secret_id IS NOT NULL,
    'hasApiKey', a.api_key_secret_id IS NOT NULL,
    'lastTestAt', a.last_test_at, 'lastOkAt', a.last_ok_at, 'lastMessage', a.last_test_message,
    'updatedAt', COALESCE(a.updated_at, i.updated_at),
    'updatedBy', (SELECT u.name FROM public.users u WHERE u.id = COALESCE(a.updated_by, i.updated_by)),
    'logo', private.betting_logo_b64(p_method),
    'accounts', v_accounts,
    'selectedAccountId', a.id,
    'selectedAccountLabel', COALESCE(a.label, 'Account 1'));
END $$;

-- -------------------------------------------------- saving one account

-- Validates and saves an account's API URL, IDs and credentials. An empty secret
-- keeps the saved one. Any change has to pass a new Test connection.
CREATE OR REPLACE FUNCTION private.save_betting_account(
  p_account uuid, p_by uuid, p_api_url text, p_login text, p_password text, p_account_id text, p_api_secret text, p_api_key text)
RETURNS public.betting_accounts LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.betting_accounts;
  v_url text := NULLIF(btrim(COALESCE(p_api_url, '')), '');
  v_cashdesk text := NULLIF(btrim(COALESCE(p_account_id, '')), '');
  v_login text := NULLIF(btrim(COALESCE(p_login, '')), '');
  v_changed text[] := '{}';
  v_prefix text;
BEGIN
  SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting account not found');
  END IF;
  IF v_url IS NOT NULL AND v_url !~ '^https://[^\s/$.?#].[^\s]*$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The API URL must start with https://');
  END IF;
  IF v_login IS NULL AND a.username_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Login / Username is required');
  END IF;
  IF NULLIF(p_password, '') IS NULL AND a.password_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Cashier password is required');
  END IF;
  IF v_cashdesk IS NULL AND a.account_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Cashdesk ID (World / Wallet ID) is required');
  END IF;
  IF COALESCE(v_cashdesk, a.account_id) !~ '^\d{1,20}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The Cashdesk ID is digits only');
  END IF;
  IF NULLIF(p_api_secret, '') IS NULL AND a.hash_secret_id IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Hash (API secret / signature key) is required');
  END IF;
  IF length(COALESCE(p_password, '')) > 200 OR length(COALESCE(p_api_secret, '')) > 500 OR length(COALESCE(p_api_key, '')) > 500
     OR length(COALESCE(v_login, '')) > 200 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'A value is too long');
  END IF;

  IF v_url IS DISTINCT FROM a.api_url THEN v_changed := array_append(v_changed, 'apiUrl'); END IF;
  IF v_cashdesk IS NOT NULL AND v_cashdesk IS DISTINCT FROM a.account_id THEN v_changed := array_append(v_changed, 'accountId'); END IF;
  IF v_login IS NOT NULL THEN v_changed := array_append(v_changed, 'login'); END IF;
  IF NULLIF(p_password, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'password'); END IF;
  IF NULLIF(p_api_secret, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'apiSecret'); END IF;
  IF NULLIF(p_api_key, '') IS NOT NULL THEN v_changed := array_append(v_changed, 'apiKey'); END IF;

  -- Each account's secrets have their own names in the vault.
  v_prefix := 'betting:' || a.method_key || ':' || a.id::text || ':';
  UPDATE public.betting_accounts SET
    api_url = v_url,
    account_id = COALESCE(v_cashdesk, account_id),
    username_secret_id = CASE WHEN v_login IS NOT NULL
      THEN private.store_secret(username_secret_id, v_login, v_prefix || 'login') ELSE username_secret_id END,
    password_secret_id = CASE WHEN NULLIF(p_password, '') IS NOT NULL
      THEN private.store_secret(password_secret_id, p_password, v_prefix || 'password') ELSE password_secret_id END,
    hash_secret_id = CASE WHEN NULLIF(p_api_secret, '') IS NOT NULL
      THEN private.store_secret(hash_secret_id, p_api_secret, v_prefix || 'secret') ELSE hash_secret_id END,
    api_key_secret_id = CASE WHEN NULLIF(p_api_key, '') IS NOT NULL
      THEN private.store_secret(api_key_secret_id, p_api_key, v_prefix || 'api_key') ELSE api_key_secret_id END,
    has_credentials = true,
    uses_server_secrets = false,
    config_version = CASE WHEN cardinality(v_changed) > 0 OR config_version IS NULL THEN gen_random_uuid() ELSE config_version END,
    updated_by = p_by, updated_at = now()
  WHERE id = a.id
  RETURNING * INTO a;
  -- An account that is not in use is not switched on until this version passes a test.
  IF NOT a.is_selected AND NOT (a.tested_version IS NOT NULL AND a.tested_version = a.config_version) THEN
    UPDATE public.betting_accounts SET enabled = false WHERE id = a.id RETURNING * INTO a;
  END IF;
  PERFORM private.audit(p_by, private.app_role(), 'betting_account.update', 'betting_account', a.method_key || '/' || a.label, NULL,
    jsonb_build_object('method', a.method_key, 'account', a.label, 'changed', to_jsonb(v_changed)));
  RETURN a;
END $$;

-- What saving the account in use does to the platform (as it always did): a
-- new platform gets its payment method row (off), and is not switched on until
-- this version passes a test (one that was live before it had a cash desk, and
-- a built-in one, stay as they are).
CREATE OR REPLACE FUNCTION private.betting_after_save(p_method text, p_by uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  i public.payment_integrations := private.betting_row(p_method);
  a public.betting_accounts := private.betting_selected(p_method);
  v_name text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method) THEN
    v_name := COALESCE(i.config_json ->> 'name', p_method);
    EXECUTE format(
      'INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order, enabled)
       VALUES (%L::public.order_method, %L, ''platform'', ''#6B7280'', %L,
               (SELECT COALESCE(max(sort_order), 0) + 1 FROM public.payment_methods), false)',
      p_method, v_name, upper(left(regexp_replace(v_name, '[^A-Za-z0-9]', '', 'g'), 2)));
  END IF;
  IF NOT (a.tested_version IS NOT NULL AND a.tested_version = a.config_version) AND NOT i.built_in AND NOT i.legacy_manual THEN
    UPDATE public.payment_methods SET enabled = false, updated_by = p_by, updated_at = now() WHERE method::text = p_method;
  END IF;
END $$;

-- Saving the account in use (the older entry point, by platform).
CREATE OR REPLACE FUNCTION public.manage_save_betting_platform(
  p_method text, p_api_url text DEFAULT NULL, p_login text DEFAULT NULL, p_password text DEFAULT NULL,
  p_account_id text DEFAULT NULL, p_api_secret text DEFAULT NULL, p_api_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
  a public.betting_accounts;
BEGIN
  IF i.id IS NULL AND NOT (p_method = ANY (private.built_in_platforms())) THEN
    IF EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method AND kind = 'platform') THEN
      PERFORM private.adopt_betting_platform(p_method);
    ELSE
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
    END IF;
  END IF;
  a := private.ensure_betting_account(p_method, v_id);
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  PERFORM private.save_betting_account(a.id, v_id, p_api_url, p_login, p_password, p_account_id, p_api_secret, p_api_key);
  PERFORM private.betting_after_save(p_method, v_id);
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.update', 'payment_integration', 'betting:' || p_method, NULL,
    jsonb_build_object('method', p_method));
  RETURN private.betting_platform_json(p_method);
END $$;

-- Saving a given account.
CREATE OR REPLACE FUNCTION public.manage_save_betting_account(
  p_account uuid, p_api_url text DEFAULT NULL, p_login text DEFAULT NULL, p_password text DEFAULT NULL,
  p_account_id text DEFAULT NULL, p_api_secret text DEFAULT NULL, p_api_key text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.betting_accounts;
BEGIN
  a := private.save_betting_account(p_account, v_id, p_api_url, p_login, p_password, p_account_id, p_api_secret, p_api_key);
  IF a.is_selected THEN
    PERFORM private.betting_after_save(a.method_key, v_id);
  END IF;
  RETURN private.betting_platform_json(a.method_key);
END $$;

-- ------------------------------------------------ the Edge Functions' side

-- Service: an account's credentials: the selected account's, or [p_account].
-- Only a version that passed its test, on an account that is ON, unless p_for_test.
DROP FUNCTION IF EXISTS public.betting_platform_config(text, boolean);
CREATE OR REPLACE FUNCTION public.betting_platform_config(p_method text, p_for_test boolean DEFAULT false, p_account uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.betting_accounts;
  i public.payment_integrations := private.betting_row(p_method);
BEGIN
  PERFORM private.require_service();
  IF p_account IS NOT NULL THEN
    SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND method_key = p_method AND removed_at IS NULL;
  ELSE
    a := private.betting_selected(p_method);
  END IF;
  IF a.id IS NULL OR i.id IS NULL OR i.deleted_at IS NOT NULL OR NOT a.has_credentials
     OR (NOT p_for_test AND (a.tested_version IS NULL OR a.tested_version <> a.config_version OR NOT a.enabled)) THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object(
    'method', p_method, 'adapter', i.adapter, 'version', a.config_version,
    'accountRowId', a.id, 'accountLabel', a.label,
    'name', COALESCE((SELECT label FROM public.payment_methods WHERE method::text = p_method), i.config_json ->> 'name'),
    'baseUrl', COALESCE(a.api_url, private.betting_adapter(i.adapter) ->> 'defaultApiUrl'),
    'login', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.username_secret_id),
    'cashierpass', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.password_secret_id),
    'hash', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.hash_secret_id),
    'cashdeskid', a.account_id);
END $$;

-- Service: the result of a Test connection for the version it tested.
DROP FUNCTION IF EXISTS public.betting_platform_record_test(text, uuid, boolean, text, uuid);
CREATE OR REPLACE FUNCTION public.betting_platform_record_test(
  p_method text, p_version uuid, p_ok boolean, p_message text, p_tested_by uuid DEFAULT NULL, p_account uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.betting_accounts;
BEGIN
  PERFORM private.require_service();
  IF p_account IS NOT NULL THEN
    SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND method_key = p_method AND removed_at IS NULL;
  ELSE
    a := private.betting_selected(p_method);
  END IF;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  UPDATE public.betting_accounts SET
    last_test_at = now(),
    last_test_result = CASE WHEN p_ok THEN 'ok' ELSE 'error' END,
    last_test_message = left(p_message, 300),
    -- A result for an older version (saved again meanwhile) proves nothing.
    tested_version = CASE WHEN p_ok AND p_version = config_version THEN p_version
                          WHEN NOT p_ok AND p_version = config_version THEN NULL ELSE tested_version END,
    last_ok_at = CASE WHEN p_ok AND p_version = config_version THEN now() ELSE last_ok_at END
  WHERE id = a.id;
  PERFORM private.audit(p_tested_by, CASE WHEN p_tested_by IS NULL THEN NULL ELSE 'agent'::public.user_role END,
    'betting_account.test', 'betting_account', p_method || '/' || a.label, NULL,
    jsonb_build_object('method', p_method, 'account', a.label, 'ok', p_ok, 'message', left(p_message, 300)));
  RETURN private.betting_platform_json(p_method);
END $$;

-- Service: which account handled an order (the selected one now, or [p_account]).
CREATE OR REPLACE FUNCTION public.platform_record_account(p_order_id uuid, p_account uuid DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.orders o SET betting_account_id = COALESCE(
      (SELECT x.id FROM public.betting_accounts x WHERE x.id = p_account AND x.method_key = o.method::text),
      (SELECT x.id FROM public.betting_accounts x WHERE x.method_key = o.method::text AND x.is_selected AND x.removed_at IS NULL))
  WHERE o.id = p_order_id AND o.betting_account_id IS NULL;
END $$;

-- ----------------------------------------------- managing the accounts

-- Platform ON / OFF: the account in use must be usable (as the platform's own
-- credentials had to be before).
CREATE OR REPLACE FUNCTION public.manage_set_betting_platform_active(p_method text, p_active boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
  a public.betting_accounts := private.betting_selected(p_method);
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method AND kind = 'platform')
     OR i.deleted_at IS NOT NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  IF p_active AND NOT (
       (i.id IS NULL)
       OR (i.built_in AND (a.id IS NULL OR NOT a.has_credentials))
       OR i.legacy_manual
       OR (a.id IS NOT NULL AND a.enabled AND a.tested_version IS NOT NULL AND a.tested_version = a.config_version)) THEN
    PERFORM private.raise_api(409, 'NOT_TESTED', 'Test the connection first: only a platform whose credentials passed can be switched on');
  END IF;
  UPDATE public.payment_methods SET enabled = p_active, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_active THEN 'betting_platform.activate' ELSE 'betting_platform.deactivate' END,
    'payment_integration', 'betting:' || p_method, NULL, jsonb_build_object('method', p_method));
  RETURN private.betting_platform_json(p_method);
END $$;

-- Removes an added platform: off, hidden, every account's secrets deleted; every
-- order that used it is kept. Built-in platforms can only be switched off.
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
  DELETE FROM vault.secrets WHERE id IN (
    SELECT unnest(ARRAY[a.username_secret_id, a.password_secret_id, a.hash_secret_id, a.api_key_secret_id])
    FROM public.betting_accounts a WHERE a.method_key = p_method AND a.removed_at IS NULL);
  UPDATE public.betting_accounts SET removed_at = now(), enabled = false, is_selected = false, has_credentials = false, tested_version = NULL,
    username_secret_id = NULL, password_secret_id = NULL, hash_secret_id = NULL, api_key_secret_id = NULL,
    updated_by = v_id, updated_at = now()
  WHERE method_key = p_method AND removed_at IS NULL;
  DELETE FROM vault.secrets WHERE id IN (i.username_secret_id, i.password_secret_id, i.hash_secret_id, i.api_key_secret_id);
  UPDATE public.payment_integrations SET deleted_at = now(), has_credentials = false, tested_version = NULL,
    username_secret_id = NULL, password_secret_id = NULL, hash_secret_id = NULL, api_key_secret_id = NULL,
    updated_by = v_id, updated_at = now()
  WHERE id = i.id;
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.delete', 'payment_integration', i.provider, NULL,
    jsonb_build_object('method', p_method, 'reason', btrim(p_reason),
                       'orders', (SELECT count(*) FROM public.orders o WHERE o.method::text = p_method)));
END $$;

-- A new platform (or one added again) starts with an "Account 1": selected (the platform itself starts off).
CREATE OR REPLACE FUNCTION public.manage_create_betting_platform(p_name text, p_adapter text DEFAULT 'cashdeskbot')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_key text := left(regexp_replace(lower(btrim(COALESCE(p_name, ''))), '[^a-z0-9]+', '', 'g'), 30);
  v_old public.payment_integrations;
  v_revive boolean;
BEGIN
  PERFORM private.check_len(p_name, 'name', 2, 40);
  IF private.betting_adapter(p_adapter) IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR',
      'No adapter for this API yet: it has to be written from the provider''s official API documentation');
  END IF;
  IF v_key !~ '^[a-z0-9]{2,30}$' OR v_key !~ '[a-z]' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The name must be 2 to 30 letters or digits (spaces are ignored), with at least one letter');
  END IF;
  SELECT * INTO v_old FROM public.payment_integrations WHERE provider = 'betting:' || v_key FOR UPDATE;
  v_revive := v_old.id IS NOT NULL AND v_old.kind = 'betting' AND v_old.deleted_at IS NOT NULL
              AND NOT v_old.built_in
              AND NOT EXISTS (SELECT 1 FROM public.payment_methods m WHERE m.method::text = v_key);
  IF NOT v_revive AND (
       EXISTS (SELECT 1 FROM unnest(enum_range(NULL::public.order_method)) e WHERE e::text = v_key)
       OR EXISTS (SELECT 1 FROM public.payment_methods WHERE lower(label) = lower(btrim(p_name)))) THEN
    PERFORM private.raise_api(409, 'PLATFORM_EXISTS', 'A payment method with this name already exists');
  END IF;
  EXECUTE format('ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS %L', v_key);
  IF v_revive THEN
    UPDATE public.payment_integrations SET deleted_at = NULL, adapter = p_adapter, status = 'inactive', has_credentials = false,
           tested_version = NULL, config_json = jsonb_build_object('name', btrim(p_name)),
           username_secret_id = NULL, password_secret_id = NULL, hash_secret_id = NULL, api_key_secret_id = NULL,
           updated_by = v_id, updated_at = now()
    WHERE id = v_old.id;
  ELSE
    INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, config_json, created_by, updated_by)
    VALUES ('betting:' || v_key, 'betting', p_adapter, v_key, 'inactive', jsonb_build_object('name', btrim(p_name)), v_id, v_id);
  END IF;
  PERFORM private.ensure_betting_account(v_key, v_id);
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.create', 'payment_integration', 'betting:' || v_key, NULL,
    jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter, 'readded', v_revive));
  RETURN jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter, 'status', 'not_configured', 'active', false);
END $$;

-- Adds an account to a platform: "Account 2", ... or a name the admin gives it.
-- It has no credentials, is off and is not in use until it is tested and selected.
CREATE OR REPLACE FUNCTION public.manage_add_betting_account(p_method text, p_label text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations;
  a public.betting_accounts;
  v_label text := NULLIF(btrim(COALESCE(p_label, '')), '');
  v_n int;
BEGIN
  IF NOT (p_method = ANY (private.built_in_platforms())) THEN
    i := private.betting_row(p_method);
    IF i.id IS NULL OR i.deleted_at IS NOT NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
    END IF;
  END IF;
  -- The platform's existing account first (a built-in platform gets its record here).
  a := private.ensure_betting_account(p_method, v_id);
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  IF v_label IS NULL THEN
    SELECT count(*) + 1 INTO v_n FROM public.betting_accounts WHERE method_key = p_method;
    v_label := 'Account ' || v_n;
    WHILE EXISTS (SELECT 1 FROM public.betting_accounts WHERE method_key = p_method AND removed_at IS NULL AND lower(label) = lower(v_label)) LOOP
      v_n := v_n + 1;
      v_label := 'Account ' || v_n;
    END LOOP;
  END IF;
  PERFORM private.check_len(v_label, 'label', 1, 40);
  IF EXISTS (SELECT 1 FROM public.betting_accounts WHERE method_key = p_method AND removed_at IS NULL AND lower(label) = lower(v_label)) THEN
    PERFORM private.raise_api(409, 'ACCOUNT_EXISTS', 'This platform already has an account with this name');
  END IF;
  INSERT INTO public.betting_accounts (method_key, label, enabled, is_selected, sort_order, created_by, updated_by)
  VALUES (p_method, v_label, false, false,
          (SELECT COALESCE(max(sort_order), 0) + 1 FROM public.betting_accounts WHERE method_key = p_method), v_id, v_id)
  RETURNING * INTO a;
  PERFORM private.audit(v_id, private.app_role(), 'betting_account.create', 'betting_account', p_method || '/' || a.label, NULL,
    jsonb_build_object('method', p_method, 'account', a.label));
  RETURN private.betting_platform_json(p_method);
END $$;

CREATE OR REPLACE FUNCTION public.manage_rename_betting_account(p_account uuid, p_label text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.betting_accounts;
  v_label text := btrim(COALESCE(p_label, ''));
BEGIN
  PERFORM private.check_len(v_label, 'label', 1, 40);
  SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting account not found');
  END IF;
  IF EXISTS (SELECT 1 FROM public.betting_accounts WHERE method_key = a.method_key AND removed_at IS NULL AND id <> a.id AND lower(label) = lower(v_label)) THEN
    PERFORM private.raise_api(409, 'ACCOUNT_EXISTS', 'This platform already has an account with this name');
  END IF;
  UPDATE public.betting_accounts SET label = v_label, updated_by = v_id, updated_at = now() WHERE id = a.id;
  PERFORM private.audit(v_id, private.app_role(), 'betting_account.rename', 'betting_account', a.method_key || '/' || v_label, NULL,
    jsonb_build_object('method', a.method_key, 'from', a.label, 'to', v_label));
  RETURN private.betting_platform_json(a.method_key);
END $$;

-- An account's own ON / OFF. ON needs its credentials to have passed their test
-- (the server's secrets of a built-in platform's first account count as ready);
-- the account in use can not be switched OFF while the platform is on.
CREATE OR REPLACE FUNCTION public.manage_set_betting_account_enabled(p_account uuid, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.betting_accounts;
BEGIN
  IF p_enabled IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'enabled is required');
  END IF;
  SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting account not found');
  END IF;
  IF p_enabled AND NOT (a.uses_server_secrets AND NOT a.has_credentials)
     AND NOT (a.has_credentials AND a.tested_version IS NOT NULL AND a.tested_version = a.config_version) THEN
    PERFORM private.raise_api(409, 'NOT_TESTED', 'Test the connection first: only an account whose credentials passed can be switched on');
  END IF;
  IF NOT p_enabled AND a.is_selected
     AND COALESCE((SELECT m.enabled FROM public.payment_methods m WHERE m.method::text = a.method_key), false) THEN
    PERFORM private.raise_api(409, 'ACCOUNT_IN_USE', 'This account is in use: select another account first, or switch the platform off');
  END IF;
  UPDATE public.betting_accounts SET enabled = p_enabled, updated_by = v_id, updated_at = now() WHERE id = a.id;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_enabled THEN 'betting_account.activate' ELSE 'betting_account.deactivate' END,
    'betting_account', a.method_key || '/' || a.label, NULL, jsonb_build_object('method', a.method_key, 'account', a.label));
  RETURN private.betting_platform_json(a.method_key);
END $$;

-- The admin selects which account customers' deposits and withdrawals use. It
-- must be ON (so tested); it applies from the next order.
CREATE OR REPLACE FUNCTION public.manage_select_betting_account(p_account uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.betting_accounts;
  v_old public.betting_accounts;
BEGIN
  SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting account not found');
  END IF;
  IF a.is_selected THEN
    RETURN private.betting_platform_json(a.method_key);
  END IF;
  IF NOT a.enabled THEN
    PERFORM private.raise_api(409, 'ACCOUNT_OFF', 'Switch the account on first (it has to pass Test connection)');
  END IF;
  v_old := private.betting_selected(a.method_key);
  UPDATE public.betting_accounts SET is_selected = false, updated_by = v_id, updated_at = now() WHERE id = v_old.id;
  UPDATE public.betting_accounts SET is_selected = true, updated_by = v_id, updated_at = now() WHERE id = a.id;
  PERFORM private.audit(v_id, private.app_role(), 'betting_account.select', 'betting_account', a.method_key || '/' || a.label, NULL,
    jsonb_build_object('method', a.method_key, 'account', a.label, 'from', v_old.label));
  RETURN private.betting_platform_json(a.method_key);
END $$;

-- Removes an account: its secrets are deleted, its orders stay. The account in
-- use can not be removed.
CREATE OR REPLACE FUNCTION public.manage_remove_betting_account(p_account uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.betting_accounts;
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  SELECT * INTO a FROM public.betting_accounts WHERE id = p_account AND removed_at IS NULL FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting account not found');
  END IF;
  IF a.is_selected THEN
    PERFORM private.raise_api(409, 'ACCOUNT_IN_USE', 'This account is in use: select another account first');
  END IF;
  DELETE FROM vault.secrets WHERE id IN (a.username_secret_id, a.password_secret_id, a.hash_secret_id, a.api_key_secret_id);
  UPDATE public.betting_accounts SET removed_at = now(), enabled = false, has_credentials = false, tested_version = NULL,
    username_secret_id = NULL, password_secret_id = NULL, hash_secret_id = NULL, api_key_secret_id = NULL,
    updated_by = v_id, updated_at = now()
  WHERE id = a.id;
  PERFORM private.audit(v_id, private.app_role(), 'betting_account.remove', 'betting_account', a.method_key || '/' || a.label, NULL,
    jsonb_build_object('method', a.method_key, 'account', a.label, 'reason', btrim(p_reason),
                       'orders', (SELECT count(*) FROM public.orders o WHERE o.betting_account_id = a.id)));
  RETURN private.betting_platform_json(a.method_key);
END $$;

-- ------------------------------------------------------------ privileges

REVOKE ALL ON FUNCTION private.betting_selected(text), private.ensure_betting_account(text, uuid), private.betting_account_status(public.betting_accounts),
  private.betting_account_json(public.betting_accounts),
  private.save_betting_account(uuid, uuid, text, text, text, text, text, text), private.betting_after_save(text, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_save_betting_platform(text, text, text, text, text, text, text),
  public.manage_save_betting_account(uuid, text, text, text, text, text, text),
  public.manage_set_betting_platform_active(text, boolean), public.manage_delete_betting_platform(text, text),
  public.manage_create_betting_platform(text, text), public.manage_add_betting_account(text, text),
  public.manage_rename_betting_account(uuid, text), public.manage_set_betting_account_enabled(uuid, boolean),
  public.manage_select_betting_account(uuid), public.manage_remove_betting_account(uuid, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_save_betting_platform(text, text, text, text, text, text, text),
  public.manage_save_betting_account(uuid, text, text, text, text, text, text),
  public.manage_set_betting_platform_active(text, boolean), public.manage_delete_betting_platform(text, text),
  public.manage_create_betting_platform(text, text), public.manage_add_betting_account(text, text),
  public.manage_rename_betting_account(uuid, text), public.manage_set_betting_account_enabled(uuid, boolean),
  public.manage_select_betting_account(uuid), public.manage_remove_betting_account(uuid, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.betting_platform_config(text, boolean, uuid), public.betting_platform_record_test(text, uuid, boolean, text, uuid, uuid),
  public.platform_record_account(uuid, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.betting_platform_config(text, boolean, uuid), public.betting_platform_record_test(text, uuid, boolean, text, uuid, uuid),
  public.platform_record_account(uuid, uuid) TO service_role;
