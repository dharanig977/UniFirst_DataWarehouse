"""What the pipeline knows about each source table.

ERP columns match the real Supabase schema (checked 2026-10-26 with
information_schema). CRM columns match db/001_crm_schema.sql in the UniFirst_CRM repo.
If a source changes, update this file and the warehouse SQL together.
"""
from dataclasses import dataclass, field


@dataclass(frozen=True)
class SourceTable:
    source: str                     # 'erp' or 'crm'
    schema: str                     # schema in the source database
    name: str                       # table name in the source database
    key: tuple[str, ...]            # primary key / business key (may be composite)
    columns: tuple[str, ...]        # columns copied to staging, in source order
    required: tuple[str, ...]       # must be present after cleaning, or the row is rejected
    upper_codes: tuple[str, ...] = ()   # code columns compared case-insensitively
    event_column: str | None = None     # newest business date/time, used for freshness only
    statuses: dict = field(default_factory=dict)  # column -> known values (case-insensitive match)
    non_negative: tuple[str, ...] = ()
    positive: tuple[str, ...] = ()
    date_columns: tuple[str, ...] = ()
    # 'full': read everything and compare row hashes (no change marker in the source).
    # 'incremental': read rows whose updated_at moved past the watermark.
    mode: str = "full"
    updated_column: str | None = None

    @property
    def source_name(self) -> str:
        return f"{self.schema}.{self.name}"

    @property
    def staging_name(self) -> str:
        return self.name if self.source == "erp" else f"crm_{self.name}"

    def key_of(self, row: dict) -> tuple:
        return tuple(row.get(k) for k in self.key)

    def key_text(self, row: dict) -> str:
        return "|".join("" if v is None else str(v) for v in self.key_of(row))


# --- ERP (Supabase, schema raw): no change timestamps, so full compare -------

PRODUCTS = SourceTable(
    source="erp", schema="raw", name="products", key=("sku",),
    columns=("sku", "product_name", "category", "unit_cost"),
    required=("sku", "product_name"),
    upper_codes=("sku",),
    non_negative=("unit_cost",),
)

SUPPLIERS = SourceTable(
    source="erp", schema="raw", name="suppliers", key=("supplier_id",),
    columns=("supplier_id", "supplier_name", "standard_lead_days"),
    required=("supplier_id", "supplier_name"),
    upper_codes=("supplier_id",),
    non_negative=("standard_lead_days",),
)

PURCHASE_ORDERS = SourceTable(
    source="erp", schema="raw", name="purchase_orders", key=("po_id",),
    columns=("po_id", "supplier_id", "sku", "warehouse_id", "order_qty", "order_date", "expected_date", "status"),
    required=("po_id", "sku", "warehouse_id", "order_qty", "order_date"),
    upper_codes=("po_id", "supplier_id", "sku", "warehouse_id"),
    event_column="order_date",
    statuses={"status": ("Draft", "Open", "Partially Received", "Received", "Closed", "Cancelled")},
    positive=("order_qty",),
    date_columns=("order_date", "expected_date"),
)

GOODS_RECEIPTS = SourceTable(
    source="erp", schema="raw", name="goods_receipts", key=("receipt_id",),
    columns=("receipt_id", "po_id", "sku", "warehouse_id", "received_qty", "receipt_date"),
    required=("receipt_id", "sku", "warehouse_id", "received_qty", "receipt_date"),
    upper_codes=("receipt_id", "po_id", "sku", "warehouse_id"),
    event_column="receipt_date",
    positive=("received_qty",),
    date_columns=("receipt_date",),
)

SALES_ORDERS = SourceTable(
    source="erp", schema="raw", name="sales_orders", key=("sales_order_id",),
    columns=("sales_order_id", "sku", "warehouse_id", "order_qty", "shipped_qty", "order_date", "status"),
    required=("sales_order_id", "sku", "warehouse_id", "order_qty", "order_date"),
    upper_codes=("sales_order_id", "sku", "warehouse_id"),
    event_column="order_date",
    statuses={"status": ("Draft", "Open", "Partially Shipped", "Shipped", "Closed", "Cancelled")},
    positive=("order_qty",),
    non_negative=("shipped_qty",),
    date_columns=("order_date",),
)

