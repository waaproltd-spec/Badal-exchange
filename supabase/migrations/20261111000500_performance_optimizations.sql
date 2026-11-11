-- Performance optimizations from the audit (docs/PERFORMANCE_AUDIT.md, measured on production 2026-11-11).
--
-- The load on the free plan is WRITES (WAL / Disk I/O) and Edge Function invocations, not reads. Every change below
-- removes work that changes nothing:
--   * writes that store the same value again are skipped (the row is not touched);
--   * the workers are woken only when there is something for them (or at a slower idle pace);
--   * the scheduler's own run history is kept for one day instead of three, and pruned in small batches.
-- NOT changed: matching, crediting, payout, wallet and ledger logic, any balance, any financial record.
-- Every skipped write is one that would store exactly the same values (or only move a "last seen" time by
-- less than the heartbeat below), so no reader can tell the difference.

-- ---------------------------------------------------------------- A. housekeeping and indexes

-- The run history of pg_cron: one day is enough to see a failure (the health scan looks 15 minutes back).
-- Deleted in batches of 20,000 so a large backlog never becomes one huge transaction.
CREATE OR REPLACE FUNCTION private.housekeeping()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cron bigint := 0;
  v_n bigint;
  v_loops int := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      LOOP
        EXECUTE $q$WITH d AS (DELETE FROM cron.job_run_details WHERE runid IN (
                       SELECT runid FROM cron.job_run_details WHERE end_time < now() - interval '1 day' LIMIT 20000)
                     RETURNING 1) SELECT count(*) FROM d$q$ INTO v_n;
        v_cron := v_cron + v_n;
        v_loops := v_loops + 1;
        EXIT WHEN v_n < 20000 OR v_loops >= 10;
      END LOOP;
    EXCEPTION WHEN others THEN
      PERFORM private.health_raise('housekeeping_cron_history', 'warning', 'Ma nadiifin karo taariikhda cron-ka',
        jsonb_build_object('error', left(SQLERRM, 200)), 'ogolaansho ama cron schema', false, false);
      RETURN jsonb_build_object('cronRowsDeleted', v_cron, 'error', true);
    END;
  END IF;
  PERFORM private.health_clear('housekeeping_cron_history');
  RETURN jsonb_build_object('cronRowsDeleted', v_cron);
END $$;
REVOKE ALL ON FUNCTION private.housekeeping() FROM PUBLIC, anon, authenticated;

-- Every 6 hours (small batches) instead of once a day (one big delete).
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-housekeeping';
    PERFORM cron.schedule('baari-housekeeping', '11 */6 * * *', 'SELECT private.housekeeping()');
  END IF;
END
$do$;

-- Duplicate of the primary key (same columns), and an index that was never used on a table written every 5 minutes.
DROP INDEX IF EXISTS public.dev_audit_recent;
DROP INDEX IF EXISTS public.idx_cashdesk_balances_requested_by;

-- ---------------------------------------------------------------- B. writes that store the same value again

-- 1. The matcher re-checks every unmatched SMS each minute and wrote the same "reason" text again (723,750 updates
--    on a 1,181-row table, 543 MB of WAL). PostgreSQL's own trigger skips an UPDATE that changes nothing.
--    A real change (status, order, new reason) is a different row and goes through untouched.
DROP TRIGGER IF EXISTS zz_skip_identical_update ON public.sms_logs;
CREATE TRIGGER zz_skip_identical_update BEFORE UPDATE ON public.sms_logs
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();
DROP TRIGGER IF EXISTS zz_skip_identical_update ON public.merchant_transactions;
CREATE TRIGGER zz_skip_identical_update BEFORE UPDATE ON public.merchant_transactions
  FOR EACH ROW EXECUTE FUNCTION suppress_redundant_updates_trigger();

