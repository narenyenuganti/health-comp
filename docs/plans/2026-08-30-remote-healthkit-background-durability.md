# Remote HealthKit Background Durability Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Persist a privacy-safe profile-scoped outcome before completing a production HealthKit background observer callback.

**Architecture:** Keep remote competition journals server-accepted-only and add a separate bounded `BackgroundDelivery` receipt store under the authenticated profile root. Route completion-bearing environment signals through that store after canonical reconciliation; retain and retry a callback when receipt persistence fails.

**Tech Stack:** Swift 6, Foundation/Darwin safe file I/O, The Composable Architecture dependency seams, XCTest, XcodeGen, HealthKit.

---

### Task 1: Prove the remote callback-ordering gap

**Files:**
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`

**Step 1: Write the failing test**

Add a test-only receipt gate to `RemoteCompetitionClientTests` and inject the
wished-for receipt client into `CompetitionClient.remote`. Mount and start the
client with an accelerated source, emit one `observerWakeupBackground` signal,
block the receipt commit, and assert that `signalCompletionCount` remains zero.
After releasing the commit, assert one receipt and exactly one completion.

**Step 2: Verify RED**

Run:

```bash
xcodebuild test \
  -project HealthComp.xcodeproj \
  -scheme HealthComp \
  -destination 'platform=iOS Simulator,id=0D6F8FE9-73F5-4F2D-B704-7FFA1DA493F1' \
  -derivedDataPath /tmp/healthcomp-remote-durability-derived.WTR2Yk \
  -parallel-testing-enabled NO \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -only-testing:HealthCompTests/RemoteCompetitionClientTests/testBackgroundObserverCompletionWaitsForDurableReceipt
```

Expected: FAIL because the existing remote client completes the environment
signal without any receipt boundary.

### Task 2: Add the profile-scoped receipt contract and store

**Files:**
- Create: `HealthComp/Services/HealthKitBackgroundDeliveryReceipt.swift`
- Create: `HealthCompTests/HealthKitBackgroundDeliveryReceiptTests.swift`
- Modify: `HealthComp/Services/AuthenticatedProfileStorage.swift`
- Modify: `HealthCompTests/AuthenticatedProfileStorageTests.swift`
- Modify: `project.yml`
- Modify: `HealthComp.xcodeproj/project.pbxproj` through XcodeGen

**Step 1: Write store RED tests**

Cover a privacy-safe round trip, idempotent identical commit, conflicting reuse,
bounded retention, invalid/symlinked files, `0600` file permissions, `0700`
directory permissions, and `.completeUntilFirstUserAuthentication` protection.
Update the profile-storage test to expect the `BackgroundDelivery` child.

**Step 2: Verify RED**

Run only the two affected test classes and confirm failures are caused by the
missing path and store.

**Step 3: Implement the minimal store**

Define a closed `HealthKitBackgroundDeliveryReceipt` containing:

```swift
let signalID: String
let trigger: ActivityRefreshTrigger
let processedAt: Date
let publicationRevision: UInt64
let hadIssues: Bool
```

Define a `HealthKitBackgroundDeliveryReceiptClient` with one async throwing
`commit` operation, plus live and test implementations. Persist a versioned,
sorted-key JSON document capped at 128 receipts using no-follow validation,
atomic replacement, bounded decoding, `0600`/`0700` permissions, and protected
data access after first unlock. Add `backgroundDeliveryDirectory` to the fixed
profile paths and regenerate the project deterministically.

**Step 4: Verify GREEN**

Run the two focused store/profile test classes and require zero failures.

### Task 3: Complete only after durable receipt persistence

**Files:**
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`

**Step 1: Implement the narrow ordering path**

Create the live receipt client during profile mount. For
`signal.requiresCompletion`, reconcile first, commit the receipt, and then call
`environment.completeSignal`. Keep a failed signal in a coordinator-owned
pending map and retry it after the next canonical reconciliation. Clear only
the coordinator's mirror on stop/remount; rely on the process-rooted provider to
replay any uncompleted callback.

**Step 2: Verify GREEN**

Run the Task 1 test and confirm receipt commit precedes exactly one completion.

**Step 3: Add and verify failure-retry RED/GREEN**

Add `testBackgroundObserverReceiptFailureRetriesBeforeCompletion`: fail the
first commit, assert no completion, invoke one foreground reconciliation, then
assert one committed receipt and one completion. Also prove stop does not
complete a pending signal and remount replays it.

### Task 4: Make HealthKit signal identities safe across launches

**Files:**
- Modify: `HealthComp/Services/HealthKitProvider.swift`
- Modify: `HealthCompTests/HealthKitProviderTests.swift`

**Step 1: Write RED test**

Construct two provider signal states, emit one observer event from each, and
assert distinct signal IDs while preserving replay identity within one state.

**Step 2: Implement GREEN**

Add one process-instance UUID to `HealthKitProviderSignalState` and include it in
the generated signal ID. Do not expose profile, competition, device, HealthKit,
or server identifiers.

**Step 3: Verify**

Run `HealthKitProviderTests` and require all tests to pass.

### Task 5: Focused and integration verification

**Files:**
- Modify: `Docs/release/production-beta-checklist.md`
- Modify: `Docs/release/production-beta-evidence.md`

**Step 1: Run focused tests**

Run the receipt, profile-storage, HealthKit-provider, remote-client, and remote-
runtime test classes serially with the bounded DerivedData directory.

**Step 2: Run project generation and diff gates**

Run XcodeGen twice and require a clean second generation, then run
`scripts/verify-no-secrets.sh` and `git diff --check`.

**Step 3: Run the relevant canonical matrices**

Run the complete app test target, CompetitionCore Debug and Release tests, and
unsigned Debug/Staging/Release device builds serially. Keep all build artifacts
inside the bounded DerivedData root and delete them after receipts are retained.

**Step 4: Record truthful evidence**

Document the August 30 physical attempt as a genuine saved Watch event with no
legacy marker and no conclusion about HealthKit delivery. Document the new
automated durability contract as passing only after its tests pass; leave the
physical background-observer gate pending until a signed build produces the
privacy-safe profile receipt on-device.

### Task 6: Review and integrate

**Step 1: Review**

Review the complete branch diff against this design and the production rollout
invariants. Resolve every Critical or Important finding and rerun affected
tests.

**Step 2: Commit**

Create conventional logical commits for the design, RED/GREEN implementation,
and evidence update. Do not include credentials, private screenshots, device
identifiers, Health values, scores, workout details, or temporary artifacts.

**Step 3: Integrate**

Push the purpose-named branch, open a plain descriptive PR, require green CI and
review, merge into `main`, and verify post-merge CI before selecting a new
physical staging artifact.
