-- Withdrawal bonus: a completed withdrawal earns the customer a bonus (a
-- percentage of the amount withdrawn) into the wallet's Bonus balance
-- (wallets.bonus_cents, shown on the Customer App's wallet card since
-- 20261021000500). The customer moves it to the main wallet; it is never
-- withdrawn directly.
--
--   * Rate: the default (app_settings 'bonus:default_bp', 100 = 1%) or the
--     customer's own (0.5%, 1%, 1.5% or 2%), set by a manager, who can also
--     turn it off for a customer. 'bonus:enabled' turns it off for everyone.
--   * Methods in 'bonus:excluded' (EVC Plus, Golis, ZAAD) earn none.
--   * Earned once per withdrawal, when it becomes completed (never for a
--     failed or cancelled one), rounded down to the cent.
--   * Moving it to the main wallet is a ledger credit, like any other.
-- The bonus is the business's money: every credit is in bonus_entries.
INSERT INTO public.app_settings (key, value) VALUES
  ('bonus:enabled', 'on'),
  ('bonus:default_bp', '100'),
  ('bonus:excluded', 'evc_plus,golis,telesom')
ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.customer_bonus (
  customer_id UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  rate_bp     INT CHECK (rate_bp IN (50, 100, 150, 200)),
  enabled     BOOLEAN NOT NULL DEFAULT true,
  updated_by  UUID REFERENCES public.users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.customer_bonus ENABLE ROW LEVEL SECURITY;

CREATE TABLE IF NOT EXISTS public.bonus_entries (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  wallet_id    UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  kind         TEXT NOT NULL CHECK (kind IN ('earned', 'moved')),
  order_id     UUID REFERENCES public.orders(id),
  amount_cents BIGINT NOT NULL CHECK (amount_cents > 0),
  rate_bp      INT,
  bonus_after_cents BIGINT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS bonus_entries_earned_once ON public.bonus_entries (order_id) WHERE kind = 'earned';
CREATE INDEX IF NOT EXISTS bonus_entries_customer ON public.bonus_entries (customer_id, created_at DESC);
ALTER TABLE public.bonus_entries ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION private.bonus_excluded()
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(string_to_array(NULLIF((SELECT value FROM public.app_settings WHERE key = 'bonus:excluded'), ''), ','), '{}')
$$;

CREATE OR REPLACE FUNCTION private.bonus_default_bp()
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(NULLIF((SELECT value FROM public.app_settings WHERE key = 'bonus:default_bp'), '')::int, 100)
$$;

-- The customer's rate in basis points (100 = 1%); 0 when the bonus is off
-- for everyone or for them.
CREATE OR REPLACE FUNCTION private.bonus_rate_bp(p_customer_id uuid)
RETURNS int LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE
    WHEN COALESCE((SELECT value FROM public.app_settings WHERE key = 'bonus:enabled'), 'off') <> 'on' THEN 0
    WHEN EXISTS (SELECT 1 FROM public.customer_bonus b WHERE b.customer_id = p_customer_id AND NOT b.enabled) THEN 0
    ELSE COALESCE((SELECT b.rate_bp FROM public.customer_bonus b WHERE b.customer_id = p_customer_id), private.bonus_default_bp())
  END
$$;

-- "1%", "1.5%"
CREATE OR REPLACE FUNCTION private.bonus_rate_text(p_bp int)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT rtrim(rtrim(to_char(p_bp / 100.0, 'FM990.00'), '0'), '.') || '%'
$$;

-- When a withdrawal becomes completed: its bonus, once.
CREATE OR REPLACE FUNCTION private.withdrawal_bonus()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_bp int;
  v_cents bigint;
  w public.wallets;
  v_id uuid;
BEGIN
  IF NEW.direction <> 'withdraw' OR NEW.status <> 'completed' OR OLD.status = 'completed'
     OR NEW.method::text = ANY (private.bonus_excluded()) THEN
    RETURN NEW;
  END IF;
  v_bp := private.bonus_rate_bp(NEW.customer_id);
  v_cents := floor(NEW.amount_cents * v_bp / 10000.0)::bigint;
  IF v_cents <= 0 THEN
    RETURN NEW;
  END IF;
  SELECT * INTO w FROM public.wallets WHERE customer_id = NEW.customer_id FOR UPDATE;
  IF w.id IS NULL THEN
    RETURN NEW;
  END IF;
  INSERT INTO public.bonus_entries (customer_id, wallet_id, kind, order_id, amount_cents, rate_bp, bonus_after_cents)
  VALUES (NEW.customer_id, w.id, 'earned', NEW.id, v_cents, v_bp, w.bonus_cents + v_cents)
  ON CONFLICT (order_id) WHERE kind = 'earned' DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    UPDATE public.wallets SET bonus_cents = bonus_cents + v_cents, updated_at = now() WHERE id = w.id;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS orders_withdrawal_bonus ON public.orders;
CREATE TRIGGER orders_withdrawal_bonus AFTER UPDATE OF status ON public.orders
FOR EACH ROW WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed')
EXECUTE FUNCTION private.withdrawal_bonus();

CREATE OR REPLACE FUNCTION private.bonus_entry_json(e public.bonus_entries)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', e.id, 'kind', e.kind, 'amount', private.money(e.amount_cents),
    'rate', CASE WHEN e.rate_bp IS NOT NULL THEN private.bonus_rate_text(e.rate_bp) END,
    'bonusAfter', private.money(e.bonus_after_cents), 'createdAt', e.created_at,
    'orderCode', o.order_code, 'withdrawal', CASE WHEN o.id IS NOT NULL THEN private.money(o.amount_cents) END,
    'method', o.method, 'methodLabel', CASE WHEN o.id IS NOT NULL THEN private.method_label(o.method) END)
  FROM (SELECT 1) x LEFT JOIN public.orders o ON o.id = e.order_id
$$;

CREATE OR REPLACE FUNCTION private.bonus_info_json(p_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'balance', private.money(COALESCE(w.bonus_cents, 0)),
    'rate', private.bonus_rate_text(private.bonus_rate_bp(p_customer_id)),
    'rateBp', private.bonus_rate_bp(p_customer_id),
    'excludedMethods', to_jsonb(private.bonus_excluded()),
    'totalEarned', private.money(COALESCE((SELECT sum(amount_cents) FROM public.bonus_entries
                                            WHERE customer_id = p_customer_id AND kind = 'earned'), 0)),
    'entries', COALESCE((SELECT jsonb_agg(private.bonus_entry_json(e) ORDER BY e.created_at DESC)
                         FROM (SELECT * FROM public.bonus_entries WHERE customer_id = p_customer_id
                               ORDER BY created_at DESC LIMIT 100) e), '[]'::jsonb))
  FROM (SELECT 1) x LEFT JOIN public.wallets w ON w.customer_id = p_customer_id
$$;

-- Customer App: the bonus balance, rate, excluded methods and history.
CREATE OR REPLACE FUNCTION public.customer_bonus()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN private.bonus_info_json(v_id);
END $$;

-- Customer App: moves the whole bonus balance to the main wallet.
CREATE OR REPLACE FUNCTION public.customer_move_bonus()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  w public.wallets := private.lock_wallet(v_id);
  v_cents bigint := w.bonus_cents;
BEGIN
  IF v_cents <= 0 THEN
    PERFORM private.raise_api(400, 'NO_BONUS', 'There is no bonus to move');
  END IF;
  UPDATE public.wallets SET bonus_cents = 0, available_cents = available_cents + v_cents, updated_at = now()
  WHERE id = w.id RETURNING * INTO w;
  PERFORM private.ledger_entry(w, NULL, 'credit', v_cents, 'Bonus moved to main wallet');
  INSERT INTO public.bonus_entries (customer_id, wallet_id, kind, amount_cents, bonus_after_cents)
  VALUES (v_id, w.id, 'moved', v_cents, 0);
  PERFORM private.audit(v_id, 'customer', 'bonus.move', 'wallet', w.id::text, NULL,
    jsonb_build_object('amount', private.money(v_cents), 'available', private.money(w.available_cents)));
  RETURN jsonb_build_object('moved', private.money(v_cents), 'availableBalance', private.money(w.available_cents),
    'bonus', private.bonus_info_json(v_id));
END $$;

-- Agent App (managers): one customer's bonus, and its setting.
CREATE OR REPLACE FUNCTION public.manage_customer_bonus(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  b public.customer_bonus;
BEGIN
  SELECT * INTO b FROM public.customer_bonus WHERE customer_id = p_customer_id;
  RETURN private.bonus_info_json(p_customer_id) || jsonb_build_object(
    'enabled', COALESCE(b.enabled, true),
    'customRateBp', b.rate_bp,
    'defaultRateBp', private.bonus_default_bp(),
    'programmeOn', COALESCE((SELECT value FROM public.app_settings WHERE key = 'bonus:enabled'), 'off') = 'on');
END $$;

CREATE OR REPLACE FUNCTION public.manage_set_customer_bonus(p_customer_id uuid, p_rate_bp int DEFAULT NULL, p_enabled boolean DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  b public.customer_bonus;
BEGIN
  IF p_rate_bp IS NOT NULL AND p_rate_bp NOT IN (50, 100, 150, 200) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The bonus must be 0.5%, 1%, 1.5% or 2%');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  INSERT INTO public.customer_bonus (customer_id, rate_bp, enabled, updated_by)
  VALUES (p_customer_id, p_rate_bp, COALESCE(p_enabled, true), v_id)
  ON CONFLICT (customer_id) DO UPDATE SET
    rate_bp = COALESCE(p_rate_bp, public.customer_bonus.rate_bp),
    enabled = COALESCE(p_enabled, public.customer_bonus.enabled),
    updated_by = v_id, updated_at = now()
  RETURNING * INTO b;
  PERFORM private.audit(v_id, private.app_role(), 'bonus.customer_setting', 'user', p_customer_id::text, NULL,
    jsonb_build_object('rateBp', b.rate_bp, 'enabled', b.enabled));
  RETURN public.manage_customer_bonus(p_customer_id);
END $$;

REVOKE ALL ON FUNCTION private.bonus_excluded(), private.bonus_default_bp(), private.bonus_rate_bp(uuid),
  private.withdrawal_bonus(), private.bonus_entry_json(public.bonus_entries), private.bonus_info_json(uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_bonus(), public.customer_move_bonus(), public.manage_customer_bonus(uuid),
  public.manage_set_customer_bonus(uuid, int, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_bonus(), public.customer_move_bonus(), public.manage_customer_bonus(uuid),
  public.manage_set_customer_bonus(uuid, int, boolean) TO authenticated, service_role;

-- Withdraw Confirm: the bonus this withdrawal will earn once completed, or
-- null (an excluded method, or no bonus for this customer). The app shows
-- it as is; it never works the bonus out itself.
CREATE OR REPLACE FUNCTION public.customer_bonus_preview(p_method text, p_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_cents bigint := private.to_cents(p_amount);
  v_bp int;
  v_bonus bigint;
BEGIN
  IF v_method::text = ANY (private.bonus_excluded()) THEN
    RETURN NULL;
  END IF;
  v_bp := private.bonus_rate_bp(v_id);
  v_bonus := floor(v_cents * v_bp / 10000.0)::bigint;
  IF v_bonus <= 0 THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('rate', private.bonus_rate_text(v_bp), 'amount', private.money(v_bonus));
END $$;

REVOKE ALL ON FUNCTION public.customer_bonus_preview(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_bonus_preview(text, text) TO authenticated, service_role;
