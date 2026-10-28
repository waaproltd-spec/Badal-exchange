-- New betting companies BetJam and BetOnGame (CashdeskBot cash desks; see
-- 20261023000200_dbbet_betjam_betongame_cashdesk.sql). The enum values are
-- added on their own: a new enum value can only be used after the
-- transaction that added it has committed.
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'betjam';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'betongame';
