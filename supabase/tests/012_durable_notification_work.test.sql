begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(52);

select has_table(
  'private', 'competition_notification_work',
  'notification delivery work is durable outside the exposed schema'
);
select hasnt_table(
  'public', 'competition_notification_work',
  'notification work has no public Data API table'
);
select has_function(
  'public', 'lease_competition_notification_work',
  array['integer', 'integer'],
  'the service worker can lease a bounded notification batch'
);
select has_function(
  'public', 'resolve_competition_notification_work',
  array['uuid', 'uuid', 'text', 'integer'],
  'the service worker can resolve a leased notification'
);
select has_trigger(
  'public', 'daily_score_revisions',
  'enqueue_competition_notification_work_from_score',
  'accepted score inserts enqueue notification work transactionally'
);
select has_trigger(
  'public', 'competition_results',
  'enqueue_competition_notification_work_from_result',
  'confirmed result inserts enqueue notification work transactionally'
);
select has_function(
  'private', 'request_competition_notification_worker', array[]::text[],
  'a private fail-open hook can request an immediate worker drain'
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
    and procedure_row.proname = 'request_competition_notification_worker'
    and procedure_row.proargtypes = ''::oidvector
), false), 'the immediate-drain hook is a locked non-API definer function');

select lives_ok(
  $$select private.request_competition_notification_worker()$$,
  'missing worker secrets fail open so durable source transactions can commit'
);

select is(
  pg_catalog.has_table_privilege(
    'authenticated', 'private.competition_notification_work', 'SELECT'
  ),
  false,
  'authenticated clients cannot read notification work directly'
);
select is(
  pg_catalog.has_table_privilege(
    'service_role', 'private.competition_notification_work', 'SELECT'
  ),
  false,
  'the service role uses narrow RPCs instead of a broad table grant'
);

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(
      coalesce(procedure_row.proconfig, array[]::text[])
    )
    and pg_catalog.has_function_privilege(
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
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'lease_competition_notification_work'
    and procedure_row.proargtypes = '23 23'::oidvector
), false), 'lease RPC is service-only with a locked search path');

select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(
      coalesce(procedure_row.proconfig, array[]::text[])
    )
    and pg_catalog.has_function_privilege(
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
  where schema_row.nspname = 'public'
    and procedure_row.proname = 'resolve_competition_notification_work'
    and procedure_row.proargtypes = '2950 2950 25 23'::oidvector
), false), 'resolution RPC is service-only with a locked search path');

select is((
  select pg_catalog.array_agg(
    column_row.column_name::text order by column_row.column_name
  )
  from information_schema.columns column_row
  where column_row.table_schema = 'private'
    and column_row.table_name = 'competition_notification_work'
), array[
  'attempt_count', 'available_at', 'competition_id', 'completed_at',
  'created_at', 'id', 'installation_id', 'kind', 'lease_expires_at',
  'lease_token', 'leased_apns_token_sha256', 'recipient_profile_id',
  'semantic_id', 'server_seq', 'source_profile_id', 'state', 'updated_at'
]::text[], 'work rows store routing metadata and token hashes, never APNs tokens or health values');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    'b1000000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'notify-alice@example.invalid', '', now(), now()
  ),
  (
    'b1000000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'notify-bob@example.invalid', '', now(), now()
  ),
  (
    'b1000000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'notify-mallory@example.invalid', '', now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    'b2000000-0000-4000-8000-000000000001',
    'b1000000-0000-4000-8000-000000000001', 'Notify Alice', 'active'
  ),
  (
    'b2000000-0000-4000-8000-000000000002',
    'b1000000-0000-4000-8000-000000000002', 'Notify Bob', 'active'
  ),
  (
    'b2000000-0000-4000-8000-000000000003',
    'b1000000-0000-4000-8000-000000000003', 'Notify Mallory', 'active'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  'b3000000-0000-4000-8000-000000000001',
  'b2000000-0000-4000-8000-000000000001', 'UTC', current_date,
  'healthcomp.activity-score.v1', 'active',
  now() + interval '1 day', now() + interval '9 days'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    'b3000000-0000-4000-8000-000000000001',
    'b2000000-0000-4000-8000-000000000001', 'creator', 'accepted'
  ),
  (
    'b3000000-0000-4000-8000-000000000001',
    'b2000000-0000-4000-8000-000000000002', 'invitee', 'accepted'
  );
