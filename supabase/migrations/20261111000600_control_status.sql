-- TEAM BADAL CONTROL, step 1 (docs/TEAM_BADAL_CONTROL_PLAN.md): one read-only overview for the group command /status.
-- It only READS; no command of the group can move money or change a balance. Service role only (the BADAL AGENT function).
CREATE OR REPLACE FUNCTION public.control_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN jsonb_build_object(
    'at', now(),
    'lastScan', (SELECT jsonb_build_object('at', at, 'errors', errors, 'open', open) FROM private.health_scans ORDER BY id DESC LIMIT 1),
    'incidents', COALESCE((SELECT jsonb_agg(jsonb_build_object('severity', i.severity, 'title', i.title, 'since', i.first_seen)
                                           ORDER BY (i.severity = 'critical') DESC, i.last_seen DESC)
                             FROM (SELECT * FROM private.health_incidents WHERE status = 'open' ORDER BY last_seen DESC LIMIT 5) i), '[]'::jsonb),
    'openIncidents', (SELECT count(*) FROM private.health_incidents WHERE status = 'open'),
    'feed', (SELECT jsonb_build_object('provider', provider, 'state', state, 'lastOkAt', last_ok_at)
               FROM public.merchant_feed_status ORDER BY updated_at DESC LIMIT 1),
    'withdrawalsOpen', (SELECT count(*) FROM public.orders WHERE direction = 'withdraw' AND status IN ('pending', 'processing')),
    'depositsOpen', (SELECT count(*) FROM public.orders WHERE direction = 'deposit' AND status IN ('pending', 'processing')),
    'unmatchedSms24h', (SELECT count(*) FROM public.sms_logs WHERE match_status = 'unmatched' AND received_at > now() - interval '24 hours'));
END $$;
REVOKE ALL ON FUNCTION public.control_status() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.control_status() TO service_role;
