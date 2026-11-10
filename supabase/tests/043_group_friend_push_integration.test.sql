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
-- All registration generations must clear capabilities they cannot advertise.
select pg_temp.as_user(2);
select is(public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,true,array['friend_request','friend_accepted','reaction'],true),
  jsonb_build_object('installation_id',md5('group-install-2')::uuid,'environment','sandbox','state','active'),'combined registration retains exact response');
select ok((select supports_friends and supports_group_matches and cardinality(muted_push_kinds)=3 from public.device_installations where profile_id=pg_temp.pid(2)),'combined registration persists both flags and friends mute kinds');
select throws_ok($$select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,true,'{}',null)$$,'22023','invalid_installation_request','combined registration rejects null group capability');
select ok(has_function_privilege('authenticated','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[],boolean)','execute')
 and not has_function_privilege('anon','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[],boolean)','execute')
 and not has_function_privilege('service_role','public.register_current_device_installation(uuid,text,text,boolean,boolean,boolean,text[],boolean)','execute'),'combined registration grant boundary');
select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,true,array['friend_request']);
select ok((select supports_friends and not supports_group_matches and muted_push_kinds=array['friend_request'] from public.device_installations where profile_id=pg_temp.pid(2)),'friends overload clears group capability and keeps friend mutes');
select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,array['friend_accepted'],true);
select ok((select not supports_friends and supports_group_matches and muted_push_kinds=array['friend_accepted'] from public.device_installations where profile_id=pg_temp.pid(2)),'group overload clears friends capability and accepts friend mute kinds');
select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,array['friend_request']);
select ok((select not supports_friends and not supports_group_matches and muted_push_kinds=array['friend_request'] from public.device_installations where profile_id=pg_temp.pid(2)),'six argument wrapper clears both flags and keeps supplied mutes');
select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true);
select ok((select not supports_friends and not supports_group_matches and muted_push_kinds='{}' from public.device_installations where profile_id=pg_temp.pid(2)),'five argument wrapper follows combined chain and resets mutes');
select public.register_current_device_installation(md5('group-install-2')::uuid,repeat('ab',32),'sandbox',true,true,true,'{}',true);
select pg_temp.make_match('mixed');
delete from private.competition_notification_work;
insert into private.friend_requests(sender_profile_id,recipient_profile_id) values(pg_temp.pid(1),pg_temp.pid(2));
select private.enqueue_challenge_notification(pg_temp.gid('mixed'),'challenge_received',pg_temp.pid(2),pg_temp.pid(1));
select set_config('request.jwt.claims','{"role":"service_role"}',true);
create temporary table leases as select public.lease_competition_notification_work(25,180) data;
select is((select array_agg(i->>'kind') from leases,jsonb_array_elements(data->'items') i),array['challenge_received'],'old worker leases group work but never friends');
select is((select state from private.competition_notification_work where kind='friend_request'),'pending','old worker leaves friends pending');
update private.competition_notification_work set state='pending',lease_token=null,lease_expires_at=null,leased_apns_token_sha256=null,completed_at=null;
update public.device_installations set supports_group_matches=false where profile_id=pg_temp.pid(2);
truncate leases;
insert into leases select public.lease_competition_notification_work(25,180,true);
select is((select array_agg(i->>'kind') from leases,jsonb_array_elements(data->'items') i),array['friend_request'],'friends worker retains friends while discarding group-incapable delivery');
select is((select state from private.competition_notification_work where kind='challenge_received'),'discarded','new worker also enforces group capability downgrade');
select ok((select (data->'items'->0->>'supportsFriends')::boolean from leases),'friends item carries worker capability marker');
update public.device_installations set supports_group_matches=true where profile_id=pg_temp.pid(2);
update private.competition_notification_work set state='pending',lease_token=null,lease_expires_at=null,leased_apns_token_sha256=null,completed_at=null;
insert into private.competition_notification_mutes(profile_id,opponent_profile_id) values(pg_temp.pid(2),pg_temp.pid(1));
truncate leases;
insert into leases select public.lease_competition_notification_work(25,180,true);
select is((select array_agg(i->>'kind') from leases,jsonb_array_elements(data->'items') i),array['friend_request'],'match opponent mute suppresses group work but permits friends from same person');
select is((select state from private.competition_notification_work where kind='challenge_received'),'suppressed','group work retains match mute semantics');
update private.competition_notification_work set state='pending',lease_token=null,lease_expires_at=null,leased_apns_token_sha256=null,completed_at=null where kind='friend_request';
update public.device_installations set muted_push_kinds=array['friend_request'] where profile_id=pg_temp.pid(2);
select is(public.lease_competition_notification_work(25,180,true),'{"items":[]}'::jsonb,'friend kind mute applies at lease time');
select is((select state from private.competition_notification_work where kind='friend_request'),'suppressed','friend kind mute records suppression');
select * from finish();
rollback;
