begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
set local timezone = 'UTC';
select no_plan();

-- Table and functions
select has_table('private', 'competition_reactions', 'reactions table exists');
select ok((select relrowsecurity and relforcerowsecurity from pg_class
    where oid = 'private.competition_reactions'::regclass),
  'reactions have RLS enabled and forced');
select is(has_table_privilege('authenticated', 'private.competition_reactions', 'select'),
  false, 'authenticated has no raw reaction table access');
select has_function('public', 'set_competition_reaction', array['uuid', 'integer', 'text'],
  'set reaction RPC exists');
select has_function('public', 'list_competition_reactions', array[]::text[],
  'list reactions RPC exists');
select has_function('public', 'register_current_device_installation',
  array['uuid', 'text', 'text', 'boolean', 'boolean'],
  'reaction-aware installation registration RPC exists');
select is((
  select array_agg(p.proname || '(' || p.proargtypes::text || ')' order by p.proname, p.proargtypes::text)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and ((p.proname = 'register_current_device_installation' and p.proargtypes = '2950 25 25 16 16'::oidvector)
      or (p.proname = 'set_competition_reaction' and p.proargtypes = '2950 23 25'::oidvector)
      or (p.proname = 'list_competition_reactions' and p.proargtypes = ''::oidvector))
    and p.prosecdef
    and 'search_path=""' = any(coalesce(p.proconfig, array[]::text[]))
    and has_function_privilege('authenticated', p.oid, 'execute')
    and not has_function_privilege('anon', p.oid, 'execute')
    and not has_function_privilege('service_role', p.oid, 'execute')
    and not has_function_privilege('public', p.oid, 'execute')),
  array['list_competition_reactions()', 'register_current_device_installation(2950 25 25 16 16)',
    'set_competition_reaction(2950 23 25)'],
  'the three new RPCs are narrow authenticated definer functions');
select ok(not has_function_privilege('authenticated',
    'private.enqueue_reaction_notification(uuid, uuid, uuid)', 'execute'),
  'the reaction enqueue is not an API function');

-- Ana and Ben play; Cal is an outsider.
insert into auth.users (id) values
  ('f8000000-0000-4000-8000-000000000001'), ('f8000000-0000-4000-8000-000000000002'),
  ('f8000000-0000-4000-8000-000000000003');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('f8100000-0000-4000-8000-000000000001', 'f8000000-0000-4000-8000-000000000001', 'Ana', 'active'),
  ('f8100000-0000-4000-8000-000000000002', 'f8000000-0000-4000-8000-000000000002', 'Ben', 'active'),
  ('f8100000-0000-4000-8000-000000000003', 'f8000000-0000-4000-8000-000000000003', 'Cal', 'active');

delete from vault.secrets
where name in ('healthcomp_notification_worker_url', 'healthcomp_notification_worker_token');
select vault.create_secret(
  'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/send-competition-notification',
  'healthcomp_notification_worker_url');
select vault.create_secret(repeat('w', 43), 'healthcomp_notification_worker_token');

-- Matches, 'scheduled' on the server, phase by date in UTC:
--   …01 Day 3 today    …02 starts tomorrow    …03 Day 3 today (mute check)
create function pg_temp.match(suffix text, first_day date)
returns uuid language plpgsql as $$
declare
  target uuid := ('f8200000-0000-4000-8000-0000000000' || suffix)::uuid;
begin
  insert into public.competitions (
    id, creator_profile_id, time_zone_identifier, start_day,
    scoring_policy_identity, lifecycle, invitation_expires_at,
    best_available_deadline
  ) values (
    target, 'f8100000-0000-4000-8000-000000000001', 'UTC', first_day,
    'healthcomp.activity-score.v1', 'scheduled', now() - interval '10 days',
    now() + interval '9 days'
  );
  insert into public.competition_participants (competition_id, profile_id, role, state) values
    (target, 'f8100000-0000-4000-8000-000000000001', 'creator', 'accepted'),
    (target, 'f8100000-0000-4000-8000-000000000002', 'invitee', 'accepted');
  return target;
