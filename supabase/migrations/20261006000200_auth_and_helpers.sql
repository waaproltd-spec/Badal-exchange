-- Supabase Auth for BAARI, and the private helpers every API function uses.
--
-- Accounts stay in public.users (role, phone, name, status, bcrypt
-- password_hash) exactly as before. Each one is mirrored into auth.users
-- with the SAME id and the SAME bcrypt hash, so:
--   * existing users log in to Supabase Auth with their current password
--     (no reset needed), and accounts created later -- by the register_customer
--     RPC, by a manager creating an agent, or by the Node backend -- get a
--     Supabase login automatically;
--   * auth.uid() in a request is the public.users id.
--
-- Supabase Auth logs in with an email address, so each account gets a
-- synthetic one derived from its phone number (see private.auth_email; the
-- apps compute the same address). Nothing is ever emailed to it.
-- Disabled accounts are banned in Supabase Auth, so they cannot log in or
-- refresh a session; every API function also checks status on each call.

CREATE SCHEMA IF NOT EXISTS private;
REVOKE ALL ON SCHEMA private FROM PUBLIC;
-- Row-level-security policies call a few private helpers as the requesting
-- role. The schema is not exposed by the Data API, so nothing in it can be
-- called as an RPC.
GRANT USAGE ON SCHEMA private TO anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Errors: PostgREST turns SQLSTATE 'PTxyz' into HTTP status xyz. The app
-- error code (e.g. INSUFFICIENT_BALANCE) travels in HINT; the apps map
-- {message, hint} to the same ApiException the REST backend produced.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.raise_api(p_status int, p_code text, p_message text)
RETURNS void
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION USING ERRCODE = 'PT' || p_status::text, MESSAGE = p_message, HINT = p_code;
END
$$;

-- ---------------------------------------------------------------------------
-- Money: cents <-> decimal strings, as the REST API returned them.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.money(p_cents numeric)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$ SELECT round(COALESCE(p_cents, 0) / 100.0, 2)::numeric(20, 2)::text $$;

-- Same rules as lib/money.ts toCents: finite, non-negative, rounded to cents.
CREATE OR REPLACE FUNCTION private.to_cents(p_amount text)
RETURNS bigint
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
DECLARE
  v numeric;
BEGIN
  BEGIN
    v := trim(p_amount)::numeric;
  EXCEPTION WHEN others THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount: ' || COALESCE(p_amount, 'null'));
  END;
  IF v IS NULL OR v < 0 OR v = 'NaN'::numeric OR v > 1e15 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount: ' || COALESCE(p_amount, 'null'));
  END IF;
  RETURN round(v * 100)::bigint;
END
$$;

-- Validates a text field's length like the REST API's zod schemas did.
CREATE OR REPLACE FUNCTION private.check_len(p_value text, p_field text, p_min int, p_max int, p_required boolean DEFAULT true)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_value IS NULL THEN
    IF p_required THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', p_field || ' is required');
    END IF;
    RETURN NULL;
  END IF;
  IF char_length(p_value) < p_min OR char_length(p_value) > p_max THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR',
      format('%s must be between %s and %s characters', p_field, p_min, p_max));
  END IF;
  RETURN p_value;
END
$$;

CREATE OR REPLACE FUNCTION private.parse_ts(p_value text, p_field text)
RETURNS timestamptz
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
BEGIN
  IF p_value IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', p_field || ' is required');
  END IF;
  RETURN p_value::timestamptz;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation THEN
  PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid ' || p_field);
  RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION private.parse_date(p_value text, p_field text)
RETURNS date
LANGUAGE plpgsql
IMMUTABLE
SET search_path = ''
AS $$
BEGIN
  IF p_value IS NULL THEN
    RETURN NULL;
  END IF;
  IF p_value !~ '^\d{4}-\d{2}-\d{2}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid ' || p_field);
  END IF;
  RETURN p_value::date;
EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
  PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid ' || p_field);
  RETURN NULL;
END
$$;

-- ---------------------------------------------------------------------------
-- Passwords (bcrypt, compatible with the Node backend's bcryptjs hashes and
-- with Supabase Auth). pgcrypto only reads the $2a$ prefix; $2b$/$2y$ are
-- the same algorithm for passwords this short.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.hash_password(p_password text)
RETURNS text
LANGUAGE sql
VOLATILE
SET search_path = ''
AS $$ SELECT extensions.crypt(p_password, extensions.gen_salt('bf', 10)) $$;

