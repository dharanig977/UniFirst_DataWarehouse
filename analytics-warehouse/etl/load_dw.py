"""Load dimensions and facts from staging, incrementally and in ONE transaction.

Incremental rule: each dw table only reprocesses staging rows whose
_changed_at is newer than its watermark minus ETL_LOOKBACK_MINUTES. The
lookback re-reads a few minutes of already-loaded changes on purpose; that
is harmless because every load is an upsert on the business key, and it
protects against a row landing in staging just as a previous run finished.

Every upsert only touches a row when a value really changed, so counts of
"updated" are honest and a rerun with nothing new reports 0.

If any statement fails, the whole dw load rolls back, the watermarks stay
where they were, and the next run simply tries again.
"""
import logging

import psycopg

log = logging.getLogger("etl")

# (dw table, staging tables it reads) - the watermark is the newest _changed_at across them.
DW_TABLES = {
    "dw.dim_warehouse": ("purchase_orders", "goods_receipts", "sales_orders", "inventory_snapshots"),
    "dw.dim_product": ("products",),
    "dw.dim_supplier": ("suppliers",),
    "dw.fact_purchase_orders": ("purchase_orders",),
    "dw.fact_goods_receipts": ("goods_receipts", "purchase_orders"),
    "dw.fact_sales_orders": ("sales_orders",),
    "dw.fact_inventory_snapshot": ("inventory_snapshots",),
}

SQL = {}

SQL["dw.dim_warehouse"] = """
with codes as (
  select warehouse_id, min(src) as src from (
    select warehouse_id, 'purchase_orders' as src from staging.purchase_orders where _changed_at > %(since)s
    union all select warehouse_id, 'goods_receipts' from staging.goods_receipts where _changed_at > %(since)s
    union all select warehouse_id, 'sales_orders' from staging.sales_orders where _changed_at > %(since)s
    union all select warehouse_id, 'inventory_snapshots' from staging.inventory_snapshots where _changed_at > %(since)s
  ) u where warehouse_id is not null group by warehouse_id
)
insert into dw.dim_warehouse (warehouse_id, first_seen_in, dw_last_run_id)
select warehouse_id, src, %(run)s from codes
on conflict (warehouse_id) do nothing
returning true as inserted
"""

