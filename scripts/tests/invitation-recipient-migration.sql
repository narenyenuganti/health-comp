\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
set local lock_timeout = '5s';
do $$ begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_user <> 'postgres' or pg_is_in_recovery()
    or (select max(version) from supabase_migrations.schema_migrations) is distinct from '20261002001700'
    or exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.competitions)
  then raise exception 'empty_local_pre_recipient_schema_required'; end if;
end $$;
insert into auth.users(id) values
 ('f6100000-0000-4000-8000-000000000001'),
 ('f6100000-0000-4000-8000-000000000002');
insert into public.profiles(id,auth_user_id,display_name,state) values
 ('f6200000-0000-4000-8000-000000000001','f6100000-0000-4000-8000-000000000001','Migration sender','active'),
 ('f6200000-0000-4000-8000-000000000002','f6100000-0000-4000-8000-000000000002','Migration recipient','active');
create temporary table legacy_invites(label text primary key,id uuid);
do $$ begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  insert into legacy_invites select 'pending',public.create_competition_invite(
    decode(repeat('61',32),'hex'),'UTC',null,'f6100000-0000-4000-8000-000000000001',
    'f6300000-0000-4000-8000-000000000001',1::smallint);
  insert into legacy_invites select 'accepted',public.create_competition_invite(
    decode(repeat('62',32),'hex'),'UTC',null,'f6100000-0000-4000-8000-000000000001',
    'f6300000-0000-4000-8000-000000000002',1::smallint);
  perform set_config('request.jwt.claims','{"role":"authenticated","sub":"f6100000-0000-4000-8000-000000000002"}',true);
  perform public.claim_competition_invite(decode(repeat('62',32),'hex'));
end $$;
insert into public.competitions(id,creator_profile_id,time_zone_identifier,start_day,
 scoring_policy_identity,lifecycle,invitation_expires_at,best_available_deadline) values
 ('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001',
 'UTC',current_date-20,'healthcomp.activity-score.v1','tallying',now()-interval '21 days',now()-interval '10 days');
insert into public.competition_participants(competition_id,profile_id,role,state) values
 ('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001','creator','accepted'),
 ('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000002','invitee','accepted');
insert into public.daily_score_revisions(competition_id,participant_profile_id,day_ordinal,
 semantic_event_id,client_revision,move_mode,stand_mode,move_basis_points,exercise_basis_points,
 stand_basis_points,accepted_centi_points,availability_reason,scoring_policy_identity,
 wire_content_sha256,server_seq,evaluated_at)
values('f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001',1,
 'f6500000-0000-4000-8000-000000000001',1,'activeEnergyKilocalories','standHours',100,0,0,100,
 'available','healthcomp.activity-score.v1',private.wire_score_digest_v1(
   'f6400000-0000-4000-8000-000000000001','f6200000-0000-4000-8000-000000000001',1::smallint,
   'activeEnergyKilocalories','standHours',100,0,0,100,'available','healthcomp.activity-score.v1',1),
 1,(current_date-20)::timestamptz+interval '1 hour');
do $$ begin
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  perform public.finalize_competition('f6400000-0000-4000-8000-000000000001');
end $$;
set constraints all immediate;
update public.competition_participants set state='anonymized'
 where competition_id='f6400000-0000-4000-8000-000000000001'
   and profile_id='f6200000-0000-4000-8000-000000000002';
create temporary table original_competitions as select * from public.competitions;
create temporary table original_profiles as select * from public.profiles;
create temporary table original_participants as select * from public.competition_participants;
create temporary table original_scores as select * from public.daily_score_revisions;
create temporary table original_results as select * from public.competition_results;
create temporary table original_history as select * from public.competition_change_log;
select :'recipient_migration' \gexec
do $$ begin
  if (select count(*) from public.daily_score_revisions) <> 1
    or (select count(*) from public.competition_results) <> 1
    or exists(select * from original_profiles except select * from public.profiles)
    or exists(select * from public.profiles except select * from original_profiles)
    or exists(select * from original_participants except select * from public.competition_participants)
    or exists(select * from public.competition_participants except select * from original_participants)
    or exists(select * from original_scores except select * from public.daily_score_revisions)
    or exists(select * from original_results except select * from public.competition_results)
    or exists(select * from original_history except select * from public.competition_change_log)
    or exists(select 1 from original_competitions o full join public.competitions n using(id)
      where case when o.lifecycle='pending'
        then n.lifecycle <> 'expired' or n.next_server_seq <> o.next_server_seq+1
          or to_jsonb(n)-array['invited_profile_id','lifecycle','updated_at','next_server_seq']
            is distinct from to_jsonb(o)-array['lifecycle','updated_at','next_server_seq']
        else to_jsonb(n)-'invited_profile_id' is distinct from to_jsonb(o) end)
  then raise exception 'history_and_accepted_schedule_preservation_required'; end if;
end $$;
rollback;
do $$ begin
  if exists(select 1 from public.profiles) or exists(select 1 from auth.users)
    or exists(select 1 from public.competitions)
    or to_regprocedure('public.resolve_invitation_recipient(uuid)') is not null
  then raise exception 'fixture_and_migration_rollback_required'; end if;
end $$;
select 'local_recipient_migration_history_preserved_rolled_back';
