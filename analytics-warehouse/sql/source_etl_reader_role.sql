-- =============================================================================
-- source_etl_reader_role.sql   (run ONCE in the SOURCE project, after review)
-- Creates a read-only login for the ETL. It does NOT touch any table, row,
-- policy or existing role. Undo with:  drop role etl_reader;
--
--   * SELECT only on the six raw tables. No INSERT/UPDATE/DELETE anywhere.
--   * Every session is read-only by default.
--   * BYPASSRLS: RLS is on for raw.* with no policies, so without this the
--     role would see 0 rows. BYPASSRLS only skips row filtering; it grants no
--     extra table privileges, so the role still can only read these six tables.
--   * Created NOLOGIN with no password. You set the password yourself (see
--     docs/setup_guide.md), so it is never written in this repository.
-- =============================================================================

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'etl_reader') then
    create role etl_reader nologin bypassrls;
  end if;
end $$;

grant usage on schema raw to etl_reader;
grant select on raw.products, raw.suppliers, raw.purchase_orders, raw.goods_receipts,
                raw.sales_orders, raw.inventory_snapshots to etl_reader;
alter role etl_reader set default_transaction_read_only = on;
alter role etl_reader set statement_timeout = '60s';

-- Check: should list exactly six SELECT grants.
select table_schema, table_name, privilege_type
from information_schema.role_table_grants
where grantee = 'etl_reader'
order by table_name;
