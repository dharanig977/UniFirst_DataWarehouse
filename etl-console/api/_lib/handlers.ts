// The console API. api/console.ts wires it to the real warehouse and sign-in;
// tests wire it to a local Postgres and a stubbed sign-in.
//   GET  /api/console                 everything the screens show
//   POST /api/console?r=schedule      { enabled, interval_minutes }   (operators)
//   POST /api/console?r=run-now                                       (operators)
//   POST /api/console?r=cancel-run                                    (operators)
import { HttpError, requireOperator, requireRead, type ConsoleUser } from './auth.js'
import type { Query } from './db.js'

export interface Deps {
  read: <T>(fn: (q: Query) => Promise<T>) => Promise<T>
  write: <T>(fn: (q: Query) => Promise<T>) => Promise<T>
  verify: (authHeader: string | null) => Promise<ConsoleUser>
}

export const INTERVALS = [1, 5, 10, 15, 30, 60, 120, 240, 720, 1440]

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

export async function handle(req: Request, deps: Deps): Promise<Response> {
  try {
    const user = await deps.verify(req.headers.get('authorization'))
    if (req.method === 'GET') {
      requireRead(user)
      return json({ ...(await snapshot(deps)), canOperate: user.role === 'operator' })
    }
    if (req.method !== 'POST') throw new HttpError(405, 'Method not allowed.')
    requireOperator(user)
    const r = new URL(req.url).searchParams.get('r') ?? ''
    const who = user.email || user.id
    switch (r) {
      case 'schedule': {
        const body = (await req.json().catch(() => null)) as { enabled?: unknown; interval_minutes?: unknown } | null
        if (typeof body?.enabled !== 'boolean') throw new HttpError(400, 'enabled must be true or false.')
        if (!INTERVALS.includes(body.interval_minutes as number)) throw new HttpError(400, `interval_minutes must be one of ${INTERVALS.join(', ')}.`)
        await deps.write((q) => q('select console.set_schedule($1, $2, $3)', [body.enabled, body.interval_minutes, who]))
        return json({ ok: true })
      }
      case 'run-now':
        await deps.write((q) => q('select console.request_run($1)', [who]))
        return json({ ok: true })
      case 'cancel-run':
        await deps.write((q) => q('select console.cancel_run_request($1)', [who]))
        return json({ ok: true })
    }
    throw new HttpError(404, `Unknown request "${r}".`)
  } catch (e) {
    return errorResponse(e)
  }
}

/** Everything the console shows, read from the analytics views in one consistent snapshot. */
export async function snapshot(deps: Pick<Deps, 'read'>) {
  return deps.read(async (q) => ({
    generatedAt: (await q<{ now: Date }>('select now() as now'))[0].now.toISOString(),
    schedule: (await q(`select is_enabled, interval_minutes, run_requested_at, run_requested_by, last_heartbeat_at,
                               minutes_since_heartbeat, scheduler_alive, last_run_started_at, next_run_due_at, updated_at, updated_by
                        from analytics.vw_etl_schedule`))[0] ?? null,
    sources: await q(`select source_no, source_label, source_system, source_platform, source_table, warehouse_table, load_method,
                             rows_loaded, rows_deleted_in_source, open_rejections, rows_read_last_run,
                             last_extracted_at, last_successful_load_at, minutes_since_last_load, load_status
                      from analytics.vw_etl_source_tables order by table_no`),
    warehouseTables: await q(`select warehouse_table, table_type, grain, fed_by, rows_loaded,
                                     last_successful_load_at, minutes_since_last_load
                              from analytics.vw_etl_warehouse_tables order by sort_no`),
    analyticsViews: await q(`select view_name, description, is_console_view from analytics.vw_etl_analytics_views
                             order by is_console_view, view_name`),
    runs: await q(`select run_id, triggered_by, status, started_at, ended_at, duration_seconds,
                          records_extracted, records_inserted, records_updated, records_deleted, records_rejected, error_details
                   from analytics.vw_etl_runs order by run_id desc limit 30`),
    runSteps: await q(`select run_id, step_no, step, target, rows_read, rows_inserted, rows_updated, rows_deleted, rows_rejected, seconds, error
                       from analytics.vw_etl_run_steps
                       where run_id in (select run_id from analytics.vw_etl_runs order by run_id desc limit 30)
                       order by run_id desc, step_no`),
    rejected: await q(`select warehouse_table, business_key, reason, times_rejected, first_rejected_at, last_rejected_at,
                              resolved_at, is_open, row_data
                       from analytics.vw_etl_rejected_records order by is_open desc, last_rejected_at desc limit 200`),
    actions: await q(`select action_id, acted_at, acted_by, action, details from analytics.vw_etl_console_actions
                      order by action_id desc limit 20`),
    quality: await q(`select check_name, entity, issue_count, status, detail from analytics.vw_data_quality
                      order by case status when 'FAIL' then 0 when 'WARN' then 1 else 2 end, check_name, entity`),
  }))
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) return json({ error: e.message }, e.status)
  const err = e as { code?: string; message?: string; name?: string }
  if (err?.name === 'ConfigError') return json({ error: err.message }, 500)
  if (err?.code === '42P01' || err?.code === '42883') return json({ error: 'The console views are missing in the warehouse. Run sql/006 and sql/007.' }, 500)
  if (err?.code === '42501') return json({ error: 'The warehouse login is missing a permission. Rerun sql/006 and sql/007.' }, 500)
  if (err?.code === '28P01') return json({ error: 'The warehouse rejected the etl_console_reader password. Check WAREHOUSE_CONSOLE_URL in Vercel.' }, 500)
  console.error(e)
  return json({ error: 'The console server hit an unexpected error. See the Vercel function logs.' }, 500)
}
