-- Bonus system, reworked (builds on 20261028000400_withdrawal_bonus):
--
--   * Its own wallet: public.bonus_wallets, one per customer. The bonus is
--     never part of the Available Balance until the customer transfers it.
--   * Exact: amounts are kept in micro-dollars (1 = $0.000001). A bonus is
--     amount_cents x rate_bp micro-dollars exactly ($0.30 at 2% = 6000 =
--     $0.006); nothing is rounded away. A transfer moves the whole cents to
--     the main wallet and leaves any fraction of a cent in the bonus wallet.
--   * Eligible types, chosen by a manager: each direction (deposit,
--     withdraw) of each method (mobile money or betting platform) is on or
--     off ('bonus:eligible'). A completed order earns only when its type is
--     on; pending, processing, failed and cancelled ones never do. Defaults
--     to what 20261028000400 did: withdrawals except EVC Plus, Golis, ZAAD.
--   * The rate: 0.5%, 1%, 1.5% or 2%, for everyone ('bonus:default_bp') or
--     per customer; on/off for everyone ('bonus:enabled') or per customer.
--   * Once: one 'earned' entry per order (unique index), however often the
--     order is updated or a webhook repeats.

-- "$0.006", "$2.50": at least two decimals, more only when they matter.
CREATE OR REPLACE FUNCTION private.money_micros(p_micros bigint)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT regexp_replace(to_char(COALESCE(p_micros, 0) / 1000000.0, 'FM999999999990.000000'), '(\.\d\d\d*?)0+$', '\1')
$$;

