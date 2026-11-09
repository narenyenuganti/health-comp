-- Friends are private RPC state; existing profile grants and wire payloads stay closed.
alter table public.profiles
  add column username text,
  add column show_in_search boolean not null default true,
  add column challenge_policy text not null default 'friends_and_link',
  add constraint profiles_username_format check (username is null or username ~ '^[a-z0-9_]{3,20}$'),
  add constraint profiles_username_requires_active check (username is null or state = 'active'),
  add constraint profiles_challenge_policy check (challenge_policy in ('friends_and_link', 'friends_only'));
create unique index profiles_username_idx on public.profiles(username) where username is not null;

create table private.friendships (
  profile_low uuid not null references public.profiles(id) on delete cascade,
  profile_high uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (profile_low, profile_high),
  constraint friendships_distinct_profiles check (profile_low < profile_high)
);
create index friendships_profile_high_idx on private.friendships(profile_high);
create table private.friend_requests (
  sender_profile_id uuid not null references public.profiles(id) on delete cascade,
  recipient_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (sender_profile_id, recipient_profile_id),
  constraint friend_requests_distinct_profiles check (sender_profile_id <> recipient_profile_id)
);
create index friend_requests_recipient_profile_id_idx on private.friend_requests(recipient_profile_id);
create table private.profile_reports (
  reporter_profile_id uuid not null references public.profiles(id) on delete cascade,
  reported_profile_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (reporter_profile_id, reported_profile_id),
  constraint profile_reports_distinct_profiles check (reporter_profile_id <> reported_profile_id)
);
create index profile_reports_reported_profile_id_idx on private.profile_reports(reported_profile_id);
create table private.people_search_limits (
  profile_id uuid primary key references public.profiles(id) on delete cascade,
  window_started_at timestamptz not null,
  used integer not null check (used between 1 and 30)
);
alter table private.friendships enable row level security;
alter table private.friendships force row level security;
revoke all on table private.friendships from public, anon, authenticated, service_role;
alter table private.friend_requests enable row level security;
alter table private.friend_requests force row level security;
revoke all on table private.friend_requests from public, anon, authenticated, service_role;
alter table private.profile_reports enable row level security;
alter table private.profile_reports force row level security;
revoke all on table private.profile_reports from public, anon, authenticated, service_role;
alter table private.people_search_limits enable row level security;
alter table private.people_search_limits force row level security;
revoke all on table private.people_search_limits from public, anon, authenticated, service_role;

create function private.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from private.friendships f
    where f.profile_low = least(a, b) and f.profile_high = greatest(a, b));
$$;

create function private.is_reserved_username(username text)
returns boolean language sql immutable security definer set search_path = ''
as $$
  select username = any(array[
    'abuse','account','activity','activity_rings','admin','administrator','admins',
    'anonymous','api','app_store','appearance','apple','apple_activity','apple_fitness',
    'apple_health','apple_watch','appleactivity','applefitness','applehealth','applewatch','appstore',
    'archive','auth','belt','beta','blocked','challenge','competition',
    'contact','deleted','everyone','exercise','fitness','former_competitor','formercompetitor',
    'friend','friends','guest','hc_admin','hc_help','hc_official','hc_security',
    'hc_staff','hc_support','hc_team','health','health_comp','health_kit','healthcomp',
    'healthcomp_app','healthcompadmin','healthcompapp','healthcomphelp','healthcompofficial','healthcompstaff','healthcompsupport',
    'healthcompteam','healthkit','help','helpdesk','history','home','hostmaster',
    'icloud','info','invite','ipad','iphone','itunes','iwatch',
    'localhost','login','logout','mail','match','moderator','moderators',
    'muted','myhealthcomp','nil','no_reply','none','noreply','notifications',
    'null','official','operator','owner','postmaster','practice','privacy',
    'reactions','recap','recaps','record','records','rematch','root',
    'score','scoring','security','settings','signin','signout','signup',
    'staff','staging','stand','superuser','support','sysadmin','system',
    'team','test','thehealthcomp','undefined','unknown','user','username',
    'watch','webmaster','week','widget','www','you']);
