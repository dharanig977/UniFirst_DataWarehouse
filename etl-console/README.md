# UniFirst ETL Console

A web console to monitor, schedule and troubleshoot the data pipeline:

```
Source 1  SCM  (ERP, Supabase PostgreSQL, schema raw)  6 tables  \
                                                                   > Python ETL (scheduled) -> Cloud data warehouse (Neon) -> Power BI
Source 2  CRM  (Aiven PostgreSQL, schema crm)          6 tables  /     staging -> dw (star schema) -> analytics (calculation views)
```

**Portfolio demonstration on synthetic data.** It is not a UniFirst production system.

| Tab | Shows |
|---|---|
| Pipeline | both sources and their tables, the three warehouse layers, Power BI, and headline tiles (schedule, last run, last successful load, failures, rejected rows, data quality) |
| Schedule & runs | the batch schedule (on/paused, every 1 min to once a day, scheduler heartbeat, next run), **Run now**, and the last 30 runs; click a run to see rows read, new, changed, deleted and rejected per table |
| Tables by schema | `staging` grouped by Source 1 SCM and Source 2 CRM (load method, rows loaded, status), then `dw` dimensions and facts, then the `analytics` calculation views |
| Troubleshoot | health checks, failed and partial runs with a plain-English hint, rejected rows with the reason and source values, and who changed the schedule |
| Data quality | every check from `analytics.vw_data_quality` (OK / WARN / FAIL) |

It refreshes every 30 seconds.

**Scheduling.** The scheduler (Render cron) starts the ETL every 15 minutes as a heartbeat. The ETL reads `etl.etl_schedule` first and only runs a batch when the schedule is on and the interval has passed, or when someone pressed **Run now** (which works even while paused). Changing the schedule needs the `operator` role; viewers can see everything but change nothing.

## How it is put together

Same stack and look as the ERP and CRM apps: React + TypeScript + Vite on Vercel, sign-in with the ERP's Supabase Auth.

```
Browser (Vercel)  --sign-in token-->  Vercel Function /api/console  --etl_console_reader, TLS verified-->  Warehouse (Supabase)
                                                          reads analytics views; writes only via console.* functions
```

- The warehouse password never reaches the browser. Only the function knows `WAREHOUSE_CONSOLE_URL`.
- `etl_console_reader` can only `SELECT` the `analytics` views and `EXECUTE` three functions in the `console` schema (`set_schedule`, `request_run`, `cancel_run_request`, from `sql/007_etl_schedule.sql`). They check their inputs and log every call to `etl.etl_console_actions`. It has no direct access to any table, its sessions default to read-only, and reads run in a `READ ONLY` transaction.
- Any account with an ERP or CRM role (`viewer` or `operator`) may open the console; only `operator` can change the schedule or press Run now. An optional `etl_role` in the user's app metadata overrides it.
- The views it reads are in `analytics-warehouse/sql/006_etl_console_views.sql`: `vw_etl_source_tables`, `vw_etl_warehouse_tables`, `vw_etl_analytics_views`, plus the existing `vw_etl_runs` and `vw_data_quality`.

```
api/console.ts            the only server endpoint (GET, and POST for schedule actions), a Vercel Function
api/_lib/                 config, database (read-only), sign-in check, handler
src/Console.tsx           the console screens
src/lib/summary.ts        headline numbers and source grouping (unit-tested)
tests/api.test.ts         API tests against a local warehouse
```

## Setup (browser only, about 10 minutes)

1. **Warehouse login.** The warehouse needs `sql/006_etl_console_views.sql` and `sql/007_etl_schedule.sql`. In the warehouse project → SQL Editor, turn the login on with a new password (letters and numbers only, about 32 characters, kept in your password manager):
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
