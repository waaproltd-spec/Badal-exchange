-- One customer account, one phone at a time. A customer's latest login
-- (session_profile with p_record_login, which the Customer App calls right
-- after signing in) becomes the account's only active session; every other
-- session of that customer is refused from then on (401 SESSION_REPLACED),
-- and the app on the old phone goes back to the login screen. The app also
-- revokes the other sessions' refresh tokens (Supabase Auth, scope others).
-- Agents and managers are not limited. Customers signed in before this
-- change keep working until their next login.

CREATE TABLE IF NOT EXISTS private.customer_active_session (
  user_id     UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  session_id  TEXT NOT NULL,
  claimed_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
REVOKE ALL ON private.customer_active_session FROM PUBLIC, anon, authenticated;

-- Refuses a customer session that another login replaced.
CREATE OR REPLACE FUNCTION private.check_customer_session(p_user_id uuid, p_role public.user_role)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_session text := auth.jwt() ->> 'session_id';
BEGIN
  IF p_role = 'customer' AND v_session IS NOT NULL AND EXISTS (
       SELECT 1 FROM private.customer_active_session s WHERE s.user_id = p_user_id AND s.session_id <> v_session) THEN
    PERFORM private.raise_api(401, 'SESSION_REPLACED', 'This account was opened on another phone. Log in again.');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.require_user()
RETURNS uuid
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_status public.user_status;
  v_role public.user_role;
BEGIN
  IF auth.uid() IS NULL THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Missing bearer token');
  END IF;
  SELECT status, role INTO v_status, v_role FROM public.users WHERE id = auth.uid();
  IF v_status IS NULL THEN
    PERFORM private.raise_api(401, 'UNAUTHORIZED', 'Invalid or expired token');
  END IF;
  IF v_status <> 'active' THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Account is disabled');
  END IF;
  PERFORM private.check_customer_session(auth.uid(), v_role);
  RETURN auth.uid();
END
$$;

CREATE OR REPLACE FUNCTION public.session_profile(p_record_login boolean DEFAULT false)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  u public.users;
  v_session text := auth.jwt() ->> 'session_id';
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
    -- This login is now the customer's only phone.
    IF u.role = 'customer' AND v_session IS NOT NULL THEN
      INSERT INTO private.customer_active_session (user_id, session_id) VALUES (u.id, v_session)
      ON CONFLICT (user_id) DO UPDATE SET session_id = EXCLUDED.session_id, claimed_at = now();
    END IF;
  ELSE
    PERFORM private.check_customer_session(u.id, u.role);
  END IF;
  RETURN jsonb_build_object(
    'id', u.id, 'role', u.role, 'name', u.name, 'phone', u.phone, 'email', u.email, 'status', u.status
  );
END
$$;

REVOKE ALL ON FUNCTION private.check_customer_session(uuid, public.user_role) FROM PUBLIC, anon, authenticated;
