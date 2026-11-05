-- The Sahal merchant feed is read every 10 seconds (was 30), so a paid
-- deposit is found and credited sooner. Only how often it is read changes:
-- matching and crediting are untouched, a transfer is stored once
-- (UNIQUE provider, transaction_id) and an order is credited once, and the
-- feed already runs one read at a time, so a slow read is never stacked.
-- Where pg_cron has no seconds schedule it stays every minute.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-golis-merchant';
    BEGIN
      PERFORM cron.schedule('baari-golis-merchant', '10 seconds', 'SELECT private.merchant_feed_kick()');
    EXCEPTION WHEN others THEN
      PERFORM cron.schedule('baari-golis-merchant', '* * * * *', 'SELECT private.merchant_feed_kick()');
    END;
  END IF;
END
$do$;
