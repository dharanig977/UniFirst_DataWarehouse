# Warehouse on Neon (separate platform), step by step

The cloud data warehouse runs on its own platform, **Neon** (serverless PostgreSQL):

```
Source 1  SCM  Supabase PostgreSQL (ERP)   \
                                             > Python ETL (Render / GitHub Actions) -> Neon warehouse: staging -> dw -> analytics
Source 2  CRM  Aiven PostgreSQL (CRM)      /
```

Three platforms, one per job. Everything is done in the browser, and **passwords never go in chat, code or GitHub files**: only in your password manager, Neon's SQL Editor, and the secrets screens of GitHub, Render and Vercel.

> **Free plan facts that shape the design.** Neon's free plan has 0.5 GB of storage (this project uses a few MB) and a monthly allowance of compute hours. The database sleeps after 5 idle minutes and wakes in about a second on the next connection. So the scheduler checks in every **15 minutes**, not every minute: each check-in wakes the database, and an every-minute heartbeat would keep it awake all month. Check [neon.com/pricing](https://neon.com/pricing) for the current limits.

---

## Step 1: create the Neon project (you, about 3 minutes)

1. Go to [neon.com](https://neon.com) → **Sign up** → **Continue with GitHub**. No payment card is needed.
2. **Create project**:
   - Project name: `supply-chain-warehouse`
   - Postgres version: the default (17)
   - Region: **AWS US East (Ohio)**, close to the Supabase ERP
   - Database name: leave `neondb`
3. On the project dashboard click **Connect**. Turn **Connection pooling off**, because the ETL's run lock needs a direct connection. Then click **Show password** and copy the whole string. It looks like:
   `postgresql://neondb_owner:xxxx@ep-something-123456.us-east-2.aws.neon.tech/neondb?sslmode=require`
   This is the warehouse **owner** login. Keep it in your password manager.

## Step 2: save the owner string as a GitHub secret (you, 1 minute)

GitHub → this repository → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**:
- Name: `WAREHOUSE_ADMIN_URL`
- Value: the string from step 1.3

It is used only by the one-time build in step 3.

## Step 3: build the warehouse (one click)

**Actions** → **Warehouse ETL** → **Run workflow** → mode `setup` → **Run workflow**.

It runs `sql/001` to `sql/007` against the empty warehouse. Those scripts create the schemas `etl`, `staging`, `dw` and `analytics`, the calculation views, the console schedule, and three logins without passwords (`etl_loader`, `powerbi_reader`, `etl_console_reader`). It stops without changing anything if the warehouse already has tables, and it never connects to a source.

✅ **Check:** the last lines of the log list the schemas: `analytics`, `dw`, `etl` and `staging`.

## Step 4: turn the logins on (you, in Neon's SQL Editor)

Make one new password per login in your password manager, **letters and numbers only, about 32 characters**. Then, in Neon → **SQL Editor**, run one line at a time, typing the password there:

```sql
alter role etl_loader         with login password 'PASTE-HERE';  -- the ETL writes the warehouse
alter role powerbi_reader     with login password 'PASTE-HERE';  -- read-only, analytics views only
alter role etl_console_reader with login password 'PASTE-HERE';  -- the ETL console
```

## Step 5: connection strings for the ETL

Neon user names are plain (there is no `.project-ref` suffix like on Supabase). Take the host from step 1.3 and build:

- `WAREHOUSE_DATABASE_URL` = `postgresql://etl_loader:<password>@<host from step 1.3>/neondb?sslmode=require`

Put it in GitHub → **Secrets** → Actions (replacing the old Supabase value if there is one). The sources stay as they are:
- `SOURCE_DATABASE_URL`: `etl_reader` on the Supabase ERP (see `setup_guide.md`, Stages 2 and 3).
- `CRM_ETL_PASSWORD` and `CRM_DATABASE_CA`: `crm_etl_reader` on Aiven (see `crm_source.md`).

Then **Actions** → **Warehouse ETL** → mode `check`, then mode `run` (twice: the second run should load `new 0 changed 0`).

## Step 6: schedule

Render (`render.yaml`) starts the ETL every 15 minutes as a heartbeat, and the batch interval (15 minutes by default) is set in the ETL console. Render setup is in `setup_guide.md`, Stage 6. Paste the same three or four values (`SOURCE_DATABASE_URL`, `WAREHOUSE_DATABASE_URL`, `CRM_DATABASE_URL`, `CRM_DATABASE_CA`).

## What the reports read

Two sets of calculation views in the `analytics` schema, readable by `powerbi_reader`:

| Report | Views |
|---|---|
| Inventory | `vw_inventory_kpis`, `vw_purchase_order_exceptions`, `vw_supplier_performance`, `vw_sales_demand` |
| Customer Demand vs Actual vs Budget | `vw_demand_actual_budget` (uses `vw_current_budget_version`) |
| Data health | `vw_data_quality`, `vw_data_freshness` |

Connection details for a reporting tool: host from step 1.3, database `neondb`, user `powerbi_reader`, SSL required.