set constraints all immediate;

insert into public.device_installations (
  id, profile_id, installation_id, apns_token, environment, state
) values
  (
    'b4000000-0000-4000-8000-000000000001',
    'b2000000-0000-4000-8000-000000000001',
    'b5000000-0000-4000-8000-000000000001',
    repeat('aa', 32), 'sandbox', 'active'
  ),
  (
    'b4000000-0000-4000-8000-000000000002',
    'b2000000-0000-4000-8000-000000000002',
    'b5000000-0000-4000-8000-000000000002',
    repeat('bb', 32), 'sandbox', 'active'
  ),
  (
    'b4000000-0000-4000-8000-000000000003',
    'b2000000-0000-4000-8000-000000000003',
    'b5000000-0000-4000-8000-000000000003',
    repeat('cc', 32), 'sandbox', 'active'
  );

delete from vault.secrets
where name in (
  'healthcomp_notification_worker_url',
  'healthcomp_notification_worker_token'
);
select vault.create_secret(
  'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/send-competition-notification',
  'healthcomp_notification_worker_url'
);
select vault.create_secret(
  repeat('w', 43),
  'healthcomp_notification_worker_token'
);

create temporary table notification_score_digests (
  revision bigint primary key,
  digest text not null
);
insert into notification_score_digests (revision, digest)
select revision,
       pg_catalog.encode(
         private.wire_score_digest_v1(
           'b3000000-0000-4000-8000-000000000001',
           'b2000000-0000-4000-8000-000000000001',
           1::smallint, 'activeEnergyKilocalories', 'standHours',
           900 + (revision::integer * 100), 1000, 1000,
           2900 + (revision::integer * 100), 'available',
           'healthcomp.activity-score.v1', revision
         ),
         'hex'
       )
from pg_catalog.generate_series(1, 5) revisions(revision);
grant select on notification_score_digests to authenticated;

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000001', 1, 1,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1000, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 1)
  )$$,
  'an accepted score transaction durably enqueues notification work'
);
reset role;

select is((
  select count(*)::bigint
  from private.competition_notification_work
), 1::bigint, 'one active opponent installation receives one durable work row');
select is((
  select pg_catalog.array_agg(recipient_profile_id order by recipient_profile_id)
  from private.competition_notification_work
), array['b2000000-0000-4000-8000-000000000002'::uuid],
'the scorer and non-participants receive no score notification work');
select is((
  select count(*)::bigint
  from net.http_request_queue request_row
), 1::bigint, 'the committed work requests one asynchronous immediate drain');
select ok(coalesce((
  select request_row.method = 'POST'
    and request_row.url
      = 'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/send-competition-notification'
    and request_row.headers->>'Authorization'
      = 'Bearer ' || repeat('w', 43)
    and request_row.headers->>'Content-Type' = 'application/json'
    and pg_catalog.convert_from(request_row.body, 'UTF8')::jsonb
      = '{"batchSize":25}'::jsonb
    and request_row.timeout_milliseconds = 5000
  from net.http_request_queue request_row
  order by request_row.id
  limit 1
), false), 'the immediate request contains only bounded worker configuration');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000002', 1, 2,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1100, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 2)
  )$$,
  'a newer accepted score enqueues a new semantic decision'
);
reset role;

select is((
  select pg_catalog.array_agg(state order by server_seq)
  from private.competition_notification_work
), array['superseded', 'pending']::text[],
'newer score work supersedes an obsolete pending score request');

