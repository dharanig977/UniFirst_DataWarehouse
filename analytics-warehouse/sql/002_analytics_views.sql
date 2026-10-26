-- =============================================================================
-- 002_analytics_views.sql   (run in the WAREHOUSE project after 001)
-- Power BI reads only these views. Each one has a documented grain, and
-- receipts are always summed per PO BEFORE joining to orders, so quantities
-- are never double-counted. All views use CREATE OR REPLACE and drop nothing.
--
-- "as of" date: views that judge lateness use current_date (UTC on Supabase).
-- =============================================================================

-- Small helper: receipts summed to one row per PO (the only safe way to join receipts to POs).
create or replace view analytics.vw_po_receipt_totals as
select r.po_id,
       sum(r.received_qty)::integer  as received_qty,
       count(*)::integer             as receipt_count,
       min(r.receipt_date)           as first_receipt_date,
       max(r.receipt_date)           as last_receipt_date
from dw.fact_goods_receipts r
where not r.is_deleted_in_source and r.po_id is not null
group by r.po_id;

-- -----------------------------------------------------------------------------
-- vw_inventory_kpis   grain: one row per inventory snapshot (product x warehouse x time)
-- Source-reported columns come straight from the count. Calculated columns add
-- receipts dated after the count day, up to and including the next count's day,
-- the same convention as the source view reporting.vw_inventory_reconciliation
-- (receipts have a date but no time). Shipments are NOT subtracted: sales orders
-- have no ship date, so calculated on-hand can overstate stock.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_inventory_kpis as
with snaps as (
  select f.*,
         lead(f.snapshot_at) over (partition by f.product_key, f.warehouse_key order by f.snapshot_at) as next_snapshot_at
  from dw.fact_inventory_snapshot f
  where not f.is_deleted_in_source
)
select s.snapshot_id,
       p.sku                                         as product_id,
       p.product_name                                as product_description,
       p.category,
       w.warehouse_id                                as warehouse,
       s.snapshot_at,
       s.snapshot_date_key,
       (s.next_snapshot_at is null)                  as is_latest_snapshot,
       -- source-reported
       s.snapshot_qty                                as reported_on_hand_qty,
       s.reserved_qty                                as reported_reserved_qty,
       s.available_qty                               as reported_available_qty,
       -- calculated
       coalesce(r.receipts_qty, 0)                   as receipts_after_snapshot_qty,
       s.snapshot_qty + coalesce(r.receipts_qty, 0)  as calculated_on_hand_qty,
       s.snapshot_qty + coalesce(r.receipts_qty, 0) - s.reserved_qty as calculated_available_qty,
       p.unit_cost,
       round(s.snapshot_qty * p.unit_cost, 2)        as reported_inventory_value,
       round((s.snapshot_qty + coalesce(r.receipts_qty, 0)) * p.unit_cost, 2) as calculated_inventory_value,
       case when s.reserved_qty > s.snapshot_qty + coalesce(r.receipts_qty, 0) then 'Over-reserved'
            when s.snapshot_qty + coalesce(r.receipts_qty, 0) - s.reserved_qty <= 0 then 'No available stock'
            else 'OK' end                            as stock_exception,
       (select max(last_successful_load_at) from etl.etl_watermarks
         where table_name = 'dw.fact_inventory_snapshot') as data_refreshed_at
from snaps s
join dw.dim_product p   on p.product_key = s.product_key
join dw.dim_warehouse w on w.warehouse_key = s.warehouse_key
left join lateral (
  select sum(g.received_qty)::integer as receipts_qty
  from dw.fact_goods_receipts g
  where g.product_key = s.product_key and g.warehouse_key = s.warehouse_key
    and not g.is_deleted_in_source
    and g.receipt_date > s.snapshot_at::date
    and (s.next_snapshot_at is null or g.receipt_date <= s.next_snapshot_at::date)
) r on true;

