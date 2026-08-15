begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(24);

select has_function(
  'private', 'broadcast_competition_change', array[]::text[],
  'private competition wake-up trigger function exists'
);

select ok(coalesce((
  select function_row.prosecdef
    and 'search_path=""' = any(
      coalesce(function_row.proconfig, array[]::text[])
    )
  from pg_catalog.pg_proc function_row
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = function_row.pronamespace
  where schema_row.nspname = 'private'
    and function_row.proname = 'broadcast_competition_change'
    and function_row.proargtypes = ''::oidvector
), false), 'wake-up trigger is security definer with an empty search path');

select ok(coalesce((
  select not pg_catalog.has_function_privilege(
      'anon', function_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'authenticated', function_row.oid, 'EXECUTE'
    )
    and not pg_catalog.has_function_privilege(
      'service_role', function_row.oid, 'EXECUTE'
    )
    and not exists (
      select 1
      from pg_catalog.aclexplode(coalesce(
        function_row.proacl,
        pg_catalog.acldefault('f', function_row.proowner)
      )) acl_row
      where acl_row.grantee = 0
        and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_catalog.pg_proc function_row
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = function_row.pronamespace
  where schema_row.nspname = 'private'
    and function_row.proname = 'broadcast_competition_change'
    and function_row.proargtypes = ''::oidvector
), false), 'no API role can invoke the wake-up trigger directly');

select is((
  select count(*)::bigint
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname = 'realtime'
    and policy_row.tablename = 'messages'
    and policy_row.policyname = 'healthcomp_profile_broadcast_read'
    and policy_row.cmd = 'SELECT'
    and policy_row.roles = array['authenticated']::name[]
    and policy_row.with_check is null
), 1::bigint, 'authenticated users receive one read-only Realtime policy');

select ok(coalesce((
  select policy_row.qual like '%realtime.topic()%'
    and policy_row.qual like '%private.current_profile_id()%'
    and policy_row.qual like '%profile:%'
    and policy_row.qual like '%extension%broadcast%'
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname = 'realtime'
    and policy_row.tablename = 'messages'
    and policy_row.policyname = 'healthcomp_profile_broadcast_read'
), false), 'Realtime authorization binds a broadcast topic to the current profile');

select is((
  select count(*)::bigint
  from pg_catalog.pg_policies policy_row
  where policy_row.schemaname = 'realtime'
    and policy_row.tablename = 'messages'
), 1::bigint, 'Realtime exposes no send, presence, anonymous, or broad policy');

select ok(coalesce((
  select not trigger_row.tgisinternal
    and trigger_row.tgenabled = 'O'
    and (trigger_row.tgtype & 1) = 1
    and (trigger_row.tgtype & 2) = 0
    and (trigger_row.tgtype & 4) = 4
  from pg_catalog.pg_trigger trigger_row
  join pg_catalog.pg_class table_row
    on table_row.oid = trigger_row.tgrelid
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and table_row.relname = 'competition_change_log'
    and trigger_row.tgname = 'broadcast_competition_change'
), false), 'each committed change-log insert emits wake-ups after insertion');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    '95000000-0000-0000-0000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'realtime-alice@example.invalid', '', now(), now()
  ),
  (
    '95000000-0000-0000-0000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'realtime-bob@example.invalid', '', now(), now()
  ),
  (
    '95000000-0000-0000-0000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'realtime-mallory@example.invalid', '', now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    '96000000-0000-0000-0000-000000000001',
    '95000000-0000-0000-0000-000000000001', 'Realtime Alice', 'active'
  ),
  (
    '96000000-0000-0000-0000-000000000002',
    '95000000-0000-0000-0000-000000000002', 'Realtime Bob', 'active'
  ),
  (
    '96000000-0000-0000-0000-000000000003',
    '95000000-0000-0000-0000-000000000003', 'Realtime Mallory', 'active'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  '97000000-0000-0000-0000-000000000001',
  '96000000-0000-0000-0000-000000000001', 'UTC', current_date,
  'healthcomp.activity-score.v1', 'active',
  now() + interval '1 day', now() + interval '9 days'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values (
  '97000000-0000-0000-0000-000000000001',
  '96000000-0000-0000-0000-000000000001', 'creator', 'accepted'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values (
  '97000000-0000-0000-0000-000000000001',
  '96000000-0000-0000-0000-000000000002', 'invitee', 'accepted'
);

set constraints all immediate;

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic in (
      'profile:96000000-0000-0000-0000-000000000001',
      'profile:96000000-0000-0000-0000-000000000002',
      'profile:96000000-0000-0000-0000-000000000003'
    )
), 3::bigint, 'participant additions emit exactly one wake-up per eligible account');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000001'
), 2::bigint, 'the creator receives both participant-change wake-ups');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000002'
), 1::bigint, 'the invitee receives wake-ups only after joining');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000003'
), 0::bigint, 'a non-participant receives no competition wake-up');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
    and message_row.private
    and message_row.extension = 'broadcast'
), 3::bigint, 'every wake-up is a private broadcast with the fixed event name');

