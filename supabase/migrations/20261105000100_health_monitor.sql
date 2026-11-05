-- Platform health monitor and self-healing.
--
-- Every minute the database runs private.health_scan(): a set of read-only checks of the whole platform
-- (Sahal feed, cron jobs, calls to the Edge Functions, stuck withdrawals, payments refused by the SIM check,
-- the wallet/ledger invariants, database load, push delivery, the cash register integrations, the Telegram
-- alert chat, the security posture). Every problem becomes ONE incident (a second sighting only counts it);
-- when the condition is gone the incident is resolved.
--
-- Self-healing is limited to predefined, safe repairs of things that are not money (re-waking a worker, an
-- interrupted sign-in, a stuck message delivery); each repair is recorded and judged on the next scan, and
-- after 3 tries that did not help the incident goes to the developer instead of being retried for ever.
-- Nothing here ever changes a balance, a ledger entry or an order's money: a failed wallet/ledger check only
-- raises a critical incident.
--
-- The owner is told on Telegram by the support bot (functions/support-bot, route /health): once per new
-- problem (after it has lasted 2 minutes, so a flicker is not reported), again every 6 hours for a critical
-- one that is still open (24 for a warning), and once when it is resolved.

CREATE TABLE IF NOT EXISTS private.health_incidents (
  id                    BIGSERIAL PRIMARY KEY,
  key                   TEXT NOT NULL,
  severity              TEXT NOT NULL CHECK (severity IN ('info', 'warning', 'critical')),
  title                 TEXT NOT NULL,
  cause                 TEXT,
  detail                JSONB NOT NULL DEFAULT '{}'::jsonb,
  status                TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'resolved')),
  first_seen            TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen             TIMESTAMPTZ NOT NULL DEFAULT now(),
  occurrences           INT NOT NULL DEFAULT 1,
  repair                TEXT,
  repair_result         TEXT,
  repairs               INT NOT NULL DEFAULT 0,
  last_repair_at        TIMESTAMPTZ,
  financial_impact      BOOLEAN NOT NULL DEFAULT false,
  customer_impact       BOOLEAN NOT NULL DEFAULT false,
  needs_developer       BOOLEAN NOT NULL DEFAULT false,
  alerted_at            TIMESTAMPTZ,
  alert_count           INT NOT NULL DEFAULT 0,
  resolved_at           TIMESTAMPTZ,
  auto_resolved         BOOLEAN,
  resolution_alerted_at TIMESTAMPTZ
);
CREATE UNIQUE INDEX IF NOT EXISTS health_incidents_one_open ON private.health_incidents (key) WHERE status = 'open';
CREATE INDEX IF NOT EXISTS health_incidents_recent ON private.health_incidents (last_seen DESC);
REVOKE ALL ON private.health_incidents FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS private.health_scans (
  id      BIGSERIAL PRIMARY KEY,
  at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  checks  INT NOT NULL,
  errors  INT NOT NULL,
  open    INT NOT NULL,
  ms      INT NOT NULL
);
REVOKE ALL ON private.health_scans FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------- incident helpers

