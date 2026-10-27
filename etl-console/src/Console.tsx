import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { loadConsole } from './lib/api'
import { ago, fmt, groupSources, headline, type SourceGroup } from './lib/summary'
import type { ConsoleData, EtlRun, QualityCheck, SourceTable } from './lib/types'

const REFRESH_MS = 30_000
type Tab = 'pipeline' | 'sources' | 'warehouse' | 'analytics' | 'runs' | 'quality'
const TABS: [Tab, string][] = [
  ['pipeline', 'Pipeline'],
  ['sources', 'Source tables'],
  ['warehouse', 'Warehouse (dw)'],
  ['analytics', 'Analytics views'],
  ['runs', 'Load history'],
  ['quality', 'Data quality'],
]

export function Console({ email, onSignOut }: { email: string; onSignOut: () => void }) {
  const [data, setData] = useState<ConsoleData | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [tab, setTab] = useState<Tab>('pipeline')
  const [loading, setLoading] = useState(false)

  const refresh = useCallback(async () => {
    setLoading(true)
    try {
      setData(await loadConsole())
      setError(null)
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setLoading(false)
    }
  }, [])

  useEffect(() => {
    void refresh()
    const id = setInterval(() => void refresh(), REFRESH_MS)
    return () => clearInterval(id)
  }, [refresh])

  return (
    <div className="app">
      <header className="topbar">
        <strong>UniFirst ETL Console</strong>
        <span className="topbar-sub">SCM + CRM → Cloud Data Warehouse → Power BI</span>
        <span className="spacer" />
        <span className="topbar-user">{email}</span>
        <button className="topbar-btn" onClick={onSignOut}>Sign out</button>
      </header>
      <nav className="tabs" aria-label="Console sections">
        {TABS.map(([id, label]) => (
          <button key={id} className={tab === id ? 'tab active' : 'tab'} onClick={() => setTab(id)}>
            {label}
          </button>
        ))}
        <span className="spacer" />
        <button className="secondary" onClick={() => void refresh()} disabled={loading}>
          {loading ? 'Refreshing…' : 'Refresh'}
        </button>
      </nav>
      <main className="content">
        {error && <p className="notice error">{error}</p>}
        {!data && !error && <p className="muted">Loading…</p>}
        {data && (
          <>
            <Headline data={data} />
            {tab === 'pipeline' && <Pipeline data={data} onOpen={setTab} />}
            {tab === 'sources' && <SourceTables data={data} />}
            {tab === 'warehouse' && <WarehouseTables data={data} />}
            {tab === 'analytics' && <AnalyticsViews data={data} />}
            {tab === 'runs' && <Runs data={data} />}
            {tab === 'quality' && <Quality checks={data.quality} />}
            <p className="footnote">
              Read-only. Data as of {new Date(data.generatedAt).toLocaleString()}, refreshes every 30 seconds. The ETL itself runs on
              its schedule (Render, every minute) or from GitHub Actions → Warehouse ETL. Synthetic portfolio data.
            </p>
          </>
        )}
      </main>
    </div>
  )
}

function Headline({ data }: { data: ConsoleData }) {
  const h = headline(data)
  const run = h.lastRun
  return (
    <section className="tiles">
      <Tile label="Last run" value={run ? <Status value={run.status} /> : 'No runs yet'} sub={run ? `#${run.run_id} · ${ago(run.started_at, data.generatedAt)}` : 'Run the ETL once to start'} />
      <Tile label="Last successful load" value={ago(h.lastSuccessAt, data.generatedAt)} sub={h.lastSuccessAt ? new Date(h.lastSuccessAt).toLocaleString() : '–'} />
      <Tile label="Runs (24 h)" value={fmt(h.runs24h)} sub={h.failed24h ? `${h.failed24h} failed` : 'none failed'} tone={h.failed24h ? 'bad' : undefined} />
      <Tile label="Open rejected rows" value={fmt(h.openRejections)} sub="rows held back by validation" tone={h.openRejections ? 'warn' : undefined} />
      <Tile label="Data quality" value={`${h.qualityFail} fail · ${h.qualityWarn} warn`} sub={`${data.quality.length} checks`} tone={h.qualityFail ? 'bad' : h.qualityWarn ? 'warn' : 'good'} />
    </section>
  )
}

function Tile({ label, value, sub, tone }: { label: string; value: ReactNode; sub: string; tone?: 'good' | 'warn' | 'bad' }) {
  return (
    <div className={`tile ${tone ?? ''}`}>
      <span className="tile-label">{label}</span>
      <span className="tile-value">{value}</span>
      <span className="tile-sub">{sub}</span>
    </div>
  )
}

