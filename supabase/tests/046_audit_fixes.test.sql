begin;
-- Regressions for 20261113191000_audit_fixes. Rolled back.
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.pid(n integer) returns uuid language sql immutable as $$ select md5('audit-profile-' || n)::uuid $$;
create function pg_temp.uid(n integer) returns uuid language sql immutable as $$ select md5('audit-auth-' || n)::uuid $$;
create function pg_temp.as_user(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object('role','authenticated','sub',pg_temp.uid(n))::text, true);
$$;
create function pg_temp.invite(sender integer, recipient integer) returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(extensions.digest(gen_random_uuid()::text, 'sha256'), 'UTC', null,
    pg_temp.uid(sender), gen_random_uuid(), 1::smallint, pg_temp.pid(recipient));
end; $$;
create function pg_temp.cancel(sender integer, cid uuid) returns void language plpgsql as $$
begin perform pg_temp.as_user(sender); perform public.cancel_competition(cid); end; $$;
-- An accepted duel whose Day 1 was `days_ago` days ago (UTC).
create function pg_temp.duel(a integer, b integer, days_ago integer) returns uuid language plpgsql as $$
declare cid uuid := pg_temp.invite(a, b);
begin
  perform pg_temp.as_user(b); perform public.accept_competition_challenge(cid);
  update public.competitions set start_day = current_date - days_ago, lifecycle = 'active',
    invitation_expires_at = (current_date - days_ago)::timestamp at time zone 'UTC',
    best_available_deadline = (current_date - days_ago + 8)::timestamp at time zone 'UTC' where id = cid;
  return cid;
end; $$;
create function pg_temp.score(n integer, cid uuid, day integer, rev bigint, move integer) returns jsonb language plpgsql as $$
begin
  perform pg_temp.as_user(n);
  return public.submit_score_revision(cid, gen_random_uuid(), day, rev, now(), 'activeEnergyKilocalories', 'standHours',
    move, 0, 0, 'available', 'healthcomp.activity-score.v1');
end; $$;

insert into auth.users(id) select pg_temp.uid(n) from generate_series(1, 12) n;
insert into public.profiles(id, auth_user_id, display_name, state)
  select pg_temp.pid(n), pg_temp.uid(n), 'Audit ' || n, 'active' from generate_series(1, 12) n;
insert into public.device_installations(profile_id, installation_id, apns_token, environment, state,
  supports_challenges, supports_reactions, supports_group_matches)
  select pg_temp.pid(n), md5('audit-install-' || n)::uuid, md5('audit-token-' || n) || md5('audit-token-' || n),
    'sandbox', 'active', true, true, true from generate_series(1, 12) n;
create temporary table gm(label text primary key, id uuid);

-- Participant policies check a set once, not a definer function per row.
select ok(not exists (select 1 from pg_policies where qual like '%is_competition_participant(%'),
  'no policy calls the per-row participant check');

-- A usernameless co-invitee seen only in a third party's lineup is no credential.
select pg_temp.as_user(1);
insert into gm values ('third-party', (public.create_group_match('three_way', jsonb_build_array(
  jsonb_build_object('kind','human','profile_id',pg_temp.pid(1)), jsonb_build_object('kind','human','profile_id',pg_temp.pid(2)),
  jsonb_build_object('kind','human','profile_id',pg_temp.pid(3))), 'UTC', gen_random_uuid())->>'competition_id')::uuid);
select throws_ok($$select pg_temp.invite(2, 3)$$, 'P0001', 'recipient_unavailable', 'co-invitee cannot challenge a usernameless peer by id');
select pg_temp.as_user(2);
select throws_ok($$select public.resolve_invitation_recipient(pg_temp.pid(3))$$, 'P0001', 'recipient_unavailable',
  'co-invitee cannot preview a usernameless peer by id');
select lives_ok($$select pg_temp.invite(2, 4)$$, 'the old app''s usernameless id path still works without a group link');

