-- Sahal merchant account, managed from the Admin Dashboard (Agent App,
-- managers only).
--
-- Until now the merchant login lived in the Edge Functions' secrets
-- (GOLIS_MERCHANT_USERNAME / _PASSWORD / _PIN). Those keep working: they are
-- used whenever no account was activated from here. An account set here is
-- stored in Supabase Vault (encrypted; the password and PIN are never read
-- back by any manager call) and is used instead once activated.
--
-- A change is never made in place:
--   1. Save: the new login is kept as "pending"; the working account and its
--      session are untouched.
--   2. Test (functions/sahal-account-verify): signs in to the NEW account in
--      its own session (Sahal texts that account's code if it wants one;
--      the manager types it here), reads its transaction list, and keeps
--      that session. The working feed is not involved.
--   3. Activate: only after a successful test, in one step with the payout
--      claims locked and no transfer in flight: the verified session becomes
--      the feed's session (no second SMS), the old account is kept as
--      "previous". Anything else leaves the working account running.
--
-- Nothing here logs or returns a password, PIN, session id or code.

CREATE TABLE IF NOT EXISTS private.sahal_accounts (
  id                 UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  role               TEXT NOT NULL CHECK (role IN ('active', 'pending', 'previous')),
  username           TEXT NOT NULL,
  password_secret_id UUID NOT NULL,
  pin_secret_id      UUID,
  currency           TEXT,
  status             TEXT NOT NULL DEFAULT 'draft'
                       CHECK (status IN ('draft', 'testing', 'logging_in', 'needs_code', 'code_entered', 'verified', 'failed', 'active')),
  message            TEXT,
  created_by         UUID,
  created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  test_requested_at  TIMESTAMPTZ,
  verified_at        TIMESTAMPTZ,
  activated_at       TIMESTAMPTZ,
  -- The new account's own session while it is being verified (never the working feed's).
  session_id         TEXT,
  cookies            TEXT,
  second_session_id  TEXT,
  second_at          TIMESTAMPTZ,
  code               TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS sahal_accounts_one_per_role ON private.sahal_accounts (role);
REVOKE ALL ON private.sahal_accounts FROM PUBLIC, anon, authenticated;

-- Wakes the verification worker, like merchant_feed_kick does for the feed.
CREATE OR REPLACE FUNCTION private.sahal_account_kick()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_url text := NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'edge_functions_url')), '');
  v_secret text := (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'platform_worker_secret');
BEGIN
  IF v_url IS NULL OR v_secret IS NULL OR NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
    RETURN;
  END IF;
  EXECUTE 'SELECT net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 30000)'
  USING rtrim(v_url, '/') || '/sahal-account-verify', jsonb_build_object('Content-Type', 'application/json', 'x-worker-secret', v_secret);
EXCEPTION WHEN others THEN
  RAISE WARNING 'sahal_account_kick: %', SQLERRM;
END $$;
REVOKE ALL ON FUNCTION private.sahal_account_kick() FROM PUBLIC, anon, authenticated;

-- ---- What a manager sees (no secret of any kind) ----

CREATE OR REPLACE FUNCTION private.sahal_account_json()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a private.sahal_accounts;
  p private.sahal_accounts;
  f public.merchant_feed_status;
  s private.merchant_feed_sessions;
  v_started timestamptz;
  v_stuck boolean;
