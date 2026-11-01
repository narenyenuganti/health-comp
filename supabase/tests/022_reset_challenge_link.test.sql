begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select ok((
  select has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')
    and p.prosecdef
    and p.proconfig = array['search_path=""']
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'reset_my_challenge_link'
), 'reset_my_challenge_link is a security definer with an empty search path, for authenticated only');

-- A Naren, B Maya, C Dana (deleting).
insert into auth.users (id) values
  ('c8000000-0000-4000-8000-000000000001'), ('c8000000-0000-4000-8000-000000000002'),
  ('c8000000-0000-4000-8000-000000000003');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-000000000001', 'c8000000-0000-4000-8000-000000000001', 'Naren', 'active'),
  ('c8100000-0000-4000-8000-000000000002', 'c8000000-0000-4000-8000-000000000002', 'Maya', 'active'),
  ('c8100000-0000-4000-8000-000000000003', 'c8000000-0000-4000-8000-000000000003', 'Dana', 'deleting');

create temporary table r (label text primary key, v jsonb);
grant all on r to authenticated, service_role;

-- Naren and Maya each have a link; Naren has a pending challenge to Maya.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
insert into r values ('naren-link', public.get_my_challenge_link());
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000002"}', true);
insert into r values ('maya-old', public.get_my_challenge_link());
reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.create_competition_invite(decode(repeat('d1', 32), 'hex'), 'America/Los_Angeles',
  null, 'c8000000-0000-4000-8000-000000000001', 'c8400000-0000-4000-8000-000000000001',
  1::smallint, 'c8100000-0000-4000-8000-000000000002');
create temporary table pending_before as
  select c.*, i.token_digest, i.expires_at as invite_expires_at
  from public.competitions c join public.competition_invites i on i.competition_id = c.id;

-- Maya resets her link.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000002"}', true);
insert into r values ('maya-new', public.reset_my_challenge_link());
select ok((select v->>'code' ~ '^[A-Za-z0-9_-]{22}$' and array(select jsonb_object_keys(v)) = array['code']
  from r where label = 'maya-new'), 'reset returns a fresh 22-character code as the only key');
select isnt((select v->>'code' from r where label = 'maya-new'),
  (select v->>'code' from r where label = 'maya-old'), 'reset replaces the code');
select is(public.get_my_challenge_link(), (select v from r where label = 'maya-new'),
  'the new code is the link from now on');
select isnt((select v->>'code' from r where label = 'maya-new'),
  (public.reset_my_challenge_link())->>'code', 'each reset makes another code');
update r set v = public.get_my_challenge_link() where label = 'maya-new';

select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000001"}', true);
select throws_ok($$select public.resolve_challenge_link((select v->>'code' from r where label = 'maya-old'))$$,
  'P0001', 'recipient_unavailable', 'the old code is unavailable, the same as an unknown code');
select is(public.resolve_challenge_link((select v->>'code' from r where label = 'maya-new')),
  '{"id":"c8100000-0000-4000-8000-000000000002","display_name":"Maya"}'::jsonb,
  'the new code resolves to Maya');
select is(public.get_my_challenge_link(), (select v from r where label = 'naren-link'),
  'another person''s link is unchanged');
select throws_ok($$select public.resolve_challenge_link((select v->>'code' from r where label = 'naren-link'))$$,
  'P0001', 'own_challenge_link', 'Naren''s link still resolves');
reset role;

select is((select count(*) from private.challenge_links), 2::bigint, 'reset adds no rows');
select results_eq(
  $$select c.*, i.token_digest, i.expires_at from public.competitions c
    join public.competition_invites i on i.competition_id = c.id$$,
  $$select * from pending_before$$,
  'a pending challenge made before the reset is untouched');
select is((select lifecycle from public.competitions), 'pending', 'the challenge is still pending');

-- Reset with no link yet creates one.
insert into auth.users (id) values ('c8000000-0000-4000-8000-000000000004');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-000000000004', 'c8000000-0000-4000-8000-000000000004', 'Ana', 'active');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000004"}', true);
select is(public.reset_my_challenge_link(), public.get_my_challenge_link(),
  'reset before any link creates the link');

-- Denied: inactive profile, no user, anon, service_role.
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000003"}', true);
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

select is((select l.code from private.challenge_links l
  where l.profile_id = 'c8100000-0000-4000-8000-000000000002'),
  (select v->>'code' from r where label = 'maya-new'), 'denied calls change nothing');

select * from finish();
rollback;
