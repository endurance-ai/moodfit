// @vitest-environment node

import type {Pool} from "pg"
import {afterAll, beforeAll, beforeEach, describe, expect, it} from "vitest"
import {applyTaskMigrations, createPipelinePool, resetPipelineData} from "./helpers"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)
type Json = Record<string, unknown>

async function seed(pool: Pool) {
  const brandId = (await pool.query<{id: string}>(
    "INSERT INTO brand_nodes(brand_name,origin_country) VALUES ('Candidate Brand','KR') RETURNING id",
  )).rows[0].id
  await pool.query(
    "INSERT INTO product_refresh_sources(platform_key,platform_type,base_url) VALUES ('candidate-shop','cafe24','https://shop.example')",
  )
  return brandId
}

function observation(brandId: string | null, observedAt = new Date().toISOString(), overrides: Json = {}) {
  return {
    platform_key: "candidate-shop",
    identity_key: "sku-1",
    product_url: "https://shop.example/product/1",
    raw_product: {name: "Jacket", price: 80000, inStock: true, crawledAt: observedAt},
    detected_brand: "Candidate Brand",
    matched_brand_node_id: brandId,
    raw_observed_at: observedAt,
    ...overrides,
  }
}

async function observe(pool: Pool, rows: Json[]) {
  return (await pool.query<{result: Json}>(
    "SELECT upsert_product_refresh_observations($1::jsonb) AS result",
    [JSON.stringify(rows)],
  )).rows[0].result
}

async function claim(pool: Pool, overrides: {maxAttempts?: number; platform?: string | null} = {}) {
  const result = await pool.query<{result: Json[]}>(
    "SELECT claim_product_refresh_candidates_v2(200,$1,'KR',$2,false,24) AS result",
    [overrides.maxAttempts ?? 3, overrides.platform ?? "candidate-shop"],
  )
  return result.rows[0].result
}

async function insertExisting(
  pool: Pool,
  brandId: string,
  observedAt: string,
  productUrl = "https://shop.example/product/1",
) {
  const envelope = preparedEnvelope(brandId, observedAt)
  envelope.product.product_url = productUrl
  const result = await pool.query<{result: Array<{id: string}>}>(
    "SELECT upsert_prepared_products($1::jsonb) AS result",
    [JSON.stringify([envelope])],
  )
  const id = result.rows[0].result[0].id
  const updatedAt = (await pool.query<{updated_at: string}>(
    "SELECT updated_at::text AS updated_at FROM products WHERE id=$1",
    [id],
  )).rows[0].updated_at
  return {id, updatedAt}
}

function normalizationEvidence(): Json {
  return {
    status: "succeeded",
    input_hash: "current-product-hash",
    policy_version: "v1",
    model: "qwen-fixture",
    completed_at: new Date().toISOString(),
  }
}

async function publishNormalization(
  pool: Pool,
  candidate: Json,
  product: {id: string; updatedAt: string},
  norm: Json = normalizationEvidence(),
  category = "tops",
  subcategory: string | null = "shirt",
) {
  return (await pool.query<{result: Json}>(
    "SELECT publish_product_refresh_candidate_normalization($1,$2,$3,$4,$5,$6::jsonb,$7,$8) AS result",
    [
      candidate.id, candidate.processing_token, candidate.observation_revision,
      product.id, product.updatedAt, JSON.stringify(norm), category, subcategory,
    ],
  )).rows[0].result
}

function preparedEnvelope(brandId: string, observedAt: string) {
  return {
    product: {
      brand: "Candidate Brand", brand_node_id: brandId, name: "Jacket",
      price: 80000, original_price: 100000, sale_price: 80000,
      source_currency: "KRW", source_price: 80000, category: "outerwear",
      subcategory: "jacket", gender: ["unisex"],
      image_url: "https://img.example/jacket.jpg",
      images: ["https://img.example/jacket.jpg"],
      product_url: "https://shop.example/product/1", platform: "candidate-shop",
      in_stock: true, sale_percentage: 20,
    },
    normalization: {
      status: "succeeded", input_hash: "candidate-hash", policy_version: "v1",
      model: "qwen-fixture", completed_at: observedAt,
    },
    pricing_observation: {version: 2, state: "sale", source: "detail"},
    observed_at: observedAt,
    expected_updated_at: null,
  }
}

