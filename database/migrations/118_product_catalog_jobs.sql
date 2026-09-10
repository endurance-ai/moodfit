-- Durable, generation-fenced work queue for product image-derived catalog data.

BEGIN;

CREATE TABLE IF NOT EXISTS public.product_catalog_jobs (
  product_id       bigint PRIMARY KEY REFERENCES public.products(id) ON DELETE CASCADE,
  platform         text NOT NULL,
  generation       bigint NOT NULL DEFAULT 1 CHECK (generation > 0),
  status           text NOT NULL DEFAULT 'pending'
                   CHECK (status IN ('pending', 'processing', 'retry', 'complete', 'quarantined')),
  attempts         integer NOT NULL DEFAULT 0 CHECK (attempts >= 0),
  available_at     timestamptz NOT NULL DEFAULT now(),
  lease_expires_at timestamptz,
  last_error       text,
  requested_at     timestamptz NOT NULL DEFAULT now(),
  started_at       timestamptz,
  completed_at     timestamptz,
  updated_at       timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_product_catalog_jobs_claim
  ON public.product_catalog_jobs (status, available_at, requested_at)
  WHERE status IN ('pending', 'retry', 'processing');

CREATE OR REPLACE FUNCTION public.enqueue_product_catalog_job()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF TG_OP = 'UPDATE' AND NOT (
    OLD.platform                IS DISTINCT FROM NEW.platform OR
    OLD.brand_node_id           IS DISTINCT FROM NEW.brand_node_id OR
    OLD.brand                   IS DISTINCT FROM NEW.brand OR
    OLD.name                    IS DISTINCT FROM NEW.name OR
    OLD.category                IS DISTINCT FROM NEW.category OR
    OLD.product_code            IS DISTINCT FROM NEW.product_code OR
    OLD.image_url               IS DISTINCT FROM NEW.image_url OR
    OLD.images                  IS DISTINCT FROM NEW.images OR
    OLD.image_selection_version IS DISTINCT FROM NEW.image_selection_version OR
    OLD.image_selected_at       IS DISTINCT FROM NEW.image_selected_at
  ) THEN
    RETURN NEW;
  END IF;

  INSERT INTO public.product_catalog_jobs (product_id, platform)
  VALUES (NEW.id, NEW.platform)
  ON CONFLICT (product_id) DO UPDATE
  SET platform = EXCLUDED.platform,
      generation = product_catalog_jobs.generation + 1,
      status = 'pending',
      attempts = 0,
      available_at = now(),
      lease_expires_at = NULL,
      last_error = NULL,
      requested_at = now(),
      completed_at = NULL,
      updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_products_enqueue_catalog_job ON public.products;
CREATE TRIGGER trg_products_enqueue_catalog_job
AFTER INSERT OR UPDATE OF
  platform, brand_node_id, brand, name, category, product_code,
  image_url, images, image_selection_version, image_selected_at
ON public.products
FOR EACH ROW EXECUTE FUNCTION public.enqueue_product_catalog_job();

CREATE OR REPLACE FUNCTION public.claim_product_catalog_jobs(
  p_limit integer DEFAULT 100,
  p_platforms text[] DEFAULT NULL,
  p_lease_seconds integer DEFAULT 7200
)
RETURNS SETOF public.product_catalog_jobs
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN QUERY
  WITH candidates AS (
    SELECT j.product_id
    FROM public.product_catalog_jobs j
    WHERE (
      j.status IN ('pending', 'retry') AND j.available_at <= now()
      OR j.status = 'processing' AND j.lease_expires_at < now()
    )
      AND (p_platforms IS NULL OR j.platform = ANY(p_platforms))
    ORDER BY j.requested_at, j.product_id
    FOR UPDATE SKIP LOCKED
    LIMIT greatest(1, least(coalesce(p_limit, 100), 1000))
  )
  UPDATE public.product_catalog_jobs j
  SET status = 'processing',
      attempts = j.attempts + 1,
      started_at = now(),
      lease_expires_at = now() + make_interval(secs => greatest(60, p_lease_seconds)),
      updated_at = now()
  FROM candidates c
  WHERE j.product_id = c.product_id
  RETURNING j.*;
END;
$$;

CREATE OR REPLACE FUNCTION public.complete_product_catalog_job(
  p_product_id bigint,
  p_generation bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
  UPDATE public.product_catalog_jobs
  SET status = 'complete', lease_expires_at = NULL, last_error = NULL,
      completed_at = now(), updated_at = now()
  WHERE product_id = p_product_id
    AND generation = p_generation
    AND status = 'processing';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END;
$$;

CREATE OR REPLACE FUNCTION public.retry_product_catalog_job(
  p_product_id bigint,
  p_generation bigint,
  p_error text,
  p_max_attempts integer DEFAULT 3
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE n integer;
BEGIN
  UPDATE public.product_catalog_jobs
  SET status = CASE WHEN attempts >= greatest(1, p_max_attempts) THEN 'quarantined' ELSE 'retry' END,
      available_at = now() + make_interval(secs => least(3600, 60 * greatest(1, attempts))),
      lease_expires_at = NULL,
      last_error = left(coalesce(p_error, 'unknown catalog pipeline failure'), 2000),
      updated_at = now()
  WHERE product_id = p_product_id
    AND generation = p_generation
    AND status = 'processing';
  GET DIAGNOSTICS n = ROW_COUNT;
  RETURN n = 1;
END;
$$;

REVOKE ALL ON FUNCTION public.enqueue_product_catalog_job() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.claim_product_catalog_jobs(integer, text[], integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.complete_product_catalog_job(bigint, bigint) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.retry_product_catalog_job(bigint, bigint, text, integer) FROM PUBLIC;

GRANT SELECT ON public.product_catalog_jobs TO app_user;
GRANT EXECUTE ON FUNCTION public.claim_product_catalog_jobs(integer, text[], integer) TO app_user;
GRANT EXECUTE ON FUNCTION public.complete_product_catalog_job(bigint, bigint) TO app_user;
GRANT EXECUTE ON FUNCTION public.retry_product_catalog_job(bigint, bigint, text, integer) TO app_user;

NOTIFY pgrst, 'reload schema';

COMMIT;
