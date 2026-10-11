-- Called on the isolated restored target; no tokens, IDs or rows are printed.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or current_setting('healthcomp.recovery_fixture',true) is distinct from 'synthetic-20260928'
  then raise exception using errcode='P0001',message='isolated_repair_target_required'; end if;
  if (select count(*) from public.device_installations) <> 2
    or (select count(*) from public.device_installations where state='revoked' and apns_token is null) <> 1
    or (select count(*) from public.device_installations where state='active' and apns_token=repeat('b2',32)) <> 1
  then raise exception using errcode='P0001',message='restored_retired_token_repair_required'; end if;
end $$;
savepoint future_retirement;
do $$ begin
  begin
    update public.device_installations set state='active'
      where id=md5('repair-revoked')::uuid;
    raise exception using errcode='P0001',message='tokenless_reactivation_accepted';
  exception when check_violation then null;
  end;
  update public.device_installations set state='revoked'
    where id=md5('repair-active')::uuid;
  if (select count(*) from public.device_installations where state='revoked' and apns_token is null) <> 2
  then raise exception using errcode='P0001',message='future_retired_token_not_cleared'; end if;
end $$;
rollback to savepoint future_retirement;
