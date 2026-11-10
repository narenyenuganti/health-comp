begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$
  select md5('friends-profile-' || n)::uuid;
$$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$
  select md5('friends-auth-' || n)::uuid;
$$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text,true);
$$;
create function pg_temp.people(q text) returns uuid[] language sql as $$
  select coalesce(array_agg((p->>'id')::uuid), array[]::uuid[])
  from jsonb_array_elements(public.search_people(q)->'people') p;
$$;
create function pg_temp.challenge(sender integer, recipient integer) returns uuid language plpgsql as $$
declare code text;
begin
  perform pg_temp.as_user(recipient);
  code := public.get_my_challenge_link()->>'code';
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  return public.create_competition_invite_from_link(extensions.digest(gen_random_uuid()::text,'sha256'),'UTC',
    pg_temp.uid(sender),gen_random_uuid(),1::smallint,code);
end;
$$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,130) n;
insert into public.profiles(id,auth_user_id,display_name,state)
select pg_temp.pid(n), pg_temp.uid(n), 'Person ' || n, 'active' from generate_series(1,130) n;
create temporary table r(label text primary key,id uuid);
grant all on r to authenticated;

select ok((select bool_and(p.prosecdef and p.proconfig = array['search_path=""']
  and has_function_privilege('authenticated',p.oid,'execute')
  and not has_function_privilege('anon',p.oid,'execute')
  and not has_function_privilege('service_role',p.oid,'execute')
  and not has_function_privilege('public',p.oid,'execute')) and count(*)=11
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public'
  and p.proname in ('get_friend_settings','set_username','username_available','update_friend_settings',
    'search_people','list_friends','send_friend_request','respond_to_friend_request','remove_friend','block_profile','report_profile')),
  'all eleven RPCs are authenticated-only definers with empty search paths');
select ok((select bool_and(c.relrowsecurity and c.relforcerowsecurity
  and not has_table_privilege('authenticated',c.oid,'select,insert,update,delete')
  and not has_table_privilege('service_role',c.oid,'select,insert,update,delete')) and count(*)=4
  from pg_class c join pg_namespace n on n.oid=c.relnamespace where n.nspname='private'
  and c.relname in ('friendships','friend_requests','profile_reports','people_search_limits')),
  'all four private tables force RLS and deny direct API access');
set local role authenticated;
select pg_temp.as_user(1);
select is(public.get_friend_settings(), '{"username":null,"show_in_search":true,"challenge_policy":"friends_and_link"}'::jsonb,
  'old profiles start usernameless with link challenges enabled');
select is(public.get_friend_settings(), public.get_friend_settings(), 'settings reads repeat');
select is(public.list_friends(), '{"friends":[],"incoming":[],"outgoing":[]}'::jsonb, 'empty list exact shape');
select is(public.list_friends(), public.list_friends(), 'list retries are stable');
select is(public.set_username('  ALIce_1  '),
  '{"username":"alice_1","show_in_search":true,"challenge_policy":"friends_and_link"}'::jsonb, 'username trim and case folding');
select is(public.set_username('ALICE_1'), public.get_friend_settings(), 'setting current username is a no-op');
select throws_ok($$select public.set_username(null)$$,'22023','invalid_username','null username');
select throws_ok($$select public.set_username('ab')$$,'22023','invalid_username','short username');
select throws_ok($$select public.set_username(repeat('a',21))$$,'22023','invalid_username','long username');
select throws_ok($$select public.set_username('bad-name')$$,'22023','invalid_username','invalid username characters');
select throws_ok($$select public.set_username('AdMiN')$$,'P0001','username_unavailable','reserved indistinguishable from taken');
select is(public.username_available(' ALICE_1 '),'{"available":true}'::jsonb,'own current username available');
select is(public.username_available('alice_1'),'{"available":true}'::jsonb,'availability retries');
select is(public.username_available('SUPPORT'),'{"available":false}'::jsonb,'reserved unavailable');
select is(public.username_available('unused'),'{"available":true}'::jsonb,'unused available');
select throws_ok($$select public.username_available('a!')$$,'22023','invalid_username','availability validates');
select throws_ok(format('select public.set_username(%L)',reserved),'P0001','username_unavailable','reserved '||reserved)
from unnest(array['healthcomp','apple_watch','former_competitor','friends']) reserved;
select pg_temp.as_user(2);
select throws_ok($$select public.set_username('ALICE_1')$$,'P0001','username_unavailable','unique index violation becomes username_unavailable');
select is(public.username_available('alice_1'),'{"available":false}'::jsonb,'other person cannot claim it');
select is(public.set_username('bob_2')->>'username','bob_2','second user claims username');
select is(public.update_friend_settings(false,'friends_only'),
  '{"username":"bob_2","show_in_search":false,"challenge_policy":"friends_only"}'::jsonb,'update settings exact shape');
