begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(108);

select has_function(
  'public',
  'bootstrap_current_profile',
  array['text'],
  'authenticated profile bootstrap RPC exists'
);
select has_function(
  'public',
  'update_current_profile',
  array['text'],
  'authenticated profile update RPC exists'
);

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'bootstrap_current_profile'
    and procedure_row.proargtypes = '25'::oidvector
), false), 'profile bootstrap is security definer with an empty search path');

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'update_current_profile'
    and procedure_row.proargtypes = '25'::oidvector
), false), 'profile update is security definer with an empty search path');

select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'bootstrap_current_profile'
    and procedure_row.proargtypes = '25'::oidvector
), false), 'only authenticated API users may execute profile bootstrap');

select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'update_current_profile'
    and procedure_row.proargtypes = '25'::oidvector
), false), 'only authenticated API users may execute profile update');

select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'profiles'
    and grantee = 'authenticated'
    and privilege_type in (
      'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER'
    )
), 0::bigint, 'profile mutation remains RPC-only');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values (
  '81000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000000',
  'authenticated',
  'authenticated',
  'profile-bootstrap@example.invalid',
  '',
  now(),
  now()
);

create temporary table profile_api_results (
  name text primary key,
  payload jsonb not null
);
grant select, insert, update on profile_api_results to authenticated;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$select public.bootstrap_current_profile(null)$$,
  '42501', null, 'anonymous profile bootstrap is denied'
);
select throws_ok(
  $$select public.update_current_profile('Anonymous')$$,
  '42501', null, 'anonymous profile update is denied'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);

select throws_ok(
  $$select public.bootstrap_current_profile(null)$$,
  'P0001', 'display_name_required',
  'first bootstrap requires an explicit user-selected display name'
);
reset role;
select is((
  select count(*)::bigint
  from public.profiles
  where auth_user_id = '81000000-0000-0000-0000-000000000001'
), 0::bigint, 'missing display name does not create a placeholder profile');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.bootstrap_current_profile('   ')$$,
  '22023', 'invalid_display_name', 'bootstrap rejects a blank display name'
);
select throws_ok(
  $$select public.bootstrap_current_profile('Former competitor')$$,
  '22023', 'invalid_display_name', 'bootstrap rejects the anonymized presentation label'
);
select throws_ok(
  $$select public.bootstrap_current_profile(E'Line\nBreak')$$,
  '22023', 'invalid_display_name', 'bootstrap rejects control characters'
);

select lives_ok(
  $$insert into profile_api_results (name, payload)
    select 'bootstrap', public.bootstrap_current_profile('  Beta Alice  ')$$,
  'bootstrap creates the first active profile'
);
reset role;
select is((
  select count(*)::bigint
  from public.profiles
  where auth_user_id = '81000000-0000-0000-0000-000000000001'
    and state = 'active'
    and display_name = 'Beta Alice'
), 1::bigint, 'bootstrap creates exactly one trimmed active profile');
select is((
  select payload
  from profile_api_results
  where name = 'bootstrap'
), (
  select jsonb_build_object('id', profile_row.id, 'display_name', 'Beta Alice')
  from public.profiles profile_row
  where profile_row.auth_user_id = '81000000-0000-0000-0000-000000000001'
), 'bootstrap returns only stable profile identity and display name');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into profile_api_results (name, payload)
    select 'repeat', public.bootstrap_current_profile('Different Name')$$,
  'repeat bootstrap returns the existing profile'
);
reset role;
select is((
  select (select payload from profile_api_results where name = 'repeat')
    = (select payload from profile_api_results where name = 'bootstrap')
    and (select display_name from public.profiles
         where auth_user_id = '81000000-0000-0000-0000-000000000001')
      = 'Beta Alice'
), true, 'repeat bootstrap is stable and never overwrites the display name');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into profile_api_results (name, payload)
    select 'updated', public.update_current_profile('  Beta Prime  ')$$,
  'profile update accepts a trimmed user-selected display name'
);
reset role;
select is((
  select payload
  from profile_api_results
  where name = 'updated'
), (
  select jsonb_build_object('id', profile_row.id, 'display_name', 'Beta Prime')
  from public.profiles profile_row
  where profile_row.auth_user_id = '81000000-0000-0000-0000-000000000001'
), 'profile update returns only the safe projection');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.update_current_profile('   ')$$,
  '22023', 'invalid_display_name', 'profile update rejects a blank display name'
);
select throws_ok(
  $$select public.update_current_profile(repeat('a', 65))$$,
  '22023', 'invalid_display_name', 'profile update rejects names longer than 64 characters'
);
select throws_ok(
  $$select public.update_current_profile(E'Line\tBreak')$$,
  '22023', 'invalid_display_name', 'profile update rejects control characters'
);
select throws_ok(
  $$select public.update_current_profile('Former competitor')$$,
  '22023', 'invalid_display_name', 'profile update rejects the anonymized presentation label'
);
reset role;

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
)
select competition_id, profile_row.id, 'UTC', null,
       'healthcomp.activity-score.v1', 'pending', now() + interval '1 day', null
