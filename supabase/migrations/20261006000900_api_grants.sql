-- Who may call which API function.
--
-- PostgreSQL lets everyone (PUBLIC) execute new functions by default. The
-- API functions all check the caller themselves, but only signed-in users
-- get to call them at all; the two calls a signed-out app needs (sign-up
-- and the payment-method catalog) are the exceptions.

-- POST /admin/payment-integrations/mobcash_winwin/login-check opens the real
-- MobCash portal in a headless browser. That can only run on the MobCash
-- automation worker (backend/, see supabase/README.md), not inside the
-- database, so the app is told so instead of getting a made-up result.
CREATE OR REPLACE FUNCTION public.admin_mobcash_login_check(p_username text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  PERFORM private.raise_api(503, 'WORKER_REQUIRED',
    'The MobCash login check runs on the MobCash automation worker. Save the credentials and check the automation runs instead.');
  RETURN NULL;
END $$;

DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig, p.proname
    FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace
      AND p.prokind = 'f'
      AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
    IF f.proname IN ('register_customer', 'payment_method_catalog') THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon', f.sig);
    END IF;
  END LOOP;
END
$$;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon;

-- Private helpers: nothing callable by app roles except what RLS needs.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.app_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_staff() TO anon, authenticated;
