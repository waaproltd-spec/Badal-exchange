-- Database side of the `telegram-bot` Edge Function (supabase/functions/
-- telegram-bot): a Telegram cashier bot for the CashdeskBot API (player
-- search, cash register balance, deposits and payouts).
--
-- Who may use the bot: the same people who may use the cashdeskbot function
-- in the Agent App (admins, and agents with 'manage_settings'). A manager
-- links their Telegram account with a one-time code from the Agent App
-- (Account -> Admin features -> Telegram Bot) and sends `/link CODE` to the
-- bot. Every bot request then runs as that manager: private.telegram_act_as
-- signs the request in as the linked user and applies require_management, so
-- disabling the account or removing 'manage_settings' locks the bot out at
-- once, and deposits and payouts go through the same idempotency, rate limit
-- and audit log as cashdeskbot_begin/finish/abort.
--
-- The bot calls the telegram_* functions with the service role key, only
-- after checking Telegram's webhook secret. Signed-in app users can't call
-- them: they take a Telegram user id, and would otherwise let anyone act as
-- whoever is linked to it.

CREATE TABLE IF NOT EXISTS public.telegram_operators (
  telegram_user_id  BIGINT PRIMARY KEY,
  user_id           UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  telegram_username TEXT,
  linked_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.telegram_link_codes (
  code       TEXT PRIMARY KEY,
  user_id    UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  expires_at TIMESTAMPTZ NOT NULL
);

-- A deposit or payout the bot has shown with Confirm / Cancel buttons. The
-- Confirm button carries only its id; the action runs exactly as stored here.
CREATE TABLE IF NOT EXISTS public.telegram_pending_actions (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  telegram_user_id BIGINT NOT NULL REFERENCES public.telegram_operators(telegram_user_id) ON DELETE CASCADE,
  action           TEXT NOT NULL CHECK (action IN ('deposit', 'payout')),
  payload          JSONB NOT NULL,
  expires_at       TIMESTAMPTZ NOT NULL DEFAULT now() + interval '10 minutes'
);

ALTER TABLE public.telegram_operators ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.telegram_link_codes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.telegram_pending_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.telegram_operators, public.telegram_link_codes, public.telegram_pending_actions FROM anon, authenticated;

-- ---------------------------------------------------------------------------
-- Agent App (signed-in managers)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.telegram_status_json(p_user uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'linked', o.telegram_user_id IS NOT NULL,
    'telegramUsername', o.telegram_username,
    'linkedAt', o.linked_at)
  FROM (SELECT 1) x LEFT JOIN public.telegram_operators o ON o.user_id = p_user
$$;

-- Whether the caller's Telegram account is linked to the bot.
CREATE OR REPLACE FUNCTION public.manage_telegram_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN private.telegram_status_json(v_id);
END $$;

-- A one-time code (valid 10 minutes) the caller sends to the bot as
-- `/link CODE`. A new code replaces the previous one.
CREATE OR REPLACE FUNCTION public.manage_telegram_link_code()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_code text := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 10));
  v_expires timestamptz := now() + interval '10 minutes';
BEGIN
  INSERT INTO public.telegram_link_codes (code, user_id, expires_at) VALUES (v_code, v_id, v_expires)
  ON CONFLICT (user_id) DO UPDATE SET code = EXCLUDED.code, expires_at = EXCLUDED.expires_at;
  RETURN jsonb_build_object('code', v_code, 'expiresAt', v_expires);
END $$;

CREATE OR REPLACE FUNCTION public.manage_telegram_unlink()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  o public.telegram_operators;
BEGIN
  DELETE FROM public.telegram_operators WHERE user_id = v_id RETURNING * INTO o;
  IF o.user_id IS NOT NULL THEN
    PERFORM private.audit(v_id, private.app_role(), 'telegram.unlink', 'telegram_operator', o.telegram_user_id::text, to_jsonb(o), NULL);
  END IF;
  RETURN private.telegram_status_json(v_id);
END $$;

-- ---------------------------------------------------------------------------
-- The bot (service role only)
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION private.require_service()
RETURNS void LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role', '') <> 'service_role' THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
END $$;

-- Runs the rest of the transaction as p_user (auth.uid() returns it).
CREATE OR REPLACE FUNCTION private.act_as(p_user uuid)
RETURNS void LANGUAGE sql SET search_path = '' AS $$
  SELECT set_config('request.jwt.claims', jsonb_build_object('sub', p_user, 'role', 'authenticated')::text, true),
         set_config('request.jwt.claim.sub', p_user::text, true);
$$;

-- Signs the request in as the manager linked to this Telegram account and
-- checks they may still manage. Returns their user id.
CREATE OR REPLACE FUNCTION private.telegram_act_as(p_telegram_user_id bigint)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_user uuid;
BEGIN
  PERFORM private.require_service();
  SELECT user_id INTO v_user FROM public.telegram_operators WHERE telegram_user_id = p_telegram_user_id;
  IF v_user IS NULL THEN
    PERFORM private.raise_api(401, 'TELEGRAM_NOT_LINKED', 'This Telegram account is not linked.');
  END IF;
  PERFORM private.act_as(v_user);
  RETURN private.require_management();
END $$;

