begin;

set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(80);

select has_table(
  'private', 'app_attest_challenges',
  'App Attest challenges remain outside the exposed schema'
);
select has_table(
  'private', 'app_attest_keys',
  'App Attest key and counter state remains private'
);
select has_table(
  'private', 'app_attest_submission_grants',
  'one-use score grants remain outside the exposed schema'
);
select has_function(
  'public', 'issue_app_attest_challenge',
  array['uuid', 'text', 'text'],
  'an authenticated installation can request a bound challenge'
);
select has_function(
  'public', 'load_app_attest_context',
  array['uuid', 'uuid', 'uuid', 'text', 'text', 'text'],
  'the service verifier can load a revalidated private context'
);
select has_function(
  'public', 'authorize_app_attest_proof',
  array[
    'uuid', 'uuid', 'uuid', 'text', 'text', 'text', 'text', 'text',
    'text', 'integer', 'text', 'bigint', 'uuid', 'uuid', 'integer',
    'bigint', 'timestamp with time zone', 'text'
  ],
  'the service verifier can atomically authorize a proof'
);
select has_function(
  'public', 'submit_attested_score_revision',
  array[
    'uuid', 'uuid', 'uuid', 'integer', 'bigint',
    'timestamp with time zone', 'text', 'text', 'integer', 'integer',
    'integer', 'text', 'text', 'text', 'text'
  ],
  'authenticated score submission requires a one-use grant'
);

select is((
  select pg_catalog.count(*)
  from pg_catalog.pg_class table_row
  join pg_catalog.pg_namespace schema_row
    on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'private'
    and table_row.relname in (
      'app_attest_challenges',
      'app_attest_keys',
      'app_attest_submission_grants'
    )
    and table_row.relrowsecurity
    and table_row.relforcerowsecurity
), 3::bigint, 'all App Attest tables enforce RLS without client policies');
select is((
  select pg_catalog.count(*)
  from information_schema.role_table_grants grant_row
  where grant_row.table_schema = 'private'
    and grant_row.table_name in (
      'app_attest_challenges',
      'app_attest_keys',
      'app_attest_submission_grants'
    )
    and grant_row.grantee in ('PUBLIC', 'anon', 'authenticated', 'service_role')
), 0::bigint, 'API roles have no App Attest table privileges');
select is((
  select pg_catalog.count(*)
  from information_schema.tables table_row
  where table_row.table_schema = 'public'
    and table_row.table_name in (
      'app_attest_challenges',
      'app_attest_keys',
      'app_attest_submission_grants'
    )
), 0::bigint, 'App Attest state has no public Data API tables');

select is((
  select pg_catalog.array_agg(
    column_row.column_name::text order by column_row.column_name
  )
  from information_schema.columns column_row
  where column_row.table_schema = 'private'
    and column_row.table_name = 'app_attest_keys'
), array[
  'attested_at', 'bundle_version', 'environment', 'installation_id',
  'key_id', 'profile_id', 'public_key_pem', 'receipt', 'sign_count',
  'updated_at', 'validation_category'
]::text[], 'key rows contain only verification material and routing identifiers');
select is((
  select pg_catalog.array_agg(
    column_row.column_name::text order by column_row.column_name
  )
  from information_schema.columns column_row
  where column_row.table_schema = 'private'
    and column_row.table_name = 'app_attest_submission_grants'
), array[
  'challenge_id', 'client_revision', 'competition_id', 'consumed_at',
  'created_at', 'day_ordinal', 'evaluated_at', 'expires_at', 'id',
  'installation_id', 'key_id', 'payload_sha256', 'profile_id',
  'semantic_event_id', 'wire_content_sha256'
]::text[], 'grants bind only canonical score metadata and digests');

