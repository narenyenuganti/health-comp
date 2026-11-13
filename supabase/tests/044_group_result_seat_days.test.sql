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
   case when points is not null then least(points,20000) end,case when points is not null then greatest(points-20000,0) end,case when points is not null then 0 end,points,case when points is null then 'sourceDataUnavailable' else 'available' end,'healthcomp.activity-score.v1',rev),'hex');
 return public.submit_score_revision(cid,md5(cid::text||person||day||rev)::uuid,day,rev,evaluated,'activeEnergyKilocalories','standHours',
   case when points is not null then least(points,20000) end,case when points is not null then greatest(points-20000,0) end,case when points is not null then 0 end,case when points is null then 'sourceDataUnavailable' else 'available' end,'healthcomp.activity-score.v1',d);
end; $$;

-- A four-way has available zero, accepted unavailable, missing, after-leave and bot days.
select pg_temp.make_match('four','four_way',3);
select pg_temp.as_user(1);
select is(public.preview_group_match(pg_temp.gid('four'))->'result','null'::jsonb,'unfinished result stays null');
select pg_temp.make_live(pg_temp.gid('four'));
update public.competition_seats set bot_daily_totals=array[0,100,200,300,400,500,600] where competition_id=pg_temp.gid('four') and kind='bot';
select is(pg_temp.score(pg_temp.gid('four'),1,1,1,12345)->>'disposition','appended','leaver has a fractional point score');
select is(pg_temp.score(pg_temp.gid('four'),1,2,2,0)->>'disposition','appended','accepted zero stays available');
select pg_temp.as_user(1); select public.leave_group_match(pg_temp.gid('four'));
select is(pg_temp.score(pg_temp.gid('four'),2,1,1,30000)->>'disposition','appended','active human score accepted');
select is(pg_temp.score(pg_temp.gid('four'),2,2,2,null)->>'disposition','appended','unavailable human score accepted');
select is(private.finalize_competition_locked(pg_temp.gid('four'),now()+interval '10 days')->>'basis','best_available','four-way finalized with leaver and missing days');

-- Doubles keeps the team standings and individual weekly/day totals separately.
select pg_temp.make_match('doubles','doubles',3);
select pg_temp.make_live(pg_temp.gid('doubles'),8);
update public.competition_seats set bot_daily_totals=array[100,100,100,100,100,100,100] where competition_id=pg_temp.gid('doubles') and kind='bot';
select pg_temp.score(pg_temp.gid('doubles'),n,d,d,n*10000) from generate_series(1,3) n,generate_series(1,7) d;
select is(private.finalize_competition_locked(pg_temp.gid('doubles'),now()+interval '2 days')->>'basis','best_available','doubles finalized');
create temporary table stored_results as select * from public.competition_group_results;
-- A later change to live bot inputs cannot change a finished result projection.
update public.competition_seats set bot_daily_totals=array[0,0,0,0,0,0,0] where kind='bot';
select pg_temp.as_user(1);
set local role authenticated;
create temporary table read_models as select m as match from jsonb_array_elements(public.list_group_matches()->'matches') m;
select is(public.list_group_matches()->'version','1'::jsonb,'list version unchanged');
select ok((select bool_and(match->'version'='1'::jsonb) from read_models),'match versions unchanged');
select is((select array_agg(k order by k) from jsonb_object_keys(public.list_group_matches()) k),array['matches','version'],'exact list envelope keys unchanged');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(match) k)=array[
 'best_available_deadline','closed_at','closed_by_profile_id','competition_id','creator_profile_id','format','invitation_expires_at',
 'lifecycle','owner','reactions','result','scoring_policy_identity','seats','server_version','start_day','time_zone_identifier','version']) from read_models),'exact match keys unchanged');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(match->'result') k)=array[
 'competition_id','completed_at','finalization_basis','format','immutable_hash','seats','server_seq','standings','version']) from read_models),'exact result keys add only seats and version, never frozen payload');
select ok((select bool_and(match->'result'->'version'='1'::jsonb) from read_models),'frozen seat projection version is 1');
select ok((select bool_and(jsonb_typeof(match->'result'->'server_seq')='string') from read_models),'result cursor stays a decimal string');
select ok((select bool_and(jsonb_array_length(match->'result'->'seats')=4) from read_models),'all four finished seats returned');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(s) k)=array['days','seat_index','total_centi_points'])
 from read_models,jsonb_array_elements(match->'result'->'seats') s),'exact frozen seat keys exclude commitments and accepted rows');
select ok((select bool_and((s->>'seat_index')::integer=ord) from read_models,jsonb_array_elements(match->'result'->'seats') with ordinality x(s,ord)),'frozen seats ordered by seat index');
select ok((select bool_and(jsonb_array_length(s->'days')=7) from read_models,jsonb_array_elements(match->'result'->'seats') s),'every frozen seat has seven days');
select ok((select bool_and((d->>'ordinal')::integer=ord) from read_models,jsonb_array_elements(match->'result'->'seats') s,
 jsonb_array_elements(s->'days') with ordinality x(d,ord)),'frozen days ordered from 1 through 7');
select ok((select bool_and((select array_agg(k order by k) from jsonb_object_keys(d) k)=array['centi_points','ordinal','reason','status'])
 from read_models,jsonb_array_elements(match->'result'->'seats') s,jsonb_array_elements(s->'days') d),'exact frozen day keys exclude raw window metadata');
