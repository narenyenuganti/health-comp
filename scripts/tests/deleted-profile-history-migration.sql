-- Exercise the actual migration on already-anonymized legacy history.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
set local lock_timeout = '5s';
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20260906001300'
    or exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.competitions)
  then raise exception 'empty_local_pre_redaction_schema_required'; end if;
end $$;
create temporary table history_test_source(sql text);
insert into history_test_source values (:'history_migration');

insert into auth.users(id,aud,role,created_at,updated_at) values
 ('f8100000-0000-4000-8000-000000000001','authenticated','authenticated',now(),now()),
 ('f8100000-0000-4000-8000-000000000002','authenticated','authenticated',now(),now());
insert into public.profiles(id,auth_user_id,display_name,state) values
 ('f8200000-0000-4000-8000-000000000001','f8100000-0000-4000-8000-000000000001','Legacy deleting','active'),
 ('f8200000-0000-4000-8000-000000000002','f8100000-0000-4000-8000-000000000002','Legacy remaining','active');
insert into public.competitions(id,creator_profile_id,time_zone_identifier,start_day,
 scoring_policy_identity,lifecycle,invitation_expires_at,best_available_deadline) values
 ('f8300000-0000-4000-8000-000000000001','f8200000-0000-4000-8000-000000000001',
 'UTC',current_date-20,'healthcomp.activity-score.v1','completed',now()-interval '21 days',now()-interval '10 days');
insert into public.competition_participants(competition_id,profile_id,role,state) values
 ('f8300000-0000-4000-8000-000000000001','f8200000-0000-4000-8000-000000000001','creator','accepted'),
 ('f8300000-0000-4000-8000-000000000001','f8200000-0000-4000-8000-000000000002','invitee','accepted');
set constraints all immediate;
update public.profiles set display_name=display_name || ' changed';
update public.competition_participants set state='anonymized'
 where profile_id='f8200000-0000-4000-8000-000000000001';
update public.profiles set state='anonymized',auth_user_id=null,
 display_name='Former competitor',anonymized_at=now()
 where id='f8200000-0000-4000-8000-000000000001';
create temporary table original_history as select * from public.competition_change_log;
create temporary table original_profiles as select * from public.profiles;
create temporary table original_competitions as select * from public.competitions;

-- Inject a mixed mutation into the real backfill UPDATE before its row guard.
-- The old name is still present, so the redaction preconditions are eligible.
create function pg_temp.tamper_history_redaction() returns trigger
language plpgsql as $$
begin
  case tg_argv[0]
    when 'time' then new.occurred_at := old.occurred_at + interval '1 second';
    when 'identity' then new.entity_id := 'f8200000-0000-4000-8000-000000000002';
    when 'payload' then new.payload_snapshot := new.payload_snapshot || '{"extra":"unapproved"}'::jsonb;
  end case;
  return new;
end;
$$;
do $test$
declare first_pass jsonb; mutation text; refused boolean;
begin
  if (select count(*) from original_history where entity_id='f8200000-0000-4000-8000-000000000001'
      and change_kind='profile_presentation_changed'
      and payload_snapshot->>'display_name'='Legacy deleting changed') <> 1
  then raise exception 'historical_name_fixture_required'; end if;
  foreach mutation in array array['time','identity','payload'] loop
    -- PostgreSQL fires same-event triggers by name: this precedes reject_*.
    execute format('create trigger a_test_redaction_tamper before update on public.competition_change_log
      for each row execute function pg_temp.tamper_history_redaction(%L)', mutation);
    refused := false;
    begin
      execute (select sql from history_test_source);
    exception when sqlstate '55000' then
      refused := sqlerrm = 'competition_change_log is append-only';
    end;
    if not refused then raise exception 'mixed_redaction_mutation_was_not_rejected: %', mutation; end if;
    drop trigger a_test_redaction_tamper on public.competition_change_log;
  end loop;
  execute (select sql from history_test_source);
  if exists(
    select 1 from original_history old_row full join public.competition_change_log new_row
      using (competition_id,server_seq)
    where to_jsonb(new_row) is distinct from case
      when old_row.entity_id='f8200000-0000-4000-8000-000000000001'
        and old_row.change_kind in ('profile_presentation_changed','profile_anonymized')
      then jsonb_set(to_jsonb(old_row),'{payload_snapshot,display_name}','"Former competitor"')
      else to_jsonb(old_row) end
  ) or exists(select * from public.profiles except select * from original_profiles)
    or exists(select * from public.competitions except select * from original_competitions)
  then raise exception 'name_only_backfill_required'; end if;
  select jsonb_agg(to_jsonb(r) order by competition_id,server_seq) into first_pass
    from public.competition_change_log r;
  execute (select sql from history_test_source);
  if first_pass is distinct from (select jsonb_agg(to_jsonb(r) order by competition_id,server_seq)
    from public.competition_change_log r)
  then raise exception 'idempotent_backfill_required'; end if;
end
$test$;
rollback;
do $$ begin
  if exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.competitions)
  then raise exception 'fixture_rollback_required'; end if;
end $$;
select 'local_history_redaction_preservation_and_idempotence_passed_rolled_back';
