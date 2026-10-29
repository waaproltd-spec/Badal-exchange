-- A Home Ad picture chosen from the phone's gallery.
--
-- The project has no file-storage service (Supabase Storage is off), so the
-- picture is kept with the ad, like platform logos, and sent to the Customer
-- App with the ad as base64: every customer's phone can load it, it survives
-- restarts, and it needs no new service. The Agent App shrinks it first
-- (at most 900 px, JPEG); the server accepts a JPEG, PNG or WebP of up to
-- 600 KB and checks the file itself, not just its name.
--
-- Saving is one step: the ad and its new picture are written together, so a
-- failed upload leaves the ad and its previous picture exactly as they were.
-- Without a new picture the existing one (or an old image link) is kept; the
-- image is optional and can be removed. A picture takes precedence over an
-- old image link.
ALTER TABLE public.home_ads ADD COLUMN IF NOT EXISTS image BYTEA;
ALTER TABLE public.home_ads ADD COLUMN IF NOT EXISTS image_type TEXT;

CREATE OR REPLACE FUNCTION private.home_ad_json(a public.home_ads)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = ''
AS $$
  SELECT jsonb_build_object(
    'id', a.id, 'title', a.title, 'body', a.body, 'imageUrl', a.image_url, 'linkUrl', a.link_url,
    'enabled', a.enabled, 'sortOrder', a.sort_order, 'updatedAt', a.updated_at,
    'image', CASE WHEN a.image IS NULL THEN NULL ELSE replace(encode(a.image, 'base64'), E'\n', '') END,
    'imageType', a.image_type
  )
$$;

DROP FUNCTION IF EXISTS public.manage_save_home_ad(text, text, text, text, boolean, int, uuid);

-- POST /agent/manage/home-ads (p_id NULL) and PUT /agent/manage/home-ads/:id
-- p_image: base64 JPEG/PNG/WebP, replaces the picture; p_remove_image drops it.
CREATE OR REPLACE FUNCTION public.manage_save_home_ad(
  p_title text, p_body text DEFAULT NULL, p_image_url text DEFAULT NULL, p_link_url text DEFAULT NULL,
  p_enabled boolean DEFAULT true, p_sort_order int DEFAULT 0, p_id uuid DEFAULT NULL,
  p_image text DEFAULT NULL, p_remove_image boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.home_ads;
  v_b64 text := regexp_replace(COALESCE(p_image, ''), '\s', '', 'g');
  v_bytes bytea;
  v_type text;
BEGIN
  PERFORM private.check_len(p_title, 'title', 1, 120);
  PERFORM private.check_len(p_body, 'body', 0, 500, false);
  PERFORM private.check_url(p_image_url, 'imageUrl');
  PERFORM private.check_url(p_link_url, 'linkUrl');
  IF COALESCE(p_sort_order, 0) NOT BETWEEN 0 AND 1000 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'sortOrder must be between 0 and 1000');
  END IF;

  IF v_b64 <> '' THEN
    IF length(v_b64) > 820000 OR v_b64 !~ '^[A-Za-z0-9+/]+={0,2}$' THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The image must be a JPEG, PNG or WebP picture of up to 600 KB');
    END IF;
    BEGIN
      v_bytes := decode(v_b64, 'base64');
    EXCEPTION WHEN others THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The image must be a JPEG, PNG or WebP picture of up to 600 KB');
    END;
    v_type := CASE
      WHEN substring(v_bytes FROM 1 FOR 3) = '\xffd8ff'::bytea THEN 'image/jpeg'
      WHEN substring(v_bytes FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea THEN 'image/png'
      WHEN substring(v_bytes FROM 1 FOR 4) = '\x52494646'::bytea AND substring(v_bytes FROM 9 FOR 4) = '\x57454250'::bytea THEN 'image/webp'
    END;
    IF v_type IS NULL OR length(v_bytes) > 600000 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The image must be a JPEG, PNG or WebP picture of up to 600 KB');
    END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.home_ads (title, body, image_url, link_url, enabled, sort_order, created_by, updated_by, image, image_type)
    VALUES (p_title, p_body, CASE WHEN v_bytes IS NULL THEN p_image_url END, p_link_url,
            COALESCE(p_enabled, true), COALESCE(p_sort_order, 0), v_id, v_id, v_bytes, v_type)
    RETURNING * INTO a;
    PERFORM private.audit(v_id, private.app_role(), 'home_ad.create', 'home_ad', a.id::text, NULL,
                          to_jsonb(a) - 'image');
  ELSE
    UPDATE public.home_ads h
    SET title = p_title, body = p_body, link_url = p_link_url,
        enabled = COALESCE(p_enabled, true), sort_order = COALESCE(p_sort_order, 0), updated_by = v_id, updated_at = now(),
        image = CASE WHEN v_bytes IS NOT NULL THEN v_bytes WHEN COALESCE(p_remove_image, false) THEN NULL ELSE h.image END,
        image_type = CASE WHEN v_bytes IS NOT NULL THEN v_type WHEN COALESCE(p_remove_image, false) THEN NULL ELSE h.image_type END,
        image_url = CASE WHEN v_bytes IS NOT NULL OR COALESCE(p_remove_image, false) THEN NULL ELSE p_image_url END
    WHERE h.id = p_id RETURNING * INTO a;
    IF a.id IS NULL THEN
      PERFORM private.raise_api(404, 'NOT_FOUND', 'Ad not found');
    END IF;
    PERFORM private.audit(v_id, private.app_role(), 'home_ad.update', 'home_ad', a.id::text, NULL,
                          to_jsonb(a) - 'image');
  END IF;
  RETURN private.home_ad_json(a);
END
$$;

REVOKE ALL ON FUNCTION public.manage_save_home_ad(text, text, text, text, boolean, int, uuid, text, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.manage_save_home_ad(text, text, text, text, boolean, int, uuid, text, boolean) TO authenticated, service_role;

-- Deleting an ad also audits it; keep the picture's bytes out of the audit row.
CREATE OR REPLACE FUNCTION public.manage_delete_home_ad(p_id uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  a public.home_ads;
BEGIN
  DELETE FROM public.home_ads WHERE id = p_id RETURNING * INTO a;
  IF a.id IS NULL THEN
    PERFORM private.raise_api(404, 'NOT_FOUND', 'Ad not found');
  END IF;
  PERFORM private.audit(v_id, private.app_role(), 'home_ad.delete', 'home_ad', p_id::text, to_jsonb(a) - 'image', NULL);
END $$;
