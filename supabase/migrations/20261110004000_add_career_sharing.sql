-- A person's 1v1 career, shown on their profile only if they opt in. Additive:
-- released builds never call these.
alter table public.profiles add column show_career boolean not null default false;

-- Finished 1v1 weeks only, in the order the app folds the belt: group matches
-- never count (the belt stays 1v1) and a deleted opponent's belt is retired.
create function private.career_summary(target uuid)
returns jsonb language sql stable security definer set search_path = ''
as $$
  with weeks as (
    select r.competition_id as id,
      case when r.participant_a_profile_id = target
        then r.participant_b_profile_id else r.participant_a_profile_id end as opponent,
      r.outcome,
      r.winner_profile_id as winner,
      case when r.participant_a_profile_id = target
        then r.participant_a_total_centi_points else r.participant_b_total_centi_points end as centi_points,
      (c.start_day + 7)::timestamp at time zone c.time_zone_identifier as ended
    from public.competition_results r
    join public.competitions c on c.id = r.competition_id
    where c.format = 'duel'
      and target in (r.participant_a_profile_id, r.participant_b_profile_id)
  ), runs as (
    select count(*) as wins from (
      select winner is not distinct from target as won,
        count(*) filter (where winner is distinct from target) over (order by ended, id) as run
      from weeks
    ) numbered where won group by run
  ), holders as (
    select distinct on (opponent) opponent, winner
    from weeks where outcome = 'winner' order by opponent, ended desc, id desc
  )
  select pg_catalog.jsonb_build_object(
    'wins', (select count(*) from weeks where winner = target),
    'losses', (select count(*) from weeks where outcome = 'winner' and winner <> target),
    'ties', (select count(*) from weeks where outcome = 'tie'),
    'people', (select count(distinct opponent) from weeks),
    'belts', (select count(*) from holders h
      join public.profiles p on p.id = h.opponent and p.state = 'active'
      where h.winner = target),
    'win_streak', coalesce((select max(wins) from runs), 0),
    'best_week_centi_points', coalesce((select max(centi_points) from weeks), 0));
$$;

-- Friends and people you have played with, never a searcher or anyone blocked.
create function private.career_is_visible(caller uuid, target uuid)
returns boolean language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.profiles p
      where p.id = target and p.id <> caller and p.state = 'active' and p.show_career)
    and not private.people_blocked(caller, target)
    and (private.are_friends(caller, target)
      or exists (select 1 from public.competitions c
        join public.competition_participants a on a.competition_id = c.id
          and a.profile_id = caller and a.state = 'accepted'
        join public.competition_participants b on b.competition_id = c.id
          and b.profile_id = target and b.state = 'accepted'
        where c.lifecycle in ('scheduled','active','ends_today','tallying','completed','archived')));
$$;

-- Null whatever the reason, so the answer can't reveal a block.
create function public.get_career_summary(target_profile_id uuid)
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  target alias for target_profile_id;
  caller uuid := private.require_active_caller_profile_id();
begin
  if not private.career_is_visible(caller, target) then
    return null;
  end if;
  return private.career_summary(target);
end;
$$;

create function public.get_career_sharing()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller uuid := private.require_active_caller_profile_id();
begin
  return (select pg_catalog.jsonb_build_object('enabled', p.show_career)
    from public.profiles p where p.id = caller);
end;
$$;

create function public.set_career_sharing(enabled boolean)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_enabled alias for enabled;
  caller uuid := private.require_active_caller_profile_id();
begin
  if input_enabled is null then
    raise exception 'invalid_career_sharing' using errcode = '22023';
  end if;
  perform private.lock_friend_pair(caller, caller);
  update public.profiles p set show_career = input_enabled
  where p.id = caller and p.show_career is distinct from input_enabled;
  return public.get_career_sharing();
end;
$$;

revoke all on function private.career_summary(uuid) from public, anon, authenticated, service_role;
revoke all on function private.career_is_visible(uuid, uuid) from public, anon, authenticated, service_role;

revoke all on function public.get_career_summary(uuid) from public, anon, authenticated, service_role;
grant execute on function public.get_career_summary(uuid) to authenticated;

revoke all on function public.get_career_sharing() from public, anon, authenticated, service_role;
grant execute on function public.get_career_sharing() to authenticated;

revoke all on function public.set_career_sharing(boolean) from public, anon, authenticated, service_role;
grant execute on function public.set_career_sharing(boolean) to authenticated;
