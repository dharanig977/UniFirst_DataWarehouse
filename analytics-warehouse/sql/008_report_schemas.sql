-- =============================================================================
-- 008_report_schemas.sql   (run in the WAREHOUSE after 007)
-- One schema per report, each a small star model that Power BI can import as is:
--
--   rpt_inventory   Distribution Network Health
--                   inventory, days of supply, stock risk, order fill rate,
--                   supplier on-time performance and PO exceptions
--   rpt_demand      Demand vs Actual vs Budget (S&OP)
--                   forecast, actual and budget by customer, product and month,
--                   attainment, forecast accuracy and bias
--
-- Every object is a view over dw (and the analytics views), so a report schema
-- is always as fresh as the last ETL run and holds no data of its own. Shared
-- dimensions (product, date) appear in both schemas so each model stands alone.
-- Dimensions keep rows deleted in the source (is_active = false) so older facts
-- still find their product, supplier or customer.
-- Naming: dim_* and fact_* are the model tables, kpi_* are ready-made summaries.
-- Safe to rerun: create schema if not exists / create or replace view only.
-- =============================================================================

create schema if not exists rpt_inventory;
create schema if not exists rpt_demand;

comment on schema rpt_inventory is 'Report 1: Distribution Network Health (inventory, service, suppliers).';
comment on schema rpt_demand    is 'Report 2: Demand vs Actual vs Budget (S&OP).';

-- =============================================================================
-- Shared dimensions (one copy in each schema)
-- =============================================================================
create or replace view rpt_inventory.dim_date as
select date_key, full_date, year, quarter, month, month_name, year_month,
       week_start, iso_week, day_of_month, day_of_week, day_name, is_weekend
from dw.dim_date;

create or replace view rpt_demand.dim_date as
select * from rpt_inventory.dim_date;

create or replace view rpt_inventory.dim_product as
select product_key, sku as product_id, product_name, category, unit_cost, list_price, list_currency,
       not is_deleted_in_source as is_active
from dw.dim_product;

create or replace view rpt_demand.dim_product as
select * from rpt_inventory.dim_product;

-- =============================================================================
-- rpt_inventory: Distribution Network Health
-- =============================================================================
create or replace view rpt_inventory.dim_warehouse as
select warehouse_key,
       warehouse_id,
       case when warehouse_id like '%-DC-%' then 'Distribution center'
            when warehouse_key = 0 then 'Unknown'
            else 'Other / test' end         as warehouse_type,
       nullif(split_part(warehouse_id, '-', 1), '') as region_code
from dw.dim_warehouse;

create or replace view rpt_inventory.dim_supplier as
select supplier_key, supplier_id, supplier_name, standard_lead_days,
       not is_deleted_in_source as is_active
from dw.dim_supplier;

-- Grain: one row per inventory count (product x warehouse x time).
-- on_hand / available add receipts after the count (see analytics.vw_inventory_kpis).
create or replace view rpt_inventory.fact_inventory as
select f.snapshot_id, f.product_key, f.warehouse_key, f.snapshot_date_key, k.snapshot_at,
       k.is_latest_snapshot,
       k.reported_on_hand_qty, k.reported_reserved_qty, k.reported_available_qty,
       k.receipts_after_snapshot_qty,
       k.calculated_on_hand_qty   as on_hand_qty,
       k.reported_reserved_qty    as reserved_qty,
       k.calculated_available_qty as available_qty,
       k.calculated_inventory_value as inventory_value,
       k.stock_exception
from dw.fact_inventory_snapshot f
join analytics.vw_inventory_kpis k on k.snapshot_id = f.snapshot_id
where not f.is_deleted_in_source;

-- Grain: one row per sales order line (Draft excluded: not a customer commitment yet).
create or replace view rpt_inventory.fact_sales_orders as
select f.sales_order_id, f.product_key, f.warehouse_key, f.customer_key, f.order_date_key, f.order_date,
       f.status, f.order_qty, f.shipped_qty, f.open_qty,
       (f.status <> 'Cancelled' and f.shipped_qty >= f.order_qty) as is_fully_shipped,
       round(f.order_qty * p.unit_cost, 2) as est_cost_value,
       f.order_amount
