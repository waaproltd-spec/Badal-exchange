-- Customers saw the agents' working note on an open order, e.g. "Payout
-- ambiguous after the PIN: No final confirmation received after entering
-- the PIN." on an EVC withdrawal still being processed. The failure reason
-- is now shown to the customer only once the order has failed; agents still
-- see it everywhere (Automatic Payouts, order details).

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
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;
