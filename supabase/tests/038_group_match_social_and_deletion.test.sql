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
 result := (public.create_group_match(fmt,pg_temp.lineup(humans,case when fmt='three_way' then 3 else 4 end,fmt='doubles'),'UTC')->>'competition_id')::uuid;
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

select pg_temp.make_match('social','doubles',4);
select pg_temp.make_live(pg_temp.gid('social'),1);
select pg_temp.as_user(1);
select lives_ok($$select public.set_competition_reaction(pg_temp.gid('social'),1,'clap',pg_temp.pid(2))$$,'react to named partner day');
select lives_ok($$select public.set_competition_reaction(pg_temp.gid('social'),1,'fire',pg_temp.pid(3))$$,'also react to a different opponent day');
select is((select count(*) from private.competition_reactions where competition_id=pg_temp.gid('social')),2::bigint,'distinct targets coexist on one day');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('social'),1,'fire',pg_temp.pid(1))$$,'P0001','reaction_not_allowed','self reaction refused');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('social'),null,'fire',pg_temp.pid(2))$$,'22023','invalid_reaction','group reactions require a day');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('social'),1,'fire',pg_temp.pid(8))$$,'P0001','reaction_not_allowed','non-seat target refused');
select lives_ok($$select public.nudge_competition_participant(pg_temp.gid('social'),pg_temp.pid(2))$$,'doubles partner nudge');
select throws_ok($$select public.nudge_competition_participant(pg_temp.gid('social'),pg_temp.pid(3))$$,'P0001','nudge_not_allowed','opponent nudge refused');
select pg_temp.as_user(2); select public.leave_group_match(pg_temp.gid('social'));
update public.competitions set start_day=current_date-2 where id=pg_temp.gid('social');
select pg_temp.as_user(1);
select throws_ok($$select public.nudge_competition_participant(pg_temp.gid('social'),pg_temp.pid(2))$$,'P0001','nudge_not_allowed','left partner cannot be nudged');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('social'),3,'fire',pg_temp.pid(2))$$,'P0001','reaction_not_allowed','cannot react after target cutoff');
select pg_temp.as_user(2);
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('social'),1,'fire',pg_temp.pid(3))$$,'P0001','reaction_not_allowed','leaver cannot send reactions');
select pg_temp.make_match('ffa','three_way',2); select pg_temp.make_live(pg_temp.gid('ffa'),1);
select pg_temp.as_user(1);
select throws_ok($$select public.nudge_competition_participant(pg_temp.gid('ffa'),pg_temp.pid(2))$$,'P0002','competition_not_found','FFA has no nudge');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('ffa'),1,'fire',null)$$,'22023','invalid_reaction','bots have no target profile');
-- Old installations never receive group pushes, including already queued work.
update public.device_installations set supports_group_matches=false where profile_id=pg_temp.pid(3);

select set_config('request.jwt.claims','{"role":"service_role"}',true);
select public.lease_competition_notification_work(100,180);
select ok(not exists(select 1 from private.competition_notification_work w where w.recipient_profile_id=pg_temp.pid(3) and w.state='leased'),'lease refuses group work when capability removed');
update public.device_installations set supports_group_matches=true where profile_id=pg_temp.pid(3);
-- Pending lineup names come only from group RPCs; photo access has its own acceptance rule.
select pg_temp.as_user(1);
insert into gm values('photos',(public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(1)),
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(5)),
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(6))),'UTC')->>'competition_id')::uuid);
select pg_temp.as_user(5);
select ok(private.can_view_profile_photo(pg_temp.pid(1)),'pending invitee may see accepted creator photo');
select ok(not private.can_view_profile_photo(pg_temp.pid(6)),'pending seat photo remains hidden');
select ok(not private.can_view_profile(pg_temp.pid(3)),'groups do not widen old profile read policy');
insert into private.account_blocks values(pg_temp.pid(1),pg_temp.pid(6),now());
select throws_ok($$select public.preview_group_match(pg_temp.gid('photos'))$$,'P0001','group_match_unavailable','all-pairs block hides preview');
delete from private.account_blocks;
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('photos'));
-- Exercise the real deletion token state machine, not a hand-edited participant row.
select pg_temp.make_match('delete-pending');
select pg_temp.make_match('delete-scheduled'); select pg_temp.accept_all(pg_temp.gid('delete-scheduled'));
select pg_temp.make_match('delete-live','three_way',2); select pg_temp.make_live(pg_temp.gid('delete-live'),1);
select pg_temp.score(pg_temp.gid('delete-live'),1,1,1,25000);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into auth.identities(id,provider_id,user_id,identity_data,provider,created_at,updated_at)
  values(extensions.gen_random_uuid(),'group-test-apple',pg_temp.uid(1),'{"sub":"group-test-apple"}','apple',now(),now());
select public.begin_account_deletion(pg_temp.uid(1));
select public.store_account_deletion_apple_token(pg_temp.pid(1),'synthetic-apple-refresh-token-for-group-test','com.example.healthcomp');
select is((select lifecycle from public.competitions where id=pg_temp.gid('delete-pending')),'cancelled','account deletion before start closes match');
select is((select lifecycle from public.competitions where id=pg_temp.gid('delete-scheduled')),'cancelled','scheduled account deletion before day one closes match');
select ok((select lifecycle<>'cancelled' from public.competitions where id=pg_temp.gid('delete-live')),'deleting one live human preserves match for partner');
select ok((select left_at is not null and frozen_revisions[1]=1 from public.competition_participants where competition_id=pg_temp.gid('delete-live') and profile_id=pg_temp.pid(1)),'deletion uses same frozen bank');
select public.mark_account_deletion_apple_revoked(pg_temp.pid(1));
select public.anonymize_account_deletion(pg_temp.pid(1));
select ok((select state='anonymized' and left_at is not null from public.competition_participants where competition_id=pg_temp.gid('delete-live') and profile_id=pg_temp.pid(1)),'deleted human retains leave bank');
select pg_temp.as_user(2); select public.leave_group_match(pg_temp.gid('delete-live'));
select is(private.finalize_competition_locked(pg_temp.gid('delete-live'),now()+interval '8 days')->>'basis','stable','anonymized leaver still finalizes');
select is((select frozen_payload->'seats'->0->>'total_centi_points' from public.competition_group_results where competition_id=pg_temp.gid('delete-live')),'25000','anonymized bank remains in standings');
set constraints all immediate;
select * from finish(); rollback;
