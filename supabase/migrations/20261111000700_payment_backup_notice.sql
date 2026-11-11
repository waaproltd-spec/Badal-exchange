-- TEAM BADAL CONTROL, step 2: the Payment Backup notice.
-- The platform already has an independent way to confirm deposits when Sahal fails (the Agent phone reads the payment SMS and
-- takes over, tested in sahal_sms_fallback; one SMS can never credit twice). What was missing is TELLING the group: which source
-- confirms payments now. private.payment_source() says 'sahal' | 'agent_sim' | 'none'. A change is confirmed only after it has
-- lasted 2 minutes (a flicker sends nothing), is stored as an event, and is announced once. Nothing here credits, pays or changes a
-- balance; it reads the source and writes two small bookkeeping tables.
CREATE TABLE IF NOT EXISTS public.payment_source_state (
  id            BOOLEAN PRIMARY KEY DEFAULT true CHECK (id),
  source        TEXT NOT NULL,
  pending       TEXT,
  pending_since TIMESTAMPTZ,
  since         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS public.payment_source_events (
  id        BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  from_src  TEXT NOT NULL,
  to_src    TEXT NOT NULL,
  at        TIMESTAMPTZ NOT NULL DEFAULT now()
);
ALTER TABLE public.payment_source_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.payment_source_events ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.payment_source_state, public.payment_source_events FROM PUBLIC, anon, authenticated;

-- Worker (service role): notices to send now. Also where a source change is detected and confirmed.
CREATE OR REPLACE FUNCTION public.payment_source_todo()
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_now text := private.payment_source();
  s public.payment_source_state;
BEGIN
  PERFORM private.require_service();
  -- First run: the current source is the starting point, nothing to announce. Two runs at once must not collide on the one row.
  INSERT INTO public.payment_source_state (source) VALUES (v_now) ON CONFLICT (id) DO NOTHING;
  SELECT * INTO s FROM public.payment_source_state FOR UPDATE;
  IF v_now = s.source THEN
    IF s.pending IS NOT NULL THEN
      UPDATE public.payment_source_state SET pending = NULL, pending_since = NULL; -- it came back by itself: a flicker
    END IF;
  ELSIF s.pending IS DISTINCT FROM v_now THEN
    UPDATE public.payment_source_state SET pending = v_now, pending_since = now();
  ELSIF s.pending_since <= now() - interval '2 minutes' THEN
    INSERT INTO public.payment_source_events (from_src, to_src) VALUES (s.source, v_now);
    DELETE FROM public.payment_source_events WHERE at < now() - interval '7 days';
    UPDATE public.payment_source_state SET source = v_now, pending = NULL, pending_since = NULL, since = now();
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(jsonb_build_object('id', e.id, 'from', e.from_src, 'to', e.to_src, 'at', e.at) ORDER BY e.id)
                     FROM public.payment_source_events e
                    WHERE e.at > now() - interval '1 day'
                      AND NOT EXISTS (SELECT 1 FROM public.group_notified n WHERE n.kind = 'source' AND n.key = e.id::text)), '[]'::jsonb);
END $$;
REVOKE ALL ON FUNCTION public.payment_source_todo() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.payment_source_todo() TO service_role;