CREATE OR REPLACE FUNCTION private.health_raise(
  p_key text, p_severity text, p_title text, p_detail jsonb DEFAULT '{}'::jsonb,
  p_cause text DEFAULT NULL, p_financial boolean DEFAULT false, p_customer boolean DEFAULT false, p_developer boolean DEFAULT false
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  UPDATE private.health_incidents SET
    last_seen = now(), occurrences = occurrences + 1, title = p_title, detail = p_detail,
    cause = COALESCE(p_cause, cause),
    severity = CASE WHEN p_severity = 'critical' OR severity = 'critical' THEN 'critical'
                    WHEN p_severity = 'warning' OR severity = 'warning' THEN 'warning' ELSE 'info' END,
    financial_impact = financial_impact OR p_financial, customer_impact = customer_impact OR p_customer,
    needs_developer = needs_developer OR p_developer
  WHERE key = p_key AND status = 'open';
  IF NOT FOUND THEN
    INSERT INTO private.health_incidents (key, severity, title, detail, cause, financial_impact, customer_impact, needs_developer)
    VALUES (p_key, p_severity, p_title, p_detail, p_cause, p_financial, p_customer, p_developer);
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.health_clear(p_key text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE private.health_incidents
  SET status = 'resolved', resolved_at = now(), auto_resolved = true,
      repair_result = CASE WHEN repairs > 0 THEN 'worked: the condition is gone' ELSE COALESCE(repair_result, 'the condition is gone') END
  WHERE key = p_key AND status = 'open'
$$;

-- Resolves the open incidents with this prefix whose key is not in the list (the condition went away).
CREATE OR REPLACE FUNCTION private.health_clear_missing(p_prefix text, p_keys text[])
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE private.health_incidents
  SET status = 'resolved', resolved_at = now(), auto_resolved = true,
      repair_result = CASE WHEN repairs > 0 THEN 'worked: the condition is gone' ELSE COALESCE(repair_result, 'the condition is gone') END
  WHERE status = 'open' AND key LIKE p_prefix || '%' AND NOT (key = ANY (COALESCE(p_keys, '{}')))
$$;

-- A safe repair was tried. The third try that did not help hands the incident to the developer.
CREATE OR REPLACE FUNCTION private.health_repaired(p_key text, p_action text, p_result text)
RETURNS void LANGUAGE sql SECURITY DEFINER SET search_path = '' AS $$
  UPDATE private.health_incidents
  SET repair = p_action, repair_result = p_result, repairs = repairs + 1, last_repair_at = now(),
      needs_developer = needs_developer OR repairs + 1 >= 3
  WHERE key = p_key AND status = 'open'
$$;

-- May a repair be tried now? Not more than 3 times, and not within 5 minutes of the last.
CREATE OR REPLACE FUNCTION private.health_may_repair(p_key text)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT repairs < 3 AND (last_repair_at IS NULL OR last_repair_at < now() - interval '5 minutes')
                     FROM private.health_incidents WHERE key = p_key AND status = 'open'), true)
$$;

-- ---------------------------------------------------------------- the scan

CREATE OR REPLACE FUNCTION private.health_scan()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t0 timestamptz := clock_timestamp();
  v_checks int := 0;
  v_errors int := 0;
  v_n bigint;
  v_m bigint;
  v_txt text;
  v_keys text[];
  f record;
  r record;
