begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(18);

select has_function(
  'public', 'archive_competition', array['uuid'],
  'authenticated archive RPC exists'
);

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'archive_competition'
    and procedure_row.proargtypes = '2950'::oidvector
), false), 'archive RPC is security definer with an empty search path');

select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
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
    and procedure_row.proname = 'archive_competition'
    and procedure_row.proargtypes = '2950'::oidvector
), false), 'only authenticated API users may execute archive');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    '91000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'archive-alice@example.invalid', '', now(), now()
  ),
  (
    '91000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'archive-bob@example.invalid', '', now(), now()
  ),
  (
    '91000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'archive-mallory@example.invalid', '', now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    '92000000-0000-0000-0000-000000000001',
    '91000000-0000-0000-0000-000000000001', 'Archive Alice', 'active'
  ),
  (
    '92000000-0000-0000-0000-000000000002',
    '91000000-0000-0000-0000-000000000002', 'Archive Bob', 'active'
  ),
  (
    '92000000-0000-0000-0000-000000000003',
    '91000000-0000-0000-0000-000000000003', 'Archive Mallory', 'active'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values
  (
    '93000000-0000-0000-0000-000000000001',
    '92000000-0000-0000-0000-000000000001', 'UTC', '2026-08-01',
    'healthcomp.activity-score.v1', 'completed',
    '2026-07-31T00:00:00Z', '2026-08-09T00:00:00Z'
  ),
  (
    '93000000-0000-0000-0000-000000000002',
    '92000000-0000-0000-0000-000000000001', 'UTC', '2026-08-10',
    'healthcomp.activity-score.v1', 'scheduled',
    '2026-08-09T00:00:00Z', '2026-08-18T00:00:00Z'
  );

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    '93000000-0000-0000-0000-000000000001',
    '92000000-0000-0000-0000-000000000001', 'creator', 'accepted'
  ),
  (
    '93000000-0000-0000-0000-000000000001',
    '92000000-0000-0000-0000-000000000002', 'invitee', 'accepted'
  ),
  (
    '93000000-0000-0000-0000-000000000002',
    '92000000-0000-0000-0000-000000000001', 'creator', 'accepted'
  ),
  (
    '93000000-0000-0000-0000-000000000002',
    '92000000-0000-0000-0000-000000000002', 'invitee', 'accepted'
  );
set constraints all immediate;

insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values (
  '93000000-0000-0000-0000-000000000001',
  '92000000-0000-0000-0000-000000000001',
  '92000000-0000-0000-0000-000000000002',
  0, 0, null, 'tie', 'best_available', '2026-08-09T00:00:00Z',
  pg_catalog.jsonb_build_object(
    'version', 1,
    'participants', pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'profile_id', '92000000-0000-0000-0000-000000000001',
        'days', (
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing'
          ) order by ordinal)
          from pg_catalog.generate_series(1, 7) ordinal
        )
      ),
      pg_catalog.jsonb_build_object(
        'profile_id', '92000000-0000-0000-0000-000000000002',
        'days', (
          select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
            'ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing'
          ) order by ordinal)
          from pg_catalog.generate_series(1, 7) ordinal
        )
      )
    )
  ),
  pg_catalog.decode(repeat('b7', 32), 'hex'), 1
);

create temporary table archive_test_context (
  name text primary key,
  value_text text not null
);
grant select, insert, update on archive_test_context to authenticated;

insert into archive_test_context (name, value_text) values
  (
    'result_hash',
    (
      select pg_catalog.encode(result_row.immutable_hash, 'hex')
      from public.competition_results result_row
      where result_row.competition_id = '93000000-0000-0000-0000-000000000001'
    )
  ),
  (
    'pre_archive_max_seq',
    (
      select coalesce(max(change_row.server_seq), 0)::text
      from public.competition_change_log change_row
      where change_row.competition_id = '93000000-0000-0000-0000-000000000001'
    )
  );

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$select public.archive_competition('93000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'anonymous archive is denied'
);
reset role;

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-0000-0000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.archive_competition('93000000-0000-0000-0000-000000000001')$$,
  '42501', 'archive_not_allowed', 'non-participant cannot archive history'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.archive_competition(null)$$,
  '22023', 'invalid_competition_id', 'null competition identity is rejected'
);
select throws_ok(
  $$select public.archive_competition('93000000-0000-0000-0000-000000000002')$$,
  '42501', 'archive_not_allowed', 'non-completed competition cannot be archived'
);

select is(
  public.archive_competition('93000000-0000-0000-0000-000000000001')->>'competition_id',
  '93000000-0000-0000-0000-000000000001',
  'accepted participant archives completed competition'
);
reset role;

select is(
  (
    select competition_row.lifecycle
    from public.competitions competition_row
    where competition_row.id = '93000000-0000-0000-0000-000000000001'
  ),
  'archived', 'archive transition is canonical server state'
);
select is(
  (
    select count(*)::integer
    from public.competition_change_log change_row
    where change_row.competition_id = '93000000-0000-0000-0000-000000000001'
      and change_row.change_kind = 'competition_lifecycle_changed'
      and change_row.payload_snapshot->>'lifecycle' = 'archived'
  ),
  1, 'archive emits exactly one lifecycle change'
);
select is(
  (
    select max(change_row.server_seq)
    from public.competition_change_log change_row
    where change_row.competition_id = '93000000-0000-0000-0000-000000000001'
  ),
  (
    select value_text::bigint + 1
    from archive_test_context
    where name = 'pre_archive_max_seq'
  ),
  'archive allocates the next gap-free server sequence'
);
select is(
  (
    select pg_catalog.encode(result_row.immutable_hash, 'hex')
    from public.competition_results result_row
    where result_row.competition_id = '93000000-0000-0000-0000-000000000001'
  ),
  (
    select value_text from archive_test_context where name = 'result_hash'
  ),
  'archive preserves the immutable result'
);
select is(
  (
    select count(*)::integer
    from public.competition_results result_row
    where result_row.competition_id = '93000000-0000-0000-0000-000000000001'
  ),
  1, 'archive preserves exactly one result row'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.archive_competition('93000000-0000-0000-0000-000000000001')->>'competition_id',
  '93000000-0000-0000-0000-000000000001',
  'same participant retry is idempotent'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.competition_change_log change_row
    where change_row.competition_id = '93000000-0000-0000-0000-000000000001'
      and change_row.change_kind = 'competition_lifecycle_changed'
      and change_row.payload_snapshot->>'lifecycle' = 'archived'
  ),
  1, 'same participant retry emits no duplicate change'
);

set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select is(
  public.archive_competition('93000000-0000-0000-0000-000000000001')->>'competition_id',
  '93000000-0000-0000-0000-000000000001',
  'other accepted participant converges on archived state'
);
reset role;

select is(
  (
    select count(*)::integer
    from public.competition_change_log change_row
    where change_row.competition_id = '93000000-0000-0000-0000-000000000001'
      and change_row.change_kind = 'competition_lifecycle_changed'
      and change_row.payload_snapshot->>'lifecycle' = 'archived'
  ),
  1, 'other participant retry emits no duplicate change'
);

update public.profiles
set state = 'deleting'
where id = '92000000-0000-0000-0000-000000000002';
set local role authenticated;
select set_config(
  'request.jwt.claims',
  '{"sub":"91000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.archive_competition('93000000-0000-0000-0000-000000000001')$$,
  '42501', 'active_profile_required', 'non-active profile cannot archive'
);

reset role;
select * from finish();
rollback;
