begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();
create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('push-profile-'||n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('push-user-'||n)::uuid $$;
create function pg_temp.iid(n integer) returns uuid language sql immutable as $$ select md5('push-install-'||n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text,true);
$$;
create function pg_temp.register(n integer, i integer, friends boolean, mutes text[] default '{}') returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(n);
  return public.register_current_device_installation(pg_temp.iid(i),md5(i::text)||md5(i::text),'sandbox',true,true,friends,mutes);
end;
$$;
create function pg_temp.send(a integer,b integer) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(a); return public.send_friend_request(pg_temp.pid(b)); end;
$$;
create function pg_temp.remove(a integer,b integer) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(a); return public.remove_friend(pg_temp.pid(b)); end;
$$;
create function pg_temp.respond(a integer,b integer,accept boolean) returns jsonb language plpgsql as $$
begin perform pg_temp.as_user(a); return public.respond_to_friend_request(pg_temp.pid(b),accept); end;
$$;
create function pg_temp.lease(friends boolean) returns jsonb language plpgsql as $$
begin
 perform set_config('request.jwt.claims','{"role":"service_role"}',true);
 return public.lease_competition_notification_work(25,180,friends);
end;
$$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,30) n;
insert into public.profiles(id,auth_user_id,display_name,state,username)
select pg_temp.pid(n),pg_temp.uid(n),'Person '||n,'active','push_person_'||n from generate_series(1,30) n;
select is((select count(*) from private.competition_notification_work),0::bigint,'migration backfill queued nothing');
select is(pg_temp.register(1,1,true),jsonb_build_object('installation_id',pg_temp.iid(1),'environment','sandbox','state','active'),'new registration exact return');
select pg_temp.register(2,2,true);
select pg_temp.register(2,3,false);
select pg_temp.register(2,4,true,array['friend_request']);
select pg_temp.register(2,5,true,array['friend_accepted']);
select ok(has_function_privilege('authenticated','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[])','execute')
 and not has_function_privilege('anon','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[])','execute')
 and not has_function_privilege('service_role','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[])','execute'),'registration grant boundary');
select pg_temp.as_user(2);
select throws_ok($$select public.register_current_device_installation(pg_temp.iid(3),repeat('ab',32),'sandbox',true,true,null::boolean,'{}')$$,'22023','invalid_installation_request','null capability rejected');
select throws_ok($$select public.register_current_device_installation(pg_temp.iid(3),repeat('ab',32),'sandbox',true,true,true,array['unknown'])$$,'22023','invalid_installation_request','unknown mute rejected');
select is(pg_temp.send(1,2),' {"relationship":"requested"}'::jsonb,'send new request');
select is((select count(*) from private.competition_notification_work where kind='friend_request'),3::bigint,'only capable installations queued');
select is((select state from private.competition_notification_work where installation_id=pg_temp.iid(4)),'suppressed','muted request suppressed at enqueue');
select is((select count(*) from private.competition_notification_work where competition_id is not null or server_seq is not null),0::bigint,'friend work has no competition or change cursor');
select pg_temp.send(1,2);
select is((select count(*) from private.competition_notification_work),3::bigint,'idempotent send queues nothing');
select is(pg_temp.lease(false),' {"items":[]}'::jsonb,'old worker cannot see friend work');
select is((select count(*) from private.competition_notification_work where state='pending'),2::bigint,'old worker leaves friends pending');
create temporary table leases as select pg_temp.lease(true) data;
select is(jsonb_array_length((select data->'items' from leases)),2,'new worker leases unmuted capable devices');
select ok((select bool_and((i->>'supportsFriends')::boolean and i->'competitionId'='null'::jsonb and i->>'kind'='friend_request' and jsonb_object_length=8)
 from leases,jsonb_array_elements(data->'items') i,
 lateral (select count(*) jsonb_object_length from jsonb_object_keys(i)) k),'friend lease exact eight-key shape attests capability');
