begin;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select no_plan();

select has_function(
  'public', 'register_current_device_installation',
  array['uuid', 'text', 'text', 'boolean'],
  'capability-aware installation registration RPC exists'
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
    and p.proargtypes = '2950 25 25 16'::oidvector
), false), 'capability-aware registration is a narrow authenticated definer RPC');

-- A Ana (sender), B Ben (1.0.2), C Cal (current app), D Dee (current app, muted Ana).
insert into auth.users (id) values
  ('c8000000-0000-4000-8000-000000000001'), ('c8000000-0000-4000-8000-000000000002'),
  ('c8000000-0000-4000-8000-000000000003'), ('c8000000-0000-4000-8000-000000000004');
insert into public.profiles (id, auth_user_id, display_name, state) values
  ('c8100000-0000-4000-8000-000000000001', 'c8000000-0000-4000-8000-000000000001', 'Ana', 'active'),
  ('c8100000-0000-4000-8000-000000000002', 'c8000000-0000-4000-8000-000000000002', 'Ben', 'active'),
  ('c8100000-0000-4000-8000-000000000003', 'c8000000-0000-4000-8000-000000000003', 'Cal', 'active'),
  ('c8100000-0000-4000-8000-000000000004', 'c8000000-0000-4000-8000-000000000004', 'Dee', 'active');
insert into private.competition_notification_mutes (profile_id, opponent_profile_id)
values ('c8100000-0000-4000-8000-000000000004', 'c8100000-0000-4000-8000-000000000001');

create temporary table r (label text primary key, id uuid, v jsonb);
grant all on r to authenticated, service_role;

create function pg_temp.supports(target uuid) returns boolean language sql as $$
  select supports_challenges from public.device_installations where installation_id = target;
$$;

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000002"}', true);
insert into r (label, v) values ('ben', public.register_current_device_installation(
  'c8300000-0000-4000-8000-000000000002', repeat('b2', 32), 'sandbox'));
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000003"}', true);
select throws_ok($$select public.register_current_device_installation(
    'c8300000-0000-4000-8000-000000000003', repeat('b3', 32), 'sandbox', null)$$,
  '22023', 'invalid_installation_request', 'a null capability is rejected');
insert into r (label, v) values ('cal', public.register_current_device_installation(
  'c8300000-0000-4000-8000-000000000003', repeat('b3', 32), 'sandbox', true));
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000004"}', true);
insert into r (label, v) values ('dee', public.register_current_device_installation(
  'c8300000-0000-4000-8000-000000000004', repeat('b4', 32), 'sandbox', true));
reset role;

select is((select v from r where label = 'ben'), jsonb_build_object(
    'installation_id', 'c8300000-0000-4000-8000-000000000002',
    'environment', 'sandbox', 'state', 'active'),
  '1.0.2 registration keeps its response shape');
select is((select v from r where label = 'cal'), jsonb_build_object(
    'installation_id', 'c8300000-0000-4000-8000-000000000003',
    'environment', 'sandbox', 'state', 'active'),
  'capability-aware registration returns the same shape');
select is(pg_temp.supports('c8300000-0000-4000-8000-000000000002'), false,
  'a 1.0.2 registration cannot show challenges');
select is(pg_temp.supports('c8300000-0000-4000-8000-000000000003'), true,
  'a current registration can show challenges');

-- The old call on the same installation clears the capability; the new one restores it.
set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated","sub":"c8000000-0000-4000-8000-000000000003"}', true);
select lives_ok($$select public.register_current_device_installation(
    'c8300000-0000-4000-8000-000000000003', repeat('b3', 32), 'sandbox')$$,
  'the old registration call still works for an existing installation');
reset role;
select is(pg_temp.supports('c8300000-0000-4000-8000-000000000003'), false,
  'registering through the old call clears the capability');
set local role authenticated;
select lives_ok($$select public.register_current_device_installation(
    'c8300000-0000-4000-8000-000000000003', repeat('b3', 32), 'sandbox', true)$$,
  'the new registration call restores the capability');
reset role;
select is(pg_temp.supports('c8300000-0000-4000-8000-000000000003'), true,
  'registering through the new call sets the capability');

-- Ana challenges Ben, Cal and Dee.
create function pg_temp.challenge(recipient uuid, digest_byte text, key uuid)
returns uuid language plpgsql as $$
begin
  perform set_config('request.jwt.claims', '{"role":"service_role"}', true);
  return public.create_competition_invite(decode(repeat(digest_byte, 32), 'hex'),
    'America/Los_Angeles', null, 'c8000000-0000-4000-8000-000000000001', key,
    1::smallint, recipient);
end;
$$;
insert into r (label, id) values
  ('to-ben', pg_temp.challenge('c8100000-0000-4000-8000-000000000002', 'e2', 'c8400000-0000-4000-8000-000000000002')),
  ('to-cal', pg_temp.challenge('c8100000-0000-4000-8000-000000000003', 'e3', 'c8400000-0000-4000-8000-000000000003')),
  ('to-dee', pg_temp.challenge('c8100000-0000-4000-8000-000000000004', 'e4', 'c8400000-0000-4000-8000-000000000004'));

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
insert into r (label, v) values ('lease', public.lease_competition_notification_work(100, 60));
reset role;

create function pg_temp.received_state(label_value text) returns text language sql as $$
  select w.state from private.competition_notification_work w
  where w.competition_id = (select id from r where label = label_value)
    and w.kind = 'challenge_received';
$$;
select is(pg_temp.received_state('to-ben'), 'discarded',
  'a challenge push to a 1.0.2 installation is discarded');
select is(pg_temp.received_state('to-cal'), 'leased',
  'a challenge push to a current installation is leased');
select is(pg_temp.received_state('to-dee'), 'suppressed',
  'a muted challenger stays muted on a current installation');
select is((select array_agg(item->>'apnsToken')
    from r, jsonb_array_elements(r.v->'items') item where r.label = 'lease'),
  array[repeat('b3', 32)], 'only the current installation receives a push');

select * from finish();
rollback;
