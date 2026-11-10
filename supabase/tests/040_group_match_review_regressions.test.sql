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
-- Invalid structures must have the same error for valid, blocked and nonexistent links.
insert into private.challenge_links(profile_id,code) values(pg_temp.pid(2),'AAAAAAAAAAAAAAAAAAAAAA');
insert into private.account_blocks values(pg_temp.pid(2),pg_temp.pid(1),now());
select throws_ok($$select public.create_group_match('doubles',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(1),'team_number',1),
 jsonb_build_object('kind','human','challenge_link_code','AAAAAAAAAAAAAAAAAAAAAA','team_number',1),
 jsonb_build_object('kind','bot','bot_mode','pacer','team_number',1),
 jsonb_build_object('kind','bot','bot_mode','pacer','team_number',2)),'UTC',extensions.gen_random_uuid())$$,'22023','invalid_group_match','unbalanced teams fail before resolving a valid blocked code');
select throws_ok($$select public.create_group_match('doubles',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(1),'team_number',1),
 jsonb_build_object('kind','human','challenge_link_code','BBBBBBBBBBBBBBBBBBBBBB','team_number',1),
 jsonb_build_object('kind','bot','bot_mode','pacer','team_number',1),
 jsonb_build_object('kind','bot','bot_mode','pacer','team_number',2)),'UTC',extensions.gen_random_uuid())$$,'22023','invalid_group_match','same structural error for unknown code');
