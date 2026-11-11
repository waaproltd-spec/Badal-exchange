-- Agent App Users screen, redesigned: how many customers there are, active
-- and blocked (all time), and how many joined in the chosen period
-- (Mogadishu days p_from..p_to, inclusive; today when null). Read-only;
-- any agent, like agent_customers.
CREATE OR REPLACE FUNCTION public.agent_customer_overview(p_from date DEFAULT NULL, p_to date DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_role('agent');
  v_today date := (now() AT TIME ZONE 'Africa/Mogadishu')::date;
  v_from date := COALESCE(p_from, v_today);
  v_to date := COALESCE(p_to, v_from);
BEGIN
  IF v_to < v_from THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The period ends before it starts');
  END IF;
  RETURN (
    SELECT jsonb_build_object(
      'from', v_from, 'to', v_to,
      'total', count(*),
      'active', count(*) FILTER (WHERE status = 'active'),
      'blocked', count(*) FILTER (WHERE status <> 'active'),
      'new', count(*) FILTER (WHERE created_at >= (v_from::timestamp AT TIME ZONE 'Africa/Mogadishu')
                                 AND created_at < ((v_to + 1)::timestamp AT TIME ZONE 'Africa/Mogadishu')))
    FROM public.users WHERE role = 'customer'
  );
END
$$;

REVOKE ALL ON FUNCTION public.agent_customer_overview(date, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.agent_customer_overview(date, date) TO authenticated, service_role;
