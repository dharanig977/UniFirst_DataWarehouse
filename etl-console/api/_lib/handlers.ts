// The console API. api/console.ts wires it to the real warehouse and sign-in;
// tests wire it to a local Postgres and a stubbed sign-in.
import { HttpError, requireRead, type ConsoleUser } from './auth.js'
import type { Query } from './db.js'

export interface Deps {
  read: <T>(fn: (q: Query) => Promise<T>) => Promise<T>
  verify: (authHeader: string | null) => Promise<ConsoleUser>
}

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

export async function handle(req: Request, deps: Deps): Promise<Response> {
  try {
    if (req.method !== 'GET') throw new HttpError(405, 'The console is read-only.')
    requireRead(await deps.verify(req.headers.get('authorization')))
    return json(await snapshot(deps))
  } catch (e) {
    return errorResponse(e)
  }
}

/** Everything the console shows, read from the analytics views in one consistent snapshot. */
export async function snapshot(deps: Pick<Deps, 'read'>) {
  return deps.read(async (q) => ({
    generatedAt: (await q<{ now: Date }>('select now() as now'))[0].now.toISOString(),
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
    quality: await q(`select check_name, entity, issue_count, status, detail from analytics.vw_data_quality
                      order by case status when 'FAIL' then 0 when 'WARN' then 1 else 2 end, check_name, entity`),
  }))
}

export function errorResponse(e: unknown): Response {
  if (e instanceof HttpError) return json({ error: e.message }, e.status)
  const err = e as { code?: string; message?: string; name?: string }
  if (err?.name === 'ConfigError') return json({ error: err.message }, 500)
  if (err?.code === '42P01') return json({ error: 'The console views are missing in the warehouse. Run sql/006_etl_console_views.sql.' }, 500)
  if (err?.code === '42501') return json({ error: 'The warehouse login cannot read the analytics views. Rerun sql/006_etl_console_views.sql.' }, 500)
  if (err?.code === '28P01') return json({ error: 'The warehouse rejected the etl_console_reader password. Check WAREHOUSE_CONSOLE_URL in Vercel.' }, 500)
  console.error(e)
  return json({ error: 'The console server hit an unexpected error. See the Vercel function logs.' }, 500)
}
