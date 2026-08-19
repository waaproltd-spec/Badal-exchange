-- Badal Exchange: EVC Plus <-> Wallet <-> WinWin
-- Core schema. All money amounts are stored as BIGINT minor units (cents) to avoid float errors.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE user_role AS ENUM ('customer', 'agent', 'admin');
CREATE TYPE user_status AS ENUM ('active', 'disabled');
CREATE TYPE order_direction AS ENUM ('deposit', 'withdraw');
CREATE TYPE order_method AS ENUM ('evc_plus', 'winwin');
CREATE TYPE order_status AS ENUM ('pending', 'processing', 'completed', 'failed', 'cancelled', 'expired');
CREATE TYPE ledger_entry_type AS ENUM ('credit', 'debit', 'reserve', 'release');
CREATE TYPE fee_type AS ENUM ('flat', 'percent');

-- ---------------------------------------------------------------------------
-- Users (customers, agents, admins share one auth table; role-specific
-- profile detail lives in satellite tables so we never store agent/admin
-- fields on customer rows or vice versa).
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role           user_role NOT NULL,
  phone          TEXT UNIQUE,
  email          TEXT UNIQUE,
  name           TEXT,
  password_hash  TEXT NOT NULL,
  status         user_status NOT NULL DEFAULT 'active',
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (phone IS NOT NULL OR email IS NOT NULL)
);

CREATE TABLE admin_profiles (
  user_id     UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  admin_role  TEXT NOT NULL DEFAULT 'manager' -- 'super_admin' | 'manager' | 'support'
);

CREATE TABLE agent_profiles (
  user_id            UUID PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  responsibilities   TEXT[] NOT NULL DEFAULT '{}', -- e.g. {'evc_deposit','evc_withdraw'}
  last_seen_at       TIMESTAMPTZ,
  last_device_id     TEXT
);

CREATE TABLE agent_devices (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id      UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  device_id     TEXT NOT NULL,
  device_label  TEXT,
  status        TEXT NOT NULL DEFAULT 'active', -- active | revoked
  registered_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ,
  UNIQUE (agent_id, device_id)
);

