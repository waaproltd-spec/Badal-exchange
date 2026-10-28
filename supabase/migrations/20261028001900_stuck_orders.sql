-- No order stays pending or processing in silence.
--
-- An order only ever ends one way: the provider's confirmed result
-- (completed), a definitive failure (failed, money released), or -- for an
-- unpaid mobile-money deposit -- expiry after 30 minutes. Where the outcome
-- is not known (an unclear Sahal answer, an agent still to pay) the order is
-- held on purpose and never resent or refunded, so nothing is paid twice;
-- the withdrawal alerts already say why after 30 seconds.
--
-- What was missing is a safety net that says so again when something
-- stays unresolved far longer than it should, for any kind of order:
--   withdrawal, mobile money ........ not final after 15 minutes
--   withdrawal, betting platform .... not final after 60 minutes
--   deposit, processing ............. after 15 minutes
--   deposit, mobile money, pending .. after 35 minutes (it should have expired
--                                     at 30: the expiry job is not running)
--   deposit, betting platform ....... pending after 6 hours
-- The Telegram alert chat is told once an hour (at most 24 times per order)
-- until it is final. This only READS orders and writes its own bookkeeping
-- row: it never changes a status, a balance, a ledger entry or a payment, and
-- never retries anything.

CREATE TABLE IF NOT EXISTS public.stuck_order_alerts (
  order_id      uuid PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  alerts        integer NOT NULL DEFAULT 0,
  last_alert_at timestamptz
);
ALTER TABLE public.stuck_order_alerts ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.stuck_reason(o public.orders)
RETURNS text LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT CASE
    WHEN o.status NOT IN ('pending', 'processing') THEN NULL
    WHEN o.direction = 'withdraw' AND private.is_mobile_money(o.method) AND o.created_at < now() - interval '15 minutes' THEN 'withdrawal_unresolved'
    WHEN o.direction = 'withdraw' AND NOT private.is_mobile_money(o.method) AND o.created_at < now() - interval '60 minutes' THEN 'withdrawal_unresolved'
    WHEN o.direction = 'deposit' AND o.status = 'processing' AND o.created_at < now() - interval '15 minutes' THEN 'deposit_processing'
    WHEN o.direction = 'deposit' AND o.status = 'pending' AND private.is_mobile_money(o.method) AND o.created_at < now() - interval '35 minutes' THEN 'expiry_not_running'
    WHEN o.direction = 'deposit' AND o.status = 'pending' AND NOT private.is_mobile_money(o.method) AND o.created_at < now() - interval '6 hours' THEN 'platform_deposit_open'
  END
$$;

-- Managers: the orders that are unresolved beyond those times.
CREATE OR REPLACE FUNCTION public.manage_stuck_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'orderId', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'method', o.method, 'status', o.status,
      'amount', private.money(o.amount_cents), 'createdAt', o.created_at,
      'hours', round(extract(epoch FROM now() - o.created_at) / 3600, 1), 'reason', private.stuck_reason(o)) ORDER BY o.created_at)
    FROM public.orders o WHERE private.stuck_reason(o) IS NOT NULL), '[]'::jsonb);
END $$;

-- Worker: what to say now (not told in the last hour, at most 24 times each).
CREATE OR REPLACE FUNCTION public.stuck_orders_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(x.j ORDER BY x.created_at) FROM (
    SELECT o.created_at, jsonb_build_object(
        'orderId', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'method', o.method, 'status', o.status,
        'amount', private.money(o.amount_cents), 'hours', round(extract(epoch FROM now() - o.created_at) / 3600, 1),
        'reason', private.stuck_reason(o)) AS j
    FROM public.orders o LEFT JOIN public.stuck_order_alerts a ON a.order_id = o.id
    WHERE private.stuck_reason(o) IS NOT NULL
      AND (a.order_id IS NULL OR (a.alerts < 24 AND a.last_alert_at < now() - interval '60 minutes'))
    ORDER BY o.created_at LIMIT 10) x), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.stuck_orders_sent(p_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  INSERT INTO public.stuck_order_alerts (order_id, alerts, last_alert_at)
  SELECT id, 1, now() FROM public.orders WHERE id = ANY (p_ids)
  ON CONFLICT (order_id) DO UPDATE SET alerts = public.stuck_order_alerts.alerts + 1, last_alert_at = now();
END $$;

REVOKE ALL ON FUNCTION private.stuck_reason(public.orders) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_stuck_orders() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_stuck_orders() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.stuck_orders_todo(), public.stuck_orders_sent(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.stuck_orders_todo(), public.stuck_orders_sent(uuid[]) TO service_role;
