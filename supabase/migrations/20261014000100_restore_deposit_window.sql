-- Fix for 20261008000300: recalculating unpaid deposits to 1:1 also set
-- their updated_at to now(), which put deposits from days ago back inside
-- the 24-hour matching window. A new payment from the same number for the
-- same amount then fit both the new and an old deposit, was marked
-- ambiguous, and credited nothing.

-- 1. Old unpaid deposits go back to their real age.
UPDATE public.orders
SET updated_at = created_at
WHERE direction = 'deposit' AND status = 'pending'
  AND created_at < now() - interval '24 hours'
  AND updated_at > created_at;

-- 2. Payments from the last 24 hours that were marked ambiguous get matched
--    again (by the minute resweep, with the same rules: they only credit
--    when exactly one deposit fits).
UPDATE public.sms_logs
SET match_status = 'unmatched',
    match_failure_reason = 'Re-checked after the 24-hour window fix'
WHERE match_status = 'ambiguous' AND matched_order_id IS NULL
  AND received_at > now() - interval '24 hours';

-- 3. Match them now instead of waiting for the next minute.
SELECT private.resweep_unmatched_sms();
