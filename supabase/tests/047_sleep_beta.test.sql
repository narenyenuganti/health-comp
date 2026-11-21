begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('sleep-profile-' || n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('sleep-auth-' || n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text, true);
$$;
create function pg_temp.invite(sender integer, recipient integer) returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(extensions.digest(gen_random_uuid()::text, 'sha256'), 'UTC', null,
    pg_temp.uid(sender), gen_random_uuid(), 1::smallint, pg_temp.pid(recipient));
end; $$;
create function pg_temp.start(b integer, cid uuid, days_ago integer) returns void language plpgsql as $$
begin
  perform pg_temp.as_user(b); perform public.accept_competition_challenge(cid);
  update public.competitions set start_day = current_date - days_ago, lifecycle = 'active',
    invitation_expires_at = (current_date - days_ago)::timestamp at time zone 'UTC',
    best_available_deadline = (current_date - days_ago + 8)::timestamp at time zone 'UTC' where id = cid;
end; $$;
create function pg_temp.night(n integer, cid uuid, day integer, points integer) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(n); return public.submit_sleep_night(cid, day, points); end; $$;
create function pg_temp.list(n integer) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(n); return public.list_sleep_scoring()->'matches'; end; $$;

insert into auth.users(id) select pg_temp.uid(n) from generate_series(1, 4) n;
insert into public.profiles(id, auth_user_id, display_name, state)
  select pg_temp.pid(n), pg_temp.uid(n), 'Sleeper ' || n, 'active' from generate_series(1, 4) n;
create temporary table m(label text primary key, id uuid);
insert into m values ('sleep', pg_temp.invite(1, 2)), ('rings', pg_temp.invite(1, 3));
grant select on m to authenticated;

select pg_temp.as_user(2);
select throws_ok($$select public.enable_sleep_scoring((select id from m where label = 'sleep'))$$,
  'P0001', 'sleep_not_allowed', 'the invitee cannot turn sleep on');
select pg_temp.as_user(4);
select throws_ok($$select public.enable_sleep_scoring((select id from m where label = 'sleep'))$$,
  'P0001', 'sleep_not_allowed', 'a stranger cannot turn sleep on');
select pg_temp.as_user(1);
select is(public.enable_sleep_scoring((select id from m where label = 'sleep')),
  jsonb_build_object('competition_id', (select id from m where label = 'sleep')),
  'the creator turns sleep on, answered like any match command');
select lives_ok($$select public.enable_sleep_scoring((select id from m where label = 'sleep'))$$,
  'turning it on twice is fine');

select is(jsonb_array_length(pg_temp.list(2)), 1, 'the invitee sees the pending sleep challenge');
select is(pg_temp.list(4), '[]'::jsonb, 'a stranger sees nothing');

select pg_temp.start(2, (select id from m where label = 'sleep'), 2);
select pg_temp.start(3, (select id from m where label = 'rings'), 2);
select pg_temp.as_user(1);
select throws_ok($$select public.enable_sleep_scoring((select id from m where label = 'rings'))$$,
  'P0001', 'sleep_not_allowed', 'an accepted rings match stays rings');

select is((pg_temp.night(1, (select id from m where label = 'sleep'), 3, 9125))->>'sleep_basis_points', '9125',
  'a player saves today''s night');
select lives_ok($$select pg_temp.night(1, (select id from m where label = 'sleep'), 3, 9400)$$,
  'a later read replaces the night');
select lives_ok($$select pg_temp.night(2, (select id from m where label = 'sleep'), 1, 0)$$,
  'a missed night can be saved as 0');
select throws_ok($$select pg_temp.night(1, (select id from m where label = 'sleep'), 4, 5000)$$,
  'P0001', 'sleep_not_allowed', 'tomorrow''s night is refused');
select throws_ok($$select pg_temp.night(1, (select id from m where label = 'sleep'), 2, 10001)$$,
  '22023', 'invalid_sleep_night', 'more than 100 points is refused');
select throws_ok($$select pg_temp.night(1, (select id from m where label = 'rings'), 1, 5000)$$,
  'P0001', 'sleep_not_allowed', 'a rings match takes no nights');
select throws_ok($$select pg_temp.night(4, (select id from m where label = 'sleep'), 1, 5000)$$,
  'P0001', 'sleep_not_allowed', 'a stranger cannot save a night');

select set_eq($$select (e->>'day_ordinal')::int as day, (e->>'sleep_basis_points')::int as points, (e->>'profile_id')::uuid as who
    from jsonb_array_elements(pg_temp.list(2)->0->'nights') e$$,
  $$values (1, 0, pg_temp.pid(2)), (3, 9400, pg_temp.pid(1))$$,
  'both players read both nights');
select set_eq($$select jsonb_object_keys(pg_temp.list(1)->0)$$, array['competition_id','nights'],
  'a match has exactly two keys');
select set_eq($$select jsonb_object_keys(pg_temp.list(1)->0->'nights'->0)$$,
  array['profile_id','day_ordinal','sleep_basis_points','updated_at'],
  'a night has exactly four keys');

update public.competitions set lifecycle = 'tallying',
  best_available_deadline = now() - interval '1 minute' where id = (select id from m where label = 'sleep');
select throws_ok($$select pg_temp.night(1, (select id from m where label = 'sleep'), 2, 5000)$$,
  'P0001', 'sleep_not_allowed', 'nights stop at the best-available deadline');

select pg_temp.as_user(1);
set local role authenticated;
select throws_ok($$select * from private.competition_sleep_nights$$, '42501', null,
  'nights are not readable directly');
reset role;

select * from finish();
rollback;
