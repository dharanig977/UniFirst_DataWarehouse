-- =============================================================================
-- 001_warehouse_schema.sql
-- Run in the WAREHOUSE project (supply-chain-analytics-warehouse), never in the
-- source project. Safe to run more than once: it only creates what is missing.
--
-- Schemas
--   etl       pipeline metadata: run log, watermarks, rejected records
--   staging   source-aligned copies of the six raw tables + change tracking
--   dw        star schema: 4 dimensions, 4 facts
--   analytics Power BI views (002_analytics_views.sql)
-- =============================================================================

create schema if not exists etl;
create schema if not exists staging;
create schema if not exists dw;
create schema if not exists analytics;

-- Nothing in these schemas is for the browser. Supabase's API roles get nothing.
revoke all on schema etl, staging, dw, analytics from public;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    execute 'revoke all on schema etl, staging, dw, analytics from anon, authenticated';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- etl: run log, watermarks, rejected records
-- -----------------------------------------------------------------------------

create table if not exists etl.etl_run_log (
  run_id              bigint generated always as identity primary key,
  pipeline_name       text        not null,
  source_system       text        not null,
  triggered_by        text        not null default 'manual',      -- manual | schedule | test
  started_at          timestamptz not null default now(),
  ended_at            timestamptz,
  status              text        not null default 'running',
  records_extracted   integer     not null default 0,
  records_inserted    integer     not null default 0,
  records_updated     integer     not null default 0,
  records_deleted     integer     not null default 0,             -- rows that disappeared from the source
  records_rejected    integer     not null default 0,
  error_details       text,
  step_details        jsonb       not null default '[]'::jsonb,   -- per-table counts and timings
  constraint etl_run_log_status_chk
    check (status in ('running', 'success', 'partial_success', 'failed', 'skipped')),
  constraint etl_run_log_end_chk
    check ((status = 'running') = (ended_at is null)),
  constraint etl_run_log_counts_chk
    check (least(records_extracted, records_inserted, records_updated, records_deleted, records_rejected) >= 0)
);
create index if not exists etl_run_log_started_idx on etl.etl_run_log (started_at desc);
create index if not exists etl_run_log_status_idx on etl.etl_run_log (status, started_at desc);

-- One row per source table (extract side) and per warehouse table (load side).
-- The source has no change timestamps, so extraction is a full read compared by
-- row hash. The load side then uses a real timestamp watermark on
-- staging._changed_at, which the warehouse controls.
create table if not exists etl.etl_watermarks (
  pipeline_name              text        not null,
  source_system              text        not null,
  table_name                 text        not null,
  watermark_type             text        not null,
  last_successful_watermark  timestamptz,                  -- load side: staging._changed_at already loaded
  last_successful_run_id     bigint references etl.etl_run_log (run_id),
  last_extracted_at          timestamptz,
  last_successful_load_at    timestamptz,
  last_source_row_count      integer,
  latest_source_event_at     timestamptz,                  -- newest business date/time seen in the data
  updated_at                 timestamptz not null default now(),
  primary key (pipeline_name, source_system, table_name),
  constraint etl_watermarks_type_chk
    check (watermark_type in ('full_compare_row_hash', 'staging_changed_at'))
);

-- Rows that failed validation. One row per (table, business key, reason) so a
-- bad source row that is re-read every minute does not create 1,440 rows a day.
create table if not exists etl.etl_rejected_records (
  rejected_id       bigint generated always as identity primary key,
  source_table      text        not null,
  business_key      text        not null,
  reason            text        not null,
  row_data          jsonb       not null,
  first_run_id      bigint      not null references etl.etl_run_log (run_id),
  last_run_id       bigint      not null references etl.etl_run_log (run_id),
  first_rejected_at timestamptz not null default now(),
  last_rejected_at  timestamptz not null default now(),
  times_rejected    integer     not null default 1,
  resolved_at       timestamptz,                     -- set when the row later passes or leaves the source
  unique (source_table, business_key, reason)
);
create index if not exists etl_rejected_open_idx on etl.etl_rejected_records (source_table) where resolved_at is null;

-- -----------------------------------------------------------------------------
-- staging: source-aligned copies. Source columns keep their source names and
-- types. Columns starting with "_" are ingestion metadata added by the ETL.
--   _row_hash        md5 of the cleaned source values, used to detect changes
--   _first_seen_at   first time the ETL saw this key
--   _changed_at      last time the values changed (insert, update or delete)
--   _last_seen_at    last run in which the key was present in the source
--   _is_deleted      key no longer exists in the source (kept for lineage)
--   _last_run_id     run that last touched the row
-- -----------------------------------------------------------------------------

