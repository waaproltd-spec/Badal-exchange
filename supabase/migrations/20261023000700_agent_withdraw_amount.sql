-- *736 takes cents differently from *712: under $1 the amount is a 0 then
-- the cents without trailing zeros ($0.10 -> "01", dialed by hand and
-- confirmed by EVC: "$0.1 ayaad uwareejisay"). Whole dollars stay as is.
-- A dollar amount with cents keeps the *712 form (1.50 -> "1*50") until
-- *736's form for it is confirmed.
CREATE OR REPLACE FUNCTION private.agent_withdraw_amount(p_amount numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE WHEN p_amount > 0 AND p_amount < 1
              THEN '0' || rtrim(lpad(round(p_amount * 100)::int::text, 2, '0'), '0')
              ELSE private.ussd_amount(p_amount) END
$$;

CREATE OR REPLACE FUNCTION private.payout_ussd(p_method public.order_method, p_phone text, p_amount numeric)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE p_method
    WHEN 'evc_plus' THEN '*736*' || private.agent_withdraw_phone(p_phone) || '*' || private.agent_withdraw_amount(p_amount) || '*{PIN}#'
    ELSE '*' || private.payout_dial_prefix(p_method) || '*' || private.phone_key(p_phone) || '*' || private.ussd_amount(p_amount) || '#'
  END
$$;
