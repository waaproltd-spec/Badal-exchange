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
\echo '== 18. Log-like and queue tables: rows, oldest, size (growth without a limit) =='
SELECT 'sms_logs' AS t, count(*) AS rows, min(created_at)::date AS oldest, pg_size_pretty(pg_total_relation_size('public.sms_logs')) AS size FROM public.sms_logs
UNION ALL SELECT 'merchant_transactions', count(*), min(created_at)::date, pg_size_pretty(pg_total_relation_size('public.merchant_transactions')) FROM public.merchant_transactions
UNION ALL SELECT 'ledger_entries', count(*), min(created_at)::date, pg_size_pretty(pg_total_relation_size('public.ledger_entries')) FROM public.ledger_entries
UNION ALL SELECT 'orders', count(*), min(created_at)::date, pg_size_pretty(pg_total_relation_size('public.orders')) FROM public.orders
UNION ALL SELECT 'health_scans', count(*), min(at)::date, pg_size_pretty(pg_total_relation_size('private.health_scans')) FROM private.health_scans
UNION ALL SELECT 'merchant_feed_events', count(*), min(at)::date, pg_size_pretty(pg_total_relation_size('private.merchant_feed_events')) FROM private.merchant_feed_events;

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
