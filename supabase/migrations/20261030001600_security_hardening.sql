-- Security hardening (see docs/SECURITY_AUDIT.md for the findings).
--
-- 1. Agent duties are enforced by the server. Until now the duties an admin
--    gives an agent (evc_deposit, evc_withdraw) only decided what the Agent
--    App showed: any agent could complete or fail any withdrawal, reject any
--    deposit, run payouts and feed payment SMS. Each of those calls now needs
--    the duty (managers -- admins and agents with manage_settings -- always
--    pass). app_settings 'agent_duty_enforcement' = 'off' switches it off.
-- 2. Money added to a wallet by an agent who is not a manager is capped per
--    Somalia day (app_settings 'wallet_adjust_agent_daily_cap', dollars).
-- 3. The audit log can never be changed, deleted or emptied, by anyone.
-- 4. Sign-ups are limited (60 in 10 minutes for the whole service).
-- 5. Suspicious activity is recorded and sent to the admin on Telegram (in
--    Somali, through the existing alert worker): many withdrawals in a short
--    time, a large wallet adjustment, a change of the payment-number
--    permission, someone probing Wallet IDs on the support bot.
-- Nothing here changes a customer's data, a balance or an existing order.

INSERT INTO public.app_settings (key, value) VALUES
  ('agent_duty_enforcement', 'on'),
  ('wallet_adjust_agent_daily_cap', '2000')
ON CONFLICT (key) DO NOTHING;

-- ------------------------------------------------------------ 1. agent duties

CREATE OR REPLACE FUNCTION private.require_agent_duty(p_duty text)
RETURNS uuid LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
BEGIN
  IF COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'agent_duty_enforcement'), 'on') = 'off' THEN
    RETURN v_id;
  END IF;
  IF private.can_manage() THEN
    RETURN v_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.agent_profiles ap WHERE ap.user_id = v_id AND p_duty = ANY (COALESCE(ap.responsibilities, '{}'))) THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Your account does not have this duty. Ask an admin to give it to you.');
  END IF;
  RETURN v_id;
END $$;
REVOKE ALL ON FUNCTION private.require_agent_duty(text) FROM PUBLIC, anon, authenticated;

-- Puts the duty check where each of these functions asked only for the agent
-- role (the function bodies are rewritten from their own definitions; the
-- migration stops if one has no agent check to replace).
DO $$
DECLARE
  r record;
  def text;
  fn text;
  n int := 0;
  withdraw_fns text[] := ARRAY[
    'agent_withdrawal_complete', 'agent_withdrawal_fail',
    'agent_payout_confirmation', 'agent_payout_report_step1', 'agent_payout_report_step2', 'agent_payout_start_dial',
    'agent_exchange_payout_confirmation', 'agent_exchange_report_step1', 'agent_exchange_report_step2', 'agent_exchange_start_dial'];
  deposit_fns text[] := ARRAY['agent_reject_deposit', 'agent_ingest_payment_sms'];
BEGIN
  FOREACH fn IN ARRAY withdraw_fns LOOP
    FOR r IN SELECT p.oid FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = fn LOOP
      def := pg_get_functiondef(r.oid);
      IF position('private.require_role(''agent'')' IN def) = 0 THEN
        RAISE EXCEPTION 'cannot guard %: it has no agent role check to replace', fn;
      END IF;
      EXECUTE replace(def, 'private.require_role(''agent'')', 'private.require_agent_duty(''evc_withdraw'')');
      n := n + 1;
    END LOOP;
  END LOOP;
  FOREACH fn IN ARRAY deposit_fns LOOP
    FOR r IN SELECT p.oid FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = fn LOOP
      def := pg_get_functiondef(r.oid);
      IF position('private.require_role(''agent'')' IN def) = 0 THEN
        RAISE EXCEPTION 'cannot guard %: it has no agent role check to replace', fn;
      END IF;
      EXECUTE replace(def, 'private.require_role(''agent'')', 'private.require_agent_duty(''evc_deposit'')');
      n := n + 1;
    END LOOP;
  END LOOP;
  IF n < 12 THEN
    RAISE EXCEPTION 'expected to guard at least 12 functions, guarded %', n;
  END IF;