select is(public.update_friend_settings(false,'friends_only'),public.get_friend_settings(),'settings retry');
select throws_ok($$select public.update_friend_settings(null,'friends_only')$$,'22023','invalid_friend_settings','null visibility');
select throws_ok($$select public.update_friend_settings(true,null)$$,'22023','invalid_friend_settings','null policy');
select throws_ok($$select public.update_friend_settings(true,'everyone')$$,'22023','invalid_friend_settings','invalid policy');
select pg_temp.as_user(1);
select is(pg_temp.people('bob'),array[]::uuid[],'hidden not searchable');
select is(pg_temp.people('Person'),array[]::uuid[],'usernameless not searchable');
select is(pg_temp.people('alice'),array[]::uuid[],'caller excluded');
select is(pg_temp.people('zzzz'),array[]::uuid[],'search retry');
select throws_ok($$select public.search_people(null)$$,'22023','invalid_query','null query');
select throws_ok($$select public.search_people('aa')$$,'22023','invalid_query','short query');
select throws_ok($$select public.search_people(repeat('x',41))$$,'22023','invalid_query','long query');
select throws_ok($$select public.search_people(E'abc\n')$$,'22023','invalid_query','control query');
select throws_ok($$select public.send_friend_request(null)$$,'22023','invalid_profile_id','send null');
select throws_ok($$select public.send_friend_request(pg_temp.pid(1))$$,'P0001','recipient_unavailable','send self');
select throws_ok($$select public.send_friend_request(pg_temp.pid(999))$$,'P0001','recipient_unavailable','send unknown');
select throws_ok($$select public.send_friend_request(pg_temp.pid(2))$$,'P0001','recipient_unavailable','send hidden stranger');
select throws_ok($$select public.respond_to_friend_request(null,true)$$,'22023','invalid_profile_id','respond null target');
select throws_ok($$select public.respond_to_friend_request(pg_temp.pid(2),null)$$,'22023','invalid_friend_request_response','respond null decision');
select throws_ok($$select public.respond_to_friend_request(pg_temp.pid(1),true)$$,'P0001','request_unavailable','accept self');
select throws_ok($$select public.respond_to_friend_request(pg_temp.pid(2),true)$$,'P0001','request_unavailable','accept absent');
select is(public.respond_to_friend_request(pg_temp.pid(1),false),'{"relationship":"none"}'::jsonb,'decline self no-op');
select is(public.respond_to_friend_request(pg_temp.pid(2),false),'{"relationship":"none"}'::jsonb,'decline absent');
select is(public.respond_to_friend_request(pg_temp.pid(2),false),'{"relationship":"none"}'::jsonb,'decline retry');
select throws_ok($$select public.remove_friend(null)$$,'22023','invalid_profile_id','remove null');
select is(public.remove_friend(pg_temp.pid(1)),'{"relationship":"none"}'::jsonb,'remove self');
select is(public.remove_friend(pg_temp.pid(999)),'{"relationship":"none"}'::jsonb,'remove unknown');
select is(public.remove_friend(pg_temp.pid(999)),'{"relationship":"none"}'::jsonb,'remove retry');
select throws_ok($$select public.block_profile(null)$$,'22023','invalid_profile_id','block null');
select throws_ok($$select public.block_profile(pg_temp.pid(1))$$,'P0001','recipient_unavailable','block self');
select throws_ok($$select public.block_profile(pg_temp.pid(999))$$,'P0001','recipient_unavailable','block unknown');
select throws_ok($$select public.block_profile(pg_temp.pid(2))$$,'P0001','recipient_unavailable','block hidden stranger');
select throws_ok($$select public.report_profile(null)$$,'22023','invalid_profile_id','report null');
select throws_ok($$select public.report_profile(pg_temp.pid(1))$$,'P0001','recipient_unavailable','report self');
select throws_ok($$select public.report_profile(pg_temp.pid(999))$$,'P0001','recipient_unavailable','report unknown');
select throws_ok($$select public.report_profile(pg_temp.pid(2))$$,'P0001','recipient_unavailable','report hidden stranger');
reset role;
-- Publish people with intentional exact, prefix, word-prefix and wildcard cases.
update public.profiles set username='person_'||n, display_name = case when n=3 then 'Alice Cooper'
  when n=4 then 'Other Alice' else 'Person '||n end
