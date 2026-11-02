-- Block a challenger: the recipient of a challenge can stop its sender from
-- challenging them again. Blocking declines their pending challenge exactly
-- like Decline (same push), and every later create or lookup by that sender
-- reads as recipient_unavailable, the same as a reset link or a gone
-- account. Checked after the pair rules, so the blocked person only ever
-- sees a refusal on a create that would otherwise have succeeded. One-way,
-- keyed by account id, and granted only through a challenge addressed to
-- the blocker: there is no way to block or probe an arbitrary account.

create table private.account_blocks (
  blocker_profile_id uuid not null references public.profiles(id) on delete cascade,
  blocked_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (blocker_profile_id, blocked_profile_id),
  constraint account_blocks_distinct_profiles
    check (blocker_profile_id <> blocked_profile_id)
);
create index account_blocks_blocked_profile_id_idx
  on private.account_blocks(blocked_profile_id);
alter table private.account_blocks enable row level security;
alter table private.account_blocks force row level security;
revoke all on table private.account_blocks
  from public, anon, authenticated, service_role;

-- Profiles are anonymized, not deleted, so the foreign key cascade alone
-- never fires: starting deletion drops the account's blocks both ways.
create function private.purge_account_blocks_on_profile_deactivation()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  if old.state = 'active' and new.state <> 'active' then
    delete from private.account_blocks b
    where b.blocker_profile_id = new.id or b.blocked_profile_id = new.id;
  end if;
  return new;
end;
$$;
create trigger purge_account_blocks_on_profile_deactivation
after update of state on public.profiles
for each row execute function private.purge_account_blocks_on_profile_deactivation();

-- Keyed by a challenge addressed to the caller, in any lifecycle. Takes the
-- profile locks in the create's order, so a concurrent create either
-- commits first (and is declined here) or waits and then sees the block.
create function public.block_challenger(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz;
  sender_profile_id uuid;
  declined record;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  select c.creator_profile_id into sender_profile_id
  from public.competitions c
  where c.id = input_competition_id and c.invited_profile_id = caller_profile_id
    and c.creator_profile_id <> caller_profile_id;
  if sender_profile_id is null then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;
  perform 1 from public.profiles p
  where p.id in (sender_profile_id, caller_profile_id)
  order by p.id for no key update;
  -- A deletion that committed while this waited has already purged blocks.
  if not exists (select 1 from public.profiles p
    where p.id = caller_profile_id and p.state = 'active') then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  -- After the locks, so a create that waited on them is seen as pending.
  decision_time := pg_catalog.clock_timestamp();
  insert into private.account_blocks (blocker_profile_id, blocked_profile_id)
  select caller_profile_id, sender_profile_id
  where exists (select 1 from public.profiles p
    where p.id = sender_profile_id and p.state = 'active')
  on conflict do nothing;
  -- Decline's effects (1900): the invitee participant stays pending.
  for declined in
    update public.competitions c set lifecycle = 'declined',
      closed_by_profile_id = caller_profile_id, closed_at = decision_time,
      updated_at = decision_time
    where c.creator_profile_id = sender_profile_id
      and c.invited_profile_id = caller_profile_id and c.lifecycle = 'pending'
      and c.invitation_expires_at > decision_time
    returning c.id
  loop
    perform private.enqueue_challenge_notification(
      declined.id, 'challenge_declined', sender_profile_id, caller_profile_id);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id', input_competition_id);
end;
$$;

-- Answers the same whether or not a block existed; only the caller's rows.
create function public.unblock_profile(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_profile_id alias for profile_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  if input_profile_id is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  delete from private.account_blocks b
  where b.blocker_profile_id = caller_profile_id
    and b.blocked_profile_id = input_profile_id;
  return pg_catalog.jsonb_build_object('profile_id', input_profile_id);
end;
$$;

-- Newest 200 first. Older blocks stay in force (an accepted limit).
create function public.list_blocked_profiles()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
begin
  return pg_catalog.jsonb_build_object('blocked', coalesce((
    select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'id', listed.id, 'display_name', listed.display_name)
      order by listed.created_at desc, listed.id)
    from (
      select p.id, p.display_name, b.created_at
      from private.account_blocks b
      join public.profiles p on p.id = b.blocked_profile_id and p.state = 'active'
      where b.blocker_profile_id = caller_profile_id
      order by b.created_at desc, p.id
      limit 200
    ) listed
  ), '[]'::jsonb));
