-- Withdrawal approval through the support bot: the Customer App opens
-- https://t.me/Badalaisupportbot?start=fasax_<Customer ID>; the bot looks the
-- customer up here and tells the administrator in Telegram.
--
--   * Only the service role (the bot) can call these functions.
--   * The administrator's chat is the one that /start-ed the bot from the
--     Telegram account @Badalexchangeadmin (the bot knows its chat only then).
--   * A request is five an hour a chat; unknown IDs count too. Nothing the
--     customer wrote is stored, and the request changes nothing: the administrator
--     approves in the Agent App as always.

ALTER TABLE public.support_events DROP CONSTRAINT IF EXISTS support_events_kind_check;
ALTER TABLE public.support_events
  ADD CONSTRAINT support_events_kind_check CHECK (kind IN ('wrong_wallet', 'ai', 'ticket', 'approval'));

CREATE TABLE IF NOT EXISTS public.support_admin (
  id        BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  chat_id   BIGINT NOT NULL,
  linked_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.support_admin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_admin FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.support_admin_link(p_chat bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.support_admin (id, chat_id) VALUES (true, p_chat)
  ON CONFLICT (id) DO UPDATE SET chat_id = EXCLUDED.chat_id, linked_at = now();
  RETURN true;
END $$;

CREATE OR REPLACE FUNCTION public.support_admin_chat()
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN (SELECT chat_id FROM public.support_admin WHERE id);
END $$;

-- The customer behind a Customer ID (BX + 8 characters), and whether the account may withdraw.
CREATE OR REPLACE FUNCTION public.support_approval_request(p_chat bigint, p_account text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_code text := upper(btrim(COALESCE(p_account, '')));
  u public.users;
  a public.withdrawal_approvals;
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
  RETURN jsonb_build_object(
    'ok', true, 'name', u.name, 'phone', u.phone, 'accountId', v_code,
    'status', COALESCE(a.status, 'pending'),
    'allowed', private.withdrawals_allowed(u.id));
END $$;

REVOKE ALL ON FUNCTION public.support_admin_link(bigint), public.support_admin_chat(),
  public.support_approval_request(bigint, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.support_admin_link(bigint), public.support_admin_chat(),
  public.support_approval_request(bigint, text) TO service_role;
