-- Wallet transfer hardening (security check):
--   * the PIN is checked BEFORE the recipient is looked up, so the transfer call can not be used to find out which Wallet IDs exist;
--   * the Wallet ID lookup is also limited to 40 an hour (it was 10 a minute only: 14,000 a day);
--   * every further PIN lock doubles the wait (15 min, 30 min, 1 h ... about 16 h) until the right PIN resets it, so the 10,000 possible PINs can not be walked through.

ALTER TABLE public.wallet_pins ADD COLUMN IF NOT EXISTS lock_count INT NOT NULL DEFAULT 0;

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
  IF (SELECT count(*) FROM public.wallet_transfer_events WHERE customer_id = v_id AND kind = 'lookup' AND at > now() - interval '1 minute') >= 10
     OR (SELECT count(*) FROM public.wallet_transfer_events WHERE customer_id = v_id AND kind = 'lookup' AND at > now() - interval '1 hour') >= 40 THEN
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
    -- 5 wrong tries lock for 15 minutes; every further lock doubles it (30 min, 1 h ... at most about 16 h) until the right PIN is entered.
    UPDATE public.wallet_pins SET failed_attempts = failed_attempts + 1, updated_at = now(),
           locked_until = CASE WHEN failed_attempts + 1 >= 5 THEN now() + interval '15 minutes' * power(2, LEAST(lock_count, 6)) END
     WHERE customer_id = v_id RETURNING failed_attempts, locked_until INTO v_left, ps.locked_until;
    IF ps.locked_until IS NOT NULL THEN
      UPDATE public.wallet_pins SET failed_attempts = 0, lock_count = lock_count + 1 WHERE customer_id = v_id;
      PERFORM private.audit(v_id, 'customer', 'wallet_pin.locked', 'wallet_pin', v_id::text, NULL, '{}'::jsonb);
      RETURN jsonb_build_object('ok', false, 'code', 'PIN_LOCKED', 'lockedUntil', ps.locked_until);
    END IF;
    RETURN jsonb_build_object('ok', false, 'code', 'WRONG_PIN', 'attemptsLeft', GREATEST(5 - v_left, 0));
  END IF;
  UPDATE public.wallet_pins SET failed_attempts = 0, locked_until = NULL, lock_count = 0 WHERE customer_id = v_id AND (failed_attempts <> 0 OR locked_until IS NOT NULL OR lock_count <> 0);

  -- Only after the PIN: whether the Wallet ID exists is not told to somebody who does not know the PIN.
  SELECT w.* INTO rw FROM public.wallets w JOIN public.users u ON u.id = w.customer_id AND u.role = 'customer' AND u.status = 'active'
   WHERE w.wallet_code = v_to;
  IF rw.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Wallet ID-gan lama helin');
  END IF;
  IF rw.customer_id = v_id THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Naftaada ma u diri kartid lacag');
  END IF;

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

REVOKE ALL ON FUNCTION public.customer_transfer_lookup(text), public.customer_wallet_transfer(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_transfer_lookup(text), public.customer_wallet_transfer(text, text, text, text) TO authenticated;
