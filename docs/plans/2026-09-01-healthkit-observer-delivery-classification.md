# HealthKit Observer Delivery Classification Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Classify HealthKit observer callbacks truthfully at synchronous ingress so only a callback received during an observed warm background interval is retained as background evidence.

**Architecture:** A process-rooted lifecycle classifier consumes aggregate SwiftUI `ScenePhase` changes and fails closed to the existing foreground observer trigger until this process has observed active-to-background. `HealthKitObserverUpdateController` snapshots that trigger at callback ingress and carries it through the existing provider, durable receipt, and completion ownership pipeline without changing the receipt schema.

**Tech Stack:** Swift 5.9 language mode, SwiftUI `ScenePhase`, HealthKit, Foundation locking, XCTest, XcodeGen.

---

### Task 1: Prove the lifecycle attribution rules

**Files:**
- Create: `HealthCompTests/HealthKitObserverDeliveryClassifierTests.swift`
- Modify: `HealthComp.xcodeproj/project.pbxproj` through XcodeGen

**Step 1: Write the failing tests**

Cover these independent states:

- no observed phase is foreground/ambiguous;
- initial `inactive` remains foreground/ambiguous;
- initial `background` remains foreground/ambiguous;
- `active` is foreground;
- `active` then `inactive` is foreground;
- `active` then `background` is background;
- `active` then `background` then will-enter-foreground is foreground before
  activation;
- reactivation returns to foreground;
- a later background transition becomes background again.

Use only the closed lifecycle enum; tests must not depend on UIKit or a running
scene.

**Step 2: Regenerate the project and verify RED**

Run XcodeGen once so the new test is compiled, then run:

```bash
xcodebuild test \
  -project HealthComp.xcodeproj \
  -scheme HealthComp \
  -destination 'platform=iOS Simulator,id=0D6F8FE9-73F5-4F2D-B704-7FFA1DA493F1' \
  -derivedDataPath /private/tmp/healthcomp-observer-delivery-derived \
  -disableAutomaticPackageResolution \
  -parallel-testing-enabled NO \
  -skipMacroValidation \
  -skipPackagePluginValidation \
  -only-testing:HealthCompTests/HealthKitObserverDeliveryClassifierTests
```

Expected: FAIL to compile because the classifier contract does not exist.

### Task 2: Implement and root the lifecycle classifier

**Files:**
- Create: `HealthComp/Services/HealthKitObserverDeliveryClassifier.swift`
- Modify: `HealthComp/App/HealthCompApp.swift`
- Modify: `HealthComp.xcodeproj/project.pbxproj` through XcodeGen

**Step 1: Implement the minimal state machine**

Add a lock-protected, `@unchecked Sendable` classifier with one process-rooted
production instance. Keep only the current closed phase and a
`hasObservedActive` flag. Return background only for current background plus
prior active; otherwise return foreground. Add a process-rooted lifecycle
bridge whose synchronous `UIScene` notification callbacks map will-enter-
foreground and will-deactivate to inactive, did-activate to active, and
did-enter-background to background.

**Step 2: Feed it from the process root**

Install the production bridge during `HealthCompApp` initialization, before the
scene is constructed. Also observe aggregate `scenePhase` on `HealthCompApp`
with the initial callback enabled and map its three cases to the same closed
lifecycle enum. Do not attach this to `MainTabView` or a profile. Add a custom-
`NotificationCenter` unit test proving will-enter-foreground clears background
attribution synchronously before the next activation.

**Step 3: Regenerate and verify GREEN**

Run XcodeGen twice, require the second generation to be clean, and rerun the
Task 1 test command with zero failures.

### Task 3: Capture classification at observer ingress

**Files:**
- Modify: `HealthComp/Services/HealthKitProvider.swift`
- Modify: `HealthCompTests/HealthKitProviderTests.swift`

**Step 1: Write ingress and propagation RED tests**

Add tests that:

- block immediately after the observer callback snapshots a test trigger,
  change the trigger source before any controller lock, ingress hook, or async
  stream consumption can finish, and assert the wakeup retained the original
  ingress trigger;
- yield explicit foreground and background wakeups through a provider and
  assert each resulting `EnvironmentSignal.trigger` is unchanged;
- assert both signals keep completion ownership until `completeSignal`.

