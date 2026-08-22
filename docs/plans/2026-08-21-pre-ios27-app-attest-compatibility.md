# Pre-iOS-27 App Attest Compatibility Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Accept fully verified pre-iOS-27 App Attest proofs without fabricating the validation-category and bundle-version extensions introduced in iOS 27.

**Architecture:** Decode the legacy and extended Apple authenticator-data shapes into one verifier result with a nullable, inseparable policy-metadata pair. Persist that pair through one forward-only private-schema migration and require every later assertion to preserve the registered key's format while retaining all cryptographic, identity, counter, replay, RLS, and score contracts.

**Tech Stack:** Deno 2, TypeScript, CBOR, ASN.1, Node-compatible crypto, Supabase PostgreSQL migrations and pgTAP.

---

### Task 1: Freeze the evidence-backed design

**Files:**
- Create: `docs/plans/2026-08-21-pre-ios27-app-attest-compatibility-design.md`
- Create: `docs/plans/2026-08-21-pre-ios27-app-attest-compatibility.md`

**Step 1: Record the physical boundary**

Record iOS 26.6, two successful challenges, two fixed authenticator-data
rejections, and zero accepted keys/grants/scores without retaining a proof,
identifier, score, HealthKit value, or request body.

**Step 2: Freeze the compatibility invariants**

Specify optional-as-a-pair policy metadata, immutable format per key, full
legacy cryptographic verification, strict extended allowlists, and one
forward-only migration.

**Step 3: Verify and commit**

Run `git diff --check`, scan the documents for false acceptance/readiness
claims, then commit as `docs(app-attest): design pre-iOS-27 compatibility`.

### Task 2: RED-to-GREEN authenticator decoding

**Files:**
- Modify: `supabase/functions/_shared/app_attest_test.ts`
- Modify: `supabase/functions/_shared/app-attest.ts`

**Step 1: Write failing verifier tests**

From the checked-in Apple fixture, remove only the trailing extension map and
assert that parsing reaches the nonce stage rather than
`invalid_attestation_authenticator_data`. Add signed synthetic assertion cases
for a 37-byte legacy header and the existing extended shape. Assert nullable
metadata for legacy, exact metadata for extended, and rejection of malformed or
extra CBOR objects.

**Step 2: Verify RED**

Run:

```bash
NO_COLOR=1 deno test --config supabase/functions/deno.json \
  --allow-read supabase/functions/_shared/app_attest_test.ts
```

Expected: the legacy attestation stops at the current authenticator-data error
and the legacy assertion is rejected by the current minimum-length/extension
requirements.

**Step 3: Implement the minimal decoder**

Return `validationCategory: number | null` and
`bundleVersion: string | null`. Accept exactly one or two attestation trailing
objects and exactly zero or one assertion extension object. Validate the map
strictly when present. Keep every other validation order and input bound.

**Step 4: Verify GREEN and commit**

Run the exact focused test and commit as
`fix(app-attest): verify legacy authenticator shapes`.

### Task 3: Preserve the handler and registered-key format

**Files:**
- Modify: `supabase/functions/submit-score-revision/index_test.ts`
- Modify: `supabase/functions/submit-score-revision/index.ts`

**Step 1: Write failing handler tests**

Add a legacy attestation result with a null metadata pair and prove the private
authorization call receives both nulls. Add legacy and extended assertion
continuity cases, plus legacy-to-extended and extended-to-legacy rejection
cases that never call authorization.

**Step 2: Verify RED**

Run the focused handler test and confirm current parsing/result guards reject
the null pair.

**Step 3: Implement pair validation**

Allow only both-null or both-valid metadata. Require assertion result presence
and values to equal the registered key's pair. Keep the same public HTTP errors
and closed diagnostic reporter.

**Step 4: Verify GREEN and commit**

Run the focused handler and shared-verifier tests, then commit as
`fix(app-attest): preserve legacy key format`.

### Task 4: Add the forward-only private-schema migration

**Files:**
- Create: `supabase/migrations/20260822001000_add_pre_ios27_app_attest_compatibility.sql`
- Modify: `supabase/tests/014_app_attest_integrity.test.sql`

**Step 1: Write failing pgTAP assertions**

Increase the plan and add assertions that the metadata columns are nullable as
a pair, half-null and invalid-present pairs fail, a legacy attestation stores a
null pair and mints one grant, the context returns JSON nulls, a legacy
assertion advances the counter, format transitions fail, replay creates no
second grant, cleanup still purges private key state, and accepted score history
remains append-only.

**Step 2: Verify RED**

Run the isolated App Attest database test against the current migration chain.
Expected: null-pair storage or contract assertions fail before the new migration.

**Step 3: Implement the migration**

Drop only the old category/version constraints and NOT NULL attributes, add the
exact pair constraint, and replace `load_app_attest_context` and
`authorize_app_attest_proof` with unchanged signatures/grants. Do not edit any
historical migration.

**Step 4: Verify GREEN and commit**

Run the isolated pgTAP test and migration-layout verifier, then commit as
`fix(backend): store unavailable App Attest metadata truthfully`.

### Task 5: Run integration, privacy, and review gates

**Files:**
- Review: all changes from merge base `6e5e775795d04e62be821291a94113e1a0bc9330`

**Step 1: Run focused runtime gates**

Run Deno formatting, both focused tests, hosted regression, dependency graph,
and the pinned Edge Runtime test.

**Step 2: Run the serialized backend matrix**

Run the checked-in migration, pgTAP, Deno, secret, privacy-column, layout,
formatting, and clean-tree gates. Keep Docker/Supabase work serial and remove
bounded temporary artifacts through their checked-in cleanup paths.

**Step 3: Review Standards and Spec**

Review the exact diff for legacy cryptographic completeness, strict extended
metadata, null-pair truthfulness, immutable format, unchanged public errors,
forward-only migration order, RLS/grants, and no privacy leakage. Resolve every
Critical or Important finding and rerun affected gates.

**Step 4: Integrate without deploying**

Push the purpose branch, require exact-head CI and review, then guarded-merge it
into `main` and require post-merge CI. Staging migration and Function deployment
remain separate action-time approvals; no physical launch is included.
