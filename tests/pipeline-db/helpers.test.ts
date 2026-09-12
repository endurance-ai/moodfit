// @vitest-environment node
import {describe, expect, it} from "vitest"
import {concurrencyBarrier, pipelineTestDatabaseUrl} from "./helpers"

describe("pipeline DB harness safety", () => {
  it("requires the dedicated environment variable", () => {
    const previous = process.env.PIPELINE_TEST_DATABASE_URL
    delete process.env.PIPELINE_TEST_DATABASE_URL
    try {
      expect(() => pipelineTestDatabaseUrl()).toThrow(/required/)
    } finally {
      if (previous) process.env.PIPELINE_TEST_DATABASE_URL = previous
    }
  })

  it("rejects a database whose name does not identify it as a test database", () => {
    const previous = process.env.PIPELINE_TEST_DATABASE_URL
    process.env.PIPELINE_TEST_DATABASE_URL = "postgres://user:pass@localhost/kiko_production"
    try {
      expect(() => pipelineTestDatabaseUrl()).toThrow(/unsafe pipeline database/)
    } finally {
      if (previous) process.env.PIPELINE_TEST_DATABASE_URL = previous
      else delete process.env.PIPELINE_TEST_DATABASE_URL
    }
  })

  it("releases all concurrent participants together", async () => {
    const barrier = concurrencyBarrier(2)
    const order: string[] = []
    const first = (async () => { order.push("first-arrived"); await barrier(); order.push("first-released") })()
    await Promise.resolve()
    expect(order).toEqual(["first-arrived"])
    const second = (async () => { order.push("second-arrived"); await barrier(); order.push("second-released") })()
    await Promise.all([first, second])
    expect(order.slice(0, 2)).toEqual(["first-arrived", "second-arrived"])
    expect(order.slice(2).sort()).toEqual(["first-released", "second-released"])
  })
})
