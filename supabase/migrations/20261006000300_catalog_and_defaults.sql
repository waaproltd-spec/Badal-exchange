-- Payment-method catalog in the database, plus the default configuration a
-- fresh project needs (what backend/src/db/seed.ts used to insert).

-- ---------------------------------------------------------------------------
-- One source of truth for both apps: id, label, kind, display order,
-- styling and the ON/OFF switch all live in payment_methods now (they were
-- split between this table and backend/src/lib/methods.ts).
-- ---------------------------------------------------------------------------
ALTER TABLE public.payment_methods
  ADD COLUMN IF NOT EXISTS label TEXT,
  ADD COLUMN IF NOT EXISTS kind TEXT,
  ADD COLUMN IF NOT EXISTS color TEXT,
  ADD COLUMN IF NOT EXISTS initials TEXT,
  ADD COLUMN IF NOT EXISTS sort_order INT;

INSERT INTO public.payment_methods (method, label, kind, color, initials, sort_order)
VALUES
  ('evc_plus',  'EVC Plus',  'mobile_money', '#16A34A', 'EVC', 0),
  ('golis',     'Golis',     'mobile_money', '#0EA5E9', 'GO',  1),
  ('telesom',   'Telesom',   'mobile_money', '#2563EB', 'TE',  2),
  ('edahab',    'eDahab',    'mobile_money', '#D97706', 'eD',  3),
  ('winwin',    'WinWin',    'platform',     '#059669', 'WW',  4),
  ('onexbet',   '1XBET',     'platform',     '#1D4ED8', '1X',  5),
  ('melbet',    'MELBET',    'platform',     '#CA8A04', 'MB',  6),
  ('betwinner', 'Betwinner', 'platform',     '#15803D', 'BW',  7),
  ('dbbet',     'DBbet',     'platform',     '#DC2626', 'DB',  8),
  ('888starz',  '888STARZ',  'platform',     '#7C3AED', '888', 9)
ON CONFLICT (method) DO UPDATE
SET label = COALESCE(public.payment_methods.label, EXCLUDED.label),
    kind = COALESCE(public.payment_methods.kind, EXCLUDED.kind),
    color = COALESCE(public.payment_methods.color, EXCLUDED.color),
    initials = COALESCE(public.payment_methods.initials, EXCLUDED.initials),
    sort_order = COALESCE(public.payment_methods.sort_order, EXCLUDED.sort_order);

ALTER TABLE public.payment_methods
  ALTER COLUMN label SET NOT NULL,
  ALTER COLUMN kind SET NOT NULL,
  ALTER COLUMN color SET NOT NULL,
  ALTER COLUMN initials SET NOT NULL,
  ALTER COLUMN sort_order SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payment_methods_kind_check') THEN
    ALTER TABLE public.payment_methods
      ADD CONSTRAINT payment_methods_kind_check CHECK (kind IN ('mobile_money', 'platform'));
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION private.method_label(p_method text)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT COALESCE((SELECT label FROM public.payment_methods WHERE method::text = p_method), p_method) $$;

CREATE OR REPLACE FUNCTION private.method_kind(p_method public.order_method)
RETURNS text
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$ SELECT kind FROM public.payment_methods WHERE method = p_method $$;

-- Parses a method id ('evc' is the original EVC Plus route name).
CREATE OR REPLACE FUNCTION private.parse_method(p_method text, p_kind text DEFAULT NULL)
RETURNS public.order_method
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_text text := CASE WHEN p_method = 'evc' THEN 'evc_plus' ELSE p_method END;
  v_method public.order_method;
BEGIN
  SELECT method INTO v_method FROM public.payment_methods
  WHERE method::text = v_text AND (p_kind IS NULL OR kind = p_kind);
  IF v_method IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown payment method');
  END IF;
  RETURN v_method;
END
$$;

