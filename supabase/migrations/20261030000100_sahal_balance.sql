-- Sahal's balance in Company Balances.
--
-- The Sahal merchant account holds the money behind EVC Plus, Golis and ZAAD
-- deposits and payouts; its balance was not shown next to the other
-- companies. The merchant feed (functions/golis-merchant), which already has
-- a live Sahal session every few seconds, now reads Sahal's balance about
-- once a minute and records it here, exactly as read (or why it could not
-- be). Company Balances lists Sahal as one more company, with the same
-- statuses (available / low / stale / offline) as the others and counted in
-- the total only when fresh. Nobody can set a balance: only the service role
-- records one, and only what Sahal answered.
--
-- It is listed once a first read exists, so nothing changes until then.
-- The Agent App needs no update: Sahal comes as one more company in the same
-- answer, and its detail page (recent reads) opens as for any company.
CREATE TABLE IF NOT EXISTS public.sahal_balances (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  ok            BOOLEAN NOT NULL,
  balance_cents BIGINT,
  error         TEXT,
  checked_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (ok = (balance_cents IS NOT NULL))
);
CREATE INDEX IF NOT EXISTS idx_sahal_balances_checked ON public.sahal_balances (checked_at DESC);
ALTER TABLE public.sahal_balances ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.sahal_balances FROM PUBLIC, anon, authenticated;

-- Service role: is a new read due (the last one is older than p_max_age_seconds)?
CREATE OR REPLACE FUNCTION public.sahal_balance_due(p_max_age_seconds int)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT max(checked_at) FROM public.sahal_balances), '-infinity')
         < now() - make_interval(secs => GREATEST(p_max_age_seconds, 5));
END $$;

-- Service role: one read of Sahal's balance (USD), or why there is none.
CREATE OR REPLACE FUNCTION public.sahal_balance_record(p_balance numeric, p_error text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.sahal_balances (ok, balance_cents, error)
  VALUES (p_balance IS NOT NULL, round(p_balance * 100)::bigint,
    CASE WHEN p_balance IS NULL THEN left(COALESCE(NULLIF(btrim(p_error), ''), 'No balance returned'), 300) END);
  -- Keep a month of reads.
  DELETE FROM public.sahal_balances WHERE checked_at < now() - interval '31 days';
END $$;

-- Sahal as a company, in the shape of private.company_balance_json.
CREATE OR REPLACE FUNCTION private.sahal_company_json(p_from timestamptz, p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_last public.sahal_balances;
  v_good public.sahal_balances;
  v_threshold bigint := COALESCE(round(NULLIF(btrim((SELECT value FROM public.app_settings
    WHERE key = 'company_low_balance')), '')::numeric * 100)::bigint, 5000);
  v_status text;
BEGIN
  SELECT * INTO v_last FROM public.sahal_balances ORDER BY checked_at DESC LIMIT 1;
  SELECT * INTO v_good FROM public.sahal_balances WHERE ok ORDER BY checked_at DESC LIMIT 1;
  v_status := CASE
    WHEN v_good.id IS NULL OR NOT v_last.ok THEN 'offline'
    WHEN v_good.checked_at < now() - interval '15 minutes' THEN 'stale'
    WHEN v_good.balance_cents < v_threshold THEN 'low'
    ELSE 'available'
  END;
  RETURN jsonb_build_object(
    'method', 'sahal', 'label', 'Sahal', 'connected', true,
    'source', 'Sahal merchant account',
    'status', v_status,
    'balance', CASE WHEN v_good.id IS NOT NULL THEN private.money(v_good.balance_cents) END,
    'limit', NULL,
    'liveBalance', CASE WHEN v_good.id IS NOT NULL THEN private.money(v_good.balance_cents) END,
    'salesSinceCheck', private.money(0), 'payoutsSinceCheck', private.money(0), 'changesSinceCheck', 0,
    'lastSuccessAt', v_good.checked_at,
    'lastCheckedAt', v_last.checked_at,
    'lastError', CASE WHEN v_last.id IS NOT NULL AND NOT v_last.ok THEN v_last.error END,
    'lowThreshold', private.money(v_threshold),
    'waitingWithdrawals', 0, 'waitingAmount', private.money(0), 'topUpNeeded', NULL,
    'openWithdrawals', 0, 'openWithdrawalAmount', private.money(0),
    'period', jsonb_build_object('from', p_from, 'to', p_to, 'received', private.money(0), 'receivedCount', 0,
                                 'sent', private.money(0), 'sentCount', 0, 'open', 0, 'failed', 0));
END $$;

-- Every company; Sahal first once it has been read.
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
  FROM public.payment_methods m
  WHERE NOT EXISTS (SELECT 1 FROM public.payment_integrations i
                    WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL);
  IF EXISTS (SELECT 1 FROM public.sahal_balances) THEN
    v_items := jsonb_build_array(private.sahal_company_json(v_from, v_to)) || v_items;
  END IF;

  RETURN jsonb_build_object(
    'companies', v_items,
    'total', private.money(COALESCE((SELECT sum((i->>'balance')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low')), 0)),
    'totalLimit', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)
      THEN private.money((SELECT sum((i->>'limit')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)) END,
    'totalCompanies', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('available', 'low')),
    'limitUnknownCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NULL),
    'openWithdrawalAmount', private.money(COALESCE((SELECT sum((i->>'openWithdrawalAmount')::numeric * 100)::bigint
      FROM jsonb_array_elements(v_items) i WHERE (i->>'connected')::boolean), 0)),
    'lowCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'low'),
    'unavailableCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('offline', 'stale')),
    'notConnectedCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'not_connected'),
    'generatedAt', now());
END $$;

-- A company's detail: Sahal's is its recent reads; every other company is
-- answered as before (the earlier function, kept under private.).
ALTER FUNCTION public.agent_company_detail(text, timestamptz, timestamptz, text) RENAME TO company_detail_methods;
ALTER FUNCTION public.company_detail_methods(text, timestamptz, timestamptz, text) SET SCHEMA private;
REVOKE ALL ON FUNCTION private.company_detail_methods(text, timestamptz, timestamptz, text) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.agent_company_detail(
  p_method text, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_status text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF lower(btrim(COALESCE(p_method, ''))) = 'sahal' THEN
    PERFORM private.require_company_balances();
    RETURN private.sahal_company_json(
        COALESCE(p_from, date_trunc('day', now()) - interval '6 days'), COALESCE(p_to, now() + interval '1 second'))
      || jsonb_build_object(
        'checks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'ok', b.ok, 'balance', CASE WHEN b.ok THEN private.money(b.balance_cents) END,
            'error', b.error, 'checkedAt', b.checked_at) ORDER BY b.checked_at DESC)
          FROM (SELECT * FROM public.sahal_balances ORDER BY checked_at DESC LIMIT 10) b), '[]'),
        'movements', '[]'::jsonb,
        'orders', '[]'::jsonb);
  END IF;
  RETURN private.company_detail_methods(p_method, p_from, p_to, p_status);
END $$;

REVOKE ALL ON FUNCTION private.sahal_company_json(timestamptz, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.agent_company_balances(timestamptz, timestamptz) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.agent_company_detail(text, timestamptz, timestamptz, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.sahal_balance_due(int), public.sahal_balance_record(numeric, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.agent_company_balances(timestamptz, timestamptz) TO authenticated;
GRANT EXECUTE ON FUNCTION public.agent_company_detail(text, timestamptz, timestamptz, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.sahal_balance_due(int), public.sahal_balance_record(numeric, text) TO service_role;
