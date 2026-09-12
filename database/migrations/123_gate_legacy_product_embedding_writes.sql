-- Post-rollout gate: apply only after every embedding caller uses the v2 RPC.
BEGIN;

REVOKE ALL ON FUNCTION public.bulk_update_product_embeddings(jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.bulk_update_product_embeddings(jsonb) FROM app_user, ai_user;

REVOKE INSERT, UPDATE, DELETE ON public.product_embeddings FROM app_user, ai_user;
GRANT SELECT ON public.product_embeddings TO app_user, ai_user;
GRANT EXECUTE ON FUNCTION public.bulk_update_product_embeddings_v2(jsonb) TO app_user, ai_user;

COMMENT ON FUNCTION public.bulk_update_product_embeddings(jsonb) IS
  'RETIRED after v2 caller rollout. Normal roles cannot execute this provenance-free writer.';

COMMIT;
