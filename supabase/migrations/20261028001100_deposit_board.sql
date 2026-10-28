-- Agent App "Lacagaha Sugaya Xaqiijinta" (deposits waiting to be confirmed):
-- the summary at the top, the deposits of a period with the customer's
-- name and how long each has waited, and a way to reject one.
--
-- Unpaid mobile-money deposits already expire by themselves
-- (private.expire_unpaid_deposits: 30 minutes, 24 hours through a merchant
-- code), so "expired" counts those of the period instead of a 48-hour rule.

-- Deposits of [p_from, p_to): waiting ones, and those that expired unpaid.
CREATE OR REPLACE FUNCTION public.agent_deposit_board(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu');
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
BEGIN
  IF v_to <= v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period must end after it starts');
  END IF;
  RETURN jsonb_build_object(
    'summary', jsonb_build_object(
      -- Waiting now (any age), and their total.
      'pendingCount', (SELECT count(*) FROM public.orders WHERE direction = 'deposit' AND status = 'pending'),
      'pendingCustomers', (SELECT count(DISTINCT customer_id) FROM public.orders WHERE direction = 'deposit' AND status = 'pending'),
      'pendingTotal', private.money(COALESCE((SELECT sum(amount_cents) FROM public.orders
                        WHERE direction = 'deposit' AND status = 'pending' AND NOT amount_unknown), 0)),
      'expiredCount', (SELECT count(*) FROM public.orders WHERE direction = 'deposit' AND status = 'expired'
                        AND updated_at >= v_from AND updated_at < v_to),
      'newCount', (SELECT count(*) FROM public.orders WHERE direction = 'deposit' AND created_at >= now() - interval '24 hours')),
    'deposits', COALESCE((
      SELECT jsonb_agg(private.agent_order_json(o) || jsonb_build_object(
               'customerName', u.name, 'customerPhone', u.phone,
               'waitingSeconds', floor(extract(epoch FROM COALESCE(CASE WHEN o.status = 'expired' THEN o.updated_at END, now()) - o.created_at))::int,
               'failureReason', o.failure_reason)
             ORDER BY o.status = 'pending' DESC, o.created_at DESC)
      FROM (SELECT * FROM public.orders x
            WHERE x.direction = 'deposit'
              AND (x.status = 'pending' OR (x.status = 'expired' AND x.created_at >= v_from AND x.created_at < v_to))
            ORDER BY x.created_at DESC LIMIT 300) o
      JOIN public.users u ON u.id = o.customer_id), '[]'::jsonb),
    'from', v_from, 'to', v_to, 'generatedAt', now());
END $$;

-- "Diid": a waiting deposit the customer did not pay (or paid wrongly) is
-- closed with a reason. Nothing was credited, so no money moves.
CREATE OR REPLACE FUNCTION public.agent_reject_deposit(p_order_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  o public.orders;
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  o := private.lock_order(p_order_id);
  IF o.id IS NULL OR o.direction <> 'deposit' THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Deposit not found');
  END IF;
  IF o.status <> 'pending' THEN
    PERFORM private.raise_api(409, 'NOT_PENDING', 'Only a waiting deposit can be rejected');
  END IF;
  UPDATE public.orders SET status = 'cancelled', failure_reason = left(btrim(p_reason), 300), updated_at = now()
  WHERE id = o.id RETURNING * INTO o;
  PERFORM private.order_audit(o.id, 'deposit_rejected', jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', 'cancelled', 'reason', o.failure_reason), v_id);
  RETURN private.agent_order_json(o);
END $$;

REVOKE ALL ON FUNCTION public.agent_deposit_board(timestamptz, timestamptz), public.agent_reject_deposit(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_deposit_board(timestamptz, timestamptz), public.agent_reject_deposit(uuid, text) TO authenticated;
