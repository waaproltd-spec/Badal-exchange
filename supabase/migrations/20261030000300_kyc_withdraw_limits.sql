-- KYC-based withdrawal limits (withdrawals only; deposits are never touched).
--
--                         daily    monthly
--   no approved KYC       $50      $500
--   approved KYC          $500     $5,000
--
-- Only management (admins, and agents holding 'manage_settings', the same
-- people who decide KYC) can change them: the four defaults, and a customer's
-- own daily / monthly limit (which replaces the default for that customer
-- alone). Everything is enforced here, by a trigger on orders that every
-- withdrawal passes through -- the app, a direct API call or a worker alike --
-- so no app can get round it:
--   * what counts: every withdrawal of the customer that is not failed,
--     cancelled or expired (pending, processing and completed ones), by the
--     amount asked for. A withdrawal that fails or is cancelled gives its
--     amount back to the limit;
--   * the day and the month are Somalia's (Africa/Mogadishu, UTC+3): the
--     daily limit starts again at 00:00 there every day, the monthly limit on
--     the 1st;
--   * requests made at the same time cannot add up past the limit: the check
--     of one customer waits for the customer's earlier request (an advisory
--     lock, and the wallet lock the order step already takes);
--   * an unverified customer who asks for more than their limit but within
--     what an approved KYC allows is told to complete KYC (WITHDRAWAL_KYC_REQUIRED);
--     anyone else is told the limit is reached (WITHDRAWAL_DAILY_LIMIT /
--     WITHDRAWAL_MONTHLY_LIMIT) and how much is left.
-- app_settings 'withdraw_limits' = 'off' switches the check off (tests).

INSERT INTO public.app_settings (key, value) VALUES
  ('withdraw_limits', 'on'),
  ('withdraw_limit:unverified_daily', '50'),
  ('withdraw_limit:unverified_monthly', '500'),
  ('withdraw_limit:verified_daily', '500'),
  ('withdraw_limit:verified_monthly', '5000')
ON CONFLICT (key) DO NOTHING;

-- A customer's own limits: NULL keeps the default for that one.
CREATE TABLE IF NOT EXISTS public.customer_withdraw_limits (
  customer_id  UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  daily_cents  BIGINT CHECK (daily_cents >= 0),
  monthly_cents BIGINT CHECK (monthly_cents >= 0),
  note         TEXT,
  set_by       UUID REFERENCES public.users(id) ON DELETE SET NULL,
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (daily_cents IS NOT NULL OR monthly_cents IS NOT NULL)
);
ALTER TABLE public.customer_withdraw_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.customer_withdraw_limits FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.withdraw_limits_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'withdraw_limits'), 'on') <> 'off'
$$;

-- A default limit in cents (dollars in the setting).
CREATE OR REPLACE FUNCTION private.withdraw_setting_cents(p_key text, p_default bigint)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(round(NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = p_key)), '')::numeric * 100)::bigint, p_default)
$$;

CREATE OR REPLACE FUNCTION private.kyc_verified(p_customer uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.kyc_applications k WHERE k.customer_id = p_customer AND k.status = 'approved')
$$;

-- Somalia's day and month: where they start and when the next ones start.
CREATE OR REPLACE FUNCTION private.withdraw_day_start()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu'
$$;
CREATE OR REPLACE FUNCTION private.withdraw_month_start()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT date_trunc('month', now() AT TIME ZONE 'Africa/Mogadishu') AT TIME ZONE 'Africa/Mogadishu'
$$;
CREATE OR REPLACE FUNCTION private.withdraw_next_day()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT (date_trunc('day', now() AT TIME ZONE 'Africa/Mogadishu') + interval '1 day') AT TIME ZONE 'Africa/Mogadishu'
$$;
CREATE OR REPLACE FUNCTION private.withdraw_next_month()
RETURNS timestamptz LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT (date_trunc('month', now() AT TIME ZONE 'Africa/Mogadishu') + interval '1 month') AT TIME ZONE 'Africa/Mogadishu'
$$;

-- What the customer has withdrawn (asked for) since p_since.
CREATE OR REPLACE FUNCTION private.withdraw_used(p_customer uuid, p_since timestamptz)
RETURNS bigint LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(sum(o.amount_cents), 0)::bigint FROM public.orders o
  WHERE o.customer_id = p_customer AND o.direction = 'withdraw'
    AND o.status NOT IN ('failed', 'cancelled', 'expired') AND o.created_at >= p_since