BEGIN
  -- 1. Sahal feed ----------------------------------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT * INTO f FROM public.merchant_feed_status WHERE provider = 'golis';
    IF f.provider IS NULL OR f.state = 'not_configured' THEN
      PERFORM private.health_clear('sahal_feed');
    ELSIF f.state = 'ok' AND f.checked_at > now() - interval '3 minutes' THEN
      PERFORM private.health_clear('sahal_feed');
    ELSIF f.state = 'needs_code' AND EXISTS (SELECT 1 FROM private.merchant_feed_sessions s WHERE s.provider = 'golis' AND s.second_at > now() - interval '10 minutes') THEN
      PERFORM private.health_clear('sahal_feed'); -- waiting for its access code: normal
    ELSE
      PERFORM private.health_raise('sahal_feed',
        CASE WHEN f.last_ok_at IS NULL OR f.last_ok_at < now() - interval '15 minutes' THEN 'critical' ELSE 'warning' END,
        'Sahal ma akhrinayo lacagaha',
        jsonb_build_object('state', f.state, 'resultCode', f.result_code, 'minutesSinceLastOk',
                           round(extract(epoch FROM now() - COALESCE(f.last_ok_at, now() - interval '1 day')) / 60),
                           'message', left(COALESCE(f.message, ''), 200)),
        CASE f.state WHEN 'stopped' THEN 'Sahal ayaa diiday sign-in-ka ama code-ka lama aqbalin' WHEN 'needs_code' THEN 'code-ka Sahal lama galin 10 daqiiqo' ELSE 'akhrinta feed-ka way joogsatay' END,
        true, true);
      -- repairs (not money): an interrupted sign-in, a worker that was not woken
      IF f.state = 'signing_in' AND f.updated_at < now() - interval '5 minutes' AND private.health_may_repair('sahal_feed') THEN
        UPDATE public.merchant_feed_status SET state = 'ready', message = 'Signing in again (the health monitor)', updated_at = now() WHERE provider = 'golis';
        PERFORM private.merchant_feed_kick();
        PERFORM private.health_repaired('sahal_feed', 'sign-in oo hakadsan dib loo bilaabay', 'sugitaan: scan-ka xiga ayaa xaqiijin doona');
      ELSIF f.state IN ('ready', 'ok') AND private.health_may_repair('sahal_feed') THEN
        PERFORM private.merchant_feed_kick();
        PERFORM private.health_repaired('sahal_feed', 'worker-ka feed-ka dib ayaa loo kiciyay', 'sugitaan: scan-ka xiga ayaa xaqiijin doona');
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:sahal_feed', 'warning', 'Hubinta Sahal feed ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 2. cron jobs that failed ---------------------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    v_keys := '{}';
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
      FOR r IN EXECUTE $q$SELECT j.jobname, count(*) AS n, max(left(d.return_message, 160)) AS msg
                          FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
                          WHERE d.status = 'failed' AND d.start_time > now() - interval '15 minutes' AND j.jobname LIKE 'baari-%'
                          GROUP BY j.jobname$q$ LOOP
        v_keys := v_keys || ('cron_failed:' || r.jobname);
        PERFORM private.health_raise('cron_failed:' || r.jobname, 'warning', 'Shaqada cron-ka ' || r.jobname || ' way fashilantay',
          jsonb_build_object('failures15min', r.n, 'message', r.msg), 'cron-ka ayaa khalad soo celiyay', false, false);
      END LOOP;
    END IF;
    PERFORM private.health_clear_missing('cron_failed:', v_keys);
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:cron', 'warning', 'Hubinta cron-ka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 3. calls from the database to the Edge Functions ----------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
      EXECUTE $q$SELECT count(*) FILTER (WHERE status_code >= 400 OR error_msg IS NOT NULL), count(*)
                  FROM net._http_response WHERE created > now() - interval '15 minutes'$q$ INTO v_n, v_m;
      IF v_n >= 5 AND v_n * 5 >= v_m THEN
        PERFORM private.health_raise('edge_calls_failing', 'warning', 'Wicitaannada Edge Functions-ka waa fashilmayaan',
          jsonb_build_object('failed15min', v_n, 'calls15min', v_m), 'function-ku ma jawaabayo ama wuu diidayaa (403/5xx/timeout)', false, true);
      ELSE
        PERFORM private.health_clear('edge_calls_failing');
      END IF;
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:edge_calls', 'warning', 'Hubinta Edge calls ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 4. withdrawals that wait too long (money is held for them) ---------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) INTO v_n FROM public.orders WHERE direction = 'withdraw' AND status = 'processing' AND updated_at < now() - interval '30 minutes';
    IF v_n > 0 THEN
      PERFORM private.health_raise('withdrawals_stuck_processing', 'critical', 'Bixinno ayaa ku xanuunsaday "processing" in ka badan 30 daqiiqo',
        jsonb_build_object('orders', v_n), 'bixinta ayaa la bilaabay laakiin lama xaqiijin (telefoon/Sahal)', true, true, true);
    ELSE
      PERFORM private.health_clear('withdrawals_stuck_processing');
    END IF;
    SELECT count(*) INTO v_n FROM public.orders WHERE direction = 'withdraw' AND status = 'pending' AND created_at < now() - interval '3 hours';
    IF v_n > 0 THEN
      PERFORM private.health_raise('withdrawals_waiting_long', 'warning', 'Bixinno ayaa sugaya in ka badan 3 saacadood',
        jsonb_build_object('orders', v_n), 'wax agent ah ayaan qaadan ama Sahal/auto-payout wuu joogsaday', false, true);
    ELSE
      PERFORM private.health_clear('withdrawals_waiting_long');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:withdrawals', 'warning', 'Hubinta bixinnada ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 5. payment SMS refused by the phone/SIM check ------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*), count(DISTINCT device_id) INTO v_n, v_m FROM public.sms_logs
     WHERE match_status = 'unmatched' AND created_at > now() - interval '1 hour'
       AND match_failure_reason LIKE 'Rejected by the wallet phone/SIM check%';
    IF v_n > 0 THEN
      PERFORM private.health_raise('sms_device_rejected', 'critical', 'SMS-yada lacagta waa la diidayaa (hubinta telefoon/SIM)',
        jsonb_build_object('sms1h', v_n, 'phones', v_m), 'wallet-ka EVC Plus ee Wallets & Auto Payout wuxuu u qoran yahay telefoon/SIM kale', true, true);
    ELSE
      PERFORM private.health_clear('sms_device_rejected');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:sms', 'warning', 'Hubinta SMS ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 6. wallet / ledger invariants: critical, never repaired automatically ----------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) INTO v_n FROM public.wallets w
      JOIN LATERAL (SELECT l.balance_after_cents FROM public.ledger_entries l WHERE l.wallet_id = w.id
                    ORDER BY l.created_at DESC, l.id DESC LIMIT 1) last ON true
     WHERE last.balance_after_cents <> w.available_cents;
    IF v_n > 0 THEN
      PERFORM private.health_raise('ledger_wallet_mismatch', 'critical', 'Haraaga wallet-ka ma la mid ahan ledger-ka',
        jsonb_build_object('wallets', v_n), 'wax ayaa si khaldan u beddelay haraaga ama ledger-ka (ha la saxin gacan ahaan ilaa la baaro)', true, true, true);
    ELSE
      PERFORM private.health_clear('ledger_wallet_mismatch');
    END IF;
    SELECT count(*) INTO v_n FROM public.wallets w
     WHERE w.pending_cents <> COALESCE((SELECT sum(o.wallet_delta_cents) FROM public.orders o
                                         WHERE o.customer_id = w.customer_id AND o.direction = 'withdraw' AND o.status IN ('pending', 'processing')), 0);
    IF v_n > 0 THEN
      PERFORM private.health_raise('ledger_held_mismatch', 'critical', 'Lacagta la hayo ma la mid ahan bixinnada furan',
        jsonb_build_object('wallets', v_n), 'bixin ayaa dhammaatay iyadoo lacagtii la hayay aan la sii deyn', true, true, true);
    ELSE
      PERFORM private.health_clear('ledger_held_mismatch');
    END IF;
    SELECT count(*) INTO v_n FROM public.wallets WHERE available_cents < 0 OR pending_cents < 0;
    IF v_n > 0 THEN
      PERFORM private.health_raise('ledger_negative_balance', 'critical', 'Wallet leh haraag taban',
        jsonb_build_object('wallets', v_n), 'bixin ka badan haraaga ayaa la sameeyay', true, true, true);
    ELSE
      PERFORM private.health_clear('ledger_negative_balance');
    END IF;
    SELECT count(*) INTO v_n FROM (SELECT l.order_id FROM public.ledger_entries l JOIN public.orders o ON o.id = l.order_id
                                    WHERE o.direction = 'deposit' AND l.entry_type = 'credit' GROUP BY l.order_id HAVING count(*) > 1) x;
    IF v_n > 0 THEN
      PERFORM private.health_raise('ledger_double_credit', 'critical', 'Deposit mid ah ayaa mar ka badan la credit-gareeyay',
        jsonb_build_object('orders', v_n), 'laba isha (SMS/Sahal) ayaa labadaba credit-gareeyay ama retry', true, true, true);
    ELSE
      PERFORM private.health_clear('ledger_double_credit');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:ledger', 'warning', 'Hubinta ledger-ka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 7. database load ---------------------------------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) INTO v_n FROM pg_stat_activity;
    v_m := current_setting('max_connections')::int;
    IF v_n * 10 >= v_m * 8 THEN
      PERFORM private.health_raise('db_connections', 'warning', 'Isku-xidhka database-ka waa ka badan yahay 80%',
        jsonb_build_object('connections', v_n, 'max', v_m), 'isku-xidhka ayaa la furay oo aan la xidhin', false, true);
    ELSE
      PERFORM private.health_clear('db_connections');
    END IF;
    SELECT count(*) INTO v_n FROM pg_stat_activity
     WHERE state = 'active' AND backend_type = 'client backend' AND pid <> pg_backend_pid()
       AND now() - query_start > interval '3 minutes' AND query NOT ILIKE '%pg_stat%' AND query NOT ILIKE 'autovacuum%';
    IF v_n > 0 THEN
      PERFORM private.health_raise('db_long_queries', 'warning', 'Query-yo database ah ayaa socda in ka badan 3 daqiiqo',
        jsonb_build_object('queries', v_n), 'query culus ama lock', false, true);
    ELSE
      PERFORM private.health_clear('db_long_queries');
    END IF;
    SELECT count(*) INTO v_n FROM pg_stat_activity WHERE wait_event_type = 'Lock' AND now() - query_start > interval '60 seconds';
    IF v_n > 0 THEN
      PERFORM private.health_raise('db_lock_waits', 'warning', 'Wax ayaa sugaya lock in ka badan 60 ilbiriqsi',
        jsonb_build_object('waiting', v_n), 'transaction dheer oo la hayo', false, true);
    ELSE
      PERFORM private.health_clear('db_lock_waits');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:database', 'warning', 'Hubinta database-ka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 8. push notifications that fail (a gone token, FCM 404, is normal and not counted) -------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) FILTER (WHERE status = 'failed' AND COALESCE(last_error, '') NOT ILIKE '%NOT_FOUND%' AND COALESCE(last_error, '') NOT ILIKE '%UNREGISTERED%'),
           count(*) INTO v_n, v_m
      FROM public.push_notifications WHERE created_at > now() - interval '1 hour';
    IF v_n >= 5 AND v_n * 2 >= v_m THEN
      PERFORM private.health_raise('push_failing', 'warning', 'Ogeysiisyada push-ka way fashilmayaan',
        jsonb_build_object('failed1h', v_n, 'total1h', v_m), 'FCM key ama function-ka push-ka ayaa xaalad xun ku jira', false, true);
    ELSE
      PERFORM private.health_clear('push_failing');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:push', 'warning', 'Hubinta push-ka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 9. scheduled messages stuck in "sending": released (not money) -------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) INTO v_n FROM public.broadcast_deliveries WHERE status = 'sending' AND claimed_at < now() - interval '15 minutes';
    IF v_n > 0 THEN
      PERFORM private.health_raise('broadcast_stuck', 'warning', 'Fariimo jadwal ah ayaa ku xanuunsaday "sending"',
        jsonb_build_object('deliveries', v_n), 'worker-ka ayaa dhintay isagoo fariimo haysta', false, true);
      IF private.health_may_repair('broadcast_stuck') THEN
        UPDATE public.broadcast_deliveries SET status = 'pending', claimed_at = NULL WHERE status = 'sending' AND claimed_at < now() - interval '15 minutes';
        PERFORM private.health_repaired('broadcast_stuck', 'fariimaha oo dib loogu celiyay safka (pending)', 'worker-ka ayaa mar kale qaadan doona');
      END IF;
    ELSE
      PERFORM private.health_clear('broadcast_stuck');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:broadcast', 'warning', 'Hubinta fariimaha jadwalka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 10. cash register integrations (CashdeskBot): the latest balance read of each platform --------------
  BEGIN
    v_checks := v_checks + 1;
    v_keys := '{}';
    FOR r IN SELECT DISTINCT ON (method) method::text AS method, ok, left(COALESCE(error, ''), 200) AS error, checked_at
               FROM public.cashdesk_balances WHERE checked_at > now() - interval '3 hours' ORDER BY method, checked_at DESC LOOP
      IF NOT r.ok THEN
        v_keys := v_keys || ('integration:' || r.method);
        PERFORM private.health_raise('integration:' || r.method, 'warning', 'Cash register-ka ' || r.method || ' ma jawaabayo',
          jsonb_build_object('error', r.error), 'furaha/sign-ka CashdeskBot ama adeegga platform-ka', false, true);
      END IF;
    END LOOP;
    PERFORM private.health_clear_missing('integration:', v_keys);
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:integrations', 'warning', 'Hubinta isku-xidhka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 11. can the owner be told? The alert chats ---------------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    IF NOT EXISTS (SELECT 1 FROM public.support_admin WHERE id) THEN
      PERFORM private.health_raise('owner_chat_not_linked', 'warning', 'Chat-ka Owner-ka lama xirin: digniinaha Telegram ma gaadhi karaan',
        '{}'::jsonb, 'bot-ka support-ka: u dir /start @Badalexchangeadmin ama /linkgroup', false, false);
    ELSE
      PERFORM private.health_clear('owner_chat_not_linked');
    END IF;
    IF EXISTS (SELECT 1 FROM public.withdrawal_alert_chat WHERE last_error IS NOT NULL AND checked_at > now() - interval '10 minutes') THEN
      PERFORM private.health_raise('withdrawal_alerts_bot', 'warning', 'Bot-ka digniinaha bixinta wuxuu soo celiyay khalad',
        jsonb_build_object('error', left((SELECT last_error FROM public.withdrawal_alert_chat), 200)), 'Telegram ama token', false, false);
    ELSE
      PERFORM private.health_clear('withdrawal_alerts_bot');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:owner_chat', 'warning', 'Hubinta chat-ka Owner-ka ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- 12. the Agent SIM fallback: is any phone reading SMS (info only) ------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    IF EXISTS (SELECT 1 FROM public.agent_devices WHERE status = 'active' AND sms_listening_at > now() - interval '24 hours') THEN
      PERFORM private.health_clear('agent_sms_reader');
    ELSE
      PERFORM private.health_raise('agent_sms_reader', 'info', 'Telefoon Agent ah oo SMS akhrinaya 24 saac ma jiro (SIM fallback)', '{}'::jsonb,
        'Agent App-ka lama furin ama SMS permission ayaa la qaaday', false, false);
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
  END;

  -- 13. security posture ------------------------------------------------------------------------------------
  BEGIN
    v_checks := v_checks + 1;
    SELECT count(*) INTO v_n FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity;
    IF v_n > 0 THEN
      PERFORM private.health_raise('security_tables_without_rls', 'critical', 'Jadwal public ah oo aan lahayn row level security',
        jsonb_build_object('tables', v_n, 'names', (SELECT string_agg(c.relname, ', ') FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
                                                     WHERE n.nspname = 'public' AND c.relkind = 'r' AND NOT c.relrowsecurity)),
        'migration cusub ayaa ilaaway ENABLE ROW LEVEL SECURITY', false, false, true);
    ELSE
      PERFORM private.health_clear('security_tables_without_rls');
    END IF;
    SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname IN ('public', 'private') AND p.prosecdef AND p.proconfig IS NULL;
    IF v_n > 0 THEN
      PERFORM private.health_raise('security_definer_without_search_path', 'critical', 'Function-yo SECURITY DEFINER ah oo aan lahayn search_path',
        jsonb_build_object('functions', v_n), 'function cusub ayaa ilaaway SET search_path', false, false, true);
    ELSE
      PERFORM private.health_clear('security_definer_without_search_path');
    END IF;
  EXCEPTION WHEN others THEN
    v_errors := v_errors + 1;
    PERFORM private.health_raise('health_check_error:security', 'warning', 'Hubinta amniga ayaa qalloocatay', jsonb_build_object('error', left(SQLERRM, 200)));
  END;

  -- A check that works again clears its own "check failed" incident.
  PERFORM private.health_clear_missing('health_check_error:',
    ARRAY(SELECT key FROM private.health_incidents WHERE status = 'open' AND key LIKE 'health_check_error:%' AND last_seen >= t0));

  INSERT INTO private.health_scans (checks, errors, open, ms)
  VALUES (v_checks, v_errors, (SELECT count(*) FROM private.health_incidents WHERE status = 'open'),
          round(extract(epoch FROM clock_timestamp() - t0) * 1000)::int);
  DELETE FROM private.health_scans WHERE id < (SELECT max(id) - 2000 FROM private.health_scans);
  DELETE FROM private.health_incidents WHERE status = 'resolved' AND resolved_at < now() - interval '90 days';
  RETURN jsonb_build_object('checks', v_checks, 'errors', v_errors,
    'open', (SELECT count(*) FROM private.health_incidents WHERE status = 'open'));
