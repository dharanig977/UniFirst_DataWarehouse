-- =============================================================================
-- 001_crm_schema.sql  -  UniFirst CRM database (Aiven PostgreSQL)
--
-- Run in the CRM database only (never in the ERP or warehouse projects).
-- Safe to run more than once: it only creates what is missing.
--
-- Rules every table follows (the warehouse ETL depends on them):
--   * a text business-key primary key (or a composite of business keys)
--   * created_at, updated_at (updated_at is set by trigger on every UPDATE)
--   * soft delete: is_deleted + deleted_at. Rows are never hard-deleted, so the
--     ETL can read changes incrementally by updated_at and still see deletions.
--   * sku is stored exactly as the ERP's raw.products.sku (upper case).
-- =============================================================================

create schema if not exists crm;
revoke all on schema crm from public;

-- ---------------------------------------------------------------------------
-- Shared trigger: keeps updated_at and deleted_at honest.
-- ---------------------------------------------------------------------------
create or replace function crm.touch_row() returns trigger
language plpgsql as $$
begin
  if tg_op = 'UPDATE' then
    new.created_at := old.created_at;            -- created_at never changes
    new.updated_at := now();
  else
    new.created_at := coalesce(new.created_at, now());
    new.updated_at := coalesce(new.updated_at, new.created_at);
  end if;
  if new.is_deleted and new.deleted_at is null then
    new.deleted_at := now();
  elsif not new.is_deleted then
    new.deleted_at := null;
  end if;
  return new;
end $$;

-- ID sequences for tables with generated text IDs (ACC-1001, CON-2001, ...).
create sequence if not exists crm.account_seq     start 1001;
create sequence if not exists crm.contact_seq     start 2001;
create sequence if not exists crm.opportunity_seq start 3001;
create sequence if not exists crm.activity_seq    start 4001;

-- ---------------------------------------------------------------------------
-- Price list: one price per ERP SKU. The ERP owns the product master; the CRM
-- owns the selling price (the ERP has no prices at all).
-- ---------------------------------------------------------------------------
create table if not exists crm.price_list (
  sku           text primary key check (sku = upper(sku) and sku <> ''),
  product_name  text not null,
  category      text,
  list_price    numeric(12,2) not null check (list_price >= 0),
  currency      text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  is_deleted    boolean not null default false,
  deleted_at    timestamptz
);

-- ---------------------------------------------------------------------------
-- Accounts (customers). home_warehouse_id is the ERP distribution centre that
-- serves the account (KY-DC-01, OH-DC-01, TN-DC-01).
-- ---------------------------------------------------------------------------
create table if not exists crm.accounts (
  account_id         text primary key default ('ACC-' || nextval('crm.account_seq')) check (account_id ~ '^ACC-[0-9]+$'),
  account_name       text not null check (btrim(account_name) <> ''),
  industry           text,
  segment            text not null default 'Mid-Market' check (segment in ('Enterprise', 'Mid-Market', 'Small Business')),
  account_status     text not null default 'Active' check (account_status in ('Prospect', 'Active', 'On Hold', 'Inactive')),
  account_owner      text,
  billing_city       text,
  billing_state      text check (billing_state is null or billing_state ~ '^[A-Z]{2}$'),
  home_warehouse_id  text check (home_warehouse_id is null or home_warehouse_id = upper(home_warehouse_id)),
  discount_pct       numeric(5,2) not null default 0 check (discount_pct between 0 and 50),
  phone              text,
  website            text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  is_deleted         boolean not null default false,
  deleted_at         timestamptz
);

