-- winwin_transactions now records agent/admin-confirmed deposits for every
-- betting platform, not just WinWin. Existing rows are WinWin.
--
-- The table keeps its name; `winwin_id` holds the customer's account ID on
-- whichever platform `method` names, and `mobcash_ref` the platform's own
-- transaction reference. References are only unique within one platform.
ALTER TABLE winwin_transactions
  ADD COLUMN method order_method NOT NULL DEFAULT 'winwin';

DROP INDEX IF EXISTS idx_winwin_transaction_ref;
CREATE UNIQUE INDEX idx_platform_transaction_ref ON winwin_transactions(method, mobcash_ref);

-- orders.winwin_id likewise holds the platform account ID for any platform
-- method (orders.method says which platform).
COMMENT ON COLUMN orders.winwin_id IS 'Betting-platform account ID (WinWin, 1XBET, MELBET, ...); see orders.method';
COMMENT ON COLUMN winwin_transactions.winwin_id IS 'Betting-platform account ID; see winwin_transactions.method';
