-- BADAL AI Support Bot (Telegram, functions/support-bot): text and images /
-- screenshots only, answers in Somali only, no voice or audio.
--
-- The bot runs as the service role. Everything it reads or writes goes through
-- the functions below, which refuse any other caller:
--   * a Telegram chat is linked to a customer in two steps -- the Wallet ID,
--     then the customer's own Telegram contact, whose phone number must be the
--     registered one (a Wallet ID alone is never enough to see an account);
--   * wrong Wallet IDs are limited (5 an hour a chat);
--   * the bot only reads the customer's orders (a deposit that is not completed
--     is not shown, as in the app) and makes tickets for the admin: it cannot
--     create an order, move money or change an account;
--   * the AI answers are limited (20 an hour a chat), tickets too (5 an hour).

CREATE TABLE IF NOT EXISTS public.support_chats (
  chat_id      BIGINT PRIMARY KEY,
  customer_id  UUID REFERENCES public.users(id) ON DELETE CASCADE,
  pending_customer_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  state        TEXT NOT NULL DEFAULT 'start' CHECK (state IN ('start', 'awaiting_wallet', 'awaiting_contact', 'awaiting_ticket', 'ready')),
  linked_at    TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.support_chats ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_chats FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.support_events (
  id         BIGSERIAL PRIMARY KEY,
  chat_id    BIGINT NOT NULL,
  kind       TEXT NOT NULL CHECK (kind IN ('wrong_wallet', 'ai', 'ticket')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS support_events_chat_idx ON public.support_events (chat_id, kind, created_at DESC);
ALTER TABLE public.support_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_events FROM PUBLIC, anon, authenticated;

CREATE SEQUENCE IF NOT EXISTS public.support_ticket_seq START 1025;

CREATE TABLE IF NOT EXISTS public.support_tickets (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  code        TEXT NOT NULL UNIQUE,
  customer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  chat_id     BIGINT NOT NULL,
  message     TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  closed_at   TIMESTAMPTZ,
  closed_by   UUID REFERENCES public.users(id) ON DELETE SET NULL
);
ALTER TABLE public.support_tickets ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.support_tickets FROM PUBLIC, anon, authenticated;

-- ------------------------------------------------------------------- the bot

-- Where this chat is: linked or not, and the customer's name and Wallet ID.
CREATE OR REPLACE FUNCTION public.support_session(p_chat bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.support_chats;
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.support_chats (chat_id) VALUES (p_chat) ON CONFLICT (chat_id) DO NOTHING;
  SELECT * INTO c FROM public.support_chats WHERE chat_id = p_chat;
  RETURN jsonb_build_object(
    'linked', c.customer_id IS NOT NULL, 'state', c.state,
    'name', (SELECT u.name FROM public.users u WHERE u.id = c.customer_id),
    'walletId', (SELECT w.wallet_code FROM public.wallets w WHERE w.customer_id = c.customer_id));
END $$;

CREATE OR REPLACE FUNCTION public.support_set_state(p_chat bigint, p_state text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.support_chats (chat_id, state) VALUES (p_chat, p_state)
  ON CONFLICT (chat_id) DO UPDATE SET state = EXCLUDED.state, updated_at = now();
END $$;

-- Step 1: the Wallet ID. Found: the chat now waits for the customer's contact.
-- Not found (or too many wrong ones): nothing says which.
CREATE OR REPLACE FUNCTION public.support_start_link(p_chat bigint, p_wallet text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_code text := upper(btrim(COALESCE(p_wallet, '')));
  v_customer uuid;
BEGIN
  PERFORM private.require_service();
  IF (SELECT count(*) FROM public.support_events
      WHERE chat_id = p_chat AND kind = 'wrong_wallet' AND created_at > now() - interval '1 hour') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'limited', true);
  END IF;
  SELECT w.customer_id INTO v_customer FROM public.wallets w
  JOIN public.users u ON u.id = w.customer_id AND u.role = 'customer' AND u.status = 'active'
  WHERE w.wallet_code = v_code;
  IF v_customer IS NULL THEN
    INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'wrong_wallet');
    RETURN jsonb_build_object('ok', false, 'limited', false);
  END IF;
  INSERT INTO public.support_chats (chat_id, pending_customer_id, state) VALUES (p_chat, v_customer, 'awaiting_contact')
  ON CONFLICT (chat_id) DO UPDATE SET pending_customer_id = v_customer, state = 'awaiting_contact', updated_at = now();
  RETURN jsonb_build_object('ok', true);
END $$;

-- Step 2: the customer's own Telegram contact (the function has checked it is
-- the sender's own); its number must be the registered one.
CREATE OR REPLACE FUNCTION public.support_verify_contact(p_chat bigint, p_phone text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  c public.support_chats;
  u public.users;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO c FROM public.support_chats WHERE chat_id = p_chat FOR UPDATE;
  IF c.pending_customer_id IS NULL OR c.state <> 'awaiting_contact' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  SELECT * INTO u FROM public.users WHERE id = c.pending_customer_id;
  IF private.phone_key(p_phone) IS NULL OR private.phone_key(p_phone) IS DISTINCT FROM private.phone_key(u.phone) THEN
    INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'wrong_wallet');
    RETURN jsonb_build_object('ok', false);
  END IF;
  UPDATE public.support_chats SET customer_id = u.id, pending_customer_id = NULL, state = 'ready',
    linked_at = now(), updated_at = now() WHERE chat_id = p_chat;
  RETURN jsonb_build_object('ok', true, 'name', u.name);
END $$;

CREATE OR REPLACE FUNCTION public.support_unlink(p_chat bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.support_chats SET customer_id = NULL, pending_customer_id = NULL, state = 'start',
    linked_at = NULL, updated_at = now() WHERE chat_id = p_chat;
END $$;

-- The customer's latest orders, as the app lists them (a deposit that is not
-- completed is not shown). p_kind: all | deposit | withdraw.
CREATE OR REPLACE FUNCTION public.support_orders(p_chat bigint, p_kind text DEFAULT 'all', p_limit int DEFAULT 5)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid;
  v_kind text := COALESCE(NULLIF(btrim(p_kind), ''), 'all');
BEGIN
  PERFORM private.require_service();
  SELECT customer_id INTO v_customer FROM public.support_chats WHERE chat_id = p_chat;
  IF v_customer IS NULL OR v_kind NOT IN ('all', 'deposit', 'withdraw') THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'code', o.order_code, 'direction', o.direction, 'method', private.method_label(o.method),
      'amount', private.money(o.amount_cents), 'status', o.status,
      'reason', CASE WHEN o.status IN ('failed', 'cancelled', 'expired') THEN o.failure_reason END,
      'createdAt', o.created_at) ORDER BY o.created_at DESC)
    FROM (SELECT * FROM public.orders
          WHERE customer_id = v_customer AND (direction <> 'deposit' OR status = 'completed')
            AND (v_kind = 'all' OR direction::text = v_kind)
          ORDER BY created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 5), 1), 10)) o), '[]'::jsonb);
