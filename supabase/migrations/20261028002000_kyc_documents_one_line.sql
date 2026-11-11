-- KYC documents shown to the admin: base64 without line breaks.
--
-- Postgres' encode(bytea, 'base64') breaks the text into lines of 76
-- characters. The Agent App's decoder (Dart base64Decode) refuses line
-- breaks, so "Review KYC Application" showed "Could not load the application"
-- for every application with photos. The text is now one line (and the app
-- also ignores whitespace). Nothing else about the function changes.

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
                     'data', replace(encode(d.bytes, 'base64'), E'\n', ''))) FROM public.kyc_documents d WHERE d.application_id = a.id), '{}'::jsonb),
    'history', COALESCE((SELECT jsonb_agg(jsonb_build_object('id', h.id, 'status', h.status, 'submittedAt', h.submitted_at,
                     'decidedAt', h.decided_at, 'reason', h.decision_reason) ORDER BY h.submitted_at DESC)
                   FROM public.kyc_applications h WHERE h.customer_id = a.customer_id AND h.id <> a.id), '[]'::jsonb));
END $$;
