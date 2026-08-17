# Supabase Network Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow an authenticated staging app to recover from a Realtime network outage without a process restart and report a transient remote discovery failure truthfully instead of describing it as local-storage damage.

**Architecture:** Upgrade the exact Supabase Swift pin from 2.49.0 to 2.55.1. The current app-owned Realtime adapter already retries a failed subscription indefinitely; Supabase 2.54–2.55 fixes the SDK state machine that could remain stuck after its first reconnect failed and makes the injected global `URLSession` available to Realtime. Preserve HealthComp's existing single ephemeral, non-persistent session and do not add app-layer request replay or client replacement. Separately map remote discovery failures to a dedicated presentation issue while keeping genuine cache/event-store failures classified as local storage.

**Tech Stack:** Swift 5.9 language mode, XCTest, Supabase Swift 2.55.1, XcodeGen, iOS 17+

---

### Task 1: Preserve truthful failure classification in tests

**Files:**
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`

**Step 1: Write the failing classification test**

Change the existing offline-cached-publication expectation from `.storageUnavailable` to `.remoteUnavailable`. Add direct expectations proving `RemoteCompetitionRuntimeFailure.discoveryUnavailable` maps to `.remoteUnavailable` while `.storageUnavailable` remains `.storageUnavailable`.

**Step 2: Write the failing presentation test**

Require `.remoteUnavailable` to render as `Unable to connect. HealthComp will keep trying.` and preserve the existing local-storage message.

**Step 3: Run the focused test and verify RED**

Run the selected `RemoteCompetitionClientTests` cases against the iOS 18.4 Simulator.

Expected: FAIL because `LocalCompetitionClientIssue.remoteUnavailable` and the failure-to-presentation mapping do not exist.

### Task 2: Implement the minimal recovery boundary

**Files:**
- Modify: `HealthComp/Features/Competition/LocalCompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/CompetitionSharingView.swift`
- Modify: `project.yml`
- Modify: `HealthComp.xcodeproj/project.pbxproj`
- Modify: `HealthComp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Step 1: Report remote discovery failure truthfully**

Add `.remoteUnavailable` to `LocalCompetitionClientIssue`. Add a deterministic mapping from `RemoteCompetitionRuntimeFailure` to the presentation issue, map only `.storageUnavailable` to local storage, and use that mapping in `performReconciliation()`. Render the dedicated remote message before the generic competition-action fallback.

**Step 2: Run the classification tests and verify GREEN**

Run the exact RED cases. Expected: PASS.

**Step 3: Pin Supabase Swift 2.55.1**

Update the exact version in `project.yml`, regenerate the Xcode project with XcodeGen, and resolve packages. Confirm `Package.resolved` records official tag commit `21d3aaf21ee98f41611f9f75070489fc8b23d882` and version `2.55.1`.

**Step 4: Verify deterministic generation**

Regenerate the project a second time and require identical project hashes. Confirm that the package upgrade does not change the deployment target or HealthComp Swift language mode.

**Step 5: Run the focused recovery gate**

Run configuration, authentication, remote API, Realtime, remote runtime, remote client, and sharing presentation tests. The existing `testSupabaseAdapterRetriesTransientSubscribeFailure` must remain green, proving the app wrapper performs a new open after a failed subscription.

### Task 3: Verify runtime and integration behavior

**Files:**
- Modify: `docs/release/production-beta-evidence.md`
- Modify: `docs/release/production-beta-checklist.md`
- Modify: `docs/plans/2026-08-17-supabase-network-recovery.md`

**Step 1: Run compatibility gates serially**

Run the canonical HealthComp unit test gate, Debug/Release/Staging builds, deterministic project generation, and source-tree cleanliness checks. Do not overlap these with another expensive Xcode or Supabase gate.

**Step 2: Install the reviewed Staging build on Simulator**

Preserve the existing authenticated profile and data container. Launch the build and confirm authenticated discovery succeeds. Retain only privacy-safe status/count evidence and do not create or consume invitations.

**Step 3: Verify the recovery contract**

Use the deterministic app-adapter retry test and the SDK's exact reviewed release pin as automated evidence. Confirm the current Simulator process remains free of `-1005` events after launch. Do not disrupt host networking or the physical phone merely to recreate an opaque platform outage.

**Step 4: Run review and repository guards**

Run `git diff --check`, the no-secrets verifier, credential-pattern scans, and independent code review. Resolve all Critical/Important findings test-first.

**Step 5: Commit and integrate**

Create one conventional bugfix commit, push the purpose-named branch, open a pull request, require hosted Backend/iOS CI, and use a guarded squash merge only after review and checks are green. Pull the resulting merge into clean local `main`.

**Step 6: Resume Task 19**

Return to the approved one-physical-iPhone-plus-Simulator two-account staging flow. This bugfix does not replace any physical-device, adversarial, deletion, restore, or production evidence gate.

## Verified result before integration

- Supabase Swift is pinned exactly to 2.55.1 at official tag revision
  `21d3aaf21ee98f41611f9f75070489fc8b23d882`. The generated project hash
  remained `f255f6cd138334c621f33c798028a289101f25334380f05227b25ef249ca6cca`
  across the tracked file and two consecutive XcodeGen 2.46.0 generations.
- The shared lockfile retains the compatibility-only packages that newer
  SwiftPM trait and platform pruning does not materialize: OpenCombine 0.14.0
  at revision `8576f0d579b27020beccbccc3ea6844f3ddfc2c2`, OpenTelemetry
  Swift Core 2.5.1 at revision
  `06f8a460a66f813758d22f09025d85df45450a63`, and Swift Atomics 1.3.1 at
  revision `0442cb5a3f98ab802acb777929fdb446bda11a34`. The first hosted
  Xcode 16.4 attempt exposed OpenCombine before app tests. The second accepted
  that pin, passed deterministic generation and both Core configurations, then
  exposed Supabase's optional OpenTelemetry package. OpenTelemetry's manifest
  also declares Swift Atomics for Linux, so both exact compatible pins are
  retained to close the cross-Xcode dependency chain. The resulting superset
  passed strict local resolution unchanged and requires a fresh hosted rerun.
- Failure classification is explicit: cancellation publishes no issue, local
  persistence failure remains `.storageUnavailable`, retryable discovery
  failure becomes `.remoteUnavailable`, and non-retryable remote failures use
  `.remoteFailure`. Activity authorization retains presentation priority when
  multiple issues are present.
- The two review-driven tests passed, followed by the complete 90/90 focused
  recovery matrix and 459/459 canonical `HealthCompTests`, all with zero
  failures or skips. CompetitionCore passed 241/241 tests in both Debug and
  Release.
- Unsigned Debug, Release, and Staging device builds succeeded serially. The
  signed Staging Simulator build used the expected public project URL, a
  publishable-key-shaped value, a blank invitation host, and the controlled
  custom scheme. Embedded HealthKit and background-delivery entitlements were
  verified before installation.
- The Staging over-install left the local data-container file count unchanged
  at 19 and restored the authenticated Sharing UI. From
  `2026-08-17 02:46:15.068` through `02:49:22.348` PDT, the current HealthComp
  process stayed running with 42 process-local HTTP-200 log markers and zero
  `-1005`, HealthKit-entitlement, or crash markers. The transient UI screenshot
  was deleted and no invitation was created or consumed.
- CodeRabbit's stabilized-diff re-review reported zero findings. The no-secrets
  verifier and `git diff --check` passed before runtime verification.

The branch is committed and published as PR #26, but it is not yet hosted-CI
verified, merged, or installed on the physical iPhone. Those remain required
before Task 19 resumes.
