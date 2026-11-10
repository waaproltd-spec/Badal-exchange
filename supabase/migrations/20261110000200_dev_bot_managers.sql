-- The Developer Bot's owner is the platform's MANAGER: an administrator, or an agent with the manage_settings responsibility
-- (the same people private.require_management lets into the other bots). The first version asked for the admin role only, which
-- refused the real owner (an agent account with the settings responsibility). Anyone who is not a manager is still refused.

CREATE OR REPLACE FUNCTION private.dev_is_manager(p_tg bigint)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.telegram_operators o JOIN public.users x ON x.id = o.user_id
     WHERE o.telegram_user_id = p_tg AND x.status = 'active'
       AND (x.role = 'admin'
            OR (x.role = 'agent' AND EXISTS (SELECT 1 FROM public.agent_profiles ap WHERE ap.user_id = x.id
                                              AND 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}'::text[]))))))
$$;
REVOKE ALL ON FUNCTION private.dev_is_manager(bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.dev_auth(p_tg bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  u public.dev_bot_users;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO u FROM public.dev_bot_users WHERE telegram_id = p_tg AND revoked_at IS NULL;
  IF u.telegram_id IS NULL THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'not_listed',
      'ownerExists', EXISTS (SELECT 1 FROM public.dev_bot_users WHERE role = 'owner' AND revoked_at IS NULL));
  END IF;
  IF NOT private.dev_is_manager(p_tg) THEN
    RETURN jsonb_build_object('authorized', false, 'reason', 'not_admin');
  END IF;
  RETURN jsonb_build_object('authorized', true, 'role', u.role, 'name', u.name);
END $$;

CREATE OR REPLACE FUNCTION public.dev_claim_owner(p_tg bigint, p_name text)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF EXISTS (SELECT 1 FROM public.dev_bot_users WHERE role = 'owner' AND revoked_at IS NULL) THEN
    RETURN false;
  END IF;
  IF NOT private.dev_is_manager(p_tg) THEN
    INSERT INTO public.dev_audit (actor, action, target, ok) VALUES (p_tg, 'owner_claim_refused', p_tg::text, false);
    RETURN false;
  END IF;
  INSERT INTO public.dev_bot_users (telegram_id, name, role, added_by) VALUES (p_tg, left(p_name, 100), 'owner', p_tg)
  ON CONFLICT (telegram_id) DO UPDATE SET role = 'owner', revoked_at = NULL, name = EXCLUDED.name;
  INSERT INTO public.dev_audit (actor, action, target) VALUES (p_tg, 'owner_claimed', p_tg::text);
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.dev_user_set(p_actor bigint, p_tg bigint, p_name text, p_grant boolean)
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF NOT EXISTS (SELECT 1 FROM public.dev_bot_users WHERE telegram_id = p_actor AND role = 'owner' AND revoked_at IS NULL) THEN
    INSERT INTO public.dev_audit (actor, action, target, ok) VALUES (p_actor, CASE WHEN p_grant THEN 'authorize' ELSE 'revoke' END, p_tg::text, false);
    RETURN 'not_owner';
  END IF;
  IF p_tg = p_actor THEN RETURN 'self'; END IF;
  IF p_grant THEN
    IF NOT private.dev_is_manager(p_tg) THEN
      RETURN 'not_admin';
    END IF;
    INSERT INTO public.dev_bot_users (telegram_id, name, role, added_by) VALUES (p_tg, left(p_name, 100), 'developer', p_actor)
    ON CONFLICT (telegram_id) DO UPDATE SET revoked_at = NULL, role = CASE WHEN dev_bot_users.role = 'owner' THEN 'owner' ELSE 'developer' END;
  ELSE
    UPDATE public.dev_bot_users SET revoked_at = now() WHERE telegram_id = p_tg AND role = 'developer';
  END IF;
  INSERT INTO public.dev_audit (actor, action, target) VALUES (p_actor, CASE WHEN p_grant THEN 'authorize' ELSE 'revoke' END, p_tg::text);
  RETURN 'ok';
END $$;
