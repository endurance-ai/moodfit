// @vitest-environment node

import type {Pool} from "pg"
import {afterAll, beforeAll, beforeEach, describe, expect, it} from "vitest"
import {createCandidateRepository} from "../../../crawler/src/lib/candidate-repository"
import {runCandidateWorker} from "../../../crawler/src/lib/candidate-worker"
import {prepareProductForImport} from "../../../crawler/src/lib/prepare-product-for-import"
import type {ClaimedProductRefreshCandidate} from "../../../crawler/src/lib/pipeline-integrity-types"
import type {Product, SiteConfig} from "../../../crawler/src/lib/types"
import {applyTaskMigrations, createPipelinePool, resetPipelineData} from "./helpers"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)
const config = {key: "js-shop", name: "JS Shop", type: "shopify", baseUrl: "https://shop.example", brand: "Raw Brand"} satisfies SiteConfig
const filters = {limit: 1, maxAttempts: 3, originCountry: "KR", platform: "js-shop", inStockOnly: false, maxAgeHours: 24}

const RPC_ARGS = {
  claim_product_refresh_candidates_v2: ["p_limit", "p_max_attempts", "p_origin_country", "p_platform_key", "p_in_stock_only", "p_max_age_hours"],
  heartbeat_product_refresh_candidate: ["p_id", "p_token"],
  checkpoint_product_refresh_candidate: ["p_id", "p_token", "p_expected_revision", "p_prepared"],
  finish_product_refresh_candidate_attempt: ["p_id", "p_token", "p_expected_revision", "p_outcome", "p_error_code", "p_error_message", "p_max_attempts"],
  publish_product_refresh_candidate: ["p_id", "p_token", "p_expected_revision"],
  publish_product_refresh_candidate_normalization: ["p_id", "p_token", "p_expected_revision", "p_product_id", "p_expected_updated_at", "p_normalization", "p_category", "p_subcategory"],
} as const

function pgBridge(pool: Pool) {
  return {
    async rpc(name: string, args: Record<string, unknown>) {
      const names = RPC_ARGS[name as keyof typeof RPC_ARGS]
      if (!names) return {data: null, error: {message: "unapproved RPC"}}
      const values = names.map((key) => {
        const value = args[key]
        return key === "p_prepared" || key === "p_normalization" ? JSON.stringify(value) : value
      })
      const casts = names.map((key, index) => `${key} => $${index + 1}${key === "p_prepared" || key === "p_normalization" ? "::jsonb" : ""}`)
      try {
        const result = await pool.query<{value: unknown}>(`SELECT public.${name}(${casts.join(",")}) AS value`, values)
        return {data: result.rows[0].value, error: null}
      } catch (error) {
        return {data: null, error: {message: error instanceof Error ? error.message : String(error)}}
      }
    },
    from(table: string) {
      if (table !== "products") throw new Error(`unapproved table ${table}`)
      let id = ""
      const builder = {
        select() { return builder },
        eq(_column: string, value: unknown) { id = String(value); return builder },
        async maybeSingle() {
          const result = await pool.query("SELECT updated_at::text,name,brand,category,subcategory,tags FROM products WHERE id=$1", [id])
          return {data: result.rows[0] ?? null, error: null}
        },
      }
      return builder
    },
  }
}

function rawProduct(observedAt: string, overrides: Partial<Product> = {}): Product {
  return {brand: "Raw Brand", name: "Archive item 001", category: "other", gender: ["women"],
    price: 80_000, originalPrice: 100_000, salePrice: 80_000,
    pricingObservation: {state: "sale", source: "detail", version: 2}, sourceCurrency: "KRW", sourcePrice: 80_000,
    priceFormatted: "₩80,000", imageUrl: "https://img.example/item.jpg", images: ["https://img.example/item.jpg"],
    productUrl: "https://shop.example/product/1", inStock: true, platform: "js-shop", crawledAt: observedAt,
    detailFetchedAt: observedAt, ...overrides}
}

