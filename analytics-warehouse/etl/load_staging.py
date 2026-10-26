"""Load staging: merge one extracted table into staging.<table> by business key.

Inside one warehouse transaction per table:
  1. COPY the cleaned rows into a temporary table (fast bulk load).
  2. Insert keys that staging has never seen.
  3. Update keys whose row hash changed (or that came back after a delete).
  4. Full-mode tables only: mark keys that vanished from the source as
     _is_deleted (never physically deleted). Incremental tables only see
     changed rows, so their deletes arrive as the source's own is_deleted flag.
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
                extracted_count: int, run_id: int, run_ts, settings, source_system: str, new_watermark=None) -> dict:
    t = sql.Identifier(table.staging_name)
    col_list = sql.SQL(", ").join(sql.Identifier(c) for c in table.columns)
    key_list = sql.SQL(", ").join(sql.Identifier(c) for c in table.key)
    match = sql.SQL(" and ").join(sql.SQL("x.{c} = s.{c}").format(c=sql.Identifier(c)) for c in table.key)
    non_key = [c for c in table.columns if c not in table.key]
    params = {"ts": run_ts, "run": run_id}

    with conn.transaction():
        conn.execute(sql.SQL("create temp table tmp_src on commit drop as "
                             "select {cols}, _row_hash from staging.{t} with no data").format(t=t, cols=col_list))
        with conn.cursor().copy(sql.SQL("copy tmp_src ({cols}, _row_hash) from stdin").format(cols=col_list)) as cp:
            for r in rows:
                cp.write_row([r[c] for c in table.columns] + [r["_row_hash"]])
        # Keys of rejected rows: they still exist in the source, so they keep
        # their last good staging version instead of being marked deleted.
        conn.execute(sql.SQL("create temp table tmp_rej on commit drop as "
                             "select {keys} from staging.{t} with no data").format(t=t, keys=key_list))
        with conn.cursor().copy(sql.SQL("copy tmp_rej ({keys}) from stdin").format(keys=key_list)) as cp:
            for _, _, raw in rejected:
                cp.write_row([raw.get(c) for c in table.key])

        inserted = conn.execute(sql.SQL("""
            insert into staging.{t} ({cols}, _row_hash, _first_seen_at, _changed_at, _last_seen_at, _is_deleted, _last_run_id)
            select {cols}, _row_hash, %(ts)s, %(ts)s, %(ts)s, false, %(run)s from tmp_src s
            where not exists (select 1 from staging.{t} x where {match})
        """).format(t=t, cols=col_list, match=match), params).rowcount

        updated = conn.execute(sql.SQL("""
            update staging.{t} x set {sets}, _row_hash = s._row_hash, _changed_at = %(ts)s,
                   _last_seen_at = %(ts)s, _is_deleted = false, _last_run_id = %(run)s
            from tmp_src s
            where {match} and (x._row_hash <> s._row_hash or x._is_deleted)
        """).format(t=t, match=match, sets=sql.SQL(", ").join(
            sql.SQL("{c} = s.{c}").format(c=sql.Identifier(c)) for c in non_key)), params).rowcount

        conn.execute(sql.SQL("""
            update staging.{t} x set _last_seen_at = %(ts)s
            from tmp_src s where {match} and x._last_seen_at < %(ts)s
        """).format(t=t, match=match), params)

        deleted = 0
        if table.mode == "full":
            missing = sql.SQL("""
                not x._is_deleted
                and not exists (select 1 from tmp_src s where {m})
                and not exists (select 1 from tmp_rej s where {m})""").format(m=match)
            live = conn.execute(sql.SQL("select count(*) as n from staging.{t} where not _is_deleted").format(t=t)).fetchone()["n"]
            to_delete = conn.execute(sql.SQL("select count(*) as n from staging.{t} x where {w}").format(
                t=t, w=missing)).fetchone()["n"]
            # Safety valve: an empty or much smaller extract (for example, a permissions or RLS
            # problem on the source role) must not wipe the warehouse.
            if to_delete and (extracted_count == 0
                              or (to_delete > 5 and to_delete * 100 > live * settings.max_delete_fraction_pct)):
                raise MassDeleteBlocked(
                    f"{table.source_name}: {to_delete} of {live} rows would be marked deleted "
                    f"(limit {settings.max_delete_fraction_pct}%). Check the source role's permissions. "
                    f"If the deletes are real, rerun with ETL_MAX_DELETE_PERCENT=100 once.")
            deleted = conn.execute(sql.SQL("""
                update staging.{t} x set _is_deleted = true, _changed_at = %(ts)s, _last_run_id = %(run)s
                where {w}""").format(t=t, w=missing), params).rowcount
        elif "is_deleted" in table.columns:
            # Soft deletes that arrived in this batch (the source row now says is_deleted).
            deleted = conn.execute(sql.SQL("""
                select count(*) as n from tmp_src s join staging.{t} x on {match}
                where s.is_deleted and x._changed_at = %(ts)s""").format(t=t, match=match), params).fetchone()["n"]

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
            """, {"t": table.staging_name, "k": bkey, "r": reason, "d": to_json(raw), **params})
        if table.mode == "full":
            # Every key was re-read, so a rejection that did not come up again is resolved.
            conn.execute("""
                update etl.etl_rejected_records set resolved_at = %(ts)s
                where source_table = %(t)s and resolved_at is null and last_run_id <> %(run)s
            """, {"t": table.staging_name, **params})
        else:
            # Only changed rows were re-read: resolve rejections whose key now loaded cleanly.
            conn.execute(sql.SQL("""
                update etl.etl_rejected_records r set resolved_at = %(ts)s
                from tmp_src s
                where r.source_table = %(t)s and r.resolved_at is null and r.last_run_id <> %(run)s
                  and r.business_key = concat_ws('|', {keys})
            """).format(keys=sql.SQL(", ").join(sql.SQL("s.{c}::text").format(c=sql.Identifier(c)) for c in table.key)),
                {"t": table.staging_name, **params})

        latest_event = (sql.SQL("(select max({c})::timestamptz from staging.{t} where not _is_deleted)").format(
                            c=sql.Identifier(table.event_column), t=t)
                        if table.event_column else sql.SQL("null::timestamptz"))
        conn.execute(sql.SQL("""
            insert into etl.etl_watermarks (pipeline_name, source_system, table_name, watermark_type,
                   last_successful_watermark, last_successful_run_id, last_extracted_at, last_successful_load_at,
                   last_source_row_count, latest_source_event_at, updated_at)
            select %(p)s, %(s)s, %(name)s, %(wtype)s, %(wm)s::timestamptz, %(run)s, %(ts)s, now(),
                   coalesce(%(n)s::integer, (select count(*) from staging.{t} where not _is_deleted)), {ev}, now()
            on conflict (pipeline_name, source_system, table_name) do update set
                   last_successful_watermark = greatest(etl.etl_watermarks.last_successful_watermark,
                                                        excluded.last_successful_watermark),
                   last_successful_run_id = excluded.last_successful_run_id,
                   last_extracted_at = excluded.last_extracted_at,
                   last_successful_load_at = excluded.last_successful_load_at,
                   last_source_row_count = excluded.last_source_row_count,
                   latest_source_event_at = excluded.latest_source_event_at,
                   updated_at = now()
        """).format(ev=latest_event, t=t), {
            "p": settings.pipeline_name, "s": source_system, "name": table.source_name,
            "wtype": "full_compare_row_hash" if table.mode == "full" else "source_updated_at",
            "wm": new_watermark, "n": extracted_count if table.mode == "full" else None, **params})

    stats = {"table": table.source_name, "extracted": extracted_count, "inserted": inserted, "updated": updated,
             "deleted": deleted, "rejected": len(rejected)}
    log.info("staging %-24s new %5d  changed %5d  deleted %5d  rejected %5d",
             table.source_name, inserted, updated, deleted, len(rejected))
    return stats
