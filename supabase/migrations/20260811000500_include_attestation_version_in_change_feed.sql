-- Forward-only contract correction: the client cannot materialize an
-- authoritative participant attestation without its stored version.
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
      'attestation_version', attestation_row.attestation_version::text,
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
