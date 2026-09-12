-- 120_product_refresh_candidate_lifecycle.sql
-- Observation generations and leased ownership for refresh candidates.

BEGIN;

ALTER TABLE public.product_refresh_candidates
  ADD COLUMN IF NOT EXISTS raw_observed_at timestamptz,
  ADD COLUMN IF NOT EXISTS observation_revision bigint NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS processing_token uuid,
  ADD COLUMN IF NOT EXISTS processing_observation_revision bigint,
  ADD COLUMN IF NOT EXISTS processing_max_age_hours integer,
  ADD COLUMN IF NOT EXISTS lease_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS prepared_observation_revision bigint,
  ADD COLUMN IF NOT EXISTS normalization_result jsonb,
  ADD COLUMN IF NOT EXISTS last_error_code text;

ALTER TABLE public.product_refresh_candidates
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_status_check,
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_check,
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_brand_state_check,
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_revision_check,
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_lease_check,
  DROP CONSTRAINT IF EXISTS product_refresh_candidates_normalization_check,
  ADD CONSTRAINT product_refresh_candidates_status_check CHECK (status IN (
    'discovered','brand_unmatched','enriching','ready','imported',
    'rejected','failed','blocked','awaiting_observation'
  )),
  ADD CONSTRAINT product_refresh_candidates_brand_state_check CHECK (
    matched_brand_node_id IS NOT NULL OR status IN (
      'brand_unmatched','enriching','ready','awaiting_observation',
      'imported','rejected','blocked'
    )
  ),
  ADD CONSTRAINT product_refresh_candidates_revision_check CHECK (
    observation_revision > 0
    AND (prepared_observation_revision IS NULL OR prepared_observation_revision > 0)
  ),
  ADD CONSTRAINT product_refresh_candidates_lease_check CHECK (
    (processing_token IS NULL) = (lease_expires_at IS NULL)
    AND (processing_token IS NULL) = (processing_observation_revision IS NULL)
    AND (processing_token IS NULL) = (processing_max_age_hours IS NULL)
  ),
  ADD CONSTRAINT product_refresh_candidates_normalization_check CHECK (
    normalization_result IS NULL OR jsonb_typeof(normalization_result) = 'object'
  );

CREATE INDEX IF NOT EXISTS idx_product_refresh_candidates_claim_v2
  ON public.product_refresh_candidates (status, next_attempt_at, first_seen_at, id);

DROP TRIGGER IF EXISTS trg_product_refresh_candidates_updated_at ON public.product_refresh_candidates;
CREATE TRIGGER trg_product_refresh_candidates_updated_at
  BEFORE UPDATE ON public.product_refresh_candidates
  FOR EACH ROW EXECUTE FUNCTION public.style_nodes_set_updated_at();

-- Volatile collection metadata cannot create a new semantic generation.
CREATE OR REPLACE FUNCTION public.product_refresh_meaningful_raw(p_raw jsonb)
RETURNS jsonb
LANGUAGE sql
IMMUTABLE
STRICT
SET search_path = public, pg_temp
AS $$
  SELECT p_raw - ARRAY[
    'crawledAt','crawled_at','observedAt','observed_at','lastSeenAt',
    'last_seen_at','debug','normalization','reviewCollection',
    'review_collection','llmUsage','llm_usage'
  ]::text[]
$$;

