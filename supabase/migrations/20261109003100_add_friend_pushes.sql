-- Friends share durable retries and resolution, but require an opted-in worker.
alter table public.device_installations
  add column supports_friends boolean not null default false;
alter table public.device_installations
  drop constraint device_installations_muted_push_kinds_check,
  add constraint device_installations_muted_push_kinds_check check (
    muted_push_kinds <@ array['nudge', 'reaction', 'friend_request', 'friend_accepted']::text[]
  );
alter table private.competition_notification_work
  add column friend_event_id uuid,
  add constraint competition_notification_work_source_profile_fk
    foreign key (source_profile_id) references public.profiles(id),
  add constraint competition_notification_work_recipient_profile_fk
    foreign key (recipient_profile_id) references public.profiles(id),
  alter column competition_id drop not null,
  alter column server_seq drop not null,
  drop constraint competition_notification_work_kind_check,
  add constraint competition_notification_work_kind_check check (
    kind in ('score_update', 'result', 'challenge_received', 'challenge_declined',
      'match_cancelled', 'nudge', 'reaction', 'friend_request', 'friend_accepted')
  ),
  add constraint competition_notification_work_route_shape check (
    (kind in ('friend_request', 'friend_accepted') and competition_id is null and server_seq is null and friend_event_id is not null)
    or (kind not in ('friend_request', 'friend_accepted') and competition_id is not null and server_seq is not null and friend_event_id is null)
  );
-- Match identities are unchanged (their friend_event_id is always null).
alter table private.competition_notification_work
  drop constraint competition_notification_work_identity_unique,
  add constraint competition_notification_work_identity_unique unique nulls not distinct (
    competition_id, server_seq, kind, recipient_profile_id, installation_id, nudge_day, friend_event_id
  );
create index competition_notification_work_friend_guard_idx
  on private.competition_notification_work(kind, source_profile_id, recipient_profile_id, created_at)
  where kind in ('friend_request', 'friend_accepted');

create function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text,
  supports_challenges boolean,
  supports_reactions boolean,
  supports_friends boolean,
  muted_push_kinds text[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_installation_id alias for installation_id;
  input_apns_token alias for apns_token;
  input_environment alias for environment;
  input_supports_challenges alias for supports_challenges;
  input_supports_reactions alias for supports_reactions;
  input_muted_push_kinds alias for muted_push_kinds;
  input_supports_friends alias for supports_friends;
  caller_profile_id uuid;
  token_owner_profile_id uuid;
  installation_record record;
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

  if input_installation_id is null
     or input_apns_token is null
     or input_apns_token !~ '^[0-9a-f]{64,200}$'
     or input_environment not in ('sandbox', 'production')
     or input_supports_challenges is null
     or input_supports_reactions is null
     or input_supports_friends is null
     or input_muted_push_kinds is null
     or not coalesce(
       input_muted_push_kinds <@ array['nudge', 'reaction', 'friend_request', 'friend_accepted']::text[], false
     ) then
    raise exception 'invalid_installation_request' using errcode = '22023';
  end if;

  select installation_row.profile_id
  into token_owner_profile_id
  from public.device_installations installation_row
  where installation_row.apns_token = input_apns_token
  for update;

  if found and token_owner_profile_id <> caller_profile_id then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  begin
    insert into public.device_installations as installation_target (
      profile_id, installation_id, apns_token, environment, state,
      supports_challenges, supports_reactions, supports_friends, muted_push_kinds
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active', input_supports_challenges,
      input_supports_reactions, input_supports_friends, input_muted_push_kinds
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        supports_challenges = excluded.supports_challenges,
        supports_reactions = excluded.supports_reactions,
        supports_friends = excluded.supports_friends,
        muted_push_kinds = excluded.muted_push_kinds,
        updated_at = pg_catalog.statement_timestamp()
    returning installation_target.installation_id,
              installation_target.environment,
              installation_target.state
    into installation_record;
  exception
    when unique_violation then
      raise exception 'installation_unavailable' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'installation_id', installation_record.installation_id,
    'environment', installation_record.environment,
    'state', installation_record.state
  );
end;
$$;

-- Every old overload follows this wrapper, preserving the supplied mute array.
create or replace function public.register_current_device_installation(
  installation_id uuid, apns_token text, environment text,
  supports_challenges boolean, supports_reactions boolean, muted_push_kinds text[]
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  return public.register_current_device_installation(installation_id, apns_token,
    environment, supports_challenges, supports_reactions, false, muted_push_kinds);
end;
$$;
revoke all on function public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[])
  from public, anon, authenticated, service_role;
grant execute on function public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[])
  to authenticated;

