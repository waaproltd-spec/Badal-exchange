-- BAARI Exchange: EVC Plus <-> eDahab exchange orders with SMS payment
-- verification and automatic USSD payout.
--
-- A port of Dalab Internet's Money Exchange (waaproltd-spec/dalab-internet,
-- admin-backend-ts): the same tables and the same state machine
-- (pending -> in_progress -> completed / failed / cancelled):
--   041_money_exchange.sql        exchange_payout_wallets, exchange_corridors,
--                                 exchange_orders, exchange_dial_attempts
--   042/046                       client_request_id idempotency, pending dedup
--   004/011 + 043                 sms_logs with its two duplicate guards and
--                                 matched_exchange_order_id
-- and the same matching rules as smsLogs.routes.ts' findMatchingExchangeOrder
-- (see the matching migration that follows this one).
--
-- Baari's existing wallet deposits and withdrawals are unchanged.

-- ---------------------------------------------------------------------------
-- Payout wallets: Baari's own EVC Plus / eDahab wallets. The same wallet a
-- corridor pays OUT of is the number customers pay INTO for the opposite
-- direction (Dalab's settlement model). The PIN that authorizes a payout is
-- kept in Supabase Vault and handed to an agent device only for one new,
-- already-verified dial attempt.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exchange_payout_wallets (
  id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method         public.order_method NOT NULL CHECK (method IN ('evc_plus', 'edahab')),
  phone_number   TEXT NOT NULL,
  -- The agent device + SIM slot this wallet's SIM sits in. Payment SMS for
  -- this wallet must arrive there once it is set (Dalab's device/SIM
  -- guardrail); payouts are dialed from it.
  device_id      TEXT,
  sim_slot       INTEGER CHECK (sim_slot IN (1, 2)),
  pin_secret_id  UUID,
  created_by     UUID REFERENCES public.users(id),
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- USSD dial prefixes of the carriers' Dial-to-Pay menus (Dalab: payment_wallets.dial_prefix).
CREATE OR REPLACE FUNCTION private.exchange_dial_prefix(p_method public.order_method)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_method WHEN 'evc_plus' THEN '712' WHEN 'edahab' THEN '110' END
$$;

-- ---------------------------------------------------------------------------
-- Corridors: admin-set rate and fee per direction.
-- amount_received = amount_sent * rate - fee (fee flat, or % of amount_sent).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exchange_corridors (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  from_method       public.order_method NOT NULL CHECK (from_method IN ('evc_plus', 'edahab')),
  to_method         public.order_method NOT NULL CHECK (to_method IN ('evc_plus', 'edahab')),
  rate              NUMERIC(10,6) NOT NULL DEFAULT 1.0 CHECK (rate > 0),
  fee_type          TEXT NOT NULL DEFAULT 'fixed' CHECK (fee_type IN ('fixed', 'percentage')),
  fee_value         NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fee_value >= 0),
  min_amount        NUMERIC(10,2),
  max_amount        NUMERIC(10,2),
  payout_wallet_id  UUID REFERENCES public.exchange_payout_wallets(id) ON DELETE SET NULL,
  enabled           BOOLEAN NOT NULL DEFAULT true,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_method <> to_method),
  UNIQUE (from_method, to_method)
);

INSERT INTO public.exchange_corridors (from_method, to_method, enabled)
VALUES ('evc_plus', 'edahab', false), ('edahab', 'evc_plus', false)
ON CONFLICT (from_method, to_method) DO NOTHING;

