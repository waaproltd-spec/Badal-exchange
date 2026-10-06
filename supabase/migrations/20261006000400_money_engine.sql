-- Wallet, quote, order and matching logic: a line-for-line port of
-- backend/src/services/{walletService,rateFeeService,orderService,
-- matchingService}.ts. Everything here is private (not callable by the
-- apps); the API functions in later migrations call it after checking who
-- the caller is. Each API call is one transaction, so a failure anywhere
-- rolls the whole operation back.

-- ---------------------------------------------------------------------------
-- Codes
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.random_code(p_length int)
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = ''
AS $$
DECLARE
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no 0/O/1/I
  bytes bytea := extensions.gen_random_bytes(p_length);
  out text := '';
BEGIN
  FOR i IN 0 .. p_length - 1 LOOP
    out := out || substr(alphabet, (get_byte(bytes, i) % 32) + 1, 1);
  END LOOP;
  RETURN out;
END
$$;

CREATE OR REPLACE FUNCTION private.unique_order_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text;
BEGIN
  FOR i IN 1 .. 5 LOOP
    v_code := 'EX' || private.random_code(6);
    IF NOT EXISTS (SELECT 1 FROM public.orders WHERE order_code = v_code) THEN
      RETURN v_code;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Could not generate a unique order code';
END
$$;

CREATE OR REPLACE FUNCTION private.unique_deposit_code()
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_code text;
BEGIN
  FOR i IN 1 .. 8 LOOP
    v_code := private.random_code(4);
    IF NOT EXISTS (SELECT 1 FROM public.orders WHERE deposit_code = v_code) THEN
      RETURN v_code;
    END IF;
  END LOOP;
  RAISE EXCEPTION 'Could not generate a unique deposit code';
END
$$;

-- ---------------------------------------------------------------------------
-- Wallet (walletService.ts). lock_wallet takes the row lock that makes
-- concurrent requests against one wallet run one after another.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.lock_wallet(p_customer_id uuid)
RETURNS public.wallets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  w public.wallets;
BEGIN
  SELECT * INTO w FROM public.wallets WHERE customer_id = p_customer_id FOR UPDATE;
  IF FOUND THEN
    RETURN w;
  END IF;
  INSERT INTO public.wallets (customer_id) VALUES (p_customer_id) ON CONFLICT (customer_id) DO NOTHING;
  SELECT * INTO w FROM public.wallets WHERE customer_id = p_customer_id FOR UPDATE;
  RETURN w;
END
$$;

CREATE OR REPLACE FUNCTION private.ledger_entry(
  p_wallet public.wallets, p_order_id uuid, p_type public.ledger_entry_type, p_amount bigint, p_reason text
)
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = ''
AS $$
  INSERT INTO public.ledger_entries (wallet_id, order_id, entry_type, amount_cents, balance_after_cents, reason)
  VALUES (p_wallet.id, p_order_id, p_type, p_amount, p_wallet.available_cents, p_reason)
$$;

-- Deposit completion: credit the verified net amount.
CREATE OR REPLACE FUNCTION private.credit_wallet(p_wallet_id uuid, p_amount bigint, p_order_id uuid, p_reason text)
RETURNS public.wallets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  w public.wallets;
BEGIN
  UPDATE public.wallets
  SET available_cents = available_cents + p_amount,
      total_deposit_cents = total_deposit_cents + p_amount,
      updated_at = now()
  WHERE id = p_wallet_id
  RETURNING * INTO w;
  PERFORM private.ledger_entry(w, p_order_id, 'credit', p_amount, p_reason);
  RETURN w;
END
$$;

-- Withdrawal accepted: move funds from available into pending.
CREATE OR REPLACE FUNCTION private.reserve_funds(p_wallet public.wallets, p_amount bigint, p_order_id uuid, p_reason text)
RETURNS public.wallets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  w public.wallets;
BEGIN
  IF p_wallet.available_cents < p_amount THEN
    PERFORM private.raise_api(400, 'INSUFFICIENT_BALANCE', 'Insufficient wallet balance');
  END IF;
  UPDATE public.wallets
  SET available_cents = available_cents - p_amount,
      pending_cents = pending_cents + p_amount,
      updated_at = now()
  WHERE id = p_wallet.id
  RETURNING * INTO w;
  PERFORM private.ledger_entry(w, p_order_id, 'reserve', p_amount, p_reason);
  RETURN w;
END
$$;

