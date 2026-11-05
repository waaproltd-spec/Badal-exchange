-- New customers register with a number of a network we pay through:
--   61, 77 -> EVC Plus     90 -> Golis     63 -> ZAAD (telesom)     62 -> eDahab
-- private.customer_network() is the one place that mapping lives; sign-up
-- refuses any other prefix with INVALID_PHONE_PREFIX. Nothing existing is
-- touched: accounts already registered with another prefix keep working
-- (login, wallet, history), and no balance, order, commission or payment
-- rule changes. Existing numbers outside the list are only reported
-- (supabase/diagnostics/payments.sql, section 14), never changed.

CREATE OR REPLACE FUNCTION private.customer_network(p_phone text)
RETURNS text LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT CASE left(right(d, 9), 2)
           WHEN '61' THEN 'evc_plus' WHEN '77' THEN 'evc_plus'
           WHEN '90' THEN 'golis'
           WHEN '63' THEN 'telesom'
           WHEN '62' THEN 'edahab'
         END
  FROM (SELECT regexp_replace(COALESCE(p_phone, ''), '\D', '', 'g') AS d) x
  WHERE length(d) >= 9
$$;

CREATE OR REPLACE FUNCTION public.register_customer(p_phone text, p_name text, p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid;
  v_ip text := private.request_ip();
  v_digits text := regexp_replace(COALESCE(p_phone, ''), '[\s+\-]', '', 'g');
  v_phone text;
BEGIN
  -- 2520XXXXXXXXX, 0XXXXXXXXX and XXXXXXXXX all mean 252XXXXXXXXX.
  v_digits := CASE
    WHEN v_digits ~ '^2520\d{9}$' THEN '252' || right(v_digits, 9)
    WHEN v_digits ~ '^0\d{9}$' OR v_digits ~ '^\d{9}$' THEN '252' || right(v_digits, 9)
    ELSE v_digits
  END;
  IF v_digits !~ '^252\d{9}$' THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter your 9-digit phone number after +252');
  END IF;
  -- Only the networks we pay through: 61 / 77 EVC Plus, 90 Golis, 63 ZAAD, 62 eDahab.
  IF private.customer_network(v_digits) IS NULL THEN
    PERFORM private.raise_api(400, 'INVALID_PHONE_PREFIX',
      'Phone number must start with 61 or 77 (EVC Plus), 90 (Golis), 63 (ZAAD) or 62 (eDahab)');
  END IF;
  v_phone := v_digits;
  PERFORM private.check_len(btrim(COALESCE(p_name, '')), 'name', 1, 100);
  PERFORM private.check_len(p_password, 'password', 8, 72);

  IF v_ip IS NOT NULL AND (
    SELECT count(*) FROM public.audit_logs
    WHERE action = 'user.register' AND ip = v_ip AND created_at > now() - interval '15 minutes'
  ) >= 10 THEN
    PERFORM private.raise_api(429, 'RATE_LIMITED', 'Too many attempts, try again later.');
  END IF;

  IF EXISTS (SELECT 1 FROM public.users WHERE right(regexp_replace(phone, '\D', '', 'g'), 9) = right(v_phone, 9))
     OR EXISTS (SELECT 1 FROM auth.users WHERE email = private.auth_email(v_phone, NULL)) THEN
    PERFORM private.raise_api(409, 'PHONE_TAKEN', 'Phone number already registered');
  END IF;

  INSERT INTO public.users (role, phone, name, password_hash)
  VALUES ('customer', v_phone, btrim(p_name), private.hash_password(p_password))
  RETURNING id INTO v_id;
  INSERT INTO public.wallets (customer_id) VALUES (v_id);
  PERFORM private.audit(v_id, 'customer', 'user.register', 'user', v_id::text);
  RETURN jsonb_build_object('user', jsonb_build_object('id', v_id, 'role', 'customer'));
END
$$;