insert into private.competition_notification_mutes (
  profile_id, opponent_profile_id
) values (
  'b2000000-0000-4000-8000-000000000002',
  'b2000000-0000-4000-8000-000000000001'
);

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000003', 1, 3,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1200, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 3)
  )$$,
  'a muted score event records a durable suppression instead of a send'
);
reset role;

select is((
  select pg_catalog.array_agg(state order by server_seq)
  from private.competition_notification_work
), array['superseded', 'superseded', 'suppressed']::text[],
'mute state suppresses the newest decision and retires older work');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000003', 1, 3,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1200, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 3)
  )$$,
  'an exact score retry is still idempotent'
);
reset role;

select is((
  select count(*)::bigint from private.competition_notification_work
), 3::bigint, 'an idempotent score retry creates no duplicate work');
select is((
  select count(*)::bigint from net.http_request_queue
), 3::bigint, 'an idempotent retry creates no duplicate worker invocation');

delete from private.competition_notification_mutes
where profile_id = 'b2000000-0000-4000-8000-000000000002'
  and opponent_profile_id = 'b2000000-0000-4000-8000-000000000001';

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000004', 1, 4,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1300, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 4)
  )$$,
  'unmuting permits a future score notification decision'
);
reset role;

select is((
  select count(*)::bigint
  from private.competition_notification_work
  where state = 'pending'
), 1::bigint, 'exactly one current score request remains pending');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$select public.lease_competition_notification_work(10, 60)$$,
  '42501', null,
  'a normal authenticated account cannot lease notification work'
);
reset role;

create temporary table notification_worker_results (
  name text primary key,
  payload jsonb not null
);
grant select, insert, update on notification_worker_results to service_role;

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select lives_ok(
  $$insert into notification_worker_results (name, payload)
    select 'first', public.lease_competition_notification_work(10, 60)$$,
  'the service worker leases the current work item'
);
reset role;

