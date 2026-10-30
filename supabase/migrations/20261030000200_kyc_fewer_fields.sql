-- KYC: the ID form asks for the name, the document number and the photos only.
--
-- The Customer App no longer asks for the country of issue, the date of birth
-- or the expiry date. The server accepts an application without them: a check
-- is made only for what was given (an older app that still sends them is
-- checked exactly as before), so a missing field never shows as a failed
-- check or sends the application to review for that. Everything else is as
-- before: the name against the account, the document number, the images, and
-- never approved on these checks alone.

CREATE OR REPLACE FUNCTION public.customer_submit_kyc(
  p_document_type text, p_full_name text, p_document_number text, p_country text,
  p_date_of_birth text, p_expiry_date text, p_front text, p_back text, p_selfie text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_type text := lower(btrim(COALESCE(p_document_type, '')));
  v_name text := regexp_replace(btrim(COALESCE(p_full_name, '')), '\s+', ' ', 'g');
  v_number text := upper(regexp_replace(COALESCE(p_document_number, ''), '[\s-]', '', 'g'));
  v_country text := upper(btrim(COALESCE(p_country, '')));
  v_dob date;
  v_expiry date;
  v_provider text := COALESCE(NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'kyc:provider')), ''), 'none');
  v_checks jsonb := '[]'::jsonb;
  v_images jsonb := '{}'::jsonb;
  v_img record;
  v_bytes bytea;
  v_info record;
  v_registered text[];
  v_given text[];
  a public.kyc_applications;
