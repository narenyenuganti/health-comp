begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

create function pg_temp.definer_with_empty_path(name text) returns boolean language sql as $$
  select p.prosecdef and p.proconfig = array['search_path=""']
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = name;
$$;
select ok((
  select has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'reset_my_challenge_link'
) and pg_temp.definer_with_empty_path('reset_my_challenge_link'),
  'reset_my_challenge_link is a security definer with an empty search path, for authenticated only');
select ok((
  select has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'create_competition_invite_from_link'
) and pg_temp.definer_with_empty_path('create_competition_invite_from_link'),
  'create_competition_invite_from_link is a security definer with an empty search path, for service_role only');

-- A Naren, B Maya (link owner), C Tess, D Dana (deleting), E Ana.
insert into auth.users (id) values
  ('c8000000-0000-4000-8000-000000000001'), ('c8000000-0000-4000-8000-000000000002'),
  ('c8000000-0000-4000-8000-000000000003'), ('c8000000-0000-4000-8000-000000000004'),
  ('c8000000-0000-4000-8000-000000000005');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-000000000001', 'c8000000-0000-4000-8000-000000000001', 'Naren', 'active'),
  ('c8100000-0000-4000-8000-000000000002', 'c8000000-0000-4000-8000-000000000002', 'Maya', 'active'),
  ('c8100000-0000-4000-8000-000000000003', 'c8000000-0000-4000-8000-000000000003', 'Tess', 'active'),
  ('c8100000-0000-4000-8000-000000000004', 'c8000000-0000-4000-8000-000000000004', 'Dana', 'deleting'),
  ('c8100000-0000-4000-8000-000000000005', 'c8000000-0000-4000-8000-000000000005', 'Ana', 'active');

create temporary table r (label text primary key, id uuid, v jsonb);
grant all on r to authenticated, service_role;

create function pg_temp.from_link(sender_auth uuid, link_code text, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite_from_link(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', sender_auth, key, 1::smallint, link_code);
end;
$$;
create function pg_temp.by_id(sender_auth uuid, recipient uuid, parent uuid, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', parent, sender_auth, key, 1::smallint, recipient);
end;
$$;
create function pg_temp.code(link text) returns text language sql as $$
  select v->>'code' from r where label = link;
$$;

-- Links, and resolve without an account id.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
insert into r (label, v) values ('naren-link', public.get_my_challenge_link());
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000002"}', true);
insert into r (label, v) values ('maya-old', public.get_my_challenge_link());
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
select is(public.resolve_challenge_link(pg_temp.code('maya-old')), '{"display_name":"Maya"}'::jsonb,
  'resolving a link returns only the display name, no account id');
reset role;

-- Naren challenges Maya from her link.
insert into r (label, id) values ('nm', pg_temp.from_link('c8000000-0000-4000-8000-000000000001',
  pg_temp.code('maya-old'), 'd1', 'c8400000-0000-4000-8000-000000000001'));
select ok((select invited_profile_id = 'c8100000-0000-4000-8000-000000000002' and lifecycle = 'pending'
  from public.competitions where id = (select id from r where label = 'nm')),
  'a challenge from a current link goes to its owner');
create temporary table pending_before as
  select c.*, i.token_digest, i.expires_at as invite_expires_at
  from public.competitions c join public.competition_invites i on i.competition_id = c.id;

-- Maya resets her link.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000002"}', true);
insert into r (label, v) values ('maya-new', public.reset_my_challenge_link());
select ok((select v->>'code' ~ '^[A-Za-z0-9_-]{22}$' and array(select jsonb_object_keys(v)) = array['code']
  from r where label = 'maya-new'), 'reset returns a fresh 22-character code as the only key');
select isnt(pg_temp.code('maya-new'), pg_temp.code('maya-old'), 'reset replaces the code');
select is(public.get_my_challenge_link(), (select v from r where label = 'maya-new'),
  'the new code is the link from now on');
select isnt(pg_temp.code('maya-new'), (public.reset_my_challenge_link())->>'code',
  'each reset makes another code');
update r set v = public.get_my_challenge_link() where label = 'maya-new';

select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.resolve_challenge_link(pg_temp.code('maya-old'))$$,
  'P0001', 'recipient_unavailable', 'the old code no longer resolves, the same as an unknown code');
select is(public.resolve_challenge_link(pg_temp.code('maya-new')), '{"display_name":"Maya"}'::jsonb,
  'the new code resolves');
select is(public.get_my_challenge_link(), (select v from r where label = 'naren-link'),
  'another person''s link is unchanged');
reset role;
select is((select count(*) from private.challenge_links), 2::bigint, 'reset adds no rows');

-- Creating from a link after the reset.
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000003',
  pg_temp.code('maya-old'), 'd2', 'c8400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'a create with the old code fails');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000003',
  'AAAAAAAAAAAAAAAAAAAAAA', 'd2', 'c8400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'the same as a create with an unknown code');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000003',
  'short', 'd2', 'c8400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'or a malformed code');
insert into r (label, id) values ('tm', pg_temp.from_link('c8000000-0000-4000-8000-000000000003',
  pg_temp.code('maya-new'), 'd2', 'c8400000-0000-4000-8000-000000000002'));
select is((select invited_profile_id from public.competitions where id = (select id from r where label = 'tm')),
  'c8100000-0000-4000-8000-000000000002'::uuid, 'a create with the new code works');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000002',
  pg_temp.code('maya-new'), 'd3', 'c8400000-0000-4000-8000-000000000003')$$,
  'P0001', 'recipient_unavailable', 'your own link cannot challenge you');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000004',
  pg_temp.code('maya-new'), 'd4', 'c8400000-0000-4000-8000-000000000004')$$,
  '42501', 'active_profile_required', 'a deleting sender cannot create');

