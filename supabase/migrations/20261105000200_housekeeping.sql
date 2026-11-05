-- Housekeeping found by the database audit (diagnostics section 29):
--   * cron.job_run_details was 35 MB and growing without end (the feed job runs every 10 seconds);
--   * cashdesk_balances.requested_by is a foreign key with no index on a 34,000-row table.
-- Nothing financial is touched: only the scheduler's own run history is pruned (3 days kept).

CREATE INDEX IF NOT EXISTS idx_cashdesk_balances_requested_by ON public.cashdesk_balances (requested_by) WHERE requested_by IS NOT NULL;

CREATE OR REPLACE FUNCTION private.housekeeping()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_cron bigint := 0;
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      EXECUTE $q$WITH d AS (DELETE FROM cron.job_run_details WHERE end_time < now() - interval '3 days' RETURNING 1) SELECT count(*) FROM d$q$ INTO v_cron;
    EXCEPTION WHEN others THEN
      PERFORM private.health_raise('housekeeping_cron_history', 'warning', 'Ma nadiifin karo taariikhda cron-ka',
        jsonb_build_object('error', left(SQLERRM, 200)), 'ogolaansho ama cron schema', false, false);
      RETURN jsonb_build_object('cronRowsDeleted', 0, 'error', true);
    END;
  END IF;
  PERFORM private.health_clear('housekeeping_cron_history');
  RETURN jsonb_build_object('cronRowsDeleted', v_cron);
END $$;
REVOKE ALL ON FUNCTION private.housekeeping() FROM PUBLIC, anon, authenticated;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-housekeeping';
    PERFORM cron.schedule('baari-housekeeping', '11 3 * * *', 'SELECT private.housekeeping()');
  END IF;
END
$do$;
