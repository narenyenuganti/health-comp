-- Exercise the actual forward migration with existing active/revoked tokens.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
set local lock_timeout = '5s';
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or current_setting('server_version_num')::integer / 10000 <> 17
    or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20260913001400'
    or exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.competitions)
    or to_regprocedure('private.clear_retired_installation_apns_token()') is not null
  then raise exception 'empty_local_pre_token_retirement_schema_required'; end if;
end $$;

insert into auth.users(id,aud,role,created_at,updated_at) values
 ('f9100000-0000-4000-8000-000000000001','authenticated','authenticated',now(),now());
insert into public.profiles(id,auth_user_id,display_name,state) values
 ('f9200000-0000-4000-8000-000000000001','f9100000-0000-4000-8000-000000000001','Token migration fixture','active');
insert into public.device_installations(id,profile_id,installation_id,apns_token,environment,state) values
 ('f9500000-0000-4000-8000-000000000001','f9200000-0000-4000-8000-000000000001',
  'f9500000-0000-4000-8000-000000000001',repeat('a1',32),'sandbox','revoked'),
 ('f9500000-0000-4000-8000-000000000002','f9200000-0000-4000-8000-000000000001',
  'f9500000-0000-4000-8000-000000000002',repeat('b2',32),'sandbox','active');
create temporary table original_installations as select * from public.device_installations;
create temporary table original_profiles as select * from public.profiles;
select :'token_migration' \gexec

do $$ begin
  if (select count(*) from public.device_installations) <> 2 or exists (
    select 1 from original_installations old_row full join public.device_installations new_row using(id)
    where to_jsonb(new_row) is distinct from case when old_row.state = 'revoked'
      then jsonb_set(to_jsonb(old_row),'{apns_token}','null'::jsonb)
      else to_jsonb(old_row) end
  ) or exists(select * from public.profiles except select * from original_profiles)
    or exists(select * from original_profiles except select * from public.profiles)
  then raise exception 'retired_token_only_backfill_required'; end if;
  begin
    update public.device_installations set state='active'
      where id='f9500000-0000-4000-8000-000000000001';
    raise exception 'active_installation_without_token_accepted';
  exception when check_violation then null;
  end;
  update public.device_installations set state='revoked'
    where id='f9500000-0000-4000-8000-000000000002';
  if exists(select 1 from public.device_installations where apns_token is not null)
  then raise exception 'future_retirement_token_clear_required'; end if;
end $$;
rollback;
do $$ begin
  if exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.device_installations)
    or to_regprocedure('private.clear_retired_installation_apns_token()') is not null
  then raise exception 'fixture_and_migration_rollback_required'; end if;
end $$;
select 'local_retired_token_backfill_preservation_passed_rolled_back';
