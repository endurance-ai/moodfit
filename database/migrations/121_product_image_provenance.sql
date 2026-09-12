-- Add DB-owned image generations and guarded embedding provenance writes.
BEGIN;

ALTER TABLE public.products
  ADD COLUMN image_revision bigint NOT NULL DEFAULT 1;

ALTER TABLE public.product_embeddings
  ADD COLUMN source_image_url text,
  ADD COLUMN source_image_revision bigint;

ALTER TABLE public.product_embeddings
  ADD CONSTRAINT chk_product_embeddings_source_provenance
  CHECK (
    (source_image_url IS NULL AND source_image_revision IS NULL)
    OR (
      source_image_url IS NOT NULL
      AND source_image_url ~* '^https?://'
      AND source_image_revision IS NOT NULL
      AND source_image_revision > 0
    )
  );

CREATE OR REPLACE FUNCTION public.set_product_image_revision()
RETURNS trigger
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'INSERT' THEN
    NEW.image_revision := 1;
    RETURN NEW;
  END IF;
  -- align_product_image_gallery runs first by trigger-name ordering. Compare
  -- its final sanitized representative, and ignore caller-supplied revisions.
  NEW.image_revision := OLD.image_revision
    + CASE WHEN OLD.image_url IS DISTINCT FROM NEW.image_url THEN 1 ELSE 0 END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_zz_set_image_revision ON public.products;
CREATE TRIGGER trg_products_zz_set_image_revision
  BEFORE INSERT OR UPDATE ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.set_product_image_revision();

CREATE OR REPLACE FUNCTION public.bulk_update_product_embeddings_v2(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  result jsonb;
BEGIN
  IF jsonb_typeof(payload) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'payload must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(payload) item
    WHERE jsonb_typeof(item) <> 'object'
       OR jsonb_typeof(item->'id') IS DISTINCT FROM 'string'
       OR jsonb_typeof(item->'source_image_revision') IS DISTINCT FROM 'string'
       OR COALESCE(item->>'id', '') !~ '^[1-9][0-9]*$'
       OR COALESCE(item->>'source_image_revision', '') !~ '^[1-9][0-9]*$'
       OR COALESCE(item->>'source_image_url', '') !~* '^https?://'
       OR NULLIF(btrim(item->>'model'), '') IS NULL
       OR NULLIF(btrim(item->>'embedding'), '') IS NULL
  ) THEN
    RAISE EXCEPTION 'each payload item requires string id, embedding, model, source_image_url, and source_image_revision'
      USING ERRCODE = '22023';
  END IF;
  -- Cast every vector before classifying row freshness so malformed or
  -- wrong-dimensional payloads never hide behind stale/missing outcomes.
  PERFORM (item->>'embedding')::halfvec(768)
  FROM jsonb_array_elements(payload) item;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(payload) item
    GROUP BY (item->>'id')::bigint HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'payload contains duplicate product ids' USING ERRCODE = '22023';
  END IF;

  -- One lock order for every batch prevents reversed-input deadlocks.
  PERFORM 1
  FROM public.products p
  JOIN (
    SELECT DISTINCT (item->>'id')::bigint AS id
    FROM jsonb_array_elements(payload) item
  ) requested ON requested.id = p.id
  ORDER BY p.id
  FOR UPDATE OF p;

  WITH input AS (
    SELECT
      ord,
      (item->>'id')::bigint AS id,
      item->>'embedding' AS embedding,
      item->>'model' AS model,
      item->>'source_image_url' AS source_image_url,
      (item->>'source_image_revision')::bigint AS source_image_revision
    FROM jsonb_array_elements(payload) WITH ORDINALITY AS x(item, ord)
  ), classified AS (
    SELECT input.*,
      CASE
        WHEN p.id IS NULL THEN 'missing'
        WHEN p.image_url IS NOT DISTINCT FROM input.source_image_url
         AND p.image_revision = input.source_image_revision THEN 'applied'
        ELSE 'stale'
      END AS outcome
    FROM input LEFT JOIN public.products p USING (id)
  ), written AS (
    INSERT INTO public.product_embeddings (
      product_id, embedding, embedding_model, embedded_at,
      source_image_url, source_image_revision
    )
    SELECT id, embedding::halfvec(768), model, now(),
      source_image_url, source_image_revision
    FROM classified WHERE outcome = 'applied'
    ON CONFLICT (product_id) DO UPDATE SET
      embedding = EXCLUDED.embedding,
      embedding_model = EXCLUDED.embedding_model,
      embedded_at = EXCLUDED.embedded_at,
      source_image_url = EXCLUDED.source_image_url,
      source_image_revision = EXCLUDED.source_image_revision
    RETURNING product_id
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id::text, 'outcome', outcome
  ) ORDER BY ord), '[]'::jsonb)
  INTO result
  FROM classified;

  RETURN result;
END;
$$;

