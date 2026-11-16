-- Sleep beta: "Rings + Sleep" duels. Each night is worth up to 100 points
-- (10000 basis points: time asleep 50, bedtime consistency 30, wake-ups 20,
-- worked out on the phone), on top of the rings' 600 a day.
--
-- Sleep lives beside the ring score, never inside it, the way reactions do
-- (20261102002700): every installed build validates scoring_policy_identity
-- and exact JSON keys, and one unknown policy fails its whole match list. So
-- a sleep duel stays an ordinary 'healthcomp.activity-score.v1' match, the
-- ring pipeline is untouched, and builds without sleep simply see rings. The
-- sleep nights are private tables read and written only through three
-- security-definer RPCs.
--
-- ponytail: nights are not App Attest signed and the combined verdict is
-- computed on the device; competition_results and career_summary stay
-- rings-only. Sign nights and fold them into finalization if sleep leaves beta.

create table private.competition_sleep_matches (
  competition_id uuid primary key references public.competitions(id),
  created_at timestamptz not null default pg_catalog.statement_timestamp()
);
alter table private.competition_sleep_matches enable row level security;
alter table private.competition_sleep_matches force row level security;
revoke all on table private.competition_sleep_matches
  from public, anon, authenticated, service_role;

-- A night counts for the day you wake up on (day_ordinal 1 is the night
-- before Day 1 ends). Only the computed points leave the phone.
create table private.competition_sleep_nights (
  competition_id uuid not null references private.competition_sleep_matches(competition_id),
  profile_id uuid not null,
  day_ordinal smallint not null check (day_ordinal between 1 and 7),
  sleep_basis_points integer not null check (sleep_basis_points between 0 and 10000),
  updated_at timestamptz not null default pg_catalog.statement_timestamp(),
  primary key (competition_id, profile_id, day_ordinal),
  constraint competition_sleep_nights_membership_fk
    foreign key (competition_id, profile_id)
    references public.competition_participants(competition_id, profile_id)
);
alter table private.competition_sleep_nights enable row level security;
alter table private.competition_sleep_nights force row level security;
revoke all on table private.competition_sleep_nights
  from public, anon, authenticated, service_role;

-- The creator turns sleep on for their own duel while it is still a pending
-- challenge, right after creating it. Once someone has accepted a rings
-- match, it stays a rings match.
create function public.enable_sleep_scoring(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  target record;
begin
  select c.id, c.lifecycle, c.format into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.role = 'creator'
  where c.id = input_competition_id
  for no key update of c;

  -- One answer for every refusal, so a non-participant learns nothing.
  if not found or target.format <> 'duel' or target.lifecycle <> 'pending' then
    raise exception 'sleep_not_allowed' using errcode = 'P0001';
  end if;

  insert into private.competition_sleep_matches (competition_id)
  values (target.id)
  on conflict on constraint competition_sleep_matches_pkey do nothing;

  return pg_catalog.jsonb_build_object('competition_id', target.id);
end;
$$;

-- Your own night. Allowed from the day it counts for until the match has a
-- result or its best-available deadline passes; a later read (a tracker that
-- syncs late) replaces it.
create function public.submit_sleep_night(
  competition_id uuid,
  day_ordinal integer,
  sleep_basis_points integer
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_day_ordinal alias for day_ordinal;
  input_basis_points alias for sleep_basis_points;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  decision_time timestamptz := pg_catalog.statement_timestamp();
  target record;
  current_points integer;
  recipient record;
begin
  if input_competition_id is null
     or input_day_ordinal is null or input_day_ordinal not between 1 and 7
     or input_basis_points is null or input_basis_points not between 0 and 10000 then
    raise exception 'invalid_sleep_night' using errcode = '22023';
  end if;

  select c.id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.best_available_deadline, c.next_server_seq
  into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted'
  join private.competition_sleep_matches s on s.competition_id = c.id
  where c.id = input_competition_id
  for no key update of c;

  if not found
     or target.lifecycle not in ('active', 'ends_today', 'tallying')
     or target.best_available_deadline <= decision_time
     or exists (select 1 from public.competition_results r
       where r.competition_id = target.id)
     or input_day_ordinal > (decision_time at time zone target.time_zone_identifier)::date
       - target.start_day + 1 then
    raise exception 'sleep_not_allowed' using errcode = 'P0001';
  end if;

  select n.sleep_basis_points into current_points
  from private.competition_sleep_nights n
  where n.competition_id = target.id and n.profile_id = caller_profile_id
    and n.day_ordinal = input_day_ordinal;

  if current_points is distinct from input_basis_points then
    insert into private.competition_sleep_nights as n (
      competition_id, profile_id, day_ordinal, sleep_basis_points, updated_at
    ) values (
      target.id, caller_profile_id, input_day_ordinal, input_basis_points, decision_time
    )
    on conflict on constraint competition_sleep_nights_pkey
    do update set sleep_basis_points = excluded.sleep_basis_points,
      updated_at = decision_time;

    -- The reactions broadcast: both apps just reconcile.
    for recipient in
      select p.profile_id
      from public.competition_participants p
      join public.profiles pr on pr.id = p.profile_id
      where p.competition_id = target.id and p.state = 'accepted'
        and pr.state = 'active'
      order by p.profile_id
    loop
      perform realtime.send(
        pg_catalog.jsonb_build_object(
          'server_cursor_hint', (target.next_server_seq - 1)::text
        ),
        'competition_changed',
        'profile:' || recipient.profile_id::text,
        true
      );
    end loop;
  end if;

  -- ponytail: no per-caller rate limit (participants only, unchanged nights write nothing).
  return pg_catalog.jsonb_build_object('competition_id', target.id,
    'day_ordinal', input_day_ordinal, 'sleep_basis_points', input_basis_points);
end;
$$;

-- Every sleep duel you are in, newest first. A pending invitee learns only
-- that the challenge is Rings + Sleep; nights are for accepted players.
create function public.list_sleep_scoring()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  result jsonb;
begin
  -- ponytail: 500 newest sleep matches. Page per match if anyone gets there.
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'competition_id', m.competition_id,
      'nights', case when m.state = 'accepted' then coalesce((
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'profile_id', n.profile_id,
            'day_ordinal', n.day_ordinal,
            'sleep_basis_points', n.sleep_basis_points,
            'updated_at', n.updated_at
          ) order by n.day_ordinal, n.profile_id)
        from private.competition_sleep_nights n
        where n.competition_id = m.competition_id), '[]'::jsonb)
        else '[]'::jsonb end
    ) order by m.created_at desc, m.competition_id), '[]'::jsonb)
  into result
  from (
    select s.competition_id, s.created_at, p.state
    from private.competition_sleep_matches s
    join public.competition_participants p
      on p.competition_id = s.competition_id
     and p.profile_id = caller_profile_id
     and p.state in ('pending', 'accepted')
    order by s.created_at desc, s.competition_id
    limit 500
  ) m;
  return pg_catalog.jsonb_build_object('matches', result);
end;
$$;

revoke all on function public.enable_sleep_scoring(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.enable_sleep_scoring(uuid) to authenticated;
revoke all on function public.submit_sleep_night(uuid, integer, integer)
  from public, anon, authenticated, service_role;
grant execute on function public.submit_sleep_night(uuid, integer, integer)
  to authenticated;
revoke all on function public.list_sleep_scoring()
  from public, anon, authenticated, service_role;
grant execute on function public.list_sleep_scoring() to authenticated;
