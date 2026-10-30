-- Agent App Reports: Today / Yesterday / Last Month / All Time (and a custom
-- range), every section from the same completed orders.
--
--   revenue       the amount of the completed deposits and withdrawals of
--                 the period (what moved; fees are given apart). Pending,
--                 processing, failed, cancelled and expired orders are not
--                 revenue; each order counts once.
--   platforms     betting platforms ranked by that amount (then count);
--   methods       mobile money the same way: platforms + methods = revenue;
--   users         customers ranked the same way: their rows add up to it too;
--   transactions  the largest completed orders;
--   statuses      every order of the period by status (failed etc. shown
--                 apart, never in the revenue);
--   series        orders per day (ranges up to 62 days).
-- Days are Mogadishu days. Last Month is the last 30 days, today included.

CREATE OR REPLACE FUNCTION public.agent_report_overview(p_range text DEFAULT 'today', p_from text DEFAULT NULL, p_to text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_range text := COALESCE(p_range, 'today');
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_from date;
  v_to date;
  v_start timestamptz;
  v_end timestamptz;
BEGIN
  CASE v_range
    WHEN 'today' THEN v_from := v_today; v_to := v_today;
    WHEN 'yesterday' THEN v_from := v_today - 1; v_to := v_today - 1;
    WHEN 'last_month' THEN v_from := v_today - 29; v_to := v_today;
    WHEN 'all_time' THEN v_from := NULL; v_to := v_today;
    WHEN 'custom' THEN
      v_from := private.parse_date(p_from, 'from');
      v_to := private.parse_date(p_to, 'to');
      IF v_from IS NULL OR v_to IS NULL THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'from and to are required for a custom range');
      END IF;
      IF v_from > v_to THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'from must be on or before to');
      END IF;
    ELSE
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid range');
  END CASE;
  v_start := CASE WHEN v_from IS NULL THEN '-infinity'::timestamptz ELSE v_from::timestamp AT TIME ZONE 'Africa/Mogadishu' END;
  v_end := (v_to + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu';

  RETURN (
    WITH o AS (
      SELECT x.id, x.order_code, x.direction, x.method, x.status, x.customer_id, x.created_at, x.completed_at,
             CASE WHEN x.amount_unknown THEN 0 ELSE x.amount_cents END AS cents,
             CASE WHEN x.amount_unknown THEN 0 ELSE x.fee_cents END AS fee
      FROM public.orders x
      WHERE x.created_at >= v_start AND x.created_at < v_end
    ), c AS (SELECT * FROM o WHERE status = 'completed')
    SELECT jsonb_build_object(
      'range', v_range,
      'from', to_char(v_from, 'YYYY-MM-DD'),
      'to', to_char(v_to, 'YYYY-MM-DD'),
      'overview', (SELECT jsonb_build_object(
          'revenue', private.money(COALESCE(sum(cents), 0)),
          'transactions', count(*),
          'fees', private.money(COALESCE(sum(fee), 0)),
          'deposits', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'deposit'),
                        'total', private.money(COALESCE(sum(cents) FILTER (WHERE direction = 'deposit'), 0))),
          'withdrawals', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'withdraw'),
                        'total', private.money(COALESCE(sum(cents) FILTER (WHERE direction = 'withdraw'), 0))))
        FROM c),
      'platforms', COALESCE((SELECT jsonb_agg(jsonb_build_object('method', p.method, 'label', p.label, 'count', p.n,
            'total', private.money(p.total)) ORDER BY p.total DESC, p.n DESC, p.label)
          FROM (SELECT c.method, m.label, count(*) AS n, sum(c.cents) AS total
                FROM c JOIN public.payment_methods m ON m.method = c.method
                WHERE m.kind = 'platform' GROUP BY c.method, m.label) p), '[]'::jsonb),
      'methods', COALESCE((SELECT jsonb_agg(jsonb_build_object('method', p.method, 'label', p.label, 'count', p.n,
            'total', private.money(p.total)) ORDER BY p.total DESC, p.n DESC, p.label)
          FROM (SELECT c.method, m.label, count(*) AS n, sum(c.cents) AS total
                FROM c JOIN public.payment_methods m ON m.method = c.method
                WHERE m.kind <> 'platform' GROUP BY c.method, m.label) p), '[]'::jsonb),
      'users', COALESCE((SELECT jsonb_agg(jsonb_build_object('customerId', q.customer_id, 'name', q.name, 'phone', q.phone,
            'count', q.n, 'total', private.money(q.total)) ORDER BY q.total DESC, q.n DESC, q.phone)
          FROM (SELECT c.customer_id, u.name, u.phone, count(*) AS n, sum(c.cents) AS total
                FROM c JOIN public.users u ON u.id = c.customer_id
                GROUP BY c.customer_id, u.name, u.phone ORDER BY sum(c.cents) DESC, count(*) DESC LIMIT 20) q), '[]'::jsonb),
      'usersCount', (SELECT count(DISTINCT customer_id) FROM c),
      'transactions', COALESCE((SELECT jsonb_agg(jsonb_build_object('orderCode', t.order_code, 'method', t.method,
            'label', m.label, 'direction', t.direction, 'amount', private.money(t.cents),
            'customerName', u.name, 'customerPhone', u.phone, 'completedAt', t.completed_at)
            ORDER BY t.cents DESC, t.completed_at DESC)
          FROM (SELECT * FROM c ORDER BY cents DESC, completed_at DESC LIMIT 10) t
          JOIN public.users u ON u.id = t.customer_id
          JOIN public.payment_methods m ON m.method = t.method), '[]'::jsonb),
      'statuses', (SELECT jsonb_object_agg(s.status, jsonb_build_object('count', s.n, 'total', private.money(s.total)))
          FROM (SELECT status::text AS status, count(*) AS n, COALESCE(sum(cents), 0) AS total FROM o GROUP BY status) s),
      'series', CASE WHEN v_from IS NOT NULL AND v_to - v_from <= 61 THEN (
          SELECT COALESCE(jsonb_agg(jsonb_build_object('date', to_char(g::date, 'YYYY-MM-DD'),
                   'deposits', (SELECT count(*) FROM c WHERE c.direction = 'deposit'
                                  AND (c.created_at AT TIME ZONE 'Africa/Mogadishu')::date = g::date),
                   'withdrawals', (SELECT count(*) FROM c WHERE c.direction = 'withdraw'
                                  AND (c.created_at AT TIME ZONE 'Africa/Mogadishu')::date = g::date),
                   'orders', (SELECT count(*) FROM o WHERE (o.created_at AT TIME ZONE 'Africa/Mogadishu')::date = g::date))
                 ORDER BY g), '[]'::jsonb)
          FROM generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g) END,
      'generatedAt', now())
  );
END $$;

REVOKE ALL ON FUNCTION public.agent_report_overview(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_report_overview(text, text, text) TO authenticated;
