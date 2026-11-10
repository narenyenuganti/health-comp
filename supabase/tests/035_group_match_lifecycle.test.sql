begin;
-- Included inside each group test transaction; no product fixture state persists.
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();
create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('group-profile-' || n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('group-auth-' || n)::uuid $$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,8) n;
insert into public.profiles(id,auth_user_id,display_name,state)
  select pg_temp.pid(n),pg_temp.uid(n),'Player ' || n,'active' from generate_series(1,8) n;
insert into public.device_installations(profile_id,installation_id,apns_token,environment,state,supports_challenges,supports_reactions,supports_group_matches)
  select pg_temp.pid(n),md5('group-install-' || n)::uuid,md5('group-token-' || n) || md5('group-token-' || n),'sandbox','active',true,true,true from generate_series(1,8) n;
create temporary table gm(label text primary key,id uuid);
grant all on gm to authenticated;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text,true);
$$;
create function pg_temp.gid(key text) returns uuid language sql as $$ select id from gm where label = key $$;
create function pg_temp.lineup(humans integer, seats integer, doubles boolean default false) returns jsonb language sql as $$
 select jsonb_agg(case when n <= humans then jsonb_build_object('kind','human','profile_id',pg_temp.pid(n))
   else jsonb_build_object('kind','bot','bot_mode','pacer') end || case when doubles then jsonb_build_object('team_number',case when n<=2 then 1 else 2 end) else '{}'::jsonb end order by n)
 from generate_series(1,seats) n;
$$;
create function pg_temp.make_match(label text,fmt text default 'three_way',humans integer default 3) returns uuid language plpgsql as $$
declare result uuid;
begin
 perform pg_temp.as_user(1);
 result := (public.create_group_match(fmt,pg_temp.lineup(humans,case when fmt='three_way' then 3 else 4 end,fmt='doubles'),'UTC',extensions.gen_random_uuid())->>'competition_id')::uuid;
 insert into gm values(label,result);
 return result;
end; $$;
create function pg_temp.accept_all(cid uuid) returns void language plpgsql as $$
begin
 for n in 2..4 loop
  if exists(select 1 from public.competition_participants where competition_id=cid and profile_id=pg_temp.pid(n)) then
   perform pg_temp.as_user(n); perform public.accept_group_match(cid);
  end if;
 end loop;
 perform pg_temp.as_user(1);
end; $$;
create function pg_temp.make_live(cid uuid,days_ago integer default 1) returns void language plpgsql as $$
begin
 perform pg_temp.accept_all(cid);
 update public.competitions set start_day=current_date-days_ago,invitation_expires_at=now()-interval '20 days',
   best_available_deadline=(current_date-days_ago+9)::timestamp at time zone 'UTC' where id=cid;
end; $$;
-- Real submission path: fixed semantic identity and evaluation time allow exact replay.
create function pg_temp.score(cid uuid,person integer,day integer,rev bigint,points integer default 30000) returns jsonb language plpgsql as $$
declare evaluated timestamptz; d text;
begin
 perform pg_temp.as_user(person);
 select (start_day + day - 1)::timestamp at time zone time_zone_identifier into evaluated from public.competitions where id=cid;
 d:=encode(private.wire_score_digest_v1(cid,pg_temp.pid(person),day::smallint,'activeEnergyKilocalories','standHours',
   least(points,20000),greatest(points-20000,0),0,points,'available','healthcomp.activity-score.v1',rev),'hex');
 return public.submit_score_revision(cid,md5(cid::text||person||day||rev)::uuid,day,rev,evaluated,'activeEnergyKilocalories','standHours',
   least(points,20000),greatest(points-20000,0),0,'available','healthcomp.activity-score.v1',d);
end; $$;

