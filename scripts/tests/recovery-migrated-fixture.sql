-- Synthetic input for this test's disposable local database only.
-- Batch 1 precedes the exported snapshot; batch 2 is the committed control.
\set ON_ERROR_STOP on
\set VERBOSITY sqlstate
\set SHOW_CONTEXT never
begin;
set local statement_timeout = '15s';
set local lock_timeout = '3s';
set local role postgres;
select set_config('healthcomp.fixture_batch', :'batch', true) as fixture_batch \gset
do $$
declare
  batch integer := current_setting('healthcomp.fixture_batch')::integer;
  owner_id uuid := md5('recovery-profile-' || batch || '-1')::uuid;
  opponent_id uuid := md5('recovery-profile-' || batch || '-2')::uuid;
  competition_id uuid := md5('recovery-competition-' || batch)::uuid;
  result jsonb;
begin
  if current_database() <> 'postgres' or inet_server_addr() is not null
    or current_setting('healthcomp.recovery_fixture', true) is distinct from 'synthetic-20260928'
    or batch not in (1,2)
    or (select max(version) from supabase_migrations.schema_migrations) <> '20260928001600'
    or (select count(*) from public.competitions) <> batch - 1
    or (select count(*) from auth.users) <> 2 * (batch - 1)
  then raise exception using errcode='P0001',message='isolated_fixture_required'; end if;

  insert into auth.users(id,aud,role,created_at,updated_at)
  select md5('recovery-auth-' || batch || '-' || n)::uuid,
    'authenticated','authenticated',now(),now() from generate_series(1,2) n;
  insert into public.profiles(id,auth_user_id,display_name,state)
  select md5('recovery-profile-' || batch || '-' || n)::uuid,
    md5('recovery-auth-' || batch || '-' || n)::uuid,'Synthetic recovery ' || n,'active'
    from generate_series(1,2) n;
  insert into public.competitions(id,creator_profile_id,time_zone_identifier,start_day,
    scoring_policy_identity,lifecycle,invitation_expires_at,best_available_deadline)
  values(competition_id,owner_id,'UTC','2000-01-01',
    'healthcomp.activity-score.v1','tallying','1999-12-31','2000-01-09');
  insert into public.competition_participants(competition_id,profile_id,role,state)
  values(competition_id,owner_id,'creator','accepted'),
    (competition_id,opponent_id,'invitee','accepted');
  perform set_config('request.jwt.claims','{"role":"service_role"}',true);
  result := public.finalize_competition(competition_id);
  if result->>'disposition' is distinct from 'finalized'
    or result->>'basis' is distinct from 'best_available'
  then raise exception using errcode='P0001',message='fixture_finalization_required'; end if;
end $$;
commit;
