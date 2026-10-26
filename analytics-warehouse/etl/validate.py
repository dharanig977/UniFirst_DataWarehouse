"""Validate and clean extracted rows. Pure Python, no database, so it is easy to test.

Rules (see docs/etl_design.md for the reasoning):
  * Text is trimmed, empty text becomes NULL, code columns are upper-cased.
  * Status values are matched case-insensitively to the known spelling.
  * sales_orders.shipped_qty NULL becomes 0 (nothing shipped yet). No other value is invented.
  * A row is REJECTED (never silently dropped) when a required value is missing,
    a quantity is out of range, a date is implausible, expected_date is before
    order_date, or two rows share a business key after cleaning.
  * Missing references (e.g. a SKU not in products) are NOT rejected here. The
    load maps them to the "Unknown" dimension member and the data-quality view counts them.
"""
import datetime as dt
import hashlib
import json
from decimal import Decimal

from .tables import SourceTable

MIN_DATE = dt.date(2000, 1, 1)
MAX_FUTURE_DAYS = 366


def _clean_value(table: SourceTable, column: str, value):
    if isinstance(value, str):
        value = value.strip()
        if value == "":
            return None
        if column in table.upper_codes:
            value = value.upper()
        elif column in table.statuses:
            match = {s.lower(): s for s in table.statuses[column]}.get(value.lower())
            value = match or value
    return value


def clean_row(table: SourceTable, row: dict) -> dict:
    cleaned = {c: _clean_value(table, c, row.get(c)) for c in table.columns}
    if table.source == "erp" and table.name == "sales_orders" and cleaned["shipped_qty"] is None:
        cleaned["shipped_qty"] = 0
    return cleaned


def row_problems(table: SourceTable, row: dict, today: dt.date) -> list[str]:
    problems = [f"missing required value: {c}" for c in table.required if row.get(c) is None]
    for c in table.positive:
        if row.get(c) is not None and row[c] <= 0:
            problems.append(f"{c} must be greater than 0 (got {row[c]})")
    for c in table.non_negative:
        if row.get(c) is not None and row[c] < 0:
            problems.append(f"{c} must not be negative (got {row[c]})")
    for c in table.date_columns:
        v = row.get(c)
        if v is None:
            continue
        d = v.date() if isinstance(v, dt.datetime) else v
        if d < MIN_DATE or d > today + dt.timedelta(days=MAX_FUTURE_DAYS):
            problems.append(f"{c} is outside the plausible range ({d})")
    if table.source == "erp" and table.name == "purchase_orders":
        if row.get("order_date") and row.get("expected_date") and row["expected_date"] < row["order_date"]:
            problems.append("expected_date is before order_date")
    # reserved_qty > snapshot_qty is kept, not rejected: over-reservation is a real
    # business exception, and analytics.vw_inventory_kpis shows it.
    return problems


def _jsonable(value):
    if isinstance(value, Decimal):
        return str(value)
    if isinstance(value, (dt.date, dt.datetime)):
        return value.isoformat()
    return value


def row_hash(table: SourceTable, row: dict) -> str:
    payload = json.dumps([_jsonable(row[c]) for c in table.columns], separators=(",", ":"))
    return hashlib.md5(payload.encode()).hexdigest()


def to_json(row: dict) -> str:
    return json.dumps({k: _jsonable(v) for k, v in row.items()})


def validate(table: SourceTable, raw_rows: list[dict], today: dt.date):
    """Return (accepted_rows, rejected) where rejected is a list of (business_key, reason, original_row)."""
    accepted, rejected = [], []
    by_key: dict[tuple, list[tuple[dict, dict]]] = {}
    for raw in raw_rows:
        row = clean_row(table, raw)
        problems = row_problems(table, row, today)
        if problems:
            rejected.append((table.key_text(row), "; ".join(problems), raw))
            continue
        by_key.setdefault(table.key_of(row), []).append((row, raw))
    for key, rows in by_key.items():
        if len(rows) > 1:  # e.g. 'po-1' and 'PO-1 ' both exist in the source
            for row, raw in rows:
                rejected.append((table.key_text(row), f"duplicate business key after cleaning ({len(rows)} rows)", raw))
            continue
        row = rows[0][0]
        row["_row_hash"] = row_hash(table, row)
        accepted.append(row)
    return accepted, rejected