delete from private.account_blocks;
select pg_temp.make_match('blocked-closed');
select pg_temp.as_user(2); select public.block_challenger(pg_temp.gid('blocked-closed'));
select ok(not exists(select 1 from jsonb_array_elements(public.list_group_matches()->'matches') m where m->>'competition_id'=pg_temp.gid('blocked-closed')::text),'blocking cannot re-expose a declined unstarted match');
select is((select count(*) from private.competition_notification_work where competition_id=pg_temp.gid('blocked-closed') and kind='challenge_declined'),2::bigint,'blocking notifies every other human');
delete from private.account_blocks;
select pg_temp.make_match('cancelled'); select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('cancelled'));
select pg_temp.as_user(2);
select throws_ok($$select public.accept_group_match(pg_temp.gid('cancelled'))$$,'P0001','group_match_unavailable','accept after cancel refused');
select pg_temp.make_match('declined'); select pg_temp.as_user(2); select public.decline_group_match(pg_temp.gid('declined'));
select throws_ok($$select public.accept_group_match(pg_temp.gid('declined'))$$,'P0001','group_match_unavailable','accept after decline refused');
select pg_temp.make_match('expired');
update public.competitions set invitation_expires_at=now()-interval '1 second' where id=pg_temp.gid('expired');
select pg_temp.as_user(2);
select is(public.accept_group_match(pg_temp.gid('expired'))->>'state','expired','accept closes expired match');
select is(public.accept_group_match(pg_temp.gid('expired'))->>'state','expired','expired retry returns same shape');
select pg_temp.make_match('lapsed-decline');
update public.competitions set invitation_expires_at=now()-interval '1 second' where id=pg_temp.gid('lapsed-decline');
select pg_temp.as_user(2); select public.decline_group_match(pg_temp.gid('lapsed-decline'));
select is((select count(*) from private.competition_notification_work where competition_id=pg_temp.gid('lapsed-decline') and kind='challenge_declined'),0::bigint,'lapsed invitation never sends declined push');
select pg_temp.make_match('prestart'); select pg_temp.accept_all(pg_temp.gid('prestart'));
select pg_temp.as_user(1);
select throws_ok($$select public.leave_group_match(pg_temp.gid('prestart'))$$,'P0001','leave_not_allowed','leave before day one refused');
select pg_temp.as_user(8);
select throws_ok($$select public.accept_group_match(pg_temp.gid('prestart'))$$,'P0001','group_match_unavailable','nonparticipant accept refused before lineup locks');
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('prestart'));
select pg_temp.make_match('live'); select pg_temp.make_live(pg_temp.gid('live'));
select pg_temp.as_user(1);
select throws_ok($$select public.cancel_group_match(pg_temp.gid('live'))$$,'P0001','cancel_not_allowed','creator cannot cancel on day one or later');
select pg_temp.as_user(2);
select throws_ok($$select public.decline_group_match(pg_temp.gid('live'))$$,'P0001','withdraw_not_allowed','invitee cannot withdraw on day one or later');
select pg_temp.as_user(1); select public.set_current_notification_mute(pg_temp.pid(2),true);
select private.enqueue_reaction_notification(pg_temp.gid('live'),pg_temp.pid(1),pg_temp.pid(2));
select private.allocate_competition_server_seq(pg_temp.gid('live'),'group_reaction_changed',pg_temp.pid(3),now());
select private.enqueue_reaction_notification(pg_temp.gid('live'),pg_temp.pid(1),pg_temp.pid(3));
select is((select count(*) from private.competition_notification_work where competition_id=pg_temp.gid('live') and kind='reaction' and state='pending'),1::bigint,'muted reaction does not silence another player');
-- An accepted invitation in a never-scheduled group does not establish a past-opponent exemption.
select pg_temp.make_match('link-cancel'); select pg_temp.as_user(2); select public.accept_group_match(pg_temp.gid('link-cancel'));
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('link-cancel'));
update private.challenge_links set code='CCCCCCCCCCCCCCCCCCCCCC' where profile_id=pg_temp.pid(2);
-- Use a link-created lineup with fresh profiles, so the earlier live match does not exempt the pair.
select pg_temp.as_user(4);
insert into private.challenge_links(profile_id,code) values(pg_temp.pid(5),'DDDDDDDDDDDDDDDDDDDDDD');
insert into gm values('link-only',(public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),jsonb_build_object('kind','human','challenge_link_code','DDDDDDDDDDDDDDDDDDDDDD'),jsonb_build_object('kind','human','profile_id',pg_temp.pid(6))),'UTC',md5('link-only-key')::uuid)->>'competition_id')::uuid);
select pg_temp.as_user(5); select public.accept_group_match(pg_temp.gid('link-only'));
select pg_temp.as_user(4); select public.cancel_group_match(pg_temp.gid('link-only'));
update private.challenge_links set code='EEEEEEEEEEEEEEEEEEEEEE' where profile_id=pg_temp.pid(5);
select ok(private.challenge_link_revoked_v1(pg_temp.pid(4),pg_temp.pid(5)),'never-scheduled acceptance does not defeat link reset');
select is((public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),jsonb_build_object('kind','human','challenge_link_code','DDDDDDDDDDDDDDDDDDDDDD'),jsonb_build_object('kind','human','profile_id',pg_temp.pid(6))),'UTC',md5('link-only-key')::uuid)->>'competition_id')::uuid,pg_temp.gid('link-only'),'same create key returns original even after link reset');
select throws_ok($$select public.create_group_match('three_way',pg_temp.lineup(3,3),'UTC',md5('link-only-key')::uuid)$$,'P0001','idempotency_conflict','same key with different setup refused');
-- Leaving the only remaining unstable person after day seven finalizes immediately.
select pg_temp.make_match('ready'); select pg_temp.make_live(pg_temp.gid('ready'),8);
select pg_temp.score(pg_temp.gid('ready'),n,d,d) from generate_series(1,2) n,generate_series(1,7) d;
select pg_temp.as_user(1);
select public.attest_final_window(pg_temp.gid('ready'),extensions.gen_random_uuid(),1,'stable',array[1,2,3,4,5,6,7]::bigint[],encode(private.owner_window_commitment_v1(pg_temp.gid('ready'),pg_temp.pid(1),array[1,2,3,4,5,6,7]::bigint[]),'hex'));
select pg_temp.as_user(2);
select public.attest_final_window(pg_temp.gid('ready'),extensions.gen_random_uuid(),1,'stable',array[1,2,3,4,5,6,7]::bigint[],encode(private.owner_window_commitment_v1(pg_temp.gid('ready'),pg_temp.pid(2),array[1,2,3,4,5,6,7]::bigint[]),'hex'));
select pg_temp.as_user(3); select public.leave_group_match(pg_temp.gid('ready'));
select is((select finalization_basis from public.competition_group_results where competition_id=pg_temp.gid('ready')),'stable','leave publishes result as soon as all remaining humans are stable');
select pg_temp.as_user(1);
select ok((public.preview_group_match(pg_temp.gid('ready'))->'owner'->'attestation'->'accepted_revisions'->0)='"1"'::jsonb,'owner attestation revisions encoded as strings');
select ok(public.preview_group_match(pg_temp.gid('ready'))->'result'->'frozen_payload' is null,'list result omits duplicated frozen payload');
select is(public.preview_group_match(pg_temp.gid('ready'))->'seats'->2->'frozen_revisions'->>0,'0','leave bank revision zero is a decimal string');
select is(public.preview_group_match(pg_temp.gid('ready'))->'seats'->0->>'attestation_basis','stable','other seats expose attestation state');
select pg_temp.make_match('all-left'); select pg_temp.make_live(pg_temp.gid('all-left'));
select pg_temp.as_user(1); select public.leave_group_match(pg_temp.gid('all-left'));
select pg_temp.as_user(2); select public.leave_group_match(pg_temp.gid('all-left'));
select pg_temp.as_user(3); select public.leave_group_match(pg_temp.gid('all-left'));
select ok(not exists(select 1 from public.competition_group_results where competition_id=pg_temp.gid('all-left')),'all-left live week does not finalize early');
select private.finalize_due_competitions_batch(100,now()+interval '7 days');
select is((select finalization_basis from public.competition_group_results where competition_id=pg_temp.gid('all-left')),'stable','hosted batch publishes all-left group at week end before fallback deadline');
-- Closed-before-start states stay hidden even if they once had a future schedule.
select pg_temp.make_match('closed-cancelled'); select pg_temp.accept_all(pg_temp.gid('closed-cancelled'));
select pg_temp.as_user(1); select public.cancel_group_match(pg_temp.gid('closed-cancelled'));
select pg_temp.make_match('closed-withdraw'); select pg_temp.accept_all(pg_temp.gid('closed-withdraw'));
select pg_temp.as_user(2); select public.decline_group_match(pg_temp.gid('closed-withdraw'));
select pg_temp.make_match('closed-expired'); update public.competitions set lifecycle='expired' where id=pg_temp.gid('closed-expired');
insert into private.account_blocks values(pg_temp.pid(2),pg_temp.pid(3),now());
select pg_temp.as_user(2);
select ok(not exists(select 1 from jsonb_array_elements(public.list_group_matches()->'matches') m where m->>'competition_id' in
 (pg_temp.gid('closed-cancelled')::text,pg_temp.gid('closed-withdraw')::text,pg_temp.gid('closed-expired')::text)),'all closed-before-start lifecycles with blocks stay hidden');
