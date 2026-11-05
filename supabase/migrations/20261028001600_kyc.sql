-- KYC: identity verification (Customer App -> Profile -> KYC Verification;
-- Agent App -> Account -> KYC Management).
--
-- Statuses: not_submitted (no application), pending_auto, pending_review,
-- approved, rejected, resubmission_required.
--
-- On submission the server checks what it can check reliably itself:
-- required fields, the document number's format, the country (ISO code),
-- date of birth (18+) and expiry, each image a real JPEG / PNG large enough
-- to be read, and the name against the account's registered name. It never
-- approves on these checks alone: whether a document is genuine and the
-- selfie is its holder needs an identity-verification service. With none
-- configured (app_settings kyc:provider = 'none', the default) every
-- application goes to Admin Review with the check results. With one, it
-- waits as pending_auto for the service (kyc_record_provider_result, the
-- server only), and is approved only when the service says verified AND
-- every check passed; anything else goes to Admin Review.
--
-- One open or approved application per customer; only admins decide; every
-- decision has a reason, a time and who made it. The images are kept in a
-- table nobody reads directly; only managers see them, through
-- manage_kyc_application. An approved KYC also approves the account for
-- withdrawals (unless an admin restricted it).

INSERT INTO public.app_settings (key, value) VALUES ('kyc:provider', 'none') ON CONFLICT (key) DO NOTHING;