from generate_series(3,35) n where id=pg_temp.pid(n);
update public.profiles set username='alice', display_name='Exact' where id=pg_temp.pid(5);
update public.profiles set username='alice_more' where id=pg_temp.pid(6);
update public.profiles set username='literal_abc' where id=pg_temp.pid(7);
update public.profiles set username='literalxabc' where id=pg_temp.pid(8);
-- Preserve a matching friendship so only the search state filter excludes it.
insert into private.friendships values(least(pg_temp.pid(1),pg_temp.pid(9)),greatest(pg_temp.pid(1),pg_temp.pid(9)),now());
alter table public.profiles disable trigger purge_friends_on_profile_deactivation;
update public.profiles set state='deleting',username=null,display_name='Inactive Search Counterpart' where id=pg_temp.pid(9);
alter table public.profiles enable trigger purge_friends_on_profile_deactivation;
update public.profiles set photo_version=md5('search-photo')::uuid where id=pg_temp.pid(5);
insert into private.account_blocks values(pg_temp.pid(1),pg_temp.pid(10),now()),(pg_temp.pid(11),pg_temp.pid(1),now());
set local role authenticated;
select pg_temp.as_user(1);
select is(jsonb_array_length(public.list_profile_photos(array[pg_temp.pid(5)])->'photos'),1,'searchable stranger photo visible');
select is(pg_temp.people('  ALICE '), array[pg_temp.pid(5),pg_temp.pid(6),pg_temp.pid(3),pg_temp.pid(4)], 'exact username then prefix then name/word prefix');
select is(pg_temp.people(' @ALICE '), array[pg_temp.pid(5),pg_temp.pid(6)], '@ username only');
select is(pg_temp.people('literal_'),array[pg_temp.pid(7)],'underscore escaped');
select is(pg_temp.people('ali%'),array[]::uuid[],'percent escaped');
select is(pg_temp.people(E'ali\\'),array[]::uuid[],'backslash escaped');
select is(cardinality(pg_temp.people('person')),20,'search capped at twenty');
select is(pg_temp.people('inactive search'),array[]::uuid[],'otherwise-matching non-active friend excluded');
select ok(not pg_temp.people('@person_') && array[pg_temp.pid(10),pg_temp.pid(11)],'both block directions excluded');
reset role;
delete from private.friendships where profile_low=least(pg_temp.pid(1),pg_temp.pid(9))
  and profile_high=greatest(pg_temp.pid(1),pg_temp.pid(9));