BEGIN
  SELECT * INTO a FROM private.sahal_accounts WHERE role = 'active';
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending';
  SELECT * INTO f FROM public.merchant_feed_status WHERE provider = 'golis';
  SELECT * INTO s FROM private.merchant_feed_sessions WHERE provider = 'golis';
  v_started := s.session_started_at;
  -- A test that never answered is shown as failed, so it can be run again.
  v_stuck := p.status IN ('testing', 'logging_in') AND p.updated_at < now() - interval '3 minutes';
  RETURN jsonb_build_object(
    'source', CASE WHEN a.id IS NULL THEN 'environment' ELSE 'database' END,
    'connection', CASE
      WHEN f.state = 'ok' AND f.last_ok_at > now() - interval '2 minutes' THEN 'connected'
      WHEN f.state IN ('needs_code', 'code_entered', 'signing_in', 'stopped') THEN 'authentication_required'
      ELSE 'disconnected' END,
    'feedState', f.state, 'feedMessage', f.message, 'lastReadAt', f.last_ok_at,
    'active', CASE WHEN a.id IS NOT NULL THEN jsonb_build_object(
      'username', a.username, 'hasPin', a.pin_secret_id IS NOT NULL, 'activatedAt', a.activated_at) END,
    'pending', CASE WHEN p.id IS NOT NULL THEN jsonb_build_object(
      'username', p.username, 'hasPin', p.pin_secret_id IS NOT NULL,
      'status', CASE WHEN v_stuck THEN 'failed' ELSE p.status END,
      'message', CASE WHEN v_stuck THEN 'The test did not finish. Test again.' ELSE p.message END,
      'verifiedAt', p.verified_at, 'testRequestedAt', p.test_requested_at,
      'codeAskedAt', CASE WHEN p.status = 'needs_code' THEN p.second_at END) END,
    'session', jsonb_build_object(
      'active', s.session_id IS NOT NULL,
      'startedAt', v_started,
      'ageSeconds', CASE WHEN v_started IS NOT NULL THEN extract(epoch FROM now() - v_started)::int END,
      'lastRenewalAt', (SELECT e.at FROM private.merchant_feed_events e
                        WHERE e.provider = 'golis' AND e.event = 'session_started'
                          AND EXISTS (SELECT 1 FROM private.merchant_feed_events x
                                      WHERE x.provider = 'golis' AND x.id < e.id AND x.event IN ('session_cleared', 'session_lost'))
                        ORDER BY e.id DESC LIMIT 1),
      'lastLoginAt', (SELECT e.at FROM private.merchant_feed_events e
                      WHERE e.provider = 'golis' AND e.event = 'session_started' ORDER BY e.id DESC LIMIT 1)),
    'open', jsonb_build_object(
      'deposits', (SELECT count(*) FROM public.orders o WHERE o.direction = 'deposit' AND o.status = 'pending'
                   AND o.created_at > now() - interval '1 day' AND private.is_mobile_money(o.method)),
      'withdrawals', (SELECT count(*) FROM public.orders o WHERE o.direction = 'withdraw' AND o.status IN ('pending', 'processing')
                      AND private.is_mobile_money(o.method)),
      'transfersInFlight', (SELECT count(*) FROM public.sahal_payout_attempts y WHERE y.status = 'pending'),
      'transfersHeld', (SELECT count(*) FROM public.sahal_payout_attempts y WHERE y.status = 'ambiguous')),
    'renewIdle', COALESCE((SELECT value FROM public.app_settings WHERE key = 'sahal_renew_idle'), 'on') <> 'off');
END $$;
REVOKE ALL ON FUNCTION private.sahal_account_json() FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.manage_sahal_account_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  RETURN private.sahal_account_json();
END $$;

-- ---- Save a login as "pending" (never replaces the working one) ----

CREATE OR REPLACE FUNCTION public.manage_sahal_account_save(
  p_username text, p_password text, p_pin text DEFAULT NULL, p_currency text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_user text := btrim(COALESCE(p_username, ''));
  v_pin text := NULLIF(btrim(COALESCE(p_pin, '')), '');
  v_cur text := NULLIF(btrim(COALESCE(p_currency, '')), '');
  v_new uuid := gen_random_uuid();
  old private.sahal_accounts;
BEGIN
  IF v_user !~ '^[A-Za-z0-9._@+-]{3,60}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the Sahal merchant login (3 to 60 letters, numbers or . _ @ + -)');
  END IF;
  IF p_password IS NULL OR length(p_password) < 4 OR length(p_password) > 100 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the Sahal merchant password');
  END IF;
  IF v_pin IS NOT NULL AND v_pin !~ '^[0-9]{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The merchant PIN is 4 to 8 digits');
  END IF;
  IF v_cur IS NOT NULL AND v_cur !~ '^[0-9]{3}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The currency code is 3 digits (840 = USD)');
  END IF;
  -- A new save replaces an earlier pending one (its secrets go with it).
  SELECT * INTO old FROM private.sahal_accounts WHERE role = 'pending';
  IF old.id IS NOT NULL THEN
    DELETE FROM vault.secrets WHERE id IN (old.password_secret_id, old.pin_secret_id);
    DELETE FROM private.sahal_accounts WHERE id = old.id;
  END IF;
  INSERT INTO private.sahal_accounts (id, role, username, password_secret_id, pin_secret_id, currency, status, message, created_by)
  VALUES (v_new, 'pending', v_user,
          private.store_secret(NULL, p_password, 'sahal_account_password_' || v_new::text),
          CASE WHEN v_pin IS NOT NULL THEN private.store_secret(NULL, v_pin, 'sahal_account_pin_' || v_new::text) END,
          v_cur, 'draft', 'Saved. Test it before it can be activated.', v_id);
  PERFORM private.audit(v_id, private.app_role(), 'sahal_account.save', 'sahal_account', 'pending', NULL,
                        jsonb_build_object('username', v_user, 'hasPin', v_pin IS NOT NULL));
  RETURN private.sahal_account_json();
