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

select pg_temp.make_match('leave','three_way',2);
select pg_temp.make_live(pg_temp.gid('leave'));
select is(pg_temp.score(pg_temp.gid('leave'),1,1,1)->>'disposition','appended','human uses existing score wire');
select pg_temp.as_user(1);
select is(public.leave_group_match(pg_temp.gid('leave'))->'accepted_revisions','["1","0","0","0","0","0","0"]'::jsonb,'leave seals accepted heads, including missing days');
select is(pg_temp.score(pg_temp.gid('leave'),1,1,1)->>'disposition','duplicate','exact pre-leave retry keeps original receipt');
select is(pg_temp.score(pg_temp.gid('leave'),1,1,2)->>'disposition','rejected','new revisions after leave refused');
select lives_ok($$select public.leave_group_match(pg_temp.gid('leave'))$$,'leave retry idempotent');
select ok(private.finalize_competition_locked(pg_temp.gid('leave'),now()) is null,'never finalizes before seven days');
select pg_temp.as_user(2);
select public.leave_group_match(pg_temp.gid('leave'));
select ok(private.finalize_competition_locked(pg_temp.gid('leave'),now()) is null,'all left still waits seven days');
select is(private.finalize_competition_locked(pg_temp.gid('leave'),now()+interval '8 days')->>'basis','stable','all-left freezes after day seven without attestations');
select is((select count(*) from public.competition_results where competition_id=pg_temp.gid('leave')),0::bigint,'two humans plus bot never produces duel result');
select is((select count(*) from public.competition_awards where competition_id=pg_temp.gid('leave')),0::bigint,'group gives no awards');
select is(private.finalize_competition_locked(pg_temp.gid('leave'),now()+interval '8 days')->>'disposition','existing','finalization retry returns stored result');
select is((select frozen_payload->'seats'->0->>'total_centi_points' from public.competition_group_results where competition_id=pg_temp.gid('leave')),'30000','leaver points banked');
select ok((select immutable_hash=extensions.digest(convert_to('healthcomp-group-result-v1','UTF8')||decode('00','hex')||convert_to(frozen_payload::text,'UTF8'),'sha256') from public.competition_group_results where competition_id=pg_temp.gid('leave')),'hash binds canonical payload and new domain');
select is((select frozen_payload->'seats'->0->'window'->'days'->6->>'status' from public.competition_group_results where competition_id=pg_temp.gid('leave')),'afterLeave','later days are resolved zero after leave');
select throws_ok($$update public.competition_group_results set standings='[]' where competition_id=pg_temp.gid('leave')$$,'55000','competition_group_results is append-only','frozen group results immutable');

-- 3/4 humans, two humans+bots, partial leave and doubles all dispatch through shared finalizer.
create function pg_temp.finalize_case(label text,fmt text,humans integer,partial_leave boolean default false) returns setof text language plpgsql as $$
declare cid uuid; n integer; d integer; revs bigint[]; com text; result jsonb;
begin
 cid:=pg_temp.make_match(label,fmt,humans); perform pg_temp.make_live(cid,8);
 for n in 1..humans loop
   for d in 1..7 loop perform pg_temp.score(cid,n,d,d,case when n<=2 then 30000 else 10000 end); end loop;
 end loop;
 if partial_leave then perform pg_temp.as_user(1); perform public.leave_group_match(cid); end if;
 return next ok(private.finalize_competition_locked(cid,now()) is null,label||': waits for stable attestations before deadline');
 for n in 1..humans loop
  if not (partial_leave and n=1) then
   perform pg_temp.as_user(n); revs:=private.latest_revision_vector(cid,pg_temp.pid(n));
   com:=encode(private.owner_window_commitment_v1(cid,pg_temp.pid(n),revs),'hex');
   result:=public.attest_final_window(cid,md5(label||n)::uuid,1,'stable',revs,com);
   return next is(result->>'disposition','appended',label||': accepts human attestation '||n);
  end if;
 end loop;
 return next is((select finalization_basis from public.competition_group_results where competition_id=cid),'stable',label||': group finalized stable');
 return next is((select count(*) from public.competition_results where competition_id=cid),0::bigint,label||': no duel result');
 return next is((select count(*) from public.competition_awards where competition_id=cid),0::bigint,label||': no awards');
end; $$;
select * from pg_temp.finalize_case('three','three_way',3);
select is((select standings->0->>'place' from public.competition_group_results where competition_id=pg_temp.gid('three')),'1','tie first');
select is((select standings->1->>'place' from public.competition_group_results where competition_id=pg_temp.gid('three')),'1','tie shares first');
select is((select standings->2->>'place' from public.competition_group_results where competition_id=pg_temp.gid('three')),'3','competition ranking 1,1,3');
select is(pg_temp.score(pg_temp.gid('three'),1,7,8)->>'code','competition_terminal','new score after group finalization refused');
select * from pg_temp.finalize_case('four','four_way',4);
select * from pg_temp.finalize_case('bot-final','four_way',2);
select * from pg_temp.finalize_case('partial','three_way',3,true);
select * from pg_temp.finalize_case('doubles','doubles',4);
select is((select max((s->>'centipoints')::integer) from public.competition_group_results r,jsonb_array_elements(r.standings) s where competition_id=pg_temp.gid('doubles')),420000,'doubles adds partner scores once');
select pg_temp.make_match('deadline');
select pg_temp.make_live(pg_temp.gid('deadline'),10);
select is(private.finalize_competition_locked(pg_temp.gid('deadline'),now())->>'basis','best_available','deadline falls back with missing days');
select is((select standings->0->>'centipoints' from public.competition_group_results where competition_id=pg_temp.gid('deadline')),'0','missing fallback scores zero');
select is((select count(*) from public.competition_group_results),7::bigint,'one group result per case');
select ok((select bool_and(r.server_seq>0 and exists(select 1 from public.competition_change_log l where l.competition_id=r.competition_id and l.server_seq=r.server_seq and l.change_kind='group_result_confirmed')) from public.competition_group_results r),'results allocated in shared sequence with new change kind');
set constraints all immediate;
select * from finish(); rollback;
