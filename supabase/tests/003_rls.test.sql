begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(47);

-- The policy helpers are deliberately checked through the catalogs so this RED
-- test remains valid before the migration creates them.
select has_function('private', 'current_profile_id', array[]::text[],
  'current_profile_id helper exists');
select ok(coalesce((
  select procedure_row.prosecdef
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'current_profile_id'
    and procedure_row.pronargs = 0
), false), 'current_profile_id is security definer');
select ok(coalesce((
  select 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'current_profile_id'
    and procedure_row.pronargs = 0
), false), 'current_profile_id has an empty search path');

select has_function('private', 'is_competition_participant', array['uuid'],
  'is_competition_participant helper exists');
select ok(coalesce((
  select procedure_row.prosecdef
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'is_competition_participant'
    and pg_get_function_identity_arguments(procedure_row.oid) = 'target_competition_id uuid'
), false), 'is_competition_participant is security definer');
select ok(coalesce((
  select 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'is_competition_participant'
    and pg_get_function_identity_arguments(procedure_row.oid) = 'target_competition_id uuid'
), false), 'is_competition_participant has an empty search path');

select has_function('private', 'can_view_profile', array['uuid'],
  'can_view_profile helper exists');
select ok(coalesce((
  select procedure_row.prosecdef
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'can_view_profile'
    and procedure_row.pronargs = 1
), false), 'can_view_profile is security definer');
select ok(coalesce((
  select 'search_path=""' = any(coalesce(procedure_row.proconfig, array[]::text[]))
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'can_view_profile'
    and procedure_row.pronargs = 1
), false), 'can_view_profile has an empty search path');

select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'current_profile_id'
    and procedure_row.pronargs = 0
), false), 'authenticated may execute current_profile_id');
select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'is_competition_participant'
    and procedure_row.pronargs = 1
), false), 'authenticated may execute is_competition_participant');
select ok(coalesce((
  select has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'can_view_profile'
    and procedure_row.pronargs = 1
), false), 'authenticated may execute can_view_profile');
select isnt(coalesce((
  select has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
  from pg_proc procedure_row
  join pg_namespace schema_row on schema_row.oid = procedure_row.pronamespace
  where schema_row.nspname = 'private'
    and procedure_row.proname = 'current_profile_id'
    and procedure_row.pronargs = 0
), false), true, 'anonymous users cannot execute current_profile_id');

select isnt(has_table_privilege('authenticated', 'public.profiles', 'SELECT'), true,
  'profiles never has a table-wide SELECT grant');
select ok(has_column_privilege('authenticated', 'public.profiles', 'id', 'SELECT'),
  'authenticated may select the stable profile id');
select is((
  select array_agg(column_name::text order by column_name)
  from information_schema.column_privileges
  where table_schema = 'public'
    and table_name = 'profiles'
    and grantee = 'authenticated'
    and privilege_type = 'SELECT'
), array['display_name', 'id']::text[],
  'counterpart-readable profiles expose only stable identity and safe display text');
select isnt(has_column_privilege('authenticated', 'public.profiles', 'auth_user_id', 'SELECT'), true,
  'authenticated cannot select auth_user_id');
select ok(has_table_privilege('authenticated', 'public.competitions', 'SELECT'),
  'authenticated may select authorized competitions');
select ok(has_table_privilege('authenticated', 'public.competition_participants', 'SELECT'),
  'authenticated may select authorized participant rows');
select ok(has_table_privilege('authenticated', 'public.daily_score_revisions', 'SELECT'),
  'authenticated may select authorized score revisions');
select ok(has_table_privilege('authenticated', 'public.participant_finalization_attestations', 'SELECT'),
  'authenticated may select authorized attestations');
select ok(has_table_privilege('authenticated', 'public.competition_results', 'SELECT'),
  'authenticated may select authorized results');
select ok(has_table_privilege('authenticated', 'public.competition_awards', 'SELECT'),
  'authenticated may select authorized awards');
select ok(has_table_privilege('authenticated', 'public.device_installations', 'SELECT'),
  'authenticated may select only their installation rows');
select isnt(has_table_privilege('authenticated', 'public.competition_invites', 'SELECT'), true,
  'competition invites have no direct client read grant');
select isnt(has_table_privilege('authenticated', 'public.competition_change_log', 'SELECT'), true,
  'the raw change log has no direct client read grant');