end;
$$;
select pg_temp.match('01', current_date - 2);
select pg_temp.match('02', current_date + 1);
select pg_temp.match('03', current_date - 2);
set constraints all immediate;

create temporary table r (label text primary key, v jsonb);
grant all on r to authenticated, service_role;
create function pg_temp.as_profile(n integer) returns void language sql as $$
  select set_config('request.jwt.claims', jsonb_build_object(
    'role', 'authenticated', 'sub', 'f8000000-0000-4000-8000-00000000000' || n)::text, true);
$$;
grant execute on function pg_temp.as_profile(integer) to authenticated;
create function pg_temp.supports(target uuid) returns boolean language sql as $$
  select supports_reactions from public.device_installations where installation_id = target;
$$;
create function pg_temp.wakeups(n integer) returns bigint language sql as $$
  select count(*) from realtime.messages
  where event = 'competition_changed'
    and topic = 'profile:f8100000-0000-4000-8000-00000000000' || n;
$$;
create function pg_temp.reaction_work(suffix text) returns bigint language sql as $$
  select count(*) from private.competition_notification_work
  where competition_id = ('f8200000-0000-4000-8000-0000000000' || suffix)::uuid
    and kind = 'reaction';
$$;
create function pg_temp.log_rows() returns bigint language sql as $$
  select count(*) from public.competition_change_log;
$$;
create temporary table marks (label text primary key, ana bigint, ben bigint, cal bigint, work bigint, log bigint);
create function pg_temp.mark(label text) returns void language sql as $$
  insert into marks values (label, pg_temp.wakeups(1), pg_temp.wakeups(2), pg_temp.wakeups(3),
    pg_temp.reaction_work('01'), pg_temp.log_rows());
$$;
create function pg_temp.since(label text) returns bigint[] language sql as $$
  select array[pg_temp.wakeups(1) - m.ana, pg_temp.wakeups(2) - m.ben,
    pg_temp.wakeups(3) - m.cal, pg_temp.reaction_work('01') - m.work, pg_temp.log_rows() - m.log]
  from marks m where m.label = since.label;
$$;

-- Registration
set local role authenticated;
select pg_temp.as_profile(2);
select lives_ok($$select public.register_current_device_installation(
    'f8300000-0000-4000-8000-000000000021', repeat('b1', 32), 'sandbox', true, true)$$,
  'Ben registers his new build');
select lives_ok($$select public.register_current_device_installation(
    'f8300000-0000-4000-8000-000000000022', repeat('b2', 32), 'sandbox', true)$$,
  'Ben registers a current-build install');
select pg_temp.as_profile(1);
select lives_ok($$select public.register_current_device_installation(
    'f8300000-0000-4000-8000-000000000011', repeat('a1', 32), 'sandbox', true)$$,
  'Ana registers a current-build install');
select pg_temp.as_profile(3);
select throws_ok($$select public.register_current_device_installation(
    'f8300000-0000-4000-8000-000000000031', repeat('c1', 32), 'sandbox', true, null)$$,
  '22023', 'invalid_installation_request', 'a null reaction capability is rejected');
insert into r values ('cal-5', public.register_current_device_installation(
  'f8300000-0000-4000-8000-000000000031', repeat('c1', 32), 'sandbox', true, true));
reset role;
select is((select v from r where label = 'cal-5'), jsonb_build_object(
    'installation_id', 'f8300000-0000-4000-8000-000000000031',
    'environment', 'sandbox', 'state', 'active'),
  'reaction-aware registration keeps the response shape');
select ok(pg_temp.supports('f8300000-0000-4000-8000-000000000031')
    and pg_temp.supports('f8300000-0000-4000-8000-000000000021')
    and not pg_temp.supports('f8300000-0000-4000-8000-000000000022')
    and not pg_temp.supports('f8300000-0000-4000-8000-000000000011'),
  'the five-argument call sets supports_reactions and the four-argument call leaves it false');
