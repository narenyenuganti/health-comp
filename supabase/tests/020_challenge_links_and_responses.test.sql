begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

-- Grants: every new RPC is authenticated-only; private helpers and the link
-- table are unreachable from API roles.
select is((
  select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname in ('accept_competition_challenge',
    'decline_competition_challenge', 'cancel_competition', 'preview_competition_invite',
    'list_challenges', 'get_my_challenge_link', 'resolve_challenge_link')
    and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')
), 7::bigint, 'the seven challenge RPCs are executable by authenticated only');
select is((
  select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and p.proname in ('new_challenge_link_code_v1',
    'match_in_progress_between', 'enqueue_challenge_notification',
    'accept_pending_invitation', 'require_active_caller_profile_id')
    and not has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
), 5::bigint, 'private challenge helpers are not executable by API roles');
select ok(not has_table_privilege('authenticated', 'private.challenge_links', 'select')
  and not has_table_privilege('anon', 'private.challenge_links', 'select')
  and not has_table_privilege('service_role', 'private.challenge_links', 'select'),
  'challenge links are not readable by API roles');

-- A Naren (sender), B Maya (recipient), C Third, D Dana, E Eve.
insert into auth.users (id) values
  ('c7000000-0000-4000-8000-000000000001'), ('c7000000-0000-4000-8000-000000000002'),
  ('c7000000-0000-4000-8000-000000000003'), ('c7000000-0000-4000-8000-000000000004'),
  ('c7000000-0000-4000-8000-000000000005');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c7100000-0000-4000-8000-000000000001', 'c7000000-0000-4000-8000-000000000001', 'Naren', 'active'),
  ('c7100000-0000-4000-8000-000000000002', 'c7000000-0000-4000-8000-000000000002', 'Maya', 'active'),
  ('c7100000-0000-4000-8000-000000000003', 'c7000000-0000-4000-8000-000000000003', 'Third', 'active'),
  ('c7100000-0000-4000-8000-000000000004', 'c7000000-0000-4000-8000-000000000004', 'Dana', 'active'),
  ('c7100000-0000-4000-8000-000000000005', 'c7000000-0000-4000-8000-000000000005', 'Eve', 'active');
-- Naren has two installations; everyone else one.
insert into public.device_installations (id, profile_id, installation_id, apns_token, environment, state) values
  ('c7200000-0000-4000-8000-000000000001', 'c7100000-0000-4000-8000-000000000001', 'c7300000-0000-4000-8000-000000000001', repeat('a1', 32), 'sandbox', 'active'),
  ('c7200000-0000-4000-8000-000000000006', 'c7100000-0000-4000-8000-000000000001', 'c7300000-0000-4000-8000-000000000006', repeat('a6', 32), 'sandbox', 'active'),
  ('c7200000-0000-4000-8000-000000000002', 'c7100000-0000-4000-8000-000000000002', 'c7300000-0000-4000-8000-000000000002', repeat('a2', 32), 'sandbox', 'active'),
  ('c7200000-0000-4000-8000-000000000003', 'c7100000-0000-4000-8000-000000000003', 'c7300000-0000-4000-8000-000000000003', repeat('a3', 32), 'sandbox', 'active'),
  ('c7200000-0000-4000-8000-000000000004', 'c7100000-0000-4000-8000-000000000004', 'c7300000-0000-4000-8000-000000000004', repeat('a4', 32), 'sandbox', 'active');

create temporary table r (label text primary key, id uuid, v jsonb);
grant all on r to authenticated, service_role;

