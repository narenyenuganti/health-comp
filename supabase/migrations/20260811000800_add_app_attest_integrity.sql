create table private.app_attest_keys (
  key_id text primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  installation_id uuid not null,
  public_key_pem text not null,
  receipt bytea not null,
  environment text not null,
  validation_category integer not null,
  bundle_version text not null,
  sign_count bigint not null default 0,
  attested_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_attest_keys_installation_unique
    unique (profile_id, installation_id),
  constraint app_attest_keys_installation_fk
    foreign key (profile_id, installation_id)
    references public.device_installations(profile_id, installation_id)
    on delete cascade,
  constraint app_attest_keys_key_id_check
    check (key_id ~ '^[A-Za-z0-9+/]{43}=$'),
  constraint app_attest_keys_public_key_check check (
    pg_catalog.char_length(public_key_pem) between 100 and 2048
    and pg_catalog.starts_with(public_key_pem, '-----BEGIN PUBLIC KEY-----')
  ),
  constraint app_attest_keys_receipt_check
    check (pg_catalog.octet_length(receipt) between 1 and 65536),
  constraint app_attest_keys_environment_check
    check (environment in ('development', 'production')),
  constraint app_attest_keys_validation_category_check check (
    validation_category between 1 and 10
    and validation_category not in (7, 8, 9)
  ),
  constraint app_attest_keys_bundle_version_check
    check (bundle_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'),
  constraint app_attest_keys_counter_check
    check (sign_count between 0 and 4294967295),
  constraint app_attest_keys_timestamp_check
    check (updated_at >= attested_at)
);

create table private.app_attest_challenges (
  id uuid primary key default extensions.gen_random_uuid(),
  profile_id uuid not null references public.profiles(id) on delete cascade,
  installation_id uuid not null,
  requested_key_id text not null,
  payload_sha256 bytea not null,
  challenge bytea not null unique,
  purpose text not null default 'score_revision',
  proof_kind text not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint app_attest_challenges_installation_fk
    foreign key (profile_id, installation_id)
    references public.device_installations(profile_id, installation_id)
    on delete cascade,
  constraint app_attest_challenges_key_id_check
    check (requested_key_id ~ '^[A-Za-z0-9+/]{43}=$'),
  constraint app_attest_challenges_payload_check
    check (pg_catalog.octet_length(payload_sha256) = 32),
  constraint app_attest_challenges_challenge_check
    check (pg_catalog.octet_length(challenge) = 32),
  constraint app_attest_challenges_purpose_check
    check (purpose = 'score_revision'),
  constraint app_attest_challenges_kind_check
    check (proof_kind in ('attestation', 'assertion')),
  constraint app_attest_challenges_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '5 minutes'
  ),
  constraint app_attest_challenges_consumed_check check (
    consumed_at is null
    or (consumed_at >= created_at and consumed_at <= expires_at)
  )
);

create table private.app_attest_submission_grants (
  id uuid primary key default extensions.gen_random_uuid(),
  challenge_id uuid not null unique
    references private.app_attest_challenges(id) on delete cascade,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  installation_id uuid not null,
  key_id text not null,
  payload_sha256 bytea not null,
  competition_id uuid not null references public.competitions(id),
  semantic_event_id uuid not null,
  day_ordinal integer not null,
  client_revision bigint not null,
  evaluated_at timestamptz not null,
  wire_content_sha256 bytea not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  consumed_at timestamptz,
  constraint app_attest_submission_grants_installation_fk
    foreign key (profile_id, installation_id)
    references public.device_installations(profile_id, installation_id)
    on delete cascade,
  constraint app_attest_submission_grants_key_id_check
    check (key_id ~ '^[A-Za-z0-9+/]{43}=$'),
  constraint app_attest_submission_grants_payload_check
    check (pg_catalog.octet_length(payload_sha256) = 32),
  constraint app_attest_submission_grants_day_check
    check (day_ordinal between 1 and 7),
  constraint app_attest_submission_grants_revision_check
    check (client_revision > 0),
  constraint app_attest_submission_grants_wire_check
    check (pg_catalog.octet_length(wire_content_sha256) = 32),
  constraint app_attest_submission_grants_expiry_check check (
    expires_at > created_at
    and expires_at <= created_at + interval '2 minutes'
  ),
  constraint app_attest_submission_grants_consumed_check check (
    consumed_at is null
    or (consumed_at >= created_at and consumed_at <= expires_at)
  )
);

