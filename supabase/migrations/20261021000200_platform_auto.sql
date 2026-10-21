-- Automatic 888STARZ orders through the CashdeskBot API
-- (supabase/functions/platform-orders does the CashdeskBot calls).
--
--   Withdraw (Baari wallet -> 888starz account): the funds are reserved as
--   for every withdrawal. The worker checks the player exists, then tops the
--   account up with Deposit/{userId}/Add.
--   Deposit (888starz account -> Baari wallet): the customer requests a
--   withdrawal to our cash desk in 888starz and gives us its code. The worker
--   collects it with Deposit/{userId}/Payout and credits what 888starz paid.
--
-- Outcomes (platform_finish):
--   done      completed (withdraw: debit finalized; deposit: wallet credited)
--   refused   888starz said no: failed (withdraw: funds returned)
--   not_sent  nothing reached 888starz (not configured, bad signature, ...):
--             the order goes back to the agents, exactly as before
--   unclear   it may have gone through: withdraw is held for review under
--             Automatic Payouts, deposit stays pending for an agent to check
-- An order is tried once (auto_claimed_at); nothing is ever retried blindly.
--
-- Orders reach the worker through pg_net right after they are created, and a
-- pg_cron job every minute is the safety net. The worker's URL is the
-- 'edge_functions_url' app setting (set by the deploy workflow) and it proves
-- who it is with a secret kept in Vault.

ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS platform_code TEXT;
ALTER TABLE public.orders ADD COLUMN IF NOT EXISTS auto_claimed_at TIMESTAMPTZ;

INSERT INTO public.app_settings (key) VALUES ('edge_functions_url') ON CONFLICT (key) DO NOTHING;
-- Only orders created from now on are automatic: one already waiting may
-- have been handled by hand, and paying it again would pay it twice.
INSERT INTO public.app_settings (key, value) VALUES ('platform_auto_since', now()::text) ON CONFLICT (key) DO NOTHING;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM vault.secrets WHERE name = 'platform_worker_secret') THEN
    PERFORM vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'platform_worker_secret');
  END IF;
END
$$;

DO $do$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'pg_net not available: %', SQLERRM;
  END;
END
$do$;

-- Methods whose orders go through the CashdeskBot cash register.
CREATE OR REPLACE FUNCTION private.is_cashdesk_method(p_method public.order_method)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT p_method::text = '888starz'
$$;

CREATE OR REPLACE FUNCTION private.platform_eligible(o public.orders)
RETURNS boolean LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT private.is_cashdesk_method(o.method) AND o.status = 'pending' AND o.auto_claimed_at IS NULL
    AND o.winwin_id IS NOT NULL AND o.created_at > now() - interval '1 day'
    AND o.created_at >= (SELECT value::timestamptz FROM public.app_settings WHERE key = 'platform_auto_since')
    AND (o.direction = 'withdraw' OR o.platform_code IS NOT NULL)
$$;

-- Asks the worker to run. Never fails the caller: without pg_net or a URL
-- the orders simply wait for the next run, or for an agent.
CREATE OR REPLACE FUNCTION private.platform_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 60000)'
  USING rtrim(v_url, '/') || '/platform-orders', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'platform_kick: %', SQLERRM;
END $$;

CREATE OR REPLACE FUNCTION private.platform_kick_if_work()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.orders o WHERE private.platform_eligible(o)) THEN
    PERFORM private.platform_kick();
  END IF;
END $$;

-- Customers see why an 888STARZ order failed, but not the notes the
-- automation leaves for agents while it is still open.
CREATE OR REPLACE FUNCTION private.customer_order_json(o public.orders)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'status', o.status,
    'statusMessage', private.order_status_message(o.status),
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', private.money(o.amount_cents),
    'fee', private.money(o.fee_cents),
    'netAmount', private.money(o.net_cents),
    'transactionRef', o.transaction_ref,
    'failureReason', CASE WHEN o.status = 'failed' OR NOT private.is_cashdesk_method(o.method) THEN o.failure_reason END,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

