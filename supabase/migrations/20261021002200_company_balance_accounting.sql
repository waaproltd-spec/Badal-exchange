-- Company Balances: Balance and Limit of each cash register (1XBET,
-- 888STARZ), kept current between live reads.
--
--   Balance  what customers have bought through the register in total
--   Limit    what the register can still sell
--
-- A sale (a BAARI withdrawal paid into the player's account) of $5 raises
-- Balance by $5 and lowers Limit by $5; a payout (the player's code paid out
-- to BAARI) of $5 does the opposite.
--
-- The live read from CashdeskBot (cashdesk_balances) stays the source of
-- truth. Every completed movement of a register is recorded once in
-- cashdesk_movements, in the same transaction that completes it:
--   - automatic orders, by platform_finish 'done' (one per order);
--   - manual deposits/payouts from the Telegram bots and the Agent App, by
--     cashdeskbot_finish when CashdeskBot reported success (one per
--     idempotency key).
-- Pending, refused, low-funds and unclear outcomes record nothing. What the
-- app shows is the last good live read plus the movements made after it;
-- the next live read replaces them. A movement's time is when the register
-- was asked (the order's claim, the manual request's start), so a read made
-- after the platform moved already includes it and it is not added twice.
-- A Limit the register did not report stays unknown.
--
-- History: no existing order, ledger entry or balance read is changed. The
-- ledger starts with this migration; everything before it is already in
-- the live values.

CREATE TABLE IF NOT EXISTS public.cashdesk_movements (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method           public.order_method NOT NULL,
  kind             TEXT NOT NULL CHECK (kind IN ('sale', 'payout')),
  amount_cents     BIGINT NOT NULL CHECK (amount_cents > 0),
  order_id         UUID UNIQUE REFERENCES public.orders(id),
  idempotency_key  TEXT UNIQUE,
  happened_at      TIMESTAMPTZ NOT NULL,
  recorded_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((order_id IS NULL) <> (idempotency_key IS NULL))
);
CREATE INDEX IF NOT EXISTS idx_cashdesk_movements_method ON public.cashdesk_movements (method, happened_at DESC);
ALTER TABLE public.cashdesk_movements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.cashdesk_movements FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.cashdesk_movement_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'cash register movements can not be changed or deleted';
END $$;
DROP TRIGGER IF EXISTS cashdesk_movements_immutable ON public.cashdesk_movements;
CREATE TRIGGER cashdesk_movements_immutable BEFORE UPDATE OR DELETE ON public.cashdesk_movements
FOR EACH ROW EXECUTE FUNCTION private.cashdesk_movement_immutable();

-- Records one movement; a second one for the same order or request is
-- ignored. Returns whether it was recorded.
CREATE OR REPLACE FUNCTION private.cashdesk_movement(
  p_method public.order_method, p_kind text, p_amount_cents bigint, p_order_id uuid, p_key text, p_at timestamptz
)
RETURNS boolean LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid;
BEGIN
  IF NOT private.is_cashdesk_method(p_method) OR COALESCE(p_amount_cents, 0) <= 0 THEN
    RETURN false;
  END IF;
  INSERT INTO public.cashdesk_movements (method, kind, amount_cents, order_id, idempotency_key, happened_at)
  VALUES (p_method, p_kind, p_amount_cents, p_order_id, p_key, COALESCE(p_at, now()))
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;
  RETURN v_id IS NOT NULL;
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
  v_label text;
  v_alert boolean := false;
  v_chats bigint[];
BEGIN
  PERFORM private.require_service();
  before := private.lock_order(p_order_id);
  IF before.auto_claimed_at IS NULL OR NOT private.is_cashdesk_method(before.method) THEN
    PERFORM private.raise_api(409, 'INVALID_ORDER_STATE', 'Not an automatic betting-platform order');
  END IF;
  IF before.status IN ('completed', 'failed') THEN
    -- An agent finished it meanwhile; keep their result and note ours.
    PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk_late', 'order', before.id::text, NULL,
      jsonb_build_object('outcome', p_outcome, 'reference', p_reference, 'message', v_message, 'summa', p_summa));
    RETURN jsonb_build_object('status', before.status, 'late', true);
  END IF;

  IF p_outcome = 'done' THEN
    IF before.direction = 'withdraw' THEN
      o := private.complete_withdraw_order(before.id, COALESCE(p_reference, private.method_label(before.method)), NULL, NULL);
    ELSIF before.amount_unknown AND COALESCE(p_summa, 0) = 0 THEN
      -- Paid out, but without an amount there is nothing safe to credit.
      UPDATE public.orders SET failure_reason = private.method_label(before.method) ||
          ' paid out the code but did not say how much. Check the player''s account and credit it by hand.',
        updated_at = now()
      WHERE id = before.id RETURNING * INTO o;
    ELSE
      -- Credit what the platform actually paid out.
      -- CashdeskBot reports a payout as money leaving the player: negative.
      v_cents := round(abs(COALESCE(p_summa, before.net_cents / 100.0)) * 100)::bigint;
      IF v_cents <= 0 THEN
        PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid amount');
      END IF;
      IF v_cents <> before.amount_cents OR before.amount_unknown THEN
        q := private.compute_quote(before.method, 'deposit', v_cents);
        UPDATE public.orders SET amount_cents = v_cents, rate = q.rate, fee_cents = q.fee_cents, net_cents = q.net_cents,
          wallet_delta_cents = q.wallet_delta_cents, exchange_rate_id = q.rate_id, fee_id = q.fee_id,
          amount_unknown = false
        WHERE id = before.id;
      END IF;
      o := private.complete_deposit_order(before.id, COALESCE(p_reference, private.method_label(before.method)), NULL, NULL);
    END IF;
    -- The register moved: a sale (withdrawal to the player) or a payout
    -- (the player's code paid to BAARI), once per order.
    IF o.status = 'completed' THEN
      PERFORM private.cashdesk_movement(o.method,
        CASE WHEN o.direction = 'withdraw' THEN 'sale' ELSE 'payout' END,
        CASE WHEN o.direction = 'withdraw' THEN o.net_cents ELSE o.amount_cents END,
        o.id, NULL, before.auto_claimed_at);
    END IF;
  ELSIF p_outcome = 'low_funds' AND before.direction = 'withdraw' THEN
    v_label := private.method_label(before.method);
    IF before.low_funds_since IS NOT NULL AND before.low_funds_since < now() - interval '60 minutes' THEN
      -- Waited an hour for a top-up: give the customer their money back.
      o := private.fail_order(before.id, v_label || ' could not receive payouts in time. Your balance was not charged; '
        || 'please try again later.', NULL, NULL);
    ELSE
      -- Keep it processing and hand it to the worker again next minute.
      UPDATE public.orders SET auto_claimed_at = NULL, low_funds_since = COALESCE(low_funds_since, now()),
        failure_reason = 'Waiting for the ' || v_label || ' cash register to be topped up (' ||
          COALESCE(v_message, 'not enough balance') || '). Sent automatically once it has enough; '
          || 'failed and refunded after 60 minutes.',
        updated_at = now()
      WHERE id = before.id RETURNING * INTO o;
      -- Tell the managers, at most every 15 minutes per cash register.
      INSERT INTO public.app_settings (key, value) VALUES ('cashdesk_low_alert:' || before.method::text, now()::text)
      ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
        WHERE public.app_settings.value::timestamptz < now() - interval '15 minutes'
      RETURNING true INTO v_alert;
      IF v_alert THEN
        SELECT array_agg(t.telegram_user_id) INTO v_chats
        FROM public.telegram_operators t JOIN public.users u ON u.id = t.user_id
        WHERE u.status = 'active' AND (u.role = 'admin'
          OR (u.role = 'agent' AND EXISTS (SELECT 1 FROM public.agent_profiles p
                WHERE p.user_id = u.id AND 'manage_settings' = ANY(p.responsibilities))));
      END IF;
    END IF;
  ELSIF p_outcome = 'refused' THEN
    o := private.fail_order(before.id, COALESCE(v_message, private.method_label(before.method) || ' refused the request'), NULL, NULL);
  ELSIF p_outcome = 'not_sent' THEN
    -- Nothing reached the platform: back to the agents as a normal order.
    UPDATE public.orders SET status = 'pending', processing_at = NULL,
      failure_reason = COALESCE(v_message, 'Automatic ' || private.method_label(before.method) || ' processing failed'), updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSIF p_outcome = 'unclear' THEN
    UPDATE public.orders SET payout_review = (direction = 'withdraw'),
      failure_reason = private.method_label(before.method) || ' gave no clear answer (' || COALESCE(v_message, 'no details') ||
        '). Check the player''s ' || private.method_label(before.method) || ' account before completing or failing this order.',
      updated_at = now()
    WHERE id = before.id RETURNING * INTO o;
  ELSE
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown outcome');
  END IF;

  PERFORM private.audit(NULL, NULL, 'order.auto_cashdesk', 'order', before.id::text, to_jsonb(before),
    to_jsonb(o) || jsonb_build_object('outcome', p_outcome, 'message', v_message, 'summa', p_summa));
  RETURN jsonb_build_object('status', o.status, 'payoutReview', o.payout_review)
    || CASE WHEN v_alert THEN jsonb_build_object('alertTelegramUserIds', COALESCE(to_jsonb(v_chats), '[]'::jsonb)) ELSE '{}'::jsonb END;
END $$;

-- Manual deposits / payouts (Telegram bots, Agent App) move the register
-- too: recorded when CashdeskBot reported success, once per request.
CREATE OR REPLACE FUNCTION public.cashdeskbot_finish(
  p_action text, p_user_id text, p_audit jsonb, p_idempotency_key text DEFAULT NULL, p_response jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  v_method public.order_method := CASE WHEN p_audit->>'brand' = '1xbet' THEN 'onexbet' ELSE '888starz' END;
  v_amount numeric;
  v_at timestamptz;
BEGIN
  IF p_action NOT IN ('deposit', 'payout') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown action');
  END IF;
  IF p_idempotency_key IS NOT NULL THEN
    UPDATE public.idempotency_keys SET status_code = 200, response_json = p_response
    WHERE key = p_idempotency_key AND user_id = v_id AND status_code IS NULL;
    SELECT created_at INTO v_at FROM public.idempotency_keys WHERE key = p_idempotency_key;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'cashdeskbot.' || p_action, 'cashdeskbot_user', p_user_id, NULL, p_audit);

  IF p_idempotency_key IS NOT NULL AND COALESCE((p_response->>'success')::boolean, false) THEN
    v_amount := abs(COALESCE(NULLIF(p_response->>'summa', '')::numeric,
      CASE WHEN p_action = 'deposit' THEN NULLIF(p_audit->>'summa', '')::numeric END));
    IF v_amount IS NOT NULL THEN
      PERFORM private.cashdesk_movement(v_method, CASE WHEN p_action = 'deposit' THEN 'sale' ELSE 'payout' END,
        round(v_amount * 100)::bigint, NULL, 'cashdeskbot:' || p_idempotency_key, v_at);
    END IF;
  END IF;
END
$$;

-- One company: live read, Balance and Limit now, status and figures for
-- [p_from, p_to).
CREATE OR REPLACE FUNCTION private.company_balance_json(
  p_method public.order_method, p_label text, p_from timestamptz, p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_connected boolean := private.is_cashdesk_method(p_method);
  v_last public.cashdesk_balances;
  v_good public.cashdesk_balances;
  v_threshold bigint := COALESCE(round(NULLIF(btrim((SELECT value FROM public.app_settings
    WHERE key = 'company_low_balance')), '')::numeric * 100)::bigint, 5000);
  v_sales bigint := 0;
  v_payouts bigint := 0;
  v_changes int := 0;
  v_balance bigint;
  v_limit bigint;
  v_waiting_n int;
  v_waiting bigint;
  v_pending_n int;
  v_pending bigint;
  v_status text;
  s record;
BEGIN
  SELECT * INTO v_last FROM public.cashdesk_balances WHERE method = p_method ORDER BY checked_at DESC LIMIT 1;
  SELECT * INTO v_good FROM public.cashdesk_balances WHERE method = p_method AND ok ORDER BY checked_at DESC LIMIT 1;

  -- Movements after the last good live read.
  IF v_good.id IS NOT NULL THEN
    SELECT COALESCE(sum(amount_cents) FILTER (WHERE kind = 'sale'), 0),
           COALESCE(sum(amount_cents) FILTER (WHERE kind = 'payout'), 0), count(*)
      INTO v_sales, v_payouts, v_changes
    FROM public.cashdesk_movements WHERE method = p_method AND happened_at > v_good.checked_at;
    v_balance := v_good.balance_cents + v_sales - v_payouts;
    v_limit := v_good.limit_cents - v_sales + v_payouts; -- NULL stays NULL: not reported
  END IF;

  SELECT count(*) FILTER (WHERE low_funds_since IS NOT NULL),
         COALESCE(sum(net_cents) FILTER (WHERE low_funds_since IS NOT NULL), 0),
         count(*), COALESCE(sum(net_cents), 0)
    INTO v_waiting_n, v_waiting, v_pending_n, v_pending
  FROM public.orders
  WHERE method = p_method AND direction = 'withdraw' AND status IN ('pending', 'processing');

  SELECT
    count(*) FILTER (WHERE direction = 'deposit' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to) AS dep_n,
    COALESCE(sum(amount_cents) FILTER (WHERE direction = 'deposit' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to), 0) AS dep,
    count(*) FILTER (WHERE direction = 'withdraw' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to) AS wd_n,
    COALESCE(sum(net_cents) FILTER (WHERE direction = 'withdraw' AND status = 'completed' AND completed_at >= p_from AND completed_at < p_to), 0) AS wd,
    count(*) FILTER (WHERE status IN ('pending', 'processing') AND created_at >= p_from AND created_at < p_to) AS open_n,
    count(*) FILTER (WHERE status = 'failed' AND created_at >= p_from AND created_at < p_to) AS failed_n
    INTO s
  FROM public.orders WHERE method = p_method;

  -- Low: the register can't sell what is waiting, or its Limit is under
  -- the low-balance level. Without a reported Limit only waiting
  -- withdrawals count.
  v_status := CASE
    WHEN NOT v_connected THEN 'not_connected'
    WHEN v_good.id IS NULL OR NOT v_last.ok THEN 'offline'
    WHEN v_good.checked_at < now() - interval '15 minutes' THEN 'stale'
    WHEN v_waiting_n > 0 OR v_limit < v_threshold THEN 'low'
    ELSE 'available'
  END;

  RETURN jsonb_build_object(
    'method', p_method, 'label', p_label, 'connected', v_connected,
    'source', CASE WHEN v_connected THEN 'CashdeskBot' END,
    'status', v_status,
    'balance', CASE WHEN v_balance IS NOT NULL THEN private.money(v_balance) END,
    'limit', CASE WHEN v_limit IS NOT NULL THEN private.money(v_limit) END,
    'liveBalance', CASE WHEN v_good.id IS NOT NULL THEN private.money(v_good.balance_cents) END,
    'liveLimit', CASE WHEN v_good.limit_cents IS NOT NULL THEN private.money(v_good.limit_cents) END,
    'salesSinceCheck', private.money(v_sales),
    'payoutsSinceCheck', private.money(v_payouts),
    'changesSinceCheck', v_changes,
    'lastSuccessAt', v_good.checked_at,
    'lastCheckedAt', v_last.checked_at,
    'lastError', CASE WHEN v_last.id IS NOT NULL AND NOT v_last.ok THEN v_last.error END,
    'lowThreshold', private.money(v_threshold),
    'waitingWithdrawals', v_waiting_n,
    'waitingAmount', private.money(v_waiting),
    'topUpNeeded', CASE WHEN v_waiting_n > 0 AND v_limit IS NOT NULL
      THEN private.money(GREATEST(v_waiting - v_limit, 0)) END,
    'openWithdrawals', v_pending_n,
    'openWithdrawalAmount', private.money(v_pending),
    'period', jsonb_build_object(
      'from', p_from, 'to', p_to,
      'received', private.money(s.dep), 'receivedCount', s.dep_n,
      'sent', private.money(s.wd), 'sentCount', s.wd_n,
      'open', s.open_n, 'failed', s.failed_n));
END $$;

CREATE OR REPLACE FUNCTION public.agent_company_balances(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now()));
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
  v_items jsonb;
BEGIN
  PERFORM private.require_company_balances();
  IF v_to <= v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period must end after it starts');
  END IF;
  SELECT COALESCE(jsonb_agg(private.company_balance_json(m.method, m.label, v_from, v_to)
           ORDER BY NOT private.is_cashdesk_method(m.method), m.kind DESC, m.sort_order), '[]')
    INTO v_items
  FROM public.payment_methods m;

  RETURN jsonb_build_object(
    'companies', v_items,
    'total', private.money(COALESCE((SELECT sum((i->>'balance')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low')), 0)),
    'totalLimit', CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)
      THEN private.money((SELECT sum((i->>'limit')::numeric * 100)::bigint FROM jsonb_array_elements(v_items) i
        WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NOT NULL)) END,
    'totalCompanies', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('available', 'low')),
    'limitUnknownCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i
      WHERE i->>'status' IN ('available', 'low') AND i->>'limit' IS NULL),
    'openWithdrawalAmount', private.money(COALESCE((SELECT sum((i->>'openWithdrawalAmount')::numeric * 100)::bigint
      FROM jsonb_array_elements(v_items) i WHERE (i->>'connected')::boolean), 0)),
    'lowCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'low'),
    'unavailableCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' IN ('offline', 'stale')),
    'notConnectedCount', (SELECT count(*) FROM jsonb_array_elements(v_items) i WHERE i->>'status' = 'not_connected'),
    'generatedAt', now());
END $$;

-- One company, plus its register history: the live reads and every
-- movement, newest first; movements after the last good read carry the
-- Balance and Limit they led to.
CREATE OR REPLACE FUNCTION public.agent_company_detail(
  p_method text, p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL, p_status text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_method public.order_method := private.parse_method(p_method);
  v_from timestamptz := COALESCE(p_from, date_trunc('day', now()) - interval '6 days');
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
  v_good public.cashdesk_balances;
BEGIN
  PERFORM private.require_company_balances();
  SELECT * INTO v_good FROM public.cashdesk_balances WHERE method = v_method AND ok ORDER BY checked_at DESC LIMIT 1;
  RETURN private.company_balance_json(v_method, private.method_label(v_method), v_from, v_to) || jsonb_build_object(
    'checks', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'ok', b.ok, 'balance', CASE WHEN b.ok THEN private.money(b.balance_cents) END,
        'limit', CASE WHEN b.limit_cents IS NOT NULL THEN private.money(b.limit_cents) END,
        'error', b.error, 'checkedAt', b.checked_at) ORDER BY b.checked_at DESC)
      FROM (SELECT * FROM public.cashdesk_balances WHERE method = v_method ORDER BY checked_at DESC LIMIT 10) b), '[]'),
    'movements', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'kind', m.kind, 'amount', private.money(m.amount_cents),
        'orderCode', m.order_code, 'manual', m.order_id IS NULL, 'at', m.happened_at,
        'sinceCheck', m.after_check,
        'balanceAfter', CASE WHEN m.after_check THEN private.money(v_good.balance_cents + m.run) END,
        'limitAfter', CASE WHEN m.after_check AND v_good.limit_cents IS NOT NULL
          THEN private.money(v_good.limit_cents - m.run) END)
        ORDER BY m.happened_at DESC, m.id DESC)
      FROM (
        SELECT x.*, o.order_code, x.happened_at > v_good.checked_at AS after_check,
          sum(CASE WHEN x.kind = 'sale' THEN x.amount_cents ELSE -x.amount_cents END)
            FILTER (WHERE x.happened_at > v_good.checked_at)
            OVER (ORDER BY x.happened_at, x.id) AS run
        FROM (SELECT * FROM public.cashdesk_movements WHERE method = v_method
              ORDER BY happened_at DESC LIMIT 50) x
        LEFT JOIN public.orders o ON o.id = x.order_id
      ) m), '[]'),
    'orders', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', o.id, 'orderCode', o.order_code, 'direction', o.direction, 'status', o.status,
        'amount', CASE WHEN o.amount_unknown THEN NULL ELSE private.money(o.net_cents) END,
        'accountId', o.winwin_id, 'customerName', u.name, 'note', o.failure_reason,
        'waitingTopUp', o.low_funds_since IS NOT NULL AND o.status = 'processing',
        'createdAt', o.created_at, 'completedAt', o.completed_at) ORDER BY o.created_at DESC)
      FROM (SELECT * FROM public.orders o2
            WHERE o2.method = v_method
              AND COALESCE(o2.completed_at, o2.created_at) >= v_from AND o2.created_at < v_to
              AND (p_status IS NULL
                OR (p_status = 'open' AND o2.status IN ('pending', 'processing'))
                OR o2.status::text = p_status)
            ORDER BY o2.created_at DESC LIMIT 100) o
      LEFT JOIN public.users u ON u.id = o.customer_id), '[]'));
END $$;

REVOKE ALL ON FUNCTION private.cashdesk_movement(public.order_method, text, bigint, uuid, text, timestamptz) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.cashdesk_movement_immutable() FROM PUBLIC, anon, authenticated;