select ok(
  has_function_privilege(
    'authenticated',
    'public.issue_app_attest_challenge(uuid,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'anon',
    'public.issue_app_attest_challenge(uuid,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'service_role',
    'public.issue_app_attest_challenge(uuid,text,text)',
    'EXECUTE'
  ),
  'challenge issuance is authenticated-only'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.load_app_attest_context(uuid,uuid,uuid,text,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'authenticated',
    'public.load_app_attest_context(uuid,uuid,uuid,text,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'anon',
    'public.load_app_attest_context(uuid,uuid,uuid,text,text,text)',
    'EXECUTE'
  ),
  'context loading is service-only'
);
select ok(
  has_function_privilege(
    'service_role',
    'public.authorize_app_attest_proof(uuid,uuid,uuid,text,text,text,text,text,text,integer,text,bigint,uuid,uuid,integer,bigint,timestamptz,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'authenticated',
    'public.authorize_app_attest_proof(uuid,uuid,uuid,text,text,text,text,text,text,integer,text,bigint,uuid,uuid,integer,bigint,timestamptz,text)',
    'EXECUTE'
  ),
  'proof authorization is service-only'
);
select ok(
  has_function_privilege(
    'authenticated',
    'public.submit_attested_score_revision(uuid,uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'anon',
    'public.submit_attested_score_revision(uuid,uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text,text)',
    'EXECUTE'
  ) and not has_function_privilege(
    'service_role',
    'public.submit_attested_score_revision(uuid,uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text,text)',
    'EXECUTE'
  ),
  'grant-backed score submission is authenticated-only'
);
select ok(not has_function_privilege(
  'authenticated',
  'public.submit_score_revision(uuid,uuid,integer,bigint,timestamptz,text,text,integer,integer,integer,text,text,text)',
  'EXECUTE'
), 'authenticated clients cannot bypass App Attest through the old score RPC');
select has_trigger(
  'public', 'profiles', 'purge_app_attest_on_profile_deactivation',
  'profile deactivation purges private App Attest material'
);
select has_trigger(
  'public', 'device_installations',
  'purge_app_attest_on_installation_revocation',
  'installation revocation purges private App Attest material'
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  (
    'e1000000-0000-4000-8000-000000000001',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'attest-a@example.invalid', '',
    now(), now()
  ),
  (
    'e1000000-0000-4000-8000-000000000002',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'attest-b@example.invalid', '',
    now(), now()
  ),
  (
    'e1000000-0000-4000-8000-000000000003',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'attest-c@example.invalid', '',
    now(), now()
  ),
  (
    'e1000000-0000-4000-8000-000000000004',
    '00000000-0000-0000-0000-000000000000',
    'authenticated', 'authenticated', 'attest-inactive@example.invalid', '',
    now(), now()
  );

insert into public.profiles (id, auth_user_id, display_name, state) values
  (
    'e2000000-0000-4000-8000-000000000001',
    'e1000000-0000-4000-8000-000000000001', 'Attest A', 'active'
  ),
  (
    'e2000000-0000-4000-8000-000000000002',
    'e1000000-0000-4000-8000-000000000002', 'Attest B', 'active'
  ),
  (
    'e2000000-0000-4000-8000-000000000003',
    'e1000000-0000-4000-8000-000000000003', 'Attest C', 'active'
  ),
  (
    'e2000000-0000-4000-8000-000000000004',
    'e1000000-0000-4000-8000-000000000004', 'Attest Inactive', 'deleting'
  );

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  'e4000000-0000-4000-8000-000000000001',
  'e2000000-0000-4000-8000-000000000001', 'UTC', '2026-08-15',
  'healthcomp.activity-score.v1', 'active',
  '2026-08-14T00:00:00Z', '2099-08-22T00:00:00Z'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  (
    'e4000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001', 'creator', 'accepted'
  ),
  (
    'e4000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002', 'invitee', 'accepted'
  );
set constraints all immediate;

insert into public.device_installations (
  id, profile_id, installation_id, apns_token, environment, state
) values
  (
    'e3000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    'e3100000-0000-4000-8000-000000000001',
    repeat('a1', 32), 'sandbox', 'active'
  ),
  (
    'e3000000-0000-4000-8000-000000000002',
    'e2000000-0000-4000-8000-000000000002',
    'e3100000-0000-4000-8000-000000000002',
    repeat('b2', 32), 'sandbox', 'active'
  ),
  (
    'e3000000-0000-4000-8000-000000000003',
    'e2000000-0000-4000-8000-000000000003',
    'e3100000-0000-4000-8000-000000000003',
    repeat('c3', 32), 'sandbox', 'active'
  ),
  (
    'e3000000-0000-4000-8000-000000000004',
    'e2000000-0000-4000-8000-000000000003',
    'e3100000-0000-4000-8000-000000000004',
    repeat('d4', 32), 'sandbox', 'active'
  ),
  (
    'e3000000-0000-4000-8000-000000000005',
    'e2000000-0000-4000-8000-000000000003',
    'e3100000-0000-4000-8000-000000000005',
    repeat('e5', 32), 'sandbox', 'active'
  );

create temporary table app_attest_values (
  key_1 text not null,
  key_2 text not null,
  key_3 text not null,
  payload_1 text not null,
  payload_2 text not null,
  wire_a_1 text not null,
  wire_a_2 text not null,
  wire_b_1 text not null,
  public_key text not null
);
insert into app_attest_values
select
  'AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=',
  'AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=',
  'AwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwM=',
  repeat('11', 32),
  repeat('22', 32),
  encode(private.wire_score_digest_v1(
    'e4000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    1::smallint, 'activeEnergyKilocalories', 'standHours',
    10000, 5000, 12500, 27500, 'available',
    'healthcomp.activity-score.v1', 1
  ), 'hex'),
  encode(private.wire_score_digest_v1(
    'e4000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000001',
    1::smallint, 'activeEnergyKilocalories', 'standHours',
    10001, 5000, 12500, 27501, 'available',
    'healthcomp.activity-score.v1', 2
  ), 'hex'),
  encode(private.wire_score_digest_v1(
    'e4000000-0000-4000-8000-000000000001',
    'e2000000-0000-4000-8000-000000000002',
    1::smallint, 'activeEnergyKilocalories', 'standHours',
    10000, 5000, 12500, 27500, 'available',
    'healthcomp.activity-score.v1', 1
  ), 'hex'),
  '-----BEGIN PUBLIC KEY-----' || chr(10)
    || repeat('A', 120) || chr(10) || '-----END PUBLIC KEY-----';

create temporary table app_attest_results (
  name text primary key,
  payload jsonb not null
);

select set_config('request.jwt.claims', '{"role":"anon"}', true);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  '42501', 'authentication_required',
  'anonymous callers cannot issue App Attest challenges'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  'P0002', 'app_attest_installation_unavailable',
  'a profile cannot issue a challenge for another installation'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000004","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  '42501', 'active_profile_required',
  'an inactive authenticated profile receives a typed profile failure'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'challenge_1', public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  'an active profile can issue a challenge for its active installation'
);
select is((
  select array_agg(key order by key)
  from jsonb_object_keys(
    (select payload from app_attest_results where name = 'challenge_1')
  ) key
), array[
  'challenge', 'challengeID', 'expiresAt', 'proofKind', 'version'
]::text[], 'challenge response has the exact bounded wire keys');
select is(
  (select payload->>'proofKind' from app_attest_results where name = 'challenge_1'),
  'attestation',
  'an unregistered key requires attestation'
);
select is((
  select octet_length(decode(payload->>'challenge', 'base64'))
  from app_attest_results where name = 'challenge_1'
), 32, 'the server challenge has 256 bits of randomness');
select ok((
  select challenge_row.expires_at - challenge_row.created_at
    = interval '5 minutes'
  from private.app_attest_challenges challenge_row
  where challenge_row.id = (
    select (payload->>'challengeID')::uuid
    from app_attest_results where name = 'challenge_1'
  )
), 'the challenge expires exactly five minutes after issuance');
select ok((
  select challenge_row.profile_id =
           'e2000000-0000-4000-8000-000000000001'::uuid
    and challenge_row.installation_id =
           'e3100000-0000-4000-8000-000000000001'::uuid
    and encode(challenge_row.payload_sha256, 'hex') =
           (select payload_1 from app_attest_values)
    and challenge_row.requested_key_id =
           (select key_1 from app_attest_values)
    and challenge_row.purpose = 'score_revision'
    and challenge_row.consumed_at is null
  from private.app_attest_challenges challenge_row
  where challenge_row.id = (
    select (payload->>'challengeID')::uuid
    from app_attest_results where name = 'challenge_1'
  )
), 'the private challenge binds profile installation key purpose and payload');

