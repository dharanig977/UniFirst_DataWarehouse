# UniFirst cloud data warehouse

> **Independent portfolio demo built on synthetic data, not affiliated with UniFirst.**

It is not a production system and does not connect to Microsoft Dynamics.

**Live ETL console:** https://uni-first-data-warehouse.vercel.app (sign in with an ERP account).

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

## Project links

This project has three repositories: two source systems and the cloud data warehouse that reads them. The database consoles need a sign-in; no passwords or connection strings are kept in any repository.

| Part | Repository | Database (console link) |
|---|---|---|
| ERP (SCM), source 1 | [UniFirst_SoftwareDev_SCM](https://github.com/dharanig977/UniFirst_SoftwareDev_SCM) | Supabase PostgreSQL: [project dashboard](https://supabase.com/dashboard/project/epvnsalihzmnrkqcxkoc) (schemas `raw`, `reporting`, `api`) |
| CRM, source 2 | [UniFirst_CRM](https://github.com/dharanig977/UniFirst_CRM) | Aiven PostgreSQL: [Aiven console](https://console.aiven.io/) (database `defaultdb`, schema `crm`) |
| Cloud data warehouse | [UniFirst_DataWarehouse](https://github.com/dharanig977/UniFirst_DataWarehouse) | Neon PostgreSQL: [project console](https://console.neon.tech/app/projects/tiny-band-79271165) (database `neondb`; report schemas `rpt_inventory`, `rpt_demand`) |

The ETL only reads the two sources, with read-only logins.

## Report views (schema `analytics`)

| Report | Views |
|---|---|
| Inventory | `vw_inventory_kpis`, `vw_purchase_order_exceptions`, `vw_supplier_performance`, `vw_sales_demand` |
| Customer Demand vs Actual vs Budget | `vw_demand_actual_budget` (uses `vw_current_budget_version`) |
| Data health | `vw_data_quality`, `vw_data_freshness` |

Secrets (database passwords, certificates) are never in this repository: they live in GitHub Actions secrets, Render and Vercel.
