# HealthComp Multi-User Production Design

**Status:** Approved design

**Date:** 2026-08-11

**Initial cohort:** Up to 25 people

## Outcome

HealthComp will evolve from its current single-device simulated competition into a genuine two-person, local-first iPhone product. Supabase will provide shared identity, invitations, durable competition history, synchronization, authorization, notification coordination, and operational visibility. Each iPhone will continue to read HealthKit and run the deterministic competition engine locally.

The first release requires Sign in with Apple, an iPhone, and HealthKit Activity read permission. People join competitions through private, single-use links or codes. There is no searchable user directory.

## Product Decisions

- Sign in with Apple is mandatory.
- Every participant must use an iPhone and grant HealthKit Activity read access.
- Invitations use private, expiring, single-use links or codes.
- The invitation creator's time zone is frozen as the competition calendar when the invitation is accepted.
- Supabase stores privacy-limited derived competition data and complete historical results.
- Raw HealthKit samples, workouts, routes, and unrelated health information never leave the originating device.
- Completed competitions survive account deletion as anonymized historical records for the remaining participant.
- The first production cohort is limited to 25 people.
- Integrity is tamper-resistant, not described as cheat-proof.

## System Boundary

The iPhone remains responsible for HealthKit reads and deterministic score evaluation. It produces derived daily competition records containing accepted Activity percentages, competition points, availability, revision metadata, content fingerprints, and the scoring-policy version.

A durable local outbox uploads these records to Supabase using stable semantic identifiers. Requests are idempotent, so retries, relaunches, weak connectivity, and duplicate callbacks cannot create duplicate accepted scores.

Supabase provides:

- Sign in with Apple identity;
- private invitation creation and atomic claim;
- competition membership and frozen schedules;
- participant-only authorization through row-level security;
- durable seven-day score history and immutable results;
- server-side validation and result confirmation;
- notification coordination;
- diagnostics for support and reconciliation.

Supabase Realtime is a wake-up hint only. A receiving client always refetches durable database state before updating its local projection.

The local journal remains available offline. When connectivity returns, it reconciles through stable event identities and monotonic revisions. Shared results become authoritative after backend validation, while detailed HealthKit evidence stays on its originating phone.

## Identity and Invitations

The canonical account identity is the stable Sign in with Apple subject, not an email address. Profiles contain a user-selected display name and lifecycle state. Email addresses are neither exposed nor searchable, including Apple private-relay addresses.

An invitation contains a cryptographically random token. Only its hash is stored. The invitation records its creator, expiry, proposed schedule and policy, but reveals no participant data before authentication. A successful claim atomically:

1. authenticates the recipient;
2. verifies that the token is valid, unused, and unexpired;
3. binds the recipient account;
4. freezes the creator's time zone and seven-day schedule;
5. creates exactly two participant memberships;
6. marks the token permanently consumed.

The same token cannot create multiple competitions or be reassigned.

## Durable Data Model

The backend keeps an append-only competition history rather than overwriting evidence.

- `profiles`: Apple identity reference, display name, lifecycle state, and anonymization marker.
- `competitions`: schedule, frozen time zone, scoring policy, lifecycle, finalization deadline, and optional rematch parent.
- `competition_participants`: exactly two account identities and their roles.
- `competition_invites`: hashed token, creator, expiry, claimed recipient, and consumption state.
- `daily_score_revisions`: participant, day ordinal, derived Activity values, accepted points, availability, content fingerprint, revision, and evaluation timestamp.
- `competition_results`: immutable totals, outcome, finalization basis, and completion timestamp.
- `awards`: durable achievements and win-counter changes.
- `device_installations`: notification token and device status without Health data.

Clients cannot write final results directly. A narrow server endpoint validates and appends daily revisions transactionally. Once the established finalization conditions are satisfied, the backend creates the result exactly once.

## Privacy and Authorization

Uploaded competition data is limited to:

- Move, Exercise, and Stand percentages, or the applicable Move Time equivalent;
- calculated competition points;
- availability and accepted revision;
- competition day and frozen time-zone identifiers;
- content fingerprints and integrity metadata;
- scoring and policy versions;
- final totals, outcome, and finalization basis.