create function pg_temp.challenge(sender_auth uuid, recipient uuid, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', null, sender_auth, key, 1::smallint, recipient);
end;
$$;
create function pg_temp.challenge_work(target uuid, target_kind text)
returns table (recipient uuid, source uuid, state text) language sql as $$
  select recipient_profile_id, source_profile_id, state from private.competition_notification_work
  where competition_id = target and kind = target_kind order by installation_id;
$$;
create function pg_temp.keys(value jsonb) returns text[] language sql as $$
  select array_agg(k order by k) from jsonb_object_keys(value) k;
$$;

-- Eve challenges Third before Eve's account starts deleting (lease and preview below).
insert into r (label, id) values ('ec1', pg_temp.challenge('c7000000-0000-4000-8000-000000000005',
  'c7100000-0000-4000-8000-000000000003', 'ce', 'c7400000-0000-4000-8000-0000000000e1'));

-- Challenge links.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
insert into r (label, v) values ('maya-link', public.get_my_challenge_link());
select ok((select v->>'code' ~ '^[A-Za-z0-9_-]{22}$' and pg_temp.keys(v) = array['code'] from r where label = 'maya-link'),
  'a challenge link code is 22 base64url characters and the only key');
select is(public.get_my_challenge_link(), (select v from r where label = 'maya-link'),
  'the challenge link is stable across calls');
select throws_ok($$select public.resolve_challenge_link((select v->>'code' from r where label = 'maya-link'))$$,
  'P0001', 'own_challenge_link', 'resolving your own link is reported as such');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000005"}', true);
insert into r (label, v) values ('eve-link', public.get_my_challenge_link());
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select is(public.resolve_challenge_link((select v->>'code' from r where label = 'maya-link')),
  '{"id":"c7100000-0000-4000-8000-000000000002","display_name":"Maya"}'::jsonb,
  'a challenge link resolves to exactly one id and display name');
select is((select count(*) from public.profiles), 1::bigint,
  'resolving a challenge link grants no profile directory');
select throws_ok($$select public.resolve_challenge_link('AAAAAAAAAAAAAAAAAAAAAA')$$,
  'P0001', 'recipient_unavailable', 'an unknown code is unavailable');
select throws_ok($$select public.resolve_challenge_link('short')$$,
  'P0001', 'recipient_unavailable', 'a malformed code is unavailable');
select throws_ok($$select public.resolve_challenge_link(null)$$,
  'P0001', 'recipient_unavailable', 'a missing code is unavailable');
select throws_ok($$select count(*) from private.challenge_links$$,
  '42501', null, 'authenticated cannot read the challenge link table');
reset role;
update public.profiles set state = 'deleting' where id = 'c7100000-0000-4000-8000-000000000005';
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.resolve_challenge_link((select v->>'code' from r where label = 'eve-link'))$$,
  'P0001', 'recipient_unavailable', 'an inactive owner''s link is unavailable');
reset role;

