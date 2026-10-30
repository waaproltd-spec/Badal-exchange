-- Phase 1 of the Admin Dashboard work, on what already exists (agents are
-- the managing accounts: an agent with 'manage_settings', or an admin, is a
-- full administrator -- private.can_manage):
--
--   * Edit an agent's name and phone, reset their password (signs them out),
--     delete an account (kept for the audit trail and its orders, but hidden
--     and unable to log in).
--   * Never leave the system without an active full administrator: the last
--     one cannot be disabled, deleted or lose 'manage_settings'.
--   * Login history and security changes (from audit_logs), and each agent's
--     performance over a period.
--   * Bonus: daily and monthly limits per customer; what is over a limit is
--     not credited, and the entry says so.
-- Passwords are only ever stored hashed (private.hash_password) and never
-- written to the audit log.

ALTER TABLE public.agent_profiles ADD COLUMN IF NOT EXISTS deleted_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION private.is_full_admin(p_user_id uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((
    SELECT u.status = 'active' AND ap.deleted_at IS NULL
       AND (u.role = 'admin' OR (u.role = 'agent' AND 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}'))))
    FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.id = p_user_id), false)
$$;

-- Raises LAST_ADMIN when p_user_id is the only active full administrator.
CREATE OR REPLACE FUNCTION private.ensure_other_full_admin(p_user_id uuid)
RETURNS void LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF private.is_full_admin(p_user_id) AND NOT EXISTS (
    SELECT 1 FROM public.users u WHERE u.id <> p_user_id AND u.role IN ('agent', 'admin') AND private.is_full_admin(u.id)) THEN
    PERFORM private.raise_api(409, 'LAST_ADMIN', 'This is the last full administrator: give another account Manage settings first');
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.agent_json(p_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', u.id, 'name', u.name, 'phone', u.phone, 'status', u.status, 'created_at', u.created_at,
    'responsibilities', ap.responsibilities, 'last_seen_at', ap.last_seen_at, 'last_device_id', ap.last_device_id,
    'last_login_at', (SELECT max(l.created_at) FROM public.audit_logs l
                      WHERE l.entity_type = 'user' AND l.entity_id = u.id::text AND l.action = 'user.login'),
    'full_admin', private.is_full_admin(u.id))
  FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
  WHERE u.id = p_id
$$;

CREATE OR REPLACE FUNCTION public.admin_agents()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.agent_json(u.id) ORDER BY u.created_at DESC)
    FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.role = 'agent' AND ap.deleted_at IS NULL
  ), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_agent_status(p_id uuid, p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status public.user_status := CASE WHEN p_enabled THEN 'active' ELSE 'disabled' END;
  before jsonb;
  after jsonb;
BEGIN
  IF NOT p_enabled AND p_id = v_id THEN
    PERFORM private.raise_api(400, 'SELF_LOCKOUT', 'You cannot disable your own account');
  END IF;
  SELECT jsonb_build_object('id', u.id, 'status', u.status) INTO before
  FROM public.users u JOIN public.agent_profiles ap ON ap.user_id = u.id
  WHERE u.id = p_id AND u.role = 'agent' AND ap.deleted_at IS NULL;
  IF before IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  IF NOT p_enabled THEN
    PERFORM private.ensure_other_full_admin(p_id);
  END IF;
  UPDATE public.users SET status = v_status, updated_at = now() WHERE id = p_id
  RETURNING jsonb_build_object('id', id, 'status', status) INTO after;
  IF NOT p_enabled THEN
    DELETE FROM auth.sessions WHERE user_id = p_id;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_enabled THEN 'agent.enable' ELSE 'agent.disable' END,
    'user', p_id::text, before, after);
  RETURN after;
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_agent_responsibilities(p_id uuid, p_responsibilities text[])
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_resp text[] := private.clean_responsibilities(p_responsibilities);
  before jsonb;
  after jsonb;
