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

-- Reconciled photos preserve friends/search/request access and group acceptance consent.
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(7),pg_temp.pid(8)),greatest(pg_temp.pid(7),pg_temp.pid(8)));
select pg_temp.as_user(7);
select ok(private.can_view_profile_photo(pg_temp.pid(8)),'friend photo without any shared match remains visible');
delete from private.friendships;
insert into private.friend_requests(sender_profile_id,recipient_profile_id) values(pg_temp.pid(8),pg_temp.pid(7));
select ok(private.can_view_profile_photo(pg_temp.pid(8)),'incoming friend-request photo remains visible');
update public.profiles set username='merge_person8',show_in_search=true where id=pg_temp.pid(8);
select pg_temp.as_user(6);
select ok(private.can_view_profile_photo(pg_temp.pid(8)),'public search photo remains visible');
select pg_temp.make_match('photo-group');
select pg_temp.as_user(2);
select ok(private.can_view_profile_photo(pg_temp.pid(1)),'pending group viewer sees accepted creator without a friendship');
select ok(not private.can_view_profile_photo(pg_temp.pid(3)),'pending group seat remains private without an existing relationship');
select pg_temp.as_user(3); select public.accept_group_match(pg_temp.gid('photo-group'));
select pg_temp.as_user(2);
select ok(private.can_view_profile_photo(pg_temp.pid(3)),'pending group viewer sees newly accepted seat');
insert into private.account_blocks(blocker_profile_id,blocked_profile_id) values(pg_temp.pid(2),pg_temp.pid(3));
select ok(not private.can_view_profile_photo(pg_temp.pid(3)),'group photo permission cannot bypass a block');
delete from private.account_blocks;

create function pg_temp.duel(sender integer,recipient integer,parent uuid default null) returns uuid language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 return public.create_competition_invite(extensions.digest(extensions.gen_random_uuid()::text,'sha256'),'UTC',parent,pg_temp.uid(sender),extensions.gen_random_uuid(),1::smallint,pg_temp.pid(recipient));
end; $$;
update public.profiles set username='merge_person5',challenge_policy='friends_only' where id=pg_temp.pid(5);
select throws_ok($$select pg_temp.duel(4,5)$$,'P0001','recipient_unavailable','duel helper preserves friends-only admission');
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(4),pg_temp.pid(5)),greatest(pg_temp.pid(4),pg_temp.pid(5)));
select lives_ok($$select pg_temp.duel(4,5)$$,'duel helper permits friends without prior matches');
select pg_temp.make_match('group-parent'); select pg_temp.accept_all(pg_temp.gid('group-parent'));
update public.competitions set lifecycle='completed' where id=pg_temp.gid('group-parent');
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(1),pg_temp.pid(2)),greatest(pg_temp.pid(1),pg_temp.pid(2)));
update public.profiles set challenge_policy='friends_only' where id=pg_temp.pid(2);
select throws_ok($$select pg_temp.duel(1,2,pg_temp.gid('group-parent'))$$,'42501','rematch_not_allowed','friend admission cannot turn a group into a duel rematch parent');
insert into gm values('duel-parent',extensions.gen_random_uuid());
insert into public.competitions(id,creator_profile_id,invited_profile_id,lifecycle,time_zone_identifier,start_day,invitation_expires_at,best_available_deadline,scoring_policy_identity)
 values(pg_temp.gid('duel-parent'),pg_temp.pid(1),pg_temp.pid(2),'completed','UTC',current_date-10,now()-interval '20 days',now()+interval '1 day','healthcomp.activity-score.v1');
insert into public.competition_participants(competition_id,profile_id,role,state) values
 (pg_temp.gid('duel-parent'),pg_temp.pid(1),'creator','accepted'),(pg_temp.gid('duel-parent'),pg_temp.pid(2),'invitee','accepted');
select lives_ok($$select pg_temp.duel(1,2,pg_temp.gid('duel-parent'))$$,'friends-only duel rematch still permitted with a duel parent');

create function pg_temp.named_group(code text default null) returns jsonb language plpgsql as $$
begin
 perform pg_temp.as_user(4);
 return public.create_group_match('three_way',jsonb_build_array(
  jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),
  case when code is null then jsonb_build_object('kind','human','profile_id',pg_temp.pid(6))
    else jsonb_build_object('kind','human','challenge_link_code',code) end,
  jsonb_build_object('kind','bot','bot_mode','pacer')),'UTC',extensions.gen_random_uuid());
end; $$;
update public.profiles set username='merge_person6',challenge_policy='friends_only' where id=pg_temp.pid(6);
update public.device_installations set supports_group_matches=false where profile_id=pg_temp.pid(6);
select throws_ok($$select pg_temp.named_group()$$,'P0001','recipient_unavailable','named group friends-only check precedes capability disclosure');
update public.profiles set challenge_policy='friends_and_link' where id=pg_temp.pid(6);
select throws_ok($$select pg_temp.named_group()$$,'P0001','recipient_unavailable','a newly discovered username is not a direct-invite credential');
select pg_temp.as_user(6);
create temporary table group_link(code text);
insert into group_link select public.get_my_challenge_link()->>'code';
select throws_ok($$select pg_temp.named_group((select code from group_link))$$,'P0001','group_update_required','current links admit nonfriends, then check capability');
update public.device_installations set supports_group_matches=true where profile_id=pg_temp.pid(6);
select lives_ok($$select pg_temp.named_group((select code from group_link))$$,'group nonfriend can join through a current challenge link');
update public.profiles set challenge_policy='friends_only' where id=pg_temp.pid(6);
select throws_ok($$select pg_temp.named_group()$$,'P0001','recipient_unavailable','friends-only policy still applies with shared match history');
insert into private.friendships(profile_low,profile_high) values(least(pg_temp.pid(4),pg_temp.pid(6)),greatest(pg_temp.pid(4),pg_temp.pid(6)));
select lives_ok($$select pg_temp.named_group()$$,'group friend can be named directly under friends-only policy');
select pg_temp.as_user(6); select public.reset_my_challenge_link();
select lives_ok($$select pg_temp.named_group()$$,'friendship bypasses reset-link history for group admission as it does for duels');
set constraints all immediate;
select * from finish(); rollback;
