begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
set local timezone = 'UTC';
select no_plan();

select has_function(
  'public', 'nudge_competition_participant', array['uuid'],
  'nudge RPC exists'
);
select ok(coalesce((
  select p.prosecdef
    and 'search_path=""' = any(coalesce(p.proconfig, array[]::text[]))
    and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname = 'nudge_competition_participant'
    and p.proargtypes = '2950'::oidvector
), false), 'nudge RPC is a narrow authenticated definer function');

-- Ana nudges. Ben has two installations, Cal none, Dee one (muted Ana before),
-- Eve one (mutes Ana after a nudge is queued).
insert into auth.users (id) values
  ('e7000000-0000-4000-8000-000000000001'), ('e7000000-0000-4000-8000-000000000002'),
  ('e7000000-0000-4000-8000-000000000003'), ('e7000000-0000-4000-8000-000000000004'),
  ('e7000000-0000-4000-8000-000000000005');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('e7100000-0000-4000-8000-000000000001', 'e7000000-0000-4000-8000-000000000001', 'Ana', 'active'),
  ('e7100000-0000-4000-8000-000000000002', 'e7000000-0000-4000-8000-000000000002', 'Ben', 'active'),
  ('e7100000-0000-4000-8000-000000000003', 'e7000000-0000-4000-8000-000000000003', 'Cal', 'active'),
  ('e7100000-0000-4000-8000-000000000004', 'e7000000-0000-4000-8000-000000000004', 'Dee', 'active'),
  ('e7100000-0000-4000-8000-000000000005', 'e7000000-0000-4000-8000-000000000005', 'Eve', 'active');
insert into public.device_installations (profile_id, installation_id, apns_token, environment, state) values
  ('e7100000-0000-4000-8000-000000000002', 'e7300000-0000-4000-8000-000000000021', repeat('b1', 32), 'sandbox', 'active'),
  ('e7100000-0000-4000-8000-000000000002', 'e7300000-0000-4000-8000-000000000022', repeat('b2', 32), 'sandbox', 'active'),
  ('e7100000-0000-4000-8000-000000000004', 'e7300000-0000-4000-8000-000000000041', repeat('d1', 32), 'sandbox', 'active'),
  ('e7100000-0000-4000-8000-000000000005', 'e7300000-0000-4000-8000-000000000051', repeat('e1', 32), 'sandbox', 'active');
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('e7100000-0000-4000-8000-000000000004', 'e7100000-0000-4000-8000-000000000001');

delete from vault.secrets
where name in ('healthcomp_notification_worker_url', 'healthcomp_notification_worker_token');
select vault.create_secret(
  'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/send-competition-notification',
  'healthcomp_notification_worker_url');
select vault.create_secret(repeat('w', 43), 'healthcomp_notification_worker_token');

-- Matches (all 'scheduled' on the server, phase by date in UTC):
--   …01 live, Ben uploaded 2 h ago       …02 live, Ben uploaded 13 h ago
--   …03 live, Ben never uploaded         …04 starts tomorrow
--   …05 tallying, deadline tomorrow      …06 tallying, deadline passed
--   …07 live, result stored              …08 live vs Cal (no device)
--   …09 live vs Dee (muted)              …0a live vs Eve
create function pg_temp.match(suffix text, opponent uuid, first_day date, deadline timestamptz)
returns uuid language plpgsql as $$
declare
  target uuid := ('e7200000-0000-4000-8000-0000000000' || suffix)::uuid;
begin
  insert into public.competitions (
    id, creator_profile_id, time_zone_identifier, start_day,
    scoring_policy_identity, lifecycle, invitation_expires_at,
    best_available_deadline
  ) values (
    target, 'e7100000-0000-4000-8000-000000000001', 'UTC', first_day,
    'healthcomp.activity-score.v1', 'scheduled', now() - interval '10 days', deadline
  );
  insert into public.competition_participants (competition_id, profile_id, role, state) values
    (target, 'e7100000-0000-4000-8000-000000000001', 'creator', 'accepted'),
    (target, opponent, 'invitee', 'accepted');
  return target;
