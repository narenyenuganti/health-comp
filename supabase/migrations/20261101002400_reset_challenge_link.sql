-- Reset Link, and challenge links that really stop working once reset.
-- A link no longer hands out its owner's account id: resolving it returns
-- only the display name, and a challenge from a link is created by its
-- current code, which the invite records (never readable by clients).
-- Challenges already created stay. The id-based create remains for
-- rematches, past opponents and 1.0.2, but not for a sender whose only way
-- in was a link that has since been reset.

alter table public.competition_invites
  add column challenge_link_code text
    check (challenge_link_code ~ '^[A-Za-z0-9_-]{22}$');

-- Replaces the caller's code; the old one reads as any unknown code.
-- Same {code} shape as get_my_challenge_link.
create function public.reset_my_challenge_link()
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  link_code text;
begin
  insert into private.challenge_links as l (profile_id, code)
  values (caller_profile_id, private.new_challenge_link_code_v1())
  on conflict (profile_id) do update
    set code = excluded.code, created_at = pg_catalog.now()
  returning l.code into link_code;
  return pg_catalog.jsonb_build_object('code', link_code);
end;
$$;

-- 1900's resolve without the account id.
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
  if not found or target.state <> 'active' then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object('display_name', target.display_name);
end;
$$;

-- 1900's create, plus the link code it was created from (null by id) and
-- the reset-link check before any other recipient rule.
create function private.create_competition_invite_v2(
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
  -- id they saw: refused when this sender only ever reached the recipient
  -- through links that are no longer current, and the two never had an
  -- accepted match. A 1.0.2 sender who never used a link, and real past
  -- opponents, are unaffected.
  if input_rematch_parent_id is null and input_link_code is null
     and exists (select 1 from public.competitions c
       join public.competition_invites i on i.competition_id = c.id
       where c.creator_profile_id = caller_profile_id
         and c.invited_profile_id = input_recipient_profile_id
         and i.challenge_link_code is not null)
     and not exists (select 1 from public.competitions c
       join public.competition_invites i on i.competition_id = c.id
       join private.challenge_links l
         on l.profile_id = input_recipient_profile_id and l.code = i.challenge_link_code
       where c.creator_profile_id = caller_profile_id
         and c.invited_profile_id = input_recipient_profile_id)
     and not exists (select 1 from public.competitions c
       join public.competition_participants a
         on a.competition_id = c.id and a.profile_id = caller_profile_id and a.state = 'accepted'
       join public.competition_participants b
         on b.competition_id = c.id and b.profile_id = input_recipient_profile_id
        and b.state = 'accepted'
       where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying',
         'completed', 'archived')) then
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

-- 1.0.2's body, rematches and Challenge Again: by account id.
create or replace function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  recipient_profile_id uuid
)
returns uuid language sql security definer set search_path = ''
as $$
  select private.create_competition_invite_v2(token_digest, creator_time_zone_identifier,
    rematch_parent_id, creator_auth_user_id, creation_idempotency_key,
    token_derivation_version, recipient_profile_id, null);
$$;

-- Create from a challenge link: the code must be the owner's current one,
-- else the same recipient_unavailable as an unknown code. The link row is
-- share-locked so a concurrent reset waits for this create to finish.
-- An exact retry of a challenge already created (a lost response, or the
-- app recovering its link) returns it even after a reset, whatever code it
-- sends; the create still checks that the rest of the retry matches.
create function public.create_competition_invite_from_link(
  token_digest bytea,
  creator_time_zone_identifier text,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint,
  challenge_link_code text
)
returns uuid language plpgsql security definer set search_path = ''
as $$
declare
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_code alias for challenge_link_code;
  recipient_id uuid;
  used_code text;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  select c.invited_profile_id into recipient_id
  from public.competitions c
  join public.profiles p on p.id = c.creator_profile_id
  where p.auth_user_id = input_creator_auth_user_id
    and c.invite_creation_idempotency_key = input_idempotency_key;
  if not found then
    if input_code is null or input_code !~ '^[A-Za-z0-9_-]{22}$' then
      raise exception 'recipient_unavailable' using errcode = 'P0001';
    end if;
    select l.profile_id into recipient_id
    from private.challenge_links l
    where l.code = input_code
    for share;
    if recipient_id is null then
      raise exception 'recipient_unavailable' using errcode = 'P0001';
    end if;
    used_code := input_code;
  end if;
  return private.create_competition_invite_v2(token_digest, creator_time_zone_identifier,
    null, input_creator_auth_user_id, input_idempotency_key, token_derivation_version,
    recipient_id, used_code);
end;
$$;

revoke all on function public.reset_my_challenge_link()
  from public, anon, authenticated, service_role;
revoke all on function public.resolve_challenge_link(text)
  from public, anon, authenticated, service_role;
revoke all on function private.create_competition_invite_v2(
  bytea, text, uuid, uuid, uuid, smallint, uuid, text)
  from public, anon, authenticated, service_role;
revoke all on function public.create_competition_invite_from_link(
  bytea, text, uuid, uuid, smallint, text)
  from public, anon, authenticated, service_role;
grant execute on function public.reset_my_challenge_link() to authenticated;
grant execute on function public.resolve_challenge_link(text) to authenticated;
grant execute on function public.create_competition_invite_from_link(
  bytea, text, uuid, uuid, smallint, text) to service_role;
