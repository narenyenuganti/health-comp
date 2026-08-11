begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(26);

select columns_are(
  'public', 'profiles',
  array['id', 'auth_user_id', 'display_name', 'state', 'anonymized_at', 'created_at', 'updated_at']::name[],
  'profiles exposes only approved columns'
);

select columns_are(
  'public', 'competitions',
  array['id', 'creator_profile_id', 'time_zone_identifier', 'start_day', 'scoring_policy_identity', 'lifecycle', 'invitation_expires_at', 'best_available_deadline', 'rematch_parent_id', 'next_server_seq', 'created_at', 'updated_at']::name[],
  'competitions exposes only approved columns'
);

select columns_are(
  'public', 'competition_participants',
  array['competition_id', 'profile_id', 'role', 'state', 'joined_at', 'updated_at']::name[],
  'competition participants expose only approved columns'
);

select columns_are(
  'public', 'competition_invites',
  array['id', 'competition_id', 'token_digest', 'claimed_profile_id', 'consumed_at', 'expires_at', 'created_at']::name[],
  'competition invites expose only approved columns'
);

select columns_are(
  'public', 'daily_score_revisions',
  array['id', 'competition_id', 'participant_profile_id', 'day_ordinal', 'semantic_event_id', 'client_revision', 'move_mode', 'stand_mode', 'move_basis_points', 'exercise_basis_points', 'stand_basis_points', 'accepted_centi_points', 'availability_reason', 'scoring_policy_identity', 'wire_digest_version', 'wire_content_sha256', 'server_seq', 'evaluated_at', 'received_at']::name[],
  'daily score revisions expose only approved quantized columns'
);

select columns_are(
  'public', 'participant_finalization_attestations',
  array['id', 'competition_id', 'participant_profile_id', 'basis', 'window_commitment_sha256', 'accepted_revisions', 'server_seq', 'attested_at', 'semantic_event_id', 'attestation_version']::name[],
  'finalization attestations expose only approved columns'
);

select columns_are(
  'public', 'competition_results',
  array['competition_id', 'participant_a_profile_id', 'participant_b_profile_id', 'participant_a_total_centi_points', 'participant_b_total_centi_points', 'winner_profile_id', 'outcome', 'finalization_basis', 'completed_at', 'frozen_window', 'immutable_hash', 'server_seq']::name[],
  'competition results expose only approved columns'
);

select columns_are(
  'public', 'competition_awards',
  array['id', 'competition_id', 'profile_id', 'award_type', 'server_seq', 'earned_at']::name[],
  'competition awards expose only approved columns'
);

select columns_are(
  'public', 'device_installations',
  array['id', 'profile_id', 'apns_token', 'environment', 'state', 'created_at', 'updated_at']::name[],
  'device installations expose only approved columns'
);

select columns_are(
  'public', 'support_events',
  array['id', 'profile_id', 'competition_id', 'kind', 'code', 'created_at']::name[],
  'support events expose only approved columns'
);

select columns_are(
  'public', 'competition_change_log',
  array['competition_id', 'server_seq', 'change_kind', 'entity_id', 'occurred_at']::name[],
  'change log exposes only cursor metadata'
);

select is(
  (
    select count(*)::bigint
    from information_schema.columns
    where table_schema = 'public'
      and table_name in (
        'profiles', 'competitions', 'competition_participants', 'competition_invites',
        'daily_score_revisions', 'participant_finalization_attestations',
        'competition_results', 'competition_awards', 'device_installations',
        'support_events', 'competition_change_log'
      )
      and lower(column_name) ~ '(heart_rate|workout|route|location|sample|raw_health|health_metric|activity_value|goal_value)'
  ),
  0::bigint,
  'live tables contain no prohibited Health data columns'
);

select ok(
  exists (
    select 1
    from pg_constraint
    where conrelid = 'public.profiles'::regclass
      and contype = 'c'
      and conname = 'profiles_identity_state_check'
      and pg_get_constraintdef(oid) like '%Former competitor%'
      and pg_get_constraintdef(oid) like '%auth_user_id IS NULL%'
  ),
  'anonymized profiles are irreversibly detached and use the literal safe display name'
);

select ok(
  exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.competition_participants'::regclass
      and not tgisinternal
      and tgdeferrable
      and tginitdeferred
  ),
  'the two-participant invariant uses a deferred constraint trigger'
);