from dw.fact_sales_orders f
join dw.dim_product p on p.product_key = f.product_key
where not f.is_deleted_in_source and f.status <> 'Draft';

-- Grain: one row per purchase order (Draft excluded), with lateness and exception reasons.
create or replace view rpt_inventory.fact_purchase_orders as
select f.po_id, f.supplier_key, f.product_key, f.warehouse_key, f.order_date_key, f.expected_date_key,
       e.order_date, e.expected_date, e.source_status, e.calculated_status,
       e.order_qty, e.received_qty, e.remaining_qty, e.over_received_qty, e.est_order_value,
       e.receipt_count, e.first_receipt_date, e.last_receipt_date,
       e.late_status, e.days_late, e.exception_reason, e.has_exception
from dw.fact_purchase_orders f
join analytics.vw_purchase_order_exceptions e on e.po_id = f.po_id;

-- Grain: one row per goods receipt.
create or replace view rpt_inventory.fact_goods_receipts as
select g.receipt_id, g.po_id, g.supplier_key, g.product_key, g.warehouse_key, g.receipt_date_key, g.receipt_date,
       g.received_qty,
       round(g.received_qty * p.unit_cost, 2) as received_value
from dw.fact_goods_receipts g
join dw.dim_product p on p.product_key = g.product_key
where not g.is_deleted_in_source;

-- -----------------------------------------------------------------------------
-- kpi_inventory_health   grain: one row per product x warehouse (latest count)
--   avg_daily_demand   ordered qty (non-Draft, non-Cancelled) in the 28 days
--                      ending on the count date, divided by 28
--   days_of_supply     available / avg_daily_demand (NULL when there is no demand)
--   inbound_qty        open PO quantity still to arrive for this product and warehouse
--   lead_days          standard lead time of the supplier on the latest PO for the product
--   stock_status       Stockout       available <= 0
--                      Reorder now    days of supply below lead time + 7 safety days,
--                                     even counting inbound
--                      Excess         more than 90 days of supply
--                      No recent demand  stock but no orders in 28 days
--                      Healthy        otherwise
--   suggested_order_qty  cover lead time + 7 days of demand, minus available and inbound
-- -----------------------------------------------------------------------------
create or replace view rpt_inventory.kpi_inventory_health as
with latest as (
  select * from rpt_inventory.fact_inventory where is_latest_snapshot
), demand as (
  select l.snapshot_id,
         coalesce(sum(s.order_qty), 0)::integer as demand_qty_28d
  from latest l
  left join dw.fact_sales_orders s
    on s.product_key = l.product_key and s.warehouse_key = l.warehouse_key
   and not s.is_deleted_in_source and s.status not in ('Draft', 'Cancelled')
   and s.order_date >  l.snapshot_at::date - 28
   and s.order_date <= l.snapshot_at::date
  group by l.snapshot_id
), inbound as (
  select product_key, warehouse_key, sum(remaining_qty)::integer as inbound_qty
  from rpt_inventory.fact_purchase_orders
  where calculated_status <> 'Received' and source_status <> 'Cancelled'
  group by product_key, warehouse_key
), supplier_lead as (
  select distinct on (f.product_key) f.product_key, s.standard_lead_days
  from dw.fact_purchase_orders f
  join dw.dim_supplier s on s.supplier_key = f.supplier_key
  where not f.is_deleted_in_source
  order by f.product_key, f.order_date desc nulls last, f.po_id desc
), calc as (
  select l.snapshot_id, l.product_key, l.warehouse_key, l.snapshot_date_key, l.snapshot_at,
         l.on_hand_qty, l.reserved_qty, l.available_qty, l.inventory_value,
         d.demand_qty_28d,
         round(d.demand_qty_28d / 28.0, 2)                     as avg_daily_demand,
         coalesce(i.inbound_qty, 0)                            as inbound_qty,
         coalesce(ld.standard_lead_days, 14)                   as lead_days
  from latest l
  join demand d on d.snapshot_id = l.snapshot_id
  left join inbound i on i.product_key = l.product_key and i.warehouse_key = l.warehouse_key
  left join supplier_lead ld   on ld.product_key = l.product_key
)
select c.*,
       round(c.available_qty / nullif(c.avg_daily_demand, 0), 1)                     as days_of_supply,
       round((c.available_qty + c.inbound_qty) / nullif(c.avg_daily_demand, 0), 1)   as days_of_supply_with_inbound,
       case when c.available_qty <= 0 then 'Stockout'
            when c.avg_daily_demand = 0 then 'No recent demand'
            when (c.available_qty + c.inbound_qty) / c.avg_daily_demand < c.lead_days + 7 then 'Reorder now'
            when c.available_qty / c.avg_daily_demand > 90 then 'Excess'
            else 'Healthy' end                                                        as stock_status,
       greatest(ceil(c.avg_daily_demand * (c.lead_days + 7)) - c.available_qty - c.inbound_qty, 0)::integer
                                                                                       as suggested_order_qty
