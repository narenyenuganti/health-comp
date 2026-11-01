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
