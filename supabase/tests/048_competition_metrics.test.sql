begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('metrics-profile-' || n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('metrics-auth-' || n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text, true);
$$;
create function pg_temp.invite(sender integer, recipient integer) returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(extensions.digest(gen_random_uuid()::text, 'sha256'), 'UTC', null,
    pg_temp.uid(sender), gen_random_uuid(), 1::smallint, pg_temp.pid(recipient));
end; $$;
create function pg_temp.list_metrics(n integer) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(n); return public.list_competition_metrics()->'matches'; end; $$;

insert into auth.users(id) select pg_temp.uid(n) from generate_series(1, 4) n;
insert into public.profiles(id, auth_user_id, display_name, state)
  select pg_temp.pid(n), pg_temp.uid(n), 'Player ' || n, 'active' from generate_series(1, 4) n;
insert into public.device_installations(
  profile_id, installation_id, apns_token, environment, state, supports_challenges, supports_reactions, supports_group_matches
)
select
  pg_temp.pid(n),
  md5('metrics-install-' || n)::uuid,
  md5('metrics-token-' || n) || md5('metrics-token-' || n),
  'sandbox', 'active', true, true, true
from generate_series(1, 4) n;

create temporary table m(label text primary key, id uuid);
insert into m values ('duel', pg_temp.invite(1, 2)), ('legacy', pg_temp.invite(1, 3));
grant select on m to authenticated;

select pg_temp.as_user(1);
insert into m values (
  'group',
  (public.create_group_match(
    'three_way',
    jsonb_build_array(
      jsonb_build_object('kind', 'human', 'profile_id', pg_temp.pid(1)),
      jsonb_build_object('kind', 'human', 'profile_id', pg_temp.pid(2)),
      jsonb_build_object('kind', 'bot', 'bot_mode', 'pacer')
    ),
    'UTC',
    extensions.gen_random_uuid()
  )->>'competition_id')::uuid
);

select throws_ok(
  $$select public.set_competition_metrics((select id from m where label = 'duel'), false, false, false, false)$$,
  '22023', 'invalid_competition_metrics',
  'empty metric set is rejected'
);

select pg_temp.as_user(2);
select throws_ok(
  $$select public.set_competition_metrics((select id from m where label = 'duel'), true, false, false, true)$$,
  'P0001', 'metrics_not_allowed',
  'invitee cannot set competition metrics'
);

select pg_temp.as_user(4);
select throws_ok(
  $$select public.set_competition_metrics((select id from m where label = 'duel'), true, false, false, true)$$,
  'P0001', 'metrics_not_allowed',
  'stranger cannot set competition metrics'
);

select pg_temp.as_user(1);
select is(
  public.set_competition_metrics((select id from m where label = 'duel'), true, false, false, true),
  jsonb_build_object(
    'competition_id', (select id from m where label = 'duel'),
    'move', true, 'exercise', false, 'stand', false, 'sleep', true
  ),
  'creator sets Move + Sleep on a pending duel'
);
select is(
  public.set_competition_metrics((select id from m where label = 'group'), false, false, false, true),
  jsonb_build_object(
    'competition_id', (select id from m where label = 'group'),
    'move', false, 'exercise', false, 'stand', false, 'sleep', true
  ),
  'creator sets Sleep-only on a pending group match'
);
select lives_ok(
  $$select public.enable_sleep_scoring((select id from m where label = 'legacy'))$$,
  'legacy enable_sleep_scoring still works'
);

select is(jsonb_array_length(pg_temp.list_metrics(2)), 2, 'invitee sees pending duel and group metrics');
select is(pg_temp.list_metrics(4), '[]'::jsonb, 'stranger sees no metrics');
select is(
  (select elem from jsonb_array_elements(pg_temp.list_metrics(3)) elem limit 1),
  jsonb_build_object(
    'competition_id', (select id from m where label = 'legacy'),
    'move', true, 'exercise', true, 'stand', true, 'sleep', true
  ),
  'legacy sleep beta matches appear as all four metrics'
);

select pg_temp.as_user(2);
select lives_ok($$select public.accept_group_match((select id from m where label = 'group'))$$, 'invitee accepts group match');
update public.competitions
set start_day = current_date - 2,
    lifecycle = 'active',
    invitation_expires_at = (current_date - 2)::timestamp at time zone 'UTC',
    best_available_deadline = (current_date + 6)::timestamp at time zone 'UTC'
where id = (select id from m where label = 'group');

select pg_temp.as_user(1);
select throws_ok(
  $$select public.set_competition_metrics((select id from m where label = 'group'), true, true, true, false)$$,
  'P0001', 'metrics_not_allowed',
  'metrics lock once match is no longer pending'
);
select is(
  (public.submit_sleep_night((select id from m where label = 'group'), 1, 8800))->>'sleep_basis_points',
  '8800',
  'group match participant can submit a sleep night'
);

select pg_temp.as_user(1);
set local role authenticated;
select throws_ok(
  $$select * from private.competition_scoring_metrics$$,
  '42501', null,
  'scoring metrics table is not readable directly'
);
reset role;

select * from finish();
rollback;
