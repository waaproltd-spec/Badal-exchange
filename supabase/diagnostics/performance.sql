-- Performance and resource audit (READ ONLY: only SELECT; changes nothing).
-- Run with: Deploy to Supabase -> mode "performance". A statement that the role may not run prints its
-- error and the report goes on.
\set ON_ERROR_STOP off
\pset pager off

\echo '== 1. Database size, connections limit, cache hit ratio =='
SELECT pg_size_pretty(pg_database_size(current_database())) AS database_size,
       current_setting('max_connections') AS max_connections,
       current_setting('shared_buffers') AS shared_buffers,
       version() AS version;
SELECT datname, numbackends, xact_commit, xact_rollback, blks_read, blks_hit,
       round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct,
       temp_files, pg_size_pretty(temp_bytes) AS temp_bytes, tup_returned, tup_fetched, tup_inserted, tup_updated, tup_deleted,
       stats_reset
FROM pg_stat_database WHERE datname = current_database();

\echo
\echo '== 2. Connections now (by role, application and state) =='
SELECT usename, COALESCE(NULLIF(application_name, ''), '(none)') AS application, state, count(*)
FROM pg_stat_activity WHERE datname = current_database() GROUP BY 1, 2, 3 ORDER BY 4 DESC LIMIT 20;

\echo
\echo '== 3. The 25 biggest tables: size, rows, dead rows, scans, writes =='
SELECT s.relname AS table_name,
       pg_size_pretty(pg_total_relation_size(s.relid)) AS total,
       pg_size_pretty(pg_relation_size(s.relid)) AS heap,
       pg_size_pretty(pg_indexes_size(s.relid)) AS indexes,
       s.n_live_tup AS live, s.n_dead_tup AS dead,
       s.seq_scan, s.idx_scan, s.n_tup_ins AS ins, s.n_tup_upd AS upd, s.n_tup_hot_upd AS hot_upd, s.n_tup_del AS del,
       to_char(GREATEST(s.last_autovacuum, s.last_vacuum), 'MM-DD HH24:MI') AS last_vacuum
FROM pg_stat_user_tables s ORDER BY pg_total_relation_size(s.relid) DESC LIMIT 25;

\echo
\echo '== 4. Tables with the most writes (inserts + updates + deletes) since the statistics began =='
SELECT relname AS table_name, n_tup_ins AS ins, n_tup_upd AS upd, n_tup_del AS del,
       n_tup_ins + n_tup_upd + n_tup_del AS writes, n_live_tup AS live
FROM pg_stat_user_tables ORDER BY n_tup_ins + n_tup_upd + n_tup_del DESC LIMIT 15;

\echo
\echo '== 5. Tables read by full scans (seq_scan) more than by index, bigger than 500 rows =='
SELECT relname AS table_name, seq_scan, seq_tup_read, COALESCE(idx_scan, 0) AS idx_scan, n_live_tup AS live
FROM pg_stat_user_tables WHERE seq_scan > COALESCE(idx_scan, 0) AND n_live_tup > 500
ORDER BY seq_tup_read DESC LIMIT 15;

\echo
\echo '== 6. Table cache hit (heap and index) of the busiest tables =='
SELECT relname AS table_name, heap_blks_read, heap_blks_hit,
       round(100.0 * heap_blks_hit / NULLIF(heap_blks_hit + heap_blks_read, 0), 2) AS heap_hit_pct,
       idx_blks_read, idx_blks_hit
FROM pg_statio_user_tables ORDER BY heap_blks_read + COALESCE(idx_blks_read, 0) DESC LIMIT 12;

\echo
\echo '== 7. Statements: most total time (pg_stat_statements) =='
SELECT calls, round(total_exec_time::numeric / 1000, 1) AS total_s, round(mean_exec_time::numeric, 2) AS mean_ms, rows,
       shared_blks_read AS blks_read, shared_blks_dirtied AS blks_dirtied, shared_blks_written AS blks_written,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY total_exec_time DESC LIMIT 15;

\echo
\echo '== 8. Statements: most disk blocks read + dirtied + written (the Disk I/O cost) =='
SELECT calls, shared_blks_read AS blks_read, shared_blks_dirtied AS blks_dirtied, shared_blks_written AS blks_written,
       round(mean_exec_time::numeric, 2) AS mean_ms, rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY shared_blks_read + shared_blks_dirtied + shared_blks_written DESC LIMIT 15;

\echo
\echo '== 9. Statements: most calls =='
SELECT calls, round(mean_exec_time::numeric, 3) AS mean_ms, rows, left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY calls DESC LIMIT 15;