from public.profiles profile_row
cross join (values
  ('83000000-0000-0000-0000-000000000001'::uuid),
  ('83000000-0000-0000-0000-000000000002'::uuid)
) competition(competition_id)
where profile_row.auth_user_id = '81000000-0000-0000-0000-000000000001';

insert into public.competition_participants (
  competition_id, profile_id, role, state
)
select competition_id, profile_row.id, 'creator', 'accepted'
from public.profiles profile_row
cross join (values
  ('83000000-0000-0000-0000-000000000001'::uuid),
  ('83000000-0000-0000-0000-000000000002'::uuid)
) competition(competition_id)
where profile_row.auth_user_id = '81000000-0000-0000-0000-000000000001';
set constraints all immediate;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into profile_api_results (name, payload)
    select 'presentation-change', public.update_current_profile('Beta Changed')$$,
  'display-name change succeeds for a profile with competitions'
);
reset role;

select is((
  select count(*)::bigint
  from public.competition_change_log change_row
  where change_row.competition_id in (
    '83000000-0000-0000-0000-000000000001',
    '83000000-0000-0000-0000-000000000002'
  )
    and change_row.change_kind = 'profile_presentation_changed'
), 2::bigint, 'display-name change emits one presentation change per competition');

select results_eq(
  $$select competition_id, server_seq
    from public.competition_change_log
    where competition_id in (
      '83000000-0000-0000-0000-000000000001',
      '83000000-0000-0000-0000-000000000002'
    )
    order by competition_id, server_seq$$,
  $$values
    ('83000000-0000-0000-0000-000000000001'::uuid, 1::bigint),
    ('83000000-0000-0000-0000-000000000001'::uuid, 2::bigint),
    ('83000000-0000-0000-0000-000000000002'::uuid, 1::bigint),
    ('83000000-0000-0000-0000-000000000002'::uuid, 2::bigint)$$,
  'presentation changes preserve each competition gap-free cursor'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.update_current_profile('Beta Changed')$$,
  'an idempotent display-name update succeeds'
);
reset role;
select is((
  select count(*)::bigint
  from public.competition_change_log change_row
  where change_row.competition_id in (
    '83000000-0000-0000-0000-000000000001',
    '83000000-0000-0000-0000-000000000002'
  )
    and change_row.change_kind = 'profile_presentation_changed'
), 2::bigint, 'an idempotent display-name update emits no change');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values (
  '81000000-0000-0000-0000-000000000002',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'profile-anonymize@example.invalid', '',
  now(), now()
);
insert into public.profiles (id, auth_user_id, display_name, state) values (
  '82000000-0000-0000-0000-000000000002',
  '81000000-0000-0000-0000-000000000002',
  'Delete Me', 'active'
);
set constraints all deferred;
insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  '83000000-0000-0000-0000-000000000003',
  '82000000-0000-0000-0000-000000000002',
  'UTC', null, 'healthcomp.activity-score.v1', 'pending',
  now() + interval '1 day', null
);
insert into public.competition_participants (
  competition_id, profile_id, role, state
) values (
  '83000000-0000-0000-0000-000000000003',
  '82000000-0000-0000-0000-000000000002',
  'creator', 'accepted'
);
set constraints all immediate;
update public.profiles
set state = 'anonymized',
    auth_user_id = null,
    display_name = 'Former competitor',
    anonymized_at = now()
where id = '82000000-0000-0000-0000-000000000002';

select results_eq(
  $$select change_kind
    from public.competition_change_log
    where competition_id = '83000000-0000-0000-0000-000000000003'
      and change_kind like 'profile_%'
    order by server_seq$$,
  $$values ('profile_anonymized'::text)$$,
  'anonymization emits only profile_anonymized presentation work'
);

