-- A logo for a betting platform added in the Agent App.
--
-- The built-in platforms have their logo inside the Customer App; an added
-- one (e.g. "wowbet") showed only coloured initials. A manager can now give
-- it a logo: a small PNG or JPEG (the Agent App makes it 128 x 128; at most
-- 60 KB here). It is stored with the platform and sent to the Customer App
-- in the payment-method catalog as base64, so it appears without a new app
-- release. Only the logo changes: credentials, tests and orders are not
-- touched, and a tested connection stays tested.
ALTER TABLE public.payment_integrations ADD COLUMN IF NOT EXISTS logo BYTEA;

CREATE OR REPLACE FUNCTION private.betting_logo_b64(p_method text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT replace(encode(i.logo, 'base64'), E'\n', '')
  FROM public.payment_integrations i
  WHERE i.kind = 'betting' AND i.method_key = p_method AND i.deleted_at IS NULL AND i.logo IS NOT NULL
$$;
REVOKE ALL ON FUNCTION private.betting_logo_b64(text) FROM PUBLIC, anon, authenticated;

-- The Customer App's catalog, as before, plus the logo (null when none).
CREATE OR REPLACE FUNCTION public.payment_method_catalog()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'method', method, 'label', label, 'kind', kind, 'color', color, 'initials', initials,
    'order', sort_order, 'enabled', enabled, 'updatedAt', updated_at,
    'cashdesk', private.is_cashdesk_method(method),
    'logo', private.betting_logo_b64(method::text)
  ) ORDER BY sort_order), '[]'::jsonb)
  FROM public.payment_methods
  WHERE NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                    WHERE i.kind = 'betting' AND i.method_key = method::text AND i.deleted_at IS NOT NULL)
$$;

-- The Agent App's platform, plus its logo.
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
    'updatedBy', (SELECT u.name FROM public.users u WHERE u.id = i.updated_by),
    'logo', private.betting_logo_b64(p_method));
END $$;

-- A manager sets (base64 PNG or JPEG) or removes (empty) an added platform's logo.
CREATE OR REPLACE FUNCTION public.manage_set_betting_platform_logo(p_method text, p_logo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
  v_b64 text := regexp_replace(COALESCE(p_logo, ''), '\s', '', 'g');
  v_bytes bytea;
BEGIN
  IF i.id IS NULL OR i.deleted_at IS NOT NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  IF p_method = ANY (private.built_in_platforms()) THEN
    PERFORM private.raise_api(400, 'BUILT_IN', 'A built-in platform keeps its own logo');
  END IF;
  IF v_b64 = '' THEN
    UPDATE public.payment_integrations SET logo = NULL, updated_by = v_id, updated_at = now() WHERE id = i.id;
    PERFORM private.audit(v_id, private.app_role(), 'betting_platform.logo', 'payment_integration', i.provider, NULL,
                          jsonb_build_object('method', p_method, 'removed', true));
  ELSE
    IF length(v_b64) > 82000 OR v_b64 !~ '^[A-Za-z0-9+/]+={0,2}$' THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The logo must be a small PNG or JPEG picture (up to 60 KB)');
    END IF;
    BEGIN
      v_bytes := decode(v_b64, 'base64');
    EXCEPTION WHEN others THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The logo must be a small PNG or JPEG picture (up to 60 KB)');
    END;
    IF length(v_bytes) > 60000
       OR NOT (substring(v_bytes FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea OR substring(v_bytes FROM 1 FOR 3) = '\xffd8ff'::bytea) THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The logo must be a small PNG or JPEG picture (up to 60 KB)');
    END IF;
    UPDATE public.payment_integrations SET logo = v_bytes, updated_by = v_id, updated_at = now() WHERE id = i.id;
    PERFORM private.audit(v_id, private.app_role(), 'betting_platform.logo', 'payment_integration', i.provider, NULL,
                          jsonb_build_object('method', p_method, 'bytes', length(v_bytes)));
  END IF;
  RETURN private.betting_platform_json(p_method);
END $$;

REVOKE ALL ON FUNCTION public.manage_set_betting_platform_logo(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_set_betting_platform_logo(text, text) TO authenticated, service_role;
