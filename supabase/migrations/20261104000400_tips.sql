-- TIPS (Shaxaha): betting tips sold in the Customer App.
--
--   * Free tips: every signed-in customer sees and copies the Odds Code.
--   * Paid tips: the list and the detail show the tip WITHOUT its Odds Code
--     (and without the match picks) until the customer has bought it. The
--     code is only ever returned by these functions, after the check; the
--     tables themselves have no grants for the app roles at all.
--   * Buying is ONE database transaction under the wallet's row lock:
--       check -> debit the wallet (never below zero) -> ledger entry ->
--       purchase row.
--     If any step fails the whole transaction is rolled back, so there is no
--     "paid but not unlocked" state to repair. A second tap (or a request
--     that arrives twice at once) finds the purchase and answers
--     "already yours" without charging again; a unique index backs that up.
--   * A manager can refund a purchase: the price goes back to the wallet
--     (ledger credit) and the access is withdrawn.
--   * Prices are kept in cents, like the rest of the wallet.

CREATE TABLE IF NOT EXISTS public.tips (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title        TEXT NOT NULL CHECK (char_length(title) BETWEEN 1 AND 120),
  sport        TEXT NOT NULL CHECK (sport IN ('football', 'basketball', 'tennis', 'volleyball', 'baseball',
                                              'hockey', 'cricket', 'rugby', 'boxing', 'other')),
  team_count   INT  NOT NULL CHECK (team_count BETWEEN 1 AND 40),
  is_paid      BOOLEAN NOT NULL DEFAULT false,
  price_cents  BIGINT NOT NULL DEFAULT 0 CHECK (price_cents >= 0),
  odds_code    TEXT NOT NULL CHECK (char_length(odds_code) BETWEEN 1 AND 200),
  total_odds   NUMERIC(10, 2) CHECK (total_odds IS NULL OR total_odds > 0),
  matches      JSONB NOT NULL DEFAULT '[]'::jsonb CHECK (jsonb_typeof(matches) = 'array'),
  note         TEXT CHECK (note IS NULL OR char_length(note) <= 500),
  image        BYTEA,
  image_type   TEXT,
  published    BOOLEAN NOT NULL DEFAULT false,
  published_at TIMESTAMPTZ,
  deleted_at   TIMESTAMPTZ,
  created_by   UUID REFERENCES public.users(id),
  updated_by   UUID REFERENCES public.users(id),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  CHECK ((is_paid AND price_cents > 0) OR (NOT is_paid AND price_cents = 0))
);
CREATE INDEX IF NOT EXISTS idx_tips_listing ON public.tips (published, published_at DESC) WHERE deleted_at IS NULL;

