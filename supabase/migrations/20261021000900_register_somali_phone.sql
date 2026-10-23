-- Sign-up takes a Somali number only: +252 and 9 digits. The app shows
-- +252 separately and sends 252XXXXXXXXX; spaces, a leading +, a leading
-- 0 or the 9 digits alone are accepted here too, and the number is stored as
-- 252XXXXXXXXX (the format logins and payments already use). A number
-- already registered in any other form (06..., 6...) is refused too.

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
