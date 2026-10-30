-- The Sahal balance check counted every withdrawal already waiting for Sahal
-- against its balance. One large waiting withdrawal that Sahal cannot pay yet
-- (more than its whole balance) then refused every small one, although Sahal
-- could pay them. A waiting withdrawal now holds back Sahal's balance only
-- when Sahal could pay it (its payout is not more than the balance).
CREATE OR REPLACE FUNCTION private.sahal_room(p_method public.order_method)
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sahal_payout_settings;
  b public.sahal_balances;
BEGIN
  SELECT * INTO s FROM public.sahal_payout_settings WHERE id;
  IF s.id IS NULL OR s.mode <> 'live' OR NOT (p_method = ANY (s.methods)) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO b FROM public.sahal_balances ORDER BY checked_at DESC LIMIT 1;
  IF b.id IS NULL OR NOT b.ok OR b.checked_at < now() - interval '10 minutes' THEN
    RETURN NULL;
  END IF;
  RETURN b.balance_cents - COALESCE((
    SELECT sum(o.net_cents) FROM public.orders o
    WHERE o.direction = 'withdraw' AND o.status IN ('pending', 'processing') AND o.method = ANY (s.methods)
      AND o.net_cents <= b.balance_cents), 0);
END $$;
REVOKE ALL ON FUNCTION private.sahal_room(public.order_method) FROM PUBLIC, anon, authenticated;