BEGIN
  IF p_id = v_id AND NOT ('manage_settings' = ANY (v_resp)) THEN
    PERFORM private.raise_api(400, 'SELF_LOCKOUT', 'You cannot remove manage_settings from your own account');
  END IF;
  SELECT jsonb_build_object('user_id', user_id, 'responsibilities', responsibilities) INTO before
  FROM public.agent_profiles WHERE user_id = p_id AND deleted_at IS NULL;
  IF before IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  IF NOT ('manage_settings' = ANY (v_resp)) THEN
    PERFORM private.ensure_other_full_admin(p_id);
  END IF;
  UPDATE public.agent_profiles SET responsibilities = v_resp WHERE user_id = p_id
  RETURNING jsonb_build_object('user_id', user_id, 'responsibilities', responsibilities) INTO after;
  PERFORM private.audit(v_id, private.app_role(), 'agent.update_responsibilities', 'user', p_id::text, before, after);
  RETURN after;
END $$;

-- Name and phone (the phone is the login; it stays unique).
CREATE OR REPLACE FUNCTION public.admin_update_agent(p_id uuid, p_name text, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_phone text := btrim(COALESCE(p_phone, ''));
  before jsonb;
BEGIN
  PERFORM private.check_len(p_name, 'name', 1, 100);
  PERFORM private.check_len(v_phone, 'phone', 6, 20);
  SELECT jsonb_build_object('name', u.name, 'phone', u.phone) INTO before
  FROM public.users u JOIN public.agent_profiles ap ON ap.user_id = u.id
  WHERE u.id = p_id AND u.role = 'agent' AND ap.deleted_at IS NULL;
  IF before IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  IF v_phone IS DISTINCT FROM before ->> 'phone' AND (
       EXISTS (SELECT 1 FROM public.users WHERE phone = v_phone AND id <> p_id)
       OR EXISTS (SELECT 1 FROM auth.users WHERE email = private.auth_email(v_phone, NULL) AND id <> p_id)) THEN
    PERFORM private.raise_api(409, 'PHONE_TAKEN', 'Phone number already registered');
  END IF;
  UPDATE public.users SET name = btrim(p_name), phone = v_phone, updated_at = now() WHERE id = p_id;
  PERFORM private.audit(v_id, private.app_role(), 'agent.update', 'user', p_id::text, before,
    jsonb_build_object('name', btrim(p_name), 'phone', v_phone));
  RETURN private.agent_json(p_id);
END $$;

-- A new password for an agent; they are signed out everywhere.
CREATE OR REPLACE FUNCTION public.admin_reset_agent_password(p_id uuid, p_new_password text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  PERFORM private.check_len(p_new_password, 'newPassword', 8, 72);
  IF p_id = v_id THEN
    PERFORM private.raise_api(400, 'USE_CHANGE_PASSWORD', 'Change your own password under Account > Change Password');
  END IF;
  UPDATE public.users u SET password_hash = private.hash_password(p_new_password), updated_at = now()
  FROM public.agent_profiles ap
  WHERE u.id = p_id AND u.role = 'agent' AND ap.user_id = u.id AND ap.deleted_at IS NULL;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  UPDATE public.refresh_tokens SET revoked_at = now() WHERE user_id = p_id AND revoked_at IS NULL;
  DELETE FROM auth.sessions WHERE user_id = p_id;
  PERFORM private.audit(v_id, private.app_role(), 'agent.reset_password', 'user', p_id::text);
END $$;

-- Deleted: hidden, cannot log in, kept with its orders and audit trail.
CREATE OR REPLACE FUNCTION public.admin_delete_agent(p_id uuid, p_reason text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  IF p_id = v_id THEN
    PERFORM private.raise_api(400, 'SELF_LOCKOUT', 'You cannot delete your own account');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users u JOIN public.agent_profiles ap ON ap.user_id = u.id
                 WHERE u.id = p_id AND u.role = 'agent' AND ap.deleted_at IS NULL) THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Agent not found');
  END IF;
  PERFORM private.ensure_other_full_admin(p_id);
  UPDATE public.users SET status = 'disabled', updated_at = now() WHERE id = p_id;
  UPDATE public.agent_profiles SET deleted_at = now() WHERE user_id = p_id;
  UPDATE public.refresh_tokens SET revoked_at = now() WHERE user_id = p_id AND revoked_at IS NULL;
  DELETE FROM auth.sessions WHERE user_id = p_id;
  PERFORM private.audit(v_id, private.app_role(), 'agent.delete', 'user', p_id::text, NULL,
    jsonb_build_object('reason', btrim(p_reason)));
END $$;

-- Logins and security changes of agents and admins, newest first.
CREATE OR REPLACE FUNCTION public.admin_login_history(p_user_id uuid DEFAULT NULL, p_limit int DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
        'action', l.action, 'createdAt', l.created_at,
        'actorId', l.actor_id, 'actorName', a.name,
        'userId', l.entity_id, 'userName', t.name))
    FROM (SELECT * FROM public.audit_logs l
          WHERE l.action IN ('user.login', 'user.change_password', 'agent.reset_password', 'agent.create', 'agent.update',
                             'agent.enable', 'agent.disable', 'agent.delete', 'agent.update_responsibilities')
            AND (p_user_id IS NULL OR l.entity_id = p_user_id::text)
            AND (l.action <> 'user.login' OR l.actor_role IN ('agent', 'admin'))
          ORDER BY l.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)) l
    LEFT JOIN public.users a ON a.id = l.actor_id
    LEFT JOIN public.users t ON t.id::text = l.entity_id
  ), '[]'::jsonb);