select ok(not exists (
  select 1
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
    and (
      select pg_catalog.array_agg(payload_key order by payload_key)
      from pg_catalog.jsonb_object_keys(message_row.payload) payload_key
    ) <> array['id', 'server_cursor_hint']::text[]
), 'wake-up payloads contain only an opaque message ID and cursor hint');

select is((
  select pg_catalog.array_agg(
    (message_row.payload->>'server_cursor_hint')::bigint
    order by (message_row.payload->>'server_cursor_hint')::bigint
  )
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000001'
), array[1, 2]::bigint[], 'creator hints mirror gap-free durable server cursors');

select is((
  select (message_row.payload->>'server_cursor_hint')::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000002'
), 2::bigint, 'invitee hint starts at the durable change that made it eligible');

grant usage on schema realtime to authenticated, anon;

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"95000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select pg_catalog.set_config(
  'realtime.topic',
  'profile:96000000-0000-0000-0000-000000000001',
  true
);
select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
), 3::bigint, 'an authenticated account can authorize its own private topic');

select pg_catalog.set_config(
  'realtime.topic',
  'profile:96000000-0000-0000-0000-000000000002',
  true
);
select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
), 0::bigint, 'one participant cannot authorize the other account topic');

select pg_catalog.set_config(
  'realtime.topic',
  'profile:95000000-0000-0000-0000-000000000001',
  true
);
select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
), 0::bigint, 'an auth-user UUID cannot substitute for the stable profile UUID');

select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"95000000-0000-0000-0000-000000000002","role":"authenticated"}',
  true
);
select pg_catalog.set_config(
  'realtime.topic',
  'profile:96000000-0000-0000-0000-000000000002',
  true
);
select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
), 3::bigint, 'the second account can authorize only its own topic');

set local role anon;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"anon"}', true
);
select pg_catalog.set_config(
  'realtime.topic',
  'profile:96000000-0000-0000-0000-000000000001',
  true
);
select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic like 'profile:96000000-0000-0000-0000-%'
), 0::bigint, 'anonymous clients cannot authorize a profile topic');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"95000000-0000-0000-0000-000000000001","role":"authenticated"}',
  true
);
select pg_catalog.set_config(
  'realtime.topic',
  'profile:96000000-0000-0000-0000-000000000001',
  true
);
select throws_ok(
  $$insert into realtime.messages (
      topic, extension, payload, event, private
    ) values (
      'profile:96000000-0000-0000-0000-000000000001',
      'broadcast', '{}'::jsonb, 'competition_changed', true
    )$$,
  '42501', null, 'authenticated clients cannot send competition broadcasts'
);

set local role postgres;
update public.profiles
set auth_user_id = null,
    display_name = 'Former competitor',
    state = 'anonymized',
    anonymized_at = now(),
    updated_at = now()
where id = '96000000-0000-0000-0000-000000000002';

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000001'
), 3::bigint, 'remaining active participant receives anonymization wake-up');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000002'
), 1::bigint, 'an anonymized account receives no later wake-up');

select is((
  select count(*)::bigint
  from realtime.messages message_row
  where message_row.event = 'competition_changed'
    and (message_row.payload->>'server_cursor_hint')::bigint = 3
    and message_row.topic = 'profile:96000000-0000-0000-0000-000000000001'
), 1::bigint, 'the anonymization wake-up carries only the next durable cursor');

select * from finish();
rollback;
