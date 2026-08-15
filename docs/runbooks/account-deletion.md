# Account Deletion and Recovery

HealthComp deletion is a durable, ordered server operation bound to a fresh
Sign in with Apple authorization. Remote completion must be confirmed before
the app removes the profile-scoped local store. Completed shared competition
history remains, with the deleted participant shown only as Former competitor.

## What completion means

A deletion is complete only when all of the following are true:

- Apple accepted revocation of the user's refresh token;
- unfinished competitions involving the profile were cancelled;
- pending invitations for those cancelled competitions were removed;
- device installations were revoked and pending notification work was
  superseded;
- the profile and its participant rows were anonymized;
- the Supabase Auth user was deleted;
- the temporary Vault token was deleted;
- the Edge Function returned HTTP 200 with status deleted;
- the iOS app cleared its local Supabase session, stopped the profile runtime,
  and removed that profile's local directory.

An app alert, a local sign-out, an anonymized profile alone, or an operator SQL
change is not proof of completion.

## User-initiated path

1. The signed-in user opens account settings and confirms permanent deletion.
2. The app performs fresh Sign in with Apple reauthorization with a new nonce.
3. The app sends only the fresh authorization code and nonce to the
   delete-account Edge Function over its authenticated session.
4. The Function verifies the session, exchanges the single-use Apple code,
   binds the returned identity to the stored Apple provider ID, exact client
   ID, nonce, issuer, and expiry, then advances the durable phases.
5. The Function returns success only after Apple revocation, anonymization,
   Auth deletion, and terminal database confirmation.
6. Only after that server receipt does the app clear its local session and
   delete profile-scoped local data.

The authorization code, nonce, Apple refresh token, provider identifier,
access token, and service-role key must never enter logs, tickets, screenshots,
analytics, shell history, or SQL output.

## Durable phase machine

| Phase | Durable state | Safe recovery behavior |
| --- | --- | --- |
| prepared | The deletion row is bound to the authenticated Supabase user and Apple identity. The profile is still active. No Apple token is stored yet. | The user retries in the app with fresh Apple reauthorization. Never replay an old authorization code. |
| token_ready | The exchanged Apple refresh token is in Vault. The profile is deleting. Unfinished competitions are cancelled, unconsumed invites for them are removed, installations are revoked, notification work is superseded, and notification mutes are removed. | An authenticated app retry resumes from the stored token and must not exchange the old single-use code again. |
| apple_revoked | Apple revocation succeeded and the Vault token was deleted. | An authenticated app retry advances anonymization. Do not recreate a token or move the phase backward. |
| auth_delete_pending | Participant rows and the profile are anonymized; the profile has no auth_user_id and displays only Former competitor. The deletion record still tracks the Auth user needed for removal. | An authenticated retry requests Auth deletion. Auth removal automatically moves the row to completed. |
| completed | The Auth user and Apple identity reference are gone, completed_at is set, the temporary Vault token is absent, and a completed support event exists. | Terminal. Never relink, deanonymize, or reuse the profile. A future signup creates a new profile. |

The transition order is strict and idempotent. No phase may be skipped,
reversed, or manually rewritten.

## Response meanings

| HTTP/result | Meaning | User-safe action |
| --- | --- | --- |
| 200, status deleted | Server-confirmed terminal completion. | Allow the app's local teardown to finish. |
| 400, invalid_request | The reauthorization body is malformed or stale. | Restart deletion in the app to obtain fresh Apple input. Do not copy the value into support. |
| 401, authentication_required | No valid Supabase session remains. | Sign in normally, verify the account, then restart deletion. |
| 403, apple_identity_mismatch | Apple identity, client, nonce, issuer, or expiry did not match. | Stop and escalate if a clean fresh reauthorization repeats the failure. |
| 503, account_deletion_retryable | A durable phase did not finish. | Keep the app installed and retry through the authenticated deletion flow. Inspect phase using the read-only procedure below. |

