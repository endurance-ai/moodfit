// @vitest-environment node

import type {Pool} from "pg"
import {afterAll, beforeAll, beforeEach, describe, expect, it} from "vitest"
import {applyTaskMigrations, asRole, createPipelinePool, resetPipelineData} from "./helpers"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)
const observedAt = "2026-09-12T01:00:00.000Z"
const embeddingVector = `[1,${Array(767).fill("0").join(",")}]`

function prepared(url: string, brandNodeId: string, overrides: Record<string, unknown> = {}) {
  return {
    product: {
      brand: "Fixture Brand",
      brand_node_id: brandNodeId,
      name: "Prepared Jacket",
      price: 80000,
      original_price: 100000,
      sale_price: 80000,
      source_currency: "KRW",
      source_price: 80000,
      category: "outerwear",
      subcategory: "jacket",
      gender: ["unisex"],
      description: "Detailed description",
      image_url: "https://img.example/representative.jpg",
      source_image_url: "https://img.example/original.jpg",
      images: ["https://img.example/detail.jpg", "https://img.example/representative.jpg"],
      size_info: "One size",
      tags: ["jacket", "unisex"],
      product_code: "SKU-119",
      product_no: 119,
      product_url: url,
      platform: "fixture-shop",
      in_stock: true,
      sale_percentage: 20,
      gender_source: "detail",
      image_selection_kind: "product",
      image_selection_score: 99,
      image_selection_version: "selection-v1",
      image_selection_candidate_count: 3,
      image_selected_at: observedAt,
      ...overrides,
    },
    normalization: {
      status: "succeeded",
      input_hash: "sha256:fixture",
      policy_version: "taxonomy-v1",
      model: "qwen-fixture",
      completed_at: observedAt,
    },
    pricing_observation: {version: 2, state: "sale", source: "detail"},
    observed_at: observedAt,
    expected_updated_at: null,
  }
}

async function createBrand(pool: Pool): Promise<string> {
  const result = await pool.query<{id: string}>(
    "INSERT INTO brand_nodes (brand_name) VALUES ('Fixture Brand') RETURNING id",
  )
  return result.rows[0].id
}

async function write(pool: Pool, rows: unknown[]) {
  const result = await pool.query<{result: Array<Record<string, unknown>>}>(
    "SELECT public.upsert_prepared_products($1::jsonb) AS result",
    [JSON.stringify(rows)],
  )
  return result.rows[0].result
}