describe.skipIf(!enabled)("product refresh candidate lifecycle", () => {
  let pool: Pool
  beforeAll(async () => {
    pool = createPipelinePool()
    await applyTaskMigrations(pool, [
      "119_upsert_prepared_products.sql",
      "120_product_refresh_candidate_lifecycle.sql",
    ])
  })
  beforeEach(async () => resetPipelineData(pool))
  afterAll(async () => pool?.end())

  it("keeps observations monotonic, ignores volatile metadata, and detects equal-time conflicts", async () => {
    const brandId = await seed(pool)
    const firstAt = new Date(Date.now() - 60_000).toISOString()
    expect(await observe(pool, [observation(brandId, firstAt)])).toMatchObject({inserted: 1})
    const laterAt = new Date().toISOString()
    const counts = await observe(pool, [observation(brandId, laterAt)])
    expect(counts).toMatchObject({updated: 1})
    expect(
      Number(counts.inserted) + Number(counts.updated) + Number(counts.unchanged) +
      Number(counts.stale) + Number(counts.conflicted),
    ).toBe(1)
    expect(Number(counts.rematched)).toBeLessThanOrEqual(Number(counts.updated))
    let row = (await pool.query("SELECT * FROM product_refresh_candidates")).rows[0]
    expect(row.observation_revision).toBe("1")
    expect(row.raw_observed_at.toISOString()).toBe(laterAt)

    expect(await observe(pool, [observation(brandId, firstAt)])).toMatchObject({stale: 1})
    const changed = observation(brandId, laterAt, {raw_product: {name: "Different", price: 80000, inStock: true}})
    expect(await observe(pool, [changed])).toMatchObject({conflicted: 1})
    row = (await pool.query("SELECT raw_product, observation_revision FROM product_refresh_candidates")).rows[0]
    expect(row.raw_product.name).toBe("Jacket")
    expect(row.observation_revision).toBe("1")
  })

  it("rematches unmatched candidates and does not retain a false match on loss", async () => {
    const brandId = await seed(pool)
    const firstAt = new Date(Date.now() - 60_000).toISOString()
    await observe(pool, [observation(null, firstAt)])
    const rematched = await observe(pool, [observation(brandId, new Date().toISOString())])
    expect(rematched).toMatchObject({updated: 1, rematched: 1})
    expect((await pool.query("SELECT status,observation_revision FROM product_refresh_candidates")).rows[0])
      .toMatchObject({status: "discovered", observation_revision: "2"})

    await claim(pool)
    await observe(pool, [observation(null, new Date(Date.now() + 1000).toISOString())])
    const processing = (await pool.query(
      "SELECT status,matched_brand_node_id,processing_token,observation_revision,enriched_product FROM product_refresh_candidates",
    )).rows[0]
    expect(processing.status).toBe("enriching")
    expect(processing.matched_brand_node_id).toBeNull()
    expect(processing.processing_token).not.toBeNull()
    expect(processing.observation_revision).toBe("3")
    expect(processing.enriched_product).toBeNull()
  })

  it("claims once across concurrent workers and applies SQL filters", async () => {
    const brandId = await seed(pool)
    await observe(pool, [observation(brandId)])
    const [a, b] = await Promise.all([claim(pool), claim(pool)])
    expect(a.length + b.length).toBe(1)
    const claimed = [...a, ...b][0]
    expect(claimed.id).toMatch(/^\d+$/)
    expect(claimed.observation_revision).toBe("1")
    expect(claimed.matched_brand_node_id).toBe(brandId)
    expect(claimed.processing_token).toMatch(/^[0-9a-f-]{36}$/)
    expect(await claim(pool, {platform: "other-shop"})).toEqual([])
  })

  it("moves missing and stale observations to awaiting_observation", async () => {
    const brandId = await seed(pool)
    await observe(pool, [observation(brandId, null as unknown as string, {raw_observed_at: null})])
    expect(await claim(pool)).toEqual([])
    expect((await pool.query("SELECT status FROM product_refresh_candidates")).rows[0].status)
      .toBe("awaiting_observation")
  })

  it("rejects malformed observation batches atomically", async () => {
    const brandId = await seed(pool)
    await expect(observe(pool, [
      observation(brandId),
      observation(brandId, new Date().toISOString(), {identity_key: "sku-2", raw_product: []}),
    ])).rejects.toThrow(/invalid observation envelope/)
    expect((await pool.query("SELECT count(*)::int AS count FROM product_refresh_candidates")).rows[0].count)
      .toBe(0)
  })

  it("requires a live owned lease for heartbeat, checkpoint, and finish", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, observedAt)])
    await pool.query("UPDATE product_refresh_candidates SET attempt_count=2")
    const candidate = (await claim(pool))[0]
    expect(candidate.attempt_count).toBe(3)
    expect((await pool.query(
      "SELECT heartbeat_product_refresh_candidate($1,$2) AS ok",
      [candidate.id, candidate.processing_token],
    )).rows[0].ok).toBe(true)
    expect((await pool.query(
      "SELECT heartbeat_product_refresh_candidate($1,gen_random_uuid()) AS ok",
      [candidate.id],
    )).rows[0].ok).toBe(false)

    const checkpoint = (await pool.query<{result: Json}>(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb) AS result",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, observedAt))],
    )).rows[0].result
    expect(checkpoint).toEqual({outcome: "ready"})
    const lost = (await pool.query<{result: Json}>(
      "SELECT finish_product_refresh_candidate_attempt($1,gen_random_uuid(),$2,'release') AS result",
      [candidate.id, candidate.observation_revision],
    )).rows[0].result
    expect(lost).toEqual({outcome: "lost_claim"})

    const released = (await pool.query<{result: Json}>(
      "SELECT finish_product_refresh_candidate_attempt($1,$2,$3,'release') AS result",
      [candidate.id, candidate.processing_token, candidate.observation_revision],
    )).rows[0].result
    expect(released).toMatchObject({outcome: "release", status: "ready"})
    const reclaimed = (await claim(pool))[0]
    expect(reclaimed.id).toBe(candidate.id)
    expect(reclaimed.attempt_count).toBe(3)
    expect(reclaimed.enriched_product).not.toBeNull()
    expect((await pool.query<{result: Json}>(
      "SELECT publish_product_refresh_candidate($1,$2,$3) AS result",
      [reclaimed.id, reclaimed.processing_token, reclaimed.observation_revision],
    )).rows[0].result).toMatchObject({outcome: "imported"})
  })

  it("keeps claim maintenance inside the requested platform scope", async () => {
    const brandId = await seed(pool)
    await pool.query(
      "INSERT INTO product_refresh_sources(platform_key,platform_type,base_url) VALUES ('other-shop','cafe24','https://other.example')",
    )
    await observe(pool, [observation(brandId)])
    await observe(pool, [observation(brandId, new Date(Date.now() - 7200_000).toISOString(), {
      platform_key: "other-shop",
      identity_key: "other-sku",
      product_url: "https://other.example/product/1",
    })])
    await pool.query(
      "UPDATE product_refresh_candidates SET attempt_count=1 WHERE platform_key='other-shop'",
    )

    await claim(pool, {maxAttempts: 1, platform: "candidate-shop"})
    expect((await pool.query(
      "SELECT status,attempt_count FROM product_refresh_candidates WHERE platform_key='other-shop'",
    )).rows[0]).toMatchObject({status: "discovered", attempt_count: 1})
  })

  it("refunds an expired changed-revision attempt before aging clears its token", async () => {
    const brandId = await seed(pool)
    const oldObservedAt = new Date(Date.now() - 25 * 3600_000).toISOString()
    await observe(pool, [observation(brandId, oldObservedAt)])
    await pool.query(
      `UPDATE product_refresh_candidates SET status='enriching', attempt_count=3,
       observation_revision=2, processing_token=gen_random_uuid(),
       processing_observation_revision=1, processing_max_age_hours=24,
       lease_expires_at=clock_timestamp()-interval '1 second'`,
    )

    expect(await claim(pool, {maxAttempts: 3})).toEqual([])
    expect((await pool.query(
      "SELECT status,attempt_count,processing_token FROM product_refresh_candidates",
    )).rows[0]).toMatchObject({status: "awaiting_observation", attempt_count: 2, processing_token: null})

    await observe(pool, [observation(brandId, new Date().toISOString(), {
      raw_product: {name: "Fresh Jacket", price: 80000, inStock: true},
    })])
    const reclaimed = (await claim(pool, {maxAttempts: 3}))[0]
    expect(reclaimed.attempt_count).toBe(3)
  })

  it("invalidates an old revision and refunds a stale claim only once", async () => {
    const brandId = await seed(pool)
    await observe(pool, [observation(brandId, new Date(Date.now() - 1000).toISOString())])
    const candidate = (await claim(pool))[0]
    await observe(pool, [observation(brandId, new Date().toISOString(), {
      raw_product: {name: "New Jacket", price: 80000, inStock: true},
    })])
    const checkpoint = (await pool.query<{result: Json}>(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb) AS result",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, new Date().toISOString()))],
    )).rows[0].result
    expect(checkpoint).toEqual({outcome: "stale"})
    const finishSql = "SELECT finish_product_refresh_candidate_attempt($1,$2,$3,'stale') AS result"
    const first = (await pool.query<{result: Json}>(finishSql, [
      candidate.id, candidate.processing_token, candidate.observation_revision,
    ])).rows[0].result
    expect(first).toMatchObject({outcome: "stale", status: "discovered", attempt_count: 0})
    expect((await pool.query<{result: Json}>(finishSql, [
      candidate.id, candidate.processing_token, candidate.observation_revision,
    ])).rows[0].result).toEqual({outcome: "lost_claim"})
  })

  it("uses 5/10 minute retry backoff and blocks at max attempts", async () => {
    const brandId = await seed(pool)
    await observe(pool, [observation(brandId)])
    for (let expectedAttempt = 1; expectedAttempt <= 3; expectedAttempt += 1) {
      const candidate = (await claim(pool, {maxAttempts: 3}))[0]
      expect(candidate.attempt_count).toBe(expectedAttempt)
      const result = (await pool.query<{result: Json}>(
        "SELECT finish_product_refresh_candidate_attempt($1,$2,$3,'retry','qwen_failed','failed',3) AS result",
        [candidate.id, candidate.processing_token, candidate.observation_revision],
      )).rows[0].result
      if (expectedAttempt < 3) {
        expect(result).toMatchObject({status: "failed", attempt_count: expectedAttempt})
        await pool.query("UPDATE product_refresh_candidates SET next_attempt_at=clock_timestamp()-interval '1 second'")
      } else {
        expect(result).toMatchObject({status: "blocked", attempt_count: 3})
      }
    }
    expect(await claim(pool)).toEqual([])
    const before = (await pool.query(
      "SELECT attempt_count,observation_revision FROM product_refresh_candidates",
    )).rows[0]
    await observe(pool, [observation(brandId, new Date(Date.now() + 1000).toISOString(), {
      raw_product: {name: "Changed after block", price: 80000, inStock: true},
    })])
    const after = (await pool.query(
      "SELECT status,attempt_count,observation_revision FROM product_refresh_candidates",
    )).rows[0]
    expect(after.status).toBe("blocked")
    expect(after.attempt_count).toBe(before.attempt_count)
    expect(Number(after.observation_revision)).toBe(Number(before.observation_revision) + 1)
  })

  it("recovers an expired ready checkpoint but never revives an expired heartbeat", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, observedAt)])
    const candidate = (await claim(pool))[0]
    await pool.query(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb)",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, observedAt))],
    )
    await pool.query("UPDATE product_refresh_candidates SET lease_expires_at=clock_timestamp()-interval '1 second'")
    expect((await pool.query(
      "SELECT heartbeat_product_refresh_candidate($1,$2) AS ok",
      [candidate.id, candidate.processing_token],
    )).rows[0].ok).toBe(false)
    const recovered = (await claim(pool))[0]
    expect(recovered.enriched_product).not.toBeNull()
    expect(recovered.prepared_observation_revision).toBe("1")
    expect(recovered.processing_token).not.toBe(candidate.processing_token)
  })

  it("publishes product and candidate atomically and double publish is idempotent", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, observedAt)])
    const candidate = (await claim(pool))[0]
    await pool.query(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb)",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, observedAt))],
    )
    const sql = "SELECT publish_product_refresh_candidate($1,$2,$3) AS result"
    const first = (await pool.query<{result: Json}>(sql, [
      candidate.id, candidate.processing_token, candidate.observation_revision,
    ])).rows[0].result
    expect(first).toMatchObject({outcome: "imported", product_id: expect.stringMatching(/^\d+$/)})
    expect((await pool.query<{result: Json}>(sql, [
      candidate.id, candidate.processing_token, candidate.observation_revision,
    ])).rows[0].result).toEqual(first)
    expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(1)
  })

  it("refuses publishing when the claim's source-age bound expires", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, observedAt)])
    const candidate = (await claim(pool))[0]
    await pool.query(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb)",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, observedAt))],
    )
    await pool.query(
      "UPDATE product_refresh_candidates SET raw_observed_at=clock_timestamp()-interval '25 hours' WHERE id=$1",
      [candidate.id],
    )
    expect((await pool.query<{result: Json}>(
      "SELECT publish_product_refresh_candidate($1,$2,$3) AS result",
      [candidate.id, candidate.processing_token, candidate.observation_revision],
    )).rows[0].result).toMatchObject({outcome: "stale"})
    expect((await pool.query(
      "SELECT status,processing_token FROM product_refresh_candidates WHERE id=$1",
      [candidate.id],
    )).rows[0]).toMatchObject({status: "awaiting_observation", processing_token: null})
    expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(0)
  })

  it("never reuses an expired prepared observation after only the source clock advances", async () => {
    const brandId = await seed(pool)
    const oldObservedAt = new Date(Date.now() - 25 * 3600_000).toISOString()
    const freshObservedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, oldObservedAt)])
    await pool.query(
      `UPDATE product_refresh_candidates SET status='ready', attempt_count=1,
       enriched_product=$1::jsonb, normalization_result=$1::jsonb->'normalization',
       prepared_observation_revision=observation_revision,
       processing_token=gen_random_uuid(), processing_observation_revision=observation_revision,
       processing_max_age_hours=24, lease_expires_at=clock_timestamp()-interval '1 second'`,
      [JSON.stringify(preparedEnvelope(brandId, oldObservedAt))],
    )

    expect(await observe(pool, [observation(brandId, freshObservedAt)]))
      .toMatchObject({updated: 1})
    expect((await pool.query(
      "SELECT observation_revision::text FROM product_refresh_candidates",
    )).rows[0].observation_revision).toBe("1")
    const reclaimed = (await claim(pool))[0]
    expect(reclaimed.status).toBe("ready")
    expect((await pool.query<{result: Json}>(
      "SELECT publish_product_refresh_candidate($1,$2,$3) AS result",
      [reclaimed.id, reclaimed.processing_token, reclaimed.observation_revision],
    )).rows[0].result).toMatchObject({outcome: "stale"})
    expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(0)
  })

  it("rolls product insert back when candidate completion fails", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date().toISOString()
    await observe(pool, [observation(brandId, observedAt)])
    const candidate = (await claim(pool))[0]
    await pool.query(
      "SELECT checkpoint_product_refresh_candidate($1,$2,$3,$4::jsonb)",
      [candidate.id, candidate.processing_token, candidate.observation_revision,
        JSON.stringify(preparedEnvelope(brandId, observedAt))],
    )
    await pool.query("CREATE FUNCTION pipeline_fail_imported() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.status='imported' THEN RAISE EXCEPTION 'candidate completion failed' USING ERRCODE='XX000'; END IF; RETURN NEW; END $$")
    await pool.query("CREATE TRIGGER pipeline_fail_imported BEFORE UPDATE ON product_refresh_candidates FOR EACH ROW EXECUTE FUNCTION pipeline_fail_imported()")
    try {
      await expect(pool.query(
        "SELECT publish_product_refresh_candidate($1,$2,$3)",
        [candidate.id, candidate.processing_token, candidate.observation_revision],
      )).rejects.toThrow(/candidate completion failed/)
      expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(0)
    } finally {
      await pool.query("DROP TRIGGER pipeline_fail_imported ON product_refresh_candidates")
      await pool.query("DROP FUNCTION pipeline_fail_imported()")
    }
  })

  it("conditionally normalizes an existing product and preserves all other fields", async () => {
    const brandId = await seed(pool)
    const productObservedAt = new Date(Date.now() - 1000).toISOString()
    const product = await insertExisting(pool, brandId, productObservedAt)
    const before = (await pool.query("SELECT * FROM products WHERE id=$1", [product.id])).rows[0]
    await observe(pool, [observation(brandId)])
    const candidate = (await claim(pool))[0]
    expect(await publishNormalization(pool, candidate, product)).toEqual({
      outcome: "imported",
      product_id: product.id,
    })
    const after = (await pool.query("SELECT * FROM products WHERE id=$1", [product.id])).rows[0]
    expect(after.category).toBe("tops")
    expect(after.subcategory).toBe("shirt")
    for (const key of Object.keys(before)) {
      if (!["category", "subcategory", "updated_at"].includes(key)) {
        expect(after[key]).toEqual(before[key])
      }
    }
    expect(await publishNormalization(pool, candidate, product)).toEqual({
      outcome: "imported",
      product_id: product.id,
    })
  })

  it("guards existing normalization by claim, revision, CAS, brand, and evidence", async () => {
    const brandId = await seed(pool)
    const product = await insertExisting(pool, brandId, new Date(Date.now() - 1000).toISOString())
    await observe(pool, [observation(brandId)])
    const candidate = (await claim(pool))[0]

    expect(await publishNormalization(
      pool, {...candidate, processing_token: "00000000-0000-0000-0000-000000000000"}, product,
    )).toMatchObject({outcome: "lost_claim"})
    expect(await publishNormalization(
      pool, {...candidate, observation_revision: "99"}, product,
    )).toMatchObject({outcome: "stale"})
    expect(await publishNormalization(
      pool, candidate, {...product, updatedAt: "2026-01-01T00:00:00Z"},
    )).toMatchObject({outcome: "conflicted", code: "updated_at_conflict"})
    expect(await publishNormalization(
      pool, candidate, product, {status: "failed"},
    )).toMatchObject({outcome: "rejected", code: "normalization_unverified"})

    const otherBrand = (await pool.query<{id: string}>(
      "INSERT INTO brand_nodes(brand_name) VALUES ('Other Brand') RETURNING id",
    )).rows[0].id
    await pool.query("UPDATE products SET brand_node_id=$1 WHERE id=$2", [otherBrand, product.id])
    const changedAt = (await pool.query<{updated_at: string}>(
      "SELECT updated_at::text AS updated_at FROM products WHERE id=$1",
      [product.id],
    )).rows[0].updated_at
    expect(await publishNormalization(pool, candidate, {id: product.id, updatedAt: changedAt}))
      .toMatchObject({outcome: "rejected", code: "brand_mismatch"})
  })

  it("rejects a legacy imported product ID when its URL belongs to another product", async () => {
    const brandId = await seed(pool)
    const observedAt = new Date(Date.now() - 1000).toISOString()
    const wrongProduct = await insertExisting(
      pool,
      brandId,
      observedAt,
      "https://shop.example/product/different",
    )
    await observe(pool, [observation(brandId)])
    await pool.query(
      "UPDATE product_refresh_candidates SET imported_product_id=$1 WHERE identity_key='sku-1'",
      [wrongProduct.id],
    )
    const candidate = (await claim(pool))[0]

    expect(await publishNormalization(pool, candidate, wrongProduct))
      .toMatchObject({outcome: "rejected", code: "product_identity_mismatch"})
    expect((await pool.query(
      "SELECT category,subcategory FROM products WHERE id=$1",
      [wrongProduct.id],
    )).rows[0]).toMatchObject({category: "outerwear", subcategory: "jacket"})
  })

  it("rolls existing category update back when candidate completion fails", async () => {
    const brandId = await seed(pool)
    const product = await insertExisting(pool, brandId, new Date(Date.now() - 1000).toISOString())
    await observe(pool, [observation(brandId)])
    const candidate = (await claim(pool))[0]
    await pool.query("CREATE FUNCTION pipeline_fail_existing_import() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.status='imported' THEN RAISE EXCEPTION 'existing completion failed' USING ERRCODE='XX000'; END IF; RETURN NEW; END $$")
    await pool.query("CREATE TRIGGER pipeline_fail_existing_import BEFORE UPDATE ON product_refresh_candidates FOR EACH ROW EXECUTE FUNCTION pipeline_fail_existing_import()")
    try {
      await expect(publishNormalization(pool, candidate, product)).rejects.toThrow(/existing completion failed/)
      expect((await pool.query("SELECT category FROM products WHERE id=$1", [product.id])).rows[0].category)
        .toBe("outerwear")
    } finally {
      await pool.query("DROP TRIGGER pipeline_fail_existing_import ON product_refresh_candidates")
      await pool.query("DROP FUNCTION pipeline_fail_existing_import()")
    }
  })

  it("uses product CAS when two candidates normalize the same current row", async () => {
    const brandId = await seed(pool)
    const product = await insertExisting(pool, brandId, new Date(Date.now() - 1000).toISOString())
    const now = new Date().toISOString()
    await observe(pool, [
      observation(brandId, now),
      observation(brandId, now, {identity_key: "sku-2"}),
    ])
    const candidates = await claim(pool)
    expect(candidates).toHaveLength(2)
    const results = await Promise.all([
      publishNormalization(pool, candidates[0], product, normalizationEvidence(), "tops", "shirt"),
      publishNormalization(pool, candidates[1], product, normalizationEvidence(), "bottoms", "pants"),
    ])
    expect(results.filter((result) => result.outcome === "imported")).toHaveLength(1)
    expect(results.filter(
      (result) => result.outcome === "conflicted" && result.code === "updated_at_conflict",
    )).toHaveLength(1)
  })
})