function Pipeline({ data, onOpen }: { data: ConsoleData; onOpen: (t: Tab) => void }) {
  const groups = groupSources(data.sources)
  const dims = data.warehouseTables.filter((t) => t.table_type === 'Dimension')
  const facts = data.warehouseTables.filter((t) => t.table_type === 'Fact')
  const views = data.analyticsViews.filter((v) => !v.is_console_view)
  const staged = data.sources.reduce((n, s) => n + s.rows_loaded, 0)
  return (
    <section className="flow" aria-label="Pipeline">
      <div className="flow-col">
        <h2 className="flow-title">Sources</h2>
        {groups.map((g) => (
          <SourceCard key={g.no} g={g} now={data.generatedAt} onOpen={() => onOpen('sources')} />
        ))}
      </div>
      <div className="flow-arrow" aria-hidden>
        <span className="lines"><span>Python ETL</span><span>every minute</span><span>read-only</span></span>
        <span className="glyph">→</span>
      </div>
      <div className="flow-col wide">
        <h2 className="flow-title">Cloud data warehouse (Supabase)</h2>
        <div className="layers">
          <button className="layer" onClick={() => onOpen('sources')}>
            <span className="layer-name">staging</span>
            <span className="layer-desc">copy of each source table</span>
            <span className="layer-stat">{data.sources.length} tables · {fmt(staged)} rows</span>
          </button>
          <span className="layer-arrow" aria-hidden>→</span>
          <button className="layer" onClick={() => onOpen('warehouse')}>
            <span className="layer-name">dw</span>
            <span className="layer-desc">star schema</span>
            <span className="layer-stat">{dims.length} dimensions · {facts.length} facts</span>
          </button>
          <span className="layer-arrow" aria-hidden>→</span>
          <button className="layer" onClick={() => onOpen('analytics')}>
            <span className="layer-name">analytics</span>
            <span className="layer-desc">calculation views</span>
            <span className="layer-stat">{views.length} views for Power BI</span>
          </button>
        </div>
        <p className="muted small">
          <code>etl</code> schema: run log, watermarks and rejected rows (shown under Load history and Data quality).
        </p>
      </div>
      <div className="flow-arrow" aria-hidden>
        <span className="lines"><span>read-only</span><span>powerbi_reader</span></span>
        <span className="glyph">→</span>
      </div>
      <div className="flow-col">
        <h2 className="flow-title">Reporting</h2>
        <div className="card powerbi">
          <strong>Microsoft Power BI</strong>
          <span className="muted">Imports the analytics views, e.g. Demand vs Actual vs Budget.</span>
        </div>
      </div>
    </section>
  )
}

function SourceCard({ g, now, onOpen }: { g: SourceGroup; now: string; onOpen: () => void }) {
  return (
    <button className="card source" onClick={onOpen}>
      <span className="source-head">
        <strong>Source {g.no}: {g.label}</strong>
        <LoadStatus value={g.status} />
      </span>
      <span className="muted small">{g.platform}</span>
      <span className="source-tables">
        {g.tables.map((t) => (
          <span key={t.source_table} className="chip" title={`${t.load_status}: ${fmt(t.rows_loaded)} rows`}>
            <span className={`dot ${statusTone(t.load_status)}`} />
            {t.source_table.split('.')[1]}
          </span>
        ))}
      </span>
      <span className="small">
        {g.tables.length} tables · {fmt(g.rows)} rows · last load {ago(g.lastLoad, now)}
        {g.rejections ? ` · ${fmt(g.rejections)} rejected` : ''}
      </span>
    </button>
  )
}