CREATE TABLE IF NOT EXISTS public.tip_purchases (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tip_id        UUID NOT NULL REFERENCES public.tips(id),
  customer_id   UUID NOT NULL REFERENCES public.users(id),
  wallet_id     UUID NOT NULL REFERENCES public.wallets(id),
  price_cents   BIGINT NOT NULL CHECK (price_cents > 0),
  status        TEXT NOT NULL DEFAULT 'completed' CHECK (status IN ('completed', 'refunded')),
  refunded_at   TIMESTAMPTZ,
  refunded_by   UUID REFERENCES public.users(id),
  refund_reason TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- One live purchase per customer and tip: the guard against a double charge.
CREATE UNIQUE INDEX IF NOT EXISTS tip_purchases_once ON public.tip_purchases (tip_id, customer_id) WHERE status = 'completed';
CREATE INDEX IF NOT EXISTS idx_tip_purchases_customer ON public.tip_purchases (customer_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_tip_purchases_tip ON public.tip_purchases (tip_id, created_at DESC);

ALTER TABLE public.tips ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tip_purchases ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.tips, public.tip_purchases FROM PUBLIC, anon, authenticated;

-- ---------------------------------------------------------------------------
-- JSON shapes
-- ---------------------------------------------------------------------------
-- What a customer sees. The code and the picks only when the tip is free or bought.
CREATE OR REPLACE FUNCTION private.tip_customer_json(t public.tips, p_owned boolean, p_with_image boolean DEFAULT false)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', t.id, 'title', t.title, 'sport', t.sport, 'teamCount', t.team_count,
    'isPaid', t.is_paid, 'price', CASE WHEN t.is_paid THEN private.money(t.price_cents) ELSE NULL END,
    'totalOdds', t.total_odds, 'note', t.note,
    'owned', p_owned, 'locked', (t.is_paid AND NOT p_owned),
    'oddsCode', CASE WHEN NOT t.is_paid OR p_owned THEN t.odds_code END,
    'matches', CASE WHEN NOT t.is_paid OR p_owned THEN t.matches ELSE '[]'::jsonb END,
    'hasImage', t.image IS NOT NULL,
    'image', CASE WHEN p_with_image AND (NOT t.is_paid OR p_owned) AND t.image IS NOT NULL
                  THEN replace(encode(t.image, 'base64'), E'\n', '') END,
    'imageType', CASE WHEN p_with_image AND (NOT t.is_paid OR p_owned) THEN t.image_type END,
    'publishedAt', t.published_at
  )
$$;

-- What a manager sees (everything, plus the sales).
CREATE OR REPLACE FUNCTION private.tip_manage_json(t public.tips)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', t.id, 'title', t.title, 'sport', t.sport, 'teamCount', t.team_count,
    'isPaid', t.is_paid, 'price', private.money(t.price_cents), 'oddsCode', t.odds_code,
    'totalOdds', t.total_odds, 'matches', t.matches, 'note', t.note,
    'hasImage', t.image IS NOT NULL,
    'image', CASE WHEN t.image IS NULL THEN NULL ELSE replace(encode(t.image, 'base64'), E'\n', '') END,
    'imageType', t.image_type,
    'published', t.published, 'publishedAt', t.published_at, 'createdAt', t.created_at, 'updatedAt', t.updated_at,
    'sales', (SELECT count(*)::int FROM public.tip_purchases p WHERE p.tip_id = t.id AND p.status = 'completed'),
    'revenue', private.money((SELECT COALESCE(sum(p.price_cents), 0) FROM public.tip_purchases p WHERE p.tip_id = t.id AND p.status = 'completed'))
  )
$$;

CREATE OR REPLACE FUNCTION private.tip_purchase_json(p public.tip_purchases)
RETURNS jsonb LANGUAGE sql STABLE SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'id', p.id, 'tipId', p.tip_id, 'title', t.title, 'sport', t.sport,
    'customerId', p.customer_id, 'customerName', u.name, 'customerPhone', u.phone,
    'price', private.money(p.price_cents), 'status', p.status,
    'createdAt', p.created_at, 'refundedAt', p.refunded_at, 'refundReason', p.refund_reason
  )
  FROM public.tips t, public.users u WHERE t.id = p.tip_id AND u.id = p.customer_id
$$;

-- ---------------------------------------------------------------------------
-- Customer App
-- ---------------------------------------------------------------------------
-- p_filter: 'all' | 'free' | 'paid'. Published tips, plus the ones the customer bought.
CREATE OR REPLACE FUNCTION public.customer_tips(p_filter text DEFAULT 'all')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  v_filter text := lower(COALESCE(NULLIF(trim(p_filter), ''), 'all'));
BEGIN
  IF v_filter NOT IN ('all', 'free', 'paid') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'filter must be all, free or paid');
  END IF;
  RETURN jsonb_build_object('tips', COALESCE((
    SELECT jsonb_agg(private.tip_customer_json(t, o.owned) ORDER BY t.published_at DESC NULLS LAST, t.created_at DESC)
    FROM public.tips t
    CROSS JOIN LATERAL (SELECT EXISTS (SELECT 1 FROM public.tip_purchases p
                                       WHERE p.tip_id = t.id AND p.customer_id = v_id AND p.status = 'completed') AS owned) o
    WHERE t.deleted_at IS NULL
      AND (t.published OR o.owned)
      AND (v_filter = 'all' OR (v_filter = 'free' AND NOT t.is_paid) OR (v_filter = 'paid' AND t.is_paid))
  ), '[]'::jsonb));