-- 2. Rows that a worker "touches" on every run (a time stamp that only says "still here"): skipped while nothing
--    else changed and the time stamp is younger than the heartbeat. Arguments: heartbeat seconds, the time stamp
--    column that proves freshness, then the columns that are ignored in the comparison.
CREATE OR REPLACE FUNCTION private.skip_heartbeat_update()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
  v_old jsonb := to_jsonb(OLD);
  v_new jsonb := to_jsonb(NEW);
  v_seen timestamptz := (to_jsonb(OLD) ->> TG_ARGV[1])::timestamptz;
  i int;
BEGIN
  FOR i IN 1..TG_NARGS - 1 LOOP
    v_old := v_old - TG_ARGV[i];
    v_new := v_new - TG_ARGV[i];
  END LOOP;
  IF v_old = v_new AND v_seen IS NOT NULL AND v_seen > now() - make_interval(secs => TG_ARGV[0]::int) THEN
    RETURN NULL; -- nothing but "still here" changed, and that was recorded moments ago
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.skip_heartbeat_update() FROM PUBLIC, anon, authenticated;

-- The feed worker saved its session and cookies on every 10-second run (nobody reads their time stamp): every 5 minutes.
DROP TRIGGER IF EXISTS zz_heartbeat ON private.merchant_feed_sessions;
CREATE TRIGGER zz_heartbeat BEFORE UPDATE ON private.merchant_feed_sessions
  FOR EACH ROW EXECUTE FUNCTION private.skip_heartbeat_update('300', 'updated_at', 'updated_at');

-- The feed status is read with 2- and 3-minute limits ("connected" / "unreachable"): a 30-second heartbeat keeps it
-- exact. A change of state, message, result code or rows seen is always written at once.
DROP TRIGGER IF EXISTS zz_heartbeat ON public.merchant_feed_status;
CREATE TRIGGER zz_heartbeat BEFORE UPDATE ON public.merchant_feed_status
  FOR EACH ROW EXECUTE FUNCTION private.skip_heartbeat_update('30', 'checked_at', 'checked_at', 'last_ok_at', 'updated_at');

-- The Telegram polling position of the BADAL AGENT bot: checked_at is only shown to managers.
DROP TRIGGER IF EXISTS zz_heartbeat ON public.withdrawal_alert_chat;
CREATE TRIGGER zz_heartbeat BEFORE UPDATE ON public.withdrawal_alert_chat
  FOR EACH ROW EXECUTE FUNCTION private.skip_heartbeat_update('300', 'checked_at', 'checked_at');

-- 3. Company balances: a read that returns exactly what the two before it returned only moves the time of the
--    newest row (the freshness checks read max(checked_at)); the first and last row of a steady period stay.
--    A changed balance, limit or error, or a read asked by a person, is a new row as before.
CREATE OR REPLACE FUNCTION public.company_balance_record(
  p_method text, p_balance numeric, p_limit numeric, p_error text, p_requested_by uuid DEFAULT NULL
)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_method public.order_method := private.parse_method(p_method);
  v_ok boolean := p_balance IS NOT NULL;
  v_bal bigint := round(p_balance * 100)::bigint;
  v_lim bigint := round(p_limit * 100)::bigint;
  v_err text := CASE WHEN p_balance IS NULL THEN left(COALESCE(NULLIF(btrim(p_error), ''), 'No balance returned'), 300) END;
  v_last public.cashdesk_balances;
  v_prev public.cashdesk_balances;
