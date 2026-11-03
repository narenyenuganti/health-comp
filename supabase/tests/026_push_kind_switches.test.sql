begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
set local timezone = 'UTC';
select no_plan();

select has_function(
  'public', 'register_current_device_installation',
  array['uuid', 'text', 'text', 'boolean', 'boolean', 'text[]'],
  'registration with switched-off push kinds exists'
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
    and p.proname = 'register_current_device_installation'
    and p.proargtypes = '2950 25 25 16 16 1009'::oidvector
), false), 'the six-argument registration is a narrow authenticated definer RPC');

-- Ana sends. Ben switched Nudges off, Cal switched nothing off, Dee muted Ana,
-- Eve switched Reactions off.
insert into auth.users (id) values
  ('e9000000-0000-4000-8000-000000000001'), ('e9000000-0000-4000-8000-000000000002'),
  ('e9000000-0000-4000-8000-000000000003'), ('e9000000-0000-4000-8000-000000000004'),
  ('e9000000-0000-4000-8000-000000000005');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('e9100000-0000-4000-8000-000000000001', 'e9000000-0000-4000-8000-000000000001', 'Ana', 'active'),
  ('e9100000-0000-4000-8000-000000000002', 'e9000000-0000-4000-8000-000000000002', 'Ben', 'active'),
  ('e9100000-0000-4000-8000-000000000003', 'e9000000-0000-4000-8000-000000000003', 'Cal', 'active'),
  ('e9100000-0000-4000-8000-000000000004', 'e9000000-0000-4000-8000-000000000004', 'Dee', 'active'),
  ('e9100000-0000-4000-8000-000000000005', 'e9000000-0000-4000-8000-000000000005', 'Eve', 'active');
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('e9100000-0000-4000-8000-000000000004', 'e9100000-0000-4000-8000-000000000001');

create function pg_temp.muted_kinds(target uuid) returns text[] language sql as $$
  select muted_push_kinds from public.device_installations where installation_id = target;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"e9000000-0000-4000-8000-000000000002"}', true);
select throws_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', true, true,
    array['lead-change'])$$,
  '22023', 'invalid_installation_request', 'an unknown push kind is rejected');
select throws_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', true, true, null)$$,
  '22023', 'invalid_installation_request', 'a null list is rejected');
select throws_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', true, true,
    array[null]::text[])$$,
  '22023', 'invalid_installation_request', 'a null kind is rejected');
select is(public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', true, true,
    array['nudge']),
  jsonb_build_object('installation_id', 'e9300000-0000-4000-8000-000000000002',
    'environment', 'sandbox', 'state', 'active'),
  'the six-argument registration keeps the response shape');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"e9000000-0000-4000-8000-000000000003"}', true);
select lives_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000003', repeat('b3', 32), 'sandbox', true, true,
    '{}'::text[])$$, 'Cal registers with nothing switched off');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"e9000000-0000-4000-8000-000000000004"}', true);
select lives_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000004', repeat('b4', 32), 'sandbox', true, true)$$,
  'Dee registers through the previous call');
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"e9000000-0000-4000-8000-000000000005"}', true);
select lives_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000005', repeat('b5', 32), 'sandbox', true, true,
    array['reaction'])$$, 'Eve registers with Reactions switched off');
reset role;

select is(pg_temp.muted_kinds('e9300000-0000-4000-8000-000000000002'), array['nudge'],
  'the six-argument call stores the switched-off kinds');
select is(pg_temp.muted_kinds('e9300000-0000-4000-8000-000000000004'), '{}'::text[],
  'the previous call stores nothing switched off');
select throws_ok($$update public.device_installations set muted_push_kinds = array['score_update']
    where installation_id = 'e9300000-0000-4000-8000-000000000003'$$,
  '23514', null, 'the column only holds kinds the server can hold back');

-- One live match per recipient, then one work row per kind.
create function pg_temp.match(suffix text, opponent uuid) returns uuid language plpgsql as $$
declare
  target uuid := ('e9200000-0000-4000-8000-0000000000' || suffix)::uuid;