END $$;

-- One tip with its picture (when there is one and the customer may see it).
CREATE OR REPLACE FUNCTION public.customer_tip(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  t public.tips;
  v_owned boolean;
BEGIN
  SELECT * INTO t FROM public.tips WHERE id = p_id AND deleted_at IS NULL;
  v_owned := EXISTS (SELECT 1 FROM public.tip_purchases p WHERE p.tip_id = p_id AND p.customer_id = v_id AND p.status = 'completed');
  IF NOT FOUND OR NOT (t.published OR v_owned) THEN
    PERFORM private.raise_api(404, 'TIP_NOT_FOUND', 'This tip is not available');
  END IF;
  RETURN private.tip_customer_json(t, v_owned, true);
END $$;

-- The purchase. p_expected_price is what the confirmation showed ("12.50");
-- if the price was changed in the meantime nothing is charged.
CREATE OR REPLACE FUNCTION public.customer_buy_tip(p_tip_id uuid, p_expected_price text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
  w public.wallets := private.lock_wallet(v_id);   -- one purchase at a time per wallet
  t public.tips;
  p public.tip_purchases;
  v_expected bigint;
BEGIN
  SELECT * INTO t FROM public.tips WHERE id = p_tip_id AND deleted_at IS NULL FOR SHARE;
  IF NOT FOUND OR NOT t.published THEN
    PERFORM private.raise_api(404, 'TIP_NOT_FOUND', 'This tip is not available');
  END IF;
  IF NOT t.is_paid THEN
    PERFORM private.raise_api(400, 'TIP_IS_FREE', 'This tip is free: there is nothing to pay');
  END IF;

  -- Already bought: show it, charge nothing.
  SELECT * INTO p FROM public.tip_purchases WHERE tip_id = t.id AND customer_id = v_id AND status = 'completed';
  IF FOUND THEN
    RETURN jsonb_build_object('charged', false, 'alreadyOwned', true, 'tip', private.tip_customer_json(t, true, true),
                              'availableBalance', private.money(w.available_cents));
  END IF;

  IF p_expected_price IS NOT NULL THEN
    BEGIN
      v_expected := round(p_expected_price::numeric * 100);
    EXCEPTION WHEN others THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'expectedPrice is not a number');
    END;
    IF v_expected <> t.price_cents THEN
      PERFORM private.raise_api(409, 'PRICE_CHANGED', 'The price of this tip changed. Please check it and confirm again');
    END IF;
  END IF;

  IF w.available_cents < t.price_cents THEN
    PERFORM private.raise_api(400, 'INSUFFICIENT_FUNDS', 'Your balance is not enough for this tip');
  END IF;

  UPDATE public.wallets SET available_cents = available_cents - t.price_cents, updated_at = now()
  WHERE id = w.id RETURNING * INTO w;
  PERFORM private.ledger_entry(w, NULL, 'debit', t.price_cents, 'Tips purchase: ' || t.title);
  INSERT INTO public.tip_purchases (tip_id, customer_id, wallet_id, price_cents)
  VALUES (t.id, v_id, w.id, t.price_cents) RETURNING * INTO p;
  PERFORM private.audit(v_id, 'customer', 'tip.buy', 'tip', t.id::text, NULL,
    jsonb_build_object('purchase', p.id, 'price', private.money(t.price_cents), 'available', private.money(w.available_cents)));

  RETURN jsonb_build_object('charged', true, 'alreadyOwned', false, 'tip', private.tip_customer_json(t, true, true),
                            'availableBalance', private.money(w.available_cents), 'purchaseId', p.id);
END $$;

-- The customer's own purchases.
CREATE OR REPLACE FUNCTION public.customer_tip_purchases()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_role('customer');
BEGIN
  RETURN jsonb_build_object('purchases', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', p.id, 'tipId', p.tip_id, 'title', t.title, 'sport', t.sport,
                                         'price', private.money(p.price_cents), 'status', p.status, 'createdAt', p.created_at)
                     ORDER BY p.created_at DESC)
    FROM public.tip_purchases p JOIN public.tips t ON t.id = p.tip_id WHERE p.customer_id = v_id
  ), '[]'::jsonb));