end;
$$;
create function pg_temp.seed_revision(target uuid, participant uuid, received timestamptz, revision bigint)
returns void language sql as $$
  insert into public.daily_score_revisions (
    competition_id, participant_profile_id, day_ordinal, semantic_event_id,
    client_revision, move_mode, stand_mode, move_basis_points,
    exercise_basis_points, stand_basis_points, accepted_centi_points,
    availability_reason, scoring_policy_identity, wire_content_sha256,
    server_seq, evaluated_at, received_at
  ) values (
    target, participant, 1, 'score:' || participant::text || ':' || revision::text,
    revision, 'activeEnergyKilocalories', 'standHours', null, null, null, null,
    'missing', 'healthcomp.activity-score.v1',
    private.wire_score_digest_v1(
      target, participant, 1::smallint, 'activeEnergyKilocalories', 'standHours',
      null, null, null, null, 'missing', 'healthcomp.activity-score.v1', revision
    ), 1, received, received
  );
$$;

select pg_temp.match('01', 'e7100000-0000-4000-8000-000000000002', current_date - 2, now() + interval '9 days');
select pg_temp.match('02', 'e7100000-0000-4000-8000-000000000002', current_date - 2, now() + interval '9 days');
select pg_temp.match('03', 'e7100000-0000-4000-8000-000000000002', current_date - 2, now() + interval '9 days');
select pg_temp.match('04', 'e7100000-0000-4000-8000-000000000002', current_date + 1, now() + interval '9 days');
select pg_temp.match('05', 'e7100000-0000-4000-8000-000000000002', current_date - 8, now() + interval '1 day');
select pg_temp.match('06', 'e7100000-0000-4000-8000-000000000002', current_date - 8, now() - interval '1 hour');
select pg_temp.match('07', 'e7100000-0000-4000-8000-000000000002', current_date - 2, now() + interval '9 days');
select pg_temp.match('08', 'e7100000-0000-4000-8000-000000000003', current_date - 2, now() + interval '9 days');
select pg_temp.match('09', 'e7100000-0000-4000-8000-000000000004', current_date - 2, now() + interval '9 days');
select pg_temp.match('0a', 'e7100000-0000-4000-8000-000000000005', current_date - 2, now() + interval '9 days');
set constraints all immediate;
select pg_temp.seed_revision('e7200000-0000-4000-8000-000000000001',
  'e7100000-0000-4000-8000-000000000002', now() - interval '2 hours', 1);
select pg_temp.seed_revision('e7200000-0000-4000-8000-000000000002',
  'e7100000-0000-4000-8000-000000000002', now() - interval '13 hours', 1);
insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values (
  'e7200000-0000-4000-8000-000000000007', 'e7100000-0000-4000-8000-000000000001',
  'e7100000-0000-4000-8000-000000000002', 0, 0, null, 'tie', 'stable', now(),
  jsonb_build_object('version', 1, 'participants', jsonb_build_array(
    jsonb_build_object('profile_id', 'e7100000-0000-4000-8000-000000000001', 'days', (
      select jsonb_agg(jsonb_build_object('ordinal', o, 'status', 'unavailable', 'reason', 'missing') order by o)
      from generate_series(1, 7) o)),
    jsonb_build_object('profile_id', 'e7100000-0000-4000-8000-000000000002', 'days', (
      select jsonb_agg(jsonb_build_object('ordinal', o, 'status', 'unavailable', 'reason', 'missing') order by o)
      from generate_series(1, 7) o)))),
  decode(repeat('21', 32), 'hex'), 1);

create temporary table r (label text primary key, v jsonb);
grant all on r to authenticated, service_role;

create function pg_temp.as_profile(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object(
    'role', 'authenticated', 'sub', 'e7000000-0000-4000-8000-00000000000' || n)::text, true);
$$;
create function pg_temp.nudges(suffix text) returns bigint language sql as $$
  select count(*) from private.competition_notification_work
  where competition_id = ('e7200000-0000-4000-8000-0000000000' || suffix)::uuid and kind = 'nudge';
$$;
grant execute on function pg_temp.as_profile(integer) to authenticated;

-- Access and eligibility
set local role authenticated;
select pg_temp.as_profile(3);
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002')$$,
  'P0002', 'competition_not_found', 'a non-participant gets competition_not_found');
select pg_temp.as_profile(1);
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000004')$$,
  'P0001', 'nudge_not_allowed', 'a scheduled match before Day 1 refuses with nudge_not_allowed');
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000001')$$,
  'P0001', 'nudge_not_allowed', 'a live match with a 2-hour-old upload refuses with nudge_not_allowed');

