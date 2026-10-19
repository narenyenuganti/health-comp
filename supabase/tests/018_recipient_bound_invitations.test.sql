begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select has_function('public', 'create_competition_invite',
  array['bytea', 'text', 'uuid', 'uuid', 'uuid', 'smallint', 'uuid'],
  'creation requires the chosen recipient identity');
select ok(not has_function_privilege('service_role',
  'public.create_competition_invite(bytea,text,uuid,uuid,uuid,smallint)', 'execute'),
  'recipient-free creation cannot bypass the new contract');

insert into auth.users (id) values
  ('98000000-0000-4000-8000-000000000001'),
  ('98000000-0000-4000-8000-000000000002'),
  ('98000000-0000-4000-8000-000000000003');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('98100000-0000-4000-8000-000000000001', '98000000-0000-4000-8000-000000000001', 'Sender', 'active'),
  ('98100000-0000-4000-8000-000000000002', '98000000-0000-4000-8000-000000000002', 'Chosen recipient', 'active'),
  ('98100000-0000-4000-8000-000000000003', '98000000-0000-4000-8000-000000000003', 'Other account', 'active');
create temporary table invitation_results (label text primary key, id uuid);
grant all on invitation_results to authenticated, service_role;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"98000000-0000-4000-8000-000000000001"}', true);
select is(public.resolve_invitation_recipient('98100000-0000-4000-8000-000000000002'),
  '{"id":"98100000-0000-4000-8000-000000000002","display_name":"Chosen recipient"}'::jsonb,
  'exact account code resolves only the chosen name and profile identity');
select throws_ok($$select public.resolve_invitation_recipient('98100000-0000-4000-8000-000000000001')$$,
  'P0001', 'recipient_unavailable', 'self cannot be a recipient');
select throws_ok($$select public.resolve_invitation_recipient(null)$$,
  'P0001', 'recipient_unavailable', 'there is no directory query without an exact code');
select is((select count(*) from public.profiles), 1::bigint,
  'exact resolution does not grant a searchable profile directory');
reset role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into invitation_results select 'first', public.create_competition_invite(
  decode(repeat('91', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000001',
  1::smallint, '98100000-0000-4000-8000-000000000002');
select is(public.create_competition_invite(
  decode(repeat('91', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000001',
  1::smallint, '98100000-0000-4000-8000-000000000002'),
  (select id from invitation_results where label = 'first'),
  'same recipient and creation key return the original invitation');
select throws_ok($$select public.create_competition_invite(
  decode(repeat('91', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000001',
  1::smallint, '98100000-0000-4000-8000-000000000003')$$,
  'P0001', 'idempotency_conflict', 'retry cannot change recipient');
select throws_ok($$select public.create_competition_invite(
  decode(repeat('92', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000002',
  1::smallint, '98100000-0000-4000-8000-000000000002')$$,
  'P0001', 'pending_invitation_exists', 'a different request cannot duplicate a pending recipient');
select lives_ok($$insert into invitation_results select 'other', public.create_competition_invite(
  decode(repeat('93', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000003',
  1::smallint, '98100000-0000-4000-8000-000000000003')$$,
  'the same sender can invite another account independently');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"98000000-0000-4000-8000-000000000001"}', true);
select is((select invitation_expires_at - created_at from public.competitions
  where id = (select id from invitation_results where label = 'first')),
  interval '24 hours', 'invitation expires exactly 24 hours after server creation');
select is((select display_name from public.profiles where id = '98100000-0000-4000-8000-000000000002'),
  'Chosen recipient', 'creator can render the pending recipient name');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"98000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.claim_competition_invite(decode(repeat('91', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'another account holding the private link cannot accept');
select is((select count(*) from public.competitions), 0::bigint,
  'holding another recipient link does not expose a competition');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"98000000-0000-4000-8000-000000000002"}', true);
select is((select count(*) from public.competitions), 0::bigint,
  'being named does not expose competition history before acceptance');
select is(public.claim_competition_invite(decode(repeat('91', 32), 'hex')),
  (select id from invitation_results where label = 'first'),
  'only the chosen recipient accepts the invitation');
select is(public.claim_competition_invite(decode(repeat('91', 32), 'hex')),
  (select id from invitation_results where label = 'first'),
  'same recipient claim retry remains idempotent');
select is((select count(*) from public.competition_participants
  where competition_id = (select id from invitation_results where label = 'first')
    and state = 'accepted'), 2::bigint, 'claim produces exactly two accepted participants');
reset role;

-- Synthetic time boundary; the same public claim and creation interfaces follow.
update public.competition_invites set created_at = now() - interval '25 hours', expires_at = now()
where competition_id = (select id from invitation_results where label = 'other');
update public.competitions set created_at = now() - interval '25 hours', invitation_expires_at = now()
where id = (select id from invitation_results where label = 'other');
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"98000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.claim_competition_invite(decode(repeat('93', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'acceptance fails at the expiry boundary');
reset role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok($$insert into invitation_results select 'replacement', public.create_competition_invite(
  decode(repeat('94', 32), 'hex'), 'UTC', null,
  '98000000-0000-4000-8000-000000000001', '98200000-0000-4000-8000-000000000004',
  1::smallint, '98100000-0000-4000-8000-000000000003')$$,
  'an expired invitation does not block its recipient replacement');
reset role;
select is((select lifecycle from public.competitions
  where id = (select id from invitation_results where label = 'other')),
  'expired', 'replacement expires the old row without deleting history');
select is((select count(*) from public.competition_change_log
  where competition_id = (select id from invitation_results where label = 'first')),
  (select next_server_seq - 1 from public.competitions
  where id = (select id from invitation_results where label = 'first')),
  'recipient binding and acceptance preserve a gap-free server cursor');

select * from finish();
rollback;