-- Retrying a create made before the reset returns it; a changed retry conflicts.
select is(pg_temp.from_link('c8000000-0000-4000-8000-000000000001',
  pg_temp.code('maya-old'), 'd1', 'c8400000-0000-4000-8000-000000000001'),
  (select id from r where label = 'nm'), 'an exact retry of a challenge made before the reset returns it');
select is(pg_temp.from_link('c8000000-0000-4000-8000-000000000001',
  pg_temp.code('maya-new'), 'd1', 'c8400000-0000-4000-8000-000000000001'),
  (select id from r where label = 'nm'), 'a same-key retry with a different code returns it');
select is(pg_temp.from_link('c8000000-0000-4000-8000-000000000001',
  'not a code', 'd1', 'c8400000-0000-4000-8000-000000000001'),
  (select id from r where label = 'nm'), 'a same-key retry with a garbage code returns it');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000001',
  pg_temp.code('maya-old'), 'df', 'c8400000-0000-4000-8000-000000000001')$$,
  'P0001', 'idempotency_conflict', 'a retry that changed is still a conflict');

select results_eq(
  $$select c.*, i.token_digest, i.expires_at from public.competitions c
    join public.competition_invites i on i.competition_id = c.id
    where c.id = (select id from r where label = 'nm')$$,
  $$select * from pending_before$$,
  'a pending challenge made before the reset is untouched');

-- The id-based create keeps working: a 1.0.2 account code, and a rematch.
insert into r (label, id) values ('an', pg_temp.by_id('c8000000-0000-4000-8000-000000000005',
  'c8100000-0000-4000-8000-000000000001', null, 'e1', 'c8400000-0000-4000-8000-000000000011'));
select ok((select id from r where label = 'an') is not null, 'a 1.0.2 account-code challenge still works');
insert into r (label, id) values ('ta', pg_temp.by_id('c8000000-0000-4000-8000-000000000003',
  'c8100000-0000-4000-8000-000000000005', null, 'e2', 'c8400000-0000-4000-8000-000000000012'));
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000005"}', true);
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'ta'))$$,
  'Ana accepts Tess''s challenge');
reset role;
update public.competitions set lifecycle = 'completed' where id = (select id from r where label = 'ta');
select ok(pg_temp.by_id('c8000000-0000-4000-8000-000000000005', 'c8100000-0000-4000-8000-000000000003',
  (select id from r where label = 'ta'), 'e3', 'c8400000-0000-4000-8000-000000000013') is not null,
  'a rematch by account id still works');

-- The link code is recorded on the invite, out of clients' reach.
select is((select challenge_link_code from public.competition_invites
  where competition_id = (select id from r where label = 'nm')), pg_temp.code('maya-old'),
  'a challenge from a link records the code it used');
select is((select challenge_link_code from public.competition_invites
  where competition_id = (select id from r where label = 'an')), null,
  'a challenge by account id records no code');
select ok(not has_table_privilege('authenticated', 'public.competition_invites', 'select')
  and not has_column_privilege('authenticated', 'public.competition_invites', 'challenge_link_code', 'select'),
  'clients cannot read the recorded link code');