select isnt(has_table_privilege('authenticated', 'public.support_events', 'SELECT'), true,
  'support events have no direct client read grant');
select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
), 0::bigint, 'authenticated has no direct mutation or schema-control grants');
select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'anon'
), 0::bigint, 'anonymous has no table grants');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  ('10000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alice@example.invalid', '', now(), now()),
  ('10000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob@example.invalid', '', now(), now()),
  ('10000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mallory@example.invalid', '', now(), now()),
  ('10000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'former@example.invalid', '', now(), now());

insert into public.profiles (id, auth_user_id, display_name, state) values
  ('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'Alice', 'active'),
  ('10000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000002', 'Bob', 'active'),
  ('10000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'Mallory', 'active'),
  ('10000000-0000-0000-0000-000000000004', '10000000-0000-0000-0000-000000000004', 'Former', 'active');

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'UTC', current_date,
   'healthcomp.activity-score.v1', 'active', now() + interval '1 day', now() + interval '9 days'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'UTC', current_date - 8,
   'healthcomp.activity-score.v1', 'completed', now() + interval '1 day', now() + interval '9 days'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', null, null,
   'healthcomp.activity-score.v1', 'pending', now() + interval '1 day', null);

insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002', 'invitee', 'accepted'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004', 'invitee', 'anonymized'),
  ('20000000-0000-0000-0000-000000000003', '10000000-0000-0000-0000-000000000003', 'creator', 'accepted');

set constraints all immediate;

insert into public.daily_score_revisions (
  competition_id, participant_profile_id, day_ordinal, semantic_event_id,
  client_revision, move_mode, stand_mode, move_basis_points,
  exercise_basis_points, stand_basis_points, accepted_centi_points,
  availability_reason, scoring_policy_identity, wire_content_sha256,
  server_seq, evaluated_at
)
select participant_row.competition_id, participant_row.profile_id, 1,
       'score:' || participant_row.profile_id::text, 1,
       'activeEnergyKilocalories', 'standHours', null, null, null, null,
       'missing', 'healthcomp.activity-score.v1',
       private.wire_score_digest_v1(
         participant_row.competition_id, participant_row.profile_id, 1::smallint,
         'activeEnergyKilocalories', 'standHours', null, null, null, null,
         'missing', 'healthcomp.activity-score.v1', 1::bigint
       ), 1, now()
from public.competition_participants participant_row
where participant_row.competition_id in (
  '20000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002'
);

insert into public.participant_finalization_attestations (
  competition_id, participant_profile_id, basis, window_commitment_sha256,
  accepted_revisions, server_seq, attested_at
)
select participant_row.competition_id, participant_row.profile_id, 'stable',
       decode(repeat('11', 32), 'hex'), array[1,2,3,4,5,6,7]::bigint[], 1, now()
from public.competition_participants participant_row
where participant_row.competition_id in (
  '20000000-0000-0000-0000-000000000001',
  '20000000-0000-0000-0000-000000000002'
);

create or replace function pg_temp.zero_window(first_profile uuid, second_profile uuid)
returns jsonb language sql stable as $$
  select jsonb_build_object(
    'version', 1,
    'participants', jsonb_build_array(
      jsonb_build_object('profile_id', first_profile, 'days', (
        select jsonb_agg(jsonb_build_object('ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing') order by ordinal)
        from generate_series(1, 7) ordinal
      )),
      jsonb_build_object('profile_id', second_profile, 'days', (
        select jsonb_agg(jsonb_build_object('ordinal', ordinal, 'status', 'unavailable', 'reason', 'missing') order by ordinal)
        from generate_series(1, 7) ordinal
      ))
    )
  );
$$;

insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002',
   0, 0, null, 'tie', 'stable', now(), pg_temp.zero_window('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000002'), decode(repeat('21', 32), 'hex'), 1),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004',
   0, 0, null, 'tie', 'stable', now(), pg_temp.zero_window('10000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000004'), decode(repeat('22', 32), 'hex'), 1);

insert into public.competition_awards (
  competition_id, profile_id, award_type, server_seq, earned_at
) values
  ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'completion', 1, now()),
  ('20000000-0000-0000-0000-000000000002', '10000000-0000-0000-0000-000000000004', 'completion', 1, now());

insert into public.competition_invites (
  competition_id, token_digest, expires_at
) values
  ('20000000-0000-0000-0000-000000000003', decode(repeat('31', 32), 'hex'), now() + interval '1 day');

