"""Shared fixtures for the end-to-end tests (local PostgreSQL only, never Supabase)."""
import os
from pathlib import Path

import psycopg
import pytest

from etl.config import Settings

ADMIN = os.environ.get("TEST_POSTGRES_URL")
ROOT = Path(__file__).resolve().parents[1]
WAREHOUSE_SQL = ("001_warehouse_schema.sql", "002_analytics_views.sql", "003_warehouse_roles.sql",
                 "004_crm_source.sql", "005_demand_actual_budget_views.sql")


def _url(db):
    return psycopg.conninfo.make_conninfo(ADMIN, dbname=db)


SEED = """
insert into raw.products values ('UFS-1001','Industrial Work Shirt','Uniforms',18.50),('PPE-2001','Safety Gloves','PPE',4.25);
insert into raw.suppliers values ('SUP-001','Northstar Apparel Supply',7),('SUP-002','SafeHands Industrial',5);
insert into raw.purchase_orders values
  ('PO-10001','SUP-001','UFS-1001','KY-DC-01',100,'2026-10-10','2026-10-20','Open'),
  ('PO-10002','SUP-002','PPE-2001','KY-DC-01',200,'2026-10-18','2026-10-25','Open');
insert into raw.goods_receipts values ('GR-50001','PO-10001','UFS-1001','KY-DC-01',80,'2026-10-24');
insert into raw.sales_orders values ('SO-70001','UFS-1001','KY-DC-01',12,5,'2026-10-23','Partially Shipped');
insert into raw.inventory_snapshots values ('INV-90001','UFS-1001','KY-DC-01',20,5,'2026-10-23 08:00');
"""


@pytest.fixture
def env():
    with psycopg.connect(ADMIN, autocommit=True) as c:
        for db in ("etl_test_source", "etl_test_wh"):
            c.execute(f"drop database if exists {db} with (force)")
            c.execute(f"create database {db}")
    with psycopg.connect(_url("etl_test_source"), autocommit=True) as c:
        c.execute((ROOT / "tests/source_schema.sql").read_text())
        c.execute(SEED)
    with psycopg.connect(_url("etl_test_wh"), autocommit=True) as c:
        for f in WAREHOUSE_SQL:
            c.execute((ROOT / "sql" / f).read_text())
    settings = Settings(source_url=_url("etl_test_source"), warehouse_url=_url("etl_test_wh"), batch_size=1,
                        lookback_minutes=5, max_retries=1, statement_timeout_s=30, max_delete_fraction_pct=20)
    src = psycopg.connect(_url("etl_test_source"), autocommit=True)
    wh = psycopg.connect(_url("etl_test_wh"), autocommit=True)
    yield settings, src, wh
    src.close()
    wh.close()


def one(conn, q, *a):
    return conn.execute(q, a).fetchone()[0]


def last_run(wh):
    return wh.execute("select status, records_inserted, records_updated, records_deleted, records_rejected "
                      "from etl.etl_run_log where status <> 'skipped' order by run_id desc limit 1").fetchone()
