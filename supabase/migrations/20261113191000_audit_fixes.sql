-- Audit fixes (2026-11-13). Additive: no released signature changes, and
-- every replaced function keeps its arguments, result and error codes.
-- Every private function needs its own `revoke all ... from public, anon,
-- authenticated, service_role`: 0200's per-schema default revoke cannot
-- remove PostgreSQL's global PUBLIC EXECUTE default.

-- Row checks as a set: the participant policies used to run a SECURITY
-- DEFINER check once per row of every competition on the platform.
create function private.current_duel_competition_ids()
returns setof uuid language sql stable security definer set search_path = ''
as $$
  select p.competition_id from public.competition_participants p
  join public.competitions c on c.id = p.competition_id and c.format = 'duel'
  where p.profile_id = private.current_profile_id() and p.state = 'accepted';
$$;
revoke all on function private.current_duel_competition_ids() from public, anon, authenticated, service_role;
grant execute on function private.current_duel_competition_ids() to authenticated;

alter policy competitions_participant_read on public.competitions
  using (id in (select private.current_duel_competition_ids()));
alter policy competition_participants_participant_read on public.competition_participants
  using (competition_id in (select private.current_duel_competition_ids()));
alter policy daily_score_revisions_participant_read on public.daily_score_revisions
  using (competition_id in (select private.current_duel_competition_ids()));
alter policy participant_attestations_participant_read on public.participant_finalization_attestations
  using (competition_id in (select private.current_duel_competition_ids()));
alter policy competition_results_participant_read on public.competition_results
  using (competition_id in (select private.current_duel_competition_ids()));
alter policy competition_awards_participant_read on public.competition_awards
  using (competition_id in (select private.current_duel_competition_ids()));

-- A profile id read from someone else's group lineup is not a challenge
-- credential, even for a person without a username. Usernameless people with
-- no group link keep the old app's id path (028_friends_invites).
create function private.needs_direct_challenge_history(caller uuid, recipient uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles p where p.id = recipient and p.username is not null)
    or exists (select 1 from public.competition_participants a
      join public.competition_participants b on b.competition_id = a.competition_id and b.profile_id = recipient
      join public.competitions c on c.id = a.competition_id and c.format <> 'duel'
      where a.profile_id = caller);
