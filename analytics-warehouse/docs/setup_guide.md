# Setup guide (beginner, browser only)

Everything below happens in a web browser: Supabase, GitHub and Render. You never need Python on your laptop, and **no password is ever pasted into chat, code or GitHub files**. Passwords go in three places only: your password manager, Supabase's SQL Editor (to set them), and the "secrets" screens of GitHub and Render.

Do the stages in order, and run the check at the end of each stage before moving on.

> **What this is.** A second Supabase project is a cloud-hosted PostgreSQL database used as a data warehouse for a portfolio project. It is *not* the same as a dedicated warehouse product like Snowflake or Microsoft Fabric Warehouse (columnar storage, separate compute, petabyte scale). The modelling, ETL and BI patterns are the same ones you would use there.

---

## Stage 1: create the warehouse project

1. Go to [supabase.com/dashboard](https://supabase.com/dashboard) → **New project**.
2. Organization: your existing one (`Interview_Supplychain`). The free plan allows two active projects.
3. Name: `supply-chain-analytics-warehouse`.
4. Database password: click **Generate a password**, then **copy it into your password manager** now. This is the warehouse's admin (`postgres`) password. You will rarely need it.
5. Region: **East US (Ohio)**, the same region as your ERP project, so the ETL travels a short distance.
6. Click **Create new project** and wait about 2 minutes.

**Create the schemas.** In the new project, open **SQL Editor** → **New query**. Paste the whole of each file, click **Run**, then do the next file:
1. `sql/001_warehouse_schema.sql`
2. `sql/002_analytics_views.sql`
3. `sql/003_warehouse_roles.sql`

All three only *create* things, and they're safe to run again.

✅ **Check:** run the first two blocks of `sql/validation_queries.sql`. You should see the 4 schemas and `dates = 1828`.

---

## Stage 2: create the logins and set their passwords

Three logins, each allowed to do only its job:

| Login | Lives in | Can do |
|---|---|---|
| `etl_reader` | ERP (source) project | read the six `raw` tables, nothing else |
| `etl_loader` | warehouse | read/write `etl`, `staging`, `dw`. Cannot drop tables |
| `powerbi_reader` | warehouse | read the `analytics` views only |

1. **Source project → SQL Editor**: run `sql/source_etl_reader_role.sql`. It creates one role, touches no table or data, and is undone with `drop role etl_reader;`. The last query should list 6 `SELECT` grants.
2. Make three new passwords in your password manager. Use **letters and numbers only, about 32 characters** (symbols like `@ : / #` break connection strings).
3. Turn each login on with its password. Type the password **directly in the SQL Editor**, never in chat or a file:
   - Source project: `alter role etl_reader with login password 'PASTE-HERE';`
   - Warehouse project: `alter role etl_loader with login password 'PASTE-HERE';`
   - Warehouse project: `alter role powerbi_reader with login password 'PASTE-HERE';`

   The SQL Editor's history keeps the query. If that bothers you, delete the query tab afterwards.

---

## Stage 3: build the two connection strings

In each project click **Connect** (top of the dashboard) → **Session pooler**. Use the session pooler, not "Direct connection" (IPv6 only, which GitHub and Render can't always reach) and not the "Transaction pooler" on port 6543 (it breaks the run lock). The string looks like:

```
postgresql://postgres.abcdefghijklmnop:[YOUR-PASSWORD]@aws-1-us-east-2.pooler.supabase.com:5432/postgres
```

Change two things: replace `postgres.` at the start of the user with your login's name, and put that login's password in place of `[YOUR-PASSWORD]`. Add `?sslmode=require` at the end.

- `SOURCE_DATABASE_URL` = `postgresql://etl_reader.<source-ref>:<etl_reader password>@<source pooler host>:5432/postgres?sslmode=require`
- `WAREHOUSE_DATABASE_URL` = `postgresql://etl_loader.<warehouse-ref>:<etl_loader password>@<warehouse pooler host>:5432/postgres?sslmode=require`

Your source project ref is `epvnsalihzmnrkqcxkoc`. Keep both strings only in your password manager.

---

## Stage 4: test the connections (GitHub Actions)

1. GitHub → your repo → **Settings** → **Secrets and variables** → **Actions** → **New repository secret**. Add `SOURCE_DATABASE_URL` and `WAREHOUSE_DATABASE_URL`. Secrets are encrypted, and GitHub hides them in logs.
2. **Actions** tab → **Warehouse ETL** → **Run workflow** → mode `check` → **Run workflow**.
3. Open the run and look at the "Check connections" step.

✅ **Check:** it shows `connected as etl_reader, read-only session: on`, six tables with row counts that are not 0, `schemas present: analytics, dw, etl, staging`, and `CHECK PASSED`.

If a table shows `0 rows visible`, the read role can't see the data: re-run `sql/source_etl_reader_role.sql`. If you see `password authentication failed`, check the user is `etl_reader.<ref>` (with the dot and the ref) and the password has no symbols.

---

## Stage 5: first manual ETL run, then validate

1. **Actions** → **Warehouse ETL** → **Run workflow** → mode `run`.
2. The log shows each table being extracted and loaded, then `Run 1 finished: success`.
3. Run it a second time. It should report `new 0 changed 0`, which proves reruns don't duplicate anything.

✅ **Check** (warehouse SQL Editor, `sql/validation_queries.sql` Stage 2 and 3 blocks):
- staging and dw counts match the source counts
- UFS-1001 @ KY-DC-01 reads **20 / 80 / 100 / 5 / 95**
- the "no double counting" pairs are equal
- `vw_data_quality` is all `OK`, or explains each `WARN`

Only switch on the schedule after this stage passes.

---

## Stage 6: run it every minute

### Which scheduler

| Option | Every minute? | Cost | Fit |
|---|---|---|---|
| **Render Cron Job** | Yes (1-minute minimum) | billed per second of runtime, with a $1/month minimum per cron job (check [render.com/pricing](https://render.com/pricing)) | **Recommended.** Real cron, Python, secrets screen, run history and logs, never overlaps runs, pause button |
| GitHub Actions schedule | No: 5-minute minimum, often delayed 5–30 min | free for public repos | already set up as a manual button; usable as a free 5-minute fallback |
| Supabase pg_cron | Yes | free | runs SQL inside the database, not this Python ETL. It would need the ETL rewritten as SQL plus a database-to-database link, so it doesn't fit |
| Your laptop | – | free | stops when the laptop sleeps, so it's not a schedule |

Render needs a payment card, and is expected to cost a few dollars a month at most for this job. If you'd rather stay free, uncomment the `schedule:` lines in `.github/workflows/warehouse-etl.yml`: you get roughly every 5–15 minutes instead of every minute.

### Render setup

1. Sign up at [render.com](https://render.com) with **GitHub**, and allow access to this repository.
2. **New** → **Blueprint** → pick this repo. Render reads `render.yaml`: one cron job, `supply-chain-etl`, schedule `* * * * *`, in Ohio.
3. Render asks for the two `sync: false` values. Paste `SOURCE_DATABASE_URL` and `WAREHOUSE_DATABASE_URL`. They're stored encrypted in Render, not in Git.
4. **Apply**. The first build installs the requirements, then the job runs every minute (UTC).

### How it works

- **Where the code runs:** a small container on Render that starts, runs `python -m etl.run --triggered-by schedule`, and exits.
- **What triggers it:** Render's scheduler, on the cron expression `* * * * *`.
- **Credentials:** Render environment variables (encrypted). The code reads them with `os.environ`.
- **Failures:** each run's log is on Render's **Runs** page, and every run is also recorded in `etl.etl_run_log` with its error. A failed run exits with code 1, so Render marks it red.
- **Overlaps:** Render never starts a run while the last one is active, and the warehouse advisory lock blocks anything else (for example, a manual GitHub run). The blocked run logs `skipped`.

✅ **Check it really runs every minute:** after 15 minutes, run the Stage 4 block of `sql/validation_queries.sql`. You should see about one run per minute. The **Runs** page on Render shows the same.

**Pause or stop:** Render → `supply-chain-etl` → **Settings** → **Suspend Cron Job** (and **Resume** later). Suspending stops runs and billing. To remove it completely, use **Delete Service**.

### What "every minute" really means

The job *starts* about once a minute. That's not a promise that Power BI shows data less than a minute old. Freshness also depends on:
- container start-up time (often 10–30 s on Render)
- how long the run takes (under a second today; it grows with data)
- whether anything changed in the source
- **Power BI refresh.** In Import mode, Power BI only sees new data when the report is refreshed. The Power BI service allows 8 scheduled refreshes a day on Pro. DirectQuery reads live, but is slower.

`analytics.vw_data_freshness` shows the real age of the data at any moment.

---

## Stage 7: Power BI

See `powerbi_guide.md`.
