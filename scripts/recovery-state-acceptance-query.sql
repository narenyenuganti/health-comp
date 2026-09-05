-- SELECT-only component. Invoke through recovery-state-acceptance.sql in a fresh
-- session. Exact schema/constraints/helpers, transport, Auth/session retirement,
-- Vault quarantine and genuine deletion/history evidence remain separate gates.
-- No identifiers, names, individual timestamps, token values or scores are output.
with expected_tables(schema_name, table_name, expected_rls, expected_force, authenticated_select) as (
  values
    ('public', 'profiles', true, false, false),
    ('public', 'competitions', true, false, true),
    ('public', 'competition_participants', true, false, true),
    ('public', 'competition_invites', true, false, false),
    ('public', 'competition_change_log', true, false, false),
    ('public', 'daily_score_revisions', true, false, true),
    ('public', 'participant_finalization_attestations', true, false, true),
    ('public', 'competition_results', true, false, true),
    ('public', 'competition_awards', true, false, true),
    ('public', 'device_installations', true, false, false),
    ('public', 'support_events', true, false, false),
    ('private', 'competition_notification_mutes', false, false, false),
    ('private', 'competition_notification_work', true, true, false),
    ('private', 'account_deletions', true, true, false),
    ('private', 'app_attest_keys', true, true, false),
    ('private', 'app_attest_challenges', true, true, false),
    ('private', 'app_attest_submission_grants', true, true, false)
),
-- Native types for columns used by the predicates. Other columns/constraints
-- still require exact migrated-schema compatibility; this is not its substitute.
required_column_groups(table_name, type_name, column_names) as (
  values
    ('profiles', 'uuid', array['id','auth_user_id']),
    ('profiles', 'text', array['display_name','state']),
    ('profiles', 'timestamptz', array['anonymized_at','created_at','updated_at']),
    ('competitions', 'uuid', array['id','creator_profile_id']),
    ('competitions', 'text', array['lifecycle']),
    ('competition_participants', 'uuid', array['competition_id','profile_id']),
    ('competition_participants', 'text', array['state']),
    ('competition_invites', 'uuid', array['id','competition_id']),
    ('competition_invites', 'timestamptz', array['consumed_at']),
    ('competition_change_log', 'uuid', array['competition_id']),
    ('competition_change_log', 'int8', array['server_seq']),
    ('daily_score_revisions', 'uuid', array['competition_id']),
    ('participant_finalization_attestations', 'uuid', array['competition_id']),
    ('competition_results', 'uuid', array['competition_id','participant_a_profile_id','participant_b_profile_id']),
    ('competition_awards', 'uuid', array['competition_id']),
    ('device_installations', 'uuid', array['id','profile_id','installation_id']),
    ('device_installations', 'text', array['state']),
    ('support_events', 'uuid', array['id','profile_id']),
    ('support_events', 'text', array['kind','code']),
    ('competition_notification_mutes', 'uuid', array['profile_id','opponent_profile_id']),
    ('competition_notification_work', 'uuid', array['id','recipient_profile_id','source_profile_id','lease_token']),
    ('competition_notification_work', 'text', array['state']),
    ('competition_notification_work', 'timestamptz', array['lease_expires_at']),
    ('competition_notification_work', 'bytea', array['leased_apns_token_sha256']),
    ('account_deletions', 'uuid', array['profile_id','auth_user_id']),
    ('account_deletions', 'text', array['apple_provider_id','phase']),
    ('account_deletions', 'timestamptz', array['started_at','updated_at','completed_at']),
    ('app_attest_keys', 'uuid', array['profile_id','installation_id']),
    ('app_attest_challenges', 'uuid', array['profile_id','installation_id']),
    ('app_attest_submission_grants', 'uuid', array['profile_id','installation_id'])
),
required_columns as (
  select g.table_name, c.column_name,
    pg_catalog.to_regtype('pg_catalog.' || g.type_name) as type_oid
  from required_column_groups g
  cross join lateral pg_catalog.unnest(g.column_names) c(column_name)
),
table_catalog as materialized (
  select e.*, c.oid, c.relrowsecurity, c.relforcerowsecurity,
    (c.oid is not null and c.relkind = 'r' and not c.relispartition
      and not exists (select 1 from pg_catalog.pg_inherits i
        where i.inhrelid = c.oid or i.inhparent = c.oid)
      and not exists (
        select 1 from required_columns rc
        left join pg_catalog.pg_attribute a on a.attrelid = c.oid
          and a.attname = rc.column_name and a.attnum > 0 and not a.attisdropped
        where rc.table_name = e.table_name and a.atttypid is distinct from rc.type_oid
      )) as supported
  from expected_tables e
  left join pg_catalog.pg_namespace n on n.nspname = e.schema_name
  left join pg_catalog.pg_class c on c.relnamespace = n.oid and c.relname = e.table_name
),
scoped_relations as (
  select c.oid, n.nspname as schema_name, c.relname as table_name
  from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public','private') and c.relkind in ('r','p','v','m','f')
),
api_roles(role_name) as (values ('public'), ('anon'), ('authenticated'), ('service_role')),
table_privileges(privilege_name) as (
  values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE'), ('TRUNCATE'), ('REFERENCES'), ('TRIGGER'), ('MAINTAIN')
),
column_privileges(privilege_name) as (values ('SELECT'), ('INSERT'), ('UPDATE'), ('REFERENCES')),
table_access as (
  select
    pg_catalog.has_table_privilege(r.role_name, t.oid, p.privilege_name) as held,
    pg_catalog.has_table_privilege(r.role_name, t.oid, p.privilege_name || ' WITH GRANT OPTION') as grantable,
    (r.role_name = 'authenticated' and p.privilege_name = 'SELECT' and t.authenticated_select) as expected
  from table_catalog t cross join api_roles r cross join table_privileges p
  where t.oid is not null
),
column_access as (
  select
    pg_catalog.has_column_privilege(r.role_name, t.oid, a.attnum, p.privilege_name) as held,
    pg_catalog.has_column_privilege(r.role_name, t.oid, a.attnum, p.privilege_name || ' WITH GRANT OPTION') as grantable,
    (r.role_name = 'authenticated' and p.privilege_name = 'SELECT'
      and (t.authenticated_select or (t.schema_name = 'public' and t.table_name = 'profiles'
        and a.attname in ('id','display_name')))) as expected
  from table_catalog t
  join pg_catalog.pg_attribute a on a.attrelid = t.oid and a.attnum > 0 and not a.attisdropped
  cross join api_roles r cross join column_privileges p
),
-- Migration00200 expressions, deparsed under PostgreSQL17/search_path=pg_catalog.
-- Whitespace alone is normalized. Do not execute policy helpers or accept just
-- names/counts; their function definitions are a separate schema prerequisite.
expected_policies(table_name, policy_name, expression) as (
  values
    ('profiles', 'profiles_participant_read', '(SELECTprivate.can_view_profile(profiles.id)AScan_view_profile)'),
    ('competitions', 'competitions_participant_read', '(SELECTprivate.is_competition_participant(competitions.id)ASis_competition_participant)'),
    ('competition_participants', 'competition_participants_participant_read', '(SELECTprivate.is_competition_participant(competition_participants.competition_id)ASis_competition_participant)'),
    ('daily_score_revisions', 'daily_score_revisions_participant_read', '(SELECTprivate.is_competition_participant(daily_score_revisions.competition_id)ASis_competition_participant)'),
    ('participant_finalization_attestations', 'participant_attestations_participant_read', '(SELECTprivate.is_competition_participant(participant_finalization_attestations.competition_id)ASis_competition_participant)'),
    ('competition_results', 'competition_results_participant_read', '(SELECTprivate.is_competition_participant(competition_results.competition_id)ASis_competition_participant)'),
    ('competition_awards', 'competition_awards_participant_read', '(SELECTprivate.is_competition_participant(competition_awards.competition_id)ASis_competition_participant)'),
    ('device_installations', 'device_installations_owner_read', '(profile_id=(SELECTprivate.current_profile_id()AScurrent_profile_id))')
),
actual_policies as (
  select s.schema_name, s.table_name, p.polname, p.polcmd, p.polpermissive,
    p.polroles, p.polwithcheck,
    pg_catalog.regexp_replace(pg_catalog.pg_get_expr(p.polqual, p.polrelid, false), '[[:space:]]', '', 'g') as expression
  from scoped_relations s join pg_catalog.pg_policy p on p.polrelid = s.oid
),
policy_checks as (
  select (a.polname is not null and a.polcmd = 'r' and a.polpermissive
    and a.polroles = array[(select oid from pg_catalog.pg_roles where rolname = 'authenticated')]
    and a.polwithcheck is null and a.expression = e.expression) as matches
  from expected_policies e left join actual_policies a on a.schema_name = 'public'
    and a.table_name = e.table_name and a.polname = e.policy_name
),
profiles as materialized (select id, auth_user_id, display_name, state,
  anonymized_at, created_at, updated_at from only public.profiles),
