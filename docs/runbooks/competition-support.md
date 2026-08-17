# Competition Support

This runbook provides privacy-minimizing diagnosis for a single competition.
It exposes only implemented read paths and standard server sweeps. It does not
grant operators a mutation back door.

## Status and authority

- The database is authoritative for remote competition lifecycle, append-only
  changes, finalization, notification work, and account-deletion state.
- The authenticated participant remains authoritative for submitting their own
  score revisions and finalization attestation.
- Raw HealthKit samples, values, goals, workouts, routes, heart rate, and local
  reversible fingerprints exist only on that participant's device. Support
  must never request or upload them.
- Final completion is server-confirmed. A local UI state is not permission to
  edit remote rows or manufacture a result.
- Run diagnosis against staging first whenever the issue can be reproduced
  there. Production access requires an approved support case and least
  privilege.

## Before querying

Record in the restricted support case:

1. environment and public app build number;
2. the competition UUID supplied by an authenticated participant;
3. the participant-visible symptom and timestamp range;
4. whether the issue affects one or both participants;
5. the exact read-only queries approved for the case.

Verify the selected Supabase project name and ref before connecting with psql
as the approved database operator. Let psql prompt for the database password;
never place it in a command or transcript. Do not run these blocks in the
dashboard SQL editor: psql's quoted variable binding is the control that keeps
participant-supplied text out of SQL syntax. Never paste a service-role key,
access token, invitation token, email, display name, Apple identifier, APNs
token, score, or Health datum into the case. Never use a service-role
credential to impersonate a participant.

Open one bounded session, then let psql read the participant-supplied value
into a variable. `:'competition_id'` emits a quoted SQL literal; the UUID cast
fails closed before any diagnostic query if the input is not one canonical
UUID. Never replace a placeholder or concatenate the supplied text manually.

~~~text
psql -X \
  --host REPLACE_WITH_SUPPORT_HOST \
  --port 5432 \
  --username REPLACE_WITH_SUPPORT_USER \
  --dbname postgres \
  --password \
  --set ON_ERROR_STOP=on
\prompt 'Competition UUID: ' competition_id
begin transaction read only;
set local statement_timeout = '10s';
select :'competition_id'::uuid as validated_competition_id;
~~~

Run only the needed queries below, then finish with:

~~~text
rollback;
\unset competition_id
\quit
~~~

## Privacy-safe diagnostic snapshot

### Lifecycle and participant shape

This shows schedule shape and participant roles without profile identities.

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  competition_record.lifecycle,
  competition_record.start_day,
  competition_record.time_zone_identifier,
  competition_record.invitation_expires_at,
  competition_record.best_available_deadline,
  competition_record.next_server_seq,
  competition_record.created_at,
  competition_record.updated_at,
  pg_catalog.count(participant_record.profile_id) as participant_count,
  pg_catalog.count(*) filter (
    where participant_record.state = 'accepted'
  ) as accepted_participant_count
from target
join public.competitions competition_record
  on competition_record.id = target.competition_id
left join public.competition_participants participant_record
  on participant_record.competition_id = competition_record.id
group by competition_record.id;

with target as (
  select :'competition_id'::uuid as competition_id
)
select
  participant_record.role,
  participant_record.state,
  participant_record.joined_at,
  participant_record.updated_at
from target
join public.competition_participants participant_record
  on participant_record.competition_id = target.competition_id
order by participant_record.role;
~~~

Expected invariant: a scheduled or later competition has exactly two
participants, one creator and one invitee. The rows intentionally omit profile
IDs and names.

### Invitation state

Only the digest is stored. Do not select token_digest or claimed_profile_id.

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  pg_catalog.count(invite_record.id) as invite_count,
  pg_catalog.count(*) filter (
    where invite_record.consumed_at is null
  ) as unconsumed_count,
  pg_catalog.count(*) filter (
    where invite_record.consumed_at is not null
  ) as consumed_count,
  pg_catalog.min(invite_record.created_at) as first_created_at,
  pg_catalog.max(invite_record.expires_at) as latest_expires_at,
  pg_catalog.max(invite_record.consumed_at) as consumed_at
from target
left join public.competition_invites invite_record
  on invite_record.competition_id = target.competition_id;
~~~

An unconsumed, unexpired row proves only that a digest can still be claimed.
It does not recover the original link or token.

