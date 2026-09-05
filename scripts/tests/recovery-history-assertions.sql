-- Synthetic assertions against the actual query exposed by the assembler as
-- pg_temp.recovery_history_receipt(receipt jsonb). No query implementation lives here.
create function pg_temp.recovery_assert(assertion_ok boolean, assertion_label text)
returns void language plpgsql
as $assert$
begin
  if assertion_ok is not true then
    raise exception 'recovery_history_assertion: %', assertion_label;
  end if;
end;
$assert$;

create function pg_temp.assert_recovery_receipt(
  assertion_label text, expected_counts jsonb default '{}'::jsonb
)
returns jsonb language plpgsql
as $assert_receipt$
declare
  actual jsonb;
  row_count bigint;
  receipt_keys text[];
  count_key text;
  digest_key text;
  expected jsonb := '{
    "competitions_checked":0,"competitions_invalid_sequence":0,
    "change_rows_total":0,"change_rows_orphaned":0,"results_total":0,
    "results_format2_checked":0,"results_format2_invalid":0,
    "results_legacy_unverified":0,"results_unsupported":0
  }'::jsonb || expected_counts;
begin
  perform pg_temp.recovery_assert((
    select pg_catalog.count(*) = 1
      and pg_catalog.bool_and(attname = 'receipt' and atttypid = 'jsonb'::pg_catalog.regtype)
    from pg_catalog.pg_attribute
    where attrelid = 'pg_temp.recovery_history_receipt'::pg_catalog.regclass
      and attnum > 0 and not attisdropped
  ), 'receipt_column_contract');
  select pg_catalog.count(*) into row_count from pg_temp.recovery_history_receipt;
  perform pg_temp.recovery_assert(row_count = 1, 'receipt_row_contract');
  select receipt into strict actual from pg_temp.recovery_history_receipt;
  perform pg_temp.recovery_assert(pg_catalog.jsonb_typeof(actual) = 'object', 'receipt_object_contract');
  select pg_catalog.array_agg(key order by key) into receipt_keys
    from pg_catalog.jsonb_object_keys(actual) key;
  perform pg_temp.recovery_assert(receipt_keys = array[
    'aggregate_complete_result_fingerprint', 'aggregate_stored_result_hash',
    'change_rows_orphaned', 'change_rows_total', 'competitions_checked',
    'competitions_invalid_sequence', 'receipt_version', 'results_format2_checked',
    'results_format2_invalid', 'results_legacy_unverified', 'results_total', 'results_unsupported'
  ], 'receipt_key_allowlist');
  perform pg_temp.recovery_assert(pg_catalog.jsonb_typeof(actual->'receipt_version') = 'number'
    and actual->>'receipt_version' = '1', 'receipt_version_contract');
  for count_key in select key from pg_catalog.jsonb_object_keys(expected) key loop
    perform pg_temp.recovery_assert(pg_catalog.jsonb_typeof(actual->count_key) = 'number'
      and actual->>count_key ~ '^(0|[1-9][0-9]*)$', 'receipt_count_type_contract');
    perform pg_temp.recovery_assert(actual->count_key = expected->count_key, assertion_label);
  end loop;
  foreach digest_key in array array['aggregate_stored_result_hash', 'aggregate_complete_result_fingerprint'] loop
    perform pg_temp.recovery_assert(pg_catalog.jsonb_typeof(actual->digest_key) = 'string'
      and actual->>digest_key ~ '^[0-9a-f]{64}$', 'receipt_digest_type_contract');
  end loop;
  perform pg_temp.recovery_assert(
    (actual->>'results_format2_checked')::bigint
      + (actual->>'results_legacy_unverified')::bigint
      + (actual->>'results_unsupported')::bigint = (actual->>'results_total')::bigint
    and (actual->>'results_format2_invalid')::bigint <= (actual->>'results_format2_checked')::bigint
    and (actual->>'competitions_invalid_sequence')::bigint <= (actual->>'competitions_checked')::bigint
    and (actual->>'change_rows_orphaned')::bigint <= (actual->>'change_rows_total')::bigint,
    'receipt_aggregate_accounting');
  return actual;
end;
$assert_receipt$;

do $recovery_history_cases$
declare
  baseline jsonb;
  observed jsonb;
  other_zone jsonb;
  result_counts jsonb := '{"competitions_checked":1,"change_rows_total":20,"results_total":1,"results_format2_checked":1}'::jsonb;
  invalid_counts jsonb := result_counts || '{"results_format2_invalid":1}'::jsonb;
  original public.competition_results;
  changed public.competition_results;
  fixture_kind text;
  field_name text;
  column_names text[];
  column_types text[];
  mutation integer;
  expected_invalid integer;
  malformed jsonb;
  original_window jsonb;