set local role authenticated;
select pg_temp.as_profile(3);
select public.register_current_device_installation(
  'f8300000-0000-4000-8000-000000000031', repeat('c1', 32), 'sandbox', true);
reset role;
select is(pg_temp.supports('f8300000-0000-4000-8000-000000000031'), false,
  'the four-argument call clears supports_reactions');
select is((select supports_challenges from public.device_installations
    where installation_id = 'f8300000-0000-4000-8000-000000000031'), true,
  'the four-argument call keeps its challenge capability');
set local role authenticated;
select pg_temp.as_profile(3);
select public.register_current_device_installation(
  'f8300000-0000-4000-8000-000000000031', repeat('c1', 32), 'sandbox', true, true);
select public.register_current_device_installation(
  'f8300000-0000-4000-8000-000000000031', repeat('c1', 32), 'sandbox');
reset role;
select ok(not pg_temp.supports('f8300000-0000-4000-8000-000000000031')
    and not (select supports_challenges from public.device_installations
      where installation_id = 'f8300000-0000-4000-8000-000000000031'),
  'the three-argument call clears both capabilities');

-- Day reactions
create temporary table earlier_messages as select id from realtime.messages;
select pg_temp.mark('first');
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('day-2', public.set_competition_reaction(
  'f8200000-0000-4000-8000-000000000001', 2, 'fire'));
reset role;
select is((select v from r where label = 'day-2'), jsonb_build_object(
    'competition_id', 'f8200000-0000-4000-8000-000000000001', 'day_ordinal', 2, 'reaction', 'fire'),
  'a reaction to a started day echoes the input');
select is(pg_temp.since('first'), array[1, 1, 0, 1, 0]::bigint[],
  'a new reaction wakes Ana and Ben once each, never Cal, queues one push to Ben''s new build and adds no change-log row');
select ok(not exists (
    select 1 from realtime.messages
    where event = 'competition_changed'
      and topic in ('profile:f8100000-0000-4000-8000-000000000001', 'profile:f8100000-0000-4000-8000-000000000002')
      and id not in (select id from earlier_messages)
      and (not private or extension <> 'broadcast'
        or (select array_agg(k order by k) from jsonb_object_keys(payload) k) <> array['id', 'server_cursor_hint']
        or (payload->>'server_cursor_hint')::bigint <> (
          select next_server_seq - 1 from public.competitions
          where id = 'f8200000-0000-4000-8000-000000000001'))),
  'reaction wake-ups are private broadcasts carrying only the cursor hint');
select is((
    select array_agg(array[w.state, w.installation_id::text, w.source_profile_id::text,
      (w.server_seq = (select max(l.server_seq) from public.competition_change_log l
        where l.competition_id = w.competition_id))::text,
      (w.semantic_id = 'healthcomp.server-notification:v1:' || w.competition_id || ':reaction:'
        || w.server_seq || ':' || w.recipient_profile_id || ':' || w.installation_id)::text])
    from private.competition_notification_work w
    where w.competition_id = 'f8200000-0000-4000-8000-000000000001' and w.kind = 'reaction'),
  array[array['pending', 'f8300000-0000-4000-8000-000000000021',
    'f8100000-0000-4000-8000-000000000001', 'true', 'true']],
  'the push goes only to Ben''s reaction-capable install, at the latest change');

set local role authenticated;
select pg_temp.as_profile(1);
select lives_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 3, 'clap')$$,
  'today (Day 3) can be reacted to');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 4, 'clap')$$,
  'P0001', 'reaction_not_allowed', 'an upcoming day refuses');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000002', 1, 'clap')$$,
  'P0001', 'reaction_not_allowed', 'Day 1 of a match that starts tomorrow refuses');
reset role;
select is(pg_temp.reaction_work('01'), 1::bigint,
  'a second reaction within the hour queues no push');