select throws_ok(
  $$
    select public.load_app_attest_context(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values),
      'attestation'
    )
  $$,
  '42501', 'service_role_required',
  'authenticated clients cannot load private verification context'
);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$
    select public.load_app_attest_context(
      'e1000000-0000-4000-8000-000000000002',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values),
      'attestation'
    )
  $$,
  'P0002', 'app_attest_context_unavailable',
  'service context loading cannot cross authenticated profiles'
);
select throws_ok(
  $$
    select public.load_app_attest_context(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      repeat('ff', 32),
      (select key_1 from app_attest_values),
      'attestation'
    )
  $$,
  'P0002', 'app_attest_context_unavailable',
  'service context loading rejects a payload mismatch'
);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'context_1', public.load_app_attest_context(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values),
      'attestation'
    )
  $$,
  'the service can load a fully bound unconsumed context'
);
select is(
  (select payload->'registeredKey' from app_attest_results where name = 'context_1'),
  'null'::jsonb,
  'first attestation context returns no registered key material'
);

select throws_ok(
  $$
    select public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      repeat('ff', 32),
      (select key_1 from app_attest_values),
      'attestation',
      (select public_key from app_attest_values),
      'cmVjZWlwdC1h', 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0002', 'app_attest_context_unavailable',
  'authorization rechecks the payload binding before storing a key'
);
select is((
  select count(*) from private.app_attest_keys
), 0::bigint, 'failed authorization stores no key material');
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'grant_1', public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values),
      'attestation',
      (select public_key from app_attest_values),
      'cmVjZWlwdC1h', 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'a verified first attestation registers the key and mints one grant'
);
select ok((
  select challenge_row.consumed_at is not null
  from private.app_attest_challenges challenge_row
  where challenge_row.id = (
    select (payload->>'challengeID')::uuid
    from app_attest_results where name = 'challenge_1'
  )
), 'successful authorization consumes the one-time challenge');
select ok((
  select key_row.profile_id =
           'e2000000-0000-4000-8000-000000000001'::uuid
    and key_row.installation_id =
           'e3100000-0000-4000-8000-000000000001'::uuid
    and key_row.sign_count = 0
    and key_row.environment = 'production'
    and key_row.validation_category = 2
    and key_row.bundle_version = '1'
    and convert_from(key_row.receipt, 'UTF8') = 'receipt-a'
  from private.app_attest_keys key_row
  where key_row.key_id = (select key_1 from app_attest_values)
), 'first attestation stores only the private verifier key receipt and policy');
select ok((
  select grant_row.profile_id =
           'e2000000-0000-4000-8000-000000000001'::uuid
    and grant_row.installation_id =
           'e3100000-0000-4000-8000-000000000001'::uuid
    and grant_row.key_id = (select key_1 from app_attest_values)
    and encode(grant_row.payload_sha256, 'hex') =
           (select payload_1 from app_attest_values)
    and grant_row.competition_id =
           'e4000000-0000-4000-8000-000000000001'::uuid
    and grant_row.semantic_event_id =
           'e5000000-0000-4000-8000-000000000001'::uuid
    and grant_row.day_ordinal = 1
    and grant_row.client_revision = 1
    and grant_row.evaluated_at = '2026-08-15T12:00:00Z'::timestamptz
    and encode(grant_row.wire_content_sha256, 'hex') =
           (select wire_a_1 from app_attest_values)
    and grant_row.expires_at - grant_row.created_at = interval '2 minutes'
    and grant_row.consumed_at is null
  from private.app_attest_submission_grants grant_row
  where grant_row.id = (
    select (payload->>'grantID')::uuid
    from app_attest_results where name = 'grant_1'
  )
), 'the short-lived grant binds every score identity field and digest');
select throws_ok(
  $$
    select public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_1'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_1 from app_attest_values),
      'attestation',
      (select public_key from app_attest_values),
      'cmVjZWlwdC1h', 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0002', 'app_attest_context_unavailable',
  'the same attestation challenge cannot authorize twice'
);
select is((
  select count(*) from private.app_attest_submission_grants
), 1::bigint, 'attestation replay creates no second grant');

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'challenge_2', public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  'a registered installation can request its next challenge'
);
select is(
  (select payload->>'proofKind' from app_attest_results where name = 'challenge_2'),
  'assertion',
  'a matching registered key advances with an assertion'
);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'context_2', public.load_app_attest_context(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_2'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values),
      'assertion'
    )
  $$,
  'assertion context exposes the registered public verifier state to service only'
);
select is(
  (select payload#>>'{registeredKey,previousSignCount}'
   from app_attest_results where name = 'context_2'),
  '0',
  'the assertion verifier receives the exact previous counter'
);
select throws_ok(
  $$
    select public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_2'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values),
      'assertion', null, null, 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_assertion_rejected',
  'an equal assertion counter is rejected'
);
select ok((
  select challenge_row.consumed_at is null
  from private.app_attest_challenges challenge_row
  where challenge_row.id = (
    select (payload->>'challengeID')::uuid
    from app_attest_results where name = 'challenge_2'
  )
), 'a rejected counter leaves the challenge retryable');
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'grant_2', public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_2'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values),
      'assertion', null, null, 'production', 2, '1', 1,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'a strictly increasing assertion counter authorizes one score grant'
);
select is((
  select sign_count from private.app_attest_keys
  where key_id = (select key_1 from app_attest_values)
), 1::bigint, 'the stored assertion counter advances monotonically');

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.submit_attested_score_revision(
      (select (payload->>'grantID')::uuid
       from app_attest_results where name = 'grant_2'),
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
      'available', 'healthcomp.activity-score.v1',
      (select payload_1 from app_attest_values),
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_grant_unavailable',
  'a grant cannot be moved to a different canonical payload digest'
);
select ok((
  select grant_row.consumed_at is null
  from private.app_attest_submission_grants grant_row
  where grant_row.id = (
    select (payload->>'grantID')::uuid
    from app_attest_results where name = 'grant_2'
  )
), 'a rejected grant binding leaves the correct submission retryable');
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'score_1', public.submit_attested_score_revision(
      (select (payload->>'grantID')::uuid
       from app_attest_results where name = 'grant_2'),
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
      'available', 'healthcomp.activity-score.v1',
      (select payload_2 from app_attest_values),
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'a correctly bound one-use grant reaches the existing score contract'
);
select is(
  (select payload->>'disposition' from app_attest_results where name = 'score_1'),
  'appended',
  'the grant-backed wrapper preserves the append response'
);
select ok((
  select grant_row.consumed_at is not null
  from private.app_attest_submission_grants grant_row
  where grant_row.id = (
    select (payload->>'grantID')::uuid
    from app_attest_results where name = 'grant_2'
  )
), 'successful score submission consumes the grant atomically');
select throws_ok(
  $$
    select public.submit_attested_score_revision(
      (select (payload->>'grantID')::uuid
       from app_attest_results where name = 'grant_2'),
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
      'available', 'healthcomp.activity-score.v1',
      (select payload_2 from app_attest_values),
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_grant_unavailable',
  'the same score grant cannot be consumed twice'
);
select is((
  select count(*) from public.daily_score_revisions
  where participant_profile_id =
    'e2000000-0000-4000-8000-000000000001'
), 1::bigint, 'grant replay writes no extra score revision');

select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'challenge_3', public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values)
    )
  $$,
  'a lost score response can start a fresh assertion proof'
);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'grant_3', public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_3'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_2 from app_attest_values),
      (select key_1 from app_attest_values),
      'assertion', null, null, 'production', 2, '1', 2,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'a fresh proof mints a replacement grant after a lost response'
);
select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select is(
  public.submit_attested_score_revision(
    (select (payload->>'grantID')::uuid
     from app_attest_results where name = 'grant_3'),
    'e4000000-0000-4000-8000-000000000001',
    'e5000000-0000-4000-8000-000000000001',
    1, 1, '2026-08-15T12:00:00Z',
    'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
    'available', 'healthcomp.activity-score.v1',
    (select payload_2 from app_attest_values),
    (select wire_a_1 from app_attest_values)
  )->>'disposition',
  'duplicate',
  'a fresh grant preserves existing semantic idempotency after a lost response'
);
select is((
  select count(*) from public.daily_score_revisions
  where participant_profile_id =
    'e2000000-0000-4000-8000-000000000001'
), 1::bigint, 'idempotent resubmission still writes exactly one score row');