END $$;

-- ---------------------------------------------------------------- alerts to the owner

-- Which incidents the owner must be told about now: a new one that lasted 2 minutes, a critical one again after
-- 6 hours (24 for a warning), a resolved one once. Info incidents are never sent.
CREATE OR REPLACE FUNCTION private.health_alert_rows()
RETURNS TABLE (id bigint, kind text) LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT i.id, CASE WHEN i.alerted_at IS NULL THEN 'new' ELSE 'repeat' END
    FROM private.health_incidents i
   WHERE i.status = 'open' AND i.severity IN ('warning', 'critical')
     AND ((i.alerted_at IS NULL AND i.first_seen < now() - interval '2 minutes')
          OR (i.alerted_at IS NOT NULL AND i.alerted_at < now() - (CASE i.severity WHEN 'critical' THEN interval '6 hours' ELSE interval '24 hours' END)))
  UNION ALL
  SELECT i.id, 'resolved'
    FROM private.health_incidents i
   WHERE i.status = 'resolved' AND i.alerted_at IS NOT NULL AND i.resolution_alerted_at IS NULL AND i.resolved_at > now() - interval '1 day'
$$;

CREATE OR REPLACE FUNCTION public.health_alert_claim()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object(
      'id', i.id, 'kind', a.kind, 'key', i.key, 'severity', i.severity, 'title', i.title, 'cause', i.cause, 'detail', i.detail,
      'repair', i.repair, 'repairResult', i.repair_result, 'repairs', i.repairs, 'financial', i.financial_impact,
      'customers', i.customer_impact, 'developer', i.needs_developer, 'firstSeen', i.first_seen, 'occurrences', i.occurrences,
      'autoResolved', i.auto_resolved) ORDER BY i.severity DESC, i.id)
    FROM private.health_alert_rows() a JOIN private.health_incidents i ON i.id = a.id), '[]'::jsonb);
