-- Synthetic projected schema only. The guarded harness owns this empty database.
-- No Auth/Vault objects, live tokens, migration execution, or product triggers.
-- Source column types: migrations 00100, 00450, 00650, 00700, 00750, 00800.
-- CHECK/FK/NOT NULL constraints are intentionally absent so corruption is testable.
-- Real migrated-schema compatibility is a separate CI invocation of the operator.
\if :build_schema
create schema private;
create table public.profiles (
  id uuid, auth_user_id uuid, display_name text, state text,
  anonymized_at timestamptz, created_at timestamptz, updated_at timestamptz
);
create table public.competitions (id uuid, creator_profile_id uuid, lifecycle text);
create table public.competition_participants (competition_id uuid, profile_id uuid, state text);
create table public.competition_invites (id uuid, competition_id uuid, consumed_at timestamptz);
create table public.competition_change_log (competition_id uuid, server_seq bigint);
create table public.daily_score_revisions (competition_id uuid);
create table public.participant_finalization_attestations (competition_id uuid);
create table public.competition_results (
  competition_id uuid, participant_a_profile_id uuid, participant_b_profile_id uuid
);
create table public.competition_awards (competition_id uuid);
create table public.device_installations (
  id uuid, profile_id uuid, installation_id uuid, state text
);
create table public.support_events (id uuid, profile_id uuid, kind text, code text);
create table private.competition_notification_mutes (profile_id uuid, opponent_profile_id uuid);
create table private.competition_notification_work (
  id uuid, recipient_profile_id uuid, source_profile_id uuid, state text,
  lease_token uuid, lease_expires_at timestamptz, leased_apns_token_sha256 bytea
);
create table private.account_deletions (
  profile_id uuid, auth_user_id uuid, apple_provider_id text, phase text,
  started_at timestamptz, updated_at timestamptz, completed_at timestamptz
);
create table private.app_attest_keys (key_id text, profile_id uuid, installation_id uuid);
create table private.app_attest_challenges (id uuid, profile_id uuid, installation_id uuid);
create table private.app_attest_submission_grants (id uuid, profile_id uuid, installation_id uuid);

-- Policy expressions are copied at runtime from immutable migration 00200,
-- never from the operator oracle. These signature-only fixture helpers MUST NOT
-- execute during an aggregate catalog inspection (helper implementation is outside
-- this projected-schema test). A call fails, rather than returning a mock truth.
create function private.current_profile_id() returns uuid language plpgsql as $$
begin raise exception using errcode = 'P0002', message = 'policy_helper_must_not_execute'; end $$;
create function private.can_view_profile(uuid) returns boolean language plpgsql as $$
begin raise exception using errcode = 'P0002', message = 'policy_helper_must_not_execute'; end $$;
create function private.is_competition_participant(uuid) returns boolean language plpgsql as $$
begin raise exception using errcode = 'P0002', message = 'policy_helper_must_not_execute'; end $$;
revoke all on all functions in schema private from public, anon, authenticated, service_role;
grant usage on schema private to authenticated;
grant execute on function private.current_profile_id(), private.can_view_profile(uuid),
  private.is_competition_participant(uuid) to authenticated;

alter table public.profiles enable row level security;
alter table public.competitions enable row level security;
alter table public.competition_participants enable row level security;
alter table public.competition_invites enable row level security;
alter table public.competition_change_log enable row level security;
alter table public.daily_score_revisions enable row level security;
alter table public.participant_finalization_attestations enable row level security;
alter table public.competition_results enable row level security;
alter table public.competition_awards enable row level security;
alter table public.device_installations enable row level security;
alter table public.support_events enable row level security;
alter table private.account_deletions enable row level security;
alter table private.account_deletions force row level security;
alter table private.competition_notification_work enable row level security;
alter table private.competition_notification_work force row level security;
alter table private.app_attest_keys enable row level security;
alter table private.app_attest_keys force row level security;
alter table private.app_attest_challenges enable row level security;
alter table private.app_attest_challenges force row level security;
alter table private.app_attest_submission_grants enable row level security;
alter table private.app_attest_submission_grants force row level security;
revoke all on all tables in schema public, private from public, anon, authenticated, service_role;
grant select (id, display_name) on public.profiles to authenticated;
grant select on public.competitions, public.competition_participants,
  public.daily_score_revisions, public.participant_finalization_attestations,
  public.competition_results, public.competition_awards to authenticated;
