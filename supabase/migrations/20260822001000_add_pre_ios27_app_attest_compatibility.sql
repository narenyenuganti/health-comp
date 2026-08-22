alter table private.app_attest_keys
  alter column validation_category drop not null,
  alter column bundle_version drop not null,
  drop constraint app_attest_keys_validation_category_check,
  drop constraint app_attest_keys_bundle_version_check,
  add constraint app_attest_keys_policy_metadata_check check (
    (
      validation_category is null
      and bundle_version is null
    )
    or (
      validation_category is not null
      and bundle_version is not null
      and
      validation_category between 1 and 10
      and validation_category not in (7, 8, 9)
      and bundle_version ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
    )
  );

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
     or (input_validation_category is null) <>
        (input_bundle_version is null)
     or (
       input_validation_category is not null
       and (
         input_validation_category not between 1 and 10
         or input_validation_category in (7, 8, 9)
         or input_bundle_version !~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
       )
     )
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
       or key_record.validation_category is distinct from
          input_validation_category
       or key_record.bundle_version is distinct from input_bundle_version
       or input_sign_count <= key_record.sign_count then
      raise exception 'app_attest_assertion_rejected' using errcode = 'P0001';
    end if;

    update private.app_attest_keys key_row
    set sign_count = input_sign_count,
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