END $$;

CREATE OR REPLACE FUNCTION public.health_alert_done(p_done jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  d jsonb;
BEGIN
  PERFORM private.require_service();
  FOR d IN SELECT * FROM jsonb_array_elements(COALESCE(p_done, '[]'::jsonb)) LOOP
    IF d ->> 'kind' = 'resolved' THEN
      UPDATE private.health_incidents SET resolution_alerted_at = now() WHERE id = (d ->> 'id')::bigint;
    ELSE
      UPDATE private.health_incidents SET alerted_at = now(), alert_count = alert_count + 1 WHERE id = (d ->> 'id')::bigint;
    END IF;
  END LOOP;
END $$;

-- What an Edge Function found (a Telegram webhook, an external service) and repaired.
CREATE OR REPLACE FUNCTION public.health_report_external(
  p_key text, p_ok boolean, p_severity text DEFAULT 'warning', p_title text DEFAULT NULL, p_detail jsonb DEFAULT '{}'::jsonb,
  p_cause text DEFAULT NULL, p_repair text DEFAULT NULL, p_repair_result text DEFAULT NULL
) RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  IF p_key !~ '^[a-z0-9_:.-]{3,80}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid key');
  END IF;
  IF p_ok THEN
    PERFORM private.health_clear(p_key);
    RETURN;
  END IF;
  PERFORM private.health_raise(p_key, CASE WHEN p_severity IN ('info', 'warning', 'critical') THEN p_severity ELSE 'warning' END,
    COALESCE(NULLIF(left(p_title, 200), ''), p_key), COALESCE(p_detail, '{}'::jsonb), left(p_cause, 300), false, true);
  IF p_repair IS NOT NULL THEN
    PERFORM private.health_repaired(p_key, left(p_repair, 300), left(COALESCE(p_repair_result, ''), 300));
  END IF;