-- Group lists name each reaction key, so a new column never reaches installed builds.
insert into private.competition_reactions(competition_id, author_profile_id, target_profile_id, day_ordinal, reaction)
  values ((select id from gm where label = 'third-party'), pg_temp.pid(1), pg_temp.pid(2), 1, 'clap');
alter table private.competition_reactions add column audit_extra integer default 1;
select set_eq($$select jsonb_object_keys(private.group_match_projection((select id from gm where label = 'third-party'), pg_temp.pid(1))->'reactions'->0)$$,
  array['competition_id','author_profile_id','target_profile_id','day_ordinal','reaction','created_at','updated_at'],
  'reaction keys are exactly the seven installed builds accept');

-- A create/cancel loop pushes once an hour.
insert into gm values ('loop-1', pg_temp.invite(5, 6));
select pg_temp.cancel(5, (select id from gm where label = 'loop-1'));
insert into gm values ('loop-2', pg_temp.invite(5, 6));
select is((select state from private.competition_notification_work where competition_id = (select id from gm where label = 'loop-2')
  and kind = 'challenge_received'), 'suppressed', 'a challenge right after a cancelled one is not pushed');

-- A rename does not wake the sender of a challenge this person declined.
insert into gm values ('declined', pg_temp.invite(7, 8));
select pg_temp.as_user(8); select public.decline_competition_challenge((select id from gm where label = 'declined'));
update public.profiles set display_name = 'Renamed', updated_at = now() where id = pg_temp.pid(8);
select ok(not exists (select 1 from public.competition_change_log where competition_id = (select id from gm where label = 'declined')
  and change_kind = 'profile_presentation_changed'), 'no rename event in a declined challenge');

-- Invite caps: 10 a day to one person.
do $$ begin
  for n in 1..10 loop perform pg_temp.cancel(9, pg_temp.invite(9, 10)); end loop;
end $$;
select throws_ok($$select pg_temp.invite(9, 10)$$, 'P0001', 'invite_rate_limited', 'the eleventh challenge to one person in a day is refused');

-- Contract for players west of the creator: a Day 7 score read after the
-- creator's Day 7 ended still counts until that player attests stable or the
-- best-available deadline (24 hours later) passes.
insert into gm values ('west', pg_temp.duel(1, 11, 7));
select is(pg_temp.score(11, (select id from gm where label = 'west'), 7, 1, 5000)->>'disposition', 'appended',
  'a late Day 7 reading is accepted before stable attestation');

-- Deleting an account settles a duel whose week is over instead of cancelling it.
insert into gm values ('ended', pg_temp.duel(12, 2, 7));
select pg_temp.score(2, (select id from gm where label = 'ended'), 1, 1, 9000);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into auth.identities(id, provider_id, user_id, identity_data, provider, created_at, updated_at)
  values (gen_random_uuid(), 'audit-apple-12', pg_temp.uid(12), '{"sub":"audit-apple-12"}', 'apple', now(), now());
select public.begin_account_deletion(pg_temp.uid(12));
select public.store_account_deletion_apple_token(pg_temp.pid(12), 'synthetic-apple-refresh-token-for-audit-test', 'com.example.healthcomp');
select is((select lifecycle from public.competitions where id = (select id from gm where label = 'ended')), 'completed',
  'a finished week is settled, not cancelled');
select is((select winner_profile_id from public.competition_results where competition_id = (select id from gm where label = 'ended')),
  pg_temp.pid(2), 'the opponent keeps the win');

-- Every RPC a signed-in person can call is a definer with an empty search
-- path, and none is callable signed out or by the service role.
select is_empty($$
  select p.oid::regprocedure::text from pg_proc p
  where p.pronamespace = 'public'::regnamespace and has_function_privilege('authenticated', p.oid, 'execute')
    and (not p.prosecdef or not coalesce(p.proconfig @> array['search_path=""'], false)
      or has_function_privilege('anon', p.oid, 'execute') or has_function_privilege('service_role', p.oid, 'execute'))
$$, 'authenticated RPCs are definers with empty search paths, closed to anon and service_role');

set constraints all immediate;
select * from finish();
rollback;
