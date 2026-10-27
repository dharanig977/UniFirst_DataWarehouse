# Supply-chain analytics warehouse

An analytics layer for the Supply Chain ERP app in this repo: a second Supabase PostgreSQL database used as a data warehouse, fed by a Python ETL job that runs every minute from two sources (the ERP and the CRM app's database), with SQL views built for Power BI.

**Portfolio demonstration on synthetic data.** It is not a UniFirst production system, and it does not connect to Microsoft Dynamics.

```mermaid
flowchart LR
  A[(ERP Supabase<br/>raw.* tables)] -- read-only etl_reader --> B[Python ETL<br/>Render cron, every minute]
  C[(CRM Aiven PostgreSQL<br/>crm.* tables)] -- read-only crm_etl_reader --> B
  B -- etl_loader --> S
  subgraph W [Warehouse Supabase]
    S[staging] --> D[dw star schema] --> V[analytics views]
    L[etl run log + watermarks]
  end
  V -- read-only powerbi_reader --> P[Power BI Desktop]
```

## What's here

```
sql/001_warehouse_schema.sql      etl, staging, dw schemas (tables, keys, indexes, dim_date, Unknown members)
sql/002_analytics_views.sql       7 Power BI views + a receipts-per-PO helper
sql/003_warehouse_roles.sql       etl_loader and powerbi_reader logins (no passwords in the file)
sql/004_crm_source.sql            CRM staging tables, dim_customer, dim_budget_version, demand + budget facts
sql/005_demand_actual_budget_views.sql   Demand vs Actual vs Budget view, CRM data-quality checks
sql/006_etl_console_views.sql     views behind the ETL console (../etl-console) and its read-only login
sql/007_etl_schedule.sql         batch schedule set from the console (pause, interval, Run now) and troubleshooting views
sql/source_etl_reader_role.sql    read-only etl_reader login for the SOURCE project
sql/validation_queries.sql        checks to run after each stage
etl/                              the pipeline: extract -> validate -> load staging -> load dw -> log
tests/                            23 tests (unit + end-to-end on a throwaway PostgreSQL)
docs/setup_guide.md               step-by-step setup, browser only
docs/data_model.md                grains, keys, measures, ER diagram, limitations
docs/etl_design.md                extraction strategy, validation rules, recovery, rerun
docs/powerbi_guide.md             connecting Power BI, DAX measures, report pages
docs/crm_source.md                the CRM source: incremental extract, demand/actual/budget model, setup, DAX
../render.yaml                    every-minute schedule on Render
../.github/workflows/             manual ETL button + tests on every pull request
```

## Key decisions

- **Change detection without timestamps.** The source tables have no `updated_at`/`created_at`, so each run reads them in full, in key-ordered batches inside one consistent read-only transaction, and compares a hash of every row. The warehouse then loads incrementally from its own `_changed_at` watermark. See `docs/etl_design.md`.
- **Idempotent everywhere.** Every load is an upsert on the source business key, so reruns and retries never duplicate rows.
- **Safe failure.** Watermarks move in the same transaction as the data, overlapping runs are blocked by an advisory lock, and an empty extract can't wipe the warehouse.
- **Two sources, two strategies.** The CRM tables do have a trigger-maintained `updated_at` and soft deletes, so they are read incrementally by watermark. The CRM is optional and isolated: if it is down, the ERP still loads. See `docs/crm_source.md`.
- **Nothing invented.** The ERP has no prices; selling prices and order amounts come only from the CRM. Values are labelled estimates at standard cost, and the limitations are listed in `docs/data_model.md`.

## Run the tests (needs any local PostgreSQL)

```bash
cd analytics-warehouse
pip install -r requirements-dev.txt
TEST_POSTGRES_URL=postgresql://postgres@localhost:5432/postgres python -m pytest -v
```

GitHub runs the same tests automatically on every pull request (`.github/workflows/warehouse-tests.yml`).