END $$;

-- ---------------------------------------------------------------- the dashboard

CREATE OR REPLACE FUNCTION public.manage_system_health()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'lastScan', (SELECT jsonb_build_object('at', at, 'checks', checks, 'errors', errors, 'ms', ms) FROM private.health_scans ORDER BY id DESC LIMIT 1),
    'ownerChatLinked', EXISTS (SELECT 1 FROM public.support_admin WHERE id),
    'open', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', i.id, 'key', i.key, 'severity', i.severity, 'title', i.title, 'cause', i.cause, 'detail', i.detail,
        'firstSeen', i.first_seen, 'lastSeen', i.last_seen, 'occurrences', i.occurrences,
        'repair', i.repair, 'repairResult', i.repair_result, 'repairs', i.repairs,
        'financial', i.financial_impact, 'customers', i.customer_impact, 'developer', i.needs_developer)
        ORDER BY (i.severity = 'critical') DESC, (i.severity = 'warning') DESC, i.first_seen)
      FROM private.health_incidents i WHERE i.status = 'open'), '[]'::jsonb),
    'resolved', COALESCE((SELECT jsonb_agg(x) FROM (
        SELECT jsonb_build_object('id', i.id, 'key', i.key, 'title', i.title, 'severity', i.severity, 'resolvedAt', i.resolved_at,
               'repair', i.repair, 'repairResult', i.repair_result, 'autoResolved', i.auto_resolved) AS x
          FROM private.health_incidents i WHERE i.status = 'resolved' AND i.resolved_at > now() - interval '2 days'
         ORDER BY i.resolved_at DESC LIMIT 20) q), '[]'::jsonb));
