-- Automatic MobCash/WinWin processing. Additive to payment_integrations;
-- automation defaults to OFF (manual confirmation) and, once turned on,
-- defaults to dry-run so nothing moves real money until an admin has
-- explicitly verified it against the real portal and disabled dry-run.

ALTER TABLE payment_integrations
  ADD COLUMN automation_mode TEXT NOT NULL DEFAULT 'manual', -- 'manual' | 'automatic'
  ADD COLUMN dry_run BOOLEAN NOT NULL DEFAULT true,
  ADD COLUMN consecutive_failures INT NOT NULL DEFAULT 0,
  ADD COLUMN circuit_breaker_tripped_at TIMESTAMPTZ,
  ADD COLUMN circuit_breaker_reason TEXT;

-- Every automation attempt (a deposit-feed poll, or a single withdrawal
-- submission) is logged here regardless of outcome, for admin debugging.
-- screenshot_base64 is populated only on failure, and only ever read by
-- an admin -- never exposed to the customer or agent apps.
CREATE TABLE automation_runs (
  id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider          TEXT NOT NULL,
  run_type          TEXT NOT NULL, -- 'deposit_poll' | 'withdrawal_submit'
  order_id          UUID REFERENCES orders(id),
  status            TEXT NOT NULL, -- 'success' | 'failed' | 'dry_run'
  message           TEXT,
  screenshot_base64 TEXT,
  started_at        TIMESTAMPTZ NOT NULL,
  finished_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_automation_runs_order ON automation_runs(order_id);
CREATE INDEX idx_automation_runs_provider_time ON automation_runs(provider, finished_at DESC);

-- Per-order attempt counter so a flaky automation run can never be retried
-- unboundedly against the same withdrawal.
ALTER TABLE orders ADD COLUMN automation_attempts INT NOT NULL DEFAULT 0;