select has_column(
  'public', 'competitions', 'invite_creation_idempotency_key',
  'competitions store the invite creation idempotency key'
);
select has_column(
  'public', 'competitions', 'invite_token_derivation_version',
  'competitions store the invite token derivation version'
);
select col_default_is(
  'public', 'competitions', 'invite_token_derivation_version', '0',
  'legacy invite rows default to random-token derivation version zero'
);
select has_function(
  'public',
  'create_competition_invite',
  array['bytea', 'text', 'uuid', 'uuid', 'uuid', 'smallint'],
  'idempotent service create RPC exists'
);
select ok(coalesce((
  select has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'create_competition_invite'
    and procedure_row.proargtypes = '17 25 2950 2950 2950 21'::oidvector
), false), 'only service_role may execute idempotent invite creation');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values (
  '81000000-0000-0000-0000-000000000003',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'invite-second-creator@example.invalid', '',
  now(), now()
);
insert into public.profiles (
  id, auth_user_id, display_name, state
) values (
  '82000000-0000-0000-0000-000000000003',
  '81000000-0000-0000-0000-000000000003',
  'Second Creator', 'active'
);

create temporary table idempotent_invite_results (
  name text primary key,
  competition_id uuid not null
);
grant select, insert on idempotent_invite_results to service_role;

set constraints all deferred;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(
  $$insert into idempotent_invite_results (name, competition_id)
    select 'first', public.create_competition_invite(
      decode(repeat('41', 32), 'hex'), 'America/Los_Angeles', null,
      '81000000-0000-0000-0000-000000000001',
      '84000000-0000-4000-8000-000000000001', 1::smallint
    )$$,
  'first idempotent invite creation succeeds'
);
select lives_ok(
  $$insert into idempotent_invite_results (name, competition_id)
    select 'retry', public.create_competition_invite(
      decode(repeat('41', 32), 'hex'), 'America/Los_Angeles', null,
      '81000000-0000-0000-0000-000000000001',
      '84000000-0000-4000-8000-000000000001', 1::smallint
    )$$,
  'exact invite creation retry succeeds'
);
reset role;

select ok((
  select first_result.competition_id is not null
    and first_result.competition_id = retry_result.competition_id
  from idempotent_invite_results first_result
  cross join idempotent_invite_results retry_result
  where first_result.name = 'first' and retry_result.name = 'retry'
), 'exact retry returns the original competition identity');
select is((
  select count(*)::bigint
  from public.competitions competition_row
  where competition_row.creator_profile_id = (
    select id from public.profiles
    where auth_user_id = '81000000-0000-0000-0000-000000000001'
  )
    and competition_row.invite_creation_idempotency_key
      = '84000000-0000-4000-8000-000000000001'
), 1::bigint, 'exact retry creates no orphan competition');
select ok((
  select invite_row.token_digest = decode(repeat('41', 32), 'hex')
    and competition_row.invite_token_derivation_version = 1
  from public.competitions competition_row
  join public.competition_invites invite_row
    on invite_row.competition_id = competition_row.id
  where competition_row.id = (
    select competition_id from idempotent_invite_results where name = 'first'
  )
), 'idempotent creation stores only the digest and derivation version');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$select public.create_competition_invite(
    decode(repeat('42', 32), 'hex'), 'America/Los_Angeles', null,
    '81000000-0000-0000-0000-000000000001',
    '84000000-0000-4000-8000-000000000001', 1::smallint
  )$$,
  'P0001', 'idempotency_conflict',
  'same creator and key reject a divergent token digest'
);
select throws_ok(
  $$select public.create_competition_invite(
    decode(repeat('41', 32), 'hex'), 'UTC', null,
    '81000000-0000-0000-0000-000000000001',
    '84000000-0000-4000-8000-000000000001', 1::smallint
  )$$,
  'P0001', 'idempotency_conflict',
  'same creator and key reject divergent request semantics'
);
select throws_ok(
  $$select public.create_competition_invite(
    decode(repeat('43', 32), 'hex'), 'UTC', null,
    '81000000-0000-0000-0000-000000000001',
    '84000000-0000-4000-8000-000000000002', 0::smallint
  )$$,
  '22023', 'invalid_token_derivation_version',
  'new idempotent creation accepts only derivation version one'
);
select lives_ok(
  $$insert into idempotent_invite_results (name, competition_id)
    select 'other-creator', public.create_competition_invite(
      decode(repeat('44', 32), 'hex'), 'UTC', null,
      '81000000-0000-0000-0000-000000000003',
      '84000000-0000-4000-8000-000000000001', 1::smallint
    )$$,
  'another creator may independently use the same UUID key'
);
reset role;
select ok((
  select first_result.competition_id <> other_result.competition_id
  from idempotent_invite_results first_result
  cross join idempotent_invite_results other_result
  where first_result.name = 'first' and other_result.name = 'other-creator'
), 'creator identity scopes the idempotency key');