Run only those tests and confirm RED because wakeups carry no trigger and the
provider hard-codes background.

**Step 2: Implement the narrow propagation path**

Make `HealthKitObserverWakeup` carry an explicit observer trigger. Inject a
sendable trigger snapshot closure into `HealthKitObserverUpdateController`; use
the process classifier in production and deterministic closures in tests.
Invoke the closure as the first operation in `receive`, before acquiring the
controller condition, invoking `didRegisterIngress`, or yielding. Emit
`update.trigger` from `HealthKitProviderSignalState`.

**Step 3: Verify GREEN**

Run all `HealthKitProviderTests` serially and require zero failures.

### Task 4: Preserve completion ownership and receipt compatibility

**Files:**
- Modify: `HealthComp/Services/FixtureActivitySource.swift`
- Rename: `HealthComp/Services/HealthKitBackgroundDeliveryReceipt.swift` to `HealthComp/Services/HealthKitObserverDeliveryReceipt.swift`
- Modify: `HealthCompTests/FixtureActivitySourceTests.swift`
- Rename: `HealthCompTests/HealthKitBackgroundDeliveryReceiptTests.swift` to `HealthCompTests/HealthKitObserverDeliveryReceiptTests.swift`
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Modify: `HealthComp/Services/AuthenticatedProfileStorage.swift`

**Step 1: Write receipt and remote RED tests**

Prove that schema version 1 round-trips one foreground and one background
observer receipt without adding fields. Prove a non-observer trigger remains
invalid. Add a direct fixture test asserting foreground and background observer
signals require completion while a non-observer signal does not. Exercise
remote durable commit-before-completion with an explicit foreground observer
callback and assert the committed trigger is preserved. Exercise first-commit
failure and idempotent retry independently for foreground and background
observer callbacks; assert both attempts retain the expected trigger rather
than checking only count and equality.

**Step 2: Implement observer-trigger validation**

Define one shared `ActivityRefreshTrigger.isHealthKitObserverDelivery` predicate
and use it for completion ownership in the fixture source and trigger validation
in the receipt store. Rename the source-level receipt/client/store/failure types,
profile storage property, coordinator variables, and tests from background
delivery to observer delivery. Keep the deployed `BackgroundDelivery` directory
component, JSON filename, schema version, privacy allowlist, retention,
durability, and teardown behavior unchanged.

**Step 3: Verify GREEN**

Run the fixture, receipt, provider, and remote client test classes serially with
the bounded DerivedData directory.

### Task 5: Focused and full verification

**Files:**
- Modify: `docs/release/production-beta-checklist.md`
- Modify: `docs/release/production-beta-evidence.md`

**Step 1: Record the evidence boundary**

Document that the prior signed artifact's receipts prove durable observer
processing only, not background provenance. Record automated lifecycle and
ingress coverage only after it passes. Specify a physical verifier that takes
an exact transient pre-install receipt baseline, compares process-scoped signal
identities in memory, and accepts only a newly appended background receipt from
the new artifact/process after the controlled active-to-background transition.
Retain only aggregate counts and artifact provenance. Leave the physical gate
pending for that newly signed artifact.

**Step 2: Run deterministic generation and static gates**

Run XcodeGen twice and require no second-pass diff. Run `git diff --check`, the
repository secret verifier, and any checked-in privacy/evidence validation
scripts applicable to the release docs.

**Step 3: Run relevant matrices serially**

Run the full HealthComp test target, CompetitionCore Debug and Release tests,
and unsigned Debug, Staging, and Release device builds. Use only bounded
DerivedData under `/private/tmp`, never run expensive Xcode and Supabase gates
in parallel, and remove temporary build artifacts after retaining only
privacy-safe receipts.

### Task 6: Review, commit, and integrate

**Step 1: Review**

Review the complete branch against the design, production rollout invariants,
and physical-evidence boundary. Resolve all Critical and Important findings and
rerun affected tests.

**Step 2: Commit logical changes**

Commit the design/plan separately, then the RED/GREEN implementation and the
truthful release evidence. Do not commit credentials, private device output,
Health values, identities, or temporary artifacts.

**Step 3: Integrate**

Push the purpose-named branch, open a plain descriptive PR, require green CI
and review, merge into `main`, and verify post-merge CI. Only then select one
new signed staging artifact for the combined HealthKit/APNs physical gates.
