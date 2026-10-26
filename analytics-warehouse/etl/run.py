"""Run the pipeline once:  python -m etl.run

  python -m etl.run                 one ETL batch (what the scheduler calls)
  python -m etl.run --check         only test the connections and permissions, change nothing
  python -m etl.run --triggered-by schedule

Sources: the ERP (always) and the CRM (only when CRM_DATABASE_URL is set).

Exit code 0 = success, partial_success or skipped (another run was busy).
Exit code 1 = failed, so the scheduler shows the run as failed.
"""
import argparse
import datetime as dt
import json
import logging
import sys
import traceback
from dataclasses import dataclass

from . import db
from .config import load_settings
from .extract import extract_all
from .load_dw import load_dw
from .load_staging import merge_table
from .tables import CRM_TABLES, ERP_TABLES
from .validate import validate

log = logging.getLogger("etl")

LOCK_SQL = "select pg_try_advisory_lock(hashtext(%s)) as got"


@dataclass(frozen=True)
class Source:
    label: str      # ERP / CRM, for logs
    system: str     # source_system value in the etl tables
    url: str
    tables: tuple


def sources(settings) -> list[Source]:
    found = [Source("ERP", settings.source_system, settings.source_url, ERP_TABLES)]
    if settings.crm_url:
        found.append(Source("CRM", settings.crm_source_system, settings.crm_url, CRM_TABLES))
    return found


def check(settings) -> int:
    ok = True
    for src in sources(settings):
        tag = f"{src.label.lower():<9}"
        try:
            with db.connect_source(src.url, settings.statement_timeout_s) as conn:
                with conn.transaction():
                    who = conn.execute("select current_user as u, current_setting('transaction_read_only') as ro").fetchone()
                    print(f"{tag} connected as {who['u']}, read-only session: {who['ro']}")
                    for t in src.tables:
                        n = conn.execute(f"select count(*) as n from {t.schema}.{t.name}").fetchone()["n"]
                        print(f"{tag} {t.source_name:<24} {n:>6} rows visible")
                        if n == 0 and t.source == "erp":
                            ok = False
                            print("          ^ 0 rows. If the table really has rows, the ETL role cannot see them (RLS/grants).")
        except Exception as exc:
            ok = False
            print(f"{tag} FAILED: {exc}")
    if not settings.crm_url:
        print("crm       not configured (CRM_DATABASE_URL is empty), so runs load the ERP only")
    try:
        with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s, autocommit=True) as wh:
            who = wh.execute("select current_user as u, version() as v").fetchone()
            print(f"warehouse connected as {who['u']}: {who['v'].split(',')[0]}")
            schemas = [r["nspname"] for r in wh.execute(
                "select nspname from pg_namespace where nspname in ('etl','staging','dw','analytics') order by 1")]
            print(f"warehouse schemas present: {', '.join(schemas) or 'none (run the sql/ files first)'}")
            ok = ok and len(schemas) == 4
    except Exception as exc:
        ok = False
        print(f"warehouse FAILED: {exc}")
    print("CHECK PASSED" if ok else "CHECK FAILED")
    return 0 if ok else 1


def _incremental_since(lock_conn, settings, src: Source) -> dict:
    """Where each incremental table starts reading: its last watermark minus the lookback."""
    rows = lock_conn.execute("""
        select table_name, last_successful_watermark - make_interval(mins => %s) as since
        from etl.etl_watermarks
        where pipeline_name = %s and source_system = %s and watermark_type = 'source_updated_at'""",
        (settings.lookback_minutes, settings.pipeline_name, src.system)).fetchall()
    return {r["table_name"]: r["since"] for r in rows if r["since"] is not None}


