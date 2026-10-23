-- Customer App log-in screen: "Forgot password?".
--
-- support_contacts: the support links (WhatsApp, Telegram, Facebook) the
-- app already shows signed-in customers, now readable before logging in,
-- so a customer who forgot the password can reach support.
--
-- manage_reset_customer_password: management sets a new password for a
-- customer who asked support for one (Agent App -> Customer Info). The
-- customer's sessions are signed out; the action is audited, the password
-- never stored or logged in clear.

CREATE OR REPLACE FUNCTION public.support_contacts()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.contacts_json()
$$;

REVOKE ALL ON FUNCTION public.support_contacts() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.support_contacts() TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.manage_reset_customer_password(p_customer_id uuid, p_new_password text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  PERFORM private.check_len(p_new_password, 'newPassword', 8, 72);
  UPDATE public.users SET password_hash = private.hash_password(p_new_password), updated_at = now()
  WHERE id = p_customer_id AND role = 'customer';
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  UPDATE public.refresh_tokens SET revoked_at = now() WHERE user_id = p_customer_id AND revoked_at IS NULL;
  DELETE FROM auth.sessions WHERE user_id = p_customer_id;
  PERFORM private.audit(v_id, private.app_role(), 'customer.reset_password', 'user', p_customer_id::text);
END $$;

REVOKE ALL ON FUNCTION public.manage_reset_customer_password(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_reset_customer_password(uuid, text) TO authenticated, service_role;