select pg_temp.respond(2,1,true);
select is((select count(*) from private.competition_notification_work where kind='friend_request' and state in ('pending','leased')),0::bigint,'accept supersedes request including live leases');
select is((select count(*) from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(1) and source_profile_id=pg_temp.pid(2)),1::bigint,'accept notifies original sender only');
select pg_temp.respond(2,1,true);
select is((select count(*) from private.competition_notification_work where kind='friend_accepted'),1::bigint,'idempotent acceptance queues nothing');
select pg_temp.lease(true);
select pg_temp.remove(1,2);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'remove supersedes accepted work including leases');
select pg_temp.send(1,2);
select is((select count(*) from private.competition_notification_work where kind='friend_request'),3::bigint,'cancel/send loop guarded for 24 hours');
select pg_temp.remove(1,2);
update private.competition_notification_work set created_at=created_at-interval '24 hours 1 second';
select pg_temp.send(1,2);
select is((select count(*) from private.competition_notification_work where kind='friend_request'),6::bigint,'request can notify again after 24 hours');
select pg_temp.respond(2,1,false);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'decline supersedes request and queues nothing');
-- Crossed requests notify the person whose original request was accepted.
select pg_temp.register(3,6,true);
select pg_temp.register(4,7,true);
select pg_temp.send(3,4);
select pg_temp.send(4,3);
select is((select count(*) from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(3) and source_profile_id=pg_temp.pid(4)),1::bigint,'crossed request notifies original sender');
select is((select count(*) from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(4)),0::bigint,'crossed request does not notify acceptor');
select pg_temp.as_user(3);
select public.report_profile(pg_temp.pid(4));
select is((select count(*) from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(3)),1::bigint,'report queues no new work');
select public.block_profile(pg_temp.pid(4));
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'block supersedes accepted work');
-- Pending requests disappear for either blocker direction and either deactivated side.
select pg_temp.register(5,8,true);
select pg_temp.register(6,9,true);
select pg_temp.send(5,6);
select pg_temp.as_user(6);
select public.block_profile(pg_temp.pid(5));
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'recipient block supersedes request');
select pg_temp.register(7,10,true);
select pg_temp.register(8,11,true);
select pg_temp.send(7,8);
update public.profiles set state='deleting' where id=pg_temp.pid(7);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'source deactivation supersedes request');
select pg_temp.register(9,12,true);
select pg_temp.register(10,13,true);
select pg_temp.send(9,10);
select pg_temp.respond(10,9,true);
update public.profiles set state='deleting' where id=pg_temp.pid(9);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')),0::bigint,'recipient deactivation supersedes acceptance');
-- Re-registration immediately revokes capability; leases must recheck both switches.
select pg_temp.register(11,14,true);
select pg_temp.register(12,15,true);
select pg_temp.send(11,12);
select pg_temp.register(12,15,false);
select is(pg_temp.lease(true),' {"items":[]}'::jsonb,'capability downgrade prevents queued delivery');
select is((select state from private.competition_notification_work where recipient_profile_id=pg_temp.pid(12)),'discarded','downgraded work discarded');
select pg_temp.remove(11,12);
select pg_temp.register(12,15,true);
select pg_temp.send(12,11);
select pg_temp.register(11,14,true,array['friend_request']);
select is(pg_temp.lease(true),' {"items":[]}'::jsonb,'mute added after enqueue prevents delivery');
select is((select state from private.competition_notification_work where recipient_profile_id=pg_temp.pid(11)),'suppressed','new mute suppresses pending work');
-- Old registration overloads retain response shape, disable capability, and keep their mute semantics.
select pg_temp.as_user(2);
select public.register_current_device_installation(pg_temp.iid(2),md5('2')||md5('2'),'sandbox',true,true,array['friend_request','reaction']);
select ok((select not supports_friends and muted_push_kinds=array['friend_request','reaction'] from public.device_installations where installation_id=pg_temp.iid(2)),'six-argument overload preserves supplied mutes and disables friends');
select pg_temp.register(2,2,true);
select public.register_current_device_installation(pg_temp.iid(2),md5('2')||md5('2'),'sandbox',true,true);
select ok((select not supports_friends and muted_push_kinds='{}' from public.device_installations where installation_id=pg_temp.iid(2)),'five-argument overload keeps old mute reset');
select pg_temp.register(2,2,true);
select public.register_current_device_installation(pg_temp.iid(2),md5('2')||md5('2'),'sandbox',true);
select ok((select not supports_friends and not supports_reactions from public.device_installations where installation_id=pg_temp.iid(2)),'four-argument overload disables friends');
select pg_temp.register(2,2,true);
select public.register_current_device_installation(pg_temp.iid(2),md5('2')||md5('2'),'sandbox');
select ok((select not supports_friends and not supports_challenges from public.device_installations where installation_id=pg_temp.iid(2)),'three-argument overload disables friends');
-- Friend work retains the shared durable retry and compare-and-set contract.
select pg_temp.register(13,16,true);
select pg_temp.register(14,17,true);
select pg_temp.send(13,14);
truncate leases;
insert into leases select pg_temp.lease(true);
select is(jsonb_array_length((select data->'items' from leases)),1,'one friend request leased');
select is(public.resolve_competition_notification_work(
  ((select data->'items'->0->>'workId' from leases))::uuid,
  ((select data->'items'->0->>'leaseToken' from leases))::uuid,'retry',60),true,'friend retry uses existing resolver');
