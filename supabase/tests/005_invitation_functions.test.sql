begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(42);

select has_function('private', 'invitation_expiry_interval_v1', array[]::text[],
  'versioned invitation-expiry policy exists');
select has_function('private', 'best_available_local_day_offset_v1', array[]::text[],
  'versioned best-available policy exists');
select is(private.best_available_local_day_offset_v1(), 8,
  'best-available policy uses the Day-9 local boundary');

select has_function('public', 'create_competition_invite', array['bytea', 'text', 'uuid', 'uuid'],
  'service-only create RPC accepts a verified auth user ID');
select has_function('public', 'claim_competition_invite', array['bytea'],
  'authenticated claim RPC exists');
select has_function('public', 'cleanup_expired_competition_invites', array[]::text[],
  'service cleanup RPC exists');

select ok(coalesce((
  select procedure_row.prosecdef
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'create_competition_invite'
), false), 'create RPC is security definer');
select ok(coalesce((
  select 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'create_competition_invite'
), false), 'create RPC has an empty search path');
select ok(coalesce((
  select procedure_row.prosecdef and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'claim_competition_invite'
), false), 'claim RPC is security definer with an empty search path');
select ok(coalesce((
  select procedure_row.prosecdef and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'cleanup_expired_competition_invites'
), false), 'cleanup RPC is security definer with an empty search path');

select ok(coalesce((
  select has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1 from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row where acl_row.grantee = 0 and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'create_competition_invite'
), false), 'only service_role may execute create');
select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1 from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row where acl_row.grantee = 0 and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'claim_competition_invite'
), false), 'only authenticated API users may execute claim');
select ok(coalesce((
  select has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1 from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl, pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row where acl_row.grantee = 0 and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public' and procedure_row.proname = 'cleanup_expired_competition_invites'
), false), 'only service_role may execute cleanup');

insert into auth.users (id, instance_id, aud, role, email, encrypted_password, created_at, updated_at) values
  ('51000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'invite-alice@example.invalid', '', now(), now()),
  ('51000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'invite-bob@example.invalid', '', now(), now()),
  ('51000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'invite-mallory@example.invalid', '', now(), now());

insert into public.profiles (id, auth_user_id, display_name, state) values
  ('52000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000001', 'Invite Alice', 'active'),
  ('52000000-0000-0000-0000-000000000002', '51000000-0000-0000-0000-000000000002', 'Invite Bob', 'active'),
  ('52000000-0000-0000-0000-000000000003', '51000000-0000-0000-0000-000000000003', 'Invite Mallory', 'active');

create temporary table invite_test_context (name text primary key, id uuid not null);
grant select, insert, update on invite_test_context to authenticated, service_role;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$select public.create_competition_invite(decode(repeat('01', 32), 'hex'), 'UTC', null, gen_random_uuid())$$,
  '42501', null, 'anonymous create is denied');
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('01', 32), 'hex'))$$,
  '42501', null, 'anonymous claim is denied');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"51000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$select public.create_competition_invite(decode(repeat('01', 32), 'hex'), 'UTC', null, '51000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'authenticated users cannot bypass Edge token generation by calling create directly');
reset role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into invite_test_context
select 'primary', public.create_competition_invite(
  decode(repeat('01', 32), 'hex'), 'America/Los_Angeles', null,
  '51000000-0000-0000-0000-000000000001');
reset role;