END $$;

-- ---------------------------------------------------------------------------
-- Admin Dashboard (managers)
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.manage_tips(p_status text DEFAULT 'all')
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_status text := lower(COALESCE(NULLIF(trim(p_status), ''), 'all'));
BEGIN
  PERFORM private.require_management();
  IF v_status NOT IN ('all', 'published', 'draft', 'free', 'paid') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'status must be all, published, draft, free or paid');
  END IF;
  RETURN jsonb_build_object('tips', COALESCE((
    SELECT jsonb_agg(private.tip_manage_json(t) ORDER BY t.created_at DESC)
    FROM public.tips t
    WHERE t.deleted_at IS NULL
      AND (v_status = 'all' OR (v_status = 'published' AND t.published) OR (v_status = 'draft' AND NOT t.published)
           OR (v_status = 'free' AND NOT t.is_paid) OR (v_status = 'paid' AND t.is_paid))
  ), '[]'::jsonb));
END $$;

-- Create (p_id null) or edit. A new tip is a draft until it is published.
-- p_matches: [{"match": "Arsenal v Chelsea", "pick": "Over 2.5", "odds": 1.85}, ...]
-- p_image: base64 JPEG/PNG/WebP of up to 600 KB, optional; p_remove_image drops it.
CREATE OR REPLACE FUNCTION public.manage_save_tip(
  p_id uuid, p_title text, p_sport text, p_team_count int, p_is_paid boolean, p_price text, p_odds_code text,
  p_total_odds numeric DEFAULT NULL, p_matches jsonb DEFAULT '[]'::jsonb, p_note text DEFAULT NULL,
  p_image text DEFAULT NULL, p_remove_image boolean DEFAULT false
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  v_price bigint := 0;
  v_code text := trim(COALESCE(p_odds_code, ''));
  v_title text := trim(COALESCE(p_title, ''));
  v_b64 text := regexp_replace(COALESCE(p_image, ''), '\s', '', 'g');
  v_bytes bytea;
  v_type text;
  v_match jsonb;
  t public.tips;
  v_before jsonb;
BEGIN
  IF v_title = '' THEN PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter a title'); END IF;
  IF lower(COALESCE(p_sport, '')) NOT IN ('football', 'basketball', 'tennis', 'volleyball', 'baseball', 'hockey', 'cricket', 'rugby', 'boxing', 'other') THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Choose a sport');
  END IF;
  IF p_team_count IS NULL OR p_team_count < 1 OR p_team_count > 40 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The number of teams must be between 1 and 40');
  END IF;
  IF v_code = '' OR char_length(v_code) > 200 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the odds code (up to 200 characters)');
  END IF;
  IF COALESCE(p_is_paid, false) THEN
    BEGIN
      v_price := round(p_price::numeric * 100);
    EXCEPTION WHEN others THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Enter the price of a paid tip');
    END;
    IF v_price IS NULL OR v_price <= 0 OR v_price > 100000 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The price must be more than 0 and at most $1,000');
    END IF;
  END IF;
  IF jsonb_typeof(COALESCE(p_matches, '[]'::jsonb)) <> 'array' OR jsonb_array_length(COALESCE(p_matches, '[]'::jsonb)) > 40 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The match details must be a list of up to 40 matches');
  END IF;
  FOR v_match IN SELECT * FROM jsonb_array_elements(COALESCE(p_matches, '[]'::jsonb)) LOOP
    IF jsonb_typeof(v_match) <> 'object' OR char_length(COALESCE(v_match ->> 'match', '')) NOT BETWEEN 1 AND 120
       OR char_length(COALESCE(v_match ->> 'pick', '')) > 80 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Each match needs a name (up to 120 characters) and a pick (up to 80)');
    END IF;
  END LOOP;

  IF v_b64 <> '' THEN
    IF char_length(v_b64) > 820000 OR v_b64 !~ '^[A-Za-z0-9+/]+=*$' THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The image must be a JPEG, PNG or WebP picture of up to 600 KB');
    END IF;
    v_bytes := decode(v_b64, 'base64');
    v_type := CASE
      WHEN substring(v_bytes FROM 1 FOR 3) = '\xffd8ff'::bytea THEN 'image/jpeg'
      WHEN substring(v_bytes FROM 1 FOR 8) = '\x89504e470d0a1a0a'::bytea THEN 'image/png'
      WHEN substring(v_bytes FROM 1 FOR 4) = '\x52494646'::bytea AND substring(v_bytes FROM 9 FOR 4) = '\x57454250'::bytea THEN 'image/webp'
    END;
    IF v_type IS NULL OR octet_length(v_bytes) > 614400 THEN
      PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'The image must be a JPEG, PNG or WebP picture of up to 600 KB');
    END IF;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO public.tips (title, sport, team_count, is_paid, price_cents, odds_code, total_odds, matches, note,
                             image, image_type, created_by, updated_by)
    VALUES (v_title, lower(p_sport), p_team_count, COALESCE(p_is_paid, false), v_price, v_code, p_total_odds,
            COALESCE(p_matches, '[]'::jsonb), NULLIF(trim(COALESCE(p_note, '')), ''), v_bytes, v_type, v_id, v_id)
    RETURNING * INTO t;
    PERFORM private.audit(v_id, private.app_role(), 'tip.create', 'tip', t.id::text, NULL, private.tip_manage_json(t) - 'image' - 'oddsCode');
  ELSE
    SELECT * INTO t FROM public.tips WHERE id = p_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN PERFORM private.raise_api(404, 'TIP_NOT_FOUND', 'Tip not found'); END IF;
    v_before := private.tip_manage_json(t) - 'image' - 'oddsCode';
    -- Customers who bought it keep what they paid for: the price they paid is in tip_purchases.
    UPDATE public.tips SET title = v_title, sport = lower(p_sport), team_count = p_team_count,
      is_paid = COALESCE(p_is_paid, false), price_cents = v_price, odds_code = v_code, total_odds = p_total_odds,
      matches = COALESCE(p_matches, '[]'::jsonb), note = NULLIF(trim(COALESCE(p_note, '')), ''),
      image = CASE WHEN v_bytes IS NOT NULL THEN v_bytes WHEN COALESCE(p_remove_image, false) THEN NULL ELSE image END,
      image_type = CASE WHEN v_bytes IS NOT NULL THEN v_type WHEN COALESCE(p_remove_image, false) THEN NULL ELSE image_type END,
      updated_by = v_id, updated_at = now()
    WHERE id = t.id RETURNING * INTO t;
    PERFORM private.audit(v_id, private.app_role(), 'tip.update', 'tip', t.id::text, v_before, private.tip_manage_json(t) - 'image' - 'oddsCode');
  END IF;
  RETURN private.tip_manage_json(t);
