"""End-to-end tests for the CRM source (demand, actuals, budget) on a local PostgreSQL.

The ERP and warehouse come from the env fixture (conftest.py), plus a third database etl_test_crm built from
tests/crm_schema.sql (a copy of db/001_crm_schema.sql in the UniFirst_CRM repo).
"""
import dataclasses

import psycopg
import pytest

from conftest import ADMIN, ROOT, _url, last_run, one
from etl.run import run

pytestmark = pytest.mark.skipif(not ADMIN, reason="TEST_POSTGRES_URL not set")

CRM_SEED = """
insert into crm.price_list (sku, product_name, category, list_price) values
  ('UFS-1001','Industrial Work Shirt','Uniforms',30.00), ('PPE-2001','Safety Gloves','PPE',7.00);
insert into crm.accounts (account_id, account_name, segment, home_warehouse_id, discount_pct) values
  ('ACC-1001','Bluegrass Metal Works','Enterprise','KY-DC-01',10), ('ACC-1002','Derby City Foods','Mid-Market','KY-DC-01',0);
insert into crm.budget_versions (budget_version, fiscal_year, version_status) values ('FY2027 Original', 2027, 'Approved');
insert into crm.demand_forecasts (account_id, sku, forecast_month, forecast_qty, unit_price) values
  ('ACC-1001','UFS-1001','2026-10-01',15,null),     -- priced from list less 10%: 27.00
  ('ACC-1002','PPE-2001','2026-10-01',50,6.50);     -- quoted price
insert into crm.sales_budgets (budget_version, account_id, sku, budget_month, budget_qty, budget_amount) values
  ('FY2027 Original','ACC-1001','UFS-1001','2026-10-01',10,270.00),
  ('FY2027 Original','ACC-1002','PPE-2001','2026-10-01',40,280.00);
insert into crm.orders (erp_sales_order_id, account_id, sku, order_date, order_qty, unit_price) values
  ('SO-70001','ACC-1001','UFS-1001','2026-10-23',12,27.00);
"""


@pytest.fixture
def crm_env(env):
    settings, src, wh = env
    with psycopg.connect(ADMIN, autocommit=True) as c:
        c.execute("drop database if exists etl_test_crm with (force)")
        c.execute("create database etl_test_crm")
    crm = psycopg.connect(_url("etl_test_crm"), autocommit=True)
    crm.execute((ROOT / "tests/crm_schema.sql").read_text())
    crm.execute(CRM_SEED)
    yield dataclasses.replace(settings, crm_url=_url("etl_test_crm"), lookback_minutes=0), src, wh, crm
    crm.close()


def dab(wh, account, sku):
    return wh.execute("""
        select demand_qty, actual_qty, budget_qty, demand_amount, actual_amount, budget_amount
        from analytics.vw_demand_actual_budget
        where account_id = %s and product_id = %s and month_start = '2026-10-01'""", (account, sku)).fetchone()


def test_demand_actual_budget_first_load(crm_env):
    settings, src, wh, crm = crm_env
    assert run(settings, "test") == 0
    assert last_run(wh)[0] == "success"
    assert dab(wh, "ACC-1001", "UFS-1001") == (15, 12, 10, 405, 324, 270)   # 15 x 27.00, 12 x 27.00
    assert dab(wh, "ACC-1002", "PPE-2001") == (50, 0, 40, 325, 0, 280)      # 50 x 6.50 quoted
    # Totals still tie to the ERP and the CRM
    assert one(wh, "select sum(actual_qty) from analytics.vw_demand_actual_budget") == 12
    assert one(wh, "select sum(demand_qty) from analytics.vw_demand_actual_budget") == 65
    assert one(wh, "select price_basis from dw.fact_demand_forecast where account_id = 'ACC-1001'") \
        == "List less account discount"
    assert one(wh, "select list_price from dw.dim_product where sku = 'UFS-1001'") == 30
    # Rerun: incremental read finds nothing new, nothing changes
    assert run(settings, "test") == 0
    assert last_run(wh)[:4] == ("success", 0, 0, 0)


