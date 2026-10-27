# UniFirst ETL Console

A read-only web console for the data pipeline:

```
Source 1  SCM  (ERP, Supabase PostgreSQL, schema raw)  6 tables  \
                                                                   > Python ETL (every minute) -> Cloud data warehouse -> Power BI
Source 2  CRM  (Aiven PostgreSQL, schema crm)          6 tables  /     staging -> dw (star schema) -> analytics (calculation views)
```

**Portfolio demonstration on synthetic data.** It is not a UniFirst production system.

| Tab | Shows |
|---|---|
| Pipeline | both sources and their tables, the three warehouse layers, Power BI, and headline tiles (last run, last successful load, failures, rejected rows, data quality) |
| Source tables | per source table: warehouse table, load method (full compare or incremental), rows loaded, deleted in source, rejected, rows read last run, last load, status |
| Warehouse (dw) | each dimension and fact: grain, which source feeds it, rows, last load |
| Analytics views | every view in the `analytics` schema and what it is for |
| Load history | the last 30 ETL runs with counts and errors |
| Data quality | every check from `analytics.vw_data_quality` (OK / WARN / FAIL) |

It refreshes every 30 seconds. It cannot change anything: the ETL itself runs on Render (every minute) or from GitHub → Actions → Warehouse ETL.

## How it is put together

Same stack and look as the ERP and CRM apps: React + TypeScript + Vite on Vercel, sign-in with the ERP's Supabase Auth.

```
Browser (Vercel)  --sign-in token-->  Vercel Function /api/console  --etl_console_reader, TLS verified-->  Warehouse (Supabase)
                                                                       read-only, analytics views only
```

- The warehouse password never reaches the browser. Only the function knows `WAREHOUSE_CONSOLE_URL`.
- `etl_console_reader` can only `SELECT` the `analytics` views, its sessions are read-only, and every request also runs in a `READ ONLY` transaction.
- Any account with an ERP or CRM role (`viewer` or `operator`) may open the console. An optional `etl_role` in the user's app metadata overrides it.
- The views it reads are in `analytics-warehouse/sql/006_etl_console_views.sql`: `vw_etl_source_tables`, `vw_etl_warehouse_tables`, `vw_etl_analytics_views`, plus the existing `vw_etl_runs` and `vw_data_quality`.

```
api/console.ts            the only server endpoint (GET /api/console), a Vercel Function
api/_lib/                 config, database (read-only), sign-in check, handler
src/Console.tsx           the console screens
src/lib/summary.ts        headline numbers and source grouping (unit-tested)
tests/api.test.ts         API tests against a local warehouse
```

## Setup (browser only, about 10 minutes)

1. **Warehouse login.** The warehouse already has `sql/006_etl_console_views.sql`. In the warehouse project → SQL Editor, turn the login on with a new password (letters and numbers only, about 32 characters, kept in your password manager):
   `alter role etl_console_reader with login password 'PASTE-HERE';`
2. **Connection string.** Warehouse project → **Connect** → **Session pooler**. Replace `postgres.` at the start of the user with `etl_console_reader.` and put the password in:
   `postgresql://etl_console_reader.<warehouse-ref>:<password>@<pooler-host>:5432/postgres`
3. **Certificate.** Warehouse project → **Database settings** → **SSL Configuration** → **Download certificate**. Open the file in a text editor and copy all of it.
4. **Vercel.** Add New → Project → import this repository again, set **Root Directory** to `etl-console`, and add these environment variables:

   | Name | Value |
   |---|---|
   | `VITE_SUPABASE_URL` | the ERP project URL (same as in the CRM app) |
   | `VITE_SUPABASE_PUBLISHABLE_KEY` | the ERP publishable key (same as in the CRM app) |
   | `WAREHOUSE_CONSOLE_URL` | the string from step 2 |
   | `WAREHOUSE_DATABASE_CA` | the certificate text from step 3 |

   Then **Deploy**.
5. Open the site and sign in with your ERP account. Before the first ETL run every table shows **Never loaded**; after it, rows and times fill in.

## Local development and tests

```bash
npm install
npm test        # unit tests; the API tests also run when TEST_WAREHOUSE_URL is set
npm run build
```
