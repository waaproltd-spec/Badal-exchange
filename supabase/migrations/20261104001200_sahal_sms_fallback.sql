-- Sahal is the primary source of a deposit; the SMS 898 that Sahal sends to the merchant phone is the
-- fallback.
--
--   * The Agent App reads SMS 898 ("[SAHAL] Tix: 7543914546, Waxaad $1 ka heshay NAME (252610346060) ...")
--     and uploads it as provider 'Sahal' (agent_ingest_payment_sms, deduped by the Tix reference).
--   * A Sahal SMS is paired with the Sahal merchant-feed row of the same payment (same payer's last 9 digits,
--     same amount, within 3 minutes). Paired, the payment is credited ONCE, by whichever source got there
--     first; the other is marked a duplicate and never credits.
--   * With no feed row for it, the SMS credits the deposit itself -- at once when the Sahal feed is down, after
--     90 seconds when it is up (a direct wallet transfer never appears in the feed, only in the SMS).
--   * Back to normal by itself: when the feed answers again its rows credit as before, and an SMS that the
--     feed already reported is only ever a duplicate.
--   * The dashboard shows which source is carrying payments: Sahal / Agent SIM fallback / neither.

ALTER TABLE public.sms_logs
  ADD COLUMN IF NOT EXISTS paired_merchant_id UUID;
ALTER TABLE public.merchant_transactions
  ADD COLUMN IF NOT EXISTS paired_sms_id UUID UNIQUE REFERENCES public.sms_logs(id) ON DELETE SET NULL;
CREATE UNIQUE INDEX IF NOT EXISTS idx_sms_logs_paired_merchant ON public.sms_logs (paired_merchant_id) WHERE paired_merchant_id IS NOT NULL;

ALTER TABLE public.merchant_transactions DROP CONSTRAINT IF EXISTS merchant_transactions_match_status_check;
ALTER TABLE public.merchant_transactions ADD CONSTRAINT merchant_transactions_match_status_check
  CHECK (match_status IN ('new', 'matched', 'unmatched', 'ignored', 'duplicate'));

-- The phone that reads SMS says so every minute while its SMS reader runs.
ALTER TABLE public.agent_devices ADD COLUMN IF NOT EXISTS sms_listening_at TIMESTAMPTZ;

