# UniFirst cloud data warehouse

**Portfolio demonstration on synthetic data.** It is not a UniFirst production system, and it does not connect to Microsoft Dynamics.

```
Source 1  SCM  Supabase PostgreSQL (ERP)   \
                                             > Python ETL (scheduled) -> Neon warehouse: staging -> dw -> analytics (calculation views)
Source 2  CRM  Aiven PostgreSQL (CRM)      /                                  ^
                                                                     ETL console (Vercel): monitor, schedule, troubleshoot
```

| Folder | What it is |
|---|---|
| [`analytics-warehouse/`](analytics-warehouse/) | warehouse SQL (schemas, star schema, calculation views), the Python ETL, tests, and guides. Start with [`docs/neon_setup.md`](analytics-warehouse/docs/neon_setup.md) |
| [`etl-console/`](etl-console/) | the web console for the ETL: sources and tables by schema, load history, schedule and Run now, troubleshooting, data quality |
| `render.yaml` | the scheduler (Render cron job) |
| `.github/workflows/` | tests for both folders, plus **Warehouse ETL** (setup / check / run, by hand) |

The source applications live in their own repositories: [UniFirst_SoftwareDev_SCM](https://github.com/dharanig977/UniFirst_SoftwareDev_SCM) and [UniFirst_CRM](https://github.com/dharanig977/UniFirst_CRM). The ETL only reads them, with read-only logins.

## Report views (schema `analytics`)

| Report | Views |
|---|---|
| Inventory | `vw_inventory_kpis`, `vw_purchase_order_exceptions`, `vw_supplier_performance`, `vw_sales_demand` |
| Customer Demand vs Actual vs Budget | `vw_demand_actual_budget` (uses `vw_current_budget_version`) |
| Data health | `vw_data_quality`, `vw_data_freshness` |

Secrets (database passwords, certificates) are never in this repository: they live in GitHub Actions secrets, Render and Vercel.
