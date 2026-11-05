-- Withdrawal approval decided in Telegram: the administrator gets the request
-- from the support bot with two buttons (Approve / Reject); the decision is
-- written to the database, the customer is told, and it can be made once.
--
--   * Only the service role (the bot) calls these functions.
--   * Only the administrator whose Telegram account linked the bot
--     (support_admin) can decide: the Telegram ID of whoever pressed the button
--     must be that account's. Anyone else is refused and nothing changes.
--   * One decision per request (the row is locked and must still be pending);
--     a second press changes nothing. The administrator's Telegram ID,
--     @username and the time are kept on the request.
--   * It changes withdrawal_approvals exactly as the Agent App does; an account
--     an administrator has restricted is not released from Telegram.

CREATE TABLE IF NOT EXISTS public.support_approval_requests (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  customer_chat_id BIGINT NOT NULL,
  admin_chat_id    BIGINT,
  admin_message_id BIGINT,
  status           TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected')),
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at       TIMESTAMPTZ,
  decided_by_tg    BIGINT,
  decided_by_name  TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS support_approval_one_pending ON public.support_approval_requests (customer_id) WHERE status = 'pending';
ALTER TABLE public.support_approval_requests ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_approval_requests FROM PUBLIC, anon, authenticated;

-- The customer behind a Customer ID; a pending request is made (once) and returned with its id.
CREATE OR REPLACE FUNCTION public.support_approval_request(p_chat bigint, p_account text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_code text := upper(btrim(COALESCE(p_account, '')));
  u public.users;
  a public.withdrawal_approvals;
  r public.support_approval_requests;
  v_new boolean := false;
BEGIN
  PERFORM private.require_service();
  IF (SELECT count(*) FROM public.support_events
      WHERE chat_id = p_chat AND kind = 'approval' AND created_at > now() - interval '1 hour') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'limited', true);
  END IF;
  INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'approval');
  IF v_code !~ '^BX[0-9A-F]{8}$' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO u FROM public.users WHERE role = 'customer' AND private.account_code(id) = v_code;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO a FROM public.withdrawal_approvals WHERE customer_id = u.id;
  IF private.withdrawals_allowed(u.id) THEN
    RETURN jsonb_build_object('ok', true, 'allowed', true, 'name', u.name, 'phone', u.phone, 'accountId', v_code,
                              'status', COALESCE(a.status, 'pending'));
  END IF;
  IF a.status = 'restricted' THEN
    RETURN jsonb_build_object('ok', true, 'allowed', false, 'restricted', true, 'name', u.name, 'phone', u.phone,
                              'accountId', v_code, 'status', a.status);
  END IF;
  SELECT * INTO r FROM public.support_approval_requests WHERE customer_id = u.id AND status = 'pending';
  IF NOT FOUND THEN
    INSERT INTO public.support_approval_requests (customer_id, customer_chat_id) VALUES (u.id, p_chat) RETURNING * INTO r;
    v_new := true;
  ELSE
    UPDATE public.support_approval_requests SET customer_chat_id = p_chat WHERE id = r.id;
  END IF;
  RETURN jsonb_build_object(
    'ok', true, 'allowed', false, 'name', u.name, 'phone', u.phone, 'accountId', v_code,
    'status', COALESCE(a.status, 'pending'),
    'requestId', r.id, 'new', v_new, 'sent', r.admin_message_id IS NOT NULL);
END $$;

-- Where the request was shown to the administrator (so the message can be updated).
CREATE OR REPLACE FUNCTION public.support_approval_sent(p_request uuid, p_admin_chat bigint, p_message_id bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.support_approval_requests SET admin_chat_id = p_admin_chat, admin_message_id = p_message_id
  WHERE id = p_request AND status = 'pending';
  RETURN FOUND;
END $$;

-- The administrator pressed Approve or Reject. p_admin_tg is the Telegram ID of whoever pressed the button.
CREATE OR REPLACE FUNCTION public.support_approval_decide(p_request uuid, p_admin_tg bigint, p_admin_name text, p_decision text)
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
  IF v_admin IS NULL OR p_admin_tg IS DISTINCT FROM v_admin THEN
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

REVOKE ALL ON FUNCTION public.support_approval_request(bigint, text), public.support_approval_sent(uuid, bigint, bigint),
  public.support_approval_decide(uuid, bigint, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.support_approval_request(bigint, text), public.support_approval_sent(uuid, bigint, bigint),
  public.support_approval_decide(uuid, bigint, text, text) TO service_role;
