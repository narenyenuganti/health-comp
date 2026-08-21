# App Attest Physical Rejection Recovery Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Preserve a privacy-safe verifier reason for the real staging rejection and give the existing legacy terminal score exactly one durable recovery attempt.

**Architecture:** The Edge handler receives an injected reporter that accepts only `AppAttestVerificationErrorCode`; the live implementation logs a fixed event and that closed enum while keeping the client response unchanged. The iOS outbox retains the old `appAttestRejected` wire value as a decode-only migration source, moves it into a durable recovery state that survives bounded transport retry and relaunch, and writes all subsequent App Attest failures as `appAttestRejectedTerminal`.

**Tech Stack:** Swift 5.9, XCTest, Deno, TypeScript, Supabase Edge Functions, JSON profile-scoped outbox storage.

---

### Task 1: Verify the exact-head focused baseline

**Files:**

- Test: `supabase/functions/submit-score-revision/index_test.ts`
- Test: `HealthCompTests/CompetitionSyncCoordinatorTests.swift`

**Step 1: Run the focused Deno suite**

Run:

```bash
deno test --config supabase/functions/deno.json --allow-env --allow-net --allow-read supabase/functions/submit-score-revision/index_test.ts
```

Expected: PASS at exact `main` head.

**Step 2: Run the focused coordinator suite serially**

Run the repository's generated `HealthComp` Debug test scheme against one
selected simulator with parallel testing disabled and a bounded DerivedData
directory, selecting only
`HealthCompTests/CompetitionSyncCoordinatorTests`. The optimized Staging
configuration is validated by build gates, not used as the XCTest host.

Expected: PASS at exact `main` head without creating an XCTest clone pool.

### Task 2: RED-to-GREEN the privacy-safe verifier reporter

**Files:**

- Modify: `supabase/functions/submit-score-revision/index_test.ts`
- Modify: `supabase/functions/submit-score-revision/index.ts`

**Step 1: Write the failing test**

Extend the stable proof-rejection test with an injected reporter that records
only its `AppAttestVerificationErrorCode`. Assert one exact code is reported,
authorization remains untouched, the public response remains HTTP 401 with
`app_attest_proof_rejected`, and no request or proof value crosses the reporter
seam.

**Step 2: Verify RED**

Run the focused Deno suite. Expected: FAIL because the handler does not invoke
the reporter.

**Step 3: Implement the smallest reporter seam**

Add an optional `reportVerificationFailure(code)` dependency, invoke it only
for typed verifier failures, and configure the live dependency to emit the
fixed event `app_attest_verification_rejected` plus the closed enum code. Do not
log an error object, request, identity, challenge, key, proof, or payload.

**Step 4: Verify GREEN**

Run the focused Deno suite. Expected: PASS with the response contract
unchanged.

**Step 5: Commit the backend unit**

```bash
git add supabase/functions/submit-score-revision/index.ts supabase/functions/submit-score-revision/index_test.ts
git commit -m "fix(backend): report App Attest rejection reason safely"
```

### Task 3: RED-to-GREEN durable one-time legacy recovery

**Files:**

- Modify: `HealthComp/Services/CompetitionOutboxStore.swift`
- Modify: `HealthComp/Services/CompetitionSyncCoordinator.swift`
- Modify: `HealthCompTests/CompetitionSyncCoordinatorTests.swift`

**Step 1: Write the first failing test**

Persist a score in legacy `.permanentFailure(.appAttestRejected, ...)`, create a
coordinator whose remote API succeeds, wake it, and assert exactly one request,
normal accepted-score persistence, and an empty outbox.

**Step 2: Verify the first RED**

Run only the new XCTest. Expected: FAIL with zero remote requests because the
startup migration currently matches only `appAttestUnavailable`.

**Step 3: Implement legacy recovery**

Extend the startup migration to select legacy `appAttestRejected` score rows as
well as `appAttestUnavailable`, without changing any other failure. Move legacy
rejections into a dedicated `appAttestRejectionRecovery` state so their origin
cannot be lost across persistence or relaunch.

