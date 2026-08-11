begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(85);

-- Assert the permanent privilege surface before transaction-local grants are
-- added below for policy-level adversarial probes.
select is((
  select count(*)::bigint
  from pg_class table_row
  join pg_namespace schema_row on schema_row.oid = table_row.relnamespace
  where schema_row.nspname = 'public'
    and table_row.relname in (
      'profiles', 'competitions', 'competition_participants',
      'competition_invites', 'competition_change_log',
      'daily_score_revisions', 'participant_finalization_attestations',
      'competition_results', 'competition_awards', 'device_installations',
      'support_events'
    )
    and table_row.relrowsecurity
), 11::bigint, 'all live API tables enforce row-level security');

select isnt(
  has_column_privilege('authenticated', 'public.profiles', 'auth_user_id', 'SELECT'),
  true,
  'the authentication UUID is not a client-readable profile column'
);
select isnt(has_table_privilege('authenticated', 'public.profiles', 'SELECT'), true,
  'profiles has no table-wide SELECT grant that could reveal auth_user_id');
select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public'
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
), 0::bigint, 'authenticated has no direct mutation or schema-control grant');
select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public' and grantee = 'anon'
), 0::bigint, 'anonymous has no API table grants');
select isnt(has_table_privilege('authenticated', 'public.competition_invites', 'SELECT'), true,
  'invites cannot be queried directly by clients');
select isnt(has_table_privilege('authenticated', 'public.competition_change_log', 'SELECT'), true,
  'the raw change log cannot be queried directly by clients');
select isnt(has_table_privilege('authenticated', 'public.support_events', 'SELECT'), true,
  'support events cannot be queried directly by clients');
select ok(has_table_privilege('authenticated', 'public.device_installations', 'SELECT'),
  'authenticated clients receive read access to policy-filtered installations');
select is((
  select count(*)::bigint
  from information_schema.role_table_grants
  where table_schema = 'public'
    and table_name = 'device_installations'
    and grantee = 'authenticated'
    and privilege_type in ('INSERT', 'UPDATE', 'DELETE')
), 0::bigint, 'device installations are client read-only');

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password, created_at, updated_at
) values
  ('41000000-0000-0000-0000-000000000001', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'alice-adversarial@example.invalid', '', now(), now()),
  ('41000000-0000-0000-0000-000000000002', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'bob-adversarial@example.invalid', '', now(), now()),
  ('41000000-0000-0000-0000-000000000003', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mallory-adversarial@example.invalid', '', now(), now()),
  ('41000000-0000-0000-0000-000000000004', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'former-adversarial@example.invalid', '', now(), now()),
  ('41000000-0000-0000-0000-000000000005', '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'mutation-candidate@example.invalid', '', now(), now());

insert into public.profiles (id, auth_user_id, display_name, state) values
  ('42000000-0000-0000-0000-000000000001', '41000000-0000-0000-0000-000000000001', 'Alice', 'active'),
  ('42000000-0000-0000-0000-000000000002', '41000000-0000-0000-0000-000000000002', 'Bob', 'active'),
  ('42000000-0000-0000-0000-000000000003', '41000000-0000-0000-0000-000000000003', 'Mallory', 'active'),
  ('42000000-0000-0000-0000-000000000004', '41000000-0000-0000-0000-000000000004', 'Former', 'active'),
  ('42000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000005', 'Declined', 'active');

insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values
  ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001', 'UTC', current_date,
   'healthcomp.activity-score.v1', 'active', now() + interval '1 day', now() + interval '9 days'),
  ('43000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000001', 'UTC', current_date - 8,
   'healthcomp.activity-score.v1', 'completed', now() + interval '1 day', now() + interval '9 days'),
  ('43000000-0000-0000-0000-000000000003', '42000000-0000-0000-0000-000000000003', null, null,
   'healthcomp.activity-score.v1', 'pending', now() + interval '1 day', null);

insert into public.competition_participants (competition_id, profile_id, role, state) values
  ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
  ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000002', 'invitee', 'accepted'),
  ('43000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000001', 'creator', 'accepted'),
  ('43000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000004', 'invitee', 'anonymized'),
  ('43000000-0000-0000-0000-000000000003', '42000000-0000-0000-0000-000000000003', 'creator', 'accepted'),
  ('43000000-0000-0000-0000-000000000003', '42000000-0000-0000-0000-000000000005', 'invitee', 'declined');

set constraints all immediate;

insert into public.daily_score_revisions (
  competition_id, participant_profile_id, day_ordinal, semantic_event_id,
  client_revision, move_mode, stand_mode, move_basis_points,
  exercise_basis_points, stand_basis_points, accepted_centi_points,
  availability_reason, scoring_policy_identity, wire_content_sha256,
  server_seq, evaluated_at
)
select participant_row.competition_id, participant_row.profile_id, 1,
       'adversarial-score:' || participant_row.profile_id::text, 1,
       'activeEnergyKilocalories', 'standHours', null, null, null, null,
       'missing', 'healthcomp.activity-score.v1',
       private.wire_score_digest_v1(
         participant_row.competition_id, participant_row.profile_id, 1::smallint,
         'activeEnergyKilocalories', 'standHours', null, null, null, null,
         'missing', 'healthcomp.activity-score.v1', 1::bigint
       ), 1, now()
from public.competition_participants participant_row;

insert into public.participant_finalization_attestations (
  competition_id, participant_profile_id, basis, window_commitment_sha256,
  accepted_revisions, server_seq, attested_at
)
select participant_row.competition_id, participant_row.profile_id, 'stable',
       decode(repeat('51', 32), 'hex'), array[1,2,3,4,5,6,7]::bigint[], 1, now()
from public.competition_participants participant_row;

create or replace function pg_temp.adversarial_zero_window(first_profile uuid, second_profile uuid)
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
  ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000002',
   0, 0, null, 'tie', 'stable', now(), pg_temp.adversarial_zero_window('42000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000002'), decode(repeat('61', 32), 'hex'), 1),
  ('43000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000004',
   0, 0, null, 'tie', 'stable', now(), pg_temp.adversarial_zero_window('42000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000004'), decode(repeat('62', 32), 'hex'), 1);

