-- Settings that agents with the 'manage_settings' responsibility manage from
-- the Agent App's Account tab, and the Customer App reads.

-- Per-method ON/OFF switch. A disabled method is hidden from the Customer
-- App and the backend refuses new orders for it; orders already in flight
-- still complete normally.
CREATE TABLE payment_methods (
  method      order_method PRIMARY KEY,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  updated_by  UUID REFERENCES users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO payment_methods (method)
SELECT unnest(enum_range(NULL::order_method))
ON CONFLICT (method) DO NOTHING;

-- Banners on the Customer App home screen.
CREATE TABLE home_ads (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title       TEXT NOT NULL,
  body        TEXT,
  image_url   TEXT,
  link_url    TEXT,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  sort_order  INT NOT NULL DEFAULT 0,
  created_by  UUID REFERENCES users(id),
  updated_by  UUID REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_home_ads_enabled ON home_ads(enabled, sort_order);

-- Numbers/accounts customers send deposits to, per method (e.g. the EVC Plus
-- number an agent device receives payments on).
CREATE TABLE deposit_numbers (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  method      order_method NOT NULL,
  number      TEXT NOT NULL,
  label       TEXT,
  enabled     BOOLEAN NOT NULL DEFAULT true,
  created_by  UUID REFERENCES users(id),
  updated_by  UUID REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (method, number)
);

-- In-app notifications broadcast to every Customer App user.
CREATE TABLE notifications (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  title       TEXT NOT NULL,
  body        TEXT NOT NULL,
  created_by  UUID REFERENCES users(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX idx_notifications_created ON notifications(created_at DESC);

-- Small key/value settings (support contact links).
CREATE TABLE app_settings (
  key         TEXT PRIMARY KEY,
  value       TEXT NOT NULL DEFAULT '',
  updated_by  UUID REFERENCES users(id),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
INSERT INTO app_settings (key) VALUES ('contact_whatsapp'), ('contact_facebook'), ('contact_telegram')
ON CONFLICT (key) DO NOTHING;

-- Same lockdown as migration 003 for the new tables.
DO $$
DECLARE
  t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['payment_methods', 'home_ads', 'deposit_numbers', 'notifications', 'app_settings'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon')
       AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
      EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    END IF;
  END LOOP;
END
$$;