END $$;

-- Each agent's work over a period (Mogadishu days, both ends included).
CREATE OR REPLACE FUNCTION public.admin_agent_performance(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_from timestamptz := (COALESCE(p_from, v_today)::timestamp AT TIME ZONE 'Africa/Mogadishu');
  v_to timestamptz := ((COALESCE(p_to, v_today) + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu');
BEGIN
  IF COALESCE(p_to, v_today) < COALESCE(p_from, v_today) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The end date is before the start date');
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
        'id', u.id, 'name', u.name, 'status', u.status,
        'deposits', s.dep_n, 'depositAmount', private.money(s.dep_c),
        'withdrawals', s.wd_n, 'withdrawalAmount', private.money(s.wd_c),
        'failed', s.failed_n, 'adjustments', s.adj_n)
      ORDER BY s.dep_n + s.wd_n DESC, u.name)
    FROM public.users u JOIN public.agent_profiles ap ON ap.user_id = u.id
    CROSS JOIN LATERAL (
      SELECT
        count(*) FILTER (WHERE o.direction = 'deposit' AND o.status = 'completed') AS dep_n,
        COALESCE(sum(o.amount_cents) FILTER (WHERE o.direction = 'deposit' AND o.status = 'completed'), 0) AS dep_c,
        count(*) FILTER (WHERE o.direction = 'withdraw' AND o.status = 'completed') AS wd_n,
        COALESCE(sum(o.amount_cents) FILTER (WHERE o.direction = 'withdraw' AND o.status = 'completed'), 0) AS wd_c,
        count(*) FILTER (WHERE o.status = 'failed') AS failed_n,
        (SELECT count(*) FROM public.wallet_adjustments w WHERE w.agent_id = u.id
           AND w.created_at >= v_from AND w.created_at < v_to) AS adj_n
      FROM public.orders o
      WHERE o.agent_id = u.id AND o.updated_at >= v_from AND o.updated_at < v_to) s
    WHERE u.role = 'agent' AND ap.deleted_at IS NULL
  ), '[]'::jsonb);
END $$;

-- Bonus limits per customer, in micro-dollars; no value, no limit.
ALTER TABLE public.bonus_entries ADD COLUMN IF NOT EXISTS note TEXT;

