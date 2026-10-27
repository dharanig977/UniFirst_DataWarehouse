# CRM source: Demand vs Actual vs Budget

The warehouse reads a second source, the CRM app's PostgreSQL database (Aiven), next to the ERP. Together they answer one question per **customer × product × month**: what the customer said they would buy (demand), what they actually ordered (actual), and what the business planned to sell (budget).

This is a portfolio demonstration with synthetic data. The "CRM" is our own small app, not Salesforce or Microsoft Dynamics.

## Who owns what

| Data | Owner | Table in the source |
|---|---|---|
| Products, sales orders (qty, date, status) | ERP | `raw.products`, `raw.sales_orders` |
| Customers | CRM | `crm.accounts` |
| Selling prices | CRM (the ERP has none) | `crm.price_list` |
| Which customer placed an ERP order, at what price | CRM | `crm.orders` (one row per ERP sales order, keyed by `erp_sales_order_id`) |
| Demand forecast | CRM | `crm.demand_forecasts` |
| Budget, with versions | CRM | `crm.budget_versions`, `crm.sales_budgets` |

The ERP stays the source of truth for an order's quantity, date and status. The CRM link only adds the customer and the price, so ERP totals never change because of the CRM.

## Extract: incremental, by `updated_at`

Unlike the ERP, every CRM table has a trigger-maintained `updated_at` and never hard-deletes (it sets `is_deleted`). So the ETL reads only rows with `updated_at` later than the last watermark minus `ETL_LOOKBACK_MINUTES`, in keyset batches ordered by `(updated_at, key)`. A soft delete bumps `updated_at`, so deletions arrive like any other change.

