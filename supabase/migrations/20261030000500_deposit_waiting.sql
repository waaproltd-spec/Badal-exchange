-- Deposits: nothing appears as an order to the customer until the payment is
-- verified.
--
-- The matching of a payment to its deposit (the Sahal feed, the payment SMS,
-- the betting-platform cash desks) keeps the record it has always matched
-- against: it holds the amount and the customer, takes nothing, credits nothing
-- and is never shown to the customer as an order. The customer waits on the
-- "payment is being verified" screen, which follows that record; the order
-- shows in the customer's lists only once it is completed (credited once,
-- by the same functions as before, with the same references).
-- A deposit that fails (the platform refuses, an error, an agent rejects it)
-- is not shown as an order either; the admin's Telegram chat is told.

-- The customer's list: deposits only when completed; withdrawals as before.
CREATE OR REPLACE FUNCTION public.customer_orders()
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
    SELECT jsonb_agg(private.customer_order_json(o) ORDER BY o.created_at DESC)
    FROM (SELECT * FROM public.orders
          WHERE customer_id = v_id AND (direction <> 'deposit' OR status = 'completed')
          ORDER BY created_at DESC LIMIT 100) o
  ), '[]'::jsonb);
END
$$;

-- Failed or unverified deposits, and failed platform withdrawals, to the admin's Telegram.
-- (Mobile-money withdrawals already have their own alert that is edited to "Failed".)
CREATE OR REPLACE FUNCTION private.order_incident()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_kind text;
BEGIN
  IF NEW.direction = 'deposit' THEN
    IF (NEW.status = 'failed' OR (NEW.status = 'cancelled' AND NEW.failure_reason IS NOT NULL))
       AND OLD.status IS DISTINCT FROM NEW.status THEN
      -- (A deposit an agent rejects is cancelled with its reason.)
      v_kind := 'failed';
    ELSIF NEW.status IN ('pending', 'processing') AND NEW.failure_reason IS NOT NULL
          AND NEW.failure_reason IS DISTINCT FROM OLD.failure_reason THEN
      -- The platform or the payment service gave no clear answer: nothing is credited.
      v_kind := 'unverified';
    END IF;
  ELSIF NEW.direction = 'withdraw' AND NEW.status = 'failed' AND OLD.status IS DISTINCT FROM 'failed'
        AND NOT private.is_mobile_money(NEW.method) THEN
    v_kind := 'failed';
  END IF;
  IF v_kind IS NOT NULL THEN
    INSERT INTO public.payment_incidents (direction, kind, customer_id, order_code, method, amount_text, error_code, error_text, source)
    VALUES (NEW.direction::text, v_kind, NEW.customer_id, NEW.order_code, NEW.method::text, private.money(NEW.amount_cents),
            'ORDER_' || upper(v_kind), left(NEW.failure_reason, 300), 'server');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.order_incident() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS orders_incident ON public.orders;
CREATE TRIGGER orders_incident AFTER UPDATE OF status, failure_reason ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.order_incident();
