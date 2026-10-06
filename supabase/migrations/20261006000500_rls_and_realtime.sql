-- Row level security and Realtime.
--
-- The apps never write tables directly: every change goes through the API
-- functions (SECURITY DEFINER, with their own permission checks, audit
-- and idempotency). Direct table access is read-only and limited to what
-- each role may see, which is also what Supabase Realtime delivers to a
-- subscriber (Realtime applies these same policies to change events).

-- Every public table keeps RLS on (as Node migration 003 did); tables
-- without a policy below stay invisible to app roles.
DO $$
DECLARE
  t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
  END LOOP;
END
$$;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;

-- Helpers the policies call as the requesting role.
GRANT EXECUTE ON FUNCTION private.app_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_staff() TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Read grants (no INSERT/UPDATE/DELETE anywhere)
-- ---------------------------------------------------------------------------
-- users: never password_hash.
GRANT SELECT (id, role, phone, email, name, status, created_at, updated_at) ON public.users TO authenticated;
GRANT SELECT ON public.wallets, public.orders, public.ledger_entries, public.notifications,
  public.home_ads, public.deposit_numbers, public.sms_transactions, public.winwin_transactions,
  public.agent_profiles, public.exchange_rates, public.fees, public.withdrawal_limits
  TO authenticated;
GRANT SELECT ON public.payment_methods TO anon, authenticated;

-- ---------------------------------------------------------------------------
-- Policies
-- ---------------------------------------------------------------------------
DROP POLICY IF EXISTS users_select ON public.users;
CREATE POLICY users_select ON public.users FOR SELECT TO authenticated
  USING (id = auth.uid() OR private.is_staff());

DROP POLICY IF EXISTS agent_profiles_select ON public.agent_profiles;
CREATE POLICY agent_profiles_select ON public.agent_profiles FOR SELECT TO authenticated
  USING (user_id = auth.uid() OR private.app_role() = 'admin');

DROP POLICY IF EXISTS wallets_select ON public.wallets;
CREATE POLICY wallets_select ON public.wallets FOR SELECT TO authenticated
  USING ((customer_id = auth.uid() AND private.app_role() = 'customer') OR private.is_staff());

DROP POLICY IF EXISTS orders_select ON public.orders;
CREATE POLICY orders_select ON public.orders FOR SELECT TO authenticated
  USING ((customer_id = auth.uid() AND private.app_role() = 'customer') OR private.is_staff());

DROP POLICY IF EXISTS ledger_entries_select ON public.ledger_entries;
CREATE POLICY ledger_entries_select ON public.ledger_entries FOR SELECT TO authenticated
  USING (
    private.is_staff()
    OR (private.app_role() = 'customer'
        AND wallet_id IN (SELECT w.id FROM public.wallets w WHERE w.customer_id = auth.uid()))
  );

DROP POLICY IF EXISTS sms_transactions_select ON public.sms_transactions;
CREATE POLICY sms_transactions_select ON public.sms_transactions FOR SELECT TO authenticated
  USING (private.is_staff());

DROP POLICY IF EXISTS winwin_transactions_select ON public.winwin_transactions;
CREATE POLICY winwin_transactions_select ON public.winwin_transactions FOR SELECT TO authenticated
  USING (private.is_staff());

DROP POLICY IF EXISTS notifications_select ON public.notifications;
CREATE POLICY notifications_select ON public.notifications FOR SELECT TO authenticated
  USING (private.app_role() IS NOT NULL);

DROP POLICY IF EXISTS home_ads_select ON public.home_ads;
CREATE POLICY home_ads_select ON public.home_ads FOR SELECT TO authenticated
  USING ((enabled AND private.app_role() IS NOT NULL) OR private.is_staff());

DROP POLICY IF EXISTS deposit_numbers_select ON public.deposit_numbers;
CREATE POLICY deposit_numbers_select ON public.deposit_numbers FOR SELECT TO authenticated
  USING ((enabled AND private.app_role() IS NOT NULL) OR private.is_staff());

DROP POLICY IF EXISTS payment_methods_select ON public.payment_methods;
CREATE POLICY payment_methods_select ON public.payment_methods FOR SELECT TO anon, authenticated
  USING (true);

DROP POLICY IF EXISTS exchange_rates_select ON public.exchange_rates;
CREATE POLICY exchange_rates_select ON public.exchange_rates FOR SELECT TO authenticated
  USING (active AND private.app_role() IS NOT NULL);

DROP POLICY IF EXISTS fees_select ON public.fees;
CREATE POLICY fees_select ON public.fees FOR SELECT TO authenticated
  USING (active AND private.app_role() IS NOT NULL);

DROP POLICY IF EXISTS withdrawal_limits_select ON public.withdrawal_limits;
CREATE POLICY withdrawal_limits_select ON public.withdrawal_limits FOR SELECT TO authenticated
  USING (private.app_role() IS NOT NULL);

-- ---------------------------------------------------------------------------
-- Realtime: order status, balances, confirmations and app content push to
-- the apps as they change.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  t text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = 'supabase_realtime') THEN
    CREATE PUBLICATION supabase_realtime;
  END IF;
  FOREACH t IN ARRAY ARRAY[
    'orders', 'wallets', 'notifications', 'payment_methods', 'home_ads', 'deposit_numbers',
    'sms_transactions', 'winwin_transactions'
  ] LOOP
    IF NOT EXISTS (
      SELECT 1 FROM pg_publication_tables
      WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = t
    ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', t);
    END IF;
  END LOOP;
END
$$;