from calc c;

-- -----------------------------------------------------------------------------
-- kpi_fill_rate   grain: one row per product x warehouse x order month
--   qty_fill_rate   shipped qty / ordered qty
--   order_fill_rate orders shipped in full / orders (the customer-experience view)
-- Cancelled orders are left out.
-- -----------------------------------------------------------------------------
create or replace view rpt_inventory.kpi_fill_rate as
select f.product_key, f.warehouse_key,
       to_char(date_trunc('month', f.order_date), 'YYYYMMDD')::integer as month_date_key,
       count(*)::integer                                      as order_count,
       count(*) filter (where f.is_fully_shipped)::integer    as orders_shipped_in_full,
       sum(f.order_qty)::integer                              as ordered_qty,
       sum(f.shipped_qty)::integer                            as shipped_qty,
       sum(f.open_qty)::integer                               as open_qty,
       round(sum(f.shipped_qty)::numeric / nullif(sum(f.order_qty), 0), 4)                         as qty_fill_rate,
       round(count(*) filter (where f.is_fully_shipped)::numeric / nullif(count(*), 0), 4)          as order_fill_rate
from rpt_inventory.fact_sales_orders f
where f.status <> 'Cancelled' and f.order_date is not null
group by 1, 2, 3;

-- kpi_supplier_scorecard   grain: one row per supplier (see analytics.vw_supplier_performance)
create or replace view rpt_inventory.kpi_supplier_scorecard as
select s.supplier_key, p.supplier_id, p.supplier_name, p.standard_lead_days,
       p.po_count, p.open_po_count, p.overdue_po_count,
       p.ordered_qty, p.received_qty, p.open_order_qty, p.est_order_value,
       p.measured_po_count, p.on_time_po_count, p.on_time_rate, p.avg_delay_days,
       (select count(*) from rpt_inventory.fact_purchase_orders e
         where e.supplier_key = s.supplier_key and e.has_exception)::integer as exception_po_count
from analytics.vw_supplier_performance p
join dw.dim_supplier s on s.supplier_id = p.supplier_id;

-- kpi_po_exception_reasons   grain: one row per exception reason x supplier x warehouse
-- (a PO with two reasons counts once under each): the root-cause list.
create or replace view rpt_inventory.kpi_po_exception_reasons as
select trim(r.reason) as exception_reason, e.supplier_key, e.warehouse_key,
       count(*)::integer               as po_count,
       sum(e.remaining_qty)::integer   as remaining_qty,
       sum(e.est_order_value)          as est_order_value,
       round(avg(e.days_late), 1)      as avg_days_late
from rpt_inventory.fact_purchase_orders e
cross join lateral unnest(string_to_array(e.exception_reason, ';')) as r(reason)
where e.has_exception
group by 1, 2, 3;

