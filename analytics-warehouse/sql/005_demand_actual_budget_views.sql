-- =============================================================================
-- 005: Demand vs Actual vs Budget, plus CRM data-quality and freshness checks.
-- Run after 004_crm_source.sql. Safe to rerun (create or replace view only).
-- Note: this file replaces analytics.vw_data_quality and analytics.vw_data_freshness
-- from 002. If you ever rerun 002, run this file again afterwards.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- vw_current_budget_version   grain: one row per fiscal year
-- The budget Power BI compares against: the Approved, not-deleted version that
-- was changed most recently in the CRM.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_current_budget_version as
select distinct on (fiscal_year)
       budget_version_key, budget_version, fiscal_year, version_status, description, source_updated_at
from dw.dim_budget_version
where budget_version_key <> 0 and version_status = 'Approved' and not is_deleted_in_source
order by fiscal_year, source_updated_at desc nulls last, budget_version desc;

-- -----------------------------------------------------------------------------
-- vw_demand_actual_budget   grain: one row per customer x product x month
--   demand = CRM demand forecast        (dw.fact_demand_forecast)
--   actual = ERP sales orders, excluding Draft and Cancelled (dw.fact_sales_orders);
--            the customer and price come from the CRM order link
--   budget = CRM sales budget, current Approved version only (dw.fact_sales_budget)
-- Quantities are units; amounts are USD. Actual orders with no CRM link land on
-- the "Unknown" customer (customer_key 0), so totals still tie to the ERP.
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_demand_actual_budget as
with demand as (
  select customer_key, product_key, forecast_month as month_start,
         sum(forecast_qty)::integer          as demand_qty,
         sum(est_forecast_amount)            as demand_amount
  from dw.fact_demand_forecast
  where not is_deleted_in_source
  group by 1, 2, 3
), actual as (
  select customer_key, product_key, date_trunc('month', order_date)::date as month_start,
         count(*)::integer                   as actual_order_count,
         sum(order_qty)::integer             as actual_qty,
         sum(shipped_qty)::integer           as actual_shipped_qty,
         sum(order_amount)                   as actual_amount,
         count(*) filter (where order_amount is null)::integer as actual_unpriced_orders
  from dw.fact_sales_orders
  where not is_deleted_in_source and status not in ('Draft', 'Cancelled') and order_date is not null
  group by 1, 2, 3
), budget as (
  select b.customer_key, b.product_key, b.budget_month as month_start,
         max(v.budget_version)               as budget_version,
         sum(b.budget_qty)::integer          as budget_qty,
         sum(b.budget_amount)                as budget_amount
  from dw.fact_sales_budget b
  join analytics.vw_current_budget_version v on v.budget_version_key = b.budget_version_key
  where not b.is_deleted_in_source
  group by 1, 2, 3
), keys as (
  select customer_key, product_key, month_start from demand
  union select customer_key, product_key, month_start from actual
  union select customer_key, product_key, month_start from budget
)
select c.customer_key, c.account_id, c.account_name, c.segment, c.industry, c.account_owner,
       p.product_key, p.sku as product_id, p.product_name, p.category,
       k.month_start,
       coalesce(dd.date_key, 0)                              as month_date_key,
       dd.year_month,
       coalesce(d.demand_qty, 0)                             as demand_qty,
       coalesce(a.actual_qty, 0)                             as actual_qty,
       coalesce(a.actual_shipped_qty, 0)                     as actual_shipped_qty,
       coalesce(b.budget_qty, 0)                             as budget_qty,
       coalesce(d.demand_amount, 0)                          as demand_amount,
       coalesce(a.actual_amount, 0)                          as actual_amount,
       coalesce(b.budget_amount, 0)                          as budget_amount,
       coalesce(a.actual_qty, 0) - coalesce(d.demand_qty, 0) as actual_vs_demand_qty,
       coalesce(a.actual_qty, 0) - coalesce(b.budget_qty, 0) as actual_vs_budget_qty,
       coalesce(a.actual_amount, 0) - coalesce(b.budget_amount, 0) as actual_vs_budget_amount,
       round(100.0 * a.actual_qty / nullif(d.demand_qty, 0), 1)       as demand_attainment_pct,
       round(100.0 * a.actual_amount / nullif(b.budget_amount, 0), 1) as budget_attainment_pct,
       coalesce(a.actual_order_count, 0)                     as actual_order_count,
       coalesce(a.actual_unpriced_orders, 0)                 as actual_unpriced_orders,
       b.budget_version,
       (k.month_start > current_date)                        as is_future_month,
       (c.customer_key = 0 or p.product_key = 0)             as has_unknown_member
