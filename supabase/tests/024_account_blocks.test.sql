begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select ok((
  select bool_and(p.prosecdef and p.proconfig = array['search_path=""']
    and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')) and count(*) = 3
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('block_challenger', 'unblock_profile', 'list_blocked_profiles')
), 'block_challenger, unblock_profile and list_blocked_profiles are security definers with an empty search path, for authenticated only');
select ok((
  select p.prosecdef and p.proconfig = array['search_path=""']
    and not has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'private' and p.proname = 'purge_account_blocks_on_profile_deactivation'
), 'the purge trigger function is not callable by API roles');
select ok((
  select c.relrowsecurity and c.relforcerowsecurity
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'private' and c.relname = 'account_blocks'
) and not has_table_privilege('authenticated', 'private.account_blocks', 'select')
  and not has_table_privilege('anon', 'private.account_blocks', 'select')
  and not has_table_privilege('service_role', 'private.account_blocks', 'select,insert,update,delete'),
  'account_blocks has RLS enabled and forced and no table privileges for client roles');

-- A Naren (blocker), B Maya (sender), C Tess, E Ana.
insert into auth.users (id) values
  ('c9000000-0000-4000-8000-000000000001'), ('c9000000-0000-4000-8000-000000000002'),
  ('c9000000-0000-4000-8000-000000000003'), ('c9000000-0000-4000-8000-000000000005');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c9100000-0000-4000-8000-000000000001', 'c9000000-0000-4000-8000-000000000001', 'Naren', 'active'),
  ('c9100000-0000-4000-8000-000000000002', 'c9000000-0000-4000-8000-000000000002', 'Maya', 'active'),
  ('c9100000-0000-4000-8000-000000000003', 'c9000000-0000-4000-8000-000000000003', 'Tess', 'active'),
  ('c9100000-0000-4000-8000-000000000005', 'c9000000-0000-4000-8000-000000000005', 'Ana', 'active');
insert into public.device_installations (id, profile_id, installation_id, apns_token, environment, state, supports_challenges) values
  ('c9200000-0000-4000-8000-000000000002', 'c9100000-0000-4000-8000-000000000002', 'c9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', 'active', true);

create temporary table r (label text primary key, id uuid, v jsonb);
grant all on r to authenticated, service_role;

create function pg_temp.by_id(sender_auth uuid, recipient uuid, parent uuid, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', parent, sender_auth, key, 1::smallint, recipient);
end;
$$;
create function pg_temp.from_link(sender_auth uuid, link_code text, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite_from_link(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', sender_auth, key, 1::smallint, link_code);
end;
$$;
create function pg_temp.as_user(auth_id text) returns void language sql as $$
  select set_config('request.jwt.claims',
    pg_catalog.jsonb_build_object('role', 'authenticated', 'sub', auth_id)::text, true);
$$;
create function pg_temp.rid(label_name text) returns uuid language sql as $$
  select id from r where label = label_name;
$$;
create function pg_temp.naren_code() returns text language sql as $$
  select v->>'code' from r where label = 'naren-link';
$$;
create function pg_temp.declined_work(target uuid)
returns table (recipient uuid, source uuid, state text) language sql as $$
  select recipient_profile_id, source_profile_id, state from private.competition_notification_work
  where competition_id = target and kind = 'challenge_declined' order by installation_id;
$$;

-- A finished match between Naren and Maya, for the rematch case.
insert into r (label, id) values ('old', pg_temp.by_id('c9000000-0000-4000-8000-000000000001',
  'c9100000-0000-4000-8000-000000000002', null, 'a0', 'c9400000-0000-4000-8000-000000000000'));
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select lives_ok($$select public.accept_competition_challenge(pg_temp.rid('old'))$$, 'Maya accepts Naren''s challenge');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
insert into r (label, v) values ('naren-link', public.get_my_challenge_link());
reset role;
update public.competitions set lifecycle = 'completed' where id = pg_temp.rid('old');

-- Maya challenges Naren, and he blocks her from it.
insert into r (label, id) values ('mn1', pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a1', 'c9400000-0000-4000-8000-000000000001'));
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select is(public.block_challenger(pg_temp.rid('mn1')),
  jsonb_build_object('competition_id', pg_temp.rid('mn1')), 'Naren blocks Maya from her challenge');
select is(public.list_challenges()->'incoming', '[]'::jsonb, 'the blocked challenge leaves Naren''s list');
reset role;
select ok((select c.lifecycle = 'declined' and c.closed_by_profile_id = 'c9100000-0000-4000-8000-000000000001'
    and c.closed_at is not null and c.updated_at = c.closed_at and p.state = 'pending'
  from public.competitions c join public.competition_participants p
    on p.competition_id = c.id and p.role = 'invitee'
  where c.id = pg_temp.rid('mn1')),
  'blocking declines the pending challenge exactly like Decline');
select results_eq($$select * from pg_temp.declined_work(pg_temp.rid('mn1'))$$,
  $$values ('c9100000-0000-4000-8000-000000000002'::uuid, 'c9100000-0000-4000-8000-000000000001'::uuid, 'pending'::text)$$,
  'blocking enqueues the same challenge_declined push as Decline');
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select is(public.list_challenges()->'closed',
  jsonb_build_array(jsonb_build_object('competition_id', pg_temp.rid('mn1'),
    'kind', 'declined',
    'other', jsonb_build_object('id', 'c9100000-0000-4000-8000-000000000001'::uuid, 'display_name', 'Naren'),
    'closed_at', (select closed_at from public.competitions where id = pg_temp.rid('mn1')))),
  'the blocked sender sees a plain decline');
reset role;
select is((select count(*) from private.account_blocks
  where blocker_profile_id = 'c9100000-0000-4000-8000-000000000001'
    and blocked_profile_id = 'c9100000-0000-4000-8000-000000000002'), 1::bigint, 'one block row');

-- Every create path refuses the blocked sender with the collapsed error.
select throws_ok($$select pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a2', 'c9400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'a blocked sender gets recipient_unavailable by id');
select throws_ok($$select pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', pg_temp.rid('old'), 'a2', 'c9400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'and by rematch');
select throws_ok($$select pg_temp.from_link('c9000000-0000-4000-8000-000000000002',
  pg_temp.naren_code(), 'a2', 'c9400000-0000-4000-8000-000000000002')$$,
  'P0001', 'recipient_unavailable', 'and by the current link code');

-- Both lookups read like an unknown code.
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select throws_ok($$select public.resolve_challenge_link('AAAAAAAAAAAAAAAAAAAAAA')$$,
  'P0001', 'recipient_unavailable', 'an unknown code is unavailable');
select throws_ok($$select public.resolve_challenge_link(pg_temp.naren_code())$$,
  'P0001', 'recipient_unavailable', 'blocked lookups by link read like an unknown code');
select throws_ok($$select public.resolve_invitation_recipient('c9100000-0000-4000-8000-000000000001')$$,
  'P0001', 'recipient_unavailable', 'blocked lookups by account id read the same');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000003');
select is(public.resolve_challenge_link(pg_temp.naren_code()), '{"display_name":"Naren"}'::jsonb,
  'others still resolve the link');
select is(public.resolve_invitation_recipient('c9100000-0000-4000-8000-000000000001'),
  '{"id":"c9100000-0000-4000-8000-000000000001","display_name":"Naren"}'::jsonb,
  'and the account');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select throws_ok($$select public.resolve_challenge_link(pg_temp.naren_code())$$,
  'P0001', 'own_challenge_link', 'the own-link answer is unchanged');
reset role;

-- A retry of the create made before the block returns its id.
select is(pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a1', 'c9400000-0000-4000-8000-000000000001'),
  pg_temp.rid('mn1'), 'an exact retry of a create made before the block returns its id');

-- One-way: the blocker can still challenge, and pair conflicts come first.
insert into r (label, id) values ('nm', pg_temp.by_id('c9000000-0000-4000-8000-000000000001',
  'c9100000-0000-4000-8000-000000000002', null, 'a3', 'c9400000-0000-4000-8000-000000000003'));
select ok(pg_temp.rid('nm') is not null, 'the blocker can still challenge the blocked person');
select throws_ok($$select pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a4', 'c9400000-0000-4000-8000-000000000004')$$,
  'P0001', 'incoming_challenge_exists', 'pair conflicts read as for anyone');
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select lives_ok($$select public.cancel_competition(pg_temp.rid('nm'))$$, 'Naren withdraws his challenge');
reset role;
select throws_ok($$select pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a4', 'c9400000-0000-4000-8000-000000000004')$$,
  'P0001', 'recipient_unavailable', 'the block refusal comes last');

-- Lists.
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select is(public.list_blocked_profiles(),
  '{"blocked":[{"id":"c9100000-0000-4000-8000-000000000002","display_name":"Maya"}]}'::jsonb,
  'list_blocked_profiles shows the caller''s blocks');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select is(public.list_blocked_profiles(), '{"blocked":[]}'::jsonb, 'the blocked person''s list is empty');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000003');
select is(public.list_blocked_profiles(), '{"blocked":[]}'::jsonb, 'so is a third person''s');

-- Only the recipient of a challenge can block from it.
select throws_ok($$select public.block_challenger(pg_temp.rid('mn1'))$$,
  'P0001', 'invite_unavailable', 'a third person cannot block from someone else''s challenge');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select throws_ok($$select public.block_challenger(pg_temp.rid('mn1'))$$,
  'P0001', 'invite_unavailable', 'the creator cannot block from their own challenge');
select throws_ok($$select public.block_challenger('c9400000-0000-4000-8000-0000000000ff')$$,
  'P0001', 'invite_unavailable', 'an unknown id reads the same');
select throws_ok($$select public.block_challenger(null)$$,
  '22023', 'invalid_competition_id', 'a null id is invalid');

-- Twice is idempotent.
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select is(public.block_challenger(pg_temp.rid('mn1')),
  jsonb_build_object('competition_id', pg_temp.rid('mn1')), 'blocking twice answers the same');
reset role;
select is((select count(*) from private.account_blocks), 1::bigint, 'blocking twice adds no row');
select is((select count(*) from pg_temp.declined_work(pg_temp.rid('mn1'))), 1::bigint,
  'blocking twice sends no second push');

-- From a declined or an expired challenge: blocks, declines nothing.
insert into r (label, id) values ('tn', pg_temp.by_id('c9000000-0000-4000-8000-000000000003',
  'c9100000-0000-4000-8000-000000000001', null, 'a5', 'c9400000-0000-4000-8000-000000000005'));
insert into r (label, id) values ('an', pg_temp.by_id('c9000000-0000-4000-8000-000000000005',
  'c9100000-0000-4000-8000-000000000001', null, 'a6', 'c9400000-0000-4000-8000-000000000006'));
update public.competitions set invitation_expires_at = now() - interval '1 second'
where id = pg_temp.rid('an');
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select lives_ok($$select public.decline_competition_challenge(pg_temp.rid('tn'))$$, 'Naren declines Tess''s challenge');
reset role;
create temporary table before_late_blocks as
  select id, lifecycle, closed_at, updated_at from public.competitions
  where id in (pg_temp.rid('tn'), pg_temp.rid('an'));
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select lives_ok($$select public.block_challenger(pg_temp.rid('tn'))$$, 'Naren blocks Tess from the declined challenge');
select lives_ok($$select public.block_challenger(pg_temp.rid('an'))$$, 'Naren blocks Ana from the expired challenge');
reset role;
select results_eq($$select id, lifecycle, closed_at, updated_at from public.competitions
    where id in (pg_temp.rid('tn'), pg_temp.rid('an')) order by id$$,
  $$select * from before_late_blocks order by id$$,
  'blocking from an expired or declined challenge blocks without declining anything');
select is((select count(*) from private.competition_notification_work
  where competition_id in (pg_temp.rid('tn'), pg_temp.rid('an')) and kind = 'challenge_declined'),
  0::bigint, 'and sends no further push');
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000001');
select is(jsonb_array_length(public.list_blocked_profiles()->'blocked'), 3, 'all three are blocked');
select is(public.list_blocked_profiles()->'blocked'->0->>'display_name', 'Ana', 'newest block first');

-- Unblock.
select is(public.unblock_profile('c9100000-0000-4000-8000-000000000002'),
  '{"profile_id":"c9100000-0000-4000-8000-000000000002"}'::jsonb, 'Naren unblocks Maya');
select is(public.unblock_profile('c9100000-0000-4000-8000-0000000000ff'),
  '{"profile_id":"c9100000-0000-4000-8000-0000000000ff"}'::jsonb,
  'unblocking someone never blocked answers the same');
select throws_ok($$select public.unblock_profile(null)$$, '22023', 'invalid_profile_id', 'a null profile is invalid');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000003');
select lives_ok($$select public.unblock_profile('c9100000-0000-4000-8000-000000000005')$$,
  'someone else''s unblock call');
reset role;
select ok(exists (select 1 from private.account_blocks
  where blocker_profile_id = 'c9100000-0000-4000-8000-000000000001'
    and blocked_profile_id = 'c9100000-0000-4000-8000-000000000005'),
  'touches only the caller''s rows');
select ok(pg_temp.by_id('c9000000-0000-4000-8000-000000000002',
  'c9100000-0000-4000-8000-000000000001', null, 'a7', 'c9400000-0000-4000-8000-000000000007') is not null,
  'unblock_profile lets them challenge again');

-- Starting deletion removes that account's blocks in both directions.
insert into r (label, id) values ('nt', pg_temp.by_id('c9000000-0000-4000-8000-000000000001',
  'c9100000-0000-4000-8000-000000000003', null, 'a8', 'c9400000-0000-4000-8000-000000000008'));
insert into r (label, id) values ('am', pg_temp.by_id('c9000000-0000-4000-8000-000000000005',
  'c9100000-0000-4000-8000-000000000002', null, 'a9', 'c9400000-0000-4000-8000-000000000009'));
set local role authenticated;
select pg_temp.as_user('c9000000-0000-4000-8000-000000000003');
select lives_ok($$select public.block_challenger(pg_temp.rid('nt'))$$, 'Tess blocks Naren');
select pg_temp.as_user('c9000000-0000-4000-8000-000000000002');
select lives_ok($$select public.block_challenger(pg_temp.rid('am'))$$, 'Maya blocks Ana');
reset role;
update public.profiles set state = 'deleting' where id = 'c9100000-0000-4000-8000-000000000001';
select is((select count(*) from private.account_blocks
  where 'c9100000-0000-4000-8000-000000000001' in (blocker_profile_id, blocked_profile_id)),
  0::bigint, 'starting account deletion removes that account''s blocks in both directions');
select is((select count(*) from private.account_blocks), 1::bigint, 'other people''s blocks stay');

select * from finish();
rollback;
