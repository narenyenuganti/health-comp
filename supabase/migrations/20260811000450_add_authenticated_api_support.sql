alter table public.competitions
  add column invite_creation_idempotency_key uuid,
  add column invite_token_derivation_version smallint not null default 0,
  add constraint competitions_invite_token_derivation_version_check
    check (invite_token_derivation_version in (0, 1)),
  add constraint competitions_creator_invite_idempotency_unique
    unique (creator_profile_id, invite_creation_idempotency_key);

alter table public.device_installations
  add column installation_id uuid not null default gen_random_uuid(),
  add constraint device_installations_profile_installation_unique
    unique (profile_id, installation_id);

alter table public.competition_change_log
  add column payload_snapshot jsonb,
  add constraint competition_change_log_payload_snapshot_object_check
    check (
      payload_snapshot is null
      or pg_catalog.jsonb_typeof(payload_snapshot) = 'object'
    );

create or replace function private.allocate_competition_server_seq(
  target_competition_id uuid,
  target_change_kind text,
  target_entity_id uuid,
  target_occurred_at timestamptz default now()
)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  allocated_seq bigint;
  allocated_payload jsonb;
begin
  if target_change_kind is null or target_change_kind !~ '^[a-z][a-z0-9_]{0,63}$' then
    raise exception 'invalid competition change kind' using errcode = '22023';
  end if;

  update public.competitions
  set next_server_seq = next_server_seq + 1,
      updated_at = greatest(updated_at, target_occurred_at)
  where id = target_competition_id
  returning next_server_seq - 1 into allocated_seq;

  if allocated_seq is null then
    raise exception 'competition does not exist' using errcode = 'P0002';
  end if;

  case target_change_kind
  when 'participant_added', 'participant_state_changed' then
    select pg_catalog.jsonb_build_object(
      'profile_id', participant_row.profile_id,
      'role', participant_row.role,
      'state', participant_row.state
    )
    into allocated_payload
    from public.competition_participants participant_row
    where participant_row.competition_id = target_competition_id
      and participant_row.profile_id = target_entity_id;

  when 'competition_lifecycle_changed' then
    select pg_catalog.jsonb_build_object(
      'lifecycle', competition_row.lifecycle,
      'time_zone_identifier', competition_row.time_zone_identifier,
      'start_day', competition_row.start_day,
      'best_available_deadline', competition_row.best_available_deadline,
      'scoring_policy_identity', competition_row.scoring_policy_identity
    )
    into allocated_payload
    from public.competitions competition_row
    where competition_row.id = target_competition_id
      and target_entity_id = target_competition_id;

  when 'profile_presentation_changed', 'profile_anonymized' then
    select pg_catalog.jsonb_build_object(
      'profile_id', profile_row.id,
      'display_name', profile_row.display_name
    )
    into allocated_payload
    from public.profiles profile_row
    where profile_row.id = target_entity_id
      and exists (
        select 1
        from public.competition_participants participant_row
        where participant_row.competition_id = target_competition_id
          and participant_row.profile_id = profile_row.id
      );

  else
    allocated_payload := null;
  end case;

  if target_change_kind in (
       'participant_added', 'participant_state_changed',
       'competition_lifecycle_changed',
       'profile_presentation_changed', 'profile_anonymized'
     ) and allocated_payload is null then
    raise exception 'server_contract_mismatch' using errcode = 'P0001';
  end if;

  insert into public.competition_change_log (
    competition_id,
    server_seq,
    change_kind,
    entity_id,
    occurred_at,
    payload_snapshot
  ) values (
    target_competition_id,
    allocated_seq,
    target_change_kind,
    target_entity_id,
    target_occurred_at,
    allocated_payload
  );

  return allocated_seq;
end;
$$;

revoke all on function private.allocate_competition_server_seq(
  uuid, text, uuid, timestamptz
) from public, anon, authenticated, service_role;