- Watermark: `etl.etl_watermarks`, `watermark_type = 'source_updated_at'`, one row per CRM table. It moves only when the table's staging transaction commits.
- Overlap: the lookback re-reads the last few minutes; the row hash makes those re-reads change nothing. It also covers a CRM transaction that commits a little after its `updated_at` was stamped.
- Composite keys: `demand_forecasts` (account, sku, month) and `sales_budgets` (version, account, sku, month).
- Login: `crm_etl_reader`, read-only, set up by the CRM app (`db/002_crm_roles.sql` in [UniFirst_CRM](https://github.com/dharanig977/UniFirst_CRM)).
- Optional: if `CRM_DATABASE_URL` is not set, runs load the ERP only. If the CRM is down, the ERP still loads and the run is `partial_success`; the next run catches up from the watermark.

## Warehouse additions (`sql/004_crm_source.sql`)

| Table | Grain | Notes |
|---|---|---|
| `staging.crm_*` | one per CRM row | same columns as the CRM, plus the `_` metadata |
| `dw.dim_customer` | account | key 0 = "Unknown / not linked to a CRM account" |
| `dw.dim_budget_version` | budget version | fiscal year, status (Draft / Approved / Archived) |
| `dw.dim_product` | (existing) | gains `list_price`, `list_currency` from the CRM price list |
| `dw.fact_sales_orders` | (existing) ERP order | gains `customer_key`, `unit_price`, `order_amount` (= ERP `order_qty` × CRM `unit_price`), `currency` |
| `dw.fact_demand_forecast` | customer × product × month | `forecast_qty`, `est_forecast_amount`; price = quoted price, else list price less the account discount (`price_basis` says which) |
| `dw.fact_sales_budget` | version × customer × product × month | `budget_qty`, `budget_amount` |

An ERP order with no CRM link (or whose link was deleted) sits on customer key 0, so its quantity still counts in totals. When it is linked later, the next run moves it to the real customer.

## Views (`sql/005_demand_actual_budget_views.sql`)

- `analytics.vw_demand_actual_budget`: one row per customer × product × month with `demand_qty`, `actual_qty`, `budget_qty`, the three amounts, the variances and `demand_attainment_pct` / `budget_attainment_pct`.
  - Actual = ERP orders except **Draft and Cancelled**, by order month.
  - Budget = the current version only (below). Older versions stay in `dw.fact_sales_budget` for comparison.
  - `has_unknown_member` flags rows on customer or product key 0.
- `analytics.vw_current_budget_version`: per fiscal year, the **Approved**, not-deleted version changed most recently. A Draft reforecast never replaces the approved budget until someone approves it in the CRM.
- `vw_data_quality` gains CRM checks: unlinked sales orders, CRM link to a missing ERP order, link that disagrees with the ERP order (SKU or quantity), unknown customer on a link, price-list SKU not in the ERP, forecasts and budgets on unknown keys, forecasts without a price, and fiscal years with no Approved budget.
- `vw_data_freshness` shows the CRM tables as `source extract` with their `source_system`.

## Setup (after the ERP pipeline works)

1. The CRM database is live on Aiven (host `pg-1d0d8e4f-dharanig977-fa92.a.aivencloud.com`, port `14198`, database `defaultdb`), with the read-only `crm_etl_reader` login. Its password is the GitHub secret `CRM_ETL_PASSWORD`, and Aiven's CA certificate is the secret `CRM_DATABASE_CA`.
2. The warehouse already has `sql/004_crm_source.sql` and `sql/005_demand_actual_budget_views.sql` applied. Both are safe to rerun. If you ever rerun `002`, rerun `005` after it.
3. **GitHub:** nothing to add. The Warehouse ETL workflow builds the CRM connection from `CRM_ETL_PASSWORD` and verifies the server certificate with `CRM_DATABASE_CA`.
4. **Render** (cron job → Environment), two values:
   - `CRM_DATABASE_URL` = `postgresql://crm_etl_reader:<crm_etl_reader password>@pg-1d0d8e4f-dharanig977-fa92.a.aivencloud.com:14198/defaultdb?sslmode=require`
   - `CRM_DATABASE_CA` = the CA certificate text (Aiven console → service → Overview → CA certificate → copy).

   **Don't mix it up with the CRM app's own `CRM_DATABASE_URL` on Vercel.** That one uses the `crm_app` login, which can write. The ETL must always use `crm_etl_reader`.
5. Actions → Warehouse ETL → mode `check`: it should show `crm connected as crm_etl_reader, read-only session: on` and the six `crm.*` tables. Then mode `run`.

`crm.orders` stays empty until the CRM app is deployed and someone clicks **Auto-link all**. Until then every actual sits on the Unknown customer, and the data-quality view says so.

✅ **Check:** `sum(actual_qty)` in `vw_demand_actual_budget` equals the ERP's non-Draft, non-Cancelled sales order quantity, and `sum(demand_qty)` / `sum(budget_qty)` equal the CRM's not-deleted forecast and current-budget totals.

## Power BI

Load `vw_demand_actual_budget` (and `vw_current_budget_version` if you want a "Budget version" card). Measures:

```DAX
Demand Qty = SUM(vw_demand_actual_budget[demand_qty])
Actual Qty = SUM(vw_demand_actual_budget[actual_qty])
Budget Qty = SUM(vw_demand_actual_budget[budget_qty])
Actual Amount = SUM(vw_demand_actual_budget[actual_amount])
Budget Amount = SUM(vw_demand_actual_budget[budget_amount])
Demand Amount = SUM(vw_demand_actual_budget[demand_amount])
Actual vs Budget = [Actual Amount] - [Budget Amount]
Budget Attainment % = DIVIDE([Actual Amount], [Budget Amount])
Demand Attainment % = DIVIDE([Actual Qty], [Demand Qty])
```

Use these measures, not the view's `*_attainment_pct` columns, whenever you group more than one row (averaging percentages gives the wrong answer).

Suggested page: a clustered column chart of Demand / Actual / Budget Amount by `year_month`; a matrix of `account_name` × `category` with Actual vs Budget and Budget Attainment %; slicers on `segment`, `account_owner` and `is_future_month`. Future months have demand and budget but no actuals yet, so filter `is_future_month = FALSE` for attainment.