END $$;

-- One AI answer allowed? 20 an hour a chat (recorded when allowed).
CREATE OR REPLACE FUNCTION public.support_ai_allowed(p_chat bigint)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF (SELECT count(*) FROM public.support_events
      WHERE chat_id = p_chat AND kind = 'ai' AND created_at > now() - interval '1 hour') >= 20 THEN
    RETURN false;
  END IF;
  INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'ai');
  RETURN true;
END $$;

-- A ticket for the admin. 5 an hour a chat. The code is what the customer quotes.
CREATE OR REPLACE FUNCTION public.support_create_ticket(p_chat bigint, p_message text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid;
  v_text text := left(btrim(COALESCE(p_message, '')), 2000);
  v_code text;
BEGIN
  PERFORM private.require_service();
  SELECT customer_id INTO v_customer FROM public.support_chats WHERE chat_id = p_chat;
  IF v_customer IS NULL OR v_text = '' THEN
    RETURN jsonb_build_object('ok', false);
  END IF;
  IF (SELECT count(*) FROM public.support_events
      WHERE chat_id = p_chat AND kind = 'ticket' AND created_at > now() - interval '1 hour') >= 5 THEN
    RETURN jsonb_build_object('ok', false, 'limited', true);
  END IF;
  v_code := '#BADAL' || nextval('public.support_ticket_seq');
  INSERT INTO public.support_tickets (code, customer_id, chat_id, message) VALUES (v_code, v_customer, p_chat, v_text);
  INSERT INTO public.support_events (chat_id, kind) VALUES (p_chat, 'ticket');
  UPDATE public.support_chats SET state = 'ready', updated_at = now() WHERE chat_id = p_chat;
  RETURN jsonb_build_object('ok', true, 'code', v_code);
END $$;

-- ---------------------------------------------------------------- management

-- Tickets for the admin (name, phone, Wallet ID, what the customer wrote).
CREATE OR REPLACE FUNCTION public.manage_support_tickets(p_status text DEFAULT 'open')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status text := COALESCE(NULLIF(btrim(p_status), ''), 'open');
BEGIN
  IF v_status NOT IN ('open', 'closed', 'all') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid status');
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', t.id, 'code', t.code, 'status', t.status, 'message', t.message, 'createdAt', t.created_at, 'closedAt', t.closed_at,
      'customerId', t.customer_id, 'name', u.name, 'phone', u.phone,
      'walletId', (SELECT w.wallet_code FROM public.wallets w WHERE w.customer_id = u.id)) ORDER BY t.created_at DESC)
    FROM (SELECT * FROM public.support_tickets WHERE v_status = 'all' OR status = v_status ORDER BY created_at DESC LIMIT 100) t
    JOIN public.users u ON u.id = t.customer_id), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.manage_close_support_ticket(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  t public.support_tickets;
BEGIN
  UPDATE public.support_tickets SET status = 'closed', closed_at = now(), closed_by = v_id
  WHERE id = p_id AND status = 'open' RETURNING * INTO t;
  IF t.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Open ticket not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'support_ticket.close', 'support_ticket', t.id::text, NULL, jsonb_build_object('code', t.code));
  RETURN jsonb_build_object('id', t.id, 'status', t.status);
END $$;

REVOKE ALL ON FUNCTION public.support_session(bigint), public.support_set_state(bigint, text), public.support_start_link(bigint, text),
  public.support_verify_contact(bigint, text), public.support_unlink(bigint), public.support_orders(bigint, text, int),
  public.support_ai_allowed(bigint), public.support_create_ticket(bigint, text), public.manage_support_tickets(text),
  public.manage_close_support_ticket(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.support_session(bigint), public.support_set_state(bigint, text), public.support_start_link(bigint, text),
  public.support_verify_contact(bigint, text), public.support_unlink(bigint), public.support_orders(bigint, text, int),
  public.support_ai_allowed(bigint), public.support_create_ticket(bigint, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.manage_support_tickets(text), public.manage_close_support_ticket(uuid) TO authenticated;