set local role authenticated;
select pg_temp.as_user(1);
select throws_ok($$select public.send_friend_request(pg_temp.pid(10))$$,'P0001','recipient_unavailable','blocked target');
select throws_ok($$select public.send_friend_request(pg_temp.pid(11))$$,'P0001','recipient_unavailable','target blocked caller');
select throws_ok($$select public.send_friend_request(pg_temp.pid(9))$$,'P0001','recipient_unavailable','deleting target');
select throws_ok($$select public.block_profile(pg_temp.pid(11))$$,'P0001','recipient_unavailable','cannot probe someone blocking caller');
select throws_ok($$select public.report_profile(pg_temp.pid(11))$$,'P0001','recipient_unavailable','cannot report blocked target');
select is(public.report_profile(pg_temp.pid(3)),'{"reported":true}'::jsonb,'report reachable');
select is(public.report_profile(pg_temp.pid(3)),'{"reported":true}'::jsonb,'report retry');
select is(public.send_friend_request(pg_temp.pid(3)),'{"relationship":"requested"}'::jsonb,'send');
select is(public.send_friend_request(pg_temp.pid(3)),'{"relationship":"requested"}'::jsonb,'send retry');
select is(public.list_friends()->'outgoing',jsonb_build_array(jsonb_build_object('id',pg_temp.pid(3),
  'display_name','Alice Cooper','username','person_3','relationship','requested')),'person exact keys in outgoing');
select pg_temp.as_user(3);
select is(public.list_friends()->'incoming',jsonb_build_array(jsonb_build_object('id',pg_temp.pid(1),
  'display_name','Person 1','username','alice_1','relationship','incoming')),'incoming person exact keys');
