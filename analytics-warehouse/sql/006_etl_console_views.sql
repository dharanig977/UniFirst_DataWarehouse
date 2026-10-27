-- =============================================================================
-- 006: views for the ETL console (etl-console/), plus its read-only login.
-- Run after 005. Safe to rerun (create or replace / if not exists only).
--
-- The console shows the pipeline the way it is built:
--   Source 1  SCM (ERP, Supabase, schema raw)  6 tables  \
--                                                          > staging -> dw -> analytics -> Power BI
--   Source 2  CRM (Aiven, schema crm)          6 tables  /
-- =============================================================================

-- -----------------------------------------------------------------------------
-- vw_etl_source_tables   grain: one row per source table (12)
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_source_tables as
with t (table_no, source_no, source_label, source_system, source_platform, source_table, staging_table, load_method) as (
  values
    ( 1, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.products',            'products',            'Full compare (row hash)'),
    ( 2, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.suppliers',           'suppliers',           'Full compare (row hash)'),
    ( 3, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.purchase_orders',     'purchase_orders',     'Full compare (row hash)'),
    ( 4, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.goods_receipts',      'goods_receipts',      'Full compare (row hash)'),
    ( 5, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.sales_orders',        'sales_orders',        'Full compare (row hash)'),
    ( 6, 1, 'SCM', 'supabase_transactional', 'Supabase PostgreSQL (ERP)', 'raw.inventory_snapshots', 'inventory_snapshots', 'Full compare (row hash)'),
    ( 7, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.price_list',       'crm_price_list',       'Incremental (updated_at)'),
    ( 8, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.accounts',         'crm_accounts',         'Incremental (updated_at)'),
    ( 9, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.budget_versions',  'crm_budget_versions',  'Incremental (updated_at)'),
    (10, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.demand_forecasts', 'crm_demand_forecasts', 'Incremental (updated_at)'),
    (11, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.sales_budgets',    'crm_sales_budgets',    'Incremental (updated_at)'),
    (12, 2, 'CRM', 'aiven_crm', 'Aiven PostgreSQL (CRM)', 'crm.orders',           'crm_orders',           'Incremental (updated_at)')
), counts (staging_table, live_rows, deleted_rows) as (
            select 'products',             count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.products
  union all select 'suppliers',            count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.suppliers
  union all select 'purchase_orders',      count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.purchase_orders
  union all select 'goods_receipts',       count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.goods_receipts
  union all select 'sales_orders',         count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.sales_orders
  union all select 'inventory_snapshots',  count(*) filter (where not _is_deleted), count(*) filter (where _is_deleted) from staging.inventory_snapshots
  -- CRM rows are soft-deleted in the source (is_deleted)
  union all select 'crm_price_list',       count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_price_list
  union all select 'crm_accounts',         count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_accounts
  union all select 'crm_budget_versions',  count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_budget_versions
  union all select 'crm_demand_forecasts', count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_demand_forecasts
  union all select 'crm_sales_budgets',    count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_sales_budgets
  union all select 'crm_orders',           count(*) filter (where not (is_deleted or _is_deleted)), count(*) filter (where is_deleted or _is_deleted) from staging.crm_orders
), rej as (
  select source_table, count(*) as open_rejections from etl.etl_rejected_records where resolved_at is null group by source_table
)
select t.table_no, t.source_no, t.source_label, t.source_system, t.source_platform, t.source_table,
       'staging.' || t.staging_table                         as warehouse_table,
       t.load_method,
       c.live_rows::bigint                                   as rows_loaded,
       c.deleted_rows::bigint                                as rows_deleted_in_source,
       coalesce(r.open_rejections, 0)::bigint                as open_rejections,
       w.last_source_row_count                               as rows_read_last_run,
       w.last_extracted_at,
       w.last_successful_load_at,
       w.last_successful_watermark,
       w.latest_source_event_at,
       round(extract(epoch from now() - w.last_successful_load_at) / 60.0, 1) as minutes_since_last_load,
       case when w.last_successful_load_at is null then 'Never loaded'
            when now() - w.last_successful_load_at > interval '15 minutes' then 'Stale'
            when coalesce(r.open_rejections, 0) > 0 then 'Loaded with rejections'
            else 'Up to date' end                            as load_status
from t
join counts c on c.staging_table = t.staging_table
left join rej r on r.source_table = t.staging_table
left join etl.etl_watermarks w on w.table_name = t.source_table and w.source_system = t.source_system;

comment on view analytics.vw_etl_source_tables is 'ETL console: one row per source table (Source 1 SCM, Source 2 CRM) with rows loaded, rejections and freshness.';

-- -----------------------------------------------------------------------------
-- vw_etl_warehouse_tables   grain: one row per dw table (dimensions and facts)
-- Row counts leave out the Unknown member (key 0) and rows deleted in the source.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_warehouse_tables as
with t (sort_no, warehouse_table, table_type, grain, fed_by, live_rows) as (
            select 1, 'dw.dim_product', 'Dimension', 'product (SKU)', 'SCM products + CRM price list',
                   (select count(*) from dw.dim_product where product_key <> 0 and not is_deleted_in_source)
  union all select 2, 'dw.dim_supplier', 'Dimension', 'supplier', 'SCM suppliers',
                   (select count(*) from dw.dim_supplier where supplier_key <> 0 and not is_deleted_in_source)
  union all select 3, 'dw.dim_warehouse', 'Dimension', 'warehouse', 'SCM warehouse codes',
                   (select count(*) from dw.dim_warehouse where warehouse_key <> 0)
  union all select 4, 'dw.dim_customer', 'Dimension', 'customer account', 'CRM accounts',
                   (select count(*) from dw.dim_customer where customer_key <> 0 and not is_deleted_in_source)
  union all select 5, 'dw.dim_budget_version', 'Dimension', 'budget version', 'CRM budget versions',
                   (select count(*) from dw.dim_budget_version where budget_version_key <> 0 and not is_deleted_in_source)
  union all select 6, 'dw.dim_date', 'Dimension', 'calendar day', 'generated',
                   (select count(*) from dw.dim_date where date_key <> 0)
  union all select 11, 'dw.fact_purchase_orders', 'Fact', 'purchase order', 'SCM purchase orders',
                   (select count(*) from dw.fact_purchase_orders where not is_deleted_in_source)
  union all select 12, 'dw.fact_goods_receipts', 'Fact', 'goods receipt', 'SCM goods receipts',
                   (select count(*) from dw.fact_goods_receipts where not is_deleted_in_source)
  union all select 13, 'dw.fact_sales_orders', 'Fact', 'sales order', 'SCM sales orders + CRM order links',
                   (select count(*) from dw.fact_sales_orders where not is_deleted_in_source)
  union all select 14, 'dw.fact_inventory_snapshot', 'Fact', 'inventory count', 'SCM inventory snapshots',
                   (select count(*) from dw.fact_inventory_snapshot where not is_deleted_in_source)
  union all select 15, 'dw.fact_demand_forecast', 'Fact', 'customer x product x month', 'CRM demand forecasts',
                   (select count(*) from dw.fact_demand_forecast where not is_deleted_in_source)
  union all select 16, 'dw.fact_sales_budget', 'Fact', 'version x customer x product x month', 'CRM sales budgets',
                   (select count(*) from dw.fact_sales_budget where not is_deleted_in_source)
)
select t.sort_no, t.warehouse_table, t.table_type, t.grain, t.fed_by, t.live_rows::bigint as rows_loaded,
       w.last_successful_load_at,
       round(extract(epoch from now() - w.last_successful_load_at) / 60.0, 1) as minutes_since_last_load
from t
left join etl.etl_watermarks w on w.table_name = t.warehouse_table and w.watermark_type = 'staging_changed_at';

comment on view analytics.vw_etl_warehouse_tables is 'ETL console: dimensions and facts in the dw schema with row counts and last load time.';

-- -----------------------------------------------------------------------------
-- vw_etl_analytics_views   grain: one row per analytics view (what Power BI reads)
-- -----------------------------------------------------------------------------
comment on view analytics.vw_po_receipt_totals         is 'Helper: received quantity per purchase order.';
comment on view analytics.vw_inventory_kpis            is 'Stock on hand, reserved, available, value and stock exceptions per inventory count.';
comment on view analytics.vw_purchase_order_exceptions is 'Open, overdue, late and over-received purchase orders.';
comment on view analytics.vw_supplier_performance      is 'On-time rate, average delay and open quantity per supplier.';
comment on view analytics.vw_sales_demand              is 'Sales order demand per product, warehouse and day, with a 7-day average.';
comment on view analytics.vw_current_budget_version    is 'The Approved budget version used for each fiscal year.';
comment on view analytics.vw_demand_actual_budget      is 'Demand vs Actual vs Budget per customer, product and month.';
comment on view analytics.vw_data_quality              is 'Data-quality checks with OK / WARN / FAIL status.';
comment on view analytics.vw_data_freshness            is 'Last load time and watermark per source and warehouse table.';
comment on view analytics.vw_etl_runs                  is 'ETL runs from the last 14 days.';

create or replace view analytics.vw_etl_analytics_views as
select c.relname::text                          as view_name,
       coalesce(obj_description(c.oid, 'pg_class'), '') as description,
       c.relname::text like 'vw_etl_%'          as is_console_view
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'analytics' and c.relkind = 'v';

comment on view analytics.vw_etl_analytics_views is 'ETL console: the views in the analytics schema and what each one is for.';

-- -----------------------------------------------------------------------------
-- Logins. etl_console_reader is used only by the console's server function;
-- like powerbi_reader it can read the analytics views and nothing else.
-- Created NOLOGIN without a password: you turn it on in the SQL Editor with
--   alter role etl_console_reader with login password '...';
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'etl_console_reader') then
    create role etl_console_reader nologin;
  end if;
end $$;
grant usage on schema analytics to etl_console_reader;
grant select on all tables in schema analytics to etl_console_reader, powerbi_reader, etl_loader;
alter default privileges in schema analytics grant select on tables to etl_console_reader;
alter role etl_console_reader set default_transaction_read_only = on;
alter role etl_console_reader set statement_timeout = '20s';