Cancellation by the user before a fresh Apple authorization succeeds leaves
the account active. Once token_ready is reached, deletion has already started
and unfinished competition cancellation is durable.

## Read-only support inspection

Use a restricted support case and a profile UUID established from the
authenticated request. Verify the environment first. Do not search by email,
display name, Apple identifier, or APNs token.

The following output deliberately omits auth_user_id, apple_provider_id, token
names, and token values:

~~~sql
begin transaction read only;
set local statement_timeout = '10s';

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  deletion_record.phase,
  deletion_record.started_at,
  deletion_record.updated_at,
  deletion_record.completed_at,
  profile_record.state as profile_state,
  profile_record.anonymized_at,
  profile_record.display_name = 'Former competitor'
    as has_anonymous_display_name
from target
join private.account_deletions deletion_record
  on deletion_record.profile_id = target.profile_id
join public.profiles profile_record
  on profile_record.id = target.profile_id;

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  competition_record.lifecycle,
  pg_catalog.count(*) as competition_count
from target
join public.competition_participants participant_record
  on participant_record.profile_id = target.profile_id
join public.competitions competition_record
  on competition_record.id = participant_record.competition_id
group by competition_record.lifecycle
order by competition_record.lifecycle;

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  installation_record.state,
  installation_record.environment,
  pg_catalog.count(*) as installation_count,
  pg_catalog.max(installation_record.updated_at) as latest_updated_at
from target
join public.device_installations installation_record
  on installation_record.profile_id = target.profile_id
group by installation_record.state, installation_record.environment
order by installation_record.environment, installation_record.state;

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  work_record.state,
  pg_catalog.count(*) as notification_count,
  pg_catalog.max(work_record.updated_at) as latest_updated_at
from target
join private.competition_notification_work work_record
  on work_record.recipient_profile_id = target.profile_id
  or work_record.source_profile_id = target.profile_id
group by work_record.state
order by work_record.state;

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  event_record.kind,
  event_record.code,
  event_record.created_at
from target
join public.support_events event_record
  on event_record.profile_id = target.profile_id
where event_record.kind = 'account_deletion'
order by event_record.created_at;

rollback;
~~~

Do not query vault.decrypted_secrets. The existence or value of an Apple token
is not support evidence. Phase and timestamps are the supported diagnostic
surface.

## Safe recovery by phase

### prepared

Ask the user to retry Delete Account in the app and complete a fresh Sign in
with Apple prompt. Do not ask for the authorization code. If fresh
reauthorization repeatedly fails before token_ready, verify the exact App ID,
Apple provider client ID, paid-team membership, key validity, device time, and
environment configuration without capturing key material.

### token_ready

The deletion is already destructive and the refresh token is durable in
Vault. Ask the same authenticated user to retry in the app. The Function
resumes Apple revocation using the stored token. Operators must not retrieve
the token, call Apple's revoke endpoint manually, or advance the phase.

If retry repeatedly returns a revocation error, verify Apple key ID, team ID,
client ID, private-key validity, and generated client-secret expiry in the
matching environment. Rotate only through the environment configuration
procedure. Never overwrite the deletion row.

### apple_revoked

Ask the authenticated app to retry. The next operation anonymizes the profile
and participant rows. If it fails, preserve the read-only invariant output and
open an engineering incident. Do not set state to anonymized directly.

### auth_delete_pending

Ask the authenticated app to retry while its session still exists. The
Function deletes the Supabase Auth user; the database trigger then marks the
deletion completed. If Auth removal happened concurrently, the trigger should
already have completed the row.

If the session is gone and the row remains auth_delete_pending, stop. This is
an identity-sensitive engineering incident. Do not invoke the public deletion
functions with a service key, impersonate the user, or null identifiers by
hand.

### completed

No remote recovery action is allowed. Confirm the terminal invariants below.
If the app reports local cleanup failure after remote completion, do not call
the remote deletion failed and do not restore server identity. Help the user
remove the app's local container, normally by deleting the app from the
device, and escalate reproducible teardown failures without collecting local
Health data.