select is(public.send_friend_request(pg_temp.pid(1)),'{"relationship":"friend"}'::jsonb,'crossed request becomes friendship');
select is(public.send_friend_request(pg_temp.pid(1)),'{"relationship":"friend"}'::jsonb,'friend send retry');
select is(public.respond_to_friend_request(pg_temp.pid(1),true),'{"relationship":"friend"}'::jsonb,'accept already friend');
select is(public.respond_to_friend_request(pg_temp.pid(1),false),'{"relationship":"friend"}'::jsonb,'decline does not remove friend');
reset role;
select is((select count(*) from private.friend_requests),0::bigint,'crossed requests leave no pending rows');
select is((select count(*) from private.friendships),1::bigint,'crossed requests leave one canonical friendship');
select is((select count(*) from private.profile_reports),1::bigint,'reports deduplicated, do not block');
set local role authenticated;
select pg_temp.as_user(1);
select is(public.send_friend_request(pg_temp.pid(4)),'{"relationship":"requested"}'::jsonb,'another outgoing');
select pg_temp.as_user(4);
select is(public.respond_to_friend_request(pg_temp.pid(1),true),'{"relationship":"friend"}'::jsonb,'accept incoming');
select is(public.respond_to_friend_request(pg_temp.pid(1),true),'{"relationship":"friend"}'::jsonb,'accept retry');
select pg_temp.as_user(1);
select is(public.list_friends()->'friends'->0->>'display_name','Alice Cooper','friends sorted by display name');
select is(public.remove_friend(pg_temp.pid(4)),'{"relationship":"none"}'::jsonb,'remove actual friend');
select is(public.remove_friend(pg_temp.pid(4)),'{"relationship":"none"}'::jsonb,'remove actual friend retry');
select is(public.send_friend_request(pg_temp.pid(4)),'{"relationship":"requested"}'::jsonb,'request after remove');
select pg_temp.as_user(4);
select is(public.respond_to_friend_request(pg_temp.pid(1),false),'{"relationship":"none"}'::jsonb,'decline incoming');
select is(public.respond_to_friend_request(pg_temp.pid(1),false),'{"relationship":"none"}'::jsonb,'decline retry after deletion');
reset role;
-- Existing challenge grants reachability without exposing a hidden invitee's username/photo.
insert into r values('hidden',pg_temp.challenge(2,1));
update public.profiles set photo_version=md5('photo-two')::uuid where id=pg_temp.pid(2);
set local role authenticated;
select pg_temp.as_user(2);
select lives_ok($$select public.cancel_competition((select id from r where label='hidden'))$$,'cancel retains creator reachability');
select pg_temp.as_user(1);
select pg_temp.as_user(2);
select lives_ok($$select public.send_friend_request(pg_temp.pid(1))$$,'hidden sender requests searchable caller');
select pg_temp.as_user(1);
select is(public.list_friends()->'incoming'->0->>'username','bob_2','incoming hidden sender reveals own username');
select is(jsonb_array_length(public.list_profile_photos(array[pg_temp.pid(2)])->'photos'),1,'incoming hidden sender reveals own photo');
select lives_ok($$select public.respond_to_friend_request(pg_temp.pid(2),false)$$,'decline removes that incoming disclosure');
select is(public.send_friend_request(pg_temp.pid(2)),'{"relationship":"requested"}'::jsonb,'history reaches hidden person');
select is(public.list_friends()->'outgoing'->0->'username','null'::jsonb,'outgoing request cannot expose hidden username');
select is(public.list_profile_photos(array[pg_temp.pid(2)]),'{"photos":[]}'::jsonb,'outgoing request cannot expose hidden photo');
select pg_temp.as_user(2);
select is(public.list_friends()->'incoming'->0->>'username','alice_1','incoming request may expose sender username');
select is(public.respond_to_friend_request(pg_temp.pid(1),true),'{"relationship":"friend"}'::jsonb,'hidden incoming accepted');
select pg_temp.as_user(1);
select is(public.list_friends()->'friends'->1->>'username','bob_2','friend sees hidden username');
select is(pg_temp.people('@bob'),array[pg_temp.pid(2)],'hidden friend is still searchable');
select is(jsonb_array_length(public.list_profile_photos(array[pg_temp.pid(2)])->'photos'),1,'friend sees hidden photo');
select is(public.report_profile_photo(pg_temp.pid(2)),jsonb_build_object('profile_id',pg_temp.pid(2)),'friend can report photo');
select is(public.list_profile_photos(array[pg_temp.pid(2)]),'{"photos":[]}'::jsonb,'photo report still hides friend photo');
reset role;
delete from private.profile_photo_reports where reporter_profile_id=pg_temp.pid(1) and reported_profile_id=pg_temp.pid(2);
-- Both request directions removed even in a legacy/inconsistent pair fixture.
insert into private.friend_requests values(pg_temp.pid(1),pg_temp.pid(2),now()),(pg_temp.pid(2),pg_temp.pid(1),now());
set local role authenticated;
select pg_temp.as_user(1);
select is(public.block_profile(pg_temp.pid(2)),jsonb_build_object('id',pg_temp.pid(2),'display_name','Person 2'),'block exact old person shape');
select is(public.block_profile(pg_temp.pid(2)),jsonb_build_object('id',pg_temp.pid(2),'display_name','Person 2'),'re-block after reachability removed');
select throws_ok($$select public.respond_to_friend_request(pg_temp.pid(2),true)$$,'P0001','request_unavailable','blocked accept');
select is(public.list_profile_photos(array[pg_temp.pid(2)]),'{"photos":[]}'::jsonb,'block hides friend photo');
reset role;
select ok(not private.are_friends(pg_temp.pid(1),pg_temp.pid(2))
  and not exists(select 1 from private.friend_requests where pg_temp.pid(2) in(sender_profile_id,recipient_profile_id)),
  'block removes friendship and both pending directions');
insert into r values('legacy-block',pg_temp.challenge(40,1));
insert into private.friendships values(least(pg_temp.pid(1),pg_temp.pid(40)),greatest(pg_temp.pid(1),pg_temp.pid(40)),now());
insert into private.friend_requests values(pg_temp.pid(1),pg_temp.pid(40),now()),(pg_temp.pid(40),pg_temp.pid(1),now());
set local role authenticated;
select pg_temp.as_user(1);
select lives_ok($$select public.block_challenger((select id from r where label='legacy-block'))$$,'legacy block still works');
reset role;
select ok(not private.are_friends(pg_temp.pid(1),pg_temp.pid(40))
  and not exists(select 1 from private.friend_requests where pg_temp.pid(40) in(sender_profile_id,recipient_profile_id)),
  'legacy block shares relationship purge');