END $$;

-- ------------------------------------------------- 2. wallet adjustment cap

CREATE OR REPLACE FUNCTION private.wallet_adjustment_cap()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cap bigint;
  v_today bigint;
BEGIN
  IF NEW.direction <> 'add' THEN
    RETURN NEW;
  END IF;
  -- Managers (admins, agents with manage_settings) are not capped; they are audited.
  IF EXISTS (SELECT 1 FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
             WHERE u.id = NEW.agent_id
               AND (u.role = 'admin' OR 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}')))) THEN
    RETURN NEW;
  END IF;
  v_cap := round(COALESCE(NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'wallet_adjust_agent_daily_cap')), '')::numeric, 2000) * 100)::bigint;
  SELECT COALESCE(sum(amount_cents), 0) INTO v_today FROM public.wallet_adjustments
  WHERE agent_id = NEW.agent_id AND direction = 'add'
    AND (created_at AT TIME ZONE 'Africa/Mogadishu')::date = (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  IF v_today + NEW.amount_cents > v_cap THEN
    PERFORM private.raise_api(403, 'ADJUSTMENT_LIMIT',
      'The daily limit for adding money to wallets (' || private.money(v_cap) || ') is reached. Ask a manager.');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.wallet_adjustment_cap() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS wallet_adjustments_cap ON public.wallet_adjustments;
CREATE TRIGGER wallet_adjustments_cap BEFORE INSERT ON public.wallet_adjustments
  FOR EACH ROW EXECUTE FUNCTION private.wallet_adjustment_cap();

-- ------------------------------------------------------ 3. audit log is final

CREATE OR REPLACE FUNCTION private.audit_logs_final()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'The audit log can not be changed or deleted' USING ERRCODE = '42501';
END $$;
REVOKE ALL ON FUNCTION private.audit_logs_final() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS audit_logs_no_change ON public.audit_logs;
CREATE TRIGGER audit_logs_no_change BEFORE UPDATE OR DELETE ON public.audit_logs
  FOR EACH ROW EXECUTE FUNCTION private.audit_logs_final();
DROP TRIGGER IF EXISTS audit_logs_no_truncate ON public.audit_logs;
CREATE TRIGGER audit_logs_no_truncate BEFORE TRUNCATE ON public.audit_logs
  FOR EACH STATEMENT EXECUTE FUNCTION private.audit_logs_final();

-- ---------------------------------------------------------- 4. sign-up limit

CREATE TABLE IF NOT EXISTS public.security_signups (
  id BIGSERIAL PRIMARY KEY,
  at TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.security_signups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.security_signups FROM PUBLIC, anon, authenticated;

DO $$
DECLARE
  r record;
  def text;
  check_sql text := E'BEGIN\n  DELETE FROM public.security_signups WHERE at < now() - interval ''1 day'';\n'
    || E'  IF (SELECT count(*) FROM public.security_signups WHERE at > now() - interval ''10 minutes'') >= 60 THEN\n'
    || E'    PERFORM private.raise_api(429, ''RATE_LIMITED'', ''Too many sign-ups right now. Please try again in a few minutes.'');\n'
    || E'  END IF;\n  INSERT INTO public.security_signups DEFAULT VALUES;\n';
BEGIN
  FOR r IN SELECT p.oid FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'register_customer' LOOP
    def := pg_get_functiondef(r.oid);
    IF position('BEGIN' IN def) = 0 THEN
      RAISE EXCEPTION 'cannot add the sign-up limit: register_customer has no BEGIN';
    END IF;
    -- the first BEGIN is the start of the body
    EXECUTE regexp_replace(def, 'BEGIN', check_sql);
  END LOOP;
END $$;

-- ------------------------------------------------- 5. suspicious activity

CREATE TABLE IF NOT EXISTS public.security_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        TEXT NOT NULL,
  severity    TEXT NOT NULL CHECK (severity IN ('medium', 'high')),
  customer_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  actor_id    UUID REFERENCES public.users(id) ON DELETE SET NULL,
  dedupe_key  TEXT,
  title_so    TEXT NOT NULL,
  detail_so   TEXT NOT NULL,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  alerted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS security_events_pending_idx ON public.security_events (created_at) WHERE alerted_at IS NULL;
CREATE INDEX IF NOT EXISTS security_events_dedupe_idx ON public.security_events (kind, dedupe_key, created_at DESC);
ALTER TABLE public.security_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.security_events FROM PUBLIC, anon, authenticated;

-- Records one event, unless the same one (kind + key) was recorded in the last p_quiet minutes.
CREATE OR REPLACE FUNCTION private.security_event(
  p_kind text, p_severity text, p_customer uuid, p_actor uuid, p_key text, p_quiet int, p_title text, p_detail text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF p_key IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.security_events e
       WHERE e.kind = p_kind AND e.dedupe_key = p_key AND e.created_at > now() - make_interval(mins => p_quiet)) THEN
    RETURN;
  END IF;
  INSERT INTO public.security_events (kind, severity, customer_id, actor_id, dedupe_key, title_so, detail_so)
  VALUES (p_kind, p_severity, p_customer, p_actor, p_key, p_title, p_detail);
END $$;
REVOKE ALL ON FUNCTION private.security_event(text, text, uuid, uuid, text, int, text, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.security_customer_text(p_customer uuid)
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 'Magaca macmiilka: ' || COALESCE(NULLIF(u.name, ''), '—') || E'\nLambarka telefoonka: ' || u.phone
  FROM public.users u WHERE u.id = p_customer
$$;
REVOKE ALL ON FUNCTION private.security_customer_text(uuid) FROM PUBLIC, anon, authenticated;

-- (a) Many withdrawals in a short time.
CREATE OR REPLACE FUNCTION private.security_watch_withdrawals()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n int;
BEGIN
  IF NEW.direction <> 'withdraw' THEN
    RETURN NEW;
  END IF;
  SELECT count(*) INTO n FROM public.orders
  WHERE customer_id = NEW.customer_id AND direction = 'withdraw' AND created_at > now() - interval '10 minutes';
  IF n >= 8 THEN
    PERFORM private.security_event('withdraw_velocity', 'high', NEW.customer_id, NULL, NEW.customer_id::text, 30,
      'Bixinno badan oo gaaban',
      private.security_customer_text(NEW.customer_id) || E'\nBixinno: ' || n || ' 10-kii daqiiqo ee u dambeeyay');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.security_watch_withdrawals() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS orders_security_watch ON public.orders;
CREATE TRIGGER orders_security_watch AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.security_watch_withdrawals();

-- (b) A large addition to a wallet.
CREATE OR REPLACE FUNCTION private.security_watch_adjustments()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'add' AND NEW.amount_cents >= 50000 THEN
    PERFORM private.security_event('wallet_adjust_large', 'high', NEW.customer_id, NEW.agent_id, NEW.reference, 0,
      'Lacag badan ayaa boorsada lagu daray',
      private.security_customer_text(NEW.customer_id) || E'\nLacagta: $' || private.money(NEW.amount_cents) ||
      E'\nXaraynta: ' || NEW.reference || E'\nLagu daray: ' || COALESCE((SELECT name FROM public.users WHERE id = NEW.agent_id), '—'));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.security_watch_adjustments() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS wallet_adjustments_security_watch ON public.wallet_adjustments;
CREATE TRIGGER wallet_adjustments_security_watch AFTER INSERT ON public.wallet_adjustments
  FOR EACH ROW EXECUTE FUNCTION private.security_watch_adjustments();

-- (c) The permission to use another payment number is granted or taken away.
CREATE OR REPLACE FUNCTION private.security_watch_number_access()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' OR NEW.enabled IS DISTINCT FROM OLD.enabled THEN
    PERFORM private.security_event('payment_number_access', 'medium', NEW.customer_id, COALESCE(NEW.revoked_by, NEW.granted_by), NULL, 0,
      CASE WHEN NEW.enabled THEN 'Oggolaansho lambar kale ayaa la siiyay' ELSE 'Oggolaanshaha lambar kale waa la qaaday' END,
      private.security_customer_text(NEW.customer_id) || E'\nWax ka beddelay: ' ||
      COALESCE((SELECT name FROM public.users WHERE id = COALESCE(NEW.revoked_by, NEW.granted_by)), '—'));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.security_watch_number_access() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS payment_number_grants_security_watch ON public.payment_number_grants;
CREATE TRIGGER payment_number_grants_security_watch AFTER INSERT OR UPDATE ON public.payment_number_grants
  FOR EACH ROW EXECUTE FUNCTION private.security_watch_number_access();

-- (d) Someone keeps trying Wallet IDs that are not theirs on the support bot.
CREATE OR REPLACE FUNCTION private.security_watch_support()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.kind = 'wrong_wallet' AND (SELECT count(*) FROM public.support_events
       WHERE chat_id = NEW.chat_id AND kind = 'wrong_wallet' AND created_at > now() - interval '1 hour') >= 5 THEN
    PERFORM private.security_event('support_wallet_probe', 'high', NULL, NULL, NEW.chat_id::text, 60,
      'Isku-day badan oo Wallet ID ah (bot-ka caawinta)',
      E'Telegram chat: ' || NEW.chat_id || E'\nIsku-day khaldan: 5+ saacaddii u dambaysay');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.security_watch_support() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS support_events_security_watch ON public.support_events;
CREATE TRIGGER support_events_security_watch AFTER INSERT ON public.support_events
  FOR EACH ROW EXECUTE FUNCTION private.security_watch_support();

-- The alert worker (functions/withdrawal-alerts) says them once, in Somali.
CREATE OR REPLACE FUNCTION public.security_events_todo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', e.id, 'severity', e.severity, 'title', e.title_so, 'detail', e.detail_so, 'at', e.created_at)
                     ORDER BY e.created_at)
    FROM (SELECT * FROM public.security_events WHERE alerted_at IS NULL ORDER BY created_at LIMIT 20) e), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.security_events_sent(p_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.security_events SET alerted_at = now() WHERE id = ANY (p_ids) AND alerted_at IS NULL;
END $$;

-- Management reads the recent events (no customer data beyond the text already sent).
CREATE OR REPLACE FUNCTION public.manage_security_events(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', e.id, 'kind', e.kind, 'severity', e.severity, 'title', e.title_so,
                                        'detail', e.detail_so, 'createdAt', e.created_at, 'alerted', e.alerted_at IS NOT NULL)
                     ORDER BY e.created_at DESC)
    FROM (SELECT * FROM public.security_events ORDER BY created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)) e), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.security_events_todo(), public.security_events_sent(uuid[]), public.manage_security_events(int)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.security_events_todo(), public.security_events_sent(uuid[]) TO service_role;
