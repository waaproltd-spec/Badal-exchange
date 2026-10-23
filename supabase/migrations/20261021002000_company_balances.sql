-- Agent App: Company Balances -- each company's cash register balance.
--
-- Only companies BAARI reaches through an API have a live balance: 1XBET
-- and 888STARZ (CashdeskBot, private.is_cashdesk_method). Every balance
-- read from them is kept in cashdesk_balances (who asked, when, what came
-- back, or the error), written only by the Edge Functions with the service
-- role. The other companies and mobile-money methods have no balance source
-- and are listed as 'not_connected' -- never with an amount.
--
-- Status of a connected company:
--   offline     no successful read yet, or the last read failed
--   stale       the last good read is older than 15 minutes
--   low         withdrawals are waiting for a top-up (platform_finish
--               'low_funds'), or the balance is under the low-balance
--               threshold (app_settings 'company_low_balance', default 50)
--   available   otherwise
-- Totals only add up fresh, verified balances and say how many companies
-- were left out.
--
-- Who may look: admins, agents with 'manage_settings', and agents given
-- 'view_company_balances'. Nobody can set a balance; there is no function
-- for it.

CREATE TABLE IF NOT EXISTS public.cashdesk_balances (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method        public.order_method NOT NULL,
  ok            BOOLEAN NOT NULL,
  balance_cents BIGINT,
  limit_cents   BIGINT,
  error         TEXT,
  source        TEXT NOT NULL DEFAULT 'cashdeskbot',
  requested_by  UUID REFERENCES public.users(id),
  checked_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ok = (balance_cents IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_cashdesk_balances_method ON public.cashdesk_balances (method, checked_at DESC);
ALTER TABLE public.cashdesk_balances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cashdesk_balances FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.can_view_company_balances()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT private.can_manage() OR COALESCE((
    SELECT u.role = 'agent' AND 'view_company_balances' = ANY (COALESCE(ap.responsibilities, '{}'))
    FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.id = auth.uid() AND u.status = 'active'
  ), false)
$$;

CREATE OR REPLACE FUNCTION private.require_company_balances()
RETURNS uuid LANGUAGE plpgsql STABLE SET search_path = '' AS $$
BEGIN
  IF NOT private.can_view_company_balances() THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'You are not allowed to see company balances');
  END IF;
  RETURN auth.uid();
END $$;

/** Raises FORBIDDEN unless the caller may see company balances. */
CREATE OR REPLACE FUNCTION public.agent_company_balances_access()
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_company_balances();
  RETURN true;
END $$;

-- Service role: connected companies whose last read is older than
-- p_max_age_seconds (or never read).
CREATE OR REPLACE FUNCTION public.company_balance_due(p_max_age_seconds int)
RETURNS text[] LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((
    SELECT array_agg(m.method::text ORDER BY m.sort_order)
    FROM public.payment_methods m
    WHERE private.is_cashdesk_method(m.method)
      AND COALESCE((SELECT max(b.checked_at) FROM public.cashdesk_balances b WHERE b.method = m.method), '-infinity')
          < now() - make_interval(secs => GREATEST(p_max_age_seconds, 5))
  ), '{}');
END $$;

-- Service role: one balance read (p_balance/p_limit in USD), or its error.
CREATE OR REPLACE FUNCTION public.company_balance_record(
  p_method text, p_balance numeric, p_limit numeric, p_error text, p_requested_by uuid DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_method public.order_method := private.parse_method(p_method);
BEGIN
  PERFORM private.require_service();
  IF NOT private.is_cashdesk_method(v_method) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'No balance source for ' || p_method);
  END IF;
  INSERT INTO public.cashdesk_balances (method, ok, balance_cents, limit_cents, error, requested_by)
  VALUES (v_method, p_balance IS NOT NULL, round(p_balance * 100)::bigint, round(p_limit * 100)::bigint,
    CASE WHEN p_balance IS NULL THEN left(COALESCE(NULLIF(btrim(p_error), ''), 'No balance returned'), 300) END,
    p_requested_by);
  -- Keep a month of reads.
  DELETE FROM public.cashdesk_balances WHERE method = v_method AND checked_at < now() - interval '31 days';
END $$;

-- One company's balance, status and figures for [p_from, p_to).
CREATE OR REPLACE FUNCTION private.company_balance_json(
  p_method public.order_method, p_label text, p_from timestamptz, p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_connected boolean := private.is_cashdesk_method(p_method);
  v_last public.cashdesk_balances;
  v_good public.cashdesk_balances;
  v_threshold bigint := COALESCE(round(NULLIF(btrim((SELECT value FROM public.app_settings
    WHERE key = 'company_low_balance')), '')::numeric * 100)::bigint, 5000);
  v_waiting_n int;
  v_waiting bigint;
  v_pending_n int;
  v_pending bigint;
  v_status text;
  s record;
BEGIN
  SELECT * INTO v_last FROM public.cashdesk_balances WHERE method = p_method ORDER BY checked_at DESC LIMIT 1;
  SELECT * INTO v_good FROM public.cashdesk_balances WHERE method = p_method AND ok ORDER BY checked_at DESC LIMIT 1;

  -- Withdrawals waiting for this register to be topped up, and all open
  -- withdrawals (money about to leave it).
  SELECT count(*) FILTER (WHERE low_funds_since IS NOT NULL),
         COALESCE(sum(net_cents) FILTER (WHERE low_funds_since IS NOT NULL), 0),
         count(*), COALESCE(sum(net_cents), 0)
    INTO v_waiting_n, v_waiting, v_pending_n, v_pending
  FROM public.orders
  WHERE method = p_method AND direction = 'withdraw' AND status IN ('pending', 'processing');

  -- Period figures, each order once: completed by completion time, the
  -- rest by creation time.
  SELECT
    count(*) FILTER (WHERE direction = 'deposit' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to) AS dep_n,
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to), 0) AS dep,
    count(*) FILTER (WHERE direction = 'withdraw' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to) AS wd_n,
    COALESCE(sum(net_cents) FILTER (WHERE direction = 'withdraw' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to), 0) AS wd,
    count(*) FILTER (WHERE status IN ('pending', 'processing') AND created_at >= p_from AND created_at < p_to) AS open_n,
    count(*) FILTER (WHERE status = 'failed' AND created_at >= p_from AND created_at < p_to) AS failed_n
    INTO s
  FROM public.orders WHERE method = p_method;

  v_status := CASE
    WHEN NOT v_connected THEN 'not_connected'
    WHEN v_good.id IS NULL OR NOT v_last.ok THEN 'offline'
    WHEN v_good.checked_at < now() - interval '15 minutes' THEN 'stale'
    WHEN v_waiting_n > 0 OR v_good.balance_cents < v_threshold THEN 'low'
    ELSE 'available'
  END;

  RETURN jsonb_build_object(
    'method', p_method, 'label', p_label, 'connected', v_connected,
    'source', CASE WHEN v_connected THEN 'CashdeskBot' END,
    'status', v_status,
    'balance', CASE WHEN v_good.id IS NOT NULL THEN private.money(v_good.balance_cents) END,
    'limit', CASE WHEN v_good.limit_cents IS NOT NULL THEN private.money(v_good.limit_cents) END,
    'lastSuccessAt', v_good.checked_at,
    'lastCheckedAt', v_last.checked_at,
    'lastError', CASE WHEN v_last.id IS NOT NULL AND NOT v_last.ok THEN v_last.error END,
    'lowThreshold', private.money(v_threshold),
    'waitingWithdrawals', v_waiting_n,
    'waitingAmount', private.money(v_waiting),
    'topUpNeeded', CASE WHEN v_waiting_n > 0 AND v_good.id IS NOT NULL
      THEN private.money(GREATEST(v_waiting - v_good.balance_cents, 0)) END,
    'openWithdrawals', v_pending_n,
    'openWithdrawalAmount', private.money(v_pending),
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to,
      'received', private.money(s.dep), 'receivedCount', s.dep_n,
      'sent', private.money(s.wd), 'sentCount', s.wd_n,
      'open', s.open_n, 'failed', s.failed_n));