insert into public.competition_awards (competition_id, profile_id, award_type, server_seq, earned_at) values
  ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001', 'completion', 1, now()),
  ('43000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000004', 'completion', 1, now());

insert into public.competition_invites (competition_id, token_digest, expires_at) values
  ('43000000-0000-0000-0000-000000000003', decode(repeat('71', 32), 'hex'), now() + interval '1 day');

insert into public.device_installations (profile_id, apns_token, environment, state) values
  ('42000000-0000-0000-0000-000000000001', repeat('a1', 32), 'sandbox', 'active'),
  ('42000000-0000-0000-0000-000000000002', repeat('b2', 32), 'sandbox', 'active'),
  ('42000000-0000-0000-0000-000000000003', repeat('c3', 32), 'sandbox', 'active');

insert into public.support_events (profile_id, competition_id, kind, code) values
  ('42000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000001', 'sync', 'retry');

update public.profiles
set auth_user_id = null, display_name = 'Former competitor', state = 'anonymized',
    anonymized_at = now(), updated_at = now()
where id = '42000000-0000-0000-0000-000000000004';
delete from auth.users where id = '41000000-0000-0000-0000-000000000004';

-- These grants roll back with the test. They isolate policy behavior from grant
-- behavior and ensure missing policies produce ordinary TAP failures.
grant select (id, display_name, state, anonymized_at, created_at, updated_at)
  on public.profiles to authenticated, anon;
grant all on table
  public.competitions,
  public.competition_participants,
  public.competition_invites,
  public.competition_change_log,
  public.daily_score_revisions,
  public.participant_finalization_attestations,
  public.competition_results,
  public.competition_awards,
  public.device_installations,
  public.support_events
to authenticated, anon;
grant insert, update, delete on public.profiles to authenticated, anon;

create or replace function pg_temp.affected_rows(statement text)
returns bigint
language plpgsql
as $$
declare
  affected bigint;
begin
  execute statement;
  get diagnostics affected = row_count;
  return affected;
end;
$$;
grant usage on schema private to authenticated;
grant execute on function private.wire_score_digest_v1(
  uuid, uuid, smallint, text, text, integer, integer, integer, integer, text, text, bigint
) to authenticated;

