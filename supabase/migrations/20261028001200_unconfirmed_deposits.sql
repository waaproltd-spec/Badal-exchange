-- Unconfirmed Deposits (Admin Dashboard, Agent App -> Account -> Unconfirmed
-- Deposits): customers who started a deposit, apart from the payments that
-- were confirmed.
--
--   * Customer has not confirmed the deposit yet: the Customer App records
--     the deposit form as the customer fills it in (customer_track_deposit_draft:
--     method and amount; the phone is the customer's registered number, read
--     here, never sent by the app). It is a temporary record of its own
--     (deposit_drafts): no order, no ledger entry, no effect on any wallet.
--   * Pending Admin Verification: the customer pressed "Confirm Deposit" and
--     the deposit order was created; the draft is tied to it. Pressing it
--     proves nothing was paid: the wallet is credited only when the payment
--     itself is verified (SMS / Sahal / an agent), as before.
--
-- Each is followed for 48 hours from when it was started; after that it is
-- shown as overdue, never removed (drafts are kept 30 days). Unpaid deposit
-- orders still expire after 30 minutes (24 hours through a merchant code) for
-- the customer (private.expire_unpaid_deposits); here they stay listed as
-- expired, unpaid and not credited.

CREATE TABLE IF NOT EXISTS public.deposit_drafts (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  method       public.order_method NOT NULL,
  amount_cents BIGINT CHECK (amount_cents IS NULL OR amount_cents > 0),
  phone        TEXT NOT NULL,
  account_id   TEXT,
  started_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  submitted_at TIMESTAMPTZ,
  order_id     UUID REFERENCES public.orders(id) ON DELETE SET NULL
);
-- One open form per customer and method.
CREATE UNIQUE INDEX IF NOT EXISTS deposit_drafts_open ON public.deposit_drafts (customer_id, method) WHERE submitted_at IS NULL;
CREATE INDEX IF NOT EXISTS deposit_drafts_started ON public.deposit_drafts (started_at DESC);
ALTER TABLE public.deposit_drafts ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.deposit_drafts FROM PUBLIC, anon, authenticated;

-- Customer App: the deposit form as it is now (method, amount, account ID
-- for a betting platform). Called while the customer types; one open record
-- per method, updated. An open form older than 48 hours is left as it was
-- (overdue) and a new one is started.
CREATE OR REPLACE FUNCTION public.customer_track_deposit_draft(p_method text, p_amount text DEFAULT NULL, p_account_id text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_cents bigint;
  d public.deposit_drafts;
BEGIN
  IF NULLIF(btrim(COALESCE(p_amount, '')), '') IS NOT NULL THEN
    IF btrim(p_amount) !~ '^\d{1,7}(\.\d{1,2})?$' THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'amount must be a number like 5 or 5.50');
    END IF;
    v_cents := round(btrim(p_amount)::numeric * 100)::bigint;
    IF v_cents <= 0 OR v_cents > 400000 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'amount out of range');
    END IF;
  END IF;
  -- Forms never confirmed are kept 30 days.
  DELETE FROM public.deposit_drafts WHERE customer_id = v_id AND order_id IS NULL AND started_at < now() - interval '30 days';
  SELECT * INTO d FROM public.deposit_drafts
  WHERE customer_id = v_id AND method = v_method AND submitted_at IS NULL FOR UPDATE;
  IF d.id IS NOT NULL AND d.started_at < now() - interval '48 hours' THEN
    -- Closed as abandoned (still listed as overdue): a new form starts below.
    UPDATE public.deposit_drafts SET submitted_at = d.updated_at WHERE id = d.id AND order_id IS NULL;
    d := NULL;
  END IF;
  IF d.id IS NULL THEN
    INSERT INTO public.deposit_drafts (customer_id, method, amount_cents, phone, account_id)
    VALUES (v_id, v_method, v_cents, (SELECT phone FROM public.users WHERE id = v_id), left(NULLIF(btrim(p_account_id), ''), 64))
    RETURNING * INTO d;
  ELSE
    UPDATE public.deposit_drafts
    SET amount_cents = COALESCE(v_cents, amount_cents),
        account_id = COALESCE(left(NULLIF(btrim(p_account_id), ''), 64), account_id),
        updated_at = now()
    WHERE id = d.id RETURNING * INTO d;
  END IF;
  RETURN jsonb_build_object('id', d.id, 'startedAt', d.started_at);
END $$;

-- "Confirm Deposit" created the order: the customer's open form for that
-- method is tied to it (submitted). Nothing else changes.
CREATE OR REPLACE FUNCTION private.deposit_draft_submitted()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'deposit' THEN
    UPDATE public.deposit_drafts SET submitted_at = now(), order_id = NEW.id, updated_at = now()
    WHERE customer_id = NEW.customer_id AND method = NEW.method AND submitted_at IS NULL;
  END IF;
  RETURN NULL;
