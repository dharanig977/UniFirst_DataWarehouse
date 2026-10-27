// API tests against a real local Postgres that already holds the warehouse
// (sql/001-007 applied, optionally loaded by the ETL). Run with:
//   TEST_WAREHOUSE_URL=postgres://etl_console_reader:...@localhost:5432/warehouse npm test
// Skipped when the variable is not set.
import pg from 'pg'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import { HttpError, type ConsoleUser } from '../api/_lib/auth'
import { readOnly, writeVia } from '../api/_lib/db'
import { handle, type Deps } from '../api/_lib/handlers'

const url = process.env.TEST_WAREHOUSE_URL
const suite = url ? describe : describe.skip

suite('console API on a local warehouse', () => {
  let pool: pg.Pool
  let deps: Deps
  const users: Record<string, ConsoleUser> = {
    viewer: { id: '1', email: 'v@example.com', role: 'viewer' },
    operator: { id: '3', email: 'op@example.com', role: 'operator' },
    none: { id: '2', email: 'n@example.com', role: null },
  }
  const call = async (who: string | null, method = 'GET', r = '', body?: unknown) => {
    const headers: Record<string, string> = who ? { authorization: `Bearer ${who}` } : {}
    const init: RequestInit = { method, headers }
    if (body !== undefined) init.body = JSON.stringify(body)
    const res = await handle(new Request(`http://x/api/console${r ? `?r=${r}` : ''}`, init), deps)
    return { status: res.status, body: (await res.json()) as any }
  }

  beforeAll(() => {
    pool = new pg.Pool({ connectionString: url, max: 2 })
    deps = {
      read: (fn) => readOnly(pool, fn),
      write: (fn) => writeVia(pool, fn),
      verify: async (h) => {
        const u = users[h?.replace(/^Bearer /, '') ?? '']
        if (!u) throw new HttpError(401, 'Not signed in.')
        return u
      },
    }
  })
  afterAll(async () => {
    // leave the local warehouse's schedule as the setup script made it
    await pool.query("select console.set_schedule(true, 1, 'test cleanup')").catch(() => undefined)
    await pool.query("select console.cancel_run_request('test cleanup')").catch(() => undefined)
    await pool.end()
  })

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

  it('reads in a read-only transaction and cannot touch ETL tables directly', async () => {
    expect((await call('viewer', 'PUT')).status).toBe(405)
    await expect(readOnly(pool, (q) => q('insert into etl.etl_run_log (pipeline_name, source_system) values ($1, $2)', ['x', 'y'])))
      .rejects.toThrow()
    await expect(writeVia(pool, (q) => q('update etl.etl_schedule set is_enabled = false')))
      .rejects.toThrow(/permission denied/)
  })

  it('returns the schedule, run steps, rejected rows and console actions', async () => {
    const { body } = await call('viewer')
    expect(body.canOperate).toBe(false)
    expect(body.schedule).toMatchObject({ interval_minutes: expect.any(Number), is_enabled: expect.any(Boolean) })
    for (const k of ['runSteps', 'rejected', 'actions']) expect(Array.isArray(body[k])).toBe(true)
    expect((await call('operator')).body.canOperate).toBe(true)
  })

  it('lets only operators change the schedule', async () => {
    expect((await call('viewer', 'POST', 'run-now')).status).toBe(403)
    expect((await call('viewer', 'POST', 'schedule', { enabled: false, interval_minutes: 5 })).status).toBe(403)
    expect((await call(null, 'POST', 'run-now')).status).toBe(401)
  })

  it('saves the schedule and logs who did it', async () => {
    expect((await call('operator', 'POST', 'schedule', { enabled: true, interval_minutes: 7 })).status).toBe(400)
    expect((await call('operator', 'POST', 'schedule', { enabled: 'yes', interval_minutes: 5 })).status).toBe(400)
    expect((await call('operator', 'POST', 'schedule', { enabled: false, interval_minutes: 15 })).status).toBe(200)
    const { body } = await call('operator')
    expect(body.schedule).toMatchObject({ is_enabled: false, interval_minutes: 15, updated_by: 'op@example.com' })
    expect(body.actions[0]).toMatchObject({ acted_by: 'op@example.com', action: 'schedule paused' })
  })

  it('requests and cancels a run', async () => {
    expect((await call('operator', 'POST', 'run-now')).status).toBe(200)
    let s = (await call('operator')).body.schedule
    expect(s.run_requested_by).toBe('op@example.com')
    expect(s.run_requested_at).not.toBeNull()
    expect((await call('operator', 'POST', 'cancel-run')).status).toBe(200)
    s = (await call('operator')).body.schedule
    expect(s.run_requested_at).toBeNull()
    expect((await call('operator', 'POST', 'nope')).status).toBe(404)
  })
})
