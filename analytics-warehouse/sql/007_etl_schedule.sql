-- =============================================================================
-- 007: batch schedule controlled from the ETL console, plus troubleshooting views.
-- Run after 006. Safe to rerun.
--
-- How scheduling works: the scheduler (Render cron) starts the ETL every minute
-- as a heartbeat. The ETL first reads etl.etl_schedule and only runs a batch if
-- the schedule is enabled and the interval has passed, or if someone pressed
-- "Run now" in the console. So the console changes the schedule without any
-- access to Render or GitHub.
-- =============================================================================

create table if not exists etl.etl_schedule (
  pipeline_name      text        primary key,
  is_enabled         boolean     not null default true,
  interval_minutes   integer     not null default 1,
  run_requested_at   timestamptz,                 -- "Run now" waiting to be picked up
  run_requested_by   text,
  last_heartbeat_at  timestamptz,                 -- last time the scheduler started the ETL
  updated_at         timestamptz not null default now(),
  updated_by         text        not null default 'setup',
  constraint etl_schedule_interval_chk check (interval_minutes in (1, 5, 10, 15, 30, 60, 120, 240, 720, 1440))
);
insert into etl.etl_schedule (pipeline_name) values ('supply_chain_etl') on conflict do nothing;

-- Who did what in the console (schedule changes, Run now). Never edited.
create table if not exists etl.etl_console_actions (
  action_id   bigint      generated always as identity primary key,
  acted_at    timestamptz not null default now(),
  acted_by    text        not null,
  action      text        not null,
  details     jsonb       not null default '{}'::jsonb
);

grant select, insert, update on etl.etl_schedule, etl.etl_console_actions to etl_loader;

-- -----------------------------------------------------------------------------
-- The console's only way to change anything: three functions. They run with
-- the owner's rights, check their inputs, and record every call. The console
-- login gets EXECUTE on these and nothing else that writes.
-- -----------------------------------------------------------------------------
create schema if not exists console;
revoke all on schema console from public;

create or replace function console.set_schedule(p_enabled boolean, p_interval_minutes integer, p_user text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or btrim(p_user) = '' then raise exception 'user is required'; end if;
  if p_enabled is null or p_interval_minutes is null then raise exception 'enabled and interval are required'; end if;
  update etl.etl_schedule
     set is_enabled = p_enabled, interval_minutes = p_interval_minutes, updated_at = now(), updated_by = p_user
   where pipeline_name = 'supply_chain_etl';
  insert into etl.etl_console_actions (acted_by, action, details)
  values (p_user, case when p_enabled then 'schedule saved' else 'schedule paused' end,
          jsonb_build_object('enabled', p_enabled, 'interval_minutes', p_interval_minutes));
end $$;

create or replace function console.request_run(p_user text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or btrim(p_user) = '' then raise exception 'user is required'; end if;
  update etl.etl_schedule set run_requested_at = now(), run_requested_by = p_user
   where pipeline_name = 'supply_chain_etl' and run_requested_at is null;
  insert into etl.etl_console_actions (acted_by, action) values (p_user, 'run requested');
end $$;

create or replace function console.cancel_run_request(p_user text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if p_user is null or btrim(p_user) = '' then raise exception 'user is required'; end if;
  update etl.etl_schedule set run_requested_at = null, run_requested_by = null
   where pipeline_name = 'supply_chain_etl';
  insert into etl.etl_console_actions (acted_by, action) values (p_user, 'run request cancelled');
end $$;

revoke all on all functions in schema console from public;
grant usage on schema console to etl_console_reader;
grant execute on all functions in schema console to etl_console_reader;

-- -----------------------------------------------------------------------------
-- vw_etl_schedule   grain: one row (the pipeline)
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_schedule as
with last_run as (
  select max(started_at) as started_at from etl.etl_run_log
  where pipeline_name = 'supply_chain_etl' and status <> 'skipped'
)
select s.pipeline_name, s.is_enabled, s.interval_minutes, s.run_requested_at, s.run_requested_by,
       s.last_heartbeat_at,
       round(extract(epoch from now() - s.last_heartbeat_at) / 60.0, 1) as minutes_since_heartbeat,
       (s.last_heartbeat_at is not null and now() - s.last_heartbeat_at < interval '5 minutes') as scheduler_alive,
       l.started_at as last_run_started_at,
       case when s.run_requested_at is not null then now()
            when not s.is_enabled then null
            when l.started_at is null then now()
            else greatest(now(), l.started_at + make_interval(mins => s.interval_minutes)) end as next_run_due_at,
       s.updated_at, s.updated_by
from etl.etl_schedule s cross join last_run l
where s.pipeline_name = 'supply_chain_etl';

comment on view analytics.vw_etl_schedule is 'ETL console: the batch schedule, Run now requests and whether the scheduler is alive.';

-- -----------------------------------------------------------------------------
-- vw_etl_run_steps   grain: one row per step of a run (extract per source,
-- staging per source table, dw per warehouse table), last 14 days
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_run_steps as
select r.run_id, r.started_at, s.ord::integer as step_no,
       s.step ->> 'step'                                    as step,
       coalesce(s.step ->> 'table', s.step ->> 'source')    as target,
       (s.step ->> 'extracted')::integer                    as rows_read,
       (s.step ->> 'inserted')::integer                     as rows_inserted,
       (s.step ->> 'updated')::integer                      as rows_updated,
       (s.step ->> 'deleted')::integer                      as rows_deleted,
       (s.step ->> 'rejected')::integer                     as rows_rejected,
       (s.step ->> 'seconds')::numeric                      as seconds,
       s.step ->> 'error'                                   as error
from etl.etl_run_log r
cross join lateral jsonb_array_elements(r.step_details) with ordinality as s(step, ord)
where r.started_at > now() - interval '14 days';

comment on view analytics.vw_etl_run_steps is 'ETL console: what each run did per source and table (rows read, inserted, updated, deleted, rejected, errors).';

-- -----------------------------------------------------------------------------
-- vw_etl_rejected_records   grain: one rejected source row (open, or resolved in the last 14 days)
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_rejected_records as
select source_table as warehouse_table, business_key, reason, times_rejected,
       first_rejected_at, last_rejected_at, resolved_at, (resolved_at is null) as is_open,
       row_data::text as row_data
from etl.etl_rejected_records
where resolved_at is null or resolved_at > now() - interval '14 days';

comment on view analytics.vw_etl_rejected_records is 'ETL console: source rows held back by validation, with the reason and the original values.';

-- -----------------------------------------------------------------------------
-- vw_etl_console_actions   grain: one console action (last 30 days)
-- -----------------------------------------------------------------------------
create or replace view analytics.vw_etl_console_actions as
select action_id, acted_at, acted_by, action, details::text as details
from etl.etl_console_actions
where acted_at > now() - interval '30 days';

comment on view analytics.vw_etl_console_actions is 'ETL console: who changed the schedule or pressed Run now, and when.';

grant select on all tables in schema analytics to etl_console_reader, powerbi_reader, etl_loader;
