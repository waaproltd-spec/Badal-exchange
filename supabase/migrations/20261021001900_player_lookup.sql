-- Customer App: "Find a Player" on the Confirm Withdrawal screen for
-- 888STARZ and 1XBET. The player-lookup Edge Function asks the brand's
-- CashdeskBot cash register for the player, and shows the customer the
-- player's name before they confirm. This function is its gate: a signed-in
-- customer, a cash-desk method, a plain numeric player ID, and at most 30
-- lookups an hour (so the lookup can't be used to collect player names).
-- Every lookup is kept for audit; only this function touches the table.

CREATE TABLE IF NOT EXISTS public.player_lookups (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id  UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  method       public.order_method NOT NULL,
  account_id   TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_player_lookups_customer ON public.player_lookups (customer_id, created_at DESC);
ALTER TABLE public.player_lookups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.player_lookups FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.customer_begin_player_lookup(p_method text, p_account_id text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_method public.order_method := private.parse_method(p_method);
  v_account text := btrim(COALESCE(p_account_id, ''));
BEGIN
  IF NOT private.is_cashdesk_method(v_method) THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Player search is only for 888STARZ and 1XBET');
  END IF;
  IF v_account !~ '^\d{1,15}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the player ID as digits only');
  END IF;
  IF (SELECT count(*) FROM public.player_lookups
      WHERE customer_id = v_id AND created_at > now() - interval '1 hour') >= 30 THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many player searches. Try again later.');
  END IF;
  INSERT INTO public.player_lookups (customer_id, method, account_id) VALUES (v_id, v_method, v_account);
  RETURN jsonb_build_object('method', v_method, 'accountId', v_account);
END $$;

REVOKE ALL ON FUNCTION public.customer_begin_player_lookup(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_begin_player_lookup(text, text) TO authenticated, service_role;
