-- Baseline tables (Node backend migrations 001, 002, 005, 006). See the
-- previous migration for why this is idempotent. The enum values added
-- there are committed before this file runs, so they can be used here.

-- ---------------------------------------------------------------------------
-- Users and role profiles
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.users (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role           public.user_role NOT NULL,
  phone          TEXT UNIQUE,
  email          TEXT UNIQUE,
  name           TEXT,
  password_hash  TEXT NOT NULL,
  status         public.user_status NOT NULL DEFAULT 'active',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (phone IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS public.admin_profiles (
  user_id     UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  admin_role  TEXT NOT NULL DEFAULT 'manager'
);

CREATE TABLE IF NOT EXISTS public.agent_profiles (
  user_id            UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  responsibilities   TEXT[] NOT NULL DEFAULT '{}',
  last_seen_at       TIMESTAMPTZ,
  last_device_id     TEXT
);

CREATE TABLE IF NOT EXISTS public.agent_devices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,
  device_label  TEXT,
  status        TEXT NOT NULL DEFAULT 'active',
  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ,
  UNIQUE (agent_id, device_id)
);

-- Used by the Node backend's own JWT sessions only. Supabase Auth keeps
-- its sessions in auth.sessions / auth.refresh_tokens.
CREATE TABLE IF NOT EXISTS public.refresh_tokens (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  expires_at  TIMESTAMPTZ NOT NULL,
  revoked_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_refresh_tokens_user ON public.refresh_tokens(user_id);

-- ---------------------------------------------------------------------------
-- Wallets, rates, fees, limits
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.wallets (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id           UUID NOT NULL UNIQUE REFERENCES public.users(id) ON DELETE CASCADE,
  available_cents       BIGINT NOT NULL DEFAULT 0 CHECK (available_cents >= 0),
  pending_cents         BIGINT NOT NULL DEFAULT 0 CHECK (pending_cents >= 0),
  total_deposit_cents   BIGINT NOT NULL DEFAULT 0,
  total_withdraw_cents  BIGINT NOT NULL DEFAULT 0,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.exchange_rates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      public.order_method NOT NULL,
  direction   public.order_direction NOT NULL,
  rate        NUMERIC(18,6) NOT NULL CHECK (rate > 0),
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_exchange_rates_lookup ON public.exchange_rates(method, direction, active);

CREATE TABLE IF NOT EXISTS public.fees (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      public.order_method NOT NULL,
  direction   public.order_direction NOT NULL,
  fee_type    public.fee_type NOT NULL,
  value       NUMERIC(18,6) NOT NULL CHECK (value >= 0), -- flat: cents; percent: 0-100
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fees_lookup ON public.fees(method, direction, active);

CREATE TABLE IF NOT EXISTS public.withdrawal_limits (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      public.order_method NOT NULL UNIQUE,
  min_cents   BIGINT NOT NULL DEFAULT 100,
  max_cents   BIGINT NOT NULL DEFAULT 100000000,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Orders and the wallet ledger
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.orders (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_code           TEXT NOT NULL UNIQUE,
  customer_id          UUID NOT NULL REFERENCES public.users(id),
  direction            public.order_direction NOT NULL,
  method               public.order_method NOT NULL,
  status               public.order_status NOT NULL DEFAULT 'pending',
  phone_number         TEXT,
  winwin_id            TEXT,
  deposit_code         TEXT,
  amount_cents         BIGINT NOT NULL CHECK (amount_cents > 0),
  rate                 NUMERIC(18,6) NOT NULL,
  fee_cents            BIGINT NOT NULL DEFAULT 0,
  net_cents            BIGINT NOT NULL,
  wallet_delta_cents   BIGINT NOT NULL,
  exchange_rate_id     UUID REFERENCES public.exchange_rates(id),
  fee_id               UUID REFERENCES public.fees(id),
  agent_id             UUID REFERENCES public.users(id),
  transaction_ref      TEXT,
  failure_reason       TEXT,
  idempotency_key      TEXT,
  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  processing_at        TIMESTAMPTZ,
  completed_at         TIMESTAMPTZ
);
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS automation_attempts INT NOT NULL DEFAULT 0;
CREATE INDEX IF NOT EXISTS idx_orders_customer ON public.orders(customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_status ON public.orders(status);
CREATE INDEX IF NOT EXISTS idx_orders_method_direction ON public.orders(method, direction, status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_deposit_code ON public.orders(deposit_code) WHERE deposit_code IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_orders_idempotency ON public.orders(customer_id, idempotency_key) WHERE idempotency_key IS NOT NULL;
COMMENT ON COLUMN public.orders.winwin_id IS 'Betting-platform account ID (WinWin, 1XBET, MELBET, ...); see orders.method';

CREATE TABLE IF NOT EXISTS public.ledger_entries (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id           UUID NOT NULL REFERENCES public.wallets(id) ON DELETE CASCADE,
  order_id            UUID REFERENCES public.orders(id),
  entry_type          public.ledger_entry_type NOT NULL,
  amount_cents        BIGINT NOT NULL CHECK (amount_cents > 0),
  balance_after_cents BIGINT NOT NULL,
  reason              TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_ledger_wallet ON public.ledger_entries(wallet_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_ledger_order ON public.ledger_entries(order_id);

-- ---------------------------------------------------------------------------
-- Payment confirmations
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sms_transactions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id          UUID NOT NULL REFERENCES public.users(id),
  device_id         TEXT,
  provider          TEXT NOT NULL,
  sender            TEXT,
  receiver          TEXT,
  amount_cents      BIGINT NOT NULL,
  transaction_ref   TEXT NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  matched_order_id  UUID REFERENCES public.orders(id),
  match_status      TEXT NOT NULL DEFAULT 'unmatched',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_transaction_ref ON public.sms_transactions(provider, transaction_ref);

CREATE TABLE IF NOT EXISTS public.winwin_transactions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submitted_by      UUID NOT NULL REFERENCES public.users(id),
  winwin_id         TEXT NOT NULL,
  deposit_code      TEXT,
  amount_cents      BIGINT NOT NULL,
  mobcash_ref       TEXT NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  matched_order_id  UUID REFERENCES public.orders(id),
  match_status      TEXT NOT NULL DEFAULT 'unmatched',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.winwin_transactions ADD COLUMN IF NOT EXISTS method public.order_method NOT NULL DEFAULT 'winwin';
DROP INDEX IF EXISTS public.idx_winwin_transaction_ref;
CREATE UNIQUE INDEX IF NOT EXISTS idx_platform_transaction_ref ON public.winwin_transactions(method, mobcash_ref);
COMMENT ON COLUMN public.winwin_transactions.winwin_id IS 'Betting-platform account ID; see winwin_transactions.method';

-- ---------------------------------------------------------------------------
-- Audit, idempotency
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.audit_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id     UUID REFERENCES public.users(id),
  actor_role   public.user_role,
  action       TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT,
  before_json  JSONB,
  after_json   JSONB,
  ip           TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_entity ON public.audit_logs(entity_type, entity_id);
CREATE INDEX IF NOT EXISTS idx_audit_actor ON public.audit_logs(actor_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.idempotency_keys (
  key            TEXT PRIMARY KEY,
  user_id        UUID REFERENCES public.users(id),
  endpoint       TEXT NOT NULL,
  request_hash   TEXT NOT NULL,
  status_code    INT,
  response_json  JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_idempotency_user_time ON public.idempotency_keys(user_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Payment integrations and MobCash automation
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_integrations (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider                  TEXT NOT NULL UNIQUE,
  status                    TEXT NOT NULL DEFAULT 'inactive',
  config_json               JSONB NOT NULL DEFAULT '{}',
  encrypted_username        BYTEA,
  username_iv               BYTEA,
  username_auth_tag         BYTEA,
  encrypted_password        BYTEA,
  password_iv               BYTEA,
  password_auth_tag         BYTEA,
  has_credentials           BOOLEAN NOT NULL DEFAULT false,
  last_test_at              TIMESTAMPTZ,
  last_test_result          TEXT,
  last_test_message         TEXT,
  last_successful_connection_at TIMESTAMPTZ,
  last_transaction_at       TIMESTAMPTZ,
  updated_by                UUID REFERENCES public.users(id),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payment_integrations
  ADD COLUMN IF NOT EXISTS automation_mode TEXT NOT NULL DEFAULT 'manual',
  ADD COLUMN IF NOT EXISTS dry_run BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS consecutive_failures INT NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS circuit_breaker_tripped_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS circuit_breaker_reason TEXT;

CREATE TABLE IF NOT EXISTS public.automation_runs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider          TEXT NOT NULL,
  run_type          TEXT NOT NULL,
  order_id          UUID REFERENCES public.orders(id),
  status            TEXT NOT NULL,
  message           TEXT,
  screenshot_base64 TEXT,
  started_at        TIMESTAMPTZ NOT NULL,
  finished_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_automation_runs_order ON public.automation_runs(order_id);
CREATE INDEX IF NOT EXISTS idx_automation_runs_provider_time ON public.automation_runs(provider, finished_at DESC);

-- ---------------------------------------------------------------------------
-- Settings managed from the Agent App (Node migration 006)
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.payment_methods (
  method      public.order_method PRIMARY KEY,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  updated_by  UUID REFERENCES public.users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.home_ads (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title       TEXT NOT NULL,
  body        TEXT,
  image_url   TEXT,
  link_url    TEXT,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  sort_order  INT NOT NULL DEFAULT 0,
  created_by  UUID REFERENCES public.users(id),
  updated_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_home_ads_enabled ON public.home_ads(enabled, sort_order);

CREATE TABLE IF NOT EXISTS public.deposit_numbers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      public.order_method NOT NULL,
  number      TEXT NOT NULL,
  label       TEXT,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES public.users(id),
  updated_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (method, number)
);

CREATE TABLE IF NOT EXISTS public.notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_by  UUID REFERENCES public.users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_notifications_created ON public.notifications(created_at DESC);

CREATE TABLE IF NOT EXISTS public.app_settings (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_by  UUID REFERENCES public.users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO public.app_settings (key) VALUES ('contact_whatsapp'), ('contact_facebook'), ('contact_telegram')
ON CONFLICT (key) DO NOTHING;
