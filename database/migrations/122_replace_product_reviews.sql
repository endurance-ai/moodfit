-- Replace a verified sampled review snapshot and its actual count atomically.
BEGIN;

ALTER TABLE public.products ADD COLUMN reviews_observed_at timestamptz;

CREATE OR REPLACE FUNCTION public.replace_product_reviews(
  p_product_id bigint,
  p_observed_at timestamptz,
  p_reviews jsonb
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  current_product public.products%ROWTYPE;
  item jsonb;
  snapshot jsonb := '[]'::jsonb;
  stored_snapshot jsonb;
  photos jsonb;
  stored_count integer;
BEGIN
  IF p_product_id IS NULL OR p_product_id <= 0 OR p_observed_at IS NULL
     OR NOT isfinite(p_observed_at) OR jsonb_typeof(p_reviews) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'product id, finite observation timestamp and review array are required'
      USING ERRCODE = '22023';
  END IF;

  -- Validate the entire request before any DELETE. Database errors after DELETE
  -- still roll the whole function call back, preserving the previous snapshot.
  FOR item IN SELECT value FROM jsonb_array_elements(p_reviews)
  LOOP
    IF jsonb_typeof(item) IS DISTINCT FROM 'object'
       OR EXISTS (SELECT FROM jsonb_object_keys(item) AS keys(key)
                  WHERE key NOT IN ('text', 'author', 'review_date', 'photo_urls', 'body_info'))
       OR (item ? 'text' AND jsonb_typeof(item->'text') NOT IN ('string', 'null'))
       OR (item ? 'author' AND jsonb_typeof(item->'author') NOT IN ('string', 'null'))
       OR (item ? 'review_date' AND jsonb_typeof(item->'review_date') NOT IN ('string', 'null'))
       OR (item ? 'photo_urls' AND jsonb_typeof(item->'photo_urls') NOT IN ('array', 'null'))
       OR (item ? 'body_info' AND jsonb_typeof(item->'body_info') NOT IN ('object', 'null')) THEN
      RAISE EXCEPTION 'invalid review item shape' USING ERRCODE = '22023';
    END IF;
    photos := COALESCE(NULLIF(item->'photo_urls', 'null'::jsonb), '[]'::jsonb);
    IF EXISTS (SELECT FROM jsonb_array_elements(photos) value
               WHERE jsonb_typeof(value) <> 'string' OR (value #>> '{}') !~* '^https?://[^[:space:]]+$')
       OR (NULLIF(btrim(item->>'text'), '') IS NULL AND jsonb_array_length(photos) = 0) THEN
      RAISE EXCEPTION 'review requires text or valid photo URLs' USING ERRCODE = '22023';
    END IF;
    IF jsonb_typeof(item->'body_info') = 'object' AND EXISTS (
      SELECT FROM jsonb_each(item->'body_info') AS body(key, value)
      WHERE key NOT IN ('height', 'weight', 'usualSize', 'purchasedSize', 'bodyType')
         OR jsonb_typeof(value) NOT IN ('string', 'null')
    ) THEN
      RAISE EXCEPTION 'invalid review body information' USING ERRCODE = '22023';
    END IF;
    snapshot := snapshot || jsonb_build_array(jsonb_build_object(
      'text', NULLIF(item->>'text', ''), 'author', NULLIF(item->>'author', ''),
      'review_date', NULLIF(item->>'review_date', ''), 'photo_urls', photos,
      'body_info', item->'body_info'
    ));
  END LOOP;
  SELECT COALESCE(jsonb_agg(value ORDER BY value::text), '[]'::jsonb)
    INTO snapshot FROM jsonb_array_elements(snapshot);

  SELECT * INTO current_product FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome', 'missing', 'product_id', p_product_id::text, 'review_count', 0);
  END IF;
  SELECT count(*)::integer,
    COALESCE(jsonb_agg(jsonb_build_object(
      'text', NULLIF(text, ''), 'author', NULLIF(author, ''),
      'review_date', NULLIF(review_date, ''), 'photo_urls', COALESCE(to_jsonb(photo_urls), '[]'::jsonb),
      'body_info', body_info
    ) ORDER BY jsonb_build_object(
      'text', NULLIF(text, ''), 'author', NULLIF(author, ''),
      'review_date', NULLIF(review_date, ''), 'photo_urls', COALESCE(to_jsonb(photo_urls), '[]'::jsonb),
      'body_info', body_info
    )::text), '[]'::jsonb)
    INTO stored_count, stored_snapshot FROM public.product_reviews WHERE product_id = p_product_id;

  IF current_product.reviews_observed_at > p_observed_at OR
     (current_product.reviews_observed_at = p_observed_at AND snapshot IS DISTINCT FROM stored_snapshot) THEN
    RETURN jsonb_build_object('outcome', 'stale', 'product_id', p_product_id::text, 'review_count', stored_count);
  END IF;
  IF current_product.reviews_observed_at = p_observed_at AND snapshot = stored_snapshot THEN
    -- Repair a legacy count mismatch without changing review identities.
    UPDATE public.products SET review_count = stored_count WHERE id = p_product_id AND review_count IS DISTINCT FROM stored_count;
    RETURN jsonb_build_object('outcome', 'unchanged', 'product_id', p_product_id::text, 'review_count', stored_count);
  END IF;

  DELETE FROM public.product_reviews WHERE product_id = p_product_id;
  INSERT INTO public.product_reviews(product_id, text, author, review_date, photo_urls, body_info)
  SELECT p_product_id, value->>'text', value->>'author', value->>'review_date',
    ARRAY(SELECT jsonb_array_elements_text(value->'photo_urls')),
    NULLIF(value->'body_info', 'null'::jsonb)
  FROM jsonb_array_elements(snapshot);
  SELECT count(*)::integer INTO stored_count FROM public.product_reviews WHERE product_id = p_product_id;
  UPDATE public.products SET review_count = stored_count, reviews_observed_at = p_observed_at WHERE id = p_product_id;
  RETURN jsonb_build_object('outcome', 'applied', 'product_id', p_product_id::text, 'review_count', stored_count);
END;
$$;

REVOKE ALL ON FUNCTION public.replace_product_reviews(bigint, timestamptz, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_product_reviews(bigint, timestamptz, jsonb) TO app_user;
COMMENT ON COLUMN public.products.reviews_observed_at IS
  'Source observation time of the last verified sampled review replacement; NULL is unverified legacy provenance.';
COMMENT ON FUNCTION public.replace_product_reviews(bigint, timestamptz, jsonb) IS
  'Atomic sampled review replacement; caller must verify succeeded collection and confirm an empty snapshot before sending [].';
NOTIFY pgrst, 'reload schema';
COMMIT;