SQL["dw.dim_product"] = """
insert into dw.dim_product as d (sku, product_name, category, unit_cost, is_deleted_in_source, dw_last_run_id)
select sku, product_name, coalesce(category, 'Uncategorized'), unit_cost, _is_deleted, %(run)s
from staging.products where _changed_at > %(since)s
on conflict (sku) do update set
  product_name = excluded.product_name, category = excluded.category, unit_cost = excluded.unit_cost,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (d.product_name, d.category, d.unit_cost, d.is_deleted_in_source)
      is distinct from (excluded.product_name, excluded.category, excluded.unit_cost, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

SQL["dw.dim_supplier"] = """
insert into dw.dim_supplier as d (supplier_id, supplier_name, standard_lead_days, is_deleted_in_source, dw_last_run_id)
select supplier_id, supplier_name, standard_lead_days, _is_deleted, %(run)s
from staging.suppliers where _changed_at > %(since)s
on conflict (supplier_id) do update set
  supplier_name = excluded.supplier_name, standard_lead_days = excluded.standard_lead_days,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (d.supplier_name, d.standard_lead_days, d.is_deleted_in_source)
      is distinct from (excluded.supplier_name, excluded.standard_lead_days, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

SQL["dw.fact_purchase_orders"] = """
insert into dw.fact_purchase_orders as f (po_id, supplier_key, product_key, warehouse_key, order_date_key,
       expected_date_key, order_date, expected_date, status, order_qty, est_order_value, is_deleted_in_source, dw_last_run_id)
select s.po_id, coalesce(ds.supplier_key, 0), coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0),
       coalesce(dd1.date_key, 0), coalesce(dd2.date_key, 0), s.order_date, s.expected_date,
       coalesce(s.status, 'Unknown'), s.order_qty, s.order_qty * dp.unit_cost, s._is_deleted, %(run)s
from staging.purchase_orders s
left join dw.dim_supplier ds on ds.supplier_id = s.supplier_id
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
left join dw.dim_date dd1 on dd1.full_date = s.order_date
left join dw.dim_date dd2 on dd2.full_date = s.expected_date
where s._changed_at > %(since)s
on conflict (po_id) do update set
  supplier_key = excluded.supplier_key, product_key = excluded.product_key, warehouse_key = excluded.warehouse_key,
  order_date_key = excluded.order_date_key, expected_date_key = excluded.expected_date_key,
  order_date = excluded.order_date, expected_date = excluded.expected_date, status = excluded.status,
  order_qty = excluded.order_qty, est_order_value = excluded.est_order_value,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (f.supplier_key, f.product_key, f.warehouse_key, f.order_date_key, f.expected_date_key, f.status,
       f.order_qty, f.est_order_value, f.is_deleted_in_source)
   is distinct from (excluded.supplier_key, excluded.product_key, excluded.warehouse_key, excluded.order_date_key,
       excluded.expected_date_key, excluded.status, excluded.order_qty, excluded.est_order_value, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

# A receipt's supplier comes from its PO, so receipts are also reprocessed when their PO changed.
SQL["dw.fact_goods_receipts"] = """
insert into dw.fact_goods_receipts as f (receipt_id, po_id, supplier_key, product_key, warehouse_key,
       receipt_date_key, receipt_date, received_qty, is_deleted_in_source, dw_last_run_id)
select s.receipt_id, s.po_id, coalesce(ds.supplier_key, 0), coalesce(dp.product_key, 0),
       coalesce(dwh.warehouse_key, 0), coalesce(dd.date_key, 0), s.receipt_date, s.received_qty, s._is_deleted, %(run)s
from staging.goods_receipts s
left join staging.purchase_orders po on po.po_id = s.po_id
left join dw.dim_supplier ds on ds.supplier_id = po.supplier_id
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
left join dw.dim_date dd on dd.full_date = s.receipt_date
where s._changed_at > %(since)s or po._changed_at > %(since)s
on conflict (receipt_id) do update set
  po_id = excluded.po_id, supplier_key = excluded.supplier_key, product_key = excluded.product_key,
  warehouse_key = excluded.warehouse_key, receipt_date_key = excluded.receipt_date_key,
  receipt_date = excluded.receipt_date, received_qty = excluded.received_qty,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (f.po_id, f.supplier_key, f.product_key, f.warehouse_key, f.receipt_date_key, f.received_qty, f.is_deleted_in_source)
   is distinct from (excluded.po_id, excluded.supplier_key, excluded.product_key, excluded.warehouse_key,
       excluded.receipt_date_key, excluded.received_qty, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

SQL["dw.fact_sales_orders"] = """
insert into dw.fact_sales_orders as f (sales_order_id, product_key, warehouse_key, order_date_key, order_date,
       status, order_qty, shipped_qty, open_qty, is_deleted_in_source, dw_last_run_id)
select s.sales_order_id, coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0), coalesce(dd.date_key, 0),
       s.order_date, coalesce(s.status, 'Unknown'), s.order_qty, s.shipped_qty,
       greatest(s.order_qty - s.shipped_qty, 0), s._is_deleted, %(run)s
from staging.sales_orders s
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
left join dw.dim_date dd on dd.full_date = s.order_date
where s._changed_at > %(since)s
on conflict (sales_order_id) do update set
  product_key = excluded.product_key, warehouse_key = excluded.warehouse_key, order_date_key = excluded.order_date_key,
  order_date = excluded.order_date, status = excluded.status, order_qty = excluded.order_qty,
  shipped_qty = excluded.shipped_qty, open_qty = excluded.open_qty,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (f.product_key, f.warehouse_key, f.order_date_key, f.status, f.order_qty, f.shipped_qty, f.is_deleted_in_source)
   is distinct from (excluded.product_key, excluded.warehouse_key, excluded.order_date_key, excluded.status,
       excluded.order_qty, excluded.shipped_qty, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

SQL["dw.fact_inventory_snapshot"] = """
insert into dw.fact_inventory_snapshot as f (snapshot_id, product_key, warehouse_key, snapshot_date_key, snapshot_at,
       snapshot_qty, reserved_qty, available_qty, is_deleted_in_source, dw_last_run_id)
select s.snapshot_id, coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0), coalesce(dd.date_key, 0),
       s.snapshot_at, s.snapshot_qty, s.reserved_qty, s.snapshot_qty - s.reserved_qty, s._is_deleted, %(run)s
from staging.inventory_snapshots s
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
left join dw.dim_date dd on dd.full_date = s.snapshot_at::date
where s._changed_at > %(since)s
on conflict (snapshot_id) do update set
  product_key = excluded.product_key, warehouse_key = excluded.warehouse_key,
  snapshot_date_key = excluded.snapshot_date_key, snapshot_at = excluded.snapshot_at,
  snapshot_qty = excluded.snapshot_qty, reserved_qty = excluded.reserved_qty, available_qty = excluded.available_qty,
  is_deleted_in_source = excluded.is_deleted_in_source, dw_updated_at = now(), dw_last_run_id = excluded.dw_last_run_id
where (f.product_key, f.warehouse_key, f.snapshot_at, f.snapshot_qty, f.reserved_qty, f.is_deleted_in_source)
   is distinct from (excluded.product_key, excluded.warehouse_key, excluded.snapshot_at, excluded.snapshot_qty,
       excluded.reserved_qty, excluded.is_deleted_in_source)
returning (xmax = 0) as inserted
"""

# Late-arriving dimensions: a fact loaded with the Unknown member (key 0) gets its
# real key once the product/supplier/warehouse shows up, even if the fact itself
# did not change. Also keeps the estimated PO value in step with unit_cost changes.
FIXUPS = [
    ("fact_purchase_orders keys", """
update dw.fact_purchase_orders f set
  supplier_key = coalesce(ds.supplier_key, 0), product_key = coalesce(dp.product_key, 0),
  warehouse_key = coalesce(dwh.warehouse_key, 0), dw_updated_at = now(), dw_last_run_id = %(run)s
from staging.purchase_orders s
left join dw.dim_supplier ds on ds.supplier_id = s.supplier_id
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
where s.po_id = f.po_id and 0 in (f.supplier_key, f.product_key, f.warehouse_key)
  and (f.supplier_key, f.product_key, f.warehouse_key)
      is distinct from (coalesce(ds.supplier_key, 0), coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0))