CREATE OR REPLACE FUNCTION public.upsert_product_refresh_observations(p_rows jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_item jsonb;
  v_raw jsonb;
  v_platform text;
  v_identity text;
  v_url text;
  v_detected text;
  v_brand_id bigint;
  v_observed timestamptz;
  v_current public.product_refresh_candidates%ROWTYPE;
  v_meaningful_changed boolean;
  v_rematched boolean;
  v_inserted integer := 0;
  v_updated integer := 0;
  v_unchanged integer := 0;
  v_stale integer := 0;
  v_conflicted integer := 0;
  v_rematched_count integer := 0;
BEGIN
  IF p_rows IS NULL OR jsonb_typeof(p_rows) <> 'array' THEN
    RAISE EXCEPTION 'p_rows must be a JSON array' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(p_rows) input(item),
      LATERAL jsonb_object_keys(item) key
    WHERE key NOT IN (
      'platform_key','identity_key','product_url','raw_product',
      'detected_brand','matched_brand_node_id','raw_observed_at'
    )
  ) THEN
    RAISE EXCEPTION 'observation contains an unsupported field' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(p_rows) a(item)
    GROUP BY item->>'platform_key', item->>'identity_key'
    HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'p_rows contains a repeated platform_key/identity_key' USING ERRCODE = '22023';
  END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(k, 120))
  FROM (
    SELECT DISTINCT concat_ws(E'\x1f', item->>'platform_key', item->>'identity_key') AS k
    FROM jsonb_array_elements(p_rows) input(item)
    ORDER BY 1
  ) keys;

  FOR v_item IN SELECT item FROM jsonb_array_elements(p_rows) WITH ORDINALITY input(item, ord) ORDER BY ord
  LOOP
    IF jsonb_typeof(v_item) <> 'object'
       OR jsonb_typeof(v_item->'platform_key') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_item->'identity_key') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_item->'product_url') IS DISTINCT FROM 'string'
       OR jsonb_typeof(v_item->'raw_product') IS DISTINCT FROM 'object'
       OR NOT (v_item ? 'detected_brand')
       OR jsonb_typeof(v_item->'detected_brand') NOT IN ('string','null')
       OR NOT (v_item ? 'matched_brand_node_id')
       OR jsonb_typeof(v_item->'matched_brand_node_id') NOT IN ('string','null')
       OR NOT (v_item ? 'raw_observed_at')
       OR jsonb_typeof(v_item->'raw_observed_at') NOT IN ('string','null') THEN
      RAISE EXCEPTION 'invalid observation envelope' USING ERRCODE = '22023';
    END IF;
    v_platform := NULLIF(btrim(v_item->>'platform_key'), '');
    v_identity := NULLIF(btrim(v_item->>'identity_key'), '');
    v_url := NULLIF(btrim(v_item->>'product_url'), '');
    v_raw := v_item->'raw_product';
    v_detected := NULLIF(btrim(v_item->>'detected_brand'), '');
    BEGIN
      v_brand_id := CASE WHEN jsonb_typeof(v_item->'matched_brand_node_id') = 'null' THEN NULL ELSE (v_item->>'matched_brand_node_id')::bigint END;
      v_observed := CASE WHEN jsonb_typeof(v_item->'raw_observed_at') = 'null' THEN NULL ELSE (v_item->>'raw_observed_at')::timestamptz END;
    EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range OR invalid_datetime_format OR datetime_field_overflow THEN
      RAISE EXCEPTION 'invalid observation id or timestamp' USING ERRCODE = '22023';
    END;
    IF v_platform IS NULL OR v_identity IS NULL OR v_url IS NULL OR v_url !~* '^https?://'
       OR (v_observed IS NOT NULL AND NOT isfinite(v_observed))
       OR (v_brand_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.brand_nodes WHERE id = v_brand_id))
       OR NOT EXISTS (SELECT 1 FROM public.product_refresh_sources WHERE platform_key = v_platform) THEN
      RAISE EXCEPTION 'invalid observation value' USING ERRCODE = '22023';
    END IF;

    SELECT * INTO v_current
    FROM public.product_refresh_candidates
    WHERE platform_key = v_platform AND identity_key = v_identity
    FOR UPDATE;

    IF NOT FOUND THEN
      INSERT INTO public.product_refresh_candidates (
        platform_key, identity_key, product_url, raw_product, raw_observed_at,
        detected_brand, matched_brand_node_id, status, first_seen_at, last_seen_at
      ) VALUES (
        v_platform, v_identity, v_url, v_raw, v_observed, v_detected, v_brand_id,
        CASE WHEN v_brand_id IS NULL THEN 'brand_unmatched' ELSE 'discovered' END,
        clock_timestamp(), clock_timestamp()
      );
      v_inserted := v_inserted + 1;
      CONTINUE;
    END IF;

    IF v_current.raw_observed_at IS NOT NULL
       AND (v_observed IS NULL OR v_observed < v_current.raw_observed_at) THEN
      v_stale := v_stale + 1;
      CONTINUE;
    END IF;

    v_meaningful_changed :=
      v_current.product_url IS DISTINCT FROM v_url
      OR public.product_refresh_meaningful_raw(v_current.raw_product)
         IS DISTINCT FROM public.product_refresh_meaningful_raw(v_raw)
      OR v_current.detected_brand IS DISTINCT FROM v_detected
      OR v_current.matched_brand_node_id IS DISTINCT FROM v_brand_id;

    IF v_current.raw_observed_at IS NOT DISTINCT FROM v_observed THEN
      IF v_meaningful_changed THEN
        v_conflicted := v_conflicted + 1;
      ELSE
        UPDATE public.product_refresh_candidates
        SET last_seen_at = clock_timestamp()
        WHERE id = v_current.id;
        v_unchanged := v_unchanged + 1;
      END IF;
      CONTINUE;
    END IF;

    v_rematched := v_current.matched_brand_node_id IS NULL AND v_brand_id IS NOT NULL;
    UPDATE public.product_refresh_candidates
    SET product_url = v_url,
        raw_product = v_raw,
        raw_observed_at = v_observed,
        detected_brand = v_detected,
        matched_brand_node_id = v_brand_id,
        last_seen_at = clock_timestamp(),
        observation_revision = observation_revision + CASE WHEN v_meaningful_changed THEN 1 ELSE 0 END,
        enriched_product = CASE WHEN v_meaningful_changed THEN NULL ELSE enriched_product END,
        prepared_observation_revision = CASE WHEN v_meaningful_changed THEN NULL ELSE prepared_observation_revision END,
        normalization_result = CASE WHEN v_meaningful_changed THEN NULL ELSE normalization_result END,
        status = CASE
          WHEN status IN ('enriching','ready','imported','rejected','blocked') THEN status
          WHEN v_brand_id IS NULL THEN 'brand_unmatched'
          WHEN status IN ('brand_unmatched','awaiting_observation') THEN 'discovered'
          ELSE status
        END,
        next_attempt_at = CASE
          WHEN status IN ('brand_unmatched','awaiting_observation') AND v_brand_id IS NOT NULL THEN NULL
          ELSE next_attempt_at
        END,
        last_error = CASE
          WHEN status IN ('brand_unmatched','awaiting_observation') AND v_brand_id IS NOT NULL THEN NULL
          ELSE last_error
        END,
        last_error_code = CASE
          WHEN status IN ('brand_unmatched','awaiting_observation') AND v_brand_id IS NOT NULL THEN NULL
          ELSE last_error_code
        END
    WHERE id = v_current.id;
    v_updated := v_updated + 1;
    IF v_rematched THEN v_rematched_count := v_rematched_count + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'inserted', v_inserted, 'updated', v_updated, 'unchanged', v_unchanged,
    'stale', v_stale, 'conflicted', v_conflicted, 'rematched', v_rematched_count
  );
