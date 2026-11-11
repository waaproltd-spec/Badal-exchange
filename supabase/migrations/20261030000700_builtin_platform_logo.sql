-- A manager can give a built-in betting platform (1XBET, MELBET, WinWin, DBbet,
-- Betwinner, BetJam, BetOnGame, 888STARZ) a different logo from the Agent App.
-- It is kept apart from the platform (credentials, tests and orders are not
-- touched), sent to the Customer App in the payment-method catalog like an added
-- platform's logo, and shown instead of the one built into the app. Removing it
-- brings the built-in logo back.
CREATE TABLE IF NOT EXISTS public.platform_logo_overrides (
  method_key TEXT PRIMARY KEY,
  logo       BYTEA NOT NULL,
  updated_by UUID REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.platform_logo_overrides ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_logo_overrides FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.betting_logo_b64(p_method text)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(
    (SELECT replace(encode(i.logo, 'base64'), E'\n', '')
       FROM public.payment_integrations i
      WHERE i.kind = 'betting' AND i.method_key = p_method AND i.deleted_at IS NULL AND i.logo IS NOT NULL),
    (SELECT replace(encode(o.logo, 'base64'), E'\n', '')
       FROM public.platform_logo_overrides o
      WHERE o.method_key = p_method AND p_method = ANY (private.built_in_platforms())))
$$;
REVOKE ALL ON FUNCTION private.betting_logo_b64(text) FROM PUBLIC, anon, authenticated;

-- A manager sets (base64 PNG or JPEG) or removes (empty) a platform's logo:
-- an added platform's own, or a built-in platform's replacement.
CREATE OR REPLACE FUNCTION public.manage_set_betting_platform_logo(p_method text, p_logo text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  i public.payment_integrations := private.betting_row(p_method);
  v_builtin boolean := p_method = ANY (private.built_in_platforms());
  v_b64 text := regexp_replace(COALESCE(p_logo, ''), '\s', '', 'g');
  v_bytes bytea;
BEGIN
  IF NOT v_builtin AND (i.id IS NULL OR i.deleted_at IS NOT NULL) THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Betting platform not found');
  END IF;
  IF v_b64 <> '' THEN
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
  END IF;

  IF v_builtin THEN
    IF v_bytes IS NULL THEN
      DELETE FROM public.platform_logo_overrides WHERE method_key = p_method;
    ELSE
      INSERT INTO public.platform_logo_overrides (method_key, logo, updated_by) VALUES (p_method, v_bytes, v_id)
      ON CONFLICT (method_key) DO UPDATE SET logo = EXCLUDED.logo, updated_by = EXCLUDED.updated_by, updated_at = now();
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'betting_platform.logo', 'platform_logo', p_method, NULL,
                          jsonb_build_object('method', p_method, 'builtIn', true, 'removed', v_bytes IS NULL, 'bytes', length(v_bytes)));
  ELSIF v_bytes IS NULL THEN
    UPDATE public.payment_integrations SET logo = NULL, updated_by = v_id, updated_at = now() WHERE id = i.id;
    PERFORM private.audit(v_id, private.app_role(), 'betting_platform.logo', 'payment_integration', i.provider, NULL,
                          jsonb_build_object('method', p_method, 'removed', true));
  ELSE
    UPDATE public.payment_integrations SET logo = v_bytes, updated_by = v_id, updated_at = now() WHERE id = i.id;
    PERFORM private.audit(v_id, private.app_role(), 'betting_platform.logo', 'payment_integration', i.provider, NULL,
                          jsonb_build_object('method', p_method, 'bytes', length(v_bytes)));
  END IF;
  RETURN private.betting_platform_json(p_method);
END $$;
REVOKE ALL ON FUNCTION public.manage_set_betting_platform_logo(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_set_betting_platform_logo(text, text) TO authenticated, service_role;
