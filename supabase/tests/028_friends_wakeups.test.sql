begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();
create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('wake-profile-'||n)::uuid $$;
-- Ignore only realtime.send's transport-generated id when checking the payload.
create temporary view wakes as select payload - 'id' as payload,event,topic,private
from realtime.messages where topic in (select 'profile:'||pg_temp.pid(n)::text from generate_series(1,6) n);
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',md5('wake-user-'||n)::uuid)::text,true)
$$;
create function pg_temp.wake_count(n integer) returns bigint language sql security definer as $$
  select count(*) from pg_temp.wakes where topic='profile:'||pg_temp.pid(n)::text;
$$;
insert into auth.users(id) select md5('wake-user-'||n)::uuid from generate_series(1,6) n;
insert into public.profiles(id,auth_user_id,display_name,state,username)
select pg_temp.pid(n),md5('wake-user-'||n)::uuid,'Wake '||n,'active','wake_'||n from generate_series(1,6) n;
create temporary table before_changes as select count(*) as n from public.competition_change_log;
set local role authenticated;
select pg_temp.as_user(1);
select lives_ok($$select public.send_friend_request(pg_temp.pid(2))$$,'send changes row');
select is(pg_temp.wake_count(2),1::bigint,'send wakes other');
select lives_ok($$select public.send_friend_request(pg_temp.pid(2))$$,'send retry');
select is(pg_temp.wake_count(2),1::bigint,'send retry no wake');
select pg_temp.as_user(2);
select lives_ok($$select public.respond_to_friend_request(pg_temp.pid(1),true)$$,'accept changes rows');
select is(pg_temp.wake_count(1),1::bigint,'accept wakes other');
select lives_ok($$select public.respond_to_friend_request(pg_temp.pid(1),true)$$,'accept retry');
select is(pg_temp.wake_count(1),1::bigint,'accept retry no wake');
select pg_temp.as_user(1);
select lives_ok($$select public.remove_friend(pg_temp.pid(2))$$,'remove changes row');
select is(pg_temp.wake_count(2),2::bigint,'remove wakes other');
select lives_ok($$select public.remove_friend(pg_temp.pid(2))$$,'remove retry');
select is(pg_temp.wake_count(2),2::bigint,'remove retry no wake');
select lives_ok($$select public.send_friend_request(pg_temp.pid(2))$$,'second send');
select pg_temp.as_user(2);
select lives_ok($$select public.respond_to_friend_request(pg_temp.pid(1),false)$$,'decline changes row');
select is(pg_temp.wake_count(1),2::bigint,'decline wakes other');
select lives_ok($$select public.respond_to_friend_request(pg_temp.pid(1),false)$$,'decline retry');
select is(pg_temp.wake_count(1),2::bigint,'decline retry no wake');
select pg_temp.as_user(1);
select lives_ok($$select public.send_friend_request(pg_temp.pid(2))$$,'third send');
select lives_ok($$select public.block_profile(pg_temp.pid(2))$$,'block removes request');
select is(pg_temp.wake_count(2),5::bigint,'block trigger wakes when it purges relationship');
select lives_ok($$select public.block_profile(pg_temp.pid(2))$$,'block retry');
select is(pg_temp.wake_count(2),5::bigint,'block retry no wake');
select lives_ok($$select public.report_profile(pg_temp.pid(3))$$,'report');
select is(pg_temp.wake_count(3),0::bigint,'report sends no wake');
reset role;
select ok((select bool_and(payload='{"server_cursor_hint":"0"}'::jsonb
  and event='competition_changed' and private) from wakes),'wake event and payload exact existing contract');
select is((select count(*) from public.competition_change_log),(select n from before_changes),'friends never add change-log entries');
-- Deactivation notifies each active relationship counterpart once, never reports.
insert into private.friendships values(least(pg_temp.pid(1),pg_temp.pid(3)),greatest(pg_temp.pid(1),pg_temp.pid(3)),now());
insert into private.friend_requests values(pg_temp.pid(1),pg_temp.pid(3),now()),(pg_temp.pid(4),pg_temp.pid(1),now()),(pg_temp.pid(1),pg_temp.pid(5),now());
-- Corrupt fixture state bypasses the purge only to test its active-recipient filter.
alter table public.profiles disable trigger purge_friends_on_profile_deactivation;
update public.profiles set state='deleting',username=null where id=pg_temp.pid(5);
alter table public.profiles enable trigger purge_friends_on_profile_deactivation;
insert into private.profile_reports values(pg_temp.pid(1),pg_temp.pid(6),now());
update public.profiles set state='deleting' where id=pg_temp.pid(1);
select is(pg_temp.wake_count(3),1::bigint,'deactivation deduplicates friendship and request counterpart');
select is(pg_temp.wake_count(4),1::bigint,'deactivation wakes incoming requester');
select is(pg_temp.wake_count(5),0::bigint,'deactivation never wakes inactive counterpart');
select is(pg_temp.wake_count(6),0::bigint,'deactivation never wakes report-only counterpart');
-- Each new RPC is actually denied to both disallowed roles, beyond ACL inspection.
create temporary table calls(sql text);
insert into calls values('get_friend_settings()'),('set_username(''alice'')'),('username_available(''alice'')'),
  ('update_friend_settings(true,''friends_only'')'),('search_people(''alice'')'),('list_friends()'),
  ('send_friend_request(null)'),('respond_to_friend_request(null,true)'),('remove_friend(null)'),('block_profile(null)'),('report_profile(null)');
grant select on calls to anon,service_role;
set local role anon;
select throws_ok('select public.'||sql,'42501',null,'anon denied '||sql) from calls;
reset role;
set local role service_role;
select throws_ok('select public.'||sql,'42501',null,'service role denied '||sql) from calls;
reset role;
select * from finish();
rollback;
