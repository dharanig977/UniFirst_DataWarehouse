"""Extract: read every source table in key-ordered batches.

Why a full read every run: none of the six source tables has an updated_at or
created_at column, and IDs are text, so neither a timestamp nor an ID
watermark can safely find changed rows (an UPDATE keeps its old ID). The
tables are small, so the pipeline reads them in full and the staging load
compares a hash of every row to find what is new, changed or deleted.

All tables are read inside ONE read-only REPEATABLE READ transaction, so a PO
and its receipts come from the same moment even while the app is writing.
"""
import logging

import psycopg
from psycopg import sql

from .tables import SourceTable

log = logging.getLogger("etl")


def extract_table(conn: psycopg.Connection, table: SourceTable, batch_size: int) -> list[dict]:
    cols = sql.SQL(", ").join(sql.Identifier(c) for c in table.columns)
    key = sql.Identifier(table.key)
    first = sql.SQL("select {cols} from raw.{t} order by {k} limit %s").format(
        cols=cols, t=sql.Identifier(table.name), k=key)
    nxt = sql.SQL("select {cols} from raw.{t} where {k} > %s order by {k} limit %s").format(
        cols=cols, t=sql.Identifier(table.name), k=key)
    rows: list[dict] = []
    last_key = None
    while True:
        if last_key is None:
            batch = conn.execute(first, (batch_size,)).fetchall()
        else:
            batch = conn.execute(nxt, (last_key, batch_size)).fetchall()
        rows.extend(batch)
        if len(batch) < batch_size:
            break
        last_key = batch[-1][table.key]
    log.info("extract %-20s %6d rows", table.name, len(rows))
    return rows


def extract_all(conn: psycopg.Connection, tables, batch_size: int) -> dict[str, list[dict]]:
    with conn.transaction():
        return {t.name: extract_table(conn, t, batch_size) for t in tables}
