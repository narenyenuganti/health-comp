# App Attest Rejection Diagnostics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Localize the remaining physical App Attest rejection to one privacy-safe verifier stage without changing the public response or retaining proof data.

**Architecture:** Replace the single internal `invalid_attestation` verifier code with four closed stage codes for the outer object, authenticator data, COSE key, and nonce binding. The existing reporter remains a one-string seam and the submit handler continues returning the same non-enumerating HTTP 401.

**Tech Stack:** Deno 2, TypeScript, Supabase Edge Functions, CBOR, ASN.1, Node-compatible crypto, shell verification scripts.

---

### Task 1: Freeze the diagnostic design

**Files:**

- Create: `docs/plans/2026-08-20-app-attest-rejection-diagnostics-design.md`
- Create: `docs/plans/2026-08-20-app-attest-rejection-diagnostics.md`

**Step 1: Record the observed boundary**

Document the version 6 physical retry as one challenge, HTTP 401,
`invalid_attestation`, no consumed challenge, and no key, grant, or score write.
State explicitly that this is not successful physical acceptance.

**Step 2: Record rejected approaches**

Reject proof capture and variable structural metadata. Preserve the fixed-event
plus closed-enum reporter and unchanged public response.

**Step 3: Verify the documents**

Run:

```bash
git diff --check
if rg -n \
  "production-ready|physical App Attest (passed|succeeded)|raw HealthKit (upload|server)" \
  docs/plans/2026-08-20-app-attest-rejection-diagnostics-design.md; then
  exit 1
fi
```

Expected: clean diff; the search returns no production-readiness,
successful-acceptance, or raw-health-upload claim.

**Step 4: Commit**

```bash
git add \
  docs/plans/2026-08-20-app-attest-rejection-diagnostics-design.md \
  docs/plans/2026-08-20-app-attest-rejection-diagnostics.md
git commit -m "docs(app-attest): plan rejection diagnostics"
```

### Task 2: RED-to-GREEN the four verifier stages

**Files:**

- Modify: `supabase/functions/_shared/app_attest_test.ts`
- Modify: `supabase/functions/_shared/app-attest.ts`

**Step 1: Write the failing fixture test**

Add a test that captures all four typed failures before comparing them, so the
RED output shows the complete current conflation:

```typescript
assertEquals(
  [
    captureCode(() => verifyAppAttestAttestation(malformedObject)),
    captureCode(() => verifyAppAttestAttestation(malformedAuthenticator)),
    captureCode(() => verifyAppAttestAttestation(malformedCOSE)),
    captureCode(() => verifyAppAttestAttestation(wrongNonce)),
  ],
  [
    "invalid_attestation_object",
    "invalid_attestation_authenticator_data",
    "invalid_attestation_cose_key",
    "invalid_attestation_nonce",
  ],
);
```

Use the checked-in Apple fixture. Change only the object byte, authenticator
flags, one COSE field, or the 32-byte client-data hash for the corresponding
case. Do not add proof logging or a test-only production seam.

**Step 2: Run the test to verify RED**

Run:

```bash
NO_COLOR=1 deno test --config supabase/functions/deno.json \
  --allow-read supabase/functions/_shared/app_attest_test.ts
```

Expected: FAIL because all four candidates currently report
`invalid_attestation`.

**Step 3: Implement the minimal split**

In `AppAttestVerificationErrorCode`, replace `invalid_attestation` with the four
new values. Map only these existing controls:

- outer CBOR and attestation-statement shape -> `invalid_attestation_object`
- authenticator fixed fields and signed extension boundary ->
  `invalid_attestation_authenticator_data`
- COSE map shape -> `invalid_attestation_cose_key`
- client-data hash bounds and certificate nonce equality ->
  `invalid_attestation_nonce`

Do not change the verification order, accepted inputs, certificate checks,
policy, or return values.

**Step 4: Run the test to verify GREEN**

Run the exact command from Step 2.

Expected: 11 tests pass with zero failures.

### Task 3: Preserve the public rejection and privacy contract

**Files:**

- Modify: `supabase/functions/submit-score-revision/index_test.ts`
- Modify: `docs/plans/2026-08-15-app-attest-beta-integrity.md`

**Step 1: Extend the existing handler matrix**

Replace the legacy `invalid_attestation` matrix entry with all four new codes.
For every code, assert one report, HTTP 401
`app_attest_proof_rejected`, and no authorization call.

**Step 2: Record the truthful boundary**

Append the version 6 privacy-safe evidence and state that the diagnostic split
is required before another authorized physical attempt. Do not claim physical
acceptance or production readiness.

**Step 3: Run focused verification**

Run:

```bash
NO_COLOR=1 deno test --config supabase/functions/deno.json \
  --allow-env --allow-net --allow-read \
  supabase/functions/submit-score-revision/index_test.ts
```

Expected: 13 tests pass with zero failures and the public error contract is
unchanged.

**Step 4: Commit the code and evidence**

```bash
git add \
  supabase/functions/_shared/app-attest.ts \
  supabase/functions/_shared/app_attest_test.ts \
  supabase/functions/submit-score-revision/index_test.ts \
  docs/plans/2026-08-15-app-attest-beta-integrity.md
git commit -m "fix(app-attest): distinguish rejection stages safely"
```

### Task 4: Run integration gates and review

**Files:**

- Review: all changes from merge base `d0ccba77af719d92b94f39f3157279e4ad456a0d`

**Step 1: Run formatting and focused runtime gates**

```bash
deno fmt --check \
  supabase/functions/_shared/app-attest.ts \
  supabase/functions/_shared/app_attest_test.ts \
  supabase/functions/submit-score-revision/index_test.ts
NO_COLOR=1 deno test --config supabase/tests/app-attest-hosted-regression.deno.json \
  --allow-read supabase/functions/_shared/app-attest_hosted_regression_test.ts
sh scripts/test-app-attest-edge-runtime.sh
```

Expected: all commands exit 0; the official fixture passes in the pinned Edge
Runtime and rejected dependencies remain unreachable.

**Step 2: Run the backend and privacy matrix serially**

Use the repository's checked-in backend verifier plus secret and privacy
scripts. Serialize any Supabase/Docker-backed gate and keep temporary artifacts
bounded.

Expected: every existing backend assertion remains green; no credential or
privacy-boundary finding.

**Step 3: Review Standards and Spec**

Review the exact diff for closed-enum completeness, unchanged public response,
no accepted-input change, no variable logging, and truthful rollout claims.
Resolve every Critical or Important finding and rerun affected gates.

**Step 4: Verify final repository state**

```bash
git diff --check d0ccba77af719d92b94f39f3157279e4ad456a0d..HEAD
git status --short --branch
```

Expected: clean committed branch with only the planned files changed.

**Step 5: Integrate without deploying**

Publish the purpose branch, require green CI and review, then integrate into
`main` with a conventional history. Do not deploy staging or launch a physical
device as part of this task.
