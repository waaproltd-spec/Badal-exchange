-- Sahal refused a $0.10 transfer ("error occurred, please try again later")
-- after finding the receiver; its hand-sent transfers are all $1 or more.
-- The Sahal test payout is $1.
UPDATE public.sahal_payout_settings SET test_amount_cents = 100, updated_at = now() WHERE id AND test_amount_cents = 10;
ALTER TABLE public.sahal_payout_settings ALTER COLUMN test_amount_cents SET DEFAULT 100;