revoke select on public.device_installations from authenticated;

create or replace function public.bootstrap_current_profile(
  suggested_display_name text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_display_name alias for suggested_display_name;
  normalized_display_name text;
  profile_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id, profile_row.display_name, profile_row.state
  into profile_record
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
  for update;

  if found then
    if profile_record.state <> 'active' then
      raise exception 'active_profile_required' using errcode = '42501';
    end if;

    return pg_catalog.jsonb_build_object(
      'id', profile_record.id,
      'display_name', profile_record.display_name
    );
  end if;

  if input_display_name is null then
    raise exception 'display_name_required' using errcode = 'P0001';
  end if;

  normalized_display_name := pg_catalog.btrim(input_display_name);
  if pg_catalog.char_length(normalized_display_name) not between 1 and 64
     or normalized_display_name = 'Former competitor'
     or normalized_display_name ~ '[[:cntrl:]]' then
    raise exception 'invalid_display_name' using errcode = '22023';
  end if;

  insert into public.profiles (auth_user_id, display_name, state)
  values ((select auth.uid()), normalized_display_name, 'active')
  on conflict (auth_user_id) do nothing
  returning id, display_name, state
  into profile_record;

  if not found then
    select profile_row.id, profile_row.display_name, profile_row.state
    into profile_record
    from public.profiles profile_row
    where profile_row.auth_user_id = (select auth.uid())
    for update;
  end if;

  if profile_record.id is null or profile_record.state <> 'active' then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  return pg_catalog.jsonb_build_object(
    'id', profile_record.id,
    'display_name', profile_record.display_name
  );
end;
$$;

create or replace function public.update_current_profile(
  new_display_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_display_name alias for new_display_name;
  normalized_display_name text;
  profile_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id, profile_row.display_name, profile_row.state
  into profile_record
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
  for update;

  if not found or profile_record.state <> 'active' then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  normalized_display_name := pg_catalog.btrim(input_display_name);
  if input_display_name is null
     or pg_catalog.char_length(normalized_display_name) not between 1 and 64
     or normalized_display_name = 'Former competitor'
     or normalized_display_name ~ '[[:cntrl:]]' then
    raise exception 'invalid_display_name' using errcode = '22023';
  end if;

  update public.profiles
  set display_name = normalized_display_name,
      updated_at = pg_catalog.statement_timestamp()
  where id = profile_record.id
  returning id, display_name
  into profile_record;

  return pg_catalog.jsonb_build_object(
    'id', profile_record.id,
    'display_name', profile_record.display_name
  );
end;
$$;

create or replace function private.record_profile_presentation_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  membership record;
begin
  if old.state = 'active'
     and new.state = 'active'
     and old.display_name is distinct from new.display_name then
    for membership in
      select participant_row.competition_id
      from public.competition_participants participant_row
      where participant_row.profile_id = new.id
    loop
      perform private.allocate_competition_server_seq(
        membership.competition_id,
        'profile_presentation_changed',
        new.id,
        new.updated_at
      );
    end loop;
  end if;

  return new;
end;
$$;

revoke all on function private.record_profile_presentation_change()
  from public, anon, authenticated, service_role;

create trigger record_profile_presentation_change
after update of display_name on public.profiles
for each row execute function private.record_profile_presentation_change();

create or replace function public.create_competition_invite(
  token_digest bytea,
  creator_time_zone_identifier text,
  rematch_parent_id uuid,
  creator_auth_user_id uuid,
  creation_idempotency_key uuid,
  token_derivation_version smallint
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  input_time_zone_identifier alias for creator_time_zone_identifier;
  input_rematch_parent_id alias for rematch_parent_id;
  input_creator_auth_user_id alias for creator_auth_user_id;
  input_idempotency_key alias for creation_idempotency_key;
  input_derivation_version alias for token_derivation_version;
  caller_profile_id uuid;
  source_scoring_policy text;
  new_competition_id uuid;
  existing_invite record;
  invite_expires_at timestamptz :=
    pg_catalog.statement_timestamp() + private.invitation_expiry_interval_v1();
begin
  if (select auth.role()) is distinct from 'service_role' then
    raise exception 'service_role_required' using errcode = '42501';
  end if;

  if input_token_digest is null
     or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invalid_token_digest' using errcode = '22023';
  end if;

  if input_idempotency_key is null then
    raise exception 'invalid_idempotency_key' using errcode = '22023';
  end if;

  if input_derivation_version is distinct from 1::smallint then
    raise exception 'invalid_token_derivation_version' using errcode = '22023';
  end if;

  if input_time_zone_identifier is null
     or not exists (
       select 1
       from pg_catalog.pg_timezone_names time_zone_row
       where time_zone_row.name = input_time_zone_identifier
     ) then
    raise exception 'invalid_time_zone' using errcode = '22023';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = input_creator_auth_user_id
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  select competition_row.id,
         competition_row.time_zone_identifier,
         competition_row.rematch_parent_id,
         competition_row.invite_token_derivation_version,
         invite_row.token_digest
  into existing_invite
  from public.competitions competition_row
  join public.competition_invites invite_row
    on invite_row.competition_id = competition_row.id
  where competition_row.creator_profile_id = caller_profile_id
    and competition_row.invite_creation_idempotency_key = input_idempotency_key
  for update of competition_row, invite_row;

  if found then
    if existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;

    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  if input_rematch_parent_id is null then
    source_scoring_policy := 'healthcomp.activity-score.v1';
  else
    select source_competition.scoring_policy_identity
    into source_scoring_policy
    from public.competitions source_competition
    where source_competition.id = input_rematch_parent_id
      and source_competition.lifecycle in ('completed', 'archived')
      and exists (
        select 1
        from public.competition_participants source_membership
        where source_membership.competition_id = source_competition.id
          and source_membership.profile_id = caller_profile_id
          and source_membership.state = 'accepted'
      );

    if source_scoring_policy is null then
      raise exception 'rematch_not_allowed' using errcode = '42501';
    end if;
  end if;

  insert into public.competitions (
    creator_profile_id,
    time_zone_identifier,
    start_day,
    scoring_policy_identity,
    lifecycle,
    invitation_expires_at,
    best_available_deadline,
    rematch_parent_id,
    invite_creation_idempotency_key,
    invite_token_derivation_version
  ) values (
    caller_profile_id,
    input_time_zone_identifier,
    null,
    source_scoring_policy,
    'pending',
    invite_expires_at,
    null,
    input_rematch_parent_id,
    input_idempotency_key,
    input_derivation_version
  )
  on conflict (creator_profile_id, invite_creation_idempotency_key) do nothing
  returning id into new_competition_id;

  if new_competition_id is null then
    select competition_row.id,
           competition_row.time_zone_identifier,
           competition_row.rematch_parent_id,
           competition_row.invite_token_derivation_version,
           invite_row.token_digest
    into existing_invite
    from public.competitions competition_row
    join public.competition_invites invite_row
      on invite_row.competition_id = competition_row.id
    where competition_row.creator_profile_id = caller_profile_id
      and competition_row.invite_creation_idempotency_key = input_idempotency_key
    for update of competition_row, invite_row;

    if found
       and existing_invite.time_zone_identifier is not distinct from input_time_zone_identifier
       and existing_invite.rematch_parent_id is not distinct from input_rematch_parent_id
       and existing_invite.invite_token_derivation_version = input_derivation_version
       and existing_invite.token_digest = input_token_digest then
      return existing_invite.id;
    end if;

    raise exception 'idempotency_conflict' using errcode = 'P0001';
  end if;

  insert into public.competition_participants (
    competition_id, profile_id, role, state
  ) values (
    new_competition_id, caller_profile_id, 'creator', 'accepted'
  );

  insert into public.competition_invites (
    competition_id, token_digest, expires_at
  ) values (
    new_competition_id, input_token_digest, invite_expires_at
  );

  return new_competition_id;
end;
$$;

create or replace function public.claim_competition_invite(token_digest bytea)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_token_digest alias for token_digest;
  caller_profile_id uuid;
  target_invite record;
  frozen_start_day date;
  frozen_deadline timestamptz;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if input_token_digest is null
     or pg_catalog.octet_length(input_token_digest) <> 32 then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select invite_row.id,
         invite_row.competition_id,
         invite_row.claimed_profile_id,
         invite_row.consumed_at,
         invite_row.expires_at,
         competition_row.creator_profile_id,
         competition_row.time_zone_identifier,
         competition_row.lifecycle
  into target_invite
  from public.competition_invites invite_row
  join public.competitions competition_row
    on competition_row.id = invite_row.competition_id
  where invite_row.token_digest = input_token_digest
  for update of invite_row, competition_row;

  if found
     and target_invite.consumed_at is not null
     and target_invite.claimed_profile_id = caller_profile_id then
    return target_invite.competition_id;
  end if;

  if not found
     or target_invite.consumed_at is not null
     or target_invite.claimed_profile_id is not null
     or target_invite.expires_at <= pg_catalog.statement_timestamp()
     or target_invite.lifecycle <> 'pending' then
    raise exception 'invite_unavailable' using errcode = 'P0001';
  end if;

  if target_invite.creator_profile_id = caller_profile_id then
    raise exception 'cannot_claim_own_invite' using errcode = 'P0001';
  end if;

  frozen_start_day :=
    (pg_catalog.statement_timestamp()
      at time zone target_invite.time_zone_identifier)::date + 1;
  frozen_deadline :=
    ((frozen_start_day + private.best_available_local_day_offset_v1())::timestamp
      at time zone target_invite.time_zone_identifier);

  insert into public.competition_participants (
    competition_id, profile_id, role, state
  ) values (
    target_invite.competition_id, caller_profile_id, 'invitee', 'accepted'
  );

  update public.competition_invites
  set claimed_profile_id = caller_profile_id,
      consumed_at = pg_catalog.statement_timestamp()
  where id = target_invite.id;

  update public.competitions
  set start_day = frozen_start_day,
      lifecycle = 'scheduled',
      best_available_deadline = frozen_deadline,
      updated_at = pg_catalog.statement_timestamp()
  where id = target_invite.competition_id;

  return target_invite.competition_id;
end;
$$;

create or replace function public.register_current_device_installation(
  installation_id uuid,
  apns_token text,
  environment text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_installation_id alias for installation_id;
  input_apns_token alias for apns_token;
  input_environment alias for environment;
  caller_profile_id uuid;
  token_owner_profile_id uuid;
  installation_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  if input_installation_id is null
     or input_apns_token is null
     or input_apns_token !~ '^[0-9a-f]{64,200}$'
     or input_environment not in ('sandbox', 'production') then
    raise exception 'invalid_installation_request' using errcode = '22023';
  end if;

  select installation_row.profile_id
  into token_owner_profile_id
  from public.device_installations installation_row
  where installation_row.apns_token = input_apns_token
  for update;

  if found and token_owner_profile_id <> caller_profile_id then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  begin
    insert into public.device_installations as installation_target (
      profile_id, installation_id, apns_token, environment, state
    ) values (
      caller_profile_id, input_installation_id, input_apns_token,
      input_environment, 'active'
    )
    on conflict on constraint device_installations_profile_installation_unique
    do update
    set apns_token = excluded.apns_token,
        environment = excluded.environment,
        state = 'active',
        updated_at = pg_catalog.statement_timestamp()
    returning installation_target.installation_id,
              installation_target.environment,
              installation_target.state
    into installation_record;
  exception
    when unique_violation then
      raise exception 'installation_unavailable' using errcode = 'P0001';
  end;

  return pg_catalog.jsonb_build_object(
    'installation_id', installation_record.installation_id,
    'environment', installation_record.environment,
    'state', installation_record.state
  );
end;
$$;

create or replace function public.remove_current_device_installation(
  installation_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_installation_id alias for installation_id;
  caller_profile_id uuid;
  installation_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  select profile_row.id
  into caller_profile_id
  from public.profiles profile_row
  where profile_row.auth_user_id = (select auth.uid())
    and profile_row.state = 'active';

  if caller_profile_id is null then
    raise exception 'active_profile_required' using errcode = '42501';
  end if;

  if input_installation_id is null then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  update public.device_installations as installation_target
  set state = 'revoked',
      updated_at = pg_catalog.statement_timestamp()
  where installation_target.profile_id = caller_profile_id
    and installation_target.installation_id = input_installation_id
  returning installation_target.installation_id,
            installation_target.environment,
            installation_target.state
  into installation_record;

  if not found then
    raise exception 'installation_unavailable' using errcode = 'P0001';
  end if;

  return pg_catalog.jsonb_build_object(
    'installation_id', installation_record.installation_id,
    'environment', installation_record.environment,
    'state', installation_record.state
  );
end;
$$;

create or replace function private.competition_change_payload(
  target_competition_id uuid,
  target_change_kind text,
  target_entity_id uuid,
  target_server_seq bigint
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  payload jsonb;
begin
  case target_change_kind
  when 'participant_added', 'participant_state_changed' then
    select change_row.payload_snapshot
    into payload
    from public.competition_change_log change_row
    where change_row.competition_id = target_competition_id
      and change_row.server_seq = target_server_seq
      and change_row.change_kind = target_change_kind
      and change_row.entity_id = target_entity_id;

    if payload is null
       or payload->>'profile_id' <> target_entity_id::text
       or (select pg_catalog.array_agg(key order by key)
           from pg_catalog.jsonb_object_keys(payload) keys(key))
          <> array['profile_id', 'role', 'state']::text[] then
      raise exception 'server_contract_mismatch' using errcode = 'P0001';
    end if;

  when 'competition_lifecycle_changed' then
    select change_row.payload_snapshot
    into payload
    from public.competition_change_log change_row
    where change_row.competition_id = target_competition_id
      and change_row.server_seq = target_server_seq
      and change_row.change_kind = target_change_kind
      and change_row.entity_id = target_entity_id;

    if payload is null
       or target_entity_id <> target_competition_id
       or (select pg_catalog.array_agg(key order by key)
           from pg_catalog.jsonb_object_keys(payload) keys(key))
          <> array[
            'best_available_deadline', 'lifecycle', 'scoring_policy_identity',
            'start_day', 'time_zone_identifier'
          ]::text[] then
      raise exception 'server_contract_mismatch' using errcode = 'P0001';
    end if;

  when 'profile_presentation_changed', 'profile_anonymized' then
    select change_row.payload_snapshot
    into payload
    from public.competition_change_log change_row
    where change_row.competition_id = target_competition_id
      and change_row.server_seq = target_server_seq
      and change_row.change_kind = target_change_kind
      and change_row.entity_id = target_entity_id;

    if payload is null
       or payload->>'profile_id' <> target_entity_id::text
       or (select pg_catalog.array_agg(key order by key)
           from pg_catalog.jsonb_object_keys(payload) keys(key))
          <> array['display_name', 'profile_id']::text[] then
      raise exception 'server_contract_mismatch' using errcode = 'P0001';
    end if;

  when 'score_revision_recorded' then
    select pg_catalog.jsonb_build_object(
      'participant_profile_id', score_row.participant_profile_id,
      'day_ordinal', score_row.day_ordinal,
      'client_revision', score_row.client_revision::text,
      'move_mode', score_row.move_mode,
      'stand_mode', score_row.stand_mode,
      'move_basis_points', score_row.move_basis_points,
      'exercise_basis_points', score_row.exercise_basis_points,
      'stand_basis_points', score_row.stand_basis_points,
      'accepted_centi_points', score_row.accepted_centi_points,
      'availability_reason', score_row.availability_reason,
      'scoring_policy_identity', score_row.scoring_policy_identity,
      'wire_digest_version', score_row.wire_digest_version,
      'wire_content_sha256', pg_catalog.encode(
        score_row.wire_content_sha256, 'hex'
      ),
      'server_seq', score_row.server_seq::text,
      'evaluated_at', score_row.evaluated_at
    )
    into payload
    from public.daily_score_revisions score_row
    where score_row.competition_id = target_competition_id
      and score_row.id = target_entity_id
      and score_row.server_seq = target_server_seq;

  when 'participant_attested' then
    select pg_catalog.jsonb_build_object(
      'participant_profile_id', attestation_row.participant_profile_id,
      'basis', attestation_row.basis,
      'window_commitment_sha256', pg_catalog.encode(
        attestation_row.window_commitment_sha256, 'hex'
      ),
      'accepted_revisions', (
        select pg_catalog.jsonb_agg(revision::text order by ordinal)
        from pg_catalog.unnest(attestation_row.accepted_revisions)
          with ordinality revisions(revision, ordinal)
      ),
      'server_seq', attestation_row.server_seq::text,
      'attested_at', attestation_row.attested_at
    )
    into payload
    from public.participant_finalization_attestations attestation_row
    where attestation_row.competition_id = target_competition_id
      and attestation_row.id = target_entity_id
      and attestation_row.server_seq = target_server_seq;

  when 'competition_result_confirmed' then
    select pg_catalog.jsonb_build_object(
      'participant_a_profile_id', result_row.participant_a_profile_id,
      'participant_b_profile_id', result_row.participant_b_profile_id,
      'participant_a_total_centi_points',
        result_row.participant_a_total_centi_points,
      'participant_b_total_centi_points',
        result_row.participant_b_total_centi_points,
      'winner_profile_id', result_row.winner_profile_id,
      'outcome', result_row.outcome,
      'finalization_basis', result_row.finalization_basis,
      'completed_at', result_row.completed_at,
      'frozen_window', result_row.frozen_window,
      'immutable_hash', pg_catalog.encode(result_row.immutable_hash, 'hex'),
      'server_seq', result_row.server_seq::text
    )
    into payload
    from public.competition_results result_row
    where result_row.competition_id = target_competition_id
      and target_entity_id = target_competition_id
      and result_row.server_seq = target_server_seq;

  when 'competition_award_earned' then
    select pg_catalog.jsonb_build_object(
      'profile_id', award_row.profile_id,
      'award_type', award_row.award_type,
      'server_seq', award_row.server_seq::text,
      'earned_at', award_row.earned_at
    )
    into payload
    from public.competition_awards award_row
    where award_row.competition_id = target_competition_id
      and award_row.id = target_entity_id
      and award_row.server_seq = target_server_seq;

  else
    raise exception 'server_contract_mismatch' using errcode = 'P0001';
  end case;

  if payload is null then
    raise exception 'server_contract_mismatch' using errcode = 'P0001';
  end if;

  return payload;
end;
$$;

revoke all on function private.competition_change_payload(
  uuid, text, uuid, bigint
) from public, anon, authenticated, service_role;

create or replace function public.fetch_competition_changes(
  competition_id uuid,
  after_server_seq bigint,
  page_size integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  input_after_server_seq alias for after_server_seq;
  input_page_size alias for page_size;
  snapshot_server_seq bigint;
  next_cursor bigint;
  expected_server_seq bigint;
  has_more boolean;
  changes jsonb := '[]'::jsonb;
  change_record record;
begin
  if (select auth.role()) is distinct from 'authenticated'
     or (select auth.uid()) is null then
    raise exception 'authentication_required' using errcode = '42501';
  end if;

  if input_after_server_seq is null or input_after_server_seq < 0 then
    raise exception 'invalid_cursor' using errcode = '22023';
  end if;
  if input_page_size is null or input_page_size not between 1 and 200 then
    raise exception 'invalid_page_size' using errcode = '22023';
  end if;

  select competition_row.next_server_seq - 1
  into snapshot_server_seq
  from public.competitions competition_row
  where competition_row.id = input_competition_id
    and (select private.is_competition_participant(competition_row.id))
  for share of competition_row;

  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;

  if input_after_server_seq > snapshot_server_seq then
    raise exception 'cursor_ahead' using errcode = '22023';
  end if;

  next_cursor := input_after_server_seq;
  expected_server_seq := input_after_server_seq + 1;

  for change_record in
    select change_row.server_seq,
           change_row.change_kind,
           change_row.entity_id,
           change_row.occurred_at
    from public.competition_change_log change_row
    where change_row.competition_id = input_competition_id
      and change_row.server_seq > input_after_server_seq
      and change_row.server_seq <= snapshot_server_seq
    order by change_row.server_seq
    limit input_page_size
  loop
    if change_record.server_seq <> expected_server_seq then
      raise exception 'server_contract_mismatch' using errcode = 'P0001';
    end if;

    changes := changes || pg_catalog.jsonb_build_array(
      pg_catalog.jsonb_build_object(
        'server_seq', change_record.server_seq::text,
        'kind', change_record.change_kind,
        'entity_id', change_record.entity_id,
        'occurred_at', change_record.occurred_at,
        'payload', private.competition_change_payload(
          input_competition_id,
          change_record.change_kind,
          change_record.entity_id,
          change_record.server_seq
        )
      )
    );
    next_cursor := change_record.server_seq;
    expected_server_seq := expected_server_seq + 1;
  end loop;

  if next_cursor < snapshot_server_seq
     and not exists (
       select 1
       from public.competition_change_log change_row
       where change_row.competition_id = input_competition_id
         and change_row.server_seq = next_cursor + 1
         and change_row.server_seq <= snapshot_server_seq
     ) then
    raise exception 'server_contract_mismatch' using errcode = 'P0001';
  end if;

  has_more := next_cursor < snapshot_server_seq;

  return pg_catalog.jsonb_build_object(
    'competition_id', input_competition_id,
    'after_server_seq', input_after_server_seq::text,
    'snapshot_server_seq', snapshot_server_seq::text,
    'next_server_seq', next_cursor::text,
    'has_more', has_more,
    'changes', changes
  );
end;
$$;

revoke all on function public.bootstrap_current_profile(text)
  from public, anon, authenticated, service_role;
revoke all on function public.update_current_profile(text)
  from public, anon, authenticated, service_role;
revoke all on function public.create_competition_invite(
  bytea, text, uuid, uuid, uuid, smallint
) from public, anon, authenticated, service_role;
revoke all on function public.create_competition_invite(bytea, text, uuid, uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.register_current_device_installation(
  uuid, text, text
) from public, anon, authenticated, service_role;
revoke all on function public.remove_current_device_installation(uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.fetch_competition_changes(uuid, bigint, integer)
  from public, anon, authenticated, service_role;

grant execute on function public.bootstrap_current_profile(text) to authenticated;
grant execute on function public.update_current_profile(text) to authenticated;
grant execute on function public.create_competition_invite(
  bytea, text, uuid, uuid, uuid, smallint
) to service_role;
grant execute on function public.register_current_device_installation(
  uuid, text, text
) to authenticated;
grant execute on function public.remove_current_device_installation(uuid)
  to authenticated;
grant execute on function public.fetch_competition_changes(uuid, bigint, integer)
  to authenticated;
