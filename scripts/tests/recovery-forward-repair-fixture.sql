-- Legacy token state in the disposable pre-repair database only.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or current_setting('healthcomp.recovery_fixture',true) is distinct from 'synthetic-20260928'
    or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20260913001400'
    or (select count(*) from public.profiles) <> 2
    or (select count(*) from public.competition_results) <> 1
    or exists(select 1 from public.device_installations)
  then raise exception using errcode='P0001',message='isolated_pre_repair_fixture_required'; end if;
end $$;
insert into public.device_installations(id,profile_id,installation_id,apns_token,environment,state)
values (md5('repair-revoked')::uuid,md5('recovery-profile-1-1')::uuid,
    md5('repair-revoked')::uuid,repeat('a1',32),'sandbox','revoked'),
  (md5('repair-active')::uuid,md5('recovery-profile-1-1')::uuid,
    md5('repair-active')::uuid,repeat('b2',32),'sandbox','active');
commit;