CREATE OR REPLACE FUNCTION public.repair_product_image_assets_v2(repairs jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  item jsonb;
  product_id bigint;
  current_product public.products%ROWTYPE;
  replacement_url text;
  source_url text;
  requested_images text[];
  bad_urls text[];
  ordered_images text[];
  result jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(repairs) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'repairs must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(repairs) value
    WHERE jsonb_typeof(value) <> 'object'
       OR jsonb_typeof(value->'id') IS DISTINCT FROM 'string'
       OR (value ? 'before_revision' AND jsonb_typeof(value->'before_revision') IS DISTINCT FROM 'string')
       OR COALESCE(value->>'id', '') !~ '^[1-9][0-9]*$'
       OR (value ? 'before_revision' AND COALESCE(value->>'before_revision', '') !~ '^[1-9][0-9]*$')
  ) THEN
    RAISE EXCEPTION 'each repair requires string id and an optional decimal before_revision'
      USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(repairs) value
    GROUP BY (value->>'id')::bigint HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'repairs contains duplicate product ids' USING ERRCODE = '22023';
  END IF;

  PERFORM 1
  FROM public.products p
  JOIN (
    SELECT DISTINCT (value->>'id')::bigint AS id
    FROM jsonb_array_elements(repairs) value
  ) requested ON requested.id = p.id
  ORDER BY p.id
  FOR UPDATE OF p;

  FOR item IN SELECT value FROM jsonb_array_elements(repairs) WITH ORDINALITY x(value, ord) ORDER BY ord
  LOOP
    product_id := (item->>'id')::bigint;
    SELECT * INTO current_product FROM public.products WHERE id = product_id;
    IF NOT FOUND THEN
      result := result || jsonb_build_array(jsonb_build_object(
        'id', product_id::text, 'outcome', 'missing', 'image_url', NULL, 'image_revision', NULL));
      CONTINUE;
    END IF;
    IF current_product.image_url IS DISTINCT FROM item->>'before_url'
       OR (item ? 'before_revision' AND current_product.image_revision <> (item->>'before_revision')::bigint) THEN
      result := result || jsonb_build_array(jsonb_build_object(
        'id', product_id::text, 'outcome', 'stale',
        'image_url', current_product.image_url,
        'image_revision', current_product.image_revision::text));
      CONTINUE;
    END IF;

    replacement_url := NULLIF(item->>'replacement_url', '');
    source_url := NULLIF(item->>'source_image_url', '');
    SELECT COALESCE(array_agg(value), '{}') INTO requested_images
      FROM jsonb_array_elements_text(COALESCE(item->'images', '[]'::jsonb)) value;
    SELECT COALESCE(array_agg(value), '{}') INTO bad_urls
      FROM jsonb_array_elements_text(COALESCE(item->'bad_urls', '[]'::jsonb)) value;
    SELECT ARRAY(
      SELECT candidate FROM (
        SELECT candidate, min(ord) AS first_ord
        FROM unnest(requested_images) WITH ORDINALITY image(candidate, ord)
        WHERE candidate ~* '^https?://' AND NOT candidate = ANY(bad_urls)
          AND candidate IS DISTINCT FROM replacement_url
        GROUP BY candidate
      ) clean ORDER BY first_ord
    ) INTO ordered_images;
    IF replacement_url IS NOT NULL
       AND (replacement_url !~* '^https?://' OR replacement_url = ANY(bad_urls)) THEN
      RAISE EXCEPTION 'invalid replacement_url for product %', product_id USING ERRCODE = '22023';
    END IF;
    IF source_url IS NOT NULL AND (source_url !~* '^https?://' OR source_url = ANY(bad_urls)) THEN
      source_url := NULL;
    END IF;
    IF replacement_url IS NOT NULL THEN
      ordered_images := ARRAY[replacement_url] || ordered_images;
    END IF;

    UPDATE public.products SET
      image_url = replacement_url,
      source_image_url = source_url,
      images = ordered_images,
      in_stock = CASE WHEN COALESCE((item->>'mark_out_of_stock')::boolean, false) THEN false ELSE in_stock END,
      updated_at = now()
    WHERE id = product_id
    RETURNING * INTO current_product;

    result := result || jsonb_build_array(jsonb_build_object(
      'id', product_id::text, 'outcome', 'applied',
      'image_url', current_product.image_url,
      'image_revision', current_product.image_revision::text));
  END LOOP;
  RETURN result;
END;
$$;

REVOKE ALL ON FUNCTION public.bulk_update_product_embeddings_v2(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.repair_product_image_assets_v2(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bulk_update_product_embeddings_v2(jsonb) TO app_user, ai_user;
GRANT EXECUTE ON FUNCTION public.repair_product_image_assets_v2(jsonb) TO app_user, ai_user;

COMMENT ON COLUMN public.products.image_revision IS
  'DB-owned generation incremented only when the final sanitized canonical image_url changes.';
COMMENT ON COLUMN public.product_embeddings.source_image_url IS
  'Canonical products.image_url used to compute this embedding; NULL means unverifiable legacy data.';
COMMENT ON COLUMN public.product_embeddings.source_image_revision IS
  'products.image_revision used to compute this embedding; NULL means unverifiable legacy data.';

COMMIT;