**Step 4: Verify the first GREEN**

Run only the new XCTest. Expected: PASS.

**Step 5: Write the second failing test**

Persist the same legacy row, make its one recovery return
`CompetitionRemoteFailure.appAttestRejected`, then create a second coordinator
over the same store. Assert the first lifetime makes one request and the second
makes none while the row remains terminal.

**Step 6: Verify the second RED**

Run only the new XCTest. Expected: FAIL because the repeated rejection still
uses the legacy encoding and is reopened in the second lifetime.

**Step 7: Implement the terminal encoding**

Add `appAttestRejectedTerminal` to `CompetitionOutboxPermanentFailure`, map all
new App Attest proof/context/conflict rejections to it, and leave only the old
`appAttestRejected` value eligible for migration. Preserve both as
support-inspectable permanent failures. If a legacy rejection recovery reaches
another App Attest availability/proof failure, persist the terminal encoding;
retryable transport alone retains the dedicated recovery state and its bounded
backoff.

**Step 8: Verify the second GREEN and focused suite**

Run the new XCTest and then all `CompetitionSyncCoordinatorTests`. Expected:
PASS, including the unchanged bounded retry and no-spin tests.

**Review hardening:** Independently reproduce the two-lifetime path where the
legacy rejection recovery returns `appAttestUnavailable`. The second lifetime
must make no further request, and a separate transport-retry relaunch test must
prove the dedicated recovery provenance remains durable until a conclusive
outcome.

**Step 9: Commit the iOS unit**

```bash
git add HealthComp/Services/CompetitionOutboxStore.swift HealthComp/Services/CompetitionSyncCoordinator.swift HealthCompTests/CompetitionSyncCoordinatorTests.swift
git commit -m "fix(ios): recover legacy App Attest rejection once"
```

### Task 4: Record the truthful rollout boundary

**Files:**

- Modify: `docs/plans/2026-08-15-app-attest-beta-integrity.md`
- Modify: the active privacy-safe continuation status outside the repository only after integration evidence is final

**Step 1: Update the checked-in App Attest plan**

Record that real staging reached the verifier and failed closed, explain the
privacy-safe reason reporter and decode-only legacy recovery, and state that
neither proves physical acceptance.

**Step 2: Verify documentation claims against the staged diff**

Run the relevant static searches and `git diff --check`. Expected: no claim of
production readiness or successful physical verification.

**Step 3: Commit the documentation unit**

```bash
git add docs/plans/2026-08-15-app-attest-beta-integrity.md docs/plans/2026-08-20-app-attest-physical-rejection-design.md docs/plans/2026-08-20-app-attest-physical-rejection-recovery.md
git commit -m "docs(app-attest): record physical rejection recovery"
```

### Task 5: Verify, review, and integrate

**Files:**

- Review: all changes from merge base `1d933bdd7a48c6e39f9a54037c765b81de8d661d`

**Step 1: Run focused gates**

Run the Deno submission suite, all coordinator tests, the App Attest dependency
graph verifier, and the pinned Edge Runtime fixture serially.

**Step 2: Run proportional integration gates**

Run deterministic XcodeGen verification, the relevant iOS application suite,
backend format/lint/tests, secret scan, privacy scan, and `git diff --check`.
Keep DerivedData and test artifacts in one bounded temporary root and disable
parallel XCTest workers.

**Step 3: Review along Spec and Standards axes**

Review the exact staged snapshot against this design, the App Attest integrity
plan, repository conventions, privacy boundaries, durable no-loop behavior,
and unchanged public error contract. Fix any Critical or Important issue with a
fresh RED-to-GREEN cycle.

**Step 4: Integrate only after clean evidence**

Push the purpose-named branch, open a plain descriptive pull request, wait for
required checks, guarded-squash merge, and verify local `main` equals
`origin/main`. Do not deploy or install in this task.

**Step 5: Request the next action-time approvals**

After integration, request approval to deploy only `submit-score-revision` to
staging, install the exact reviewed Staging build over the existing app without
erasing data, and perform exactly one physical retry with privacy-safe local and
hosted readback.
