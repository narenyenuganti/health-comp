begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select md5('sign-up-auth-' || n)::uuid;
$$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text,true);
$$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,4) n;
insert into public.profiles(auth_user_id,display_name,state) values (pg_temp.uid(4),'Old Build','active');

select ok((select p.prosecdef and p.proconfig = array['search_path=""']
  and has_function_privilege('authenticated',p.oid,'execute')
  and not has_function_privilege('anon',p.oid,'execute')
  and not has_function_privilege('service_role',p.oid,'execute')
  and not has_function_privilege('public',p.oid,'execute')
  from pg_proc p where p.oid = 'public.sign_up_with_username(text)'::regprocedure),
  'only signed-in callers can sign up with a username');

set local role authenticated;
select pg_temp.as_user(1);
select throws_ok($$select public.sign_up_with_username(null)$$,'22023','invalid_username','null username');
select throws_ok($$select public.sign_up_with_username('ab')$$,'22023','invalid_username','short username');
select throws_ok($$select public.sign_up_with_username('bad-name')$$,'22023','invalid_username','invalid characters');
select throws_ok($$select public.sign_up_with_username('AdMiN')$$,'P0001','username_unavailable','reserved reads as taken');
select is(public.sign_up_with_username('  ALIce_1  ')->>'display_name','alice_1','the username is the name');
select is(public.get_friend_settings()->>'username','alice_1','the profile holds the username');
select is(public.sign_up_with_username('other_name')->>'display_name','alice_1','a second call returns the same profile');
select is(public.bootstrap_current_profile(null)->>'display_name','alice_1','launch restores it');

select pg_temp.as_user(2);
select throws_ok($$select public.sign_up_with_username('alice_1')$$,'P0001','username_unavailable','taken username');
select throws_ok($$select public.bootstrap_current_profile(null)$$,'P0001','display_name_required','a taken username creates no profile');
select is(public.sign_up_with_username('bob_2')->>'display_name','bob_2','another username works');

select pg_temp.as_user(4);
select is(public.sign_up_with_username('alice_1')->>'display_name','Old Build','an existing profile is returned unchanged');
select is(public.get_friend_settings()->>'username',null::text,'and gains no username');

reset role;
select set_config('request.jwt.claims','{"role":"anon"}',true);
set local role anon;
select throws_ok($$select public.sign_up_with_username('carol_3')$$,'42501',null,'signed-out callers are refused');

reset role;
select * from finish();
rollback;