select col_type_is('public', 'daily_score_revisions', 'move_basis_points', 'integer', 'Move uses integer basis points');
select col_type_is('public', 'daily_score_revisions', 'accepted_centi_points', 'integer', 'scores use integer centi-points');
select col_type_is('public', 'daily_score_revisions', 'wire_content_sha256', 'bytea', 'wire content identity is a digest');
select col_type_is('public', 'daily_score_revisions', 'server_seq', 'bigint', 'score cursor sequence is a bigint');

select is(
  encode(
    private.wire_score_digest_v1(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      1::smallint,
      'activeEnergyKilocalories',
      'standHours',
      10000,
      5000,
      12500,
      27500,
      'available',
      'healthcomp.activity-score.v1',
      7
    ),
    'hex'
  ),
  '37df3f48a20b0b6e042e2450241af9c84ec7696ee505b97d9052dc201afb7fd9',
  'wire digest v1 has a cross-language golden vector'
);

select is(
  encode(
    private.wire_score_content_v1(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      1::smallint,
      'activeEnergyKilocalories',
      'standHours',
      10000,
      5000,
      12500,
      27500,
      'available',
      'healthcomp.activity-score.v1',
      7
    ),
    'hex'
  ),
  '6865616c7468636f6d702d776972652d73636f72652d7631000100000010000000000000000000000000000000010200000010000000000000000000000000000000020300000004000000010400000018616374697665456e657267794b696c6f63616c6f72696573050000000a7374616e64486f7572730600000004000027100700000004000013880800000004000030d4090000000400006b6c0a00000009617661696c61626c650b0000001c6865616c7468636f6d702e61637469766974792d73636f72652e76310c000000080000000000000007',
  'wire digest bytes use tagged UInt32-length-delimited big-endian fields'
);

select is(
  encode(
    private.wire_score_digest_v1(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      2::smallint,
      'activeEnergyKilocalories',
      'standHours',
      null,
      null,
      null,
      null,
      'sourceDataUnavailable',
      'healthcomp.activity-score.v1',
      8
    ),
    'hex'
  ),
  '9ae1b056c0a331f571d6e906b43051d36f47020187b9729e9048f4666fe81660',
  'unavailable wire digest uses the frozen null encoding'
);

select is(
  encode(
    private.wire_score_content_v1(
      '00000000-0000-0000-0000-000000000001'::uuid,
      '00000000-0000-0000-0000-000000000002'::uuid,
      2::smallint,
      'activeEnergyKilocalories',
      'standHours',
      null,
      null,
      null,
      null,
      'sourceDataUnavailable',
      'healthcomp.activity-score.v1',
      8
    ),
    'hex'
  ),
  '6865616c7468636f6d702d776972652d73636f72652d7631000100000010000000000000000000000000000000010200000010000000000000000000000000000000020300000004000000020400000018616374697665456e657267794b696c6f63616c6f72696573050000000a7374616e64486f75727306ffffffff07ffffffff08ffffffff09ffffffff0a00000015736f7572636544617461556e617661696c61626c650b0000001c6865616c7468636f6d702e61637469766974792d73636f72652e76310c000000080000000000000008',
  'unavailable numeric fields use UInt32 max length and no payload'
);

select is(
  (
    select count(*)::bigint
    from pg_constraint constraint_row
    join pg_class source_table on source_table.oid = constraint_row.conrelid
    join pg_namespace source_schema on source_schema.oid = source_table.relnamespace
    where constraint_row.contype = 'f'
      and constraint_row.confrelid = 'auth.users'::regclass
      and source_schema.nspname = 'public'
      and not (source_schema.nspname = 'public' and source_table.relname = 'profiles')
  ),
  0::bigint,
  'only profiles.auth_user_id may reference auth.users'
);

select is(
  (
    select count(*)::bigint
    from pg_trigger
    where tgrelid in (
      'public.daily_score_revisions'::regclass,
      'public.participant_finalization_attestations'::regclass,
      'public.competition_results'::regclass,
      'public.competition_awards'::regclass,
      'public.competition_change_log'::regclass
    )
      and not tgisinternal
      and tgname like 'reject_%_mutation'
  ),
  5::bigint,
  'evidence, results, awards, and cursor rows are append-only'
);

select ok(
  to_regprocedure('private.allocate_competition_server_seq(uuid,text,uuid,timestamptz)') is not null,
  'server sequence allocator is transactionally row-counter based'
);

select ok(
  (
    select count(*) >= 5
    from pg_constraint
    where conrelid = 'public.daily_score_revisions'::regclass
      and contype = 'c'
  ),
  'daily score revisions constrain ordinals, versions, modes, bounds, and availability shape'
);

select * from finish();
rollback;
