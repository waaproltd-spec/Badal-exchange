-- Home screen wallet card: Wallet ID, promo code and bonus balance.
--
-- Wallet ID: every wallet gets a unique code like BE482913, once, when it
-- is created (existing wallets get theirs now). It never changes: updates
-- that try to change it keep the old one.
--
-- Bonus: the wallet's bonus balance, in cents. Nothing credits it yet (there
-- is no bonus programme); it is served so the app shows the real value.
--
-- Promo code: one code set by management in the Agent App (Account -> Admin
-- features -> Promo Code) and shown to every customer; empty means none.

ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS wallet_code TEXT;
ALTER TABLE public.wallets ADD COLUMN IF NOT EXISTS bonus_cents BIGINT NOT NULL DEFAULT 0;
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wallets_bonus_cents_check') THEN
    ALTER TABLE public.wallets ADD CONSTRAINT wallets_bonus_cents_check CHECK (bonus_cents >= 0);
  END IF;
END
$$;

-- A Wallet ID not used by any wallet yet: BE + 6 digits.
CREATE OR REPLACE FUNCTION private.new_wallet_code()
RETURNS text LANGUAGE plpgsql VOLATILE SET search_path = '' AS $$
DECLARE
  v text;
BEGIN
  LOOP
    v := 'BE' || lpad(floor(random() * 1000000)::int::text, 6, '0');
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.wallets WHERE wallet_code = v);
  END LOOP;
  RETURN v;
END $$;

CREATE OR REPLACE FUNCTION private.wallet_code_guard()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.wallet_code := COALESCE(NEW.wallet_code, private.new_wallet_code());
  ELSIF OLD.wallet_code IS NOT NULL THEN
    NEW.wallet_code := OLD.wallet_code; -- permanent
  ELSE
    NEW.wallet_code := COALESCE(NEW.wallet_code, private.new_wallet_code());
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS wallets_wallet_code ON public.wallets;
CREATE TRIGGER wallets_wallet_code BEFORE INSERT OR UPDATE ON public.wallets
FOR EACH ROW EXECUTE FUNCTION private.wallet_code_guard();

-- Existing wallets, one at a time so each sees the codes already given.
DO $$
DECLARE
  w record;
BEGIN
  FOR w IN SELECT id FROM public.wallets WHERE wallet_code IS NULL LOOP
    UPDATE public.wallets SET wallet_code = private.new_wallet_code() WHERE id = w.id;
  END LOOP;
END
$$;
ALTER TABLE public.wallets ALTER COLUMN wallet_code SET NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS wallets_wallet_code_key ON public.wallets (wallet_code);

INSERT INTO public.app_settings (key) VALUES ('promo_code') ON CONFLICT (key) DO NOTHING;

-- GET /customer/wallet, plus walletId, bonusBalance and promoCode.
CREATE OR REPLACE FUNCTION public.customer_wallet()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
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
    'bonusBalance', private.money(w.bonus_cents),
    'walletId', w.wallet_code,
    'promoCode', NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'promo_code')), '')
  );
END
$$;

-- Agent App: the promo code customers see.
CREATE OR REPLACE FUNCTION public.manage_promo_code()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object('promoCode',
    NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'promo_code')), ''));
END $$;

CREATE OR REPLACE FUNCTION public.manage_set_promo_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_code text := upper(btrim(COALESCE(p_code, '')));
BEGIN
  PERFORM private.check_len(v_code, 'promoCode', 0, 32);
  IF v_code !~ '^[A-Z0-9_-]*$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Use letters, digits, - and _ only');
  END IF;
  INSERT INTO public.app_settings (key, value, updated_by) VALUES ('promo_code', v_code, v_id)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_by = EXCLUDED.updated_by, updated_at = now();
  PERFORM private.audit(v_id, private.app_role(), 'promo_code.update', 'app_settings', 'promo_code', NULL,
    jsonb_build_object('promoCode', v_code));
  RETURN jsonb_build_object('promoCode', NULLIF(v_code, ''));
END $$;

REVOKE ALL ON FUNCTION public.manage_promo_code() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.manage_set_promo_code(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_promo_code() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.manage_set_promo_code(text) TO authenticated, service_role;
