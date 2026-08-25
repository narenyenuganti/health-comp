# App Attest Assertion-Stage Diagnostics Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Localize the exact physical App Attest assertion rejection stage with fixed privacy-safe labels while preserving every verification and public-response contract.

**Architecture:** Split the current broad assertion rejection into object, key, and signature stages inside the shared verifier. Reuse the existing closed reporter seam so the handler still returns the same non-enumerating rejection and never exposes proof material.

**Tech Stack:** Deno 2, TypeScript, Node-compatible crypto, CBOR, Supabase Edge Functions.

---

### Task 1: Freeze assertion-stage RED tests

**Files:**
- Modify: `supabase/functions/_shared/app_attest_test.ts`
- Modify: `supabase/functions/submit-score-revision/index_test.ts`

**Step 1: Write the failing verifier test**

Extend the assertion test to require `invalid_assertion_object` for malformed
CBOR/shape and `invalid_assertion_signature` for a tampered signature. Require
`invalid_key` for an invalid or non-P-256 registered key.

**Step 2: Verify RED**

Run:

```bash
NO_COLOR=1 deno test --config supabase/functions/deno.json \
  --allow-read supabase/functions/_shared/app_attest_test.ts
```

Expected: FAIL because all new assertion stages currently collapse to
`invalid_assertion`.

**Step 3: Write the failing handler contract test**

Extend the stable proof-rejection table with both new codes and assert each
returns HTTP 401 `app_attest_proof_rejected`, reports exactly that code, and
does not call `authorize_app_attest_proof`.

**Step 4: Verify RED**

Run:

```bash
NO_COLOR=1 deno test --config supabase/functions/deno.json \
  --allow-env --allow-net --allow-read \
  supabase/functions/submit-score-revision/index_test.ts
```

Expected: type-check or assertion failure because the new codes are not in the
closed verifier union.

### Task 2: Implement the minimal diagnostic split

**Files:**
- Modify: `supabase/functions/_shared/app-attest.ts`

**Step 1: Add the closed codes**

Add `invalid_assertion_object` and `invalid_assertion_signature` to
`AppAttestVerificationErrorCode`.

**Step 2: Assign stages without changing acceptance**

Map decode and shape failures to `invalid_assertion_object`, public-key parse
and curve failures to `invalid_key`, and ECDSA verification failures to
`invalid_assertion_signature`. Preserve every existing validation and order.

**Step 3: Verify GREEN**

Run both exact focused commands from Task 1 and require zero failures.

**Step 4: Commit the implementation**

```bash
git add supabase/functions/_shared/app-attest.ts \
  supabase/functions/_shared/app_attest_test.ts \
  supabase/functions/submit-score-revision/index_test.ts
git commit -m "fix(app-attest): distinguish assertion rejection stages"
```

### Task 3: Run integration, privacy, and review gates

**Files:**
- Review: exact branch diff from `aa16411`

**Step 1: Run focused integration gates**

Run Deno formatting, the App Attest dependency-graph guard, the pinned Edge
Runtime probe, secret scan, and relevant privacy guards serially.

**Step 2: Review Standards and Spec**

Verify closed labels only, unchanged client response, unchanged authorization
boundary, no proof telemetry, no acceptance relaxation, and no unrelated diff.

**Step 3: Push and integrate**

Push the purpose branch, open a plain descriptive PR, require exact-head
Backend CI and review, then merge and require post-merge Backend CI.

### Task 4: Promote diagnostics and re-probe physically

**Files:**
- Update after evidence: `Docs/release/production-beta-checklist.md`
- Update after evidence: `Docs/release/production-beta-evidence.md`
- Update after evidence: `Docs/runbooks/supabase-environments.md`

**Step 1: Deploy only the reviewed Function**

Deploy only `submit-score-revision` from merged main to
`healthcomp-staging`. Do not change migrations, secrets, other Functions, or
production.

**Step 2: Run one phone-required retry**

State-preserving over-install the exact merged staging artifact, launch once,
perform one eligible authenticated refresh, and retain only aggregate HTTP
counts plus the fixed assertion-stage label.

**Step 3: Choose the next RED-to-GREEN step**

Correct only the proven failing stage test-first. Do not weaken App Attest or
claim acceptance until the hosted score submission returns 200 and replay
remains rejected.

