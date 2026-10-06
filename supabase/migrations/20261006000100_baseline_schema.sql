-- BAARI / Badal Exchange on Supabase: baseline schema.
--
-- The same tables, columns and constraints the Node backend created with
-- backend/src/db/migrations/001-006, so existing data, the Node backend
-- (kept as a fallback and as the MobCash automation worker) and the
-- Supabase-native API in later migrations all share one schema.
--
-- Written to be idempotent: it applies cleanly to an empty Supabase
-- project AND to a database where the Node migrations already ran.
-- All money amounts are BIGINT minor units (cents).

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF to_regtype('public.user_role') IS NULL THEN
    CREATE TYPE public.user_role AS ENUM ('customer', 'agent', 'admin');
  END IF;
  IF to_regtype('public.user_status') IS NULL THEN
    CREATE TYPE public.user_status AS ENUM ('active', 'disabled');
  END IF;
  IF to_regtype('public.order_direction') IS NULL THEN
    CREATE TYPE public.order_direction AS ENUM ('deposit', 'withdraw');
  END IF;
  IF to_regtype('public.order_method') IS NULL THEN
    CREATE TYPE public.order_method AS ENUM (
      'evc_plus', 'winwin', 'golis', 'telesom', 'edahab', 'onexbet', 'melbet', 'betwinner', 'dbbet', '888starz'
    );
  END IF;
  IF to_regtype('public.order_status') IS NULL THEN
    CREATE TYPE public.order_status AS ENUM ('pending', 'processing', 'completed', 'failed', 'cancelled', 'expired');
  END IF;
  IF to_regtype('public.ledger_entry_type') IS NULL THEN
    CREATE TYPE public.ledger_entry_type AS ENUM ('credit', 'debit', 'reserve', 'release');
  END IF;
  IF to_regtype('public.fee_type') IS NULL THEN
    CREATE TYPE public.fee_type AS ENUM ('flat', 'percent');
  END IF;
END
$$;

-- A database migrated by the Node backend before migration 004 only has
-- evc_plus and winwin.
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'golis';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'telesom';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'edahab';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'onexbet';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'melbet';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'betwinner';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS 'dbbet';
ALTER TYPE public.order_method ADD VALUE IF NOT EXISTS '888starz';
