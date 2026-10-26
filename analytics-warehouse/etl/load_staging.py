"""Load staging: merge one extracted table into staging.<table> by business key.

Inside one warehouse transaction per table:
  1. COPY the cleaned rows into a temporary table (fast bulk load).
  2. Insert keys that staging has never seen.
  3. Update keys whose row hash changed (or that came back after a delete).
  4. Mark keys that vanished from the source as _is_deleted (never physically deleted).
  5. Upsert rejected rows into etl.etl_rejected_records and resolve old rejections.
  6. Update the extract-side watermark row.
If anything fails, the whole table rolls back and the watermark is unchanged.
Running it twice with the same data changes nothing, so retries are safe.
"""
import logging

import psycopg
from psycopg import sql

from .tables import SourceTable
from .validate import to_json

log = logging.getLogger("etl")


class MassDeleteBlocked(RuntimeError):
    pass


def merge_table(conn: psycopg.Connection, table: SourceTable, rows: list[dict], rejected: list,
                extracted_count: int, run_id: int, run_ts, settings) -> dict:
    t = sql.Identifier(table.name)
    key = sql.Identifier(table.key)
    cols = [sql.Identifier(c) for c in table.columns]
    col_list = sql.SQL(", ").join(cols)
    non_key = [c for c in table.columns if c != table.key]
    rejected_keys = sorted({k for k, _, _ in rejected})

    with conn.transaction():
        conn.execute(sql.SQL("create temp table tmp_src on commit drop as select {cols}, _row_hash from staging.{t} with no data").format(t=t, cols=col_list))
        with conn.cursor().copy(sql.SQL("copy tmp_src ({cols}, _row_hash) from stdin").format(cols=col_list)) as cp:
            for r in rows:
                cp.write_row([r[c] for c in table.columns] + [r["_row_hash"]])

        inserted = conn.execute(sql.SQL("""
            insert into staging.{t} ({cols}, _row_hash, _first_seen_at, _changed_at, _last_seen_at, _is_deleted, _last_run_id)
            select {cols}, _row_hash, %(ts)s, %(ts)s, %(ts)s, false, %(run)s from tmp_src s
            where not exists (select 1 from staging.{t} x where x.{k} = s.{k})
        """).format(t=t, cols=col_list, k=key), {"ts": run_ts, "run": run_id}).rowcount

        updated = conn.execute(sql.SQL("""
            update staging.{t} x set {sets}, _row_hash = s._row_hash, _changed_at = %(ts)s,
                   _last_seen_at = %(ts)s, _is_deleted = false, _last_run_id = %(run)s
            from tmp_src s
            where x.{k} = s.{k} and (x._row_hash <> s._row_hash or x._is_deleted)
        """).format(t=t, k=key, sets=sql.SQL(", ").join(
            sql.SQL("{c} = s.{c}").format(c=sql.Identifier(c)) for c in non_key)),
            {"ts": run_ts, "run": run_id}).rowcount

        conn.execute(sql.SQL("""
            update staging.{t} x set _last_seen_at = %(ts)s
            from tmp_src s where x.{k} = s.{k} and x._last_seen_at < %(ts)s
        """).format(t=t, k=key), {"ts": run_ts})

        # Rows missing from this extract. Rejected keys still exist in the source,
        # so they keep their last good version instead of being marked deleted.
        live = conn.execute(sql.SQL("select count(*) as n from staging.{t} where not _is_deleted").format(t=t)).fetchone()["n"]
        to_delete = conn.execute(sql.SQL("""
            select count(*) as n from staging.{t} x
            where not x._is_deleted
              and not exists (select 1 from tmp_src s where s.{k} = x.{k})
              and not (x.{k} = any(%(rej)s))
        """).format(t=t, k=key), {"rej": rejected_keys}).fetchone()["n"]
        # Safety valve: an empty or much smaller extract (for example, a permissions or RLS
        # problem on the source role) must not wipe the warehouse.
        if to_delete and (extracted_count == 0
                          or (to_delete > 5 and to_delete * 100 > live * settings.max_delete_fraction_pct)):
            raise MassDeleteBlocked(
                f"{table.name}: {to_delete} of {live} rows would be marked deleted "
                f"(limit {settings.max_delete_fraction_pct}%). Check the source role's permissions. "
                f"If the deletes are real, rerun with ETL_MAX_DELETE_PERCENT=100 once.")
        deleted = conn.execute(sql.SQL("""
            update staging.{t} x set _is_deleted = true, _changed_at = %(ts)s, _last_run_id = %(run)s
            where not x._is_deleted
              and not exists (select 1 from tmp_src s where s.{k} = x.{k})
              and not (x.{k} = any(%(rej)s))
        """).format(t=t, k=key), {"ts": run_ts, "run": run_id, "rej": rejected_keys}).rowcount

        for bkey, reason, raw in rejected:
            conn.execute("""
                insert into etl.etl_rejected_records (source_table, business_key, reason, row_data, first_run_id, last_run_id,
                                                      first_rejected_at, last_rejected_at)
                values (%(t)s, %(k)s, %(r)s, %(d)s::jsonb, %(run)s, %(run)s, %(ts)s, %(ts)s)
                on conflict (source_table, business_key, reason) do update
                  set row_data = excluded.row_data, last_run_id = excluded.last_run_id,
                      last_rejected_at = excluded.last_rejected_at,
                      times_rejected = etl.etl_rejected_records.times_rejected + 1,
                      resolved_at = null
            """, {"t": table.name, "k": bkey, "r": reason, "d": to_json(raw), "run": run_id, "ts": run_ts})
        # A rejection is resolved when that key/reason did not come up in this run.
        conn.execute("""
            update etl.etl_rejected_records set resolved_at = %(ts)s
            where source_table = %(t)s and resolved_at is null and last_run_id <> %(run)s
        """, {"t": table.name, "run": run_id, "ts": run_ts})

        latest_event = (sql.SQL("(select max({c})::timestamptz from staging.{t} where not _is_deleted)").format(
                            c=sql.Identifier(table.event_column), t=t)
                        if table.event_column else sql.SQL("null::timestamptz"))
        conn.execute(sql.SQL("""
            insert into etl.etl_watermarks (pipeline_name, source_system, table_name, watermark_type,
                   last_successful_run_id, last_extracted_at, last_successful_load_at, last_source_row_count,
                   latest_source_event_at, updated_at)
            select %(p)s, %(s)s, %(name)s, 'full_compare_row_hash', %(run)s, %(ts)s, now(), %(n)s,
                   {ev}, now()
            on conflict (pipeline_name, source_system, table_name) do update set
                   last_successful_run_id = excluded.last_successful_run_id,
                   last_extracted_at = excluded.last_extracted_at,
                   last_successful_load_at = excluded.last_successful_load_at,
                   last_source_row_count = excluded.last_source_row_count,
                   latest_source_event_at = excluded.latest_source_event_at,
                   updated_at = now()
        """).format(ev=latest_event), {"p": settings.pipeline_name, "s": settings.source_system,
                                         "name": "raw." + table.name, "run": run_id, "ts": run_ts,
                                         "n": extracted_count})

    stats = {"table": table.name, "extracted": extracted_count, "inserted": inserted, "updated": updated,
             "deleted": deleted, "rejected": len(rejected)}
    log.info("staging %-20s new %5d  changed %5d  deleted %5d  rejected %5d",
             table.name, inserted, updated, deleted, len(rejected))
    return stats
