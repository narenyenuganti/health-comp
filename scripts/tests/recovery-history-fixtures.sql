-- Synthetic fixture setup only, inside the assembler's guarded rollback transaction.
-- These projections deliberately omit constraints so malformed restore records can
-- reach the actual read-only query. They do not test production constraints.
-- The competition_results columns, order and types match the immutable migration.
create table public.competitions (id uuid, next_server_seq bigint);
create table public.competition_change_log (competition_id uuid, server_seq bigint);
create table public.competition_results (
  competition_id uuid,
  participant_a_profile_id uuid,
  participant_b_profile_id uuid,
  participant_a_total_centi_points integer,
  participant_b_total_centi_points integer,
  winner_profile_id uuid,
  outcome text,
  finalization_basis text,
  completed_at timestamptz,
  frozen_window jsonb,
  immutable_hash bytea,
  server_seq bigint
);
create table public.profiles (
  id uuid, auth_user_id uuid, display_name text, state text,
  anonymized_at timestamptz
);

-- Only fixture construction is new. TLV/day/hash implementations are the real
-- definitions extracted by the assembler, not substitute hash implementations.
create function pg_temp.recovery_fixture_result(
  fixture_kind text,
  fixture_competition_id uuid default '00000000-0000-0000-0000-000000000001'
)
returns public.competition_results
language plpgsql
as $fixture_result$
declare
  result_row public.competition_results;
  owner_ids uuid[] := array[
    '00000000-0000-0000-0000-000000000002'::uuid,
    '00000000-0000-0000-0000-000000000003'::uuid
  ];
  owner_totals integer[] := array[0, 0];
  commitments bytea[] := array[]::bytea[];
  participants jsonb := '[]'::jsonb;
  days jsonb;
  owner_content bytea;
  day_points integer;
  day_reason text;
  day_status text;
  day_source text;
  day_digest bytea;
  day_revision bigint;
  day_sequence bigint;
  owner_index integer;
  ordinal integer;
begin
  if fixture_kind not in ('missing', 'stable', 'mixed') or fixture_kind is null then
    raise exception 'recovery_fixture_kind_invalid';
  end if;
  for owner_index in 1..2 loop
    days := '[]'::jsonb;
    owner_content := pg_catalog.convert_to('healthcomp-owner-window-v1', 'UTF8')
      || pg_catalog.decode('00', 'hex')
      || private.tlv_v1(1, pg_catalog.uuid_send(fixture_competition_id))
      || private.tlv_v1(2, pg_catalog.uuid_send(owner_ids[owner_index]))
      || private.tlv_v1(3, pg_catalog.convert_to('healthcomp.activity-score.v1', 'UTF8'));
    for ordinal in 1..7 loop
      day_source := 'accepted_revision';
      day_status := 'points';
      day_points := case owner_index when 1 then 600 else 400 end;
      day_reason := null;
      day_digest := pg_catalog.decode(repeat(case owner_index when 1 then 'a1' else 'b2' end, 32), 'hex');
      day_revision := ordinal;
      day_sequence := (owner_index - 1) * 7 + ordinal;
      if fixture_kind = 'missing' then
        day_source := 'deadline_missing';
        day_status := 'unavailable';
        day_points := null;
        day_reason := 'missing';
        day_digest := null;
        day_revision := null;
        day_sequence := null;
      elsif fixture_kind = 'mixed' and ordinal = 1 then
        day_points := 0;
      elsif fixture_kind = 'mixed' and ordinal = 2 then
        day_status := 'unavailable';
        day_points := null;
        day_reason := 'sourceDataUnavailable';
      end if;
      owner_totals[owner_index] := owner_totals[owner_index] + coalesce(day_points, 0);
      days := days || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
        'ordinal', ordinal, 'status', day_status, 'source', day_source,
        'centi_points', day_points, 'reason', day_reason,
        'wire_content_sha256', pg_catalog.encode(day_digest, 'hex'),
        'client_revision', day_revision::text, 'server_seq', day_sequence::text,
        'scoring_policy_identity', case when day_source = 'accepted_revision'
          then 'healthcomp.activity-score.v1' else null end
      ));
      owner_content := owner_content || private.tlv_v1(10 + ordinal,
        private.window_day_content_v1(ordinal, day_status, day_points, day_reason,
          day_digest, day_revision, day_sequence));
    end loop;
    commitments := pg_catalog.array_append(commitments, extensions.digest(owner_content, 'sha256'));
    participants := participants || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'profile_id', owner_ids[owner_index], 'total_centi_points', owner_totals[owner_index],
      'window_commitment_sha256', pg_catalog.encode(commitments[owner_index], 'hex'), 'days', days
    ));
  end loop;
  result_row.competition_id := fixture_competition_id;
  result_row.participant_a_profile_id := owner_ids[1];
  result_row.participant_b_profile_id := owner_ids[2];
  result_row.participant_a_total_centi_points := owner_totals[1];
  result_row.participant_b_total_centi_points := owner_totals[2];
  result_row.winner_profile_id := case when owner_totals[1] = owner_totals[2] then null else owner_ids[1] end;
  result_row.outcome := case when owner_totals[1] = owner_totals[2] then 'tie' else 'winner' end;
  result_row.finalization_basis := case when fixture_kind = 'stable' then 'stable' else 'best_available' end;
  result_row.completed_at := '2026-08-09T12:34:56.123456Z'::timestamptz;
  result_row.frozen_window := pg_catalog.jsonb_build_object(
    'version', 2, 'policy', 'healthcomp.activity-score.v1', 'participants', participants);
  result_row.immutable_hash := private.result_immutable_hash_v1(
    result_row.competition_id, owner_ids[1], owner_totals[1], commitments[1],
    owner_ids[2], owner_totals[2], commitments[2], result_row.outcome,
    result_row.winner_profile_id, result_row.finalization_basis);
  result_row.server_seq := 20;
  return result_row;
end;
$fixture_result$;

create function pg_temp.reset_recovery_fixture(fixture_kind text default null)
returns void language plpgsql
as $reset_fixture$
begin
  truncate public.competition_results, public.competition_change_log,
    public.competitions, public.profiles;
  if fixture_kind is not null then
    insert into public.competitions values ('00000000-0000-0000-0000-000000000001', 21);
    insert into public.competition_change_log
      select '00000000-0000-0000-0000-000000000001'::uuid, ordinal
      from pg_catalog.generate_series(1, 20) ordinal;
    insert into public.profiles values
      ('00000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000012', 'Fixture participant A', 'active', null),
      ('00000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000013', 'Fixture participant B', 'active', null);
    insert into public.competition_results select * from pg_temp.recovery_fixture_result(fixture_kind);
  end if;
end;
$reset_fixture$;

-- Start empty. The assertions first reject an absent/empty query contract.