select ok(coalesce((
  select not has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'create_competition_invite'
    and procedure_row.proargtypes = '17 25 2950 2950'::oidvector
), false), 'legacy random-token create overload is no longer executable');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values (
  '81000000-0000-0000-0000-000000000004',
  '00000000-0000-0000-0000-000000000000',
  'authenticated', 'authenticated', 'invite-outsider@example.invalid', '',
  now(), now()
);
insert into public.profiles (
  id, auth_user_id, display_name, state
) values (
  '82000000-0000-0000-0000-000000000004',
  '81000000-0000-0000-0000-000000000004',
  'Invite Outsider', 'active'
);

create temporary table idempotent_claim_results (
  name text primary key,
  competition_id uuid not null
);
grant select, insert on idempotent_claim_results to authenticated;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into idempotent_claim_results (name, competition_id)
    select 'first', public.claim_competition_invite(
      decode(repeat('41', 32), 'hex')
    )$$,
  'first authenticated invite claim succeeds'
);
select lives_ok(
  $$insert into idempotent_claim_results (name, competition_id)
    select 'retry', public.claim_competition_invite(
      decode(repeat('41', 32), 'hex')
    )$$,
  'same profile recovers an already-consumed invite claim'
);
reset role;

select ok((
  select first_result.competition_id is not null
    and first_result.competition_id = retry_result.competition_id
  from idempotent_claim_results first_result
  cross join idempotent_claim_results retry_result
  where first_result.name = 'first' and retry_result.name = 'retry'
), 'claim retry returns the original competition identity');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.claim_competition_invite(decode(repeat('41', 32), 'hex'))$$,
  'P0001', 'invite_unavailable',
  'a different profile sees the consumed invite as unavailable'
);
reset role;

select has_column(
  'public', 'device_installations', 'installation_id',
  'device installations have a client-stable installation identity'
);
select ok(coalesce((
  select index_row.indisunique
  from pg_catalog.pg_index index_row
  join pg_catalog.pg_class table_row on table_row.oid = index_row.indrelid
  join pg_catalog.pg_namespace schema_row on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and table_row.relname = 'device_installations'
    and pg_catalog.pg_get_indexdef(index_row.indexrelid)
      like '%(profile_id, installation_id)%'
), false), 'profile and installation identity are unique together');
select has_function(
  'public', 'register_current_device_installation',
  array['uuid', 'text', 'text'],
  'authenticated installation registration RPC exists'
);
select has_function(
  'public', 'remove_current_device_installation', array['uuid'],
  'authenticated installation removal RPC exists'
);
select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
    and has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'register_current_device_installation'
    and procedure_row.proargtypes = '2950 25 25'::oidvector
), false), 'installation registration is a narrow authenticated definer RPC');
select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
    and has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'remove_current_device_installation'
    and procedure_row.proargtypes = '2950'::oidvector
), false), 'installation removal is a narrow authenticated definer RPC');
select is(
  has_table_privilege('authenticated', 'public.device_installations', 'SELECT'),
  false,
  'authenticated clients have no raw installation table access'
);

create temporary table installation_api_results (
  name text primary key,
  payload jsonb not null
);
grant select, insert on installation_api_results to authenticated;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$select public.register_current_device_installation(
    '85000000-0000-4000-8000-000000000001', repeat('a1', 32), 'sandbox'
  )$$,
  '42501', null, 'anonymous installation registration is denied'
);
select throws_ok(
  $$select public.remove_current_device_installation(
    '85000000-0000-4000-8000-000000000001'
  )$$,
  '42501', null, 'anonymous installation removal is denied'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.register_current_device_installation(
    null, repeat('a1', 32), 'sandbox'
  )$$,
  '22023', 'invalid_installation_request',
  'registration rejects a missing installation identity'
);
select throws_ok(
  $$select public.register_current_device_installation(
    '85000000-0000-4000-8000-000000000001', 'not-a-token', 'sandbox'
  )$$,
  '22023', 'invalid_installation_request',
  'registration rejects a malformed APNs token'
);
select throws_ok(
  $$select public.register_current_device_installation(
    '85000000-0000-4000-8000-000000000001', repeat('a1', 32), 'invalid'
  )$$,
  '22023', 'invalid_installation_request',
  'registration rejects an invalid APNs environment'
);
select lives_ok(
  $$insert into installation_api_results (name, payload)
    select 'registered', public.register_current_device_installation(
      '85000000-0000-4000-8000-000000000001', repeat('a1', 32), 'sandbox'
    )$$,
  'active profile registers an installation'
);
reset role;

