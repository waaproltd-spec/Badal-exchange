-- Agent App Dashboard, the redesigned one: what agent_dashboard shows, plus
-- the money behind each status, customers, a 7-day chart and the top
-- services and deposit methods. Read-only; any agent (like agent_dashboard).
--
-- "Orders" are betting-platform orders (deposits and withdrawals of a
-- payment method of kind 'platform'); "deposits" and "withdrawals" are
-- mobile money. Days are Mogadishu days; the chart and the top lists cover
-- the 7 days ending p_day (today when null).
CREATE OR REPLACE FUNCTION public.agent_dashboard_stats(p_day date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_day date := COALESCE(p_day, v_today);
  v_from timestamptz := ((v_day - 6)::timestamp AT TIME ZONE 'Africa/Mogadishu');
  v_to timestamptz := ((v_day + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu');
  v_month timestamptz := (date_trunc('month', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu');
  c record;
BEGIN
  IF v_day > v_today THEN
    v_day := v_today;
    v_from := ((v_day - 6)::timestamp AT TIME ZONE 'Africa/Mogadishu');
    v_to := ((v_day + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu');
  END IF;

  SELECT
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit' AND status = 'pending'), 0) AS pending_deposits,
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'withdraw' AND status = 'pending'), 0) AS pending_withdrawals,
    COALESCE(sum(amount_cents) FILTER (WHERE status = 'processing'), 0) AS processing,
    COALESCE(sum(amount_cents) FILTER (WHERE status = 'completed'), 0) AS completed,
    COALESCE(sum(amount_cents) FILTER (WHERE status = 'failed'), 0) AS failed
  INTO c FROM public.orders;

  RETURN jsonb_build_object(
    'day', v_day,
    'amounts', jsonb_build_object(
      'pendingDeposits', private.money(c.pending_deposits),
      'pendingWithdrawals', private.money(c.pending_withdrawals),
      'processing', private.money(c.processing),
      'completed', private.money(c.completed),
      'failed', private.money(c.failed)),
    'totalCustomers', (SELECT count(*) FROM public.users WHERE role = 'customer'),
    'newCustomersThisMonth', (SELECT count(*) FROM public.users WHERE role = 'customer' AND created_at >= v_month),
    'days', (
      SELECT jsonb_agg(jsonb_build_object(
          'day', d.day::date,
          'deposits', count(o.id) FILTER (WHERE o.direction = 'deposit' AND m.kind <> 'platform'),
          'withdrawals', count(o.id) FILTER (WHERE o.direction = 'withdraw' AND m.kind <> 'platform'),
          'orders', count(o.id) FILTER (WHERE m.kind = 'platform'))
        ORDER BY d.day)
      FROM generate_series(v_day - 6, v_day, interval '1 day') AS d(day)
      LEFT JOIN public.orders o
        ON (o.created_at AT TIME ZONE 'Africa/Mogadishu')::date = d.day::date
      LEFT JOIN public.payment_methods m ON m.method = o.method
      GROUP BY d.day),
    'topServices', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('method', t.method, 'label', t.label, 'orders', t.n, 'amount', private.money(t.cents))
        ORDER BY t.n DESC, t.cents DESC)
      FROM (
        SELECT o.method, m.label, count(*) AS n, sum(o.amount_cents) AS cents
        FROM public.orders o JOIN public.payment_methods m ON m.method = o.method
        WHERE m.kind = 'platform' AND o.status = 'completed' AND o.created_at >= v_from AND o.created_at < v_to
        GROUP BY o.method, m.label ORDER BY n DESC, cents DESC LIMIT 5
      ) t), '[]'::jsonb),
    'topDepositMethods', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('method', t.method, 'label', t.label, 'count', t.n, 'amount', private.money(t.cents))
        ORDER BY t.cents DESC)
      FROM (
        SELECT o.method, m.label, count(*) AS n, sum(o.amount_cents) AS cents
        FROM public.orders o JOIN public.payment_methods m ON m.method = o.method
        WHERE m.kind <> 'platform' AND o.direction = 'deposit' AND o.status = 'completed'
          AND o.created_at >= v_from AND o.created_at < v_to
        GROUP BY o.method, m.label ORDER BY cents DESC LIMIT 5
      ) t), '[]'::jsonb)
  );
END
$$;

REVOKE ALL ON FUNCTION public.agent_dashboard_stats(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_dashboard_stats(date) TO authenticated, service_role;