create table if not exists crm.contacts (
  contact_id   text primary key default ('CON-' || nextval('crm.contact_seq')) check (contact_id ~ '^CON-[0-9]+$'),
  account_id   text not null references crm.accounts (account_id),
  first_name   text not null check (btrim(first_name) <> ''),
  last_name    text not null check (btrim(last_name) <> ''),
  title        text,
  email        text check (email is null or email ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  phone        text,
  is_primary   boolean not null default false,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  is_deleted   boolean not null default false,
  deleted_at   timestamptz
);

create table if not exists crm.opportunities (
  opportunity_id    text primary key default ('OPP-' || nextval('crm.opportunity_seq')) check (opportunity_id ~ '^OPP-[0-9]+$'),
  account_id        text not null references crm.accounts (account_id),
  opportunity_name  text not null check (btrim(opportunity_name) <> ''),
  stage             text not null default 'Prospecting'
                    check (stage in ('Prospecting', 'Qualification', 'Proposal', 'Negotiation', 'Closed Won', 'Closed Lost')),
  amount            numeric(14,2) not null default 0 check (amount >= 0),
  probability_pct   integer not null default 10 check (probability_pct between 0 and 100),
  close_date        date not null,
  owner             text,
  next_step         text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  is_deleted        boolean not null default false,
  deleted_at        timestamptz
);

create table if not exists crm.activities (
  activity_id     text primary key default ('ACT-' || nextval('crm.activity_seq')) check (activity_id ~ '^ACT-[0-9]+$'),
  account_id      text not null references crm.accounts (account_id),
  contact_id      text references crm.contacts (contact_id),
  opportunity_id  text references crm.opportunities (opportunity_id),
  activity_type   text not null default 'Task' check (activity_type in ('Call', 'Meeting', 'Email', 'Task')),
  subject         text not null check (btrim(subject) <> ''),
  due_date        date,
  is_done         boolean not null default false,
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  is_deleted      boolean not null default false,
  deleted_at      timestamptz
);

-- ---------------------------------------------------------------------------
-- Demand: what the customer says it will buy, per account x SKU x month.
-- forecast_month is always the first day of the month.
-- ---------------------------------------------------------------------------
create table if not exists crm.demand_forecasts (
  account_id       text not null references crm.accounts (account_id),
  sku              text not null references crm.price_list (sku),
  forecast_month   date not null check (extract(day from forecast_month) = 1),
  forecast_qty     integer not null check (forecast_qty >= 0),
  unit_price       numeric(12,2) check (unit_price is null or unit_price >= 0),  -- optional quoted price
  forecast_source  text not null default 'Sales rep' check (forecast_source in ('Customer', 'Sales rep', 'Statistical')),
  notes            text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  is_deleted       boolean not null default false,
  deleted_at       timestamptz,
  primary key (account_id, sku, forecast_month)
);

-- ---------------------------------------------------------------------------
-- Budget: what the business planned to sell. Versioned ("FY2027 Original",
-- "FY2027 Reforecast Q2", ...) so a re-budget never overwrites the original.
-- ---------------------------------------------------------------------------
create table if not exists crm.budget_versions (
  budget_version  text primary key check (btrim(budget_version) <> ''),
  fiscal_year     integer not null check (fiscal_year between 2020 and 2100),
  version_status  text not null default 'Draft' check (version_status in ('Draft', 'Approved', 'Archived')),
  description     text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  is_deleted      boolean not null default false,
  deleted_at      timestamptz
);

create table if not exists crm.sales_budgets (
  budget_version  text not null references crm.budget_versions (budget_version),
  account_id      text not null references crm.accounts (account_id),
  sku             text not null references crm.price_list (sku),
  budget_month    date not null check (extract(day from budget_month) = 1),
  budget_qty      integer not null check (budget_qty >= 0),
  budget_amount   numeric(14,2) not null check (budget_amount >= 0),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  is_deleted      boolean not null default false,
  deleted_at      timestamptz,
  primary key (budget_version, account_id, sku, budget_month)
);

-- ---------------------------------------------------------------------------
-- Orders: links each ERP sales order to its customer and selling price.
-- The ERP sales_orders table has no customer or price, and is never changed;
-- this table fills the gap. sku/order_date/order_qty are copied from the ERP
-- order when it is linked (for convenience); the ERP stays the source of truth.
-- ---------------------------------------------------------------------------
create table if not exists crm.orders (
  erp_sales_order_id  text primary key check (erp_sales_order_id = upper(erp_sales_order_id) and erp_sales_order_id <> ''),
  account_id          text not null references crm.accounts (account_id),
  sku                 text not null references crm.price_list (sku),
  order_date          date not null,
  order_qty           integer not null check (order_qty > 0),
  unit_price          numeric(12,2) not null check (unit_price >= 0),
  currency            text not null default 'USD' check (currency ~ '^[A-Z]{3}$'),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  is_deleted          boolean not null default false,
  deleted_at          timestamptz
);

-- Triggers + an updated_at index on every table (the ETL reads by updated_at).
do $$
declare t text;
begin
  foreach t in array array['price_list','accounts','contacts','opportunities','activities',
                           'demand_forecasts','budget_versions','sales_budgets','orders']
  loop
    execute format('drop trigger if exists %I on crm.%I', t || '_touch', t);
    execute format('create trigger %I before insert or update on crm.%I for each row execute function crm.touch_row()', t || '_touch', t);
    execute format('create index if not exists %I on crm.%I (updated_at)', t || '_updated_at_idx', t);
  end loop;
end $$;

create index if not exists contacts_account_idx       on crm.contacts (account_id);
create index if not exists opportunities_account_idx  on crm.opportunities (account_id);
create index if not exists activities_account_idx     on crm.activities (account_id);
create index if not exists demand_month_idx           on crm.demand_forecasts (forecast_month);
create index if not exists budgets_month_idx          on crm.sales_budgets (budget_month);
create index if not exists orders_account_month_idx   on crm.orders (account_id, order_date);
