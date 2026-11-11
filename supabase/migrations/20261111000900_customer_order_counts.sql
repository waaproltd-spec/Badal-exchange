-- Customer App, Dalabaadka: the totals on the summary cards come from the database, and the list can be read page by page.
--
--   customer_order_counts()  -> {total, deposits, withdrawals}, counted in ONE pass over the customer's own orders with exactly the rule
--                               the list uses (a withdrawal always; a deposit once completed). Every order has one direction, so
--                               total = deposits + withdrawals by construction, and the cards always match the list.
--   customer_orders(p_limit, p_offset, p_direction) -> the same rows as before (newest first), 100 by default; the app reads further
--                               pages when the customer scrolls (before, only the newest 100 were ever reachable).
-- Both use idx_orders_customer (customer_id, created_at DESC); they read only. No order, wallet or payment function is touched.
CREATE OR REPLACE FUNCTION public.customer_order_counts()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_dep bigint;
  v_wd bigint;
BEGIN
  SELECT count(*) FILTER (WHERE direction = 'deposit'), count(*) FILTER (WHERE direction = 'withdraw')
    INTO v_dep, v_wd
    FROM public.orders
   WHERE customer_id = v_id AND (direction <> 'deposit' OR status = 'completed');
  RETURN jsonb_build_object('total', v_dep + v_wd, 'deposits', v_dep, 'withdrawals', v_wd);
END $$;

DROP FUNCTION IF EXISTS public.customer_orders();
CREATE OR REPLACE FUNCTION public.customer_orders(p_limit int DEFAULT 100, p_offset int DEFAULT 0, p_direction text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  IF p_direction IS NOT NULL AND p_direction NOT IN ('deposit', 'withdraw') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'direction must be deposit or withdraw');
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(private.customer_order_json(o) ORDER BY o.created_at DESC, o.id)
    FROM (SELECT * FROM public.orders
          WHERE customer_id = v_id AND (direction <> 'deposit' OR status = 'completed')
            AND (p_direction IS NULL OR direction::text = p_direction)
          ORDER BY created_at DESC, id
          LIMIT GREATEST(1, LEAST(COALESCE(p_limit, 100), 200)) OFFSET GREATEST(0, COALESCE(p_offset, 0))) o
  ), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.customer_order_counts(), public.customer_orders(int, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_order_counts(), public.customer_orders(int, int, text) TO authenticated;
