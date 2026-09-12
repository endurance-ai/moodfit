-- 119_upsert_prepared_products.sql
-- Publish only products with confirmed pricing and verified normalization.
-- The RPC deliberately maps a fixed field allow-list; JSON cannot assign
-- arbitrary product columns.

BEGIN;

CREATE OR REPLACE FUNCTION public.upsert_prepared_products(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_results jsonb := '[]'::jsonb;
  v_item jsonb;
  v_product jsonb;
  v_norm jsonb;
  v_pricing jsonb;
  v_url text;
  v_brand_node_id bigint;
  v_observed_at timestamptz;
  v_normalization_completed_at timestamptz;
  v_expected_updated_at timestamptz;
  v_product_crawled_at timestamptz;
  v_product_last_seen_at timestamptz;
  v_existing products%ROWTYPE;
  v_exists boolean;
  v_id bigint;
  v_outcome text;
  v_images text[];
  v_gender text[];
  v_price integer;
  v_original_price integer;
  v_sale_price integer;
  v_source_price numeric(12,2);
  v_sale_percentage integer;
  v_product_no integer;
  v_image_selection_score real;
  v_image_selection_candidate_count integer;
  v_image_selected_at timestamptz;
  v_in_stock boolean;
  v_allowed_keys constant text[] := ARRAY[
    'brand','brand_node_id','name','price','original_price','sale_price',
    'source_currency','source_price','category','subcategory','gender',
    'description','image_url','source_image_url','images','size_info','tags',
    'product_code','product_no','product_url','platform','in_stock','sale_percentage',
    'gender_source','crawled_at','last_seen_at','image_selection_kind',
    'image_selection_score','image_selection_version',
    'image_selection_candidate_count','image_selected_at'
  ];
  v_canonical_subcategories constant jsonb := '{
    "tops":["t-shirt","shirt","blouse","polo","hoodie","sweatshirt","tank-top","crop-top","henley","camisole","bodysuit","asymmetric-top"],
    "knitwear":["sweater","cardigan","pullover","knit-top","turtleneck","sweater-vest"],
    "bottoms":["jeans","trousers","chinos","shorts","skirt","joggers","cargo-pants","wide-pants","leggings","sweatpants","pants"],
    "dresses":["mini-dress","midi-dress","maxi-dress","shirt-dress","wrap-dress","slip-dress","knit-dress","jumpsuit"],
    "outerwear":["overcoat","trench-coat","parka","bomber","blazer","vest","leather-jacket","denim-jacket","down-jacket","windbreaker","fleece","varsity-jacket","biker-jacket","suede-jacket","shearling-jacket","fur-jacket","quilted-jacket","coach-jacket","track-jacket","field-jacket","chore-jacket","wool-jacket","harrington","anorak","shirt-jacket","jacket"],
    "underwear":["briefs","bra"],"swimwear":["swimsuit","bikini","trunks"],
    "activewear":["tracksuit","sports-bra","athletic-shorts"],
    "shoes":["sneakers","boots","loafers","derby","oxford","sandals","mules","heels","flats","slides","running-shoes","flip-flops"],
    "bags":["tote","crossbody","backpack","clutch","shoulder-bag","belt-bag","messenger","bucket-bag","mini-bag","hobo-bag","camera-bag","handbag"],
    "accessories":["scarf","belt","watch","tie","gloves","socks","phone-case"],
    "eyewear":["sunglasses","glasses"],"jewelry":["necklace","bracelet","ring","earrings"],
    "headwear":["hat","cap","beanie","beret","bucket-hat"],"other":[]
  }'::jsonb;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array' USING ERRCODE = '22023';
  END IF;

  -- Serialize every conflict key in deterministic order, including URLs that
  -- do not exist yet. Row locks alone cannot order concurrent INSERTs.
  PERFORM pg_advisory_xact_lock(hashtextextended(keys.product_url, 119))
  FROM (
    SELECT DISTINCT item->'product'->>'product_url' AS product_url
    FROM jsonb_array_elements(p_rows) AS input(item)
    WHERE NULLIF(btrim(item->'product'->>'product_url'), '') IS NOT NULL
    ORDER BY 1
  ) AS keys;

  -- Use the table's stable primary-key order shared by image repair and
  -- embedding writers. URL order can be the reverse of ID order and deadlock
  -- with those writers when each transaction holds the other's next row.
  PERFORM p.id
  FROM public.products p
  JOIN (
    SELECT DISTINCT item->'product'->>'product_url' AS product_url
    FROM jsonb_array_elements(p_rows) AS input(item)
    WHERE NULLIF(btrim(item->'product'->>'product_url'), '') IS NOT NULL
  ) keys ON keys.product_url = p.product_url
  ORDER BY p.id
  FOR UPDATE OF p;

  FOR v_item IN SELECT item FROM jsonb_array_elements(p_rows) WITH ORDINALITY AS input(item, ord) ORDER BY ord
  LOOP
    v_product := v_item->'product';
    v_norm := v_item->'normalization';
    v_pricing := v_item->'pricing_observation';
    v_url := NULLIF(btrim(v_product->>'product_url'), '');
    v_id := NULL;

    IF jsonb_typeof(v_item) <> 'object' OR jsonb_typeof(v_product) <> 'object' THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'invalid_envelope', 'message', 'product must be an object'));
      CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_object_keys(v_product) key WHERE NOT (key = ANY(v_allowed_keys))) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'unknown_product_field', 'message', 'product contains an unsupported field'));
      CONTINUE;
    END IF;

    IF jsonb_typeof(v_product->'brand') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'brand_node_id') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'name') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'price') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_product->'original_price') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_product->'source_currency') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'source_price') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_product->'category') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'gender') IS DISTINCT FROM 'array'
       OR jsonb_typeof(v_product->'image_url') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'product_url') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'platform') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_product->'in_stock') IS DISTINCT FROM 'boolean'
       OR (v_product ? 'sale_price' AND jsonb_typeof(v_product->'sale_price') NOT IN ('number','null'))
       OR (v_product ? 'subcategory' AND jsonb_typeof(v_product->'subcategory') NOT IN ('string','null'))
       OR (v_product ? 'description' AND jsonb_typeof(v_product->'description') NOT IN ('string','null'))
       OR (v_product ? 'source_image_url' AND jsonb_typeof(v_product->'source_image_url') NOT IN ('string','null'))
       OR (v_product ? 'images' AND jsonb_typeof(v_product->'images') NOT IN ('array','null'))
       OR (v_product ? 'size_info' AND jsonb_typeof(v_product->'size_info') NOT IN ('string','null'))
       OR (v_product ? 'tags' AND jsonb_typeof(v_product->'tags') NOT IN ('array','null'))
       OR (v_product ? 'product_code' AND jsonb_typeof(v_product->'product_code') NOT IN ('string','null'))
       OR (v_product ? 'product_no' AND jsonb_typeof(v_product->'product_no') NOT IN ('number','null'))
       OR (v_product ? 'sale_percentage' AND jsonb_typeof(v_product->'sale_percentage') NOT IN ('number','null'))
       OR (v_product ? 'gender_source' AND jsonb_typeof(v_product->'gender_source') NOT IN ('string','null'))
       OR (v_product ? 'crawled_at' AND jsonb_typeof(v_product->'crawled_at') NOT IN ('string','null'))
       OR (v_product ? 'last_seen_at' AND jsonb_typeof(v_product->'last_seen_at') NOT IN ('string','null'))
       OR (v_product ? 'image_selection_kind' AND jsonb_typeof(v_product->'image_selection_kind') NOT IN ('string','null'))
       OR (v_product ? 'image_selection_score' AND jsonb_typeof(v_product->'image_selection_score') NOT IN ('number','null'))
       OR (v_product ? 'image_selection_version' AND jsonb_typeof(v_product->'image_selection_version') NOT IN ('string','null'))
       OR (v_product ? 'image_selection_candidate_count' AND jsonb_typeof(v_product->'image_selection_candidate_count') NOT IN ('number','null'))
       OR (v_product ? 'image_selected_at' AND jsonb_typeof(v_product->'image_selected_at') NOT IN ('string','null')) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'invalid_field_type', 'message', 'prepared product contains an invalid scalar or array value'));
      CONTINUE;
    END IF;

    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_product->'gender') e WHERE jsonb_typeof(e) <> 'string')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(NULLIF(v_product->'images','null'::jsonb),'[]'::jsonb)) e WHERE jsonb_typeof(e) <> 'string' OR e#>>'{}' !~* '^https?://')
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(COALESCE(NULLIF(v_product->'tags','null'::jsonb),'[]'::jsonb)) e WHERE jsonb_typeof(e) <> 'string') THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'invalid_array_item', 'message', 'gender, images, and tags must contain valid strings'));
      CONTINUE;
    END IF;

    IF v_url IS NULL OR v_url !~* '^https?://' OR
       (SELECT count(*) FROM jsonb_array_elements(p_rows) d WHERE d->'product'->>'product_url' = v_url) > 1 THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', CASE WHEN v_url IS NULL OR v_url !~* '^https?://' THEN 'invalid_product_url' ELSE 'duplicate_product_url' END,
        'message', CASE WHEN v_url IS NULL OR v_url !~* '^https?://' THEN 'a valid HTTP product_url is required' ELSE 'product_url is repeated in p_rows' END));
      CONTINUE;
    END IF;

    BEGIN
      IF jsonb_typeof(v_item->'observed_at') IS DISTINCT FROM 'string' THEN RAISE invalid_datetime_format; END IF;
      IF jsonb_typeof(v_item->'expected_updated_at') NOT IN ('string','null') THEN RAISE invalid_datetime_format; END IF;
      v_observed_at := (v_item->>'observed_at')::timestamptz;
      IF NOT isfinite(v_observed_at) THEN RAISE invalid_datetime_format; END IF;
      v_expected_updated_at := CASE WHEN jsonb_typeof(v_item->'expected_updated_at') = 'null' THEN NULL ELSE (v_item->>'expected_updated_at')::timestamptz END;
      IF v_expected_updated_at IS NOT NULL AND NOT isfinite(v_expected_updated_at) THEN RAISE invalid_datetime_format; END IF;
      IF v_product->>'brand_node_id' !~ '^[1-9][0-9]*$' THEN RAISE invalid_text_representation; END IF;
      v_brand_node_id := (v_product->>'brand_node_id')::bigint;
      v_price := (v_product->>'price')::integer;
      v_original_price := (v_product->>'original_price')::integer;
      v_sale_price := CASE WHEN jsonb_typeof(v_product->'sale_price') = 'null' THEN NULL ELSE (v_product->>'sale_price')::integer END;
      v_source_price := (v_product->>'source_price')::numeric(12,2);
      v_sale_percentage := CASE WHEN v_product ? 'sale_percentage' AND jsonb_typeof(v_product->'sale_percentage') <> 'null' THEN (v_product->>'sale_percentage')::integer ELSE NULL END;
      v_product_no := CASE WHEN v_product ? 'product_no' AND jsonb_typeof(v_product->'product_no') <> 'null' THEN (v_product->>'product_no')::integer ELSE NULL END;
      v_image_selection_score := CASE WHEN v_product ? 'image_selection_score' AND jsonb_typeof(v_product->'image_selection_score') <> 'null' THEN (v_product->>'image_selection_score')::real ELSE NULL END;
      v_image_selection_candidate_count := CASE WHEN v_product ? 'image_selection_candidate_count' AND jsonb_typeof(v_product->'image_selection_candidate_count') <> 'null' THEN (v_product->>'image_selection_candidate_count')::integer ELSE NULL END;
      v_image_selected_at := CASE WHEN v_product ? 'image_selected_at' AND jsonb_typeof(v_product->'image_selected_at') <> 'null' THEN (v_product->>'image_selected_at')::timestamptz ELSE NULL END;
      IF v_image_selected_at IS NOT NULL AND NOT isfinite(v_image_selected_at) THEN RAISE invalid_datetime_format; END IF;
      v_product_crawled_at := CASE WHEN v_product ? 'crawled_at' AND jsonb_typeof(v_product->'crawled_at') <> 'null' THEN (v_product->>'crawled_at')::timestamptz ELSE NULL END;
      v_product_last_seen_at := CASE WHEN v_product ? 'last_seen_at' AND jsonb_typeof(v_product->'last_seen_at') <> 'null' THEN (v_product->>'last_seen_at')::timestamptz ELSE NULL END;
      IF (v_product_crawled_at IS NOT NULL AND NOT isfinite(v_product_crawled_at))
         OR (v_product_last_seen_at IS NOT NULL AND NOT isfinite(v_product_last_seen_at)) THEN RAISE invalid_datetime_format; END IF;
      v_in_stock := CASE WHEN v_product ? 'in_stock' THEN (v_product->>'in_stock')::boolean ELSE true END;
      SELECT COALESCE(array_agg(value ORDER BY ord), '{}'::text[]) INTO v_gender
      FROM jsonb_array_elements_text(v_product->'gender') WITH ORDINALITY AS g(value, ord);
      SELECT COALESCE(array_agg(value ORDER BY ord), '{}'::text[]) INTO v_images
      FROM jsonb_array_elements_text(COALESCE(NULLIF(v_product->'images','null'::jsonb), '[]'::jsonb)) WITH ORDINALITY AS i(value, ord);
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow OR invalid_text_representation OR numeric_value_out_of_range THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'invalid_field_type', 'message', 'prepared product contains an invalid scalar or array value'));
      CONTINUE;
    END;

    IF jsonb_typeof(v_norm) IS DISTINCT FROM 'object'
       OR jsonb_typeof(v_norm->'status') IS DISTINCT FROM 'string'
       OR v_norm->>'status' NOT IN ('not_required','succeeded','unchanged')
       OR jsonb_typeof(v_norm->'input_hash') IS DISTINCT FROM 'string'
       OR NULLIF(btrim(v_norm->>'input_hash'), '') IS NULL
       OR jsonb_typeof(v_norm->'policy_version') IS DISTINCT FROM 'string'
       OR NULLIF(btrim(v_norm->>'policy_version'), '') IS NULL
       OR jsonb_typeof(v_norm->'completed_at') IS DISTINCT FROM 'string'
       OR NULLIF(btrim(v_norm->>'completed_at'), '') IS NULL
       OR (v_norm->>'status' IN ('succeeded','unchanged') AND (jsonb_typeof(v_norm->'model') IS DISTINCT FROM 'string' OR NULLIF(btrim(v_norm->>'model'), '') IS NULL))
       OR NOT (v_norm ? 'model')
       OR (v_norm->>'status' = 'not_required' AND jsonb_typeof(v_norm->'model') NOT IN ('string','null')) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'normalization_unverified', 'message', 'successful normalization evidence is required'));
      CONTINUE;
    END IF;

    BEGIN
      v_normalization_completed_at := (v_norm->>'completed_at')::timestamptz;
      IF NOT isfinite(v_normalization_completed_at) THEN RAISE invalid_datetime_format; END IF;
    EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'normalization_unverified', 'message', 'normalization completed_at is invalid'));
      CONTINUE;
    END;

    IF jsonb_typeof(v_pricing) IS DISTINCT FROM 'object'
       OR jsonb_typeof(v_pricing->'version') IS DISTINCT FROM 'number'
       OR v_pricing->>'version' <> '2'
       OR jsonb_typeof(v_pricing->'state') IS DISTINCT FROM 'string'
       OR v_pricing->>'state' NOT IN ('sale','regular')
       OR jsonb_typeof(v_pricing->'source') IS DISTINCT FROM 'string'
       OR v_pricing->>'source' NOT IN ('variant','api','listing','detail') THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'pricing_unconfirmed', 'message', 'confirmed pricing observation v2 is required'));
      CONTINUE;
    END IF;

    IF NULLIF(btrim(v_product->>'brand'), '') IS NULL OR NULLIF(btrim(v_product->>'name'), '') IS NULL
       OR NULLIF(btrim(v_product->>'platform'), '') IS NULL
       OR NULLIF(btrim(v_product->>'image_url'), '') IS NULL OR v_product->>'image_url' !~* '^https?://'
       OR (NULLIF(btrim(v_product->>'source_image_url'), '') IS NOT NULL AND v_product->>'source_image_url' !~* '^https?://')
       OR NULLIF(btrim(v_product->>'source_currency'), '') IS NULL OR upper(v_product->>'source_currency') !~ '^[A-Z]{3}$'
       OR v_price <= 0 OR v_original_price <= 0 OR v_source_price <= 0
       OR v_gender IS NULL OR cardinality(v_gender) <> 1 OR NOT (v_gender <@ ARRAY['men','women','unisex']::text[])
       OR v_product->>'category' NOT IN ('tops','knitwear','bottoms','dresses','outerwear','underwear','swimwear','activewear','shoes','bags','accessories','eyewear','jewelry','headwear','other')
       OR (NULLIF(btrim(v_product->>'subcategory'), '') IS NOT NULL AND NOT (v_canonical_subcategories->(v_product->>'category') ? (v_product->>'subcategory')))
       OR (v_pricing->>'state' = 'regular' AND (v_sale_price IS NOT NULL OR v_price <> v_original_price))
       OR (v_pricing->>'state' = 'sale' AND (v_sale_price IS NULL OR v_sale_price <= 0 OR v_sale_price >= v_original_price OR v_price <> v_sale_price))
       OR (upper(v_product->>'source_currency') = 'KRW' AND v_source_price <> v_price)
       OR (v_sale_percentage IS NOT NULL AND (v_sale_percentage < 0 OR v_sale_percentage > 100))
       OR (v_pricing->>'state' = 'regular' AND COALESCE(v_sale_percentage, 0) <> 0)
       OR (v_product_crawled_at IS NOT NULL AND v_product_crawled_at IS DISTINCT FROM v_observed_at)
       OR (v_product_last_seen_at IS NOT NULL AND v_product_last_seen_at IS DISTINCT FROM v_observed_at)
       OR (v_product ? 'gender_source' AND jsonb_typeof(v_product->'gender_source') <> 'null' AND NULLIF(btrim(v_product->>'gender_source'), '') IS NULL)
       OR (v_product ? 'product_no' AND jsonb_typeof(v_product->'product_no') NOT IN ('number','null'))
       OR (v_product ? 'image_selection_kind' AND jsonb_typeof(v_product->'image_selection_kind') <> 'null' AND v_product->>'image_selection_kind' NOT IN ('model','product','fallback'))
       OR (v_image_selection_score IS NOT NULL AND (v_image_selection_score < 0 OR v_image_selection_score > 100))
       OR (v_image_selection_candidate_count IS NOT NULL AND (v_image_selection_candidate_count <= 0 OR v_image_selection_candidate_count > 10))
       OR ((v_product ? 'image_selection_version') AND jsonb_typeof(v_product->'image_selection_version') <> 'null' AND NULLIF(btrim(v_product->>'image_selection_version'), '') IS NULL) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'invalid_product', 'message', 'required product, taxonomy, gender, image, or pricing fields are invalid'));
      CONTINUE;
    END IF;

    IF NOT EXISTS (SELECT 1 FROM public.brand_nodes WHERE id = v_brand_node_id) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'rejected',
        'code', 'brand_not_found', 'message', 'brand_node_id does not exist'));
      CONTINUE;
    END IF;

    SELECT * INTO v_existing FROM public.products WHERE product_url = v_url FOR UPDATE;
    v_exists := FOUND;

    IF NOT v_exists AND v_expected_updated_at IS NOT NULL THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', NULL, 'outcome', 'conflicted',
        'code', 'expected_row_missing', 'message', 'expected product does not exist'));
      CONTINUE;
    ELSIF v_exists AND v_expected_updated_at IS NULL THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', v_existing.id::text, 'outcome', 'conflicted',
        'code', 'insert_only_conflict', 'message', 'product already exists'));
      CONTINUE;
    ELSIF v_exists AND v_existing.updated_at IS DISTINCT FROM v_expected_updated_at THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', v_existing.id::text, 'outcome', 'conflicted',
        'code', 'updated_at_conflict', 'message', 'expected_updated_at does not match'));
      CONTINUE;
    ELSIF v_exists AND GREATEST(v_existing.crawled_at, v_existing.last_seen_at) IS NOT NULL
       AND v_observed_at < GREATEST(v_existing.crawled_at, v_existing.last_seen_at) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', v_existing.id::text, 'outcome', 'conflicted',
        'code', 'stale_observation', 'message', 'observed_at predates stored source observation'));
      CONTINUE;
    END IF;

    -- Representative image is first; retain older detail images and remove duplicates.
    SELECT COALESCE(array_agg(url ORDER BY first_ord), '{}'::text[]) INTO v_images
    FROM (
      SELECT url, min(ord) AS first_ord
      FROM unnest(ARRAY[v_product->>'image_url'] || v_images || COALESCE(v_existing.images, '{}'::text[])) WITH ORDINALITY AS all_images(url, ord)
      WHERE NULLIF(btrim(url), '') IS NOT NULL
      GROUP BY url
    ) deduped;

    IF v_exists AND ROW(
      v_existing.brand, v_existing.brand_node_id, v_existing.name, v_existing.price,
      v_existing.original_price, v_existing.sale_price, v_existing.source_currency,
      v_existing.source_price, v_existing.category, v_existing.subcategory,
      v_existing.gender, v_existing.description, v_existing.image_url,
      v_existing.source_image_url, v_existing.images, v_existing.size_info,
      v_existing.tags, v_existing.product_code, v_existing.platform,
      v_existing.in_stock, v_existing.sale_percentage, v_existing.crawled_at,
      v_existing.last_seen_at, v_existing.product_no, v_existing.gender_source,
      v_existing.image_selection_kind, v_existing.image_selection_score,
      v_existing.image_selection_version, v_existing.image_selection_candidate_count,
      v_existing.image_selected_at
    ) IS NOT DISTINCT FROM ROW(
      btrim(v_product->>'brand'), v_brand_node_id, btrim(v_product->>'name'), v_price,
      v_original_price, v_sale_price, upper(v_product->>'source_currency'),
      v_source_price, v_product->>'category', NULLIF(btrim(v_product->>'subcategory'), ''),
      v_gender, NULLIF(v_product->>'description',''), v_product->>'image_url',
      COALESCE(NULLIF(v_product->>'source_image_url',''), v_product->>'image_url'), v_images,
      NULLIF(v_product->>'size_info',''), COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(NULLIF(v_product->'tags','null'::jsonb),'[]'::jsonb))), '{}'::text[]),
      NULLIF(v_product->>'product_code',''), btrim(v_product->>'platform'), v_in_stock,
      v_sale_percentage, v_observed_at, v_observed_at, v_product_no,
      NULLIF(v_product->>'gender_source',''), NULLIF(v_product->>'image_selection_kind',''),
      v_image_selection_score, NULLIF(v_product->>'image_selection_version',''),
      v_image_selection_candidate_count, v_image_selected_at
    ) THEN
      v_results := v_results || jsonb_build_array(jsonb_build_object(
        'product_url', v_url, 'id', v_existing.id::text, 'outcome', 'unchanged'));
      CONTINUE;
    END IF;

    IF v_exists THEN
      UPDATE public.products SET
        brand = btrim(v_product->>'brand'), brand_node_id = v_brand_node_id,
        name = btrim(v_product->>'name'), price = v_price,
        original_price = v_original_price, sale_price = v_sale_price,
        source_currency = upper(v_product->>'source_currency'), source_price = v_source_price,
        category = v_product->>'category', subcategory = NULLIF(btrim(v_product->>'subcategory'), ''),
        gender = v_gender, description = NULLIF(v_product->>'description',''),
        image_url = v_product->>'image_url',
        source_image_url = COALESCE(NULLIF(v_product->>'source_image_url',''), v_product->>'image_url'),
        images = v_images, size_info = NULLIF(v_product->>'size_info',''),
        tags = COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(NULLIF(v_product->'tags','null'::jsonb),'[]'::jsonb))), '{}'::text[]),
        product_code = NULLIF(v_product->>'product_code',''), platform = btrim(v_product->>'platform'),
        in_stock = v_in_stock, sale_percentage = v_sale_percentage,
        product_no = v_product_no, gender_source = NULLIF(v_product->>'gender_source',''),
        image_selection_kind = NULLIF(v_product->>'image_selection_kind',''),
        image_selection_score = v_image_selection_score,
        image_selection_version = NULLIF(v_product->>'image_selection_version',''),
        image_selection_candidate_count = v_image_selection_candidate_count,
        image_selected_at = v_image_selected_at,
        crawled_at = v_observed_at, last_seen_at = v_observed_at, updated_at = clock_timestamp()
      WHERE id = v_existing.id
      RETURNING id INTO v_id;
      v_outcome := 'updated';
    ELSE
      BEGIN
        INSERT INTO public.products (
          brand, brand_node_id, name, price, original_price, sale_price,
          source_currency, source_price, category, subcategory, gender,
          description, image_url, source_image_url, images, size_info, tags,
          product_code, product_url, platform, in_stock, sale_percentage,
          product_no, gender_source, image_selection_kind, image_selection_score,
          image_selection_version, image_selection_candidate_count, image_selected_at,
          crawled_at, last_seen_at, updated_at
        ) VALUES (
          btrim(v_product->>'brand'), v_brand_node_id, btrim(v_product->>'name'), v_price,
          v_original_price, v_sale_price, upper(v_product->>'source_currency'), v_source_price,
          v_product->>'category', NULLIF(btrim(v_product->>'subcategory'), ''), v_gender,
          NULLIF(v_product->>'description',''), v_product->>'image_url',
          COALESCE(NULLIF(v_product->>'source_image_url',''), v_product->>'image_url'), v_images,
          NULLIF(v_product->>'size_info',''), COALESCE(ARRAY(SELECT jsonb_array_elements_text(COALESCE(NULLIF(v_product->'tags','null'::jsonb),'[]'::jsonb))), '{}'::text[]),
          NULLIF(v_product->>'product_code',''), v_url, btrim(v_product->>'platform'), v_in_stock,
          v_sale_percentage, v_product_no, NULLIF(v_product->>'gender_source',''),
          NULLIF(v_product->>'image_selection_kind',''), v_image_selection_score,
          NULLIF(v_product->>'image_selection_version',''), v_image_selection_candidate_count,
          v_image_selected_at, v_observed_at, v_observed_at, clock_timestamp()
        ) RETURNING id INTO v_id;
        v_outcome := 'inserted';
      EXCEPTION WHEN unique_violation THEN
        SELECT id INTO v_id FROM public.products WHERE product_url = v_url;
        v_results := v_results || jsonb_build_array(jsonb_build_object(
          'product_url', v_url, 'id', v_id::text, 'outcome', 'conflicted',
          'code', 'insert_only_conflict', 'message', 'product was inserted concurrently'));
        CONTINUE;
      END;
    END IF;

    v_results := v_results || jsonb_build_array(jsonb_build_object(
      'product_url', v_url, 'id', v_id::text, 'outcome', v_outcome));
  END LOOP;

  RETURN v_results;
END
$$;

REVOKE ALL ON FUNCTION public.upsert_prepared_products(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_prepared_products(jsonb) TO app_user;

COMMENT ON FUNCTION public.upsert_prepared_products(jsonb) IS
  'Conditionally publishes products with confirmed pricing v2 and verified normalization. '
  'IDs are returned as decimal strings; row validation is reported and infrastructure errors propagate.';

COMMIT;