BEGIN
  IF v_type NOT IN ('passport', 'national_id') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose a passport or a national ID');
  END IF;
  IF EXISTS (SELECT 1 FROM public.kyc_applications WHERE customer_id = v_id AND status IN ('pending_auto', 'pending_review', 'approved')) THEN
    PERFORM private.raise_api(409, 'KYC_ALREADY_SUBMITTED', 'Your KYC is already submitted or approved');
  END IF;
  BEGIN
    v_dob := NULLIF(btrim(COALESCE(p_date_of_birth, '')), '')::date;
    v_expiry := NULLIF(btrim(COALESCE(p_expiry_date, '')), '')::date;
  EXCEPTION WHEN others THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Dates must be YYYY-MM-DD');
  END;

  -- The fields.
  v_checks := v_checks || private.kyc_check('full_name', length(v_name) BETWEEN 3 AND 100 AND v_name ~ '^[[:alpha:]'' .-]+$'
                 AND array_length(private.kyc_name_tokens(v_name), 1) >= 2, 'Full name as on the document (two names or more)');
  v_checks := v_checks || private.kyc_check('document_number',
                 CASE v_type WHEN 'passport' THEN v_number ~ '^[A-Z0-9]{6,9}$' ELSE v_number ~ '^[A-Z0-9]{5,20}$' END,
                 CASE v_type WHEN 'passport' THEN '6 to 9 letters or digits' ELSE '5 to 20 letters or digits' END);
  -- Country of issue, date of birth and expiry are no longer asked for; when an
  -- older app still sends them they are checked as before, and when they are
  -- not given there is no check to fail.
  IF v_country <> '' THEN
    v_checks := v_checks || private.kyc_check('country', private.iso_country(v_country), 'A country of issue (ISO code)');
  END IF;
  IF v_dob IS NOT NULL THEN
    v_checks := v_checks || private.kyc_check('date_of_birth', v_dob <= (now()::date - interval '18 years')::date
                   AND v_dob > '1900-01-01', 'Date of birth, 18 or older');
  END IF;
  IF v_expiry IS NOT NULL THEN
    v_checks := v_checks || private.kyc_check('expiry_date', v_expiry > now()::date, 'Not expired');
  END IF;
  -- The name against the account's registered name.
  v_registered := private.kyc_name_tokens((SELECT name FROM public.users WHERE id = v_id));
  v_given := private.kyc_name_tokens(v_name);
  v_checks := v_checks || private.kyc_check('name_matches_account',
                 COALESCE(array_length(v_registered, 1), 0) > 0 AND (v_registered <@ v_given OR v_given <@ v_registered),
                 'The name matches the account''s registered name');

  -- The images: real JPEG / PNG, large enough to be read.
  FOR v_img IN SELECT * FROM (VALUES ('front', p_front, 600, 400), ('back', p_back, 600, 400), ('selfie', p_selfie, 400, 400)) x(kind, b64, min_w, min_h) LOOP
    IF v_img.kind = 'back' AND v_type = 'passport' THEN CONTINUE; END IF;
    v_bytes := NULL;
    IF NULLIF(btrim(COALESCE(v_img.b64, '')), '') IS NOT NULL THEN
      BEGIN
        v_bytes := decode(regexp_replace(v_img.b64, '^data:[^,]*,|\s', '', 'g'), 'base64');
      EXCEPTION WHEN others THEN v_bytes := NULL;
      END;
    END IF;
    IF v_bytes IS NULL THEN
      v_checks := v_checks || private.kyc_check('image_' || v_img.kind, false, 'Missing or not an image');
      CONTINUE;
    END IF;
    IF length(v_bytes) > 8 * 1024 * 1024 THEN
      PERFORM private.raise_api(413, 'VALIDATION_ERROR', 'An image is larger than 8 MB');
    END IF;
    SELECT * INTO v_info FROM private.image_info(v_bytes);
    v_checks := v_checks || private.kyc_check('image_' || v_img.kind,
      v_info.kind IS NOT NULL AND v_info.width >= v_img.min_w AND v_info.height >= v_img.min_h AND length(v_bytes) >= 20000,
      CASE WHEN v_info.kind IS NULL THEN 'Not a JPEG or PNG image'
           ELSE format('%s %sx%s, %s KB (at least %sx%s and 20 KB to be readable)', replace(v_info.kind, 'image/', ''),
                       v_info.width, v_info.height, length(v_bytes) / 1024, v_img.min_w, v_img.min_h) END);
    v_images := v_images || jsonb_build_object(v_img.kind, jsonb_build_object('bytes', encode(v_bytes, 'base64'),
      'mime', COALESCE(v_info.kind, 'application/octet-stream'), 'width', v_info.width, 'height', v_info.height));
  END LOOP;

  INSERT INTO public.kyc_applications (customer_id, document_type, full_name, document_number, country,
                                       date_of_birth, expiry_date, status, checks, provider, auto_checked_at)
  VALUES (v_id, v_type, left(v_name, 100), left(v_number, 30), left(v_country, 2), v_dob, v_expiry,
          'pending_auto', v_checks, v_provider, now())
  RETURNING * INTO a;
  INSERT INTO public.kyc_documents (application_id, kind, mime, width, height, bytes)
  SELECT a.id, e.key, e.value ->> 'mime', (e.value ->> 'width')::int, (e.value ->> 'height')::int, decode(e.value ->> 'bytes', 'base64')
  FROM jsonb_each(v_images) e;

  IF v_provider = 'none' THEN
    -- No identity service: never approved on these checks alone.
    UPDATE public.kyc_applications SET status = 'pending_review', updated_at = now(),
      review_reason = CASE WHEN EXISTS (SELECT 1 FROM jsonb_array_elements(v_checks) c WHERE NOT (c ->> 'ok')::boolean)
                           THEN 'Some checks did not pass' ELSE 'No identity-verification service is configured: an admin checks it' END
    WHERE id = a.id RETURNING * INTO a;
  END IF;
  PERFORM private.audit(v_id, 'customer', 'kyc.submit', 'kyc_application', a.id::text, NULL,
    jsonb_build_object('status', a.status, 'documentType', a.document_type, 'checks', a.checks));
  RETURN private.kyc_status_json(v_id);
END $$;

REVOKE ALL ON FUNCTION public.customer_submit_kyc(text, text, text, text, text, text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_submit_kyc(text, text, text, text, text, text, text, text, text) TO authenticated;