-- methodForSmsProvider: agent devices report the method id; long-form
-- provider names from older clients are accepted; anything else is EVC Plus.
CREATE OR REPLACE FUNCTION private.method_for_sms_provider(p_provider text)
RETURNS public.order_method
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT COALESCE(
    (SELECT method FROM public.payment_methods WHERE method::text = p_provider AND kind = 'mobile_money'),
    CASE p_provider
      WHEN 'hormuud_evc_plus' THEN 'evc_plus'
      WHEN 'golis_sahal' THEN 'golis'
      WHEN 'telesom_zaad' THEN 'telesom'
      WHEN 'somtel_edahab' THEN 'edahab'
      ELSE 'evc_plus'
    END::public.order_method
  )
$$;

-- ---------------------------------------------------------------------------
-- Defaults (each only fills what is missing; nothing existing is changed)
-- ---------------------------------------------------------------------------

-- Actor for orders/audit entries the MobCash automation completes. Disabled
-- (and therefore banned in Supabase Auth): it can never log in.
INSERT INTO public.users (id, role, email, name, password_hash, status)
VALUES (
  '00000000-0000-0000-0000-000000000001', 'admin', 'system-automation@badal.internal', 'MobCash Automation (system)',
  private.hash_password(encode(extensions.gen_random_bytes(32), 'hex')), 'disabled'
)
ON CONFLICT (id) DO NOTHING;
INSERT INTO public.admin_profiles (user_id, admin_role) VALUES ('00000000-0000-0000-0000-000000000001', 'system')
ON CONFLICT (user_id) DO NOTHING;

-- Rates 1:1, fees $0.20 flat on deposits and 1% on withdrawals, limits
-- $1-$500 per withdrawal: the same defaults the backend seed used. They
-- are edited from the Agent App (Account -> Rates / Fees / Limits).
INSERT INTO public.exchange_rates (method, direction, rate)
SELECT m.method, d.direction, 1.0
FROM public.payment_methods m
CROSS JOIN (VALUES ('deposit'::public.order_direction), ('withdraw'::public.order_direction)) d(direction)
WHERE NOT EXISTS (
  SELECT 1 FROM public.exchange_rates r WHERE r.method = m.method AND r.direction = d.direction AND r.active
);

INSERT INTO public.fees (method, direction, fee_type, value)
SELECT m.method, d.direction, d.fee_type, d.value
FROM public.payment_methods m
CROSS JOIN (VALUES
  ('deposit'::public.order_direction, 'flat'::public.fee_type, 20::numeric),
  ('withdraw'::public.order_direction, 'percent'::public.fee_type, 1::numeric)
) d(direction, fee_type, value)
WHERE NOT EXISTS (
  SELECT 1 FROM public.fees f WHERE f.method = m.method AND f.direction = d.direction AND f.active
);

INSERT INTO public.withdrawal_limits (method, min_cents, max_cents)
SELECT method, 100, 50000 FROM public.payment_methods
ON CONFLICT (method) DO NOTHING;

INSERT INTO public.payment_integrations (provider, status, config_json)
VALUES ('evc_plus', 'inactive', '{}'), ('mobcash_winwin', 'inactive', '{}')
ON CONFLICT (provider) DO NOTHING;

-- First accounts, on a brand-new project only (no person has an account
-- yet): the same demo logins the backend seed created. Change these
-- passwords from the app (Account -> Change Password) before going live.
DO $$
DECLARE
  v_admin uuid;
  v_agent uuid;
  v_customer uuid;
BEGIN
  IF EXISTS (SELECT 1 FROM public.users WHERE id <> '00000000-0000-0000-0000-000000000001') THEN
    RETURN;
  END IF;

  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('admin', '252610000001', 'Super Admin', private.hash_password('ChangeMe123!'))
  RETURNING id INTO v_admin;
  INSERT INTO public.admin_profiles (user_id, admin_role) VALUES (v_admin, 'super_admin');

  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('agent', '252610000002', 'Demo Agent', private.hash_password('ChangeMe123!'))
  RETURNING id INTO v_agent;
  INSERT INTO public.agent_profiles (user_id, responsibilities)
  VALUES (v_agent, ARRAY['evc_deposit', 'evc_withdraw', 'manage_settings']);

  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('customer', '252610000003', 'Demo Customer', private.hash_password('ChangeMe123!'))
  RETURNING id INTO v_customer;
  INSERT INTO public.wallets (customer_id) VALUES (v_customer);
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
