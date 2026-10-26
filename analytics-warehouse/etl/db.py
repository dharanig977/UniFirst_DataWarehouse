"""Database connections and retry helper."""
import logging
import time

import psycopg
from psycopg.rows import dict_row

log = logging.getLogger("etl")

# Errors worth retrying: lost connections, timeouts, serialization conflicts.
TRANSIENT = (psycopg.OperationalError, psycopg.errors.SerializationFailure, psycopg.errors.DeadlockDetected)


def connect_source(url: str, statement_timeout_s: int) -> psycopg.Connection:
    """Read-only connection to the transactional database.

    Read-only is enforced twice: the database role only has SELECT, and the
    session itself is read-only, so even a bug here cannot write to the source.
    """
    conn = psycopg.connect(url, row_factory=dict_row, application_name="supply_chain_etl_extract",
                           connect_timeout=15, autocommit=True)
    # SET after connecting (not a startup option) so it also works through Supabase's pooler.
    conn.execute("set default_transaction_read_only = on")
    conn.execute(f"set statement_timeout = {int(statement_timeout_s) * 1000}")
    conn.autocommit = False
    conn.read_only = True
    conn.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ  # every batch sees the same snapshot
    return conn


def connect_warehouse(url: str, statement_timeout_s: int, autocommit: bool = False) -> psycopg.Connection:
    conn = psycopg.connect(url, row_factory=dict_row, application_name="supply_chain_etl_load",
                           connect_timeout=15, autocommit=True)
    conn.execute(f"set statement_timeout = {int(statement_timeout_s) * 1000}")
    conn.autocommit = autocommit
    return conn


def with_retries(what: str, attempts: int, fn, *args, **kwargs):
    """Run fn, retrying transient database errors with 2s, 4s, 8s... waits.

    Only use this for steps that are safe to repeat (every step in this
    pipeline is: staging and dw loads are upserts keyed on business keys).
    """
    for attempt in range(1, attempts + 1):
        try:
            return fn(*args, **kwargs)
        except TRANSIENT as exc:
            if attempt == attempts:
                raise
            wait = 2 ** attempt
            log.warning("%s failed (attempt %d/%d): %s. Retrying in %ds.", what, attempt, attempts, exc, wait)
            time.sleep(wait)
