begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select plan(3);

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$
  select ('cc100000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid;
$$;
insert into auth.users(id)
select ('cc000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid from generate_series(1,10) n;
insert into public.profiles(id,auth_user_id,display_name,state)
select pg_temp.pid(n),('cc000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
  case when n in(3,4) then 'Alpha' else 'Zulu' end,'active' from generate_series(1,10) n;

-- Insertion order differs from the expected name/time order and its UUID ties.
insert into private.friendships(profile_low,profile_high) values
  (pg_temp.pid(1),pg_temp.pid(2)),(pg_temp.pid(1),pg_temp.pid(4)),(pg_temp.pid(1),pg_temp.pid(3));
insert into private.friend_requests(sender_profile_id,recipient_profile_id,created_at) values
  (pg_temp.pid(5),pg_temp.pid(1),'2026-11-01 12:00:00+00'),
  (pg_temp.pid(7),pg_temp.pid(1),'2026-11-02 12:00:00+00'),
  (pg_temp.pid(6),pg_temp.pid(1),'2026-11-02 12:00:00+00'),
  (pg_temp.pid(1),pg_temp.pid(8),'2026-11-01 12:00:00+00'),
  (pg_temp.pid(1),pg_temp.pid(10),'2026-11-02 12:00:00+00'),
  (pg_temp.pid(1),pg_temp.pid(9),'2026-11-02 12:00:00+00');
set local role authenticated;
select set_config('request.jwt.claims',
  '{"role":"authenticated","sub":"cc000000-0000-4000-8000-000000000001"}',true);
select is(array(select (person->>'id')::uuid
  from jsonb_array_elements(public.list_friends()->'friends') with ordinality listed(person,position)
  order by position),array[pg_temp.pid(3),pg_temp.pid(4),pg_temp.pid(2)],
  'friends sorted by display name then id when names collide');
select is(array(select (person->>'id')::uuid
  from jsonb_array_elements(public.list_friends()->'incoming') with ordinality listed(person,position)
  order by position),array[pg_temp.pid(6),pg_temp.pid(7),pg_temp.pid(5)],
  'incoming newest first then id when timestamps collide');
select is(array(select (person->>'id')::uuid
  from jsonb_array_elements(public.list_friends()->'outgoing') with ordinality listed(person,position)
  order by position),array[pg_temp.pid(9),pg_temp.pid(10),pg_temp.pid(8)],
  'outgoing newest first then id when timestamps collide');
reset role;
select * from finish();
rollback;