function SourceTables({ data }: { data: ConsoleData }) {
  return (
    <>
      {groupSources(data.sources).map((g) => (
        <section key={g.no} className="card">
          <h2>
            Source {g.no}: {g.label} <span className="muted small">· {g.platform}</span>
          </h2>
          <div className="grid-wrap">
            <table className="grid">
              <thead>
                <tr>
                  <th>Source table</th><th>Warehouse table</th><th>Load method</th>
                  <th className="num">Rows loaded</th><th className="num">Deleted in source</th><th className="num">Rejected</th>
                  <th className="num">Read last run</th><th>Last load</th><th>Status</th>
                </tr>
              </thead>
              <tbody>
                {g.tables.map((t) => (
                  <tr key={t.source_table}>
                    <td><code>{t.source_table}</code></td>
                    <td><code>{t.warehouse_table}</code></td>
                    <td>{t.load_method}</td>
                    <td className="num">{fmt(t.rows_loaded)}</td>
                    <td className="num">{fmt(t.rows_deleted_in_source)}</td>
                    <td className="num">{fmt(t.open_rejections)}</td>
                    <td className="num">{fmt(t.rows_read_last_run)}</td>
                    <td title={t.last_successful_load_at ?? ''}>{ago(t.last_successful_load_at, data.generatedAt)}</td>
                    <td><LoadStatus value={t.load_status} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </section>
      ))}
      <p className="muted small">
        Full compare: the SCM tables have no change timestamps, so each run reads them and compares a hash of every row. Incremental:
        the CRM tables carry <code>updated_at</code>, so each run reads only rows changed since the last load (with a 5-minute overlap).
      </p>
    </>
  )
}

function WarehouseTables({ data }: { data: ConsoleData }) {
  return (
    <section className="card">
      <h2>Star schema (dw)</h2>
      <div className="grid-wrap">
        <table className="grid">
          <thead>
            <tr><th>Table</th><th>Type</th><th>One row per</th><th>Fed by</th><th className="num">Rows</th><th>Last load</th></tr>
          </thead>
          <tbody>
            {data.warehouseTables.map((t) => (
              <tr key={t.warehouse_table}>
                <td><code>{t.warehouse_table}</code></td>
                <td>{t.table_type}</td>
                <td>{t.grain}</td>
                <td>{t.fed_by}</td>
                <td className="num">{fmt(t.rows_loaded)}</td>
                <td title={t.last_successful_load_at ?? ''}>{t.warehouse_table === 'dw.dim_date' ? 'static' : ago(t.last_successful_load_at, data.generatedAt)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function AnalyticsViews({ data }: { data: ConsoleData }) {
  return (
    <section className="card">
      <h2>Analytics schema (calculation views)</h2>
      <div className="grid-wrap">
        <table className="grid">
          <thead><tr><th>View</th><th>Used by</th><th>What it shows</th></tr></thead>
          <tbody>
            {data.analyticsViews.map((v) => (
              <tr key={v.view_name}>
                <td><code>analytics.{v.view_name}</code></td>
                <td>{v.is_console_view ? 'This console' : 'Power BI'}</td>
                <td>{v.description}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function Runs({ data }: { data: ConsoleData }) {
  if (!data.runs.length) return <p className="notice">No ETL runs in the last 14 days.</p>
  return (
    <section className="card">
      <h2>Load history (last 30 runs)</h2>
      <div className="grid-wrap">
        <table className="grid">
          <thead>
            <tr>
              <th className="num">Run</th><th>Started</th><th>Trigger</th><th>Status</th><th className="num">Seconds</th>
              <th className="num">Read</th><th className="num">New</th><th className="num">Changed</th><th className="num">Deleted</th>
              <th className="num">Rejected</th><th>Error</th>
            </tr>
          </thead>
          <tbody>
            {data.runs.map((r: EtlRun) => (
              <tr key={r.run_id}>
                <td className="num">{r.run_id}</td>
                <td title={r.started_at}>{new Date(r.started_at).toLocaleString()}</td>
                <td>{r.triggered_by}</td>
                <td><Status value={r.status} /></td>
                <td className="num">{r.duration_seconds ?? '–'}</td>
                <td className="num">{fmt(r.records_extracted)}</td>
                <td className="num">{fmt(r.records_inserted)}</td>
                <td className="num">{fmt(r.records_updated)}</td>
                <td className="num">{fmt(r.records_deleted)}</td>
                <td className="num">{fmt(r.records_rejected)}</td>
                <td className="err">{r.error_details ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function Quality({ checks }: { checks: QualityCheck[] }) {
  return (
    <section className="card">
      <h2>Data quality checks</h2>
      <div className="grid-wrap">
        <table className="grid">
          <thead><tr><th>Status</th><th>Check</th><th>Table</th><th className="num">Issues</th><th>Detail</th></tr></thead>
          <tbody>
            {checks.map((c, i) => (
              <tr key={`${c.check_name}-${c.entity}-${i}`}>
                <td><span className={`badge ${c.status === 'OK' ? 'good' : c.status === 'WARN' ? 'warn' : 'bad'}`}>{c.status}</span></td>
                <td>{c.check_name}</td>
                <td><code>{c.entity}</code></td>
                <td className="num">{fmt(c.issue_count)}</td>
                <td className="err">{c.detail ?? ''}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

const RUN_LABEL: Record<EtlRun['status'], [string, string]> = {
  success: ['Success', 'good'],
  partial_success: ['Partial success', 'warn'],
  failed: ['Failed', 'bad'],
  running: ['Running', 'info'],
  skipped: ['Skipped (busy)', 'muted'],
}

function Status({ value }: { value: EtlRun['status'] }) {
  const [label, tone] = RUN_LABEL[value] ?? [value, 'muted']
  return <span className={`badge ${tone}`}>{label}</span>
}

function statusTone(s: SourceTable['load_status']) {
  return s === 'Up to date' ? 'good' : s === 'Loaded with rejections' ? 'warn' : s === 'Stale' ? 'bad' : 'muted'
}

function LoadStatus({ value }: { value: SourceTable['load_status'] }) {
  return <span className={`badge ${statusTone(value)}`}>{value}</span>
}