-- The hour, not the work identity, is what keeps it silent: Ben's rename adds
-- a change-log row, so the next reaction lands at a new server_seq.
update public.profiles set display_name = 'Benjamin', updated_at = now()
where id = 'f8100000-0000-4000-8000-000000000002';
set local role authenticated;
select pg_temp.as_profile(1);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 3, 'fire');
reset role;
select is(pg_temp.reaction_work('01'), 1::bigint,
  'a reaction at a new change within the hour still queues no push');
update private.competition_notification_work set created_at = created_at - interval '61 minutes'
where competition_id = 'f8200000-0000-4000-8000-000000000001' and kind = 'reaction';
set local role authenticated;
select pg_temp.as_profile(1);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 3, 'clap');
reset role;
select is((
    select array_agg(array[w.state, (w.server_seq = (select max(l.server_seq)
      from public.competition_change_log l where l.competition_id = w.competition_id))::text]
      order by w.created_at)
    from private.competition_notification_work w
    where w.competition_id = 'f8200000-0000-4000-8000-000000000001' and w.kind = 'reaction'),
  array[array['pending', 'false'], array['pending', 'true']],
  'once the last reaction push is over an hour old, the next one queues at the new change');
-- Drop the aged row so the lease check below sees one reaction item.
delete from private.competition_notification_work
where competition_id = 'f8200000-0000-4000-8000-000000000001' and kind = 'reaction'
  and created_at < statement_timestamp() - interval '1 hour';

-- Refusals
set local role authenticated;
select pg_temp.as_profile(3);
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 2, 'fire')$$,
  'P0001', 'reaction_not_allowed', 'a non-participant gets reaction_not_allowed');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-0000000000ff', 2, 'fire')$$,
  'P0001', 'reaction_not_allowed', 'an unknown match gets the same answer');
select pg_temp.as_profile(1);
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 2, 'heart')$$,
  '22023', 'invalid_reaction', 'an unknown preset is invalid');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 9, 'fire')$$,
  '22023', 'invalid_reaction', 'a day outside 1...7 is invalid');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 0, 'fire')$$,
  '22023', 'invalid_reaction', 'day 0 is invalid');
select throws_ok($$select public.set_competition_reaction(null, 2, 'fire')$$,
  '22023', 'invalid_reaction', 'a null match is invalid');

-- Writes
reset role;
select pg_temp.mark('same');
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('same', public.set_competition_reaction(
  'f8200000-0000-4000-8000-000000000001', 2, 'fire'));
reset role;
select ok((select v->>'reaction' = 'fire' from r where label = 'same')
    and pg_temp.since('same') = array[0, 0, 0, 0, 0]::bigint[],
  'the same reaction again echoes with no wake-up and no push');

update private.competition_reactions set updated_at = updated_at - interval '1 minute'
where competition_id = 'f8200000-0000-4000-8000-000000000001' and day_ordinal = 2;
select pg_temp.mark('change');
set local role authenticated;
select pg_temp.as_profile(1);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 2, 'clap');
reset role;
select ok((select count(*) = 1 and bool_and(reaction = 'clap' and created_at < updated_at)
    from private.competition_reactions
    where competition_id = 'f8200000-0000-4000-8000-000000000001'
      and author_profile_id = 'f8100000-0000-4000-8000-000000000001' and day_ordinal = 2)
    and pg_temp.since('change') = array[1, 1, 0, 0, 0]::bigint[],
  'changing a reaction keeps one row, advances updated_at and wakes both people');

select pg_temp.mark('remove');
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('remove', public.set_competition_reaction(
  'f8200000-0000-4000-8000-000000000001', 3, null));