-- Queuing
insert into r values ('first', public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002'));
reset role;
select ok((select (v->>'nudged_at')::timestamptz between now() and clock_timestamp() and v ?& array['nudged_at']
    and (select count(*) from jsonb_object_keys(v)) = 1 from r where label = 'first'),
  'a nudge answers with only nudged_at');
select is((
  select array_agg(array[w.state, w.nudge_day::text, w.source_profile_id::text,
      (w.server_seq = (select max(l.server_seq) from public.competition_change_log l
        where l.competition_id = w.competition_id))::text] order by w.installation_id)
  from private.competition_notification_work w
  where w.competition_id = 'e7200000-0000-4000-8000-000000000002' and w.kind = 'nudge'),
  array[
    array['pending', current_date::text, 'e7100000-0000-4000-8000-000000000001', 'true'],
    array['pending', current_date::text, 'e7100000-0000-4000-8000-000000000001', 'true']],
  'a live match with a 13-hour-old upload queues one pending nudge per active installation');
set local role authenticated;
select pg_temp.as_profile(1);
select lives_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000003')$$,
  'a live match with no upload and Day 1 over 12 hours ago is stale');
reset role;
select is(pg_temp.nudges('03'), 2::bigint, 'the never-uploaded nudge queues a row per installation');

-- Repeats and spacing
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('repeat', public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002'));
reset role;
select ok((select v ? 'nudged_at' from r where label = 'repeat') and pg_temp.nudges('02') = 2,
  'a second nudge the same day returns a nudged_at and queues nothing');

update private.competition_notification_work
set nudge_day = current_date - 1,
    semantic_id = replace(semantic_id, ':nudge:' || current_date, ':nudge:' || (current_date - 1))
where competition_id = 'e7200000-0000-4000-8000-000000000002' and kind = 'nudge';
set local role authenticated;
select pg_temp.as_profile(1);
select lives_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002')$$,
  'a nudge within 12 hours of the last still answers');
reset role;
select is(pg_temp.nudges('02'), 2::bigint,
  'a nudge on the next match day within 12 hours of the last queues nothing');

update private.competition_notification_work
set created_at = now() - interval '13 hours', available_at = now() - interval '13 hours'
where competition_id = 'e7200000-0000-4000-8000-000000000002' and kind = 'nudge';
set local role authenticated;
select pg_temp.as_profile(1);
select lives_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002')$$,
  'a nudge on the next match day over 12 hours later answers');
reset role;
select ok(pg_temp.nudges('02') = 4 and (
    select count(distinct server_seq) = 1 from private.competition_notification_work
    where competition_id = 'e7200000-0000-4000-8000-000000000002' and kind = 'nudge'),
  'a nudge on the next match day over 12 hours later queues new rows with the same server_seq');

-- Same match day, over 12 hours later, after the sender's upload moved server_seq.
update private.competition_notification_work
set created_at = now() - interval '13 hours', available_at = now() - interval '13 hours'
where competition_id = 'e7200000-0000-4000-8000-000000000003' and kind = 'nudge';
select pg_temp.seed_revision('e7200000-0000-4000-8000-000000000003',
  'e7100000-0000-4000-8000-000000000001', now(), 1);
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('same-day', public.nudge_competition_participant('e7200000-0000-4000-8000-000000000003'));
reset role;
select ok((select v ? 'nudged_at' from r where label = 'same-day') and pg_temp.nudges('03') = 2,
  'a second nudge the same match day over 12 hours later returns nudged_at and queues nothing');

-- Privacy
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('muted', public.nudge_competition_participant('e7200000-0000-4000-8000-000000000009'));
insert into r values ('no-device', public.nudge_competition_participant('e7200000-0000-4000-8000-000000000008'));
reset role;
select ok((select v ? 'nudged_at' from r where label = 'muted') and (
    select array_agg(state) = array['suppressed'] from private.competition_notification_work
    where competition_id = 'e7200000-0000-4000-8000-000000000009' and kind = 'nudge'),
  'a muted recipient gets suppressed rows and the caller still gets nudged_at');
select ok((select v ? 'nudged_at' from r where label = 'no-device') and pg_temp.nudges('08') = 0,
  'a recipient with no installation returns nudged_at and queues nothing');

select pg_temp.seed_revision('e7200000-0000-4000-8000-000000000002',
  'e7100000-0000-4000-8000-000000000002', now(), 2);
select pg_temp.seed_revision('e7200000-0000-4000-8000-000000000008',
  'e7100000-0000-4000-8000-000000000003', now(), 1);
