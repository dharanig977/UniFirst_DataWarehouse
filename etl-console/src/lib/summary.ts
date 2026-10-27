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
