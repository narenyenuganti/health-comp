# Recipient-bound invitations

Status, October 21: selected source `a5809f9` passed exact-main CI and the hosted
20/v2 sequential database adversarial verifier. One live recipient happy path
reached the same scheduled match on both clients; full live adversarial/concurrent
flow and physical scoring remain unqualified. No production promotion. See the
[current checklist](../release/production-beta-checklist.md#current-qualification-checkpoint--october-21-2026-utc).

Historical status, October 19: source integrated with passing exact-head CI; migration 018
and only the create invitation Function promoted to Staging. The matching
Simulator client is installed; physical-client and live recipient-flow
qualification remain incomplete. No production promotion.

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
constraints or changing accepted history. The recovery harness's exact
migration-manifest pin was updated and both existing synthetic modes passed.
The corrected migration was subsequently applied to Staging as recorded below;
no earlier migration or hosted history was repaired.

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
or production-readiness evidence. The correction's PR #151 passed all three
expected checks at `446714d85e0505bd344630016ea6ff978dd4363b` before integration.
Merged main `6635c22e56908e6538c3f4261ab5d68cd8a38380` has exactly the same tree.
Source qualification did not itself authorize the subsequent hosted rollout.

The populated backup/export/restore harness now pins the corrected 23-migration
manifest. Both native synthetic snapshot and forward-repair modes passed after
the ordering correction. This is not a genuine hosted backup/restore pass; all
existing beta-readiness holds remain in effect.

## Dated Staging rollout evidence

October 21 UTC checkpoint:

- The selected `a5809f9` verifier passed 20/20 against hosted Staging, rolled back
  its temporary synthetic writes and independently confirmed zero residue. This
  covers sequential database contracts, including the five recipient assertions;
  it does not replace live Edge or concurrent-client verification.
- On October 20 UTC, one invitation between the existing test accounts was
  accepted into the same October 21–27 Los Angeles schedule on the Simulator and
  phone. No refresh or accepted-score claim was part of that observation; exact
  server claim-request count was not proved. It is a diagnostic scoring target,
  not stable-result qualification. Preserve completed history and this match.
- The [release evidence](../release/production-beta-evidence.md#current-qualification-checkpoint--october-21-2026-utc)
  records source/receipt hashes and the remaining physical, recovery and release
  limits. Historical October 19 observations below retain their original scope.

October 19, 20:20 UTC, following the owner's explicit approval:

- Exactly migration 018 was applied, producing the expected 23-version chain.
  Four old unnamed pending invitations expired. Same-process before/after
  aggregate and ordered-row comparisons preserved all four accepted competitions
  and their related history. No migration repair or reset was used.
- Only `create-competition-invite` advanced from ACTIVE version 5 to version 6;
  gateway JWT verification remained enabled and other Function metadata was
  unchanged. Activated entry, shared invitation source and returned import map
  matched source. No deployed lockfile was returned, so dependency-lock/graph
  equality is not proved.
- Recipient-column, unique-pair, 24-hour-expiry and service-role-only creation
  catalog checks passed. These are not live create/accept tests.

By 20:38 UTC the matching Simulator package had been installed once and launched
once without manual refresh, account switch or invitation action. The installed
executable/signature matched its prepared artifact; application/configuration
sources are unchanged between packaged `da3ce2a` and integrated `6635c22`.
The installation's combined path/mode/byte preservation assertion failed and its
RAM-only baseline is gone. Its cause and original byte equality remain unproved;
current-state replay must not be presented as that lost comparison.

Stopped current-main Core replay passed all five journals and 147 events with
owner binding and valid/corrupt/wrong-owner controls. The original October 11
competition caught up to a completed `best_available` result with zero accepted
day slots and 14 deadline-missing slots, not a stable result. Normal startup network
effects were not classified. The app was terminated and dedicated Simulator shut
down; no recipient drawer, lookup, creation or acceptance was qualified.

The physical candidate remains uninstalled and the physical live reader remains
disabled and pinned to the old installation. Physical qualification, live
recipient flow, genuine hosted recovery and the broader release gates remain
open. Do not reapply 018 or treat this Staging checkpoint as production readiness.