CREATE TABLE IF NOT EXISTS public.bonus_wallets (
  customer_id          UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  balance_micros       BIGINT NOT NULL DEFAULT 0 CHECK (balance_micros >= 0),
  total_earned_micros  BIGINT NOT NULL DEFAULT 0 CHECK (total_earned_micros >= 0),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.bonus_wallets ENABLE ROW LEVEL SECURITY;

ALTER TABLE public.bonus_entries ADD COLUMN IF NOT EXISTS amount_micros BIGINT;
ALTER TABLE public.bonus_entries ADD COLUMN IF NOT EXISTS bonus_after_micros BIGINT;
ALTER TABLE public.bonus_entries ADD COLUMN IF NOT EXISTS moved_cents BIGINT;
ALTER TABLE public.bonus_entries ALTER COLUMN amount_cents DROP NOT NULL;
ALTER TABLE public.bonus_entries ALTER COLUMN bonus_after_cents DROP NOT NULL;
ALTER TABLE public.bonus_entries DROP CONSTRAINT IF EXISTS bonus_entries_amount_cents_check;
UPDATE public.bonus_entries SET amount_micros = amount_cents * 10000 WHERE amount_micros IS NULL;
UPDATE public.bonus_entries SET bonus_after_micros = bonus_after_cents * 10000 WHERE bonus_after_micros IS NULL;
UPDATE public.bonus_entries SET moved_cents = amount_cents WHERE kind = 'moved' AND moved_cents IS NULL;
ALTER TABLE public.bonus_entries ALTER COLUMN amount_micros SET NOT NULL;
ALTER TABLE public.bonus_entries ALTER COLUMN bonus_after_micros SET NOT NULL;
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bonus_entries_amount_micros_check') THEN
    ALTER TABLE public.bonus_entries ADD CONSTRAINT bonus_entries_amount_micros_check CHECK (amount_micros > 0);
  END IF;
END $$;

-- What 20261028000400 credited to wallets.bonus_cents moves to the bonus wallet.
INSERT INTO public.bonus_wallets (customer_id, balance_micros, total_earned_micros)
SELECT w.customer_id, w.bonus_cents * 10000,
       COALESCE((SELECT sum(e.amount_micros) FROM public.bonus_entries e
                 WHERE e.customer_id = w.customer_id AND e.kind = 'earned'), 0)
FROM public.wallets w
WHERE w.bonus_cents > 0 OR EXISTS (SELECT 1 FROM public.bonus_entries e WHERE e.customer_id = w.customer_id)
ON CONFLICT (customer_id) DO NOTHING;
UPDATE public.wallets SET bonus_cents = 0 WHERE bonus_cents <> 0;

-- Eligible types: 'withdraw:edahab', 'deposit:melbet', ...
INSERT INTO public.app_settings (key, value)
SELECT 'bonus:eligible', COALESCE(string_agg('withdraw:' || m::text, ',' ORDER BY m::text), '')
FROM unnest(enum_range(NULL::public.order_method)) m
WHERE m::text <> ALL (string_to_array(COALESCE((SELECT value FROM public.app_settings WHERE key = 'bonus:excluded'),
                                               'evc_plus,golis,telesom'), ','))
ON CONFLICT (key) DO NOTHING;
DELETE FROM public.app_settings WHERE key = 'bonus:excluded';

CREATE OR REPLACE FUNCTION private.bonus_eligible_types()
RETURNS text[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(string_to_array(NULLIF((SELECT value FROM public.app_settings WHERE key = 'bonus:eligible'), ''), ','), '{}')
$$;

CREATE OR REPLACE FUNCTION private.bonus_is_eligible(p_direction text, p_method text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT (p_direction || ':' || p_method) = ANY (private.bonus_eligible_types())
$$;

CREATE OR REPLACE FUNCTION private.bonus_programme_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT value FROM public.app_settings WHERE key = 'bonus:enabled'), 'off') = 'on'
$$;

-- The old trigger and functions give way to these.
DROP TRIGGER IF EXISTS orders_withdrawal_bonus ON public.orders;
DROP FUNCTION IF EXISTS private.withdrawal_bonus();
DROP FUNCTION IF EXISTS private.bonus_excluded();

-- A completed order of an eligible type: its bonus, once, into the bonus
-- wallet. Anything else (not completed, not eligible, off) earns nothing.
CREATE OR REPLACE FUNCTION private.credit_order_bonus(o public.orders)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_bp int;
  v_micros bigint;
  v_entry uuid;
  b public.bonus_wallets;
BEGIN
  IF o.status <> 'completed' OR o.amount_cents IS NULL OR o.amount_cents <= 0
     OR NOT private.bonus_is_eligible(o.direction::text, o.method::text) THEN
    RETURN;
  END IF;
  v_bp := private.bonus_rate_bp(o.customer_id);
  v_micros := o.amount_cents * v_bp;
  IF v_micros <= 0 THEN
    RETURN;
  END IF;
  INSERT INTO public.bonus_wallets (customer_id) VALUES (o.customer_id) ON CONFLICT (customer_id) DO NOTHING;
  SELECT * INTO b FROM public.bonus_wallets WHERE customer_id = o.customer_id FOR UPDATE;
  INSERT INTO public.bonus_entries (customer_id, wallet_id, kind, order_id, amount_micros, rate_bp, bonus_after_micros)
  SELECT o.customer_id, w.id, 'earned', o.id, v_micros, v_bp, b.balance_micros + v_micros
  FROM public.wallets w WHERE w.customer_id = o.customer_id
  ON CONFLICT (order_id) WHERE kind = 'earned' DO NOTHING
  RETURNING id INTO v_entry;
  IF v_entry IS NOT NULL THEN
    UPDATE public.bonus_wallets
    SET balance_micros = balance_micros + v_micros, total_earned_micros = total_earned_micros + v_micros, updated_at = now()
    WHERE customer_id = o.customer_id;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.order_bonus()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.credit_order_bonus(NEW);
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS orders_bonus_update ON public.orders;
CREATE TRIGGER orders_bonus_update AFTER UPDATE OF status ON public.orders
FOR EACH ROW WHEN (NEW.status = 'completed' AND OLD.status IS DISTINCT FROM 'completed')
EXECUTE FUNCTION private.order_bonus();
DROP TRIGGER IF EXISTS orders_bonus_insert ON public.orders;
CREATE TRIGGER orders_bonus_insert AFTER INSERT ON public.orders
FOR EACH ROW WHEN (NEW.status = 'completed')
EXECUTE FUNCTION private.order_bonus();

-- Catch-up, once: eligible orders completed since the bonus went live
-- (20261028000400, deployed 2026-10-28 04:36 UTC) that the old rounding to
-- the cent left with no bonus (e.g. $0.30 at 1%). Already credited ones are
-- skipped by the unique index.
DO $$
DECLARE o public.orders;
BEGIN
  FOR o IN SELECT * FROM public.orders
           WHERE status = 'completed' AND COALESCE(completed_at, updated_at, created_at) >= '2026-10-28 04:36:00+00'
           ORDER BY COALESCE(completed_at, updated_at, created_at)
  LOOP
    PERFORM private.credit_order_bonus(o);
  END LOOP;
END $$;

CREATE OR REPLACE FUNCTION private.bonus_entry_json(e public.bonus_entries)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', e.id, 'kind', e.kind, 'amount', private.money_micros(e.amount_micros),
    'rate', CASE WHEN e.rate_bp IS NOT NULL THEN private.bonus_rate_text(e.rate_bp) END,
    'rateBp', e.rate_bp,
    'bonusAfter', private.money_micros(e.bonus_after_micros), 'createdAt', e.created_at,
    'movedToMain', CASE WHEN e.moved_cents IS NOT NULL THEN private.money(e.moved_cents) END,
    'orderCode', o.order_code, 'direction', o.direction,
    'orderAmount', CASE WHEN o.id IS NOT NULL THEN private.money(o.amount_cents) END,
    -- Kept for the Customer App built before 'orderAmount'.
    'withdrawal', CASE WHEN o.id IS NOT NULL THEN private.money(o.amount_cents) END,
    'method', o.method, 'methodLabel', CASE WHEN o.id IS NOT NULL THEN private.method_label(o.method) END)
  FROM (SELECT 1) x LEFT JOIN public.orders o ON o.id = e.order_id