select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'challenge_4', public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_2 from app_attest_values)
    )
  $$,
  'an installation can request attestation for a replacement key'
);
select is(
  (select payload->>'proofKind' from app_attest_results where name = 'challenge_4'),
  'attestation',
  'a changed key identifier requires a new attestation'
);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'grant_4', public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000001',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_4'),
      'e3100000-0000-4000-8000-000000000001',
      (select payload_1 from app_attest_values),
      (select key_2 from app_attest_values),
      'attestation',
      (select public_key from app_attest_values),
      'cmVjZWlwdC1i', 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000002',
      1, 2, '2026-08-15T13:00:00Z',
      (select wire_a_2 from app_attest_values)
    )
  $$,
  'a verified replacement atomically supersedes the installation key'
);
select is((
  select key_id from private.app_attest_keys
  where profile_id = 'e2000000-0000-4000-8000-000000000001'
    and installation_id = 'e3100000-0000-4000-8000-000000000001'
), (select key_2 from app_attest_values),
  'an installation retains exactly its newest attested key');
select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.submit_attested_score_revision(
      (select (payload->>'grantID')::uuid
       from app_attest_results where name = 'grant_1'),
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000001',
      1, 1, '2026-08-15T12:00:00Z',
      'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
      'available', 'healthcomp.activity-score.v1',
      (select payload_1 from app_attest_values),
      (select wire_a_1 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_grant_unavailable',
  'key replacement invalidates every older unconsumed grant'
);

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
select lives_ok(
  $$
    insert into app_attest_results (name, payload)
    select 'challenge_b', public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000002',
      (select payload_1 from app_attest_values),
      (select key_2 from app_attest_values)
    )
  $$,
  'a second profile can request a first attestation challenge'
);
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select throws_ok(
  $$
    select public.authorize_app_attest_proof(
      'e1000000-0000-4000-8000-000000000002',
      (select (payload->>'challengeID')::uuid
       from app_attest_results where name = 'challenge_b'),
      'e3100000-0000-4000-8000-000000000002',
      (select payload_1 from app_attest_values),
      (select key_2 from app_attest_values),
      'attestation',
      (select public_key from app_attest_values),
      'cmVjZWlwdC1i', 'production', 2, '1', 0,
      'e4000000-0000-4000-8000-000000000001',
      'e5000000-0000-4000-8000-000000000003',
      1, 1, '2026-08-15T12:00:00Z',
      (select wire_b_1 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_key_unavailable',
  'one App Attest key identifier can never belong to two profiles'
);
select is((
  select count(*) from private.app_attest_keys
  where profile_id = 'e2000000-0000-4000-8000-000000000002'
), 0::bigint, 'global key collision stores no second-profile key');
select ok((
  select consumed_at is null from private.app_attest_challenges
  where id = (
    select (payload->>'challengeID')::uuid
    from app_attest_results where name = 'challenge_b'
  )
), 'a rejected global key collision leaves its challenge unconsumed');

select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000001","role":"authenticated"}',
  true
);
insert into app_attest_results (name, payload)
select 'outstanding_1', public.issue_app_attest_challenge(
  'e3100000-0000-4000-8000-000000000001', repeat('31', 32),
  (select key_2 from app_attest_values)
);
insert into app_attest_results (name, payload)
select 'outstanding_2', public.issue_app_attest_challenge(
  'e3100000-0000-4000-8000-000000000001', repeat('32', 32),
  (select key_2 from app_attest_values)
);
insert into app_attest_results (name, payload)
select 'outstanding_3', public.issue_app_attest_challenge(
  'e3100000-0000-4000-8000-000000000001', repeat('33', 32),
  (select key_2 from app_attest_values)
);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000001', repeat('34', 32),
      (select key_2 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_challenge_limit',
  'an installation cannot accumulate more than three live challenges'
);
select is((
  select count(*) from private.app_attest_challenges
  where profile_id = 'e2000000-0000-4000-8000-000000000001'
    and installation_id = 'e3100000-0000-4000-8000-000000000001'
    and consumed_at is null
    and expires_at > statement_timestamp()
), 3::bigint, 'the failed outstanding-limit request inserts no challenge');

insert into private.app_attest_challenges (
  profile_id, installation_id, requested_key_id, payload_sha256,
  challenge, proof_kind, created_at, expires_at, consumed_at
)
select
  'e2000000-0000-4000-8000-000000000002',
  'e3100000-0000-4000-8000-000000000002',
  (select key_3 from app_attest_values),
  digest('installation-rate-payload-' || series.value, 'sha256'),
  digest('installation-rate-challenge-' || series.value, 'sha256'),
  'attestation', statement_timestamp(),
  statement_timestamp() + interval '5 minutes', statement_timestamp()
from generate_series(1, 9) series(value);
select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000002","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000002', repeat('41', 32),
      (select key_3 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_rate_limited',
  'an installation is limited to ten challenges per five minutes'
);

insert into private.app_attest_challenges (
  profile_id, installation_id, requested_key_id, payload_sha256,
  challenge, proof_kind, created_at, expires_at, consumed_at
)
select
  'e2000000-0000-4000-8000-000000000003',
  case series.value % 3
    when 0 then 'e3100000-0000-4000-8000-000000000003'::uuid
    when 1 then 'e3100000-0000-4000-8000-000000000004'::uuid
    else 'e3100000-0000-4000-8000-000000000005'::uuid
  end,
  (select key_3 from app_attest_values),
  digest('profile-rate-payload-' || series.value, 'sha256'),
  digest('profile-rate-challenge-' || series.value, 'sha256'),
  'attestation', statement_timestamp(),
  statement_timestamp() + interval '5 minutes', statement_timestamp()
from generate_series(1, 20) series(value);
select set_config(
  'request.jwt.claims',
  '{"sub":"e1000000-0000-4000-8000-000000000003","role":"authenticated"}',
  true
);
select throws_ok(
  $$
    select public.issue_app_attest_challenge(
      'e3100000-0000-4000-8000-000000000003', repeat('51', 32),
      (select key_3 from app_attest_values)
    )
  $$,
  'P0001', 'app_attest_rate_limited',
  'a profile is limited across all installations per five minutes'
);

update public.profiles profile_row
set state = 'deleting', updated_at = statement_timestamp()
where profile_row.id = 'e2000000-0000-4000-8000-000000000001';
select is((
  select count(*)
  from private.app_attest_challenges
  where profile_id = 'e2000000-0000-4000-8000-000000000001'
), 0::bigint, 'profile deactivation purges every challenge and cascaded grant');
select is((
  select count(*)
  from private.app_attest_submission_grants
  where profile_id = 'e2000000-0000-4000-8000-000000000001'
), 0::bigint, 'profile deactivation leaves no submission grant');
select is((
  select count(*)
  from private.app_attest_keys
  where profile_id = 'e2000000-0000-4000-8000-000000000001'
), 0::bigint, 'profile deactivation purges public keys receipts and counters');
select is((
  select count(*) from public.daily_score_revisions
  where participant_profile_id = 'e2000000-0000-4000-8000-000000000001'
), 1::bigint, 'App Attest cleanup preserves append-only score history');
select ok((
  select count(*) > 0 from private.app_attest_challenges
  where profile_id = 'e2000000-0000-4000-8000-000000000002'
), 'one profile deactivation never purges another profile state');

insert into private.app_attest_keys (
  key_id, profile_id, installation_id, public_key_pem, receipt,
  environment, validation_category, bundle_version
)
select
  key_3,
  'e2000000-0000-4000-8000-000000000002',
  'e3100000-0000-4000-8000-000000000002',
  public_key, decode('b2', 'hex'), 'production', 2, '1'
from app_attest_values;
update public.device_installations installation_row
set state = 'revoked', updated_at = statement_timestamp()
where installation_row.profile_id = 'e2000000-0000-4000-8000-000000000002'
  and installation_row.installation_id =
    'e3100000-0000-4000-8000-000000000002';
select is((
  select count(*) from private.app_attest_challenges
  where profile_id = 'e2000000-0000-4000-8000-000000000002'
), 0::bigint, 'installation revocation purges its challenges and grants');
select is((
  select count(*) from private.app_attest_keys
  where profile_id = 'e2000000-0000-4000-8000-000000000002'
), 0::bigint, 'installation revocation purges its verifier key state');

select * from finish();
rollback;