select is((select lifecycle from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  'pending', 'create produces a pending competition');
select is((select time_zone_identifier from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  'America/Los_Angeles', 'create stores the creator time zone immediately');
select is((select start_day from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  null::date, 'create does not freeze a start day before claim');
select is((select count(*)::bigint from public.competition_participants
           where competition_id = (select id from invite_test_context where name = 'primary')
             and profile_id = '52000000-0000-0000-0000-000000000001' and role = 'creator' and state = 'accepted'),
  1::bigint, 'create records the authenticated creator as accepted');
select is((select encode(token_digest, 'hex') from public.competition_invites
           where competition_id = (select id from invite_test_context where name = 'primary')),
  repeat('01', 32), 'create stores exactly the supplied SHA-256 digest');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select public.create_competition_invite(decode(repeat('02', 32), 'hex'), 'Not/A_Time_Zone', null, '51000000-0000-0000-0000-000000000001')$$,
  '22023', 'invalid_time_zone', 'create validates the IANA time zone catalog');
select throws_ok(
  $$select public.create_competition_invite(decode(repeat('02', 31), 'hex'), 'UTC', null, '51000000-0000-0000-0000-000000000001')$$,
  '22023', 'invalid_token_digest', 'create accepts only a SHA-256-sized digest');
reset role;
set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"51000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('01', 32), 'hex'))$$,
  'P0001', 'cannot_claim_own_invite', 'creator cannot claim their own invitation');

select set_config('request.jwt.claims', '{"sub":"51000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select is(public.claim_competition_invite(decode(repeat('01', 32), 'hex')),
  (select id from invite_test_context where name = 'primary'), 'claim returns the competition ID');
reset role;
select is((select lifecycle from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  'scheduled', 'claim schedules the competition atomically');
select is((select start_day from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  ((now() at time zone 'America/Los_Angeles')::date + 1), 'claim freezes the next creator-local calendar day');
select is((select best_available_deadline from public.competitions where id = (select id from invite_test_context where name = 'primary')),
  ((((now() at time zone 'America/Los_Angeles')::date + 1 + 8)::timestamp)
    at time zone 'America/Los_Angeles'),
  'claim freezes the DST-safe Day-9 boundary in the creator IANA zone');
select is((select count(*)::bigint from public.competition_participants
           where competition_id = (select id from invite_test_context where name = 'primary')
             and profile_id = '52000000-0000-0000-0000-000000000002' and role = 'invitee' and state = 'accepted'),
  1::bigint, 'claim creates exactly one accepted invitee');
select ok((select consumed_at is not null and claimed_profile_id = '52000000-0000-0000-0000-000000000002'
           from public.competition_invites where competition_id = (select id from invite_test_context where name = 'primary')),
  'claim consumes the invite without replacing its history');
select results_eq(
  $$select server_seq from public.competition_change_log
    where competition_id = (select id from invite_test_context where name = 'primary') order by server_seq$$,
  $$select generate_series(1::bigint, 3::bigint)$$,
  'create and claim preserve a gap-free competition cursor');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"51000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('01', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'consumed invite reuse is privacy-safe and idempotently rejected');
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('99', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'unknown invite uses the same privacy-safe failure');

reset role;
insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day, scoring_policy_identity,
  lifecycle, invitation_expires_at, best_available_deadline
) values (
  '53000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001',
  'UTC', current_date - 8, 'healthcomp.activity-score.v1', 'completed', now() - interval '8 days', now() - interval '1 day'
);
insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('53000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
  ('53000000-0000-0000-0000-000000000001', '52000000-0000-0000-0000-000000000002', 'invitee', 'accepted');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into invite_test_context
select 'rematch', public.create_competition_invite(
  decode(repeat('03', 32), 'hex'), 'Pacific/Kiritimati',
  '53000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000002');
reset role;
select isnt((select id from invite_test_context where name = 'rematch'),
  '53000000-0000-0000-0000-000000000001'::uuid, 'rematch receives a new competition identity');
select is((select rematch_parent_id from public.competitions where id = (select id from invite_test_context where name = 'rematch')),
  '53000000-0000-0000-0000-000000000001'::uuid, 'rematch links to its completed source');
select is((select scoring_policy_identity from public.competitions where id = (select id from invite_test_context where name = 'rematch')),
  'healthcomp.activity-score.v1', 'rematch inherits the source scoring policy');
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select public.create_competition_invite(decode(repeat('04', 32), 'hex'), 'UTC', '53000000-0000-0000-0000-000000000001', '51000000-0000-0000-0000-000000000003')$$,
  '42501', 'rematch_not_allowed', 'a nonparticipant cannot create a rematch');

reset role;
update public.competition_invites set expires_at = now() - interval '1 second', created_at = now() - interval '1 hour'
where competition_id = (select id from invite_test_context where name = 'rematch');

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"51000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('03', 32), 'hex'))$$,
  'P0001', 'invite_unavailable', 'expired invite uses the same privacy-safe failure');
reset role;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(public.cleanup_expired_competition_invites(), 1::bigint,
  'cleanup marks one expired unclaimed pending competition');
select is(public.cleanup_expired_competition_invites(), 0::bigint,
  'cleanup is idempotent');
reset role;
select is((select lifecycle from public.competitions where id = (select id from invite_test_context where name = 'rematch')),
  'expired', 'cleanup retains history and marks the competition expired');
select is((select count(*)::bigint from public.competition_invites
           where competition_id = (select id from invite_test_context where name = 'rematch') and consumed_at is null),
  1::bigint, 'cleanup retains the unconsumed invite history');

select * from finish();
rollback;
