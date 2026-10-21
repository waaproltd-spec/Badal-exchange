-- No rates and no fees (Dalab Reseller style): every deposit and withdrawal
-- is 1:1. A $1 deposit credits $1; a $1 withdrawal takes $1 from the wallet
-- and pays out $1. Withdrawal limits stay.

CREATE OR REPLACE FUNCTION private.compute_quote(
  p_method public.order_method,
  p_direction public.order_direction,
  p_amount_cents bigint,
  OUT rate numeric,
  OUT rate_id uuid,
  OUT fee_id uuid,
  OUT fee_cents bigint,
  OUT net_cents bigint,
  OUT wallet_delta_cents bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_min bigint := 100;
  v_max bigint := 100000000;
BEGIN
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM private.raise_api(400, 'INVALID_AMOUNT', 'Amount must be greater than zero');
  END IF;

  IF p_direction = 'withdraw' THEN
    SELECT l.min_cents, l.max_cents INTO v_min, v_max FROM public.withdrawal_limits l WHERE l.method = p_method;
    v_min := COALESCE(v_min, 100);
    v_max := COALESCE(v_max, 100000000);
    IF p_amount_cents < v_min THEN
      PERFORM private.raise_api(400, 'BELOW_MIN_WITHDRAWAL', 'Minimum withdrawal is ' || (v_min / 100.0)::float8::text);
    END IF;
    IF p_amount_cents > v_max THEN
      PERFORM private.raise_api(400, 'ABOVE_MAX_WITHDRAWAL', 'Maximum withdrawal is ' || (v_max / 100.0)::float8::text);
    END IF;
  END IF;

  rate := 1;
  rate_id := NULL;
  fee_id := NULL;
  fee_cents := 0;
  net_cents := p_amount_cents;
  wallet_delta_cents := p_amount_cents;
END
$$;

-- Deposits still waiting for their payment get the 1:1 amount too (nothing
-- has been credited yet, so this changes no balance).
UPDATE public.orders
SET rate = 1, fee_cents = 0, net_cents = amount_cents, wallet_delta_cents = amount_cents,
    exchange_rate_id = NULL, fee_id = NULL, updated_at = now()
WHERE direction = 'deposit' AND status = 'pending'
  AND (net_cents <> amount_cents OR fee_cents <> 0 OR rate <> 1);

-- Keep the stored settings consistent with what is applied.
UPDATE public.exchange_rates SET rate = 1 WHERE active AND rate <> 1;
UPDATE public.fees SET value = 0 WHERE active AND value <> 0;

-- Rates and fees can no longer be set.
CREATE OR REPLACE FUNCTION public.admin_set_exchange_rate(p_method text, p_direction text, p_rate numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  PERFORM private.raise_api(410, 'RATES_DISABLED', 'Rates are turned off: deposits and withdrawals are 1:1');
  RETURN NULL;
END
$$;

CREATE OR REPLACE FUNCTION public.admin_set_fee(p_method text, p_direction text, p_fee_type text, p_value numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  PERFORM private.raise_api(410, 'FEES_DISABLED', 'Fees are turned off: deposits and withdrawals have no fee');
  RETURN NULL;
END
$$;
