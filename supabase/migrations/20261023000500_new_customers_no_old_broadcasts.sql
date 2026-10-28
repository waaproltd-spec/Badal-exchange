-- A new customer's Notifications list starts when they joined: general
-- messages sent before their account was created are not shown to them.
-- Their own deposit/withdrawal messages are listed as before.
CREATE OR REPLACE FUNCTION public.customer_notifications()
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
    SELECT jsonb_agg(x.j ORDER BY x.at DESC)
    FROM (
      SELECT * FROM (
        SELECT private.notification_json(n) AS j, n.created_at AS at
        FROM public.notifications n
        WHERE n.created_at >= (SELECT created_at FROM public.users WHERE id = v_id)
        UNION ALL
        SELECT jsonb_build_object(
                 'id', p.id,
                 'title', CASE p.kind WHEN 'deposit_completed' THEN 'Deposit-kaagu wuu guulaystay'
                                      ELSE 'Withdrawal-kaagu wuu guulaystay' END,
                 'body', CASE p.kind WHEN 'deposit_completed' THEN 'Lacagta deposit-kaaga si guul leh ayaa loo xaqiijiyey.'
                                     ELSE 'Lacagtaada si guul leh ayaa loo bixiyey.' END
                         || format(' $%s · %s · %s', private.money(o.net_cents),
                                   COALESCE((SELECT m.label FROM public.payment_methods m WHERE m.method = o.method), o.method::text),
                                   o.order_code),
                 'createdAt', p.created_at),
               p.created_at
        FROM public.push_notifications p
        JOIN public.orders o ON o.id = p.order_id
        WHERE p.customer_id = v_id
      ) u
      ORDER BY u.at DESC
      LIMIT 50
    ) x(j, at)
  ), '[]'::jsonb);
END
$$;