GRANT EXECUTE ON FUNCTION public.manage_security_events(int) TO authenticated;

-- ------------------------------------------- 6. the support bot's Wallet ID check

-- A Wallet ID that does not exist looks exactly like one that does (the chat
-- is asked for the customer's own contact either way), so Wallet IDs can not
-- be found out one by one. A wrong ID still counts toward the hourly limit.
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
  END IF;
  INSERT INTO public.support_chats (chat_id, pending_customer_id, state) VALUES (p_chat, v_customer, 'awaiting_contact')
  ON CONFLICT (chat_id) DO UPDATE SET pending_customer_id = v_customer, state = 'awaiting_contact', updated_at = now();
  RETURN jsonb_build_object('ok', true);
END $$;

-- (e) A large deposit is credited (a forged payment SMS would end like this).
CREATE OR REPLACE FUNCTION private.security_watch_deposits()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'deposit' AND NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed' AND NEW.amount_cents >= 30000 THEN
    PERFORM private.security_event('large_deposit', 'medium', NEW.customer_id, NEW.agent_id, NEW.order_code, 0,
      'Dhigasho weyn ayaa la xaqiijiyay',
      private.security_customer_text(NEW.customer_id) || E'\nLacagta: $' || private.money(NEW.amount_cents) ||
      E'\nLambarka macaamilka: ' || NEW.order_code || E'\nShirkadda lacagta: ' || private.method_label(NEW.method));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.security_watch_deposits() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS orders_security_watch_deposits ON public.orders;
CREATE TRIGGER orders_security_watch_deposits AFTER UPDATE OF status ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.security_watch_deposits();
