-- Support bot "Haraagayga": the linked customer's wallet balance, read only.
-- Only the bot (service role) can call it, and only for a chat that has been
-- linked with the Wallet ID and the customer's own contact. Nothing is stored.
CREATE OR REPLACE FUNCTION public.support_balance(p_chat bigint)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_customer uuid;
  w public.wallets;
BEGIN
  PERFORM private.require_service();
  SELECT customer_id INTO v_customer FROM public.support_chats WHERE chat_id = p_chat;
  IF v_customer IS NULL THEN
    RETURN NULL;
  END IF;
  SELECT * INTO w FROM public.wallets WHERE customer_id = v_customer;
  IF w.id IS NULL THEN
    RETURN jsonb_build_object('available', '0.00', 'pending', '0.00', 'bonus', '0.00');
  END IF;
  RETURN jsonb_build_object(
    'available', private.money(w.available_cents),
    'pending', private.money(w.pending_cents),
    'bonus', private.money_micros(COALESCE((SELECT b.balance_micros FROM public.bonus_wallets b WHERE b.customer_id = v_customer), 0)));
END $$;

REVOKE ALL ON FUNCTION public.support_balance(bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.support_balance(bigint) TO service_role;