-- F Finn and G Gus reach H Hana by her link; I Ivy is a 1.0.2 sender; J Jo's
-- link outlives her account.
insert into auth.users (id) values
  ('c8000000-0000-4000-8000-000000000006'), ('c8000000-0000-4000-8000-000000000007'),
  ('c8000000-0000-4000-8000-000000000008'), ('c8000000-0000-4000-8000-000000000009'),
  ('c8000000-0000-4000-8000-00000000000a');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-000000000006', 'c8000000-0000-4000-8000-000000000006', 'Finn', 'active'),
  ('c8100000-0000-4000-8000-000000000007', 'c8000000-0000-4000-8000-000000000007', 'Gus', 'active'),
  ('c8100000-0000-4000-8000-000000000008', 'c8000000-0000-4000-8000-000000000008', 'Hana', 'active'),
  ('c8100000-0000-4000-8000-000000000009', 'c8000000-0000-4000-8000-000000000009', 'Ivy', 'active'),
  ('c8100000-0000-4000-8000-00000000000a', 'c8000000-0000-4000-8000-00000000000a', 'Jo', 'active');
create function pg_temp.as_user(auth_id text) returns void language sql as $$
  select set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('role', 'authenticated', 'sub', auth_id)::text, true);
$$;
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000008');
insert into r (label, v) values ('hana-1', public.get_my_challenge_link());
select pg_temp.as_user('c8000000-0000-4000-8000-00000000000a');
insert into r (label, v) values ('jo', public.get_my_challenge_link());
reset role;

-- Send from the link, withdraw at once, then the owner resets: the account
-- id the sender saw no longer works either.
insert into r (label, id) values ('fh', pg_temp.from_link('c8000000-0000-4000-8000-000000000006',
  pg_temp.code('hana-1'), 'f1', 'c8400000-0000-4000-8000-000000000021'));
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000006');
select lives_ok($$select public.cancel_competition((select id from r where label = 'fh'))$$,
  'Finn withdraws his challenge');
reset role;
insert into r (label, id) values ('fh-id', pg_temp.by_id('c8000000-0000-4000-8000-000000000006',
  'c8100000-0000-4000-8000-000000000008', null, 'f2', 'c8400000-0000-4000-8000-000000000022'));
select ok((select id from r where label = 'fh-id') is not null,
  'before a reset, the sender may still challenge by account id');
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000006');
select lives_ok($$select public.cancel_competition((select id from r where label = 'fh-id'))$$,
  'Finn withdraws that one too');
select pg_temp.as_user('c8000000-0000-4000-8000-000000000008');
insert into r (label, v) values ('hana-2', public.reset_my_challenge_link());
reset role;
select throws_ok($$select pg_temp.by_id('c8000000-0000-4000-8000-000000000006',
  'c8100000-0000-4000-8000-000000000008', null, 'f3', 'c8400000-0000-4000-8000-000000000023')$$,
  'P0001', 'recipient_unavailable', 'after the reset, a by-id challenge from a link-only sender fails');
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000006',
  pg_temp.code('hana-1'), 'f3', 'c8400000-0000-4000-8000-000000000023')$$,
  'P0001', 'recipient_unavailable', 'and so does the old link');

-- Send from the link, the owner accepts and plays, then resets: a real past
-- opponent keeps challenging by account id.
insert into r (label, id) values ('gh', pg_temp.from_link('c8000000-0000-4000-8000-000000000007',
  pg_temp.code('hana-2'), 'a1', 'c8400000-0000-4000-8000-000000000031'));
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000008');
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'gh'))$$,
  'Hana accepts Gus''s challenge');
insert into r (label, v) values ('hana-3', public.reset_my_challenge_link());
reset role;
update public.competitions set lifecycle = 'completed' where id = (select id from r where label = 'gh');
select ok(pg_temp.by_id('c8000000-0000-4000-8000-000000000007', 'c8100000-0000-4000-8000-000000000008',
  null, 'a2', 'c8400000-0000-4000-8000-000000000032') is not null,
  'after a reset, a past opponent may still challenge by account id');

-- A 1.0.2 sender who never used a link is unaffected by Hana's resets.
select ok(pg_temp.by_id('c8000000-0000-4000-8000-000000000009', 'c8100000-0000-4000-8000-000000000008',
  null, 'c1', 'c8400000-0000-4000-8000-000000000041') is not null,
  'a 1.0.2 account-code sender still challenges a person who reset her link');

-- The account lookup refuses the blocked sender the same way, so the name
-- never shows before a failed send; others still see it.
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000006');
select throws_ok($$select public.resolve_invitation_recipient('c8100000-0000-4000-8000-000000000008')$$,
  'P0001', 'recipient_unavailable', 'a blocked sender''s account lookup is unavailable');
select pg_temp.as_user('c8000000-0000-4000-8000-000000000009');
select is(public.resolve_invitation_recipient('c8100000-0000-4000-8000-000000000008'),
  '{"id":"c8100000-0000-4000-8000-000000000008","display_name":"Hana"}'::jsonb,
  'a 1.0.2 sender''s account lookup still works');
