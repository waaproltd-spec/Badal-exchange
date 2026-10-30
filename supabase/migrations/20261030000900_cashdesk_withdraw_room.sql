-- A withdrawal to a betting platform (1XBET, MELBET, WinWin, ... and any added
-- one) is refused before any order exists when the platform's cash desk cannot
-- cover it: its last read Limit (what it can still pay into players' accounts),
-- brought up to date with the sales and payouts since the read, minus the
-- withdrawals already waiting that it could pay, is less than this one. Nothing
-- is taken from the wallet (the whole request is undone), the customer is told in
-- Somali, and the app tells the admin's Telegram, exactly as for Sahal.
-- When the cash desk reports no Limit, or its last read is older than 10 minutes
-- or failed, nothing changes: the withdrawal goes on as before.
-- (app_settings 'withdraw_balance_check' = 'off' switches this off too.)
CREATE OR REPLACE FUNCTION private.cashdesk_room(p_method public.order_method)
RETURNS bigint LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_good public.cashdesk_balances;
  v_sales bigint := 0;
  v_payouts bigint := 0;
  v_limit bigint;
BEGIN
  IF NOT private.is_cashdesk_method(p_method) THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_good FROM public.cashdesk_balances WHERE method = p_method AND ok ORDER BY checked_at DESC LIMIT 1;
  IF v_good.id IS NULL OR v_good.limit_cents IS NULL OR v_good.checked_at < now() - interval '10 minutes' THEN
    RETURN NULL;
  END IF;
  -- A later failed read means the answer is not trustworthy.
  IF EXISTS (SELECT 1 FROM public.cashdesk_balances WHERE method = p_method AND NOT ok AND checked_at > v_good.checked_at) THEN
    RETURN NULL;
  END IF;
  SELECT COALESCE(sum(amount_cents) FILTER (WHERE kind = 'sale'), 0), COALESCE(sum(amount_cents) FILTER (WHERE kind = 'payout'), 0)
    INTO v_sales, v_payouts
  FROM public.cashdesk_movements WHERE method = p_method AND happened_at > v_good.checked_at;
  v_limit := v_good.limit_cents - v_sales + v_payouts;
  RETURN v_limit - COALESCE((
    SELECT sum(o.net_cents) FROM public.orders o
    WHERE o.direction = 'withdraw' AND o.status IN ('pending', 'processing') AND o.method = p_method
      AND o.net_cents <= v_limit), 0);
END $$;
REVOKE ALL ON FUNCTION private.cashdesk_room(public.order_method) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.withdraw_balance_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_room bigint;
BEGIN
  IF NEW.direction <> 'withdraw'
     OR COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'withdraw_balance_check'), 'on') = 'off' THEN
    RETURN NEW;
  END IF;
  v_room := COALESCE(private.sahal_room(NEW.method), private.cashdesk_room(NEW.method));
  IF v_room IS NOT NULL AND v_room < NEW.net_cents THEN
    PERFORM private.raise_api(503, 'WITHDRAWAL_PROVIDER_BALANCE', 'Lacag-bixinta hadda cilad ayaa ka jirta. Fadlan mar kale isku day.');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.withdraw_balance_check() FROM PUBLIC, anon, authenticated;