select is((
  select pg_catalog.jsonb_array_length(payload->'items')
  from notification_worker_results where name = 'first'
), 1, 'the lease returns exactly one sendable item');
select is((
  select pg_catalog.array_agg(key order by key)
  from notification_worker_results result_row,
       lateral pg_catalog.jsonb_object_keys(
         result_row.payload->'items'->0
       ) keys(key)
  where result_row.name = 'first'
), array[
  'apnsToken', 'competitionId', 'environment', 'kind',
  'leaseToken', 'semanticId', 'workId'
]::text[], 'the worker projection is exact and omits profile identity');
select is((
  select pg_catalog.jsonb_build_object(
    'apnsToken', payload#>>'{items,0,apnsToken}',
    'competitionId', payload#>>'{items,0,competitionId}',
    'environment', payload#>>'{items,0,environment}',
    'kind', payload#>>'{items,0,kind}'
  )
  from notification_worker_results where name = 'first'
), pg_catalog.jsonb_build_object(
  'apnsToken', repeat('bb', 32),
  'competitionId', 'b3000000-0000-4000-8000-000000000001',
  'environment', 'sandbox',
  'kind', 'score_update'
), 'the worker receives only the current token and generic route metadata');
select ok(coalesce((
  select work_row.state = 'leased'
    and work_row.attempt_count = 1
    and work_row.leased_apns_token_sha256
      = extensions.digest(repeat('bb', 32), 'sha256')
  from private.competition_notification_work work_row
  join notification_worker_results result_row
    on work_row.id = (result_row.payload#>>'{items,0,workId}')::uuid
  where result_row.name = 'first'
), false), 'leasing records an attempt and only a token digest');

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select is((
  select public.resolve_competition_notification_work(
    (payload#>>'{items,0,workId}')::uuid,
    (payload#>>'{items,0,leaseToken}')::uuid,
    'retry', 1
  )
  from notification_worker_results where name = 'first'
), true, 'a matching lease can schedule a bounded retry');
reset role;

select ok(coalesce((
  select work_row.state = 'pending'
    and work_row.available_at > work_row.updated_at
    and work_row.lease_token is null
    and work_row.leased_apns_token_sha256 is null
  from private.competition_notification_work work_row
  join notification_worker_results result_row
    on work_row.id = (result_row.payload#>>'{items,0,workId}')::uuid
  where result_row.name = 'first'
), false), 'retry clears lease material and returns work to a delayed pending state');

update private.competition_notification_work
set available_at = pg_catalog.statement_timestamp() - interval '1 second'
where state = 'pending';

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select lives_ok(
  $$insert into notification_worker_results (name, payload)
    select 'second', public.lease_competition_notification_work(10, 60)$$,
  'the scheduled sweep can re-lease retryable work'
);
reset role;

select isnt((
  select first_row.payload#>>'{items,0,leaseToken}'
  from notification_worker_results first_row
  where first_row.name = 'first'
), (
  select second_row.payload#>>'{items,0,leaseToken}'
  from notification_worker_results second_row
  where second_row.name = 'second'
), 'a re-lease receives a fresh compare-and-set token');

update public.device_installations
set apns_token = repeat('dd', 32),
    updated_at = pg_catalog.statement_timestamp()
where profile_id = 'b2000000-0000-4000-8000-000000000002'
  and installation_id = 'b5000000-0000-4000-8000-000000000002';

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select is((
  select public.resolve_competition_notification_work(
    (payload#>>'{items,0,workId}')::uuid,
    (payload#>>'{items,0,leaseToken}')::uuid,
    'invalid_token', null
  )
  from notification_worker_results where name = 'second'
), true, 'an invalid-token outcome resolves the exact leased work');
reset role;

select ok(coalesce((
  select installation_row.state = 'active'
    and installation_row.apns_token = repeat('dd', 32)
  from public.device_installations installation_row
  where installation_row.profile_id
    = 'b2000000-0000-4000-8000-000000000002'
    and installation_row.installation_id
      = 'b5000000-0000-4000-8000-000000000002'
), false), 'an old-token response cannot revoke a rotated current token');

set local role authenticated;
select pg_catalog.set_config(
  'request.jwt.claims',
  '{"sub":"b1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$select public.submit_score_revision(
    'b3000000-0000-4000-8000-000000000001',
    'b6000000-0000-4000-8000-000000000005', 1, 5,
    (current_date::timestamp + interval '12 hours') at time zone 'UTC',
    'activeEnergyKilocalories', 'standHours', 1400, 1000, 1000,
    'available', 'healthcomp.activity-score.v1',
    (select digest from notification_score_digests where revision = 5)
  )$$,
  'a later score uses the rotated active installation token'
);
reset role;

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select lives_ok(
  $$insert into notification_worker_results (name, payload)
    select 'third', public.lease_competition_notification_work(10, 60)$$,
  'the rotated-token work can be leased'
);
select is((
  select public.resolve_competition_notification_work(
    (payload#>>'{items,0,workId}')::uuid,
    (payload#>>'{items,0,leaseToken}')::uuid,
    'invalid_token', null
  )
  from notification_worker_results where name = 'third'
), true, 'the current invalid token is durably resolved');
reset role;

select is((
  select state
  from public.device_installations
  where profile_id = 'b2000000-0000-4000-8000-000000000002'
    and installation_id = 'b5000000-0000-4000-8000-000000000002'
), 'revoked', 'a matching invalid-token outcome revokes that installation');

update public.device_installations
set apns_token = repeat('ee', 32), state = 'active',
    updated_at = pg_catalog.statement_timestamp()
where profile_id = 'b2000000-0000-4000-8000-000000000002'
  and installation_id = 'b5000000-0000-4000-8000-000000000002';

select lives_ok($result$
  do $$
  declare
    revisions_a bigint[];
    revisions_b bigint[];
    commitment_a bytea;
    commitment_b bytea;
    projection_a jsonb;
    projection_b jsonb;
    frozen_projection jsonb;
    result_hash bytea;
  begin
    revisions_a := private.latest_revision_vector(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000001'
    );
    revisions_b := private.latest_revision_vector(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000002'
    );
    commitment_a := private.owner_window_commitment_v1(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000001', revisions_a
    );
    commitment_b := private.owner_window_commitment_v1(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000002', revisions_b
    );
    projection_a := private.participant_projection_v2(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000001',
      revisions_a, commitment_a
    );
    projection_b := private.participant_projection_v2(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000002',
      revisions_b, commitment_b
    );
    frozen_projection := pg_catalog.jsonb_build_object(
      'version', 2,
      'policy', 'healthcomp.activity-score.v1',
      'participants', pg_catalog.jsonb_build_array(
        projection_a, projection_b
      )
    );
    result_hash := private.result_immutable_hash_v1(
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000001', 3400, commitment_a,
      'b2000000-0000-4000-8000-000000000002', 0, commitment_b,
      'winner', 'b2000000-0000-4000-8000-000000000001',
      'best_available'
    );
    insert into public.competition_results (
      competition_id, participant_a_profile_id, participant_b_profile_id,
      participant_a_total_centi_points, participant_b_total_centi_points,
      winner_profile_id, outcome, finalization_basis, completed_at,
      frozen_window, immutable_hash, server_seq
    ) values (
      'b3000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000001',
      'b2000000-0000-4000-8000-000000000002',
      3400, 0, 'b2000000-0000-4000-8000-000000000001',
      'winner', 'best_available', pg_catalog.statement_timestamp(),
      frozen_projection, result_hash, 1
    );
  end;
  $$
$result$, 'a confirmed result transaction enqueues both participants');

select is((
  select count(*)::bigint
  from private.competition_notification_work
  where kind = 'result' and state = 'pending'
), 2::bigint, 'each active participant installation gets result work');
select is((
  select count(*)::bigint
  from private.competition_notification_work
  where recipient_profile_id = 'b2000000-0000-4000-8000-000000000003'
), 0::bigint, 'result work never reaches a non-participant installation');

update public.device_installations
set state = 'revoked', updated_at = pg_catalog.statement_timestamp()
where profile_id = 'b2000000-0000-4000-8000-000000000001'
  and installation_id = 'b5000000-0000-4000-8000-000000000001';
insert into private.competition_notification_mutes (
  profile_id, opponent_profile_id
) values (
  'b2000000-0000-4000-8000-000000000002',
  'b2000000-0000-4000-8000-000000000001'
);

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select lives_ok(
  $$insert into notification_worker_results (name, payload)
    select 'sweep', public.lease_competition_notification_work(10, 60)$$,
  'a scheduled lease sweep repairs obsolete and newly muted work'
);
reset role;

select is((
  select pg_catalog.jsonb_array_length(payload->'items')
  from notification_worker_results where name = 'sweep'
), 0, 'obsolete or muted work is never projected to the APNs worker');
select is((
  select pg_catalog.array_agg(state order by recipient_profile_id)
  from private.competition_notification_work
  where kind = 'result'
), array['discarded', 'suppressed']::text[],
'the sweep durably records revoked-installation and mute decisions');

update private.competition_notification_work
set state = 'pending', attempt_count = 0,
    available_at = pg_catalog.statement_timestamp(),
    lease_token = null, lease_expires_at = null,
    leased_apns_token_sha256 = null,
    updated_at = pg_catalog.statement_timestamp(),
    completed_at = null;
update public.device_installations
set state = 'revoked', updated_at = pg_catalog.statement_timestamp();

set local role service_role;
select pg_catalog.set_config(
  'request.jwt.claims', '{"role":"service_role"}', true
);
select public.lease_competition_notification_work(1, 60);
reset role;

select is((
  select count(*)::bigint
  from private.competition_notification_work
  where state = 'discarded'
), 4::bigint, 'one small lease bounds housekeeping to four locked rows');
select is((
  select count(*)::bigint
  from private.competition_notification_work
  where state = 'pending'
), 3::bigint, 'bounded housekeeping leaves later work for a future sweep');

select * from finish();
rollback;
