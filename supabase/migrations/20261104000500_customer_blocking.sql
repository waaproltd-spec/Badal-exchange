-- Block / Unblock customers (Agent App, Customer Info).
--
-- A blocked customer is a user whose status is 'disabled'. That is what already makes the
-- rest work, and this migration adds the missing action, the reason and the history:
--   * login: private.sync_auth_user bans the account in Supabase Auth (banned_until) and
--     deletes its sessions, so the customer is signed out everywhere and can not sign in;
--   * the API: every customer function starts with private.require_user, which refuses a
--     disabled account on every call ("Account is disabled"), so a token still held by a
--     blocked customer is useless;
--   * the Users screen counters and the Blocked tab already read users.status, so they
--     follow at once.
-- Added here: who blocked or unblocked whom, why and when (append-only history written
-- only by the functions below), and manage_set_customer_blocked for managers.

CREATE TABLE IF NOT EXISTS public.customer_block_history (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  seq         BIGINT GENERATED ALWAYS AS IDENTITY,   -- the order, even for entries made in the same instant
  customer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  action      TEXT NOT NULL CHECK (action IN ('blocked', 'unblocked')),
  reason      TEXT,
  actor_id    UUID REFERENCES public.users(id) ON DELETE SET NULL,
  actor_role  public.user_role,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp()
);
CREATE INDEX IF NOT EXISTS idx_customer_block_history ON public.customer_block_history (customer_id, created_at DESC);
ALTER TABLE public.customer_block_history ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_block_history FROM PUBLIC, anon, authenticated;

-- Blocked or Active, the reason and the history of one customer (managers).
CREATE OR REPLACE FUNCTION private.customer_block_json(p_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'customerId', u.id,
    'status', CASE WHEN u.status = 'active' THEN 'active' ELSE 'blocked' END,
    'blockedReason', CASE WHEN u.status <> 'active' THEN
        (SELECT h.reason FROM public.customer_block_history h WHERE h.customer_id = u.id AND h.action = 'blocked'
         ORDER BY h.seq DESC LIMIT 1) END,
    'blockedAt', CASE WHEN u.status <> 'active' THEN
        (SELECT h.created_at FROM public.customer_block_history h WHERE h.customer_id = u.id AND h.action = 'blocked'
         ORDER BY h.seq DESC LIMIT 1) END,
    'history', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', h.id, 'action', h.action, 'reason', h.reason, 'at', h.created_at,
               'by', a.name, 'byPhone', a.phone, 'byRole', h.actor_role) ORDER BY h.seq DESC)
      FROM public.customer_block_history h LEFT JOIN public.users a ON a.id = h.actor_id
      WHERE h.customer_id = u.id), '[]'::jsonb)
  )
  FROM public.users u WHERE u.id = p_customer_id AND u.role = 'customer'
$$;
REVOKE ALL ON FUNCTION private.customer_block_json(uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.manage_customer_block_info(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r jsonb;
BEGIN
  PERFORM private.require_management();
  r := private.customer_block_json(p_customer_id);
  IF r IS NULL THEN PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found'); END IF;
  RETURN r;
END $$;

-- Blocks (p_blocked = true, a reason is required) or unblocks (the reason is optional).
-- Only customers; once each way (blocking a blocked customer is ALREADY_BLOCKED).
CREATE OR REPLACE FUNCTION public.manage_set_customer_blocked(p_customer_id uuid, p_blocked boolean, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  u public.users;
  v_reason text := NULLIF(trim(COALESCE(p_reason, '')), '');
BEGIN
  IF p_blocked IS NULL THEN PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'blocked must be true or false'); END IF;
  IF v_reason IS NOT NULL AND char_length(v_reason) > 300 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The reason must be at most 300 characters');
  END IF;
  SELECT * INTO u FROM public.users WHERE id = p_customer_id AND role = 'customer' FOR UPDATE;
  IF NOT FOUND THEN PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found'); END IF;

  IF p_blocked THEN
    IF v_reason IS NULL OR char_length(v_reason) < 3 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Write the reason for blocking this customer');
    END IF;
    IF u.status <> 'active' THEN PERFORM private.raise_api(409, 'ALREADY_BLOCKED', 'This customer is already blocked'); END IF;
    UPDATE public.users SET status = 'disabled', updated_at = now() WHERE id = u.id;   -- bans the login, ends the sessions
  ELSE
    IF u.status = 'active' THEN PERFORM private.raise_api(409, 'NOT_BLOCKED', 'This customer is not blocked'); END IF;
    UPDATE public.users SET status = 'active', updated_at = now() WHERE id = u.id;
  END IF;

  INSERT INTO public.customer_block_history (customer_id, action, reason, actor_id, actor_role)
  VALUES (u.id, CASE WHEN p_blocked THEN 'blocked' ELSE 'unblocked' END, v_reason, v_id, private.app_role());
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_blocked THEN 'customer.block' ELSE 'customer.unblock' END,
    'user', u.id::text, jsonb_build_object('status', u.status),
    jsonb_build_object('status', CASE WHEN p_blocked THEN 'disabled' ELSE 'active' END, 'reason', v_reason));
  RETURN private.customer_block_json(u.id);
END $$;

REVOKE ALL ON FUNCTION public.manage_customer_block_info(uuid), public.manage_set_customer_blocked(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_customer_block_info(uuid), public.manage_set_customer_blocked(uuid, boolean, text) TO authenticated, service_role;
