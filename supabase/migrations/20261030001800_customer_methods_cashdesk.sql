-- The Customer App builds the deposit screen of a platform from the list of
-- payment methods (customer_payment_methods), which did not say whether the
-- platform is a cash desk. The app then used its built-in list of eight
-- platforms, so a platform added later -- even a fully connected one -- got
-- the account ID + amount screen instead of account ID + code. The list now
-- says it, from the same rule the server uses for orders. Nothing else changes.
CREATE OR REPLACE FUNCTION public.customer_payment_methods()
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
    SELECT jsonb_agg(jsonb_build_object(
      'method', m.method, 'label', m.label, 'kind', m.kind, 'color', m.color, 'initials', m.initials,
      'cashdesk', private.is_cashdesk_method(m.method),
      'depositNumbers', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('number', n.number, 'label', n.label) ORDER BY n.created_at)
        FROM public.deposit_numbers n WHERE n.method = m.method AND n.enabled
      ), '[]'::jsonb),
      'minWithdraw', (SELECT private.money(l.min_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'maxWithdraw', (SELECT private.money(l.max_cents) FROM public.withdrawal_limits l WHERE l.method = m.method),
      'paymentLocation', private.payment_location_json(m),
      'merchantUssd', CASE WHEN m.merchant_ussd_enabled THEN m.merchant_ussd END
    ) ORDER BY m.sort_order)
    FROM public.payment_methods m WHERE m.enabled
  ), '[]'::jsonb);
END
$$;
