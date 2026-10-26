-- =============================================================================
-- 003_warehouse_roles.sql   (run in the WAREHOUSE project after 001 and 002)
-- Two least-privilege logins, so the warehouse's postgres password never
-- leaves Supabase:
--   etl_loader     used by the ETL job: read/write etl, staging, dw. Cannot
--                  drop or alter anything, cannot create tables.
--   powerbi_reader used by Power BI: SELECT on the analytics views only.
-- Both are created WITHOUT a password and NOLOGIN. You set the passwords
-- yourself in the SQL Editor (see docs/setup_guide.md, step 4), so no
-- password is ever written in this repository.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'etl_loader') then
    create role etl_loader nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'powerbi_reader') then
    create role powerbi_reader nologin;
  end if;
end $$;

-- ETL loader
grant usage on schema etl, staging, dw to etl_loader;
grant select, insert, update on all tables in schema etl, staging, dw to etl_loader;
grant usage, select on all sequences in schema etl, staging, dw to etl_loader;
grant usage on schema analytics to etl_loader;
grant select on all tables in schema analytics to etl_loader;   -- lets --check and tests read views
alter role etl_loader set statement_timeout = '60s';

-- Power BI reader: analytics views only. The views read dw/etl with the view
-- owner's rights, so this role needs no access to the underlying tables.
grant usage on schema analytics to powerbi_reader;
grant select on all tables in schema analytics to powerbi_reader;
alter default privileges in schema analytics grant select on tables to powerbi_reader;
alter role powerbi_reader set default_transaction_read_only = on;
alter role powerbi_reader set statement_timeout = '120s';