begin
  -- Keep the fixture's complete row shape tied to source; omitted constraints are intentional.
  select pg_catalog.array_agg(attname::text order by attnum),
    pg_catalog.array_agg(pg_catalog.format_type(atttypid, atttypmod) order by attnum)
  into column_names, column_types
  from pg_catalog.pg_attribute
  where attrelid = 'public.competition_results'::pg_catalog.regclass and attnum > 0 and not attisdropped;
  perform pg_temp.recovery_assert(column_names = array[
    'competition_id','participant_a_profile_id','participant_b_profile_id',
    'participant_a_total_centi_points','participant_b_total_centi_points',
    'winner_profile_id','outcome','finalization_basis','completed_at','frozen_window','immutable_hash','server_seq'
  ] and column_types = array[
    'uuid','uuid','uuid','integer','integer','uuid','text','text',
    'timestamp with time zone','jsonb','bytea','bigint'
  ], 'complete_result_fixture_shape');

  baseline := pg_temp.assert_recovery_receipt('empty_input');
  perform pg_temp.recovery_assert(baseline->>'aggregate_stored_result_hash'
    = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855', 'empty_stored_hash');

  foreach fixture_kind in array array['missing', 'stable', 'mixed'] loop
    perform pg_temp.reset_recovery_fixture(fixture_kind);
    observed := pg_temp.assert_recovery_receipt('supported_window_family', result_counts);
    select * into strict original from public.competition_results;
    perform pg_temp.recovery_assert(private.is_valid_frozen_window_v2(
      original.frozen_window, original.competition_id, original.participant_a_profile_id,
      original.participant_b_profile_id, original.participant_a_total_centi_points,
      original.participant_b_total_centi_points), 'fixture_real_window_contract');
    perform pg_temp.recovery_assert(observed->>'aggregate_stored_result_hash'
      = pg_catalog.encode(extensions.digest(pg_catalog.encode(original.immutable_hash, 'hex'), 'sha256'), 'hex'),
      'single_result_stored_hash_comparison');
    if fixture_kind = 'missing' then
      -- Same fixture identities and fourteen deadline-missing days as the existing SQL/Swift golden.
      perform pg_temp.recovery_assert(pg_catalog.encode(original.immutable_hash, 'hex')
        = '3013a48c4f2de0a28b34ba9c43a456893963c21a74ab2ef9ffffa452571ef78c', 'existing_cross_language_result_golden');
    end if;
  end loop;

  perform pg_temp.reset_recovery_fixture('missing');
  baseline := pg_temp.assert_recovery_receipt('before_anonymization', result_counts);
  update public.profiles set auth_user_id = null, display_name = 'Former competitor',
    state = 'anonymized', anonymized_at = '2026-08-10T00:00:00Z'
    where id = '00000000-0000-0000-0000-000000000002';
  observed := pg_temp.assert_recovery_receipt('anonymized_result_remains_included', result_counts);
  perform pg_temp.recovery_assert(observed = baseline, 'anonymization_preserves_result_receipt');

  -- Every stored result column must affect the independent complete-row fingerprint.
  -- Timestamp and top-level sequence are intentionally outside the established hash.
  foreach field_name in array column_names loop
    perform pg_temp.reset_recovery_fixture('missing');
    baseline := pg_temp.assert_recovery_receipt('fingerprint_before_mutation', result_counts);
    select * into strict original from public.competition_results;
    changed := original;
    expected_invalid := 1;
    case field_name
      when 'competition_id' then changed.competition_id := '00000000-0000-0000-0000-000000000004';
      when 'participant_a_profile_id' then changed.participant_a_profile_id := '00000000-0000-0000-0000-000000000004';
      when 'participant_b_profile_id' then changed.participant_b_profile_id := '00000000-0000-0000-0000-000000000004';
      when 'participant_a_total_centi_points' then changed.participant_a_total_centi_points := 1;
      when 'participant_b_total_centi_points' then changed.participant_b_total_centi_points := 1;
      when 'winner_profile_id' then changed.winner_profile_id := original.participant_a_profile_id;
      when 'outcome' then changed.outcome := 'winner';
      when 'finalization_basis' then changed.finalization_basis := 'stable';
      when 'completed_at' then
        changed.completed_at := original.completed_at + interval '1 microsecond'; expected_invalid := 0;
      when 'frozen_window' then changed.frozen_window := pg_catalog.jsonb_set(original.frozen_window, '{policy}', '"wrong"');
      when 'immutable_hash' then changed.immutable_hash := pg_catalog.decode(repeat('00', 32), 'hex');
      when 'server_seq' then changed.server_seq := 19; expected_invalid := 0;
      else raise exception 'recovery_fixture_column_unhandled';
    end case;
    delete from public.competition_results;
    insert into public.competition_results select (changed).*;
    observed := pg_temp.assert_recovery_receipt('mutated_result_column',
      result_counts || pg_catalog.jsonb_build_object('results_format2_invalid', expected_invalid));
    perform pg_temp.recovery_assert(observed->>'aggregate_complete_result_fingerprint'
      <> baseline->>'aggregate_complete_result_fingerprint', 'complete_fingerprint_covers_column');
    if field_name <> 'immutable_hash' then
      perform pg_temp.recovery_assert(observed->>'aggregate_stored_result_hash'
        = baseline->>'aggregate_stored_result_hash', 'stored_hash_preservation_is_not_complete_fingerprint');
    end if;
  end loop;

  -- Frozen-content failures must be classified, not thrown away by unsafe casts or null predicates.
  perform pg_temp.reset_recovery_fixture('stable');
  select frozen_window into original_window from public.competition_results;
  for mutation in 1..18 loop
    malformed := original_window;
    case mutation
      when 1 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,centi_points}', '601');
      when 2 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,window_commitment_sha256}', pg_catalog.to_jsonb(repeat('00', 32)));
      when 3 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,extra}', 'true');
      when 4 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,client_revision}', '1');
      when 5 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,server_seq}', '1');
      when 6 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,wire_content_sha256}', '1');
      when 7 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,scoring_policy_identity}', '1');
      when 8 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,ordinal}', '"1"');
      when 9 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,client_revision}', '"not-an-integer"');
      when 10 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,server_seq}', '"999999999999999999999999999999"');
      when 11 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,profile_id}', '"not-a-uuid"');
      when 12 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,window_commitment_sha256}', '"not-hex"');
      when 13 then malformed := pg_catalog.jsonb_set(malformed, '{participants}', 'null');
      when 14 then malformed := pg_catalog.jsonb_set(malformed, '{participants}', '{}');
      when 15 then malformed := malformed - 'policy';
      when 16 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,centi_points}', 'null');
      when 17 then malformed := pg_catalog.jsonb_set(malformed, '{participants}', pg_catalog.jsonb_build_array(
        original_window->'participants'->1, original_window->'participants'->0));
      when 18 then malformed := pg_catalog.jsonb_set(malformed, '{participants,0,days,0,source}', '"deadline_missing"');
    end case;
    update public.competition_results set frozen_window = malformed;
    perform pg_temp.assert_recovery_receipt('malformed_frozen_content', invalid_counts);
  end loop;

  -- The historical validator uses a nullable text comparison for missing reason.
  -- A JSON null must not inherit the hardcoded commitment value "missing".
  perform pg_temp.reset_recovery_fixture('missing');
  update public.competition_results set frozen_window = pg_catalog.jsonb_set(
    frozen_window, '{participants,0,days,0,reason}', 'null');
  perform pg_temp.assert_recovery_receipt('deadline_missing_reason_must_be_explicit', invalid_counts);

  -- Necessary frozen-content rule only; this does not prove historical attestations.
  perform pg_temp.reset_recovery_fixture('missing');
  update public.competition_results set finalization_basis = 'stable',
    immutable_hash = private.result_immutable_hash_v1(
      competition_id, participant_a_profile_id, participant_a_total_centi_points,
      pg_catalog.decode(frozen_window->'participants'->0->>'window_commitment_sha256', 'hex'),
      participant_b_profile_id, participant_b_total_centi_points,
      pg_catalog.decode(frozen_window->'participants'->1->>'window_commitment_sha256', 'hex'),
      outcome, winner_profile_id, 'stable');
  perform pg_temp.assert_recovery_receipt('stable_cannot_contain_deadline_missing_days', invalid_counts);

  for mutation in 1..9 loop
    perform pg_temp.reset_recovery_fixture('missing');
    case mutation
      when 1 then update public.competition_results set participant_a_profile_id = null;
      when 2 then update public.competition_results set participant_b_total_centi_points = null;
      when 3 then update public.competition_results set completed_at = null;
      when 4 then update public.competition_results set completed_at = 'infinity';
      when 5 then update public.competition_results set completed_at = '-infinity';
      when 6 then update public.competition_results set server_seq = null;
      when 7 then update public.competition_results set server_seq = 0;
      when 8 then update public.competition_results set immutable_hash = null;
      when 9 then update public.competition_results set finalization_basis = null;
    end case;
    perform pg_temp.assert_recovery_receipt('invalid_result_scalar', invalid_counts);
  end loop;

  -- Historical format 1 is structurally representable but has no derived hash rule.
  perform pg_temp.reset_recovery_fixture('missing');
  select * into strict original from public.competition_results;
  update public.competition_results set frozen_window = pg_catalog.jsonb_build_object(
    'version', 1, 'participants', (
      select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object('profile_id', participant->'profile_id', 'days', (
        select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
          'ordinal', day->'ordinal', 'status', 'unavailable', 'reason', 'missing') order by ordinal)
        from pg_catalog.jsonb_array_elements(participant->'days') with ordinality as day_entry(day, ordinal)
      )) order by ordinal)
      from pg_catalog.jsonb_array_elements(original.frozen_window->'participants') with ordinality as entry(participant, ordinal)
    )), immutable_hash = pg_catalog.decode(repeat('b7', 32), 'hex');
  baseline := pg_temp.assert_recovery_receipt('legacy_is_unverified',
    result_counts || '{"results_format2_checked":0,"results_legacy_unverified":1}'::jsonb);
  update public.competition_results set immutable_hash = pg_catalog.decode(repeat('b8', 32), 'hex');
  observed := pg_temp.assert_recovery_receipt('legacy_hash_not_reinterpreted',
    result_counts || '{"results_format2_checked":0,"results_legacy_unverified":1}'::jsonb);
  perform pg_temp.recovery_assert(observed->>'aggregate_stored_result_hash' <> baseline->>'aggregate_stored_result_hash'
    and observed->>'aggregate_complete_result_fingerprint' <> baseline->>'aggregate_complete_result_fingerprint',
    'legacy_values_remain_in_preservation_comparison');

  for mutation in 1..7 loop
    perform pg_temp.reset_recovery_fixture('missing');
    case mutation
      when 1 then update public.competition_results set frozen_window = pg_catalog.jsonb_set(frozen_window, '{version}', '3');
      when 2 then update public.competition_results set frozen_window = pg_catalog.jsonb_set(frozen_window, '{version}', '"2"');
      when 3 then update public.competition_results set frozen_window = pg_catalog.jsonb_set(frozen_window, '{version}', 'null');
      when 4 then update public.competition_results set frozen_window = frozen_window - 'version';
      when 5 then update public.competition_results set frozen_window = null;
      when 6 then update public.competition_results set frozen_window = '[]';
      when 7 then update public.competition_results set frozen_window = pg_catalog.jsonb_set(frozen_window, '{version}', '"1"');
    end case;
    perform pg_temp.assert_recovery_receipt('unsupported_version',
      result_counts || '{"results_format2_checked":0,"results_unsupported":1}'::jsonb);
  end loop;

  perform pg_temp.reset_recovery_fixture('missing');
  insert into public.competition_results select * from pg_temp.recovery_fixture_result('stable', '00000000-0000-0000-0000-000000000004');
  update public.competition_results set immutable_hash = pg_catalog.decode(repeat('00', 32), 'hex')
    where competition_id = '00000000-0000-0000-0000-000000000004';
  insert into public.competition_results select * from pg_temp.recovery_fixture_result('missing', '00000000-0000-0000-0000-000000000005');
  update public.competition_results set frozen_window = '{"version":1}'
    where competition_id = '00000000-0000-0000-0000-000000000005';
  insert into public.competition_results select * from pg_temp.recovery_fixture_result('missing', '00000000-0000-0000-0000-000000000006');
  update public.competition_results set frozen_window = '{"version":99}'
    where competition_id = '00000000-0000-0000-0000-000000000006';
  baseline := pg_temp.assert_recovery_receipt('mixed_result_accounting', result_counts || '{
    "results_total":4,"results_format2_checked":2,"results_format2_invalid":1,
    "results_legacy_unverified":1,"results_unsupported":1}'::jsonb);
  perform pg_catalog.set_config('TimeZone', 'Pacific/Kiritimati', true);
  observed := pg_temp.assert_recovery_receipt('timezone_independent_receipt', result_counts || '{
    "results_total":4,"results_format2_checked":2,"results_format2_invalid":1,
    "results_legacy_unverified":1,"results_unsupported":1}'::jsonb);
  perform pg_catalog.set_config('TimeZone', 'America/Los_Angeles', true);
  other_zone := pg_temp.assert_recovery_receipt('second_timezone_independent_receipt', result_counts || '{
    "results_total":4,"results_format2_checked":2,"results_format2_invalid":1,
    "results_legacy_unverified":1,"results_unsupported":1}'::jsonb);
  perform pg_temp.recovery_assert(baseline = observed and observed = other_zone, 'binary_timestamp_fingerprint');
  perform pg_catalog.set_config('TimeZone', 'UTC', true);
  perform pg_catalog.set_config('bytea_output', 'escape', true);
  select receipt into strict observed from pg_temp.recovery_history_receipt;
  perform pg_temp.recovery_assert(observed = baseline, 'binary_hash_rendering_independent_fingerprint');
  perform pg_catalog.set_config('bytea_output', 'hex', true);
  create temporary table recovery_result_order_copy as select * from public.competition_results;
  delete from public.competition_results;
  insert into public.competition_results select * from recovery_result_order_copy order by competition_id desc;
  observed := pg_temp.assert_recovery_receipt('row_order_independent_receipt', result_counts || '{
    "results_total":4,"results_format2_checked":2,"results_format2_invalid":1,
    "results_legacy_unverified":1,"results_unsupported":1}'::jsonb);
  perform pg_temp.recovery_assert(observed = baseline, 'deterministic_aggregate_order');

  -- Sequence shapes are tested independently of result constraints and row fingerprints.
  perform pg_temp.reset_recovery_fixture();
  insert into public.competitions values ('00000000-0000-0000-0000-000000000001', 1);
  perform pg_temp.assert_recovery_receipt('empty_competition_checked', '{"competitions_checked":1}');
  update public.competitions set next_server_seq = 2;
  perform pg_temp.assert_recovery_receipt('empty_cursor_invalid', '{"competitions_checked":1,"competitions_invalid_sequence":1}');
  update public.competitions set next_server_seq = null;
  perform pg_temp.assert_recovery_receipt('null_empty_cursor_invalid', '{"competitions_checked":1,"competitions_invalid_sequence":1}');

  for mutation in 0..8 loop
    perform pg_temp.reset_recovery_fixture();
    insert into public.competitions values ('00000000-0000-0000-0000-000000000001', 4);
    insert into public.competition_change_log select '00000000-0000-0000-0000-000000000001'::uuid, ordinal
      from pg_catalog.generate_series(1, 3) ordinal;
    case mutation
      when 0 then null;
      when 1 then delete from public.competition_change_log where server_seq = 2;
      when 2 then insert into public.competition_change_log values ('00000000-0000-0000-0000-000000000001', 2);
      when 3 then delete from public.competition_change_log where server_seq = 1;
      when 4 then update public.competitions set next_server_seq = 5;
      when 5 then update public.competition_change_log set server_seq = 0 where server_seq = 1;
      when 6 then
        -- The remaining non-null prefix is valid: null rows must not disappear from validation.
        update public.competition_change_log set server_seq = null where server_seq = 3;
        update public.competitions set next_server_seq = 3;
      when 7 then update public.competitions set next_server_seq = null;
      when 8 then
        -- Count, minimum, maximum, and cursor still agree; distinctness must be checked too.
        update public.competition_change_log set server_seq = 1 where server_seq = 2;
    end case;
    perform pg_temp.assert_recovery_receipt('sequence_shape', pg_catalog.jsonb_build_object(
      'competitions_checked', 1, 'competitions_invalid_sequence', case when mutation = 0 then 0 else 1 end,
      'change_rows_total', case when mutation in (1, 3) then 2 when mutation = 2 then 4 else 3 end));
  end loop;
  perform pg_temp.reset_recovery_fixture();
  insert into public.competitions values
    ('00000000-0000-0000-0000-000000000001', 1), ('00000000-0000-0000-0000-000000000004', 2);
  insert into public.competition_change_log values
    ('00000000-0000-0000-0000-000000000005', 1), (null, 1);
  perform pg_temp.assert_recovery_receipt('all_parents_and_orphan_rows',
    '{"competitions_checked":2,"competitions_invalid_sequence":1,"change_rows_total":2,"change_rows_orphaned":2}');
  perform pg_temp.reset_recovery_fixture();
  perform pg_temp.assert_recovery_receipt('empty_input_is_only_empty_evidence');
end;
$recovery_history_cases$;