-- ---------------------------------------------------------------------------
-- Exchange orders
--   pending      waiting for the customer's payment SMS ("Pending Payment")
--   in_progress  payment verified; payout queued / being dialed
--   completed    payout sent and confirmed
--   failed       payout failed: money collected, payout not sent; recoverable
--                through Retry payout or Reverse
--   cancelled    reversed by a manager
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exchange_orders (
  id                       TEXT PRIMARY KEY,
  customer_id              UUID REFERENCES public.users(id) ON DELETE SET NULL,
  corridor_id              UUID NOT NULL REFERENCES public.exchange_corridors(id) ON DELETE RESTRICT,
  from_method              public.order_method NOT NULL,
  to_method                public.order_method NOT NULL,
  amount_sent              NUMERIC(10,2) NOT NULL CHECK (amount_sent > 0),
  rate_applied             NUMERIC(10,6) NOT NULL,
  fee_applied              NUMERIC(10,2) NOT NULL,
  amount_received          NUMERIC(10,2) NOT NULL CHECK (amount_received >= 0),
  sender_phone             TEXT NOT NULL,
  receiver_phone           TEXT NOT NULL,
  collection_phone_number  TEXT,
  status                   TEXT NOT NULL DEFAULT 'pending'
                             CHECK (status IN ('pending', 'in_progress', 'completed', 'failed', 'cancelled')),
  client_request_id        UUID,
  -- Payment and payout trail (the audit fields the product asked for).
  payment_sms_log_id       UUID,
  payment_reference        TEXT,
  payment_received_at      TIMESTAMPTZ,
  payment_verified_at      TIMESTAMPTZ,
  payment_verified_by      TEXT,          -- 'sms_match' | 'manager'
  payout_reference         TEXT,
  payout_confirmed_at      TIMESTAMPTZ,
  payout_requested_at      TIMESTAMPTZ,  -- a manager asked for another payout attempt
  failure_reason           TEXT,
  agent_id                 UUID REFERENCES public.users(id) ON DELETE SET NULL,
  reversed_at              TIMESTAMPTZ,
  completed_at             TIMESTAMPTZ,
  created_at               TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at               TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_exchange_orders_customer_id ON public.exchange_orders(customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_exchange_orders_status ON public.exchange_orders(status);
CREATE UNIQUE INDEX IF NOT EXISTS idx_exchange_orders_client_request_id
  ON public.exchange_orders (client_request_id) WHERE client_request_id IS NOT NULL;
-- One pending order per customer + corridor + amount (Dalab 046): a payment
-- SMS can only ever have one order of the customer's to complete.
CREATE UNIQUE INDEX IF NOT EXISTS idx_exchange_orders_pending_content_dedup
  ON public.exchange_orders (customer_id, corridor_id, amount_sent) WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- Payout dial attempts (2-step USSD). One row per attempt; never holds the
-- PIN (carrier response text is scrubbed of it before it is stored).
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.exchange_dial_attempts (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  exchange_order_id TEXT NOT NULL REFERENCES public.exchange_orders(id) ON DELETE CASCADE,
  agent_id          UUID REFERENCES public.users(id) ON DELETE SET NULL,
  device_id         TEXT,
  sim_slot          INTEGER CHECK (sim_slot IN (1, 2)),
  attempt_number    INTEGER NOT NULL,
  step1_ussd_string TEXT,
  step1_response    TEXT,
  step2_response    TEXT,
  status            TEXT NOT NULL DEFAULT 'pending'
                      CHECK (status IN ('pending', 'step1_success', 'success', 'failed', 'ambiguous')),
  created_at        TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at      TIMESTAMPTZ,
  UNIQUE (exchange_order_id, attempt_number)
);

-- ---------------------------------------------------------------------------
-- sms_logs: every payment SMS an agent device uploads, matched or not (Dalab
-- 001/004/011/037/043). Unmatched rows are what SMS-before-order matching
-- picks up later.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.sms_logs (
  id                        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id                  UUID REFERENCES public.users(id) ON DELETE SET NULL,
  device_id                 TEXT,
  sender                    TEXT NOT NULL,
  body                      TEXT NOT NULL,
  parsed_provider           TEXT,
  parsed_amount             NUMERIC(10,2),
  parsed_phone              TEXT,
  transaction_ref           TEXT,
  sim_slot                  INTEGER,
  received_at               TIMESTAMPTZ NOT NULL,
  matched_exchange_order_id TEXT REFERENCES public.exchange_orders(id) ON DELETE SET NULL,
  matched_order_id          UUID REFERENCES public.orders(id) ON DELETE SET NULL,
  match_status              TEXT NOT NULL DEFAULT 'unmatched'
                              CHECK (match_status IN ('unmatched', 'matched', 'ambiguous', 'duplicate_blocked', 'ignored')),
  match_failure_reason      TEXT,
  created_at                TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- Duplicate guard 1 (Dalab 011): the carrier's own transaction reference.
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_logs_transaction_ref
  ON public.sms_logs (transaction_ref) WHERE transaction_ref IS NOT NULL;
-- Duplicate guard 2 (Dalab 004): a redelivered broadcast / client retry.
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_logs_dedup
  ON public.sms_logs (sender, body, date_trunc('minute', received_at AT TIME ZONE 'UTC'));
-- One SMS per exchange order (Dalab enforces this in code; here also in the database).
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_logs_one_per_exchange_order
  ON public.sms_logs (matched_exchange_order_id) WHERE matched_exchange_order_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_logs_one_per_order
  ON public.sms_logs (matched_order_id) WHERE matched_order_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sms_logs_unmatched
  ON public.sms_logs (received_at) WHERE match_status = 'unmatched';

-- Outgoing payout-confirmation SMS (carrier's "ayaad uwareejisay ..."), kept
-- for the audit trail whether or not it completed an order.
CREATE TABLE IF NOT EXISTS public.exchange_payout_confirmations (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  agent_id           UUID REFERENCES public.users(id) ON DELETE SET NULL,
  provider           TEXT,
  receiver_phone     TEXT NOT NULL,
  amount             NUMERIC(10,2) NOT NULL,
  raw_text           TEXT,
  exchange_order_id  TEXT REFERENCES public.exchange_orders(id) ON DELETE SET NULL,
  result             TEXT NOT NULL,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Row level security (reads only; every change goes through the functions)
-- ---------------------------------------------------------------------------
ALTER TABLE public.exchange_payout_wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_corridors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_dial_attempts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sms_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.exchange_payout_confirmations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.exchange_payout_wallets, public.exchange_corridors, public.exchange_orders,
  public.exchange_dial_attempts, public.sms_logs, public.exchange_payout_confirmations FROM anon, authenticated;

GRANT SELECT ON public.exchange_orders, public.exchange_corridors TO authenticated;

DROP POLICY IF EXISTS exchange_orders_select ON public.exchange_orders;
CREATE POLICY exchange_orders_select ON public.exchange_orders FOR SELECT TO authenticated
  USING ((customer_id = auth.uid() AND private.app_role() = 'customer') OR private.is_staff());

DROP POLICY IF EXISTS exchange_corridors_select ON public.exchange_corridors;
CREATE POLICY exchange_corridors_select ON public.exchange_corridors FOR SELECT TO authenticated
  USING (enabled OR private.is_staff());

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_publication_tables
    WHERE pubname = 'supabase_realtime' AND schemaname = 'public' AND tablename = 'exchange_orders'
  ) THEN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.exchange_orders;
  END IF;
END
$$;
