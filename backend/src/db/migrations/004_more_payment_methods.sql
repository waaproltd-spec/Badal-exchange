-- More payment methods beyond EVC Plus and WinWin (see src/lib/methods.ts).
-- Mobile money: Golis, Telesom, eDahab. Betting platforms: 1XBET, MELBET,
-- Betwinner, DBbet, 888STARZ.
--
-- New enum values can be added inside a transaction but not used until it
-- commits, so anything that references them lives in migration 005.
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'golis';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'telesom';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'edahab';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'onexbet';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'melbet';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'betwinner';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS 'dbbet';
ALTER TYPE order_method ADD VALUE IF NOT EXISTS '888starz';
