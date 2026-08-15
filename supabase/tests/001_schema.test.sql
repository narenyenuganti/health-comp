begin;

create extension if not exists pgtap with schema extensions;
set local search_path = extensions, public, pg_catalog;

select plan(20);

select has_table('public', 'profiles', 'profiles exists');
select has_table('public', 'competitions', 'competitions exists');
select has_table('public', 'competition_participants', 'competition_participants exists');
select has_table('public', 'competition_invites', 'competition_invites exists');
select has_table('public', 'daily_score_revisions', 'daily_score_revisions exists');
select has_table('public', 'participant_finalization_attestations', 'participant_finalization_attestations exists');
select has_table('public', 'competition_results', 'competition_results exists');
select has_table('public', 'competition_awards', 'competition_awards exists');
select has_table('public', 'device_installations', 'device_installations exists');
select has_table('public', 'support_events', 'support_events exists');
select has_table('public', 'competition_change_log', 'competition_change_log exists');

select has_schema('private', 'private helper schema exists');
select has_extension('pgcrypto', 'pgcrypto is installed for wire digests');
select has_extension('pg_net', 'pg_net is installed for notification wakeups');
select has_extension('pg_cron', 'pg_cron is installed for hosted schedules');

select has_pk('public', 'profiles', 'profiles has a primary key');
select has_pk('public', 'competitions', 'competitions has a primary key');
select has_pk('public', 'competition_participants', 'competition_participants has a primary key');
select has_pk('public', 'competition_results', 'competition_results has a primary key');
select has_pk('public', 'competition_change_log', 'competition_change_log has a primary key');

select * from finish();
rollback;
