begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();
create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('backfill-profile-'||n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('backfill-user-'||n)::uuid $$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,20) n;
insert into public.profiles(id,auth_user_id,display_name,state)
select pg_temp.pid(n),pg_temp.uid(n),'Backfill Person '||n,'active' from generate_series(1,20) n;
-- Six accepted lifecycle pairs, cancelled/pending/declined/expired exclusions,
-- nonaccepted participant, inactive profile and both block directions.
do $$
declare c uuid; life text; n integer;
begin
  for n, life in select * from (values
    (2,'scheduled'),(3,'active'),(4,'ends_today'),(5,'tallying'),(6,'completed'),(7,'archived'),
    (8,'cancelled'),(9,'pending'),(10,'declined'),(11,'expired'),
    (12,'completed'),(13,'completed'),(14,'completed'),(15,'completed'),
    (16,'completed'),(17,'completed'),(18,'completed'),
    (2,'cancelled'),(2,'completed'),(2,'archived'),(19,'pending'),(19,'declined')
  ) fixtures(profile_number,lifecycle) loop
    c := gen_random_uuid();
    insert into public.competitions(id,creator_profile_id,invited_profile_id,time_zone_identifier,
      scoring_policy_identity,lifecycle,invitation_expires_at,start_day,best_available_deadline,
      closed_by_profile_id,closed_at)
    values(c,pg_temp.pid(1),pg_temp.pid(n),'UTC','healthcomp.activity-score.v1',life,
      now()+interval '7 days',
      case when life in ('scheduled','active','ends_today','tallying','completed','archived') then current_date end,
      case when life in ('scheduled','active','ends_today','tallying','completed','archived') then now()+interval '30 days' end,
      case when life in ('cancelled','declined') then pg_temp.pid(1) end,
      case when life in ('cancelled','declined') then now() end);
    insert into public.competition_participants(competition_id,profile_id,role,state)
    values(c,pg_temp.pid(1),'creator','accepted'),(c,pg_temp.pid(n),'invitee',
      case when n=12 then 'pending' when n=18 then 'anonymized' else 'accepted' end);
  end loop;
end;
$$;
update public.profiles set state='deleting' where id=pg_temp.pid(13);
-- pid(16) sorts below pid(1); pid(13) above it, exercising both profile joins.
update public.profiles set state='deleting' where id=pg_temp.pid(16);
update public.profiles set state='anonymized',auth_user_id=null,
  display_name='Former competitor',anonymized_at=now() where id=pg_temp.pid(17);
insert into private.account_blocks values(pg_temp.pid(1),pg_temp.pid(14),now()),(pg_temp.pid(15),pg_temp.pid(1),now());
-- Remove only 030's objects within this transaction, then replay the exact
-- migration against the preexisting fixture. No copied backfill implementation.
drop trigger purge_friends_on_block on private.account_blocks;
drop trigger purge_friends_on_profile_deactivation on public.profiles;
drop table private.friendships,private.friend_requests,private.profile_reports,private.people_search_limits;
alter table public.profiles drop column username,drop column show_in_search,drop column challenge_policy;
drop function private.are_friends(uuid, uuid);
drop function private.is_reserved_username(text);
drop function private.people_blocked(uuid, uuid);
drop function private.person_reachable(uuid, uuid);
drop function private.friend_relationship(uuid, uuid);
drop function private.friend_person(uuid, uuid);
drop function private.lock_friend_pair(uuid, uuid);
drop function private.wake_friend_profile(uuid);
drop function private.consume_people_search(uuid);
drop function public.get_friend_settings();
drop function public.set_username(text);
drop function public.username_available(text);
drop function public.update_friend_settings(boolean, text);
drop function public.search_people(text);
drop function public.list_friends();
drop function public.send_friend_request(uuid);
drop function public.respond_to_friend_request(uuid, boolean);
drop function public.remove_friend(uuid);
drop function public.block_profile(uuid);
drop function public.report_profile(uuid);
drop function private.purge_friends_on_block();
drop function private.purge_friends_on_profile_deactivation();
-- Supabase's pgTAP runner mounts test files only; migration history holds the
-- exact applied statements, so replay those rather than a copied SQL oracle.
do $$
declare statement text;
begin
  foreach statement in array (select statements from supabase_migrations.schema_migrations
    where version='20261109003000') loop
    execute statement;
  end loop;
end;
$$;
-- The replay also put that migration's older function bodies back for the
-- rest of this transaction: assert only on the backfill below, nothing that
-- invites, blocks or reads photos.
create temporary table fixture_people as select pg_temp.pid(n) as id from generate_series(1,20) n;
create temporary view fixture_friendships as select f.* from private.friendships f
  where f.profile_low in (select id from fixture_people) and f.profile_high in (select id from fixture_people);
select is((select count(*) from fixture_friendships),6::bigint,'backfill includes exactly six qualifying pairs');
select results_eq($$select case when profile_low=pg_temp.pid(1) then profile_high else profile_low end
  from fixture_friendships order by 1$$,
  $$select pg_temp.pid(n) from generate_series(2,7) n order by 1$$,
  'backfill all six lifecycles; excludes cancelled, pending, declined, expired, unaccepted, inactive, blocks both ways');
select ok(not exists(select 1 from private.friendships where pg_temp.pid(16) in(profile_low,profile_high)),
  'backfill excludes a pair whose lower-id profile is non-active');
select ok(not exists(select 1 from private.friendships where pg_temp.pid(17) in(profile_low,profile_high)),
  'backfill excludes an anonymized profile even with accepted participant history');
select ok(not exists(select 1 from private.friendships where pg_temp.pid(18) in(profile_low,profile_high)),
  'backfill excludes an anonymized participant even with an active profile');
select is((select count(*) from private.friendships
  where profile_low=least(pg_temp.pid(1),pg_temp.pid(2)) and profile_high=greatest(pg_temp.pid(1),pg_temp.pid(2))),
  1::bigint,'several qualifying and cancelled competitions produce exactly one friendship');
select ok(not exists(select 1 from private.friendships where pg_temp.pid(19) in(profile_low,profile_high)),
  'a pair with only pending and declined competitions is not backfilled');
select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',pg_temp.uid(1))::text,true);
set local role authenticated;
select is(public.remove_friend(pg_temp.pid(2)),'{"relationship":"none"}'::jsonb,'backfilled friendship removable');
select lives_ok($$select public.list_friends()$$,'listing does not rerun backfill');
reset role;
select ok(not private.are_friends(pg_temp.pid(1),pg_temp.pid(2)),'removed launch friend stays removed');
select * from finish();
rollback;