select ok(exists(select 1 from jsonb_array_elements(public.list_group_matches()->'matches') m where m->>'competition_id'=pg_temp.gid('live')::text),'an actually started match stays available under the ruling');
delete from private.account_blocks;
-- The 14 most recent distinct available dates exclude the oldest seven-date cohort.
select pg_temp.make_match('base-old'); select pg_temp.make_live(pg_temp.gid('base-old'),21);
update public.competitions set best_available_deadline=now()+interval '1 day' where id=pg_temp.gid('base-old');
select pg_temp.score(pg_temp.gid('base-old'),1,d,d,10000) from generate_series(1,7) d;
select private.finalize_competition_locked(pg_temp.gid('base-old'),now()+interval '2 days');
select pg_temp.make_match('base-middle'); select pg_temp.make_live(pg_temp.gid('base-middle'),14);
update public.competitions set best_available_deadline=now()+interval '1 day' where id=pg_temp.gid('base-middle');
select pg_temp.score(pg_temp.gid('base-middle'),1,d,d,20000) from generate_series(1,7) d;
select private.finalize_competition_locked(pg_temp.gid('base-middle'),now()+interval '2 days');
select pg_temp.make_match('base-new'); select pg_temp.make_live(pg_temp.gid('base-new'),7);
select pg_temp.score(pg_temp.gid('base-new'),1,d,d,40000) from generate_series(1,7) d;
select private.finalize_competition_locked(pg_temp.gid('base-new'),now()+interval '3 days');
select is(private.group_player_baseline(pg_temp.pid(1)),300,'baseline uses 14 newest distinct dates, not 21 dates');
-- The last live account deletion banks the last person's scores before closing the match.
select pg_temp.as_user(4);
insert into gm values('delete-last',(public.create_group_match('three_way',jsonb_build_array(
 jsonb_build_object('kind','human','profile_id',pg_temp.pid(4)),jsonb_build_object('kind','human','challenge_link_code','EEEEEEEEEEEEEEEEEEEEEE'),jsonb_build_object('kind','bot','bot_mode','pacer')),'UTC',extensions.gen_random_uuid())->>'competition_id')::uuid);
select pg_temp.as_user(5); select public.accept_group_match(pg_temp.gid('delete-last'));
update public.competitions set start_day=current_date-1,invitation_expires_at=now()-interval '20 days',best_available_deadline=now()+interval '8 days' where id=pg_temp.gid('delete-last');
insert into auth.identities(id,provider_id,user_id,identity_data,provider,created_at,updated_at)
 select extensions.gen_random_uuid(),'review-apple-'||n,pg_temp.uid(n),jsonb_build_object('sub','review-apple-'||n),'apple',now(),now() from generate_series(4,5) n;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select public.begin_account_deletion(pg_temp.uid(4));
select public.store_account_deletion_apple_token(pg_temp.pid(4),'synthetic-refresh-token-for-review-4','com.example.healthcomp');
select public.begin_account_deletion(pg_temp.uid(5));
select public.store_account_deletion_apple_token(pg_temp.pid(5),'synthetic-refresh-token-for-review-5','com.example.healthcomp');
select is((select lifecycle from public.competitions where id=pg_temp.gid('delete-last')),'cancelled','no active humans after deletion closes live match');
select ok((select bool_and(left_at is not null) from public.competition_participants where competition_id=pg_temp.gid('delete-last')),'every deleted human retains bank');
select * from finish(); rollback;
