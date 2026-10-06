-- Database side of the `cashdeskbot` Edge Function (supabase/functions/
-- cashdeskbot), which replaces the Node backend's /admin/cashdeskbot routes.
-- The function holds the CashdeskBot secrets and makes the signed calls; the
-- database checks the caller, keeps idempotency and writes the audit log,
-- exactly as routes/cashdeskbot.ts did.

-- Starts a money-moving CashdeskBot call. Returns the stored response when
-- this idempotency key was already completed (the function then replays it
-- instead of calling CashdeskBot again), otherwise NULL.
CREATE OR REPLACE FUNCTION public.cashdeskbot_begin(p_action text, p_idempotency_key text, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  IF p_action NOT IN ('deposit', 'payout') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown action');
  END IF;
  RETURN private.idempotency_begin(p_idempotency_key, 'cashdeskbot.' || p_action, p_payload);
END
$$;

-- Records the outcome: stores the response against the idempotency key
-- (for deposit/payout) and writes the audit entry.
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
BEGIN
  IF p_action NOT IN ('deposit', 'payout') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Unknown action');
  END IF;
  IF p_idempotency_key IS NOT NULL THEN
    UPDATE public.idempotency_keys SET status_code = 200, response_json = p_response
    WHERE key = p_idempotency_key AND user_id = v_id AND status_code IS NULL;
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'cashdeskbot.' || p_action, 'cashdeskbot_user', p_user_id, NULL, p_audit);
END
$$;

-- A call that failed before CashdeskBot accepted it releases its key, so the
-- manager can retry with it.
CREATE OR REPLACE FUNCTION public.cashdeskbot_abort(p_idempotency_key text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
BEGIN
  DELETE FROM public.idempotency_keys
  WHERE key = p_idempotency_key AND user_id = v_id AND status_code IS NULL;
END
$$;

REVOKE ALL ON FUNCTION public.cashdeskbot_begin(text, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cashdeskbot_finish(text, text, jsonb, text, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cashdeskbot_abort(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cashdeskbot_begin(text, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cashdeskbot_finish(text, text, jsonb, text, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cashdeskbot_abort(text) TO authenticated, service_role;