END
$$;

CREATE OR REPLACE FUNCTION public.claim_product_refresh_candidates_v2(
  p_limit integer DEFAULT 200,
  p_max_attempts integer DEFAULT 3,
  p_origin_country text DEFAULT NULL,
  p_platform_key text DEFAULT NULL,
  p_in_stock_only boolean DEFAULT false,
  p_max_age_hours integer DEFAULT 24
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE v_result jsonb;
BEGIN
  IF p_limit IS NULL OR p_max_attempts IS NULL OR p_max_age_hours IS NULL OR p_in_stock_only IS NULL
     OR p_limit < 1 OR p_limit > 1000 OR p_max_attempts < 1 OR p_max_age_hours < 1 THEN
    RAISE EXCEPTION 'invalid claim limits' USING ERRCODE = '22023';
  END IF;

  UPDATE public.product_refresh_candidates
  SET status = 'awaiting_observation', processing_token = NULL, lease_expires_at = NULL,
      processing_observation_revision = NULL, processing_max_age_hours = NULL,
      attempt_count = GREATEST(attempt_count - CASE
        WHEN processing_token IS NOT NULL
          AND lease_expires_at <= clock_timestamp()
          AND processing_observation_revision IS DISTINCT FROM observation_revision
          THEN 1 ELSE 0 END, 0),
      last_error_code = 'observation_stale', last_error = 'source observation is missing or stale'
  WHERE status IN ('discovered','failed','enriching','ready')
    AND (processing_token IS NULL OR lease_expires_at <= clock_timestamp())
    AND (raw_observed_at IS NULL OR raw_observed_at < clock_timestamp() - make_interval(hours => p_max_age_hours))
    AND (p_platform_key IS NULL OR platform_key = p_platform_key)
    AND (NOT p_in_stock_only OR COALESCE(raw_product->>'inStock', raw_product->>'in_stock') = 'true')
    AND EXISTS (
      SELECT 1 FROM public.product_refresh_sources s
      JOIN public.brand_nodes b ON b.id = product_refresh_candidates.matched_brand_node_id
      WHERE s.platform_key = product_refresh_candidates.platform_key AND s.enabled = true
        AND (p_origin_country IS NULL OR upper(COALESCE(b.origin_country,b.country,'')) = upper(p_origin_country))
    );

  -- A lease that expired after its observation generation changed is a stale
  -- attempt. Refund it once while clearing the only token that could refund it.
  UPDATE public.product_refresh_candidates
  SET status = CASE
        WHEN matched_brand_node_id IS NULL THEN 'brand_unmatched'
        WHEN raw_observed_at IS NULL OR raw_observed_at < clock_timestamp() - make_interval(hours => p_max_age_hours)
          THEN 'awaiting_observation'
        ELSE 'discovered'
      END,
      attempt_count = GREATEST(attempt_count - 1, 0),
      processing_token = NULL, processing_observation_revision = NULL,
      processing_max_age_hours = NULL,
      lease_expires_at = NULL, next_attempt_at = NULL
  WHERE status IN ('enriching','ready')
    AND processing_token IS NOT NULL
    AND lease_expires_at <= clock_timestamp()
    AND processing_observation_revision IS DISTINCT FROM observation_revision
    AND (p_platform_key IS NULL OR platform_key = p_platform_key)
    AND (NOT p_in_stock_only OR COALESCE(raw_product->>'inStock', raw_product->>'in_stock') = 'true')
    AND EXISTS (
      SELECT 1 FROM public.product_refresh_sources s
      JOIN public.brand_nodes b ON b.id = product_refresh_candidates.matched_brand_node_id
      WHERE s.platform_key = product_refresh_candidates.platform_key AND s.enabled = true
        AND (p_origin_country IS NULL OR upper(COALESCE(b.origin_country,b.country,'')) = upper(p_origin_country))
    );

  UPDATE public.product_refresh_candidates
  SET status = 'blocked', processing_token = NULL, lease_expires_at = NULL,
      processing_observation_revision = NULL, processing_max_age_hours = NULL,
      last_error_code = COALESCE(last_error_code, 'attempts_exhausted')
  WHERE status IN ('discovered','failed','enriching','ready')
    AND attempt_count >= p_max_attempts
    AND (processing_token IS NULL OR lease_expires_at <= clock_timestamp())
    AND (p_platform_key IS NULL OR platform_key = p_platform_key)
    AND (NOT p_in_stock_only OR COALESCE(raw_product->>'inStock', raw_product->>'in_stock') = 'true')
    AND EXISTS (
      SELECT 1 FROM public.product_refresh_sources s
      JOIN public.brand_nodes b ON b.id = product_refresh_candidates.matched_brand_node_id
      WHERE s.platform_key = product_refresh_candidates.platform_key AND s.enabled = true
        AND (p_origin_country IS NULL OR upper(COALESCE(b.origin_country,b.country,'')) = upper(p_origin_country))
    );

  WITH selected AS (
    SELECT c.id
    FROM public.product_refresh_candidates c
    JOIN public.product_refresh_sources s ON s.platform_key = c.platform_key
    JOIN public.brand_nodes b ON b.id = c.matched_brand_node_id
    WHERE s.enabled = true
      AND c.raw_observed_at IS NOT NULL
      AND c.raw_observed_at >= clock_timestamp() - make_interval(hours => p_max_age_hours)
      AND c.attempt_count < p_max_attempts
      AND (c.next_attempt_at IS NULL OR c.next_attempt_at <= clock_timestamp())
      AND (
        c.status IN ('discovered','failed')
        OR (c.status IN ('enriching','ready') AND
            (c.processing_token IS NULL OR c.lease_expires_at <= clock_timestamp()))
      )
      AND (p_origin_country IS NULL OR upper(COALESCE(b.origin_country, b.country, '')) = upper(p_origin_country))
      AND (p_platform_key IS NULL OR c.platform_key = p_platform_key)
      AND (NOT p_in_stock_only OR COALESCE(c.raw_product->>'inStock', c.raw_product->>'in_stock') = 'true')
    ORDER BY c.first_seen_at, c.id
    LIMIT p_limit
    FOR UPDATE OF c SKIP LOCKED
  ), claimed AS (
    UPDATE public.product_refresh_candidates c
    SET status = CASE
          WHEN c.status = 'ready' AND c.prepared_observation_revision = c.observation_revision
            AND c.enriched_product IS NOT NULL THEN 'ready'
          ELSE 'enriching'
        END,
        attempt_count = c.attempt_count + 1,
        processing_token = gen_random_uuid(),
        processing_observation_revision = c.observation_revision,
        processing_max_age_hours = p_max_age_hours,
        lease_expires_at = clock_timestamp() + interval '30 minutes',
        next_attempt_at = NULL
    FROM selected
    WHERE c.id = selected.id
    RETURNING c.*
  )
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', id::text, 'platform_key', platform_key, 'identity_key', identity_key,
    'product_url', product_url, 'raw_product', raw_product,
    'raw_observed_at', raw_observed_at, 'detected_brand', detected_brand,
    'matched_brand_node_id', matched_brand_node_id::text, 'status', status,
    'observation_revision', observation_revision::text,
    'processing_token', processing_token, 'lease_expires_at', lease_expires_at,
    'prepared_observation_revision', prepared_observation_revision::text,
    'enriched_product', enriched_product, 'normalization_result', normalization_result,
    'imported_product_id', imported_product_id::text, 'attempt_count', attempt_count,
    'last_error_code', last_error_code, 'updated_at', updated_at,
    'last_seen_at', last_seen_at, 'next_attempt_at', next_attempt_at
  ) ORDER BY first_seen_at, id), '[]'::jsonb)
  INTO v_result FROM claimed;
  RETURN v_result;
