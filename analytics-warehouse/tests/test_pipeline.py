"""End-to-end tests against a throwaway local PostgreSQL (never Supabase).

Set TEST_POSTGRES_URL to an admin connection on a local server, e.g.
    TEST_POSTGRES_URL=postgresql://postgres@127.0.0.1:5432/postgres
The env fixture (conftest.py) creates fresh databases etl_test_source and etl_test_wh.
"""

import psycopg
import pytest

from conftest import ADMIN, last_run, one
from etl.run import run

pytestmark = pytest.mark.skipif(not ADMIN, reason="TEST_POSTGRES_URL not set")


def test_first_load_and_rerun_is_idempotent(env):
    settings, src, wh = env
    assert run(settings, "test") == 0
    assert last_run(wh)[0] == "success"
    assert one(wh, "select count(*) from dw.fact_purchase_orders") == 2
    # batch_size=1 forces many extract batches; nothing is lost or duplicated
    assert one(wh, "select count(*) from staging.purchase_orders") == 2
    assert run(settings, "test") == 0
    assert last_run(wh)[:4] == ("success", 0, 0, 0)
    assert one(wh, "select count(*) from dw.fact_purchase_orders") == 2


def test_business_scenario_ufs1001(env):
    settings, src, wh = env
    run(settings, "test")
    row = wh.execute("""select reported_on_hand_qty, receipts_after_snapshot_qty, calculated_on_hand_qty,
                               reported_reserved_qty, calculated_available_qty
                        from analytics.vw_inventory_kpis where snapshot_id = 'INV-90001'""").fetchone()
    assert row == (20, 80, 100, 5, 95)


def test_updates_and_deletes_flow_through(env):
    settings, src, wh = env
    run(settings, "test")
    src.execute("update raw.purchase_orders set status = 'Partially Received' where po_id = 'PO-10001'")
    src.execute("insert into raw.sales_orders values ('SO-70002','PPE-2001','KY-DC-01',60,0,'2026-10-24','Open')")
    src.execute("delete from raw.sales_orders where sales_order_id = 'SO-70001'")
    assert run(settings, "test") == 0
    assert one(wh, "select status from dw.fact_purchase_orders where po_id = 'PO-10001'") == "Partially Received"
    assert one(wh, "select is_deleted_in_source from dw.fact_sales_orders where sales_order_id = 'SO-70001'") is True
    assert one(wh, "select count(*) from analytics.vw_sales_demand") == 1
    status, ins, upd, deleted, _ = last_run(wh)
    assert (status, ins, upd, deleted) == ("success", 1, 2, 1)   # +SO-70002, PO-10001 & SO-70001 changed


def test_rejected_rows_are_logged_then_resolved(env):
    settings, src, wh = env
    src.execute("insert into raw.purchase_orders values ('PO-10003','SUP-001','UFS-1001','KY-DC-01',-5,'2026-10-12','2026-10-22','Open')")
    run(settings, "test")
    assert last_run(wh)[0] == "partial_success"
    run(settings, "test")   # same bad row again: still one rejection record, counted twice
    assert one(wh, "select times_rejected from etl.etl_rejected_records where business_key = 'PO-10003'") == 2
    assert one(wh, "select count(*) from dw.fact_purchase_orders where po_id = 'PO-10003'") == 0
    src.execute("update raw.purchase_orders set order_qty = 5 where po_id = 'PO-10003'")
    run(settings, "test")
    assert last_run(wh)[0] == "success"
    assert one(wh, "select resolved_at is not null from etl.etl_rejected_records where business_key = 'PO-10003'")
    assert one(wh, "select order_qty from dw.fact_purchase_orders where po_id = 'PO-10003'") == 5


def test_late_arriving_product_gets_real_key(env):
    settings, src, wh = env
    # Product exists but is invalid (negative cost) -> rejected; its PO loads with the Unknown product.
    src.execute("insert into raw.products values ('NEW-1','New item','PPE',-1)")
    src.execute("insert into raw.purchase_orders values ('PO-10009','SUP-001','NEW-1','KY-DC-01',10,'2026-10-20','2026-10-27','Open')")
    run(settings, "test")
    assert one(wh, "select product_key from dw.fact_purchase_orders where po_id = 'PO-10009'") == 0
    src.execute("update raw.products set unit_cost = 3 where sku = 'NEW-1'")
    run(settings, "test")
    assert one(wh, "select p.sku from dw.fact_purchase_orders f join dw.dim_product p using (product_key) "
                   "where po_id = 'PO-10009'") == "NEW-1"


def test_empty_extract_cannot_wipe_the_warehouse(env):
    settings, src, wh = env
    run(settings, "test")
    src.execute("delete from raw.inventory_snapshots")   # looks exactly like an RLS/permission problem
    assert run(settings, "test") == 0
    assert last_run(wh)[0] == "partial_success"
    assert one(wh, "select count(*) from staging.inventory_snapshots where not _is_deleted") == 1


def test_failed_dw_load_keeps_watermark_and_recovers(env):
    settings, src, wh = env
    run(settings, "test")
    mark = one(wh, "select last_successful_watermark from etl.etl_watermarks where table_name = 'dw.fact_sales_orders'")
    src.execute("insert into raw.sales_orders values ('SO-70009','PPE-2001','KY-DC-01',7,0,'2026-10-25','Open')")
    wh.execute("alter table dw.fact_sales_orders add constraint t_block check (sales_order_id <> 'SO-70009')")
    assert run(settings, "test") == 1
    assert last_run(wh)[0] == "failed"
    assert one(wh, "select last_successful_watermark from etl.etl_watermarks "
                   "where table_name = 'dw.fact_sales_orders'") == mark
    wh.execute("alter table dw.fact_sales_orders drop constraint t_block")
    assert run(settings, "test") == 0     # staging already has the row; dw catches up via the watermark
    assert one(wh, "select count(*) from dw.fact_sales_orders where sales_order_id = 'SO-70009'") == 1


def test_overlapping_run_is_skipped(env):
    settings, src, wh = env
    holder = psycopg.connect(settings.warehouse_url, autocommit=True)
    holder.execute("select pg_advisory_lock(hashtext(%s))", (settings.pipeline_name,))
    try:
        assert run(settings, "test") == 0
        assert one(wh, "select status from etl.etl_run_log order by run_id desc limit 1") == "skipped"
        assert one(wh, "select count(*) from staging.products") == 0
    finally:
        holder.close()
    assert run(settings, "test") == 0
    assert last_run(wh)[0] == "success"


def test_interrupted_run_is_marked_failed_by_next_run(env):
    settings, src, wh = env
    wh.execute("insert into etl.etl_run_log (pipeline_name, source_system) values (%s, %s)",
               (settings.pipeline_name, settings.source_system))
    run(settings, "test")
    assert one(wh, "select count(*) from etl.etl_run_log where status = 'running'") == 0
    assert one(wh, "select status from etl.etl_run_log order by run_id limit 1") == "failed"


def test_source_session_is_read_only(env):
    settings, src, wh = env
    from etl.db import connect_source
    with connect_source(settings.source_url, 10) as conn:
        with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
            conn.execute("insert into raw.suppliers values ('X','x',1)")