-- -----------------------------------------------------------------------------
-- vw_purchase_order_exceptions   grain: one row per purchase order (all POs,
-- with has_exception so Power BI can filter). Draft POs are excluded: they
-- are not commitments to the supplier yet.
-- Rules (as_of_date = today):
--   Overdue           not fully received and today > expected_date
--   Received late     fully received and last receipt > expected_date
--   Over-received     received_qty > order_qty
--   Status mismatch   source status disagrees with the receipts
--   No expected date  expected_date missing, lateness cannot be judged
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_purchase_order_exceptions as
with po as (
  select f.po_id, s.supplier_id, s.supplier_name, p.sku as product_id, p.product_name, w.warehouse_id as warehouse,
         f.status as source_status, f.order_qty, f.order_date, f.expected_date, f.est_order_value,
         coalesce(t.received_qty, 0) as received_qty, coalesce(t.receipt_count, 0) as receipt_count,
         t.first_receipt_date, t.last_receipt_date, current_date as as_of_date
  from dw.fact_purchase_orders f
  join dw.dim_supplier s  on s.supplier_key = f.supplier_key
  join dw.dim_product p   on p.product_key = f.product_key
  join dw.dim_warehouse w on w.warehouse_key = f.warehouse_key
  left join analytics.vw_po_receipt_totals t on t.po_id = f.po_id
  where not f.is_deleted_in_source and f.status <> 'Draft'
), calc as (
  select po.*,
         greatest(order_qty - received_qty, 0)       as remaining_qty,
         greatest(received_qty - order_qty, 0)       as over_received_qty,
         received_qty >= order_qty                   as is_fully_received,
         case when received_qty >= order_qty then 'Received'
              when received_qty > 0 then 'Partially Received'
              else 'Open' end                        as calculated_status
  from po
)
select calc.*,
       case when expected_date is null then 'Unknown (no expected date)'
            when is_fully_received and last_receipt_date > expected_date then 'Received late'
            when is_fully_received then 'Received on time'
            when as_of_date > expected_date then 'Overdue'
            else 'Not yet due' end                   as late_status,
       case when not is_fully_received and as_of_date > expected_date then as_of_date - expected_date
            when is_fully_received and expected_date is not null then greatest(last_receipt_date - expected_date, 0)
            end                                      as days_late,
       nullif(concat_ws('; ',
         case when not is_fully_received and as_of_date > expected_date then 'Overdue' end,
         case when is_fully_received and last_receipt_date > expected_date then 'Received late' end,
         case when over_received_qty > 0 then 'Over-received' end,
         case when source_status in ('Open', 'Partially Received', 'Received')
               and source_status <> calculated_status then 'Status mismatch' end,
         case when expected_date is null then 'No expected date' end
       ), '')                                        as exception_reason,
       (   (not is_fully_received and as_of_date > expected_date)
        or (is_fully_received and last_receipt_date > expected_date)
        or over_received_qty > 0
        or (source_status in ('Open', 'Partially Received', 'Received') and source_status <> calculated_status)
        or expected_date is null)                    as has_exception
from calc;

-- -----------------------------------------------------------------------------
-- vw_supplier_performance   grain: one row per supplier (non-Draft POs)
--   on_time_rate      fully received POs whose LAST receipt was on/before
--                     expected_date, divided by fully received POs with an expected date
--   avg_delay_days    average of (last receipt - expected date) over fully received POs;
--                     negative means early
--   open_order_qty    remaining quantity on POs not fully received
-- Rates are NULL (not 0) when there is nothing to measure.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_supplier_performance as
select e.supplier_id, e.supplier_name,
       count(*)                                                       as po_count,
       sum(e.order_qty)                                               as ordered_qty,
       sum(e.received_qty)                                            as received_qty,
       sum(e.remaining_qty)                                           as open_order_qty,
       count(*) filter (where not e.is_fully_received)                as open_po_count,
       count(*) filter (where e.late_status = 'Overdue')              as overdue_po_count,
       count(*) filter (where e.is_fully_received and e.expected_date is not null) as measured_po_count,
       count(*) filter (where e.late_status = 'Received on time')     as on_time_po_count,
       round(count(*) filter (where e.late_status = 'Received on time')::numeric
             / nullif(count(*) filter (where e.is_fully_received and e.expected_date is not null), 0), 4) as on_time_rate,
       round(avg(e.last_receipt_date - e.expected_date)
             filter (where e.is_fully_received and e.expected_date is not null), 1) as avg_delay_days,
       sum(e.est_order_value)                                         as est_order_value,
       sd.standard_lead_days