END
$$;

CREATE OR REPLACE FUNCTION public.heartbeat_product_refresh_candidate(p_id bigint, p_token uuid)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  IF p_id IS NULL OR p_token IS NULL THEN RETURN false; END IF;
  UPDATE public.product_refresh_candidates
  SET lease_expires_at = clock_timestamp() + interval '30 minutes'
  WHERE id = p_id AND processing_token = p_token
    AND lease_expires_at > clock_timestamp() AND status IN ('enriching','ready');
  RETURN FOUND;
END
$$;

CREATE OR REPLACE FUNCTION public.checkpoint_product_refresh_candidate(
  p_id bigint, p_token uuid, p_expected_revision bigint, p_prepared jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.product_refresh_candidates%ROWTYPE;
  v_prepared_observed_at timestamptz;
BEGIN
  IF p_id IS NULL OR p_token IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1
     OR jsonb_typeof(p_prepared) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_prepared->'normalization') IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'p_prepared must be a prepared envelope' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_row FROM public.product_refresh_candidates WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR v_row.processing_token IS DISTINCT FROM p_token
     OR v_row.lease_expires_at IS NULL OR v_row.lease_expires_at <= clock_timestamp()
     OR v_row.status NOT IN ('enriching','ready') THEN
    RETURN jsonb_build_object('outcome','lost_claim');
  END IF;
  IF v_row.observation_revision <> p_expected_revision
     OR v_row.processing_observation_revision <> p_expected_revision THEN
    RETURN jsonb_build_object('outcome','stale');
  END IF;
  IF v_row.raw_observed_at IS NULL OR v_row.raw_observed_at < clock_timestamp() -
       make_interval(hours => v_row.processing_max_age_hours) THEN
    UPDATE public.product_refresh_candidates SET status='awaiting_observation',
      processing_token=NULL, processing_observation_revision=NULL,
      processing_max_age_hours=NULL, lease_expires_at=NULL,
      last_error_code='observation_stale', last_error='source observation is missing or stale'
    WHERE id=p_id;
    RETURN jsonb_build_object('outcome','stale');
  END IF;
  BEGIN
    v_prepared_observed_at := (p_prepared->>'observed_at')::timestamptz;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RETURN jsonb_build_object('outcome','stale');
  END;
  IF v_prepared_observed_at IS NULL OR NOT isfinite(v_prepared_observed_at)
     OR v_prepared_observed_at < clock_timestamp() -
       make_interval(hours => v_row.processing_max_age_hours) THEN
    RETURN jsonb_build_object('outcome','stale');
  END IF;
  UPDATE public.product_refresh_candidates
  SET status = 'ready', enriched_product = p_prepared,
      prepared_observation_revision = p_expected_revision,
      normalization_result = p_prepared->'normalization',
      last_error = NULL, last_error_code = NULL
  WHERE id = p_id;
  RETURN jsonb_build_object('outcome','ready');
