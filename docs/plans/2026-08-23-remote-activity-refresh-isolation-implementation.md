# Remote Activity Refresh Isolation Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep a valid hosted competition visible when its subsequent on-device Activity refresh fails, while retaining a truthful scoped issue and all fail-closed server and score contracts.

**Architecture:** `RemoteCompetitionRuntime` will return validated remote materialization and typed Activity-read failures through separate result channels. `RemoteCompetitionClientCoordinator` will publish successful materializations and map only the typed nonfatal failures into a dedicated presentation issue; all other failures retain their existing behavior.

**Tech Stack:** Swift 6, XCTest, Xcode 16, CompetitionCore, HealthKit-facing dependency injection.

---

### Task 1: Reproduce the coupled failure

**Files:**
- Modify: `HealthCompTests/RemoteCompetitionRuntimeTests.swift`

1. Add a scheduled two-participant runtime test whose fixture uses
   `initialReadState: .failure(.healthDataUnavailable)`.
2. Assert the wished-for contract: one successful materialization, no fatal
   per-ID failure, one scoped Activity failure, no score request, and a saved
   server cursor.
3. Run only that test with a bounded DerivedData directory.
4. Confirm RED because the current runtime reports a fatal per-ID failure and
   no successful materialization.

### Task 2: Separate typed Activity failure from remote materialization

**Files:**
- Modify: `HealthComp/Services/RemoteCompetitionRuntime.swift`
- Test: `HealthCompTests/RemoteCompetitionRuntimeTests.swift`

1. Add a competition-scoped Activity failure result to
   `RemoteCompetitionRuntimeOutcome`.
2. Catch only typed `CompetitionActivitySourceError` values at the
   `environment.read` boundary.
3. Return the already-validated materialization alongside that nonfatal result.
4. Preserve cancellation and every storage, outbox, App Attest, score, and
   server-contract throw.
5. Run the focused runtime test and confirm GREEN.

### Task 3: Publish the competition with a truthful issue

**Files:**
- Modify: `HealthComp/Features/Competition/LocalCompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/CompetitionSharingView.swift`
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`

1. Add a client test for a valid scheduled history plus failing Activity read.
2. Assert that the competition remains visible and the new scoped
   `activityFailures` issue is published.
3. Run the test and confirm RED before production edits.
4. Map runtime Activity failures to the new client issue and add the truthful
   Sharing summary.
5. Run the focused client and presentation tests and confirm GREEN.

### Task 4: Focused regression and evidence

**Files:**
- Modify: `docs/release/production-beta-checklist.md`
- Modify: `docs/release/production-beta-evidence.md`

1. Run the focused runtime/client suite, related HealthKit provider tests, and
   source-level diff/secret checks with bounded artifacts.
2. Record the diagnosed boundary, test proof, and remaining need for an
   exact-current staging runtime receipt; do not mark physical HealthKit or
   production readiness complete.
3. Review the Standards and Spec axes without subagents, per the explicit
   zero-subagent rollout constraint.
4. Conventionally commit, push, open a purpose-named PR, wait for exact-head
   Backend and iOS CI, merge only if green, and verify both post-merge runs.