create function public.lease_competition_notification_work(
  batch_size integer,
  lease_seconds integer,
  supports_friends boolean
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_batch_size alias for batch_size;
  input_supports_friends alias for supports_friends;
  input_lease_seconds alias for lease_seconds;
  as_of timestamptz := pg_catalog.statement_timestamp();
  result jsonb;
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_batch_size is null or input_batch_size not between 1 and 100 then
    raise exception 'invalid_batch_size' using errcode = '22023';
  end if;
  if input_lease_seconds is null or input_lease_seconds not between 15 and 300 then
    raise exception 'invalid_lease_seconds' using errcode = '22023';
  end if;

  if input_supports_friends is null then
    raise exception 'invalid_friends_capability' using errcode = '22023';
  end if;

  with locked_candidates as materialized (
    select work_row.id,
           work_row.available_at,
           work_row.created_at,
           installation_row.apns_token,
           installation_row.environment,
           case
             when work_row.kind in ('friend_request', 'friend_accepted')
               and (source_profile_row.state is distinct from 'active'
                 or profile_row.state is distinct from 'active'
                 or private.people_blocked(work_row.source_profile_id, work_row.recipient_profile_id)
                 or (work_row.kind = 'friend_request' and not exists (
                   select 1 from private.friend_requests r
                   where r.sender_profile_id = work_row.source_profile_id
                     and r.recipient_profile_id = work_row.recipient_profile_id))
                 or (work_row.kind = 'friend_accepted' and not private.are_friends(
                   work_row.source_profile_id, work_row.recipient_profile_id)))
               then 'superseded'
             when work_row.kind in ('friend_request', 'friend_accepted')
               and not installation_row.supports_friends then 'discarded'
             when work_row.attempt_count >= 10
               or installation_row.installation_id is null
               or installation_row.state <> 'active'
               or profile_row.id is null
               or profile_row.state <> 'active'
               or (work_row.kind in ('challenge_received', 'challenge_declined',
                     'match_cancelled')
                   and (source_profile_row.state is distinct from 'active'
                     or not installation_row.supports_challenges))
               or (work_row.kind = 'challenge_received'
                   and (competition_row.lifecycle is distinct from 'pending'
                     or competition_row.invitation_expires_at <= as_of))
               or (work_row.kind = 'nudge'
                   and (source_profile_row.state is distinct from 'active'
                     or coalesce(competition_row.lifecycle, '') not in
                       ('scheduled', 'active', 'ends_today', 'tallying')))
               then 'discarded'
             when (work_row.competition_id is not null and exists (
               select 1
               from private.competition_notification_mutes mute_row
               where mute_row.profile_id = work_row.recipient_profile_id
                 and mute_row.opponent_profile_id
                   = work_row.source_profile_id
             ))
               or work_row.kind = any(installation_row.muted_push_kinds)
               then 'suppressed'
             else 'lease'
           end as disposition
    from private.competition_notification_work work_row
    left join public.device_installations installation_row
      on installation_row.profile_id = work_row.recipient_profile_id
     and installation_row.installation_id = work_row.installation_id
    left join public.profiles profile_row
      on profile_row.id = work_row.recipient_profile_id
    left join public.profiles source_profile_row
      on source_profile_row.id = work_row.source_profile_id
    left join public.competitions competition_row
      on competition_row.id = work_row.competition_id
    where (input_supports_friends or work_row.kind not in ('friend_request', 'friend_accepted'))
      and (
        work_row.state = 'pending'
        or (
          work_row.state = 'leased'
          and work_row.lease_expires_at <= as_of
        )
      )
    order by work_row.available_at, work_row.created_at, work_row.id
    for update of work_row skip locked
    limit input_batch_size * 4
  ), housekept as (
    update private.competition_notification_work work_row
    set state = candidate.disposition,
        lease_token = null,
        lease_expires_at = null,
        leased_apns_token_sha256 = null,
        updated_at = as_of,
        completed_at = as_of
    from locked_candidates candidate
    where work_row.id = candidate.id
      and candidate.disposition in ('discarded', 'suppressed', 'superseded')
    returning work_row.id
  ), candidates as materialized (
    select candidate.id,
           candidate.apns_token,
           candidate.environment,
           candidate.created_at
    from locked_candidates candidate
    where candidate.disposition = 'lease'
      and candidate.available_at <= as_of
    order by candidate.available_at, candidate.created_at, candidate.id
    limit input_batch_size
  ), leased as (
    update private.competition_notification_work work_row
    set state = 'leased',
        attempt_count = work_row.attempt_count + 1,
        lease_token = extensions.gen_random_uuid(),
        lease_expires_at = as_of
          + pg_catalog.make_interval(secs => input_lease_seconds),
        leased_apns_token_sha256 = extensions.digest(
          candidate.apns_token, 'sha256'
        ),
        updated_at = as_of,
        completed_at = null
    from candidates candidate
    where work_row.id = candidate.id
    returning work_row.id,
              work_row.lease_token,
              work_row.semantic_id,
              work_row.competition_id,
              work_row.kind,
              candidate.created_at,
              candidate.apns_token,
              candidate.environment
  )
  select pg_catalog.jsonb_build_object(
    'items', coalesce(
      pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'workId', leased.id,
          'leaseToken', leased.lease_token,
          'semanticId', leased.semantic_id,
          'competitionId', leased.competition_id,
          'kind', leased.kind,
          'apnsToken', leased.apns_token,
          'environment', leased.environment
        ) || case when leased.kind in ('friend_request', 'friend_accepted')
          then '{"supportsFriends":true}'::jsonb else '{}'::jsonb end
        order by leased.created_at, leased.id
      ),
      '[]'::jsonb
    )
  )
  into result
  from leased;

  return result;
