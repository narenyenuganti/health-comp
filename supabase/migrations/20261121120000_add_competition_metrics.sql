create table private.competition_scoring_metrics (
  competition_id uuid primary key references public.competitions(id),
  move boolean not null default true,
  exercise boolean not null default true,
  stand boolean not null default true,
  sleep boolean not null default false,
  created_at timestamptz not null default pg_catalog.statement_timestamp(),
  constraint competition_scoring_metrics_non_empty check (move or exercise or stand or sleep)
);
alter table private.competition_scoring_metrics enable row level security;
alter table private.competition_scoring_metrics force row level security;
revoke all on table private.competition_scoring_metrics
  from public, anon, authenticated, service_role;

create function public.set_competition_metrics(
  competition_id uuid,
  move boolean,
  exercise boolean,
  stand boolean,
  sleep boolean
)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_move alias for move;
  input_exercise alias for exercise;
  input_stand alias for stand;
  input_sleep alias for sleep;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  target record;
begin
  if input_competition_id is null
     or input_move is null
     or input_exercise is null
     or input_stand is null
     or input_sleep is null
     or not (input_move or input_exercise or input_stand or input_sleep) then
    raise exception 'invalid_competition_metrics' using errcode = '22023';
  end if;

  select c.id, c.lifecycle into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.role = 'creator'
  where c.id = input_competition_id
  for no key update of c;

  if not found or target.lifecycle <> 'pending' then
    raise exception 'metrics_not_allowed' using errcode = 'P0001';
  end if;

  if input_move and input_exercise and input_stand and not input_sleep then
    delete from private.competition_scoring_metrics m
    where m.competition_id = target.id;
    delete from private.competition_sleep_matches s
    where s.competition_id = target.id;
  else
    insert into private.competition_scoring_metrics as m (
      competition_id, move, exercise, stand, sleep
    ) values (
      target.id, input_move, input_exercise, input_stand, input_sleep
    )
    on conflict on constraint competition_scoring_metrics_pkey
    do update set
      move = excluded.move,
      exercise = excluded.exercise,
      stand = excluded.stand,
      sleep = excluded.sleep;

    if input_sleep then
      insert into private.competition_sleep_matches (competition_id)
      values (target.id)
      on conflict on constraint competition_sleep_matches_pkey do nothing;
    else
      delete from private.competition_sleep_matches s
      where s.competition_id = target.id;
    end if;
  end if;

  return pg_catalog.jsonb_build_object(
    'competition_id', target.id,
    'move', input_move,
    'exercise', input_exercise,
    'stand', input_stand,
    'sleep', input_sleep
  );
end;
$$;

create function public.list_competition_metrics()
returns jsonb language plpgsql stable security definer set search_path = ''
as $$
declare
  caller_profile_id uuid := private.require_active_caller_profile_id();
  result jsonb;
begin
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
      'competition_id', r.competition_id,
      'move', r.move,
      'exercise', r.exercise,
      'stand', r.stand,
      'sleep', r.sleep
    ) order by r.created_at desc, r.competition_id), '[]'::jsonb)
  into result
  from (
    select
      coalesce(m.competition_id, s.competition_id) as competition_id,
      coalesce(m.move, true) as move,
      coalesce(m.exercise, true) as exercise,
      coalesce(m.stand, true) as stand,
      coalesce(m.sleep, true) as sleep,
      coalesce(m.created_at, s.created_at) as created_at
    from private.competition_scoring_metrics m
    full outer join private.competition_sleep_matches s
      on s.competition_id = m.competition_id
    join public.competition_participants p
      on p.competition_id = coalesce(m.competition_id, s.competition_id)
     and p.profile_id = caller_profile_id
     and p.state in ('pending', 'accepted')
    order by coalesce(m.created_at, s.created_at) desc, coalesce(m.competition_id, s.competition_id)
    limit 500
  ) r;

  return pg_catalog.jsonb_build_object('matches', result);
end;
$$;

create or replace function public.submit_sleep_night(
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
    c.best_available_deadline, c.next_server_seq, p.left_at
  into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted'
  join private.competition_sleep_matches s on s.competition_id = c.id
  where c.id = input_competition_id
  for no key update of c;

  if not found
     or target.left_at is not null
     or target.lifecycle not in ('active', 'ends_today', 'tallying')
     or target.best_available_deadline <= decision_time
     or exists (select 1 from public.competition_results r
       where r.competition_id = target.id)
     or exists (select 1 from public.competition_group_results gr
       where gr.competition_id = target.id)
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

  return pg_catalog.jsonb_build_object('competition_id', target.id,
    'day_ordinal', input_day_ordinal, 'sleep_basis_points', input_basis_points);
end;
$$;

revoke all on function public.set_competition_metrics(uuid, boolean, boolean, boolean, boolean)
  from public, anon, authenticated, service_role;
grant execute on function public.set_competition_metrics(uuid, boolean, boolean, boolean, boolean)
  to authenticated;
revoke all on function public.list_competition_metrics()
  from public, anon, authenticated, service_role;
grant execute on function public.list_competition_metrics()
  to authenticated;
