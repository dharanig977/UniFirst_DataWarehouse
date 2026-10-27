// API tests against a real local Postgres that already holds the warehouse
// (sql/001-006 applied, optionally loaded by the ETL). Run with:
//   TEST_WAREHOUSE_URL=postgres://etl_console_reader:...@localhost:5432/warehouse npm test
// Skipped when the variable is not set.
import pg from 'pg'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { HttpError, type ConsoleUser } from '../api/_lib/auth'
import { readOnly } from '../api/_lib/db'
import { handle, type Deps } from '../api/_lib/handlers'

const url = process.env.TEST_WAREHOUSE_URL
const suite = url ? describe : describe.skip

suite('console API on a local warehouse', () => {
  let pool: pg.Pool
  let deps: Deps
  const users: Record<string, ConsoleUser> = {
    viewer: { id: '1', email: 'v@example.com', role: 'viewer' },
    none: { id: '2', email: 'n@example.com', role: null },
  }
  const call = async (who: string | null, method = 'GET') => {
    const res = await handle(new Request('http://x/api/console', { method, headers: who ? { authorization: `Bearer ${who}` } : {} }), deps)
    return { status: res.status, body: (await res.json()) as any }
  }

  beforeAll(() => {
    pool = new pg.Pool({ connectionString: url, max: 2 })
    deps = {
      read: (fn) => readOnly(pool, fn),
      verify: async (h) => {
        const u = users[h?.replace(/^Bearer /, '') ?? '']
        if (!u) throw new HttpError(401, 'Not signed in.')
        return u
      },
    }
  })
  afterAll(() => pool.end())

  it('returns both sources with their 12 tables, the dw tables, views, runs and checks', async () => {
    const { status, body } = await call('viewer')
    expect(status).toBe(200)
    expect(body.sources).toHaveLength(12)
    expect(new Set(body.sources.map((s: any) => `${s.source_no}:${s.source_label}`))).toEqual(new Set(['1:SCM', '2:CRM']))
    expect(body.warehouseTables.map((t: any) => t.warehouse_table)).toContain('dw.fact_demand_forecast')
    expect(body.analyticsViews.map((v: any) => v.view_name)).toContain('vw_demand_actual_budget')
    expect(Array.isArray(body.runs)).toBe(true)
    expect(body.quality.length).toBeGreaterThan(10)
    expect(typeof body.sources[0].rows_loaded).toBe('number')
  })

  it('refuses callers who are signed out or have no role', async () => {
    expect((await call(null)).status).toBe(401)
    expect((await call('none')).status).toBe(403)
  })

  it('is read-only', async () => {
    expect((await call('viewer', 'POST')).status).toBe(405)
    await expect(readOnly(pool, (q) => q('insert into etl.etl_run_log (pipeline_name, source_system) values ($1, $2)', ['x', 'y'])))
      .rejects.toThrow()
  })
})