$$;
revoke all on function private.needs_direct_challenge_history(uuid,uuid) from public,anon,authenticated,service_role;

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
  f boolean;
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
  f := private.are_friends(caller_profile_id, input_recipient_profile_id);
  -- A reset link also stops its challengers from switching to the account
  -- id they saw (a rematch is between people who already played).
  if input_rematch_parent_id is null and input_link_code is null
     and not f and private.challenge_link_revoked_v1(caller_profile_id, input_recipient_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  -- Search discovery is not a challenge link; shipped Challenge Again has history.
  if input_rematch_parent_id is null and input_link_code is null and not f
     and private.needs_direct_challenge_history(caller_profile_id,input_recipient_profile_id)
     and not private.has_direct_challenge_history(caller_profile_id,input_recipient_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select c.scoring_policy_identity into source_scoring_policy
    from public.competitions c
    where c.id = input_rematch_parent_id and c.format = 'duel' and c.lifecycle in ('completed', 'archived')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = caller_profile_id and p.state = 'accepted')
      and exists (select 1 from public.competition_participants p
        where p.competition_id = c.id and p.profile_id = input_recipient_profile_id and p.state = 'accepted');
    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  if not f and exists (select 1 from public.profiles p
    where p.id = input_recipient_profile_id and p.challenge_policy = 'friends_only') then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
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
  -- Generous caps no real player meets: 30 challenges an hour, and 10 a day
  -- to one person. The caller's profile lock above serializes the counts.
  if (select count(*) from public.competitions c
      where c.creator_profile_id = caller_profile_id and c.format = 'duel'
        and c.created_at > created_time - interval '1 hour') >= 30
    or (select count(*) from public.competitions c
      where c.creator_profile_id = caller_profile_id and c.format = 'duel'
        and c.invited_profile_id = input_recipient_profile_id
        and c.created_at > created_time - interval '24 hours') >= 10 then
    raise exception 'invite_rate_limited' using errcode = 'P0001';
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
     or (not private.are_friends(caller_profile_id, input_profile_id)
       and (private.challenge_link_revoked_v1(caller_profile_id, input_profile_id)
         or exists (select 1 from public.profiles p where p.id = input_profile_id
           and p.challenge_policy = 'friends_only')
         or (private.needs_direct_challenge_history(caller_profile_id,input_profile_id)
           and not private.has_direct_challenge_history(caller_profile_id,input_profile_id))))
     or exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = input_profile_id
         and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return recipient;
end;
$$;

create or replace function public.create_group_match(format text, seats jsonb, time_zone_identifier text, creation_idempotency_key uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  input_format alias for format; input_seats alias for seats; input_zone alias for time_zone_identifier;
  input_key alias for creation_idempotency_key;
  caller uuid; cid uuid := extensions.gen_random_uuid(); existing record; request_hash bytea;
  entry jsonb; normalized jsonb := '[]'::jsonb; pid uuid; humans uuid[] := '{}'::uuid[];
  idx integer := 0; n integer; missing record; decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_format is null or input_format not in ('three_way','four_way','doubles')
    or pg_catalog.jsonb_typeof(input_seats) is distinct from 'array'
    or input_zone is null or not exists (select 1 from pg_catalog.pg_timezone_names z where z.name = input_zone) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  n := pg_catalog.jsonb_array_length(input_seats);
  if n <> (case when input_format = 'three_way' then 3 else 4 end) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  -- Validate the entire shape before any code resolution or profile lookup.
  if input_key is null then raise exception 'invalid_group_match' using errcode = '22023'; end if;
  for entry in select value from pg_catalog.jsonb_array_elements(input_seats) loop
    idx := idx + 1;
    if pg_catalog.jsonb_typeof(entry) is distinct from 'object'
      or coalesce(entry->>'kind','') not in ('human','bot')
      or exists (select 1 from pg_catalog.jsonb_object_keys(entry) k where k not in ('kind','profile_id','challenge_link_code','team_number','bot_mode'))
      or (input_format = 'doubles' and coalesce(entry->>'team_number','') not in ('1','2'))
      or (input_format <> 'doubles' and entry->>'team_number' is not null) then
      raise exception 'invalid_group_seat' using errcode = '22023';
    end if;
    if entry->>'kind' = 'human' then
      if (entry->>'profile_id' is null) = (entry->>'challenge_link_code' is null)
        or entry->>'bot_mode' is not null
        or (entry->>'profile_id' is not null and entry->>'profile_id' !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')
        or (entry->>'challenge_link_code' is not null and entry->>'challenge_link_code' !~ '^[A-Za-z0-9_-]{22}$')
        or (idx = 1 and entry->>'profile_id' is null) then
        raise exception 'invalid_group_seat' using errcode = '22023';
      end if;
    elsif idx = 1 or coalesce(entry->>'bot_mode','') not in ('pacer','chill','erratic','beast')
      or entry->>'profile_id' is not null or entry->>'challenge_link_code' is not null then
      raise exception 'invalid_group_seat' using errcode = '22023';
    end if;
  end loop;
  if (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(input_seats) e where e->>'kind' = 'human') < 2
    or (input_format = 'doubles' and (select pg_catalog.count(*) from pg_catalog.jsonb_array_elements(input_seats) e where e->>'team_number' = '1') <> 2)
    or exists (select 1 from pg_catalog.jsonb_array_elements(input_seats) e where e->>'profile_id' is not null
      group by (e->>'profile_id')::uuid having pg_catalog.count(*) > 1) then
    raise exception 'invalid_group_match' using errcode = '22023';
  end if;
  caller := private.require_active_caller_profile_id();
  request_hash := extensions.digest(pg_catalog.jsonb_build_object('format',input_format,'seats',input_seats,'zone',input_zone)::text,'sha256');
  -- Serialize retries independently of link resolution, including a link reset after the first commit.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended('group-create/' || caller::text || '/' || input_key::text,0));
  select c.id,c.group_creation_request_sha256 into existing from public.competitions c
    where c.creator_profile_id = caller and c.invite_creation_idempotency_key = input_key;
  if found then
    if existing.group_creation_request_sha256 is distinct from request_hash then raise exception 'idempotency_conflict' using errcode = 'P0001'; end if;
    return pg_catalog.jsonb_build_object('competition_id',existing.id);
  end if;
  idx := 0;
  for entry in select value from pg_catalog.jsonb_array_elements(input_seats) loop
    idx := idx + 1; pid := (entry->>'profile_id')::uuid;
    if entry->>'kind' = 'human' then
      if entry->>'challenge_link_code' is not null then
        select l.profile_id into pid from private.challenge_links l where l.code = entry->>'challenge_link_code';
      end if;
      if pid is null or pid = any(humans) or (idx = 1 and pid <> caller) or (idx <> 1 and pid = caller) then
        raise exception 'recipient_unavailable' using errcode = 'P0001';
      end if;
      humans := pg_catalog.array_append(humans,pid);
      entry := entry || pg_catalog.jsonb_build_object('profile_id',pid);
    end if;
    normalized := normalized || pg_catalog.jsonb_build_array(entry);
  end loop;
  -- The same ordered profile locks serialize creation, acceptance and blocking.
  perform 1 from public.profiles p where p.id = any(humans) order by p.id for no key update;
  if exists (select 1 from pg_catalog.unnest(humans) h(id)
    where not exists (select 1 from public.profiles p where p.id = h.id and p.state = 'active'))
    or exists (select 1 from pg_catalog.jsonb_array_elements(normalized) e
      where e->>'kind' = 'human' and (e->>'profile_id')::uuid <> caller
        and ((e->>'challenge_link_code' is null and not private.are_friends(caller,(e->>'profile_id')::uuid)
            and private.challenge_link_revoked_v1(caller,(e->>'profile_id')::uuid))
          or (e->>'challenge_link_code' is not null and not exists (select 1 from private.challenge_links l
            where l.profile_id = (e->>'profile_id')::uuid and l.code = e->>'challenge_link_code'))))
    or exists (select 1 from pg_catalog.jsonb_array_elements(normalized) e
      join public.profiles recipient on recipient.id = (e->>'profile_id')::uuid
      where e->>'kind' = 'human' and recipient.id <> caller
        and not private.are_friends(caller,recipient.id)
        and (recipient.challenge_policy = 'friends_only'
          or (e->>'challenge_link_code' is null and private.needs_direct_challenge_history(caller,recipient.id)
            and not private.has_direct_challenge_history(caller,recipient.id))))
    or exists (select 1 from private.account_blocks b where b.blocker_profile_id = any(humans) and b.blocked_profile_id = any(humans)) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  -- Capability is checked last so blocked, reset-link and inactive profiles have no update oracle.
  select p.id,p.display_name into missing from public.profiles p where p.id = any(humans)
    and not exists (select 1 from public.device_installations i where i.profile_id = p.id and i.state = 'active' and i.supports_group_matches)
    order by pg_catalog.array_position(humans,p.id) limit 1;
  if found then raise exception 'group_update_required' using errcode = 'P0001', detail = missing.id::text,
    hint = missing.display_name || ' needs to update HealthComp first.'; end if;
  if (select count(*) from public.competitions c where c.creator_profile_id = caller and c.format <> 'duel'
    and ((c.lifecycle = 'pending' and c.invitation_expires_at > decision_time)
      or (c.lifecycle in ('scheduled','active','ends_today','tallying') and
        (decision_time at time zone c.time_zone_identifier)::date <= c.start_day + 6))) >= 5 then
    raise exception 'group_creation_limit' using errcode = 'P0001';
  end if;
  insert into public.competitions(id,creator_profile_id,format,seat_count,time_zone_identifier,scoring_policy_identity,lifecycle,invitation_expires_at,invite_creation_idempotency_key,group_creation_request_sha256)
    values(cid,caller,input_format,n,input_zone,'healthcomp.activity-score.v1','pending',decision_time + private.invitation_expiry_interval_v1(),input_key,request_hash);
  idx := 0;
  for entry in select value from pg_catalog.jsonb_array_elements(normalized) loop
    idx := idx + 1; pid := (entry->>'profile_id')::uuid;
    if entry->>'kind' = 'human' then
      insert into public.competition_participants(competition_id,profile_id,role,state,seat_index,team_number)
        values(cid,pid,case when idx = 1 then 'creator' else 'invitee' end,
          case when idx = 1 then 'accepted' else 'pending' end,idx,(entry->>'team_number')::integer);
    end if;
    insert into public.competition_seats(competition_id,seat_index,team_number,kind,profile_id,challenge_link_code,bot_mode)
      values(cid,idx,(entry->>'team_number')::integer,entry->>'kind',pid,entry->>'challenge_link_code',entry->>'bot_mode');
  end loop;
  insert into public.competition_invites(competition_id,token_digest,expires_at)
    values(cid,extensions.digest(extensions.gen_random_bytes(32),'sha256'),decision_time + private.invitation_expiry_interval_v1());
  for pid in select h from pg_catalog.unnest(humans) h where h <> caller loop
    perform private.enqueue_challenge_notification(cid,'challenge_received',pid,caller);
  end loop;
  return pg_catalog.jsonb_build_object('competition_id',cid);
end; $$;

-- Challenge and cancel pushes are rate limited per sender and recipient.
create index competition_notification_work_challenge_guard_idx
  on private.competition_notification_work(kind, source_profile_id, recipient_profile_id, created_at)
  where kind in ('challenge_received', 'match_cancelled');

create or replace function private.enqueue_challenge_notification(
  target_competition_id uuid,
  target_kind text,
  target_recipient_profile_id uuid,
  target_source_profile_id uuid
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  target_server_seq bigint;
  decision_time timestamptz := pg_catalog.statement_timestamp();
  is_muted boolean;
begin
  if target_kind not in ('challenge_received', 'challenge_declined', 'match_cancelled') then
    raise exception 'invalid_notification_kind' using errcode = '22023';
  end if;
  -- The change that caused this notification is the competition's latest.
  select max(log_row.server_seq) into target_server_seq
  from public.competition_change_log log_row
  where log_row.competition_id = target_competition_id;
  is_muted := exists (
    select 1 from private.competition_notification_mutes mute_row
    where mute_row.profile_id = target_recipient_profile_id
      and mute_row.opponent_profile_id = target_source_profile_id
  )
  -- A create/cancel loop cannot flood a phone: once a sender has cancelled a
  -- match they pushed to this person in the last hour, further challenge and
  -- cancel pushes between them that hour land suppressed.
  or (target_kind in ('challenge_received', 'match_cancelled') and exists (
    select 1 from private.competition_notification_work w
    join public.competitions earlier on earlier.id = w.competition_id and earlier.lifecycle = 'cancelled'
    where w.kind = target_kind and w.source_profile_id = target_source_profile_id
      and w.recipient_profile_id = target_recipient_profile_id
      and w.competition_id <> target_competition_id
      and w.created_at > decision_time - interval '1 hour'));

  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind,
    recipient_profile_id, source_profile_id, installation_id,
    state, available_at, created_at, updated_at, completed_at
  )
  select 'healthcomp.server-notification:v1:'
      || target_competition_id::text || ':' || target_kind || ':'
      || target_server_seq::text || ':'
      || target_recipient_profile_id::text || ':'
      || installation_row.installation_id::text,
    target_competition_id, target_server_seq, target_kind,
    target_recipient_profile_id, target_source_profile_id,
    installation_row.installation_id,
    case when is_muted then 'suppressed' else 'pending' end,
    decision_time, decision_time, decision_time,
    case when is_muted then decision_time else null end
  from public.device_installations installation_row
  join public.profiles profile_row on profile_row.id = installation_row.profile_id
  where installation_row.profile_id = target_recipient_profile_id
    and installation_row.state = 'active'
    and (installation_row.supports_group_matches or exists (select 1 from public.competitions c where c.id = target_competition_id and c.format = 'duel'))
    and profile_row.state = 'active'
  order by installation_row.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
end;
$$;

-- settle_now: an account deletion settles a duel whose week is over on
-- best_available instead of waiting for the deadline (and cancelling it).
create function private.finalize_competition_locked(target_competition_id uuid, as_of timestamptz, settle_now boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare c record; pids uuid[]; rev_a bigint[]; rev_b bigint[]; com_a bytea; com_b bytea; pa jsonb; pb jsonb; total_a integer; total_b integer;
 final_basis text; outcome text; winner uuid; frozen_projection jsonb; result_hash bytea; existing record;
begin
 select * into c from public.competitions where id=target_competition_id for update;
 if not found then return null; end if;
 if c.format <> 'duel' then return private.finalize_group_match_locked(target_competition_id,as_of); end if;
 select * into existing from public.competition_results where competition_id=target_competition_id;
 if found then return pg_catalog.jsonb_build_object('disposition','existing','serverCursor',existing.server_seq::text); end if;
 select pg_catalog.array_agg(profile_id order by profile_id) into pids from public.competition_participants
   where competition_id=target_competition_id and state='accepted';
 if pg_catalog.array_length(pids,1)<>2 then return null; end if;
 if (select count(*) from (select distinct on(att.participant_profile_id) att.participant_profile_id,att.basis from public.participant_finalization_attestations att
      where att.competition_id=target_competition_id order by att.participant_profile_id,att.attestation_version desc) latest where latest.basis='stable')=2 then final_basis:='stable';
 elsif as_of>=c.best_available_deadline
   or (settle_now and as_of>=((c.start_day+7)::timestamp at time zone c.time_zone_identifier)) then final_basis:='best_available'; else return null; end if;
 rev_a:=private.latest_revision_vector(target_competition_id,pids[1]); rev_b:=private.latest_revision_vector(target_competition_id,pids[2]);
 com_a:=private.owner_window_commitment_v1(target_competition_id,pids[1],rev_a); com_b:=private.owner_window_commitment_v1(target_competition_id,pids[2],rev_b);
 pa:=private.participant_projection_v2(target_competition_id,pids[1],rev_a,com_a); pb:=private.participant_projection_v2(target_competition_id,pids[2],rev_b,com_b);
 total_a:=(pa->>'total_centi_points')::integer; total_b:=(pb->>'total_centi_points')::integer;
 if total_a=total_b then outcome:='tie';winner:=null; elsif total_a>total_b then outcome:='winner';winner:=pids[1];else outcome:='winner';winner:=pids[2];end if;
 frozen_projection:=pg_catalog.jsonb_build_object('version',2,'policy','healthcomp.activity-score.v1','participants',pg_catalog.jsonb_build_array(pa,pb));
 result_hash:=private.result_immutable_hash_v1(target_competition_id,pids[1],total_a,com_a,pids[2],total_b,com_b,outcome,winner,final_basis);
 insert into public.competition_results(competition_id,participant_a_profile_id,participant_b_profile_id,participant_a_total_centi_points,
   participant_b_total_centi_points,winner_profile_id,outcome,finalization_basis,completed_at,frozen_window,immutable_hash,server_seq)
 values(target_competition_id,pids[1],pids[2],total_a,total_b,winner,outcome,final_basis,as_of,frozen_projection,result_hash,1);
 if winner is not null then insert into public.competition_awards(competition_id,profile_id,award_type,server_seq,earned_at)
   values(target_competition_id,winner,'competition_win',1,as_of) on conflict do nothing; end if;
 update public.competitions set lifecycle='completed',updated_at=as_of where id=target_competition_id;
 return pg_catalog.jsonb_build_object('disposition','finalized','basis',final_basis,'immutableHash',pg_catalog.encode(result_hash,'hex'));
end; $$;
revoke all on function private.finalize_competition_locked(uuid,timestamptz,boolean) from public,anon,authenticated,service_role;

create or replace function private.finalize_competition_locked(target_competition_id uuid, as_of timestamptz)
returns jsonb language plpgsql security definer set search_path = ''
as $$ begin
  return private.finalize_competition_locked(target_competition_id, as_of, false);
end; $$;

create or replace function private.store_account_deletion_apple_token(
  target_profile_id uuid,
  refresh_token text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_profile_id alias for target_profile_id;
  input_refresh_token alias for refresh_token;
  deletion_row record;
  secret_name text;
  group_match record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if input_profile_id is null
     or input_refresh_token is null
     or pg_catalog.char_length(input_refresh_token) not between 16 and 4096
     or input_refresh_token ~ '[[:space:][:cntrl:]]' then
    raise exception 'invalid_apple_refresh_token'
      using errcode = '22023';
  end if;

  select deletion_record.*
  into deletion_row
  from private.account_deletions deletion_record
  where deletion_record.profile_id = input_profile_id
  for update;

  if not found then
    raise exception 'account_deletion_not_found' using errcode = 'P0002';
  end if;

  if deletion_row.phase = 'token_ready' then
    return pg_catalog.jsonb_build_object(
      'profile_id', deletion_row.profile_id,
      'phase', deletion_row.phase
    );
  end if;

  if deletion_row.phase <> 'prepared' then
    raise exception 'invalid_account_deletion_phase'
      using errcode = '55000';
  end if;

  perform 1
  from public.profiles profile_record
  where profile_record.id = input_profile_id
    and profile_record.state = 'active'
  for update;

  if not found then
    raise exception 'active_profile_required' using errcode = '55000';
  end if;

  secret_name := private.account_deletion_secret_name(input_profile_id);
  delete from vault.secrets secret_row where secret_row.name = secret_name;
  perform vault.create_secret(
    input_refresh_token,
    secret_name,
    'Temporary Sign in with Apple token for durable account deletion'
  );

  update public.profiles profile_record
  set state = 'deleting',
      updated_at = decision_time
  where profile_record.id = input_profile_id;

  perform competition_record.id
  from public.competitions competition_record
  join public.competition_participants participant_record
    on participant_record.competition_id = competition_record.id
  where participant_record.profile_id = input_profile_id
    and competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
  order by competition_record.id
  for update of competition_record;

  -- A duel whose seven days are over is settled on what was uploaded, not
  -- cancelled, so the opponent keeps the result they played for.
  for group_match in select c.id from public.competitions c join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = input_profile_id
    where c.format = 'duel' and c.lifecycle in ('scheduled','active','ends_today','tallying')
      and decision_time >= ((c.start_day + 7)::timestamp at time zone c.time_zone_identifier)
    order by c.id loop
    perform private.finalize_competition_locked(group_match.id,decision_time,true);
  end loop;

  for group_match in select c.id from public.competitions c join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = input_profile_id
    where c.format <> 'duel' and c.lifecycle in ('scheduled','active','ends_today','tallying')
      and (decision_time at time zone c.time_zone_identifier)::date >= c.start_day
    order by c.id loop
    perform private.bank_group_match_seat(group_match.id,input_profile_id,decision_time);
  end loop;

  update public.competitions competition_record
  set lifecycle = 'cancelled',
      updated_at = decision_time
  where competition_record.lifecycle in (
      'pending', 'scheduled', 'active', 'ends_today', 'tallying'
    )
    and (competition_record.format = 'duel' or competition_record.lifecycle = 'pending'
      or (decision_time at time zone competition_record.time_zone_identifier)::date < competition_record.start_day
      or not exists (select 1 from public.competition_participants active_person
        where active_person.competition_id = competition_record.id and active_person.state = 'accepted' and active_person.left_at is null))
    and exists (
      select 1
      from public.competition_participants participant_record
      where participant_record.competition_id = competition_record.id
        and participant_record.profile_id = input_profile_id
    );

  delete from public.competition_invites invite_record
  where invite_record.consumed_at is null
    and exists (
      select 1
      from public.competitions competition_record
      join public.competition_participants participant_record
        on participant_record.competition_id = competition_record.id
      where competition_record.id = invite_record.competition_id
        and competition_record.lifecycle = 'cancelled'
        and participant_record.profile_id = input_profile_id
    );

  update public.device_installations installation_record
  set state = 'revoked',
      updated_at = decision_time
  where installation_record.profile_id = input_profile_id
    and installation_record.state = 'active';

  update private.competition_notification_work work_record
  set state = 'superseded',
      lease_token = null,
      lease_expires_at = null,
      leased_apns_token_sha256 = null,
      updated_at = decision_time,
      completed_at = decision_time
  where work_record.state in ('pending', 'leased')
    and (
      work_record.recipient_profile_id = input_profile_id
      or work_record.source_profile_id = input_profile_id
    );

  delete from private.competition_notification_mutes mute_record
  where mute_record.profile_id = input_profile_id
     or mute_record.opponent_profile_id = input_profile_id;

  update private.account_deletions deletion_record
  set phase = 'token_ready',
      updated_at = decision_time
  where deletion_record.profile_id = input_profile_id
  returning deletion_record.* into deletion_row;

  return pg_catalog.jsonb_build_object(
    'profile_id', deletion_row.profile_id,
    'phase', deletion_row.phase
  );
end;
$$;

-- Reactions and results list their keys: installed builds accept exact key
-- sets, so a new column on either table must not reach them.
create or replace function private.group_match_projection(cid uuid, viewer uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select pg_catalog.jsonb_build_object('version',1,'competition_id',c.id,'format',c.format,
    'server_version',(c.next_server_seq-1)::text,'creator_profile_id',c.creator_profile_id,
    'lifecycle',case when c.lifecycle = 'pending' and c.invitation_expires_at <= pg_catalog.statement_timestamp() then 'expired' else c.lifecycle end,
    'time_zone_identifier',c.time_zone_identifier,'start_day',c.start_day,'scoring_policy_identity',c.scoring_policy_identity,
    'invitation_expires_at',c.invitation_expires_at,'best_available_deadline',c.best_available_deadline,
    'closed_by_profile_id',c.closed_by_profile_id,'closed_at',c.closed_at,
    'seats',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'id',s.id,'seat_index',s.seat_index,'team_number',s.team_number,'kind',s.kind,'profile_id',s.profile_id,
      'display_name',p.display_name,'can_view_photo',case when s.profile_id is null then false else private.can_view_profile_photo(s.profile_id) end,
      'state',cp.state,'left_at',cp.left_at,'frozen_through_day',cp.frozen_through_day,'frozen_revisions',private.group_revision_strings(cp.frozen_revisions),
      'attestation_basis',(select a.basis from public.participant_finalization_attestations a where a.competition_id = c.id and a.participant_profile_id = s.profile_id order by a.attestation_version desc limit 1),
      'bot_mode',s.bot_mode,'bot_seed',s.bot_seed,'bot_baseline',s.bot_baseline,'bot_generator_version',s.bot_generator_version,
      'bot_daily_totals',s.bot_daily_totals,
      'days',coalesce((select pg_catalog.jsonb_agg(pg_catalog.to_jsonb(h) || pg_catalog.jsonb_build_object(
        'client_revision',h.client_revision::text,'server_seq',h.server_seq::text,'wire_content_sha256',pg_catalog.encode(h.wire_content_sha256,'hex')) order by h.day_ordinal)
        from (select distinct on (r.day_ordinal) r.* from public.daily_score_revisions r
          where r.competition_id = c.id and r.participant_profile_id = s.profile_id
            and (cp.left_at is null or r.client_revision = cp.frozen_revisions[r.day_ordinal])
          order by r.day_ordinal,r.client_revision desc) h),'[]'::jsonb)
      ) order by s.seat_index) from public.competition_seats s
      left join public.profiles p on p.id = s.profile_id left join public.competition_participants cp
        on cp.competition_id = s.competition_id and cp.profile_id = s.profile_id where s.competition_id = c.id),
    'owner',pg_catalog.jsonb_build_object('profile_id',viewer,
      'revision_high_water',coalesce((select max(r.client_revision) from public.daily_score_revisions r
        where r.competition_id = c.id and r.participant_profile_id = viewer),0)::text,
      'attestation',(select pg_catalog.to_jsonb(a) || pg_catalog.jsonb_build_object('attestation_version',a.attestation_version::text,
        'server_seq',a.server_seq::text,'accepted_revisions',private.group_revision_strings(a.accepted_revisions),'window_commitment_sha256',pg_catalog.encode(a.window_commitment_sha256,'hex'))
        from public.participant_finalization_attestations a where a.competition_id = c.id and a.participant_profile_id = viewer
        order by a.attestation_version desc limit 1)),
    'reactions',coalesce((select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('competition_id',r.competition_id,
        'author_profile_id',r.author_profile_id,'target_profile_id',r.target_profile_id,'day_ordinal',r.day_ordinal,
        'reaction',r.reaction,'created_at',r.created_at,'updated_at',r.updated_at) order by r.updated_at,r.author_profile_id)
      from private.competition_reactions r where r.competition_id = c.id),'[]'::jsonb),
    'result',(select pg_catalog.jsonb_build_object('competition_id',r.competition_id,'format',r.format,
      'finalization_basis',r.finalization_basis,'completed_at',r.completed_at,'standings',r.standings,'server_seq',r.server_seq::text,
      'immutable_hash',pg_catalog.encode(r.immutable_hash,'hex'),'version',1,
      'seats',(select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
        'seat_index',(s->>'seat_index')::integer,'total_centi_points',s->>'total_centi_points',
        'days',case when s->>'kind' = 'bot' then
          (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'ordinal',d.ordinal,'status','available','centi_points',((d.points::text)::bigint*100)::text,'reason',null)
            order by d.ordinal)
            from pg_catalog.jsonb_array_elements(s->'bot_daily_totals') with ordinality d(points,ordinal))
        else (select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'ordinal',(d->>'ordinal')::integer,
          'status',case when d->>'status' = 'points' then 'available' else d->>'status' end,
          'centi_points',case when d->>'status' = 'points' then d->>'centi_points' else null end,
          'reason',case when d->>'status' = 'afterLeave' then 'afterLeave' else d->>'reason' end)
          order by (d->>'ordinal')::integer) from pg_catalog.jsonb_array_elements(s->'window'->'days') d) end)
        order by (s->>'seat_index')::integer) from pg_catalog.jsonb_array_elements(r.frozen_payload->'seats') s)) from public.competition_group_results r where r.competition_id = c.id))
  from public.competitions c where c.id = cid and c.format <> 'duel';
