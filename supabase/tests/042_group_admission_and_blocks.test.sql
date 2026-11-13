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

create function pg_temp.duel(sender integer,recipient integer) returns uuid language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 return public.create_competition_invite(extensions.digest(extensions.gen_random_uuid()::text,'sha256'),'UTC',null,pg_temp.uid(sender),extensions.gen_random_uuid(),1::smallint,pg_temp.pid(recipient));
end; $$;
create function pg_temp.pair(sender integer,recipient integer) returns jsonb language plpgsql as $$
begin
 perform pg_temp.as_user(sender);
 return public.create_group_match('three_way',jsonb_build_array(
  jsonb_build_object('kind','human','profile_id',pg_temp.pid(sender)),
  jsonb_build_object('kind','human','profile_id',pg_temp.pid(recipient)),
  jsonb_build_object('kind','bot','bot_mode','pacer')),'UTC',extensions.gen_random_uuid());
end; $$;
create function pg_temp.refuse_pair() returns setof text language plpgsql as $$
begin
 perform pg_temp.as_user(2);
 return next throws_ok('select public.resolve_invitation_recipient(pg_temp.pid(3))','P0001','recipient_unavailable','co-invitee cannot resolve a username by id');
 return next throws_ok('select pg_temp.duel(2,3)','P0001','recipient_unavailable','co-invitee cannot create a duel by id');
 return next throws_ok('select pg_temp.pair(2,3)','P0001','recipient_unavailable','co-invitee cannot create another group by id');
end; $$;
update public.profiles set username='sv3_target',show_in_search=false where id=pg_temp.pid(3);
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(1),pg_temp.pid(3)),greatest(pg_temp.pid(1),pg_temp.pid(3)));
select pg_temp.make_match('third-party');
select * from pg_temp.refuse_pair();
select pg_temp.as_user(2); select public.accept_group_match(pg_temp.gid('third-party'));
select pg_temp.as_user(3); select public.decline_group_match(pg_temp.gid('third-party')); select public.reset_my_challenge_link();
select * from pg_temp.refuse_pair();
select pg_temp.make_match('partial','four_way',4);
select pg_temp.as_user(2); select public.accept_group_match(pg_temp.gid('partial'));
select pg_temp.as_user(3); select public.accept_group_match(pg_temp.gid('partial'));
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('partial'));
select * from pg_temp.refuse_pair();
select ok(not private.person_reachable(pg_temp.pid(2),pg_temp.pid(3)),'unstarted co-acceptance does not make co-invitees reachable after cancellation');
select pg_temp.make_match('consented'); select pg_temp.accept_all(pg_temp.gid('consented'));
select pg_temp.as_user(2);
select lives_ok($$select public.resolve_invitation_recipient(pg_temp.pid(3))$$,'fully accepted scheduled peers retain direct history');
select lives_ok($$select pg_temp.duel(2,3)$$,'scheduled group peers may create duels');
select lives_ok($$select pg_temp.pair(2,3)$$,'scheduled group peers may create groups');
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('consented'));

-- A block through the general friends API closes all five groups and frees the creator's quota.
select pg_temp.make_match('quota-'||n) from generate_series(1,5) n;
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(1),pg_temp.pid(2)),greatest(pg_temp.pid(1),pg_temp.pid(2)));
select pg_temp.as_user(2);
select lives_ok($$select public.block_profile(pg_temp.pid(1))$$,'friends block API accepts a reachable creator');
select is((select count(*) from public.competitions c join gm on gm.id=c.id where gm.label like 'quota-%' and c.lifecycle='declined'),5::bigint,'blocking closes every pending group between the pair');
select is((select count(*) from private.competition_notification_work w join gm on gm.id=w.competition_id where gm.label like 'quota-%' and w.kind='challenge_declined'),10::bigint,'every other human receives the closure notification');
select lives_ok($$select pg_temp.pair(1,4)$$,'hidden blocked matches no longer consume the five-match quota');

insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(5),pg_temp.pid(6)),greatest(pg_temp.pid(5),pg_temp.pid(6)));
insert into gm values('creator-block',(pg_temp.pair(5,6)->>'competition_id')::uuid);
select pg_temp.as_user(5); select lives_ok($$select public.block_profile(pg_temp.pid(6))$$,'creator can block an invitee');
select is((select lifecycle from public.competitions where id=pg_temp.gid('creator-block')),'cancelled','creator block cancels own pending group');
select is((select count(*) from private.competition_notification_work where competition_id=pg_temp.gid('creator-block') and kind='match_cancelled'),1::bigint,'creator cancellation notifies its human invitee');

-- Co-invitee blocks must close the third party's pending match but preserve a scheduled match.
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(4),pg_temp.pid(5)),greatest(pg_temp.pid(4),pg_temp.pid(5)));
-- Player 3 met 4 only in player 1's lineup, which is no challenge credential.
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(3),pg_temp.pid(4)),greatest(pg_temp.pid(3),pg_temp.pid(4))),
  (least(pg_temp.pid(3),pg_temp.pid(5)),greatest(pg_temp.pid(3),pg_temp.pid(5)));
select pg_temp.as_user(3);
insert into gm values('co-block',(public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(3)),jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),jsonb_build_object('kind','human','profile_id',pg_temp.pid(5))),'UTC',extensions.gen_random_uuid())->>'competition_id')::uuid);
insert into gm values('co-scheduled',(public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(3)),jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),jsonb_build_object('kind','human','profile_id',pg_temp.pid(5))),'UTC',extensions.gen_random_uuid())->>'competition_id')::uuid);
select pg_temp.as_user(4); select public.accept_group_match(pg_temp.gid('co-scheduled'));
select pg_temp.as_user(5); select public.accept_group_match(pg_temp.gid('co-scheduled'));
select pg_temp.as_user(4); select lives_ok($$select public.block_profile(pg_temp.pid(5))$$,'co-invitee can block a reachable peer');
select is((select lifecycle from public.competitions where id=pg_temp.gid('co-block')),'declined','co-invitee block closes third-party pending match');
select is((select lifecycle from public.competitions where id=pg_temp.gid('co-scheduled')),'scheduled','general block does not cancel a scheduled group');

-- A hidden creator is directly reachable by their own named invitee, just as in duels.
insert into gm values('hidden-creator',(pg_temp.pair(7,8)->>'competition_id')::uuid);
select pg_temp.as_user(8);
select ok(private.person_reachable(pg_temp.pid(8),pg_temp.pid(7)),'pending invitee can reach their hidden creator');
select lives_ok($$select public.report_profile(pg_temp.pid(7))$$,'pending invitee can report hidden creator');
select lives_ok($$select public.send_friend_request(pg_temp.pid(7))$$,'pending invitee can request friendship with hidden creator');
select lives_ok($$select public.block_profile(pg_temp.pid(7))$$,'pending invitee can block hidden creator');
set constraints all immediate;
select * from finish(); rollback;
