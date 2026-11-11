-- Betting platforms: dynamic, for every platform now and in the future.
--
-- A betting platform is a payment method of kind 'platform'. Platforms made
-- in the Agent App (manage_create_betting_platform) always had their own
-- connection record (payment_integrations, kind 'betting') with ON/OFF,
-- credentials, a connection test and a logo. A platform that existed only as
-- a payment-method row (Betandyou, LuckyPari, Goldpari, or any added from the
-- backend or the Admin Dashboard) had none: it showed in the Agent App list but
-- its credentials, test and logo could not be saved ("not found").
--
-- From now on:
--   * a payment method of kind 'platform' gets its connection record the moment
--     it exists (a trigger), and the ones that exist now get it here;
--   * such a platform keeps behaving exactly as it did -- same ON/OFF, the same
--     deposit screen for customers (account ID and amount, handled by hand) --
--     until its cash desk is connected (credentials saved and tested). Only
--     then it becomes a cash-desk platform for customers (account ID and code,
--     checked automatically), without any new app release: the Customer App
--     reads that from the catalog;
--   * its ON/OFF is its own; saving credentials never switches it off;
--   * the Agent App shows the connection status and whether customers use
--     the cash desk or the manual deposit ('mode').
-- Nothing here changes an order, a balance, a rate or whether a platform is on.

ALTER TABLE public.payment_integrations
  ADD COLUMN IF NOT EXISTS legacy_manual BOOLEAN NOT NULL DEFAULT false;

-- A cash-desk platform for customers: the built-in ones, and those added
-- here and not removed -- a platform that existed before it had a connection
-- record only once its credentials passed their test.
CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT p_method::text = ANY (private.built_in_platforms())
      OR EXISTS (SELECT 1 FROM public.payment_integrations i
                 WHERE i.kind = 'betting' AND i.method_key = p_method::text AND i.deleted_at IS NULL
                   AND (NOT i.legacy_manual
                        OR (i.has_credentials AND i.tested_version IS NOT NULL AND i.tested_version = i.config_version)))
$$;

-- Gives a platform that has none its connection record (idempotent).
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
  PERFORM private.audit(NULL, NULL, 'betting_platform.adopt', 'payment_integration', 'betting:' || p_method, NULL,
    jsonb_build_object('method', p_method, 'name', m.label, 'active', m.enabled));
END $$;
REVOKE ALL ON FUNCTION private.adopt_betting_platform(text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.payment_method_adopt_trigger()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.adopt_betting_platform(NEW.method::text);
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.payment_method_adopt_trigger() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS payment_methods_adopt_platform ON public.payment_methods;
CREATE TRIGGER payment_methods_adopt_platform AFTER INSERT OR UPDATE OF kind ON public.payment_methods
  FOR EACH ROW WHEN (NEW.kind = 'platform') EXECUTE FUNCTION private.payment_method_adopt_trigger();

-- The platforms that exist now.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT method::text AS m FROM public.payment_methods WHERE kind = 'platform' LOOP
    PERFORM private.adopt_betting_platform(r.m);
  END LOOP;
END $$;

-- The platform as the Agent App shows it: now also how customers use it.
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
    -- What a customer gets: 'cashdesk' (account ID and a code, checked automatically) or 'manual' (account ID and amount, handled by hand).
    'mode', CASE WHEN private.is_cashdesk_method(p_method::public.order_method) THEN 'cashdesk' ELSE 'manual' END,
    'apiUrl', i.api_url,
    'accountId', i.account_id,
    'login', private.mask((SELECT s.decrypted_secret FROM vault.decrypted_secrets s WHERE s.id = i.username_secret_id)),
    'hasPassword', i.password_secret_id IS NOT NULL,
    'hasApiSecret', i.hash_secret_id IS NOT NULL,
    'hasApiKey', i.api_key_secret_id IS NOT NULL,
    'lastTestAt', i.last_test_at, 'lastOkAt', i.last_ok_at, 'lastMessage', i.last_test_message,
    'updatedAt', i.updated_at,
    'updatedBy', (SELECT u.name FROM public.users u WHERE u.id = i.updated_by),
    'logo', private.betting_logo_b64(p_method));
END $$;

-- Saving credentials: a platform that existed before gets its record first, and
-- saving never switches it off (it was already live without a cash desk).
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
    IF p_method = ANY (private.built_in_platforms()) THEN
      INSERT INTO public.payment_integrations (provider, kind, adapter, method_key, status, built_in, created_by)
      VALUES ('betting:' || p_method, 'betting', 'cashdeskbot', p_method, 'inactive', true, v_id)
      RETURNING * INTO i;
    ELSIF EXISTS (SELECT 1 FROM public.payment_methods WHERE method::text = p_method AND kind = 'platform') THEN
      PERFORM private.adopt_betting_platform(p_method);
      i := private.betting_row(p_method);
    ELSE
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
    END IF;
  END IF;
  IF i.id IS NULL OR i.deleted_at IS NOT NULL THEN
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
  -- A new platform is not switched on until this version passes a test (one that was live before it had a cash desk stays as it is).
  IF NOT (i.tested_version IS NOT NULL AND i.tested_version = i.config_version) AND NOT i.built_in AND NOT i.legacy_manual THEN
    UPDATE public.payment_methods SET enabled = false, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.update', 'payment_integration', i.provider, NULL,
    jsonb_build_object('method', p_method, 'changed', to_jsonb(v_changed)));
  RETURN private.betting_platform_json(p_method);
END $$;

-- On / off. A new platform needs its saved credentials to have passed their
-- test; one that was live before it had a cash desk (or a built-in one without
-- saved credentials) can be switched on and off freely.
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
       OR (i.id IS NULL AND NOT (p_method = ANY (private.built_in_platforms())))
       OR (i.id IS NOT NULL AND NOT i.has_credentials AND i.built_in)
       OR (i.id IS NOT NULL AND i.legacy_manual)
       OR (i.tested_version IS NOT NULL AND i.tested_version = i.config_version)) THEN
    PERFORM private.raise_api(409, 'NOT_TESTED', 'Test the connection first: only a platform whose credentials passed can be switched on');
  END IF;
  UPDATE public.payment_methods SET enabled = p_active, updated_by = v_id, updated_at = now() WHERE method::text = p_method;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_active THEN 'betting_platform.activate' ELSE 'betting_platform.deactivate' END,
    'payment_integration', 'betting:' || p_method, NULL, jsonb_build_object('method', p_method));
  RETURN private.betting_platform_json(p_method);
END $$;
