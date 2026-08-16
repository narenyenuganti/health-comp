begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(11);

select has_function(
  'private',
  'finalize_due_competitions_batch',
  array['integer', 'timestamp with time zone'],
  'the shared due-finalization batch is private'
);
select has_function(
  'private',
  'run_due_competition_finalizer',
  array[]::text[],
  'hosted cron has a private finalizer entry point'
);
select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(
      coalesce(procedure_row.proconfig, array[]::text[])
    )
    and not pg_catalog.has_function_privilege(
      'service_role', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'authenticated', procedure_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', procedure_row.oid, 'EXECUTE'
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
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'run_due_competition_finalizer'
    and procedure_row.proargtypes = ''::oidvector
), false), 'the hosted finalizer is a locked non-API definer function');
select ok(
  pg_catalog.has_function_privilege(
    'service_role', 'public.finalize_due_competitions(integer)', 'EXECUTE'
  )
    and not pg_catalog.has_function_privilege(
      'authenticated', 'public.finalize_due_competitions(integer)', 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'anon', 'public.finalize_due_competitions(integer)', 'EXECUTE'
    ),
  'the public batch RPC remains service-role-only'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"86000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.finalize_due_competitions(100)$$,
  '42501',
  'service_role_required',
  'authenticated callers cannot use the public finalizer'
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    '86000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'hosted-finalizer-a@example.invalid',
    '',
    now(),
    now()
  ),
  (
    '86000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated',
    'authenticated',
    'hosted-finalizer-b@example.invalid',
    '',
    now(),
    now()
  );
insert into public.profiles (
  id, auth_user_id, display_name, state
) values
  (
    '87000000-0000-0000-0000-000000000001',
    '86000000-0000-0000-0000-000000000001',
    'Finalizer A',
    'active'
  ),
  (
    '87000000-0000-0000-0000-000000000002',
    '86000000-0000-0000-0000-000000000002',
    'Finalizer B',
    'active'
  );
insert into public.competitions (
  id,
  creator_profile_id,
  time_zone_identifier,
  start_day,
  scoring_policy_identity,
  lifecycle,
  invitation_expires_at,
  best_available_deadline
) values (
  '88000000-0000-0000-0000-000000000001',
  '87000000-0000-0000-0000-000000000001',
  'UTC',
  '2026-07-20',
  'healthcomp.activity-score.v1',
  'tallying',
  '2026-07-19T00:00:00Z',
  '2026-08-01T00:00:00Z'
);
insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    '88000000-0000-0000-0000-000000000001',
    '87000000-0000-0000-0000-000000000001',
    'creator',
    'accepted'
  ),
  (
    '88000000-0000-0000-0000-000000000001',
    '87000000-0000-0000-0000-000000000002',
    'invitee',
    'accepted'
  );

create temporary table hosted_finalizer_results (
  finalized_count bigint not null
);
select lives_ok(
  $$
    insert into hosted_finalizer_results (finalized_count)
    select private.run_due_competition_finalizer()
  $$,
  'postgres-owned hosted cron can run the private finalizer'
);
select is(
  (select finalized_count from hosted_finalizer_results),
  1::bigint,
  'the hosted finalizer reports one completed competition'
);
select is(
  (
    select count(*)::integer
    from public.competition_results
    where competition_id = '88000000-0000-0000-0000-000000000001'
  ),
  1,
  'the hosted finalizer persists exactly one immutable result'
);
select is(
  (
    select lifecycle
    from public.competitions
    where id = '88000000-0000-0000-0000-000000000001'
  ),
  'completed',
  'the hosted finalizer completes the competition lifecycle'
);
select is(
  (
    select finalization_basis
    from public.competition_results
    where competition_id = '88000000-0000-0000-0000-000000000001'
  ),
  'best_available',
  'the hosted finalizer preserves deadline finalization semantics'
);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is(
  public.finalize_due_competitions(100),
  0::bigint,
  'the public service-role batch converges after hosted finalization'
);

select * from finish();
rollback;
