create or replace function private.invitation_expiry_interval_v1()
returns interval
language sql
immutable
set search_path = ''
as $$
  select interval '48 hours';
$$;

create or replace function private.best_available_local_day_offset_v1()
returns integer
language sql
immutable
set search_path = ''
as $$
  select 8;
$$;

revoke all on function private.invitation_expiry_interval_v1()
  from public, anon, authenticated, service_role;
revoke all on function private.best_available_local_day_offset_v1()
  from public, anon, authenticated, service_role;

create or replace function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  input_time_zone_identifier alias for creator_time_zone_identifier;
  input_rematch_parent_id alias for rematch_parent_id;
  input_creator_auth_user_id alias for creator_auth_user_id;
  caller_profile_id uuid;
  source_scoring_policy text;
  new_competition_id uuid;
  invite_expires_at timestamptz :=
    pg_catalog.statement_timestamp() + private.invitation_expiry_interval_v1();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invalid_token_digest' using errcode = '22023';
  end if;

  if input_time_zone_identifier is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names time_zone_row
       where time_zone_row.name = input_time_zone_identifier
     ) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = input_creator_auth_user_id
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select source_competition.scoring_policy_identity
    into source_scoring_policy
    from public.competitions source_competition
    where source_competition.id = input_rematch_parent_id
      and source_competition.lifecycle in ('completed', 'archived')
      and exists (
        select 1
        from public.competition_participants source_membership
        where source_membership.competition_id = source_competition.id
          and source_membership.profile_id = caller_profile_id
          and source_membership.state = 'accepted'
      );

    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  insert into public.competitions (
    creator_profile_id,
    time_zone_identifier,
    start_day,
    scoring_policy_identity,
    lifecycle,
    invitation_expires_at,
    best_available_deadline,
    rematch_parent_id
  ) values (
    caller_profile_id,
    input_time_zone_identifier,
    null,
    source_scoring_policy,
    'pending',
    invite_expires_at,
    null,
    input_rematch_parent_id
  ) returning id into new_competition_id;

  insert into public.competition_participants (
    competition_id,
    profile_id,
    role,
    state
  ) values (
    new_competition_id,
    caller_profile_id,
    'creator',
    'accepted'
  );

  insert into public.competition_invites (
    competition_id,
    token_digest,
    expires_at
  ) values (
    new_competition_id,
    input_token_digest,
    invite_expires_at
  );

  return new_competition_id;
end;
$$;

create or replace function public.claim_competition_invite(token_digest bytea)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  caller_profile_id uuid;
  target_invite record;
  frozen_start_day date;
  frozen_deadline timestamptz;
begin
  if (select auth.role()) is distinct from 'authenticated' or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if token_digest is null or pg_catalog.octet_length(token_digest) <> 32 then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select
    invite_row.id,
    invite_row.competition_id,
    invite_row.claimed_profile_id,
    invite_row.consumed_at,
    invite_row.expires_at,
    competition_row.creator_profile_id,
    competition_row.time_zone_identifier,
    competition_row.lifecycle
  into target_invite
  from public.competition_invites invite_row
  join public.competitions competition_row on competition_row.id = invite_row.competition_id
  where invite_row.token_digest = input_token_digest
  for update of invite_row, competition_row;

  if not found
     or target_invite.consumed_at is not null
     or target_invite.claimed_profile_id is not null
     or target_invite.expires_at <= pg_catalog.statement_timestamp()
     or target_invite.lifecycle <> 'pending' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;

  if target_invite.creator_profile_id = caller_profile_id then
    raise exception 'cannot_claim_own_invite' using errcode = 'P0001';
  end if;

  frozen_start_day :=
    (pg_catalog.statement_timestamp() at time zone target_invite.time_zone_identifier)::date + 1;
  frozen_deadline :=
    ((frozen_start_day + private.best_available_local_day_offset_v1())::timestamp
      at time zone target_invite.time_zone_identifier);

  insert into public.competition_participants (
    competition_id,
    profile_id,
    role,
    state
  ) values (
    target_invite.competition_id,
    caller_profile_id,
    'invitee',
    'accepted'
  );

  update public.competition_invites
  set claimed_profile_id = caller_profile_id,
      consumed_at = pg_catalog.statement_timestamp()
  where id = target_invite.id;

  update public.competitions
  set start_day = frozen_start_day,
      lifecycle = 'scheduled',
      best_available_deadline = frozen_deadline,
      updated_at = pg_catalog.statement_timestamp()
  where id = target_invite.competition_id;

  return target_invite.competition_id;
end;
$$;

create or replace function public.cleanup_expired_competition_invites()
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  expired_count bigint;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  update public.competitions competition_row
  set lifecycle = 'expired',
      updated_at = pg_catalog.statement_timestamp()
  where competition_row.lifecycle = 'pending'
    and exists (
      select 1
      from public.competition_invites invite_row
      where invite_row.competition_id = competition_row.id
        and invite_row.claimed_profile_id is null
        and invite_row.consumed_at is null
        and invite_row.expires_at <= pg_catalog.statement_timestamp()
    );

  get diagnostics expired_count = row_count;
  return expired_count;
end;
$$;

revoke all on function public.create_competition_invite(bytea, text, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.claim_competition_invite(bytea)
  from public, anon, authenticated, service_role;
revoke all on function public.cleanup_expired_competition_invites()
  from public, anon, authenticated, service_role;

grant execute on function public.create_competition_invite(bytea, text, uuid, uuid) to service_role;
grant execute on function public.claim_competition_invite(bytea) to authenticated;
grant execute on function public.cleanup_expired_competition_invites() to service_role;
