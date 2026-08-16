-- Hosted pg_cron jobs execute as postgres without PostgREST JWT claims. Keep
-- the public finalizer service-role-only, and expose a separate private
-- scheduler entry point that is unreachable from every API role.

create or replace function private.finalize_due_competitions_batch(
  input_batch_size integer,
  input_as_of timestamptz
)
returns bigint
language plpgsql
set search_path = ''
as $$
declare
  candidate record;
  finalized_count bigint := 0;
begin
  if input_batch_size is null or input_batch_size not between 1 and 1000 then
    raise exception 'invalid_batch_size' using errcode = '22023';
  end if;
  if input_as_of is null or not pg_catalog.isfinite(input_as_of) then
    raise exception 'invalid_as_of' using errcode = '22023';
  end if;

  for candidate in
    select competition_row.id
    from public.competitions competition_row
    where competition_row.lifecycle in (
      'scheduled', 'active', 'ends_today', 'tallying'
    )
      and competition_row.best_available_deadline <= input_as_of
    order by competition_row.best_available_deadline
    for update skip locked
    limit input_batch_size
  loop
    if private.finalize_competition_locked(
      candidate.id,
      input_as_of
    ) is not null then
      finalized_count := finalized_count + 1;
    end if;
  end loop;

  return finalized_count;
end;
$$;

create or replace function public.finalize_due_competitions(
  batch_size integer default 100
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  return private.finalize_due_competitions_batch(
    batch_size,
    pg_catalog.statement_timestamp()
  );
end;
$$;

create or replace function private.run_due_competition_finalizer()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
begin
  if session_user <> 'postgres' then
    raise exception 'postgres_required' using errcode = '42501';
  end if;

  return private.finalize_due_competitions_batch(
    100,
    pg_catalog.statement_timestamp()
  );
end;
$$;

revoke all on function private.finalize_due_competitions_batch(
  integer,
  timestamptz
) from public, anon, authenticated, service_role;
revoke all on function private.run_due_competition_finalizer()
  from public, anon, authenticated, service_role;
revoke all on function public.finalize_due_competitions(integer)
  from public, anon, authenticated, service_role;
grant execute on function public.finalize_due_competitions(integer)
  to service_role;

comment on function private.run_due_competition_finalizer() is
  'Postgres-owned hosted scheduler entry point for due competition finalization.';