insert into r values('outgoing-cancel',pg_temp.challenge(1,41));
set local role authenticated;
select pg_temp.as_user(41);
select lives_ok($$select public.send_friend_request(pg_temp.pid(1))$$,'invitee can reach searchable sender');
select pg_temp.as_user(1);
select lives_ok($$select public.block_profile(pg_temp.pid(41))$$,'block own pending invitee');
reset role;
select ok((select lifecycle='cancelled' and closed_by_profile_id=pg_temp.pid(1) and closed_at is not null
  from public.competitions where id=(select id from r where label='outgoing-cancel')),'block cancels caller pending challenge');
-- The incoming path must match block_challenger's decline and durable push.
insert into public.device_installations(id,profile_id,installation_id,apns_token,environment,state,supports_challenges)
values(gen_random_uuid(),pg_temp.pid(42),gen_random_uuid(),repeat('d2',32),'sandbox','active',true);
insert into r values('incoming-decline',pg_temp.challenge(42,1));
set local role authenticated;
select pg_temp.as_user(1);
select lives_ok($$select public.block_profile(pg_temp.pid(42))$$,'block pending incoming challenger by profile');
reset role;
select ok((select c.lifecycle='declined' and c.closed_by_profile_id=pg_temp.pid(1)
    and c.closed_at is not null and c.updated_at=c.closed_at and p.state='pending'
  from public.competitions c join public.competition_participants p
    on p.competition_id=c.id and p.role='invitee'
  where c.id=(select id from r where label='incoming-decline')),
  'profile block declines the incoming challenge with the same state as block_challenger');
select results_eq($$select recipient_profile_id,source_profile_id,state from private.competition_notification_work
  where competition_id=(select id from r where label='incoming-decline') and kind='challenge_declined'$$,
  $$values (pg_temp.pid(42),pg_temp.pid(1),'pending'::text)$$,
  'profile block queues exactly one challenge_declined push to the sender');
set local role authenticated;
select pg_temp.as_user(1);
select lives_ok($$select public.block_profile(pg_temp.pid(42))$$,'re-block incoming challenger');
reset role;
select is((select count(*) from private.competition_notification_work
  where competition_id=(select id from r where label='incoming-decline') and kind='challenge_declined'),
  1::bigint,'re-block does not queue another decline push');
-- Rate validation precedes accounting; shared quota resets after a minute.
delete from private.people_search_limits where profile_id=pg_temp.pid(1);
set local role authenticated;
select pg_temp.as_user(1);
select throws_ok($$select public.search_people('ab')$$,'22023','invalid_query','invalid search before counter');
select throws_ok($$select public.username_available('!bad')$$,'22023','invalid_username','invalid availability before counter');
reset role;
select is((select count(*) from private.people_search_limits where profile_id=pg_temp.pid(1)),0::bigint,'invalid inputs do not create counter');
set local role authenticated;
select lives_ok($$do $b$ begin for n in 1..15 loop perform public.search_people('nothing');
  perform public.username_available('nothing'); end loop; end $b$;$$,'thirty shared searches allowed');