$$;

-- The eligible types as the apps show them: [{direction, method, label, kind}].
CREATE OR REPLACE FUNCTION private.bonus_types_json(p_only_eligible boolean)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'direction', d.direction, 'method', m.method, 'label', m.label, 'kind', m.kind,
      'eligible', private.bonus_is_eligible(d.direction, m.method::text))
    ORDER BY m.kind, d.direction, m.sort_order, m.method), '[]'::jsonb)
  FROM public.payment_methods m CROSS JOIN (VALUES ('deposit'), ('withdraw')) d(direction)
  WHERE NOT p_only_eligible OR private.bonus_is_eligible(d.direction, m.method::text)
$$;

CREATE OR REPLACE FUNCTION private.bonus_info_json(p_customer_id uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'balance', private.money_micros(COALESCE(b.balance_micros, 0)),
    'transferable', private.money(COALESCE(b.balance_micros, 0) / 10000),
    'totalEarned', private.money_micros(COALESCE(b.total_earned_micros, 0)),
    'rate', private.bonus_rate_text(private.bonus_rate_bp(p_customer_id)),
    'rateBp', private.bonus_rate_bp(p_customer_id),
    'eligibleTypes', private.bonus_types_json(true),
    'entries', COALESCE((SELECT jsonb_agg(private.bonus_entry_json(e) ORDER BY e.created_at DESC)
                         FROM (SELECT * FROM public.bonus_entries WHERE customer_id = p_customer_id
                               ORDER BY created_at DESC LIMIT 100) e), '[]'::jsonb))
  FROM (SELECT 1) x LEFT JOIN public.bonus_wallets b ON b.customer_id = p_customer_id
$$;

