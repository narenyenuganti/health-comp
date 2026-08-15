begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(29);

select has_table(
  'private', 'competition_notification_mutes',
  'notification mutes are stored outside the exposed public schema'
);
select hasnt_table(
  'public', 'competition_notification_mutes',
  'notification mute storage has no public Data API table'
);
select has_index(
  'private', 'competition_notification_mutes',
  'competition_notification_mutes_opponent_profile_id_idx',
  'opponent profile deletion has a bounded reverse foreign-key lookup'
);
select has_function(
  'public', 'list_current_notification_mutes', array[]::text[],
  'authenticated mute-list RPC exists'
);
select has_function(
  'public', 'set_current_notification_mute', array['uuid', 'boolean'],
  'authenticated mute mutation RPC exists'
);

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
    and pg_catalog.has_function_privilege(
      'authenticated', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'service_role', procedure_row.oid, 'EXECUTE'
    )
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_catalog.pg_proc procedure_row
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'list_current_notification_mutes'
    and procedure_row.proargtypes = ''::oidvector
), false), 'mute-list RPC is a narrow definer function with a locked path');

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
    and pg_catalog.has_function_privilege(
      'authenticated', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'service_role', procedure_row.oid, 'EXECUTE'
    )
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        procedure_row.proacl,
        pg_catalog.acldefault('f', procedure_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_catalog.pg_proc procedure_row
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'set_current_notification_mute'
    and procedure_row.proargtypes = '2950 16'::oidvector
), false), 'mute mutation RPC is a narrow definer function with a locked path');

select is(
  pg_catalog.has_table_privilege(
    'authenticated', 'private.competition_notification_mutes', 'SELECT'
  ),
  false,
  'authenticated clients cannot read mute storage directly'
);
select is(
  pg_catalog.has_table_privilege(
    'service_role', 'private.competition_notification_mutes', 'SELECT'
  ),
  false,
  'service role uses no broad direct mute-table grant'
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    'a1000000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'mute-alice@example.invalid', '', now(), now()
  ),
  (
    'a1000000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'mute-bob@example.invalid', '', now(), now()
  ),
  (
    'a1000000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'mute-mallory@example.invalid', '', now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    'a2000000-0000-4000-8000-000000000001',
    'a1000000-0000-4000-8000-000000000001', 'Mute Alice', 'active'
  ),
  (
    'a2000000-0000-4000-8000-000000000002',
    'a1000000-0000-4000-8000-000000000002', 'Mute Bob', 'active'
  ),
  (
    'a2000000-0000-4000-8000-000000000003',
    'a1000000-0000-4000-8000-000000000003', 'Mute Mallory', 'active'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  'a3000000-0000-4000-8000-000000000001',
  'a2000000-0000-4000-8000-000000000001', 'UTC', current_date,
  'healthcomp.activity-score.v1', 'active',
  now() + interval '1 day', now() + interval '9 days'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    'a3000000-0000-4000-8000-000000000001',
    'a2000000-0000-4000-8000-000000000001', 'creator', 'accepted'
  ),
  (
    'a3000000-0000-4000-8000-000000000001',
    'a2000000-0000-4000-8000-000000000002', 'invitee', 'accepted'
  );
set constraints all immediate;

create temporary table notification_mute_results (
  name text primary key,
  payload jsonb not null
);
grant select, insert, update on notification_mute_results to authenticated;

set local role anon;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"anon"}', true
);
select throws_ok(
  $$select public.list_current_notification_mutes()$$,
  '42501', null, 'anonymous mute reads are denied'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', true
  )$$,
  '42501', null, 'anonymous mute writes are denied'
);
reset role;

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.list_current_notification_mutes(),
  pg_catalog.jsonb_build_object(
    'opponent_profile_ids', pg_catalog.jsonb_build_array()
  ),
  'an account starts with an explicit empty mute set'
);
select throws_ok(
  $$select public.set_current_notification_mute(null, true)$$,
  'P0001', 'opponent_unavailable',
  'missing opponent identity is privacy-collapsed'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000001', true
  )$$,
  'P0001', 'opponent_unavailable',
  'self mute is privacy-collapsed'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000003', true
  )$$,
  'P0001', 'opponent_unavailable',
  'an unrelated active profile is privacy-collapsed'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000099', true
  )$$,
  'P0001', 'opponent_unavailable',
  'an unknown profile is indistinguishable from an unrelated profile'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', null
  )$$,
  '22023', 'invalid_notification_mute',
  'a null mute disposition is rejected'
);
select lives_ok(
  $$insert into notification_mute_results (name, payload)
    select 'muted', public.set_current_notification_mute(
      'a2000000-0000-4000-8000-000000000002', true
    )$$,
  'an accepted participant can mute their stable opponent identity'
);
reset role;

select is((
  select payload from notification_mute_results where name = 'muted'
), pg_catalog.jsonb_build_object(
  'opponent_profile_id', 'a2000000-0000-4000-8000-000000000002'::uuid,
  'is_muted', true
), 'mute mutation returns only stable identity and disposition');
select is((
  select count(*)::bigint
  from private.competition_notification_mutes mute_row
  where mute_row.profile_id = 'a2000000-0000-4000-8000-000000000001'
    and mute_row.opponent_profile_id
      = 'a2000000-0000-4000-8000-000000000002'
), 1::bigint, 'the account stores exactly one stable opponent mute');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.list_current_notification_mutes(),
  pg_catalog.jsonb_build_object(
    'opponent_profile_ids', pg_catalog.jsonb_build_array(
      'a2000000-0000-4000-8000-000000000002'
    )
  ),
  'mute reads return only the caller account stable opponent identities'
);
select lives_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', true
  )$$,
  'an exact mute retry is idempotent'
);
reset role;

update public.profiles
set display_name = 'Renamed Bob'
where id = 'a2000000-0000-4000-8000-000000000002';

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.list_current_notification_mutes(),
  pg_catalog.jsonb_build_object(
    'opponent_profile_ids', pg_catalog.jsonb_build_array(
      'a2000000-0000-4000-8000-000000000002'
    )
  ),
  'display-name changes do not alter account mute identity'
);
reset role;

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
select is(
  public.list_current_notification_mutes(),
  pg_catalog.jsonb_build_object(
    'opponent_profile_ids', pg_catalog.jsonb_build_array()
  ),
  'the opponent account does not inherit the caller mute'
);
reset role;

update public.profiles
set state = 'deleting'
where id = 'a2000000-0000-4000-8000-000000000002';

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', false
  ),
  pg_catalog.jsonb_build_object(
    'opponent_profile_id', 'a2000000-0000-4000-8000-000000000002'::uuid,
    'is_muted', false
  ),
  'unmute remains possible after the opponent becomes unavailable'
);
select lives_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', false
  )$$,
  'an exact unmute retry is idempotent'
);
select is(
  public.list_current_notification_mutes(),
  pg_catalog.jsonb_build_object(
    'opponent_profile_ids', pg_catalog.jsonb_build_array()
  ),
  'unmute removes the opponent from the account mute set'
);
reset role;

update public.profiles
set state = 'active'
where id = 'a2000000-0000-4000-8000-000000000002';

update public.profiles
set state = 'deleting'
where id = 'a2000000-0000-4000-8000-000000000001';

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"a1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.list_current_notification_mutes()$$,
  '42501', 'active_profile_required',
  'a non-active profile cannot read account mutes'
);
select throws_ok(
  $$select public.set_current_notification_mute(
    'a2000000-0000-4000-8000-000000000002', true
  )$$,
  '42501', 'active_profile_required',
  'a non-active profile cannot write account mutes'
);
reset role;

select * from finish();
rollback;
