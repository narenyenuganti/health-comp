begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(22);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'owner@example.invalid', '', now(), now()),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'opponent@example.invalid', '', now(), now()),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'third@example.invalid', '', now(), now());

insert into public.profiles (id, auth_user_id, display_name, state) values
  ('00000000-0000-0000-0000-000000000101', '00000000-0000-0000-0000-000000000101', 'Owner', 'active'),
  ('00000000-0000-0000-0000-000000000102', '00000000-0000-0000-0000-000000000102', 'Opponent', 'active'),
  ('00000000-0000-0000-0000-000000000103', '00000000-0000-0000-0000-000000000103', 'Third', 'active');

insert into public.competitions (
  id, creator_profile_id, scoring_policy_identity, lifecycle, invitation_expires_at
) values (
  '10000000-0000-0000-0000-000000000001',
  '00000000-0000-0000-0000-000000000101',
  'healthcomp.activity-score.v1',
  'pending',
  now() + interval '1 day'
);

insert into public.competition_participants (
  competition_id, profile_id, role, state
) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000101', 'creator', 'accepted'),
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000102', 'invitee', 'accepted');

set constraints all immediate;

select is(
  (select next_server_seq from public.competitions where id = '10000000-0000-0000-0000-000000000001'),
  3::bigint,
  'participant inserts allocate the first two per-competition sequence values'
);

select is(
  (select pg_catalog.array_agg(server_seq order by server_seq) from public.competition_change_log),
  array[1, 2]::bigint[],
  'participant changes are durably cursor-addressable'
);

select is(
  private.allocate_competition_server_seq(
    '10000000-0000-0000-0000-000000000001',
    'test_change',
    '10000000-0000-0000-0000-000000000001',
    now()
  ),
  3::bigint,
  'allocator returns the next locked row-counter value'
);

create or replace function pg_temp.allocate_then_fail(target_id uuid)
returns void
language plpgsql
as $$
begin
  perform private.allocate_competition_server_seq(target_id, 'rolled_back', target_id, now());
  raise exception 'intentional rollback probe';
end;
$$;

select throws_ok(
  $$select pg_temp.allocate_then_fail('10000000-0000-0000-0000-000000000001')$$,
  'P0001',
  'intentional rollback probe',
  'failed transactions roll back sequence allocation and change rows'
);

select is(
  private.allocate_competition_server_seq(
    '10000000-0000-0000-0000-000000000001',
    'after_rollback',
    '10000000-0000-0000-0000-000000000001',
    now()
  ),
  4::bigint,
  'rolled-back sequence values are reused without a cursor gap'
);

select is(
  (select pg_catalog.array_agg(server_seq order by server_seq) from public.competition_change_log),
  array[1, 2, 3, 4]::bigint[],
  'committed change rows remain contiguous'
);

select throws_ok(
  $$
    insert into public.competition_participants (competition_id, profile_id, role, state)
    values (
      '10000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000103',
      'invitee',
      'accepted'
    )
  $$,
  '23505',
  null,
  'a competition cannot add a duplicate role or third participant'
);

select throws_ok(
  $$
    update public.profiles
    set state = 'anonymized'
    where id = '00000000-0000-0000-0000-000000000102'
  $$,
  '23514',
  null,
  'anonymization cannot retain authentication identity or display name'
);

select lives_ok(
  $$
    update public.profiles
    set state = 'anonymized',
        auth_user_id = null,
        display_name = 'Former competitor',
        anonymized_at = now(),
        updated_at = now()
    where id = '00000000-0000-0000-0000-000000000102'
  $$,
  'a fully detached anonymized profile is accepted'
);

select lives_ok(
  $$delete from auth.users where id = '00000000-0000-0000-0000-000000000102'$$,
  'auth deletion succeeds after durable identity anonymization'
);

select is(
  (select display_name from public.profiles where id = '00000000-0000-0000-0000-000000000102'),
  'Former competitor',
  'anonymized history has only the safe literal display name'
);

select is(
  (select count(*)::bigint from public.competitions where id = '10000000-0000-0000-0000-000000000001'),
  1::bigint,
  'auth deletion preserves shared competition history'
);

select lives_ok(
  $$
    insert into public.daily_score_revisions (
      competition_id, participant_profile_id, day_ordinal, semantic_event_id,
      client_revision, move_mode, stand_mode, move_basis_points,
      exercise_basis_points, stand_basis_points, accepted_centi_points,
      availability_reason, scoring_policy_identity, wire_content_sha256,
      server_seq, evaluated_at
    ) values (
      '10000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000101',
      1, 'score-day-1-revision-1', 1, 'activeEnergyKilocalories', 'standHours',
      10000, 5000, 12500, 27500, 'available', 'healthcomp.activity-score.v1',
      private.wire_score_digest_v1(
        '10000000-0000-0000-0000-000000000001',
        '00000000-0000-0000-0000-000000000101',
        1::smallint, 'activeEnergyKilocalories', 'standHours', 10000, 5000, 12500,
        27500, 'available', 'healthcomp.activity-score.v1', 1::bigint
      ),
      0, now()
    )
  $$,
  'a bounded available score revision is accepted and sequenced'
);

