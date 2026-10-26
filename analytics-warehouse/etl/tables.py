"""What the pipeline knows about each source table.

These column lists match the real source schema (checked 2026-10-26 with
information_schema). If the source changes, update this file and
sql/001_warehouse_schema.sql together.
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SourceTable:
    name: str                       # table name in raw.* (source) and staging.* (warehouse)
    key: str                        # primary key / business key
    columns: tuple[str, ...]        # every source column, in source order
    required: tuple[str, ...]       # must be present after cleaning, or the row is rejected
    upper_codes: tuple[str, ...] = ()   # code columns compared case-insensitively
    event_column: str | None = None     # newest business date, used for freshness only
    statuses: tuple[str, ...] = ()      # known status values (case-insensitive match)
    non_negative: tuple[str, ...] = ()
    positive: tuple[str, ...] = ()
    date_columns: tuple[str, ...] = field(default=())


PRODUCTS = SourceTable(
    name="products", key="sku",
    columns=("sku", "product_name", "category", "unit_cost"),
    required=("sku", "product_name"),
    upper_codes=("sku",),
    non_negative=("unit_cost",),
)

SUPPLIERS = SourceTable(
    name="suppliers", key="supplier_id",
    columns=("supplier_id", "supplier_name", "standard_lead_days"),
    required=("supplier_id", "supplier_name"),
    upper_codes=("supplier_id",),
    non_negative=("standard_lead_days",),
)

PURCHASE_ORDERS = SourceTable(
    name="purchase_orders", key="po_id",
    columns=("po_id", "supplier_id", "sku", "warehouse_id", "order_qty", "order_date", "expected_date", "status"),
    required=("po_id", "sku", "warehouse_id", "order_qty", "order_date"),
    upper_codes=("po_id", "supplier_id", "sku", "warehouse_id"),
    event_column="order_date",
    statuses=("Draft", "Open", "Partially Received", "Received", "Closed", "Cancelled"),
    positive=("order_qty",),
    date_columns=("order_date", "expected_date"),
)

GOODS_RECEIPTS = SourceTable(
    name="goods_receipts", key="receipt_id",
    columns=("receipt_id", "po_id", "sku", "warehouse_id", "received_qty", "receipt_date"),
    required=("receipt_id", "sku", "warehouse_id", "received_qty", "receipt_date"),
    upper_codes=("receipt_id", "po_id", "sku", "warehouse_id"),
    event_column="receipt_date",
    positive=("received_qty",),
    date_columns=("receipt_date",),
)

SALES_ORDERS = SourceTable(
    name="sales_orders", key="sales_order_id",
    columns=("sales_order_id", "sku", "warehouse_id", "order_qty", "shipped_qty", "order_date", "status"),
    required=("sales_order_id", "sku", "warehouse_id", "order_qty", "order_date"),
    upper_codes=("sales_order_id", "sku", "warehouse_id"),
    event_column="order_date",
    statuses=("Draft", "Open", "Partially Shipped", "Shipped", "Closed", "Cancelled"),
    positive=("order_qty",),
    non_negative=("shipped_qty",),
    date_columns=("order_date",),
)

INVENTORY_SNAPSHOTS = SourceTable(
    name="inventory_snapshots", key="snapshot_id",
    columns=("snapshot_id", "sku", "warehouse_id", "snapshot_qty", "reserved_qty", "snapshot_at"),
    required=("snapshot_id", "sku", "warehouse_id", "snapshot_qty", "reserved_qty", "snapshot_at"),
    upper_codes=("snapshot_id", "sku", "warehouse_id"),
    event_column="snapshot_at",
    non_negative=("snapshot_qty", "reserved_qty"),
    date_columns=("snapshot_at",),
)

# Dimensions first, so facts can find their keys in the same run.
ALL_TABLES = (PRODUCTS, SUPPLIERS, PURCHASE_ORDERS, GOODS_RECEIPTS, SALES_ORDERS, INVENTORY_SNAPSHOTS)
