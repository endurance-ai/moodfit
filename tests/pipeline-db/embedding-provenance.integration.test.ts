// @vitest-environment node

import {afterAll, beforeAll, beforeEach, describe, expect, it} from "vitest"
import type {Client, Pool, PoolClient} from "pg"
import {
  applyTaskMigrations,
  asRole,
  createPipelinePool,
  openPipelineClient,
  resetPipelineData,
  withRollback,
} from "./helpers"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)
const imageA = "https://images.test/a.jpg"
const imageB = "https://images.test/b.jpg"
const vector = `[1,${Array(767).fill("0").join(",")}]`

async function insertProduct(pool: Pool, suffix: string, imageUrl: string | null = imageA): Promise<string> {
  const {rows} = await pool.query<{id: string}>(`
    INSERT INTO products (
      brand, name, price, category, gender, image_url, images,
      product_url, platform
    ) VALUES ('Test', $1, 10000, 'tops', ARRAY['unisex'], $2,
      CASE WHEN $2::text IS NULL THEN '{}'::text[] ELSE ARRAY[$2::text] END,
      $3, 'pipeline-test')
    RETURNING id::text
  `, [`Product ${suffix}`, imageUrl, `https://shop.test/${suffix}`])
  return rows[0].id
}

function embeddingPayload(id: string, url: string, revision: string) {
  return [{id, embedding: vector, model: "test-model", source_image_url: url, source_image_revision: revision}]
}

async function callV2(client: Client | Pool | PoolClient, payload: unknown) {
  const {rows} = await client.query<{result: Array<Record<string, string>>}>(
    "SELECT bulk_update_product_embeddings_v2($1::jsonb) AS result",
    [JSON.stringify(payload)],
  )
  return rows[0].result
}

