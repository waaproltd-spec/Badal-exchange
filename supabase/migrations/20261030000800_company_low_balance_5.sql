-- The low-balance level, the same for every company (Sahal, the cash desks, ...):
-- a balance under it shows as "Low balance" in Company Balances. It was $50; now $5.
INSERT INTO public.app_settings (key, value) VALUES ('company_low_balance', '5')
ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value;
