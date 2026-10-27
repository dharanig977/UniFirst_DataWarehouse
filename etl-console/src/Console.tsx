import { useCallback, useEffect, useState, type ReactNode } from 'react'
import { cancelRun, loadConsole, requestRun, saveSchedule } from './lib/api'
import { ago, fmt, groupSources, headline, hintFor, type SourceGroup } from './lib/summary'
import type { ConsoleData, EtlRun, QualityCheck, Schedule, SourceTable } from './lib/types'

const REFRESH_MS = 30_000
const INTERVALS = [1, 5, 10, 15, 30, 60, 120, 240, 720, 1440]
type Tab = 'pipeline' | 'schedule' | 'tables' | 'troubleshoot' | 'quality'
const TABS: [Tab, string][] = [
  ['pipeline', 'Pipeline'],
  ['schedule', 'Schedule & runs'],
  ['tables', 'Tables by schema'],
  ['troubleshoot', 'Troubleshoot'],
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
            {tab === 'schedule' && (
              <>
                <ScheduleCard data={data} onChanged={refresh} />
                <Runs data={data} />
              </>
            )}
            {tab === 'tables' && (
              <>
                <SourceTables data={data} />
                <WarehouseTables data={data} />
                <AnalyticsViews data={data} />
              </>
            )}
            {tab === 'troubleshoot' && <Troubleshoot data={data} />}
            {tab === 'quality' && <Quality checks={data.quality} />}
            <p className="footnote">
              Data as of {new Date(data.generatedAt).toLocaleString()}, refreshes every 30 seconds. The console reads the warehouse and
              can change only the batch schedule; it never changes business data. Synthetic portfolio data.
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
      <Tile label="Schedule" value={scheduleText(data.schedule)} sub={schedulerText(data.schedule, data.generatedAt)} tone={data.schedule && !data.schedule.scheduler_alive ? 'warn' : undefined} />
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
          <SourceCard key={g.no} g={g} now={data.generatedAt} onOpen={() => onOpen('tables')} />
        ))}
      </div>
      <div className="flow-arrow" aria-hidden>
        <span className="lines"><span>Python ETL</span><span>every minute</span><span>read-only</span></span>
        <span className="glyph">→</span>
      </div>
      <div className="flow-col wide">
        <h2 className="flow-title">Cloud data warehouse (Supabase)</h2>
        <div className="layers">
          <button className="layer" onClick={() => onOpen('tables')}>
            <span className="layer-name">staging</span>
            <span className="layer-desc">copy of each source table</span>
            <span className="layer-stat">{data.sources.length} tables · {fmt(staged)} rows</span>
          </button>
          <span className="layer-arrow" aria-hidden>→</span>
          <button className="layer" onClick={() => onOpen('tables')}>
            <span className="layer-name">dw</span>
            <span className="layer-desc">star schema</span>
            <span className="layer-stat">{dims.length} dimensions · {facts.length} facts</span>
          </button>
          <span className="layer-arrow" aria-hidden>→</span>
          <button className="layer" onClick={() => onOpen('tables')}>
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
      <h2 className="schema-title">Schema <code>staging</code>: one copy of each source table</h2>
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
      <h2>Schema <code>dw</code>: star schema (dimensions and facts)</h2>
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
      <h2>Schema <code>analytics</code>: calculation views</h2>
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
  const [open, setOpen] = useState<number | null>(null)
  if (!data.runs.length) return <p className="notice">No ETL runs in the last 14 days.</p>
  return (
    <section className="card">
      <h2>Load history (last 30 runs)</h2>
      <p className="muted small">Click a run to see what it read and loaded for each table.</p>
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
            {data.runs.map((r: EtlRun) => [
              <tr key={r.run_id} className="clickable" onClick={() => setOpen(open === r.run_id ? null : r.run_id)}>
                <td className="num">{open === r.run_id ? '▾' : '▸'} {r.run_id}</td>
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
              </tr>,
              open === r.run_id && (
                <tr key={`${r.run_id}-steps`} className="detail">
                  <td colSpan={11}>
                    <RunSteps data={data} runId={r.run_id} />
                  </td>
                </tr>
              ),
            ])}
          </tbody>
        </table>
      </div>
    </section>
  )
}

const STEP_LABEL = { extract: '1. Read source', staging: '2. Load staging', dw: '3. Load dw' } as const