def run(settings, triggered_by: str) -> int:
    srcs = sources(settings)
    systems = ",".join(s.system for s in srcs)
    lock_conn = db.with_retries("connect to warehouse", settings.max_retries, db.connect_warehouse,
                                settings.warehouse_url, settings.statement_timeout_s, autocommit=True)
    with lock_conn:
        # Only one run at a time. The lock lives as long as this connection, so a
        # crashed run releases it automatically.
        if not lock_conn.execute(LOCK_SQL, (settings.pipeline_name,)).fetchone()["got"]:
            lock_conn.execute("""
                insert into etl.etl_run_log (pipeline_name, source_system, triggered_by, status, ended_at, error_details)
                values (%s, %s, %s, 'skipped', now(), 'previous run still in progress')""",
                (settings.pipeline_name, systems, triggered_by))
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
            (settings.pipeline_name, systems, triggered_by)).fetchone()
        run_id, run_ts = row["run_id"], row["started_at"]
        log.info("Run %d started (%s): %s", run_id, triggered_by, systems)

        totals = {"extracted": 0, "inserted": 0, "updated": 0, "deleted": 0, "rejected": 0}
        steps, errors = [], []
        status = "failed"
        try:
            # Each attempt opens a fresh connection, so a retry never reuses a broken one.
            def _merge(table, accepted, rejected, n, system, wm):
                with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s) as wh:
                    return merge_table(wh, table, accepted, rejected, n, run_id, run_ts, settings, system, wm)

            def _load_dw():
                with db.connect_warehouse(settings.warehouse_url, settings.statement_timeout_s) as wh:
                    return load_dw(wh, run_id, settings)

            today = dt.date.today()
            staged_ok = 0
            for src in srcs:
                # 1. Extract (read-only, one consistent snapshot per source)
                since = _incremental_since(lock_conn, settings, src)

                def _extract(src=src, since=since):
                    with db.connect_source(src.url, settings.statement_timeout_s) as conn:
                        return extract_all(conn, src.tables, settings.batch_size, since)
                try:
                    extracted = db.with_retries(f"extract {src.label}", settings.max_retries, _extract)
                except Exception as exc:  # the other source can still load
                    errors.append(f"extract {src.label}: {type(exc).__name__}: {exc}")
                    steps.append({"step": "extract", "source": src.system, "error": str(exc)})
                    log.error("extract %s failed: %s", src.label, exc)
                    continue
                totals["extracted"] += sum(len(rows) for rows in extracted.values())

                # 2-4. Validate, transform and load staging, one transaction per table
                for table in src.tables:
                    raw_rows = extracted[table.source_name]
                    accepted, rejected = validate(table, raw_rows, today)
                    # Incremental watermark = newest updated_at read. Rejected rows count
                    # too: they are logged, and re-read once fixed (fixing bumps updated_at).
                    wm = None
                    if table.mode == "incremental":
                        wm = max((r[table.updated_column] for r in raw_rows
                                  if r.get(table.updated_column) is not None), default=None)
                    try:
                        stats = db.with_retries(f"staging {table.source_name}", settings.max_retries, _merge,
                                                table, accepted, rejected, len(raw_rows), src.system, wm)
                        staged_ok += 1
                        steps.append({"step": "staging", **stats})
                        totals["deleted"] += stats["deleted"]
                        totals["rejected"] += stats["rejected"]
                    except Exception as exc:  # keep going: other tables can still load
                        errors.append(f"staging {table.source_name}: {exc}")
                        steps.append({"step": "staging", "table": table.source_name, "error": str(exc)})
                        log.error("staging %s failed: %s", table.source_name, exc)

            if staged_ok == 0:
                raise RuntimeError("no source table could be loaded")

            # 5. Dimensions and facts (one transaction; watermarks move only on commit).
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
    parser = argparse.ArgumentParser(description="Supply-chain ETL: ERP + CRM -> warehouse")
    parser.add_argument("--check", action="store_true", help="test connections only, change nothing")
    parser.add_argument("--triggered-by", default="manual", choices=["manual", "schedule", "test"])
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s", stream=sys.stdout)
    settings = load_settings()
    return check(settings) if args.check else run(settings, args.triggered_by)


if __name__ == "__main__":
    sys.exit(main())