begin
  insert into public.competitions (
    id, creator_profile_id, time_zone_identifier, start_day,
    scoring_policy_identity, lifecycle, invitation_expires_at,
    best_available_deadline
  ) values (
    target, 'e9100000-0000-4000-8000-000000000001', 'UTC', current_date - 2,
    'healthcomp.activity-score.v1', 'scheduled', now() - interval '10 days',
    now() + interval '9 days'
  );
  insert into public.competition_participants (competition_id, profile_id, role, state) values
    (target, 'e9100000-0000-4000-8000-000000000001', 'creator', 'accepted'),
    (target, opponent, 'invitee', 'accepted');
  return target;
end;
$$;
select pg_temp.match('02', 'e9100000-0000-4000-8000-000000000002');
select pg_temp.match('03', 'e9100000-0000-4000-8000-000000000003');
select pg_temp.match('04', 'e9100000-0000-4000-8000-000000000004');
select pg_temp.match('05', 'e9100000-0000-4000-8000-000000000005');
set constraints all immediate;

create function pg_temp.work(suffix text, work_kind text) returns void language sql as $$
  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind, nudge_day, recipient_profile_id,
    source_profile_id, installation_id, state
  ) select 'healthcomp.server-notification:v1:switches:' || suffix || ':' || work_kind,
      ('e9200000-0000-4000-8000-0000000000' || suffix)::uuid, max(l.server_seq), work_kind,
      case when work_kind = 'nudge' then current_date end,
      ('e9100000-0000-4000-8000-0000000000' || suffix)::uuid,
      'e9100000-0000-4000-8000-000000000001',
      ('e9300000-0000-4000-8000-0000000000' || suffix)::uuid, 'pending'
    from public.competition_change_log l
    where l.competition_id = ('e9200000-0000-4000-8000-0000000000' || suffix)::uuid;
$$;
select pg_temp.work('02', kind) from unnest(array[
  'nudge', 'reaction', 'score_update', 'result', 'challenge_declined']) kind;
select pg_temp.work('03', kind) from unnest(array['nudge', 'reaction']) kind;
select pg_temp.work('04', kind) from unnest(array['nudge', 'reaction']) kind;
select pg_temp.work('05', kind) from unnest(array['nudge', 'reaction', 'score_update']) kind;

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select lives_ok($$select public.lease_competition_notification_work(100, 60)$$,
  'the lease runs');
reset role;

create function pg_temp.state(suffix text, work_kind text) returns text language sql as $$
  select state from private.competition_notification_work
  where semantic_id = 'healthcomp.server-notification:v1:switches:' || suffix || ':' || work_kind;
$$;
select is(pg_temp.state('02', 'nudge'), 'suppressed',
  'a nudge to an installation that switched Nudges off is suppressed');
select is(pg_temp.state('02', 'reaction'), 'leased',
  'a reaction to an installation that switched only Nudges off is leased');
select is(pg_temp.state('02', 'score_update'), 'leased', 'score updates ignore the switches');
select is(pg_temp.state('02', 'result'), 'leased', 'results ignore the switches');
select is(pg_temp.state('02', 'challenge_declined'), 'leased', 'challenge pushes ignore the switches');
select is(pg_temp.state('03', 'nudge'), 'leased', 'a nudge to an installation with nothing off is leased');
select is(pg_temp.state('03', 'reaction'), 'leased', 'a reaction to an installation with nothing off is leased');
select is(pg_temp.state('04', 'nudge'), 'suppressed', 'a muted sender still suppresses nudges');
select is(pg_temp.state('04', 'reaction'), 'suppressed', 'a muted sender still suppresses reactions');
select is(pg_temp.state('05', 'reaction'), 'suppressed',
  'a reaction to an installation that switched Reactions off is suppressed');
select is(pg_temp.state('05', 'nudge'), 'leased',
  'a nudge to an installation that switched only Reactions off is leased');
select is(pg_temp.state('05', 'score_update'), 'leased',
  'score updates still lease when Reactions are off');

-- Registering through the previous call clears an earlier switch.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"e9000000-0000-4000-8000-000000000002"}', true);
select lives_ok($$select public.register_current_device_installation(
    'e9300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox', true, true)$$,
  'Ben re-registers through the previous call');
reset role;
select is(pg_temp.muted_kinds('e9300000-0000-4000-8000-000000000002'), '{}'::text[],
  're-registering through the previous call clears the switched-off kinds');

select * from finish();
rollback;