END $$;

-- ---- Test the pending login: a real sign-in to the NEW account only ----

CREATE OR REPLACE FUNCTION public.manage_sahal_account_test()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  p private.sahal_accounts;
BEGIN
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending' FOR UPDATE;
  IF p.id IS NULL THEN
    PERFORM private.raise_api(409, 'NO_PENDING', 'Save a Sahal login first');
  END IF;
  -- Each test makes Sahal text a code to that account's phone: not more than one a minute.
  IF p.test_requested_at > now() - interval '60 seconds' THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Wait a minute before testing again (each test sends an SMS code)');
  END IF;
  UPDATE private.sahal_accounts SET status = 'testing', message = 'Signing in to the new account…', test_requested_at = now(),
         updated_at = now(), verified_at = NULL, session_id = NULL, cookies = NULL, second_session_id = NULL, second_at = NULL, code = NULL
  WHERE id = p.id;
  PERFORM private.audit(v_id, private.app_role(), 'sahal_account.test', 'sahal_account', 'pending', NULL,
                        jsonb_build_object('username', p.username));
  PERFORM private.sahal_account_kick();
  RETURN private.sahal_account_json();
END $$;

-- The SMS code Sahal sent to the NEW account's phone (within 10 minutes).
CREATE OR REPLACE FUNCTION public.manage_sahal_account_code(p_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_code text := regexp_replace(COALESCE(p_code, ''), '\s', '', 'g');
  p private.sahal_accounts;
BEGIN
  IF v_code !~ '^[0-9]{4,8}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the code from the SMS (numbers only)');
  END IF;
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending' FOR UPDATE;
  IF p.id IS NULL OR p.status <> 'needs_code' OR p.second_session_id IS NULL THEN
    PERFORM private.raise_api(409, 'NO_CODE_ASKED', 'Sahal is not waiting for a code from the new account. Tap Test first.');
  END IF;
  IF p.second_at < now() - interval '10 minutes' THEN
    PERFORM private.raise_api(409, 'CODE_EXPIRED', 'That code has expired. Tap Test for a new one.');
  END IF;
  UPDATE private.sahal_accounts SET code = v_code, status = 'code_entered', message = 'Checking the code…', updated_at = now() WHERE id = p.id;
  PERFORM private.audit(v_id, private.app_role(), 'sahal_account.code', 'sahal_account', 'pending', NULL, NULL);
  PERFORM private.sahal_account_kick();
  RETURN private.sahal_account_json();
END $$;

-- Drop the pending login and its secrets. The working account is not touched.
CREATE OR REPLACE FUNCTION public.manage_sahal_account_discard()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  p private.sahal_accounts;
BEGIN
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending';
  IF p.id IS NOT NULL THEN
    DELETE FROM vault.secrets WHERE id IN (p.password_secret_id, p.pin_secret_id);
    DELETE FROM private.sahal_accounts WHERE id = p.id;
    PERFORM private.audit(v_id, private.app_role(), 'sahal_account.discard', 'sahal_account', 'pending', NULL,
                          jsonb_build_object('username', p.username));
  END IF;
  RETURN private.sahal_account_json();