-- Create: Naren challenges Maya; the recipient is told once.
insert into r (label, id) values ('ab1', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000002', 'c1', 'c7400000-0000-4000-8000-000000000001'));
select is(pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000002', 'c1', 'c7400000-0000-4000-8000-000000000001'),
  (select id from r where label = 'ab1'), 'an exact create retry returns the same challenge');
select results_eq($$select * from pg_temp.challenge_work((select id from r where label = 'ab1'), 'challenge_received')$$,
  $$values ('c7100000-0000-4000-8000-000000000002'::uuid, 'c7100000-0000-4000-8000-000000000001'::uuid, 'pending'::text)$$,
  'create enqueues one challenge_received per recipient installation, and a retry none');
select ok((select count(*) > 0 from realtime.messages m
  where m.topic = 'profile:c7100000-0000-4000-8000-000000000002' and m.event = 'competition_changed'),
  'the pending invitee receives a competition_changed wakeup on create');
select throws_ok($$select pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000002', 'c2', 'c7400000-0000-4000-8000-000000000002')$$,
  'P0001', 'pending_invitation_exists', 'a second pending challenge to the same person is still rejected');
select throws_ok($$select pg_temp.challenge('c7000000-0000-4000-8000-000000000002',
  'c7100000-0000-4000-8000-000000000001', 'c3', 'c7400000-0000-4000-8000-000000000003')$$,
  'P0001', 'incoming_challenge_exists', 'a reciprocal challenge is rejected');
insert into r (label, v) select 'ab1-preview', jsonb_build_object('competition_id', c.id, 'state', 'pending',
  'sender', jsonb_build_object('id', 'c7100000-0000-4000-8000-000000000001'::uuid, 'display_name', 'Naren'),
  'time_zone_identifier', 'America/Los_Angeles', 'expires_at', c.invitation_expires_at)
from public.competitions c where c.id = (select id from r where label = 'ab1');

-- Preview: recipient only.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is(public.preview_competition_invite(decode(repeat('c1', 32), 'hex')),
  (select v from r where label = 'ab1-preview'),
  'the recipient previews exactly the sender, time zone and expiry');
select throws_ok($$select public.preview_competition_invite(decode(repeat('cf', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'an unknown link is unavailable');
select is(public.list_challenges()->'incoming',
  jsonb_build_array(jsonb_build_object('competition_id', (select id from r where label = 'ab1'),
    'sender', (select v->'sender' from r where label = 'ab1-preview'),
    'time_zone_identifier', 'America/Los_Angeles',
    'created_at', (select (v->>'expires_at')::timestamptz - interval '24 hours' from r where label = 'ab1-preview'),
    'expires_at', (select v->'expires_at' from r where label = 'ab1-preview'))),
  'the recipient lists the incoming challenge with names only');
select is(public.list_challenges()->'closed', '[]'::jsonb, 'nothing closed yet');
select is(pg_temp.keys(public.list_challenges()), array['closed', 'incoming'],
  'the challenge list has exactly two keys');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.preview_competition_invite(decode(repeat('c1', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'a third account previewing a live link gets the same unavailable error');
select is(public.list_challenges()->'incoming', '[]'::jsonb,
  'other recipients'' challenges and inactive senders'' challenges are not listed');
select throws_ok($$select public.preview_competition_invite(decode(repeat('ce', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'a challenge from an inactive sender is unavailable');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.preview_competition_invite(decode(repeat('c1', 32), 'hex'))$$,
  'P0001', 'cannot_claim_own_invite', 'the creator previewing their own link is told so');
select is(public.list_challenges()->'incoming', '[]'::jsonb, 'the sender has nothing incoming');

-- Accept in the app, without the token.
select throws_ok($$select public.accept_competition_challenge((select id from r where label = 'ab1'))$$,
  'P0001', 'cannot_claim_own_invite', 'the creator cannot accept their own challenge');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.accept_competition_challenge((select id from r where label = 'ab1'))$$,
  'P0001', 'invite_unavailable', 'a third account cannot accept by id');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is(public.accept_competition_challenge((select id from r where label = 'ab1')),
  jsonb_build_object('competition_id', (select id from r where label = 'ab1')),
  'the bound recipient accepts by id');
select is(public.accept_competition_challenge((select id from r where label = 'ab1')),
  jsonb_build_object('competition_id', (select id from r where label = 'ab1')),
  'accept by id is idempotent for the recipient');
select is(public.claim_competition_invite(decode(repeat('c1', 32), 'hex')),
  (select id from r where label = 'ab1'), 'claim after accept-by-id returns the same id');
select is(public.preview_competition_invite(decode(repeat('c1', 32), 'hex'))->>'state', 'accepted',
  'after accepting, the preview state is accepted');
reset role;
select ok((select lifecycle = 'scheduled'
    and start_day = (now() at time zone 'America/Los_Angeles')::date + 1
    and best_available_deadline = (((now() at time zone 'America/Los_Angeles')::date + 1 + 8)::timestamp
      at time zone 'America/Los_Angeles')
  from public.competitions where id = (select id from r where label = 'ab1')),
  'accept by id schedules the match exactly like claim');
select is((select count(*) from public.competition_change_log
  where competition_id = (select id from r where label = 'ab1')),
  (select next_server_seq - 1 from public.competitions where id = (select id from r where label = 'ab1')),
  'accept by id keeps a gap-free server cursor');

-- Overlap: a scheduled match blocks new challenges and legacy reciprocal accepts.
select throws_ok($$select pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000002', 'c4', 'c7400000-0000-4000-8000-000000000004')$$,
  'P0001', 'active_match_exists', 'create is blocked while the pair has a scheduled match');
select throws_ok($$select pg_temp.challenge('c7000000-0000-4000-8000-000000000002',
  'c7100000-0000-4000-8000-000000000001', 'c5', 'c7400000-0000-4000-8000-000000000005')$$,
  'P0001', 'active_match_exists', 'the other direction is blocked too');
-- A pre-existing reciprocal pending challenge (created before this rule).
set constraints all deferred;
insert into public.competitions (id, creator_profile_id, invited_profile_id, time_zone_identifier,
  scoring_policy_identity, lifecycle, invitation_expires_at)
values ('c7500000-0000-4000-8000-000000000001', 'c7100000-0000-4000-8000-000000000002',
  'c7100000-0000-4000-8000-000000000001', 'UTC', 'healthcomp.activity-score.v1', 'pending',
  now() + interval '1 hour');
insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('c7500000-0000-4000-8000-000000000001', 'c7100000-0000-4000-8000-000000000002', 'creator', 'accepted'),
  ('c7500000-0000-4000-8000-000000000001', 'c7100000-0000-4000-8000-000000000001', 'invitee', 'pending');
insert into public.competition_invites (competition_id, token_digest, expires_at)
values ('c7500000-0000-4000-8000-000000000001', decode(repeat('c9', 32), 'hex'), now() + interval '1 hour');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.accept_competition_challenge('c7500000-0000-4000-8000-000000000001')$$,
  'P0001', 'active_match_exists', 'a legacy reciprocal challenge cannot be accepted in the app during a match');
select throws_ok($$select public.claim_competition_invite(decode(repeat('c9', 32), 'hex'))$$,
  'P0001', 'active_match_exists', 'nor by its link');
select throws_ok($$select public.preview_competition_invite(decode(repeat('c9', 32), 'hex'))$$,
  'P0001', 'active_match_exists', 'and its preview says why');
select throws_ok($$select public.cancel_competition('c7500000-0000-4000-8000-000000000001')$$,
  'P0001', 'cancel_not_allowed', 'the recipient cannot cancel a pending challenge');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is(public.cancel_competition('c7500000-0000-4000-8000-000000000001'),
  '{"competition_id":"c7500000-0000-4000-8000-000000000001"}'::jsonb,
  'the creator withdraws a pending challenge');
reset role;
select is((select count(*) from private.competition_notification_work
  where competition_id = 'c7500000-0000-4000-8000-000000000001'), 0::bigint,
  'withdrawing a challenge tells no one');
-- Synthetic time boundary: the match's Day 7 has passed (tallying).
update public.competitions set start_day = start_day - 8
where id = (select id from r where label = 'ab1');
select lives_ok($$insert into r (label, id) values ('ab2', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000002', 'c6', 'c7400000-0000-4000-8000-000000000006'))$$,
  'a new challenge is allowed once the match week has ended');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select is(public.cancel_competition((select id from r where label = 'ab2')),
  jsonb_build_object('competition_id', (select id from r where label = 'ab2')),
  'the creator cancels a pending challenge');
select is(public.cancel_competition((select id from r where label = 'ab2')),
  jsonb_build_object('competition_id', (select id from r where label = 'ab2')),
  'cancel is idempotent for the person who cancelled');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is(public.list_challenges(), '{"incoming":[],"closed":[]}'::jsonb,
  'a withdrawn challenge leaves the recipient''s list without a closed row');
select throws_ok($$select public.preview_competition_invite(decode(repeat('c6', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'a cancelled challenge is unavailable');
select throws_ok($$select public.accept_competition_challenge((select id from r where label = 'ab2'))$$,
  'P0001', 'invite_unavailable', 'a cancelled challenge cannot be accepted');
reset role;

-- Decline: Naren challenges Third, who declines.
insert into r (label, id) values ('ac1', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000003', 'd1', 'c7400000-0000-4000-8000-000000000011'));
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.decline_competition_challenge((select id from r where label = 'ac1'))$$,
  'P0001', 'invite_unavailable', 'the creator cannot decline');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select throws_ok($$select public.decline_competition_challenge((select id from r where label = 'ac1'))$$,
  'P0001', 'invite_unavailable', 'a third account cannot decline');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select is(public.decline_competition_challenge((select id from r where label = 'ac1')),
  jsonb_build_object('competition_id', (select id from r where label = 'ac1')),
  'the recipient declines');
select is(public.decline_competition_challenge((select id from r where label = 'ac1')),
  jsonb_build_object('competition_id', (select id from r where label = 'ac1')),
  'decline is idempotent for the recipient');
select is(public.list_challenges()->'closed', '[]'::jsonb, 'the person who declined sees no closed row');
select throws_ok($$select public.preview_competition_invite(decode(repeat('d1', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'a declined challenge is unavailable');
reset role;
select ok((select c.lifecycle = 'declined' and c.closed_by_profile_id = 'c7100000-0000-4000-8000-000000000003'
    and c.closed_at is not null and p.state = 'pending'
  from public.competitions c join public.competition_participants p
    on p.competition_id = c.id and p.role = 'invitee'
  where c.id = (select id from r where label = 'ac1')),
  'decline records who and when, and leaves the invitee participant pending');
select results_eq($$select * from pg_temp.challenge_work((select id from r where label = 'ac1'), 'challenge_declined')$$,
  $$values ('c7100000-0000-4000-8000-000000000001'::uuid, 'c7100000-0000-4000-8000-000000000003'::uuid, 'pending'::text),
    ('c7100000-0000-4000-8000-000000000001'::uuid, 'c7100000-0000-4000-8000-000000000003'::uuid, 'pending'::text)$$,
  'decline enqueues one challenge_declined per creator installation');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select is((select display_name from public.profiles where id = 'c7100000-0000-4000-8000-000000000003'),
  'Third', 'the creator can still render the recipient''s name after a decline');
select is(public.list_challenges()->'closed',
  jsonb_build_array(jsonb_build_object('competition_id', (select id from r where label = 'ac1'),
    'kind', 'declined',
    'other', jsonb_build_object('id', 'c7100000-0000-4000-8000-000000000003'::uuid, 'display_name', 'Third'),
    'closed_at', (select closed_at from public.competitions where id = (select id from r where label = 'ac1')))),
  'the creator lists the decline with names only');
reset role;

-- Expired: Naren challenges Third again; it lapses before an answer.
insert into r (label, id) values ('ac2', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000003', 'd2', 'c7400000-0000-4000-8000-000000000012'));
update public.competition_invites set created_at = now() - interval '25 hours', expires_at = now() - interval '1 second'
where competition_id = (select id from r where label = 'ac2');
update public.competitions set created_at = now() - interval '25 hours', invitation_expires_at = now() - interval '1 second'
where id = (select id from r where label = 'ac2');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.decline_competition_challenge((select id from r where label = 'ac2'))$$,
  'P0001', 'invite_unavailable', 'an expired challenge cannot be declined');
select throws_ok($$select public.preview_competition_invite(decode(repeat('d2', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'an expired challenge is unavailable');
select is(public.list_challenges()->'incoming', '[]'::jsonb, 'an expired challenge is not listed');
reset role;

-- Mute: Dana muted Third, so Third's decline is suppressed for Dana.
insert into r (label, id) values ('dc1', pg_temp.challenge('c7000000-0000-4000-8000-000000000004',
  'c7100000-0000-4000-8000-000000000003', 'd3', 'c7400000-0000-4000-8000-000000000013'));
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('c7100000-0000-4000-8000-000000000004', 'c7100000-0000-4000-8000-000000000003');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select lives_ok($$select public.decline_competition_challenge((select id from r where label = 'dc1'))$$,
  'the recipient declines a muted creator''s challenge');
reset role;
select results_eq($$select state from pg_temp.challenge_work((select id from r where label = 'dc1'), 'challenge_declined')$$,
  $$values ('suppressed'::text)$$, 'a muted creator''s decline notification is suppressed');

-- Cancel Match: Naren challenges Third; Third accepts, then cancels before Day 1.
insert into r (label, id) values ('ac3', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000003', 'd4', 'c7400000-0000-4000-8000-000000000014'));
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'ac3'))$$,
  'the recipient accepts');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select throws_ok($$select public.cancel_competition((select id from r where label = 'ac3'))$$,
  'P0001', 'cancel_not_allowed', 'a non-participant cannot cancel a match');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000003"}', true);
select is(public.cancel_competition((select id from r where label = 'ac3')),
  jsonb_build_object('competition_id', (select id from r where label = 'ac3')),
  'the recipient may cancel a scheduled match before Day 1');
select is(public.list_challenges()->'closed', '[]'::jsonb, 'the person who cancelled sees no closed row');
reset role;
select results_eq($$select * from pg_temp.challenge_work((select id from r where label = 'ac3'), 'match_cancelled')$$,
  $$values ('c7100000-0000-4000-8000-000000000001'::uuid, 'c7100000-0000-4000-8000-000000000003'::uuid, 'pending'::text),
    ('c7100000-0000-4000-8000-000000000001'::uuid, 'c7100000-0000-4000-8000-000000000003'::uuid, 'pending'::text)$$,
  'Cancel Match enqueues match_cancelled to the other participant');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000001"}', true);
select is((select jsonb_agg(jsonb_build_array(e->>'kind', e->'other'->>'display_name') order by e->>'closed_at' desc)
  from jsonb_array_elements(public.list_challenges()->'closed') e),
  '[["cancelled","Third"],["declined","Third"]]'::jsonb,
  'the other participant lists the cancel, newest first');
reset role;

-- Cancel Match by the creator, in a relationship that is only cancelled.
insert into r (label, id) values ('db1', pg_temp.challenge('c7000000-0000-4000-8000-000000000004',
  'c7100000-0000-4000-8000-000000000002', 'd5', 'c7400000-0000-4000-8000-000000000015'));
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'db1'))$$,
  'Maya accepts Dana''s challenge');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000004"}', true);
select lives_ok($$select public.cancel_competition((select id from r where label = 'db1'))$$,
  'the creator may cancel a scheduled match before Day 1');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is((select display_name from public.profiles where id = 'c7100000-0000-4000-8000-000000000004'),
  'Dana', 'a counterpart in a cancelled-only relationship stays visible');
reset role;
-- An account-deletion cancel leaves an anonymized counterpart (no closed_by).
insert into public.profiles (id, auth_user_id, display_name, state, anonymized_at)
values ('c7100000-0000-4000-8000-000000000009', null, 'Former competitor', 'anonymized', now());
set constraints all deferred;
insert into public.competitions (id, creator_profile_id, invited_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at, best_available_deadline)
values ('c7500000-0000-4000-8000-000000000009', 'c7100000-0000-4000-8000-000000000002',
  'c7100000-0000-4000-8000-000000000009', 'UTC', current_date + 1, 'healthcomp.activity-score.v1',
  'cancelled', now() - interval '1 hour', now() + interval '9 days');
insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('c7500000-0000-4000-8000-000000000009', 'c7100000-0000-4000-8000-000000000002', 'creator', 'accepted'),
  ('c7500000-0000-4000-8000-000000000009', 'c7100000-0000-4000-8000-000000000009', 'invitee', 'anonymized');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000002"}', true);
select is((select display_name from public.profiles where id = 'c7100000-0000-4000-8000-000000000009'),
  'Former competitor', 'an anonymized counterpart of a deletion cancel stays visible');
reset role;

-- Cancel windows: Day 1 has started, and a completed match.
insert into r (label, id) values ('ad1', pg_temp.challenge('c7000000-0000-4000-8000-000000000001',
  'c7100000-0000-4000-8000-000000000004', 'd6', 'c7400000-0000-4000-8000-000000000016'));
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c7000000-0000-4000-8000-000000000004"}', true);
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'ad1'))$$,
  'Dana accepts Naren''s challenge');
reset role;
update public.competitions set start_day = start_day - 1 where id = (select id from r where label = 'ad1');
set local role authenticated;
select throws_ok($$select public.cancel_competition((select id from r where label = 'ad1'))$$,
  'P0001', 'cancel_not_allowed', 'a match cannot be cancelled once Day 1 has started');
reset role;
update public.competitions set lifecycle = 'completed' where id = (select id from r where label = 'ad1');
set local role authenticated;
select throws_ok($$select public.cancel_competition((select id from r where label = 'ad1'))$$,
  'P0001', 'cancel_not_allowed', 'a completed match cannot be cancelled');
reset role;

-- Lease: stale challenge pushes are discarded; leased items keep seven keys.
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into r (label, v) values ('lease', public.lease_competition_notification_work(100, 60));
reset role;
select is((select state from private.competition_notification_work
  where competition_id = (select id from r where label = 'ab2') and kind = 'challenge_received'),
  'discarded', 'challenge_received is discarded after a cancel');
select is((select state from private.competition_notification_work
  where competition_id = (select id from r where label = 'ac2') and kind = 'challenge_received'),
  'discarded', 'challenge_received is discarded after expiry');
select is((select state from private.competition_notification_work
  where competition_id = (select id from r where label = 'ec1') and kind = 'challenge_received'),
  'discarded', 'a challenge push from an inactive sender is discarded');
select is((select array_agg(distinct state) from private.competition_notification_work
  where competition_id = (select id from r where label = 'ac1') and kind = 'challenge_declined'),
  array['leased'], 'a live decline push is leased');
select ok((select bool_and(pg_temp.keys(item) = array['apnsToken', 'competitionId', 'environment',
    'kind', 'leaseToken', 'semanticId', 'workId'])
    and count(*) filter (where item->>'kind' in ('challenge_declined', 'match_cancelled')) = 5
  from r, jsonb_array_elements(r.v->'items') item where r.label = 'lease'),
  'leased challenge items keep exactly the seven existing keys');

select * from finish();
rollback;
