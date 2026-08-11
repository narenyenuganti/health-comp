begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(15);

select is(
  (
    select count(*)::bigint
    from pg_class table_row
    join pg_namespace schema_row on schema_row.oid = table_row.relnamespace
    where schema_row.nspname = 'public'
      and table_row.relkind = 'r'
      and table_row.relname in (
        'profiles', 'competitions', 'competition_participants', 'competition_invites',
        'competition_change_log', 'daily_score_revisions',
        'participant_finalization_attestations', 'competition_results',
        'competition_awards', 'device_installations', 'support_events'
      )
      and table_row.relrowsecurity
  ),
  11::bigint,
  'every live table starts RLS-enabled and deny-by-default'
);

select is(
  (
    select count(*)::bigint
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in (
        'profiles', 'competitions', 'competition_participants', 'competition_invites',
        'competition_change_log', 'daily_score_revisions',
        'participant_finalization_attestations', 'competition_results',
        'competition_awards', 'device_installations', 'support_events'
      )
      and grantee in ('anon', 'authenticated')
      and privilege_type <> 'SELECT'
  ),
  0::bigint,
  'API roles receive no direct non-read table privileges'
);

select is(
  (
    select count(*)::bigint
    from information_schema.role_table_grants
    where table_schema = 'public'
      and table_name in (
        'profiles', 'competitions', 'competition_participants', 'competition_invites',
        'competition_change_log', 'daily_score_revisions',
        'participant_finalization_attestations', 'competition_results',
        'competition_awards', 'device_installations', 'support_events'
      )
      and grantee in ('anon', 'authenticated', 'service_role')
      and privilege_type in ('TRUNCATE', 'REFERENCES', 'TRIGGER')
  ),
  0::bigint,
  'RLS-bypassing and schema-control table privileges are revoked from every API role'
);

select isnt(
  has_column_privilege('authenticated', 'public.profiles', 'auth_user_id', 'SELECT'),
  true,
  'counterpart-facing profile access can never expose the authentication UUID column'
);