create table if not exists staging.products (
  sku           text primary key,
  product_name  text not null,
  category      text,
  unit_cost     numeric(12,2),
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.suppliers (
  supplier_id         text primary key,
  supplier_name       text not null,
  standard_lead_days  integer,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.purchase_orders (
  po_id          text primary key,
  supplier_id    text,
  sku            text,
  warehouse_id   text,
  order_qty      integer,
  order_date     date,
  expected_date  date,
  status         text,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.goods_receipts (
  receipt_id    text primary key,
  po_id         text,
  sku           text,
  warehouse_id  text,
  received_qty  integer,
  receipt_date  date,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.sales_orders (
  sales_order_id  text primary key,
  sku             text,
  warehouse_id    text,
  order_qty       integer,
  shipped_qty     integer,
  order_date      date,
  status          text,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.inventory_snapshots (
  snapshot_id   text primary key,
  sku           text,
  warehouse_id  text,
  snapshot_qty  integer,
  reserved_qty  integer,
  snapshot_at   timestamp,              -- source type: timestamp without time zone
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create index if not exists stg_products_changed_idx  on staging.products (_changed_at);
create index if not exists stg_suppliers_changed_idx on staging.suppliers (_changed_at);
create index if not exists stg_po_changed_idx        on staging.purchase_orders (_changed_at);
create index if not exists stg_gr_changed_idx        on staging.goods_receipts (_changed_at);
create index if not exists stg_so_changed_idx        on staging.sales_orders (_changed_at);
create index if not exists stg_inv_changed_idx       on staging.inventory_snapshots (_changed_at);

-- -----------------------------------------------------------------------------
-- dw: dimensions. Surrogate key 0 is the "Unknown" member, used when a fact
-- points at a code that is missing or not (yet) in the dimension.
-- Dimensions are SCD type 1: changes overwrite the old values.
-- -----------------------------------------------------------------------------

create table if not exists dw.dim_date (
  date_key       integer primary key,          -- yyyymmdd; 0 = unknown date
  full_date      date unique,
  year           smallint,
  quarter        smallint,
  month          smallint,
  month_name     text,
  year_month     text,                          -- 2026-10, sorts correctly in Power BI
  week_start     date,                          -- Monday of the ISO week
  iso_week       smallint,
  day_of_month   smallint,
  day_of_week    smallint,                      -- 1 = Monday ... 7 = Sunday
  day_name       text,
  is_weekend     boolean
);

insert into dw.dim_date (date_key, full_date, month_name, year_month, day_name)
values (0, null, 'Unknown', 'Unknown', 'Unknown')
on conflict (date_key) do nothing;

insert into dw.dim_date
select to_char(d, 'YYYYMMDD')::integer, d,
       extract(year from d), extract(quarter from d), extract(month from d),
       to_char(d, 'FMMonth'), to_char(d, 'YYYY-MM'),
       date_trunc('week', d)::date, extract(week from d), extract(day from d),
       extract(isodow from d), to_char(d, 'FMDay'), extract(isodow from d) in (6, 7)
from generate_series(date '2024-01-01', date '2028-12-31', interval '1 day') as g(d)
on conflict (date_key) do nothing;

create table if not exists dw.dim_product (
  product_key         integer generated by default as identity primary key,
  sku                 text not null unique,              -- business key from raw.products
  product_name        text not null,
  category            text not null,
  unit_cost           numeric(12,2),                     -- current standard cost (USD assumed)
  is_deleted_in_source boolean not null default false,
  dw_inserted_at      timestamptz not null default now(),
  dw_updated_at       timestamptz not null default now(),
  dw_last_run_id      bigint
);

create table if not exists dw.dim_supplier (
  supplier_key         integer generated by default as identity primary key,
  supplier_id          text not null unique,
  supplier_name        text not null,
  standard_lead_days   integer,
  is_deleted_in_source boolean not null default false,
  dw_inserted_at       timestamptz not null default now(),
  dw_updated_at        timestamptz not null default now(),
  dw_last_run_id       bigint
);

-- The source has no warehouse table, only warehouse_id codes on transactions.
-- This dimension is built from the distinct codes seen; it has no name or address.
create table if not exists dw.dim_warehouse (
  warehouse_key   integer generated by default as identity primary key,
  warehouse_id    text not null unique,
  first_seen_in   text not null,                        -- which source table first used the code
  dw_inserted_at  timestamptz not null default now(),
  dw_last_run_id  bigint
);

insert into dw.dim_product (product_key, sku, product_name, category, unit_cost)
  overriding system value values (0, 'UNKNOWN', 'Unknown product', 'Unknown', null)
  on conflict do nothing;
insert into dw.dim_supplier (supplier_key, supplier_id, supplier_name, standard_lead_days)
  overriding system value values (0, 'UNKNOWN', 'Unknown supplier', null)
  on conflict do nothing;
insert into dw.dim_warehouse (warehouse_key, warehouse_id, first_seen_in)
  overriding system value values (0, 'UNKNOWN', 'n/a')
  on conflict do nothing;

-- -----------------------------------------------------------------------------
-- dw: facts. Each fact keeps the source ID as a unique business key, so a
-- retry can never insert the same record twice, and every row traces back.
-- -----------------------------------------------------------------------------

-- Grain: one row per purchase order. Each source PO has exactly one SKU, so a
-- PO is also a PO line.
create table if not exists dw.fact_purchase_orders (
  po_id                 text primary key,
  supplier_key          integer not null references dw.dim_supplier (supplier_key),
  product_key           integer not null references dw.dim_product (product_key),
  warehouse_key         integer not null references dw.dim_warehouse (warehouse_key),
  order_date_key        integer not null references dw.dim_date (date_key),
  expected_date_key     integer not null references dw.dim_date (date_key),
  order_date            date,
  expected_date         date,
  status                text not null,
  order_qty             integer not null,                 -- units
  -- The source has no PO price. This is order_qty x the product's current
  -- standard unit_cost, so it is an estimate and changes if unit_cost changes.
  est_order_value       numeric(14,2),
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);

-- Grain: one row per goods receipt (a delivery event; one SKU per receipt).
create table if not exists dw.fact_goods_receipts (
  receipt_id            text primary key,
  po_id                 text,                             -- degenerate dimension; link to fact_purchase_orders
  supplier_key          integer not null references dw.dim_supplier (supplier_key),  -- via the PO
  product_key           integer not null references dw.dim_product (product_key),
  warehouse_key         integer not null references dw.dim_warehouse (warehouse_key),
  receipt_date_key      integer not null references dw.dim_date (date_key),
  receipt_date          date,
  received_qty          integer not null,                 -- units
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);

-- Grain: one row per sales order (one SKU per source sales order).
create table if not exists dw.fact_sales_orders (
  sales_order_id        text primary key,
  product_key           integer not null references dw.dim_product (product_key),
  warehouse_key         integer not null references dw.dim_warehouse (warehouse_key),
  order_date_key        integer not null references dw.dim_date (date_key),
  order_date            date,
  status                text not null,
  order_qty             integer not null,                 -- units
  shipped_qty           integer not null,                 -- units
  open_qty              integer not null,                 -- greatest(order_qty - shipped_qty, 0)
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);

-- Grain: one row per inventory count (product x warehouse x snapshot time).
-- Snapshots are history: a new count is a new row, old counts are never overwritten.
create table if not exists dw.fact_inventory_snapshot (
  snapshot_id           text primary key,
  product_key           integer not null references dw.dim_product (product_key),
  warehouse_key         integer not null references dw.dim_warehouse (warehouse_key),
  snapshot_date_key     integer not null references dw.dim_date (date_key),
  snapshot_at           timestamp not null,
  snapshot_qty          integer not null,                 -- units counted (source-reported on hand)
  reserved_qty          integer not null,                 -- units reserved (source-reported)
  available_qty         integer not null,                 -- snapshot_qty - reserved_qty
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);

create index if not exists fpo_supplier_idx on dw.fact_purchase_orders (supplier_key);
create index if not exists fpo_product_idx  on dw.fact_purchase_orders (product_key, warehouse_key);
create index if not exists fpo_date_idx     on dw.fact_purchase_orders (order_date_key);
create index if not exists fgr_po_idx       on dw.fact_goods_receipts (po_id);
create index if not exists fgr_product_idx  on dw.fact_goods_receipts (product_key, warehouse_key, receipt_date);
create index if not exists fso_product_idx  on dw.fact_sales_orders (product_key, warehouse_key);
create index if not exists fso_date_idx     on dw.fact_sales_orders (order_date_key);
create index if not exists finv_product_idx on dw.fact_inventory_snapshot (product_key, warehouse_key, snapshot_at);