END $$;

CREATE OR REPLACE FUNCTION public.manage_publish_tip(p_id uuid, p_published boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  t public.tips;
BEGIN
  UPDATE public.tips SET published = p_published,
    published_at = CASE WHEN p_published THEN COALESCE(published_at, now()) ELSE published_at END,
    updated_by = v_id, updated_at = now()
  WHERE id = p_id AND deleted_at IS NULL RETURNING * INTO t;
  IF NOT FOUND THEN PERFORM private.raise_api(404, 'TIP_NOT_FOUND', 'Tip not found'); END IF;
  PERFORM private.audit(v_id, private.app_role(), CASE WHEN p_published THEN 'tip.publish' ELSE 'tip.unpublish' END, 'tip', t.id::text);
  RETURN private.tip_manage_json(t);
END $$;

-- Deleting hides the tip; the purchases (money records) stay.
CREATE OR REPLACE FUNCTION public.manage_delete_tip(p_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  t public.tips;
BEGIN
  UPDATE public.tips SET deleted_at = now(), published = false, updated_by = v_id, updated_at = now()
  WHERE id = p_id AND deleted_at IS NULL RETURNING * INTO t;
  IF NOT FOUND THEN PERFORM private.raise_api(404, 'TIP_NOT_FOUND', 'Tip not found'); END IF;
  PERFORM private.audit(v_id, private.app_role(), 'tip.delete', 'tip', t.id::text);
  RETURN jsonb_build_object('deleted', true, 'id', t.id);
END $$;

-- Purchase history (newest first), of one tip or of all.
CREATE OR REPLACE FUNCTION public.manage_tip_purchases(p_tip_id uuid DEFAULT NULL, p_limit int DEFAULT 100, p_offset int DEFAULT 0)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  RETURN jsonb_build_object('purchases', COALESCE((
    SELECT jsonb_agg(private.tip_purchase_json(p) ORDER BY p.created_at DESC)
    FROM (SELECT * FROM public.tip_purchases WHERE p_tip_id IS NULL OR tip_id = p_tip_id
          ORDER BY created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500) OFFSET GREATEST(COALESCE(p_offset, 0), 0)) p
  ), '[]'::jsonb));
END $$;

-- Totals: sales and revenue (refunds are not revenue).
CREATE OR REPLACE FUNCTION private.tip_stats_json()
RETURNS jsonb LANGUAGE sql STABLE SECURITY DEFINER SET search_path = '' AS $$
  SELECT jsonb_build_object(
    'tips', (SELECT count(*)::int FROM public.tips WHERE deleted_at IS NULL),
    'published', (SELECT count(*)::int FROM public.tips WHERE deleted_at IS NULL AND published),
    'paidTips', (SELECT count(*)::int FROM public.tips WHERE deleted_at IS NULL AND is_paid),
    'freeTips', (SELECT count(*)::int FROM public.tips WHERE deleted_at IS NULL AND NOT is_paid),
    'sales', (SELECT count(*)::int FROM public.tip_purchases WHERE status = 'completed'),
    'revenue', private.money((SELECT COALESCE(sum(price_cents), 0) FROM public.tip_purchases WHERE status = 'completed')),
    'salesToday', (SELECT count(*)::int FROM public.tip_purchases WHERE status = 'completed' AND created_at >= date_trunc('day', now())),
    'revenueToday', private.money((SELECT COALESCE(sum(price_cents), 0) FROM public.tip_purchases WHERE status = 'completed' AND created_at >= date_trunc('day', now()))),
    'sales7d', (SELECT count(*)::int FROM public.tip_purchases WHERE status = 'completed' AND created_at >= now() - interval '7 days'),
    'revenue7d', private.money((SELECT COALESCE(sum(price_cents), 0) FROM public.tip_purchases WHERE status = 'completed' AND created_at >= now() - interval '7 days')),
    'refunds', (SELECT count(*)::int FROM public.tip_purchases WHERE status = 'refunded'),
    'refunded', private.money((SELECT COALESCE(sum(price_cents), 0) FROM public.tip_purchases WHERE status = 'refunded')),
    'top', COALESCE((SELECT jsonb_agg(x ORDER BY (x ->> 'salesN')::int DESC) FROM (
        SELECT jsonb_build_object('tipId', t.id, 'title', t.title, 'sport', t.sport, 'sales', count(*)::int, 'salesN', count(*)::int,
                                  'revenue', private.money(sum(p.price_cents))) AS x
        FROM public.tip_purchases p JOIN public.tips t ON t.id = p.tip_id
        WHERE p.status = 'completed' GROUP BY t.id ORDER BY count(*) DESC LIMIT 10) s), '[]'::jsonb)
  )
$$;

CREATE OR REPLACE FUNCTION public.manage_tips_stats()
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
BEGIN
  PERFORM private.require_management();
  RETURN private.tip_stats_json();
END $$;

-- Gives the money back and withdraws the access. Once per purchase.
CREATE OR REPLACE FUNCTION public.manage_refund_tip_purchase(p_purchase_id uuid, p_reason text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_id uuid := private.require_management();
  p public.tip_purchases;
  w public.wallets;
  v_reason text := trim(COALESCE(p_reason, ''));
BEGIN
  IF char_length(v_reason) < 3 THEN
    PERFORM private.raise_api(400, 'VALIDATION_ERROR', 'Write the reason for the refund');
  END IF;
  SELECT * INTO p FROM public.tip_purchases WHERE id = p_purchase_id;
  IF NOT FOUND THEN PERFORM private.raise_api(404, 'NOT_FOUND', 'Purchase not found'); END IF;
  w := private.lock_wallet(p.customer_id);
  SELECT * INTO p FROM public.tip_purchases WHERE id = p_purchase_id FOR UPDATE;   -- after the wallet lock: two refunds run one after the other
  IF p.status = 'refunded' THEN
    PERFORM private.raise_api(409, 'ALREADY_REFUNDED', 'This purchase was already refunded');
  END IF;
  UPDATE public.wallets SET available_cents = available_cents + p.price_cents, updated_at = now() WHERE id = w.id RETURNING * INTO w;
  PERFORM private.ledger_entry(w, NULL, 'credit', p.price_cents, 'Tips refund: ' || v_reason);
  UPDATE public.tip_purchases SET status = 'refunded', refunded_at = now(), refunded_by = v_id, refund_reason = v_reason
  WHERE id = p.id RETURNING * INTO p;
  PERFORM private.audit(v_id, private.app_role(), 'tip.refund', 'tip_purchase', p.id::text, NULL,
    jsonb_build_object('price', private.money(p.price_cents), 'reason', v_reason));
  RETURN private.tip_purchase_json(p);
END $$;

-- ---------------------------------------------------------------------------
-- Agent App: view only
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.agent_tip_purchases(p_limit int DEFAULT 100, p_search text DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = '' AS $$
DECLARE
  v_q text := NULLIF(trim(COALESCE(p_search, '')), '');
BEGIN
  PERFORM private.require_user();
  IF private.app_role() NOT IN ('agent', 'admin') THEN
    PERFORM private.raise_api(403, 'FORBIDDEN', 'Forbidden');
  END IF;
  RETURN jsonb_build_object(
    'summary', private.tip_stats_json(),
    'purchases', COALESCE((
      SELECT jsonb_agg(private.tip_purchase_json(p) ORDER BY p.created_at DESC)
      FROM (SELECT p.* FROM public.tip_purchases p
            JOIN public.users u ON u.id = p.customer_id JOIN public.tips t ON t.id = p.tip_id
            WHERE v_q IS NULL OR u.phone ILIKE '%' || v_q || '%' OR u.name ILIKE '%' || v_q || '%' OR t.title ILIKE '%' || v_q || '%'
            ORDER BY p.created_at DESC LIMIT LEAST(GREATEST(COALESCE(p_limit, 100), 1), 500)) p
    ), '[]'::jsonb));
END $$;

REVOKE ALL ON FUNCTION
  public.customer_tips(text), public.customer_tip(uuid), public.customer_buy_tip(uuid, text), public.customer_tip_purchases(),
  public.manage_tips(text),
  public.manage_save_tip(uuid, text, text, int, boolean, text, text, numeric, jsonb, text, text, boolean),
  public.manage_publish_tip(uuid, boolean), public.manage_delete_tip(uuid),
  public.manage_tip_purchases(uuid, int, int), public.manage_tips_stats(),
  public.manage_refund_tip_purchase(uuid, text), public.agent_tip_purchases(int, text)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION
  public.customer_tips(text), public.customer_tip(uuid), public.customer_buy_tip(uuid, text), public.customer_tip_purchases(),
  public.manage_tips(text),
  public.manage_save_tip(uuid, text, text, int, boolean, text, text, numeric, jsonb, text, text, boolean),
  public.manage_publish_tip(uuid, boolean), public.manage_delete_tip(uuid),
  public.manage_tip_purchases(uuid, int, int), public.manage_tips_stats(),
  public.manage_refund_tip_purchase(uuid, text), public.agent_tip_purchases(int, text)
TO authenticated, service_role;