select throws_ok(
  $$update public.daily_score_revisions set accepted_centi_points = 1$$,
  '55000',
  'daily_score_revisions is append-only',
  'accepted score revisions cannot be updated'
);

select throws_ok(
  $$
    insert into public.daily_score_revisions (
      competition_id, participant_profile_id, day_ordinal, semantic_event_id,
      client_revision, move_mode, stand_mode, move_basis_points,
      exercise_basis_points, stand_basis_points, accepted_centi_points,
      availability_reason, scoring_policy_identity, wire_content_sha256,
      server_seq, evaluated_at
    ) values (
      '10000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000101',
      2, 'invalid-over-cap', 1, 'activeEnergyKilocalories', 'standHours',
      20001, 0, 0, 20001, 'available', 'healthcomp.activity-score.v1',
      decode(repeat('00', 32), 'hex'), 0, now()
    )
  $$,
  '23514',
  null,
  'wire percentages above 200 percent are rejected'
);

select is(
  private.allocate_competition_server_seq(
    '10000000-0000-0000-0000-000000000001',
    'after_failed_score',
    '10000000-0000-0000-0000-000000000001',
    now()
  ),
  7::bigint,
  'a rejected score does not consume its attempted sequence value'
);

select throws_ok(
  $$update public.competition_change_log set change_kind = 'rewritten' where server_seq = 1$$,
  '55000',
  'competition_change_log is append-only',
  'cursor history cannot be rewritten'
);

select is(
  (select wire_digest_version from public.daily_score_revisions where semantic_event_id = 'score-day-1-revision-1'),
  1::smallint,
  'accepted revisions persist their wire digest version'
);

select is(
  (select server_seq from public.daily_score_revisions where semantic_event_id = 'score-day-1-revision-1'),
  6::bigint,
  'entity rows reference the exact sequence allocated by their change row'
);

select ok(
  private.is_valid_frozen_window_v1(
    '{"version":1,"participants":[{"profile_id":"00000000-0000-0000-0000-000000000101","days":[{"ordinal":1,"status":"points","centi_points":100},{"ordinal":2,"status":"unavailable","reason":"missing"},{"ordinal":3,"status":"unavailable","reason":"missing"},{"ordinal":4,"status":"unavailable","reason":"missing"},{"ordinal":5,"status":"unavailable","reason":"missing"},{"ordinal":6,"status":"unavailable","reason":"missing"},{"ordinal":7,"status":"unavailable","reason":"missing"}]},{"profile_id":"00000000-0000-0000-0000-000000000102","days":[{"ordinal":1,"status":"unavailable","reason":"missing"},{"ordinal":2,"status":"unavailable","reason":"missing"},{"ordinal":3,"status":"unavailable","reason":"missing"},{"ordinal":4,"status":"unavailable","reason":"missing"},{"ordinal":5,"status":"unavailable","reason":"missing"},{"ordinal":6,"status":"unavailable","reason":"missing"},{"ordinal":7,"status":"unavailable","reason":"missing"}]}]}'::jsonb,
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000102',
    100,
    0
  ),
  'frozen result windows accept exactly two seven-day privacy-safe ledgers'
);

select isnt(
  private.is_valid_frozen_window_v1(
    '{"version":1,"raw_value":1,"participants":[]}'::jsonb,
    '00000000-0000-0000-0000-000000000101',
    '00000000-0000-0000-0000-000000000102',
    0,
    0
  ),
  true,
  'frozen result windows reject extra raw-value keys and malformed ledgers'
);

select throws_ok(
  $$
    insert into public.daily_score_revisions (
      competition_id, participant_profile_id, day_ordinal, semantic_event_id,
      client_revision, move_mode, stand_mode, move_basis_points,
      exercise_basis_points, stand_basis_points, accepted_centi_points,
      availability_reason, scoring_policy_identity, wire_content_sha256,
      server_seq, evaluated_at
    ) values (
      '10000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000101',
      3, 'wrong-wire-digest', 1, 'activeEnergyKilocalories', 'standHours',
      10000, 5000, 12500, 27500, 'available', 'healthcomp.activity-score.v1',
      decode(repeat('00', 32), 'hex'), 0, now()
    )
  $$,
  '23514',
  null,
  'accepted score rows must match the canonical wire digest of their approved fields'
);

select * from finish();
rollback;
