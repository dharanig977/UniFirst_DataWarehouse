// Pure helpers behind the console's headline numbers (unit-tested).
import type { ConsoleData, EtlRun, SourceTable } from './types'

export interface SourceGroup {
  no: number
  label: string
  platform: string
  tables: SourceTable[]
  rows: number
  rejections: number
  lastLoad: string | null
  status: SourceTable['load_status']
}

const WORST: SourceTable['load_status'][] = ['Never loaded', 'Stale', 'Loaded with rejections', 'Up to date']

/** Source 1 (SCM), Source 2 (CRM): their tables, totals and the worst table status. */
export function groupSources(tables: SourceTable[]): SourceGroup[] {
  const groups = new Map<number, SourceGroup>()
  for (const t of tables) {
    const g = groups.get(t.source_no) ?? {
      no: t.source_no, label: t.source_label, platform: t.source_platform, tables: [], rows: 0, rejections: 0, lastLoad: null, status: 'Up to date',
    }
    g.tables.push(t)
    g.rows += t.rows_loaded
    g.rejections += t.open_rejections
    if (t.last_successful_load_at && (!g.lastLoad || t.last_successful_load_at > g.lastLoad)) g.lastLoad = t.last_successful_load_at
    if (WORST.indexOf(t.load_status) < WORST.indexOf(g.status)) g.status = t.load_status
    groups.set(t.source_no, g)
  }
  return [...groups.values()].sort((a, b) => a.no - b.no)
}

/** The newest run that actually did work (a "skipped" run only means another run was busy). */
export function latestRun(runs: EtlRun[]): EtlRun | null {
  return runs.find((r) => r.status !== 'skipped') ?? null
}

export function headline(d: ConsoleData) {
  const last = latestRun(d.runs)
  const lastOk = d.runs.find((r) => r.status === 'success' || r.status === 'partial_success') ?? null
  return {
    lastRun: last,
    lastSuccessAt: lastOk?.ended_at ?? null,
    runs24h: d.runs.filter((r) => r.status !== 'skipped' && Date.parse(r.started_at) > Date.parse(d.generatedAt) - 86_400_000).length,
    failed24h: d.runs.filter((r) => r.status === 'failed' && Date.parse(r.started_at) > Date.parse(d.generatedAt) - 86_400_000).length,
    qualityFail: d.quality.filter((q) => q.status === 'FAIL').length,
    qualityWarn: d.quality.filter((q) => q.status === 'WARN').length,
    openRejections: d.sources.reduce((n, s) => n + s.open_rejections, 0),
  }
}

export function ago(iso: string | null, nowIso: string): string {
  if (!iso) return 'never'
  const mins = Math.round((Date.parse(nowIso) - Date.parse(iso)) / 60_000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins} min ago`
  const h = Math.round(mins / 60)
  if (h < 48) return `${h} h ago`
  return `${Math.round(h / 24)} days ago`
}

export const fmt = (n: number | null | undefined) => (n == null ? '–' : n.toLocaleString('en-US'))

/** A first thing to check for an ETL error, in plain words. */
export function hintFor(error: string): string {
  const e = error.toLowerCase()
  if (e.includes('password authentication failed'))
    return 'A database password or user name is wrong. Supabase users look like etl_loader.<project-ref>; check the secret in Render/GitHub.'
  if (e.includes('would be marked deleted') || e.includes('massdeleteblocked'))
    return 'Safety stop: far fewer rows came back than before. Check the source login can still see the table (grants/RLS). If the deletes are real, run once with ETL_MAX_DELETE_PERCENT=100.'
  if (e.includes('certificate') || e.includes('ssl'))
    return 'The secure connection failed. Check the CA certificate setting (CRM_DATABASE_CA) and that sslmode is set.'
  if (e.includes('permission denied'))
    return 'A login is missing a permission. Rerun the grants in sql/003 (warehouse) or the source role script.'
  if (e.includes('process stopped before finishing'))
    return 'The job was killed before it finished (for example a time limit on Render). Check the Render logs for that time; the next run recovered automatically.'
  if (e.includes('extract crm'))
    return 'The CRM database could not be read. The SCM data still loaded. Check that the Aiven service is running (free services power off when idle).'
  if (e.includes('extract erp'))
    return 'The SCM (ERP) database could not be read. Check that the Supabase project is not paused.'
  if (e.includes('timeout') || e.includes('could not connect') || e.includes('connection'))
    return 'A database could not be reached in time. Check that the Supabase projects and the Aiven service are running, then press Run now.'
  return 'Open the Render (or GitHub Actions) log for this run to see the full message.'
}
