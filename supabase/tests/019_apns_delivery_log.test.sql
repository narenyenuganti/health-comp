begin;
set local role postgres;
create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;
select plan(25);

select has_column(
  'private', 'competition_notification_work', 'apns_development_delivery_log_id',
  'development delivery-log correlation stays in private durable work'
);

insert into auth.users (id, aud, role, created_at, updated_at)
select ('d1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'authenticated', 'authenticated', now(), now()
from generate_series(1, 2) n;
insert into public.profiles (id, auth_user_id, display_name, state)
select ('d2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('d1000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       'Synthetic notification ' || n, 'active'
from generate_series(1, 2) n;
insert into public.competitions (
  id, creator_profile_id, time_zone_identifier, start_day,
  scoring_policy_identity, lifecycle, invitation_expires_at,
  best_available_deadline
) values (
  'd3000000-0000-4000-8000-000000000001',
  'd2000000-0000-4000-8000-000000000001', 'UTC', '2000-01-01',
  'healthcomp.activity-score.v1', 'tallying', '1999-12-31', '2000-01-09'
);
insert into public.competition_participants (competition_id, profile_id, role, state)
select 'd3000000-0000-4000-8000-000000000001',
       ('d2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       case when n = 1 then 'creator' else 'invitee' end, 'accepted'
from generate_series(1, 2) n;
insert into public.device_installations (
  profile_id, installation_id, apns_token, environment, state
)
select ('d2000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       ('d5000000-0000-4000-8000-' || lpad(n::text, 12, '0'))::uuid,
       case when n = 1 then repeat('aa', 32) else repeat('bb', 32) end,
       case when n = 1 then 'sandbox' else 'production' end, 'active'
from generate_series(1, 2) n;
set constraints all immediate;

create temporary table notification_log_leases (payload jsonb not null);
grant select, insert on notification_log_leases to service_role;
set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select public.finalize_competition('d3000000-0000-4000-8000-000000000001');
insert into notification_log_leases
select jsonb_array_elements(public.lease_competition_notification_work(2, 60)->'items');

select throws_ok(format(
  'select public.resolve_competition_notification_work_with_delivery_log(%L::uuid,%L::uuid,%L::text)',
  payload->>'workId', payload->>'leaseToken', invalid_id
), '22023', 'invalid_notification_resolution',
  'invalid delivery-log identifiers cannot resolve leased work')
from notification_log_leases,
     unnest(array[null, '', 'contains space', E'bad\tvalue', E'bad\nvalue', 'é', repeat('x', 257)]) invalid_id
where payload->>'environment' = 'sandbox';
select is((
  select public.resolve_competition_notification_work_with_delivery_log(
    (payload->>'workId')::uuid, 'd9000000-0000-4000-8000-000000000001',
    'wrong-lease-log'
  ) from notification_log_leases where payload->>'environment' = 'sandbox'
), false, 'a different lease token cannot resolve or correlate work');

select is((
  select public.resolve_competition_notification_work_with_delivery_log(
    (payload->>'workId')::uuid, (payload->>'leaseToken')::uuid,
    'development-log_ABC123'
  ) from notification_log_leases where payload->>'environment' = 'sandbox'
), true, 'an exact sandbox lease resolves with its APNs delivery-log identifier');
reset role;
select is((
  select apns_development_delivery_log_id
  from private.competition_notification_work
  where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001'
), 'development-log_ABC123', 'the returned identifier is retained only in private work');

set local role service_role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);
select is((
  select public.resolve_competition_notification_work_with_delivery_log(
    (payload->>'workId')::uuid, (payload->>'leaseToken')::uuid,
    'replayed-log'
  ) from notification_log_leases where payload->>'environment' = 'sandbox'
), false, 'a resolved lease cannot overwrite its correlation identifier');
select is((
  select public.resolve_competition_notification_work_with_delivery_log(
    (payload->>'workId')::uuid, (payload->>'leaseToken')::uuid,
    'not-a-development-send'
  ) from notification_log_leases where payload->>'environment' = 'production'
), true, 'production acceptance keeps existing resolution behavior');
reset role;
select is((
  select apns_development_delivery_log_id
  from private.competition_notification_work
  where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001'
), 'development-log_ABC123', 'the first correlation survives replay unchanged');
select ok((
  select state = 'sent' and apns_development_delivery_log_id is null
  from private.competition_notification_work
  where recipient_profile_id = 'd2000000-0000-4000-8000-000000000002'
), 'production work never retains a development delivery-log identifier');

-- All rows below are transaction-local synthetic fixtures. Each scenario uses
-- the real lease/resolution RPCs; only an owner simulates the intervening race.
select lives_ok($cases$
  do $$
  declare
    scenario text;
    leased jsonb;
    resolved boolean;
  begin
    foreach scenario in array array['rotated', 'retired', 'expired', 'environment_changed'] loop
      update public.device_installations
      set state = 'active', apns_token = repeat('aa', 32), environment = 'sandbox'
      where profile_id = 'd2000000-0000-4000-8000-000000000001';
      update private.competition_notification_work
      set state = 'pending', lease_token = null, lease_expires_at = null,
          leased_apns_token_sha256 = null, completed_at = null,
          apns_development_delivery_log_id = null
      where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001';
      leased := public.lease_competition_notification_work(1, 60)->'items'->0;
      if leased is null then raise exception 'synthetic_lease_required'; end if;
      if scenario = 'rotated' then
        update public.device_installations set apns_token = repeat('cc', 32)
        where profile_id = 'd2000000-0000-4000-8000-000000000001';
      elsif scenario = 'retired' then
        update public.device_installations set state = 'revoked'
        where profile_id = 'd2000000-0000-4000-8000-000000000001';
      elsif scenario = 'environment_changed' then
        update public.device_installations set environment = 'production'
        where profile_id = 'd2000000-0000-4000-8000-000000000001';
      else
        update private.competition_notification_work
        set lease_expires_at = statement_timestamp() - interval '1 second'
        where id = (leased->>'workId')::uuid;
      end if;
      resolved := public.resolve_competition_notification_work_with_delivery_log(
        (leased->>'workId')::uuid, (leased->>'leaseToken')::uuid, 'stale-binding-log'
      );
      if resolved is distinct from true or not exists (
        select 1 from private.competition_notification_work
        where id = (leased->>'workId')::uuid and state = 'sent'
          and apns_development_delivery_log_id is null
      ) then raise exception 'stale_binding_correlated:%', scenario; end if;
    end loop;
  end;
  $$
$cases$, 'rotated, retired, expired and changed-environment leases resolve without correlation');

update public.device_installations
set state = 'active', apns_token = repeat('aa', 32), environment = 'sandbox'
where profile_id = 'd2000000-0000-4000-8000-000000000001';
update private.competition_notification_work
set state = 'pending', lease_token = null, lease_expires_at = null,
    leased_apns_token_sha256 = null, completed_at = null,
    apns_development_delivery_log_id = null
where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001';
truncate notification_log_leases;
set local role service_role;
insert into notification_log_leases
select jsonb_array_elements(public.lease_competition_notification_work(1, 60)->'items');
select is((
  select public.resolve_competition_notification_work_with_delivery_log(
    (payload->>'workId')::uuid, (payload->>'leaseToken')::uuid, repeat('x', 256)
  ) from notification_log_leases
), true, 'the opaque identifier accepts the documented local 256-byte bound');
select throws_ok(
  $$select apns_development_delivery_log_id from private.competition_notification_work$$,
  '42501', null, 'service callers still have no direct private-table access'
);
reset role;
select is((
  select octet_length(apns_development_delivery_log_id)
  from private.competition_notification_work
  where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001'
), 256, 'the bounded opaque identifier is stored without truncation');
select ok(coalesce((
  select procedure_row.prosecdef
    and 'search_path=""' = any(procedure_row.proconfig)
    and has_function_privilege('service_role', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('authenticated', procedure_row.oid, 'EXECUTE')
    and not has_function_privilege('anon', procedure_row.oid, 'EXECUTE')
    and not exists (
      select 1 from aclexplode(procedure_row.proacl) acl_row
      where acl_row.grantee = 0 and acl_row.privilege_type = 'EXECUTE'
    )
  from pg_proc procedure_row
  where procedure_row.oid = 'public.resolve_competition_notification_work_with_delivery_log(uuid,uuid,text)'::regprocedure
), false), 'the new RPC is service-only with a locked definer search path');
select has_function('public', 'resolve_competition_notification_work',
  array['uuid', 'uuid', 'text', 'integer'], 'the legacy four-argument RPC remains available');

set local role authenticated;
select set_config('request.jwt.claims', '{"role":"authenticated"}', true);
select throws_ok(
  $$select public.resolve_competition_notification_work_with_delivery_log(
    'd9000000-0000-4000-8000-000000000001', 'd9000000-0000-4000-8000-000000000001', 'untrusted-log')$$,
  '42501', null, 'participants cannot call the correlation RPC'
);
select throws_ok(
  $$select apns_development_delivery_log_id from private.competition_notification_work$$,
  '42501', null, 'participants cannot read delivery-log identifiers'
);
reset role;
select throws_ok(
  $$select public.resolve_competition_notification_work_with_delivery_log(
    'd9000000-0000-4000-8000-000000000001', 'd9000000-0000-4000-8000-000000000001', 'untrusted-log')$$,
  '42501', 'service_role_required', 'the definer function also rejects a non-service JWT role'
);
delete from public.device_installations
where profile_id = 'd2000000-0000-4000-8000-000000000001';
select is((
  select count(*)::bigint from private.competition_notification_work
  where recipient_profile_id = 'd2000000-0000-4000-8000-000000000001'
), 0::bigint, 'installation deletion cascades the correlated operational work');

select * from finish();
rollback;