from analytics.vw_purchase_order_exceptions e
join dw.dim_supplier sd on sd.supplier_id = e.supplier_id
group by e.supplier_id, e.supplier_name, sd.standard_lead_days;

-- -----------------------------------------------------------------------------
-- vw_sales_demand   grain: one row per product x warehouse x order date
-- (Draft orders excluded). The source has NO sales price, so there is no sales
-- amount. est_cost_value = ordered_qty x current unit_cost, labelled as cost.
-- rolling_7d_avg_daily_qty = ordered qty over the 7 calendar days ending on
-- this date, divided by 7 (days with no orders count as 0).
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_sales_demand as
with daily as (
  select f.product_key, f.warehouse_key, f.order_date, f.order_date_key,
         count(*)::integer           as order_count,
         sum(f.order_qty)::integer   as ordered_qty,
         sum(f.shipped_qty)::integer as shipped_qty,
         sum(f.open_qty)::integer    as open_qty,
         count(*) filter (where f.shipped_qty > f.order_qty)::integer as over_shipped_orders
  from dw.fact_sales_orders f
  where not f.is_deleted_in_source and f.status <> 'Draft' and f.order_date is not null
  group by f.product_key, f.warehouse_key, f.order_date, f.order_date_key
)
select p.sku as product_id, p.product_name, p.category, w.warehouse_id as warehouse,
       d.order_date, d.order_date_key, dd.year_month, dd.week_start,
       d.order_count, d.ordered_qty, d.shipped_qty, d.open_qty,
       round(d.ordered_qty * p.unit_cost, 2) as est_cost_value,
       round(sum(d.ordered_qty) over (partition by d.product_key, d.warehouse_key order by d.order_date
                                      range between interval '6 days' preceding and current row) / 7.0, 2)
         as rolling_7d_avg_daily_qty,
       d.over_shipped_orders,
       (p.product_key = 0 or w.warehouse_key = 0) as has_unknown_member
from daily d
join dw.dim_product p   on p.product_key = d.product_key
join dw.dim_warehouse w on w.warehouse_key = d.warehouse_key
join dw.dim_date dd     on dd.date_key = d.order_date_key;

