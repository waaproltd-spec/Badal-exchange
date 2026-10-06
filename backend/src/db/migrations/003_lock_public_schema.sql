-- Keep every table private to the backend.
--
-- Supabase exposes the `public` schema over its auto-generated Data API
-- (PostgREST) to the `anon` and `authenticated` roles, i.e. to anyone with
-- the project's public anon key. All access to this app's data must go
-- through the backend, so:
--   1. enable row level security with NO policies on every table, so those
--      roles see nothing even if they hold grants (the backend connects as
--      the tables' owner, which bypasses RLS, so it is unaffected);
--   2. revoke the grants Supabase hands those roles, now and for tables
--      created by later migrations.
-- On a plain Postgres server the `anon`/`authenticated` roles do not exist
-- and step 2 is skipped; step 1 is harmless there.

DO $$
DECLARE
  t record;
BEGIN
  FOR t IN SELECT tablename FROM pg_tables WHERE schemaname = 'public' LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t.tablename);
  END LOOP;

  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
     AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    REVOKE ALL ON ALL TABLES IN SCHEMA public FROM anon, authenticated;
    REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM anon, authenticated;
    REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM anon, authenticated;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON SEQUENCES FROM anon, authenticated;
    ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon, authenticated;
  END IF;
END
$$;