EXCEPTION WHEN others THEN
  -- Never stands in the way of the deposit itself.
  RAISE WARNING 'deposit_draft_submitted: %', SQLERRM;
  RETURN NULL;
END $$;
REVOKE ALL ON FUNCTION private.deposit_draft_submitted() FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS orders_deposit_draft ON public.orders;
CREATE TRIGGER orders_deposit_draft AFTER INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.deposit_draft_submitted();

-- Admin: deposits started in [p_from, p_to) that are not confirmed payments.
--   not_confirmed          "Customer has not confirmed the deposit yet."
--   pending_verification   "Pending Admin Verification."
--   expired                the order expired unpaid (not credited)
--   cancelled              rejected (not credited)
-- overdue: started more than 48 hours ago and still one of the first two.
-- Completed (verified) deposits are not here: they are confirmed payments.
CREATE OR REPLACE FUNCTION public.manage_unconfirmed_deposits(p_from timestamptz DEFAULT NULL, p_to timestamptz DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_from timestamptz := COALESCE(p_from, now() - interval '7 days');
  v_to timestamptz := COALESCE(p_to, now() + interval '1 second');
  v_rows jsonb;
BEGIN
  IF v_to <= v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period must end after it starts');
  END IF;
  WITH r AS (
    -- Forms the customer never confirmed.
    SELECT d.id, NULL::uuid AS order_id, NULL::text AS order_code, d.customer_id, d.phone, d.method,
           d.amount_cents, d.account_id, d.started_at, NULL::timestamptz AS submitted_at, d.updated_at,
           'not_confirmed'::text AS status
    FROM public.deposit_drafts d
    WHERE d.order_id IS NULL AND d.started_at >= v_from AND d.started_at < v_to
    UNION ALL
    -- Deposit orders not (yet) verified, started from a form or not.
    SELECT o.id, o.id, o.order_code, o.customer_id, u.phone, o.method,
           CASE WHEN o.amount_unknown THEN NULL ELSE o.amount_cents END, o.winwin_id,
           COALESCE(d.started_at, o.created_at), o.created_at, o.updated_at,
           CASE WHEN o.status IN ('pending', 'processing') THEN 'pending_verification' ELSE o.status::text END
    FROM public.orders o
    JOIN public.users u ON u.id = o.customer_id
    LEFT JOIN public.deposit_drafts d ON d.order_id = o.id
    WHERE o.direction = 'deposit' AND o.status IN ('pending', 'processing', 'expired', 'cancelled')
      AND COALESCE(d.started_at, o.created_at) >= v_from AND COALESCE(d.started_at, o.created_at) < v_to
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'id', r.id, 'orderId', r.order_id, 'orderCode', r.order_code,
      'customerId', r.customer_id, 'customerName', u.name, 'customerPhone', r.phone,
      'method', r.method, 'amount', CASE WHEN r.amount_cents IS NOT NULL THEN private.money(r.amount_cents) END,
      'accountId', r.account_id,
      'status', r.status,
      'statusText', CASE r.status
          WHEN 'not_confirmed' THEN 'Customer has not confirmed the deposit yet.'
          WHEN 'pending_verification' THEN 'Pending Admin Verification.'
          WHEN 'expired' THEN 'Expired unpaid. Nothing was credited.'
          ELSE 'Rejected. Nothing was credited.' END,
      'overdue', r.status IN ('not_confirmed', 'pending_verification') AND r.started_at < now() - interval '48 hours',
      'startedAt', r.started_at, 'submittedAt', r.submitted_at, 'updatedAt', r.updated_at,
      'waitingSeconds', floor(extract(epoch FROM now() - r.started_at))::int
    ) ORDER BY r.started_at DESC), '[]'::jsonb)
  INTO v_rows
  FROM (SELECT * FROM r ORDER BY r.started_at DESC LIMIT 500) r
  JOIN public.users u ON u.id = r.customer_id;

  RETURN jsonb_build_object(
    'deposits', v_rows,
    'summary', jsonb_build_object(
      'notConfirmed', (SELECT count(*) FROM jsonb_array_elements(v_rows) x WHERE x->>'status' = 'not_confirmed'),
      'pendingVerification', (SELECT count(*) FROM jsonb_array_elements(v_rows) x WHERE x->>'status' = 'pending_verification'),
      'overdue', (SELECT count(*) FROM jsonb_array_elements(v_rows) x WHERE (x->>'overdue')::boolean),
      'expired', (SELECT count(*) FROM jsonb_array_elements(v_rows) x WHERE x->>'status' IN ('expired', 'cancelled'))),
    'from', v_from, 'to', v_to, 'generatedAt', now());
END $$;

REVOKE ALL ON FUNCTION public.customer_track_deposit_draft(text, text, text), public.manage_unconfirmed_deposits(timestamptz, timestamptz)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_track_deposit_draft(text, text, text), public.manage_unconfirmed_deposits(timestamptz, timestamptz)
  TO authenticated;
