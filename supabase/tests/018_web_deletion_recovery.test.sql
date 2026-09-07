begin;
set local role postgres;
set local search_path = extensions, public, pg_catalog;
select no_plan();

insert into auth.users(id,aud,role,created_at,updated_at)
values ('f3000000-0000-4000-8000-000000000001','authenticated','authenticated',now(),now());
insert into public.profiles(id,auth_user_id,display_name,state)
values ('f4000000-0000-4000-8000-000000000001',
  'f3000000-0000-4000-8000-000000000001','Synthetic recovery','active');

-- Model a restored snapshot directly, including states that may have changed
-- since the recovery point. No real user or Apple authorization is involved.
insert into private.apple_deletion_web_requests(
  request_id,state_digest,verifier_digest,nonce,profile_id,auth_user_id,
  apple_client_id,redirect_uri,phase,expires_at)
select repeat(n::text,64),repeat(to_hex(n+5),64),repeat('a',64),repeat('b',64),
  'f4000000-0000-4000-8000-000000000001',
  'f3000000-0000-4000-8000-000000000001','com.example.web',
  'https://example.invalid/callback',phase,now()+interval '10 minutes'
from unnest(array['pending','code_ready','claimed','cancelled','expired'])
  with ordinality as states(phase,n);

insert into auth.users(id,aud,role,created_at,updated_at)
values ('f3000000-0000-4000-8000-000000000002','authenticated','authenticated',now(),now());
insert into public.profiles(id,auth_user_id,display_name,state,anonymized_at)
values ('f4000000-0000-4000-8000-000000000002',
  'f3000000-0000-4000-8000-000000000002','Synthetic pending deletion','deleting',null),
  ('f4000000-0000-4000-8000-000000000003',null,'Former competitor','anonymized',now());
insert into private.account_deletions(profile_id,auth_user_id,apple_provider_id,phase,apple_client_id,completed_at)
values ('f4000000-0000-4000-8000-000000000002','f3000000-0000-4000-8000-000000000002',
  'synthetic-recovery-apple','token_ready','com.example.web',null),
  ('f4000000-0000-4000-8000-000000000003',null,null,'completed','com.example.native',now());

insert into public.competitions(id,creator_profile_id,scoring_policy_identity,lifecycle,invitation_expires_at,next_server_seq)
values ('f5000000-0000-4000-8000-000000000001','f4000000-0000-4000-8000-000000000003',
  'synthetic-recovery-policy','cancelled',now(),2);
insert into public.competition_change_log(competition_id,server_seq,change_kind,entity_id)
values ('f5000000-0000-4000-8000-000000000001',1,'account_anonymized',
  'f4000000-0000-4000-8000-000000000003');

do $$ begin
  perform vault.create_secret('synthetic-code', 'healthcomp_web_deletion_code:'||repeat('2',64));
  perform vault.create_secret('synthetic-orphan', 'healthcomp_web_deletion_code:'||repeat('f',64));
  -- Similar spelling must not match an SQL LIKE underscore wildcard.
  perform vault.create_secret('synthetic-unrelated', 'healthcompXwebXdeletionXcode:unrelated');
  perform vault.create_secret('synthetic-durable-refresh-token',
    private.account_deletion_secret_name('f4000000-0000-4000-8000-000000000002'));
end $$;

create temporary table recovery_preserved as
select 'profiles' as category, to_jsonb(p) as value from public.profiles p
union all select 'deletions',to_jsonb(d) from private.account_deletions d
union all select 'competitions',to_jsonb(c) from public.competitions c
union all select 'history',to_jsonb(h) from public.competition_change_log h
union all select 'results',to_jsonb(r) from public.competition_results r
union all select 'vault',to_jsonb(s) from vault.secrets s
where not starts_with(s.name,'healthcomp_web_deletion_code:');

select lives_ok($$select private.invalidate_apple_deletion_web_requests_for_recovery()$$,
  'owner can invalidate temporary recovery state');
select is((select count(*) from private.apple_deletion_web_requests),0::bigint,
  'all restored request phases are removed, including unexpired requests');
select is((select count(*) from vault.secrets where starts_with(name,'healthcomp_web_deletion_code:')),
  0::bigint,'temporary and orphaned code secrets are removed');
select is(public.receive_apple_deletion_web_callback(repeat('6',64),'synthetic-late-callback',false),
  null::text,'old pending callback cannot restore authorization');
select is(public.claim_apple_deletion_web_request(
  'f3000000-0000-4000-8000-000000000001',repeat('2',64),repeat('a',64)),
  null::jsonb,'old ready request cannot be claimed after recovery');
select results_eq($$
  select 'profiles' as category,to_jsonb(p) as value from public.profiles p
  union all select 'deletions',to_jsonb(d) from private.account_deletions d
  union all select 'competitions',to_jsonb(c) from public.competitions c
  union all select 'history',to_jsonb(h) from public.competition_change_log h
  union all select 'results',to_jsonb(r) from public.competition_results r
  union all select 'vault',to_jsonb(s) from vault.secrets s
  where not starts_with(s.name,'healthcomp_web_deletion_code:')
  order by 1,2
$$,$$select category,value from recovery_preserved order by 1,2$$,
  'unrelated Vault state, profiles, durable progress and history are unchanged');
select lives_ok($$select private.invalidate_apple_deletion_web_requests_for_recovery()$$,
  'cleanup can be repeated without creating state');
select is((select bool_or(has_function_privilege(role_name,
  'private.invalidate_apple_deletion_web_requests_for_recovery()','EXECUTE'))
  from unnest(array['anon','authenticated','service_role']) roles(role_name)),false,
  'application roles cannot run recovery cleanup');
select is((select prosecdef from pg_proc where oid=
  'private.invalidate_apple_deletion_web_requests_for_recovery()'::regprocedure),false,
  'cleanup never elevates the operator privilege');
select * from finish();
rollback;