-- Payout confirmed: the reserved amount leaves the wallet for good.
CREATE OR REPLACE FUNCTION private.finalize_debit(p_wallet_id uuid, p_amount bigint, p_order_id uuid, p_reason text)
RETURNS public.wallets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  w public.wallets;
BEGIN
  UPDATE public.wallets
  SET pending_cents = pending_cents - p_amount,
      total_withdraw_cents = total_withdraw_cents + p_amount,
      updated_at = now()
  WHERE id = p_wallet_id
  RETURNING * INTO w;
  PERFORM private.ledger_entry(w, p_order_id, 'debit', p_amount, p_reason);
  RETURN w;
END
$$;

-- Payout failed: the reservation goes back to available.
CREATE OR REPLACE FUNCTION private.release_funds(p_wallet_id uuid, p_amount bigint, p_order_id uuid, p_reason text)
RETURNS public.wallets
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  w public.wallets;
BEGIN
  UPDATE public.wallets
  SET pending_cents = pending_cents - p_amount,
      available_cents = available_cents + p_amount,
      updated_at = now()
  WHERE id = p_wallet_id
  RETURNING * INTO w;
  PERFORM private.ledger_entry(w, p_order_id, 'release', p_amount, p_reason);
  RETURN w;
END
$$;

-- ---------------------------------------------------------------------------
-- Quotes (rateFeeService.ts) -- the only place amounts are calculated.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.compute_quote(
  p_method public.order_method,
  p_direction public.order_direction,
  p_amount_cents bigint,
  OUT rate numeric,
  OUT rate_id uuid,
  OUT fee_id uuid,
  OUT fee_cents bigint,
  OUT net_cents bigint,
  OUT wallet_delta_cents bigint
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_fee_type public.fee_type := 'flat';
  v_fee_value numeric := 0;
  v_min bigint := 100;
  v_max bigint := 100000000;
BEGIN
  IF p_amount_cents IS NULL OR p_amount_cents <= 0 THEN
    PERFORM private.raise_api(400, 'INVALID_AMOUNT', 'Amount must be greater than zero');
  END IF;

  SELECT r.id, r.rate INTO rate_id, rate
  FROM public.exchange_rates r
  WHERE r.method = p_method AND r.direction = p_direction AND r.active
  ORDER BY r.created_at DESC LIMIT 1;
  IF rate_id IS NULL THEN
    PERFORM private.raise_api(400, 'RATE_NOT_CONFIGURED',
      format('No active exchange rate configured for %s/%s', p_method, p_direction));
  END IF;

  SELECT f.id, f.fee_type, f.value INTO fee_id, v_fee_type, v_fee_value
  FROM public.fees f
  WHERE f.method = p_method AND f.direction = p_direction AND f.active
  ORDER BY f.created_at DESC LIMIT 1;
  IF fee_id IS NULL THEN
    v_fee_type := 'flat';
    v_fee_value := 0;
  END IF;

  IF p_direction = 'withdraw' THEN
    SELECT l.min_cents, l.max_cents INTO v_min, v_max FROM public.withdrawal_limits l WHERE l.method = p_method;
    v_min := COALESCE(v_min, 100);
    v_max := COALESCE(v_max, 100000000);
    IF p_amount_cents < v_min THEN
      PERFORM private.raise_api(400, 'BELOW_MIN_WITHDRAWAL', 'Minimum withdrawal is ' || (v_min / 100.0)::float8::text);
    END IF;
    IF p_amount_cents > v_max THEN
      PERFORM private.raise_api(400, 'ABOVE_MAX_WITHDRAWAL', 'Maximum withdrawal is ' || (v_max / 100.0)::float8::text);
    END IF;
  END IF;

  fee_cents := greatest(0, CASE
    WHEN v_fee_type = 'flat' THEN round(v_fee_value)
    ELSE round(p_amount_cents * v_fee_value / 100)
  END)::bigint;

  IF p_direction = 'deposit' THEN
    net_cents := greatest(0, round(p_amount_cents * rate)::bigint - fee_cents);
    wallet_delta_cents := net_cents;
  ELSE
    net_cents := round(p_amount_cents * rate)::bigint; -- paid out to the customer
    wallet_delta_cents := p_amount_cents + fee_cents;    -- reserved/debited from the wallet
  END IF;
END
$$;

-- Refuses new orders for a method switched OFF in the Agent App.
CREATE OR REPLACE FUNCTION private.assert_method_enabled(p_method public.order_method)
RETURNS void
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.payment_methods WHERE method = p_method AND enabled = false) THEN
    PERFORM private.raise_api(400, 'METHOD_DISABLED', private.method_label(p_method::text) || ' is currently unavailable');
  END IF;
