// @vitest-environment node

import {readFile} from "node:fs/promises"
import {resolve, sep} from "node:path"
import {Client, Pool, type PoolClient, type QueryResult} from "pg"

export type PipelineRole = "app_user" | "ai_user"

const repoRoot = resolve(import.meta.dirname, "../..")
const migrationsRoot = resolve(repoRoot, "database/migrations")
const fixturePath = resolve(repoRoot, "database/tests/pipeline-db-fixture.sql")

export function pipelineTestDatabaseUrl(): string {
  const raw = process.env.PIPELINE_TEST_DATABASE_URL
  if (!raw) throw new Error("PIPELINE_TEST_DATABASE_URL is required; no database URL fallback is allowed")

  let url: URL
  try {
    url = new URL(raw)
  } catch {
    throw new Error("PIPELINE_TEST_DATABASE_URL must be a valid PostgreSQL URL")
  }
  if (!['postgres:', 'postgresql:'].includes(url.protocol)) {
    throw new Error("PIPELINE_TEST_DATABASE_URL must use postgres:// or postgresql://")
  }
  const database = decodeURIComponent(url.pathname.slice(1))
  if (!/(?:^|[_-])(test|testing|ci)(?:$|[_-])/i.test(database)) {
    throw new Error(`Refusing unsafe pipeline database name ${JSON.stringify(database)}; it must contain a test/ci segment`)
  }
  if (["postgres", "template0", "template1"].includes(database)) {
    throw new Error(`Refusing system database ${JSON.stringify(database)}`)
  }
  return raw
}

export function createPipelinePool(): Pool {
  return new Pool({connectionString: pipelineTestDatabaseUrl(), max: 12})
}

export async function openPipelineClient(): Promise<Client> {
  const client = new Client({connectionString: pipelineTestDatabaseUrl()})
  await client.connect()
  return client
}

export async function installPipelineFixture(pool: Pool): Promise<void> {
  await pool.query(await readFile(fixturePath, "utf8"))
}

export async function applyTaskMigrations(pool: Pool, files: readonly string[]): Promise<void> {
  for (const file of files) {
    if (!/^\d{3}_[a-z0-9_]+\.sql$/.test(file)) throw new Error(`Invalid migration filename: ${file}`)
    const path = resolve(migrationsRoot, file)
    if (!path.startsWith(`${migrationsRoot}${sep}`)) throw new Error(`Migration escapes migrations directory: ${file}`)
    const sql = await readFile(path, "utf8")
    const client = await pool.connect()
    try {
      await client.query("SELECT pg_advisory_lock($1)", [920119123])
      if (/^\s*BEGIN\s*;/im.test(sql)) {
        await client.query(sql)
      } else {
        await client.query("BEGIN")
        try {
          await client.query(sql)
          await client.query("COMMIT")
        } catch (error) {
          await client.query("ROLLBACK")
          throw error
        }
      }
    } finally {
      await client.query("SELECT pg_advisory_unlock($1)", [920119123]).catch(() => undefined)
      client.release()
    }
  }
}

export async function resetPipelineData(pool: Pool): Promise<void> {
  await pool.query("SELECT public.pipeline_test_truncate()")
}

export async function withRollback<T>(pool: Pool, run: (client: PoolClient) => Promise<T>): Promise<T> {
  const client = await pool.connect()
  try {
    await client.query("BEGIN")
    return await run(client)
  } finally {
    await client.query("ROLLBACK").catch(() => undefined)
    client.release()
  }
}

export async function asRole<T>(client: PoolClient, role: PipelineRole, run: () => Promise<T>): Promise<T> {
  await client.query("SAVEPOINT pipeline_role_scope")
  await client.query(`SET LOCAL ROLE ${role}`)
  try {
    const result = await run()
    await client.query("RESET ROLE")
    await client.query("RELEASE SAVEPOINT pipeline_role_scope")
    return result
  } catch (error) {
    await client.query("ROLLBACK TO SAVEPOINT pipeline_role_scope").catch(() => undefined)
    await client.query("RELEASE SAVEPOINT pipeline_role_scope").catch(() => undefined)
    throw error
  }
}

export function concurrencyBarrier(participants: number): () => Promise<void> {
  if (!Number.isInteger(participants) || participants < 1) throw new Error("participants must be a positive integer")
  let arrived = 0
  let release!: () => void
  const ready = new Promise<void>((resolveReady) => { release = resolveReady })
  return async () => {
    arrived += 1
    if (arrived === participants) release()
    if (arrived > participants) throw new Error("concurrency barrier used more times than configured")
    await ready
  }
}

export async function queryAsRole<T extends Record<string, unknown>>(
  pool: Pool,
  role: PipelineRole,
  text: string,
  values: readonly unknown[] = [],
): Promise<QueryResult<T>> {
  return withRollback(pool, (client) => asRole(client, role, () => client.query<T>(text, [...values])))
}