alter table private.app_attest_keys enable row level security;
alter table private.app_attest_keys force row level security;
alter table private.app_attest_challenges enable row level security;
alter table private.app_attest_challenges force row level security;
alter table private.app_attest_submission_grants enable row level security;
alter table private.app_attest_submission_grants force row level security;

revoke all on table
  private.app_attest_keys,
  private.app_attest_challenges,
  private.app_attest_submission_grants
from public, anon, authenticated, service_role;

create index app_attest_challenges_rate_idx
  on private.app_attest_challenges(profile_id, installation_id, created_at desc);
create index app_attest_challenges_outstanding_idx
  on private.app_attest_challenges(profile_id, installation_id, expires_at)
  where consumed_at is null;
create index app_attest_submission_grants_profile_idx
  on private.app_attest_submission_grants(profile_id, expires_at)
  where consumed_at is null;

create or replace function private.app_attest_key_id_is_valid(value text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select value is not null and value ~ '^[A-Za-z0-9+/]{43}=$';
$$;

create or replace function private.decode_app_attest_sha256(value text)
returns bytea
language plpgsql
immutable
strict
set search_path = ''
as $$
begin
  if value !~ '^[0-9a-f]{64}$' then
    raise exception 'invalid_app_attest_digest' using errcode = '22023';
  end if;
  return pg_catalog.decode(value, 'hex');
end;
$$;

revoke all on function private.app_attest_key_id_is_valid(text)
  from public, anon, authenticated, service_role;
revoke all on function private.decode_app_attest_sha256(text)
  from public, anon, authenticated, service_role;

create or replace function public.issue_app_attest_challenge(
  installation_id uuid,
  payload_sha256 text,
  key_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_installation_id alias for installation_id;
  input_payload_sha256 alias for payload_sha256;
  input_key_id alias for key_id;
  caller_profile_id uuid;
  caller_profile_state text;
  payload_digest bytea;
  registered_key_id text;
  selected_kind text;
  challenge_record record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if input_installation_id is null
     or input_payload_sha256 is null
     or not private.app_attest_key_id_is_valid(input_key_id) then
    raise exception 'invalid_app_attest_challenge_request'
      using errcode = '22023';
  end if;
  payload_digest := private.decode_app_attest_sha256(input_payload_sha256);

  select profile_row.id, profile_row.state
  into caller_profile_id, caller_profile_state
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
  for update;

  if not found or caller_profile_state <> 'active' then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  perform 1
  from public.device_installations installation_row
  where installation_row.profile_id = caller_profile_id
    and installation_row.installation_id = input_installation_id
    and installation_row.state = 'active'
  for update;

  if not found then
    raise exception 'app_attest_installation_unavailable'
      using errcode = 'P0002';
  end if;

  delete from private.app_attest_challenges challenge_row
  where challenge_row.profile_id = caller_profile_id
    and challenge_row.created_at < decision_time - interval '1 day';

  if (
    select pg_catalog.count(*) >= 20
    from private.app_attest_challenges challenge_row
    where challenge_row.profile_id = caller_profile_id
      and challenge_row.created_at > decision_time - interval '5 minutes'
  ) or (
    select pg_catalog.count(*) >= 10
    from private.app_attest_challenges challenge_row
    where challenge_row.profile_id = caller_profile_id
      and challenge_row.installation_id = input_installation_id
      and challenge_row.created_at > decision_time - interval '5 minutes'
  ) then
    raise exception 'app_attest_rate_limited' using errcode = 'P0001';
  end if;

  if (
    select pg_catalog.count(*) >= 3
    from private.app_attest_challenges challenge_row
    where challenge_row.profile_id = caller_profile_id
      and challenge_row.installation_id = input_installation_id
      and challenge_row.consumed_at is null
      and challenge_row.expires_at > decision_time
  ) then
    raise exception 'app_attest_challenge_limit' using errcode = 'P0001';
  end if;

  select key_row.key_id
  into registered_key_id
  from private.app_attest_keys key_row
  where key_row.profile_id = caller_profile_id
    and key_row.installation_id = input_installation_id;

  selected_kind := case
    when registered_key_id = input_key_id then 'assertion'
    else 'attestation'
  end;

  insert into private.app_attest_challenges (
    profile_id,
    installation_id,
    requested_key_id,
    payload_sha256,
    challenge,
    purpose,
    proof_kind,
    created_at,
    expires_at
  ) values (
    caller_profile_id,
    input_installation_id,
    input_key_id,
    payload_digest,
    extensions.gen_random_bytes(32),
    'score_revision',
    selected_kind,
    decision_time,
    decision_time + interval '5 minutes'
  )
  returning * into challenge_record;

  return pg_catalog.jsonb_build_object(
    'version', 1,
    'challengeID', challenge_record.id,
    'challenge', pg_catalog.encode(challenge_record.challenge, 'base64'),
    'expiresAt', challenge_record.expires_at,
    'proofKind', challenge_record.proof_kind
  );
end;
$$;

create or replace function public.load_app_attest_context(
  target_auth_user_id uuid,
  challenge_id uuid,
  installation_id uuid,
  payload_sha256 text,
  key_id text,
  proof_kind text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_auth_user_id alias for target_auth_user_id;
  input_challenge_id alias for challenge_id;
  input_installation_id alias for installation_id;
  input_payload_sha256 alias for payload_sha256;
  input_key_id alias for key_id;
  input_proof_kind alias for proof_kind;
  payload_digest bytea;
  challenge_record record;
  key_record record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_auth_user_id is null
     or input_challenge_id is null
     or input_installation_id is null
     or input_payload_sha256 is null
     or input_proof_kind is null
     or input_proof_kind not in ('attestation', 'assertion')
     or not private.app_attest_key_id_is_valid(input_key_id) then
    raise exception 'invalid_app_attest_context_request'
      using errcode = '22023';
  end if;
  payload_digest := private.decode_app_attest_sha256(input_payload_sha256);

  select challenge_row.*
  into challenge_record
  from private.app_attest_challenges challenge_row
  join public.profiles profile_row
    on profile_row.id = challenge_row.profile_id
   and profile_row.auth_user_id = input_auth_user_id
   and profile_row.state = 'active'
  join public.device_installations installation_row
    on installation_row.profile_id = challenge_row.profile_id
   and installation_row.installation_id = challenge_row.installation_id
   and installation_row.state = 'active'
  where challenge_row.id = input_challenge_id
    and challenge_row.installation_id = input_installation_id
    and challenge_row.requested_key_id = input_key_id
    and challenge_row.payload_sha256 = payload_digest
    and challenge_row.purpose = 'score_revision'
    and challenge_row.proof_kind = input_proof_kind
    and challenge_row.consumed_at is null
    and challenge_row.expires_at > decision_time
  for share of challenge_row;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  select key_row.*
  into key_record
  from private.app_attest_keys key_row
  where key_row.profile_id = challenge_record.profile_id
    and key_row.installation_id = challenge_record.installation_id;

  if input_proof_kind = 'assertion' then
    if not found or key_record.key_id <> input_key_id then
      raise exception 'app_attest_context_unavailable'
        using errcode = 'P0002';
    end if;
  elsif found and key_record.key_id = input_key_id then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  return pg_catalog.jsonb_build_object(
    'version', 1,
    'challengeID', challenge_record.id,
    'challenge', pg_catalog.encode(challenge_record.challenge, 'base64'),
    'profileID', challenge_record.profile_id,
    'installationID', challenge_record.installation_id,
    'payloadSHA256', pg_catalog.encode(challenge_record.payload_sha256, 'hex'),
    'keyID', challenge_record.requested_key_id,
    'proofKind', challenge_record.proof_kind,
    'expiresAt', challenge_record.expires_at,
    'registeredKey', case
      when input_proof_kind = 'assertion' then
        pg_catalog.jsonb_build_object(
          'publicKeyPEM', key_record.public_key_pem,
          'previousSignCount', key_record.sign_count,
          'environment', key_record.environment,
          'validationCategory', key_record.validation_category,
          'bundleVersion', key_record.bundle_version
        )
      else null
    end
  );
end;
$$;

create or replace function public.authorize_app_attest_proof(
  target_auth_user_id uuid,
  challenge_id uuid,
  installation_id uuid,
  payload_sha256 text,
  key_id text,
  proof_kind text,
  public_key_pem text,
  receipt_base64 text,
  environment text,
  validation_category integer,
  bundle_version text,
  sign_count bigint,
  competition_id uuid,
  semantic_event_id uuid,
  day_ordinal integer,
  client_revision bigint,
  evaluated_at timestamptz,
  wire_content_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_auth_user_id alias for target_auth_user_id;
  input_challenge_id alias for challenge_id;
  input_installation_id alias for installation_id;
  input_payload_sha256 alias for payload_sha256;
  input_key_id alias for key_id;
  input_proof_kind alias for proof_kind;
  input_public_key_pem alias for public_key_pem;
  input_receipt_base64 alias for receipt_base64;
  input_environment alias for environment;
  input_validation_category alias for validation_category;
  input_bundle_version alias for bundle_version;
  input_sign_count alias for sign_count;
  input_competition_id alias for competition_id;
  input_semantic_event_id alias for semantic_event_id;
  input_day_ordinal alias for day_ordinal;
  input_client_revision alias for client_revision;
  input_evaluated_at alias for evaluated_at;
  input_wire_content_sha256 alias for wire_content_sha256;
  caller_profile_id uuid;
  payload_digest bytea;
  wire_digest bytea;
  receipt_bytes bytea;
  challenge_record record;
  key_record record;
  grant_record record;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;
  if input_auth_user_id is null
     or input_challenge_id is null
     or input_installation_id is null
     or input_payload_sha256 is null
     or input_wire_content_sha256 is null
     or input_proof_kind is null
     or input_proof_kind not in ('attestation', 'assertion')
     or not private.app_attest_key_id_is_valid(input_key_id)
     or input_environment is null
     or input_environment not in ('development', 'production')
     or input_validation_category is null
     or input_validation_category not between 1 and 10
     or input_validation_category in (7, 8, 9)
     or input_bundle_version is null
     or input_bundle_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
     or input_sign_count is null
     or input_sign_count not between 0 and 4294967295
     or input_competition_id is null
     or input_semantic_event_id is null
     or input_day_ordinal is null
     or input_day_ordinal not between 1 and 7
     or input_client_revision is null
     or input_client_revision <= 0
     or input_evaluated_at is null then
    raise exception 'invalid_app_attest_authorization'
      using errcode = '22023';
  end if;
  payload_digest := private.decode_app_attest_sha256(input_payload_sha256);
  wire_digest := private.decode_app_attest_sha256(input_wire_content_sha256);

  if input_proof_kind = 'attestation' then
    if input_sign_count <> 0
       or input_public_key_pem is null
       or pg_catalog.char_length(input_public_key_pem) not between 100 and 2048
       or not pg_catalog.starts_with(
         input_public_key_pem, '-----BEGIN PUBLIC KEY-----'
       )
       or input_receipt_base64 is null
       or pg_catalog.char_length(input_receipt_base64) not between 4 and 87384
       or pg_catalog.char_length(input_receipt_base64) % 4 <> 0
       or input_receipt_base64 !~ '^[A-Za-z0-9+/]+={0,2}$' then
      raise exception 'invalid_app_attest_authorization'
        using errcode = '22023';
    end if;
    begin
      receipt_bytes := pg_catalog.decode(input_receipt_base64, 'base64');
    exception
      when others then
        raise exception 'invalid_app_attest_authorization'
          using errcode = '22023';
    end;
    if pg_catalog.octet_length(receipt_bytes) not between 1 and 65536 then
      raise exception 'invalid_app_attest_authorization'
        using errcode = '22023';
    end if;
  elsif input_public_key_pem is not null or input_receipt_base64 is not null then
    raise exception 'invalid_app_attest_authorization'
      using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = input_auth_user_id
    and profile_row.state = 'active'
  for update;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  perform 1
  from public.device_installations installation_row
  where installation_row.profile_id = caller_profile_id
    and installation_row.installation_id = input_installation_id
    and installation_row.state = 'active'
  for update;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  select challenge_row.*
  into challenge_record
  from private.app_attest_challenges challenge_row
  where challenge_row.id = input_challenge_id
  for update;

  if not found
     or challenge_record.profile_id <> caller_profile_id
     or challenge_record.installation_id <> input_installation_id
     or challenge_record.requested_key_id <> input_key_id
     or challenge_record.payload_sha256 <> payload_digest
     or challenge_record.purpose <> 'score_revision'
     or challenge_record.proof_kind <> input_proof_kind
     or challenge_record.consumed_at is not null
     or challenge_record.expires_at <= decision_time then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  perform 1
  from public.competitions competition_row
  join public.competition_participants participant_row
    on participant_row.competition_id = competition_row.id
   and participant_row.profile_id = caller_profile_id
   and participant_row.state = 'accepted'
  where competition_row.id = input_competition_id;

  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;

  select key_row.*
  into key_record
  from private.app_attest_keys key_row
  where key_row.profile_id = caller_profile_id
    and key_row.installation_id = input_installation_id
  for update;

  if input_proof_kind = 'assertion' then
    if not found
       or key_record.key_id <> input_key_id
       or key_record.environment <> input_environment
       or input_sign_count <= key_record.sign_count then
      raise exception 'app_attest_assertion_rejected' using errcode = 'P0001';
    end if;

    update private.app_attest_keys key_row
    set sign_count = input_sign_count,
        validation_category = input_validation_category,
        bundle_version = input_bundle_version,
        updated_at = decision_time
    where key_row.key_id = input_key_id;
  else
    if found and key_record.key_id = input_key_id then
      raise exception 'app_attest_attestation_stale' using errcode = 'P0001';
    end if;

    begin
      insert into private.app_attest_keys as key_target (
        key_id,
        profile_id,
        installation_id,
        public_key_pem,
        receipt,
        environment,
        validation_category,
        bundle_version,
        sign_count,
        attested_at,
        updated_at
      ) values (
        input_key_id,
        caller_profile_id,
        input_installation_id,
        input_public_key_pem,
        receipt_bytes,
        input_environment,
        input_validation_category,
        input_bundle_version,
        0,
        decision_time,
        decision_time
      )
      on conflict on constraint app_attest_keys_installation_unique
      do update
      set key_id = excluded.key_id,
          public_key_pem = excluded.public_key_pem,
          receipt = excluded.receipt,
          environment = excluded.environment,
          validation_category = excluded.validation_category,
          bundle_version = excluded.bundle_version,
          sign_count = 0,
          attested_at = excluded.attested_at,
          updated_at = excluded.updated_at;
    exception
      when unique_violation then
        raise exception 'app_attest_key_unavailable' using errcode = 'P0001';
    end;
  end if;

  update private.app_attest_challenges challenge_row
  set consumed_at = decision_time
  where challenge_row.id = challenge_record.id
    and challenge_row.consumed_at is null
    and challenge_row.expires_at > decision_time;

  if not found then
    raise exception 'app_attest_context_unavailable'
      using errcode = 'P0002';
  end if;

  insert into private.app_attest_submission_grants (
    challenge_id,
    profile_id,
    installation_id,
    key_id,
    payload_sha256,
    competition_id,
    semantic_event_id,
    day_ordinal,
    client_revision,
    evaluated_at,
    wire_content_sha256,
    created_at,
    expires_at
  ) values (
    challenge_record.id,
    caller_profile_id,
    input_installation_id,
    input_key_id,
    payload_digest,
    input_competition_id,
    input_semantic_event_id,
    input_day_ordinal,
    input_client_revision,
    input_evaluated_at,
    wire_digest,
    decision_time,
    decision_time + interval '2 minutes'
  )
  returning * into grant_record;

  return pg_catalog.jsonb_build_object(
    'version', 1,
    'grantID', grant_record.id,
    'expiresAt', grant_record.expires_at
  );
end;
$$;

create or replace function public.submit_attested_score_revision(
  grant_id uuid,
  competition_id uuid,
  semantic_event_id uuid,
  day_ordinal integer,
  client_revision bigint,
  evaluated_at timestamptz,
  move_mode text,
  stand_mode text,
  move_basis_points integer,
  exercise_basis_points integer,
  stand_basis_points integer,
  availability_reason text,
  scoring_policy_identity text,
  payload_sha256 text,
  expected_wire_content_sha256 text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_grant_id alias for grant_id;
  input_competition_id alias for competition_id;
  input_semantic_event_id alias for semantic_event_id;
  input_day_ordinal alias for day_ordinal;
  input_client_revision alias for client_revision;
  input_evaluated_at alias for evaluated_at;
  input_payload_sha256 alias for payload_sha256;
  input_expected_wire_content_sha256 alias for expected_wire_content_sha256;
  caller_profile_id uuid;
  payload_digest bytea;
  wire_digest bytea;
  grant_record record;
  result jsonb;
  decision_time timestamptz := pg_catalog.statement_timestamp();
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;
  if input_grant_id is null
     or input_competition_id is null
     or input_semantic_event_id is null
     or input_day_ordinal is null
     or input_client_revision is null
     or input_evaluated_at is null
     or input_payload_sha256 is null
     or input_expected_wire_content_sha256 is null then
    raise exception 'invalid_app_attest_grant' using errcode = '22023';
  end if;
  payload_digest := private.decode_app_attest_sha256(input_payload_sha256);
  wire_digest := private.decode_app_attest_sha256(
    input_expected_wire_content_sha256
  );
  caller_profile_id := private.assert_authenticated_profile();

  select grant_row.*
  into grant_record
  from private.app_attest_submission_grants grant_row
  where grant_row.id = input_grant_id
  for update;

  if not found
     or grant_record.profile_id <> caller_profile_id
     or grant_record.competition_id <> input_competition_id
     or grant_record.semantic_event_id <> input_semantic_event_id
     or grant_record.day_ordinal <> input_day_ordinal
     or grant_record.client_revision <> input_client_revision
     or grant_record.evaluated_at <> input_evaluated_at
     or grant_record.payload_sha256 <> payload_digest
     or grant_record.wire_content_sha256 <> wire_digest
     or grant_record.consumed_at is not null
     or grant_record.expires_at <= decision_time
     or not exists (
       select 1
       from private.app_attest_keys key_row
       where key_row.profile_id = grant_record.profile_id
         and key_row.installation_id = grant_record.installation_id
         and key_row.key_id = grant_record.key_id
     ) then
    raise exception 'app_attest_grant_unavailable' using errcode = 'P0001';
  end if;

  update private.app_attest_submission_grants grant_row
  set consumed_at = decision_time
  where grant_row.id = grant_record.id
    and grant_row.consumed_at is null
    and grant_row.expires_at > decision_time;

  if not found then
    raise exception 'app_attest_grant_unavailable' using errcode = 'P0001';
  end if;

  result := public.submit_score_revision(
    input_competition_id,
    input_semantic_event_id,
    input_day_ordinal,
    input_client_revision,
    input_evaluated_at,
    move_mode,
    stand_mode,
    move_basis_points,
    exercise_basis_points,
    stand_basis_points,
    availability_reason,
    scoring_policy_identity,
    input_expected_wire_content_sha256
  );
  return result;
end;
$$;

create or replace function private.purge_app_attest_on_profile_deactivation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.state = 'active' and new.state <> 'active' then
    delete from private.app_attest_challenges challenge_row
    where challenge_row.profile_id = new.id;

    delete from private.app_attest_keys key_row
    where key_row.profile_id = new.id;
  end if;
  return new;
end;
$$;

create trigger purge_app_attest_on_profile_deactivation
after update of state on public.profiles
for each row execute function private.purge_app_attest_on_profile_deactivation();

create or replace function private.purge_app_attest_on_installation_revocation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.state = 'active' and new.state = 'revoked' then
    delete from private.app_attest_challenges challenge_row
    where challenge_row.profile_id = new.profile_id
      and challenge_row.installation_id = new.installation_id;

    delete from private.app_attest_keys key_row
    where key_row.profile_id = new.profile_id
      and key_row.installation_id = new.installation_id;
  end if;
  return new;
end;
$$;

create trigger purge_app_attest_on_installation_revocation
after update of state on public.device_installations
for each row execute function private.purge_app_attest_on_installation_revocation();

revoke all on function private.purge_app_attest_on_profile_deactivation()
  from public, anon, authenticated, service_role;
revoke all on function private.purge_app_attest_on_installation_revocation()
  from public, anon, authenticated, service_role;

revoke all on function public.issue_app_attest_challenge(uuid, text, text)
  from public, anon, authenticated, service_role;
revoke all on function public.load_app_attest_context(
  uuid, uuid, uuid, text, text, text
) from public, anon, authenticated, service_role;
revoke all on function public.authorize_app_attest_proof(
  uuid, uuid, uuid, text, text, text, text, text, text, integer,
  text, bigint, uuid, uuid, integer, bigint, timestamptz, text
) from public, anon, authenticated, service_role;
revoke all on function public.submit_attested_score_revision(
  uuid, uuid, uuid, integer, bigint, timestamptz, text, text,
  integer, integer, integer, text, text, text, text
) from public, anon, authenticated, service_role;

grant execute on function public.issue_app_attest_challenge(uuid, text, text)
  to authenticated;
grant execute on function public.load_app_attest_context(
  uuid, uuid, uuid, text, text, text
) to service_role;
grant execute on function public.authorize_app_attest_proof(
  uuid, uuid, uuid, text, text, text, text, text, text, integer,
  text, bigint, uuid, uuid, integer, bigint, timestamptz, text
) to service_role;
grant execute on function public.submit_attested_score_revision(
  uuid, uuid, uuid, integer, bigint, timestamptz, text, text,
  integer, integer, integer, text, text, text, text
) to authenticated;

revoke all on function public.submit_score_revision(
  uuid, uuid, integer, bigint, timestamptz, text, text,
  integer, integer, integer, text, text, text
) from authenticated;
