-- =============================================================================
-- 004_crm_source.sql   (run in the WAREHOUSE project after 001-003)
-- Adds the CRM (Aiven PostgreSQL, schema crm) as a second source:
--   staging.crm_*            source-aligned copies of 6 CRM tables
--   dw.dim_customer          conformed customer dimension (CRM accounts)
--   dw.dim_budget_version    budget versions (Original, Reforecast, ...)
--   dw.dim_product           + CRM list price (ERP still owns the product)
--   dw.fact_sales_orders     + customer, CRM selling price and order amount
--   dw.fact_demand_forecast  grain: customer x product x month
--   dw.fact_sales_budget     grain: budget version x customer x product x month
-- Only adds tables/columns; changes no existing data. Safe to run again.
-- =============================================================================

-- CRM tables carry a trigger-maintained updated_at, so they are extracted
-- incrementally ('source_updated_at'), unlike the ERP tables.
alter table etl.etl_watermarks drop constraint if exists etl_watermarks_type_chk;
alter table etl.etl_watermarks add constraint etl_watermarks_type_chk
  check (watermark_type in ('full_compare_row_hash', 'source_updated_at', 'staging_changed_at'));

-- -----------------------------------------------------------------------------
-- staging. Source columns keep their CRM names and types (including the CRM's
-- own created_at/updated_at/is_deleted/deleted_at); "_" columns are ETL metadata.
-- -----------------------------------------------------------------------------
create table if not exists staging.crm_price_list (
  sku text primary key, product_name text, category text, list_price numeric(12,2), currency text,
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.crm_accounts (
  account_id text primary key, account_name text, industry text, segment text, account_status text,
  account_owner text, billing_city text, billing_state text, home_warehouse_id text, discount_pct numeric(5,2),
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.crm_budget_versions (
  budget_version text primary key, fiscal_year integer, version_status text, description text,
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create table if not exists staging.crm_demand_forecasts (
  account_id text, sku text, forecast_month date, forecast_qty integer, unit_price numeric(12,2), forecast_source text,
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null,
  primary key (account_id, sku, forecast_month)
);

create table if not exists staging.crm_sales_budgets (
  budget_version text, account_id text, sku text, budget_month date, budget_qty integer, budget_amount numeric(14,2),
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null,
  primary key (budget_version, account_id, sku, budget_month)
);

create table if not exists staging.crm_orders (
  erp_sales_order_id text primary key, account_id text, sku text, order_date date, order_qty integer,
  unit_price numeric(12,2), currency text,
  created_at timestamptz, updated_at timestamptz, is_deleted boolean, deleted_at timestamptz,
  _row_hash text not null, _first_seen_at timestamptz not null, _changed_at timestamptz not null,
  _last_seen_at timestamptz not null, _is_deleted boolean not null default false, _last_run_id bigint not null
);

create index if not exists stg_crm_price_changed_idx    on staging.crm_price_list (_changed_at);
create index if not exists stg_crm_accounts_changed_idx on staging.crm_accounts (_changed_at);
create index if not exists stg_crm_bver_changed_idx     on staging.crm_budget_versions (_changed_at);
create index if not exists stg_crm_demand_changed_idx   on staging.crm_demand_forecasts (_changed_at);
create index if not exists stg_crm_budget_changed_idx   on staging.crm_sales_budgets (_changed_at);
create index if not exists stg_crm_orders_changed_idx   on staging.crm_orders (_changed_at);

-- -----------------------------------------------------------------------------
-- dimensions
-- -----------------------------------------------------------------------------
create table if not exists dw.dim_customer (
  customer_key          integer generated by default as identity primary key,
  account_id            text not null unique,              -- business key from crm.accounts
  account_name          text not null,
  industry              text,
  segment               text,
  account_status        text,
  account_owner         text,
  billing_city          text,
  billing_state         text,
  home_warehouse_id     text,
  discount_pct          numeric(5,2),
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);
insert into dw.dim_customer (customer_key, account_id, account_name)
  overriding system value values (0, 'UNKNOWN', 'Unknown / not linked to a CRM account')
  on conflict do nothing;

create table if not exists dw.dim_budget_version (
  budget_version_key    integer generated by default as identity primary key,
  budget_version        text not null unique,
  fiscal_year           integer,
  version_status        text,
  description           text,
  source_updated_at     timestamptz,
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint
);
insert into dw.dim_budget_version (budget_version_key, budget_version, version_status)
  overriding system value values (0, 'UNKNOWN', 'Unknown')
  on conflict do nothing;

-- The ERP has no prices; the CRM price list is the selling price.
alter table dw.dim_product add column if not exists list_price numeric(12,2);
alter table dw.dim_product add column if not exists list_currency text;

-- -----------------------------------------------------------------------------
-- facts
-- -----------------------------------------------------------------------------
-- Same grain as before (one row per ERP sales order). The ERP order stays the
-- source of truth for quantity, date and status; the CRM link (crm.orders)
-- adds who the customer is and the agreed unit price.
alter table dw.fact_sales_orders add column if not exists customer_key integer not null default 0
  references dw.dim_customer (customer_key);
alter table dw.fact_sales_orders add column if not exists unit_price numeric(12,2);      -- from crm.orders
alter table dw.fact_sales_orders add column if not exists order_amount numeric(14,2);    -- ERP order_qty x CRM unit_price
alter table dw.fact_sales_orders add column if not exists currency text;
create index if not exists fso_customer_idx on dw.fact_sales_orders (customer_key, order_date);

-- Grain: one row per customer x product x month (first day of month).
create table if not exists dw.fact_demand_forecast (
  account_id            text not null,
  sku                   text not null,
  forecast_month        date not null,
  customer_key          integer not null references dw.dim_customer (customer_key),
  product_key           integer not null references dw.dim_product (product_key),
  month_date_key        integer not null references dw.dim_date (date_key),
  forecast_qty          integer not null,                 -- units
  quoted_unit_price     numeric(12,2),                    -- price the customer was quoted, if any
  est_unit_price        numeric(12,2),                    -- quoted, else list price less account discount
  est_forecast_amount   numeric(14,2),                    -- forecast_qty x est_unit_price (USD)
  price_basis           text,                             -- 'Quoted' | 'List less account discount' | null
  forecast_source       text,
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint,
  primary key (account_id, sku, forecast_month)
);
create index if not exists fdf_keys_idx on dw.fact_demand_forecast (customer_key, product_key, forecast_month);

-- Grain: one row per budget version x customer x product x month.
create table if not exists dw.fact_sales_budget (
  budget_version        text not null,
  account_id            text not null,
  sku                   text not null,
  budget_month          date not null,
  budget_version_key    integer not null references dw.dim_budget_version (budget_version_key),
  customer_key          integer not null references dw.dim_customer (customer_key),
  product_key           integer not null references dw.dim_product (product_key),
  month_date_key        integer not null references dw.dim_date (date_key),
  budget_qty            integer not null,                 -- units
  budget_amount         numeric(14,2) not null,           -- USD
  is_deleted_in_source  boolean not null default false,
  dw_inserted_at        timestamptz not null default now(),
  dw_updated_at         timestamptz not null default now(),
  dw_last_run_id        bigint,
  primary key (budget_version, account_id, sku, budget_month)
);
create index if not exists fsb_keys_idx on dw.fact_sales_budget (budget_version_key, customer_key, product_key, budget_month);

-- Rights for the ETL login on everything added above.
grant select, insert, update on all tables in schema etl, staging, dw to etl_loader;
grant usage, select on all sequences in schema etl, staging, dw to etl_loader;