$$;

-- The limits that apply to this customer, in cents.
CREATE OR REPLACE FUNCTION private.withdraw_limits(p_customer uuid)
RETURNS TABLE (daily_cents bigint, monthly_cents bigint, verified boolean, custom_daily boolean, custom_monthly boolean,
               verified_daily_cents bigint, verified_monthly_cents bigint)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v boolean := private.kyc_verified(p_customer);
  o public.customer_withdraw_limits;
  vd bigint := private.withdraw_setting_cents('withdraw_limit:verified_daily', 50000);
  vm bigint := private.withdraw_setting_cents('withdraw_limit:verified_monthly', 500000);
BEGIN
  SELECT * INTO o FROM public.customer_withdraw_limits c WHERE c.customer_id = p_customer;
  daily_cents := COALESCE(o.daily_cents, CASE WHEN v THEN vd ELSE private.withdraw_setting_cents('withdraw_limit:unverified_daily', 5000) END);
  monthly_cents := COALESCE(o.monthly_cents, CASE WHEN v THEN vm ELSE private.withdraw_setting_cents('withdraw_limit:unverified_monthly', 50000) END);
  verified := v;
  custom_daily := o.daily_cents IS NOT NULL;
  custom_monthly := o.monthly_cents IS NOT NULL;
  verified_daily_cents := vd;
  verified_monthly_cents := vm;
  RETURN NEXT;
END $$;

-- Dollars for a message: 50 -> "50", 12.5 -> "12.50".
CREATE OR REPLACE FUNCTION private.withdraw_dollars(p_cents bigint)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_cents % 100 = 0 THEN (p_cents / 100)::text ELSE private.money(p_cents) END
$$;

-- The rule, wherever a withdrawal comes from.
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
      E'Xadka lacag-bixinta ee aan la xaqiijin waa $%s maalintii iyo $%s bishii (waxaad maanta bixin kartaa ilaa $%s). Fadlan dhammaystir xaqiijinta KYC si aad u bixiso ilaa $%s maalintii iyo $%s bishii.\n'
      'Without KYC you can withdraw up to $%s a day and $%s a month (up to $%s more today). Complete KYC verification to withdraw up to $%s a day and $%s a month.',
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month)),
      private.withdraw_dollars(l.verified_daily_cents), private.withdraw_dollars(l.verified_monthly_cents),
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month)),
      private.withdraw_dollars(l.verified_daily_cents), private.withdraw_dollars(l.verified_monthly_cents)));
  ELSIF NEW.amount_cents > v_left_day THEN
    PERFORM private.raise_api(403, 'WITHDRAWAL_DAILY_LIMIT', format(
      E'Xadka maalinlaha ah ee lacag-bixinta ($%s) waa gaadhay ama waa dhaafayaa. Maanta waxaad bixin kartaa ilaa $%s oo kale. Wuxuu dib u bilaabmayaa 00:00 (waqtiga Soomaaliya).\n'
      'Daily withdrawal limit ($%s) reached. You can withdraw up to $%s more today. It starts again at 00:00 (Somalia time).',
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month)),
      private.withdraw_dollars(l.daily_cents), private.withdraw_dollars(LEAST(v_left_day, v_left_month))));
  ELSE
    PERFORM private.raise_api(403, 'WITHDRAWAL_MONTHLY_LIMIT', format(
      E'Xadka bil kasta ee lacag-bixinta ($%s) waa gaadhay ama waa dhaafayaa. Bishan waxaad bixin kartaa ilaa $%s oo kale. Wuxuu dib u bilaabmayaa 1da bisha.\n'
      'Monthly withdrawal limit ($%s) reached. You can withdraw up to $%s more this month. It starts again on the 1st.',
      private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(v_left_month),
      private.withdraw_dollars(l.monthly_cents), private.withdraw_dollars(v_left_month)));
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.withdraw_limit_check() FROM PUBLIC, anon, authenticated;

-- After the account-verification trigger (triggers run by name).
DROP TRIGGER IF EXISTS orders_withdrawal_z_limit ON public.orders;
CREATE TRIGGER orders_withdrawal_z_limit BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.withdraw_limit_check();