$$;

-- A rename no longer wakes the sender of a challenge this person never took up.
create or replace function private.record_profile_presentation_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership record;
begin
  if old.state = 'active'
     and new.state = 'active'
     and (old.display_name is distinct from new.display_name
       or old.photo_version is distinct from new.photo_version) then
    for membership in
      select participant_row.competition_id
      from public.competition_participants participant_row
      join public.competitions competition_row on competition_row.id = participant_row.competition_id
      where participant_row.profile_id = new.id
        -- A challenge this person never took up tells its sender nothing more.
        and not (participant_row.state = 'pending'
          and competition_row.lifecycle in ('declined', 'expired', 'cancelled'))
    loop
      perform private.allocate_competition_server_seq(
        membership.competition_id,
        'profile_presentation_changed',
        new.id,
        new.updated_at
      );
    end loop;
  end if;

  return new;
end;
$$;

-- Account deletion redacts names through this index instead of a log scan.
create index competition_change_log_profile_presentation_idx
  on public.competition_change_log(entity_id)
  where change_kind in ('profile_presentation_changed', 'profile_anonymized');

-- The invite rate cap counts a sender's recent challenges.
create index competitions_creator_created_idx on public.competitions(creator_profile_id, created_at);

-- list_challenges and the finalizer no longer scan every competition.
create index competitions_pending_recipient_idx
  on public.competitions(invited_profile_id, invitation_expires_at) where lifecycle = 'pending';
create index competitions_open_deadline_idx
  on public.competitions(best_available_deadline)
  where lifecycle in ('scheduled', 'active', 'ends_today', 'tallying');

revoke all on function private.is_valid_frozen_window_v2(jsonb,uuid,uuid,uuid,integer,integer)
  from public, anon, authenticated, service_role;
alter table private.competition_notification_mutes enable row level security;
alter table private.competition_notification_mutes force row level security;