-- Customer App: bonusBalance now comes from the bonus wallet.
CREATE OR REPLACE FUNCTION public.customer_wallet()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  w public.wallets;
BEGIN
  SELECT * INTO w FROM public.wallets WHERE customer_id = v_id;
  IF NOT FOUND THEN
    w := private.lock_wallet(v_id);
  END IF;
  RETURN jsonb_build_object(
    'availableBalance', private.money(w.available_cents),
    'pendingBalance', private.money(w.pending_cents),
    'totalDeposit', private.money(w.total_deposit_cents),
    'totalWithdraw', private.money(w.total_withdraw_cents),
    'bonusBalance', private.money_micros(COALESCE((SELECT balance_micros FROM public.bonus_wallets WHERE customer_id = v_id), 0)),
    'walletId', w.wallet_code,
    'promoCode', NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'promo_code')), '')
  );
END $$;

-- Customer App: moves the whole cents of the bonus to the main wallet; a
-- fraction of a cent stays. Under one cent is NO_BONUS.
CREATE OR REPLACE FUNCTION public.customer_move_bonus()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  w public.wallets := private.lock_wallet(v_id);
  b public.bonus_wallets;
  v_cents bigint;
BEGIN
  SELECT * INTO b FROM public.bonus_wallets WHERE customer_id = v_id FOR UPDATE;
  v_cents := COALESCE(b.balance_micros, 0) / 10000;
  IF v_cents <= 0 THEN
    PERFORM private.raise_api(400, 'NO_BONUS', 'There is no bonus to transfer yet (at least $0.01)');
  END IF;
  UPDATE public.bonus_wallets SET balance_micros = balance_micros - v_cents * 10000, updated_at = now()
  WHERE customer_id = v_id RETURNING * INTO b;
  UPDATE public.wallets SET available_cents = available_cents + v_cents, updated_at = now()
  WHERE id = w.id RETURNING * INTO w;
  PERFORM private.ledger_entry(w, NULL, 'credit', v_cents, 'Bonus moved to main wallet');
  INSERT INTO public.bonus_entries (customer_id, wallet_id, kind, amount_micros, moved_cents, bonus_after_micros)
  VALUES (v_id, w.id, 'moved', v_cents * 10000, v_cents, b.balance_micros);
  PERFORM private.audit(v_id, 'customer', 'bonus.move', 'wallet', w.id::text, NULL,
    jsonb_build_object('amount', private.money(v_cents), 'available', private.money(w.available_cents)));
  RETURN jsonb_build_object('moved', private.money(v_cents), 'availableBalance', private.money(w.available_cents),
    'bonus', private.bonus_info_json(v_id));
END $$;

-- Withdraw Confirm: what this withdrawal will earn once completed, or null.
CREATE OR REPLACE FUNCTION public.customer_bonus_preview(p_method text, p_amount text)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_cents bigint := private.to_cents(p_amount);
  v_bp int;
BEGIN
  IF NOT private.bonus_is_eligible('withdraw', v_method::text) THEN
    RETURN NULL;
  END IF;
  v_bp := private.bonus_rate_bp(v_id);
  IF v_bp <= 0 OR v_cents <= 0 THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('rate', private.bonus_rate_text(v_bp), 'amount', private.money_micros(v_cents * v_bp));
END $$;