select is(
  (
    select count(*)::bigint
    from pg_constraint constraint_row
    join pg_class source_table on source_table.oid = constraint_row.conrelid
    join pg_namespace source_schema on source_schema.oid = source_table.relnamespace
    where constraint_row.contype = 'f'
      and source_schema.nspname = 'public'
      and source_table.relname in (
        'competition_participants', 'competition_invites', 'competition_change_log',
        'daily_score_revisions', 'participant_finalization_attestations',
        'competition_results', 'competition_awards'
      )
      and constraint_row.confrelid = 'public.competitions'::regclass
      and constraint_row.confdeltype = 'c'
  ),
  0::bigint,
  'durable competition history uses restrictive foreign keys instead of impossible cascades'
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'a@example.invalid', '', now(), now()),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'b@example.invalid', '', now(), now()),
  ('00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'former@example.invalid', '', now(), now());

insert into public.profiles (id, auth_user_id, display_name, state) values
  ('00000000-0000-0000-0000-000000000201', '00000000-0000-0000-0000-000000000201', 'A', 'active'),
  ('00000000-0000-0000-0000-000000000202', '00000000-0000-0000-0000-000000000202', 'B', 'active'),
  ('00000000-0000-0000-0000-000000000203', '00000000-0000-0000-0000-000000000203', 'Former', 'active');

insert into public.competitions (
  id, creator_profile_id, scoring_policy_identity, lifecycle, invitation_expires_at
) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000201', 'healthcomp.activity-score.v1', 'pending', now() + interval '1 day'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000201', 'healthcomp.activity-score.v1', 'pending', now() + interval '1 day'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000201', 'healthcomp.activity-score.v1', 'pending', now() + interval '1 day'),
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000201', 'healthcomp.activity-score.v1', 'pending', now() + interval '1 day');

insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000201', 'creator', 'accepted'),
  ('20000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000202', 'invitee', 'accepted'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000201', 'creator', 'accepted'),
  ('20000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000202', 'invitee', 'accepted'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000201', 'creator', 'accepted'),
  ('20000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000202', 'invitee', 'accepted'),
  ('20000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000201', 'creator', 'accepted');

set constraints all immediate;

update public.competitions
set lifecycle = 'active',
    time_zone_identifier = 'UTC',
    start_day = current_date,
    best_available_deadline = invitation_expires_at + interval '8 days',
    updated_at = now()
where id = '20000000-0000-0000-0000-000000000003';

create or replace function pg_temp.window_100_0()
returns jsonb
language sql
immutable
as $$
  select '{"version":1,"participants":[{"profile_id":"00000000-0000-0000-0000-000000000201","days":[{"ordinal":1,"status":"points","centi_points":100},{"ordinal":2,"status":"unavailable","reason":"missing"},{"ordinal":3,"status":"unavailable","reason":"missing"},{"ordinal":4,"status":"unavailable","reason":"missing"},{"ordinal":5,"status":"unavailable","reason":"missing"},{"ordinal":6,"status":"unavailable","reason":"missing"},{"ordinal":7,"status":"unavailable","reason":"missing"}]},{"profile_id":"00000000-0000-0000-0000-000000000202","days":[{"ordinal":1,"status":"unavailable","reason":"missing"},{"ordinal":2,"status":"unavailable","reason":"missing"},{"ordinal":3,"status":"unavailable","reason":"missing"},{"ordinal":4,"status":"unavailable","reason":"missing"},{"ordinal":5,"status":"unavailable","reason":"missing"},{"ordinal":6,"status":"unavailable","reason":"missing"},{"ordinal":7,"status":"unavailable","reason":"missing"}]}]}'::jsonb;
$$;

select throws_ok(
  $$
    insert into public.competition_results (
      competition_id, participant_a_profile_id, participant_b_profile_id,
      participant_a_total_centi_points, participant_b_total_centi_points,
      winner_profile_id, outcome, finalization_basis, completed_at,
      frozen_window, immutable_hash, server_seq
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000201',
      '00000000-0000-0000-0000-000000000202',
      100, 0, null, 'tie', 'stable', now(), pg_temp.window_100_0(),
      decode(repeat('11', 32), 'hex'), 0
    )
  $$,
  '23514',
  null,
  'unequal totals cannot be persisted as a tie'
);

select throws_ok(
  $$
    insert into public.competition_results (
      competition_id, participant_a_profile_id, participant_b_profile_id,
      participant_a_total_centi_points, participant_b_total_centi_points,
      winner_profile_id, outcome, finalization_basis, completed_at,
      frozen_window, immutable_hash, server_seq
    ) values (
      '20000000-0000-0000-0000-000000000002',
      '00000000-0000-0000-0000-000000000201',
      '00000000-0000-0000-0000-000000000202',
      100, 0, '00000000-0000-0000-0000-000000000202', 'winner', 'stable',
      now(), pg_temp.window_100_0(), decode(repeat('22', 32), 'hex'), 0
    )
  $$,
  '23514',
  null,
  'the lower-scoring participant cannot be persisted as the winner'
);

select throws_ok(
  $$
    update public.competition_participants
    set competition_id = '20000000-0000-0000-0000-000000000004'
    where competition_id = '20000000-0000-0000-0000-000000000003'
      and profile_id = '00000000-0000-0000-0000-000000000202'
  $$,
  '55000',
  'competition participant identity is immutable',
  'participant membership cannot move between competition histories'
);

select throws_ok(
  $$
    delete from public.competition_participants
    where competition_id = '20000000-0000-0000-0000-000000000003'
      and profile_id = '00000000-0000-0000-0000-000000000201'
  $$,
  '55000',
  'competition participant history is append-only',
  'participant membership cannot be deleted from history'
);

update public.profiles
set state = 'anonymized', auth_user_id = null,
    display_name = 'Former competitor', anonymized_at = now(), updated_at = now()
where id = '00000000-0000-0000-0000-000000000203';

select throws_ok(
  $$
    update public.profiles
    set state = 'active',
        auth_user_id = '00000000-0000-0000-0000-000000000203',
        display_name = 'Reattached', anonymized_at = null, updated_at = now()
    where id = '00000000-0000-0000-0000-000000000203'
  $$,
  '23514',
  'anonymized profile state is terminal',
  'anonymized durable identities cannot be reattached to authentication'
);

select throws_ok(
  $$
    insert into public.participant_finalization_attestations (
      competition_id, participant_profile_id, basis, window_commitment_sha256,
      accepted_revisions, server_seq, attested_at
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000201', 'stable',
      decode(repeat('33', 32), 'hex'), array[1, 2, 3, null, 5, 6, 7]::bigint[],
      0, now()
    )
  $$,
  '23514',
  null,
  'accepted revision sets cannot contain null revisions'
);

select throws_ok(
  $$
    insert into public.participant_finalization_attestations (
      competition_id, participant_profile_id, basis, window_commitment_sha256,
      accepted_revisions, server_seq, attested_at
    ) values (
      '20000000-0000-0000-0000-000000000001',
      '00000000-0000-0000-0000-000000000202', 'stable',
      decode(repeat('44', 32), 'hex'), array[[1],[2],[3],[4],[5],[6],[7]]::bigint[],
      0, now()
    )
  $$,
  '23514',
  null,
  'accepted revision sets must be one-dimensional'
);

select isnt(
  private.is_valid_frozen_window_v1(
    jsonb_set(pg_temp.window_100_0(), '{version}', '"1"'::jsonb),
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000202', 100, 0
  ),
  true,
  'frozen result version is a JSON number, never a numeric-looking string'
);

select isnt(
  private.is_valid_frozen_window_v1(
    jsonb_set(pg_temp.window_100_0(), '{participants,0,days,0,ordinal}', '"1"'::jsonb),
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000202', 100, 0
  ),
  true,
  'frozen result ordinals are JSON numbers, never numeric-looking strings'
);

select isnt(
  private.is_valid_frozen_window_v1(
    jsonb_set(pg_temp.window_100_0(), '{participants,0,days,0,centi_points}', '"100"'::jsonb),
    '00000000-0000-0000-0000-000000000201',
    '00000000-0000-0000-0000-000000000202', 100, 0
  ),
  true,
  'frozen result points are JSON numbers, never numeric-looking strings'
);

select * from finish();
rollback;