insert into public.device_installations (profile_id, apns_token, environment, state) values
  ('10000000-0000-0000-0000-000000000001', repeat('a1', 32), 'sandbox', 'active'),
  ('10000000-0000-0000-0000-000000000002', repeat('b2', 32), 'sandbox', 'active'),
  ('10000000-0000-0000-0000-000000000003', repeat('c3', 32), 'sandbox', 'active');

insert into public.support_events (profile_id, competition_id, kind, code) values
  ('10000000-0000-0000-0000-000000000001', '20000000-0000-0000-0000-000000000001', 'sync', 'retry');

update public.profiles
set auth_user_id = null, display_name = 'Former competitor', state = 'anonymized',
    anonymized_at = now(), updated_at = now()
where id = '10000000-0000-0000-0000-000000000004';

-- Transaction-local grants let the policy behavior fail as TAP assertions on
-- the pre-migration schema instead of aborting on the foundation's revokes.
grant select (id, display_name, state, anonymized_at, created_at, updated_at)
  on public.profiles to authenticated, anon;
grant select on table
  public.competitions,
  public.competition_participants,
  public.daily_score_revisions,
  public.participant_finalization_attestations,
  public.competition_results,
  public.competition_awards,
  public.device_installations
to authenticated, anon;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select count(*)::bigint from public.profiles), 0::bigint,
  'anonymous sees no profiles even when SELECT is temporarily granted');
select is((select count(*)::bigint from public.competitions), 0::bigint,
  'anonymous sees no competitions even when SELECT is temporarily granted');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select results_eq(
  $$select id from public.profiles order by id$$,
  $$values
    ('10000000-0000-0000-0000-000000000001'::uuid),
    ('10000000-0000-0000-0000-000000000002'::uuid),
    ('10000000-0000-0000-0000-000000000004'::uuid)$$,
  'Alice sees only self and shared active or historical counterparts');
select results_eq(
  $$select id from public.competitions order by id$$,
  $$values
    ('20000000-0000-0000-0000-000000000001'::uuid),
    ('20000000-0000-0000-0000-000000000002'::uuid)$$,
  'Alice sees only competitions in which she participates');
select is((select count(*)::bigint from public.competition_participants), 4::bigint,
  'Alice sees participant rows only for her competitions');
select is((select count(*)::bigint from public.daily_score_revisions), 4::bigint,
  'Alice sees score revisions only for her competitions');
select is((select count(*)::bigint from public.participant_finalization_attestations), 4::bigint,
  'Alice sees attestations only for her competitions');
select is((select count(*)::bigint from public.competition_results), 2::bigint,
  'Alice sees results only for her competitions');
select is((select count(*)::bigint from public.competition_awards), 2::bigint,
  'Alice sees awards only for her competitions');
select results_eq(
  $$select profile_id from public.device_installations order by profile_id$$,
  $$values ('10000000-0000-0000-0000-000000000001'::uuid)$$,
  'Alice sees only her own installation');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select results_eq(
  $$select id from public.profiles order by id$$,
  $$values
    ('10000000-0000-0000-0000-000000000001'::uuid),
    ('10000000-0000-0000-0000-000000000002'::uuid)$$,
  'Bob sees only self and Alice');
select results_eq(
  $$select id from public.competitions order by id$$,
  $$values ('20000000-0000-0000-0000-000000000001'::uuid)$$,
  'Bob cannot see Alice historical competitions that do not include him');
select is((select count(*)::bigint from public.daily_score_revisions), 2::bigint,
  'Bob sees only score revisions for the shared competition');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select results_eq(
  $$select id from public.profiles order by id$$,
  $$values ('10000000-0000-0000-0000-000000000003'::uuid)$$,
  'Mallory cannot enumerate unrelated profiles');
select results_eq(
  $$select id from public.competitions order by id$$,
  $$values ('20000000-0000-0000-0000-000000000003'::uuid)$$,
  'Mallory sees only her pending competition');
select is((select count(*)::bigint from public.daily_score_revisions), 0::bigint,
  'Mallory cannot enumerate unrelated score revisions');

select set_config('request.jwt.claims', '{"sub":"10000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is((select count(*)::bigint from public.profiles), 0::bigint,
  'a stale JWT for an anonymized former participant sees no profiles');
select is((select count(*)::bigint from public.competitions), 0::bigint,
  'a stale JWT for an anonymized former participant sees no competitions');
reset role;

select * from finish();
rollback;