Raw HealthKit samples, heart rate, workouts, locations, routes, and unrelated Health data are prohibited from backend payloads and logs.

Row-level security permits participants to read only competitions in which they have membership. Client credentials cannot bypass those policies. Privileged service credentials remain in server-side functions and deployment tooling.

App Attest, authenticated device installations, monotonic revisions, schedule validation, bounds checks, and server-computed totals provide reasonable beta integrity. They do not make claims of perfect resistance to a compromised user device.

## Synchronization and Failure Handling

Each accepted competition descriptor is downloaded before scoring begins. During a competition, HealthComp records revisions in its durable local journal and places uploadable envelopes in an outbox.

The server verifies membership, schedule alignment, ordinal, revision monotonicity, point bounds, policy version, and finalization state. It appends a valid revision and returns the accepted server revision. The opponent is notified through a realtime wake-up and refetches the durable state.

Failure semantics remain explicit:

- HealthKit authorization loss or unavailable evidence is never converted to zero points.
- Network failures leave the outbox pending for bounded, observable retry.
- Stale or invalid revisions become inspectable synchronization errors.
- A user can remain offline for multiple days and later upload the missing ordered sequence.
- Partial Day 7 evidence enters Tallying Points.
- Finalization uses the existing stable-evidence deadline and best-available policy.
- Backend unavailability cannot destroy the local journal.
- Permanent validation failures require support-visible diagnostics rather than infinite silent retry.

## Account Deletion and History

Account deletion removes authentication identity, profile details, device installations, pending invitations, and unfinished competitions according to a durable cleanup workflow.

Completed competitions remain in the opponent's history. The deleted participant is irreversibly detached from identifying profile data and rendered as **Former competitor**. Derived competition facts needed to preserve the result remain, but cannot be used to recover the deleted person's identity.

Deletion is idempotent and auditable. Partial cleanup resumes after relaunch or backend recovery.

## Environments and Operations

Development, staging, and production use separate Supabase projects. Database changes ship only through versioned migrations. The app contains public project configuration only; service-role credentials remain outside the repository.

A minimal read-only support console exposes:

- account and installation health without HealthKit details;
- invitation and competition lifecycle;
- last successful synchronization per participant;
- pending and rejected outbox records;
- daily availability and revision numbers;
- finalization and notification status;
- anonymization and deletion progress.

Repair operations are explicit and audited. Initial capabilities are limited to resending an invitation, reconciling a competition, cancelling an unfinished competition, and retrying deletion cleanup. Administrators cannot manually edit final scores.

## Production Verification

Before inviting real users, verification must cover:

- Sign in with Apple and deletion on physical devices;
- two-device invitation, acceptance, seven-day accelerated simulation, result, history, and rematch;
- creator-time-zone behavior across different participant time zones and travel;
- offline use followed by multi-day ordered reconciliation;
- simultaneous, duplicate, stale, and conflicting score submissions;
- denied and re-enabled HealthKit authorization;
- notification delivery and deep-link routing;
- row-level-security tests proving unrelated accounts cannot read or mutate a competition;
- App Attest failure and replacement-device enrollment;
- backup restoration and migration rollback rehearsal;
- privacy disclosures, support instructions, and TestFlight metadata.

The rollout starts with the owner and one trusted pair, expands to five participants after the first completed real competition is inspected, and reaches the 25-person cohort only after synchronization, notifications, deletion, and history have been validated in production-like conditions.

## Non-Goals for the Initial Release

- Android or web clients;
- public profiles or user search;
- competitions with more than two participants;
- manual score entry;
- raw HealthKit backup or analytics;
- administrator score editing;
- mass-market abuse systems, ranking, or matchmaking;
- a claim of perfect anti-cheat protection.

## Migration Note

The repository's historical Supabase migrations and Edge Functions are reference material only. They must not be reconnected unchanged. The production backend will be rebuilt around the current deterministic journal, privacy boundary, idempotent outbox, append-only score revisions, and server-confirmed results described above.