CREATE OR REPLACE FUNCTION private.verify_password(p_password text, p_hash text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  v_hash text := p_hash;
BEGIN
  IF p_password IS NULL OR v_hash IS NULL OR v_hash !~ '^\$2[aby]\$' THEN
    RETURN false;
  END IF;
  v_hash := '$2a$' || substr(v_hash, 5);
  RETURN extensions.crypt(p_password, v_hash) = v_hash;
END
$$;

-- ---------------------------------------------------------------------------
-- Request context
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.request_ip()
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = ''
AS $$
DECLARE
  h jsonb;
BEGIN
  h := NULLIF(current_setting('request.headers', true), '')::jsonb;
  RETURN COALESCE(
    h ->> 'cf-connecting-ip',
    split_part(h ->> 'x-forwarded-for', ',', 1),
    h ->> 'x-real-ip'
  );
EXCEPTION WHEN others THEN
  RETURN NULL;
END
$$;

-- Role of the signed-in user, only while the account is active.
CREATE OR REPLACE FUNCTION private.app_role()
RETURNS public.user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT u.role FROM public.users u WHERE u.id = auth.uid() AND u.status = 'active'
$$;

CREATE OR REPLACE FUNCTION private.is_staff()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT COALESCE(private.app_role() IN ('agent', 'admin'), false) $$;

-- Management access (formerly the admin dashboard): admins, and active
-- agents holding the 'manage_settings' responsibility. Checked live on
-- every call, so revoking the responsibility takes effect immediately.
CREATE OR REPLACE FUNCTION private.can_manage()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE((
    SELECT u.role = 'admin'
        OR (u.role = 'agent' AND 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}')))
    FROM public.users u
    LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.id = auth.uid() AND u.status = 'active'
  ), false)
$$;

-- Guards used at the top of every API function. They return the caller's
-- user id.
CREATE OR REPLACE FUNCTION private.require_user()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status public.user_status;
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Missing bearer token');
  END IF;
  SELECT status INTO v_status FROM public.users WHERE id = auth.uid();
  IF v_status IS NULL THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Invalid or expired token');
  END IF;
  IF v_status <> 'active' THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Account is disabled');
  END IF;
  RETURN auth.uid();
END
$$;

CREATE OR REPLACE FUNCTION private.require_role(p_role public.user_role)
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_user();
BEGIN
  IF private.app_role() IS DISTINCT FROM p_role THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
  RETURN v_id;
END
$$;

CREATE OR REPLACE FUNCTION private.require_management()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_user();
BEGIN
  IF private.app_role() NOT IN ('agent', 'admin') THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
  IF NOT private.can_manage() THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Your account is not allowed to manage settings. Ask an admin for access.');
  END IF;
  RETURN v_id;
END
$$;

-- ---------------------------------------------------------------------------
-- Audit log
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.audit(
  p_actor_id uuid,
  p_actor_role public.user_role,
  p_action text,
  p_entity_type text,
  p_entity_id text,
  p_before jsonb DEFAULT NULL,
  p_after jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.audit_logs (actor_id, actor_role, action, entity_type, entity_id, before_json, after_json, ip)
  VALUES (p_actor_id, p_actor_role, p_action, p_entity_type, p_entity_id, p_before, p_after, private.request_ip())
$$;

-- ---------------------------------------------------------------------------
-- Idempotency (lib/idempotency.ts): money-moving calls carry a client key;
-- a retry with the same key and arguments returns the first response
-- instead of running again. Also applies the money rate limit (20 per
-- minute per user, as moneyLimiter did).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.idempotency_begin(p_key text, p_endpoint text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_user uuid := auth.uid();
  v_hash text;
  v_row public.idempotency_keys;
BEGIN
  IF p_key IS NULL OR btrim(p_key) = '' THEN
    PERFORM private.raise_api(400, 'IDEMPOTENCY_KEY_REQUIRED', 'Idempotency-Key header is required');
  END IF;
  IF char_length(p_key) > 200 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Idempotency key is too long');
  END IF;
  v_hash := md5(jsonb_build_object('endpoint', p_endpoint, 'userId', v_user, 'body', p_payload)::text);

  INSERT INTO public.idempotency_keys (key, user_id, endpoint, request_hash)
  VALUES (p_key, v_user, p_endpoint, v_hash)
  ON CONFLICT (key) DO NOTHING;
  IF FOUND THEN
    IF (SELECT count(*) FROM public.idempotency_keys
        WHERE user_id IS NOT DISTINCT FROM v_user AND created_at > now() - interval '1 minute') > 20 THEN
      PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many requests, slow down.');
    END IF;
    RETURN NULL;
  END IF;

  SELECT * INTO v_row FROM public.idempotency_keys WHERE key = p_key;
  IF v_row.request_hash IS DISTINCT FROM v_hash THEN
    PERFORM private.raise_api(409, 'IDEMPOTENCY_KEY_REUSED', 'Idempotency-Key was already used with a different request');
  END IF;
  IF v_row.status_code IS NULL THEN
    PERFORM private.raise_api(409, 'REQUEST_IN_PROGRESS', 'This request is already being processed');
  END IF;
  RETURN v_row.response_json;
END
$$;

CREATE OR REPLACE FUNCTION private.idempotency_finish(p_key text, p_response jsonb, p_status int DEFAULT 200)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  UPDATE public.idempotency_keys SET status_code = p_status, response_json = p_response WHERE key = p_key;
  SELECT p_response;
$$;

-- ---------------------------------------------------------------------------
-- public.users -> auth.users mirror
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.auth_email(p_phone text, p_email text)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE
    WHEN p_phone IS NOT NULL THEN
      CASE
        WHEN char_length(regexp_replace(p_phone, '\D', '', 'g')) >= 4 THEN regexp_replace(p_phone, '\D', '', 'g')
        ELSE 'x' || encode(convert_to(p_phone, 'UTF8'), 'hex')
      END || '@phone.baari.invalid'
    ELSE lower(p_email)
  END
$$;

CREATE OR REPLACE FUNCTION private.sync_auth_user(p_user_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  u public.users;
  v_email text;
  v_banned timestamptz;
BEGIN
  SELECT * INTO u FROM public.users WHERE id = p_user_id;
  IF NOT FOUND THEN
    RETURN;
  END IF;
  v_email := private.auth_email(u.phone, u.email);
  v_banned := CASE WHEN u.status = 'disabled' THEN '2999-12-31 00:00:00+00'::timestamptz END;

  IF NOT EXISTS (SELECT 1 FROM auth.users WHERE id = u.id) THEN
    INSERT INTO auth.users (
      instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
      raw_app_meta_data, raw_user_meta_data, created_at, updated_at, banned_until,
      confirmation_token, recovery_token, email_change_token_new, email_change
    ) VALUES (
      '00000000-0000-0000-0000-000000000000', u.id, 'authenticated', 'authenticated', v_email, u.password_hash, now(),
      jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'), 'app_role', u.role),
      jsonb_build_object('name', u.name),
      u.created_at, now(), v_banned,
      '', '', '', ''
    );
    INSERT INTO auth.identities (id, provider_id, user_id, identity_data, provider, created_at, updated_at)
    VALUES (
      gen_random_uuid(), u.id::text, u.id,
      jsonb_build_object('sub', u.id::text, 'email', v_email, 'email_verified', true, 'phone_verified', false),
      'email', now(), now()
    );
    RETURN;
  END IF;

  UPDATE auth.users a
  SET email = v_email,
      encrypted_password = u.password_hash,
      banned_until = v_banned,
      raw_app_meta_data = COALESCE(a.raw_app_meta_data, '{}'::jsonb) || jsonb_build_object('app_role', u.role),
      updated_at = now()
  WHERE a.id = u.id
    AND (a.email IS DISTINCT FROM v_email
      OR a.encrypted_password IS DISTINCT FROM u.password_hash
      OR a.banned_until IS DISTINCT FROM v_banned
      OR a.raw_app_meta_data ->> 'app_role' IS DISTINCT FROM u.role::text);

  UPDATE auth.identities i
  SET identity_data = i.identity_data || jsonb_build_object('email', v_email), updated_at = now()
  WHERE i.user_id = u.id AND i.provider = 'email' AND i.identity_data ->> 'email' IS DISTINCT FROM v_email;

  -- A disabled account is signed out everywhere at once.
  IF u.status = 'disabled' THEN
    DELETE FROM auth.sessions WHERE user_id = u.id;
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION private.users_after_write()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  PERFORM private.sync_auth_user(NEW.id);
  RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS users_sync_auth ON public.users;
CREATE TRIGGER users_sync_auth
  AFTER INSERT OR UPDATE OF phone, email, password_hash, status, role, name ON public.users
  FOR EACH ROW EXECUTE FUNCTION private.users_after_write();

-- A password changed through Supabase Auth itself (e.g. a recovery flow
-- run from the Supabase dashboard) is copied back, so both stay in step.
CREATE OR REPLACE FUNCTION private.auth_password_changed()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF NEW.encrypted_password IS NOT NULL AND NEW.encrypted_password <> '' THEN
    UPDATE public.users
    SET password_hash = NEW.encrypted_password, updated_at = now()
    WHERE id = NEW.id AND password_hash IS DISTINCT FROM NEW.encrypted_password;
  END IF;
  RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS on_auth_password_changed ON auth.users;
CREATE TRIGGER on_auth_password_changed
  AFTER UPDATE OF encrypted_password ON auth.users
  FOR EACH ROW EXECUTE FUNCTION private.auth_password_changed();

-- Every account that already exists gets its Supabase login now.
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT id FROM public.users LOOP
    PERFORM private.sync_auth_user(r.id);
  END LOOP;
END
$$;

-- Nothing in the private schema is callable by API roles except the
-- helpers row-level-security policies need (granted in the RLS migration).
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA private REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