$$;

create function private.people_blocked(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from private.account_blocks x
    where (x.blocker_profile_id = a and x.blocked_profile_id = b)
       or (x.blocker_profile_id = b and x.blocked_profile_id = a));
$$;

create function private.person_reachable(caller uuid, target uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p
    where p.id = target and p.id <> caller and p.state = 'active'
      and not private.people_blocked(caller, target)
      and ((p.username is not null and p.show_in_search)
        or private.are_friends(caller, target)
        or exists (select 1 from private.friend_requests r
          where (r.sender_profile_id = caller and r.recipient_profile_id = target)
             or (r.sender_profile_id = target and r.recipient_profile_id = caller))
        or exists (select 1 from public.competitions c
          join public.competition_participants a on a.competition_id = c.id
            and a.profile_id = caller and a.state = 'accepted'
          join public.competition_participants b on b.competition_id = c.id
            and b.profile_id = target and b.state = 'accepted'
          where c.lifecycle in ('scheduled','active','ends_today','tallying','completed','archived','cancelled'))
        or exists (select 1 from public.competitions c
          where c.creator_profile_id = target and c.invited_profile_id = caller)));
$$;

create function private.friend_relationship(caller uuid, target uuid)
returns text language sql stable security definer set search_path = ''
as $$
  select case when private.are_friends(caller, target) then 'friend'
    when exists (select 1 from private.friend_requests r
      where r.sender_profile_id = caller and r.recipient_profile_id = target) then 'requested'
    when exists (select 1 from private.friend_requests r
      where r.sender_profile_id = target and r.recipient_profile_id = caller) then 'incoming'
    else 'none' end;
$$;