describe.skipIf(!enabled)("image and embedding provenance", () => {
  let pool: Pool

  beforeAll(async () => {
    pool = createPipelinePool()
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

  it("increments only for the final sanitized representative and distinguishes A→B→A", async () => {
    const id = await insertProduct(pool, "revision")
    await pool.query("UPDATE products SET images = ARRAY[$2, $1] WHERE id = $3", [imageA, imageB, id])
    expect((await pool.query("SELECT image_revision::text AS revision FROM products WHERE id=$1", [id])).rows[0].revision).toBe("1")
    await pool.query("UPDATE products SET image_revision=999 WHERE id=$1", [id])
    expect((await pool.query("SELECT image_revision::text AS revision FROM products WHERE id=$1", [id])).rows[0].revision).toBe("1")

    await pool.query("UPDATE products SET image_url=$2 WHERE id=$1", [id, imageB])
    await pool.query("UPDATE products SET image_url=$2 WHERE id=$1", [id, imageA])
    const {rows} = await pool.query("SELECT image_url, image_revision::text AS revision, images FROM products WHERE id=$1", [id])
    expect(rows[0]).toMatchObject({image_url: imageA, revision: "3"})
    expect(rows[0].images[0]).toBe(imageA)

    await pool.query("UPDATE products SET image_url='javascript:bad' WHERE id=$1", [id])
    expect((await pool.query("SELECT image_url, image_revision::text AS revision FROM products WHERE id=$1", [id])).rows[0])
      .toEqual({image_url: null, revision: "4"})
  })

  it("applies matching provenance and returns stale or missing without writing", async () => {
    const id = await insertProduct(pool, "outcomes")
    expect(await callV2(pool, embeddingPayload(id, imageA, "1"))).toEqual([{id, outcome: "applied"}])
    expect(await callV2(pool, embeddingPayload(id, imageB, "1"))).toEqual([{id, outcome: "stale"}])
    expect(await callV2(pool, embeddingPayload("999999", imageA, "1"))).toEqual([{id: "999999", outcome: "missing"}])
    const stored = await pool.query("SELECT source_image_url, source_image_revision::text AS revision FROM product_embeddings WHERE product_id=$1", [id])
    expect(stored.rows[0]).toEqual({source_image_url: imageA, revision: "1"})
  })

  it("keeps unverifiable legacy vectors unstamped and rejects legacy v2 payloads", async () => {
    const id = await insertProduct(pool, "legacy")
    await pool.query(
      "INSERT INTO product_embeddings(product_id, embedding, embedding_model) VALUES ($1, $2::halfvec(768), 'legacy')",
      [id, vector],
    )
    expect((await pool.query("SELECT source_image_url, source_image_revision FROM product_embeddings WHERE product_id=$1", [id])).rows[0])
      .toEqual({source_image_url: null, source_image_revision: null})
    await expect(callV2(pool, [{id, embedding: vector, model: "legacy"}])).rejects.toThrow(/source_image_url/)
    await expect(callV2(pool, null)).rejects.toThrow(/JSON array/)
    await expect(pool.query(
      "UPDATE product_embeddings SET source_image_revision=1 WHERE product_id=$1",
      [id],
    )).rejects.toThrow(/chk_product_embeddings_source_provenance/)
  })

  it("deletes derived embeddings when the representative changes or is removed", async () => {
    const id = await insertProduct(pool, "delete")
    await callV2(pool, embeddingPayload(id, imageA, "1"))
    await pool.query("UPDATE products SET image_url=$2 WHERE id=$1", [id, imageB])
    expect((await pool.query("SELECT count(*)::int AS count FROM product_embeddings WHERE product_id=$1", [id])).rows[0].count).toBe(0)
    await callV2(pool, embeddingPayload(id, imageB, "2"))
    await pool.query("UPDATE products SET image_url=NULL WHERE id=$1", [id])
    expect((await pool.query("SELECT image_revision::text AS revision FROM products WHERE id=$1", [id])).rows[0].revision).toBe("3")
    expect((await pool.query("SELECT count(*)::int AS count FROM product_embeddings WHERE product_id=$1", [id])).rows[0].count).toBe(0)
  })

  it("locks reversed batches in stable product order", async () => {
    const first = await insertProduct(pool, "lock-1")
    const second = await insertProduct(pool, "lock-2")
    const clients = await Promise.all([openPipelineClient(), openPipelineClient()])
    try {
      const run = async (client: typeof clients[number], ids: string[]) => {
        await client.query("BEGIN")
        const result = await callV2(client, ids.map((id) => embeddingPayload(id, imageA, "1")[0]))
        await client.query("COMMIT")
        return result
      }
      const [forward, reverse] = await Promise.all([
        run(clients[0], [first, second]),
        run(clients[1], [second, first]),
      ])
      expect(forward.every((row) => row.outcome === "applied")).toBe(true)
      expect(reverse.every((row) => row.outcome === "applied")).toBe(true)
    } finally {
      await Promise.all(clients.map((client) => client.end()))
    }
  })

  it("returns repair provenance and rejects an embedding racing the repair", async () => {
    const id = await insertProduct(pool, "repair")
    const repairClient = await pool.connect()
    const embeddingClient = await pool.connect()
    try {
      await repairClient.query("BEGIN")
      const repaired = await repairClient.query<{result: Array<Record<string, string>>}>(
        "SELECT repair_product_image_assets_v2($1::jsonb) AS result",
        [JSON.stringify([{id, before_url: imageA, before_revision: "1", replacement_url: imageB, images: [imageB], bad_urls: [imageA]}])],
      )
      expect(repaired.rows[0].result).toEqual([{id, outcome: "applied", image_url: imageB, image_revision: "2"}])

      const racedWrite = callV2(embeddingClient, embeddingPayload(id, imageA, "1"))
      await repairClient.query("COMMIT")
      expect(await racedWrite).toEqual([{id, outcome: "stale"}])
      expect((await pool.query("SELECT count(*)::int AS count FROM product_embeddings WHERE product_id=$1", [id])).rows[0].count).toBe(0)

      const staleRepair = await pool.query<{result: Array<Record<string, string>>}>(
        "SELECT repair_product_image_assets_v2($1::jsonb) AS result",
        [JSON.stringify([{id, before_url: imageA, before_revision: "1", replacement_url: imageA, images: [imageA]}])],
      )
      expect(staleRepair.rows[0].result[0]).toMatchObject({id, outcome: "stale", image_url: imageB, image_revision: "2"})
    } finally {
      await repairClient.query("ROLLBACK").catch(() => undefined)
      repairClient.release()
      embeddingClient.release()
    }
  })

  it("keeps the legacy repair signature and scopes v2 execution by role", async () => {
    const signature = await pool.query<{present: boolean}>(
      "SELECT to_regprocedure('public.repair_product_image_assets(jsonb)') IS NOT NULL AS present",
    )
    expect(signature.rows[0].present).toBe(true)
    await withRollback(pool, async (client) => {
      expect(await asRole(client, "app_user", () => callV2(client, []))).toEqual([])
      expect(await asRole(client, "ai_user", () => callV2(client, []))).toEqual([])
      expect((await asRole(client, "app_user", () => client.query(
        "SELECT repair_product_image_assets_v2('[]'::jsonb) AS result",
      ))).rows[0].result).toEqual([])
      expect((await asRole(client, "ai_user", () => client.query(
        "SELECT repair_product_image_assets_v2('[]'::jsonb) AS result",
      ))).rows[0].result).toEqual([])
    })
  })

  it("applies the separate 123 gate to legacy and direct normal-role writes", async () => {
    await applyTaskMigrations(pool, ["123_gate_legacy_product_embedding_writes.sql"])
    const id = await insertProduct(pool, "gate")
    await withRollback(pool, async (client) => {
      await expect(asRole(client, "ai_user", () => client.query(
        "SELECT bulk_update_product_embeddings($1::jsonb)",
        [JSON.stringify([{id, embedding: vector, model: "legacy"}])],
      ))).rejects.toThrow(/permission denied/)
    })
    await withRollback(pool, async (client) => {
      await expect(asRole(client, "app_user", () => client.query(
        "INSERT INTO product_embeddings(product_id, embedding, embedding_model) VALUES ($1,$2::halfvec(768),'bypass')",
        [id, vector],
      ))).rejects.toThrow(/permission denied/)
    })
    await withRollback(pool, async (client) => {
      await expect(asRole(client, "ai_user", () => client.query(
        "INSERT INTO product_embeddings(product_id, embedding, embedding_model) VALUES ($1,$2::halfvec(768),'bypass')",
        [id, vector],
      ))).rejects.toThrow(/permission denied/)
    })
    await withRollback(pool, async (client) => {
      expect(await asRole(client, "ai_user", () => callV2(client, embeddingPayload(id, imageA, "1"))))
        .toEqual([{id, outcome: "applied"}])
    })
  })
})