CREATE TABLE IF NOT EXISTS public.kyc_applications (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id      UUID NOT NULL REFERENCES public.users(id) ON DELETE CASCADE,
  document_type    TEXT NOT NULL CHECK (document_type IN ('passport', 'national_id')),
  full_name        TEXT NOT NULL,
  document_number  TEXT NOT NULL,
  country          TEXT NOT NULL,
  date_of_birth    DATE,
  expiry_date      DATE,
  status           TEXT NOT NULL DEFAULT 'pending_auto'
                     CHECK (status IN ('pending_auto', 'pending_review', 'approved', 'rejected', 'resubmission_required')),
  checks           JSONB NOT NULL DEFAULT '[]'::jsonb,   -- [{key, ok, detail}]
  provider         TEXT,
  provider_result  JSONB,
  review_reason    TEXT,                                 -- why it went to Admin Review
  decided_at       TIMESTAMPTZ,
  decided_by       UUID REFERENCES public.users(id) ON DELETE SET NULL,
  decision_reason  TEXT,
  submitted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  auto_checked_at  TIMESTAMPTZ,
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- One application at a time (and none once approved).
CREATE UNIQUE INDEX IF NOT EXISTS kyc_one_open ON public.kyc_applications (customer_id)
  WHERE status IN ('pending_auto', 'pending_review', 'approved');
CREATE INDEX IF NOT EXISTS kyc_status ON public.kyc_applications (status, submitted_at DESC);
ALTER TABLE public.kyc_applications ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kyc_applications FROM PUBLIC, anon, authenticated;

CREATE TABLE IF NOT EXISTS public.kyc_documents (
  application_id UUID NOT NULL REFERENCES public.kyc_applications(id) ON DELETE CASCADE,
  kind           TEXT NOT NULL CHECK (kind IN ('front', 'back', 'selfie')),
  mime           TEXT NOT NULL,
  width          INT,
  height         INT,
  bytes          BYTEA NOT NULL,
  created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (application_id, kind)
);
ALTER TABLE public.kyc_documents ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.kyc_documents FROM PUBLIC, anon, authenticated;

-- An image's type and size from its own bytes (PNG header, JPEG SOF marker); NULLs when it is neither.
CREATE OR REPLACE FUNCTION private.image_info(p bytea, OUT kind text, OUT width int, OUT height int)
LANGUAGE plpgsql IMMUTABLE SET search_path = '' AS $$
DECLARE
  i int := 2;
  n int := length(p);
  m int;
  seg int;
BEGIN
  IF n > 24 AND substring(p FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea THEN
    kind := 'image/png';
    width := (get_byte(p, 16) << 24) | (get_byte(p, 17) << 16) | (get_byte(p, 18) << 8) | get_byte(p, 19);
    height := (get_byte(p, 20) << 24) | (get_byte(p, 21) << 16) | (get_byte(p, 22) << 8) | get_byte(p, 23);
    RETURN;
  END IF;
  IF n > 4 AND get_byte(p, 0) = 255 AND get_byte(p, 1) = 216 THEN
    WHILE i + 9 < n LOOP
      IF get_byte(p, i) <> 255 THEN RETURN; END IF;
      m := get_byte(p, i + 1);
      IF m IN (192, 193, 194, 195, 197, 198, 199, 201, 202, 203, 205, 206, 207) THEN  -- SOFn
        kind := 'image/jpeg';
        height := (get_byte(p, i + 5) << 8) | get_byte(p, i + 6);
        width := (get_byte(p, i + 7) << 8) | get_byte(p, i + 8);
        RETURN;
      END IF;
      IF m = 255 THEN i := i + 1; CONTINUE; END IF;
      IF m IN (216, 1) OR m BETWEEN 208 AND 215 THEN i := i + 2; CONTINUE; END IF;
      seg := (get_byte(p, i + 2) << 8) | get_byte(p, i + 3);
      IF seg < 2 THEN RETURN; END IF;
      i := i + 2 + seg;
    END LOOP;
  END IF;
END $$;

CREATE OR REPLACE FUNCTION private.kyc_name_tokens(p text)
RETURNS text[] LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT COALESCE(array_agg(t ORDER BY t), '{}') FROM (
    SELECT DISTINCT t FROM regexp_split_to_table(lower(regexp_replace(COALESCE(p, ''), '[^[:alpha:] ]', ' ', 'g')), '\s+') t
    WHERE length(t) > 1) x
$$;

-- ISO 3166-1 alpha-2.
CREATE OR REPLACE FUNCTION private.iso_country(p text)
RETURNS boolean LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT upper(COALESCE(p, '')) = ANY (string_to_array(
    'AD,AE,AF,AG,AI,AL,AM,AO,AQ,AR,AS,AT,AU,AW,AX,AZ,BA,BB,BD,BE,BF,BG,BH,BI,BJ,BL,BM,BN,BO,BQ,BR,BS,BT,BV,BW,BY,BZ,'
    'CA,CC,CD,CF,CG,CH,CI,CK,CL,CM,CN,CO,CR,CU,CV,CW,CX,CY,CZ,DE,DJ,DK,DM,DO,DZ,EC,EE,EG,EH,ER,ES,ET,FI,FJ,FK,FM,FO,FR,'
    'GA,GB,GD,GE,GF,GG,GH,GI,GL,GM,GN,GP,GQ,GR,GS,GT,GU,GW,GY,HK,HM,HN,HR,HT,HU,ID,IE,IL,IM,IN,IO,IQ,IR,IS,IT,JE,JM,JO,'
    'JP,KE,KG,KH,KI,KM,KN,KP,KR,KW,KY,KZ,LA,LB,LC,LI,LK,LR,LS,LT,LU,LV,LY,MA,MC,MD,ME,MF,MG,MH,MK,ML,MM,MN,MO,MP,MQ,MR,'
    'MS,MT,MU,MV,MW,MX,MY,MZ,NA,NC,NE,NF,NG,NI,NL,NO,NP,NR,NU,NZ,OM,PA,PE,PF,PG,PH,PK,PL,PM,PN,PR,PS,PT,PW,PY,QA,RE,RO,'
    'RS,RU,RW,SA,SB,SC,SD,SE,SG,SH,SI,SJ,SK,SL,SM,SN,SO,SR,SS,ST,SV,SX,SY,SZ,TC,TD,TF,TG,TH,TJ,TK,TL,TM,TN,TO,TR,TT,TV,'
    'TW,TZ,UA,UG,UM,US,UY,UZ,VA,VC,VE,VG,VI,VN,VU,WF,WS,YE,YT,ZA,ZM,ZW', ','))
$$;

CREATE OR REPLACE FUNCTION private.kyc_check(p_key text, p_ok boolean, p_detail text)
RETURNS jsonb LANGUAGE sql IMMUTABLE SET search_path = '' AS $$
  SELECT jsonb_build_object('key', p_key, 'ok', COALESCE(p_ok, false), 'detail', p_detail)
$$;

CREATE OR REPLACE FUNCTION private.kyc_status_json(p_customer uuid)
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT COALESCE((
    SELECT jsonb_build_object('id', a.id, 'status', a.status, 'documentType', a.document_type, 'fullName', a.full_name,
             'documentNumber', a.document_number, 'country', a.country,
             'submittedAt', a.submitted_at, 'autoCheckedAt', a.auto_checked_at, 'decidedAt', a.decided_at,
             -- What the customer may see: the admin's reason for a rejection or a resubmission.
             'reason', CASE WHEN a.status IN ('rejected', 'resubmission_required') THEN a.decision_reason END,
             'canSubmit', a.status IN ('rejected', 'resubmission_required'))
    FROM public.kyc_applications a WHERE a.customer_id = p_customer ORDER BY a.submitted_at DESC LIMIT 1),
    jsonb_build_object('status', 'not_submitted', 'canSubmit', true))
$$;

-- Customer: my KYC.
CREATE OR REPLACE FUNCTION public.customer_kyc_status()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE v_id uuid := private.require_role('customer');
BEGIN
  RETURN private.kyc_status_json(v_id);
END $$;

-- Customer: submit (base64 images: the document's front, its back for a
-- national ID, and a selfie). Checked here; then Admin Review or, with an
-- identity service configured, pending_auto for it.
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
  v_checks := v_checks || private.kyc_check('country', private.iso_country(v_country), 'A country of issue (ISO code)');
  v_checks := v_checks || private.kyc_check('date_of_birth', v_dob IS NOT NULL AND v_dob <= (now()::date - interval '18 years')::date
                 AND v_dob > '1900-01-01', 'Date of birth, 18 or older');
  v_checks := v_checks || private.kyc_check('expiry_date', v_expiry IS NOT NULL AND v_expiry > now()::date, 'Not expired');
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

-- The identity service's answer (server only). Approved only when it says
-- verified and every check passed; otherwise Admin Review.
CREATE OR REPLACE FUNCTION public.kyc_record_provider_result(p_application_id uuid, p_verified boolean, p_result jsonb DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  a public.kyc_applications;
  v_all_ok boolean;
BEGIN
  PERFORM private.require_service();
  SELECT * INTO a FROM public.kyc_applications WHERE id = p_application_id FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Application not found');
  END IF;
  IF a.status <> 'pending_auto' THEN
    RETURN jsonb_build_object('status', a.status, 'unchanged', true);
  END IF;
  v_all_ok := NOT EXISTS (SELECT 1 FROM jsonb_array_elements(a.checks) c WHERE NOT (c ->> 'ok')::boolean);
  IF COALESCE(p_verified, false) AND v_all_ok THEN
    UPDATE public.kyc_applications SET status = 'approved', provider_result = p_result, decided_at = now(), decided_by = NULL,
      decision_reason = 'Verified automatically by ' || COALESCE(a.provider, 'the identity service'), updated_at = now()
    WHERE id = a.id RETURNING * INTO a;
    PERFORM private.kyc_approved(a, NULL);
  ELSE
    UPDATE public.kyc_applications SET status = 'pending_review', provider_result = p_result, updated_at = now(),
      review_reason = CASE WHEN NOT COALESCE(p_verified, false) THEN 'The identity service could not verify it'
                           ELSE 'Verified by the identity service, but some checks did not pass' END
    WHERE id = a.id RETURNING * INTO a;
  END IF;
  PERFORM private.audit(NULL, NULL, 'kyc.provider_result', 'kyc_application', a.id::text, NULL,
    jsonb_build_object('status', a.status, 'verified', p_verified));
  RETURN jsonb_build_object('status', a.status);
END $$;

-- Approved KYC: the account is approved for withdrawals too (unless restricted).
CREATE OR REPLACE FUNCTION private.kyc_approved(a public.kyc_applications, p_admin uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  INSERT INTO public.withdrawal_approvals (customer_id, status, decided_at, decided_by, reason)
  VALUES (a.customer_id, 'approved', now(), p_admin, 'KYC approved')
  ON CONFLICT (customer_id) DO UPDATE SET status = 'approved', decided_at = now(), decided_by = p_admin,
    reason = 'KYC approved', updated_at = now()
  WHERE withdrawal_approvals.status IN ('pending', 'rejected');
END $$;

-- Admin: the applications (p_status: one status or 'all'; p_query: name, phone or document number).
CREATE OR REPLACE FUNCTION public.manage_kyc_applications(p_status text DEFAULT 'pending_review', p_query text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status text := COALESCE(NULLIF(btrim(p_status), ''), 'pending_review');
  v_q text := NULLIF(lower(btrim(COALESCE(p_query, ''))), '');
BEGIN
  IF v_status NOT IN ('all', 'pending_auto', 'pending_review', 'approved', 'rejected', 'resubmission_required') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Invalid status');
  END IF;
  RETURN jsonb_build_object(
    'counts', COALESCE((SELECT jsonb_object_agg(s.status, s.n) FROM (SELECT status, count(*) AS n FROM public.kyc_applications GROUP BY status) s), '{}'::jsonb),
    'provider', COALESCE(NULLIF(btrim((SELECT value FROM public.app_settings WHERE key = 'kyc:provider')), ''), 'none'),
    'applications', COALESCE((SELECT jsonb_agg(jsonb_build_object(
        'id', a.id, 'customerId', a.customer_id, 'customerName', u.name, 'phone', u.phone,
        'documentType', a.document_type, 'documentNumber', a.document_number, 'fullName', a.full_name, 'country', a.country,
        'status', a.status, 'submittedAt', a.submitted_at, 'decidedAt', a.decided_at,
        'failedChecks', (SELECT count(*) FROM jsonb_array_elements(a.checks) c WHERE NOT (c ->> 'ok')::boolean))
        ORDER BY a.submitted_at DESC)
      FROM (SELECT * FROM public.kyc_applications x WHERE v_status = 'all' OR x.status = v_status
            ORDER BY x.submitted_at DESC LIMIT 300) a
      JOIN public.users u ON u.id = a.customer_id
      WHERE v_q IS NULL OR lower(COALESCE(u.name, '')) LIKE '%' || v_q || '%' OR u.phone LIKE '%' || v_q || '%'
         OR lower(a.document_number) LIKE '%' || v_q || '%' OR lower(a.full_name) LIKE '%' || v_q || '%'), '[]'::jsonb));
END $$;

-- Admin: one application with its images (base64), checks, results and history.
CREATE OR REPLACE FUNCTION public.manage_kyc_application(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.kyc_applications;
BEGIN
  SELECT * INTO a FROM public.kyc_applications WHERE id = p_id;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Application not found');
  END IF;
  -- Who looked at the documents is kept too.
  PERFORM private.audit(v_id, private.app_role(), 'kyc.view_documents', 'kyc_application', a.id::text, NULL, NULL);
  RETURN jsonb_build_object(
    'id', a.id, 'customerId', a.customer_id, 'status', a.status,
    'customerName', (SELECT name FROM public.users WHERE id = a.customer_id),
    'phone', (SELECT phone FROM public.users WHERE id = a.customer_id),
    'documentType', a.document_type, 'fullName', a.full_name, 'documentNumber', a.document_number, 'country', a.country,
    'dateOfBirth', a.date_of_birth, 'expiryDate', a.expiry_date,
    'checks', a.checks, 'provider', a.provider, 'providerResult', a.provider_result, 'reviewReason', a.review_reason,
    'submittedAt', a.submitted_at, 'autoCheckedAt', a.auto_checked_at, 'decidedAt', a.decided_at,
    'decidedBy', (SELECT name FROM public.users WHERE id = a.decided_by), 'decisionReason', a.decision_reason,
    'documents', COALESCE((SELECT jsonb_object_agg(d.kind, jsonb_build_object('mime', d.mime, 'width', d.width, 'height', d.height,
                     'data', encode(d.bytes, 'base64'))) FROM public.kyc_documents d WHERE d.application_id = a.id), '{}'::jsonb),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', h.id, 'status', h.status, 'submittedAt', h.submitted_at,
                     'decidedAt', h.decided_at, 'reason', h.decision_reason) ORDER BY h.submitted_at DESC)
                   FROM public.kyc_applications h WHERE h.customer_id = a.customer_id AND h.id <> a.id), '[]'::jsonb));
END $$;

-- Admin: approve / reject / resubmit, always with a reason.
CREATE OR REPLACE FUNCTION public.manage_decide_kyc(p_id uuid, p_decision text, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_status text := CASE p_decision WHEN 'approve' THEN 'approved' WHEN 'reject' THEN 'rejected'
                                   WHEN 'resubmit' THEN 'resubmission_required' END;
  a public.kyc_applications;
BEGIN
  IF v_status IS NULL THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'decision must be approve, reject or resubmit');
  END IF;
  PERFORM private.check_len(p_reason, 'reason', 3, 300);
  SELECT * INTO a FROM public.kyc_applications WHERE id = p_id FOR UPDATE;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Application not found');
  END IF;
  IF a.status NOT IN ('pending_auto', 'pending_review') THEN
    PERFORM private.raise_api(409, 'KYC_ALREADY_DECIDED', 'This application has already been decided');
  END IF;
  UPDATE public.kyc_applications SET status = v_status, decided_at = now(), decided_by = v_id,
    decision_reason = btrim(p_reason), updated_at = now()
  WHERE id = a.id RETURNING * INTO a;
  IF v_status = 'approved' THEN
    PERFORM private.kyc_approved(a, v_id);
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'kyc.' || p_decision, 'kyc_application', a.id::text,
    jsonb_build_object('status', 'pending'), jsonb_build_object('status', a.status, 'reason', a.decision_reason));
  RETURN jsonb_build_object('id', a.id, 'status', a.status, 'decidedAt', a.decided_at, 'reason', a.decision_reason);
END $$;

REVOKE ALL ON FUNCTION private.image_info(bytea), private.kyc_name_tokens(text), private.iso_country(text),
  private.kyc_check(text, boolean, text), private.kyc_status_json(uuid), private.kyc_approved(public.kyc_applications, uuid)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.customer_kyc_status(), public.customer_submit_kyc(text, text, text, text, text, text, text, text, text),
  public.manage_kyc_applications(text, text), public.manage_kyc_application(uuid), public.manage_decide_kyc(uuid, text, text),
  public.kyc_record_provider_result(uuid, boolean, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.customer_kyc_status(), public.customer_submit_kyc(text, text, text, text, text, text, text, text, text),
  public.manage_kyc_applications(text, text), public.manage_kyc_application(uuid), public.manage_decide_kyc(uuid, text, text)
  TO authenticated;
REVOKE ALL ON FUNCTION public.kyc_record_provider_result(uuid, boolean, jsonb) FROM authenticated;
GRANT EXECUTE ON FUNCTION public.kyc_record_provider_result(uuid, boolean, jsonb) TO service_role;
