-- Copy of the SOURCE schema (raw.*) for local tests only. Matches the real
-- Supabase tables as of 2026-10-26. Never run this against Supabase.
create schema if not exists raw;
create table raw.products (sku text primary key, product_name text not null, category text, unit_cost numeric(12,2));
create table raw.suppliers (supplier_id text primary key, supplier_name text not null, standard_lead_days integer);
create table raw.purchase_orders (po_id text primary key, supplier_id text references raw.suppliers(supplier_id),
  sku text references raw.products(sku), warehouse_id text, order_qty integer, order_date date, expected_date date, status text);
create table raw.goods_receipts (receipt_id text primary key, po_id text references raw.purchase_orders(po_id),
  sku text references raw.products(sku), warehouse_id text, received_qty integer, receipt_date date);
create table raw.sales_orders (sales_order_id text primary key, sku text references raw.products(sku), warehouse_id text,
  order_qty integer, shipped_qty integer, order_date date, status text);
create table raw.inventory_snapshots (snapshot_id text primary key, sku text references raw.products(sku), warehouse_id text,
  snapshot_qty integer, reserved_qty integer, snapshot_at timestamp);
alter table raw.products enable row level security; alter table raw.suppliers enable row level security;
alter table raw.purchase_orders enable row level security; alter table raw.goods_receipts enable row level security;
alter table raw.sales_orders enable row level security; alter table raw.inventory_snapshots enable row level security;
-- The source reporting view, copied from pg_get_viewdef on 2026-10-26.
create schema if not exists reporting;
create view reporting.vw_inventory_reconciliation as
 SELECT i.snapshot_id, i.sku, p.product_name, i.warehouse_id, i.snapshot_qty, i.reserved_qty, i.snapshot_at,
    COALESCE(sum(g.received_qty) FILTER (WHERE g.receipt_date > i.snapshot_at::date), 0::bigint) AS receipt_after_snapshot,
    i.snapshot_qty + COALESCE(sum(g.received_qty) FILTER (WHERE g.receipt_date > i.snapshot_at::date), 0::bigint) AS adjusted_on_hand,
    i.snapshot_qty + COALESCE(sum(g.received_qty) FILTER (WHERE g.receipt_date > i.snapshot_at::date), 0::bigint) - i.reserved_qty AS adjusted_available
   FROM raw.inventory_snapshots i
     JOIN raw.products p ON p.sku = i.sku
     LEFT JOIN raw.goods_receipts g ON g.sku = i.sku AND g.warehouse_id = i.warehouse_id
  GROUP BY i.snapshot_id, i.sku, p.product_name, i.warehouse_id, i.snapshot_qty, i.reserved_qty, i.snapshot_at;
