-- Adding a betting platform again after it was removed.
--
-- Diagnosed on production (supabase/diagnostics/payments.sql section 19,
-- 2026-10-29): "Goldpari" was added on 10-28 13:55 and removed before it was
-- ever saved. The removal hides the platform (a row marked deleted) but the
-- name's order_method value stays for good (a Postgres enum value cannot be
-- dropped), so adding "Goldpari" again was refused with "A payment method
-- with this name already exists" although nothing used the name.
--
-- Now a name that was added and removed WITHOUT ever becoming a payment
-- method (no payment_methods row, so no order, no customer ever saw it) can
-- be added again: its removed row is revived, switched off, with no
-- credentials. A removed platform that did become a payment method (it may
-- have orders) and every name in use stay refused, as before.
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
  IF v_key !~ '^[a-z][a-z0-9]{1,29}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The name must start with a letter and contain letters or digits');
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
  PERFORM private.audit(v_id, private.app_role(), 'betting_platform.create', 'payment_integration', 'betting:' || v_key, NULL,
    jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter, 'readded', v_revive));
  RETURN jsonb_build_object('method', v_key, 'name', btrim(p_name), 'adapter', p_adapter, 'status', 'not_configured', 'active', false);
END $$;
