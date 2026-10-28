-- Account verification before a customer's first withdrawal.
--
-- A customer's withdrawals need their account approved by an admin
-- (withdrawal_approvals, one row per customer: never two requests). Until
-- then every withdrawal is refused when the order would be created -- by
-- the app or by a direct API call alike (a trigger on orders) -- with
-- WITHDRAWAL_VERIFICATION_REQUIRED and the admin's WhatsApp number. Deposits,
-- balances and everything else are untouched.
--
--   * Customers who already completed a withdrawal are approved here (they
--     are past their first one); nobody legitimate is suddenly stopped.
--   * Opening Withdraw in the Customer App (customer_withdrawal_access)
--     records a pending request the first time.
--   * Admins approve (who and when is kept), reject with a reason, or later
--     restrict an approved account again, with a reason.
--   * The WhatsApp number is the support contact admins already set
--     (app_settings contact_whatsapp).
--   * app_settings withdrawal_verification = 'off' turns the rule off.

INSERT INTO public.app_settings (key, value) VALUES ('withdrawal_verification', 'on') ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.withdrawal_approvals (
  customer_id   UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  status        TEXT NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'restricted')),
  requested_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  decided_at    TIMESTAMPTZ,
  decided_by    UUID REFERENCES public.users(id) ON DELETE SET NULL,
  reason        TEXT,
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS withdrawal_approvals_status ON public.withdrawal_approvals (status, requested_at DESC);
ALTER TABLE public.withdrawal_approvals ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.withdrawal_approvals FROM PUBLIC, anon, authenticated;

-- Already withdrew: approved (by nobody: the rule did not exist yet).
INSERT INTO public.withdrawal_approvals (customer_id, status, requested_at, decided_at, reason)
SELECT DISTINCT o.customer_id, 'approved', now(), now(), 'Had already withdrawn before verification was required'
FROM public.orders o JOIN public.users u ON u.id = o.customer_id AND u.role = 'customer'
WHERE o.direction = 'withdraw' AND o.status = 'completed'
ON CONFLICT (customer_id) DO NOTHING;

CREATE OR REPLACE FUNCTION private.withdrawal_verification_on()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT lower(btrim(value)) FROM public.app_settings WHERE key = 'withdrawal_verification'), 'on') <> 'off'
$$;

CREATE OR REPLACE FUNCTION private.admin_whatsapp()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'contact_whatsapp')), '')
$$;

CREATE OR REPLACE FUNCTION private.withdrawal_verification_message()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT 'Si aad lacag ula baxdo markii ugu horreysay, fadlan la xiriir maamulka si account-kaaga loo xaqiijiyo loona fasaxo.'
         || COALESCE(' WhatsApp-ka maamulka: ' || private.admin_whatsapp() || '.', '')
$$;

-- The short account ID customers and admins both see (EX-style, from the user id).
CREATE OR REPLACE FUNCTION private.account_code(p_id uuid)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT 'BX' || upper(left(replace(p_id::text, '-', ''), 8))
$$;