reset role;
select ok((select v = jsonb_build_object('competition_id', 'f8200000-0000-4000-8000-000000000001',
      'day_ordinal', 3, 'reaction', null) from r where label = 'remove')
    and not exists (select 1 from private.competition_reactions
      where competition_id = 'f8200000-0000-4000-8000-000000000001' and day_ordinal = 3)
    and pg_temp.since('remove') = array[1, 1, 0, 0, 0]::bigint[],
  'a null reaction deletes the row with one wake-up each and no push');

select pg_temp.mark('remove-again');
set local role authenticated;
select pg_temp.as_profile(1);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 3, null);
reset role;
select is(pg_temp.since('remove-again'), array[0, 0, 0, 0, 0]::bigint[],
  'removing a missing reaction is a no-op');

-- Ben reacts to Ana: Ana has only a current-build install.
set local role authenticated;
select pg_temp.as_profile(2);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 1, 'huffing');
reset role;
select is((select count(*) from private.competition_notification_work
    where kind = 'reaction' and recipient_profile_id = 'f8100000-0000-4000-8000-000000000001'), 0::bigint,
  'no push to an install registered with the four-argument call');

-- Older builds: the change feed never sees reactions.
set local role authenticated;
select pg_temp.as_profile(2);
select ok((
    select count(*) > 0 and bool_and(c->>'kind' <> 'reaction')
    from jsonb_array_elements(public.fetch_competition_changes(
      'f8200000-0000-4000-8000-000000000001', 0, 200)->'changes') c),
  'Ben''s change feed still reads the whole match');

-- List
select pg_temp.as_profile(1);
insert into r values ('ana-list', public.list_competition_reactions());
select pg_temp.as_profile(2);
insert into r values ('ben-list', public.list_competition_reactions());
select pg_temp.as_profile(3);
insert into r values ('cal-list', public.list_competition_reactions());
reset role;
select is((select v from r where label = 'ana-list'), (select v from r where label = 'ben-list'),
  'both participants see the same reactions');
select is((
    select array_agg(array[e.item->>'author_profile_id', e.item->>'day_ordinal', e.item->>'reaction']
      order by e.n)
    from r, jsonb_array_elements(r.v->'reactions') with ordinality as e(item, n)
    where r.label = 'ana-list'),
  array[
    array['f8100000-0000-4000-8000-000000000002', '1', 'huffing'],
    array['f8100000-0000-4000-8000-000000000001', '2', 'clap']],
  'reactions list newest first, both people''s');
select ok((
    select bool_and((select array_agg(k order by k) from jsonb_object_keys(e) k)
      = array['author_profile_id', 'competition_id', 'day_ordinal', 'reaction', 'updated_at'])
    from r, jsonb_array_elements(r.v->'reactions') e where r.label = 'ana-list')
    and (select array_agg(k) from r, jsonb_object_keys(r.v) k where r.label = 'ana-list')
      = array['reactions'],
  'list rows carry exactly the five keys');
select is((select v from r where label = 'cal-list'), '{"reactions": []}'::jsonb,
  'an outsider lists nothing');

-- Mute and lease
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('f8100000-0000-4000-8000-000000000002', 'f8100000-0000-4000-8000-000000000001');
set local role authenticated;
select pg_temp.as_profile(1);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000003', 2, 'salute');
reset role;
select is((select array_agg(state) from private.competition_notification_work
    where competition_id = 'f8200000-0000-4000-8000-000000000003' and kind = 'reaction'),
  array['suppressed'], 'a reaction from a muted person queues a suppressed row');
delete from private.competition_notification_mutes
where profile_id = 'f8100000-0000-4000-8000-000000000002';

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into r values ('lease', public.lease_competition_notification_work(100, 60));
reset role;
select ok((
    select count(*) = 1
      and bool_and((select array_agg(k order by k) from jsonb_object_keys(item) k) = array[
        'apnsToken', 'competitionId', 'environment', 'kind', 'leaseToken', 'semanticId', 'workId'])
      and bool_and(item->>'competitionId' = 'f8200000-0000-4000-8000-000000000001'
        and item->>'apnsToken' = repeat('b1', 32))
    from r, jsonb_array_elements(r.v->'items') item
    where r.label = 'lease' and item->>'kind' = 'reaction'),
  'the lease sends the reaction item with the seven keys and kind reaction');