-- -----------------------------------------------------------------------------
-- vw_data_quality   grain: one row per check. status = OK / WARN / FAIL.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_data_quality as
with last_ok as (
  select max(ended_at) as at, max(run_id) as run_id from etl.etl_run_log where status in ('success', 'partial_success')
), latest as (
  select status, started_at, ended_at, error_details from etl.etl_run_log
  where status <> 'skipped' order by run_id desc limit 1
), checks as (
  select 'Rejected source records (open)' as check_name, 'all' as entity,
         count(*)::bigint as issue_count, string_agg(distinct source_table || ': ' || reason, ' | ') as detail
  from etl.etl_rejected_records where resolved_at is null
  union all
  select 'Missing required values', source_table, count(*), string_agg(distinct reason, ' | ')
  from etl.etl_rejected_records where resolved_at is null and reason like '%missing required value%'
  group by source_table
  union all
  select 'Duplicate business keys', source_table, count(*), null
  from etl.etl_rejected_records where resolved_at is null and reason like 'duplicate business key%'
  group by source_table
  union all
  select 'Invalid relationship: unknown product/supplier/warehouse', 'fact_purchase_orders', count(*), null
  from dw.fact_purchase_orders where 0 in (product_key, supplier_key, warehouse_key) and not is_deleted_in_source
  union all
  select 'Invalid relationship: unknown product/supplier/warehouse', 'fact_goods_receipts', count(*), null
  from dw.fact_goods_receipts where 0 in (product_key, supplier_key, warehouse_key) and not is_deleted_in_source
  union all
  select 'Invalid relationship: unknown product/warehouse', 'fact_sales_orders', count(*), null
  from dw.fact_sales_orders where 0 in (product_key, warehouse_key) and not is_deleted_in_source
  union all
  select 'Invalid relationship: unknown product/warehouse', 'fact_inventory_snapshot', count(*), null
  from dw.fact_inventory_snapshot where 0 in (product_key, warehouse_key) and not is_deleted_in_source
  union all
  select 'Receipt does not match its PO (missing PO, SKU or warehouse differs)', 'fact_goods_receipts', count(*), null
  from dw.fact_goods_receipts g left join dw.fact_purchase_orders po on po.po_id = g.po_id
  where not g.is_deleted_in_source
    and (po.po_id is null or po.product_key <> g.product_key or po.warehouse_key <> g.warehouse_key)
  union all
  select 'Over-received purchase orders', 'fact_purchase_orders', count(*), string_agg(po_id, ', ')
  from analytics.vw_purchase_order_exceptions where over_received_qty > 0
  union all
  select 'Sales orders shipped more than ordered', 'fact_sales_orders', count(*), string_agg(sales_order_id, ', ')
  from dw.fact_sales_orders where shipped_qty > order_qty and not is_deleted_in_source
  union all
  select 'Duplicate snapshot (same product, warehouse and time)', 'fact_inventory_snapshot', count(*), null
  from (select 1 from dw.fact_inventory_snapshot where not is_deleted_in_source
        group by product_key, warehouse_key, snapshot_at having count(*) > 1) x
  union all
  select 'Rows deleted in source (kept, flagged)', 'all', (
      (select count(*) from staging.products where _is_deleted) + (select count(*) from staging.suppliers where _is_deleted)
    + (select count(*) from staging.purchase_orders where _is_deleted) + (select count(*) from staging.goods_receipts where _is_deleted)
    + (select count(*) from staging.sales_orders where _is_deleted) + (select count(*) from staging.inventory_snapshots where _is_deleted)), null
)
select c.check_name, c.entity, c.issue_count,
       case when c.issue_count = 0 then 'OK'
            when c.check_name like 'Invalid relationship%' or c.check_name like 'Duplicate%' then 'FAIL'
            else 'WARN' end                                    as status,
       c.detail,
       l.run_id                                                as last_successful_run_id,
       l.at                                                    as last_successful_load_at,
       (select status from latest)                             as current_pipeline_status,
       (select error_details from latest)                      as current_pipeline_error
from checks c cross join last_ok l;

-- -----------------------------------------------------------------------------
-- vw_data_freshness   grain: one row per source table / warehouse table
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_data_freshness as
select w.table_name                          as entity,
       case when w.watermark_type = 'full_compare_row_hash' then 'source extract' else 'warehouse load' end as layer,
       w.watermark_type,
       w.last_extracted_at,
       w.last_successful_load_at,
       w.last_successful_watermark,
       w.latest_source_event_at,
       w.last_source_row_count,
       round(extract(epoch from now() - w.last_successful_load_at) / 60.0, 1) as minutes_since_last_load,
       r.status                              as latest_etl_status,
       r.started_at                          as latest_etl_started_at
from etl.etl_watermarks w
left join lateral (
  select status, started_at from etl.etl_run_log
  where pipeline_name = w.pipeline_name and status <> 'skipped'
  order by run_id desc limit 1
) r on true;

-- Recent runs for a monitoring page in Power BI.
create or replace view analytics.vw_etl_runs as
select run_id, pipeline_name, triggered_by, status, started_at, ended_at,
       round(extract(epoch from coalesce(ended_at, now()) - started_at)::numeric, 1) as duration_seconds,
       records_extracted, records_inserted, records_updated, records_deleted, records_rejected, error_details
from etl.etl_run_log
where started_at > now() - interval '14 days';