## Terminal invariant check

This query returns counts and booleans only. It does not return identity,
score, token, or competition data.

~~~sql
begin transaction read only;
set local statement_timeout = '10s';

with target as (
  select 'REPLACE_WITH_PROFILE_UUID'::uuid as profile_id
)
select
  deletion_record.phase = 'completed' as deletion_completed,
  deletion_record.completed_at,
  deletion_record.auth_user_id is null as auth_reference_removed,
  deletion_record.apple_provider_id is null as apple_reference_removed,
  profile_record.state = 'anonymized' as profile_anonymized,
  profile_record.auth_user_id is null as profile_auth_removed,
  profile_record.display_name = 'Former competitor'
    as anonymous_name_applied,
  (
    select pg_catalog.count(*)
    from public.competition_participants participant_record
    where participant_record.profile_id = target.profile_id
      and participant_record.state <> 'anonymized'
  ) as non_anonymized_participant_count,
  (
    select pg_catalog.count(*)
    from public.competitions competition_record
    join public.competition_participants participant_record
      on participant_record.competition_id = competition_record.id
    where participant_record.profile_id = target.profile_id
      and competition_record.lifecycle in (
        'pending', 'scheduled', 'active', 'ends_today', 'tallying'
      )
  ) as unfinished_competition_count,
  (
    select pg_catalog.count(*)
    from public.device_installations installation_record
    where installation_record.profile_id = target.profile_id
      and installation_record.state = 'active'
  ) as active_installation_count,
  (
    select pg_catalog.count(*)
    from private.competition_notification_work work_record
    where (
      work_record.recipient_profile_id = target.profile_id
      or work_record.source_profile_id = target.profile_id
    )
      and work_record.state in ('pending', 'leased')
  ) as open_notification_count,
  (
    select pg_catalog.count(*)
    from public.support_events event_record
    where event_record.profile_id = target.profile_id
      and event_record.kind = 'account_deletion'
      and event_record.code = 'completed'
  ) as completed_event_count
from target
join private.account_deletions deletion_record
  on deletion_record.profile_id = target.profile_id
join public.profiles profile_record
  on profile_record.id = target.profile_id;

rollback;
~~~

Expected terminal values are all true, all open/non-anonymized counts zero,
and exactly one completed event.

## Preserved shared history

Deletion intentionally preserves completed competitions, frozen results,
immutable result hashes, awards, change sequence, and the other participant's
view of the shared event. The deleted profile becomes terminal and anonymous:

- display name: Former competitor;
- profile state: anonymized;
- participant state: anonymized;
- no auth user or Apple identity remains linked.

Never delete completed results to satisfy a deletion request. Never create a
reverse mapping, support note, analytics property, or export that links Former
competitor back to a person. Existing restricted operational backups remain
subject to their retention policy; a restore must not reactivate an anonymized
profile.

## Physical-device and staging evidence

Task 19 must exercise the complete flow with a dedicated staging account on a
physical iPhone. Required evidence includes fresh Apple reauthorization,
server-confirmed deletion, terminal database invariants, local profile storage
removal, inability to reuse the deleted session, preserved Former competitor
history for the other account, and no notification delivery to the deleted
installation. Simulator or unit-test evidence alone is insufficient.

This physical and hosted evidence is pending until it is actually performed.

## Escalate immediately when

- target environment or profile identity is ambiguous;
- a deletion phase moves backward, skips a phase, or remains inconsistent with
  profile state;
- Apple revocation repeatedly fails with verified current configuration;
- auth_delete_pending remains after the Auth user is absent;
- completed deletion retains an Apple/Auth reference or temporary token;
- unfinished competitions, active installations, or open notification work
  remain after completion;
- anonymized history exposes a former display name or can be reverse-mapped;
- support would need a token, service-role impersonation, or direct SQL write;
- the server completed but profile-scoped local data reproducibly remains.

Record exact phase, timestamps, invariant booleans/counts, app build, device OS,
and error code. Do not record personal or secret values.