set local role authenticated;
select pg_temp.as_profile(1);
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000002')$$,
  'P0001', 'nudge_not_allowed', 'after the recipient updates, a repeat with stored rows refuses');
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000008')$$,
  'P0001', 'nudge_not_allowed',
  'after the recipient updates, a repeat refuses the same way with or without stored rows');

-- Tallying
select lives_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000005')$$,
  'tallying without the recipient''s stable attestation allows a nudge');
reset role;
insert into public.participant_finalization_attestations (
  competition_id, participant_profile_id, basis, window_commitment_sha256,
  accepted_revisions, server_seq, attested_at
) values ('e7200000-0000-4000-8000-000000000005', 'e7100000-0000-4000-8000-000000000002',
  'stable', decode(repeat('11', 32), 'hex'), array[1,2,3,4,5,6,7]::bigint[], 1, now());
set local role authenticated;
select pg_temp.as_profile(1);
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000005')$$,
  'P0001', 'nudge_not_allowed', 'tallying after the recipient''s stable attestation refuses');
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000006')$$,
  'P0001', 'nudge_not_allowed', 'tallying after best_available_deadline refuses');
select throws_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-000000000007')$$,
  'P0001', 'nudge_not_allowed', 'a finished match (competition_results row) refuses');

-- Lease
select lives_ok($$select public.nudge_competition_participant('e7200000-0000-4000-8000-00000000000a')$$,
  'a nudge to Eve is queued');
reset role;
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('e7100000-0000-4000-8000-000000000005', 'e7100000-0000-4000-8000-000000000001');
update public.competitions set lifecycle = 'completed'
where id = 'e7200000-0000-4000-8000-000000000003';

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into r values ('lease', public.lease_competition_notification_work(100, 60));
reset role;
select ok((
    select count(*) = 6
      and bool_and((select array_agg(k order by k) from jsonb_object_keys(item) k) = array[
        'apnsToken', 'competitionId', 'environment', 'kind', 'leaseToken', 'semanticId', 'workId'])
      and bool_and(item->>'semanticId' like '%:nudge:%')
    from r, jsonb_array_elements(r.v->'items') item
    where r.label = 'lease' and item->>'kind' = 'nudge'),
  'the lease sends nudge work with the seven keys and kind nudge');
select is((select array_agg(distinct state) from private.competition_notification_work
    where competition_id = 'e7200000-0000-4000-8000-000000000003' and kind = 'nudge'),
  array['discarded'], 'the lease discards nudge work once the match is completed');
select is((select array_agg(distinct state) from private.competition_notification_work
    where competition_id = 'e7200000-0000-4000-8000-00000000000a' and kind = 'nudge'),
  array['suppressed'], 'the lease suppresses nudge work for a pair muted after queuing');

-- Constraints
create function pg_temp.insert_work(semantic text, work_kind text, day date)
returns void language sql as $$
  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind, nudge_day, recipient_profile_id,
    source_profile_id, installation_id, state
  ) select 'healthcomp.server-notification:v1:' || semantic,
      'e7200000-0000-4000-8000-000000000001', max(l.server_seq), work_kind, day,
      'e7100000-0000-4000-8000-000000000002', 'e7100000-0000-4000-8000-000000000001',
      'e7300000-0000-4000-8000-000000000021', 'pending'
    from public.competition_change_log l
    where l.competition_id = 'e7200000-0000-4000-8000-000000000001'
  on conflict on constraint competition_notification_work_identity_unique do nothing;
$$;
select throws_ok($$select pg_temp.insert_work('shape-1', 'nudge', null)$$, '23514',
  'new row for relation "competition_notification_work" violates check constraint "competition_notification_work_nudge_day_shape"',
  'a nudge row without nudge_day violates competition_notification_work_nudge_day_shape');
select throws_ok($$select pg_temp.insert_work('shape-2', 'score_update', current_date)$$, '23514',
  'new row for relation "competition_notification_work" violates check constraint "competition_notification_work_nudge_day_shape"',
  'a score_update with nudge_day violates it');
select pg_temp.insert_work('dedupe-1', 'score_update', null);
select pg_temp.insert_work('dedupe-2', 'score_update', null);
select is((select count(*) from private.competition_notification_work
    where semantic_id like 'healthcomp.server-notification:v1:dedupe-%'), 1::bigint,
  'existing kinds still dedupe on the identity constraint');

select * from finish();
rollback;
