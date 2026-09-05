-- Aggregate comparison only: no row content, identifiers or individual hashes.
-- Run through recovery-history-integrity.sql for the read-only/error boundary.
-- Shape checks cannot establish that history was never rewritten. Schema/FK,
-- genuine deletion and common-recovery-point evidence remain separate gates.
with log_shapes as (
  select competition_id, pg_catalog.count(*) as row_count,
    pg_catalog.count(distinct server_seq) as distinct_sequences,
    pg_catalog.min(server_seq) as first_sequence,
    pg_catalog.max(server_seq) as last_sequence
  from public.competition_change_log
  group by competition_id
), competition_checks as (
  select case when coalesce(log.row_count, 0) = 0
    then competition.next_server_seq = 1
    else log.first_sequence = 1
      and log.last_sequence = log.row_count
      and log.distinct_sequences = log.row_count
      and competition.next_server_seq::numeric = log.row_count::numeric + 1
    end as valid_sequence
  from public.competitions competition
  left join log_shapes log on log.competition_id = competition.id
), result_checks as (
  select result.competition_id,
    case when result.frozen_window->'version' = '2'::jsonb then 2
      when result.frozen_window->'version' = '1'::jsonb then 1
      else 0 end as frozen_format,
    -- CASE is deliberate: malformed JSON/hex must never reach the decoder.
    case when private.is_valid_frozen_window_v2(
      result.frozen_window, result.competition_id,
      result.participant_a_profile_id, result.participant_b_profile_id,
      result.participant_a_total_centi_points, result.participant_b_total_centi_points
    ) is true then (
      result.competition_id <> '00000000-0000-0000-0000-000000000000'::uuid
      and result.participant_a_profile_id <> '00000000-0000-0000-0000-000000000000'::uuid
      and result.participant_b_profile_id <> '00000000-0000-0000-0000-000000000000'::uuid
      and result.participant_a_profile_id < result.participant_b_profile_id
      and result.frozen_window->'participants'->0->>'profile_id' = result.participant_a_profile_id::text
      and result.frozen_window->'participants'->1->>'profile_id' = result.participant_b_profile_id::text
      and result.participant_a_total_centi_points between 0 and 420000
      and result.participant_b_total_centi_points between 0 and 420000
      and result.finalization_basis in ('stable', 'best_available')
      -- Supplement historical validation with null-safe missing-reason and
      -- stable-window rules. This cannot prove prior attestation acceptance.
      and not exists (
        select 1
        from pg_catalog.jsonb_array_elements(result.frozen_window->'participants') participant
        cross join lateral pg_catalog.jsonb_array_elements(participant->'days') day
        where (day->>'source' = 'deadline_missing'
          and day->'reason' is distinct from '"missing"'::jsonb)
          or (result.finalization_basis = 'stable'
            and day->>'source' is distinct from 'accepted_revision')
      )
      and result.server_seq > 0
      and pg_catalog.isfinite(result.completed_at)
      and (
        (result.outcome = 'tie' and result.winner_profile_id is null
          and result.participant_a_total_centi_points = result.participant_b_total_centi_points)
        or (result.outcome = 'winner' and (
          (result.participant_a_total_centi_points > result.participant_b_total_centi_points
            and result.winner_profile_id = result.participant_a_profile_id)
          or (result.participant_b_total_centi_points > result.participant_a_total_centi_points
            and result.winner_profile_id = result.participant_b_profile_id)
        ))
      )
      and result.immutable_hash = private.result_immutable_hash_v1(
        result.competition_id,
        result.participant_a_profile_id, result.participant_a_total_centi_points,
        pg_catalog.decode(result.frozen_window->'participants'->0->>'window_commitment_sha256', 'hex'),
        result.participant_b_profile_id, result.participant_b_total_centi_points,
        pg_catalog.decode(result.frozen_window->'participants'->1->>'window_commitment_sha256', 'hex'),
        result.outcome, result.winner_profile_id, result.finalization_basis
      )
    ) is true else false end as valid_format2,
    pg_catalog.encode(result.immutable_hash, 'hex') as stored_hash,
    -- Include every stored column, including nulls and unknown/legacy formats.
    -- Normalize timestamp and bytea rendering independently of session settings.
    pg_catalog.encode(extensions.digest(pg_catalog.convert_to((
      pg_catalog.to_jsonb(result) || pg_catalog.jsonb_build_object(
        'completed_at', pg_catalog.encode(pg_catalog.timestamptz_send(result.completed_at), 'hex'),
        'immutable_hash', pg_catalog.encode(result.immutable_hash, 'hex')
      )
    )::text, 'UTF8'), 'sha256'), 'hex') as complete_fingerprint
  from public.competition_results result
), result_totals as (
  select pg_catalog.count(*) as total,
    pg_catalog.count(*) filter (where frozen_format = 2) as checked,
    pg_catalog.count(*) filter (where frozen_format = 2 and valid_format2 is not true) as invalid,
    pg_catalog.count(*) filter (where frozen_format = 1) as legacy,
    pg_catalog.count(*) filter (where frozen_format = 0) as unsupported,
    pg_catalog.encode(extensions.digest(coalesce(pg_catalog.string_agg(
      stored_hash, '' order by stored_hash collate "C"), ''), 'sha256'), 'hex') as stored_hash,
    pg_catalog.encode(extensions.digest(coalesce(pg_catalog.string_agg(
      complete_fingerprint, '' order by competition_id, complete_fingerprint collate "C"), ''), 'sha256'), 'hex') as complete_fingerprint
  from result_checks
)
select pg_catalog.jsonb_build_object(
  'receipt_version', 1,
  'competitions_checked', (select pg_catalog.count(*) from competition_checks),
  'competitions_invalid_sequence', (select pg_catalog.count(*) from competition_checks where valid_sequence is not true),
  'change_rows_total', (select pg_catalog.count(*) from public.competition_change_log),
  'change_rows_orphaned', (select pg_catalog.count(*) from public.competition_change_log log
    where not exists (select 1 from public.competitions competition where competition.id = log.competition_id)),
  'results_total', result_totals.total,
  'results_format2_checked', result_totals.checked,
  'results_format2_invalid', result_totals.invalid,
  'results_legacy_unverified', result_totals.legacy,
  'results_unsupported', result_totals.unsupported,
  'aggregate_stored_result_hash', result_totals.stored_hash,
  'aggregate_complete_result_fingerprint', result_totals.complete_fingerprint
) as receipt
from result_totals;
