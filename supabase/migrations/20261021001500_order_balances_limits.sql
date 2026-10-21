-- Customer App transaction details and withdrawal form.
--
-- Orders now carry the wallet's available balance before and after them:
-- a completed deposit's credit, or a withdrawal's reservation (the moment
-- the money left the available balance). Orders that never moved the
-- balance (unpaid deposits, failed or cancelled withdrawals) have none.
--
-- Payment methods carry their withdrawal limits (minWithdraw/maxWithdraw),
-- which the server already enforces, so the form can show them up front.

CREATE OR REPLACE FUNCTION private.customer_order_json(o public.orders)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'status', o.status,
    'statusMessage', private.order_status_message(o.status),
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.amount_cents) END,
    'fee', private.money(o.fee_cents),
    'netAmount', CASE WHEN o.amount_unknown THEN '0.00' ELSE private.money(o.net_cents) END,
    'amountPending', o.amount_unknown,
    'transactionRef', o.transaction_ref,
    'failureReason', CASE WHEN o.status = 'failed' THEN o.failure_reason END,
    'balanceBefore', CASE WHEN b.after_cents IS NOT NULL THEN private.money(b.before_cents) END,
    'balanceAfter', CASE WHEN b.after_cents IS NOT NULL THEN private.money(b.after_cents) END,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
  FROM (SELECT NULL::int AS x) _
  LEFT JOIN LATERAL (
    SELECT l.balance_after_cents AS after_cents,
           CASE WHEN l.entry_type = 'credit' THEN l.balance_after_cents - l.amount_cents
                ELSE l.balance_after_cents + l.amount_cents END AS before_cents
    FROM public.ledger_entries l
    WHERE l.order_id = o.id
      AND ((o.direction = 'deposit' AND l.entry_type = 'credit')
        OR (o.direction = 'withdraw' AND l.entry_type = 'reserve' AND o.status NOT IN ('failed', 'cancelled')))
    ORDER BY l.created_at
    LIMIT 1
  ) b ON true
$$;

CREATE OR REPLACE FUNCTION public.customer_payment_methods()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'method', m.method, 'label', m.label, 'kind', m.kind, 'color', m.color, 'initials', m.initials,
      'depositNumbers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('number', n.number, 'label', n.label) ORDER BY n.created_at)
        FROM public.deposit_numbers n WHERE n.method = m.method AND n.enabled
      ), '[]'::jsonb),
      'minWithdraw', (SELECT private.money(l.min_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'maxWithdraw', (SELECT private.money(l.max_cents) FROM public.withdrawal_limits l WHERE l.method = m.method)
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m WHERE m.enabled
  ), '[]'::jsonb);
END
$$;