INVENTORY_SNAPSHOTS = SourceTable(
    source="erp", schema="raw", name="inventory_snapshots", key=("snapshot_id",),
    columns=("snapshot_id", "sku", "warehouse_id", "snapshot_qty", "reserved_qty", "snapshot_at"),
    required=("snapshot_id", "sku", "warehouse_id", "snapshot_qty", "reserved_qty", "snapshot_at"),
    upper_codes=("snapshot_id", "sku", "warehouse_id"),
    event_column="snapshot_at",
    non_negative=("snapshot_qty", "reserved_qty"),
    date_columns=("snapshot_at",),
)

# --- CRM (Aiven, schema crm): trigger-maintained updated_at + soft deletes ---
# The CRM never hard-deletes (is_deleted/deleted_at), so reading rows whose
# updated_at moved is complete: inserts, updates and deletes all bump it.

_CRM_META = ("created_at", "updated_at", "is_deleted", "deleted_at")

CRM_PRICE_LIST = SourceTable(
    source="crm", schema="crm", name="price_list", key=("sku",),
    columns=("sku", "product_name", "category", "list_price", "currency") + _CRM_META,
    required=("sku", "list_price", "updated_at"),
    upper_codes=("sku", "currency"),
    event_column="updated_at",
    non_negative=("list_price",),
    mode="incremental", updated_column="updated_at",
)

CRM_ACCOUNTS = SourceTable(
    source="crm", schema="crm", name="accounts", key=("account_id",),
    columns=("account_id", "account_name", "industry", "segment", "account_status", "account_owner",
             "billing_city", "billing_state", "home_warehouse_id", "discount_pct") + _CRM_META,
    required=("account_id", "account_name", "updated_at"),
    upper_codes=("account_id", "billing_state", "home_warehouse_id"),
    event_column="updated_at",
    non_negative=("discount_pct",),
    mode="incremental", updated_column="updated_at",
)

CRM_BUDGET_VERSIONS = SourceTable(
    source="crm", schema="crm", name="budget_versions", key=("budget_version",),
    columns=("budget_version", "fiscal_year", "version_status", "description") + _CRM_META,
    required=("budget_version", "fiscal_year", "version_status", "updated_at"),
    event_column="updated_at",
    statuses={"version_status": ("Draft", "Approved", "Archived")},
    mode="incremental", updated_column="updated_at",
)

CRM_DEMAND_FORECASTS = SourceTable(
    source="crm", schema="crm", name="demand_forecasts", key=("account_id", "sku", "forecast_month"),
    columns=("account_id", "sku", "forecast_month", "forecast_qty", "unit_price", "forecast_source") + _CRM_META,
    required=("account_id", "sku", "forecast_month", "forecast_qty", "updated_at"),
    upper_codes=("account_id", "sku"),
    event_column="updated_at",
    non_negative=("forecast_qty", "unit_price"),
    date_columns=("forecast_month",),
    mode="incremental", updated_column="updated_at",
)

CRM_SALES_BUDGETS = SourceTable(
    source="crm", schema="crm", name="sales_budgets", key=("budget_version", "account_id", "sku", "budget_month"),
    columns=("budget_version", "account_id", "sku", "budget_month", "budget_qty", "budget_amount") + _CRM_META,
    required=("budget_version", "account_id", "sku", "budget_month", "budget_qty", "budget_amount", "updated_at"),
    upper_codes=("account_id", "sku"),
    event_column="updated_at",
    non_negative=("budget_qty", "budget_amount"),
    date_columns=("budget_month",),
    mode="incremental", updated_column="updated_at",
)

CRM_ORDERS = SourceTable(
    source="crm", schema="crm", name="orders", key=("erp_sales_order_id",),
    columns=("erp_sales_order_id", "account_id", "sku", "order_date", "order_qty", "unit_price", "currency") + _CRM_META,
    required=("erp_sales_order_id", "account_id", "unit_price", "updated_at"),
    upper_codes=("erp_sales_order_id", "account_id", "sku", "currency"),
    event_column="updated_at",
    non_negative=("unit_price",),
    positive=("order_qty",),
    date_columns=("order_date",),
    mode="incremental", updated_column="updated_at",
)

ERP_TABLES = (PRODUCTS, SUPPLIERS, PURCHASE_ORDERS, GOODS_RECEIPTS, SALES_ORDERS, INVENTORY_SNAPSHOTS)
CRM_TABLES = (CRM_PRICE_LIST, CRM_ACCOUNTS, CRM_BUDGET_VERSIONS, CRM_DEMAND_FORECASTS, CRM_SALES_BUDGETS, CRM_ORDERS)