end;
$$;
-- An old sender can never lease a Friends item, even after the migration.
create or replace function public.lease_competition_notification_work(
  batch_size integer default 25, lease_seconds integer default 180
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
begin
  return public.lease_competition_notification_work(batch_size, lease_seconds, false);
end;
$$;
revoke all on function public.lease_competition_notification_work(integer,integer,boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.lease_competition_notification_work(integer,integer,boolean) to service_role;

-- Pair locks in the Friends RPCs serialize this rolling 24-hour guard.
create function private.enqueue_friend_notification(
  push_kind text, source_id uuid, recipient_id uuid
)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  decision_time timestamptz := pg_catalog.statement_timestamp();
  event_id uuid := extensions.gen_random_uuid();
begin
  if push_kind not in ('friend_request', 'friend_accepted') then
    raise exception 'invalid_friend_push_kind' using errcode = '22023';
  end if;
  if exists (select 1 from private.competition_notification_work w
    where w.kind = push_kind and w.source_profile_id = source_id
      and w.recipient_profile_id = recipient_id
      and w.created_at > decision_time - interval '24 hours') then
    return;
  end if;
  insert into private.competition_notification_work (
    semantic_id, friend_event_id, kind, recipient_profile_id, source_profile_id, installation_id,
    state, available_at, created_at, updated_at, completed_at
  )
  select 'healthcomp.server-notification:v1:' || event_id::text || ':' || push_kind || ':' || i.installation_id::text,
    event_id, push_kind, recipient_id, source_id, i.installation_id,
    case when push_kind = any(i.muted_push_kinds) then 'suppressed' else 'pending' end,
    decision_time, decision_time, decision_time,
    case when push_kind = any(i.muted_push_kinds) then decision_time else null end
  from public.device_installations i
  join public.profiles recipient on recipient.id = i.profile_id and recipient.state = 'active'
  join public.profiles source on source.id = source_id and source.state = 'active'
  where i.profile_id = recipient_id and i.state = 'active' and i.supports_friends
    and not private.people_blocked(source_id, recipient_id);
  if found then
    perform private.request_competition_notification_worker();
  end if;
end;
$$;
revoke all on function private.enqueue_friend_notification(text,uuid,uuid)
  from public, anon, authenticated, service_role;

create function private.enqueue_friend_request_notification()
returns trigger language plpgsql security definer set search_path = ''
as $$
begin
  perform private.enqueue_friend_notification('friend_request', new.sender_profile_id, new.recipient_profile_id);
  return new;
end;
$$;
revoke all on function private.enqueue_friend_request_notification()
  from public, anon, authenticated, service_role;
create trigger enqueue_friend_request_notification after insert on private.friend_requests
for each row execute function private.enqueue_friend_request_notification();

-- Clear live leases too: stale completions must not revive invalid work.
create function private.supersede_friend_notification_work()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  a uuid;
  b uuid;
  push_kind text;
begin
  if tg_table_name = 'friend_requests' then
    a := old.sender_profile_id;
    b := old.recipient_profile_id;
    push_kind := 'friend_request';
  else
    a := old.profile_low;
    b := old.profile_high;
    push_kind := 'friend_accepted';
  end if;
  update private.competition_notification_work w
  set state = 'superseded', lease_token = null, lease_expires_at = null,
    leased_apns_token_sha256 = null, updated_at = pg_catalog.statement_timestamp(),
    completed_at = pg_catalog.statement_timestamp()
  where w.kind = push_kind and w.state in ('pending', 'leased')
    and ((w.source_profile_id = a and w.recipient_profile_id = b)
      or (w.source_profile_id = b and w.recipient_profile_id = a));
  return old;
end;
$$;
revoke all on function private.supersede_friend_notification_work()
  from public, anon, authenticated, service_role;
create trigger supersede_friend_request_notification after delete on private.friend_requests
for each row execute function private.supersede_friend_notification_work();
create trigger supersede_friend_accepted_notification after delete on private.friendships
for each row execute function private.supersede_friend_notification_work();

create or replace function public.send_friend_request(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  target alias for profile_id;
  caller uuid := private.require_active_caller_profile_id();
begin
  if target is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, target);
  if not private.person_reachable(caller, target) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  if private.are_friends(caller, target) then
    return pg_catalog.jsonb_build_object('relationship', 'friend');
  end if;
  if exists (select 1 from private.friend_requests r
    where r.sender_profile_id = caller and r.recipient_profile_id = target) then
    return pg_catalog.jsonb_build_object('relationship', 'requested');
  end if;
  delete from private.friend_requests r
    where r.sender_profile_id = target and r.recipient_profile_id = caller;
  if found then
    insert into private.friendships (profile_low, profile_high)
      values (least(caller, target), greatest(caller, target));
    perform private.enqueue_friend_notification('friend_accepted', caller, target);
    perform private.wake_friend_profile(target);
    return pg_catalog.jsonb_build_object('relationship', 'friend');
  end if;
  if (select count(*) from private.friend_requests r where r.sender_profile_id = caller) >= 100 then
    raise exception 'friend_request_limit' using errcode = 'P0001';
  end if;
  insert into private.friend_requests (sender_profile_id, recipient_profile_id) values (caller, target);
  perform private.wake_friend_profile(target);
  return pg_catalog.jsonb_build_object('relationship', 'requested');
end;
$$;


create or replace function public.respond_to_friend_request(profile_id uuid, accept boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  target alias for profile_id;
  caller uuid := private.require_active_caller_profile_id();
begin
  if target is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  if accept is null then
    raise exception 'invalid_friend_request_response' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, target);
  if accept then
    if target = caller or not exists (select 1 from public.profiles p
      where p.id = target and p.state = 'active') or private.people_blocked(caller, target) then
      raise exception 'request_unavailable' using errcode = 'P0001';
    end if;
    if private.are_friends(caller, target) then
      return pg_catalog.jsonb_build_object('relationship', 'friend');
    end if;
    delete from private.friend_requests r
      where r.sender_profile_id = target and r.recipient_profile_id = caller;
    if not found then
      raise exception 'request_unavailable' using errcode = 'P0001';
    end if;
    delete from private.friend_requests r
      where r.sender_profile_id = caller and r.recipient_profile_id = target;
    insert into private.friendships (profile_low, profile_high)
      values (least(caller, target), greatest(caller, target));
    perform private.enqueue_friend_notification('friend_accepted', caller, target);
    perform private.wake_friend_profile(target);
    return pg_catalog.jsonb_build_object('relationship', 'friend');
  end if;
  delete from private.friend_requests r
    where r.sender_profile_id = target and r.recipient_profile_id = caller;
  if found then perform private.wake_friend_profile(target); end if;
  return pg_catalog.jsonb_build_object('relationship',
    case when private.are_friends(caller, target) then 'friend' else 'none' end);
end;
$$;