END $$;

-- ---- Activate: only a verified account, with no transfer in flight ----

CREATE OR REPLACE FUNCTION public.manage_sahal_account_activate(p_deposit_codes_updated boolean DEFAULT false)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  p private.sahal_accounts;
  a private.sahal_accounts;
  v_from text;
BEGIN
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending' FOR UPDATE;
  IF p.id IS NULL THEN
    PERFORM private.raise_api(409, 'NO_PENDING', 'There is no new account to activate');
  END IF;
  IF p.status <> 'verified' OR p.session_id IS NULL OR p.verified_at < now() - interval '30 minutes' THEN
    PERFORM private.raise_api(409, 'NOT_VERIFIED', 'Test the new account first (a test is good for 30 minutes)');
  END IF;
  SELECT * INTO a FROM private.sahal_accounts WHERE role = 'active' FOR UPDATE;
  v_from := COALESCE(a.username, 'environment');
  -- A different merchant account is a different pay-to code for customers.
  IF p.username IS DISTINCT FROM a.username AND NOT COALESCE(p_deposit_codes_updated, false) THEN
    PERFORM private.raise_api(409, 'CONFIRM_DEPOSIT_CODES',
      'A different Sahal account receives deposits on its own merchant code. Confirm that the deposit codes were updated.');
  END IF;
  -- No payout is claimed while this runs (sahal_payout_next takes the same lock).
  PERFORM 1 FROM public.sahal_payout_settings WHERE id FOR UPDATE;
  IF EXISTS (SELECT 1 FROM public.sahal_payout_attempts WHERE status = 'pending') THEN
    PERFORM private.raise_api(409, 'TRANSFER_IN_FLIGHT', 'A Sahal transfer is being sent. Try again in a minute.');
  END IF;
  -- The old account is kept as "previous" (one only).
  DELETE FROM vault.secrets WHERE id IN (SELECT password_secret_id FROM private.sahal_accounts WHERE role = 'previous'
                                         UNION SELECT pin_secret_id FROM private.sahal_accounts WHERE role = 'previous' AND pin_secret_id IS NOT NULL);
  DELETE FROM private.sahal_accounts WHERE role = 'previous';
  UPDATE private.sahal_accounts SET role = 'previous', status = 'draft', updated_at = now() WHERE role = 'active';
  UPDATE private.sahal_accounts SET role = 'active', status = 'active', message = NULL, activated_at = now(), updated_at = now(),
         session_id = NULL, cookies = NULL, second_session_id = NULL, second_at = NULL, code = NULL
  WHERE id = p.id;
  -- The verified session becomes the feed's: no second SMS, no gap.
  INSERT INTO private.merchant_feed_sessions (provider, session_id, cookies, read_session_id, read_cookies, second_session_id, second_at, code, updated_at)
  VALUES ('golis', p.session_id, p.cookies, NULL, NULL, NULL, NULL, NULL, now())
  ON CONFLICT (provider) DO UPDATE SET session_id = EXCLUDED.session_id, cookies = EXCLUDED.cookies, read_session_id = NULL,
    read_cookies = NULL, second_session_id = NULL, second_at = NULL, code = NULL, updated_at = now();
  UPDATE public.merchant_feed_status SET state = 'ready', result_code = NULL, message = 'Switched to the new Sahal account', updated_at = now()
  WHERE provider = 'golis';
  PERFORM private.audit(v_id, private.app_role(), 'sahal_account.activate', 'sahal_account', 'active',
                        jsonb_build_object('from', v_from), jsonb_build_object('to', p.username));
  INSERT INTO private.merchant_feed_events (provider, event, detail) VALUES ('golis', 'account_switched', jsonb_build_object('to', p.username));
  PERFORM private.merchant_feed_kick();
  RETURN private.sahal_account_json();
END $$;

-- Reconnect now (the existing sign-in; Sahal texts its code and the SMS
-- forwarder enters it) and a connection check that does not sign in again.
CREATE OR REPLACE FUNCTION public.manage_sahal_connection_check()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  -- Reads Sahal's list with the working session; no new sign-in, no SMS.
  PERFORM private.merchant_feed_kick();
  RETURN private.sahal_account_json();
