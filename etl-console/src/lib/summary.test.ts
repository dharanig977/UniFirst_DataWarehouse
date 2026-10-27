import { describe, expect, it } from 'vitest'
import { ago, hintFor, groupSources, headline, latestRun } from './summary'
import type { ConsoleData, EtlRun, SourceTable } from './types'

const t = (no: number, name: string, rows: number, status: SourceTable['load_status'], last: string | null, rej = 0): SourceTable => ({
  source_no: no, source_label: no === 1 ? 'SCM' : 'CRM', source_system: 's', source_platform: 'p', source_table: name,
  warehouse_table: 'staging.x', load_method: 'm', rows_loaded: rows, rows_deleted_in_source: 0, open_rejections: rej,
  rows_read_last_run: rows, last_extracted_at: last, last_successful_load_at: last, minutes_since_last_load: 1, load_status: status,
})
const run = (id: number, status: EtlRun['status'], started: string): EtlRun => ({
  run_id: id, triggered_by: 'schedule', status, started_at: started, ended_at: started, duration_seconds: 2,
  records_extracted: 0, records_inserted: 0, records_updated: 0, records_deleted: 0, records_rejected: 0, error_details: null,
})

describe('groupSources', () => {
  it('groups by source, totals rows and keeps the worst status', () => {
    const g = groupSources([
      t(2, 'crm.accounts', 15, 'Up to date', '2026-10-27T01:00:00Z'),
      t(1, 'raw.products', 15, 'Up to date', '2026-10-27T01:00:00Z'),
      t(1, 'raw.sales_orders', 396, 'Loaded with rejections', '2026-10-27T01:05:00Z', 2),
    ])
    expect(g.map((x) => [x.no, x.label, x.tables.length, x.rows, x.rejections, x.status])).toEqual([
      [1, 'SCM', 2, 411, 2, 'Loaded with rejections'],
      [2, 'CRM', 1, 15, 0, 'Up to date'],
    ])
    expect(g[0].lastLoad).toBe('2026-10-27T01:05:00Z')
  })
  it('a never-loaded table makes the whole source "Never loaded"', () => {
    expect(groupSources([t(1, 'a', 1, 'Stale', 'x'), t(1, 'b', 0, 'Never loaded', null)])[0].status).toBe('Never loaded')
  })
})

describe('headline', () => {
  it('ignores skipped runs for "last run" and counts the last 24 hours', () => {
    const runs = [run(5, 'skipped', '2026-10-27T02:00:00Z'), run(4, 'failed', '2026-10-27T01:59:00Z'),
      run(3, 'success', '2026-10-27T01:58:00Z'), run(1, 'success', '2026-10-25T01:00:00Z')]
    expect(latestRun(runs)?.run_id).toBe(4)
    const h = headline({ generatedAt: '2026-10-27T02:00:30Z', runs, sources: [], quality: [], warehouseTables: [], analyticsViews: [] } as unknown as ConsoleData)
    expect([h.lastRun?.run_id, h.runs24h, h.failed24h, h.lastSuccessAt]).toEqual([4, 2, 1, '2026-10-27T01:58:00Z'])
  })
})

describe('ago', () => {
  it('reads like a person would say it', () => {
    const now = '2026-10-27T12:00:00Z'
    expect([ago(null, now), ago('2026-10-27T11:59:50Z', now), ago('2026-10-27T11:45:00Z', now), ago('2026-10-27T09:00:00Z', now), ago('2026-10-20T12:00:00Z', now)])
      .toEqual(['never', 'just now', '15 min ago', '3 h ago', '7 days ago'])
  })
})

describe('hintFor', () => {
  it('points at the likely fix for common errors', () => {
    expect(hintFor('FATAL: password authentication failed for user "etl_loader"')).toMatch(/password/)
    expect(hintFor('extract CRM: connection refused')).toMatch(/Aiven/)
    expect(hintFor('MassDeleteBlocked: 90% of raw.products would be marked deleted')).toMatch(/Safety stop/)
    expect(hintFor('something odd')).toMatch(/log/)
  })
})