-- Agent App (managers): one customer's bonus.
CREATE OR REPLACE FUNCTION public.manage_customer_bonus(p_customer_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  c public.customer_bonus;
BEGIN
  SELECT * INTO c FROM public.customer_bonus WHERE customer_id = p_customer_id;
  RETURN private.bonus_info_json(p_customer_id) || jsonb_build_object(
    'enabled', COALESCE(c.enabled, true),
    'customRateBp', c.rate_bp,
    'defaultRateBp', private.bonus_default_bp(),
    'programmeOn', private.bonus_programme_on());
END $$;

-- Agent App (managers): the Bonus settings screen.
CREATE OR REPLACE FUNCTION public.manage_bonus_settings()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'enabled', private.bonus_programme_on(),
    'defaultRateBp', private.bonus_default_bp(),
    'types', private.bonus_types_json(false),
    'totalBalance', private.money_micros(COALESCE((SELECT sum(balance_micros) FROM public.bonus_wallets), 0)::bigint),
    'totalEarned', private.money_micros(COALESCE((SELECT sum(total_earned_micros) FROM public.bonus_wallets), 0)::bigint),
    'customers', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
          'id', u.id, 'name', u.name, 'phone', u.phone,
          'balance', private.money_micros(b.balance_micros), 'totalEarned', private.money_micros(b.total_earned_micros),
          'rate', private.bonus_rate_text(private.bonus_rate_bp(u.id)))
        ORDER BY b.balance_micros DESC, b.total_earned_micros DESC)
      FROM (SELECT * FROM public.bonus_wallets ORDER BY balance_micros DESC, total_earned_micros DESC LIMIT 100) b
      JOIN public.users u ON u.id = b.customer_id), '[]'::jsonb),
    'history', COALESCE((
      SELECT jsonb_agg(private.bonus_entry_json(e) || jsonb_build_object('customerName', u.name, 'customerPhone', u.phone)
        ORDER BY e.created_at DESC)
      FROM (SELECT * FROM public.bonus_entries ORDER BY created_at DESC LIMIT 100) e
      JOIN public.users u ON u.id = e.customer_id), '[]'::jsonb));
END $$;

-- Agent App (managers): on/off for everyone, the rate, the eligible types
-- ('withdraw:edahab', ...). Any left null stays as it is.
CREATE OR REPLACE FUNCTION public.manage_set_bonus_settings(
  p_enabled boolean DEFAULT NULL, p_default_bp int DEFAULT NULL, p_eligible text[] DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_bad text;
BEGIN
  IF p_default_bp IS NOT NULL AND p_default_bp NOT IN (50, 100, 150, 200) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The bonus must be 0.5%, 1%, 1.5% or 2%');
  END IF;
  IF p_eligible IS NOT NULL THEN
    SELECT t INTO v_bad FROM unnest(p_eligible) t
    WHERE NOT EXISTS (SELECT 1 FROM public.payment_methods m
                      WHERE t IN ('deposit:' || m.method::text, 'withdraw:' || m.method::text))
    LIMIT 1;
    IF v_bad IS NOT NULL THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', format('Unknown transaction type: %s', v_bad));
    END IF;
  END IF;
  IF p_enabled IS NOT NULL THEN
    INSERT INTO public.app_settings (key, value) VALUES ('bonus:enabled', CASE WHEN p_enabled THEN 'on' ELSE 'off' END)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  END IF;
  IF p_default_bp IS NOT NULL THEN
    INSERT INTO public.app_settings (key, value) VALUES ('bonus:default_bp', p_default_bp::text)
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  END IF;
  IF p_eligible IS NOT NULL THEN
    INSERT INTO public.app_settings (key, value)
    VALUES ('bonus:eligible', COALESCE((SELECT string_agg(DISTINCT t, ',') FROM unnest(p_eligible) t), ''))
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'bonus.settings', 'app_settings', 'bonus', NULL,
    jsonb_build_object('enabled', p_enabled, 'defaultRateBp', p_default_bp, 'eligible', to_jsonb(p_eligible)));
  RETURN public.manage_bonus_settings();
END $$;

REVOKE ALL ON FUNCTION private.money_micros(bigint), private.bonus_eligible_types(), private.bonus_is_eligible(text, text),
  private.bonus_programme_on(), private.order_bonus(), private.credit_order_bonus(public.orders),
  private.bonus_types_json(boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.manage_bonus_settings(), public.manage_set_bonus_settings(boolean, int, text[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_bonus_settings(), public.manage_set_bonus_settings(boolean, int, text[])
  TO authenticated, service_role;