END
$$;

CREATE OR REPLACE FUNCTION public.finish_product_refresh_candidate_attempt(
  p_id bigint, p_token uuid, p_expected_revision bigint, p_outcome text,
  p_error_code text DEFAULT NULL, p_error_message text DEFAULT NULL,
  p_max_attempts integer DEFAULT 3
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.product_refresh_candidates%ROWTYPE;
  v_status text;
  v_attempt integer;
  v_refund boolean;
BEGIN
  IF p_id IS NULL OR p_token IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1
     OR p_outcome IS NULL
     OR p_outcome NOT IN ('retry','rejected','awaiting_observation','release','stale')
     OR p_max_attempts IS NULL OR p_max_attempts < 1 THEN
    RAISE EXCEPTION 'invalid finish outcome' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_row FROM public.product_refresh_candidates WHERE id = p_id FOR UPDATE;
  IF NOT FOUND OR v_row.processing_token IS DISTINCT FROM p_token
     OR v_row.lease_expires_at IS NULL OR v_row.lease_expires_at <= clock_timestamp() THEN
    RETURN jsonb_build_object('outcome','lost_claim');
  END IF;

  v_refund := p_outcome IN ('release','stale')
    OR v_row.observation_revision <> p_expected_revision
    OR v_row.processing_observation_revision <> p_expected_revision;
  v_attempt := GREATEST(v_row.attempt_count - CASE WHEN v_refund THEN 1 ELSE 0 END, 0);

  IF v_row.observation_revision <> p_expected_revision
     OR v_row.processing_observation_revision <> p_expected_revision
     OR p_outcome = 'stale' THEN
    v_status := CASE
      WHEN v_row.matched_brand_node_id IS NULL THEN 'brand_unmatched'
      WHEN v_row.raw_observed_at IS NULL
        OR v_row.raw_observed_at < clock_timestamp() - make_interval(hours => COALESCE(v_row.processing_max_age_hours,24))
        THEN 'awaiting_observation'
      ELSE 'discovered'
    END;
  ELSIF p_outcome = 'release' THEN
    v_status := CASE
      WHEN v_row.prepared_observation_revision = v_row.observation_revision AND v_row.enriched_product IS NOT NULL THEN 'ready'
      WHEN v_row.matched_brand_node_id IS NULL THEN 'brand_unmatched'
      ELSE 'discovered'
    END;
  ELSIF p_outcome = 'rejected' THEN
    v_status := 'rejected';
  ELSIF p_outcome = 'awaiting_observation' THEN
    v_status := 'awaiting_observation';
  ELSE
    v_status := CASE WHEN v_attempt >= p_max_attempts THEN 'blocked' ELSE 'failed' END;
  END IF;

  UPDATE public.product_refresh_candidates
  SET status = v_status, attempt_count = v_attempt,
      processing_token = NULL, processing_observation_revision = NULL,
      processing_max_age_hours = NULL, lease_expires_at = NULL,
      next_attempt_at = CASE
        WHEN p_outcome = 'retry' AND v_status = 'failed'
          THEN clock_timestamp() + CASE WHEN v_attempt <= 1 THEN interval '5 minutes' ELSE interval '10 minutes' END
        ELSE NULL
      END,
      last_error_code = CASE WHEN p_outcome IN ('release','stale') THEN NULL ELSE p_error_code END,
      last_error = CASE WHEN p_outcome IN ('release','stale') THEN NULL ELSE p_error_message END
  WHERE id = p_id;
  RETURN jsonb_build_object(
    'outcome', CASE
      WHEN v_row.observation_revision <> p_expected_revision
        OR v_row.processing_observation_revision <> p_expected_revision
        THEN 'stale'
      ELSE p_outcome
    END,
    'status',v_status,'attempt_count',v_attempt
  );
END
$$;

CREATE OR REPLACE FUNCTION public.publish_product_refresh_candidate(
  p_id bigint, p_token uuid, p_expected_revision bigint
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_row public.product_refresh_candidates%ROWTYPE;
  v_write jsonb;
  v_result jsonb;
  v_prepared_brand bigint;
  v_prepared_observed_at timestamptz;
BEGIN
  IF p_id IS NULL OR p_token IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1 THEN
    RAISE EXCEPTION 'invalid publish arguments' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_row FROM public.product_refresh_candidates WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome','lost_claim','product_id',NULL);
  END IF;
  IF v_row.status = 'imported' AND v_row.prepared_observation_revision = p_expected_revision
     AND v_row.imported_product_id IS NOT NULL THEN
    RETURN jsonb_build_object('outcome','imported','product_id',v_row.imported_product_id::text);
  END IF;
  IF v_row.processing_token IS DISTINCT FROM p_token OR v_row.lease_expires_at IS NULL
     OR v_row.lease_expires_at <= clock_timestamp() OR v_row.status NOT IN ('enriching','ready')
     OR v_row.prepared_observation_revision IS DISTINCT FROM v_row.observation_revision
     OR v_row.enriched_product IS NULL THEN
    RETURN jsonb_build_object('outcome','lost_claim','product_id',NULL);
  END IF;
  IF v_row.observation_revision <> p_expected_revision
     OR v_row.processing_observation_revision <> p_expected_revision
     OR v_row.prepared_observation_revision <> p_expected_revision THEN
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END IF;
  IF v_row.raw_observed_at IS NULL OR v_row.raw_observed_at < clock_timestamp() -
       make_interval(hours => v_row.processing_max_age_hours) THEN
    UPDATE public.product_refresh_candidates SET status='awaiting_observation',
      processing_token=NULL, processing_observation_revision=NULL,
      processing_max_age_hours=NULL, lease_expires_at=NULL,
      last_error_code='observation_stale', last_error='source observation is missing or stale'
    WHERE id=p_id;
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END IF;
  BEGIN
    v_prepared_observed_at := (v_row.enriched_product->>'observed_at')::timestamptz;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END;
  IF v_prepared_observed_at IS NULL OR NOT isfinite(v_prepared_observed_at)
     OR v_prepared_observed_at < clock_timestamp() -
       make_interval(hours => v_row.processing_max_age_hours) THEN
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END IF;
  BEGIN
    v_prepared_brand := (v_row.enriched_product->'product'->>'brand_node_id')::bigint;
  EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',NULL,'code','brand_mismatch');
  END;
  IF v_row.matched_brand_node_id IS NULL OR v_prepared_brand IS DISTINCT FROM v_row.matched_brand_node_id
     OR NOT EXISTS (SELECT 1 FROM public.brand_nodes WHERE id = v_row.matched_brand_node_id) THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',NULL,'code','brand_mismatch');
  END IF;
  IF v_row.enriched_product->'product'->>'product_url' IS DISTINCT FROM v_row.product_url THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',NULL,'code','product_identity_mismatch');
  END IF;

  v_write := public.upsert_prepared_products(jsonb_build_array(v_row.enriched_product));
  v_result := v_write->0;
  IF v_result->>'outcome' IN ('inserted','updated','unchanged') THEN
    UPDATE public.product_refresh_candidates
    SET status = 'imported', imported_product_id = (v_result->>'id')::bigint,
        processing_token = NULL, processing_observation_revision = NULL,
        processing_max_age_hours = NULL, lease_expires_at = NULL,
        next_attempt_at = NULL, last_error = NULL, last_error_code = NULL
    WHERE id = p_id;
    RETURN jsonb_build_object('outcome','imported','product_id',v_result->>'id');
  ELSIF v_result->>'outcome' = 'conflicted' THEN
    RETURN jsonb_build_object('outcome','conflicted','product_id',v_result->>'id','code',v_result->>'code');
  END IF;
  RETURN jsonb_build_object('outcome','rejected','product_id',v_result->>'id','code',v_result->>'code');
END
$$;

CREATE OR REPLACE FUNCTION public.publish_product_refresh_candidate_normalization(
  p_id bigint,
  p_token uuid,
  p_expected_revision bigint,
  p_product_id bigint,
  p_expected_updated_at timestamptz,
  p_normalization jsonb,
  p_category text,
  p_subcategory text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_candidate public.product_refresh_candidates%ROWTYPE;
  v_product public.products%ROWTYPE;
  v_completed_at timestamptz;
  v_subcategories constant jsonb := '{
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
  IF p_id IS NULL OR p_token IS NULL OR p_expected_revision IS NULL OR p_expected_revision < 1
     OR p_product_id IS NULL OR p_expected_updated_at IS NULL THEN
    RAISE EXCEPTION 'invalid normalization publish arguments' USING ERRCODE = '22023';
  END IF;
  SELECT * INTO v_candidate
  FROM public.product_refresh_candidates
  WHERE id = p_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome','lost_claim','product_id',NULL);
  END IF;
  IF v_candidate.status = 'imported'
     AND v_candidate.prepared_observation_revision = p_expected_revision
     AND v_candidate.imported_product_id = p_product_id THEN
    RETURN jsonb_build_object('outcome','imported','product_id',p_product_id::text);
  END IF;
  IF v_candidate.processing_token IS DISTINCT FROM p_token
     OR v_candidate.lease_expires_at IS NULL
     OR v_candidate.lease_expires_at <= clock_timestamp()
     OR v_candidate.status NOT IN ('enriching','ready') THEN
    RETURN jsonb_build_object('outcome','lost_claim','product_id',NULL);
  END IF;
  IF v_candidate.observation_revision <> p_expected_revision
     OR v_candidate.processing_observation_revision <> p_expected_revision THEN
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END IF;
  IF v_candidate.raw_observed_at IS NULL OR v_candidate.raw_observed_at < clock_timestamp() -
       make_interval(hours => v_candidate.processing_max_age_hours) THEN
    UPDATE public.product_refresh_candidates SET status='awaiting_observation',
      processing_token=NULL, processing_observation_revision=NULL,
      processing_max_age_hours=NULL, lease_expires_at=NULL,
      last_error_code='observation_stale', last_error='source observation is missing or stale'
    WHERE id=p_id;
    RETURN jsonb_build_object('outcome','stale','product_id',NULL);
  END IF;

  IF jsonb_typeof(p_normalization) IS DISTINCT FROM 'object'
     OR jsonb_typeof(p_normalization->'status') IS DISTINCT FROM 'string'
     OR p_normalization->>'status' NOT IN ('not_required','succeeded','unchanged')
     OR jsonb_typeof(p_normalization->'input_hash') IS DISTINCT FROM 'string'
     OR NULLIF(btrim(p_normalization->>'input_hash'),'') IS NULL
     OR jsonb_typeof(p_normalization->'policy_version') IS DISTINCT FROM 'string'
     OR NULLIF(btrim(p_normalization->>'policy_version'),'') IS NULL
     OR jsonb_typeof(p_normalization->'completed_at') IS DISTINCT FROM 'string'
     OR NOT (p_normalization ? 'model')
     OR (p_normalization->>'status' IN ('succeeded','unchanged')
         AND (jsonb_typeof(p_normalization->'model') IS DISTINCT FROM 'string'
              OR NULLIF(btrim(p_normalization->>'model'),'') IS NULL))
     OR (p_normalization->>'status' = 'not_required'
         AND jsonb_typeof(p_normalization->'model') NOT IN ('string','null')) THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',p_product_id::text,'code','normalization_unverified');
  END IF;
  BEGIN
    v_completed_at := (p_normalization->>'completed_at')::timestamptz;
  EXCEPTION WHEN invalid_datetime_format OR datetime_field_overflow THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',p_product_id::text,'code','normalization_unverified');
  END;
  IF NOT isfinite(v_completed_at)
     OR p_category IS NULL
     OR p_category NOT IN ('tops','knitwear','bottoms','dresses','outerwear','underwear','swimwear','activewear','shoes','bags','accessories','eyewear','jewelry','headwear','other')
     OR (NULLIF(btrim(p_subcategory),'') IS NOT NULL AND NOT (v_subcategories->p_category ? p_subcategory)) THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',p_product_id::text,'code','normalization_unverified');
  END IF;

  SELECT * INTO v_product FROM public.products WHERE id = p_product_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('outcome','conflicted','product_id',NULL,'code','product_missing');
  END IF;
  IF v_product.updated_at IS DISTINCT FROM p_expected_updated_at THEN
    RETURN jsonb_build_object('outcome','conflicted','product_id',p_product_id::text,'code','updated_at_conflict');
  END IF;
  IF v_product.product_url IS DISTINCT FROM v_candidate.product_url
     OR (v_candidate.imported_product_id IS NOT NULL
         AND v_candidate.imported_product_id IS DISTINCT FROM p_product_id) THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',p_product_id::text,'code','product_identity_mismatch');
  END IF;
  IF v_product.brand_node_id IS NULL
     OR v_candidate.matched_brand_node_id IS NULL
     OR v_product.brand_node_id <> v_candidate.matched_brand_node_id THEN
    RETURN jsonb_build_object('outcome','rejected','product_id',p_product_id::text,'code','brand_mismatch');
  END IF;

  IF ROW(v_product.category, v_product.subcategory)
     IS DISTINCT FROM ROW(p_category, NULLIF(btrim(p_subcategory),'')) THEN
    UPDATE public.products
    SET category = p_category,
        subcategory = NULLIF(btrim(p_subcategory),''),
        updated_at = clock_timestamp()
    WHERE id = p_product_id;
  END IF;

  UPDATE public.product_refresh_candidates
  SET status = 'imported',
      imported_product_id = p_product_id,
      normalization_result = p_normalization,
      prepared_observation_revision = p_expected_revision,
      processing_token = NULL,
      processing_observation_revision = NULL,
      processing_max_age_hours = NULL,
      lease_expires_at = NULL,
      next_attempt_at = NULL,
      last_error = NULL,
      last_error_code = NULL
  WHERE id = p_id;
  RETURN jsonb_build_object('outcome','imported','product_id',p_product_id::text);
END
$$;

REVOKE ALL ON FUNCTION public.product_refresh_meaningful_raw(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_product_refresh_observations(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_product_refresh_candidates_v2(integer,integer,text,text,boolean,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.heartbeat_product_refresh_candidate(bigint,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.checkpoint_product_refresh_candidate(bigint,uuid,bigint,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.finish_product_refresh_candidate_attempt(bigint,uuid,bigint,text,text,text,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_product_refresh_candidate(bigint,uuid,bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.publish_product_refresh_candidate_normalization(bigint,uuid,bigint,bigint,timestamptz,jsonb,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.upsert_product_refresh_observations(jsonb) TO app_user;
GRANT EXECUTE ON FUNCTION public.claim_product_refresh_candidates_v2(integer,integer,text,text,boolean,integer) TO app_user;
GRANT EXECUTE ON FUNCTION public.heartbeat_product_refresh_candidate(bigint,uuid) TO app_user;
GRANT EXECUTE ON FUNCTION public.checkpoint_product_refresh_candidate(bigint,uuid,bigint,jsonb) TO app_user;
GRANT EXECUTE ON FUNCTION public.finish_product_refresh_candidate_attempt(bigint,uuid,bigint,text,text,text,integer) TO app_user;
GRANT EXECUTE ON FUNCTION public.publish_product_refresh_candidate(bigint,uuid,bigint) TO app_user;
GRANT EXECUTE ON FUNCTION public.publish_product_refresh_candidate_normalization(bigint,uuid,bigint,bigint,timestamptz,jsonb,text,text) TO app_user;

COMMIT;