from keys k
join dw.dim_customer c on c.customer_key = k.customer_key
join dw.dim_product p  on p.product_key = k.product_key
left join dw.dim_date dd on dd.full_date = k.month_start
left join demand d on (d.customer_key, d.product_key, d.month_start) = (k.customer_key, k.product_key, k.month_start)
left join actual a on (a.customer_key, a.product_key, a.month_start) = (k.customer_key, k.product_key, k.month_start)
left join budget b on (b.customer_key, b.product_key, b.month_start) = (k.customer_key, k.product_key, k.month_start);

-- -----------------------------------------------------------------------------
-- vw_data_quality   grain: one row per check. status = OK / WARN / FAIL.
-- Same ERP checks as 002, plus the CRM checks at the end of "checks".
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
  -- ---- CRM checks ----
  union all
  select 'Sales orders not linked to a CRM customer', 'fact_sales_orders', count(*), null
  from dw.fact_sales_orders
  where customer_key = 0 and not is_deleted_in_source and status not in ('Draft', 'Cancelled')
  union all
  select 'CRM order link points to a missing ERP sales order', 'crm.orders', count(*), string_agg(o.erp_sales_order_id, ', ')
  from staging.crm_orders o left join staging.sales_orders s on s.sales_order_id = o.erp_sales_order_id and not s._is_deleted
  where not o.is_deleted and s.sales_order_id is null
  union all
  select 'CRM order link disagrees with the ERP order (SKU or quantity)', 'crm.orders', count(*), string_agg(o.erp_sales_order_id, ', ')
  from staging.crm_orders o join staging.sales_orders s on s.sales_order_id = o.erp_sales_order_id and not s._is_deleted
  where not o.is_deleted
    and ((o.sku is not null and o.sku <> s.sku) or (o.order_qty is not null and o.order_qty <> s.order_qty))
  union all
  select 'CRM customer not found for an order link', 'crm.orders', count(*), string_agg(distinct o.account_id, ', ')
  from staging.crm_orders o left join staging.crm_accounts a on a.account_id = o.account_id and not a.is_deleted
  where not o.is_deleted and a.account_id is null
  union all
  select 'CRM price list SKU not in the ERP product master', 'crm.price_list', count(*), string_agg(pl.sku, ', ')
  from staging.crm_price_list pl left join staging.products p on p.sku = pl.sku and not p._is_deleted
  where not pl.is_deleted and p.sku is null
  union all
  select 'Invalid relationship: unknown customer/product', 'fact_demand_forecast', count(*), null
  from dw.fact_demand_forecast where 0 in (customer_key, product_key) and not is_deleted_in_source
  union all
  select 'Invalid relationship: unknown customer/product/budget version', 'fact_sales_budget', count(*), null
  from dw.fact_sales_budget where 0 in (customer_key, product_key, budget_version_key) and not is_deleted_in_source
  union all
  select 'Forecast with no price (amount cannot be estimated)', 'fact_demand_forecast', count(*), null
  from dw.fact_demand_forecast where est_unit_price is null and not is_deleted_in_source
  union all
  select 'Budget fiscal years with no Approved version', 'dim_budget_version', count(*), string_agg(fiscal_year::text, ', ')
  from (select distinct fiscal_year from dw.dim_budget_version
        where budget_version_key <> 0 and not is_deleted_in_source
        except select fiscal_year from analytics.vw_current_budget_version) x
)
select c.check_name, c.entity, c.issue_count,
       case when c.issue_count = 0 then 'OK'
            when c.check_name like 'Invalid relationship%' or c.check_name like 'Duplicate%'
              or c.check_name like 'CRM order link points%' then 'FAIL'
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
       case when w.watermark_type in ('full_compare_row_hash', 'source_updated_at') then 'source extract'
            else 'warehouse load' end         as layer,
       w.watermark_type,
       w.last_extracted_at,
       w.last_successful_load_at,
       w.last_successful_watermark,
       w.latest_source_event_at,
       w.last_source_row_count,
       round(extract(epoch from now() - w.last_successful_load_at) / 60.0, 1) as minutes_since_last_load,
       r.status                              as latest_etl_status,
       r.started_at                          as latest_etl_started_at,
       w.source_system
from etl.etl_watermarks w
left join lateral (
  select status, started_at from etl.etl_run_log
  where pipeline_name = w.pipeline_name and status <> 'skipped'
  order by run_id desc limit 1
) r on true;

-- powerbi_reader reads everything in analytics (views created above included).
grant select on all tables in schema analytics to powerbi_reader, etl_loader;
