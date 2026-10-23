-- The Customer App's Notifications list showed only the broadcasts, not
-- the customer's own "deposit / withdrawal completed" messages (sent as
-- phone notifications only). They are now listed too, with the same title
-- and text as the phone notification plus the amount, method and order
-- code, newest first with the broadcasts (50 in all).
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