END $$;

-- Every company, connected first, and the totals of fresh verified balances.
CREATE OR REPLACE FUNCTION public.agent_company_balances(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now()));
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
  v_items jsonb;
BEGIN
  PERFORM private.require_company_balances();
  IF v_to <= v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period must end after it starts');
  END IF;
  SELECT COALESCE(jsonb_agg(private.company_balance_json(m.method, m.label, v_from, v_to)
           ORDER BY NOT private.is_cashdesk_method(m.method), m.kind DESC, m.sort_order), '[]')
    INTO v_items
  FROM public.payment_methods m;

  RETURN jsonb_build_object(
    'companies', v_items,
    'total', private.money(COALESCE((SELECT sum((i->>'balance')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low')), 0)),
    'totalCompanies', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('available', 'low')),
    'openWithdrawalAmount', private.money(COALESCE((SELECT sum((i->>'openWithdrawalAmount')::numeric * 100)::bigint
      FROM jsonb_array_elements(v_items) i WHERE (i->>'connected')::boolean), 0)),
    'lowCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'low'),
    'unavailableCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('offline', 'stale')),
    'notConnectedCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'not_connected'),
    'generatedAt', now());
END $$;

-- One company: its balance, recent balance reads, and its orders in the
-- period (newest first; p_status 'open' | 'completed' | 'failed' filters).
CREATE OR REPLACE FUNCTION public.agent_company_detail(
  p_method text, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_status text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_method public.order_method := private.parse_method(p_method);
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now()) - interval '6 days');
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
BEGIN
  PERFORM private.require_company_balances();
  RETURN private.company_balance_json(v_method, private.method_label(v_method), v_from, v_to) || jsonb_build_object(
    'checks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'ok', b.ok, 'balance', CASE WHEN b.ok THEN private.money(b.balance_cents) END,
        'error', b.error, 'checkedAt', b.checked_at) ORDER BY b.checked_at DESC)
      FROM (SELECT * FROM public.cashdesk_balances WHERE method = v_method ORDER BY checked_at DESC LIMIT 10) b), '[]'),
    'orders', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'status', o.status,
        'amount', CASE WHEN o.amount_unknown THEN NULL ELSE private.money(o.net_cents) END,
        'accountId', o.winwin_id, 'customerName', u.name, 'note', o.failure_reason,
        'waitingTopUp', o.low_funds_since IS NOT NULL AND o.status = 'processing',
        'createdAt', o.created_at, 'completedAt', o.completed_at) ORDER BY o.created_at DESC)
      FROM (SELECT * FROM public.orders o2
            WHERE o2.method = v_method
              AND COALESCE(o2.completed_at, o2.created_at) >= v_from AND o2.created_at < v_to
              AND (p_status IS NULL
                OR (p_status = 'open' AND o2.status IN ('pending', 'processing'))
                OR o2.status::text = p_status)
            ORDER BY o2.created_at DESC LIMIT 100) o
      LEFT JOIN public.users u ON u.id = o.customer_id), '[]'));
END $$;

-- Refresh balances every 5 minutes (the platform-orders worker reads them
-- when it is woken; see functions/platform-orders).
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-company-balances';
    PERFORM cron.schedule('baari-company-balances', '*/5 * * * *', 'SELECT private.platform_kick()');
  END IF;
END
$do$;

REVOKE ALL ON FUNCTION private.can_view_company_balances() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.require_company_balances() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.company_balance_json(public.order_method, text, timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.agent_company_balances_access() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.agent_company_balances(timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.agent_company_detail(text, timestamptz, timestamptz, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.company_balance_due(int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.company_balance_record(text, numeric, numeric, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_company_balances_access() TO authenticated;
GRANT EXECUTE ON FUNCTION public.agent_company_balances(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agent_company_detail(text, timestamptz, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.company_balance_due(int) TO service_role;
GRANT EXECUTE ON FUNCTION public.company_balance_record(text, numeric, numeric, text, uuid) TO service_role;