\endif

\if :seed_rows
truncate public.profiles, public.competitions, public.competition_participants,
  public.competition_invites, public.competition_change_log, public.daily_score_revisions,
  public.participant_finalization_attestations, public.competition_results,
  public.competition_awards, public.device_installations, public.support_events,
  private.competition_notification_mutes, private.competition_notification_work,
  private.account_deletions, private.app_attest_keys, private.app_attest_challenges,
  private.app_attest_submission_grants;
insert into public.profiles
select md5('profile-' || n)::uuid,
  case when n in (4, 5) then null else md5('auth-' || n)::uuid end,
  case when n in (4, 5) then 'Former competitor' else 'Synthetic profile ' || n end,
  case when n in (4, 5) then 'anonymized' when n in (2, 3) then 'deleting' else 'active' end,
  case when n in (4, 5) then '2026-09-01 12:00:00+00'::timestamptz end,
  '2026-09-01 10:00:00+00', '2026-09-01 12:00:00+00'
from generate_series(1, 7) n;
insert into private.account_deletions
select md5('profile-' || n)::uuid,
  case when n = 5 then null else md5('auth-' || n)::uuid end,
  case when n = 5 then null else 'synthetic-apple-' || n end,
  (array['prepared','token_ready','apple_revoked','auth_delete_pending','completed'])[n],
  '2026-09-01 10:00:00+00', '2026-09-01 12:00:00+00',
  case when n = 5 then '2026-09-01 12:00:00+00'::timestamptz end
from generate_series(1, 5) n;
insert into public.support_events values
  (md5('completion-5')::uuid, md5('profile-5')::uuid, 'account_deletion', 'completed'),
  (md5('other-event')::uuid, md5('profile-6')::uuid, 'account_deletion', 'started');
insert into public.competitions
select md5('competition-' || n)::uuid, md5('profile-6')::uuid,
  case n when 102 then 'archived' when 103 then 'cancelled'
    when 104 then 'active' when 105 then 'cancelled' else 'completed' end
from generate_series(100, 105) n;
insert into public.competition_participants
select md5('competition-' || c)::uuid, md5('profile-' || p)::uuid,
  case when p in (4, 5) then 'anonymized' else 'accepted' end
from (values (100,5),(100,6),(101,4),(101,7),(102,5),(102,7),
  (103,2),(103,6),(104,6),(104,7),(105,6),(105,7)) pairs(c,p);
insert into public.competition_results
select md5('competition-' || c)::uuid, md5('profile-' || a)::uuid, md5('profile-' || b)::uuid
from (values (100,5,6),(101,4,7),(102,7,5)) results(c,a,b);
-- Consumed cancelled invitation for a deleting profile, and unconsumed invitation
-- involving only active profiles, must not create retirement false positives.
insert into public.competition_invites values
  (md5('invite-103')::uuid, md5('competition-103')::uuid, '2026-09-01 12:00:00+00'),
  (md5('invite-105')::uuid, md5('competition-105')::uuid, null);
insert into public.device_installations
select md5('device-' || n)::uuid, md5('profile-' || n)::uuid,
  md5('installation-' || n)::uuid, case when n between 2 and 5 then 'revoked' else 'active' end
from generate_series(1, 7) n;
-- Prepared is deliberately non-destructive: these rows remain legitimate.
-- Unrelated active-profile rows also prove retirement is profile-scoped.
insert into private.competition_notification_work
select md5('work-' || n)::uuid, md5('profile-' || n)::uuid, md5('profile-7')::uuid,
  case when n in (1,6) then 'pending' else 'superseded' end, null, null, null
from generate_series(1, 6) n;
insert into private.competition_notification_mutes values
  (md5('profile-1')::uuid, md5('profile-7')::uuid),
  (md5('profile-6')::uuid, md5('profile-7')::uuid);
insert into private.app_attest_keys
select 'synthetic-key-' || n, md5('profile-' || n)::uuid, md5('installation-' || n)::uuid
from (values (1),(6)) active(n);
insert into private.app_attest_challenges
select md5('challenge-' || n)::uuid, md5('profile-' || n)::uuid, md5('installation-' || n)::uuid
from (values (1),(6)) active(n);
insert into private.app_attest_submission_grants
select md5('grant-' || n)::uuid, md5('profile-' || n)::uuid, md5('installation-' || n)::uuid
from (values (1),(6)) active(n);
\endif
