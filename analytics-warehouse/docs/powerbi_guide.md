# Power BI guide

Power BI Desktop (free, Windows) connects straight to the warehouse with the built-in **PostgreSQL database** connector, using the read-only `powerbi_reader` login. It only sees the `analytics` views.

## 1. Connection details

Warehouse project → **Connect** → **Session pooler**, and read the pieces off the string:

| Power BI field | Value |
|---|---|
| Server | `aws-1-us-east-2.pooler.supabase.com:5432` (your host from the string, then `:5432`) |
| Database | `postgres` |
| User name | `powerbi_reader.<warehouse-project-ref>` |
| Password | the `powerbi_reader` password from your password manager |

## 2. Connect

1. Power BI Desktop → **Get data** → **PostgreSQL database**.
2. Enter the Server and Database, and choose **Import** (fast visuals; data refreshes when you click Refresh or on a schedule).
3. Credentials: choose **Database** (not Windows), then enter the User name and Password.
4. In the Navigator, tick the views under `analytics` and click **Load**.

Recent Power BI Desktop versions include the PostgreSQL driver (Npgsql). If you see "*the PostgreSQL provider is not installed*", update Power BI Desktop from the Microsoft Store.

**SSL.** Keep **Encrypt connections** on. If Power BI says *"The remote certificate is invalid"*, Windows doesn't trust Supabase's certificate authority yet:
1. Warehouse project → **Database settings** → **SSL Configuration** → **Download certificate**.
2. Double-click the file → **Install Certificate** → **Current User** → *Place all certificates in the following store* → **Trusted Root Certification Authorities** → Finish.
3. Restart Power BI Desktop.

Some online guides say to untick *Encrypt connections*. Don't: that would send the password and data unencrypted.

If you see a *SCRAM* or *password authentication* error, check that the user name includes `.<project-ref>`, and that the password has no symbols.

## 3. Views to load

| View | Grain | Use it for |
|---|---|---|
| `vw_inventory_kpis` | one inventory count | stock on hand, reserved, available, value, exceptions |
| `vw_purchase_order_exceptions` | one PO | open, overdue and late POs, remaining qty |
| `vw_supplier_performance` | one supplier | on-time rate, average delay, open qty |
| `vw_sales_demand` | product × warehouse × day | demand trend, 7-day average |
| `vw_data_quality` | one check | trust panel |
| `vw_data_freshness` | one table | "data as of" card |
| `vw_etl_runs` | one ETL run (last 14 days) | pipeline monitor |

Every view is already joined to product, supplier and warehouse names, so you need no relationships to start. Each view is a self-contained table, which avoids accidental double counting from many-to-many joins.

## 4. Measures (DAX)

Create these with **New measure** on the matching table:

```DAX
-- vw_inventory_kpis: use only the latest count per product+warehouse
On Hand (latest) = CALCULATE(SUM(vw_inventory_kpis[calculated_on_hand_qty]), vw_inventory_kpis[is_latest_snapshot] = TRUE())
Available (latest) = CALCULATE(SUM(vw_inventory_kpis[calculated_available_qty]), vw_inventory_kpis[is_latest_snapshot] = TRUE())
Inventory Value (latest) = CALCULATE(SUM(vw_inventory_kpis[calculated_inventory_value]), vw_inventory_kpis[is_latest_snapshot] = TRUE())
Stock Exceptions = CALCULATE(COUNTROWS(vw_inventory_kpis), vw_inventory_kpis[is_latest_snapshot] = TRUE(), vw_inventory_kpis[stock_exception] <> "OK")

-- vw_purchase_order_exceptions
Open POs = CALCULATE(COUNTROWS(vw_purchase_order_exceptions), vw_purchase_order_exceptions[is_fully_received] = FALSE())
Overdue POs = CALCULATE(COUNTROWS(vw_purchase_order_exceptions), vw_purchase_order_exceptions[late_status] = "Overdue")
Remaining Qty = SUM(vw_purchase_order_exceptions[remaining_qty])

-- vw_supplier_performance (weighted, so it is correct for any group of suppliers)
On-Time Rate = DIVIDE(SUM(vw_supplier_performance[on_time_po_count]), SUM(vw_supplier_performance[measured_po_count]))

-- vw_sales_demand
Ordered Qty = SUM(vw_sales_demand[ordered_qty])
Open Sales Qty = SUM(vw_sales_demand[open_qty])

-- vw_data_freshness
Data As Of = MAX(vw_data_freshness[last_successful_load_at])
```

Don't sum `calculated_on_hand_qty` across all snapshots: each row is a count at a different time, so that would add the same stock up again and again. Always use the latest-snapshot measures, or put `snapshot_at` on an axis. Also, don't average `on_time_rate` across suppliers. Use the `On-Time Rate` measure above.

## 5. Suggested report pages

1. **Overview:** cards for On Hand, Inventory Value, Open POs, Overdue POs, On-Time Rate and Data As Of.
2. **Inventory:** a table by product × warehouse (latest), plus a stock-exception slicer.
3. **Purchasing:** an exception table filtered to `has_exception = TRUE`, a bar chart of `days_late` by supplier, and a slicer on `late_status`.
4. **Suppliers:** a bar chart of on-time rate and a table of average delay and open qty.
5. **Demand:** a line chart of `ordered_qty` by `order_date` with `rolling_7d_avg_daily_qty`, and a slicer on category and warehouse.
6. **Data health:** `vw_data_quality` with conditional formatting on `status`, plus `vw_etl_runs`.

Put a text box on the overview page: *"Synthetic portfolio data. Values are estimates at current standard cost; the source has no sales prices."*

## 6. Refresh

In **Import** mode, click **Home → Refresh** to pull the latest warehouse data. To refresh on a schedule after publishing to the Power BI service, the service must reach Supabase. Because Supabase is a public cloud host, a cloud connection normally works without an on-premises gateway. If the service asks for a gateway anyway, refresh from Desktop and republish instead. Set the same credentials under the dataset's **Data source credentials**, then set a scheduled refresh (up to 8 a day on Pro).