END $$;

-- ---------------------------------------------------------------- scheduling

-- Wakes the support bot's /health route (it sends the alerts and checks its Telegram webhook) when an alert is
-- waiting and every 5 minutes otherwise, and the cashier bots' /health route every 5 minutes.
CREATE OR REPLACE FUNCTION private.health_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF NOT (EXISTS (SELECT 1 FROM private.health_alert_rows()) OR extract(minute FROM now())::int % 5 = 0) THEN
    RETURN;
  END IF;
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 50000)'
  USING rtrim(v_url, '/') || '/support-bot/health', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
  -- Every 5 minutes also the cashier bots' webhooks (a lost one is registered again).
  IF extract(minute FROM now())::int % 5 = 0 THEN
    EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
    USING rtrim(v_url, '/') || '/telegram-bot/health', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
  END IF;
EXCEPTION WHEN others THEN
  RAISE WARNING 'health_kick: %', SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION private.health_tick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.health_scan();
  PERFORM private.health_kick();
END $$;

REVOKE ALL ON FUNCTION private.health_raise(text, text, text, jsonb, text, boolean, boolean, boolean), private.health_clear(text),
  private.health_clear_missing(text, text[]), private.health_repaired(text, text, text), private.health_may_repair(text),
  private.health_scan(), private.health_alert_rows(), private.health_kick(), private.health_tick() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.health_alert_claim(), public.health_alert_done(jsonb),
  public.health_report_external(text, boolean, text, text, jsonb, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.health_alert_claim(), public.health_alert_done(jsonb),
  public.health_report_external(text, boolean, text, text, jsonb, text, text, text) TO service_role;
REVOKE ALL ON FUNCTION public.manage_system_health() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_system_health() TO authenticated, service_role;

DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-health';
    PERFORM cron.schedule('baari-health', '* * * * *', 'SELECT private.health_tick()');
  END IF;
END
$do$;