### Append-only sequence health

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
), sequence_summary as (
  select
    competition_record.next_server_seq,
    pg_catalog.count(change_record.server_seq) as change_count,
    pg_catalog.count(distinct change_record.server_seq)
      as distinct_change_count,
    pg_catalog.min(change_record.server_seq) as minimum_server_seq,
    pg_catalog.max(change_record.server_seq) as maximum_server_seq
  from target
  join public.competitions competition_record
    on competition_record.id = target.competition_id
  left join public.competition_change_log change_record
    on change_record.competition_id = competition_record.id
  group by competition_record.id
)
select
  next_server_seq,
  change_count,
  distinct_change_count,
  minimum_server_seq,
  maximum_server_seq,
  case
    when change_count = 0 then next_server_seq = 1
    else minimum_server_seq = 1
      and maximum_server_seq = change_count
      and distinct_change_count = change_count
      and next_server_seq = change_count + 1
  end as sequence_is_gap_free
from sequence_summary;

with target as (
  select :'competition_id'::uuid as competition_id
)
select
  change_record.change_kind,
  pg_catalog.count(*) as change_count,
  pg_catalog.min(change_record.server_seq) as first_server_seq,
  pg_catalog.max(change_record.server_seq) as last_server_seq,
  pg_catalog.min(change_record.occurred_at) as first_occurred_at,
  pg_catalog.max(change_record.occurred_at) as last_occurred_at
from target
join public.competition_change_log change_record
  on change_record.competition_id = target.competition_id
group by change_record.change_kind
order by first_server_seq;
~~~

Any gap, duplicate, or next_server_seq mismatch is an engineering incident.
Do not renumber or insert replacement changes.

### Score revision and attestation shape

These queries return operational shape, not points, component values,
commitments, digests, semantic event IDs, or profile IDs.

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  participant_record.role,
  revision_record.day_ordinal,
  revision_record.availability_reason,
  pg_catalog.count(*) as revision_count,
  pg_catalog.max(revision_record.client_revision) as latest_client_revision,
  pg_catalog.max(revision_record.received_at) as latest_received_at
from target
join public.daily_score_revisions revision_record
  on revision_record.competition_id = target.competition_id
join public.competition_participants participant_record
  on participant_record.competition_id = revision_record.competition_id
 and participant_record.profile_id = revision_record.participant_profile_id
group by
  participant_record.role,
  revision_record.day_ordinal,
  revision_record.availability_reason
order by participant_record.role, revision_record.day_ordinal;

with target as (
  select :'competition_id'::uuid as competition_id
)
select
  participant_record.role,
  attestation_record.basis,
  attestation_record.attested_at,
  attestation_record.server_seq
from target
join public.participant_finalization_attestations attestation_record
  on attestation_record.competition_id = target.competition_id
join public.competition_participants participant_record
  on participant_record.competition_id = attestation_record.competition_id
 and participant_record.profile_id = attestation_record.participant_profile_id
order by participant_record.role;
~~~

Support may ask the affected authenticated app to pull-to-refresh or retry its
normal upload. Support must not calculate, enter, or alter a participant's
score.

### Result and awards

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  result_record.outcome,
  result_record.finalization_basis,
  result_record.completed_at,
  result_record.server_seq,
  pg_catalog.encode(result_record.immutable_hash, 'hex')
    as immutable_result_hash
from target
join public.competition_results result_record
  on result_record.competition_id = target.competition_id;

with target as (
  select :'competition_id'::uuid as competition_id
)
select
  participant_record.role,
  award_record.award_type,
  award_record.earned_at,
  award_record.server_seq
from target
join public.competition_awards award_record
  on award_record.competition_id = target.competition_id
join public.competition_participants participant_record
  on participant_record.competition_id = award_record.competition_id
 and participant_record.profile_id = award_record.profile_id
order by award_record.server_seq;
~~~

Never select totals or frozen_window for routine support. A stored immutable
hash mismatch is an engineering and security incident. Results and awards are
append-only server facts; there is no support edit path.

### Notification work

Do not select installation_id, recipient_profile_id, source_profile_id,
semantic_id, lease_token, or leased_apns_token_sha256.

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  work_record.kind,
  work_record.state,
  case
    when work_record.attempt_count = 0 then '0'
    when work_record.attempt_count <= 2 then '1-2'
    else '3-10'
  end as attempt_bucket,
  pg_catalog.count(*) as work_count,
  pg_catalog.min(work_record.available_at) as earliest_available_at,
  pg_catalog.max(work_record.updated_at) as latest_updated_at,
  pg_catalog.max(work_record.completed_at) as latest_completed_at
