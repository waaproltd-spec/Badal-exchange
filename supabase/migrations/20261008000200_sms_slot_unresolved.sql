-- A payment SMS whose SIM slot the phone could not resolve (no Phone
-- permission, or the OEM gives no slot) now counts when it arrived on the
-- wallet's phone. The carrier's own sender already pins the SIM: a Hormuud
-- "192" SMS can only reach an EVC Plus SIM and an eDahab SMS an eDahab SIM,
-- so on Baari's phone it can only be Baari's wallet of that kind. A slot
-- that IS known and differs is still rejected, as is any other phone.
-- (Before, an unresolved slot was rejected whenever the phone held two
-- wallets, e.g. EVC Plus on SIM 1 and eDahab on SIM 2, so real deposits
-- stayed pending.)
CREATE OR REPLACE FUNCTION private.sms_device_reason(s public.sms_logs, p_method public.order_method)
RETURNS text LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  w record;
  v_any boolean := false;
BEGIN
  FOR w IN SELECT device_id, sim_slot FROM public.payout_wallets WHERE method = p_method AND device_id IS NOT NULL LOOP
    v_any := true;
    IF w.device_id = s.device_id AND (w.sim_slot IS NULL OR s.sim_slot IS NULL OR w.sim_slot = s.sim_slot) THEN
      RETURN NULL;
    END IF;
  END LOOP;
  IF NOT v_any THEN
    RETURN NULL; -- no phone set yet (Dalab's permissive fallback)
  END IF;
  RETURN format('expects the %s wallet''s phone/SIM, SMS arrived on device %s slot %s',
    p_method, COALESCE(s.device_id, '(unknown)'), COALESCE(s.sim_slot::text, '(unresolved)'));
END
$$;

REVOKE ALL ON FUNCTION private.sms_device_reason(public.sms_logs, public.order_method) FROM PUBLIC, anon, authenticated;