deletions as materialized (select profile_id, auth_user_id, apple_provider_id,
  phase, started_at, updated_at, completed_at from only private.account_deletions),
deactivated as (select id, state from profiles where state in ('deleting','anonymized')),
attest_rows as materialized (
  select profile_id, installation_id from only private.app_attest_keys
  union all select profile_id, installation_id from only private.app_attest_challenges
  union all select profile_id, installation_id from only private.app_attest_submission_grants
),
completion_events as materialized (
  select profile_id from only public.support_events
  where kind = 'account_deletion' and code = 'completed'
)
select pg_catalog.json_build_object(
  'receipt_version', 1,
  'application_tables_checked', (select count(*) from table_catalog where supported),
  'application_tables_missing_or_unsupported', (select count(*) from table_catalog where supported is not true),
  'application_tables_unexpected', (select count(*) from scoped_relations s where not exists (
    select 1 from expected_tables e where e.schema_name = s.schema_name and e.table_name = s.table_name)),
  'rls_flag_mismatches', (select count(*) from table_catalog where oid is not null and
    (relrowsecurity is distinct from expected_rls or relforcerowsecurity is distinct from expected_force)),
  'table_privilege_mismatches', (select count(*) from table_access
    where held is distinct from expected or grantable is distinct from false),
  'column_privilege_mismatches', (select count(*) from column_access
    where held is distinct from expected or grantable is distinct from false),
  'policy_mismatches', (select count(*) from policy_checks where matches is not true)
    + (select count(*) from actual_policies a where not exists (
      select 1 from expected_policies e where a.schema_name = 'public'
        and e.table_name = a.table_name and e.policy_name = a.polname)),
  'profiles_checked', (select count(*) from profiles),
  'profiles_invalid_shape', (select count(*) from profiles where (
    id is not null and created_at is not null and updated_at is not null and (
      (state in ('active','deleting') and auth_user_id is not null and anonymized_at is null
        and pg_catalog.btrim(display_name) <> '' and display_name <> 'Former competitor')
      or (state = 'anonymized' and auth_user_id is null
        and display_name = 'Former competitor' and anonymized_at is not null)
    )) is not true),
  'profiles_anonymized', (select count(*) from profiles where state = 'anonymized'),
  'deletion_records_checked', (select count(*) from deletions),
  'deletion_records_invalid_shape', (select count(*) from deletions where (
    profile_id is not null and started_at is not null and updated_at is not null
    and updated_at >= started_at and (completed_at is null or completed_at >= started_at)
    and ((phase in ('prepared','token_ready','apple_revoked','auth_delete_pending')
      and auth_user_id is not null and apple_provider_id is not null
      and pg_catalog.btrim(apple_provider_id) <> '' and apple_provider_id !~ '[[:cntrl:]]'
      and pg_catalog.char_length(apple_provider_id) <= 255 and completed_at is null)
      or (phase = 'completed' and auth_user_id is null and apple_provider_id is null and completed_at is not null))
    ) is not true),
  'deletion_phase_profile_mismatches', (select count(*) from deletions d where not exists (
    select 1 from profiles p where p.id = d.profile_id and (
      (d.phase = 'prepared' and p.state = 'active' and p.auth_user_id = d.auth_user_id)
      or (d.phase in ('token_ready','apple_revoked') and p.state = 'deleting' and p.auth_user_id = d.auth_user_id)
      or (d.phase in ('auth_delete_pending','completed') and p.state = 'anonymized'))))
    + (select count(*) from deactivated p where not exists (select 1 from deletions d where d.profile_id = p.id)),
  'deletions_prepared', (select count(*) from deletions where phase = 'prepared'),
  'deletions_token_ready', (select count(*) from deletions where phase = 'token_ready'),
  'deletions_apple_revoked', (select count(*) from deletions where phase = 'apple_revoked'),
  'deletions_auth_delete_pending', (select count(*) from deletions where phase = 'auth_delete_pending'),
  'deletions_completed', (select count(*) from deletions where phase = 'completed'),
  'anonymized_profiles_without_completed_deletion', (select count(*) from profiles p
    where p.state = 'anonymized' and not exists (select 1 from deletions d where d.profile_id = p.id and d.phase = 'completed')),
  'deactivated_profiles_with_active_installations', (select count(*) from deactivated p where exists (
    select 1 from only public.device_installations i where i.profile_id = p.id and i.state = 'active')),
  'deactivated_profiles_with_live_notification_work', (select count(*) from deactivated p where exists (
    select 1 from only private.competition_notification_work w
    where (w.recipient_profile_id = p.id or w.source_profile_id = p.id)
      and (w.state in ('pending','leased') or w.lease_token is not null
        or w.lease_expires_at is not null or w.leased_apns_token_sha256 is not null))),
  'deactivated_profiles_with_mute_links', (select count(*) from deactivated p where exists (
    select 1 from only private.competition_notification_mutes m where m.profile_id = p.id or m.opponent_profile_id = p.id)),
  'deactivated_profiles_with_app_attest_rows', (select count(*) from deactivated p where exists (
    select 1 from attest_rows a where a.profile_id = p.id)),
  'revoked_installations_with_app_attest_rows', (select count(*) from only public.device_installations i
    where i.state = 'revoked' and exists (select 1 from attest_rows a
      where a.profile_id = i.profile_id and a.installation_id = i.installation_id)),
  'anonymized_profiles_with_nonanonymized_participants', (select count(*) from profiles p
    where p.state = 'anonymized' and exists (select 1 from only public.competition_participants cp
      where cp.profile_id = p.id and cp.state is distinct from 'anonymized')),
  'deactivated_profiles_with_unfinished_competitions', (select count(*) from deactivated p where exists (
    select 1 from only public.competition_participants cp join only public.competitions c on c.id = cp.competition_id
    where cp.profile_id = p.id and c.lifecycle in ('pending','scheduled','active','ends_today','tallying'))),
  'deactivated_profiles_with_unconsumed_cancelled_invites', (select count(*) from deactivated p where exists (
    select 1 from only public.competition_participants cp join only public.competitions c on c.id = cp.competition_id
    join only public.competition_invites i on i.competition_id = c.id
    where cp.profile_id = p.id and c.lifecycle = 'cancelled' and i.consumed_at is null)),
  'completed_deletions_with_bad_completion_event_count', (select count(*) from deletions d
    where d.phase = 'completed' and (select count(*) from completion_events e where e.profile_id = d.profile_id) <> 1),
  'completion_events_without_completed_deletion', (select count(*) from completion_events e
    where not exists (select 1 from deletions d where d.profile_id = e.profile_id and d.phase = 'completed')),
  'anonymized_profiles_in_results', (select count(*) from profiles p where p.state = 'anonymized' and exists (
    select 1 from only public.competition_results r where r.participant_a_profile_id = p.id or r.participant_b_profile_id = p.id))
);