from target
join private.competition_notification_work work_record
  on work_record.competition_id = target.competition_id
group by work_record.kind, work_record.state, attempt_bucket
order by work_record.kind, work_record.state, attempt_bucket;
~~~

Pending work before available_at is normal. Repeated attempts, expired leases,
or pending work beyond the retry window require worker and schedule readback.
Do not expose APNs tokens or their hashes while diagnosing delivery.

### Support events

~~~sql
with target as (
  select :'competition_id'::uuid as competition_id
)
select
  event_record.kind,
  event_record.code,
  event_record.created_at
from target
join public.support_events event_record
  on event_record.competition_id = target.competition_id
order by event_record.created_at;
~~~

## Supported operator actions

Use the smallest applicable action and record its timestamp. A database write
requires an approved incident or release procedure even when the function is
idempotent.

1. Ask an authenticated participant to pull-to-refresh or retry the normal app
   action. The app and RLS remain the identity boundary.
2. To close genuinely expired, unclaimed pending invitations, first record one
   privacy-safe scope snapshot. The count is reviewable; the SHA-256 value is
   an opaque fingerprint of the sorted eligible competition UUIDs. The query
   does not return any competition, invitation, profile, token, or invite
   digest identifier:

   ~~~sql
   with eligible as (
     select competition_record.id
     from public.competitions competition_record
     where competition_record.lifecycle = 'pending'
       and exists (
         select 1
         from public.competition_invites invite_record
         where invite_record.competition_id = competition_record.id
           and invite_record.claimed_profile_id is null
           and invite_record.consumed_at is null
           and invite_record.expires_at <= pg_catalog.statement_timestamp()
       )
   )
   select
     pg_catalog.count(*)::bigint as expected_expired_pending_count,
     pg_catalog.encode(
       extensions.digest(
        coalesce(
           pg_catalog.string_agg(
             eligible.id::text,
             ',' order by eligible.id
           ),
           ''
         ),
         'sha256'
       ),
       'hex'
     ) as eligible_scope_sha256
   from eligible;
   ~~~

   Obtain action-time approval for that exact count and fingerprint. Open a
   fresh `psql -X` session as the approved privileged database operator with
   `ON_ERROR_STOP=on`, and enter the two approved values only when prompted.
   Do not `SET ROLE service_role`: that role intentionally has only function
   execution privilege, while the transaction guard must read the eligible
   scope. The request-role claim below is used only by the reviewed function's
   authorization check.

   The serializable transaction recomputes both approved values and invokes
   cleanup inside one guarded statement. A malformed value, changed scope,
   timeout, or unexpected cleanup count raises an error and aborts the whole
   transaction before `commit;` can persist anything:

   ~~~text
   \prompt 'Approved expired-pending count: ' approved_expired_pending_count
   \prompt 'Approved eligible-scope SHA-256: ' approved_eligible_scope_sha256

   begin transaction isolation level serializable;
   set local statement_timeout = '10s';
   set local lock_timeout = '3s';
   set local idle_in_transaction_session_timeout = '30s';

   select pg_catalog.set_config(
     'healthcomp.approved_expired_pending_count',
     :'approved_expired_pending_count',
     true
   );
   select pg_catalog.set_config(
     'healthcomp.approved_eligible_scope_sha256',
     :'approved_eligible_scope_sha256',
     true
   );
   select pg_catalog.set_config(
     'request.jwt.claims',
     '{"role":"service_role"}',
     true
   );

   do $cleanup$
   declare
     approved_count_text text := pg_catalog.current_setting(
       'healthcomp.approved_expired_pending_count'
     );
     approved_scope_sha256 text := pg_catalog.lower(
       pg_catalog.current_setting(
         'healthcomp.approved_eligible_scope_sha256'
       )
     );
     approved_count bigint;
     actual_count bigint;
     actual_scope_sha256 text;
     expired_count bigint;
   begin
     if approved_count_text !~ '^(0|[1-9][0-9]*)$' then
       raise exception 'invalid_approved_expired_pending_count'
         using errcode = '22023';
     end if;
     if approved_scope_sha256 !~ '^[0-9a-f]{64}$' then
       raise exception 'invalid_approved_eligible_scope_sha256'
         using errcode = '22023';
     end if;

     approved_count := approved_count_text::bigint;

     with eligible as (
       select competition_record.id
       from public.competitions competition_record
       where competition_record.lifecycle = 'pending'
         and exists (
           select 1
           from public.competition_invites invite_record
           where invite_record.competition_id = competition_record.id
             and invite_record.claimed_profile_id is null
             and invite_record.consumed_at is null
             and invite_record.expires_at
               <= pg_catalog.statement_timestamp()
         )
     )
     select
       pg_catalog.count(*)::bigint,
       pg_catalog.encode(
         extensions.digest(
          coalesce(
             pg_catalog.string_agg(
               eligible.id::text,
               ',' order by eligible.id
             ),
             ''
           ),
           'sha256'
         ),
         'hex'
       )
     into actual_count, actual_scope_sha256
     from eligible;

     if actual_count is distinct from approved_count
        or actual_scope_sha256 is distinct from approved_scope_sha256 then
       raise exception 'approved_expired_invitation_scope_changed'
         using errcode = '40001';
     end if;

     expired_count := public.cleanup_expired_competition_invites();
     if expired_count is distinct from approved_count then
       raise exception 'expired_invitation_cleanup_count_changed'
         using errcode = '40001';
     end if;

     raise notice 'expired_pending_invitation_cleanup_count=%', expired_count;
   end
   $cleanup$;

   commit;
   \unset approved_expired_pending_count
   \unset approved_eligible_scope_sha256
   ~~~

   If any statement times out or errors, the transaction is aborted: do not
   retry or alter the approved values. Enter `rollback;` if the session remains
   open, refresh the read-only scope snapshot, investigate the change, and seek
   fresh action-time approval. Never disconnect and later assume that the
   mutation committed. After a successful commit, use the same privacy-safe
   count query to confirm zero live expired-and-pending invitations.

   The function is idempotent. It marks only eligible competitions `expired`
   and deliberately retains the unconsumed invitation-history rows; it does
   not recover a token or make an expired invitation claimable.
