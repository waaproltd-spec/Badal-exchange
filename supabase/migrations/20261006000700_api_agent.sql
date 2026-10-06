-- Public API (Supabase RPC) for the Agent App: the /agent REST routes
-- (routes/agent.ts and routes/agentConsole.ts). Every function requires an
-- active account with role 'agent', as the /agent router did.

-- POST /agent/devices/register
CREATE OR REPLACE FUNCTION public.agent_register_device(p_device_id text, p_device_label text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
BEGIN
  PERFORM private.check_len(p_device_id, 'deviceId', 4, 200);
  PERFORM private.check_len(p_device_label, 'deviceLabel', 0, 100, false);
  INSERT INTO public.agent_devices (agent_id, device_id, device_label)
  VALUES (v_id, p_device_id, p_device_label)
  ON CONFLICT (agent_id, device_id) DO UPDATE SET last_seen_at = now(), status = 'active';
  UPDATE public.agent_profiles SET last_device_id = p_device_id, last_seen_at = now() WHERE user_id = v_id;
END
$$;

CREATE OR REPLACE FUNCTION private.agent_order_list(p_where text, p_order text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v jsonb;
BEGIN
  EXECUTE format(
    'SELECT COALESCE(jsonb_agg(private.agent_order_json(o) ORDER BY %1$s), ''[]''::jsonb)
     FROM (SELECT * FROM public.orders o WHERE %2$s ORDER BY %1$s LIMIT 200) o', p_order, p_where)
  INTO v;
  RETURN v;
END
$$;

-- GET /agent/deposits/pending
CREATE OR REPLACE FUNCTION public.agent_pending_deposits()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  RETURN private.agent_order_list($w$direction = 'deposit' AND status = 'pending'$w$, 'o.created_at ASC');
END $$;

-- GET /agent/withdrawals/pending
CREATE OR REPLACE FUNCTION public.agent_pending_withdrawals()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  RETURN private.agent_order_list($w$direction = 'withdraw' AND status IN ('pending', 'processing')$w$, 'o.created_at ASC');
END $$;

-- GET /agent/orders/completed
CREATE OR REPLACE FUNCTION public.agent_completed_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  RETURN private.agent_order_list($w$status = 'completed'$w$, 'o.completed_at DESC');
END $$;

-- GET /agent/orders/failed
CREATE OR REPLACE FUNCTION public.agent_failed_orders()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  RETURN private.agent_order_list($w$status = 'failed'$w$, 'o.updated_at DESC');
END $$;

-- GET /agent/profile
CREATE OR REPLACE FUNCTION public.agent_profile()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
BEGIN
  RETURN (
    SELECT jsonb_build_object(
      'id', u.id, 'name', u.name, 'phone', u.phone, 'status', u.status,
      'responsibilities', ap.responsibilities, 'last_seen_at', ap.last_seen_at
    )
    FROM public.users u LEFT JOIN public.agent_profiles ap ON ap.user_id = u.id
    WHERE u.id = v_id
  );
END
$$;

-- ---------------------------------------------------------------------------
-- Payment confirmations
-- ---------------------------------------------------------------------------

-- POST /agent/sms-transactions: fields extracted from an authorized
-- payment SMS on an agent device (never the raw message).
CREATE OR REPLACE FUNCTION public.agent_submit_sms_transaction(
  p_provider text, p_amount text, p_transaction_ref text, p_occurred_at text, p_idempotency_key text,
  p_sender text DEFAULT NULL, p_receiver text DEFAULT NULL, p_device_id text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_replay jsonb;
BEGIN
  v_replay := private.idempotency_begin(p_idempotency_key, 'agent.sms_transactions', jsonb_build_object(
    'provider', p_provider, 'sender', p_sender, 'receiver', p_receiver, 'amount', p_amount,
    'transactionRef', p_transaction_ref, 'occurredAt', p_occurred_at, 'deviceId', p_device_id));
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  PERFORM private.check_len(p_provider, 'provider', 2, 50);
  PERFORM private.check_len(p_sender, 'sender', 4, 20, false);
  PERFORM private.check_len(p_receiver, 'receiver', 4, 20, false);
  PERFORM private.check_len(p_transaction_ref, 'transactionRef', 3, 100);
  PERFORM private.check_len(p_device_id, 'deviceId', 0, 200, false);
  RETURN private.idempotency_finish(p_idempotency_key, private.submit_sms_transaction(
    v_id, p_device_id, p_provider, p_sender, p_receiver, private.to_cents(p_amount),
    p_transaction_ref, private.parse_ts(p_occurred_at, 'occurredAt')));
END
$$;

-- POST /agent/mobile-money-transactions: a payment the agent saw and keys in.
CREATE OR REPLACE FUNCTION public.agent_submit_mobile_money_transaction(
  p_method text, p_sender_phone text, p_amount text, p_transaction_ref text, p_occurred_at text, p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_replay jsonb;
  v_method public.order_method;
BEGIN
  v_replay := private.idempotency_begin(p_idempotency_key, 'agent.mobile_money_transactions', jsonb_build_object(
    'method', p_method, 'senderPhone', p_sender_phone, 'amount', p_amount,
    'transactionRef', p_transaction_ref, 'occurredAt', p_occurred_at));
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_method := private.parse_method(p_method, 'mobile_money');
  PERFORM private.check_len(p_sender_phone, 'senderPhone', 4, 20);
  PERFORM private.check_len(p_transaction_ref, 'transactionRef', 3, 100);
  RETURN private.idempotency_finish(p_idempotency_key, private.submit_sms_transaction(
    v_id, NULL, v_method::text, p_sender_phone, NULL, private.to_cents(p_amount),
    p_transaction_ref, private.parse_ts(p_occurred_at, 'occurredAt')));
END
$$;

-- POST /agent/platform-transactions (and /agent/winwin-transactions with
-- p_method 'winwin'): a betting-platform top-up the agent saw.
CREATE OR REPLACE FUNCTION public.agent_submit_platform_transaction(
  p_method text, p_account_id text, p_amount text, p_reference text, p_occurred_at text, p_idempotency_key text,
  p_deposit_code text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_replay jsonb;
  v_method public.order_method;
BEGIN
  v_replay := private.idempotency_begin(p_idempotency_key, 'agent.platform_transactions', jsonb_build_object(
    'method', p_method, 'accountId', p_account_id, 'depositCode', p_deposit_code, 'amount', p_amount,
    'reference', p_reference, 'occurredAt', p_occurred_at));
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  v_method := private.parse_method(COALESCE(p_method, 'winwin'), 'platform');
  PERFORM private.check_len(p_account_id, 'accountId', 3, 30);
  PERFORM private.check_len(p_deposit_code, 'depositCode', 3, 10, false);
  PERFORM private.check_len(p_reference, 'reference', 3, 100);
  RETURN private.idempotency_finish(p_idempotency_key, private.submit_platform_transaction(
    v_id, 'agent', v_method, p_account_id, p_deposit_code, private.to_cents(p_amount),
    p_reference, private.parse_ts(p_occurred_at, 'occurredAt')));
END
$$;

-- ---------------------------------------------------------------------------
-- Withdrawal processing
-- ---------------------------------------------------------------------------

-- POST /agent/withdrawals/:orderId/start
CREATE OR REPLACE FUNCTION public.agent_withdrawal_start(p_order_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  RETURN private.agent_order_json(private.start_processing_withdraw(p_order_id, v_id, 'agent'));
END $$;

-- POST /agent/withdrawals/:orderId/complete
CREATE OR REPLACE FUNCTION public.agent_withdrawal_complete(p_order_id uuid, p_transaction_ref text, p_idempotency_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_replay jsonb;
BEGIN
  v_replay := private.idempotency_begin(p_idempotency_key, 'agent.withdrawals.complete',
    jsonb_build_object('orderId', p_order_id, 'transactionRef', p_transaction_ref));
  IF v_replay IS NOT NULL THEN
    RETURN v_replay;
  END IF;
  PERFORM private.check_len(p_transaction_ref, 'transactionRef', 3, 100);
  RETURN private.idempotency_finish(p_idempotency_key,
    private.agent_order_json(private.complete_withdraw_order(p_order_id, p_transaction_ref, v_id, 'agent')));
END
$$;

-- POST /agent/withdrawals/:orderId/fail (releases the reserved funds)
CREATE OR REPLACE FUNCTION public.agent_withdrawal_fail(p_order_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('agent');
BEGIN
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  RETURN private.agent_order_json(private.fail_order(p_order_id, p_reason, v_id, 'agent'));
END $$;

-- ---------------------------------------------------------------------------
-- Console: Dashboard, Users, Reports, History, Account
-- ---------------------------------------------------------------------------

-- GET /agent/dashboard
CREATE OR REPLACE FUNCTION public.agent_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  c record;
BEGIN
  SELECT
    count(*) FILTER (WHERE direction = 'deposit' AND status = 'pending')::int AS pending_deposits,
    count(*) FILTER (WHERE direction = 'withdraw' AND status = 'pending')::int AS pending_withdrawals,
    count(*) FILTER (WHERE status = 'processing')::int AS processing,
    count(*) FILTER (WHERE status = 'completed')::int AS completed,
    count(*) FILTER (WHERE status = 'failed')::int AS failed,
    count(*)::int AS total
  INTO c FROM public.orders;
  RETURN jsonb_build_object(
    'pendingDeposits', c.pending_deposits,
    'pendingWithdrawals', c.pending_withdrawals,
    'processing', c.processing,
    'completed', c.completed,
    'failed', c.failed,
    'totalTransactions', c.total,
    'recentActivity', COALESCE((
      SELECT jsonb_agg(private.history_order_json(r.o, r.name, r.phone) ORDER BY (r.o).updated_at DESC)
      FROM (
        SELECT o, u.name, u.phone FROM public.orders o JOIN public.users u ON u.id = o.customer_id
        ORDER BY o.updated_at DESC LIMIT 10
      ) r
    ), '[]'::jsonb)
  );
END
$$;

CREATE OR REPLACE FUNCTION private.customer_status(p_status public.user_status)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_status = 'active' THEN 'active' ELSE 'blocked' END
$$;

-- GET /agent/customers (Users tab: customers only, view-only)
CREATE OR REPLACE FUNCTION public.agent_customers(
  p_q text DEFAULT NULL, p_status text DEFAULT 'all', p_sort text DEFAULT 'newest',
  p_limit int DEFAULT 50, p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_status text := COALESCE(p_status, 'all');
  v_sort text := COALESCE(p_sort, 'newest');
BEGIN
  PERFORM private.check_len(p_q, 'q', 0, 100, false);
  IF v_status NOT IN ('all', 'active', 'blocked') OR v_sort NOT IN ('newest', 'oldest', 'balance', 'name')
     OR p_limit NOT BETWEEN 1 AND 100 OR p_offset < 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid request');
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', r.id, 'name', r.name, 'phone', r.phone, 'status', private.customer_status(r.status),
      'walletBalance', private.money(r.available_cents), 'registeredAt', r.created_at,
      'orders', r.orders, 'deposits', r.deposits, 'withdrawals', r.withdrawals, 'transactions', r.transactions
    ) ORDER BY r.rn)
    FROM (
      SELECT u.id, u.name, u.phone, u.status, u.created_at, COALESCE(w.available_cents, 0) AS available_cents,
             COALESCE(o.orders, 0) AS orders, COALESCE(o.deposits, 0) AS deposits,
             COALESCE(o.withdrawals, 0) AS withdrawals, COALESCE(l.entries, 0) AS transactions,
             row_number() OVER (ORDER BY
               CASE WHEN v_sort = 'newest' THEN u.created_at END DESC,
               CASE WHEN v_sort = 'oldest' THEN u.created_at END ASC,
               CASE WHEN v_sort = 'balance' THEN COALESCE(w.available_cents, 0) END DESC,
               CASE WHEN v_sort = 'balance' THEN u.created_at END DESC,
               CASE WHEN v_sort = 'name' THEN u.name END ASC NULLS LAST
             ) AS rn
      FROM public.users u
      LEFT JOIN public.wallets w ON w.customer_id = u.id
      LEFT JOIN LATERAL (
        SELECT count(*)::int AS orders,
               count(*) FILTER (WHERE direction = 'deposit')::int AS deposits,
               count(*) FILTER (WHERE direction = 'withdraw')::int AS withdrawals
        FROM public.orders WHERE customer_id = u.id
      ) o ON true
      LEFT JOIN LATERAL (SELECT count(*)::int AS entries FROM public.ledger_entries WHERE wallet_id = w.id) l ON true
      WHERE u.role = 'customer'
        AND (v_q IS NULL OR u.name ILIKE '%' || v_q || '%' OR u.phone ILIKE '%' || v_q || '%')
        AND (v_status = 'all' OR u.status = CASE WHEN v_status = 'active' THEN 'active' ELSE 'disabled' END::public.user_status)
      ORDER BY rn
      LIMIT p_limit OFFSET p_offset
    ) r
  ), '[]'::jsonb);
END
$$;

-- GET /agent/customers/:id
CREATE OR REPLACE FUNCTION public.agent_customer(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  c record;
  t record;
BEGIN
  SELECT u.id, u.name, u.phone, u.status, u.created_at,
         COALESCE(w.available_cents, 0) AS available_cents, COALESCE(w.pending_cents, 0) AS pending_cents,
         w.id AS wallet_id
  INTO c
  FROM public.users u LEFT JOIN public.wallets w ON w.customer_id = u.id
  WHERE u.id = p_id AND u.role = 'customer';
  IF c.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;

  SELECT count(*)::int AS orders,
         COALESCE(sum(net_cents) FILTER (WHERE direction = 'deposit' AND status = 'completed'), 0) AS deposits,
         COALESCE(sum(wallet_delta_cents) FILTER (WHERE direction = 'withdraw' AND status = 'completed'), 0) AS withdrawals
  INTO t FROM public.orders WHERE customer_id = p_id;

  RETURN jsonb_build_object(
    'id', c.id,
    'name', c.name,
    'phone', c.phone,
    'status', private.customer_status(c.status),
    'registeredAt', c.created_at,
    'walletBalance', private.money(c.available_cents),
    'pendingBalance', private.money(c.pending_cents),
    'totalOrders', t.orders,
    'totalDeposits', private.money(t.deposits),
    'totalWithdrawals', private.money(t.withdrawals),
    'totalTransactions', (SELECT count(*)::int FROM public.ledger_entries WHERE wallet_id = c.wallet_id),
    'recentOrders', COALESCE((
      SELECT jsonb_agg(private.history_order_json(o, c.name, c.phone) ORDER BY o.created_at DESC)
      FROM (SELECT * FROM public.orders WHERE customer_id = p_id ORDER BY created_at DESC LIMIT 10) o
    ), '[]'::jsonb),
    'recentTransactions', COALESCE((
      SELECT jsonb_agg(private.ledger_json(l) ORDER BY l.created_at DESC)
      FROM (SELECT * FROM public.ledger_entries WHERE wallet_id = c.wallet_id ORDER BY created_at DESC LIMIT 10) l
    ), '[]'::jsonb)
  );
END
$$;

-- GET /agent/customers/:id/ledger
CREATE OR REPLACE FUNCTION public.agent_customer_ledger(p_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.ledger_json(l) ORDER BY l.created_at DESC)
    FROM (
      SELECT le.* FROM public.ledger_entries le JOIN public.wallets w ON w.id = le.wallet_id
      WHERE w.customer_id = p_id ORDER BY le.created_at DESC LIMIT 300
    ) l
  ), '[]'::jsonb);
END
$$;

-- GET /agent/reports: [from, to] are whole UTC days, inclusive.
CREATE OR REPLACE FUNCTION public.agent_reports(p_period text DEFAULT 'daily', p_from text DEFAULT NULL, p_to text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_period text := COALESCE(p_period, 'daily');
  v_today date := (now() AT TIME ZONE 'UTC')::date;
  v_from date;
  v_to date;
  s record;
BEGIN
  CASE v_period
    WHEN 'daily' THEN v_from := v_today; v_to := v_today;
    WHEN 'weekly' THEN v_from := v_today - 6; v_to := v_today;
    WHEN 'monthly' THEN v_from := v_today - 29; v_to := v_today;
    WHEN 'custom' THEN
      v_from := private.parse_date(p_from, 'from');
      v_to := private.parse_date(p_to, 'to');
      IF v_from IS NULL OR v_to IS NULL THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'from and to are required for a custom range');
      END IF;
      IF v_from > v_to THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'from must be on or before to');
      END IF;
      IF v_to - v_from > 366 THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Custom range can be at most one year');
      END IF;
    ELSE
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid period');
  END CASE;

  SELECT
    count(*) FILTER (WHERE direction = 'deposit')::int AS deposit_count,
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit'), 0) AS deposit_total,
    count(*) FILTER (WHERE direction = 'withdraw')::int AS withdraw_count,
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'withdraw'), 0) AS withdraw_total,
    count(*)::int AS order_count,
    COALESCE(sum(amount_cents), 0) AS order_total,
    count(*) FILTER (WHERE status = 'completed')::int AS completed_count,
    COALESCE(sum(amount_cents) FILTER (WHERE status = 'completed'), 0) AS completed_total,
    count(*) FILTER (WHERE status = 'failed')::int AS failed_count,
    COALESCE(sum(amount_cents) FILTER (WHERE status = 'failed'), 0) AS failed_total
  INTO s
  FROM public.orders
  WHERE created_at >= v_from::timestamp AT TIME ZONE 'UTC'
    AND created_at < (v_to + 1)::timestamp AT TIME ZONE 'UTC';

  RETURN jsonb_build_object(
    'period', v_period,
    'from', to_char(v_from, 'YYYY-MM-DD'),
    'to', to_char(v_to, 'YYYY-MM-DD'),
    'deposits', jsonb_build_object('count', s.deposit_count, 'total', private.money(s.deposit_total)),
    'withdrawals', jsonb_build_object('count', s.withdraw_count, 'total', private.money(s.withdraw_total)),
    'orders', jsonb_build_object('count', s.order_count, 'total', private.money(s.order_total)),
    'completed', jsonb_build_object('count', s.completed_count, 'total', private.money(s.completed_total)),
    'failed', jsonb_build_object('count', s.failed_count, 'total', private.money(s.failed_total)),
    'series', (
      SELECT COALESCE(jsonb_agg(jsonb_build_object(
        'date', to_char(d.day, 'YYYY-MM-DD'), 'deposits', d.deposits, 'withdrawals', d.withdrawals, 'orders', d.orders
      ) ORDER BY d.day), '[]'::jsonb)
      FROM (
        SELECT g::date AS day,
               count(o.id) FILTER (WHERE o.direction = 'deposit')::int AS deposits,
               count(o.id) FILTER (WHERE o.direction = 'withdraw')::int AS withdrawals,
               count(o.id)::int AS orders
        FROM generate_series(v_from::timestamp, v_to::timestamp, interval '1 day') g
        LEFT JOIN public.orders o
          ON o.created_at >= g AT TIME ZONE 'UTC' AND o.created_at < (g + interval '1 day') AT TIME ZONE 'UTC'
        GROUP BY g
      ) d
    )
  );
END
$$;

-- GET /agent/history: orders plus payment confirmations, newest first.
CREATE OR REPLACE FUNCTION public.agent_history(
  p_q text DEFAULT NULL, p_customer_id uuid DEFAULT NULL, p_type text DEFAULT 'all', p_status text DEFAULT NULL,
  p_method text DEFAULT NULL, p_from text DEFAULT NULL, p_to text DEFAULT NULL,
  p_limit int DEFAULT 50, p_offset int DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_type text := COALESCE(p_type, 'all');
  v_q text := NULLIF(btrim(COALESCE(p_q, '')), '');
  v_pat text;
  v_method text;
  v_from date := private.parse_date(p_from, 'from');
  v_to date := private.parse_date(p_to, 'to');
  v_from_ts timestamptz;
  v_to_ts timestamptz;
  v_window int;
  v_orders boolean;
  v_confirmations boolean;
BEGIN
  PERFORM private.check_len(p_q, 'q', 0, 100, false);
  PERFORM private.check_len(p_status, 'status', 0, 20, false);
  IF v_type NOT IN ('all', 'deposit', 'withdraw', 'order', 'confirmation')
     OR p_limit NOT BETWEEN 1 AND 100 OR p_offset < 0 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid request');
  END IF;
  IF p_method IS NOT NULL THEN
    v_method := private.parse_method(p_method)::text;
  END IF;
  v_pat := '%' || v_q || '%';
  v_from_ts := v_from::timestamp AT TIME ZONE 'UTC';
  v_to_ts := (v_to + 1)::timestamp AT TIME ZONE 'UTC';
  v_window := p_limit + p_offset;
  v_orders := v_type <> 'confirmation';
  v_confirmations := v_type IN ('all', 'confirmation') AND p_customer_id IS NULL;

  RETURN COALESCE((
    SELECT jsonb_agg(x.item ORDER BY x.created_at DESC)
    FROM (
      SELECT a.item, a.created_at
      FROM (
        (
          SELECT private.history_order_json(o, u.name, u.phone) AS item, o.created_at
          FROM public.orders o JOIN public.users u ON u.id = o.customer_id
          WHERE v_orders
            AND (v_type NOT IN ('deposit', 'withdraw') OR o.direction::text = v_type)
            AND (p_status IS NULL OR o.status::text = p_status)
            AND (v_method IS NULL OR o.method::text = v_method)
            AND (p_customer_id IS NULL OR o.customer_id = p_customer_id)
            AND (v_from IS NULL OR o.created_at >= v_from_ts)
            AND (v_to IS NULL OR o.created_at < v_to_ts)
            AND (v_q IS NULL OR u.name ILIKE v_pat OR u.phone ILIKE v_pat OR o.phone_number ILIKE v_pat
                 OR o.winwin_id ILIKE v_pat OR o.order_code ILIKE v_pat)
          ORDER BY o.created_at DESC
          LIMIT v_window
        )
        UNION ALL
        (
          SELECT jsonb_build_object(
                   'kind', 'confirmation',
                   'id', c.id,
                   'orderCode', NULL,
                   'direction', 'deposit',
                   'method', c.method,
                   'methodLabel', private.method_label(c.method),
                   'status', c.status,
                   'amount', private.money(c.amount_cents),
                   'counterparty', c.counterparty,
                   'reference', c.reference,
                   'customerName', u.name,
                   'customerPhone', u.phone,
                   'createdAt', c.created_at
                 ) AS item, c.created_at
          FROM (
            SELECT s.id,
                   CASE WHEN EXISTS (SELECT 1 FROM public.payment_methods pm
                                     WHERE pm.method::text = s.provider AND pm.kind = 'mobile_money')
                        THEN s.provider ELSE 'evc_plus' END AS method,
                   s.sender AS counterparty, s.amount_cents, s.transaction_ref AS reference,
                   s.match_status AS status, s.matched_order_id, s.created_at
            FROM public.sms_transactions s
            UNION ALL
            SELECT w.id, w.method::text, w.winwin_id, w.amount_cents, w.mobcash_ref,
                   w.match_status, w.matched_order_id, w.created_at
            FROM public.winwin_transactions w
          ) c
          LEFT JOIN public.orders o ON o.id = c.matched_order_id
          LEFT JOIN public.users u ON u.id = o.customer_id
          WHERE v_confirmations
            AND (p_status IS NULL OR c.status = p_status)
            AND (v_method IS NULL OR c.method = v_method)
            AND (v_from IS NULL OR c.created_at >= v_from_ts)
            AND (v_to IS NULL OR c.created_at < v_to_ts)
            AND (v_q IS NULL OR c.counterparty ILIKE v_pat OR c.reference ILIKE v_pat
                 OR u.name ILIKE v_pat OR u.phone ILIKE v_pat)
          ORDER BY c.created_at DESC
          LIMIT v_window
        )
      ) a
      ORDER BY a.created_at DESC
      LIMIT p_limit OFFSET p_offset
    ) x
  ), '[]'::jsonb);
END
$$;

-- GET /agent/account
CREATE OR REPLACE FUNCTION public.agent_account()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_resp text[];
BEGIN
  SELECT COALESCE(ap.responsibilities, '{}') INTO v_resp FROM public.agent_profiles ap WHERE ap.user_id = v_id;
  v_resp := COALESCE(v_resp, '{}');
  RETURN (
    SELECT jsonb_build_object(
      'id', u.id, 'name', u.name, 'phone', u.phone, 'email', u.email, 'status', u.status,
      'responsibilities', to_jsonb(v_resp),
      'canManageSettings', 'manage_settings' = ANY (v_resp),
      'contacts', private.contacts_json()
    )
    FROM public.users u WHERE u.id = v_id
  );
END
$$;