-- ---------------------------------------------------------------------------
-- Customer API: deposits take the 888starz withdrawal code; new 888STARZ
-- orders wake the worker.
-- ---------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.customer_create_deposit(text, text, text, text, text, text);
CREATE OR REPLACE FUNCTION public.customer_create_deposit(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL,
  p_platform_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text := NULLIF(btrim(COALESCE(p_platform_code, '')), '');
  v_result jsonb;
BEGIN
  PERFORM private.check_len(v_code, 'platformCode', 1, 64, false);
  v_result := private.customer_order_request('deposit', p_method, p_amount, p_phone_number, p_account_id, p_winwin_id, p_idempotency_key);
  IF v_code IS NOT NULL AND private.is_cashdesk_method(private.parse_method(p_method)) THEN
    -- Only on the first call: a replayed request leaves the order as it is.
    UPDATE public.orders SET platform_code = v_code
    WHERE id = (v_result ->> 'id')::uuid AND platform_code IS NULL AND auto_claimed_at IS NULL AND status = 'pending';
    IF FOUND THEN
      PERFORM private.platform_kick();
    END IF;
  END IF;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION public.customer_create_withdrawal(
  p_method text, p_amount text, p_idempotency_key text,
  p_phone_number text DEFAULT NULL, p_account_id text DEFAULT NULL, p_winwin_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_result jsonb := private.customer_order_request('withdraw', p_method, p_amount, p_phone_number, p_account_id, p_winwin_id, p_idempotency_key);
BEGIN
  IF private.is_cashdesk_method(private.parse_method(p_method)) THEN
    PERFORM private.platform_kick();
  END IF;
  RETURN v_result;
END
$$;

-- ---------------------------------------------------------------------------
-- The worker (service role only)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.platform_worker_check(p_secret text)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_service();
  RETURN p_secret IS NOT NULL AND p_secret = (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
END $$;

-- Takes the oldest waiting 888STARZ order (each order once). Also puts
-- orders whose worker never reported back (crashed mid-call) in front of an
-- agent after 10 minutes.
CREATE OR REPLACE FUNCTION public.platform_claim_next()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  o public.orders;
  stale public.orders;
BEGIN
  PERFORM private.require_service();

  FOR stale IN
    SELECT * FROM public.orders
    WHERE auto_claimed_at < now() - interval '10 minutes' AND status IN ('pending', 'processing')
      AND private.is_cashdesk_method(method) AND failure_reason IS NULL AND NOT payout_review
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.orders SET
      payout_review = (direction = 'withdraw'),
      failure_reason = '888starz did not answer. Check the player''s 888starz account before completing or failing this order.',
      updated_at = now()
    WHERE id = stale.id;
  END LOOP;

  SELECT * INTO o FROM public.orders o2
  WHERE private.platform_eligible(o2)
  ORDER BY o2.created_at ASC LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    RETURN NULL;
  END IF;

  IF o.direction = 'withdraw' THEN
    o := private.start_processing_withdraw(o.id, NULL, NULL);
  END IF;
  UPDATE public.orders SET auto_claimed_at = now(), updated_at = now() WHERE id = o.id RETURNING * INTO o;
  RETURN jsonb_build_object(
    'orderId', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'method', o.method,
    'accountId', o.winwin_id, 'amount', private.money(o.net_cents), 'code', o.platform_code);
END $$;

CREATE OR REPLACE FUNCTION public.platform_finish(
  p_order_id uuid, p_outcome text, p_reference text DEFAULT NULL, p_message text DEFAULT NULL, p_summa numeric DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  before public.orders;
  o public.orders;
  q record;
  v_cents bigint;
  v_message text := left(NULLIF(btrim(COALESCE(p_message, '')), ''), 300);
BEGIN
  PERFORM private.require_service();
  before := private.lock_order(p_order_id);
  IF before.auto_claimed_at IS NULL OR NOT private.is_cashdesk_method(before.method) THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Not an automatic 888STARZ order');
  END IF;
  IF before.status IN ('completed', 'failed') THEN
    -- An agent finished it meanwhile; keep their result and note ours.
    PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk_late', 'order', before.id::text, NULL,
      jsonb_build_object('outcome', p_outcome, 'reference', p_reference, 'message', v_message, 'summa', p_summa));
    RETURN jsonb_build_object('status', before.status, 'late', true);
  END IF;

  IF p_outcome = 'done' THEN
    IF before.direction = 'withdraw' THEN
      o := private.complete_withdraw_order(before.id, COALESCE(p_reference, '888starz'), NULL, NULL);
    ELSE
      -- Credit what 888starz actually paid out.
      v_cents := round(COALESCE(p_summa, before.net_cents / 100.0) * 100)::bigint;
      IF v_cents <= 0 THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount');
      END IF;
      IF v_cents <> before.amount_cents THEN
        q := private.compute_quote(before.method, 'deposit', v_cents);
        UPDATE public.orders SET amount_cents = v_cents, rate = q.rate, fee_cents = q.fee_cents, net_cents = q.net_cents,
          wallet_delta_cents = q.wallet_delta_cents, exchange_rate_id = q.rate_id, fee_id = q.fee_id
        WHERE id = before.id;
      END IF;
      o := private.complete_deposit_order(before.id, COALESCE(p_reference, '888starz'), NULL, NULL);
    END IF;
  ELSIF p_outcome = 'refused' THEN
    o := private.fail_order(before.id, COALESCE(v_message, '888starz refused the request'), NULL, NULL);
  ELSIF p_outcome = 'not_sent' THEN
    -- Nothing reached 888starz: back to the agents as a normal order.
    UPDATE public.orders SET status = 'pending', processing_at = NULL,
      failure_reason = COALESCE(v_message, 'Automatic 888STARZ processing failed'), updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSIF p_outcome = 'unclear' THEN
    UPDATE public.orders SET payout_review = (direction = 'withdraw'),
      failure_reason = '888starz gave no clear answer (' || COALESCE(v_message, 'no details') ||
        '). Check the player''s 888starz account before completing or failing this order.',
      updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSE
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown outcome');
  END IF;

  PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk', 'order', before.id::text, to_jsonb(before),
    to_jsonb(o) || jsonb_build_object('outcome', p_outcome, 'message', v_message, 'summa', p_summa));
  RETURN jsonb_build_object('status', o.status, 'payoutReview', o.payout_review);
END $$;

REVOKE ALL ON FUNCTION public.customer_create_deposit(text, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_create_deposit(text, text, text, text, text, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.platform_worker_check(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.platform_claim_next() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.platform_finish(uuid, text, text, text, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.platform_worker_check(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.platform_claim_next() TO service_role;
GRANT EXECUTE ON FUNCTION public.platform_finish(uuid, text, text, text, numeric) TO service_role;

-- Safety net: wake the worker every minute while 888STARZ orders wait.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-platform-orders';
    PERFORM cron.schedule('baari-platform-orders', '* * * * *', 'SELECT private.platform_kick_if_work()');
  END IF;
END
$do$;