select is((select state from private.competition_notification_work where recipient_profile_id=pg_temp.pid(14)),'pending','retry returns friend work to pending');
select is(pg_temp.lease(true),' {"items":[]}'::jsonb,'retry availability respected');
update private.competition_notification_work set available_at=statement_timestamp()-interval '1 second'
where recipient_profile_id=pg_temp.pid(14);
truncate leases;
insert into leases select pg_temp.lease(true);
select is((select attempt_count from private.competition_notification_work where recipient_profile_id=pg_temp.pid(14)),2,'retry increments attempts');
select pg_temp.respond(14,13,false);
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select is(public.resolve_competition_notification_work(
  ((select data->'items'->0->>'workId' from leases))::uuid,
  ((select data->'items'->0->>'leaseToken' from leases))::uuid,'sent',null),false,'decline invalidates stale friend completion');
-- Per-kind mute and rolling guard also apply to acceptance.
select pg_temp.register(15,18,true,array['friend_accepted']);
select pg_temp.register(16,19,true);
select pg_temp.send(15,16);
select pg_temp.respond(16,15,true);
select is((select state from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(15)),'suppressed','accept mute suppresses accept without muting request');
select pg_temp.remove(15,16);
select pg_temp.send(15,16);
select pg_temp.respond(16,15,true);
select is((select count(*) from private.competition_notification_work where kind='friend_accepted' and recipient_profile_id=pg_temp.pid(15)),1::bigint,'accept/remove/reaccept guarded for 24 hours');
-- Actual deletion preparation revokes installations and leaves no deliverable
-- work referencing the deleting profile, as source or as recipient.
select pg_temp.register(17,20,true);
select pg_temp.register(18,21,true);
select pg_temp.register(19,22,true);
select pg_temp.send(17,18);
select pg_temp.send(19,17);
insert into auth.identities(id,provider_id,user_id,identity_data,provider,created_at,updated_at)
values(gen_random_uuid(),'friend-push-deletion',pg_temp.uid(17),'{"sub":"friend-push-deletion"}','apple',now(),now());
select set_config('request.jwt.claims','{"role":"service_role"}',true);
select lives_ok($$select public.begin_account_deletion(pg_temp.uid(17))$$,'account deletion preparation succeeds with friend work');
select lives_ok($$select public.store_account_deletion_apple_token(pg_temp.pid(17),'synthetic-friend-refresh-token','com.example.native')$$,'deletion token phase supersedes friend work');
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')
  and pg_temp.pid(17) in (source_profile_id,recipient_profile_id)),0::bigint,'deletion leaves no deliverable source or recipient friend work');
select is((select state from public.device_installations where profile_id=pg_temp.pid(17)),'revoked','deletion revokes friend-capable installation');
select pg_temp.register(20,23,true);
select pg_temp.register(21,24,true);
select pg_temp.send(20,21);
update public.profiles set state='deleting' where id=pg_temp.pid(21);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')
 and pg_temp.pid(21) in (source_profile_id,recipient_profile_id)),0::bigint,'recipient deactivation supersedes request');
