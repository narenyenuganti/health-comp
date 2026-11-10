begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();
create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('friends-invite-profile-'||n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('friends-invite-auth-'||n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims',jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text,true)
$$;
create function pg_temp.link(n integer) returns text language plpgsql as $$
begin
  perform pg_temp.as_user(n);
  return public.get_my_challenge_link()->>'code';
end;
$$;
create function pg_temp.invite(sender integer, recipient integer, link text default null, parent uuid default null,
  key uuid default gen_random_uuid(), token bytea default extensions.digest(gen_random_uuid()::text,'sha256'))
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  if link is not null then
    return public.create_competition_invite_from_link(token,'UTC',pg_temp.uid(sender),key,1::smallint,link);
  end if;
  return public.create_competition_invite(token,'UTC',parent,pg_temp.uid(sender),key,1::smallint,pg_temp.pid(recipient));
end;
$$;
create function pg_temp.finished(sender integer, recipient integer) returns uuid language plpgsql as $$
declare c uuid;
begin
  c := pg_temp.invite(sender,recipient);
  update public.competition_participants set state='accepted',joined_at=now()
    where competition_id=c and profile_id=pg_temp.pid(recipient);
  update public.competitions set lifecycle='completed',start_day=current_date-10,best_available_deadline=now()+interval '30 days'
    where id=c;
  return c;
end;
$$;
insert into auth.users(id) select pg_temp.uid(n) from generate_series(1,20) n;
insert into public.profiles(id,auth_user_id,display_name,state)
select pg_temp.pid(n),pg_temp.uid(n),'Invite Person '||n,'active' from generate_series(1,20) n;
create temporary table r(label text primary key,id uuid,code text);
grant all on r to authenticated;
insert into r values('parent',pg_temp.finished(1,2),pg_temp.link(2));
insert into r values('cancelled',pg_temp.invite(3,4),null);
select pg_temp.as_user(3);
select lives_ok($$select public.cancel_competition((select id from r where label='cancelled'))$$,'seed cancelled history');
insert into r values('default',null,pg_temp.link(5)),('reset',null,pg_temp.link(6)),('only',null,pg_temp.link(7));
update public.profiles set username='invite_'||n from generate_series(2,7) n where id=pg_temp.pid(n);
-- B: new discovery cannot bypass links; old clients' usernameless route still works.
select throws_ok($$select pg_temp.invite(1,5)$$,'P0001','recipient_unavailable','B id from search rejected');
select pg_temp.as_user(1);
select throws_ok($$select public.resolve_invitation_recipient(pg_temp.pid(5))$$,'P0001','recipient_unavailable','B id preview rejected');
select is(public.resolve_challenge_link((select code from r where label='default')),
  jsonb_build_object('display_name','Invite Person 5'),'default link preview exact old shape');
select lives_ok($$select pg_temp.invite(1,5,(select code from r where label='default'))$$,'B current link creation permitted');
select lives_ok($$select pg_temp.invite(1,8)$$,'B usernameless old app id path permitted');
select lives_ok($$select pg_temp.invite(1,2)$$,'B shipped Challenge Again null parent and link allowed after finished match');
select lives_ok($$select pg_temp.invite(3,4)$$,'B played any lifecycle includes cancelled challenges');
select pg_temp.as_user(1);
select is(public.resolve_invitation_recipient(pg_temp.pid(2)),jsonb_build_object('id',pg_temp.pid(2),'display_name','Invite Person 2'),'B prior players id preview old shape');
-- A: reset link history; friends bypass reset but keep all retry/pair rules.
insert into r values('reset-seed',pg_temp.invite(9,6,(select code from r where label='reset')),null);
select pg_temp.as_user(9);
select lives_ok($$select public.cancel_competition((select id from r where label='reset-seed'))$$,'reset seed cancelled');
select pg_temp.as_user(6);
select lives_ok($$select public.reset_my_challenge_link()$$,'reset target link');
select throws_ok($$select pg_temp.invite(9,6)$$,'P0001','recipient_unavailable','A reset denies nonfriend id even with prior challenge');
select pg_temp.as_user(9);
select throws_ok($$select public.resolve_invitation_recipient(pg_temp.pid(6))$$,'P0001','recipient_unavailable','A reset denies id preview');
select throws_ok($$select public.resolve_challenge_link((select code from r where label='reset'))$$,'P0001','recipient_unavailable','old reset code unavailable');
insert into private.friendships values(least(pg_temp.pid(9),pg_temp.pid(6)),greatest(pg_temp.pid(9),pg_temp.pid(6)),now());
select pg_temp.as_user(9);
select is(public.resolve_invitation_recipient(pg_temp.pid(6)),jsonb_build_object('id',pg_temp.pid(6),'display_name','Invite Person 6'),'A friend bypass id preview guard');
select lives_ok($$select pg_temp.invite(9,6)$$,'A friend bypass create reset guard');
-- A/B: friendship with no prior competition authorizes direct challenges.
insert into private.friendships values(least(pg_temp.pid(10),pg_temp.pid(7)),greatest(pg_temp.pid(10),pg_temp.pid(7)),now());
select lives_ok($$select pg_temp.invite(10,7)$$,'B friend with no history can challenge by id');
-- C: policy is enforced after rematch validation, before pending pair conflicts.
update public.profiles set challenge_policy='friends_only' where id in(pg_temp.pid(2),pg_temp.pid(5),pg_temp.pid(7));
select throws_ok($$select pg_temp.invite(1,2)$$,'P0001','recipient_unavailable','C id with played history denied before existing pending conflict');
select throws_ok($$select pg_temp.invite(1,2,null,(select id from r where label='parent'))$$,'P0001','recipient_unavailable','C valid rematch denied');
select throws_ok($$select pg_temp.invite(1,7,(select code from r where label='only'))$$,'P0001','recipient_unavailable','C link creation denied');
select pg_temp.as_user(1);
select throws_ok($$select public.resolve_challenge_link((select code from r where label='only'))$$,'P0001','recipient_unavailable','C link preview denied');
select throws_ok($$select public.resolve_invitation_recipient(pg_temp.pid(2))$$,'P0001','recipient_unavailable','C history id preview denied');
select throws_ok($$select pg_temp.invite(1,2,null,md5('bogus')::uuid)$$,'42501','rematch_not_allowed','bogus rematch under friends_only');
update public.profiles set challenge_policy='friends_and_link' where id=pg_temp.pid(2);
select throws_ok($$select pg_temp.invite(1,2,null,md5('bogus')::uuid)$$,'42501','rematch_not_allowed','same bogus rematch under friends_and_link');
select pg_temp.as_user(10);
select is(public.resolve_challenge_link((select code from r where label='only')),
  jsonb_build_object('display_name','Invite Person 7'),'C friend can preview friends_only link');
select is(public.resolve_invitation_recipient(pg_temp.pid(7)),jsonb_build_object('id',pg_temp.pid(7),'display_name','Invite Person 7'),'C friend can preview id');
select throws_ok($$select pg_temp.invite(10,7)$$,'P0001','pending_invitation_exists','friend keeps pending conflict');
-- Friends-only valid rematch success on a separate completed pair.
insert into r values('friend-parent',pg_temp.finished(11,12),pg_temp.link(12));
update public.profiles set username='invite_12',challenge_policy='friends_only' where id=pg_temp.pid(12);
insert into private.friendships values(least(pg_temp.pid(11),pg_temp.pid(12)),greatest(pg_temp.pid(11),pg_temp.pid(12)),now());
select lives_ok($$select pg_temp.invite(11,12,null,(select id from r where label='friend-parent'))$$,'C friends_only friend rematch permitted');
-- Retry return precedes new privacy checks, and restores exactly the same invite.
insert into r values('retry-key',gen_random_uuid(),null);
insert into r values('retry',pg_temp.invite(13,14,null,null,(select id from r where label='retry-key'),decode(repeat('ab',32),'hex')),null);
update public.profiles set username='invite_14',challenge_policy='friends_only' where id=pg_temp.pid(14);
select is(pg_temp.invite(13,14,null,null,(select id from r where label='retry-key'),decode(repeat('ab',32),'hex')),
  (select id from r where label='retry'),'exact retry returns before changed privacy');
select pg_temp.as_user(14);
select lives_ok($$select public.reset_my_challenge_link()$$,'privacy target reset');
select is(pg_temp.invite(13,14,null,null,(select id from r where label='retry-key'),decode(repeat('ab',32),'hex')),
  (select id from r where label='retry'),'retry also survives reset');
select throws_ok($$select pg_temp.invite(13,14,null,null,(select id from r where label='retry-key'),decode(repeat('cd',32),'hex'))$$,
  'P0001','idempotency_conflict','retry mismatch remains idempotency conflict');
-- C friends-only applies to usernameless old-app targets too.
update public.profiles set challenge_policy='friends_only' where id=pg_temp.pid(15);
select throws_ok($$select pg_temp.invite(1,15)$$,'P0001','recipient_unavailable','C old-app id path respects policy');
select pg_temp.as_user(1);
select throws_ok($$select public.resolve_invitation_recipient(pg_temp.pid(15))$$,'P0001','recipient_unavailable','C old-app id preview respects policy');
select * from finish();
rollback;
