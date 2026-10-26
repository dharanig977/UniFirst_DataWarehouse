import datetime as dt

from etl.tables import INVENTORY_SNAPSHOTS, PURCHASE_ORDERS, SALES_ORDERS
from etl.validate import validate

TODAY = dt.date(2026, 10, 26)


def po(**kw):
    row = dict(po_id="PO-1", supplier_id="SUP-001", sku="UFS-1001", warehouse_id="KY-DC-01", order_qty=10,
               order_date=dt.date(2026, 10, 1), expected_date=dt.date(2026, 10, 8), status="Open")
    row.update(kw)
    return row


def test_clean_row_trims_and_uppercases_codes():
    ok, bad = validate(PURCHASE_ORDERS, [po(warehouse_id=" ky-dc-01 ", status="partially received")], TODAY)
    assert bad == []
    assert ok[0]["warehouse_id"] == "KY-DC-01"
    assert ok[0]["status"] == "Partially Received"


def test_missing_required_and_bad_quantity_are_rejected_with_reasons():
    ok, bad = validate(PURCHASE_ORDERS, [po(po_id="PO-2", sku=None), po(po_id="PO-3", order_qty=0)], TODAY)
    assert ok == []
    reasons = {k: r for k, r, _ in bad}
    assert "missing required value: sku" in reasons["PO-2"]
    assert "order_qty must be greater than 0" in reasons["PO-3"]


def test_expected_before_order_date_rejected():
    _, bad = validate(PURCHASE_ORDERS, [po(expected_date=dt.date(2026, 9, 1))], TODAY)
    assert bad[0][1] == "expected_date is before order_date"


def test_duplicate_keys_after_cleaning_reject_both_rows():
    ok, bad = validate(PURCHASE_ORDERS, [po(po_id="po-9"), po(po_id="PO-9 ")], TODAY)
    assert ok == []
    assert len(bad) == 2 and all("duplicate business key" in r for _, r, _ in bad)


def test_shipped_qty_null_means_nothing_shipped():
    row = dict(sales_order_id="SO-1", sku="A", warehouse_id="W", order_qty=5, shipped_qty=None,
               order_date=dt.date(2026, 10, 1), status="Open")
    ok, bad = validate(SALES_ORDERS, [row], TODAY)
    assert bad == [] and ok[0]["shipped_qty"] == 0


def test_reserved_qty_null_is_rejected_not_guessed():
    row = dict(snapshot_id="INV-1", sku="A", warehouse_id="W", snapshot_qty=5, reserved_qty=None,
               snapshot_at=dt.datetime(2026, 10, 1, 8))
    ok, bad = validate(INVENTORY_SNAPSHOTS, [row], TODAY)
    assert ok == [] and "reserved_qty" in bad[0][1]


def test_hash_changes_only_when_values_change():
    a, _ = validate(PURCHASE_ORDERS, [po()], TODAY)
    b, _ = validate(PURCHASE_ORDERS, [po(status=" open ")], TODAY)   # same after cleaning
    c, _ = validate(PURCHASE_ORDERS, [po(order_qty=11)], TODAY)
    assert a[0]["_row_hash"] == b[0]["_row_hash"] != c[0]["_row_hash"]