3. For a genuinely due tallying competition, run the standard finalizer sweep
   as the privileged database operator, then repeat the read-only result query:

   ~~~sql
   select private.run_due_competition_finalizer();
   ~~~

4. For durable pending notification work, trigger the standard worker request
   after verifying its Vault entries and Function configuration:

   ~~~sql
   select private.request_competition_notification_worker();
   ~~~

These calls exercise reviewed, idempotent server contracts. They do not grant
permission to bypass a deadline, forge an attestation, or alter a result.

## Unsupported operations

| Request | Current truth | Required next step |
| --- | --- | --- |
| Resend an existing invitation | Unsupported. Only a one-way digest is stored; the raw token is unrecoverable. | The creator must use a future audited replacement flow. Do not extract or replace the digest. |
| Operator-cancel a competition | Unsupported. No audited operator cancellation RPC exists. | Escalate as a product/engineering decision. Do not update lifecycle directly. |
| Force reconciliation or upload for a participant | Unsupported. Only that authenticated participant owns submission. | Diagnose connectivity/session state and ask the app to retry. |
| Change a score, result, winner, award, or server sequence | Forbidden by the append-only and immutable contracts. | Open an engineering/security incident; preserve the evidence. |
| Delete a participant to clean up a case | Forbidden. Account deletion follows its own durable, Apple-bound flow. | Use the account-deletion runbook. |

## Escalation conditions

Stop standard support and preserve read-only evidence when any of these occurs:

- the target project or competition identity is ambiguous;
- participant count, role shape, or server sequence invariants fail;
- RLS returns another participant's non-shared data;
- a result hash differs across reads or a completed result changes;
- finalization remains blocked after a due standard sweep;
- notification work remains leased past expiry or exceeds its retry policy;
- an operator request would require direct SQL mutation;
- diagnosis would require identity, token, score, or Health data disclosure.

## Evidence receipt

The release/support receipt may contain environment, app build, lifecycle,
role/state counts, sequence ranges, revision counts, availability reasons,
result hash, notification state counts, support event codes, query timestamps,
and unresolved blockers. Keep the competition UUID only in the access-
controlled case. Redact all user identity, token, device, raw score, frozen
window, and Health data from screenshots and general release evidence.