describe.skipIf(!enabled)("upsert_prepared_products", () => {
  let pool: Pool

  beforeAll(async () => {
    pool = createPipelinePool()
    await applyTaskMigrations(pool, ["119_upsert_prepared_products.sql"])
    const installed = (await pool.query<{installed: boolean}>(
      "SELECT to_regprocedure('public.bulk_update_product_embeddings_v2(jsonb)') IS NOT NULL AS installed",
    )).rows[0].installed
    if (!installed) await applyTaskMigrations(pool, [
      "110_product_image_health.sql", "111_product_image_repair_permissions.sql",
      "112_product_image_failure_permissions.sql", "121_product_image_provenance.sql",
    ])
  })
  beforeEach(async () => resetPipelineData(pool))
  afterAll(async () => pool?.end())

  it("persists all supported fields, gallery union, and a decimal string id", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/products/119"
    const result = await write(pool, [prepared(url, brandId)])
    expect(result).toEqual([{product_url: url, id: expect.stringMatching(/^\d+$/), outcome: "inserted"}])

    const stored = (await pool.query("SELECT * FROM products WHERE product_url=$1", [url])).rows[0]
    expect(stored).toMatchObject({
      brand: "Fixture Brand",
      brand_node_id: brandId,
      name: "Prepared Jacket",
      price: 80000,
      original_price: 100000,
      sale_price: 80000,
      source_currency: "KRW",
      source_price: "80000.00",
      category: "outerwear",
      subcategory: "jacket",
      gender: ["unisex"],
      description: "Detailed description",
      image_url: "https://img.example/representative.jpg",
      source_image_url: "https://img.example/original.jpg",
      size_info: "One size",
      tags: ["jacket", "unisex"],
      product_code: "SKU-119",
      product_no: 119,
      platform: "fixture-shop",
      in_stock: true,
      sale_percentage: 20,
      gender_source: "detail",
      image_selection_kind: "product",
      image_selection_score: 99,
      image_selection_version: "selection-v1",
      image_selection_candidate_count: 3,
    })
    expect(stored.images).toEqual([
      "https://img.example/representative.jpg",
      "https://img.example/detail.jpg",
    ])
    expect(stored.crawled_at.toISOString()).toBe(observedAt)
    expect(stored.last_seen_at.toISOString()).toBe(observedAt)
    expect(stored.image_selected_at.toISOString()).toBe(observedAt)
  })

  it.each([
    ["missing-brand", {brand_node_id: "999999"}, {}, "brand_not_found"],
    ["failed-normalization", {}, {normalization: {status: "failed"}}, "normalization_unverified"],
    ["unconfirmed-pricing", {}, {pricing_observation: {version: 1, state: "sale", source: "detail"}}, "pricing_unconfirmed"],
    ["incoherent-sale", {sale_price: 70000}, {}, "invalid_product"],
    ["noncanonical-category", {category: "coats"}, {}, "invalid_product"],
    ["noncanonical-subcategory", {subcategory: "coat-ish"}, {}, "invalid_product"],
    ["ambiguous-gender", {gender: ["men", "women"]}, {}, "invalid_product"],
    ["bad-gallery", {images: ["javascript:alert(1)"]}, {}, "invalid_array_item"],
    ["unknown-column", {secret_internal: "x"}, {}, "unknown_product_field"],
    ["null-required", {name: null}, {}, "invalid_field_type"],
    ["malformed-array", {tags: [7]}, {}, "invalid_array_item"],
    ["infinite-observation", {}, {observed_at: "infinity"}, "invalid_field_type"],
  ])("rejects %s without inserting", async (label, productOverrides, envelopeOverrides, code) => {
    const brandId = await createBrand(pool)
    const row = {
      ...prepared(`https://shop.example/${label}`, brandId, productOverrides),
      ...envelopeOverrides,
    }
    expect((await write(pool, [row]))[0]).toMatchObject({outcome: "rejected", code})
    const count = (await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count
    expect(count).toBe(0)
  })

  it("rejects every repeated product URL explicitly", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/duplicate"
    const result = await write(pool, [prepared(url, brandId), prepared(url, brandId)])
    expect(result).toHaveLength(2)
    expect(result.every((row) => row.outcome === "rejected" && row.code === "duplicate_product_url")).toBe(true)
    expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(0)
  })

  it("accepts explicit null optional arrays without treating JSON null as an array", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/null-arrays"
    expect((await write(pool, [prepared(url, brandId, {images: null, tags: null})]))[0].outcome)
      .toBe("inserted")
    const stored = (await pool.query("SELECT images, tags FROM products WHERE product_url=$1", [url])).rows[0]
    expect(stored.images).toEqual(["https://img.example/representative.jpg"])
    expect(stored.tags).toEqual([])
  })

  it("conflicts when a CAS update expects a row that does not exist", async () => {
    const brandId = await createBrand(pool)
    const row = {
      ...prepared("https://shop.example/missing-cas", brandId),
      expected_updated_at: observedAt,
    }
    expect((await write(pool, [row]))[0]).toMatchObject({
      outcome: "conflicted",
      code: "expected_row_missing",
    })
  })

  it("accepts a coherent regular price tuple", async () => {
    const brandId = await createBrand(pool)
    const row = {
      ...prepared("https://shop.example/regular", brandId, {
        price: 100000,
        original_price: 100000,
        sale_price: null,
        source_price: 100000,
        sale_percentage: null,
      }),
      pricing_observation: {version: 2, state: "regular", source: "api"},
    }
    expect((await write(pool, [row]))[0].outcome).toBe("inserted")
  })

  it("enforces insert-only, compare-and-swap, and source freshness", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/cas"
    await write(pool, [prepared(url, brandId)])
    const current = (await pool.query("SELECT updated_at::text AS updated_at FROM products WHERE product_url=$1", [url])).rows[0]

    expect((await write(pool, [prepared(url, brandId)]))[0]).toMatchObject({
      outcome: "conflicted",
      code: "insert_only_conflict",
    })
    const wrongCas = {
      ...prepared(url, brandId, {name: "Changed"}),
      expected_updated_at: "2026-09-11T00:00:00Z",
    }
    expect((await write(pool, [wrongCas]))[0]).toMatchObject({
      outcome: "conflicted",
      code: "updated_at_conflict",
    })
    const stale = {
      ...prepared(url, brandId, {name: "Old"}),
      observed_at: "2026-09-11T00:00:00Z",
      expected_updated_at: current.updated_at,
    }
    expect((await write(pool, [stale]))[0]).toMatchObject({
      outcome: "conflicted",
      code: "stale_observation",
    })
    expect((await pool.query("SELECT name FROM products WHERE product_url=$1", [url])).rows[0].name)
      .toBe("Prepared Jacket")
  })

  it("updates fields while retaining and deduplicating the gallery", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/gallery"
    await write(pool, [prepared(url, brandId)])
    const current = (await pool.query("SELECT updated_at::text AS updated_at FROM products WHERE product_url=$1", [url])).rows[0]
    const changed = {
      ...prepared(url, brandId, {
        name: "Updated Jacket",
        image_url: "https://img.example/new.jpg",
        images: ["https://img.example/new.jpg", "https://img.example/detail-2.jpg"],
      }),
      observed_at: "2026-09-12T02:00:00.000Z",
      expected_updated_at: current.updated_at,
    }
    expect((await write(pool, [changed]))[0].outcome).toBe("updated")
    const stored = (await pool.query("SELECT name, images FROM products WHERE product_url=$1", [url])).rows[0]
    expect(stored.name).toBe("Updated Jacket")
    expect(stored.images).toEqual([
      "https://img.example/new.jpg",
      "https://img.example/detail-2.jpg",
      "https://img.example/representative.jpg",
      "https://img.example/detail.jpg",
    ])
  })

  it("reports unchanged only for the same persisted snapshot and observation", async () => {
    const brandId = await createBrand(pool)
    const url = "https://shop.example/unchanged"
    await write(pool, [prepared(url, brandId)])
    const current = (await pool.query("SELECT updated_at::text AS updated_at FROM products WHERE product_url=$1", [url])).rows[0]
    const same = {...prepared(url, brandId), expected_updated_at: current.updated_at}
    expect((await write(pool, [same]))[0]).toMatchObject({outcome: "unchanged"})
  })

  it("propagates infrastructure errors and rolls back the item", async () => {
    const brandId = await createBrand(pool)
    await pool.query("CREATE FUNCTION pipeline_test_fail_product() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'injected' USING ERRCODE='XX000'; END $$")
    await pool.query("CREATE TRIGGER pipeline_test_fail_product BEFORE INSERT ON products FOR EACH ROW EXECUTE FUNCTION pipeline_test_fail_product()")
    try {
      await expect(write(pool, [prepared("https://shop.example/injected", brandId)]))
        .rejects.toThrow(/injected/)
      expect((await pool.query("SELECT count(*)::int AS count FROM products")).rows[0].count).toBe(0)
    } finally {
      await pool.query("DROP TRIGGER pipeline_test_fail_product ON products")
      await pool.query("DROP FUNCTION pipeline_test_fail_product()")
    }
  })

  it("allows app_user and denies ai_user", async () => {
    const brandId = await createBrand(pool)
    const client = await pool.connect()
    try {
      await client.query("BEGIN")
      await asRole(client, "app_user", async () => {
        const result = await client.query(
          "SELECT public.upsert_prepared_products($1::jsonb) AS result",
          [JSON.stringify([prepared("https://shop.example/role", brandId)])],
        )
        expect(result.rows[0].result[0].outcome).toBe("inserted")
      })
      await client.query("ROLLBACK")
      await client.query("BEGIN")
      await expect(
        asRole(client, "ai_user", () =>
          client.query("SELECT public.upsert_prepared_products('[]'::jsonb)"),
        ),
      ).rejects.toThrow(/permission denied/i)
      await client.query("ROLLBACK")
    } finally {
      client.release()
    }
  })

  it("serializes reversed multi-row conflict keys without deadlock", async () => {
    const brandId = await createBrand(pool)
    const one = await pool.connect()
    const two = await pool.connect()
    const rowsA = [
      prepared("https://shop.example/lock-a", brandId),
      prepared("https://shop.example/lock-b", brandId),
    ]
    const rowsB = [...rowsA].reverse()
    try {
      const [first, second] = await Promise.all([
        one.query<{result: Array<{outcome: string}>}>(
          "SELECT public.upsert_prepared_products($1::jsonb) AS result",
          [JSON.stringify(rowsA)],
        ),
        two.query<{result: Array<{outcome: string}>}>(
          "SELECT public.upsert_prepared_products($1::jsonb) AS result",
          [JSON.stringify(rowsB)],
        ),
      ])
      const outcomes = [...first.rows[0].result, ...second.rows[0].result].map((row) => row.outcome)
      expect(outcomes.filter((outcome) => outcome === "inserted")).toHaveLength(2)
      expect(outcomes.filter((outcome) => outcome === "conflicted")).toHaveLength(2)
    } finally {
      one.release()
      two.release()
    }
  })

  it("shares ID lock order with the embedding writer when URL order is reversed", async () => {
    const brandId = await createBrand(pool)
    const urlZ = "https://shop.example/z-first-id"
    const urlA = "https://shop.example/a-second-id"
    await write(pool, [prepared(urlZ, brandId), prepared(urlA, brandId)])
    const stored = (await pool.query<{id: string; product_url: string; updated_at: string; image_url: string; image_revision: string}>(
      "SELECT id::text,product_url,updated_at::text,image_url,image_revision::text FROM products ORDER BY id",
    )).rows
    expect(stored.map((row) => row.product_url)).toEqual([urlZ, urlA])

    const embedding = await pool.connect()
    const productWriter = await pool.connect()
    try {
      await embedding.query("BEGIN")
      await embedding.query("SET LOCAL lock_timeout='750ms'")
      await embedding.query("SELECT 1 FROM products WHERE id=$1 FOR UPDATE", [stored[0].id])

      await productWriter.query("BEGIN")
      await productWriter.query("SET LOCAL application_name='pipeline-119-lock-order-test'")
      const nextObserved = "2026-09-12T02:00:00.000Z"
      const rows = stored.map((row) => ({...prepared(row.product_url, brandId), observed_at: nextObserved,
        expected_updated_at: row.updated_at}))
      const pendingPrepared = productWriter.query(
        "SELECT public.upsert_prepared_products($1::jsonb) AS result",
        [JSON.stringify(rows)],
      )

      let blocked = false
      for (let attempt = 0; attempt < 50; attempt += 1) {
        const activity = await pool.query<{wait_event_type: string | null}>(
          "SELECT wait_event_type FROM pg_stat_activity WHERE application_name='pipeline-119-lock-order-test'",
        )
        if (activity.rows[0]?.wait_event_type === "Lock") { blocked = true; break }
        await new Promise((resolve) => setTimeout(resolve, 20))
      }
      expect(blocked).toBe(true)

      // Fixed migration 119 is waiting on id1 without holding id2, so this
      // transaction can retain id1 and acquire id2 in the shared ID order.
      const payload = stored.map((row) => ({id: row.id, embedding: embeddingVector, model: "lock-order-test",
        source_image_url: row.image_url, source_image_revision: row.image_revision}))
      const embedded = await embedding.query<{result: Array<{id: string; outcome: string}>}>(
        "SELECT public.bulk_update_product_embeddings_v2($1::jsonb) AS result",
        [JSON.stringify(payload)],
      )
      expect(embedded.rows[0].result).toEqual(stored.map((row) => ({id: row.id, outcome: "applied"})))
      await embedding.query("COMMIT")
      expect((await pendingPrepared).rows[0].result).toHaveLength(2)
      await productWriter.query("COMMIT")
    } finally {
      await embedding.query("ROLLBACK").catch(() => undefined)
      await productWriter.query("ROLLBACK").catch(() => undefined)
      embedding.release()
      productWriter.release()
    }
  })
})
