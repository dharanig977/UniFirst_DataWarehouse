// Shapes returned by GET /api/console (see api/_lib/handlers.ts).

export interface SourceTable {
  source_no: number
  source_label: string
  source_system: string
  source_platform: string
  source_table: string
  warehouse_table: string
  load_method: string
  rows_loaded: number
  rows_deleted_in_source: number
  open_rejections: number
  rows_read_last_run: number | null
  last_extracted_at: string | null
  last_successful_load_at: string | null
  minutes_since_last_load: number | null
  load_status: 'Up to date' | 'Loaded with rejections' | 'Stale' | 'Never loaded'
}

export interface WarehouseTable {
  warehouse_table: string
  table_type: 'Dimension' | 'Fact'
  grain: string
  fed_by: string
  rows_loaded: number
  last_successful_load_at: string | null
  minutes_since_last_load: number | null
}

export interface AnalyticsView {
  view_name: string
  description: string
  is_console_view: boolean
}

export interface EtlRun {
  run_id: number
  triggered_by: string
  status: 'running' | 'success' | 'partial_success' | 'failed' | 'skipped'
  started_at: string
  ended_at: string | null
  duration_seconds: number | null
  records_extracted: number | null
  records_inserted: number | null
  records_updated: number | null
  records_deleted: number | null
  records_rejected: number | null
  error_details: string | null
}

export interface QualityCheck {
  check_name: string
  entity: string
  issue_count: number
  status: 'OK' | 'WARN' | 'FAIL'
  detail: string | null
}

export interface ConsoleData {
  generatedAt: string
  sources: SourceTable[]
  warehouseTables: WarehouseTable[]
  analyticsViews: AnalyticsView[]
  runs: EtlRun[]
  quality: QualityCheck[]
}
