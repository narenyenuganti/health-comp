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

select pg_temp.make_match('group','three_way',2);
select pg_temp.make_live(pg_temp.gid('group'));
select pg_temp.score(pg_temp.gid('group'),1,1,1);
select public.set_competition_reaction(pg_temp.gid('group'),1,'clap',pg_temp.pid(2));
insert into public.participant_finalization_attestations(competition_id,participant_profile_id,basis,window_commitment_sha256,accepted_revisions,server_seq,semantic_event_id,attestation_version,attested_at)
 values(pg_temp.gid('group'),pg_temp.pid(1),'best_available',private.owner_window_commitment_v1(pg_temp.gid('group'),pg_temp.pid(1),array[1,0,0,0,0,0,0]::bigint[]),array[1,0,0,0,0,0,0],1,'isolation-attestation',1,now());
select pg_temp.make_match('finished-group','three_way',2); select pg_temp.make_live(pg_temp.gid('finished-group'));
select pg_temp.as_user(1); select public.leave_group_match(pg_temp.gid('finished-group'));
select pg_temp.as_user(2); select public.leave_group_match(pg_temp.gid('finished-group'));
select private.finalize_competition_locked(pg_temp.gid('finished-group'),now()+interval '8 days');
insert into gm values('duel',md5('isolation-duel')::uuid);
insert into public.competitions(id,creator_profile_id,invited_profile_id,lifecycle,time_zone_identifier,start_day,best_available_deadline,invitation_expires_at,scoring_policy_identity)
values(pg_temp.gid('duel'),pg_temp.pid(1),pg_temp.pid(2),'scheduled','UTC',current_date-1,now()+interval '9 days',now()-interval '1 day','healthcomp.activity-score.v1');
insert into public.competition_participants(competition_id,profile_id,role,state) values
 (pg_temp.gid('duel'),pg_temp.pid(1),'creator','accepted'),(pg_temp.gid('duel'),pg_temp.pid(2),'invitee','accepted');
select pg_temp.score(pg_temp.gid('duel'),1,1,1);
select pg_temp.as_user(1);
set local role authenticated;
select results_eq($$select id from public.competitions order by id$$,$$select pg_temp.gid('duel')$$,'old direct competitions read sees duel only');
select is((select count(*) from public.competition_participants),2::bigint,'old participants read sees two duel rows');
select is((select count(*) from public.daily_score_revisions),1::bigint,'old score select hides group score');
select is((select count(*) from public.participant_finalization_attestations),0::bigint,'old attestation select excludes groups');
select is((select count(*) from public.competition_results),0::bigint,'old results select safe');
select is((select count(*) from public.competition_awards),0::bigint,'old awards select safe');
select throws_ok($$select public.fetch_competition_changes(pg_temp.gid('group'),0,100)$$,'P0002','competition_not_found','old change feed refuses groups');
select throws_ok($$select public.archive_competition(pg_temp.gid('group'))$$,'42501','archive_not_allowed','old archive refuses group');
select throws_ok($$select public.cancel_competition(pg_temp.gid('group'))$$,'P0001',null,'old cancel refuses group');
select throws_ok($$select public.nudge_competition_participant(pg_temp.gid('group'))$$,'P0002','competition_not_found','old nudge refuses group');
select throws_ok($$select public.set_competition_reaction(pg_temp.gid('group'),1,'clap')$$,'P0001','reaction_not_allowed','old reaction refuses group');
select is(public.list_competition_reactions()->'reactions','[]'::jsonb,'legacy reaction list excludes groups');
select ok(jsonb_array_length(public.list_group_matches()->'matches')=2,'new group read sees group only');
select ok((public.preview_group_match(pg_temp.gid('group'))->'owner'->>'revision_high_water')='1','new projection returns authoritative owner revision');
reset role;
select pg_temp.make_match('pending');
select pg_temp.as_user(2);
set local role authenticated;
select throws_ok($$select public.accept_competition_challenge(pg_temp.gid('pending'))$$,'P0001',null,'old accept refuses group');
select throws_ok($$select public.decline_competition_challenge(pg_temp.gid('pending'))$$,'P0001',null,'old decline refuses group');
select is(public.list_challenges()->'incoming','[]'::jsonb,'old incoming challenges excludes pending group');
reset role;
-- Token RPCs still require authentication and reject group invites, even with their exact digest.
create temporary table tokens(token bytea);
insert into tokens select token_digest from public.competition_invites where competition_id=pg_temp.gid('pending');
grant select on tokens to authenticated;
set local role authenticated;
select throws_ok($$select public.preview_competition_invite((select token from tokens))$$,'P0001','invite_unavailable','old invite preview hides group');
select throws_ok($$select public.claim_competition_invite((select token from tokens))$$,'P0001','invite_unavailable','old claim hides group');
select public.decline_group_match(pg_temp.gid('pending'));
select pg_temp.as_user(1);
select is(public.list_challenges()->'closed','[]'::jsonb,'old closed challenge list excludes declined group');
reset role;
select ok(private.match_in_progress_between(pg_temp.pid(1),pg_temp.pid(2))=pg_temp.gid('duel'),'group does not interfere with duel overlap guard');
-- Install capability can turn off safely through the historical registration overload.
select pg_temp.as_user(2);
select public.register_current_device_installation(md5('group-install-2')::uuid,md5('group-token-2')||md5('group-token-2'),'sandbox',true,true,'{}'::text[],true);
select ok((select supports_group_matches from public.device_installations where profile_id=pg_temp.pid(2)),'new overload stores capability');
select public.register_current_device_installation(md5('group-install-2')::uuid,md5('group-token-2')||md5('group-token-2'),'sandbox',true,true,'{}'::text[]);
select ok((select not supports_group_matches from public.device_installations where profile_id=pg_temp.pid(2)),'old registration resets capability false');
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select throws_ok($$select public.create_competition_invite(decode(repeat('e1',32),'hex'),'UTC',pg_temp.gid('finished-group'),pg_temp.uid(1),extensions.gen_random_uuid(),1::smallint,pg_temp.pid(2))$$,
 '42501','rematch_not_allowed','recipient-bound duel cannot rematch a group result');
select throws_ok($$select public.create_competition_invite(decode(repeat('e2',32),'hex'),'UTC',pg_temp.gid('finished-group'),pg_temp.uid(1),extensions.gen_random_uuid(),1::smallint)$$,
 '42501','rematch_not_allowed','legacy unbound duel cannot rematch a group result');
set constraints all immediate;
select * from finish(); rollback;
