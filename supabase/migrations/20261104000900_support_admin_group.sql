-- The approval requests can go to a Telegram group of administrators
-- ("BADAL EXCHANGE ADMIN") instead of one private chat.
--
-- The decision is refused unless it is pressed in the linked chat (the group or
-- the private chat) by either the owner of that private chat or, in a group,
-- a member Telegram itself reports as the group's creator or administrator (the
-- bot asks Telegram when the button is pressed and passes the answer). Anyone
-- else, in any other chat, changes nothing.

DROP FUNCTION IF EXISTS public.support_approval_decide(uuid, bigint, text, text);

CREATE OR REPLACE FUNCTION public.support_approval_decide(
  p_request uuid, p_admin_tg bigint, p_admin_name text, p_decision text, p_chat bigint, p_verified boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_status text := CASE p_decision WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' END;
  v_admin bigint;
  r public.support_approval_requests;
  a public.withdrawal_approvals;
  u public.users;
BEGIN
  PERFORM private.require_service();
  IF v_status IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'bad_decision');
  END IF;
  SELECT chat_id INTO v_admin FROM public.support_admin WHERE id;
  IF v_admin IS NULL OR p_chat IS DISTINCT FROM v_admin
     OR NOT (p_admin_tg IS NOT DISTINCT FROM v_admin OR COALESCE(p_verified, false)) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
  END IF;
  SELECT * INTO r FROM public.support_approval_requests WHERE id = p_request FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false, 'error', 'not_found');
  END IF;
  IF r.status <> 'pending' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'already', 'status', r.status, 'decidedAt', r.decided_at, 'decidedBy', r.decided_by_name);
  END IF;
  SELECT * INTO u FROM public.users WHERE id = r.customer_id;
  SELECT * INTO a FROM public.withdrawal_approvals WHERE customer_id = r.customer_id FOR UPDATE;
  IF a.status = 'restricted' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'restricted');
  END IF;
  INSERT INTO public.withdrawal_approvals (customer_id, status, decided_at, reason, updated_at)
  VALUES (r.customer_id, v_status, now(),
          CASE WHEN v_status = 'rejected' THEN 'Maamuluhu wuu diiday codsiga (Telegram)' END, now())
  ON CONFLICT (customer_id) DO UPDATE SET status = EXCLUDED.status, decided_at = now(), decided_by = NULL,
    reason = EXCLUDED.reason, updated_at = now();
  UPDATE public.support_approval_requests
     SET status = v_status, decided_at = now(), decided_by_tg = p_admin_tg, decided_by_name = left(COALESCE(p_admin_name, ''), 100)
   WHERE id = r.id
   RETURNING * INTO r;
  RETURN jsonb_build_object(
    'ok', true, 'status', v_status, 'decidedAt', r.decided_at,
    'customerChat', r.customer_chat_id, 'adminChat', r.admin_chat_id, 'adminMessage', r.admin_message_id,
    'name', u.name, 'phone', u.phone, 'accountId', private.account_code(u.id));
END $$;

REVOKE ALL ON FUNCTION public.support_approval_decide(uuid, bigint, text, text, bigint, boolean) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.support_approval_decide(uuid, bigint, text, text, bigint, boolean) TO service_role;