-- =============================================================================
-- rpt_demand: Demand vs Actual vs Budget (S&OP)
-- =============================================================================
create or replace view rpt_demand.dim_customer as
select customer_key, account_id, account_name, industry, segment, account_status, account_owner,
       billing_city, billing_state, home_warehouse_id,
       not is_deleted_in_source as is_active
from dw.dim_customer;

create or replace view rpt_demand.dim_budget_version as
select b.budget_version_key, b.budget_version, b.fiscal_year, b.version_status, b.description,
       (c.budget_version_key is not null) as is_current
from dw.dim_budget_version b
left join analytics.vw_current_budget_version c on c.budget_version_key = b.budget_version_key;

-- Grain: customer x product x month.
create or replace view rpt_demand.fact_demand_forecast as
select customer_key, product_key, month_date_key, forecast_month as month_start,
       forecast_qty, est_forecast_amount as forecast_amount, price_basis, forecast_source
from dw.fact_demand_forecast
where not is_deleted_in_source;

-- Grain: one row per sales order line; Draft and Cancelled are not actual demand.
create or replace view rpt_demand.fact_sales_actual as
select sales_order_id, customer_key, product_key, warehouse_key, order_date_key, order_date,
       to_char(date_trunc('month', order_date), 'YYYYMMDD')::integer as month_date_key,
       status, order_qty, shipped_qty, unit_price, order_amount
from dw.fact_sales_orders
where not is_deleted_in_source and status not in ('Draft', 'Cancelled') and order_date is not null;

-- Grain: budget version x customer x product x month (all versions; filter on is_current).
create or replace view rpt_demand.fact_sales_budget as
select b.budget_version_key, b.customer_key, b.product_key, b.month_date_key, b.budget_month as month_start,
       b.budget_qty, b.budget_amount
from dw.fact_sales_budget b
where not b.is_deleted_in_source;

-- -----------------------------------------------------------------------------
-- kpi_demand_actual_budget   grain: customer x product x month (current budget),
-- the full Demand vs Actual vs Budget table plus forecast-error columns.
--   abs_forecast_error  |actual - forecast| for closed months only (NULL for open/future)
-- -----------------------------------------------------------------------------
create or replace view rpt_demand.kpi_demand_actual_budget as
select v.customer_key, v.product_key, v.month_date_key, v.month_start, v.year_month,
       v.demand_qty as forecast_qty, v.actual_qty, v.actual_shipped_qty, v.budget_qty,
       v.demand_amount as forecast_amount, v.actual_amount, v.budget_amount,
       v.actual_vs_demand_qty as actual_vs_forecast_qty, v.actual_vs_budget_qty, v.actual_vs_budget_amount,
       v.demand_attainment_pct as forecast_attainment_pct, v.budget_attainment_pct,
       v.actual_order_count, v.actual_unpriced_orders, v.budget_version,
       (v.month_start < date_trunc('month', current_date)::date) as is_closed_month,
       v.is_future_month,
       case when v.month_start < date_trunc('month', current_date)::date
            then abs(v.actual_qty - v.demand_qty) end      as abs_forecast_error,
       v.has_unknown_member
from analytics.vw_demand_actual_budget v;

-- -----------------------------------------------------------------------------
-- kpi_forecast_accuracy   grain: product x month (closed months only)
--   wape            sum |actual - forecast| / sum actual (weighted MAPE)
--   forecast_accuracy_pct  100 x (1 - wape), floored at 0
--   bias_pct        100 x (forecast - actual) / actual; positive = over-forecast
-- Error is summed at customer x product grain first, so over- and under-forecast
-- for different customers do not cancel out.
-- -----------------------------------------------------------------------------
create or replace view rpt_demand.kpi_forecast_accuracy as
select k.product_key, k.month_date_key, k.month_start, k.year_month,
       sum(k.forecast_qty)::integer        as forecast_qty,
       sum(k.actual_qty)::integer          as actual_qty,
       sum(k.abs_forecast_error)::integer  as abs_forecast_error,
       round(sum(k.abs_forecast_error)::numeric / nullif(sum(k.actual_qty), 0), 4)                    as wape,
       greatest(round(100 * (1 - sum(k.abs_forecast_error)::numeric / nullif(sum(k.actual_qty), 0)), 1), 0)
                                                                                                    as forecast_accuracy_pct,
       round(100 * (sum(k.forecast_qty) - sum(k.actual_qty))::numeric / nullif(sum(k.actual_qty), 0), 1) as bias_pct