select pg_temp.register(22,25,true);
select pg_temp.send(20,22);
select pg_temp.respond(22,20,true);
update public.profiles set state='deleting' where id=pg_temp.pid(22);
select is((select count(*) from private.competition_notification_work where state in ('pending','leased')
 and pg_temp.pid(22) in (source_profile_id,recipient_profile_id)),0::bigint,'source deactivation supersedes acceptance');
-- Invalid route combinations cannot bypass the existing competition FKs.
select throws_ok($$insert into private.competition_notification_work(
 semantic_id,kind,source_profile_id,recipient_profile_id,installation_id,state)
 values('healthcomp.server-notification:v1:invalid-match','reaction',pg_temp.pid(1),pg_temp.pid(2),pg_temp.iid(2),'pending')$$,
 '23514',null,'match kind still requires competition and change cursor');
select throws_ok($$insert into private.competition_notification_work(
 semantic_id,kind,source_profile_id,recipient_profile_id,installation_id,state)
 values('healthcomp.server-notification:v1:invalid-friend','friend_request',pg_temp.pid(1),pg_temp.pid(2),pg_temp.iid(2),'pending')$$,
 '23514',null,'friend kind requires event identity');
select ok(not has_function_privilege('authenticated','public.lease_competition_notification_work(integer,integer,boolean)','execute')
 and has_function_privilege('service_role','public.lease_competition_notification_work(integer,integer,boolean)','execute'), 'opted-in lease remains service-only');
-- Match mutes apply only to match work, even in a mixed new-worker batch.
create function pg_temp.challenge(a integer, b integer) returns uuid language plpgsql as $$
declare code text;
begin
  perform pg_temp.as_user(b);
  code := public.get_my_challenge_link()->>'code';
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  return public.create_competition_invite_from_link(
    extensions.digest(gen_random_uuid()::text,'sha256'),'UTC',pg_temp.uid(a),gen_random_uuid(),1::smallint,code);
end;
$$;
create function pg_temp.item_keys(item jsonb) returns text[] language sql as $$
  select array_agg(k order by k) from jsonb_object_keys(item) k;
$$;
select pg_temp.register(23,26,true);
select pg_temp.register(24,27,true);
select pg_temp.challenge(23,24);
insert into private.competition_notification_mutes(profile_id,opponent_profile_id)
values(pg_temp.pid(24),pg_temp.pid(23)),(pg_temp.pid(23),pg_temp.pid(24));
select pg_temp.send(23,24);
truncate leases;
insert into leases select pg_temp.lease(true);
select is((select array_agg(i->>'kind') from leases,jsonb_array_elements(data->'items') i),
 array['friend_request'],'match-opponent mute still permits friend request delivery');
select is((select state from private.competition_notification_work
 where recipient_profile_id=pg_temp.pid(24) and kind='challenge_received'),'suppressed','match-opponent mute still suppresses match push');
select is((select pg_temp.item_keys(data->'items'->0) from leases),
 array['apnsToken','competitionId','environment','kind','leaseToken','semanticId','supportsFriends','workId'],
 'new lease friend item has exactly eight expected keys');
select pg_temp.respond(24,23,true);
truncate leases;
insert into leases select pg_temp.lease(true);
select is((select array_agg(i->>'kind') from leases,jsonb_array_elements(data->'items') i),
 array['friend_accepted'],'match-opponent mute still permits friend acceptance delivery');
-- New worker can parse both shapes in the same batch.
select pg_temp.register(25,28,true);
select pg_temp.register(26,29,true);
select pg_temp.challenge(25,26);
select pg_temp.send(25,26);
truncate leases;
insert into leases select pg_temp.lease(true);
select is(jsonb_array_length((select data->'items' from leases)),2,'new lease returns mixed match and friend batch');
select is((select pg_temp.item_keys(i) from leases,jsonb_array_elements(data->'items') i where i->>'kind'='challenge_received'),
 array['apnsToken','competitionId','environment','kind','leaseToken','semanticId','workId'],
 'new lease match item retains exactly seven expected keys');