def test_unlinked_erp_order_goes_to_unknown_customer(crm_env):
    settings, src, wh, crm = crm_env
    src.execute("insert into raw.sales_orders values ('SO-70002','PPE-2001','KY-DC-01',60,0,'2026-10-24','Open')")
    run(settings, "test")
    assert one(wh, "select customer_key from dw.fact_sales_orders where sales_order_id = 'SO-70002'") == 0
    assert one(wh, "select issue_count from analytics.vw_data_quality "
                   "where check_name = 'Sales orders not linked to a CRM customer'") == 1
    # Linking it in the CRM later moves the actual onto the customer
    crm.execute("insert into crm.orders (erp_sales_order_id, account_id, sku, order_date, order_qty, unit_price) "
                "values ('SO-70002','ACC-1002','PPE-2001','2026-10-24',60,6.50)")
    run(settings, "test")
    assert dab(wh, "ACC-1002", "PPE-2001")[1:5:3] == (60, 390)
    assert one(wh, "select count(*) from dw.fact_sales_orders where customer_key = 0") == 0


def test_crm_changes_and_soft_deletes_flow_through(crm_env):
    settings, src, wh, crm = crm_env
    run(settings, "test")
    crm.execute("update crm.demand_forecasts set forecast_qty = 20 where account_id = 'ACC-1001'")
    crm.execute("update crm.price_list set list_price = 40 where sku = 'UFS-1001'")       # 40 less 10% = 36
    crm.execute("update crm.sales_budgets set is_deleted = true where account_id = 'ACC-1002'")
    crm.execute("update crm.orders set is_deleted = true where erp_sales_order_id = 'SO-70001'")
    assert run(settings, "test") == 0
    assert dab(wh, "ACC-1001", "UFS-1001") == (20, 0, 10, 720, 0, 270)
    assert dab(wh, "ACC-1002", "PPE-2001") == (50, 0, 0, 325, 0, 0)
    # The ERP order is still there; with its CRM link deleted it moves to Unknown
    assert one(wh, "select customer_key from dw.fact_sales_orders where sales_order_id = 'SO-70001'") == 0
    assert one(wh, "select count(*) from etl.etl_watermarks where watermark_type = 'source_updated_at'") == 6


def test_only_the_current_approved_budget_counts(crm_env):
    settings, src, wh, crm = crm_env
    crm.execute("insert into crm.budget_versions values ('FY2027 Reforecast Q2', 2027, 'Draft')")
    crm.execute("insert into crm.sales_budgets (budget_version, account_id, sku, budget_month, budget_qty, budget_amount) "
                "values ('FY2027 Reforecast Q2','ACC-1001','UFS-1001','2026-10-01',99,999)")
    run(settings, "test")
    assert dab(wh, "ACC-1001", "UFS-1001")[2] == 10       # Draft ignored
    crm.execute("update crm.budget_versions set version_status = 'Approved' where budget_version = 'FY2027 Reforecast Q2'")
    run(settings, "test")
    assert dab(wh, "ACC-1001", "UFS-1001")[2] == 99       # newest Approved version wins
    assert one(wh, "select budget_version from analytics.vw_current_budget_version") == "FY2027 Reforecast Q2"


def test_crm_outage_still_loads_the_erp(crm_env):
    settings, src, wh, crm = crm_env
    broken = dataclasses.replace(settings, crm_url=_url("etl_test_no_such_db"))
    assert run(broken, "test") == 0
    status = last_run(wh)[0]
    assert status == "partial_success"
    assert one(wh, "select count(*) from dw.fact_sales_orders") == 1
    assert one(wh, "select error_details like 'extract CRM%%' from etl.etl_run_log order by run_id desc limit 1")
    assert run(settings, "test") == 0                     # CRM back: catches up
    assert last_run(wh)[0] == "success"
    assert dab(wh, "ACC-1001", "UFS-1001")[1] == 12


def test_crm_source_session_is_read_only(crm_env):
    settings, src, wh, crm = crm_env
    from etl.db import connect_source
    with connect_source(settings.crm_url, 10) as conn:
        with pytest.raises(psycopg.errors.ReadOnlySqlTransaction):
            conn.execute("update crm.accounts set account_name = 'x'")
