-- Read-only security checks for the production database (run in the Supabase
-- SQL editor). Nothing here changes anything.

-- 1. Agents who will be refused payment work once agent_duty_enforcement is on
--    (no evc_withdraw / evc_deposit duty and not a manager). Give them the duty
--    in the Agent App (Agents -> the agent -> Responsibilities) BEFORE deploying
--    if they do payouts, deposits or SMS.
SELECT u.name, u.phone, u.status, ap.responsibilities,
       ('evc_withdraw' = ANY (COALESCE(ap.responsibilities, '{}')) OR 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}'))) AS can_withdraw_work,
       ('evc_deposit' = ANY (COALESCE(ap.responsibilities, '{}')) OR 'manage_settings' = ANY (COALESCE(ap.responsibilities, '{}'))) AS can_deposit_work,
       ap.last_seen_at
FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
WHERE u.role = 'agent' AND u.status = 'active'
ORDER BY can_withdraw_work, can_deposit_work, u.name;

-- 2. Who actually did payment work in the last 30 days (completed / failed
--    withdrawals, rejected deposits): these must keep their duties.
SELECT u.name, u.phone, count(*) AS actions, max(a.created_at) AS last_action
FROM public.audit_logs a JOIN public.users u ON u.id = a.actor_id
WHERE a.created_at > now() - interval '30 days' AND u.role = 'agent'
  AND a.action IN ('order.complete_withdraw', 'order.fail', 'order.complete_deposit', 'deposit_rejected', 'deposit_verified_by_sms')
GROUP BY u.name, u.phone ORDER BY actions DESC;

-- 3. Wallet money added by agents in the last 30 days, per agent (the daily cap applies to non-managers).
SELECT u.name, count(*) AS adjustments, sum(w.amount_cents) / 100.0 AS added_usd, max(w.amount_cents) / 100.0 AS biggest_usd
FROM public.wallet_adjustments w JOIN public.users u ON u.id = w.agent_id
WHERE w.direction = 'add' AND w.created_at > now() - interval '30 days'
GROUP BY u.name ORDER BY added_usd DESC;

-- 4. Security settings in force.
SELECT key, value FROM public.app_settings
WHERE key IN ('agent_duty_enforcement', 'wallet_adjust_agent_daily_cap', 'withdrawal_verification', 'withdraw_limits', 'withdraw_balance_check');

-- 5. The latest suspicious-activity events.
SELECT created_at, kind, severity, title_so, alerted_at IS NOT NULL AS alerted FROM public.security_events ORDER BY created_at DESC LIMIT 50;

-- 6. Accounts with several customers sharing a payment number (the ones an admin authorized).
SELECT u.name, u.phone, g.methods, g.granted_at, (SELECT count(*) FROM public.customer_payment_numbers n WHERE n.customer_id = u.id) AS numbers
FROM public.payment_number_grants g JOIN public.users u ON u.id = g.customer_id WHERE g.enabled ORDER BY g.granted_at DESC;