select is((
  select payload from installation_api_results where name = 'registered'
), jsonb_build_object(
  'installation_id', '85000000-0000-4000-8000-000000000001'::uuid,
  'environment', 'sandbox',
  'state', 'active'
), 'registration response omits APNs token and profile identity');
select is((
  select count(*)::bigint
  from public.device_installations installation_row
  where installation_row.profile_id = '82000000-0000-0000-0000-000000000004'
    and installation_row.installation_id
      = '85000000-0000-4000-8000-000000000001'
    and installation_row.apns_token = repeat('a1', 32)
    and installation_row.environment = 'sandbox'
    and installation_row.state = 'active'
), 1::bigint, 'server stores one owned token without exposing it to the client');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into installation_api_results (name, payload)
    select 'retry', public.register_current_device_installation(
      '85000000-0000-4000-8000-000000000001', repeat('a1', 32), 'sandbox'
    )$$,
  'exact installation retry succeeds'
);
reset role;
select ok((
  select (select payload from installation_api_results where name = 'retry')
      = (select payload from installation_api_results where name = 'registered')
    and (select count(*) from public.device_installations installation_row
         where installation_row.profile_id = '82000000-0000-0000-0000-000000000004'
           and installation_row.installation_id
             = '85000000-0000-4000-8000-000000000001') = 1
), 'exact installation retry returns the same projection without a duplicate');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into installation_api_results (name, payload)
    select 'rotated', public.register_current_device_installation(
      '85000000-0000-4000-8000-000000000001', repeat('b2', 32), 'production'
    )$$,
  'owned installation rotates its token and environment'
);
reset role;
select is((
  select count(*)::bigint
  from public.device_installations installation_row
  where installation_row.profile_id = '82000000-0000-0000-0000-000000000004'
    and installation_row.installation_id
      = '85000000-0000-4000-8000-000000000001'
    and installation_row.apns_token = repeat('b2', 32)
    and installation_row.environment = 'production'
    and installation_row.state = 'active'
), 1::bigint, 'token rotation updates the one owned installation');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.register_current_device_installation(
    '85000000-0000-4000-8000-000000000002', repeat('b2', 32), 'production'
  )$$,
  'P0001', 'installation_unavailable',
  'cross-profile APNs token collision is privacy-collapsed'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into installation_api_results (name, payload)
    select 'removed', public.remove_current_device_installation(
      '85000000-0000-4000-8000-000000000001'
    )$$,
  'owner removes an installation'
);
reset role;
select is((
  select payload from installation_api_results where name = 'removed'
), jsonb_build_object(
  'installation_id', '85000000-0000-4000-8000-000000000001'::uuid,
  'environment', 'production',
  'state', 'revoked'
), 'removal response remains a token-free safe projection');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into installation_api_results (name, payload)
    select 'remove-retry', public.remove_current_device_installation(
      '85000000-0000-4000-8000-000000000001'
    )$$,
  'exact installation removal retry succeeds'
);
reset role;
select is((
  select (select payload from installation_api_results where name = 'remove-retry')
    = (select payload from installation_api_results where name = 'removed')
), true, 'removal retry returns the same revoked projection');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.remove_current_device_installation(
    '85000000-0000-4000-8000-000000000099'
  )$$,
  'P0001', 'installation_unavailable',
  'unknown installation removal is privacy-collapsed'
);
reset role;

select has_function(
  'public', 'fetch_competition_changes',
  array['uuid', 'bigint', 'integer'],
  'typed authenticated competition change-feed RPC exists'
);
select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'fetch_competition_changes'
    and procedure_row.proargtypes = '2950 20 23'::oidvector
), false), 'change feed is security definer with an empty search path');
select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'fetch_competition_changes'
    and procedure_row.proargtypes = '2950 20 23'::oidvector
), false), 'only authenticated API users may execute the change feed');
select is(
  has_table_privilege('authenticated', 'public.competition_change_log', 'SELECT'),
  false,
  'typed change feed does not grant raw change-log access'
);

update public.profiles
set display_name = 'Feed Creator',
    updated_at = now()
where auth_user_id = '81000000-0000-0000-0000-000000000001';

