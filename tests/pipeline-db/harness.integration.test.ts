// @vitest-environment node

import {afterAll, beforeAll, describe, expect, it} from "vitest"
import {
  asRole,
  concurrencyBarrier,
  createPipelinePool,
  openPipelineClient,
  pipelineTestDatabaseUrl,
  resetPipelineData,
  withRollback,
} from "./helpers"
import type {Pool} from "pg"

const enabled = Boolean(process.env.PIPELINE_TEST_DATABASE_URL)

describe.skipIf(!enabled)("pipeline PostgreSQL fixture", () => {
  let pool: Pool

  beforeAll(async () => {
    pipelineTestDatabaseUrl()
    pool = createPipelinePool()
    await resetPipelineData(pool)
  })

  afterAll(async () => {
    await pool?.end()
  })

  it("uses bigint product and relation IDs after the 070 transition", async () => {
    const {rows} = await pool.query<{column_name: string; data_type: string}>(`
      SELECT column_name, data_type
      FROM information_schema.columns
      WHERE table_schema = 'public'
        AND (table_name, column_name) IN (
          ('products', 'id'),
          ('product_reviews', 'product_id'),
          ('product_embeddings', 'product_id'),
          ('product_refresh_candidates', 'imported_product_id')
        )
    `)
    expect(rows).toHaveLength(4)
    expect(rows.every((row) => row.data_type === "bigint")).toBe(true)
  })

  it("rolls back role-scoped writes", async () => {
    await withRollback(pool, async (client) => {
      await asRole(client, "app_user", async () => {
        await client.query("INSERT INTO brand_nodes (brand_name) VALUES ($1)", ["rollback-brand"])
      })
      expect((await client.query("SELECT count(*)::int AS count FROM brand_nodes")).rows[0].count).toBe(1)
    })
    expect((await pool.query("SELECT count(*)::int AS count FROM brand_nodes")).rows[0].count).toBe(0)
  })

  it("opens independent connections for concurrency tests", async () => {
    const clients = await Promise.all([openPipelineClient(), openPipelineClient()])
    const barrier = concurrencyBarrier(2)
    try {
      const backendPids = await Promise.all(clients.map(async (client) => {
        await client.query("BEGIN")
        await barrier()
        return (await client.query<{pid: number}>("SELECT pg_backend_pid() AS pid")).rows[0].pid
      }))
      expect(new Set(backendPids).size).toBe(2)
    } finally {
      await Promise.all(clients.map(async (client) => {
        await client.query("ROLLBACK").catch(() => undefined)
        await client.end()
      }))
    }
  })
})