from rpt_demand.kpi_demand_actual_budget k
where k.is_closed_month
group by k.product_key, k.month_date_key, k.month_start, k.year_month;

-- =============================================================================
-- Descriptions (shown in the ETL console and in Power BI's navigator tooltip)
-- =============================================================================
comment on view rpt_inventory.dim_date               is 'Calendar (one row per day; date_key = yyyymmdd).';
comment on view rpt_inventory.dim_product            is 'Products (SKU, category, unit cost, list price).';
comment on view rpt_inventory.dim_warehouse          is 'Distribution centers and other stock locations.';
comment on view rpt_inventory.dim_supplier           is 'Suppliers and their standard lead time.';
comment on view rpt_inventory.fact_inventory         is 'Inventory counts with on hand, reserved, available and value.';
comment on view rpt_inventory.fact_sales_orders      is 'Sales order lines (Draft excluded) with shipped and open quantity.';
comment on view rpt_inventory.fact_purchase_orders   is 'Purchase orders with receipts, lateness and exception reasons.';
comment on view rpt_inventory.fact_goods_receipts    is 'Goods receipts with quantity and value.';
comment on view rpt_inventory.kpi_inventory_health   is 'Days of supply, stock status and suggested order quantity per product and DC.';
comment on view rpt_inventory.kpi_fill_rate          is 'Quantity and order fill rate per product, DC and month.';
comment on view rpt_inventory.kpi_supplier_scorecard is 'On-time rate, delay, open orders and exceptions per supplier.';
comment on view rpt_inventory.kpi_po_exception_reasons is 'Root causes of purchase order exceptions by supplier and DC.';
comment on view rpt_demand.dim_date                  is 'Calendar (one row per day; month_date_key = first day of month).';
comment on view rpt_demand.dim_product               is 'Products (SKU, category, unit cost, list price).';
comment on view rpt_demand.dim_customer              is 'CRM customers (segment, industry, owner, home DC).';
comment on view rpt_demand.dim_budget_version        is 'Budget versions; is_current marks the Approved one in use.';
comment on view rpt_demand.fact_demand_forecast      is 'Customer demand forecast per product and month.';
comment on view rpt_demand.fact_sales_actual         is 'Actual sales order lines (Draft and Cancelled excluded).';
comment on view rpt_demand.fact_sales_budget         is 'Sales budget per version, customer, product and month.';
comment on view rpt_demand.kpi_demand_actual_budget  is 'Forecast vs Actual vs Budget per customer, product and month.';
comment on view rpt_demand.kpi_forecast_accuracy     is 'Forecast accuracy (WAPE) and bias per product and closed month.';

-- =============================================================================
-- Access: the same read-only logins that read analytics read the report schemas.
-- =============================================================================
grant usage on schema rpt_inventory, rpt_demand to powerbi_reader, etl_console_reader, etl_loader;
grant select on all tables in schema rpt_inventory, rpt_demand to powerbi_reader, etl_console_reader, etl_loader;
alter default privileges in schema rpt_inventory grant select on tables to powerbi_reader, etl_console_reader;
alter default privileges in schema rpt_demand    grant select on tables to powerbi_reader, etl_console_reader;

-- The ETL console lists every view Power BI can read, now including the report schemas.
create or replace view analytics.vw_etl_analytics_views as
select case when n.nspname = 'analytics' then c.relname::text
            else n.nspname || '.' || c.relname end    as view_name,
       coalesce(obj_description(c.oid, 'pg_class'), '') as description,
       c.relname::text like 'vw_etl_%'                as is_console_view
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in ('analytics', 'rpt_inventory', 'rpt_demand') and c.relkind = 'v';