create temporary table change_feed_results (
  name text primary key,
  payload jsonb not null
);
grant select, insert on change_feed_results to authenticated;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    0, 100
  )$$,
  '42501', null, 'anonymous change-feed access is denied'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    -1, 100
  )$$,
  '22023', 'invalid_cursor', 'negative change-feed cursor is rejected'
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    5, 100
  )$$,
  '22023', 'cursor_ahead', 'cursor ahead of the frozen snapshot is rejected'
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    0, 0
  )$$,
  '22023', 'invalid_page_size', 'zero change-feed page size is rejected'
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    0, 201
  )$$,
  '22023', 'invalid_page_size', 'change-feed page size above 200 is rejected'
);
select lives_ok(
  $$insert into change_feed_results (name, payload)
    select 'first-page', public.fetch_competition_changes(
      (select competition_id from idempotent_claim_results where name = 'first'),
      0, 2
    )$$,
  'accepted participant fetches the first frozen change page'
);
reset role;

select is((
  select array_agg(key order by key)
  from change_feed_results result_row,
       lateral jsonb_object_keys(result_row.payload) keys(key)
  where result_row.name = 'first-page'
), array[
  'after_server_seq', 'changes', 'competition_id', 'has_more',
  'next_server_seq', 'snapshot_server_seq'
]::text[], 'change page has an exact closed top-level key set');
select ok((
  select payload->>'after_server_seq' = '0'
    and payload->>'snapshot_server_seq' = '4'
    and payload->>'next_server_seq' = '2'
    and payload->'has_more' = 'true'::jsonb
    and jsonb_array_length(payload->'changes') = 2
    and jsonb_typeof(payload->'after_server_seq') = 'string'
    and jsonb_typeof(payload->'snapshot_server_seq') = 'string'
    and jsonb_typeof(payload->'next_server_seq') = 'string'
  from change_feed_results where name = 'first-page'
), 'first page freezes snapshot four and decimal-string encodes cursors');
select is((
  select array_agg(key order by key)
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row,
       lateral jsonb_object_keys(change_row) keys(key)
  where result_row.name = 'first-page'
), array[
  'entity_id', 'entity_id', 'kind', 'kind', 'occurred_at', 'occurred_at',
  'payload', 'payload', 'server_seq', 'server_seq'
]::text[], 'each change envelope has only typed identity, time, payload, and cursor');
select ok((
  select bool_and(
    change_row->>'kind' = 'participant_added'
    and jsonb_typeof(change_row->'server_seq') = 'string'
    and (select array_agg(key order by key)
         from jsonb_object_keys(change_row->'payload') keys(key))
      = array['profile_id', 'role', 'state']::text[]
  )
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'first-page'
), 'participant payloads expose only stable profile identity, role, and state');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into change_feed_results (name, payload)
    select 'second-page', public.fetch_competition_changes(
      (select competition_id from idempotent_claim_results where name = 'first'),
      2, 200
    )$$,
  'accepted participant fetches the remaining frozen changes'
);
reset role;
select ok((
  select payload->>'after_server_seq' = '2'
    and payload->>'snapshot_server_seq' = '4'
    and payload->>'next_server_seq' = '4'
    and payload->'has_more' = 'false'::jsonb
    and (select array_agg(change_row->>'kind' order by change_row->>'server_seq')
         from jsonb_array_elements(payload->'changes') change_row)
      = array['competition_lifecycle_changed', 'profile_presentation_changed']::text[]
  from change_feed_results where name = 'second-page'
), 'second page returns contiguous lifecycle then profile changes');
select is((
  select array_agg(key order by key)
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row,
       lateral jsonb_object_keys(change_row->'payload') keys(key)
  where result_row.name = 'second-page'
    and change_row->>'kind' = 'profile_presentation_changed'
), array['display_name', 'profile_id']::text[],
  'profile presentation payload exposes only stable ID and safe display name'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.update_current_profile('Feed Creator Two')$$,
  'participant can publish a later profile presentation change'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into change_feed_results (name, payload)
    select 'retried-profile-event', public.fetch_competition_changes(
      (select competition_id from idempotent_claim_results where name = 'first'),
      3, 1
    )$$,
  'counterpart can retry the exact earlier profile event after a later update'
);
reset role;
select is((
  select retry_change->'payload'
  from change_feed_results retry_result,
       lateral jsonb_array_elements(retry_result.payload->'changes') retry_change
  where retry_result.name = 'retried-profile-event'
), (
  select original_change->'payload'
  from change_feed_results original_result,
       lateral jsonb_array_elements(original_result.payload->'changes') original_change
  where original_result.name = 'second-page'
    and original_change->>'server_seq' = '4'
), 'an exact retry returns sequence-bound profile presentation payload bytes');

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000004","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    0, 100
  )$$,
  'P0002', 'competition_not_found',
  'outsider competition access is privacy-collapsed'
);
select throws_ok(
  $$select public.fetch_competition_changes(
    '89000000-0000-4000-8000-000000000099', 0, 100
  )$$,
  'P0002', 'competition_not_found',
  'nonexistent competition access uses the same privacy-collapsed failure'
);
reset role;

