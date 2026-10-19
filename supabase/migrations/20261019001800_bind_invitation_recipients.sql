alter table public.competitions
  add column invited_profile_id uuid references public.profiles(id);

alter table public.competitions
  add constraint invitation_recipient_not_creator check (
    invited_profile_id is null or invited_profile_id <> creator_profile_id
  );

create unique index one_pending_invitation_per_recipient
  on public.competitions (creator_profile_id, invited_profile_id)
  where lifecycle = 'pending';

create or replace function private.invitation_expiry_interval_v1()
returns interval language sql immutable set search_path = ''
as $$ select interval '24 hours'; $$;

create function private.reject_invitation_recipient_mutation()
returns trigger language plpgsql set search_path = ''
as $$
begin
  if new.invited_profile_id is distinct from old.invited_profile_id then
    raise exception 'invitation recipient is immutable' using errcode = '55000';
  end if;
  return new;
end;
$$;
revoke all on function private.reject_invitation_recipient_mutation()
  from public, anon, authenticated, service_role;
create trigger reject_invitation_recipient_mutation
before update on public.competitions
for each row execute function private.reject_invitation_recipient_mutation();

create function public.resolve_invitation_recipient(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_profile_id alias for profile_id;
  caller_profile_id uuid;
  recipient jsonb;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  caller_profile_id := private.current_profile_id();
  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  select pg_catalog.jsonb_build_object('id', p.id, 'display_name', p.display_name)
  into recipient from public.profiles p
  where p.id = input_profile_id and p.id <> caller_profile_id and p.state = 'active';
  if recipient is null then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return recipient;
end;
$$;
revoke all on function public.resolve_invitation_recipient(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.resolve_invitation_recipient(uuid) to authenticated;

-- The creator can render the chosen name, including an expired pending card.
-- Pending membership never grants the recipient competition or profile access.
create or replace function private.can_view_profile(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select current_profile.id is not null and (
    target_profile_id = current_profile.id or exists (
      select 1 from public.competition_participants own_membership
      join public.competition_participants counterpart_membership
        on counterpart_membership.competition_id = own_membership.competition_id
      join public.competitions c on c.id = own_membership.competition_id
      where own_membership.profile_id = current_profile.id
        and own_membership.state = 'accepted'
        and counterpart_membership.profile_id = target_profile_id
        and (
          (counterpart_membership.state in ('accepted', 'anonymized')
            and c.lifecycle in ('pending', 'scheduled', 'active', 'ends_today',
              'tallying', 'completed', 'archived'))
          or (own_membership.role = 'creator'
            and c.invited_profile_id = target_profile_id
            and counterpart_membership.state in ('pending', 'anonymized'))
        )
    )
  ) from (select private.current_profile_id() as id) current_profile;
$$;

-- Retire both recipient-free entry points; keep their definitions as history.
revoke all on function public.create_competition_invite(bytea, text, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.create_competition_invite(bytea, text, uuid, uuid, uuid, smallint)
  from public, anon, authenticated, service_role;

create function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  recipient_profile_id uuid
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  input_time_zone_identifier alias for creator_time_zone_identifier;
  input_rematch_parent_id alias for rematch_parent_id;
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_derivation_version alias for token_derivation_version;
  input_recipient_profile_id alias for recipient_profile_id;
  caller_profile_id uuid;
  source_scoring_policy text;
  new_competition_id uuid;
  existing_invite record;
  created_time timestamptz := pg_catalog.statement_timestamp();
  invite_expires_at timestamptz := created_time + private.invitation_expiry_interval_v1();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invalid_token_digest' using errcode = '22023';
  end if;
  if input_idempotency_key is null then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;
  if input_derivation_version is distinct from 1::smallint then
    raise exception 'invalid_token_derivation_version' using errcode = '22023';
  end if;
  if input_time_zone_identifier is null or not exists (
    select 1 from pg_catalog.pg_timezone_names z where z.name = input_time_zone_identifier
  ) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  -- Serialize a sender's creates before checking idempotence or pending pairs.
  select p.id into caller_profile_id from public.profiles p
  where p.auth_user_id = input_creator_auth_user_id and p.state = 'active'
  for update;
  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  select c.id, c.time_zone_identifier, c.rematch_parent_id,
    c.invite_token_derivation_version, c.invited_profile_id, i.token_digest
  into existing_invite from public.competitions c
  join public.competition_invites i on i.competition_id = c.id
  where c.creator_profile_id = caller_profile_id
    and c.invite_creation_idempotency_key = input_idempotency_key;
  if found then
    if existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.invited_profile_id is not distinct from input_recipient_profile_id
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;
    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  if input_recipient_profile_id is null or input_recipient_profile_id = caller_profile_id
     or not exists (select 1 from public.profiles p
       where p.id = input_recipient_profile_id and p.state = 'active') then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select c.scoring_policy_identity into source_scoring_policy
    from public.competitions c
    where c.id = input_rematch_parent_id and c.lifecycle in ('completed', 'archived')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = caller_profile_id and p.state = 'accepted')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = input_recipient_profile_id and p.state = 'accepted');
    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  update public.competitions c set lifecycle = 'expired', updated_at = created_time
  where c.creator_profile_id = caller_profile_id and c.lifecycle = 'pending'
    and c.invitation_expires_at <= created_time;
  if exists (select 1 from public.competitions c
    where c.creator_profile_id = caller_profile_id
      and c.invited_profile_id = input_recipient_profile_id and c.lifecycle = 'pending') then
    raise exception 'pending_invitation_exists' using errcode = 'P0001';
  end if;

  insert into public.competitions (
    creator_profile_id, invited_profile_id, time_zone_identifier, scoring_policy_identity,
    lifecycle, invitation_expires_at, rematch_parent_id, invite_creation_idempotency_key,
    invite_token_derivation_version, created_at, updated_at
  ) values (
    caller_profile_id, input_recipient_profile_id, input_time_zone_identifier,
    source_scoring_policy, 'pending', invite_expires_at, input_rematch_parent_id,
    input_idempotency_key, input_derivation_version, created_time, created_time
  ) returning id into new_competition_id;
  insert into public.competition_participants (competition_id, profile_id, role, state)
  values (new_competition_id, caller_profile_id, 'creator', 'accepted'),
    (new_competition_id, input_recipient_profile_id, 'invitee', 'pending');
  insert into public.competition_invites (competition_id, token_digest, expires_at, created_at)
  values (new_competition_id, input_token_digest, invite_expires_at, created_time);
  return new_competition_id;
end;
$$;
revoke all on function public.create_competition_invite(bytea, text, uuid, uuid, uuid, smallint, uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.create_competition_invite(bytea, text, uuid, uuid, uuid, smallint, uuid)
  to service_role;

create or replace function public.claim_competition_invite(token_digest bytea)
returns uuid language plpgsql security definer set search_path = ''
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
  if input_token_digest is null or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  caller_profile_id := private.current_profile_id();
  if caller_profile_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  select i.id, i.competition_id, i.claimed_profile_id, i.consumed_at, i.expires_at,
    c.creator_profile_id, c.invited_profile_id, c.time_zone_identifier, c.lifecycle
  into target_invite from public.competition_invites i
  join public.competitions c on c.id = i.competition_id
  where i.token_digest = input_token_digest for update of i, c;
  if found and target_invite.consumed_at is not null
     and target_invite.claimed_profile_id = caller_profile_id then
    return target_invite.competition_id;
  end if;
  if not found or target_invite.consumed_at is not null
     or target_invite.claimed_profile_id is not null
     or target_invite.expires_at <= pg_catalog.statement_timestamp()
     or target_invite.lifecycle <> 'pending' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  if target_invite.creator_profile_id = caller_profile_id then
    raise exception 'cannot_claim_own_invite' using errcode = 'P0001';
  end if;
  if target_invite.invited_profile_id is distinct from caller_profile_id then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  frozen_start_day := (pg_catalog.statement_timestamp()
    at time zone target_invite.time_zone_identifier)::date + 1;
  frozen_deadline := ((frozen_start_day + private.best_available_local_day_offset_v1())::timestamp
    at time zone target_invite.time_zone_identifier);
  update public.competition_participants set state = 'accepted'
  where competition_id = target_invite.competition_id
    and profile_id = caller_profile_id and role = 'invitee' and state = 'pending';
  if not found then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  update public.competition_invites set claimed_profile_id = caller_profile_id,
    consumed_at = pg_catalog.statement_timestamp() where id = target_invite.id;
  update public.competitions set start_day = frozen_start_day, lifecycle = 'scheduled',
    best_available_deadline = frozen_deadline, updated_at = pg_catalog.statement_timestamp()
  where id = target_invite.competition_id;
  return target_invite.competition_id;
end;
$$;

-- Expire bearer-only links after table DDL so deferred trigger events cannot block it.
update public.competitions
set lifecycle = 'expired', updated_at = pg_catalog.statement_timestamp()
where lifecycle = 'pending';
