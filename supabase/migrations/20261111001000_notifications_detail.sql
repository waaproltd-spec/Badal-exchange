-- Customer App, Ogeysiisyo: every notification now carries what the card shows (kind, status, amount, the other person, Wallet ID,
-- reference, the balance after, the provider) and the list is read page by page.
--
--   customer_notifications(p_limit int DEFAULT 30, p_before timestamptz DEFAULT NULL)
--     newest first; the next page is "older than the last createdAt received". Each row appears once (the sources are unique:
--     one push row per order and kind, one per transfer and side, one notification row per broadcast).
--   Added fields (the old id, title, body, createdAt are unchanged and still sent, so an older app keeps working):
--     kind         broadcast | deposit | withdraw | transfer_sent | transfer_received
--     status       completed   (only completed money movements are notified today; the app also draws failed and pending)
--     amount, method (label), reference, transactionRef, balanceAfter, counterpartName, counterpartWalletId
-- Read only: no order, wallet, ledger or push row is changed. The wording of title and body is as before.
CREATE INDEX IF NOT EXISTS idx_push_notifications_customer ON public.push_notifications (customer_id, created_at DESC);

DROP FUNCTION IF EXISTS public.customer_notifications();
CREATE OR REPLACE FUNCTION public.customer_notifications(p_limit int DEFAULT 30, p_before timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_since timestamptz := (SELECT created_at FROM public.users WHERE id = v_id);
  v_before timestamptz := COALESCE(p_before, 'infinity'::timestamptz);
  v_limit int := GREATEST(1, LEAST(COALESCE(p_limit, 30), 50));
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(x.j ORDER BY x.at DESC)
    FROM (
      SELECT * FROM (
        SELECT private.notification_json(n) || jsonb_build_object('kind', 'broadcast') AS j, n.created_at AS at
        FROM public.notifications n
        WHERE n.created_at >= v_since AND n.created_at < v_before
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
                 'createdAt', p.created_at,
                 'kind', CASE p.kind WHEN 'deposit_completed' THEN 'deposit' ELSE 'withdraw' END,
                 'status', 'completed',
                 'amount', private.money(o.net_cents),
                 'method', COALESCE((SELECT m.label FROM public.payment_methods m WHERE m.method = o.method), o.method::text),
                 'reference', o.order_code,
                 'transactionRef', o.transaction_ref,
                 'balanceAfter', private.customer_order_json(o) ->> 'balanceAfter'),
               p.created_at
        FROM public.push_notifications p
        JOIN public.orders o ON o.id = p.order_id
        WHERE p.customer_id = v_id AND p.created_at < v_before
        UNION ALL
        SELECT jsonb_build_object(
                 'id', p.id,
                 'title', CASE p.kind WHEN 'transfer_sent' THEN 'Lacag ayaad dirtay' ELSE 'Lacag ayaa laguu soo diray' END,
                 'body', CASE p.kind WHEN 'transfer_sent' THEN format('Waxaad u dirtay %s $%s (%s). Khidmad ma jirto. Haraagaaga: $%s · %s',
                                                                        c.name, private.money(t.amount_cents), cw.wallet_code, private.money(t.from_balance_after), t.reference)
                                     ELSE format('%s (%s) ayaa kuu soo diray $%s. Haraagaaga: $%s · %s',
                                                 c.name, cw.wallet_code, private.money(t.amount_cents), private.money(t.to_balance_after), t.reference) END,
                 'createdAt', p.created_at,
                 'kind', p.kind,
                 'status', 'completed',
                 'amount', private.money(t.amount_cents),
                 'reference', t.reference,
                 'balanceAfter', CASE WHEN p.kind = 'transfer_sent' THEN private.money(t.from_balance_after) ELSE private.money(t.to_balance_after) END,
                 'counterpartName', c.name,
                 'counterpartWalletId', cw.wallet_code),
               p.created_at
        FROM public.push_notifications p
        JOIN public.wallet_transfers t ON t.id = p.transfer_id
        JOIN public.users c ON c.id = CASE WHEN p.kind = 'transfer_sent' THEN t.to_customer_id ELSE t.from_customer_id END
        JOIN public.wallets cw ON cw.customer_id = c.id
        WHERE p.customer_id = v_id AND p.created_at < v_before
      ) u
      ORDER BY u.at DESC
      LIMIT v_limit
    ) x(j, at)
  ), '[]'::jsonb);
END $$;

REVOKE ALL ON FUNCTION public.customer_notifications(int, timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_notifications(int, timestamptz) TO authenticated;