BEGIN
  PERFORM private.require_service();
  IF NOT private.is_cashdesk_method(v_method) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'No balance source for ' || p_method);
  END IF;
  IF p_requested_by IS NULL THEN
    SELECT * INTO v_last FROM public.cashdesk_balances WHERE method = v_method ORDER BY checked_at DESC LIMIT 1;
    IF v_last.id IS NOT NULL AND v_last.requested_by IS NULL THEN
      SELECT * INTO v_prev FROM public.cashdesk_balances WHERE method = v_method AND id <> v_last.id ORDER BY checked_at DESC LIMIT 1;
      IF v_prev.id IS NOT NULL AND v_prev.requested_by IS NULL
         AND (v_last.ok, v_last.balance_cents, v_last.limit_cents, v_last.error) IS NOT DISTINCT FROM (v_ok, v_bal, v_lim, v_err)
         AND (v_prev.ok, v_prev.balance_cents, v_prev.limit_cents, v_prev.error) IS NOT DISTINCT FROM (v_ok, v_bal, v_lim, v_err) THEN
        UPDATE public.cashdesk_balances SET checked_at = now() WHERE id = v_last.id;
        RETURN;
      END IF;
    END IF;
  END IF;
  INSERT INTO public.cashdesk_balances (method, ok, balance_cents, limit_cents, error, requested_by)
  VALUES (v_method, v_ok, v_bal, v_lim, v_err, p_requested_by);
  -- Keep a month of reads.
  DELETE FROM public.cashdesk_balances WHERE method = v_method AND checked_at < now() - interval '31 days';
END $$;
REVOKE ALL ON FUNCTION public.company_balance_record(text, numeric, numeric, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.company_balance_record(text, numeric, numeric, text, uuid) TO service_role;

-- ---------------------------------------------------------------- C. wake the workers only when there is work

-- Messages (scheduled broadcasts): wake the worker when a schedule is due or a message waits (or a sender died
-- mid-way). The same gate the push kick already uses. 43,000 invocations a month were empty runs.
CREATE OR REPLACE FUNCTION private.broadcast_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM public.broadcast_schedules WHERE status = 'active' AND deleted_at IS NULL AND next_run_at <= now())
          OR EXISTS (SELECT 1 FROM public.broadcast_deliveries WHERE status = 'pending')
          OR EXISTS (SELECT 1 FROM public.broadcast_deliveries WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes')) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 55000)'
  USING rtrim(v_url, '/') || '/support-bot/broadcast', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'broadcast_kick: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION private.broadcast_kick() FROM PUBLIC, anon, authenticated;

-- BADAL AGENT alerts: the function also reads Telegram commands (/report, /start, /movehere) and sends the daily
-- report and the live notices, so it is never switched off. While a withdrawal is open or was touched in the last
-- 30 minutes it still runs every 30 seconds as before; when nothing is going on it runs once a minute (every other
-- cron tick), which halves the idle invocations (43,000 a month) and changes no alert, only the idle pace.
CREATE OR REPLACE FUNCTION private.withdrawal_alerts_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  IF extract(second FROM clock_timestamp()) >= 30
     AND NOT EXISTS (SELECT 1 FROM public.orders o
                      WHERE o.direction = 'withdraw'
                        AND (o.status IN ('pending', 'processing') OR o.updated_at > now() - interval '30 minutes')) THEN
    RETURN; -- idle: the other tick of this minute does the work
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/withdrawal-alerts', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'withdrawal_alerts_kick: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION private.withdrawal_alerts_kick() FROM PUBLIC, anon, authenticated;

-- The platform kick evaluated platform_eligible() (several sub-selects) for every order row each minute (167 ms,
-- 8 million heap reads). The same test, with the cheap conditions first so the planner stops at once.
CREATE OR REPLACE FUNCTION private.platform_kick_if_work()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.orders o
              WHERE o.status = 'pending' AND o.auto_claimed_at IS NULL AND o.created_at > now() - interval '1 day'
                AND private.platform_eligible(o)) THEN
    PERFORM private.platform_kick();
  END IF;
END $$;
REVOKE ALL ON FUNCTION private.platform_kick_if_work() FROM PUBLIC, anon, authenticated;

-- The health scan every 2 minutes instead of every minute (1.5 s average, 4.9 s at p95): a problem is seen at most
-- one minute later. The alert delivery and every check are unchanged.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-health';
    PERFORM cron.schedule('baari-health', '*/2 * * * *', 'SELECT private.health_tick()');
  END IF;
END
$do$;
