"""Run the pipeline once:  python -m etl.run

  python -m etl.run                 one ETL batch (what the scheduler calls)
  python -m etl.run --check         only test both connections and permissions, change nothing
  python -m etl.run --triggered-by schedule

Exit code 0 = success, partial_success or skipped (another run was busy).
Exit code 1 = failed, so the scheduler shows the run as failed.
"""
import argparse
import datetime as dt
import json
import logging
import sys
import traceback

from . import db
from .config import load_settings
from .extract import extract_all
from .load_dw import load_dw
from .load_staging import merge_table
from .tables import ALL_TABLES
from .validate import validate

log = logging.getLogger("etl")

LOCK_SQL = "select pg_try_advisory_lock(hashtext(%s)) as got"


def check(settings) -> int:
    ok = True
    try:
        with db.connect_source(settings.source_url, settings.statement_timeout_s) as src:
            with src.transaction():
                who = src.execute("select current_user as u, current_setting('transaction_read_only') as ro").fetchone()
                print(f"source    connected as {who['u']}, read-only session: {who['ro']}")
                for t in ALL_TABLES:
                    n = src.execute(f"select count(*) as n from raw.{t.name}").fetchone()["n"]
                    print(f"source    raw.{t.name:<20} {n:>6} rows visible")
                    if n == 0:
                        ok = False
                        print("          ^ 0 rows. If the table really has rows, the ETL role cannot see them (RLS/grants).")
    except Exception as exc:
        ok = False
        print(f"source    FAILED: {exc}")
    try:
        with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s, autocommit=True) as wh:
            who = wh.execute("select current_user as u, version() as v").fetchone()
            print(f"warehouse connected as {who['u']}: {who['v'].split(',')[0]}")
            schemas = [r["nspname"] for r in wh.execute(
                "select nspname from pg_namespace where nspname in ('etl','staging','dw','analytics') order by 1")]
            print(f"warehouse schemas present: {', '.join(schemas) or 'none (run sql/001 and sql/002 first)'}")
            ok = ok and len(schemas) == 4
    except Exception as exc:
        ok = False
        print(f"warehouse FAILED: {exc}")
    print("CHECK PASSED" if ok else "CHECK FAILED")
    return 0 if ok else 1


def run(settings, triggered_by: str) -> int:
    lock_conn = db.with_retries("connect to warehouse", settings.max_retries, db.connect_warehouse,
                                settings.warehouse_url, settings.statement_timeout_s, autocommit=True)
    with lock_conn:
        # Only one run at a time. The lock lives as long as this connection, so a
        # crashed run releases it automatically.
        if not lock_conn.execute(LOCK_SQL, (settings.pipeline_name,)).fetchone()["got"]:
            lock_conn.execute("""
                insert into etl.etl_run_log (pipeline_name, source_system, triggered_by, status, ended_at, error_details)
                values (%s, %s, %s, 'skipped', now(), 'previous run still in progress')""",
                (settings.pipeline_name, settings.source_system, triggered_by))
            log.warning("Another run is still in progress. Skipping this one.")
            return 0

        # We hold the lock, so any run still marked 'running' died without finishing.
        stale = lock_conn.execute("""
            update etl.etl_run_log set status = 'failed', ended_at = now(),
                   error_details = coalesce(error_details, '') || 'process stopped before finishing (detected by a later run)'
            where pipeline_name = %s and status = 'running' returning run_id""", (settings.pipeline_name,)).fetchall()
        if stale:
            log.warning("Marked %d interrupted run(s) as failed: %s", len(stale), [r["run_id"] for r in stale])

        row = lock_conn.execute("""
            insert into etl.etl_run_log (pipeline_name, source_system, triggered_by)
            values (%s, %s, %s) returning run_id, started_at""",
            (settings.pipeline_name, settings.source_system, triggered_by)).fetchone()
        run_id, run_ts = row["run_id"], row["started_at"]
        log.info("Run %d started (%s)", run_id, triggered_by)

        totals = {"extracted": 0, "inserted": 0, "updated": 0, "deleted": 0, "rejected": 0}
        steps, errors = [], []
        status = "failed"
        try:
            # 1. Extract (read-only, one consistent snapshot of all tables)
            def _extract():
                with db.connect_source(settings.source_url, settings.statement_timeout_s) as src:
                    return extract_all(src, ALL_TABLES, settings.batch_size)
            extracted = db.with_retries("extract", settings.max_retries, _extract)
            totals["extracted"] = sum(len(rows) for rows in extracted.values())

            # 2-4. Validate, transform and load staging, one transaction per table.
            # Each attempt opens a fresh connection, so a retry never reuses a broken one.
            def _merge(table, accepted, rejected, n):
                with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s) as wh:
                    return merge_table(wh, table, accepted, rejected, n, run_id, run_ts, settings)

            def _load_dw():
                with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s) as wh:
                    return load_dw(wh, run_id, settings)

            today = dt.date.today()
            staged_ok = 0
            for table in ALL_TABLES:
                raw_rows = extracted[table.name]
                accepted, rejected = validate(table, raw_rows, today)
                try:
                    stats = db.with_retries(f"staging {table.name}", settings.max_retries, _merge,
                                            table, accepted, rejected, len(raw_rows))
                    staged_ok += 1
                    steps.append({"step": "staging", **stats})
                    totals["deleted"] += stats["deleted"]
                    totals["rejected"] += stats["rejected"]
                except Exception as exc:  # keep going: other tables can still load
                    errors.append(f"staging {table.name}: {exc}")
                    steps.append({"step": "staging", "table": table.name, "error": str(exc)})
                    log.error("staging %s failed: %s", table.name, exc)

            if staged_ok == 0:
                raise RuntimeError("every staging table failed")

            # 5. Dimensions and facts (one transaction; watermarks move only on commit)
            # records_inserted / records_updated count warehouse (dim + fact) rows;
            # the per-table staging counts are kept in step_details.
            for s in db.with_retries("dw load", settings.max_retries, _load_dw):
                steps.append({"step": "dw", **s})
                totals["inserted"] += s["inserted"]
                totals["updated"] += s["updated"]

            status = "partial_success" if errors or totals["rejected"] else "success"
        except Exception as exc:
            errors.append(f"{type(exc).__name__}: {exc}")
            log.error("Run %d failed:\n%s", run_id, traceback.format_exc())
            status = "failed"
        finally:
            # 6. Log the run. Never "success" if a required stage failed.
            lock_conn.execute("""
                update etl.etl_run_log set status = %s, ended_at = now(), records_extracted = %s,
                       records_inserted = %s, records_updated = %s, records_deleted = %s, records_rejected = %s,
                       error_details = %s, step_details = %s::jsonb
                where run_id = %s""",
                (status, totals["extracted"], totals["inserted"], totals["updated"], totals["deleted"],
                 totals["rejected"], "\n".join(errors) or None, json.dumps(steps, default=str), run_id))
            lock_conn.execute("select pg_advisory_unlock(hashtext(%s))", (settings.pipeline_name,))
        log.info("Run %d finished: %s  extracted %d  new %d  changed %d  deleted %d  rejected %d",
                 run_id, status, totals["extracted"], totals["inserted"], totals["updated"],
                 totals["deleted"], totals["rejected"])
        return 1 if status == "failed" else 0


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Supply-chain ETL: source Supabase -> warehouse")
    parser.add_argument("--check", action="store_true", help="test connections only, change nothing")
    parser.add_argument("--triggered-by", default="manual", choices=["manual", "schedule", "test"])
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    settings = load_settings()
    return check(settings) if args.check else run(settings, args.triggered_by)


if __name__ == "__main__":
    sys.exit(main())