END
$$;

-- ---------------------------------------------------------------------------
-- Orders (orderService.ts)
-- ---------------------------------------------------------------------------

-- Deposits never touch the wallet until verified.
CREATE OR REPLACE FUNCTION private.create_deposit_order(
  p_customer_id uuid, p_method public.order_method, p_amount_cents bigint,
  p_phone_number text, p_account_id text, p_idempotency_key text
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  q record;
  o public.orders;
BEGIN
  q := private.compute_quote(p_method, 'deposit', p_amount_cents);
  INSERT INTO public.orders (
    order_code, customer_id, direction, method, status,
    phone_number, winwin_id, deposit_code,
    amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
    exchange_rate_id, fee_id, idempotency_key
  ) VALUES (
    private.unique_order_code(), p_customer_id, 'deposit', p_method, 'pending',
    p_phone_number, p_account_id,
    CASE WHEN private.method_kind(p_method) = 'platform' THEN private.unique_deposit_code() END,
    p_amount_cents, q.rate, q.fee_cents, q.net_cents, q.wallet_delta_cents,
    q.rate_id, q.fee_id, p_idempotency_key
  ) RETURNING * INTO o;
  PERFORM private.audit(p_customer_id, 'customer', 'order.create_deposit', 'order', o.id::text, NULL, to_jsonb(o));
  RETURN o;
END
$$;

-- Withdrawals reserve funds immediately so a balance can't be spent twice.
CREATE OR REPLACE FUNCTION private.create_withdraw_order(
  p_customer_id uuid, p_method public.order_method, p_amount_cents bigint,
  p_phone_number text, p_account_id text, p_idempotency_key text
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  q record;
  w public.wallets;
  o public.orders;
BEGIN
  q := private.compute_quote(p_method, 'withdraw', p_amount_cents);
  -- Lock first so two identical requests can't both pass the duplicate check.
  w := private.lock_wallet(p_customer_id);

  IF EXISTS (
    SELECT 1 FROM public.orders
    WHERE customer_id = p_customer_id AND direction = 'withdraw' AND method = p_method
      AND status IN ('pending', 'processing') AND amount_cents = p_amount_cents
      AND COALESCE(phone_number, winwin_id, '') = COALESCE(p_phone_number, p_account_id, '')
  ) THEN
    PERFORM private.raise_api(409, 'DUPLICATE_WITHDRAWAL', 'An identical withdrawal request is already in progress');
  END IF;

  INSERT INTO public.orders (
    order_code, customer_id, direction, method, status,
    phone_number, winwin_id,
    amount_cents, rate, fee_cents, net_cents, wallet_delta_cents,
    exchange_rate_id, fee_id, idempotency_key
  ) VALUES (
    private.unique_order_code(), p_customer_id, 'withdraw', p_method, 'pending',
    p_phone_number, p_account_id,
    p_amount_cents, q.rate, q.fee_cents, q.net_cents, q.wallet_delta_cents,
    q.rate_id, q.fee_id, p_idempotency_key
  ) RETURNING * INTO o;

  PERFORM private.reserve_funds(w, q.wallet_delta_cents, o.id, 'Reserve for withdrawal ' || o.order_code);
  PERFORM private.audit(p_customer_id, 'customer', 'order.create_withdraw', 'order', o.id::text, NULL, to_jsonb(o));
  RETURN o;
END
$$;

CREATE OR REPLACE FUNCTION private.lock_order(p_order_id uuid)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  o public.orders;
BEGIN
  SELECT * INTO o FROM public.orders WHERE id = p_order_id FOR UPDATE;
  IF NOT FOUND THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Order not found');
  END IF;
  RETURN o;
END
$$;

-- Deposit verified: credit the wallet and complete the order.
CREATE OR REPLACE FUNCTION private.complete_deposit_order(
  p_order_id uuid, p_transaction_ref text, p_agent_id uuid, p_actor_role public.user_role
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  before public.orders := private.lock_order(p_order_id);
  w public.wallets;
  o public.orders;
BEGIN
  IF before.direction <> 'deposit' THEN
    PERFORM private.raise_api(400, 'BAD_REQUEST', 'Not a deposit order');
  END IF;
  IF before.status <> 'pending' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Order is already ' || before.status);
  END IF;
  UPDATE public.orders
  SET status = 'processing', agent_id = p_agent_id, transaction_ref = p_transaction_ref,
      processing_at = now(), updated_at = now()
  WHERE id = p_order_id;

  w := private.lock_wallet(before.customer_id);
  PERFORM private.credit_wallet(w.id, before.net_cents, p_order_id,
    format('Deposit %s verified (%s)', before.order_code, p_transaction_ref));

  UPDATE public.orders SET status = 'completed', completed_at = now(), updated_at = now()
  WHERE id = p_order_id RETURNING * INTO o;
  PERFORM private.audit(p_agent_id, p_actor_role, 'order.complete_deposit', 'order', p_order_id::text, to_jsonb(before), to_jsonb(o));
  RETURN o;
END
$$;

CREATE OR REPLACE FUNCTION private.fail_order(
  p_order_id uuid, p_reason text, p_actor_id uuid, p_actor_role public.user_role
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  before public.orders := private.lock_order(p_order_id);
  w public.wallets;
  o public.orders;
BEGIN
  IF before.status IN ('completed', 'failed') THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Order is already ' || before.status);
  END IF;
  IF before.direction = 'withdraw' AND before.status IN ('pending', 'processing') THEN
    w := private.lock_wallet(before.customer_id);
    PERFORM private.release_funds(w.id, before.wallet_delta_cents, p_order_id,
      format('Withdrawal %s failed: %s', before.order_code, p_reason));
  END IF;
  UPDATE public.orders SET status = 'failed', failure_reason = p_reason, updated_at = now()
  WHERE id = p_order_id RETURNING * INTO o;
  PERFORM private.audit(p_actor_id, p_actor_role, 'order.fail', 'order', p_order_id::text, to_jsonb(before), to_jsonb(o));
  RETURN o;
END
$$;

CREATE OR REPLACE FUNCTION private.start_processing_withdraw(
  p_order_id uuid, p_agent_id uuid, p_actor_role public.user_role
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  before public.orders := private.lock_order(p_order_id);
  o public.orders;
BEGIN
  IF before.direction <> 'withdraw' THEN
    PERFORM private.raise_api(400, 'BAD_REQUEST', 'Not a withdrawal order');
  END IF;
  IF before.status <> 'pending' THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Order is already ' || before.status);
  END IF;
  UPDATE public.orders
  SET status = 'processing', agent_id = p_agent_id, processing_at = now(), updated_at = now()
  WHERE id = p_order_id RETURNING * INTO o;
  PERFORM private.audit(p_agent_id, p_actor_role, 'order.start_processing_withdraw', 'order', p_order_id::text, to_jsonb(before), to_jsonb(o));
  RETURN o;
END
$$;

-- Payout confirmed by the provider: finalize the wallet deduction.
CREATE OR REPLACE FUNCTION private.complete_withdraw_order(
  p_order_id uuid, p_transaction_ref text, p_agent_id uuid, p_actor_role public.user_role
)
RETURNS public.orders
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  before public.orders := private.lock_order(p_order_id);
  w public.wallets;
  o public.orders;
BEGIN
  IF before.direction <> 'withdraw' THEN
    PERFORM private.raise_api(400, 'BAD_REQUEST', 'Not a withdrawal order');
  END IF;
  IF before.status NOT IN ('processing', 'pending') THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Order is already ' || before.status);
  END IF;
  w := private.lock_wallet(before.customer_id);
  PERFORM private.finalize_debit(w.id, before.wallet_delta_cents, p_order_id,
    format('Withdrawal %s paid out (%s)', before.order_code, p_transaction_ref));
  UPDATE public.orders
  SET status = 'completed', agent_id = p_agent_id, transaction_ref = p_transaction_ref,
      completed_at = now(), updated_at = now()
  WHERE id = p_order_id RETURNING * INTO o;
  PERFORM private.audit(p_agent_id, p_actor_role, 'order.complete_withdraw', 'order', p_order_id::text, to_jsonb(before), to_jsonb(o));
  RETURN o;
END
$$;

-- ---------------------------------------------------------------------------
-- Payment confirmations (matchingService.ts)
-- ---------------------------------------------------------------------------

-- Mobile-money payment (SMS on an agent device, or keyed in by an agent).
-- The provider reference is the dedupe key: one payment credits once.
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
    AND phone_number = p_sender AND amount_cents = p_amount_cents
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

-- Betting-platform top-up confirmed by an agent/manager who saw the real
-- transaction in that platform's cashier tools.
CREATE OR REPLACE FUNCTION private.submit_platform_transaction(
  p_submitted_by uuid, p_actor_role public.user_role, p_method public.order_method, p_account_id text,
  p_deposit_code text, p_amount_cents bigint, p_reference text, p_occurred_at timestamptz
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_txn_id uuid;
  v_order_id uuid;
BEGIN
  INSERT INTO public.winwin_transactions (submitted_by, winwin_id, deposit_code, amount_cents, mobcash_ref, occurred_at, method)
  VALUES (p_submitted_by, p_account_id, p_deposit_code, p_amount_cents, p_reference, p_occurred_at, p_method)
  ON CONFLICT (method, mobcash_ref) DO NOTHING
  RETURNING id INTO v_txn_id;
  IF v_txn_id IS NULL THEN
    RETURN jsonb_build_object('status', 'duplicate');
  END IF;

  -- With a deposit code it must match too; without one, account ID +
  -- amount on this platform's pending orders (see matchingService.ts).
  SELECT id INTO v_order_id FROM public.orders
  WHERE direction = 'deposit' AND method = p_method AND status = 'pending'
    AND winwin_id = p_account_id AND amount_cents = p_amount_cents
    AND (p_deposit_code IS NULL OR deposit_code = p_deposit_code)
  ORDER BY created_at ASC LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF v_order_id IS NULL THEN
    UPDATE public.winwin_transactions SET match_status = 'unmatched' WHERE id = v_txn_id;
    RETURN jsonb_build_object('status', 'unmatched');
  END IF;

  PERFORM private.complete_deposit_order(v_order_id, p_reference, p_submitted_by, p_actor_role);
  UPDATE public.winwin_transactions SET match_status = 'matched', matched_order_id = v_order_id WHERE id = v_txn_id;
  RETURN jsonb_build_object('status', 'matched', 'orderId', v_order_id);
END
$$;

-- ---------------------------------------------------------------------------
-- JSON shapes the apps read (same keys as the REST responses)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION private.order_status_message(p_status public.order_status)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = ''
AS $$
  SELECT CASE p_status
    WHEN 'pending' THEN 'Your transaction is being verified.'
    WHEN 'processing' THEN 'Your transaction is being processed.'
    WHEN 'completed' THEN 'Transaction completed successfully.'
    WHEN 'failed' THEN 'Transaction failed. Your balance was not charged.'
    WHEN 'cancelled' THEN 'Transaction was cancelled.'
    WHEN 'expired' THEN 'Transaction expired.'
    ELSE ''
  END
$$;

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
    'failureReason', o.failure_reason,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.agent_order_json(o public.orders)
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
    'customerId', o.customer_id,
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'depositCode', o.deposit_code,
    'amount', private.money(o.amount_cents),
    'fee', private.money(o.fee_cents),
    'netAmount', private.money(o.net_cents),
    'walletDelta', private.money(o.wallet_delta_cents),
    'transactionRef', o.transaction_ref,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.admin_order_json(o public.orders)
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
    'customerId', o.customer_id,
    'agentId', o.agent_id,
    'phoneNumber', o.phone_number,
    'accountId', o.winwin_id,
    'winwinId', o.winwin_id,
    'amount', private.money(o.amount_cents),
    'fee', private.money(o.fee_cents),
    'netAmount', private.money(o.net_cents),
    'transactionRef', o.transaction_ref,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.history_order_json(o public.orders, p_customer_name text, p_customer_phone text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'kind', 'order',
    'id', o.id,
    'orderCode', o.order_code,
    'direction', o.direction,
    'method', o.method,
    'methodLabel', private.method_label(o.method::text),
    'status', o.status,
    'amount', private.money(o.amount_cents),
    'counterparty', COALESCE(o.phone_number, o.winwin_id),
    'reference', o.transaction_ref,
    'customerId', o.customer_id,
    'customerName', p_customer_name,
    'customerPhone', p_customer_phone,
    'createdAt', o.created_at,
    'completedAt', o.completed_at
  )
$$;

CREATE OR REPLACE FUNCTION private.ledger_json(l public.ledger_entries)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', l.id,
    'type', l.entry_type,
    'amount', private.money(l.amount_cents),
    'balanceAfter', private.money(l.balance_after_cents),
    'description', l.reason,
    'createdAt', l.created_at
  )
$$;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC, anon, authenticated;
