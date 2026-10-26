-- =============================================================================
-- validation_queries.sql   Read-only checks. Run them in the WAREHOUSE SQL Editor
-- one block at a time after each stage. Expected results are in the comments.
-- =============================================================================

-- Stage 1: schemas exist  -> 4 rows: analytics, dw, etl, staging
select nspname from pg_namespace where nspname in ('etl', 'staging', 'dw', 'analytics') order by 1;

-- Stage 1: dim_date and Unknown members  -> dates = 1828 (2024-2028 plus the Unknown row); Unknown product/supplier
select (select count(*) from dw.dim_date) as dates,
       (select product_name from dw.dim_product where product_key = 0) as unknown_product,
       (select supplier_name from dw.dim_supplier where supplier_key = 0) as unknown_supplier;

-- Stage 2: last runs  -> newest first; status success (or partial_success with a reason)
select run_id, status, triggered_by, started_at, ended_at - started_at as took,
       records_extracted, records_inserted, records_updated, records_deleted, records_rejected, error_details
from etl.etl_run_log order by run_id desc limit 10;

-- Stage 2: row counts match the source.
-- Run the same counts in the SOURCE SQL Editor:
--   select 'products', count(*) from raw.products union all select 'suppliers', count(*) from raw.suppliers
--   union all select 'purchase_orders', count(*) from raw.purchase_orders union all select 'goods_receipts', count(*) from raw.goods_receipts
--   union all select 'sales_orders', count(*) from raw.sales_orders union all select 'inventory_snapshots', count(*) from raw.inventory_snapshots;
select 'products' t, count(*) filter (where not _is_deleted) staging, (select count(*) from dw.dim_product where product_key <> 0 and not is_deleted_in_source) dw from staging.products
union all select 'suppliers', count(*) filter (where not _is_deleted), (select count(*) from dw.dim_supplier where supplier_key <> 0 and not is_deleted_in_source) from staging.suppliers
union all select 'purchase_orders', count(*) filter (where not _is_deleted), (select count(*) from dw.fact_purchase_orders where not is_deleted_in_source) from staging.purchase_orders
union all select 'goods_receipts', count(*) filter (where not _is_deleted), (select count(*) from dw.fact_goods_receipts where not is_deleted_in_source) from staging.goods_receipts
union all select 'sales_orders', count(*) filter (where not _is_deleted), (select count(*) from dw.fact_sales_orders where not is_deleted_in_source) from staging.sales_orders
union all select 'inventory_snapshots', count(*) filter (where not _is_deleted), (select count(*) from dw.fact_inventory_snapshot where not is_deleted_in_source) from staging.inventory_snapshots;

-- Stage 2: test scenario  -> 20 | 80 | 100 | 5 | 95
select reported_on_hand_qty, receipts_after_snapshot_qty, calculated_on_hand_qty,
       reported_reserved_qty, calculated_available_qty
from analytics.vw_inventory_kpis where product_id = 'UFS-1001' and warehouse = 'KY-DC-01' and is_latest_snapshot;

-- Stage 3: no double counting  -> both pairs equal
select (select sum(order_qty) from analytics.vw_purchase_order_exceptions) as view_ordered,
       (select sum(order_qty) from dw.fact_purchase_orders where status <> 'Draft' and not is_deleted_in_source) as fact_ordered,
       (select sum(received_qty) from analytics.vw_supplier_performance) as view_received,
       (select sum(g.received_qty) from dw.fact_goods_receipts g join dw.fact_purchase_orders p using (po_id)
         where p.status <> 'Draft' and not p.is_deleted_in_source and not g.is_deleted_in_source) as fact_received;

-- Stage 3: data quality and freshness
select * from analytics.vw_data_quality;
select * from analytics.vw_data_freshness;

-- Stage 4 (after the schedule is on): runs per minute over the last 15 minutes  -> about 1 per minute
select date_trunc('minute', started_at) as minute, count(*) as runs, string_agg(status, ',') as statuses
from etl.etl_run_log where started_at > now() - interval '15 minutes'
group by 1 order by 1 desc;