select private.allocate_competition_server_seq(
  (select competition_id from idempotent_claim_results where name = 'first'),
  'future_change_kind',
  '89000000-0000-4000-8000-000000000001',
  now()
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    4, 100
  )$$,
  'P0001', 'server_contract_mismatch',
  'unknown change kind fails closed without returning a cursor'
);
select throws_ok(
  $$select public.fetch_competition_changes(
    (select competition_id from idempotent_claim_results where name = 'first'),
    4, 100
  )$$,
  'P0001', 'server_contract_mismatch',
  'unknown change kind remains visible on exact retry'
);
reset role;

select private.allocate_competition_server_seq(
  '83000000-0000-0000-0000-000000000001',
  'score_revision_recorded',
  '89000000-0000-4000-8000-000000000002',
  now()
);
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.fetch_competition_changes(
    '83000000-0000-0000-0000-000000000001',
    3,
    100
  )$$,
  'P0001', 'server_contract_mismatch',
  'known change with a missing authoritative entity fails closed'
);
reset role;

set constraints all deferred;
insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  '86000000-0000-4000-8000-000000000001',
  '82000000-0000-0000-0000-000000000003',
  'UTC', current_date, 'healthcomp.activity-score.v1', 'active',
  now() - interval '8 days', now() + interval '1 day'
);
insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    '86000000-0000-4000-8000-000000000001',
    '82000000-0000-0000-0000-000000000003', 'creator', 'accepted'
  ),
  (
    '86000000-0000-4000-8000-000000000001',
    '82000000-0000-0000-0000-000000000004', 'invitee', 'accepted'
  );
set constraints all immediate;

insert into public.daily_score_revisions (
  id, competition_id, participant_profile_id, day_ordinal,
  semantic_event_id, client_revision, move_mode, stand_mode,
  move_basis_points, exercise_basis_points, stand_basis_points,
  accepted_centi_points, availability_reason, scoring_policy_identity,
  wire_content_sha256, server_seq, evaluated_at
) values (
  '87000000-0000-4000-8000-000000000001',
  '86000000-0000-4000-8000-000000000001',
  '82000000-0000-0000-0000-000000000003',
  1, 'typed-payload-score', 9007199254740993,
  'activeEnergyKilocalories', 'standHours',
  null, null, null, null, 'sourceDataUnavailable',
  'healthcomp.activity-score.v1',
  private.wire_score_digest_v1(
    '86000000-0000-4000-8000-000000000001',
    '82000000-0000-0000-0000-000000000003',
    1::smallint, 'activeEnergyKilocalories', 'standHours',
    null, null, null, null, 'sourceDataUnavailable',
    'healthcomp.activity-score.v1', 9007199254740993
  ),
  1, now() - interval '1 hour'
);

insert into public.participant_finalization_attestations (
  id, competition_id, participant_profile_id, basis,
  window_commitment_sha256, accepted_revisions, server_seq, attested_at
) values (
  '87000000-0000-4000-8000-000000000002',
  '86000000-0000-4000-8000-000000000001',
  '82000000-0000-0000-0000-000000000003', 'best_available',
  decode(repeat('a5', 32), 'hex'),
  array[9007199254740993, 2, 3, 4, 5, 6, 7]::bigint[],
  1, now() - interval '30 minutes'
);

insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values (
  '86000000-0000-4000-8000-000000000001',
  '82000000-0000-0000-0000-000000000003',
  '82000000-0000-0000-0000-000000000004',
  0, 0, null, 'tie', 'best_available', now() - interval '15 minutes',
  jsonb_build_object(
    'version', 1,
    'participants', jsonb_build_array(
      jsonb_build_object(
        'profile_id', '82000000-0000-0000-0000-000000000003',
        'days', (
          select jsonb_agg(jsonb_build_object(
            'ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing'
          ) order by ordinal)
          from generate_series(1, 7) ordinal
        )
      ),
      jsonb_build_object(
        'profile_id', '82000000-0000-0000-0000-000000000004',
        'days', (
          select jsonb_agg(jsonb_build_object(
            'ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing'
          ) order by ordinal)
          from generate_series(1, 7) ordinal
        )
      )
    )
  ),
  decode(repeat('b6', 32), 'hex'), 1
);