set local role anon;
select set_config('request.jwt.claims', '{"role":"anon"}', true);
select is((select count(*)::bigint from public.profiles), 0::bigint, 'anonymous sees zero profiles');
select is((select count(*)::bigint from public.competitions), 0::bigint, 'anonymous sees zero competitions');
select is((select count(*)::bigint from public.competition_participants), 0::bigint, 'anonymous sees zero participant rows');
select is((select count(*)::bigint from public.competition_invites), 0::bigint, 'anonymous sees zero invites');
select is((select count(*)::bigint from public.competition_change_log), 0::bigint, 'anonymous sees zero change-log rows');
select is((select count(*)::bigint from public.daily_score_revisions), 0::bigint, 'anonymous sees zero score revisions');
select is((select count(*)::bigint from public.participant_finalization_attestations), 0::bigint, 'anonymous sees zero attestations');
select is((select count(*)::bigint from public.competition_results), 0::bigint, 'anonymous sees zero results');
select is((select count(*)::bigint from public.competition_awards), 0::bigint, 'anonymous sees zero awards');
select is((select count(*)::bigint from public.device_installations), 0::bigint, 'anonymous sees zero installations');
select is((select count(*)::bigint from public.support_events), 0::bigint, 'anonymous sees zero support events');
reset role;

set local role authenticated;
select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select results_eq(
  $$select id from public.profiles order by id$$,
  $$values
    ('42000000-0000-0000-0000-000000000001'::uuid),
    ('42000000-0000-0000-0000-000000000002'::uuid),
    ('42000000-0000-0000-0000-000000000004'::uuid)$$,
  'Alice sees only herself and current or historical counterparts'
);
select is((select display_name from public.profiles where id = '42000000-0000-0000-0000-000000000004'),
  'Former competitor', 'Alice sees the anonymized historical counterpart only by the safe literal');
select results_eq(
  $$select id from public.competitions order by id$$,
  $$values
    ('43000000-0000-0000-0000-000000000001'::uuid),
    ('43000000-0000-0000-0000-000000000002'::uuid)$$,
  'Alice sees only competitions in which she participates'
);
select is((select count(*)::bigint from public.competition_participants), 4::bigint,
  'Alice sees only participant rows from her two competitions');
select is((select count(*)::bigint from public.daily_score_revisions), 4::bigint,
  'Alice sees only score revisions from her two competitions');
select is((select count(*)::bigint from public.participant_finalization_attestations), 4::bigint,
  'Alice sees only attestations from her two competitions');
select is((select count(*)::bigint from public.competition_results), 2::bigint,
  'Alice sees only results from her two competitions');
select is((select count(*)::bigint from public.competition_awards), 2::bigint,
  'Alice sees only awards from her two competitions');
select results_eq(
  $$select profile_id from public.device_installations order by profile_id$$,
  $$values ('42000000-0000-0000-0000-000000000001'::uuid)$$,
  'Alice sees only her own installation'
);
select is((select count(*)::bigint from public.competition_invites), 0::bigint,
  'Alice cannot query invites directly');
select is((select count(*)::bigint from public.competition_change_log), 0::bigint,
  'Alice cannot query raw change-log rows directly');
select is((select count(*)::bigint from public.support_events), 0::bigint,
  'Alice cannot query support events directly');

select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000002","role":"authenticated"}', true);
select results_eq(
  $$select id from public.profiles order by id$$,
  $$values
    ('42000000-0000-0000-0000-000000000001'::uuid),
    ('42000000-0000-0000-0000-000000000002'::uuid)$$,
  'Bob sees only himself and Alice'
);
select results_eq(
  $$select id from public.competitions order by id$$,
  $$values ('43000000-0000-0000-0000-000000000001'::uuid)$$,
  'Bob sees only the active competition he shares with Alice'
);
select is((select count(*)::bigint from public.competition_participants), 2::bigint,
  'Bob sees only the shared active participant rows');
select is((select count(*)::bigint from public.daily_score_revisions), 2::bigint,
  'Bob sees only the shared active score revisions');
select is((select count(*)::bigint from public.competition_results), 1::bigint,
  'Bob sees only the shared active result');
select is((select count(*)::bigint from public.competition_results where competition_id = '43000000-0000-0000-0000-000000000002'), 0::bigint,
  'Bob cannot see Alice and Former history');