async function seed(pool: Pool, observedAt: string, product = rawProduct(observedAt)) {
  const brandId = (await pool.query<{id: string}>("INSERT INTO brand_nodes(brand_name,origin_country) VALUES ('Canonical Brand','KR') RETURNING id")).rows[0].id
  await pool.query("INSERT INTO product_refresh_sources(platform_key,platform_type,base_url) VALUES ('js-shop','shopify','https://shop.example')")
  await pool.query("SELECT upsert_product_refresh_observations($1::jsonb)", [JSON.stringify([{platform_key: "js-shop", identity_key: "sku-1",
    product_url: product.productUrl, raw_product: product, detected_brand: "Canonical Brand", matched_brand_node_id: brandId,
    raw_observed_at: observedAt}])])
  return brandId
}

function workerDependencies(repository: ReturnType<typeof createCandidateRepository>, brandId: string) {
  return {
    repository,
    checkpointReusable: () => false,
    prepare: async (candidate: ClaimedProductRefreshCandidate) => {
      const result = await prepareProductForImport({product: candidate.raw_product as unknown as Product, config,
        observedAt: candidate.raw_observed_at!, expectedUpdatedAt: null}, {
        resolveBrand: () => ({status: "existing", brand: "Canonical Brand", brandNodeId: brandId}),
        normalize: async () => ({category: "outerwear", subcategory: "jacket", model: "qwen-fixture", completedAt: candidate.raw_observed_at!}),
        policyVersion: "integration-v1",
      })
      if (result.status !== "prepared") throw new Error(`unexpected preparation ${result.status}`)
      return {status: "prepared" as const, prepared: result.prepared}
    },
    setInterval: () => 1,
    clearInterval: () => undefined,
  }
}