\echo
\echo '== 10. Statements: slowest on average (more than 100 calls) =='
SELECT calls, round(mean_exec_time::numeric, 1) AS mean_ms, round(max_exec_time::numeric, 0) AS max_ms, rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND calls > 100
ORDER BY mean_exec_time DESC LIMIT 10;

\echo
\echo '== 11. Scheduled jobs: schedule, and runs / failures / average time in the history kept =='
SELECT j.jobname, j.schedule, j.active,
       count(d.runid) AS runs, count(*) FILTER (WHERE d.status = 'failed') AS failed,
       round(avg(EXTRACT(epoch FROM (d.end_time - d.start_time)) * 1000)::numeric, 1) AS avg_ms,
       min(d.start_time)::timestamp(0) AS history_from
FROM cron.job j LEFT JOIN cron.job_run_details d ON d.jobid = j.jobid
GROUP BY j.jobid, j.jobname, j.schedule, j.active ORDER BY count(d.runid) DESC;
SELECT 'cron.job_run_details rows: ' || count(*) || ', size ' || pg_size_pretty(pg_total_relation_size('cron.job_run_details')) FROM cron.job_run_details;

\echo
\echo '== 12. pg_net: requests and responses kept =='
SELECT 'net._http_response rows: ' || count(*) || ', size ' || pg_size_pretty(pg_total_relation_size('net._http_response')) FROM net._http_response;
SELECT status_code, count(*) FROM net._http_response GROUP BY 1 ORDER BY 2 DESC LIMIT 8;
SELECT 'net.http_request_queue rows: ' || count(*) FROM net.http_request_queue;

\echo
\echo '== 13. Indexes: never used (any size) =='
SELECT s.relname AS table_name, s.indexrelname AS index_name, pg_size_pretty(pg_relation_size(s.indexrelid)) AS size, s.idx_scan,
       i.indisunique AS is_unique, i.indisprimary AS is_primary
FROM pg_stat_user_indexes s JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisprimary ORDER BY pg_relation_size(s.indexrelid) DESC LIMIT 25;

\echo
\echo '== 14. Indexes: duplicates (same table and same columns) =='
SELECT indrelid::regclass AS table_name, array_agg(indexrelid::regclass) AS duplicate_indexes, pg_size_pretty(sum(pg_relation_size(indexrelid))::bigint) AS size
FROM pg_index GROUP BY indrelid, indkey, indpred::text, indexprs::text HAVING count(*) > 1;

\echo
\echo '== 15. Foreign keys with no index on the referencing column (tables over 1000 rows) =='
SELECT c.conrelid::regclass AS table_name, a.attname AS column_name, c.confrelid::regclass AS references_table,
       (SELECT n_live_tup FROM pg_stat_user_tables t WHERE t.relid = c.conrelid) AS rows
FROM pg_constraint c JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
WHERE c.contype = 'f' AND c.connamespace = 'public'::regnamespace
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.conrelid AND i.indkey[0] = c.conkey[1])
  AND (SELECT n_live_tup FROM pg_stat_user_tables t WHERE t.relid = c.conrelid) > 1000
ORDER BY 4 DESC LIMIT 20;

\echo
\echo '== 16. Indexes per table (more than 6 means write overhead) =='
SELECT tablename, count(*) AS indexes, pg_size_pretty(sum(pg_relation_size(format('%I.%I', schemaname, indexname)::regclass))::bigint) AS size
FROM pg_indexes WHERE schemaname = 'public' GROUP BY tablename HAVING count(*) > 6 ORDER BY 2 DESC;

\echo
\echo '== 17. Realtime: tables published and the size of the realtime schema =='
SELECT schemaname, tablename FROM pg_publication_tables WHERE pubname = 'supabase_realtime' ORDER BY 1, 2;
SELECT 'realtime schema size: ' || pg_size_pretty(sum(pg_total_relation_size(c.oid))::bigint) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'realtime' AND c.relkind = 'r';

\echo
\echo '== 18. Log-like and queue tables: rows and size (growth without a limit) =='
SELECT relname AS table_name, n_live_tup AS rows, pg_size_pretty(pg_total_relation_size(relid)) AS size
FROM pg_stat_user_tables
WHERE relname IN ('sms_logs', 'merchant_transactions', 'ledger_entries', 'orders', 'audit_logs', 'cashdesk_balances', 'sahal_balances',
                  'health_scans', 'health_incidents', 'merchant_feed_events', 'push_notifications', 'broadcast_deliveries', 'notifications', 'dev_audit')
ORDER BY pg_total_relation_size(relid) DESC;

