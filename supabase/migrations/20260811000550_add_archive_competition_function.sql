create or replace function public.archive_competition(competition_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid;
  archived_competition_id uuid;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  update public.competitions competition_row
  set lifecycle = 'archived',
      updated_at = pg_catalog.statement_timestamp()
  where competition_row.id = input_competition_id
    and competition_row.lifecycle = 'completed'
    and exists (
      select 1
      from public.competition_participants participant_row
      where participant_row.competition_id = competition_row.id
        and participant_row.profile_id = caller_profile_id
        and participant_row.state = 'accepted'
    )
  returning competition_row.id into archived_competition_id;

  if archived_competition_id is null then
    select competition_row.id
    into archived_competition_id
    from public.competitions competition_row
    where competition_row.id = input_competition_id
      and competition_row.lifecycle = 'archived'
      and exists (
        select 1
        from public.competition_participants participant_row
        where participant_row.competition_id = competition_row.id
          and participant_row.profile_id = caller_profile_id
          and participant_row.state = 'accepted'
      );
  end if;

  if archived_competition_id is null then
    raise exception 'archive_not_allowed' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'competition_id', archived_competition_id
  );
end;
$$;

revoke all on function public.archive_competition(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.archive_competition(uuid) to authenticated;