select pg_temp.as_user(1);
select throws_ok($$select public.create_group_match('three_way',pg_temp.lineup(1,3),'UTC',extensions.gen_random_uuid())$$,'22023','invalid_group_match','one human plus bots stays practice');
update public.device_installations set supports_group_matches=false where profile_id=pg_temp.pid(3);
select throws_ok($$select public.create_group_match('three_way',pg_temp.lineup(3,3),'UTC',extensions.gen_random_uuid())$$,'P0001','group_update_required','old-only named installation refused');
insert into private.account_blocks values(pg_temp.pid(2),pg_temp.pid(3),now());
select throws_ok($$select public.create_group_match('three_way',pg_temp.lineup(3,3),'UTC',extensions.gen_random_uuid())$$,'P0001','recipient_unavailable','all-pairs block checked before capability (no update oracle)');
delete from private.account_blocks;
update public.profiles set state='deleting' where id=pg_temp.pid(3);
select throws_ok($$select public.create_group_match('three_way',pg_temp.lineup(3,3),'UTC',extensions.gen_random_uuid())$$,'P0001','recipient_unavailable','inactive profile checked before capability');
update public.profiles set state='active' where id=pg_temp.pid(3);
update public.device_installations set supports_group_matches=true where profile_id=pg_temp.pid(3);
select pg_temp.make_match('lobby');
select is((select lifecycle from public.competitions where id=pg_temp.gid('lobby')),'pending','creator accepted but lobby pending');
select pg_temp.as_user(2);
select is(public.accept_group_match(pg_temp.gid('lobby'))->>'state','pending','first accept does not schedule');
select ok((select consumed_at is null and claimed_profile_id is null from public.competition_invites where competition_id=pg_temp.gid('lobby')),'shared invite remains unconsumed');
select pg_temp.as_user(3);
select is(public.accept_group_match(pg_temp.gid('lobby'))->>'state','scheduled','last accept schedules');
select is((select start_day from public.competitions where id=pg_temp.gid('lobby')),current_date+1,'next local day');
select ok((select consumed_at is not null from public.competition_invites where competition_id=pg_temp.gid('lobby')),'only last accept consumes invite');
select lives_ok($$select public.accept_group_match(pg_temp.gid('lobby'))$$,'accept retry idempotent');
select lives_ok($$select public.decline_group_match(pg_temp.gid('lobby'))$$,'accepted seat can withdraw before day one');
select is((select lifecycle from public.competitions where id=pg_temp.gid('lobby')),'declined','withdraw closes entire match');
select pg_temp.make_match('bot','four_way',2);
select ok((select bool_and(bot_daily_totals is null) from public.competition_seats where competition_id=pg_temp.gid('bot') and kind='bot'),'no fixed bot week before last human accept');
select pg_temp.accept_all(pg_temp.gid('bot'));
select ok((select bool_and(cardinality(bot_daily_totals)=7 and bot_baseline=300 and bot_generator_version=1 and bot_seed::numeric between 0 and 18446744073709551615) from public.competition_seats where competition_id=pg_temp.gid('bot') and kind='bot'),'last accept fixes seven-point weeks and baseline');
select pg_temp.as_user(1);
select lives_ok($$select public.cancel_group_match(pg_temp.gid('bot'))$$,'creator cancels before day one');
select is((select count(*) from private.competition_notification_work where competition_id=pg_temp.gid('bot') and kind='match_cancelled'),1::bigint,'cancel notifies every other human');
select pg_temp.make_match('decline');
select pg_temp.as_user(2);
select lives_ok($$select public.decline_group_match(pg_temp.gid('decline'))$$,'pending person declines');
select pg_temp.make_match('blocked');
insert into private.account_blocks values(pg_temp.pid(2),pg_temp.pid(3),now());
select pg_temp.as_user(2);
select throws_ok($$select public.accept_group_match(pg_temp.gid('blocked'))$$,'P0001','group_match_unavailable','accept rechecks blocks between other seats');
select ok(not exists(select 1 from jsonb_array_elements(public.list_group_matches()->'matches') m where m->>'competition_id'=pg_temp.gid('blocked')::text),'blocked pending lineup hidden');
delete from private.account_blocks;
select lives_ok($$select public.block_challenger(pg_temp.gid('blocked'))$$,'group invitee can block creator');
select is((select lifecycle from public.competitions where id=pg_temp.gid('blocked')),'declined','blocking closes group');
delete from private.account_blocks;
select pg_temp.make_match('expire');
update public.competitions set invitation_expires_at=now()-interval '1 second' where id=pg_temp.gid('expire');
update public.competition_invites set created_at=now()-interval '2 days',expires_at=now()-interval '1 second' where competition_id=pg_temp.gid('expire');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select public.cleanup_expired_competition_invites();
select is((select lifecycle from public.competitions where id=pg_temp.gid('expire')),'expired','unanswered group expires');
select pg_temp.as_user(1);
select pg_temp.make_match('limit-'||n) from generate_series(1,5) n;
select throws_ok($$select pg_temp.make_match('sixth')$$,'P0001','group_creation_limit','sixth pending/live creation refused');
update public.competitions set invitation_expires_at=now()-interval '1 second' where id=pg_temp.gid('limit-1');
select lives_ok($$select pg_temp.make_match('after-expiry')$$,'expired pending matches do not consume limit');
select ok((select bool_and(not has_table_privilege('authenticated',oid,'select')) from pg_class where oid in ('public.competition_seats'::regclass,'public.competition_group_results'::regclass)),'new tables have no direct client grants');
set constraints all immediate;
select * from finish();
rollback;
