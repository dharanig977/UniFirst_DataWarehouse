# ETL design

`python -m etl.run` runs one batch. Code: `etl/` (about 600 lines, one file per stage).

```
extract.py  ->  validate.py  ->  load_staging.py  ->  load_dw.py      run.py ties them together,
(read-only)     (clean+check)    (merge by hash)      (dims, facts)   logs the run, holds the lock
```

## 1. Extract: strategy per table

Checked in the real schema: **no table has `created_at`, `updated_at` or any other change marker**, and all IDs are text. So:

| Table | Change marker? | Strategy | Why it's safe |
|---|---|---|---|
| products, suppliers | none | full read + row-hash compare | tiny master data |
| purchase_orders | none (`order_date` is a business date; status changes keep the same row) | full read + row-hash compare | an UPDATE (e.g. status to Received) never changes the ID or `order_date`, so a date/ID watermark would miss it |
| goods_receipts | none (`receipt_date` has no time; backdated receipts are possible) | full read + row-hash compare | same |
| sales_orders | none (`shipped_qty` and `status` are updated in place) | full read + row-hash compare | same |
| inventory_snapshots | `snapshot_at` is a business time, not an insert time | full read + row-hash compare | a late-entered or corrected count would be missed by a time watermark |

A timestamp watermark here would be pretending. Instead, every run reads each table in key order, in batches of `ETL_BATCH_SIZE`, inside **one read-only REPEATABLE READ transaction**, so all six tables come from the same instant. With ~900 rows this takes well under a second. It stays practical up to roughly a few hundred thousand rows. Beyond that, the right fix is in the source (add an `updated_at` column with a trigger, or logical-replication CDC). That would be a change to the source schema, so it is listed as a future option, not done.

**Where the real incremental step happens.** Staging records `_changed_at` (a time the warehouse controls) whenever a row is new, changed or deleted. The dw load then uses a proper timestamp watermark on `_changed_at` with a `ETL_LOOKBACK_MINUTES` overlap. So: full compare at the edge (the only honest option), timestamp-incremental inside the warehouse.

## 2. Validate

Every rejected row is written to `etl.etl_rejected_records` with its business key, the full original row (JSON) and a plain-English reason. Nothing is dropped silently.

| Rule | Action |
|---|---|
| Required value missing (IDs, SKU, warehouse, qty, dates; `reserved_qty` on snapshots) | reject |
| `order_qty`, `received_qty` ≤ 0; any qty or cost < 0 | reject |
| Date before 2000 or more than a year ahead | reject |
| `expected_date` before `order_date` | reject |
| Two rows with the same business key after cleaning (e.g. `po-1` and `PO-1 `) | reject both |
| SKU/supplier/warehouse not found in dimensions | **keep**, map to Unknown (key 0), counted in `vw_data_quality` |
| Over-receipt, over-shipment, over-reservation, status that disagrees with receipts | **keep**: these are real business exceptions, surfaced in the views |

A rejection that stops happening (the source row was fixed or deleted) is marked `resolved_at`. A row rejected every minute keeps one record with a `times_rejected` counter.

If a row that was valid before becomes invalid, staging keeps its last good version (it is not marked deleted, because it still exists in the source).

## 3. Transform

Only changes that are justified and reversible:
- trim text; empty text → NULL
- upper-case code columns (`sku`, `warehouse_id`, IDs), the same rule the ERP app applies when it writes
- match statuses case-insensitively to the known spelling (`open` → `Open`)
- `sales_orders.shipped_qty` NULL → 0 (an order with nothing shipped). No other value is invented
- calculated measures in dw: `available_qty`, `open_qty`, `est_order_value`
- lineage: staging keeps `_first_seen_at`, `_changed_at`, `_last_seen_at`, `_last_run_id`; dw tables keep `dw_inserted_at`, `dw_updated_at`, `dw_last_run_id`

## 4. Load staging (per table, one transaction each)

1. Bulk `COPY` the cleaned rows into a temp table.
2. Insert new keys, update keys whose hash changed, mark missing keys `_is_deleted` (rows are never physically deleted).
3. **Mass-delete guard:** if a table's extract is empty, or more than `ETL_MAX_DELETE_PERCENT` of it would be marked deleted, that table fails instead. An RLS or grant problem on the source looks exactly like "everything was deleted", and this stops it from emptying the warehouse.
4. Record rejections, then update that table's extract watermark row in `etl.etl_watermarks`.

## 5. Load dimensions and facts (one transaction for all)

Order: warehouses, products, suppliers, then the four facts, then the late-arriving fix-ups. Every statement is `INSERT … ON CONFLICT (business key) DO UPDATE … WHERE something actually changed`, so:
- a retry or a rerun can never create a duplicate fact
- `records_updated` only counts real changes
- source deletes become `is_deleted_in_source = true` (views exclude them)

Each dw table's watermark moves **in the same transaction** as its data, so a crash can't leave a watermark ahead of the data.

## 6. Run log

`etl.etl_run_log` gets one row per run: start/end time, status, counts and errors, plus `step_details` (JSON, per-table counts).

| Status | Meaning |
|---|---|
| `success` | every table extracted, validated and loaded; nothing rejected |
| `partial_success` | warehouse loaded, but some rows were rejected or a single staging table failed (details in `error_details`) |
| `failed` | extract failed, every staging table failed, or the dw load failed. **Nothing in dw changed, and watermarks did not move** |
| `skipped` | another run still held the lock |

`records_inserted` / `records_updated` count dimension and fact rows, `records_deleted` counts source rows that disappeared, and `records_rejected` counts rows that failed validation.

## 7. Recovery

- **Overlaps are impossible.** A run takes a PostgreSQL advisory lock in the warehouse. A second run that starts meanwhile logs `skipped` and exits. The lock belongs to the connection, so a crashed run releases it automatically. Render also never starts a cron job while the previous run is active.
- **Retries:** connection drops, timeouts and deadlocks are retried up to `ETL_MAX_RETRIES` times (waits of 2 s, 4 s…), each time on a fresh connection. Every step is idempotent, so retrying is safe.
- **A crash halfway** leaves committed staging tables (correct and complete per table) and either all or none of the dw load. The next run finds the staging changes through the dw watermark and finishes the job. A run left in `running` is marked `failed` by the next run.
- **To rerun a failed batch:** fix the cause shown in `error_details`, then run again (Render "Trigger Run", the GitHub Action, or `python -m etl.run`). There is no batch ID to replay: each run reloads the current source state, which is the full truth.
- **To rebuild a dw table from scratch:** delete its watermark row (`delete from etl.etl_watermarks where table_name = 'dw.fact_sales_orders';`) and run. Everything in staging is reprocessed as an upsert, with no duplicates.
