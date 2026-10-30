-- Payment safety, first part: a withdrawal the payment provider cannot cover is
-- refused before any order exists; incidents are recorded and sent to the
-- admin's Telegram; the customer's messages are Somali only.
--
-- A withdrawal paid through Sahal (the methods Sahal pays, while Sahal payouts
-- are on) is refused with WITHDRAWAL_PROVIDER_BALANCE when Sahal's last read
-- balance (not older than 10 minutes) minus the withdrawals already waiting for
-- Sahal is less than this one. No order is made and nothing is taken from the
-- wallet (the whole request is undone). When the balance cannot be read, or the
-- method is paid another way, nothing changes: the withdrawal goes on as before
-- and is held, never retried when its result is unclear.
-- app_settings 'withdraw_balance_check' = 'off' switches it off (tests).

INSERT INTO public.app_settings (key, value) VALUES ('withdraw_balance_check', 'on') ON CONFLICT (key) DO NOTHING;

-- Every deposit / withdrawal error worth the admin's attention.
CREATE TABLE IF NOT EXISTS public.payment_incidents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  direction   TEXT NOT NULL CHECK (direction IN ('deposit', 'withdraw')),
  kind        TEXT NOT NULL CHECK (kind IN ('blocked', 'failed', 'unverified')),
  customer_id UUID REFERENCES public.users(id) ON DELETE SET NULL,
  order_code  TEXT,
  method      TEXT,
  amount_text TEXT,
  error_code  TEXT,
  error_text  TEXT,
  source      TEXT NOT NULL DEFAULT 'app' CHECK (source IN ('app', 'server')),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  alerted_at  TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_payment_incidents_open ON public.payment_incidents (created_at) WHERE alerted_at IS NULL;
ALTER TABLE public.payment_incidents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_incidents FROM PUBLIC, anon, authenticated;

-- What Sahal can still pay (cents), or NULL when this method is not paid through
-- Sahal now or its balance is unknown.
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
    WHERE o.direction = 'withdraw' AND o.status IN ('pending', 'processing') AND o.method = ANY (s.methods)), 0);
END $$;

CREATE OR REPLACE FUNCTION private.withdraw_balance_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_room bigint;
BEGIN
  IF NEW.direction <> 'withdraw'
     OR COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'withdraw_balance_check'), 'on') = 'off' THEN
    RETURN NEW;
  END IF;
  v_room := private.sahal_room(NEW.method);
  IF v_room IS NOT NULL AND v_room < NEW.net_cents THEN
    PERFORM private.raise_api(503, 'WITHDRAWAL_PROVIDER_BALANCE', 'Lacag-bixinta hadda cilad ayaa ka jirta. Fadlan mar kale isku day.');
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.withdraw_balance_check(), private.sahal_room(public.order_method) FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS orders_withdrawal_y_balance ON public.orders;
CREATE TRIGGER orders_withdrawal_y_balance BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.withdraw_balance_check();

-- The customer's app tells the server a deposit / withdrawal failed or was
-- refused (the server undoes a refused request, so it cannot note it itself).
-- Only recorded: no money moves. At most 30 a hour per customer.
CREATE OR REPLACE FUNCTION public.customer_report_payment_error(
  p_direction text, p_method text, p_amount text, p_code text, p_detail text DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  IF p_direction NOT IN ('deposit', 'withdraw') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid direction');
  END IF;
  IF (SELECT count(*) FROM public.payment_incidents WHERE customer_id = v_id AND created_at > now() - interval '1 hour') >= 30 THEN
    RETURN;
  END IF;
  INSERT INTO public.payment_incidents (direction, kind, customer_id, method, amount_text, error_code, error_text, source)
  VALUES (p_direction,
          CASE WHEN COALESCE(p_code, '') LIKE '%LIMIT%' OR p_code IN ('WITHDRAWAL_KYC_REQUIRED', 'WITHDRAWAL_PROVIDER_BALANCE', 'INSUFFICIENT_BALANCE',
                                                                     'WITHDRAWAL_VERIFICATION_REQUIRED', 'DUPLICATE_WITHDRAWAL') THEN 'blocked' ELSE 'failed' END,
          v_id, left(p_method, 40), left(p_amount, 20), left(p_code, 60), left(p_detail, 300), 'app');
END $$;
REVOKE ALL ON FUNCTION public.customer_report_payment_error(text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_report_payment_error(text, text, text, text, text) TO authenticated;

-- The alerts worker: incidents not yet sent, then marked.
CREATE OR REPLACE FUNCTION public.payment_incidents_todo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', i.id, 'direction', i.direction, 'kind', i.kind, 'orderCode', i.order_code, 'method', i.method,
      'amount', i.amount_text, 'code', i.error_code, 'error', i.error_text, 'source', i.source, 'at', i.created_at,
      'customerName', u.name, 'customerPhone', u.phone) ORDER BY i.created_at)
    FROM (SELECT * FROM public.payment_incidents WHERE alerted_at IS NULL ORDER BY created_at LIMIT 20) i
    LEFT JOIN public.users u ON u.id = i.customer_id), '[]'::jsonb);
