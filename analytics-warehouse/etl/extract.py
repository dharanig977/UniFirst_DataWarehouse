"""Extract: read source tables in key-ordered batches, read-only.

ERP tables ('full' mode): none of them has an updated_at or created_at column,
and IDs are text, so neither a timestamp nor an ID watermark can safely find
changed rows (an UPDATE keeps its old ID). The tables are small, so every run
reads them in full and the staging load compares a hash of every row.

CRM tables ('incremental' mode): each has a trigger-maintained updated_at and
soft deletes, so a run only reads rows with updated_at later than the last
watermark minus ETL_LOOKBACK_MINUTES.

All tables of one source are read inside ONE read-only REPEATABLE READ
transaction, so related rows (a PO and its receipts) come from the same moment
even while the app is writing.
"""
import logging

import psycopg
from psycopg import sql

from .tables import SourceTable

log = logging.getLogger("etl")


def extract_table(conn: psycopg.Connection, table: SourceTable, batch_size: int, since=None) -> list[dict]:
    """Keyset pagination: each batch starts after the last row of the previous one."""
    order = ((table.updated_column,) if table.mode == "incremental" else ()) + table.key
    cols = sql.SQL(", ").join(sql.Identifier(c) for c in table.columns)
    order_ids = sql.SQL(", ").join(sql.Identifier(c) for c in order)
    src = sql.Identifier(table.schema, table.name)
    where, params = [], []
    if table.mode == "incremental" and since is not None:
        where.append(sql.SQL("{u} > %s").format(u=sql.Identifier(table.updated_column)))
        params.append(since)

    rows: list[dict] = []
    last = None
    while True:
        conds = list(where)
        args = list(params)
        if last is not None:
            conds.append(sql.SQL("({ids}) > ({ph})").format(
                ids=order_ids, ph=sql.SQL(", ").join(sql.Placeholder() for _ in order)))
            args.extend(last[c] for c in order)
        query = sql.SQL("select {cols} from {src} {where} order by {ids} limit %s").format(
            cols=cols, src=src, ids=order_ids,
            where=sql.SQL("where ") + sql.SQL(" and ").join(conds) if conds else sql.SQL(""))
        batch = conn.execute(query, args + [batch_size]).fetchall()
        rows.extend(batch)
        if len(batch) < batch_size:
            break
        last = batch[-1]
    log.info("extract %-24s %6d rows%s", table.source_name, len(rows),
             f" (changed since {since:%Y-%m-%d %H:%M:%S})" if since is not None else "")
    return rows


def extract_all(conn: psycopg.Connection, tables, batch_size: int, since: dict | None = None) -> dict[str, list[dict]]:
    since = since or {}
    with conn.transaction():
        return {t.source_name: extract_table(conn, t, batch_size, since.get(t.source_name)) for t in tables}
