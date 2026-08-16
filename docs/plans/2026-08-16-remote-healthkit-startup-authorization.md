# Remote HealthKit Startup Authorization Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure the authenticated remote competition client requests HealthKit read authorization before its first reconciliation without blocking or contaminating profile remounts.

**Architecture:** Split startup into two guarded phases around the system authorization request. The first phase marks the current runtime generation as started, the authorization request runs outside the profile operation gate, and the second phase starts signal/realtime pumps and reconciles only if the captured generation is still current. Authorization failure becomes the existing `.authorizationUnavailable` issue while reconciliation continues.

**Tech Stack:** Swift 5.9, Swift concurrency actors, XCTest, Xcode 26, HealthKit dependency seams.

---

### Task 1: Prove the missing request and failure behavior

**Files:**
- Modify: `HealthComp/Services/FixtureActivitySource.swift`
- Test: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`

**Step 1: Add observable authorization behavior to the DEBUG fixture**

Teach `FixtureActivitySource` to count authorization requests and optionally throw a configured `CompetitionActivitySourceError`. This is fixture infrastructure, not a production-only API.

**Step 2: Write the failing test**

Add `testStartRequestsHealthAuthorizationAndPublishesFailure`. Mount a real remote client over the accelerated environment, configure the fixture authorization request to fail, start the client, and assert exactly one request plus a canonical publication containing `.authorizationUnavailable`.

**Step 3: Run the focused RED test**

Run only the new XCTest with a unique temporary DerivedData path. Expected: FAIL because the current remote startup records zero authorization requests and publishes no authorization issue.

**Step 4: Implement the minimal behavior**

Request HealthKit authorization during remote startup, retain the failure as an additional reconciliation issue, and continue reconciliation.

**Step 5: Run the focused GREEN test**

Expected: the new test passes with one request and one `.authorizationUnavailable` issue.

### Task 2: Preserve profile-remount isolation while the prompt is open

**Files:**
- Modify: `HealthComp/Services/FixtureActivitySource.swift`
- Test: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`

**Step 1: Add a controllable authorization gate to the DEBUG fixture**

Mirror the fixture's existing read/wait gates so a test can block, observe, and release one authorization request deterministically.

**Step 2: Write the failing concurrency test**

Add `testHealthAuthorizationPromptDoesNotBlockOrPublishAcrossProfileRemount`. Start the first profile with authorization blocked, remount a second profile, require that remount to complete before release, and require the first profile stream to receive no stale publication.

**Step 3: Run the focused RED test**

Expected: FAIL because requesting authorization inside the current operation gate blocks the remount and permits the old generation to reconcile first.

**Step 4: Implement generation-safe startup**

Use a short first gate to mark startup and capture `runtimeGeneration`, run authorization outside the gate, then use a second gate that checks generation and stopped state before starting signal/realtime tasks and reconciling with any authorization issue.

**Step 5: Run focused and suite-level GREEN verification**

Run both new tests, then all `RemoteCompetitionClientTests`. Verify `git diff --check`, the secret scanner, and a clean source tree aside from the intentional change.

### Task 3: Review and integrate

**Files:**
- Review the complete branch diff and the updated plan.

**Step 1: Run code review**

Require no Critical or Important findings, with particular attention to actor reentrancy, stale-profile publication, duplicate prompts, and Test Lab isolation.

**Step 2: Commit conventionally**

Commit the implementation as `fix(healthkit): request remote startup authorization`.

**Step 3: Publish and integrate**

Push a purpose-named branch, open a focused PR, wait for serialized backend/iOS CI, and merge only the reviewed immutable head.

**Step 4: Resume the physical gate**

Rebuild and reinstall Staging from integrated `main`, then collect privacy-safe grant, deny, and re-enable evidence without retaining raw HealthKit values.