reset role;

-- Contact the recipient started lifts the rule: her challenge surfaces as
-- incoming, and once it's withdrawn the sender may answer by account id.
insert into r (label, id) values ('hf', pg_temp.by_id('c8000000-0000-4000-8000-000000000008',
  'c8100000-0000-4000-8000-000000000006', null, 'b1', 'c8400000-0000-4000-8000-000000000051'));
select throws_ok($$select pg_temp.by_id('c8000000-0000-4000-8000-000000000006',
  'c8100000-0000-4000-8000-000000000008', null, 'b2', 'c8400000-0000-4000-8000-000000000052')$$,
  'P0001', 'incoming_challenge_exists', 'the recipient''s own challenge surfaces, not the rule');
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000008');
select lives_ok($$select public.cancel_competition((select id from r where label = 'hf'))$$,
  'Hana withdraws her challenge to Finn');
reset role;
select ok(pg_temp.by_id('c8000000-0000-4000-8000-000000000006', 'c8100000-0000-4000-8000-000000000008',
  null, 'b3', 'c8400000-0000-4000-8000-000000000053') is not null,
  'after contact the recipient started, the sender may challenge by account id');

-- An accepted match that was later cancelled still counts as playing.
insert into auth.users (id) values ('c8000000-0000-4000-8000-00000000000b');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-00000000000b', 'c8000000-0000-4000-8000-00000000000b', 'Kai', 'active');
insert into r (label, id) values ('kh', pg_temp.from_link('c8000000-0000-4000-8000-00000000000b',
  pg_temp.code('hana-3'), 'b4', 'c8400000-0000-4000-8000-000000000061'));
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000008');
select lives_ok($$select public.accept_competition_challenge((select id from r where label = 'kh'))$$,
  'Hana accepts Kai''s challenge');
select lives_ok($$select public.cancel_competition((select id from r where label = 'kh'))$$,
  'Hana cancels the match before Day 1');
insert into r (label, v) values ('hana-4', public.reset_my_challenge_link());
reset role;
select is((select lifecycle from public.competitions where id = (select id from r where label = 'kh')),
  'cancelled', 'the accepted match is cancelled');
select ok(pg_temp.by_id('c8000000-0000-4000-8000-00000000000b', 'c8100000-0000-4000-8000-000000000008',
  null, 'b5', 'c8400000-0000-4000-8000-000000000062') is not null,
  'after a reset, someone whose accepted match was cancelled may still challenge by account id');

-- A current code whose owner is leaving is unavailable.
update public.profiles set state = 'deleting' where id = 'c8100000-0000-4000-8000-00000000000a';
select throws_ok($$select pg_temp.from_link('c8000000-0000-4000-8000-000000000009',
  pg_temp.code('jo'), 'c2', 'c8400000-0000-4000-8000-000000000042')$$,
  'P0001', 'recipient_unavailable', 'a deleting owner''s current code is unavailable');
set local role authenticated;
select pg_temp.as_user('c8000000-0000-4000-8000-000000000009');
select throws_ok($$select public.resolve_challenge_link(pg_temp.code('jo'))$$,
  'P0001', 'recipient_unavailable', 'and resolving it is unavailable too');
reset role;

-- Denied callers.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.create_competition_invite_from_link(decode(repeat('d9', 32), 'hex'),
  'UTC', 'c8000000-0000-4000-8000-000000000001', 'c8400000-0000-4000-8000-000000000009', 1::smallint,
  pg_temp.code('maya-new'))$$, '42501', null, 'authenticated cannot create from a link directly');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000004"}', true);
select throws_ok($$select public.reset_my_challenge_link()$$, '42501', 'active_profile_required',
  'a deleting account cannot reset');
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok($$select public.reset_my_challenge_link()$$, '42501', 'authentication_required',
  'an authenticated call without a user cannot reset');
reset role;
set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok($$select public.reset_my_challenge_link()$$, '42501', null, 'anon cannot reset');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok($$select public.reset_my_challenge_link()$$, '42501', null, 'service_role cannot reset');
reset role;

-- Reset with no link yet creates one.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000003"}', true);
select is(public.reset_my_challenge_link(), public.get_my_challenge_link(),
  'reset before any link creates the link');
reset role;

select is((select l.code from private.challenge_links l
  where l.profile_id = 'c8100000-0000-4000-8000-000000000002'), pg_temp.code('maya-new'),
  'denied calls change nothing');

select * from finish();
rollback;