-- One customer's KYC status, limits, what was withdrawn and what is left.
-- The same answer for the Customer App and for management.
CREATE OR REPLACE FUNCTION private.withdraw_state(p_customer uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  l record;
  o public.customer_withdraw_limits;
  v_day bigint := private.withdraw_used(p_customer, private.withdraw_day_start());
  v_month bigint := private.withdraw_used(p_customer, private.withdraw_month_start());
  v_kyc text := COALESCE((SELECT k.status FROM public.kyc_applications k WHERE k.customer_id = p_customer
                          ORDER BY k.submitted_at DESC LIMIT 1), 'not_submitted');
  v_left_day bigint;
  v_left_month bigint;
  v_available bigint;
  v_warning text;
BEGIN
  SELECT * INTO l FROM private.withdraw_limits(p_customer);
  SELECT * INTO o FROM public.customer_withdraw_limits c WHERE c.customer_id = p_customer;
  v_left_day := GREATEST(l.daily_cents - v_day, 0);
  v_left_month := GREATEST(l.monthly_cents - v_month, 0);
  v_available := LEAST(v_left_day, v_left_month);
  v_warning := CASE
    WHEN v_left_day <= 0 THEN 'daily_reached'
    WHEN v_left_month <= 0 THEN 'monthly_reached'
    WHEN l.daily_cents > 0 AND v_day * 10 >= l.daily_cents * 8 THEN 'near_daily'
    WHEN l.monthly_cents > 0 AND v_month * 10 >= l.monthly_cents * 8 THEN 'near_monthly'
  END;
  RETURN jsonb_build_object(
    'enabled', private.withdraw_limits_on(),
    'kyc', jsonb_build_object('status', v_kyc, 'verified', l.verified),
    'daily', jsonb_build_object('limit', private.money(l.daily_cents), 'used', private.money(v_day),
      'remaining', private.money(v_left_day), 'resetsAt', private.withdraw_next_day(), 'custom', l.custom_daily),
    'monthly', jsonb_build_object('limit', private.money(l.monthly_cents), 'used', private.money(v_month),
      'remaining', private.money(v_left_month), 'resetsAt', private.withdraw_next_month(), 'custom', l.custom_monthly),
    'availableNow', private.money(v_available),
    'canWithdraw', v_available > 0 OR NOT private.withdraw_limits_on(),
    'warning', v_warning,
    'custom', jsonb_build_object('daily', l.custom_daily, 'monthly', l.custom_monthly, 'note', o.note),
    'ifVerified', jsonb_build_object('daily', private.money(l.verified_daily_cents), 'monthly', private.money(l.verified_monthly_cents)),
    'askKyc', NOT l.verified AND NOT l.custom_daily AND NOT l.custom_monthly AND v_kyc <> 'pending_review' AND v_kyc <> 'pending_auto');
END $$;
REVOKE ALL ON FUNCTION private.withdraw_state(uuid), private.withdraw_used(uuid, timestamptz), private.withdraw_limits(uuid),
  private.kyc_verified(uuid), private.withdraw_setting_cents(text, bigint), private.withdraw_limits_on(),
  private.withdraw_dollars(bigint), private.withdraw_day_start(), private.withdraw_month_start(),
  private.withdraw_next_day(), private.withdraw_next_month() FROM PUBLIC, anon, authenticated;

-- Customer App, Withdraw: the customer's own status and limits.
CREATE OR REPLACE FUNCTION public.customer_withdraw_limits()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('customer');
BEGIN
  RETURN private.withdraw_state(v_id);
END $$;

-- Management: the four default limits.
CREATE OR REPLACE FUNCTION private.withdraw_settings_json()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'enabled', private.withdraw_limits_on(),
    'unverifiedDaily', private.money(private.withdraw_setting_cents('withdraw_limit:unverified_daily', 5000)),
    'unverifiedMonthly', private.money(private.withdraw_setting_cents('withdraw_limit:unverified_monthly', 50000)),
    'verifiedDaily', private.money(private.withdraw_setting_cents('withdraw_limit:verified_daily', 50000)),
    'verifiedMonthly', private.money(private.withdraw_setting_cents('withdraw_limit:verified_monthly', 500000)))
$$;
REVOKE ALL ON FUNCTION private.withdraw_settings_json() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.manage_withdraw_limit_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN private.withdraw_settings_json();
END $$;

