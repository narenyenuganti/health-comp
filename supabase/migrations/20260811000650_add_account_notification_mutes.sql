create table private.competition_notification_mutes (
  profile_id uuid not null
    references public.profiles(id) on delete cascade,
  opponent_profile_id uuid not null
    references public.profiles(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (profile_id, opponent_profile_id),
  constraint competition_notification_mutes_distinct_profiles
    check (profile_id <> opponent_profile_id)
);

create index competition_notification_mutes_opponent_profile_id_idx
  on private.competition_notification_mutes(opponent_profile_id);

revoke all on table private.competition_notification_mutes
  from public, anon, authenticated, service_role;

create or replace function public.list_current_notification_mutes()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  caller_profile_id uuid;
  opponent_profile_ids jsonb;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  select coalesce(
    pg_catalog.jsonb_agg(
      mute_row.opponent_profile_id::text
      order by mute_row.opponent_profile_id
    ),
    '[]'::jsonb
  )
  into opponent_profile_ids
  from private.competition_notification_mutes mute_row
  where mute_row.profile_id = caller_profile_id;

  return pg_catalog.jsonb_build_object(
    'opponent_profile_ids', opponent_profile_ids
  );
end;
$$;

create or replace function public.set_current_notification_mute(
  opponent_profile_id uuid,
  is_muted boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_opponent_profile_id alias for opponent_profile_id;
  input_is_muted alias for is_muted;
  caller_profile_id uuid;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  if input_is_muted is null then
    raise exception 'invalid_notification_mute' using errcode = '22023';
  end if;

  if input_opponent_profile_id is null
     or input_opponent_profile_id = caller_profile_id then
    raise exception 'opponent_unavailable' using errcode = 'P0001';
  end if;

  if input_is_muted
     and not exists (
       select 1
       from public.competition_participants caller_membership
       join public.competition_participants opponent_membership
         on opponent_membership.competition_id
           = caller_membership.competition_id
       join public.profiles opponent_profile
         on opponent_profile.id = opponent_membership.profile_id
       where caller_membership.profile_id = caller_profile_id
         and caller_membership.state = 'accepted'
         and opponent_membership.profile_id = input_opponent_profile_id
         and opponent_membership.state = 'accepted'
         and opponent_profile.state = 'active'
     ) then
    raise exception 'opponent_unavailable' using errcode = 'P0001';
  end if;

  if input_is_muted then
    insert into private.competition_notification_mutes as mute_target (
      profile_id, opponent_profile_id
    ) values (
      caller_profile_id, input_opponent_profile_id
    )
    on conflict on constraint competition_notification_mutes_pkey
    do update
    set updated_at = pg_catalog.statement_timestamp();
  else
    delete from private.competition_notification_mutes mute_target
    where mute_target.profile_id = caller_profile_id
      and mute_target.opponent_profile_id = input_opponent_profile_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'opponent_profile_id', input_opponent_profile_id,
    'is_muted', input_is_muted
  );
end;
$$;

revoke all on function public.list_current_notification_mutes()
  from public, anon, authenticated, service_role;
revoke all on function public.set_current_notification_mute(uuid, boolean)
  from public, anon, authenticated, service_role;

grant execute on function public.list_current_notification_mutes()
  to authenticated;
grant execute on function public.set_current_notification_mute(uuid, boolean)
  to authenticated;