-- Result reaction
set local role authenticated;
select pg_temp.as_profile(1);
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', null, 'fire')$$,
  'P0001', 'reaction_not_allowed', 'the result refuses before a result exists');
reset role;
insert into public.competition_results (
  competition_id, participant_a_profile_id, participant_b_profile_id,
  participant_a_total_centi_points, participant_b_total_centi_points,
  winner_profile_id, outcome, finalization_basis, completed_at,
  frozen_window, immutable_hash, server_seq
) values (
  'f8200000-0000-4000-8000-000000000001', 'f8100000-0000-4000-8000-000000000001',
  'f8100000-0000-4000-8000-000000000002', 0, 0, null, 'tie', 'stable', now(),
  jsonb_build_object('version', 1, 'participants', jsonb_build_array(
    jsonb_build_object('profile_id', 'f8100000-0000-4000-8000-000000000001', 'days', (
      select jsonb_agg(jsonb_build_object('ordinal', o, 'status', 'unavailable', 'reason', 'missing') order by o)
      from generate_series(1, 7) o)),
    jsonb_build_object('profile_id', 'f8100000-0000-4000-8000-000000000002', 'days', (
      select jsonb_agg(jsonb_build_object('ordinal', o, 'status', 'unavailable', 'reason', 'missing') order by o)
      from generate_series(1, 7) o)))),
  decode(repeat('25', 32), 'hex'), 1);
set local role authenticated;
select pg_temp.as_profile(1);
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', null, 'fire')$$,
  'P0001', 'reaction_not_allowed', 'the result refuses while the lifecycle is still live');
reset role;
update public.competitions set lifecycle = 'completed'
where id = 'f8200000-0000-4000-8000-000000000001';
set local role authenticated;
select pg_temp.as_profile(1);
insert into r values ('result', public.set_competition_reaction(
  'f8200000-0000-4000-8000-000000000001', null, 'fire'));
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', 2, 'fire')$$,
  'P0001', 'reaction_not_allowed', 'day reactions close once the result lands');
select pg_temp.as_profile(2);
select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', null, 'salute');
reset role;
select is((select v from r where label = 'result'), jsonb_build_object(
    'competition_id', 'f8200000-0000-4000-8000-000000000001', 'day_ordinal', null, 'reaction', 'fire'),
  'a result reaction echoes a null day');

-- Anonymized: Ben deletes his account.
update public.profiles set state = 'deleting' where id = 'f8100000-0000-4000-8000-000000000002';
update public.competition_participants set state = 'anonymized'
where profile_id = 'f8100000-0000-4000-8000-000000000002';
update public.profiles
set auth_user_id = null, display_name = 'Former competitor', state = 'anonymized',
    anonymized_at = now(), updated_at = now()
where id = 'f8100000-0000-4000-8000-000000000002';
set local role authenticated;
select pg_temp.as_profile(1);
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000001', null, 'clap')$$,
  'P0001', 'reaction_not_allowed', 'a reaction to a deleted account refuses');
select throws_ok($$select public.set_competition_reaction('f8200000-0000-4000-8000-000000000003', 3, 'clap')$$,
  'P0001', 'reaction_not_allowed', 'a live match with a deleted account refuses too');
insert into r values ('after-delete', public.list_competition_reactions());
reset role;
select is((
    select array_agg(array[e->>'day_ordinal', e->>'reaction'] order by e->>'day_ordinal' nulls first)
    from r, jsonb_array_elements(r.v->'reactions') e
    where r.label = 'after-delete'
      and e->>'author_profile_id' = 'f8100000-0000-4000-8000-000000000002'),
  array[array[null, 'salute'], array['1', 'huffing']],
  'a deleted account''s reactions, including the result, still list for Ana');

select * from finish();
rollback;
