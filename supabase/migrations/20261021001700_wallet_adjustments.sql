-- Agent App: Add Money / Deduct Money on a customer's wallet.
--
-- Any active agent (or admin) can adjust a customer's available balance
-- directly, without approval; every adjustment is recorded for audit:
--   wallet_adjustments  one row per adjustment: reference (WAL...),
--                       customer, add/deduct, amount, balance before and
--                       after, reason, agent, time, status. Rows can never
--                       be changed or deleted (trigger), and only these
--                       functions read them -- customers can't.
--   ledger_entries      the wallet's ledger gets a credit or debit that
--                       only says "Wallet adjustment <reference>": the
--                       customer can read their ledger, so the agent's
--                       reason and identity stay out of it.
--   audit_logs          wallet.adjust_add / wallet.adjust_deduct.
-- Balance changes happen only here, on the locked wallet row, so two
-- adjustments (or an adjustment and a withdrawal) can't interleave; a
-- deduction can't take the available balance below zero. A retried
-- request with the same idempotency key returns the first result.

CREATE TABLE IF NOT EXISTS public.wallet_adjustments (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reference             TEXT NOT NULL UNIQUE,
  customer_id           UUID NOT NULL REFERENCES public.users(id),
  wallet_id             UUID NOT NULL REFERENCES public.wallets(id),
  direction             TEXT NOT NULL CHECK (direction IN ('add', 'deduct')),
  amount_cents          BIGINT NOT NULL CHECK (amount_cents > 0),
  balance_before_cents  BIGINT NOT NULL,
  balance_after_cents   BIGINT NOT NULL CHECK (balance_after_cents >= 0),
  reason                TEXT NOT NULL,
  agent_id              UUID NOT NULL REFERENCES public.users(id),
  idempotency_key       TEXT NOT NULL,
  status                TEXT NOT NULL DEFAULT 'completed' CHECK (status = 'completed'),
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (agent_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_wallet_adjustments_customer ON public.wallet_adjustments (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_adjustments_agent ON public.wallet_adjustments (agent_id, created_at DESC);
ALTER TABLE public.wallet_adjustments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wallet_adjustments FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION private.wallet_adjustment_immutable()
RETURNS trigger LANGUAGE plpgsql SET search_path = '' AS $$
BEGIN
  RAISE EXCEPTION 'wallet adjustments can not be changed or deleted';
END $$;
DROP TRIGGER IF EXISTS wallet_adjustments_immutable ON public.wallet_adjustments;
CREATE TRIGGER wallet_adjustments_immutable BEFORE UPDATE OR DELETE ON public.wallet_adjustments
FOR EACH ROW EXECUTE FUNCTION private.wallet_adjustment_immutable();

CREATE OR REPLACE FUNCTION private.wallet_adjustment_json(a public.wallet_adjustments)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', a.id, 'reference', a.reference,
    'customerId', a.customer_id, 'customerName', c.name, 'customerPhone', c.phone,
    'direction', a.direction, 'amount', private.money(a.amount_cents),
    'balanceBefore', private.money(a.balance_before_cents), 'balanceAfter', private.money(a.balance_after_cents),
    'reason', a.reason, 'agentId', a.agent_id, 'agentName', ag.name,
    'status', a.status, 'createdAt', a.created_at)
  FROM public.users c, public.users ag
  WHERE c.id = a.customer_id AND ag.id = a.agent_id
$$;

-- Add (p_direction 'add') or deduct ('deduct') p_amount on a customer's
-- available balance.
CREATE OR REPLACE FUNCTION public.agent_wallet_adjust(
  p_customer_id uuid, p_direction text, p_amount text, p_reason text, p_idempotency_key text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_user();
  v_role public.user_role := private.app_role();
  v_direction text := lower(btrim(COALESCE(p_direction, '')));
  v_reason text := btrim(COALESCE(p_reason, ''));
  v_cents bigint;
  w public.wallets;
  a public.wallet_adjustments;
  v_ref text;
BEGIN
  IF NOT private.is_staff() THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
  IF v_direction NOT IN ('add', 'deduct') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'direction must be add or deduct');
  END IF;
  PERFORM private.check_len(p_idempotency_key, 'idempotencyKey', 8, 100);
  PERFORM private.check_len(v_reason, 'reason', 3, 200);
  v_cents := private.to_cents(p_amount);
  IF v_cents IS NULL OR v_cents <= 0 OR v_cents > 10000000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter an amount between $0.01 and $100000.00');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;

  -- One adjustment at a time per wallet.
  w := private.lock_wallet(p_customer_id);

  -- A retry of a request already processed returns its result.
  SELECT * INTO a FROM public.wallet_adjustments WHERE agent_id = v_agent AND idempotency_key = p_idempotency_key;
  IF a.id IS NOT NULL THEN
    IF a.customer_id <> p_customer_id OR a.direction <> v_direction OR a.amount_cents <> v_cents THEN
      PERFORM private.raise_api(409, 'IDEMPOTENCY_CONFLICT', 'This request was already used for a different adjustment');
    END IF;
    RETURN private.wallet_adjustment_json(a) || jsonb_build_object('replayed', true);
  END IF;

  IF v_direction = 'deduct' AND w.available_cents < v_cents THEN
    PERFORM private.raise_api(400, 'INSUFFICIENT_BALANCE',
      'The customer''s available balance is $' || private.money(w.available_cents) || '; you can deduct at most that');
  END IF;

  LOOP
    v_ref := 'WAL' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.wallet_adjustments WHERE reference = v_ref);
  END LOOP;

  UPDATE public.wallets
  SET available_cents = available_cents + CASE WHEN v_direction = 'add' THEN v_cents ELSE -v_cents END,
      updated_at = now()
  WHERE id = w.id
  RETURNING * INTO w;
  PERFORM private.ledger_entry(w, NULL, (CASE WHEN v_direction = 'add' THEN 'credit' ELSE 'debit' END)::public.ledger_entry_type,
    v_cents, 'Wallet adjustment ' || v_ref);

  INSERT INTO public.wallet_adjustments (reference, customer_id, wallet_id, direction, amount_cents,
    balance_before_cents, balance_after_cents, reason, agent_id, idempotency_key)
  VALUES (v_ref, p_customer_id, w.id, v_direction, v_cents,
    w.available_cents + CASE WHEN v_direction = 'add' THEN -v_cents ELSE v_cents END, w.available_cents,
    v_reason, v_agent, p_idempotency_key)
  RETURNING * INTO a;

  PERFORM private.audit(v_agent, v_role, 'wallet.adjust_' || v_direction, 'wallet_adjustment', a.id::text,
    jsonb_build_object('balance', private.money(a.balance_before_cents)),
    jsonb_build_object('balance', private.money(a.balance_after_cents), 'amount', private.money(v_cents),
      'reference', v_ref, 'customerId', p_customer_id, 'reason', v_reason));
  RETURN private.wallet_adjustment_json(a);
END
$$;

-- Adjustments, newest first: an agent sees the ones they made; managers
-- and admins see everyone's. Optionally for one customer / one direction.
CREATE OR REPLACE FUNCTION public.agent_wallet_adjustments(
  p_customer_id uuid DEFAULT NULL, p_direction text DEFAULT NULL, p_limit int DEFAULT 100
)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_user();
  v_all boolean;
BEGIN
  IF NOT private.is_staff() THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
  v_all := private.can_manage();
  RETURN COALESCE((
    SELECT jsonb_agg(private.wallet_adjustment_json(a) ORDER BY a.created_at DESC)
    FROM (
      SELECT * FROM public.wallet_adjustments a
      WHERE (v_all OR a.agent_id = v_agent)
        AND (p_customer_id IS NULL OR a.customer_id = p_customer_id)
        AND (p_direction IS NULL OR a.direction = lower(p_direction))
      ORDER BY a.created_at DESC
      LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)
    ) a
  ), '[]'::jsonb);
END
$$;

REVOKE ALL ON FUNCTION private.wallet_adjustment_immutable() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.wallet_adjustment_json(public.wallet_adjustments) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.agent_wallet_adjust(uuid, text, text, text, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.agent_wallet_adjustments(uuid, text, int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_wallet_adjust(uuid, text, text, text, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.agent_wallet_adjustments(uuid, text, int) TO authenticated, service_role;