CREATE OR REPLACE FUNCTION private.withdrawals_allowed(p_customer uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT NOT private.withdrawal_verification_on()
      OR EXISTS (SELECT 1 FROM public.withdrawal_approvals a WHERE a.customer_id = p_customer AND a.status = 'approved')
$$;

-- The rule itself, wherever a withdrawal comes from.
CREATE OR REPLACE FUNCTION private.withdrawal_verification_check()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  IF NEW.direction = 'withdraw' AND NOT private.withdrawals_allowed(NEW.customer_id) THEN
    PERFORM private.raise_api(403, 'WITHDRAWAL_VERIFICATION_REQUIRED', private.withdrawal_verification_message());
  END IF;
  RETURN NEW;
END $$;
REVOKE ALL ON FUNCTION private.withdrawal_verification_check(), private.withdrawals_allowed(uuid),
  private.withdrawal_verification_on(), private.admin_whatsapp(), private.withdrawal_verification_message()
  FROM PUBLIC, anon, authenticated;
DROP TRIGGER IF EXISTS orders_withdrawal_verification ON public.orders;
CREATE TRIGGER orders_withdrawal_verification BEFORE INSERT ON public.orders
  FOR EACH ROW EXECUTE FUNCTION private.withdrawal_verification_check();

-- Customer App, opening Withdraw: may this account withdraw? The first time,
-- a request for the admin is recorded (once).
CREATE OR REPLACE FUNCTION public.customer_withdrawal_access()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  a public.withdrawal_approvals;
BEGIN
  IF private.withdrawal_verification_on() THEN
    INSERT INTO public.withdrawal_approvals (customer_id) VALUES (v_id) ON CONFLICT (customer_id) DO NOTHING;
  END IF;
  SELECT * INTO a FROM public.withdrawal_approvals WHERE customer_id = v_id;
  RETURN jsonb_build_object(
    'allowed', private.withdrawals_allowed(v_id),
    'status', CASE WHEN NOT private.withdrawal_verification_on() THEN 'approved' ELSE COALESCE(a.status, 'pending') END,
    'reason', CASE WHEN a.status IN ('rejected', 'restricted') THEN a.reason END,
    'message', CASE WHEN NOT private.withdrawals_allowed(v_id) THEN private.withdrawal_verification_message() END,
    'whatsapp', private.admin_whatsapp(),
    'accountId', private.account_code(v_id),
    'phone', (SELECT phone FROM public.users WHERE id = v_id));
END $$;

-- Admin: the requests, newest first (p_status: pending | approved | rejected |
-- restricted | all), each with what the customer has done so far.
CREATE OR REPLACE FUNCTION public.manage_withdrawal_verifications(p_status text DEFAULT 'pending')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status text := COALESCE(NULLIF(btrim(p_status), ''), 'pending');
BEGIN
  IF v_status NOT IN ('pending', 'approved', 'rejected', 'restricted', 'all') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid status');
  END IF;
  RETURN jsonb_build_object(
    'counts', (SELECT jsonb_object_agg(s.status, s.n) FROM (SELECT status, count(*) AS n FROM public.withdrawal_approvals GROUP BY status) s),
    'whatsapp', private.admin_whatsapp(),
    'on', private.withdrawal_verification_on(),
    'requests', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'customerId', a.customer_id, 'accountId', private.account_code(a.customer_id),
        'name', u.name, 'phone', u.phone, 'customerStatus', u.status, 'joinedAt', u.created_at,
        'status', a.status, 'requestedAt', a.requested_at, 'decidedAt', a.decided_at,
        'decidedBy', (SELECT d.name FROM public.users d WHERE d.id = a.decided_by), 'reason', a.reason,
        'balance', (SELECT private.money(w.available_cents) FROM public.wallets w WHERE w.customer_id = a.customer_id),
        'deposits', (SELECT jsonb_build_object('count', count(*), 'total', private.money(COALESCE(sum(o.amount_cents), 0)))
                     FROM public.orders o WHERE o.customer_id = a.customer_id AND o.direction = 'deposit' AND o.status = 'completed'),
        'withdrawals', (SELECT jsonb_build_object('count', count(*), 'total', private.money(COALESCE(sum(o.amount_cents), 0)))
                        FROM public.orders o WHERE o.customer_id = a.customer_id AND o.direction = 'withdraw' AND o.status = 'completed'),
        'recent', COALESCE((SELECT jsonb_agg(jsonb_build_object('orderCode', r.order_code, 'direction', r.direction, 'method', r.method,
                     'status', r.status, 'amount', private.money(r.amount_cents), 'createdAt', r.created_at) ORDER BY r.created_at DESC)
                   FROM (SELECT * FROM public.orders o WHERE o.customer_id = a.customer_id ORDER BY o.created_at DESC LIMIT 10) r), '[]'::jsonb)
      ) ORDER BY a.requested_at DESC)
      FROM (SELECT * FROM public.withdrawal_approvals x WHERE v_status = 'all' OR x.status = v_status
            ORDER BY x.requested_at DESC LIMIT 200) a
      JOIN public.users u ON u.id = a.customer_id), '[]'::jsonb));
END $$;

-- Admin: approve, reject (reason required) or restrict again (reason
-- required). p_decision: approve | reject | restrict. Audited.
CREATE OR REPLACE FUNCTION public.manage_decide_withdrawal_verification(p_customer_id uuid, p_decision text, p_reason text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status text := CASE p_decision WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected' WHEN 'restrict' THEN 'restricted' END;
  v_before public.withdrawal_approvals;
  a public.withdrawal_approvals;
BEGIN
  IF v_status IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'decision must be approve, reject or restrict');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.users WHERE id = p_customer_id AND role = 'customer') THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Customer not found');
  END IF;
  IF v_status <> 'approved' THEN
    PERFORM private.check_len(p_reason, 'reason', 3, 300);
  END IF;
  SELECT * INTO v_before FROM public.withdrawal_approvals WHERE customer_id = p_customer_id FOR UPDATE;
  INSERT INTO public.withdrawal_approvals (customer_id, status, decided_at, decided_by, reason, updated_at)
  VALUES (p_customer_id, v_status, now(), v_id, NULLIF(btrim(COALESCE(p_reason, '')), ''), now())
  ON CONFLICT (customer_id) DO UPDATE SET status = EXCLUDED.status, decided_at = now(), decided_by = v_id,
    reason = EXCLUDED.reason, updated_at = now()
  RETURNING * INTO a;
  PERFORM private.audit(v_id, private.app_role(), 'withdrawal_verification.' || p_decision, 'user', p_customer_id::text,
    CASE WHEN v_before.customer_id IS NOT NULL THEN jsonb_build_object('status', v_before.status) END,
    jsonb_build_object('status', a.status, 'reason', a.reason));
  RETURN jsonb_build_object('customerId', a.customer_id, 'status', a.status, 'decidedAt', a.decided_at, 'reason', a.reason);
END $$;

REVOKE ALL ON FUNCTION public.customer_withdrawal_access(), public.manage_withdrawal_verifications(text),
  public.manage_decide_withdrawal_verification(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_withdrawal_access(), public.manage_withdrawal_verifications(text),
  public.manage_decide_withdrawal_verification(uuid, text, text) TO authenticated;