END $$;

-- ---- The worker's side (service role only) ----

-- The active account's login, from Vault; NULL while none was activated here
-- (the function secrets are used then).
CREATE OR REPLACE FUNCTION public.sahal_credentials()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a private.sahal_accounts;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO a FROM private.sahal_accounts WHERE role = 'active';
  IF a.id IS NULL THEN
    RETURN NULL;
  END IF;
  RETURN jsonb_build_object('username', a.username,
    'password', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.password_secret_id),
    'pin', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = a.pin_secret_id),
    'currency', a.currency);
END $$;

-- The next piece of verification work (claimed once): a sign-in to the new
-- account, or the code a manager typed for it.
CREATE OR REPLACE FUNCTION public.sahal_pending_work()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p private.sahal_accounts;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending' FOR UPDATE SKIP LOCKED;
  IF p.id IS NULL OR p.updated_at < now() - interval '10 minutes' THEN
    RETURN NULL;
  END IF;
  IF p.status = 'testing' THEN
    UPDATE private.sahal_accounts SET status = 'logging_in', updated_at = now() WHERE id = p.id;
    RETURN jsonb_build_object('action', 'login', 'username', p.username, 'currency', p.currency,
      'password', (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE id = p.password_secret_id));
  ELSIF p.status = 'code_entered' AND p.code IS NOT NULL AND p.second_session_id IS NOT NULL THEN
    UPDATE private.sahal_accounts SET status = 'logging_in', code = NULL, updated_at = now() WHERE id = p.id;
    RETURN jsonb_build_object('action', 'code', 'code', p.code, 'secondSessionId', p.second_session_id, 'cookies', p.cookies);
  END IF;
  RETURN NULL;
END $$;

CREATE OR REPLACE FUNCTION public.sahal_pending_report(
  p_status text, p_message text DEFAULT NULL, p_session text DEFAULT NULL, p_cookies text DEFAULT NULL,
  p_second_session text DEFAULT NULL)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  p private.sahal_accounts;
BEGIN
  PERFORM private.require_service();
  IF p_status NOT IN ('verified', 'needs_code', 'failed') THEN
    RAISE EXCEPTION 'bad status';
  END IF;
  SELECT * INTO p FROM private.sahal_accounts WHERE role = 'pending' FOR UPDATE;
  IF p.id IS NULL OR p.status <> 'logging_in' THEN
    RETURN; -- discarded or replaced meanwhile: nothing to report to
  END IF;
  UPDATE private.sahal_accounts SET status = p_status, message = left(p_message, 300), updated_at = now(),
    verified_at = CASE WHEN p_status = 'verified' THEN now() END,
    session_id = CASE WHEN p_status = 'verified' THEN p_session END,
    cookies = left(p_cookies, 4000),
    second_session_id = CASE WHEN p_status = 'needs_code' THEN p_second_session END,
    second_at = CASE WHEN p_status = 'needs_code' THEN now() END
  WHERE id = p.id;
  PERFORM private.audit(NULL, NULL, 'sahal_account.' || p_status, 'sahal_account', 'pending', NULL,
                        jsonb_build_object('username', p.username));
END $$;

REVOKE ALL ON FUNCTION public.manage_sahal_account_status(), public.manage_sahal_account_save(text, text, text, text),
  public.manage_sahal_account_test(), public.manage_sahal_account_code(text), public.manage_sahal_account_discard(),
  public.manage_sahal_account_activate(boolean), public.manage_sahal_connection_check() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_sahal_account_status(), public.manage_sahal_account_save(text, text, text, text),
  public.manage_sahal_account_test(), public.manage_sahal_account_code(text), public.manage_sahal_account_discard(),
  public.manage_sahal_account_activate(boolean), public.manage_sahal_connection_check() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.sahal_credentials(), public.sahal_pending_work(),
  public.sahal_pending_report(text, text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.sahal_credentials(), public.sahal_pending_work(),
  public.sahal_pending_report(text, text, text, text, text) TO service_role;
