-- Synthetic local-only rehearsal on the actual pre-binding migration chain.
-- The caller supplies the exact checked-in forward migration, never credentials.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
set local lock_timeout = '5s';
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20260822001000'
    or exists(select 1 from private.account_deletions)
    or exists(select 1 from public.profiles)
    or exists(select 1 from auth.users)
  then raise exception using errcode='P0001',message='empty_local_pre_binding_schema_required'; end if;
end $$;
create temporary table binding_test_source(sql text);
insert into binding_test_source values (:'binding_migration');

insert into auth.users(id,aud,role,created_at,updated_at)
values ('f6000000-0000-4000-8000-000000000001','authenticated','authenticated',now(),now());
insert into auth.identities(id,provider_id,user_id,identity_data,provider,created_at,updated_at)
values ('f6500000-0000-4000-8000-000000000001','synthetic-legacy-apple',
 'f6000000-0000-4000-8000-000000000001','{"sub":"synthetic-legacy-apple"}','apple',now(),now());
insert into public.profiles(id,auth_user_id,display_name,state)
values ('f7000000-0000-4000-8000-000000000001','f6000000-0000-4000-8000-000000000001',
 'Synthetic legacy deletion','active');

do $test$
declare
  original_record jsonb;
  original_profile jsonb;
  original_secret jsonb;
  failure_message text;
  refused boolean := false;
begin
  perform public.begin_account_deletion('f6000000-0000-4000-8000-000000000001');
  perform public.store_account_deletion_apple_token('f7000000-0000-4000-8000-000000000001',
    'synthetic-legacy-refresh-token');
  select to_jsonb(d) into original_record from private.account_deletions d;
  select to_jsonb(p) into original_profile from public.profiles p;
  select to_jsonb(s) into original_secret from vault.secrets s
    where name=private.account_deletion_secret_name('f7000000-0000-4000-8000-000000000001');
  if original_record->>'phase' is distinct from 'token_ready' or original_secret is null then
    raise exception using errcode='P0001',message='legacy_fixture_required';
  end if;
  begin
    execute (select sql from binding_test_source);
  exception when sqlstate '55000' then
    get stacked diagnostics failure_message = message_text;
    refused := failure_message='account_deletion_legacy_token_binding_required';
  end;
  if not refused then raise exception using errcode='P0001',message='legacy_refusal_required'; end if;
  if original_record is distinct from (select to_jsonb(d) from private.account_deletions d)
    or original_profile is distinct from (select to_jsonb(p) from public.profiles p)
    or original_secret is distinct from (select to_jsonb(s) from vault.secrets s
      where name=private.account_deletion_secret_name('f7000000-0000-4000-8000-000000000001'))
    or exists(select 1 from information_schema.columns where table_schema='private'
      and table_name='account_deletions' and column_name='apple_client_id')
    or to_regprocedure('public.store_account_deletion_apple_token(uuid,text)') is null
    or to_regprocedure('public.store_account_deletion_apple_token(uuid,text,text)') is not null
    or not has_function_privilege('service_role','public.store_account_deletion_apple_token(uuid,text)','EXECUTE')
  then raise exception using errcode='P0001',message='legacy_state_changed'; end if;

  -- Synthetic acknowledgement only: no Apple request occurred. This tests the
  -- migration's compatibility with an existing later phase, not revocation.
  perform public.mark_account_deletion_apple_revoked('f7000000-0000-4000-8000-000000000001');
  execute (select sql from binding_test_source);
  if (select phase from private.account_deletions) is distinct from 'apple_revoked'
    or (select apple_client_id from private.account_deletions) is not null
    or to_regprocedure('public.store_account_deletion_apple_token(uuid,text)') is not null
    or not has_function_privilege('service_role','public.store_account_deletion_apple_token(uuid,text,text)','EXECUTE')
    or has_function_privilege('service_role','private.store_account_deletion_apple_token(uuid,text)','EXECUTE')
  then raise exception using errcode='P0001',message='later_phase_migration_contract'; end if;
end
$test$;
rollback;
do $$ begin
  if exists(select 1 from public.profiles) or exists(select 1 from private.account_deletions)
    or exists(select 1 from auth.users)
    or exists(select 1 from information_schema.columns where table_schema='private'
      and table_name='account_deletions' and column_name='apple_client_id')
  then raise exception using errcode='P0001',message='fixture_rollback_required'; end if;
end $$;
select 'local_legacy_token_refusal_and_later_phase_migration_passed_rolled_back';
