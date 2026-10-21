-- BAARI Exchange: grants, the minute resweep, and SMS-before-order for
-- Baari's existing wallet deposits (an SMS stored in sms_logs before the
-- customer created the deposit order is matched when the order is made).

CREATE OR REPLACE FUNCTION private.customer_order_request(
  p_direction public.order_direction, p_method text, p_amount text,
  p_phone_number text, p_account_id text, p_winwin_id text, p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method;
  v_kind text;
  v_cents bigint;
  v_phone text;
  v_account text;
  v_replay jsonb;
  o public.orders;
BEGIN
  v_method := private.parse_method(p_method);
  v_kind := private.method_kind(v_method);
  v_replay := private.idempotency_begin(
    p_idempotency_key,
    format('customer.%s.%s', CASE WHEN p_direction = 'deposit' THEN 'deposits' ELSE 'withdrawals' END, p_method),
    jsonb_build_object('phoneNumber', p_phone_number, 'accountId', p_account_id, 'winwinId', p_winwin_id, 'amount', p_amount)
  );
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;

  PERFORM private.check_len(p_phone_number, 'phoneNumber', 6, 20, false);
  PERFORM private.check_len(p_account_id, 'accountId', 3, 30, false);
  PERFORM private.check_len(p_winwin_id, 'winwinId', 3, 30, false);
  IF v_kind = 'mobile_money' THEN
    IF p_phone_number IS NULL THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'phoneNumber is required');
    END IF;
    v_phone := p_phone_number;
  ELSE
    v_account := COALESCE(p_account_id, p_winwin_id);
    IF v_account IS NULL THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'accountId is required');
    END IF;
  END IF;
  v_cents := private.to_cents(p_amount);
  PERFORM private.assert_method_enabled(v_method);

  IF p_direction = 'deposit' THEN
    o := private.create_deposit_order(v_id, v_method, v_cents, v_phone, v_account, p_idempotency_key);
    -- SMS-before-order: the customer may already have paid.
    IF v_phone IS NOT NULL THEN
      PERFORM private.match_waiting_sms(v_phone, v_cents / 100.0);
      SELECT * INTO o FROM public.orders WHERE id = o.id;
    END IF;
  ELSE
    o := private.create_withdraw_order(v_id, v_method, v_cents, v_phone, v_account, p_idempotency_key);
    -- The MobCash automation worker picks up pending WinWin withdrawals.
    IF v_method = 'winwin' THEN
      PERFORM pg_notify('mobcash_withdrawal', o.id::text);
    END IF;
  END IF;
  RETURN private.idempotency_finish(p_idempotency_key, private.customer_order_json(o), 201);
END
$$;

-- Agents' payment SMS now go through agent_ingest_payment_sms; the older
-- agent_submit_sms_transaction stays for app versions that still call it,
-- and now also compares phone numbers by their last 9 digits.
CREATE OR REPLACE FUNCTION private.submit_sms_transaction(
  p_agent_id uuid, p_device_id text, p_provider text, p_sender text, p_receiver text,
  p_amount_cents bigint, p_transaction_ref text, p_occurred_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_sms_id uuid;
  v_order_id uuid;
  v_method public.order_method := private.method_for_sms_provider(p_provider);
BEGIN
  INSERT INTO public.sms_transactions (agent_id, device_id, provider, sender, receiver, amount_cents, transaction_ref, occurred_at)
  VALUES (p_agent_id, p_device_id, p_provider, p_sender, p_receiver, p_amount_cents, p_transaction_ref, p_occurred_at)
  ON CONFLICT (provider, transaction_ref) DO NOTHING
  RETURNING id INTO v_sms_id;
  IF v_sms_id IS NULL THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  SELECT id INTO v_order_id FROM public.orders
  WHERE direction = 'deposit' AND method = v_method AND status = 'pending'
    AND private.phone_key(phone_number) = private.phone_key(p_sender) AND amount_cents = p_amount_cents
  ORDER BY created_at ASC LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF v_order_id IS NULL THEN
    UPDATE public.sms_transactions SET match_status = 'unmatched' WHERE id = v_sms_id;
    RETURN jsonb_build_object('status', 'unmatched');
  END IF;

  PERFORM private.complete_deposit_order(v_order_id, p_transaction_ref, p_agent_id, 'agent');
  UPDATE public.sms_transactions SET match_status = 'matched', matched_order_id = v_order_id WHERE id = v_sms_id;
  RETURN jsonb_build_object('status', 'matched', 'orderId', v_order_id);
END
$$;

-- Dalab resweeps every 15s from the API process; here pg_cron runs it every
-- minute when the extension is available (order creation also matches a
-- waiting SMS at once, so this is the safety net).
DO $do$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN others THEN
    RAISE NOTICE 'pg_cron not available: %', SQLERRM;
  END;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.unschedule(jobid) FROM cron.job WHERE jobname = 'baari-resweep-unmatched-sms';
    PERFORM cron.schedule('baari-resweep-unmatched-sms', '* * * * *', 'SELECT private.resweep_unmatched_sms()');
  END IF;
END
$do$;

-- Grants: signed-in users only, as for every other API function.
DO $$
DECLARE
  f record;
BEGIN
  FOR f IN
    SELECT p.oid::regprocedure AS sig FROM pg_proc p
    WHERE p.pronamespace = 'public'::regnamespace AND p.prokind = 'f'
      AND p.proname ~ '^(agent_ingest_payment_sms|exchange_options|exchange_quote|customer_create_exchange_order|customer_exchange_order|customer_exchange_orders|agent_exchange_|manage_exchange_|manage_resolve_payment_sms|manage_payment_sms|manage_save_exchange_corridor|manage_save_payout_wallet|manage_set_payout_wallet_pin)'
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', f.sig);
  END LOOP;
END
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.app_role() TO anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_staff() TO anon, authenticated;