\echo
\echo '== 19. Autovacuum / bloat: tables with dead rows over 10% =='
SELECT relname AS table_name, n_live_tup AS live, n_dead_tup AS dead, round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS dead_pct
FROM pg_stat_user_tables WHERE n_dead_tup > 100 AND n_dead_tup > 0.1 * n_live_tup ORDER BY n_dead_tup DESC LIMIT 15;

\echo
\echo '== 20. Checkpoints and background writer (Disk I/O pressure) =='
SELECT * FROM pg_stat_checkpointer;
SELECT * FROM pg_stat_bgwriter;

\echo
\echo '== 21. Storage buckets =='
SELECT bucket_id, count(*) AS objects, pg_size_pretty(COALESCE(sum((metadata ->> 'size')::bigint), 0)) AS size FROM storage.objects GROUP BY 1 ORDER BY 2 DESC;

\echo
\echo '== 22. Which tables the functions called by the cron jobs write to (the health scan, the broadcasts, the housekeeping) =='
SELECT jobname, left(regexp_replace(command, '\s+', ' ', 'g'), 120) AS command FROM cron.job ORDER BY jobname;

\echo
\echo '== 23. Statements that write TEMPORARY FILES (the 74 GB of temp bytes) =='
SELECT calls, temp_blks_written, temp_blks_read, round(mean_exec_time::numeric, 1) AS mean_ms, rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database()) AND temp_blks_written > 0
ORDER BY temp_blks_written DESC LIMIT 12;

\echo
\echo '== 24. Statements that write the most WAL (bytes) =='
SELECT calls, pg_size_pretty(wal_bytes) AS wal, wal_records, round(mean_exec_time::numeric, 1) AS mean_ms,
       left(regexp_replace(query, '\s+', ' ', 'g'), 150) AS query
FROM extensions.pg_stat_statements WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
ORDER BY wal_bytes DESC LIMIT 12;

\echo
\echo '== 25. The housekeeping job: definition, runs, and its incident =='
SELECT jobid, jobname, schedule, active, database, username FROM cron.job WHERE jobname = 'baari-housekeeping';
SELECT count(*) AS runs, max(start_time) AS last_run, max(status) AS status, max(left(return_message, 200)) AS message
FROM cron.job_run_details WHERE jobid = (SELECT jobid FROM cron.job WHERE jobname = 'baari-housekeeping');
SELECT key, status, left(title, 80) AS title, occurrences, last_seen FROM private.health_incidents WHERE key LIKE 'housekeeping%';
SELECT 'cron.job_run_details oldest row: ' || min(start_time)::text || ', newest ' || max(start_time)::text FROM cron.job_run_details;
SELECT 'rows older than 3 days (what housekeeping should delete): ' || count(*) FROM cron.job_run_details WHERE end_time < now() - interval '3 days';

\echo
\echo '== 26. Unmatched SMS being re-checked every minute (the 24 hour window) =='
SELECT match_status, count(*) AS rows, count(*) FILTER (WHERE received_at > now() - interval '24 hours') AS last_24h FROM public.sms_logs GROUP BY 1 ORDER BY 2 DESC;
SELECT left(match_failure_reason, 70) AS reason, count(*) FROM public.sms_logs WHERE match_status = 'unmatched' AND received_at > now() - interval '24 hours' GROUP BY 1 ORDER BY 2 DESC LIMIT 6;

\echo
\echo '== 27. Health scan cost: time per scan (ms) over the stored scans =='
SELECT count(*) AS scans, round(avg(ms)) AS avg_ms, percentile_disc(0.5) WITHIN GROUP (ORDER BY ms) AS p50_ms,
       percentile_disc(0.95) WITHIN GROUP (ORDER BY ms) AS p95_ms, max(ms) AS max_ms FROM private.health_scans;

\echo
\echo '== 28. cashdesk_balances: rows per method per day (insert-only history) =='
SELECT date_trunc('day', created_at)::date AS day, count(*) AS rows FROM public.cashdesk_balances GROUP BY 1 ORDER BY 1 DESC LIMIT 6;
SELECT method, count(*) AS rows, max(created_at) AS newest FROM public.cashdesk_balances GROUP BY 1 ORDER BY 2 DESC LIMIT 12;

\echo
\echo '== 29. Which Telegram chat receives the BADAL AGENT alerts (group or private; no ids) =='
SELECT chat_id IS NOT NULL AS linked, chat_id < 0 AS is_group, left(chat_name, 60) AS chat_name,
       to_char(linked_at AT TIME ZONE 'Africa/Mogadishu', 'MM-DD HH24:MI') AS linked_somalia, left(last_error, 100) AS last_error
FROM public.withdrawal_alert_chat;
