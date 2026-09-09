-- Canonical product identity layer. Source `products` rows remain immutable
-- listings; these tables add model/color/offer identity without re-keying them.

BEGIN;

CREATE TABLE IF NOT EXISTS catalog_products (
  id              bigserial PRIMARY KEY,
  brand_node_id   bigint REFERENCES brand_nodes(id) ON DELETE SET NULL,
  brand           text NOT NULL,
  canonical_name  text NOT NULL,
  model_name      text,
  identity_key    text NOT NULL UNIQUE,
  category        text,
  status          text NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active','merged','review')),
  merged_into_id  bigint REFERENCES catalog_products(id) ON DELETE SET NULL,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS catalog_variants (
  id                  bigserial PRIMARY KEY,
  catalog_product_id  bigint NOT NULL REFERENCES catalog_products(id) ON DELETE CASCADE,
  color_key           text,
  color_label         text,
  images              text[] NOT NULL DEFAULT '{}',
  identity_key        text NOT NULL UNIQUE,
  status              text NOT NULL DEFAULT 'active'
                      CHECK (status IN ('active','merged','review')),
  merged_into_id      bigint REFERENCES catalog_variants(id) ON DELETE SET NULL,
  metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS product_offers (
  id                  bigserial PRIMARY KEY,
  source_product_id   bigint NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  catalog_variant_id  bigint REFERENCES catalog_variants(id) ON DELETE SET NULL,
  platform            text NOT NULL,
  source_product_key  text NOT NULL,
  source_variant_key  text NOT NULL DEFAULT 'default',
  product_url         text NOT NULL,
  listed_price        numeric,
  original_price      numeric,
  sale_price          numeric,
  source_price        numeric,
  source_currency     text,
  in_stock            boolean NOT NULL DEFAULT false,
  size_info           text,
  sizes               text[] NOT NULL DEFAULT '{}',
  last_seen_at        timestamptz,
  metadata            jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform, source_product_key, source_variant_key)
);

CREATE TABLE IF NOT EXISTS product_identifiers (
  id                  bigserial PRIMARY KEY,
  product_offer_id    bigint REFERENCES product_offers(id) ON DELETE CASCADE,
  catalog_variant_id  bigint REFERENCES catalog_variants(id) ON DELETE CASCADE,
  kind                text NOT NULL CHECK (kind IN ('unknown','gtin','mpn','sku','source_item_id','model_id','product_group_id')),
  raw_value           text NOT NULL,
  normalized_value    text NOT NULL,
  namespace           text NOT NULL,
  scope               text NOT NULL CHECK (scope IN ('global','brand','platform','shop')),
  level               text NOT NULL CHECK (level IN ('product','color_variant','offer')),
  provenance          text NOT NULL,
  trust               numeric NOT NULL DEFAULT 0 CHECK (trust >= 0 AND trust <= 1),
  dedupe_key          text GENERATED ALWAYS AS (
    kind || ':' || normalized_value || ':' || namespace || ':' ||
    COALESCE(product_offer_id::text, 'offerless') || ':' ||
    COALESCE(catalog_variant_id::text, 'variantless')
  ) STORED UNIQUE,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (product_offer_id IS NOT NULL OR catalog_variant_id IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS catalog_match_decisions (
  id                  bigserial PRIMARY KEY,
  source_product_id   bigint NOT NULL REFERENCES products(id) ON DELETE CASCADE,
  candidate_variant_id bigint REFERENCES catalog_variants(id) ON DELETE SET NULL,
  status              text NOT NULL CHECK (status IN ('auto','review','reject','manual_merge','manual_split')),
  confidence          numeric,
  reason              text NOT NULL,
  evidence            jsonb NOT NULL DEFAULT '{}'::jsonb,
  matcher_version     text NOT NULL,
  reviewed_by         text,
  reviewed_at         timestamptz,
  created_at          timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE products
  ADD COLUMN IF NOT EXISTS canonical_variant_id bigint REFERENCES catalog_variants(id) ON DELETE SET NULL;

ALTER TABLE catalog_products ADD COLUMN IF NOT EXISTS model_name text;
ALTER TABLE catalog_variants ADD COLUMN IF NOT EXISTS images text[] NOT NULL DEFAULT '{}';
ALTER TABLE product_offers ADD COLUMN IF NOT EXISTS sizes text[] NOT NULL DEFAULT '{}';

CREATE INDEX IF NOT EXISTS idx_catalog_products_brand ON catalog_products (brand_node_id, brand);
CREATE INDEX IF NOT EXISTS idx_catalog_variants_product ON catalog_variants (catalog_product_id);
CREATE INDEX IF NOT EXISTS idx_product_offers_source_product ON product_offers (source_product_id);
CREATE INDEX IF NOT EXISTS idx_product_offers_variant ON product_offers (catalog_variant_id, in_stock, last_seen_at DESC);
CREATE INDEX IF NOT EXISTS idx_product_identifiers_lookup ON product_identifiers (kind, normalized_value, namespace);
CREATE INDEX IF NOT EXISTS idx_catalog_match_review ON catalog_match_decisions (status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_products_canonical_variant ON products (canonical_variant_id);

GRANT SELECT, INSERT, UPDATE, DELETE ON catalog_products, catalog_variants, product_offers, product_identifiers, catalog_match_decisions TO app_user;
GRANT USAGE, SELECT ON SEQUENCE catalog_products_id_seq, catalog_variants_id_seq, product_offers_id_seq, product_identifiers_id_seq, catalog_match_decisions_id_seq TO app_user;

COMMIT;