END $$;
CREATE OR REPLACE FUNCTION public.payment_incidents_sent(p_ids uuid[])
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  UPDATE public.payment_incidents SET alerted_at = now() WHERE id = ANY (p_ids);
END $$;
REVOKE ALL ON FUNCTION public.payment_incidents_todo(), public.payment_incidents_sent(uuid[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_incidents_todo(), public.payment_incidents_sent(uuid[]) TO service_role;

-- The limit messages: Somali only.
CREATE OR REPLACE FUNCTION private.withdraw_limit_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l record;
  v_day bigint;
  v_month bigint;
  v_left_day bigint;
  v_left_month bigint;
  v_would_pass_kyc boolean;
BEGIN
  IF NEW.direction <> 'withdraw' OR NOT private.withdraw_limits_on() THEN
    RETURN NEW;
  END IF;
  -- One customer's requests are checked one at a time, so several at once cannot add up past the limit.
  PERFORM pg_advisory_xact_lock(hashtextextended('withdraw-limit:' || NEW.customer_id::text, 0));
  SELECT * INTO l FROM private.withdraw_limits(NEW.customer_id);
  v_day := private.withdraw_used(NEW.customer_id, private.withdraw_day_start());
  v_month := private.withdraw_used(NEW.customer_id, private.withdraw_month_start());
  v_left_day := GREATEST(l.daily_cents - v_day, 0);
  v_left_month := GREATEST(l.monthly_cents - v_month, 0);
  IF NEW.amount_cents <= v_left_day AND NEW.amount_cents <= v_left_month THEN
    RETURN NEW;
  END IF;

  -- Not verified, and an approved KYC would allow it: ask for KYC.
  v_would_pass_kyc := NOT l.verified AND NOT l.custom_daily AND NOT l.custom_monthly
    AND v_day + NEW.amount_cents <= l.verified_daily_cents AND v_month + NEW.amount_cents <= l.verified_monthly_cents;
  IF v_would_pass_kyc THEN
    PERFORM private.raise_api(403, 'WITHDRAWAL_KYC_REQUIRED', format(
      'Xadka lacag-bixinta ee aan la xaqiijin waa $%s maalintii iyo $%s bishii (waxaad maanta bixin kartaa ilaa $%s). Fadlan dhammaystir xaqiijinta KYC si aad u bixiso ilaa $%s maalintii iyo $%s bishii.',
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month)),
      private.withdraw_dollars(l.verified_daily_cents), private.withdraw_dollars(l.verified_monthly_cents)));
  ELSIF NEW.amount_cents > v_left_day THEN
    PERFORM private.raise_api(403, 'WITHDRAWAL_DAILY_LIMIT', format(
      'Xadka maalinlaha ah ee lacag-bixinta ($%s) waa gaadhay ama waa dhaafayaa. Maanta waxaad bixin kartaa ilaa $%s oo kale. Wuxuu dib u bilaabmayaa 00:00 (waqtiga Soomaaliya).',
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month))));
  ELSE
    PERFORM private.raise_api(403, 'WITHDRAWAL_MONTHLY_LIMIT', format(
      'Xadka bil kasta ee lacag-bixinta ($%s) waa gaadhay ama waa dhaafayaa. Bishan waxaad bixin kartaa ilaa $%s oo kale. Wuxuu dib u bilaabmayaa 1da bisha.',
      private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(v_left_month)));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.withdraw_limit_check() FROM PUBLIC, anon, authenticated;