CREATE OR REPLACE FUNCTION private.bonus_limit_micros(p_key text)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NULLIF((SELECT value FROM public.app_settings WHERE key = p_key), '')::bigint
$$;

CREATE OR REPLACE FUNCTION private.credit_order_bonus(o public.orders)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_bp int;
  v_micros bigint;
  v_full bigint;
  v_entry uuid;
  v_note text;
  v_day timestamptz := (date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu');
  v_month timestamptz := (date_trunc('month', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu');
  v_daily bigint := private.bonus_limit_micros('bonus:daily_limit_micros');
  v_monthly bigint := private.bonus_limit_micros('bonus:monthly_limit_micros');
  v_used bigint;
  b public.bonus_wallets;
BEGIN
  IF o.status <> 'completed' OR o.amount_cents IS NULL OR o.amount_cents <= 0
     OR NOT private.bonus_is_eligible(o.direction::text, o.method::text) THEN
    RETURN;
  END IF;
  v_bp := private.bonus_rate_bp(o.customer_id);
  v_full := o.amount_cents * v_bp;
  v_micros := v_full;
  IF v_micros <= 0 THEN
    RETURN;
  END IF;
  INSERT INTO public.bonus_wallets (customer_id) VALUES (o.customer_id) ON CONFLICT (customer_id) DO NOTHING;
  SELECT * INTO b FROM public.bonus_wallets WHERE customer_id = o.customer_id FOR UPDATE;
  -- The limits (read under the wallet's lock, so two at once cannot both pass).
  IF v_daily IS NOT NULL THEN
    SELECT COALESCE(sum(amount_micros), 0) INTO v_used FROM public.bonus_entries
    WHERE customer_id = o.customer_id AND kind = 'earned' AND created_at >= v_day;
    IF v_micros > v_daily - v_used THEN
      v_micros := GREATEST(v_daily - v_used, 0);
      v_note := 'Daily bonus limit reached';
    END IF;
  END IF;
  IF v_monthly IS NOT NULL THEN
    SELECT COALESCE(sum(amount_micros), 0) INTO v_used FROM public.bonus_entries
    WHERE customer_id = o.customer_id AND kind = 'earned' AND created_at >= v_month;
    IF v_micros > v_monthly - v_used THEN
      v_micros := GREATEST(v_monthly - v_used, 0);
      v_note := 'Monthly bonus limit reached';
    END IF;
  END IF;
  IF v_micros <= 0 THEN
    PERFORM private.order_audit(o.id, 'bonus_not_credited', NULL, jsonb_build_object('reason', v_note), NULL);
    RETURN;
  END IF;
  INSERT INTO public.bonus_entries (customer_id, wallet_id, kind, order_id, amount_micros, rate_bp, bonus_after_micros, note)
  SELECT o.customer_id, w.id, 'earned', o.id, v_micros, v_bp, b.balance_micros + v_micros,
         CASE WHEN v_micros < v_full THEN v_note END
  FROM public.wallets w WHERE w.customer_id = o.customer_id
  ON CONFLICT (order_id) WHERE kind = 'earned' DO NOTHING
  RETURNING id INTO v_entry;
  IF v_entry IS NOT NULL THEN
    UPDATE public.bonus_wallets
    SET balance_micros = balance_micros + v_micros, total_earned_micros = total_earned_micros + v_micros, updated_at = now()
    WHERE customer_id = o.customer_id;
  END IF;
END $$;

-- Dollars as typed ("5", "0.50"); empty clears the limit.
CREATE OR REPLACE FUNCTION public.manage_set_bonus_limits(p_daily text, p_monthly text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_daily bigint;
  v_monthly bigint;
  before jsonb := jsonb_build_object('daily', private.bonus_limit_micros('bonus:daily_limit_micros'),
                                     'monthly', private.bonus_limit_micros('bonus:monthly_limit_micros'));
BEGIN
  IF NULLIF(btrim(COALESCE(p_daily, '')), '') IS NOT NULL THEN
    v_daily := private.to_cents(p_daily) * 10000;
    IF v_daily <= 0 THEN PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The daily limit must be more than $0'); END IF;
  END IF;
  IF NULLIF(btrim(COALESCE(p_monthly, '')), '') IS NOT NULL THEN
    v_monthly := private.to_cents(p_monthly) * 10000;
    IF v_monthly <= 0 THEN PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The monthly limit must be more than $0'); END IF;
  END IF;
  IF v_daily IS NOT NULL AND v_monthly IS NOT NULL AND v_daily > v_monthly THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The daily limit cannot be more than the monthly limit');
  END IF;
  INSERT INTO public.app_settings (key, value) VALUES
    ('bonus:daily_limit_micros', COALESCE(v_daily::text, '')),
    ('bonus:monthly_limit_micros', COALESCE(v_monthly::text, ''))
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM private.audit(v_id, private.app_role(), 'bonus.limits', 'app_settings', 'bonus', before,
    jsonb_build_object('daily', v_daily, 'monthly', v_monthly));
  RETURN public.manage_bonus_settings();
END $$;

-- The Bonus screen, with the limits and what was moved to main wallets.
CREATE OR REPLACE FUNCTION public.manage_bonus_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'enabled', private.bonus_programme_on(),
    'defaultRateBp', private.bonus_default_bp(),
    'types', private.bonus_types_json(false),
    'dailyLimit', CASE WHEN private.bonus_limit_micros('bonus:daily_limit_micros') IS NOT NULL
                       THEN private.money_micros(private.bonus_limit_micros('bonus:daily_limit_micros')) END,
    'monthlyLimit', CASE WHEN private.bonus_limit_micros('bonus:monthly_limit_micros') IS NOT NULL
                         THEN private.money_micros(private.bonus_limit_micros('bonus:monthly_limit_micros')) END,
    'totalBalance', private.money_micros(COALESCE((SELECT sum(balance_micros) FROM public.bonus_wallets), 0)::bigint),
    'totalEarned', private.money_micros(COALESCE((SELECT sum(total_earned_micros) FROM public.bonus_wallets), 0)::bigint),
    'totalMoved', private.money_micros(COALESCE((SELECT sum(amount_micros) FROM public.bonus_entries WHERE kind = 'moved'), 0)::bigint),
    'customers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
          'id', u.id, 'name', u.name, 'phone', u.phone,
          'balance', private.money_micros(b.balance_micros), 'totalEarned', private.money_micros(b.total_earned_micros),
          'rate', private.bonus_rate_text(private.bonus_rate_bp(u.id)))
        ORDER BY b.balance_micros DESC, b.total_earned_micros DESC)
      FROM (SELECT * FROM public.bonus_wallets ORDER BY balance_micros DESC, total_earned_micros DESC LIMIT 100) b
      JOIN public.users u ON u.id = b.customer_id), '[]'::jsonb),
    'history', COALESCE((
      SELECT jsonb_agg(private.bonus_entry_json(e) || jsonb_build_object('customerName', u.name, 'customerPhone', u.phone, 'note', e.note)
        ORDER BY e.created_at DESC)
      FROM (SELECT * FROM public.bonus_entries ORDER BY created_at DESC LIMIT 100) e
      JOIN public.users u ON u.id = e.customer_id), '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION private.is_full_admin(uuid), private.ensure_other_full_admin(uuid), private.agent_json(uuid),
  private.bonus_limit_micros(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.admin_update_agent(uuid, text, text), public.admin_reset_agent_password(uuid, text),
  public.admin_delete_agent(uuid, text), public.admin_login_history(uuid, int), public.admin_agent_performance(date, date),
  public.manage_set_bonus_limits(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_agent(uuid, text, text), public.admin_reset_agent_password(uuid, text),
  public.admin_delete_agent(uuid, text), public.admin_login_history(uuid, int), public.admin_agent_performance(date, date),
  public.manage_set_bonus_limits(text, text) TO authenticated, service_role;
