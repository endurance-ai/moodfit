CREATE EXTENSION IF NOT EXISTS vector;

DO $roles$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'ai_user') THEN
    CREATE ROLE ai_user NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
$roles$;

GRANT USAGE ON SCHEMA public TO app_user, ai_user;

CREATE OR REPLACE FUNCTION public.style_nodes_set_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END
$$;

CREATE TABLE public.brand_nodes (
  id bigserial PRIMARY KEY,
  brand_name text NOT NULL UNIQUE,
  country text,
  origin_country text,
  status text NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.products (
  id bigserial PRIMARY KEY,
  brand text NOT NULL,
  brand_node_id bigint REFERENCES public.brand_nodes(id) ON DELETE RESTRICT,
  name text NOT NULL,
  price integer NOT NULL,
  original_price integer,
  sale_price integer,
  product_no integer,
  source_currency text,
  source_price numeric(12,2),
  category text,
  subcategory text,
  gender text[] NOT NULL CHECK (
    cardinality(gender) = 1
    AND gender <@ ARRAY['men', 'women', 'unisex']::text[]
  ),
  gender_source text,
  description text,
  image_url text,
  source_image_url text,
  image_selection_kind text CHECK (
    image_selection_kind IS NULL OR image_selection_kind IN ('model', 'product', 'fallback')
  ),
  image_selection_score real CHECK (
    image_selection_score IS NULL OR image_selection_score BETWEEN 0 AND 100
  ),
  image_selection_version text,
  image_selection_candidate_count smallint CHECK (
    image_selection_candidate_count IS NULL OR image_selection_candidate_count BETWEEN 1 AND 10
  ),
  image_selected_at timestamptz,
  images text[] NOT NULL DEFAULT '{}',
  size_info text,
  tags text[] NOT NULL DEFAULT '{}',
  product_code text,
  product_url text NOT NULL,
  platform text,
  in_stock boolean NOT NULL DEFAULT true,
  sale_percentage integer,
  review_count integer NOT NULL DEFAULT 0,
  crawled_at timestamptz,
  last_seen_at timestamptz,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (product_url)
);

CREATE TABLE public.category_canonical (
  raw_category text PRIMARY KEY,
  family text NOT NULL
);

CREATE TABLE public.product_reviews (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id bigint NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  text text,
  author text,
  review_date text,
  photo_urls text[],
  body_info jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_embeddings (
  product_id bigint PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  embedding halfvec(768) NOT NULL,
  embedding_model text NOT NULL,
  embedded_at timestamptz NOT NULL DEFAULT now()
);

CREATE OR REPLACE FUNCTION public.bulk_update_product_embeddings(payload jsonb)
RETURNS integer LANGUAGE plpgsql AS $$
DECLARE
  affected integer;
BEGIN
  INSERT INTO public.product_embeddings(product_id, embedding, embedding_model, embedded_at)
  SELECT (item->>'id')::bigint, (item->>'embedding')::halfvec(768), item->>'model', now()
  FROM jsonb_array_elements(payload) item
  ON CONFLICT (product_id) DO UPDATE SET
    embedding = EXCLUDED.embedding,
    embedding_model = EXCLUDED.embedding_model,
    embedded_at = EXCLUDED.embedded_at;
  GET DIAGNOSTICS affected = ROW_COUNT;
  RETURN affected;
END
$$;

CREATE TABLE public.product_features (
  product_id bigint PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  feature_metadata jsonb NOT NULL DEFAULT '{}',
  retrieval_text text,
  text_embedding halfvec(768),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_image_failures (
  product_id bigint PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  failed_url text NOT NULL,
  failure_kind text NOT NULL,
  disposition text NOT NULL,
  http_status integer,
  attempt_count integer NOT NULL DEFAULT 1,
  first_failed_at timestamptz NOT NULL DEFAULT now(),
  last_failed_at timestamptz NOT NULL DEFAULT now(),
  next_retry_at timestamptz,
  last_error text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_refresh_sources (
  platform_key text PRIMARY KEY,
  platform_type text NOT NULL,
  base_url text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE public.product_refresh_candidates (
  id bigserial PRIMARY KEY,
  platform_key text NOT NULL REFERENCES public.product_refresh_sources(platform_key) ON DELETE CASCADE,
  identity_key text NOT NULL,
  product_url text NOT NULL,
  raw_product jsonb NOT NULL,
  detected_brand text,
  matched_brand_node_id bigint REFERENCES public.brand_nodes(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'discovered' CHECK (status IN ('discovered','brand_unmatched','enriching','ready','imported','rejected','failed')),
  attempt_count integer NOT NULL DEFAULT 0,
  first_seen_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  next_attempt_at timestamptz,
  llm_model text,
  llm_usage jsonb NOT NULL DEFAULT '{}',
  llm_cost_usd numeric,
  enriched_product jsonb,
  imported_product_id bigint REFERENCES public.products(id) ON DELETE SET NULL,
  last_error text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (platform_key, identity_key),
  CHECK (status = 'brand_unmatched' OR matched_brand_node_id IS NOT NULL)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.product_embeddings, public.product_image_failures TO ai_user;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_user, ai_user;

CREATE OR REPLACE FUNCTION public.pipeline_test_truncate()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  TRUNCATE product_refresh_candidates, product_refresh_sources,
    product_image_failures, product_features, product_embeddings,
    product_reviews, products, brand_nodes, category_canonical RESTART IDENTITY CASCADE;
END
$$;
REVOKE ALL ON FUNCTION public.pipeline_test_truncate() FROM PUBLIC;
