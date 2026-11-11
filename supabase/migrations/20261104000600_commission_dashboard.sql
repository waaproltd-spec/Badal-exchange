-- Commission dashboard: complete calendar months, the trend, and the top companies and agents.
--
-- agent_commission (20261028001400) keeps its arguments and everything it returned; this adds:
--   * ranges that are whole calendar months in Mogadishu time, so they roll over by themselves
--     when a month begins:  this_month  = the 1st .. the last day of the current month;
--                           last_month  = the previous month, complete;
--                           last_3_months = the three complete months before this one
--                           (Aug 1 - Oct 31 in November).
--     last_6_months and last_1_year stay rolling, as before.
--   * series: the transactions per day (up to a month), per week (up to six months) or per month,
--     deposits and withdrawals apart, from the same commission entries as the totals;
--   * topCompanies and topAgents: ranked by net commission in the period, with the same company /
--     agent filters (an agent only ever sees their own row).
-- Nothing is calculated twice: every figure comes from commission_entries, the rows written once when
-- an order completes (rates, bonus and eligibility as they have always been), by their completion date.

CREATE OR REPLACE FUNCTION public.agent_commission(
  p_range text DEFAULT 'today', p_from text DEFAULT NULL, p_to text DEFAULT NULL,
  p_method text DEFAULT NULL, p_agent text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_manager boolean := private.can_manage();
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_from date;
  v_to date := v_today;
  v_start timestamptz;
  v_end timestamptz;
  v_method public.order_method;
  v_scope text;      -- 'all' | 'automatic' | 'agent'
  v_agent uuid;
  v_s_from date;     -- the trend chart: first and last day, and how it is grouped
  v_s_to date;
  v_unit text;
BEGIN
  CASE COALESCE(p_range, 'today')
    WHEN 'today' THEN v_from := v_today;
    WHEN 'yesterday' THEN v_from := v_today - 1; v_to := v_today - 1;
    -- The whole current calendar month (Nov 1 - Nov 30), whatever day it is.
    WHEN 'this_month' THEN
      v_from := date_trunc('month', v_today)::date;
      v_to := (date_trunc('month', v_today) + interval '1 month - 1 day')::date;
    -- The whole previous calendar month (Oct 1 - Oct 31).
    WHEN 'last_month' THEN
      v_from := date_trunc('month', v_today - interval '1 month')::date;
      v_to := (date_trunc('month', v_today) - interval '1 day')::date;
    -- The three complete calendar months before this one (Aug 1 - Oct 31).
    WHEN 'last_3_months' THEN
      v_from := date_trunc('month', v_today - interval '3 months')::date;
      v_to := (date_trunc('month', v_today) - interval '1 day')::date;
    WHEN 'last_6_months' THEN v_from := (v_today - interval '6 months')::date + 1;
    WHEN 'last_1_year' THEN v_from := (v_today - interval '1 year')::date + 1;
    WHEN 'all_time' THEN v_from := NULL;
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

  IF NULLIF(btrim(COALESCE(p_method, '')), '') IS NOT NULL THEN
    v_method := private.parse_method(p_method);
    IF NOT EXISTS (SELECT 1 FROM public.payment_methods WHERE method = v_method AND kind = 'platform') THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Not a betting company');
    END IF;
  END IF;

  IF NOT v_manager THEN
    v_scope := 'agent'; v_agent := v_id;          -- an agent: only their own, whatever was asked
  ELSIF NULLIF(btrim(COALESCE(p_agent, '')), '') IS NULL THEN
    v_scope := 'all';
  ELSIF p_agent = 'automatic' THEN
    v_scope := 'automatic';
  ELSE
    BEGIN
      v_agent := p_agent::uuid;
    EXCEPTION WHEN others THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid agent');
    END;
    v_scope := 'agent';
  END IF;

  -- The trend: daily for up to a month, weekly up to six months, monthly beyond. All time starts at the first commission.
  v_s_to := LEAST(v_to, v_today);
  v_s_from := COALESCE(v_from, (SELECT min((c.completed_at AT TIME ZONE 'Africa/Mogadishu')::date) FROM public.commission_entries c
      WHERE (v_method IS NULL OR c.method = v_method)
        AND (v_scope = 'all' OR (v_scope = 'automatic' AND c.agent_id IS NULL) OR (v_scope = 'agent' AND c.agent_id = v_agent))), v_s_to);
  IF v_s_from > v_s_to THEN v_s_from := v_s_to; END IF;
  v_unit := CASE WHEN v_s_to - v_s_from + 1 <= 31 THEN 'day' WHEN v_s_to - v_s_from + 1 <= 186 THEN 'week' ELSE 'month' END;

  RETURN (
    WITH e AS (
      SELECT c.* FROM public.commission_entries c
      WHERE c.completed_at >= v_start AND c.completed_at < v_end
        AND (v_method IS NULL OR c.method = v_method)
        AND (v_scope = 'all' OR (v_scope = 'automatic' AND c.agent_id IS NULL) OR (v_scope = 'agent' AND c.agent_id = v_agent))
    ), t AS (
      -- The list: every platform order of the period, completed or not (only completed ones earn).
      SELECT o.id, o.order_code, o.method, o.direction, o.status, o.created_at, o.completed_at,
             CASE WHEN o.amount_unknown THEN NULL ELSE o.amount_cents END AS cents, c.gross_micros, c.bonus_micros, c.net_micros,
             COALESCE(c.completed_at, o.created_at) AS at
      FROM public.orders o
      JOIN public.payment_methods m ON m.method = o.method AND m.kind = 'platform'
      LEFT JOIN public.commission_entries c ON c.order_id = o.id
      WHERE COALESCE(c.completed_at, o.created_at) >= v_start AND COALESCE(c.completed_at, o.created_at) < v_end
        AND (v_method IS NULL OR o.method = v_method)
        AND (v_scope = 'all' OR (v_scope = 'automatic' AND o.agent_id IS NULL) OR (v_scope = 'agent' AND o.agent_id = v_agent))
      ORDER BY COALESCE(c.completed_at, o.created_at) DESC
      LIMIT 200
    ), s AS (
      SELECT date_trunc(v_unit, e.completed_at AT TIME ZONE 'Africa/Mogadishu')::date AS start,
             count(*) FILTER (WHERE e.direction = 'deposit') AS dep_n, count(*) FILTER (WHERE e.direction = 'withdraw') AS wd_n,
             COALESCE(sum(e.amount_cents) FILTER (WHERE e.direction = 'deposit'), 0) AS dep_cents,
             COALESCE(sum(e.amount_cents) FILTER (WHERE e.direction = 'withdraw'), 0) AS wd_cents,
             COALESCE(sum(e.net_micros), 0) AS net
      FROM e GROUP BY 1
    )
    SELECT jsonb_build_object(
      'range', COALESCE(p_range, 'today'), 'from', to_char(v_from, 'YYYY-MM-DD'), 'to', to_char(v_to, 'YYYY-MM-DD'),
      'method', v_method, 'scope', v_scope, 'agentId', v_agent, 'canSeeAll', v_manager,
      'rates', jsonb_build_object('depositBp', private.commission_bp('commission:deposit_bp', 200),
                                  'withdrawBp', private.commission_bp('commission:withdraw_bp', 500),
                                  'bonusBp', private.commission_bp('commission:bonus_bp', 100)),
      'summary', (SELECT jsonb_build_object(
          'deposit', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'deposit'),
                       'total', private.money(COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit'), 0)),
                       'commission', private.money_micros(COALESCE(sum(net_micros) FILTER (WHERE direction = 'deposit'), 0)::bigint)),
          'withdrawal', jsonb_build_object('count', count(*) FILTER (WHERE direction = 'withdraw'),
                       'total', private.money(COALESCE(sum(amount_cents) FILTER (WHERE direction = 'withdraw'), 0)),
                       'grossCommission', private.money_micros(COALESCE(sum(gross_micros) FILTER (WHERE direction = 'withdraw'), 0)::bigint),
                       'commission', private.money_micros(COALESCE(sum(net_micros) FILTER (WHERE direction = 'withdraw'), 0)::bigint)),
          'grossCommission', private.money_micros(COALESCE(sum(gross_micros), 0)::bigint),
          'bonus', private.money_micros(COALESCE(sum(bonus_micros), 0)::bigint),
          'commission', private.money_micros(COALESCE(sum(net_micros), 0)::bigint),
          'transactions', count(*))
        FROM e),
      -- Every company; a removed one stays while it has commission (its history adds up in All Companies).
      'companies', COALESCE((SELECT jsonb_agg(jsonb_build_object('method', x.method, 'label', x.label, 'removed', x.removed)
                                ORDER BY x.removed, x.sort_order)
          FROM (SELECT m.method, m.sort_order,
                       EXISTS (SELECT 1 FROM public.payment_integrations i
                               WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL) AS removed,
                       m.label || CASE WHEN EXISTS (SELECT 1 FROM public.payment_integrations i
                               WHERE i.kind = 'betting' AND i.method_key = m.method::text AND i.deleted_at IS NOT NULL)
                               THEN ' (removed)' ELSE '' END AS label
                FROM public.payment_methods m WHERE m.kind = 'platform') x
          WHERE NOT x.removed OR EXISTS (SELECT 1 FROM public.commission_entries c WHERE c.method = x.method)), '[]'::jsonb),
      'agents', CASE WHEN v_manager THEN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', u.id, 'name', u.name, 'phone', u.phone) ORDER BY u.name)
          FROM public.users u WHERE u.role IN ('agent', 'admin')
            AND NOT EXISTS (SELECT 1 FROM public.agent_profiles p WHERE p.user_id = u.id AND p.deleted_at IS NOT NULL)), '[]'::jsonb) END,
      'transactions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'orderCode', t.order_code, 'method', t.method, 'label', m.label, 'direction', t.direction, 'status', t.status,
            'amount', CASE WHEN t.cents IS NOT NULL THEN private.money(t.cents) END,
            'commission', CASE WHEN t.gross_micros IS NOT NULL THEN private.money_micros(t.gross_micros) END,
            'bonus', CASE WHEN t.bonus_micros IS NOT NULL THEN private.money_micros(t.bonus_micros) END,
            'netCommission', CASE WHEN t.net_micros IS NOT NULL THEN private.money_micros(t.net_micros) END,
            'at', t.at) ORDER BY t.at DESC)
          FROM t JOIN public.payment_methods m ON m.method = t.method), '[]'::jsonb),
      'series', jsonb_build_object('granularity', v_unit, 'from', to_char(v_s_from, 'YYYY-MM-DD'), 'to', to_char(v_s_to, 'YYYY-MM-DD'),
        'points', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'start', to_char(b.start, 'YYYY-MM-DD'),
            'deposits', COALESCE(s.dep_n, 0), 'withdrawals', COALESCE(s.wd_n, 0), 'transactions', COALESCE(s.dep_n, 0) + COALESCE(s.wd_n, 0),
            'depositAmount', private.money(COALESCE(s.dep_cents, 0)), 'withdrawalAmount', private.money(COALESCE(s.wd_cents, 0)),
            'commission', private.money_micros(COALESCE(s.net, 0)::bigint)) ORDER BY b.start)
          FROM (SELECT generate_series(date_trunc(v_unit, v_s_from::timestamp),
                                        v_s_to::timestamp,
                                        CASE v_unit WHEN 'day' THEN interval '1 day' WHEN 'week' THEN interval '1 week' ELSE interval '1 month' END)::date AS start) b
          LEFT JOIN s ON s.start = b.start), '[]'::jsonb)),
      -- Companies and agents ranked by their net commission in this period (the same filters as the totals).
      'topCompanies', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'method', x.method, 'label', m.label, 'transactions', x.n, 'deposits', x.dn, 'withdrawals', x.wn,
            'amount', private.money(x.cents), 'commission', private.money_micros(x.net::bigint))
            ORDER BY x.net DESC, x.n DESC, m.label)
          FROM (SELECT e.method, count(*) AS n, count(*) FILTER (WHERE e.direction = 'deposit') AS dn,
                       count(*) FILTER (WHERE e.direction = 'withdraw') AS wn, COALESCE(sum(e.amount_cents), 0) AS cents,
                       COALESCE(sum(e.net_micros), 0) AS net FROM e GROUP BY e.method) x
          JOIN public.payment_methods m ON m.method = x.method), '[]'::jsonb),
      'topAgents', COALESCE((SELECT jsonb_agg(jsonb_build_object(
            'id', x.agent_id, 'name', u.name, 'phone', u.phone, 'automatic', x.agent_id IS NULL, 'transactions', x.n,
            'amount', private.money(x.cents), 'commission', private.money_micros(x.net::bigint))
            ORDER BY x.net DESC, x.n DESC, u.name NULLS LAST)
          FROM (SELECT e.agent_id, count(*) AS n, COALESCE(sum(e.amount_cents), 0) AS cents, COALESCE(sum(e.net_micros), 0) AS net
                FROM e GROUP BY e.agent_id) x
          LEFT JOIN public.users u ON u.id = x.agent_id), '[]'::jsonb),
      'generatedAt', now())
  );
END $$;

REVOKE ALL ON FUNCTION public.agent_commission(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_commission(text, text, text, text, text) TO authenticated;