select is((select pg_temp.item_keys(i) from leases,jsonb_array_elements(data->'items') i where i->>'kind'='friend_request'),
 array['apnsToken','competitionId','environment','kind','leaseToken','semanticId','supportsFriends','workId'],
 'mixed new lease friend item retains exactly eight expected keys');
select pg_temp.register(27,30,true);
select pg_temp.register(28,31,true);
select pg_temp.challenge(27,28);
select pg_temp.send(27,28);
truncate leases;
select set_config('request.jwt.claims','{"role":"service_role"}',true);
insert into leases select public.lease_competition_notification_work(25,180);
select is(jsonb_array_length((select data->'items' from leases)),1,'old lease returns only match from mixed pending work');
select is((select pg_temp.item_keys(data->'items'->0) from leases),
 array['apnsToken','competitionId','environment','kind','leaseToken','semanticId','workId'],
 'old lease match item retains exactly seven expected keys');
select is((select state from private.competition_notification_work
 where recipient_profile_id=pg_temp.pid(28) and kind='friend_request'),'pending','old lease leaves friend work pending');
-- Direct profile FKs cover friend rows whose nullable composite FKs skip checks.
select ok((select count(*)=2 and bool_and(convalidated and confdeltype='a'
 and confrelid='public.profiles'::regclass and cardinality(conkey)=1)
 from pg_constraint where conrelid='private.competition_notification_work'::regclass
 and conname in ('competition_notification_work_source_profile_fk','competition_notification_work_recipient_profile_fk')),
 'both profile foreign keys are validated and preserve tombstoned profiles');
select throws_ok($$insert into private.competition_notification_work(
 semantic_id,friend_event_id,kind,source_profile_id,recipient_profile_id,installation_id,state)
 values('healthcomp.server-notification:v1:missing-source',gen_random_uuid(),'friend_request',pg_temp.pid(999),pg_temp.pid(28),pg_temp.iid(31),'pending')$$,
 '23503',null,'friend row cannot reference nonexistent source profile');
select throws_ok($$update private.competition_notification_work set recipient_profile_id=pg_temp.pid(999)
 where recipient_profile_id=pg_temp.pid(28) and kind='friend_request'$$,
 '23503',null,'friend row cannot reference nonexistent recipient profile');
-- No delete trigger runs here: this exercises the lease-time stale-work check.
insert into private.competition_notification_work(
 semantic_id,friend_event_id,kind,source_profile_id,recipient_profile_id,installation_id,state)
values('healthcomp.server-notification:v1:stale-request',gen_random_uuid(),'friend_request',pg_temp.pid(25),pg_temp.pid(28),pg_temp.iid(31),'pending'),
 ('healthcomp.server-notification:v1:stale-accepted',gen_random_uuid(),'friend_accepted',pg_temp.pid(25),pg_temp.pid(28),pg_temp.iid(31),'pending');
select pg_temp.lease(true);
select is((select count(*) from private.competition_notification_work
 where semantic_id in ('healthcomp.server-notification:v1:stale-request','healthcomp.server-notification:v1:stale-accepted') and state='superseded'),
 2::bigint,'lease supersedes request and acceptance with no backing relationship');
-- Observe only worker wakeups; realtime Friends wakeups retain their own path.
create temporary table worker_wakeups(n integer generated always as identity);
create or replace function private.request_competition_notification_worker()
returns void language sql security definer set search_path = '' as $$
 insert into pg_temp.worker_wakeups default values;
$$;
select pg_temp.register(30,32,false);
select pg_temp.send(29,30);
select is((select count(*) from worker_wakeups),0::bigint,'no capable installation means no worker wakeup');
select is((select count(*) from private.competition_notification_work where recipient_profile_id=pg_temp.pid(30)),0::bigint,'no capable installation means no queued rows');
select pg_temp.remove(29,30);
select pg_temp.register(30,32,true);
select pg_temp.send(29,30);
select is((select count(*) from worker_wakeups),1::bigint,'queued friend work wakes sender once');
select pg_temp.remove(29,30);
select pg_temp.send(29,30);
select is((select count(*) from worker_wakeups),1::bigint,'rate guard queues nothing and does not wake sender');
select * from finish();
rollback;