describe.skipIf(!enabled)("crawler candidate repository/worker to SQL", () => {
  let pool: Pool
  beforeAll(async () => {
    pool = createPipelinePool()
    await applyTaskMigrations(pool, ["119_upsert_prepared_products.sql", "120_product_refresh_candidate_lifecycle.sql"])
  })
  beforeEach(async () => resetPipelineData(pool))
  afterAll(async () => pool?.end())

  it("publishes an actual T07 prepared envelope through repository RPC argument mapping", async () => {
    const observedAt = new Date().toISOString()
    const brandId = await seed(pool, observedAt)
    const repository = createCandidateRepository(pgBridge(pool) as never)
    const result = await runCandidateWorker({...filters, mode: "apply", budgetMs: 60_000}, workerDependencies(repository, brandId))
    expect(result).toMatchObject({claimed: 1, imported: 1, failed: 0})
    const row = (await pool.query("SELECT brand,brand_node_id::text,category,subcategory,crawled_at::text,last_seen_at::text,price,sale_price FROM products")).rows[0]
    expect(row).toMatchObject({brand: "Canonical Brand", brand_node_id: brandId, category: "outerwear", subcategory: "jacket", price: 80_000, sale_price: 80_000})
    expect(Date.parse(row.crawled_at)).toBe(Date.parse(observedAt))
    expect(row.last_seen_at).toBe(row.crawled_at)
  })

  it("normalizes an existing conflict without changing price, image, stock, or source timestamps", async () => {
    const oldAt = new Date(Date.now() - 60_000).toISOString()
    const brandId = await seed(pool, oldAt)
    const prepared = await prepareProductForImport({product: rawProduct(oldAt, {category: "tops", subcategory: "shirt"}), config,
      observedAt: oldAt, expectedUpdatedAt: null}, {resolveBrand: () => ({status: "existing", brand: "Canonical Brand", brandNodeId: brandId})})
    if (prepared.status !== "prepared") throw new Error("existing fixture did not prepare")
    const inserted = (await pool.query<{value: Array<{id: string}>}>("SELECT upsert_prepared_products($1::jsonb) AS value", [JSON.stringify([prepared.prepared])])).rows[0].value[0]
    const before = (await pool.query("SELECT price,sale_price,image_url,in_stock,crawled_at::text,last_seen_at::text FROM products WHERE id=$1", [inserted.id])).rows[0]

    const repository = createCandidateRepository(pgBridge(pool) as never)
    const deps = workerDependencies(repository, brandId)
    const result = await runCandidateWorker({...filters, mode: "apply", budgetMs: 60_000}, {...deps,
      normalizeCurrent: async () => ({normalization: {status: "succeeded", input_hash: "existing-hash", policy_version: "integration-v1",
        model: "qwen-fixture", completed_at: new Date().toISOString()}, category: "outerwear", subcategory: "jacket"})})
    expect(result.imported).toBe(1)
    const after = (await pool.query("SELECT price,sale_price,image_url,in_stock,crawled_at::text,last_seen_at::text,category,subcategory FROM products WHERE id=$1", [inserted.id])).rows[0]
    expect(after).toMatchObject({...before, category: "outerwear", subcategory: "jacket"})
  })

  it("reclaims an expired ready checkpoint and publishes it without preparing again", async () => {
    const observedAt = new Date().toISOString()
    const brandId = await seed(pool, observedAt)
    const repository = createCandidateRepository(pgBridge(pool) as never)
    await runCandidateWorker({...filters, mode: "apply", budgetMs: 0, signal: AbortSignal.abort()}, workerDependencies(repository, brandId))
    const candidate = (await pool.query("SELECT id::text,observation_revision::text FROM product_refresh_candidates")).rows[0]
    // Build a verified checkpoint with the real T07 adapter, then emulate a worker dying after checkpoint.
    const prepared = await prepareProductForImport({product: rawProduct(observedAt), config, observedAt, expectedUpdatedAt: null}, {
      resolveBrand: () => ({status: "existing", brand: "Canonical Brand", brandNodeId: brandId}),
      normalize: async () => ({category: "outerwear", subcategory: "jacket", model: "qwen-fixture", completedAt: observedAt}),
    })
    if (prepared.status !== "prepared") throw new Error("checkpoint fixture did not prepare")
    await pool.query("UPDATE product_refresh_candidates SET status='ready', enriched_product=$2::jsonb, normalization_result=$2::jsonb->'normalization', prepared_observation_revision=observation_revision, processing_observation_revision=observation_revision, processing_token=gen_random_uuid(), processing_max_age_hours=24, lease_expires_at=now()-interval '1 minute' WHERE id=$1", [candidate.id, JSON.stringify(prepared.prepared)])
    let prepareCalls = 0
    const result = await runCandidateWorker({...filters, mode: "apply", budgetMs: 60_000}, {
      ...workerDependencies(repository, brandId), checkpointReusable: (row) => row.status === "ready" && row.enriched_product !== null,
      prepare: async () => { prepareCalls++; throw new Error("checkpoint should be reused") },
    })
    expect(result).toMatchObject({claimed: 1, imported: 1, failed: 0})
    expect(prepareCalls).toBe(0)
  })

  it("keeps the latest observation when revision changes during preparation and refunds once", async () => {
    const firstAt = new Date(Date.now() - 60_000).toISOString()
    const brandId = await seed(pool, firstAt)
    const repository = createCandidateRepository(pgBridge(pool) as never)
    const nextAt = new Date().toISOString()
    const next = rawProduct(nextAt, {name: "Latest coherent item", inStock: false})
    const base = workerDependencies(repository, brandId)
    const result = await runCandidateWorker({...filters, mode: "apply", budgetMs: 60_000}, {...base,
      prepare: async (candidate) => {
        await pool.query("SELECT upsert_product_refresh_observations($1::jsonb)", [JSON.stringify([{platform_key: "js-shop", identity_key: "sku-1",
          product_url: next.productUrl, raw_product: next, detected_brand: "Canonical Brand", matched_brand_node_id: brandId,
          raw_observed_at: nextAt}])])
        return base.prepare(candidate)
      },
    })
    expect(result).toMatchObject({claimed: 1, stale: 1, imported: 0, failed: 0})
    const row = (await pool.query("SELECT raw_product,raw_observed_at,observation_revision::text,attempt_count,processing_token FROM product_refresh_candidates")).rows[0]
    expect(row.raw_product).toMatchObject({name: "Latest coherent item", inStock: false})
    expect(row.raw_observed_at.toISOString()).toBe(nextAt)
    expect(row.observation_revision).toBe("2")
    expect(row.attempt_count).toBe(0)
    expect(row.processing_token).toBeNull()
  })
})