"""),
    ("fact_purchase_orders est_order_value", """
update dw.fact_purchase_orders f set est_order_value = f.order_qty * p.unit_cost, dw_updated_at = now(),
       dw_last_run_id = %(run)s
from dw.dim_product p
where p.product_key = f.product_key and f.est_order_value is distinct from f.order_qty * p.unit_cost
"""),
    ("fact_goods_receipts keys", """
update dw.fact_goods_receipts f set
  supplier_key = coalesce(ds.supplier_key, 0), product_key = coalesce(dp.product_key, 0),
  warehouse_key = coalesce(dwh.warehouse_key, 0), dw_updated_at = now(), dw_last_run_id = %(run)s
from staging.goods_receipts s
left join staging.purchase_orders po on po.po_id = s.po_id
left join dw.dim_supplier ds on ds.supplier_id = po.supplier_id
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
where s.receipt_id = f.receipt_id and 0 in (f.supplier_key, f.product_key, f.warehouse_key)
  and (f.supplier_key, f.product_key, f.warehouse_key)
      is distinct from (coalesce(ds.supplier_key, 0), coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0))
"""),
    ("fact_sales_orders keys", """
update dw.fact_sales_orders f set
  product_key = coalesce(dp.product_key, 0), warehouse_key = coalesce(dwh.warehouse_key, 0),
  dw_updated_at = now(), dw_last_run_id = %(run)s
from staging.sales_orders s
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
where s.sales_order_id = f.sales_order_id and 0 in (f.product_key, f.warehouse_key)
  and (f.product_key, f.warehouse_key) is distinct from (coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0))
"""),
    ("fact_inventory_snapshot keys", """
update dw.fact_inventory_snapshot f set
  product_key = coalesce(dp.product_key, 0), warehouse_key = coalesce(dwh.warehouse_key, 0),
  dw_updated_at = now(), dw_last_run_id = %(run)s
from staging.inventory_snapshots s
left join dw.dim_product dp on dp.sku = s.sku
left join dw.dim_warehouse dwh on dwh.warehouse_id = s.warehouse_id
where s.snapshot_id = f.snapshot_id and 0 in (f.product_key, f.warehouse_key)
  and (f.product_key, f.warehouse_key) is distinct from (coalesce(dp.product_key, 0), coalesce(dwh.warehouse_key, 0))
"""),
]


def load_dw(conn: psycopg.Connection, run_id: int, settings) -> list[dict]:
    steps = []
    with conn.transaction():
        marks = {r["table_name"]: r["last_successful_watermark"] for r in conn.execute(
            "select table_name, last_successful_watermark from etl.etl_watermarks "
            "where pipeline_name = %s and source_system = %s and watermark_type = 'staging_changed_at'",
            (settings.pipeline_name, settings.source_system))}
        for dw_table, sources in DW_TABLES.items():
            since = conn.execute(
                "select coalesce(%(wm)s::timestamptz - make_interval(mins => %(lb)s), '1900-01-01'::timestamptz) as since",
                {"wm": marks.get(dw_table), "lb": settings.lookback_minutes}).fetchone()["since"]
            flags = [r["inserted"] for r in conn.execute(SQL[dw_table], {"since": since, "run": run_id})]
            newest = " union all ".join(f"select max(_changed_at) as m from staging.{s}" for s in sources)
            new_mark = conn.execute(f"select max(m) as m from ({newest}) x").fetchone()["m"]
            conn.execute("""
                insert into etl.etl_watermarks (pipeline_name, source_system, table_name, watermark_type,
                       last_successful_watermark, last_successful_run_id, last_successful_load_at, updated_at)
                values (%(p)s, %(s)s, %(t)s, 'staging_changed_at', %(wm)s, %(run)s, now(), now())
                on conflict (pipeline_name, source_system, table_name) do update set
                  last_successful_watermark = greatest(etl.etl_watermarks.last_successful_watermark, excluded.last_successful_watermark),
                  last_successful_run_id = excluded.last_successful_run_id,
                  last_successful_load_at = excluded.last_successful_load_at, updated_at = now()
            """, {"p": settings.pipeline_name, "s": settings.source_system, "t": dw_table, "wm": new_mark, "run": run_id})
            step = {"table": dw_table, "inserted": sum(flags), "updated": len(flags) - sum(flags)}
            steps.append(step)
            log.info("dw      %-28s new %5d  changed %5d", dw_table, step["inserted"], step["updated"])
        for name, stmt in FIXUPS:
            n = conn.execute(stmt, {"run": run_id}).rowcount
            if n:
                steps.append({"table": "fixup " + name, "inserted": 0, "updated": n})
                log.info("dw      fixup %-22s changed %5d", name, n)
    return steps