-- Management: change the defaults (dollars). A daily limit cannot be above its monthly one.
CREATE OR REPLACE FUNCTION public.manage_set_withdraw_limit_settings(
  p_unverified_daily numeric, p_unverified_monthly numeric, p_verified_daily numeric, p_verified_monthly numeric
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_before jsonb := private.withdraw_settings_json();
BEGIN
  IF p_unverified_daily IS NULL OR p_unverified_monthly IS NULL OR p_verified_daily IS NULL OR p_verified_monthly IS NULL
     OR LEAST(p_unverified_daily, p_unverified_monthly, p_verified_daily, p_verified_monthly) < 0
     OR GREATEST(p_unverified_daily, p_unverified_monthly, p_verified_daily, p_verified_monthly) > 10000000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Each limit must be an amount of 0 or more');
  END IF;
  IF p_unverified_daily > p_unverified_monthly OR p_verified_daily > p_verified_monthly THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'A daily limit cannot be higher than its monthly limit');
  END IF;
  INSERT INTO public.app_settings (key, value) VALUES
    ('withdraw_limit:unverified_daily', round(p_unverified_daily, 2)::text),
    ('withdraw_limit:unverified_monthly', round(p_unverified_monthly, 2)::text),
    ('withdraw_limit:verified_daily', round(p_verified_daily, 2)::text),
    ('withdraw_limit:verified_monthly', round(p_verified_monthly, 2)::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  PERFORM private.audit(v_id, private.app_role(), 'withdraw_limits.settings', 'withdraw_limits', 'defaults', v_before, private.withdraw_settings_json());
  RETURN private.withdraw_settings_json();
END $$;

-- Management: one customer's limits, what they withdrew and what is left, KYC status, recent withdrawals.
CREATE OR REPLACE FUNCTION public.manage_customer_withdraw_limits(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  u public.users;
BEGIN
  SELECT * INTO u FROM public.users WHERE id = p_customer_id AND role = 'customer';
  IF u.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  RETURN private.withdraw_state(u.id) || jsonb_build_object(
    'customer', jsonb_build_object('id', u.id, 'name', u.name, 'phone', u.phone, 'accountId', private.account_code(u.id)),
    'defaults', private.withdraw_settings_json(),
    'kycApplicationId', (SELECT k.id FROM public.kyc_applications k WHERE k.customer_id = u.id ORDER BY k.submitted_at DESC LIMIT 1),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'orderCode', o.order_code, 'method', o.method, 'amount', private.money(o.amount_cents), 'status', o.status,
        'counted', o.status NOT IN ('failed', 'cancelled', 'expired'), 'createdAt', o.created_at) ORDER BY o.created_at DESC)
      FROM (SELECT * FROM public.orders x WHERE x.customer_id = u.id AND x.direction = 'withdraw'
            ORDER BY x.created_at DESC LIMIT 50) o), '[]'::jsonb));
END $$;

-- Management: a customer's own limits (dollars). A NULL keeps the default for that one;
-- both NULL removes the customer's own limits.
CREATE OR REPLACE FUNCTION public.manage_set_customer_withdraw_limits(
  p_customer_id uuid, p_daily numeric DEFAULT NULL, p_monthly numeric DEFAULT NULL, p_note text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  l record;
  v_before jsonb;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  IF (p_daily IS NOT NULL AND (p_daily < 0 OR p_daily > 10000000)) OR (p_monthly IS NOT NULL AND (p_monthly < 0 OR p_monthly > 10000000)) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'A limit must be an amount of 0 or more');
  END IF;
  PERFORM private.check_len(p_note, 'note', 0, 200, false);
  v_before := private.withdraw_state(p_customer_id) -> 'custom';
  IF p_daily IS NULL AND p_monthly IS NULL THEN
    DELETE FROM public.customer_withdraw_limits WHERE customer_id = p_customer_id;
  ELSE
    INSERT INTO public.customer_withdraw_limits (customer_id, daily_cents, monthly_cents, note, set_by)
    VALUES (p_customer_id, round(p_daily * 100)::bigint, round(p_monthly * 100)::bigint, NULLIF(btrim(p_note), ''), v_id)
    ON CONFLICT (customer_id) DO UPDATE SET daily_cents = EXCLUDED.daily_cents, monthly_cents = EXCLUDED.monthly_cents,
      note = EXCLUDED.note, set_by = EXCLUDED.set_by, updated_at = now();
    -- Whatever the customer's day and month now are, the daily limit may not be above the monthly one.
    SELECT * INTO l FROM private.withdraw_limits(p_customer_id);
    IF l.daily_cents > l.monthly_cents THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'A daily limit cannot be higher than the monthly limit');
    END IF;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'withdraw_limits.customer', 'customer', p_customer_id::text, v_before,
    private.withdraw_state(p_customer_id) -> 'custom');
  RETURN private.withdraw_state(p_customer_id);
