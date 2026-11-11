-- Wallet to wallet transfers (Customer App: Wallet -> Send Money).
--
-- A customer sends money from their existing wallet to another customer's existing wallet, by the recipient's Wallet ID (BE592850).
-- It uses the existing wallet system: the sender's available balance is debited and the recipient's available balance is credited
-- in ONE transaction, each with a ledger entry; there is no new wallet and no fee (fee_cents is always 0, enforced by a constraint).
--
-- Safety:
--   * a 4-digit Wallet PIN, kept only as a bcrypt hash, set once with the account password; 5 wrong PINs lock sending for 15 minutes
--     (the counter is stored even when the PIN is wrong, because a wrong PIN is an answer, not an error);
--   * a retry with the same idempotency key returns the first result, a changed request with the same key is refused;
--   * both wallets are locked in a fixed order (no deadlock, no double spend); the balance is checked after the lock;
--   * nobody can send to themselves; the recipient must be an active customer; a blocked account can not call any function;
--   * the account must be allowed to withdraw (the admin's first-withdrawal approval) so a transfer is not a way around it;
--   * looking a Wallet ID up is limited to 10 a minute (no walking through the IDs), and only the name is shown.
-- Notifications: a phone notification and an entry in the Notifications list for both customers. History: public.wallet_transfers
-- (and the two ledger entries); the app lists them.

CREATE TABLE IF NOT EXISTS public.wallet_pins (
  customer_id     UUID PRIMARY KEY REFERENCES public.users(id) ON DELETE CASCADE,
  pin_hash        TEXT NOT NULL,
  failed_attempts INT NOT NULL DEFAULT 0,
  locked_until    TIMESTAMPTZ,
  set_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wallet_transfers (
  id                    UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  reference             TEXT NOT NULL UNIQUE,
  from_customer_id      UUID NOT NULL REFERENCES public.users(id),
  to_customer_id        UUID NOT NULL REFERENCES public.users(id),
  from_wallet_id        UUID NOT NULL REFERENCES public.wallets(id),
  to_wallet_id          UUID NOT NULL REFERENCES public.wallets(id),
  amount_cents          BIGINT NOT NULL CHECK (amount_cents > 0),
  fee_cents             BIGINT NOT NULL DEFAULT 0 CHECK (fee_cents = 0),           -- transfers are free
  from_balance_after    BIGINT NOT NULL,
  to_balance_after      BIGINT NOT NULL,
  idempotency_key       TEXT NOT NULL,
  created_at            TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK (from_customer_id <> to_customer_id),
  UNIQUE (from_customer_id, idempotency_key)
);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_from ON public.wallet_transfers (from_customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_wallet_transfers_to ON public.wallet_transfers (to_customer_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.wallet_transfer_events (
  id          BIGSERIAL PRIMARY KEY,
  customer_id UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  kind        TEXT NOT NULL CHECK (kind IN ('lookup', 'password_fail')),
  at          TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_wallet_transfer_events ON public.wallet_transfer_events (customer_id, kind, at DESC);

ALTER TABLE public.wallet_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transfers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wallet_transfer_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.wallet_pins, public.wallet_transfers, public.wallet_transfer_events FROM PUBLIC, anon, authenticated;

-- Phone notifications for transfers: the same queue and sender as the order notifications.
ALTER TABLE public.push_notifications ADD COLUMN IF NOT EXISTS transfer_id UUID REFERENCES public.wallet_transfers(id) ON DELETE CASCADE;
ALTER TABLE public.push_notifications DROP CONSTRAINT IF EXISTS push_notifications_kind_check;
ALTER TABLE public.push_notifications ADD CONSTRAINT push_notifications_kind_check
  CHECK (kind IN ('deposit_completed', 'withdraw_completed', 'broadcast', 'transfer_sent', 'transfer_received'));
ALTER TABLE public.push_notifications DROP CONSTRAINT IF EXISTS push_notifications_target_check;
ALTER TABLE public.push_notifications ADD CONSTRAINT push_notifications_target_check CHECK (
  CASE WHEN kind = 'broadcast'
         THEN notification_id IS NOT NULL AND order_id IS NULL AND customer_id IS NULL AND transfer_id IS NULL
       WHEN kind IN ('transfer_sent', 'transfer_received')
         THEN transfer_id IS NOT NULL AND order_id IS NULL AND notification_id IS NULL AND customer_id IS NOT NULL
       ELSE notification_id IS NULL AND transfer_id IS NULL AND order_id IS NOT NULL AND customer_id IS NOT NULL END);
CREATE UNIQUE INDEX IF NOT EXISTS idx_push_notifications_transfer ON public.push_notifications (transfer_id, kind) WHERE transfer_id IS NOT NULL;

-- As before, plus the transfer id of a transfer notification.
CREATE OR REPLACE FUNCTION public.push_claim(p_limit int DEFAULT 50)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  n public.push_notifications;
  m public.notifications;
  v_tokens text[];
  v_out jsonb := '[]'::jsonb;
BEGIN
  PERFORM private.require_service();
  UPDATE public.push_notifications SET status = 'expired', last_error = 'Not delivered within a day'
  WHERE status IN ('pending', 'sending') AND created_at < now() - interval '1 day';
  UPDATE public.push_notifications SET status = 'pending'
  WHERE status = 'sending' AND claimed_at < now() - interval '5 minutes';

  FOR n IN
    SELECT * FROM public.push_notifications WHERE status = 'pending'
    ORDER BY created_at LIMIT LEAST(GREATEST(COALESCE(p_limit, 50), 1), 200)
    FOR UPDATE SKIP LOCKED
  LOOP
    IF n.kind = 'broadcast' THEN
      SELECT * INTO m FROM public.notifications WHERE id = n.notification_id;
      UPDATE public.push_notifications SET status = 'sending', attempts = attempts + 1, claimed_at = now() WHERE id = n.id;
      v_out := v_out || jsonb_build_object('id', n.id, 'kind', n.kind, 'notificationId', n.notification_id,
        'title', m.title, 'body', m.body, 'topic', 'customers');
      CONTINUE;
    END IF;
    SELECT array_agg(token ORDER BY updated_at DESC) INTO v_tokens FROM public.push_tokens WHERE customer_id = n.customer_id;
    IF v_tokens IS NULL THEN
      UPDATE public.push_notifications SET status = 'no_device', attempts = attempts + 1 WHERE id = n.id;
      CONTINUE;
    END IF;
    UPDATE public.push_notifications SET status = 'sending', attempts = attempts + 1, claimed_at = now() WHERE id = n.id;
    v_out := v_out || jsonb_build_object('id', n.id, 'kind', n.kind, 'orderId', n.order_id, 'transferId', n.transfer_id, 'tokens', to_jsonb(v_tokens));
  END LOOP;
  RETURN v_out;
END $$;
REVOKE ALL ON FUNCTION public.push_claim(int) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.push_claim(int) TO service_role;

-- ---------------------------------------------------------------- the Wallet PIN
CREATE OR REPLACE FUNCTION public.customer_wallet_pin_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  p public.wallet_pins;
BEGIN
  SELECT * INTO p FROM public.wallet_pins WHERE customer_id = v_id;
  RETURN jsonb_build_object('hasPin', p.customer_id IS NOT NULL,
    'locked', COALESCE(p.locked_until > now(), false),
    'lockedUntil', CASE WHEN p.locked_until > now() THEN p.locked_until END);
END $$;

-- Set or change the Wallet PIN: 4 digits (not 0000, 1234, 1111...), confirmed with the account password.
CREATE OR REPLACE FUNCTION public.customer_set_wallet_pin(p_pin text, p_password text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_pin text := btrim(COALESCE(p_pin, ''));
  v_hash text;
BEGIN
  IF v_pin !~ '^[0-9]{4}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'PIN-ku waa inuu ahaado 4 lambar');
  END IF;
  IF v_pin ~ '^(.)\1{3}$' OR v_pin IN ('0123', '1234', '2345', '3456', '4567', '5678', '6789', '9876', '8765', '7654', '6543', '5432', '4321', '3210') THEN
    PERFORM private.raise_api(400, 'WEAK_PIN', 'PIN-kan way fudud tahay: dooro 4 lambar oo kale');
  END IF;
  IF (SELECT count(*) FROM public.wallet_transfer_events WHERE customer_id = v_id AND kind = 'password_fail' AND at > now() - interval '15 minutes') >= 5 THEN
    PERFORM private.raise_api(429, 'TOO_MANY_ATTEMPTS', 'Isku-day badan: fadlan sug 15 daqiiqo');
  END IF;
  SELECT password_hash INTO v_hash FROM public.users WHERE id = v_id;
  IF NOT private.verify_password(COALESCE(p_password, ''), v_hash) THEN
    INSERT INTO public.wallet_transfer_events (customer_id, kind) VALUES (v_id, 'password_fail');
    RETURN jsonb_build_object('ok', false, 'code', 'WRONG_PASSWORD');
  END IF;
  INSERT INTO public.wallet_pins (customer_id, pin_hash) VALUES (v_id, private.hash_password(v_pin))
  ON CONFLICT (customer_id) DO UPDATE SET pin_hash = EXCLUDED.pin_hash, failed_attempts = 0, locked_until = NULL, updated_at = now();
  PERFORM private.audit(v_id, 'customer', 'wallet_pin.set', 'wallet_pin', v_id::text, NULL, '{}'::jsonb);
  RETURN jsonb_build_object('ok', true);
END $$;

-- ---------------------------------------------------------------- the recipient
-- Who owns this Wallet ID? Only the name (and the ID) is returned; 10 lookups a minute at most.
CREATE OR REPLACE FUNCTION public.customer_transfer_lookup(p_wallet_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_code text := upper(btrim(COALESCE(p_wallet_id, '')));
  w public.wallets;
  u public.users;
BEGIN
  IF v_code !~ '^BE[0-9]{6}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Wallet ID-ga waa BE iyo 6 lambar (tusaale BE592850)');
  END IF;
  IF (SELECT count(*) FROM public.wallet_transfer_events WHERE customer_id = v_id AND kind = 'lookup' AND at > now() - interval '1 minute') >= 10 THEN
    PERFORM private.raise_api(429, 'TOO_MANY_ATTEMPTS', 'Isku-day badan: fadlan sug daqiiqad');
  END IF;
  INSERT INTO public.wallet_transfer_events (customer_id, kind) VALUES (v_id, 'lookup');
  SELECT * INTO w FROM public.wallets WHERE wallet_code = v_code;
  SELECT * INTO u FROM public.users WHERE id = w.customer_id AND role = 'customer' AND status = 'active';
  IF u.id IS NULL THEN
    RETURN jsonb_build_object('found', false);
  END IF;
  IF u.id = v_id THEN
    RETURN jsonb_build_object('found', true, 'self', true, 'walletId', v_code);
  END IF;
  RETURN jsonb_build_object('found', true, 'self', false, 'walletId', v_code, 'name', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'));
END $$;

-- ---------------------------------------------------------------- the transfer
CREATE OR REPLACE FUNCTION private.wallet_transfer_json(t public.wallet_transfers, p_me uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', t.id, 'reference', t.reference,
    'direction', CASE WHEN t.from_customer_id = p_me THEN 'sent' ELSE 'received' END,
    'amount', private.money(t.amount_cents), 'fee', private.money(t.fee_cents),
    'counterpartName', COALESCE(NULLIF(btrim(u.name), ''), 'Macmiil'),
    'counterpartWalletId', w.wallet_code,
    'balanceAfter', private.money(CASE WHEN t.from_customer_id = p_me THEN t.from_balance_after ELSE t.to_balance_after END),
    'createdAt', t.created_at)
  FROM public.users u JOIN public.wallets w ON w.customer_id = u.id
  WHERE u.id = CASE WHEN t.from_customer_id = p_me THEN t.to_customer_id ELSE t.from_customer_id END
$$;
REVOKE ALL ON FUNCTION private.wallet_transfer_json(public.wallet_transfers, uuid) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_wallet_transfer(p_to_wallet text, p_amount text, p_pin text, p_idempotency_key text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_to text := upper(btrim(COALESCE(p_to_wallet, '')));
  v_cents bigint;
  v_pin text := btrim(COALESCE(p_pin, ''));
  rw public.wallets;
  sw public.wallets;
  ps public.wallet_pins;
  t public.wallet_transfers;
  v_ref text;
  v_left int;
BEGIN
  IF v_to !~ '^BE[0-9]{6}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Wallet ID-ga waa BE iyo 6 lambar (tusaale BE592850)');
  END IF;
  PERFORM private.check_len(p_idempotency_key, 'idempotencyKey', 8, 100);
  v_cents := private.to_cents(p_amount);
  IF v_cents IS NULL OR v_cents <= 0 OR v_cents > 100000000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Geli lacag u dhexeysa $0.01 iyo $1,000,000.00');
  END IF;

  -- A retry of a request already done: the first result (no PIN needed again); a different request with the same key: refused.
  SELECT * INTO t FROM public.wallet_transfers WHERE from_customer_id = v_id AND idempotency_key = p_idempotency_key;
  IF t.id IS NOT NULL THEN
    IF t.amount_cents <> v_cents OR (SELECT wallet_code FROM public.wallets WHERE id = t.to_wallet_id) <> v_to THEN
      PERFORM private.raise_api(409, 'IDEMPOTENCY_CONFLICT', 'Codsigan horey ayaa loo isticmaalay dirid kale');
    END IF;
    RETURN jsonb_build_object('ok', true, 'replayed', true) || private.wallet_transfer_json(t, v_id);
  END IF;

  SELECT w.* INTO rw FROM public.wallets w JOIN public.users u ON u.id = w.customer_id AND u.role = 'customer' AND u.status = 'active'
   WHERE w.wallet_code = v_to;
  IF rw.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet ID-gan lama helin');
  END IF;
  IF rw.customer_id = v_id THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Naftaada ma u diri kartid lacag');
  END IF;
  IF NOT private.withdrawals_allowed(v_id) THEN
    PERFORM private.raise_api(403, 'TRANSFER_NOT_ALLOWED', 'Akoonkaaga weli lama fasaxin: fadlan la xiriir maamulka');
  END IF;

  -- The PIN. A wrong PIN is an answer (ok false), so the counter is kept.
  SELECT * INTO ps FROM public.wallet_pins WHERE customer_id = v_id FOR UPDATE;
  IF ps.customer_id IS NULL THEN
    PERFORM private.raise_api(400, 'PIN_NOT_SET', 'Marka hore samee Wallet PIN');
  END IF;
  IF ps.locked_until > now() THEN
    RETURN jsonb_build_object('ok', false, 'code', 'PIN_LOCKED', 'lockedUntil', ps.locked_until);
  END IF;
  IF v_pin !~ '^[0-9]{4}$' OR NOT private.verify_password(v_pin, ps.pin_hash) THEN
    UPDATE public.wallet_pins SET failed_attempts = failed_attempts + 1, updated_at = now(),
           locked_until = CASE WHEN failed_attempts + 1 >= 5 THEN now() + interval '15 minutes' END
     WHERE customer_id = v_id RETURNING failed_attempts, locked_until INTO v_left, ps.locked_until;
    IF ps.locked_until IS NOT NULL THEN
      UPDATE public.wallet_pins SET failed_attempts = 0 WHERE customer_id = v_id;
      PERFORM private.audit(v_id, 'customer', 'wallet_pin.locked', 'wallet_pin', v_id::text, NULL, '{}'::jsonb);
      RETURN jsonb_build_object('ok', false, 'code', 'PIN_LOCKED', 'lockedUntil', ps.locked_until);
    END IF;
    RETURN jsonb_build_object('ok', false, 'code', 'WRONG_PIN', 'attemptsLeft', GREATEST(5 - v_left, 0));
  END IF;
  UPDATE public.wallet_pins SET failed_attempts = 0, locked_until = NULL WHERE customer_id = v_id AND (failed_attempts <> 0 OR locked_until IS NOT NULL);

  -- Both wallets, in a fixed order, then the checks that need the locked balance.
  PERFORM 1 FROM public.wallets WHERE customer_id IN (v_id, rw.customer_id) ORDER BY id FOR UPDATE;
  SELECT * INTO sw FROM public.wallets WHERE customer_id = v_id;
  SELECT * INTO rw FROM public.wallets WHERE id = rw.id;
  SELECT * INTO t FROM public.wallet_transfers WHERE from_customer_id = v_id AND idempotency_key = p_idempotency_key;
  IF t.id IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'replayed', true) || private.wallet_transfer_json(t, v_id);
  END IF;
  IF sw.available_cents < v_cents THEN
    PERFORM private.raise_api(400, 'INSUFFICIENT_BALANCE', 'Haraagaaga waa ' || '$' || private.money(sw.available_cents) || ': kuma filna');
  END IF;

  UPDATE public.wallets SET available_cents = available_cents - v_cents, updated_at = now() WHERE id = sw.id RETURNING * INTO sw;
  UPDATE public.wallets SET available_cents = available_cents + v_cents, updated_at = now() WHERE id = rw.id RETURNING * INTO rw;
  LOOP
    v_ref := 'TRF' || upper(substr(md5(random()::text || clock_timestamp()::text), 1, 8));
    EXIT WHEN NOT EXISTS (SELECT 1 FROM public.wallet_transfers WHERE reference = v_ref);
  END LOOP;
  PERFORM private.ledger_entry(sw, NULL, 'debit', v_cents, 'Wallet transfer to ' || rw.wallet_code || ' ' || v_ref);
  PERFORM private.ledger_entry(rw, NULL, 'credit', v_cents, 'Wallet transfer from ' || sw.wallet_code || ' ' || v_ref);
  INSERT INTO public.wallet_transfers (reference, from_customer_id, to_customer_id, from_wallet_id, to_wallet_id, amount_cents,
                                       from_balance_after, to_balance_after, idempotency_key)
  VALUES (v_ref, v_id, rw.customer_id, sw.id, rw.id, v_cents, sw.available_cents, rw.available_cents, p_idempotency_key)
  RETURNING * INTO t;

  INSERT INTO public.push_notifications (customer_id, transfer_id, kind) VALUES (v_id, t.id, 'transfer_sent'), (rw.customer_id, t.id, 'transfer_received')
  ON CONFLICT DO NOTHING;
  PERFORM private.push_kick();
  PERFORM private.audit(v_id, 'customer', 'wallet.transfer', 'wallet_transfer', t.id::text, NULL,
    jsonb_build_object('reference', v_ref, 'amount', private.money(v_cents), 'toWallet', rw.wallet_code, 'toCustomerId', rw.customer_id, 'fee', '0.00'));
  RETURN jsonb_build_object('ok', true, 'replayed', false) || private.wallet_transfer_json(t, v_id);
END $$;

-- My transfers (sent and received), newest first.
CREATE OR REPLACE FUNCTION public.customer_wallet_transfers(p_limit int DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(private.wallet_transfer_json(t, v_id) ORDER BY t.created_at DESC)
    FROM (SELECT * FROM public.wallet_transfers WHERE from_customer_id = v_id OR to_customer_id = v_id
          ORDER BY created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 30), 1), 100)) t
  ), '[]'::jsonb);
END $$;

-- The Notifications list: as before, plus the transfers I sent and received (with the amount and who).
CREATE OR REPLACE FUNCTION public.customer_notifications()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN COALESCE((
    SELECT jsonb_agg(x.j ORDER BY x.at DESC)
    FROM (
      SELECT * FROM (
        SELECT private.notification_json(n) AS j, n.created_at AS at
        FROM public.notifications n
        WHERE n.created_at >= (SELECT created_at FROM public.users WHERE id = v_id)
        UNION ALL
        SELECT jsonb_build_object(
                 'id', p.id,
                 'title', CASE p.kind WHEN 'deposit_completed' THEN 'Deposit-kaagu wuu guulaystay'
                                      ELSE 'Withdrawal-kaagu wuu guulaystay' END,
                 'body', CASE p.kind WHEN 'deposit_completed' THEN 'Lacagta deposit-kaaga si guul leh ayaa loo xaqiijiyey.'
                                     ELSE 'Lacagtaada si guul leh ayaa loo bixiyey.' END
                         || format(' $%s · %s · %s', private.money(o.net_cents),
                                   COALESCE((SELECT m.label FROM public.payment_methods m WHERE m.method = o.method), o.method::text),
                                   o.order_code),
                 'createdAt', p.created_at),
               p.created_at
        FROM public.push_notifications p
        JOIN public.orders o ON o.id = p.order_id
        WHERE p.customer_id = v_id
        UNION ALL
        SELECT jsonb_build_object(
                 'id', p.id,
                 'title', CASE p.kind WHEN 'transfer_sent' THEN 'Lacag ayaad dirtay' ELSE 'Lacag ayaa laguu soo diray' END,
                 'body', CASE p.kind WHEN 'transfer_sent' THEN format('Waxaad u dirtay %s $%s (%s). Khidmad ma jirto. Haraagaaga: $%s · %s',
                                                                        c.name, private.money(t.amount_cents), cw.wallet_code, private.money(t.from_balance_after), t.reference)
                                     ELSE format('%s (%s) ayaa kuu soo diray $%s. Haraagaaga: $%s · %s',
                                                 c.name, cw.wallet_code, private.money(t.amount_cents), private.money(t.to_balance_after), t.reference) END,
                 'createdAt', p.created_at),
               p.created_at
        FROM public.push_notifications p
        JOIN public.wallet_transfers t ON t.id = p.transfer_id
        JOIN public.users c ON c.id = CASE WHEN p.kind = 'transfer_sent' THEN t.to_customer_id ELSE t.from_customer_id END
        JOIN public.wallets cw ON cw.customer_id = c.id
        WHERE p.customer_id = v_id
      ) u
      ORDER BY u.at DESC
      LIMIT 50
    ) x(j, at)
  ), '[]'::jsonb);
END
$$;

REVOKE ALL ON FUNCTION public.customer_wallet_pin_status(), public.customer_set_wallet_pin(text, text), public.customer_transfer_lookup(text),
  public.customer_wallet_transfer(text, text, text, text), public.customer_wallet_transfers(int) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_wallet_pin_status(), public.customer_set_wallet_pin(text, text), public.customer_transfer_lookup(text),
  public.customer_wallet_transfer(text, text, text, text), public.customer_wallet_transfers(int) TO authenticated;