CREATE OR REPLACE FUNCTION private.telegram_profile_json(p_user uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object('userId', u.id, 'name', u.name, 'phone', u.phone, 'role', u.role)
  FROM public.users u WHERE u.id = p_user
$$;

-- `/link CODE`: links this Telegram account to the manager who made the
-- code. One Telegram account per manager, and one manager per Telegram
-- account; linking again replaces the old link.
CREATE OR REPLACE FUNCTION public.telegram_link(p_telegram_user_id bigint, p_telegram_username text, p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_user uuid;
  v_id uuid;
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.telegram_link_codes
  WHERE code = upper(btrim(COALESCE(p_code, ''))) AND expires_at > now()
  RETURNING user_id INTO v_user;
  IF v_user IS NULL THEN
    PERFORM private.raise_api(400, 'INVALID_LINK_CODE', 'This code is wrong or has expired. Get a new one in the Agent App.');
  END IF;
  PERFORM private.act_as(v_user);
  v_id := private.require_management();
  DELETE FROM public.telegram_operators WHERE telegram_user_id = p_telegram_user_id OR user_id = v_id;
  INSERT INTO public.telegram_operators (telegram_user_id, user_id, telegram_username)
  VALUES (p_telegram_user_id, v_id, NULLIF(left(btrim(COALESCE(p_telegram_username, '')), 64), ''));
  PERFORM private.audit(v_id, private.app_role(), 'telegram.link', 'telegram_operator', p_telegram_user_id::text, NULL,
    jsonb_build_object('telegramUserId', p_telegram_user_id, 'telegramUsername', p_telegram_username));
  RETURN private.telegram_profile_json(v_id);
END $$;

-- `/unlink`. Works even when the manager has lost access, so anyone can
-- remove their own Telegram account.
CREATE OR REPLACE FUNCTION public.telegram_unlink(p_telegram_user_id bigint)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.telegram_operators;
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.telegram_operators WHERE telegram_user_id = p_telegram_user_id RETURNING * INTO o;
  IF o.user_id IS NOT NULL THEN
    PERFORM private.audit(o.user_id, (SELECT role FROM public.users WHERE id = o.user_id), 'telegram.unlink',
      'telegram_operator', o.telegram_user_id::text, to_jsonb(o), NULL);
  END IF;
END $$;

-- Who this Telegram account acts as; fails unless it may use the bot.
CREATE OR REPLACE FUNCTION public.telegram_whoami(p_telegram_user_id bigint)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  RETURN private.telegram_profile_json(private.telegram_act_as(p_telegram_user_id));
END $$;

-- Stores a deposit or payout to show with Confirm / Cancel. Returns its id.
CREATE OR REPLACE FUNCTION public.telegram_prepare(p_telegram_user_id bigint, p_action text, p_payload jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_pending uuid;
BEGIN
  PERFORM private.telegram_act_as(p_telegram_user_id);
  IF p_action NOT IN ('deposit', 'payout') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown action');
  END IF;
  DELETE FROM public.telegram_pending_actions WHERE expires_at <= now();
  INSERT INTO public.telegram_pending_actions (telegram_user_id, action, payload)
  VALUES (p_telegram_user_id, p_action, p_payload) RETURNING id INTO v_pending;
  RETURN v_pending;
END $$;

-- Confirm pressed: takes the pending action (so a second press finds
-- nothing) and starts it like cashdeskbot_begin, with idempotency key
-- 'telegram:<id>'. Returns {action, payload, replay}; replay is the stored
-- response when the action already ran.
CREATE OR REPLACE FUNCTION public.telegram_begin(p_telegram_user_id bigint, p_pending_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p public.telegram_pending_actions;
BEGIN
  PERFORM private.telegram_act_as(p_telegram_user_id);
  DELETE FROM public.telegram_pending_actions
  WHERE id = p_pending_id AND telegram_user_id = p_telegram_user_id AND expires_at > now()
  RETURNING * INTO p;
  IF p.id IS NULL THEN
    PERFORM private.raise_api(404, 'PENDING_NOT_FOUND', 'This request was already handled or has expired.');
  END IF;
  RETURN jsonb_build_object(
    'action', p.action,
    'payload', p.payload,
    'replay', public.cashdeskbot_begin(p.action, 'telegram:' || p.id, p.payload));
END $$;

CREATE OR REPLACE FUNCTION public.telegram_finish(
  p_telegram_user_id bigint, p_pending_id uuid, p_action text, p_user_id text, p_audit jsonb, p_response jsonb
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.telegram_act_as(p_telegram_user_id);
  PERFORM public.cashdeskbot_finish(p_action, p_user_id,
    COALESCE(p_audit, '{}'::jsonb) || jsonb_build_object('via', 'telegram', 'telegramUserId', p_telegram_user_id),
    'telegram:' || p_pending_id, p_response);
END $$;

-- CashdeskBot never accepted it: frees the idempotency key.
CREATE OR REPLACE FUNCTION public.telegram_abort(p_telegram_user_id bigint, p_pending_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.telegram_act_as(p_telegram_user_id);
  PERFORM public.cashdeskbot_abort('telegram:' || p_pending_id);
END $$;

-- Cancel pressed.
CREATE OR REPLACE FUNCTION public.telegram_cancel(p_telegram_user_id bigint, p_pending_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  DELETE FROM public.telegram_pending_actions WHERE id = p_pending_id AND telegram_user_id = p_telegram_user_id;
END $$;

REVOKE ALL ON FUNCTION public.manage_telegram_status() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_telegram_link_code() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_telegram_unlink() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_telegram_status() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manage_telegram_link_code() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manage_telegram_unlink() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.telegram_link(bigint, text, text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_unlink(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_whoami(bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_prepare(bigint, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_begin(bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_finish(bigint, uuid, text, text, jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_abort(bigint, uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.telegram_cancel(bigint, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.telegram_link(bigint, text, text) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_unlink(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_whoami(bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_prepare(bigint, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_begin(bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_finish(bigint, uuid, text, text, jsonb, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_abort(bigint, uuid) TO service_role;
GRANT EXECUTE ON FUNCTION public.telegram_cancel(bigint, uuid) TO service_role;