END $$;

-- Management: customers with their KYC status, withdrawals today and this month, and limits.
-- p_filter: all | custom | near | reached | unverified | verified. p_query: name, phone or account ID.
CREATE OR REPLACE FUNCTION public.manage_withdraw_limit_customers(p_query text DEFAULT NULL, p_filter text DEFAULT 'all')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_filter text := COALESCE(NULLIF(btrim(p_filter), ''), 'all');
  v_q text := NULLIF(btrim(COALESCE(p_query, '')), '');
BEGIN
  IF v_filter NOT IN ('all', 'custom', 'near', 'reached', 'unverified', 'verified') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid filter');
  END IF;
  RETURN jsonb_build_object('settings', private.withdraw_settings_json(), 'customers', COALESCE((
    SELECT jsonb_agg(row_to_json(r)::jsonb ORDER BY r.used_month DESC, r.name) FROM (
      SELECT u.id, u.name, u.phone, private.account_code(u.id) AS "accountId",
             s.state -> 'kyc' ->> 'status' AS "kycStatus", (s.state -> 'kyc' ->> 'verified')::boolean AS verified,
             s.state -> 'daily' ->> 'limit' AS "dailyLimit", s.state -> 'daily' ->> 'used' AS "dailyUsed",
             s.state -> 'daily' ->> 'remaining' AS "dailyRemaining",
             s.state -> 'monthly' ->> 'limit' AS "monthlyLimit", s.state -> 'monthly' ->> 'used' AS "monthlyUsed",
             s.state -> 'monthly' ->> 'remaining' AS "monthlyRemaining",
             COALESCE((s.state -> 'custom' ->> 'daily')::boolean, false) OR COALESCE((s.state -> 'custom' ->> 'monthly')::boolean, false) AS custom,
             s.state ->> 'warning' AS warning,
             (s.state -> 'monthly' ->> 'used')::numeric AS used_month
      FROM public.users u
      CROSS JOIN LATERAL (SELECT private.withdraw_state(u.id) AS state) s
      WHERE u.role = 'customer'
        AND (v_q IS NULL OR u.name ILIKE '%' || v_q || '%' OR u.phone ILIKE '%' || v_q || '%'
             OR private.account_code(u.id) ILIKE '%' || upper(v_q) || '%')
        AND (v_filter = 'all'
          OR (v_filter = 'custom' AND (COALESCE((s.state -> 'custom' ->> 'daily')::boolean, false) OR COALESCE((s.state -> 'custom' ->> 'monthly')::boolean, false)))
          OR (v_filter = 'near' AND s.state ->> 'warning' IN ('near_daily', 'near_monthly'))
          OR (v_filter = 'reached' AND s.state ->> 'warning' IN ('daily_reached', 'monthly_reached'))
          OR (v_filter = 'unverified' AND NOT (s.state -> 'kyc' ->> 'verified')::boolean)
          OR (v_filter = 'verified' AND (s.state -> 'kyc' ->> 'verified')::boolean))
      ORDER BY (s.state -> 'monthly' ->> 'used')::numeric DESC, u.name
      LIMIT 100) r), '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION public.customer_withdraw_limits(), public.manage_withdraw_limit_settings(),
  public.manage_set_withdraw_limit_settings(numeric, numeric, numeric, numeric),
  public.manage_customer_withdraw_limits(uuid), public.manage_set_customer_withdraw_limits(uuid, numeric, numeric, text),
  public.manage_withdraw_limit_customers(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_withdraw_limits(), public.manage_withdraw_limit_settings(),
  public.manage_set_withdraw_limit_settings(numeric, numeric, numeric, numeric),
  public.manage_customer_withdraw_limits(uuid), public.manage_set_customer_withdraw_limits(uuid, numeric, numeric, text),
  public.manage_withdraw_limit_customers(text, text) TO authenticated;
