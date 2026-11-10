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

select ok(private.group_bot_week('0','pacer',300)=private.group_bot_week('0','pacer',300),'bot totals deterministic');
select ok((select bool_and(cardinality(w)=7 and 0<=all(w) and 600>=all(w)) from
  (select private.group_bot_week(seed,mode,baseline) w from unnest(array['0','18446744073709551615']) seed,
    unnest(array['pacer','chill','erratic','beast']) mode,unnest(array[100,300,600]) baseline) weeks),'all seeds/modes/baseline edges are seven bounded whole points');
select ok((select bool_and(p between 270 and 330) from unnest(private.group_bot_week('0','pacer',300)) p),'pacer 90-110 percent');
select ok((select bool_and(p between 225 and 270) from unnest(private.group_bot_week('0','chill',300)) p),'chill 75-90 percent');
select ok((select bool_and(p between 375 and 450) from unnest(private.group_bot_week('18446744073709551615','beast',300)) p),'beast 125-150 percent');
select is((select count(*) from unnest(private.group_bot_week('0','erratic',100)) p where p between 130 and 160),3::bigint,'erratic exactly three high days');
select is((select count(*) from unnest(private.group_bot_week('0','erratic',100)) p where p between 30 and 65),4::bigint,'erratic exactly four low days');
select is(private.group_player_baseline(pg_temp.pid(1)),300,'no finalized history uses 300');
select pg_temp.make_match('baseline-old'); select pg_temp.make_live(pg_temp.gid('baseline-old'),8);
select pg_temp.score(pg_temp.gid('baseline-old'),1,1,1,10000);
select private.finalize_competition_locked(pg_temp.gid('baseline-old'),now()+interval '2 days');
select is(private.group_player_baseline(pg_temp.pid(1)),100,'finalized accepted centipoints convert to whole points once');
select pg_temp.make_match('baseline-new'); select pg_temp.make_live(pg_temp.gid('baseline-new'),8);
select pg_temp.score(pg_temp.gid('baseline-new'),1,1,1,40000);
select private.finalize_competition_locked(pg_temp.gid('baseline-new'),now()+interval '3 days');
select is(private.group_player_baseline(pg_temp.pid(1)),400,'overlapping local date counted once using newest finalization');
select pg_temp.make_match('baseline-bot','three_way',2); select pg_temp.accept_all(pg_temp.gid('baseline-bot'));
select is((select bot_baseline from public.competition_seats where competition_id=pg_temp.gid('baseline-bot') and kind='bot'),350,'human means weighted equally with 300 fallback');
select is(private.group_bot_week('0','pacer',300),array[306,273,321,270,327,291,312],'server generator v1 pacer golden');
select is(private.group_bot_week('0','chill',300),array[252,267,237,243,231,258,252],'server generator v1 chill golden');
select is(private.group_bot_week('0','erratic',300),array[189,192,186,450,435,456,141],'server generator v1 erratic golden');
select is(private.group_bot_week('0','beast',300),array[450,393,417,435,423,378,390],'server generator v1 beast golden');
select * from finish(); rollback;