create function private.friend_person(caller uuid, target uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  select pg_catalog.jsonb_build_object('id', p.id, 'display_name', p.display_name,
    'username', case when (p.username is not null and p.show_in_search)
      or private.are_friends(caller, target)
      or exists (select 1 from private.friend_requests r
        where r.sender_profile_id = target and r.recipient_profile_id = caller)
      then p.username else null end,
    'relationship', private.friend_relationship(caller, target))
  from public.profiles p where p.id = target and p.state = 'active';
$$;

create function private.lock_friend_pair(caller uuid, target uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  perform 1 from public.profiles p where p.id in (caller, target)
    order by p.id for no key update;
  if not exists (select 1 from public.profiles p where p.id = caller and p.state = 'active') then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
end;
$$;

create function private.wake_friend_profile(target uuid)
returns void language plpgsql security definer set search_path = ''
as $$
begin
  if exists (select 1 from public.profiles p where p.id = target and p.state = 'active') then
    perform realtime.send(pg_catalog.jsonb_build_object('server_cursor_hint', '0'),
      'competition_changed', 'profile:' || target::text, true);
  end if;
end;
$$;

create function private.consume_people_search(caller uuid)
returns void language plpgsql security definer set search_path = ''
as $$
declare
  decision_time timestamptz := pg_catalog.clock_timestamp();
begin
  -- The caller row also serializes search with deactivation's purge.
  perform 1 from public.profiles p where p.id = caller for no key update;
  if not exists (select 1 from public.profiles p where p.id = caller and p.state = 'active') then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;
  insert into private.people_search_limits as limits (profile_id, window_started_at, used)
  values (caller, decision_time, 1)
  on conflict (profile_id) do update set
    window_started_at = case when limits.window_started_at <= decision_time - interval '1 minute'
      then decision_time else limits.window_started_at end,
    used = case when limits.window_started_at <= decision_time - interval '1 minute'
      then 1 else limits.used + 1 end
  where limits.window_started_at <= decision_time - interval '1 minute' or limits.used < 30;
  if not found then
    raise exception 'search_rate_limited' using errcode = 'P0001';
  end if;
end;
$$;

create function public.get_friend_settings()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := private.require_active_caller_profile_id();
begin
  return (select pg_catalog.jsonb_build_object('username', p.username,
    'show_in_search', p.show_in_search, 'challenge_policy', p.challenge_policy)
    from public.profiles p where p.id = caller);
end;
$$;

create function public.set_username(username text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_username text := pg_catalog.lower(pg_catalog.btrim(username));
  caller uuid := private.require_active_caller_profile_id();
begin
  if input_username is null or input_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  if private.is_reserved_username(input_username) then
    raise exception 'username_unavailable' using errcode = 'P0001';
  end if;
  perform private.lock_friend_pair(caller, caller);
  begin
    update public.profiles p set username = input_username
    where p.id = caller and p.username is distinct from input_username;
  exception when unique_violation then
    raise exception 'username_unavailable' using errcode = 'P0001';
  end;
  return public.get_friend_settings();
end;
$$;

create function public.username_available(username text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_username text := pg_catalog.lower(pg_catalog.btrim(username));
  caller uuid := private.require_active_caller_profile_id();
begin
  if input_username is null or input_username !~ '^[a-z0-9_]{3,20}$' then
    raise exception 'invalid_username' using errcode = '22023';
  end if;
  perform private.consume_people_search(caller);
  return pg_catalog.jsonb_build_object('available',
    not private.is_reserved_username(input_username)
    and not exists (select 1 from public.profiles p
      where p.username = input_username and p.id <> caller));
end;
$$;

create function public.update_friend_settings(show_in_search boolean, challenge_policy text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_show_in_search alias for show_in_search;
  input_challenge_policy alias for challenge_policy;
  caller uuid := private.require_active_caller_profile_id();
begin
  if input_show_in_search is null or input_challenge_policy is null
     or input_challenge_policy not in ('friends_and_link', 'friends_only') then
    raise exception 'invalid_friend_settings' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, caller);
  update public.profiles p set show_in_search = input_show_in_search,
    challenge_policy = input_challenge_policy
  where p.id = caller and (p.show_in_search is distinct from input_show_in_search
    or p.challenge_policy is distinct from input_challenge_policy);
  return public.get_friend_settings();
end;
$$;

create function public.search_people(query text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  normalized text := pg_catalog.btrim(query);
  usernames_only boolean := pg_catalog.left(normalized, 1) = '@';
  pattern text;
  caller uuid := private.require_active_caller_profile_id();
begin
  if usernames_only then normalized := pg_catalog.substr(normalized, 2); end if;
  normalized := pg_catalog.lower(normalized);
  if normalized is null or pg_catalog.length(normalized) not between 3 and 40
     or normalized ~ '[[:cntrl:]]' then
    raise exception 'invalid_query' using errcode = '22023';
  end if;
  perform private.consume_people_search(caller);
  pattern := pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(normalized,
    E'\\', E'\\\\'), '%', E'\\%'), '_', E'\\_') || '%';
  return pg_catalog.jsonb_build_object('people', coalesce((
    select pg_catalog.jsonb_agg(private.friend_person(caller, listed.id)
      order by listed.rank, listed.username, listed.id)
    from (
      select p.id, p.username, case when p.username = normalized then 0
        when p.username like pattern then 1 else 2 end as rank
      from public.profiles p
      where p.id <> caller and p.state = 'active'
        and not private.people_blocked(caller, p.id)
        and ((p.username is not null and p.show_in_search) or private.are_friends(caller, p.id))
        and (p.username like pattern or (not usernames_only
          and (pg_catalog.lower(p.display_name) like pattern
            or pg_catalog.lower(p.display_name) like '% ' || pattern)))
      order by rank, p.username, p.id limit 20
    ) listed
  ), '[]'::jsonb));
end;
$$;

create function public.list_friends()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := private.require_active_caller_profile_id();
begin
  return pg_catalog.jsonb_build_object(
    'friends', coalesce((select pg_catalog.jsonb_agg(private.friend_person(caller, p.id)
      order by p.display_name, p.id)
      from private.friendships f join public.profiles p
        on p.id = case when f.profile_low = caller then f.profile_high else f.profile_low end
      where caller in (f.profile_low, f.profile_high) and p.state = 'active'), '[]'::jsonb),
    'incoming', coalesce((select pg_catalog.jsonb_agg(private.friend_person(caller, p.id)
      order by r.created_at desc, p.id)
      from private.friend_requests r join public.profiles p on p.id = r.sender_profile_id
      where r.recipient_profile_id = caller and p.state = 'active'), '[]'::jsonb),
    'outgoing', coalesce((select pg_catalog.jsonb_agg(private.friend_person(caller, p.id)
      order by r.created_at desc, p.id)
      from private.friend_requests r join public.profiles p on p.id = r.recipient_profile_id
      where r.sender_profile_id = caller and p.state = 'active'), '[]'::jsonb));
end;
$$;

create function public.send_friend_request(profile_id uuid)
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

create function public.respond_to_friend_request(profile_id uuid, accept boolean)
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

create function public.remove_friend(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  target alias for profile_id;
  caller uuid := private.require_active_caller_profile_id();
  changed boolean;
begin
  if target is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, target);
  delete from private.friendships f
    where f.profile_low = least(caller, target) and f.profile_high = greatest(caller, target);
  changed := found;
  delete from private.friend_requests r
    where (r.sender_profile_id = caller and r.recipient_profile_id = target)
       or (r.sender_profile_id = target and r.recipient_profile_id = caller);
  if changed or found then perform private.wake_friend_profile(target); end if;
  return pg_catalog.jsonb_build_object('relationship', 'none');
end;
$$;

create function public.block_profile(profile_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  target alias for profile_id;
  caller uuid := private.require_active_caller_profile_id();
  decision_time timestamptz;
  declined record;
begin
  if target is null then
    raise exception 'invalid_profile_id' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, target);
  if target = caller or not exists (select 1 from public.profiles p
    where p.id = target and p.state = 'active')
    or (not exists (select 1 from private.account_blocks b
      where b.blocker_profile_id = caller and b.blocked_profile_id = target)
      and not private.person_reachable(caller, target)) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  decision_time := pg_catalog.clock_timestamp();
  insert into private.account_blocks (blocker_profile_id, blocked_profile_id)
    values (caller, target) on conflict do nothing;
  for declined in
    update public.competitions c set lifecycle = 'declined',
      closed_by_profile_id = caller, closed_at = decision_time, updated_at = decision_time
    where c.creator_profile_id = target and c.invited_profile_id = caller
      and c.lifecycle = 'pending' and c.invitation_expires_at > decision_time
    returning c.id
  loop
    perform private.enqueue_challenge_notification(declined.id, 'challenge_declined', target, caller);
  end loop;
  update public.competitions c set lifecycle = 'cancelled',
    closed_by_profile_id = caller, closed_at = decision_time, updated_at = decision_time
  where c.creator_profile_id = caller and c.invited_profile_id = target and c.lifecycle = 'pending';
  return (select pg_catalog.jsonb_build_object('id', p.id, 'display_name', p.display_name)
    from public.profiles p where p.id = target);
end;
$$;

create function public.report_profile(profile_id uuid)
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
  insert into private.profile_reports (reporter_profile_id, reported_profile_id)
    values (caller, target) on conflict do nothing;
  return pg_catalog.jsonb_build_object('reported', true);
end;
$$;

-- A block from either entry point invalidates the same private relationship state.
create function private.purge_friends_on_block()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  changed boolean;
begin
  delete from private.friendships f where f.profile_low = least(new.blocker_profile_id, new.blocked_profile_id)
    and f.profile_high = greatest(new.blocker_profile_id, new.blocked_profile_id);
  changed := found;
  delete from private.friend_requests r
    where (r.sender_profile_id = new.blocker_profile_id and r.recipient_profile_id = new.blocked_profile_id)
       or (r.sender_profile_id = new.blocked_profile_id and r.recipient_profile_id = new.blocker_profile_id);
  if changed or found then perform private.wake_friend_profile(new.blocked_profile_id); end if;
  return new;
end;
$$;
create trigger purge_friends_on_block after insert on private.account_blocks
for each row execute function private.purge_friends_on_block();

create function private.purge_friends_on_profile_deactivation()
returns trigger language plpgsql security definer set search_path = ''
as $$
declare
  counterpart uuid;
begin
  if old.state = 'active' and new.state <> 'active' then
    new.username := null;
    for counterpart in
      with friends as (
        delete from private.friendships f where new.id in (f.profile_low, f.profile_high)
        returning case when f.profile_low = new.id then f.profile_high else f.profile_low end as id
      ), requests as (
        delete from private.friend_requests r where new.id in (r.sender_profile_id, r.recipient_profile_id)
        returning case when r.sender_profile_id = new.id then r.recipient_profile_id else r.sender_profile_id end as id
      ) select id from friends union select id from requests
    loop
      perform private.wake_friend_profile(counterpart);
    end loop;
    delete from private.profile_reports r where new.id in (r.reporter_profile_id, r.reported_profile_id);
    delete from private.people_search_limits l where l.profile_id = new.id;
  end if;
  return new;
end;
$$;
create trigger purge_friends_on_profile_deactivation before update of state on public.profiles
for each row execute function private.purge_friends_on_profile_deactivation();

create or replace function private.enforce_anonymized_profile_terminal()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if old.state = 'anonymized'
     and (
       new.state is distinct from old.state
       or new.auth_user_id is distinct from old.auth_user_id
       or new.display_name is distinct from old.display_name
       or new.anonymized_at is distinct from old.anonymized_at
       or new.username is not null
     ) then
    raise exception 'anonymized profile state is terminal' using errcode = '23514';
  end if;

  return new;
end;
$$;

create or replace function private.can_view_profile_photo(target_profile_id uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select viewer.id is not null
    and exists (select 1 from public.profiles p
      where p.id = target_profile_id and p.state = 'active')
    and (
      target_profile_id = viewer.id
      or (
        not exists (select 1 from private.account_blocks b
          where (b.blocker_profile_id = viewer.id and b.blocked_profile_id = target_profile_id)
             or (b.blocker_profile_id = target_profile_id and b.blocked_profile_id = viewer.id))
        and not exists (select 1 from private.profile_photo_reports r
          where r.reporter_profile_id = viewer.id and r.reported_profile_id = target_profile_id)
        and (
          private.are_friends(viewer.id, target_profile_id)
          or exists (select 1 from private.friend_requests r
            where r.sender_profile_id = target_profile_id and r.recipient_profile_id = viewer.id)
          or exists (select 1 from public.profiles p where p.id = target_profile_id
            and p.username is not null and p.show_in_search)
          or exists (select 1 from public.competitions c
            join public.competition_participants own
              on own.competition_id = c.id and own.profile_id = viewer.id
                and own.state = 'accepted'
            join public.competition_participants other
              on other.competition_id = c.id and other.profile_id = target_profile_id
                and other.state = 'accepted'
            where c.lifecycle in ('scheduled', 'active', 'ends_today', 'tallying',
              'completed', 'archived'))
          or exists (select 1 from public.competitions c
            where c.creator_profile_id = target_profile_id
              and c.invited_profile_id = viewer.id and c.lifecycle = 'pending'
              and c.invitation_expires_at > pg_catalog.statement_timestamp())
        )
      )
    )
  from (select private.current_profile_id() as id) viewer;
$$;

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
     and exists (select 1 from public.profiles p where p.id = input_recipient_profile_id and p.username is not null)
     and not exists (select 1 from public.competition_participants a
       join public.competition_participants b on b.competition_id = a.competition_id
       where a.profile_id = caller_profile_id and b.profile_id = input_recipient_profile_id) then
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
         or (exists (select 1 from public.profiles p where p.id = input_profile_id and p.username is not null)
           and not exists (select 1 from public.competition_participants a
             join public.competition_participants b on b.competition_id = a.competition_id
             where a.profile_id = caller_profile_id and b.profile_id = input_profile_id))))
     or exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = input_profile_id
         and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return recipient;
end;
$$;

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
  select p.id, p.display_name, p.state, p.challenge_policy into target
  from private.challenge_links l
  join public.profiles p on p.id = l.profile_id
  where l.code = input_code;
  if found and target.id = caller_profile_id then
    raise exception 'own_challenge_link' using errcode = 'P0001';
  end if;
  if not found or target.state <> 'active'
     or (target.challenge_policy = 'friends_only' and not private.are_friends(caller_profile_id, target.id))
     or exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = target.id
         and b.blocked_profile_id = caller_profile_id) then
    raise exception 'recipient_unavailable' using errcode = 'P0001';
  end if;
  return pg_catalog.jsonb_build_object('display_name', target.display_name);
end;
$$;

revoke all on function private.are_friends(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.is_reserved_username(text) from public, anon, authenticated, service_role;

revoke all on function private.people_blocked(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.person_reachable(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.friend_relationship(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.friend_person(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.lock_friend_pair(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function private.wake_friend_profile(uuid) from public, anon, authenticated, service_role;

revoke all on function private.consume_people_search(uuid) from public, anon, authenticated, service_role;

revoke all on function private.purge_friends_on_block() from public, anon, authenticated, service_role;

revoke all on function private.purge_friends_on_profile_deactivation() from public, anon, authenticated, service_role;

revoke all on function public.get_friend_settings() from public, anon, authenticated, service_role;
grant execute on function public.get_friend_settings() to authenticated;

revoke all on function public.set_username(text) from public, anon, authenticated, service_role;
grant execute on function public.set_username(text) to authenticated;

revoke all on function public.username_available(text) from public, anon, authenticated, service_role;
grant execute on function public.username_available(text) to authenticated;

revoke all on function public.update_friend_settings(boolean, text) from public, anon, authenticated, service_role;
grant execute on function public.update_friend_settings(boolean, text) to authenticated;

revoke all on function public.search_people(text) from public, anon, authenticated, service_role;
grant execute on function public.search_people(text) to authenticated;

revoke all on function public.list_friends() from public, anon, authenticated, service_role;
grant execute on function public.list_friends() to authenticated;

revoke all on function public.send_friend_request(uuid) from public, anon, authenticated, service_role;
grant execute on function public.send_friend_request(uuid) to authenticated;

revoke all on function public.respond_to_friend_request(uuid, boolean) from public, anon, authenticated, service_role;
grant execute on function public.respond_to_friend_request(uuid, boolean) to authenticated;

revoke all on function public.remove_friend(uuid) from public, anon, authenticated, service_role;
grant execute on function public.remove_friend(uuid) to authenticated;

revoke all on function public.block_profile(uuid) from public, anon, authenticated, service_role;
grant execute on function public.block_profile(uuid) to authenticated;

revoke all on function public.report_profile(uuid) from public, anon, authenticated, service_role;
grant execute on function public.report_profile(uuid) to authenticated;

-- One-time launch backfill. RPCs never recreate a friendship removed afterwards.
insert into private.friendships (profile_low, profile_high)
select distinct a.profile_id, b.profile_id
from public.competition_participants a
join public.competition_participants b on b.competition_id = a.competition_id and a.profile_id < b.profile_id
join public.competitions c on c.id = a.competition_id
join public.profiles low on low.id = a.profile_id and low.state = 'active'
join public.profiles high on high.id = b.profile_id and high.state = 'active'
where a.state = 'accepted' and b.state = 'accepted'
  and c.lifecycle in ('scheduled','active','ends_today','tallying','completed','archived')
  and not private.people_blocked(a.profile_id, b.profile_id)
on conflict do nothing;
