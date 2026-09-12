// @vitest-environment node
import {afterAll, beforeAll, beforeEach, describe, expect, it} from "vitest"
import type {Pool, PoolClient} from "pg"
import {applyTaskMigrations, asRole, createPipelinePool, resetPipelineData, withRollback} from "./helpers"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)
const oldTime = "2026-09-10T00:00:00.000Z"
const newTime = "2026-09-11T00:00:00.000Z"
const reviews = [{text: "Good fit", author: "A", review_date: "2026-09-10", photo_urls: [], body_info: {height: "170", weight: null}}]

async function replace(client: Pool | PoolClient, id: string, observedAt: string, snapshot: unknown) {
  return (await client.query("SELECT replace_product_reviews($1,$2,$3::jsonb) AS result", [id, observedAt, JSON.stringify(snapshot)])).rows[0].result
}

describe.skipIf(!enabled)("atomic review replacement", () => {
  let pool: Pool
  let id: string
  beforeAll(async () => {
    pool = createPipelinePool()
    await applyTaskMigrations(pool, ["122_replace_product_reviews.sql"])
  })
  beforeEach(async () => {
    await resetPipelineData(pool)
    id = (await pool.query("INSERT INTO products(brand,name,price,gender,product_url,platform) VALUES ('Test','Test',10000,ARRAY['unisex'],'https://shop.test/reviews','test') RETURNING id::text")).rows[0].id
  })
  afterAll(async () => pool?.end())

  it("stores actual count, preserves idempotent rows, rejects stale and equal-time conflicts", async () => {
    expect(await replace(pool, id, oldTime, reviews)).toEqual({outcome: "applied", product_id: id, review_count: 1})
    const reviewId = (await pool.query("SELECT id FROM product_reviews WHERE product_id=$1", [id])).rows[0].id
    expect(await replace(pool, id, oldTime, reviews)).toMatchObject({outcome: "unchanged", review_count: 1})
    expect((await pool.query("SELECT id FROM product_reviews WHERE product_id=$1", [id])).rows[0].id).toBe(reviewId)
    expect(await replace(pool, id, oldTime, [{text: "Different"}])).toMatchObject({outcome: "stale"})
    expect(await replace(pool, id, "2026-09-09T00:00:00Z", [])).toMatchObject({outcome: "stale"})
    expect(await replace(pool, id, newTime, [])).toMatchObject({outcome: "applied", review_count: 0})
    expect((await pool.query("SELECT review_count, reviews_observed_at FROM products WHERE id=$1", [id])).rows[0]).toEqual({review_count: 0, reviews_observed_at: new Date(newTime)})
    expect(await replace(pool, "999999", newTime, reviews)).toMatchObject({outcome: "missing", review_count: 0})
  })

  it("validates the whole snapshot and rolls back a failure after deletion", async () => {
    await replace(pool, id, oldTime, reviews)
    for (const invalid of [null, [{text: "valid"}, {text: 42}], [{text: ""}], [{photo_urls: ["javascript:bad"]}], [{text: "x", body_info: {height: 42}}]]) {
      await expect(replace(pool, id, newTime, invalid)).rejects.toThrow()
    }
    await pool.query(`CREATE FUNCTION public.pipeline_test_review_failure() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN IF NEW.text = 'injected failure' THEN RAISE EXCEPTION 'test insert failure'; END IF; RETURN NEW; END $$;
      CREATE TRIGGER pipeline_test_review_failure BEFORE INSERT ON public.product_reviews FOR EACH ROW EXECUTE FUNCTION public.pipeline_test_review_failure();`)
    try {
      await expect(replace(pool, id, newTime, [{text: "injected failure"}])).rejects.toThrow(/test insert failure/)
      expect((await pool.query("SELECT text FROM product_reviews WHERE product_id=$1", [id])).rows).toEqual([{text: "Good fit"}])
      expect((await pool.query("SELECT review_count, reviews_observed_at FROM products WHERE id=$1", [id])).rows[0]).toEqual({review_count: 1, reviews_observed_at: new Date(oldTime)})
    } finally {
      await pool.query("DROP TRIGGER pipeline_test_review_failure ON public.product_reviews; DROP FUNCTION public.pipeline_test_review_failure()")
    }
  })

  it("serializes concurrent snapshots with the newer observation winning in either lock order", async () => {
    for (const firstTime of [oldTime, newTime]) {
      await pool.query("UPDATE products SET reviews_observed_at=NULL WHERE id=$1", [id])
      const first = await pool.connect()
      const second = await pool.connect()
      try {
        await first.query("BEGIN")
        await replace(first, id, firstTime, [{text: firstTime === oldTime ? "old" : "new"}])
        const secondTime = firstTime === oldTime ? newTime : oldTime
        const raced = replace(second, id, secondTime, [{text: secondTime === oldTime ? "old" : "new"}])
        await first.query("COMMIT")
        expect((await raced).outcome).toBe(firstTime === oldTime ? "applied" : "stale")
        expect((await pool.query("SELECT text FROM product_reviews WHERE product_id=$1", [id])).rows).toEqual([{text: "new"}])
      } finally {
        await first.query("ROLLBACK").catch(() => undefined)
        first.release()
        second.release()
      }
    }
  })

  it("permits app_user and denies unrelated ai_user writes through the RPC", async () => {
    await withRollback(pool, async (client) => {
      expect(await asRole(client, "app_user", () => replace(client, id, oldTime, reviews))).toMatchObject({outcome: "applied"})
      await expect(asRole(client, "ai_user", () => replace(client, id, oldTime, reviews))).rejects.toThrow(/permission denied/)
    })
  })
})