CREATE TABLE refresh_tokens (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash  TEXT NOT NULL UNIQUE,
  expires_at  TIMESTAMPTZ NOT NULL,
  revoked_at  TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_refresh_tokens_user ON refresh_tokens(user_id);

-- ---------------------------------------------------------------------------
-- Wallet: one per customer. This table holds a *cached* snapshot for fast
-- reads; ledger_entries (below, after orders) is the append-only source of
-- truth used to audit and, if ever needed, rebuild the cache.
-- ---------------------------------------------------------------------------
CREATE TABLE wallets (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id           UUID NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  available_cents       BIGINT NOT NULL DEFAULT 0 CHECK (available_cents >= 0),
  pending_cents         BIGINT NOT NULL DEFAULT 0 CHECK (pending_cents >= 0),
  total_deposit_cents   BIGINT NOT NULL DEFAULT 0,
  total_withdraw_cents  BIGINT NOT NULL DEFAULT 0,
  updated_at            TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Exchange rates & fees. Admin-configurable; every order snapshots the rate
-- and fee that applied *at order creation time* so later admin edits never
-- retroactively change a past transaction.
-- ---------------------------------------------------------------------------
CREATE TABLE exchange_rates (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      order_method NOT NULL,
  direction   order_direction NOT NULL, -- deposit: method->wallet, withdraw: wallet->method
  rate        NUMERIC(18,6) NOT NULL CHECK (rate > 0),
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_exchange_rates_lookup ON exchange_rates(method, direction, active);

CREATE TABLE fees (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      order_method NOT NULL,
  direction   order_direction NOT NULL,
  fee_type    fee_type NOT NULL,
  value       NUMERIC(18,6) NOT NULL CHECK (value >= 0), -- flat: cents; percent: 0-100
  active      BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_fees_lookup ON fees(method, direction, active);

-- min/max withdrawal limits per method
CREATE TABLE withdrawal_limits (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      order_method NOT NULL UNIQUE,
  min_cents   BIGINT NOT NULL DEFAULT 100,
  max_cents   BIGINT NOT NULL DEFAULT 100000000,
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Orders: the single record type for every deposit and withdrawal.
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
  id                   UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  order_code           TEXT NOT NULL UNIQUE, -- human-facing e.g. EX12345
  customer_id          UUID NOT NULL REFERENCES users(id),
  direction            order_direction NOT NULL,
  method               order_method NOT NULL,
  status               order_status NOT NULL DEFAULT 'pending',

  -- counterparty details
  phone_number         TEXT,        -- EVC Plus
  winwin_id            TEXT,        -- WinWin
  deposit_code         TEXT,        -- WinWin deposit only, short unique match code

  -- money, all snapshot at creation time
  amount_cents         BIGINT NOT NULL CHECK (amount_cents > 0), -- amount the customer typed (input currency)
  rate                 NUMERIC(18,6) NOT NULL,
  fee_cents            BIGINT NOT NULL DEFAULT 0,
  net_cents            BIGINT NOT NULL, -- deposit: credited to wallet; withdraw: paid out to customer
  wallet_delta_cents   BIGINT NOT NULL, -- deposit: net credited; withdraw: amount+fee reserved/debited

  exchange_rate_id     UUID REFERENCES exchange_rates(id),
  fee_id               UUID REFERENCES fees(id),

  agent_id             UUID REFERENCES users(id), -- agent who verified/processed this order
  transaction_ref      TEXT, -- provider (EVC/WinWin) transaction/reference id once verified
  failure_reason       TEXT,

  idempotency_key      TEXT,

  created_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT now(),
  processing_at        TIMESTAMPTZ,
  completed_at         TIMESTAMPTZ
);
CREATE INDEX idx_orders_customer ON orders(customer_id, created_at DESC);
CREATE INDEX idx_orders_status ON orders(status);
CREATE INDEX idx_orders_method_direction ON orders(method, direction, status);
CREATE UNIQUE INDEX idx_orders_deposit_code ON orders(deposit_code) WHERE deposit_code IS NOT NULL;
CREATE UNIQUE INDEX idx_orders_idempotency ON orders(customer_id, idempotency_key) WHERE idempotency_key IS NOT NULL;

CREATE TABLE ledger_entries (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_id           UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  order_id            UUID REFERENCES orders(id),
  entry_type          ledger_entry_type NOT NULL,
  amount_cents        BIGINT NOT NULL CHECK (amount_cents > 0),
  balance_after_cents BIGINT NOT NULL, -- available balance after this entry
  reason              TEXT NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_ledger_wallet ON ledger_entries(wallet_id, created_at DESC);
CREATE INDEX idx_ledger_order ON ledger_entries(order_id);

-- ---------------------------------------------------------------------------
-- SMS transactions captured by the Agent App (EVC Plus deposit verification).
-- Only the minimal extracted fields are stored -- never the raw SMS body.
-- ---------------------------------------------------------------------------
CREATE TABLE sms_transactions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id          UUID NOT NULL REFERENCES users(id),
  device_id         TEXT,
  provider          TEXT NOT NULL, -- e.g. 'hormuud_evc_plus'
  sender            TEXT,
  receiver          TEXT,
  amount_cents      BIGINT NOT NULL,
  transaction_ref   TEXT NOT NULL, -- provider transaction/reference id, unique dedupe key
  occurred_at       TIMESTAMPTZ NOT NULL,
  matched_order_id  UUID REFERENCES orders(id),
  match_status      TEXT NOT NULL DEFAULT 'unmatched', -- unmatched | matched | duplicate
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_sms_transaction_ref ON sms_transactions(provider, transaction_ref);

-- WinWin/MobCash confirmations submitted by an authorized agent/admin after
-- observing the real transaction in the MobCash system (never auto-generated).
CREATE TABLE winwin_transactions (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  submitted_by      UUID NOT NULL REFERENCES users(id),
  winwin_id         TEXT NOT NULL,
  deposit_code      TEXT,
  amount_cents      BIGINT NOT NULL,
  mobcash_ref       TEXT NOT NULL,
  occurred_at       TIMESTAMPTZ NOT NULL,
  matched_order_id  UUID REFERENCES orders(id),
  match_status      TEXT NOT NULL DEFAULT 'unmatched',
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_winwin_transaction_ref ON winwin_transactions(mobcash_ref);

-- ---------------------------------------------------------------------------
-- Audit log: every admin/agent mutation, and every wallet-affecting state
-- transition, is recorded here.
-- ---------------------------------------------------------------------------
CREATE TABLE audit_logs (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id     UUID REFERENCES users(id),
  actor_role   user_role,
  action       TEXT NOT NULL,
  entity_type  TEXT NOT NULL,
  entity_id    TEXT,
  before_json  JSONB,
  after_json   JSONB,
  ip           TEXT,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_audit_entity ON audit_logs(entity_type, entity_id);
CREATE INDEX idx_audit_actor ON audit_logs(actor_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Idempotency keys: any client-supplied Idempotency-Key on a mutating
-- request is stored with its response so a retried request never double-runs.
-- ---------------------------------------------------------------------------
CREATE TABLE idempotency_keys (
  key            TEXT PRIMARY KEY,
  user_id        UUID REFERENCES users(id),
  endpoint       TEXT NOT NULL,
  request_hash   TEXT NOT NULL,
  status_code    INT,
  response_json  JSONB,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Payment integrations (EVC Plus, MobCash/WinWin manager account). Secrets
-- are stored encrypted (AES-256-GCM) -- never in plaintext, never returned
-- by any API response. Only admin_role in ('super_admin','manager') may
-- read (masked) or write these rows; every write is audit-logged.
-- ---------------------------------------------------------------------------
CREATE TABLE payment_integrations (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider                  TEXT NOT NULL UNIQUE, -- 'evc_plus' | 'mobcash_winwin'
  status                    TEXT NOT NULL DEFAULT 'inactive', -- active | inactive
  config_json               JSONB NOT NULL DEFAULT '{}', -- non-secret settings, e.g. api_base_url
  encrypted_username        BYTEA,
  username_iv               BYTEA,
  username_auth_tag         BYTEA,
  encrypted_password        BYTEA,
  password_iv               BYTEA,
  password_auth_tag         BYTEA,
  has_credentials           BOOLEAN NOT NULL DEFAULT false,
  last_test_at              TIMESTAMPTZ,
  last_test_result          TEXT,           -- success | failed | not_configured
  last_test_message         TEXT,
  last_successful_connection_at TIMESTAMPTZ,
  last_transaction_at       TIMESTAMPTZ,
  updated_by                UUID REFERENCES users(id),
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
