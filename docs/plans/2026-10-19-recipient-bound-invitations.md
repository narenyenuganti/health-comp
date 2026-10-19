# Recipient-bound invitations

Status: source and focused local qualification passed; exact-head CI pending;
not deployed.

## User contract

- Choose an existing HealthComp account before creating an invitation. Only that
  account can accept it. A display name is not an identity.
- One unaccepted outgoing invitation per sender/recipient pair, not one total per
  sender. Different recipients remain independent.
- Invitations expire exactly 24 hours after creation. An expired invitation
  cannot be accepted and does not prevent a new invitation to that recipient.
- Retries of the same request remain idempotent. Concurrent requests cannot
  create duplicate pending invitations. Changing the recipient is a new request.
- Long recipient names wrap without truncation, including at accessibility sizes.

## Private account selection

Account exposes a shareable HealthComp account code: the existing random profile
UUID, not an Apple identifier or email. The creator pastes the exact code and
confirms the returned display name before creating a link. Authenticated exact-code
resolution returns only the profile ID and display name of an active other account;
there is no prefix search, email lookup, directory, or access to its history.

## Migration and compatibility

Use a new forward migration; never change historical migrations. Existing unnamed,
unaccepted invitations cannot safely be assigned a recipient, so expire them in
place. Preserve accepted competitions, schedules, scores and completed history.
Close older recipient-free creation RPCs rather than leaving a bearer-only bypass.
Ship the new RPC, Edge Function and app as a coordinated change. Older apps cannot
create new unnamed invitations after migration; existing accepted competitions
continue to work.

Pending recipient membership is visible to the creator but is not accepted
membership: it must not grant the chosen recipient competition/history access
before they open and accept the link. Expiry and duplicate checks run on the server.

## Verification interfaces

Use the established create/claim RPCs, HTTP handlers, client wire contracts, feature
actions and rendered app flow. Verify exact-recipient acceptance, wrong-account
rejection, same-request retry, concurrent duplicate creation, separate recipients,
24-hour boundary, stale invitation replacement, participant isolation, migration
preservation, and long-name/large-text rendering. Use synthetic local accounts only.

No phone, hosted migration/deployment, account switching, production action or new
live competition is part of source implementation and local qualification.

## Local qualification

### Populated Staging migration correction

The first Staging apply rolled back with PostgreSQL `55006`: expiring legacy
pending rows queued deferred constraint triggers before later table DDL. The
rehearsal had masked this by leaving fixture setup's immediate-constraint mode
enabled. Restore deferred mode before the migration and flush it afterward;
the unchanged migration then reproduces the hosted error. Move only the legacy
expiration update after table DDL so the same fixture passes without weakening
constraints or changing accepted history. Update the recovery harness's exact
migration-manifest pin and rerun its existing synthetic modes. Migration018
remains unapplied on Staging; no earlier migration or hosted history is repaired.

- 635 app unit tests and six rendered UI flows passed. The appearance matrix
  covered light/dark mode at xSmall and accessibility5 with the existing
  clipping, hit-region and description audits unchanged. Invitation confirmation
  was also visually inspected. Long recipient names grow vertically rather than
  being limited to one line.
- 22 pgTAP files / 849 assertions passed, including the recipient, isolation,
  24-hour boundary and duplicate-pair contracts. A real forward-migration
  rehearsal preserved populated accepted legacy history and rolled back.
- The real-JWT HTTP invitation gate passed all 15 tests, including concurrent
  request recovery, wrong-account acceptance rejection, expiry and replacement.
- The complete Deno function suite passed 143 tests. Its one gated JWT case was
  skipped there but executed successfully by the separate real-JWT gate above.
  The 100-way create/retry/claim matrix now runs twice without a reset between
  passes. Fresh synthetic token digests prevent cross-pass fixture collisions;
  same-request retries deliberately retain the same digest.
- The offline App Attest regression and both public attestation/assertion
  fixtures passed in the pinned Edge Runtime. Schema lint passed and the local
  schema diff was empty.
- Independent Standards and Spec reviews cleared the application/server source
  at `41a4fbe` and the subsequent test-only fixture fix at `8aaeb7e`.

These are local synthetic results, not hosted, physical-device, Release archive
or production-readiness evidence. The PR's exact-head automated matrix must pass
before source integration. A later rollout must coordinate migration, Functions
and app compatibility; it is not authorized by this source-only qualification.

The populated backup/export/restore harness still pins the prior migration
manifest. Current-schema recovery must be qualified separately before hosted
rollout; do not rewrite older evidence or treat an empty-schema check as proof
of a populated restore. All existing beta-readiness holds remain in effect.