insert into public.competition_awards (
  id, competition_id, profile_id, award_type, server_seq, earned_at
) values (
  '87000000-0000-4000-8000-000000000003',
  '86000000-0000-4000-8000-000000000001',
  '82000000-0000-0000-0000-000000000003',
  'seven_day_finisher', 1, now()
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select lives_ok(
  $$insert into change_feed_results (name, payload)
    select 'typed-payloads', public.fetch_competition_changes(
      '86000000-0000-4000-8000-000000000001', 2, 100
    )$$,
  'participant fetches all typed append-only payload families'
);
reset role;

select is((
  select array_agg(change_row->>'kind' order by (change_row->>'server_seq')::bigint)
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'typed-payloads'
), array[
  'score_revision_recorded', 'participant_attested',
  'competition_result_confirmed', 'competition_award_earned'
]::text[], 'typed append-only payload families remain gap-free and ordered');

select ok((
  select (select array_agg(key order by key)
          from jsonb_object_keys(change_row->'payload') keys(key)) = array[
           'accepted_centi_points', 'availability_reason', 'client_revision',
           'day_ordinal', 'evaluated_at', 'exercise_basis_points', 'move_basis_points',
           'move_mode', 'participant_profile_id', 'scoring_policy_identity',
           'server_seq', 'stand_basis_points', 'stand_mode', 'wire_content_sha256',
           'wire_digest_version'
         ]::text[]
    and change_row->'payload'->>'client_revision' = '9007199254740993'
    and jsonb_typeof(change_row->'payload'->'client_revision') = 'string'
    and jsonb_typeof(change_row->'payload'->'server_seq') = 'string'
    and change_row->'payload'->>'wire_content_sha256' ~ '^[0-9a-f]{64}$'
    and not (change_row->'payload' ?| array[
      'raw_health_data', 'move_goal', 'exercise_goal', 'stand_goal', 'fingerprint'
    ])
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'typed-payloads'
    and change_row->>'kind' = 'score_revision_recorded'
), 'score payload has a closed privacy-safe contract with lossless bigint strings');

select ok((
  select (select array_agg(key order by key)
          from jsonb_object_keys(change_row->'payload') keys(key)) = array[
           'accepted_revisions', 'attestation_version', 'attested_at', 'basis',
           'participant_profile_id', 'server_seq', 'window_commitment_sha256'
         ]::text[]
    and change_row->'payload'->'accepted_revisions'
      = '["9007199254740993","2","3","4","5","6","7"]'::jsonb
    and change_row->'payload'->>'attestation_version' = '1'
    and jsonb_typeof(change_row->'payload'->'attestation_version') = 'string'
    and jsonb_typeof(change_row->'payload'->'server_seq') = 'string'
    and change_row->'payload'->>'window_commitment_sha256' = repeat('a5', 32)
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'typed-payloads'
    and change_row->>'kind' = 'participant_attested'
), 'attestation payload closes keys and losslessly string-encodes revisions');

select ok((
  select (select array_agg(key order by key)
          from jsonb_object_keys(change_row->'payload') keys(key)) = array[
           'completed_at', 'finalization_basis', 'frozen_window', 'immutable_hash',
           'outcome', 'participant_a_profile_id',
           'participant_a_total_centi_points', 'participant_b_profile_id',
           'participant_b_total_centi_points', 'server_seq', 'winner_profile_id'
         ]::text[]
    and change_row->'payload'->>'immutable_hash' = repeat('b6', 32)
    and jsonb_typeof(change_row->'payload'->'server_seq') = 'string'
    and jsonb_typeof(change_row->'payload'->'frozen_window') = 'object'
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'typed-payloads'
    and change_row->>'kind' = 'competition_result_confirmed'
), 'result payload has a closed canonical snapshot and digest contract');

select ok((
  select (select array_agg(key order by key)
          from jsonb_object_keys(change_row->'payload') keys(key))
      = array['award_type', 'earned_at', 'profile_id', 'server_seq']::text[]
    and change_row->'payload'->>'award_type' = 'seven_day_finisher'
    and jsonb_typeof(change_row->'payload'->'server_seq') = 'string'
  from change_feed_results result_row,
       lateral jsonb_array_elements(result_row.payload->'changes') change_row
  where result_row.name = 'typed-payloads'
    and change_row->>'kind' = 'competition_award_earned'
), 'award payload exposes only stable identity, type, time, and cursor');

update public.profiles
set state = 'deleting'
where auth_user_id = '81000000-0000-0000-0000-000000000001';

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"81000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.update_current_profile('Cannot Update')$$,
  '42501', 'active_profile_required', 'a deleting profile fails closed'
);
reset role;

select * from finish();
rollback;