CREATE OR REPLACE FUNCTION public.agent_sms_heartbeat(p_device_id text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_role('agent');
BEGIN
  PERFORM private.check_len(p_device_id, 'deviceId', 4, 200);
  UPDATE public.agent_devices SET sms_listening_at = now(), last_seen_at = now()
  WHERE agent_id = v_agent AND device_id = p_device_id;
END $$;

-- Is Sahal answering? (its feed polls every 10 seconds)
CREATE OR REPLACE FUNCTION private.sahal_feed_up()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((SELECT s.state = 'ok' AND s.checked_at > now() - interval '2 minutes'
                     FROM public.merchant_feed_status s WHERE s.provider = 'golis'), false)
$$;

-- Is an Agent phone reading SMS right now?
CREATE OR REPLACE FUNCTION private.agent_sim_up()
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT EXISTS (SELECT 1 FROM public.agent_devices d WHERE d.status = 'active' AND d.sms_listening_at > now() - interval '3 minutes')
$$;

-- 'sahal' | 'agent_sim' | 'none'
CREATE OR REPLACE FUNCTION private.payment_source()
RETURNS text LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT CASE WHEN private.sahal_feed_up() THEN 'sahal' WHEN private.agent_sim_up() THEN 'agent_sim' ELSE 'none' END
$$;

CREATE OR REPLACE FUNCTION public.manage_payment_source()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN jsonb_build_object(
    'source', private.payment_source(),
    'sahalUp', private.sahal_feed_up(),
    'simUp', private.agent_sim_up(),
    'sahalCheckedAt', (SELECT checked_at FROM public.merchant_feed_status WHERE provider = 'golis'),
    'simSeenAt', (SELECT max(sms_listening_at) FROM public.agent_devices WHERE status = 'active'),
    'creditedBySmsToday', (SELECT count(*) FROM public.sms_logs WHERE parsed_provider = 'Sahal' AND match_status = 'matched'
                            AND created_at > now() - interval '24 hours'),
    'waitingToday', (SELECT count(*) FROM public.sms_logs WHERE parsed_provider = 'Sahal' AND match_status = 'unmatched'
                      AND received_at > now() - interval '24 hours'));
END $$;

-- A Sahal SMS: pair it with the feed's row, or credit the deposit it pays.
CREATE OR REPLACE FUNCTION private.match_sahal_sms(p_sms_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  s public.sms_logs;
  m public.merchant_transactions;
  o public.orders;
  v_key text;
  v_cents bigint;
  v_reason text;
BEGIN
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id;
  IF s.id IS NULL OR s.match_status <> 'unmatched' THEN
    RETURN jsonb_build_object('status', COALESCE(s.match_status, 'missing'), 'orderId', s.matched_order_id);
  END IF;
  v_key := private.phone_key(s.parsed_phone);
  IF s.parsed_amount IS NULL OR v_key IS NULL THEN
    UPDATE public.sms_logs SET match_status = 'ignored',
      match_failure_reason = 'SMS did not parse a usable amount and sender phone number' WHERE id = s.id;
    RETURN jsonb_build_object('status', 'ignored');
  END IF;
  v_cents := round(s.parsed_amount * 100);
  -- One payment (payer + amount) is decided by one transaction at a time, from either source.
  PERFORM pg_advisory_xact_lock(hashtext('sahalpay:' || v_key || ':' || v_cents));
  SELECT * INTO s FROM public.sms_logs WHERE id = p_sms_id FOR UPDATE;
  IF s.match_status <> 'unmatched' THEN
    RETURN jsonb_build_object('status', s.match_status, 'orderId', s.matched_order_id);
  END IF;
  IF s.received_at < now() - interval '24 hours' THEN
    UPDATE public.sms_logs SET match_failure_reason = 'Received more than 24h ago: outside the matching window' WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', 'outside the matching window');
  END IF;

  -- Did Sahal's own feed report this payment? Then the feed carries it and the SMS is only a duplicate.
  SELECT * INTO m FROM public.merchant_transactions x
  WHERE x.provider = 'golis' AND x.direction = 'in' AND x.paired_sms_id IS NULL
    AND x.payer_phone IS NOT NULL AND right(x.payer_phone, 9) = v_key AND x.amount_cents = v_cents
    AND x.paid_at BETWEEN s.received_at - interval '3 minutes' AND s.received_at + interval '3 minutes'
    AND x.match_status IN ('new', 'unmatched', 'matched')
  ORDER BY abs(extract(epoch FROM x.paid_at - s.received_at)) ASC
  LIMIT 1
  FOR UPDATE;
  IF m.id IS NOT NULL THEN
    UPDATE public.merchant_transactions SET paired_sms_id = s.id WHERE id = m.id;
    UPDATE public.sms_logs SET match_status = 'duplicate_blocked', paired_merchant_id = m.id,
      match_failure_reason = 'Sahal reported this payment itself: not credited twice' WHERE id = s.id;
    RETURN jsonb_build_object('status', 'duplicate_blocked', 'orderId', m.matched_order_id);
  END IF;

  -- Sahal is answering: give its feed 90 seconds to list the payment before the SMS takes over.
  IF private.sahal_feed_up() AND s.received_at > now() - interval '90 seconds' THEN
    UPDATE public.sms_logs SET match_failure_reason = 'Waiting for Sahal to list it (the SMS takes over after 90 seconds)' WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', 'waiting for Sahal');
  END IF;

  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'deposit'
    AND x.method IN (SELECT method FROM public.payment_methods WHERE kind = 'mobile_money')
    AND private.phone_key(x.phone_number) = v_key
    AND x.amount_cents = v_cents
    AND (x.status = 'pending' OR (x.status = 'expired' AND x.failure_reason = private.unpaid_deposit_reason()))
    AND x.created_at BETWEEN s.received_at - interval '24 hours' AND s.received_at + interval '10 minutes'
    AND NOT EXISTS (SELECT 1 FROM public.merchant_transactions y WHERE y.matched_order_id = x.id)
    AND NOT EXISTS (SELECT 1 FROM public.sms_logs z WHERE z.matched_order_id = x.id)
  ORDER BY (x.status = 'pending') DESC, x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    v_reason := format('No pending deposit for $%s from ...%s in the last 24h', s.parsed_amount, v_key);
    UPDATE public.sms_logs SET match_failure_reason = v_reason WHERE id = s.id;
    RETURN jsonb_build_object('status', 'unmatched', 'reason', v_reason);
  END IF;
  IF o.status = 'expired' THEN
    UPDATE public.orders SET status = 'pending', failure_reason = NULL, updated_at = now() WHERE id = o.id;
    PERFORM private.order_audit(o.id, 'deposit_reopened_paid', jsonb_build_object('status', 'expired'),
      jsonb_build_object('status', 'pending', 'sahalSms', s.transaction_ref), NULL);
  END IF;
  o := private.complete_deposit_order(o.id, 'Sahal SMS ' || COALESCE(s.transaction_ref, s.id::text), s.agent_id, 'agent');
  UPDATE public.sms_logs SET match_status = 'matched', matched_order_id = o.id, match_failure_reason = NULL WHERE id = s.id;
  PERFORM private.order_audit(o.id, 'deposit_verified_by_sahal_sms', jsonb_build_object('status', 'pending'),
    jsonb_build_object('status', o.status, 'smsLogId', s.id, 'amount', s.parsed_amount, 'smsReceivedAt', s.received_at,
      'transactionRef', s.transaction_ref, 'sahalFeedUp', private.sahal_feed_up(), 'verifiedAt', now()), s.agent_id);
  RETURN jsonb_build_object('status', 'matched', 'orderId', o.id);
END $$;

-- As before, plus: a payment Sahal's feed lists is first paired with its SMS (when that already credited it,
-- the feed row is a duplicate and credits nothing).
CREATE OR REPLACE FUNCTION private.merchant_match(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  t public.merchant_transactions;
  o public.orders;
  sm public.sms_logs;
BEGIN
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') OR t.payer_phone IS NULL OR t.amount_cents IS NULL
     OR t.direction IS DISTINCT FROM 'in' THEN
    RETURN;
  END IF;
  PERFORM pg_advisory_xact_lock(hashtext('sahalpay:' || right(t.payer_phone, 9) || ':' || t.amount_cents));
  SELECT * INTO t FROM public.merchant_transactions WHERE id = p_id FOR UPDATE SKIP LOCKED;
  IF t.id IS NULL OR t.match_status NOT IN ('new', 'unmatched') THEN
    RETURN;
  END IF;

  IF t.paired_sms_id IS NULL THEN
    SELECT * INTO sm FROM public.sms_logs x
    WHERE x.parsed_provider = 'Sahal' AND x.paired_merchant_id IS NULL
      AND private.phone_key(x.parsed_phone) = right(t.payer_phone, 9) AND round(x.parsed_amount * 100) = t.amount_cents
      AND x.received_at BETWEEN t.paid_at - interval '3 minutes' AND t.paid_at + interval '3 minutes'
      AND x.match_status IN ('unmatched', 'matched')
    ORDER BY abs(extract(epoch FROM x.received_at - t.paid_at)) ASC
    LIMIT 1
    FOR UPDATE;
    IF sm.id IS NOT NULL THEN
      UPDATE public.merchant_transactions SET paired_sms_id = sm.id WHERE id = t.id;
      UPDATE public.sms_logs SET paired_merchant_id = t.id WHERE id = sm.id;
      IF sm.match_status = 'matched' THEN
        -- The SMS already credited this payment (Sahal was slow): never twice.
        UPDATE public.merchant_transactions SET match_status = 'duplicate', matched_order_id = NULL WHERE id = t.id;
        RETURN;
      END IF;
      UPDATE public.sms_logs SET match_status = 'duplicate_blocked',
        match_failure_reason = 'Sahal reported this payment itself: not credited twice' WHERE id = sm.id;
    END IF;
  END IF;

  SELECT * INTO o FROM public.orders x
  WHERE x.direction = 'deposit'
    AND x.method IN (SELECT method FROM public.payment_methods WHERE kind = 'mobile_money')
    AND right(regexp_replace(COALESCE(x.phone_number, ''), '\D', '', 'g'), 9) = right(t.payer_phone, 9)
    AND x.amount_cents = t.amount_cents
    AND (x.status = 'pending'
         OR (x.status = 'expired' AND x.failure_reason = private.unpaid_deposit_reason()))
    AND x.created_at BETWEEN t.paid_at - interval '24 hours' AND t.paid_at + interval '10 minutes'
    AND NOT EXISTS (SELECT 1 FROM public.merchant_transactions m WHERE m.matched_order_id = x.id)
  ORDER BY (x.status = 'pending') DESC, x.created_at ASC
  LIMIT 1
  FOR UPDATE SKIP LOCKED;
  IF o.id IS NULL THEN
    UPDATE public.merchant_transactions SET match_status = 'unmatched' WHERE id = p_id;
    RETURN;
  END IF;
  IF o.status = 'expired' THEN
    UPDATE public.orders SET status = 'pending', failure_reason = NULL, updated_at = now() WHERE id = o.id;
    PERFORM private.order_audit(o.id, 'deposit_reopened_paid', jsonb_build_object('status', 'expired'),
      jsonb_build_object('status', 'pending', 'merchantTransaction', t.transaction_id), NULL);
  END IF;
  UPDATE public.merchant_transactions SET match_status = 'matched', matched_order_id = o.id, matched_at = now()
  WHERE id = p_id;
  PERFORM private.complete_deposit_order(o.id, 'Sahal merchant ' || t.transaction_id, NULL, NULL);
END $$;

-- As before (the deposit duty check included), plus the upload of a Sahal SMS goes to its own matcher.
CREATE OR REPLACE FUNCTION public.agent_ingest_payment_sms(
  p_sender text, p_body text, p_received_at text,
  p_parsed_provider text DEFAULT NULL, p_parsed_amount text DEFAULT NULL, p_parsed_phone text DEFAULT NULL,
  p_transaction_ref text DEFAULT NULL, p_sim_slot int DEFAULT NULL, p_device_id text DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_agent uuid := private.require_agent_duty('evc_deposit');
  v_received timestamptz := private.parse_ts(p_received_at, 'receivedAt');
  v_ref text := NULLIF(btrim(COALESCE(p_transaction_ref, '')), '');
  v_amount numeric;
  v_id uuid;
  v_existing public.sms_logs;
  v_result jsonb;
BEGIN
  PERFORM private.check_len(p_sender, 'sender', 1, 60);
  PERFORM private.check_len(p_body, 'body', 1, 2000);
  IF p_parsed_amount IS NOT NULL THEN
    v_amount := private.to_amount(p_parsed_amount);
  END IF;

  IF v_ref IS NOT NULL THEN
    SELECT * INTO v_existing FROM public.sms_logs WHERE transaction_ref = v_ref;
    IF v_existing.id IS NOT NULL THEN
      RETURN jsonb_build_object('id', v_existing.id, 'status', 'already_processed',
        'matchStatus', v_existing.match_status, 'orderId', v_existing.matched_order_id);
    END IF;
  END IF;

  INSERT INTO public.sms_logs (agent_id, device_id, sender, body, parsed_provider, parsed_amount, parsed_phone,
                               transaction_ref, sim_slot, received_at)
  VALUES (v_agent, p_device_id, p_sender, p_body, p_parsed_provider, v_amount, p_parsed_phone, v_ref, p_sim_slot, v_received)
  ON CONFLICT DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT * INTO v_existing FROM public.sms_logs
    WHERE (v_ref IS NOT NULL AND transaction_ref = v_ref)
       OR (sender = p_sender AND body = p_body
           AND date_trunc('minute', received_at AT TIME ZONE 'UTC') = date_trunc('minute', v_received AT TIME ZONE 'UTC'))
    LIMIT 1;
    RETURN jsonb_build_object('id', v_existing.id, 'status', 'already_processed',
      'matchStatus', v_existing.match_status, 'orderId', v_existing.matched_order_id);
  END IF;

  IF p_parsed_provider = 'Sahal' THEN
    v_result := private.match_sahal_sms(v_id);
  ELSE
    v_result := private.match_sms_log(v_id);
  END IF;
  RETURN jsonb_build_object('id', v_id, 'status', 'new', 'matchStatus', v_result ->> 'status',
    'orderId', v_result ->> 'orderId', 'reason', v_result ->> 'reason');
END
$$;

-- As before, plus the Sahal SMS that waited for its feed row are decided here.
CREATE OR REPLACE FUNCTION private.resweep_unmatched_sms()
RETURNS integer LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  v_matched int := 0;
BEGIN
  PERFORM private.expire_unpaid_deposits();
  FOR r IN
    SELECT id, parsed_provider FROM public.sms_logs
    WHERE match_status = 'unmatched' AND received_at > now() - interval '24 hours'
    ORDER BY received_at ASC
  LOOP
    BEGIN
      IF (CASE WHEN r.parsed_provider = 'Sahal' THEN private.match_sahal_sms(r.id) ELSE private.match_sms_log(r.id) END) ->> 'status' = 'matched' THEN
        v_matched := v_matched + 1;
      END IF;
    EXCEPTION WHEN others THEN
      RAISE WARNING 'resweep failed for sms_log %: %', r.id, SQLERRM;
    END;
  END LOOP;
  PERFORM private.expire_interrupted_payouts();
  RETURN v_matched;
END
$$;

-- As before, plus: a Sahal SMS that waited for its deposit goes to its own matcher (the carrier matcher
-- would ignore it).
CREATE OR REPLACE FUNCTION private.match_waiting_sms(p_phone text, p_amount numeric)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  r record;
  v jsonb;
BEGIN
  FOR r IN
    SELECT id, parsed_provider FROM public.sms_logs
    WHERE match_status = 'unmatched' AND private.phone_key(parsed_phone) = private.phone_key(p_phone)
      AND abs(parsed_amount - p_amount) < 0.01 AND received_at > now() - interval '24 hours'
    ORDER BY received_at ASC
  LOOP
    v := CASE WHEN r.parsed_provider = 'Sahal' THEN private.match_sahal_sms(r.id) ELSE private.match_sms_log(r.id) END;
    IF v ->> 'status' IN ('matched', 'ambiguous') THEN
      RETURN v;
    END IF;
  END LOOP;
  RETURN NULL;
END
$$;

REVOKE ALL ON FUNCTION private.sahal_feed_up(), private.agent_sim_up(), private.payment_source(), private.match_sahal_sms(uuid),
  private.merchant_match(uuid), private.resweep_unmatched_sms(), private.match_waiting_sms(text, numeric) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.agent_sms_heartbeat(text), public.manage_payment_source(), public.agent_ingest_payment_sms(text, text, text, text, text, text, text, int, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_sms_heartbeat(text), public.manage_payment_source(), public.agent_ingest_payment_sms(text, text, text, text, text, text, text, int, text) TO authenticated, service_role;