select results_eq(
  $$select profile_id from public.device_installations order by profile_id$$,
  $$values ('42000000-0000-0000-0000-000000000002'::uuid)$$,
  'Bob sees only his own installation'
);

select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000003","role":"authenticated"}', true);
select is((select count(*)::bigint from public.profiles where id in ('42000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000002', '42000000-0000-0000-0000-000000000004')), 0::bigint,
  'Mallory sees zero Alice, Bob, or Former profiles');
select is((select count(*)::bigint from public.competitions where id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated competitions');
select is((select count(*)::bigint from public.competition_participants where competition_id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated participant rows');
select is((select count(*)::bigint from public.daily_score_revisions where competition_id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated score revisions');
select is((select count(*)::bigint from public.participant_finalization_attestations where competition_id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated attestations');
select is((select count(*)::bigint from public.competition_results where competition_id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated results');
select is((select count(*)::bigint from public.competition_awards where competition_id in ('43000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000002')), 0::bigint,
  'Mallory sees zero unrelated awards');
select is((select count(*)::bigint from public.device_installations where profile_id = '42000000-0000-0000-0000-000000000001'), 0::bigint,
  'Mallory sees zero Alice installations');
select is((select count(*)::bigint from public.profiles where id = '42000000-0000-0000-0000-000000000003'), 1::bigint,
  'Mallory can read her own profile');
select is((select count(*)::bigint from public.profiles where id = '42000000-0000-0000-0000-000000000005'), 0::bigint,
  'Mallory cannot read a declined counterpart profile');
select is((select count(*)::bigint from public.competitions where id = '43000000-0000-0000-0000-000000000003'), 1::bigint,
  'Mallory can read her isolated competition');
select is((select count(*)::bigint from public.device_installations where profile_id = '42000000-0000-0000-0000-000000000003'), 1::bigint,
  'Mallory can read her own installation');
select is((select count(*)::bigint from public.competition_invites), 0::bigint,
  'Mallory cannot query her competition invite directly');
select is((select count(*)::bigint from public.competition_change_log), 0::bigint,
  'Mallory cannot query raw change-log rows directly');
select is((select count(*)::bigint from public.support_events), 0::bigint,
  'Mallory cannot query support events directly');

select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000004","role":"authenticated"}', true);
select is((select count(*)::bigint from public.profiles), 0::bigint,
  'a stale Former JWT sees zero profiles after auth detachment');
select is((select count(*)::bigint from public.competitions), 0::bigint,
  'a stale Former JWT sees zero competitions after auth detachment');
select is((select count(*)::bigint from public.competition_participants), 0::bigint,
  'a stale Former JWT sees zero participant rows after auth detachment');
select is((select count(*)::bigint from public.daily_score_revisions), 0::bigint,
  'a stale Former JWT sees zero score revisions after auth detachment');
select is((select count(*)::bigint from public.participant_finalization_attestations), 0::bigint,
  'a stale Former JWT sees zero attestations after auth detachment');
select is((select count(*)::bigint from public.competition_results), 0::bigint,
  'a stale Former JWT sees zero results after auth detachment');
select is((select count(*)::bigint from public.competition_awards), 0::bigint,
  'a stale Former JWT sees zero awards after auth detachment');
select is((select count(*)::bigint from public.device_installations), 0::bigint,
  'a stale Former JWT sees zero installations after auth detachment');
select is((select count(*)::bigint from public.competition_invites), 0::bigint,
  'a stale Former JWT sees zero invites after auth detachment');
select is((select count(*)::bigint from public.competition_change_log), 0::bigint,
  'a stale Former JWT sees zero change-log rows after auth detachment');
select is((select count(*)::bigint from public.support_events), 0::bigint,
  'a stale Former JWT sees zero support events after auth detachment');

select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000005","role":"authenticated"}', true);
select is((select count(*)::bigint from public.competitions), 0::bigint,
  'an active identity with only declined membership sees zero competitions');
select is((select count(*)::bigint from public.daily_score_revisions), 0::bigint,
  'an active identity with only declined membership sees zero score revisions');
select is((select count(*)::bigint from public.participant_finalization_attestations), 0::bigint,
  'an active identity with only declined membership sees zero attestations');

select set_config('request.jwt.claims', '{"sub":"41000000-0000-0000-0000-000000000001","role":"authenticated"}', true);
select throws_ok(
  $$insert into public.profiles (id, auth_user_id, display_name, state)
    values ('42000000-0000-0000-0000-000000000005', '41000000-0000-0000-0000-000000000005', 'Injected', 'active')$$,
  '42501', null, 'Alice cannot directly insert a profile');
select is(pg_temp.affected_rows(
  $$update public.profiles set display_name = 'Tampered' where id = '42000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly update her profile');
select is(pg_temp.affected_rows(
  $$delete from public.profiles where id = '42000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly delete her profile');
select throws_ok(
  $$insert into public.competitions (id, creator_profile_id, scoring_policy_identity, lifecycle, invitation_expires_at)
    values ('43000000-0000-0000-0000-000000000099', '42000000-0000-0000-0000-000000000001', 'healthcomp.activity-score.v1', 'pending', now() + interval '1 day')$$,
  '42501', null, 'Alice cannot directly insert a competition');
select is(pg_temp.affected_rows(
  $$update public.competitions set lifecycle = 'cancelled' where id = '43000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly update a competition');
select is(pg_temp.affected_rows(
  $$delete from public.competitions where id = '43000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly delete a competition');
select throws_ok(
  $$insert into public.competition_participants (competition_id, profile_id, role, state)
    values ('43000000-0000-0000-0000-000000000003', '42000000-0000-0000-0000-000000000002', 'invitee', 'pending')$$,
  '42501', null, 'Alice cannot directly insert participant membership');
select throws_ok(
  $$insert into public.daily_score_revisions (
      competition_id, participant_profile_id, day_ordinal, semantic_event_id,
      client_revision, move_mode, stand_mode, availability_reason,
      scoring_policy_identity, wire_content_sha256, server_seq, evaluated_at
    ) values (
      '43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001',
      2, 'client-injected-score', 1, 'activeEnergyKilocalories', 'standHours',
      'missing', 'healthcomp.activity-score.v1',
      private.wire_score_digest_v1(
        '43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001',
        2::smallint, 'activeEnergyKilocalories', 'standHours', null, null, null, null,
        'missing', 'healthcomp.activity-score.v1', 1::bigint
      ), 1, now()
    )$$,
  '42501', null, 'Alice cannot directly insert a score revision');
select is(pg_temp.affected_rows(
  $$update public.competition_results set finalization_basis = 'best_available'
    where competition_id = '43000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly update a result');
select throws_ok(
  $$insert into public.competition_awards (competition_id, profile_id, award_type, server_seq, earned_at)
    values ('43000000-0000-0000-0000-000000000001', '42000000-0000-0000-0000-000000000001', 'client_award', 1, now())$$,
  '42501', null, 'Alice cannot directly create an award');
select throws_ok(
  $$insert into public.device_installations (profile_id, apns_token, environment, state)
    values ('42000000-0000-0000-0000-000000000001', repeat('d4', 32), 'sandbox', 'active')$$,
  '42501', null, 'Alice cannot directly register an installation');
select is(pg_temp.affected_rows(
  $$update public.device_installations set state = 'revoked'
    where profile_id = '42000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly update her installation');
select is(pg_temp.affected_rows(
  $$delete from public.device_installations
    where profile_id = '42000000-0000-0000-0000-000000000001'$$
), 0::bigint, 'Alice cannot directly delete her installation');
select throws_ok(
  $$insert into public.competition_invites (competition_id, token_digest, expires_at)
    values ('43000000-0000-0000-0000-000000000003', decode(repeat('72', 32), 'hex'), now() + interval '1 day')$$,
  '42501', null, 'Alice cannot directly create an invite');
select throws_ok(
  $$insert into public.competition_change_log (competition_id, server_seq, change_kind, entity_id)
    values ('43000000-0000-0000-0000-000000000001', 9999, 'client_injected', '42000000-0000-0000-0000-000000000001')$$,
  '42501', null, 'Alice cannot directly inject a change-log row');
select throws_ok(
  $$insert into public.support_events (profile_id, competition_id, kind, code)
    values ('42000000-0000-0000-0000-000000000001', '43000000-0000-0000-0000-000000000001', 'client', 'injected')$$,
  '42501', null, 'Alice cannot directly create a support event');
reset role;

select * from finish();
rollback;