function RunSteps({ data, runId }: { data: ConsoleData; runId: number }) {
  const steps = data.runSteps.filter((s) => s.run_id === runId)
  if (!steps.length) return <p className="muted small">No step details (the run was skipped, or stopped before its first step).</p>
  return (
    <table className="grid inner">
      <thead>
        <tr>
          <th>Step</th><th>Source / target table</th><th className="num">Read</th><th className="num">New</th><th className="num">Changed</th>
          <th className="num">Deleted</th><th className="num">Rejected</th><th className="num">Seconds</th><th>Error</th>
        </tr>
      </thead>
      <tbody>
        {steps.map((s) => (
          <tr key={s.step_no}>
            <td>{STEP_LABEL[s.step] ?? s.step}</td>
            <td><code>{s.target}</code></td>
            <td className="num">{fmt(s.rows_read)}</td>
            <td className="num">{fmt(s.rows_inserted)}</td>
            <td className="num">{fmt(s.rows_updated)}</td>
            <td className="num">{fmt(s.rows_deleted)}</td>
            <td className="num">{fmt(s.rows_rejected)}</td>
            <td className="num">{s.seconds ?? '–'}</td>
            <td className="err">{s.error ?? ''}</td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function every(min: number) {
  return min < 60 ? `every ${min} min` : min < 1440 ? `every ${min / 60} h` : 'once a day'
}

function scheduleText(s: Schedule | null) {
  if (!s) return 'Not set up'
  return s.is_enabled ? `Runs ${every(s.interval_minutes)}` : 'Paused'
}

function schedulerText(s: Schedule | null, now: string) {
  if (!s) return 'run sql/007 in the warehouse'
  if (!s.last_heartbeat_at) return 'scheduler has not started yet'
  return s.scheduler_alive ? `scheduler checked in ${ago(s.last_heartbeat_at, now)}` : `scheduler silent since ${ago(s.last_heartbeat_at, now)}`
}

function ScheduleCard({ data, onChanged }: { data: ConsoleData; onChanged: () => Promise<void> }) {
  const s = data.schedule
  const [enabled, setEnabled] = useState(s?.is_enabled ?? true)
  const [interval, setInterval_] = useState(s?.interval_minutes ?? 1)
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState<{ kind: 'ok' | 'error'; text: string } | null>(null)
  useEffect(() => {
    if (s) {
      setEnabled(s.is_enabled)
      setInterval_(s.interval_minutes)
    }
  }, [s?.is_enabled, s?.interval_minutes]) // eslint-disable-line react-hooks/exhaustive-deps

  if (!s) return <p className="notice error">The schedule table is missing. Run sql/007_etl_schedule.sql in the warehouse.</p>
  const act = async (fn: () => Promise<unknown>, done: string) => {
    setBusy(true)
    setMsg(null)
    try {
      await fn()
      setMsg({ kind: 'ok', text: done })
      await onChanged()
    } catch (e) {
      setMsg({ kind: 'error', text: e instanceof Error ? e.message : String(e) })
    } finally {
      setBusy(false)
    }
  }
  const dirty = enabled !== s.is_enabled || interval !== s.interval_minutes
  return (
    <section className="card schedule">
      <h2>Batch schedule</h2>
      <div className="schedule-grid">
        <div className="kv"><span>Status</span><strong>{scheduleText(s)}</strong></div>
        <div className="kv"><span>Next run</span><strong>{s.run_requested_at ? 'within a minute (Run now)' : s.next_run_due_at ? ago(s.next_run_due_at, data.generatedAt).replace(' ago', '').replace('just now', 'within a minute') : '–'}</strong></div>
        <div className="kv"><span>Last run started</span><strong>{ago(s.last_run_started_at, data.generatedAt)}</strong></div>
        <div className="kv"><span>Scheduler (Render)</span><strong className={s.scheduler_alive ? 'ok-text' : 'warn-text'}>{schedulerText(s, data.generatedAt)}</strong></div>
        <div className="kv"><span>Last changed</span><strong>{ago(s.updated_at, data.generatedAt)} by {s.updated_by}</strong></div>
      </div>
      {s.run_requested_at && (
        <p className="notice">Run requested by {s.run_requested_by} {ago(s.run_requested_at, data.generatedAt)}. It starts at the scheduler's next check-in (within a minute).</p>
      )}
      {data.canOperate ? (
        <div className="schedule-actions">
          <label className="inline">
            <input type="checkbox" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} /> Schedule on
          </label>
          <label className="inline">
            Run
            <select value={interval} onChange={(e) => setInterval_(Number(e.target.value))} disabled={!enabled}>
              {INTERVALS.map((m) => <option key={m} value={m}>{every(m)}</option>)}
            </select>
          </label>
          <button className="primary" disabled={busy || !dirty} onClick={() => void act(() => saveSchedule(enabled, interval), 'Schedule saved.')}>Save schedule</button>
          <span className="spacer" />
          {s.run_requested_at ? (
            <button disabled={busy} onClick={() => void act(cancelRun, 'Run request cancelled.')}>Cancel Run now</button>
          ) : (
            <button className="primary" disabled={busy} onClick={() => void act(requestRun, 'Run requested. It starts within a minute.')}>Run now</button>
          )}
        </div>
      ) : (
        <p className="muted small">You can view the schedule. Changing it or starting a run needs the operator role.</p>
      )}
      {msg && <p className={msg.kind === 'ok' ? 'notice' : 'notice error'}>{msg.text}</p>}
      <p className="muted small">
        The scheduler (Render cron) checks in every minute and the ETL runs only when this schedule says it is due, so changes here take
        effect at the next check-in. Run now works even while the schedule is paused.
      </p>
    </section>
  )
}

function Troubleshoot({ data }: { data: ConsoleData }) {
  const problems = data.runs.filter((r) => r.status === 'failed' || r.status === 'partial_success')
  const stepErrors = data.runSteps.filter((s) => s.error)
  const open = data.rejected.filter((r) => r.is_open)
  const s = data.schedule
  return (
    <>
      <section className="card">
        <h2>Health checks</h2>
        <ul className="checks">
          <Check ok={!!s?.scheduler_alive} text={s?.scheduler_alive ? 'The scheduler is checking in.' : 'The scheduler has not checked in for 5 minutes. Check the Render cron job (or start a run from GitHub Actions).'} />
          <Check ok={!!s?.is_enabled} text={s?.is_enabled ? 'The schedule is on.' : 'The schedule is paused. Turn it on under Schedule & runs.'} />
          <Check ok={!data.sources.some((t) => t.load_status === 'Stale' || t.load_status === 'Never loaded')} text={
            data.sources.some((t) => t.load_status === 'Never loaded') ? 'Some source tables were never loaded. Run the ETL once.'
              : data.sources.some((t) => t.load_status === 'Stale') ? 'Some source tables have not loaded for over 15 minutes.'
                : 'Every source table loaded in the last 15 minutes.'} />
          <Check ok={!problems.length} text={problems.length ? `${problems.length} of the last ${data.runs.length} runs failed or partly failed (below).` : 'No failed runs recently.'} />
          <Check ok={!open.length} text={open.length ? `${open.length} source rows are held back by validation (below).` : 'No rejected rows.'} />
        </ul>
      </section>
      <section className="card">
        <h2>Failed and partial runs</h2>
        {!problems.length ? <p className="muted">None in the last 30 runs.</p> : (
          <div className="grid-wrap">
            <table className="grid">
              <thead><tr><th className="num">Run</th><th>Started</th><th>Status</th><th>Error</th><th>What to check</th></tr></thead>
              <tbody>
                {problems.map((r) => {
                  const err = r.error_details ?? stepErrors.find((e) => e.run_id === r.run_id)?.error ?? (r.records_rejected ? `${r.records_rejected} rows rejected` : '')
                  return (
                    <tr key={r.run_id}>
                      <td className="num">{r.run_id}</td>
                      <td>{new Date(r.started_at).toLocaleString()}</td>
                      <td><Status value={r.status} /></td>
                      <td className="err">{err}</td>
                      <td className="hint">{r.status === 'partial_success' && !r.error_details ? 'Some rows were rejected by validation; see Rejected rows below.' : hintFor(err)}</td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </section>
      <section className="card">
        <h2>Rejected rows</h2>
        <p className="muted small">Rows that failed validation are never loaded silently or dropped: they wait here until the source is fixed, then the next run loads them and marks them resolved.</p>
        {!data.rejected.length ? <p className="muted">None.</p> : (
          <div className="grid-wrap">
            <table className="grid">
              <thead><tr><th>State</th><th>Table</th><th>Key</th><th>Reason</th><th className="num">Times</th><th>Last seen</th><th>Source values</th></tr></thead>
              <tbody>
                {data.rejected.map((r) => (
                  <tr key={`${r.warehouse_table}-${r.business_key}-${r.reason}`}>
                    <td><span className={`badge ${r.is_open ? 'warn' : 'good'}`}>{r.is_open ? 'Open' : 'Resolved'}</span></td>
                    <td><code>{r.warehouse_table}</code></td>
                    <td><code>{r.business_key}</code></td>
                    <td>{r.reason}</td>
                    <td className="num">{r.times_rejected}</td>
                    <td>{ago(r.last_rejected_at, data.generatedAt)}</td>
                    <td className="err"><code>{r.row_data}</code></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
      <section className="card">
        <h2>Console activity</h2>
        {!data.actions.length ? <p className="muted">No schedule changes or Run now requests yet.</p> : (
          <table className="grid">
            <thead><tr><th>When</th><th>Who</th><th>Action</th><th>Details</th></tr></thead>
            <tbody>
              {data.actions.map((a) => (
                <tr key={a.action_id}>
                  <td>{new Date(a.acted_at).toLocaleString()}</td>
                  <td>{a.acted_by}</td>
                  <td>{a.action}</td>
                  <td className="err"><code>{a.details === '{}' ? '' : a.details}</code></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
    </>
  )
}

function Check({ ok, text }: { ok: boolean; text: string }) {
  return (
    <li>
      <span className={`badge ${ok ? 'good' : 'warn'}`}>{ok ? 'OK' : 'Check'}</span> {text}
    </li>
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