select ok((select bool_and(jsonb_typeof(s->'total_centi_points')='string' and s->>'total_centi_points' ~ '^[0-9]+$')
 from read_models,jsonb_array_elements(match->'result'->'seats') s),'weekly centipoints are decimal strings');
select ok((select bool_and(case when d->>'status'='available' then jsonb_typeof(d->'centi_points')='string' and d->>'centi_points' ~ '^[0-9]+$' and d->'reason'='null'::jsonb
 else d->'centi_points'='null'::jsonb and jsonb_typeof(d->'reason')='string' end)
 from read_models,jsonb_array_elements(match->'result'->'seats') s,jsonb_array_elements(s->'days') d),'day centipoints are decimal strings or null with a reason');
select is((select match->'result'->'seats'->0 from read_models where match->>'format'='four_way'),
 '{"seat_index":1,"total_centi_points":"12345","days":[
 {"ordinal":1,"status":"available","centi_points":"12345","reason":null},
 {"ordinal":2,"status":"available","centi_points":"0","reason":null},
 {"ordinal":3,"status":"afterLeave","centi_points":null,"reason":"afterLeave"},
 {"ordinal":4,"status":"afterLeave","centi_points":null,"reason":"afterLeave"},
 {"ordinal":5,"status":"afterLeave","centi_points":null,"reason":"afterLeave"},
 {"ordinal":6,"status":"afterLeave","centi_points":null,"reason":"afterLeave"},
 {"ordinal":7,"status":"afterLeave","centi_points":null,"reason":"afterLeave"}]}'::jsonb,'four-way leaver returns exactly the frozen bank and resolved post-leave days');
select is((select match->'result'->'seats'->1->'days'->1 from read_models where match->>'format'='four_way'),
 '{"ordinal":2,"status":"unavailable","centi_points":null,"reason":"sourceDataUnavailable"}'::jsonb,'accepted unavailable reason retained');
select is((select match->'result'->'seats'->1->'days'->2 from read_models where match->>'format'='four_way'),
 '{"ordinal":3,"status":"unavailable","centi_points":null,"reason":"missing"}'::jsonb,'missing day distinguished from accepted unavailable');
select is((select match->'result'->'seats'->2->>'total_centi_points' from read_models where match->>'format'='four_way'),'0','entirely missing human has zero frozen weekly total');
select is((select jsonb_agg(d->'centi_points' order by d->>'ordinal') from read_models,jsonb_array_elements(match->'result'->'seats'->3->'days') d
 where match->>'format'='four_way'),'["0","10000","20000","30000","40000","50000","60000"]'::jsonb,'bot committed whole points converted to frozen centipoints once');
select is((select match->'result'->'seats'->3->>'total_centi_points' from read_models where match->>'format'='four_way'),'210000','bot frozen weekly total survives live input changes');
select is((select jsonb_agg(s->'total_centi_points' order by s->>'seat_index') from read_models,jsonb_array_elements(match->'result'->'seats') s
 where match->>'format'='doubles'),'["70000","140000","210000","70000"]'::jsonb,'doubles returns each human and bot weekly total rather than team totals');
select is((select match->'result'->'standings' from read_models where match->>'format'='doubles'),
 '[{"subject":"2","place":1,"centipoints":280000},{"subject":"1","place":2,"centipoints":210000}]'::jsonb,'doubles frozen team standings unchanged');
select ok((select bool_and(s->'days'=(select jsonb_agg(jsonb_build_object('ordinal',d,'status','available','centi_points',
 case when (s->>'seat_index')::integer=4 then '10000' else ((s->>'seat_index')::integer*10000)::text end,'reason',null) order by d) from generate_series(1,7) d))
 from read_models,jsonb_array_elements(match->'result'->'seats') s where match->>'format'='doubles'),'doubles returns all seven frozen individual day values');
select ok((select bool_and(public.preview_group_match((match->>'competition_id')::uuid)->'result'=match->'result') from read_models),'preview and list share the same frozen result');
reset role;
select ok((select bool_and(to_jsonb(r)=to_jsonb(before_read)) from public.competition_group_results r join stored_results before_read using(competition_id)),'reads and live input changes leave the entire stored row untouched');
select ok((select bool_and(r.immutable_hash=extensions.digest(convert_to('healthcomp-group-result-v1','UTF8')||decode('00','hex')||convert_to(r.frozen_payload::text,'UTF8'),'sha256')) from public.competition_group_results r),'stored hashes still bind original frozen bytes');
select ok((select bool_and((match->'result')-array['version','seats']=(to_jsonb(r)-'frozen_payload')||jsonb_build_object('server_seq',r.server_seq::text,'immutable_hash',encode(r.immutable_hash,'hex')))
 from read_models join public.competition_group_results r on r.competition_id=(match->>'competition_id')::uuid),'every pre-existing result field stays byte-for-byte equivalent');
set constraints all immediate;
-- Installed builds decode each reaction against exactly seven keys; a later column must not reach them.
insert into private.competition_reactions(competition_id,author_profile_id,target_profile_id,day_ordinal,reaction)
  values (pg_temp.gid('doubles'),pg_temp.pid(1),pg_temp.pid(2),1,'clap');
alter table private.competition_reactions add column probe_later_column integer;
select pg_temp.as_user(1);
select is((select array_agg(k order by k) from jsonb_array_elements(public.preview_group_match(pg_temp.gid('doubles'))->'reactions') r,jsonb_object_keys(r) k),
 array['author_profile_id','competition_id','created_at','day_ordinal','reaction','target_profile_id','updated_at'],'reaction keys stay the seven installed builds decode');
select * from finish(); rollback;