end;
$$;

-- 2400's create, plus the block check after the pair checks.
create or replace function private.create_competition_invite_v2(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  recipient_profile_id uuid,
  challenge_link_code text
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
  input_link_code alias for challenge_link_code;
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

  -- No key update: closed_by_profile_id's foreign key check (key share)
  -- from a concurrent decline or cancel must not wait on these locks.
  -- Serialize creates and accepts between both people before checking
  -- idempotence, pending pairs, overlap and reciprocal challenges.
  select p.id into caller_profile_id from public.profiles p
  where p.auth_user_id = input_creator_auth_user_id and p.state = 'active';
  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  perform 1 from public.profiles p
  where p.id in (caller_profile_id, input_recipient_profile_id)
  order by p.id for no key update;
  if not exists (select 1 from public.profiles p
    where p.id = caller_profile_id and p.state = 'active') then
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
  -- A reset link also stops its challengers from switching to the account
  -- id they saw (a rematch is between people who already played).
  if input_rematch_parent_id is null and input_link_code is null
     and private.challenge_link_revoked_v1(caller_profile_id, input_recipient_profile_id) then
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
  if private.match_in_progress_between(caller_profile_id, input_recipient_profile_id)
     is not null then
    raise exception 'active_match_exists' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.competitions c
    where c.creator_profile_id = input_recipient_profile_id
      and c.invited_profile_id = caller_profile_id and c.lifecycle = 'pending'
      and c.invitation_expires_at > created_time) then
    raise exception 'incoming_challenge_exists' using errcode = 'P0001';
  end if;
  -- Someone the recipient blocked reads as unavailable. Pair conflicts
  -- above describe only what both people already see.
  if exists (select 1 from private.account_blocks b
    where b.blocker_profile_id = input_recipient_profile_id
      and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
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
  insert into public.competition_invites (
    competition_id, token_digest, expires_at, created_at, challenge_link_code
  ) values (
    new_competition_id, input_token_digest, invite_expires_at, created_time, input_link_code
  );
  perform private.enqueue_challenge_notification(
    new_competition_id, 'challenge_received', input_recipient_profile_id, caller_profile_id);
  return new_competition_id;
end;
$$;

-- 2400's lookup, plus the block check.
create or replace function public.resolve_invitation_recipient(profile_id uuid)
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
  if recipient is null
     or private.challenge_link_revoked_v1(caller_profile_id, input_profile_id)
     or exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = input_profile_id
         and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return recipient;
end;
$$;

-- 2400's lookup, plus the block check. The own-link branch stays first.
create or replace function public.resolve_challenge_link(code text)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  input_code alias for code;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  target record;
begin
  if input_code is null or input_code !~ '^[A-Za-z0-9_-]{22}$' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  select p.id, p.display_name, p.state into target
  from private.challenge_links l
  join public.profiles p on p.id = l.profile_id
  where l.code = input_code;
  if found and target.id = caller_profile_id then
    raise exception 'own_challenge_link' using errcode = 'P0001';
  end if;
  if not found or target.state <> 'active'
     or exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = target.id
         and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object('display_name', target.display_name);
end;
$$;

revoke all on function private.purge_account_blocks_on_profile_deactivation()
  from public, anon, authenticated, service_role;
revoke all on function public.block_challenger(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.unblock_profile(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.list_blocked_profiles()
  from public, anon, authenticated, service_role;
grant execute on function public.block_challenger(uuid) to authenticated;
grant execute on function public.unblock_profile(uuid) to authenticated;
grant execute on function public.list_blocked_profiles() to authenticated;
