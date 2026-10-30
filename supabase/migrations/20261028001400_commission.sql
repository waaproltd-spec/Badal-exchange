-- Commission (Agent App -> Commission, its own screen; Reports unchanged).
--
-- On every completed betting-platform order (1XBET, MELBET, BETWINNER,
-- WINWIN, 888STARZ, DBbet, BetOnGame, ... any payment method of kind
-- 'platform', added ones included), Badal Exchange earns:
--   deposit      2% of the amount                       ($1,000 -> $20)
--   withdrawal   5% gross, less a 1% bonus = 4% net     ($1,000 -> $50 - $10 = $40)
-- The bonus comes off the commission, never off the customer's amount: no
-- wallet, ledger or order is changed here.
--
-- Each completed order gets exactly one commission_entries row (its order
-- id is the key), with the rates of that moment, written when the order
-- completes; an order that leaves 'completed' loses it. Failed, rejected,
-- cancelled, expired, pending and processing orders earn nothing. Amounts
-- are kept in micro-dollars ($0.30 deposit -> $0.006), so nothing is lost
-- to rounding; totals are rounded only when shown.
--
-- Who sees what: an agent sees the orders they handled (orders.agent_id);
-- a manager sees everything (orders done automatically included), one
-- agent, or only the automatic ones.

INSERT INTO public.app_settings (key, value) VALUES
  ('commission:deposit_bp', '200'), ('commission:withdraw_bp', '500'), ('commission:bonus_bp', '100')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.commission_entries (
  order_id      UUID PRIMARY KEY REFERENCES public.orders(id) ON DELETE CASCADE,
  agent_id      UUID REFERENCES public.users(id) ON DELETE SET NULL,
  method        public.order_method NOT NULL,
  direction     TEXT NOT NULL CHECK (direction IN ('deposit', 'withdraw')),
  amount_cents  BIGINT NOT NULL CHECK (amount_cents >= 0),
  rate_bp       INT NOT NULL,
  bonus_bp      INT NOT NULL,
  gross_micros  BIGINT NOT NULL,
  bonus_micros  BIGINT NOT NULL,
  net_micros    BIGINT NOT NULL,
  completed_at  TIMESTAMPTZ NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS commission_entries_completed ON public.commission_entries (completed_at DESC);
CREATE INDEX IF NOT EXISTS commission_entries_agent ON public.commission_entries (agent_id, completed_at DESC);
ALTER TABLE public.commission_entries ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.commission_entries FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.commission_bp(p_key text, p_default int)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT NULLIF(btrim(value), '')::int FROM public.app_settings WHERE key = p_key AND btrim(value) ~ '^\d{1,4}$'), p_default)
$$;

-- The order's commission, once: written when it is completed (and is a
-- betting platform's), removed if it stops being completed.
CREATE OR REPLACE FUNCTION private.commission_for(o public.orders)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_rate int;
  v_bonus int := 0;
  v_cents bigint := CASE WHEN o.amount_unknown THEN 0 ELSE o.amount_cents END;
BEGIN
  IF o.status <> 'completed' THEN
    DELETE FROM public.commission_entries WHERE order_id = o.id;
    RETURN;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.payment_methods m WHERE m.method = o.method AND m.kind = 'platform') THEN
    RETURN;
  END IF;
  IF o.direction = 'deposit' THEN
    v_rate := private.commission_bp('commission:deposit_bp', 200);
  ELSE
    v_rate := private.commission_bp('commission:withdraw_bp', 500);
    v_bonus := private.commission_bp('commission:bonus_bp', 100);
  END IF;
  -- cents * bp = micro-dollars: $1,000 (100000 cents) * 200 bp = 20,000,000 = $20.
  INSERT INTO public.commission_entries (order_id, agent_id, method, direction, amount_cents, rate_bp, bonus_bp,
                                         gross_micros, bonus_micros, net_micros, completed_at)
  VALUES (o.id, o.agent_id, o.method, o.direction::text, v_cents, v_rate, v_bonus,
          v_cents * v_rate, v_cents * v_bonus, v_cents * (v_rate - v_bonus), COALESCE(o.completed_at, now()))
  ON CONFLICT (order_id) DO UPDATE SET
    -- The amount of a code-only deposit may be learnt after it completed; the rates stay as first written.
    amount_cents = EXCLUDED.amount_cents,
    gross_micros = EXCLUDED.amount_cents * commission_entries.rate_bp,
    bonus_micros = EXCLUDED.amount_cents * commission_entries.bonus_bp,
    net_micros = EXCLUDED.amount_cents * (commission_entries.rate_bp - commission_entries.bonus_bp),
    agent_id = EXCLUDED.agent_id
  WHERE commission_entries.amount_cents IS DISTINCT FROM EXCLUDED.amount_cents
     OR commission_entries.agent_id IS DISTINCT FROM EXCLUDED.agent_id;
END $$;

CREATE OR REPLACE FUNCTION private.orders_commission()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' AND NEW.status <> 'completed' THEN
    RETURN NULL;
  END IF;
  PERFORM private.commission_for(NEW);
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- Never stands in the way of the order itself.
  RAISE WARNING 'orders_commission: %', SQLERRM;
  RETURN NULL;
END $$;
DROP TRIGGER IF EXISTS orders_commission_insert ON public.orders;
CREATE TRIGGER orders_commission_insert AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.orders_commission();
DROP TRIGGER IF EXISTS orders_commission_update ON public.orders;
CREATE TRIGGER orders_commission_update AFTER UPDATE OF status, amount_cents, amount_unknown, agent_id ON public.orders
  FOR EACH ROW WHEN (OLD.status IS DISTINCT FROM NEW.status OR NEW.status = 'completed')
  EXECUTE FUNCTION private.orders_commission();
REVOKE ALL ON FUNCTION private.commission_for(public.orders), private.orders_commission(),
  private.commission_bp(text, int) FROM PUBLIC, anon, authenticated;

-- The completed platform orders so far.
DO $do$
DECLARE o public.orders;
BEGIN
  FOR o IN SELECT x.* FROM public.orders x JOIN public.payment_methods m ON m.method = x.method AND m.kind = 'platform'
           WHERE x.status = 'completed' LOOP
    PERFORM private.commission_for(o);
  END LOOP;
END
$do$;

-- The Commission screen. p_range: today | yesterday | this_month |
-- last_3_months | last_6_months | last_1_year | all_time | custom (p_from,
-- p_to YYYY-MM-DD), Mogadishu days. p_method: one company, NULL for all.
-- p_agent: managers only -- an agent's id, 'automatic' (no agent), NULL for
-- everyone; for anyone else it is always themselves.
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
BEGIN
  CASE COALESCE(p_range, 'today')
    WHEN 'today' THEN v_from := v_today;
    WHEN 'yesterday' THEN v_from := v_today - 1; v_to := v_today - 1;
    WHEN 'this_month' THEN v_from := date_trunc('month', v_today)::date;
    WHEN 'last_3_months' THEN v_from := (v_today - interval '3 months')::date + 1;
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
      'generatedAt', now())
  );
END $$;

REVOKE ALL ON FUNCTION public.agent_commission(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_commission(text, text, text, text, text) TO authenticated;