select throws_ok($$select public.search_people('nothing')$$,'P0001','search_rate_limited','search quota');
select throws_ok($$select public.username_available('nothing')$$,'P0001','search_rate_limited','availability same quota');
select throws_ok($$select public.search_people('ab')$$,'22023','invalid_query','validation still first when exhausted');
reset role;
update private.people_search_limits set window_started_at=now()-interval '61 seconds' where profile_id=pg_temp.pid(1);
set local role authenticated;
select lives_ok($$select public.search_people('nothing')$$,'new window allowed');
reset role;
select is((select used from private.people_search_limits where profile_id=pg_temp.pid(1)),1,'window resets to one');
-- Sender lock makes the 100-request bound safe across different recipients.
insert into private.friend_requests select pg_temp.pid(50),pg_temp.pid(n),now() from generate_series(51,125) n;
insert into private.friend_requests select pg_temp.pid(50),pg_temp.pid(n),now() from generate_series(1,25) n;
update public.profiles set username='limit_target' where id=pg_temp.pid(126);
set local role authenticated;
select pg_temp.as_user(50);
select throws_ok($$select public.send_friend_request(pg_temp.pid(126))$$,'P0001','friend_request_limit','one hundred outgoing limit');
select is(public.send_friend_request(pg_temp.pid(51)),'{"relationship":"requested"}'::jsonb,'retry at limit succeeds');
reset role;
-- Deactivation clears private state both ways and immediately frees username.
insert into private.friendships values(least(pg_temp.pid(3),pg_temp.pid(4)),greatest(pg_temp.pid(3),pg_temp.pid(4)),now());
insert into private.friend_requests values(pg_temp.pid(3),pg_temp.pid(5),now()),(pg_temp.pid(6),pg_temp.pid(3),now());
insert into private.profile_reports values(pg_temp.pid(3),pg_temp.pid(5),now());
insert into private.people_search_limits values(pg_temp.pid(3),now(),1) on conflict do nothing;
update public.profiles set state='deleting' where id=pg_temp.pid(3);
select ok((select username is null from public.profiles where id=pg_temp.pid(3)),'deactivation clears username before constraint');
select is((select count(*) from private.friendships where pg_temp.pid(3) in(profile_low,profile_high)),0::bigint,'purge friendships');
select is((select count(*) from private.friend_requests where pg_temp.pid(3) in(sender_profile_id,recipient_profile_id)),0::bigint,'purge requests both ways');
select is((select count(*) from private.profile_reports where pg_temp.pid(3) in(reporter_profile_id,reported_profile_id)),0::bigint,'purge reports both ways');
select is((select count(*) from private.people_search_limits where profile_id=pg_temp.pid(3)),0::bigint,'purge limit');
set local role authenticated;
select pg_temp.as_user(4);
select is(public.set_username('person_3')->>'username','person_3','deactivation frees username');
select throws_ok($$select public.respond_to_friend_request(pg_temp.pid(3),true)$$,'P0001','request_unavailable','accept deactivated');
select throws_ok($$select public.block_profile(pg_temp.pid(3))$$,'P0001','recipient_unavailable','block deactivated');
select throws_ok($$select public.report_profile(pg_temp.pid(3))$$,'P0001','recipient_unavailable','report deactivated');
select pg_temp.as_user(3);
select throws_ok($$select public.get_friend_settings()$$,'42501','active_profile_required','deactivated caller');
reset role;
update public.profiles set state='anonymized',auth_user_id=null,display_name='Former competitor',anonymized_at=now() where id=pg_temp.pid(3);
select throws_ok($$update public.profiles set username='revived' where id=pg_temp.pid(3)$$,'23514','anonymized profile state is terminal','anonymized username stays null');
-- Old endpoints retain closed key sets.
set local role authenticated;
select pg_temp.as_user(1);
select is((select array_agg(k order by k) from jsonb_object_keys(public.bootstrap_current_profile('Person 1')) k),array['display_name','id'],'bootstrap old shape');
select is((select array_agg(k order by k) from jsonb_object_keys(public.update_current_profile('Person 1')) k),array['display_name','id'],'update profile old shape');
select is((select array_agg(k order by k) from jsonb_object_keys(public.list_challenges()) k),array['closed','incoming'],'challenge list old shape');
select is((select array_agg(k order by k) from jsonb_object_keys(public.list_blocked_profiles()->'blocked'->0) k),array['display_name','id'],'blocked row old shape');
select throws_ok($$select * from private.friendships$$,'42501',null,'direct friendships denied');
select throws_ok($$select * from private.friend_requests$$,'42501',null,'direct requests denied');
select throws_ok($$select * from private.profile_reports$$,'42501',null,'direct reports denied');
select throws_ok($$select * from private.people_search_limits$$,'42501',null,'direct limits denied');
reset role;
select * from finish();
rollback;
