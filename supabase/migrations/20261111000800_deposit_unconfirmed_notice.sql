-- TEAM BADAL CONTROL, step 3: "money seen, not confirmed" notice.
-- A payment that ARRIVED (a payment SMS read by an Agent phone, or an incoming transfer listed by Sahal) and is still not matched to a
-- deposit after 10 minutes is told to the group once, so nobody has to find it by looking. Only said: nothing is credited, matched or
-- changed here. Not repeated for an SMS already refused by the wallet phone/SIM check (that has its own critical incident), and only
-- for payments that arrived after this was switched on (no flood of old ones).
INSERT INTO public.app_settings (key, value) VALUES ('unconfirmed_notice_since', now()::text) ON CONFLICT (key) DO NOTHING;

CREATE OR REPLACE FUNCTION public.deposit_unconfirmed_todo()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_since timestamptz := COALESCE((SELECT value::timestamptz FROM public.app_settings WHERE key = 'unconfirmed_notice_since'), now());
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((
    SELECT jsonb_agg(x.j ORDER BY x.at)
      FROM (
        (SELECT s.received_at AS at, jsonb_build_object('key', 'sms:' || s.id, 'source', 'sms', 'provider', s.parsed_provider,
                  'phone', s.parsed_phone, 'amount', private.money(round(s.parsed_amount * 100)::bigint), 'at', s.received_at,
                  'minutes', floor(extract(epoch FROM now() - s.received_at) / 60)::int) AS j
           FROM public.sms_logs s
          WHERE s.match_status = 'unmatched' AND s.parsed_amount IS NOT NULL
            AND s.received_at >= v_since AND s.received_at < now() - interval '10 minutes' AND s.received_at > now() - interval '24 hours'
            AND COALESCE(s.match_failure_reason, '') NOT LIKE 'Rejected by the wallet phone/SIM check%'
            AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'unconfirmed' AND n.key = 'sms:' || s.id)
          ORDER BY s.received_at LIMIT 10)
        UNION ALL
        (SELECT m.first_seen_at, jsonb_build_object('key', 'sahal:' || m.id, 'source', 'sahal', 'provider', 'Sahal',
                  'phone', m.payer_phone, 'amount', private.money(COALESCE(m.amount_cents, 0)), 'at', m.first_seen_at,
                  'minutes', floor(extract(epoch FROM now() - m.first_seen_at) / 60)::int)
           FROM public.merchant_transactions m
          WHERE m.direction = 'in' AND m.match_status = 'unmatched' AND m.paired_sms_id IS NULL
            AND m.first_seen_at >= v_since AND m.first_seen_at < now() - interval '10 minutes' AND m.first_seen_at > now() - interval '24 hours'
            AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'unconfirmed' AND n.key = 'sahal:' || m.id)
          ORDER BY m.first_seen_at LIMIT 10)
      ) x), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.deposit_unconfirmed_todo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.deposit_unconfirmed_todo() TO service_role;
