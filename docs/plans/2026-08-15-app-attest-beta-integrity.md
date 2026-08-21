# App Attest Beta Integrity Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:test-driven-development to
> implement this plan task-by-task.

**Goal:** Require a fresh, one-time App Attest proof before every production
score-revision submission while preserving HealthComp's local raw-HealthKit
boundary, idempotent outbox, and deterministic DEBUG Test Lab.

**Architecture:** A profile-scoped iOS coordinator signs a compact binary
client-data envelope that binds the authenticated profile, stable installation,
one-time server challenge, purpose, and SHA-256 of the existing canonical score
JSON. Supabase stores private challenge/key/counter state and exchanges each
verified proof for a short-lived, single-use submission grant; the existing
score mutation can only be reached through that grant. The Deno verifier pins
CBOR and ASN.1 dependencies and performs strict app-owned certificate,
attestation, and assertion verification with ASN.1.js and `node:crypto`. The
production graph deliberately excludes PKI.js and `node-app-attest`; an isolated
adversarial fixture retains their exact former versions only to reproduce the
hosted-runtime incompatibility. The shared boundary enforces the 2026 Apple
requirements: exact CBOR shape, certificate chain and time, nonce, key binding,
environment, validation category, bundle version, payload binding, one-time
challenge, and monotonic counter.

**Tech Stack:** Swift 5.9, CryptoKit, DeviceCheck `DCAppAttestService`, XCTest,
Deno, `cbor@10.0.12`, `asn1js@3.0.10`, `node:crypto`, Supabase Edge Functions
and pinned Edge Runtime fixture, PostgreSQL 17, RLS, pgTAP, XcodeGen.

---

## Frozen decisions

- App Attest is a beta integrity signal; it never claims raw HealthKit truth or
  a cheat-proof device.
- Score payloads remain the existing privacy-approved percentage/points
  envelope. No raw HealthKit values, samples, workouts, routes, or fingerprints
  enter App Attest client data, backend rows, responses, or logs.
- The client-data byte layout is versioned and non-JSON:
  `healthcomp-app-attest-v1`, NUL, then tag/length/value fields for challenge
  UUID, 32-byte challenge, profile UUID, installation UUID, 32-byte canonical
  score-JSON hash, and ASCII purpose `score_revision`.
- Debug Test Lab continues to construct no live Supabase or DeviceCheck
  dependency graph.
- Development and Staging direct installs use the App Attest development
  environment. Release/TestFlight uses production. A Supabase project accepts
  exactly one configured App ID, environment, validation-category set, and
  bundle-version set.
- The private-beta production category is TestFlight (`2`). Staging
  direct-development category is development signing (`3`). App Store category
  (`4`) is added only when that distribution exists. Bundle-version policy uses
  the exact `CFBundleVersion` build string (`1` today), not the marketing
  version.
- HealthComp owns the complete attestation and assertion verifier. The
  production dependency graph contains neither `node-app-attest` nor PKI.js:
  their initialization and X.509 paths are incompatible with the pinned hosted
  Edge worker. Certificate structure, algorithm matching, Apple-chain
  signatures, nonce extraction, assertion signatures, and counters are all
  verified in the shared boundary with bounded ASN.1 parsing and
  `node:crypto`.
- Apple's 2026 guide prose labels its example bundle version `1.0`, while the
  published CBOR fixture encodes `1`. Tests preserve both facts and treat the
  signed CBOR value as authoritative.
- Apple's 2026 fixture signs the UTF-8 challenge bytes directly as
  `clientDataHash` even though the guide prose describes hashing the challenge.
  The fixture preserves those signed bytes for compatibility testing;
  HealthComp's production protocol always supplies a 32-byte SHA-256 client-data
  hash.
- Missing, unsupported, malformed, stale, replayed, or misbound proof fails
  score submission closed. Apple/server outages remain retryable and do not
  discard the local outbox.
- Associated Domains remain outside this task and explicitly deferred because no
  invitation domain exists.

> **Runtime correction (2026-08-20):** A real staging attestation reached a
> fail-closed hosted-runtime error even though the deployed ESZip contained the
> checked-in import map and frozen graph. The corrective boundary removes both
> PKI dependency ingresses, verifies Apple's official fixture inside the exact
> pinned Supabase Edge user worker, and separately preserves the former exact
> raw dependency graph as a RED-capable regression. A credential-free endpoint
> boot probe alone is not App Attest runtime evidence.

> **Physical staging checkpoint (2026-08-20):** Function version 5 booted and a
> development-signed physical iPhone obtained one fresh attestation challenge
> and reached `submit-score-revision`. The endpoint returned the unchanged
> non-enumerating HTTP 401 `app_attest_proof_rejected`; the challenge remained
> unconsumed, and staging created no App Attest key, submission grant, or
> accepted score. This proves fail-closed verifier reachability after the
> runtime correction, not successful physical attestation.
>
> The rejection-recovery follow-up preserves that public response and reports
> only a fixed log event plus the closed verifier-reason enum. It treats the
> existing local `appAttestRejected` encoding as a decode-only beta migration
> source eligible for one recovery. Its dedicated durable recovery state
> survives bounded transport retry and relaunch without becoming a generic
> legacy failure again, while every subsequent App Attest
> availability/proof/context/conflict failure is written as
> `appAttestRejectedTerminal` and is never reopened by a fresh coordinator. No
> identity, challenge, key, proof, score, or HealthKit value enters this
> diagnostic seam. Successful physical key registration and assertion renewal
> remain required evidence.

> **Physical rejection diagnostic checkpoint (2026-08-20):** Function version
> 6 was deployed from exact `main` commit `d0ccba7`, and HealthComp Staging was
> reinstalled in place without erasing its authenticated or App Attest state.
> Exactly one legacy recovery request reached the verifier. It returned HTTP
> 401 and emitted only `app_attest_verification_rejected invalid_attestation`.
> The retry window contained one new attestation challenge, zero consumed
> challenges, zero registered keys, zero submission grants, and zero accepted
> score revisions. The device retained one `appAttestRejectedTerminal` outbox
> entry with no retry scheduled, so no further request occurred.
>
> That enum value still combines the outer CBOR object, authenticator-data
> layout, COSE credential key, and certificate nonce binding. The next
> phone-free diagnostic change separates those four fixed stages without
> logging any variable proof metadata or changing the client-visible 401.
> Staging deployment of that diagnostic and any additional physical attempt
> remain separately approved actions. Physical acceptance is still missing.

## Task 1: Freeze protocol fixtures and verifier boundary

**Files:**

- Create: `supabase/functions/_shared/app-attest.ts`
- Create: `supabase/functions/_shared/app_attest_test.ts`
- Create: `supabase/tests/fixtures/app-attest-official-2026.json`
- Modify: `supabase/functions/deno.json`
- Modify: `supabase/functions/deno.lock`

1. Add RED tests for the binary client-data golden bytes and canonical score
   payload hash.
2. Add Apple's published 2026 attestation object, challenge, key ID, App ID,
   expected category, and bundle version as a non-secret offline fixture.
3. Add RED verifier tests for valid fixture, wrong App ID/team-or-bundle, wrong
   environment, disallowed validation category, wrong bundle version,
   expired/not-yet-valid leaf certificate, malformed CBOR, invalid AAGUID, and
   key-ID mismatch.
4. Add RED synthetic assertion tests for signature, RP ID, exact extension map,
   bundle/category mismatch, and counter extraction.
5. Pin `cbor@10.0.12` and `asn1js@3.0.10`, regenerate the frozen Deno lock, and
   fail the runtime gate if the resolved production graph reaches PKI.js or
   `node-app-attest`. Keep the former exact package pins only in the isolated
   hosted-regression configuration.
6. Implement the smallest strict wrapper that makes the tests green. Do not
   implement certificate parsing or signature verification inside an HTTP
   handler.

Run:

```bash
deno test --config supabase/functions/deno.json --allow-env --allow-read supabase/functions/_shared/app_attest_test.ts
deno test --config supabase/tests/app-attest-hosted-regression.deno.json --allow-read supabase/functions/_shared/app-attest_hosted_regression_test.ts
sh scripts/test-app-attest-edge-runtime.sh
```

Expected: RED before `_shared/app-attest.ts`; GREEN with every fixture and
mutation test passing, the rejected raw graph reproduced safely, the production
graph free of both rejected packages, and the real fixture verified inside the
pinned Edge user worker.

## Task 2: Add private challenge, key, counter, and submission-grant state

**Files:**

- Create: `supabase/migrations/20260811000800_add_app_attest_integrity.sql`
- Create: `supabase/tests/014_app_attest_integrity.test.sql`
- Modify: `supabase/tests/006_score_revision.test.sql`
- Modify: `supabase/tests/013_account_deletion.test.sql`

1. Write pgTAP REDs proving private forced-RLS tables, no client table grants,
   exact RPC grants, and the old unauthenticated-to-App-Attest score RPC is
   revoked.
2. RED-test challenge issuance for active authenticated profile + active owned
   installation, 32-byte randomness, five-minute expiry,
   assertion-vs-attestation selection, bounded outstanding challenges, and
   per-profile/installation rate limits.
3. RED-test service-role-only context loading and proof authorization. Both must
   re-check profile, installation, challenge purpose, expiry, consumption state,
   payload hash, proof kind, key ID, and environment.
4. RED-test globally unique key ownership, same-installation replacement,
   receipt/public-key storage only in `private`, and monotonic unsigned 32-bit
   counters.
5. RED-test a short-lived single-use submission grant tied to profile,
   installation, challenge, payload digest, competition ID, semantic event ID,
   client revision, evaluated timestamp, and wire digest.
6. RED-test that `submit_attested_score_revision` atomically consumes the grant
   and calls the existing idempotent score function, while direct calls to the
   old signature fail for `authenticated`.
7. RED-test concurrent challenge/grant reuse and counter races: exactly one
   succeeds.
8. RED-test account-deletion transition purges all App Attest
   challenge/key/grant material while completed competition history remains
   anonymized.
9. Implement the migration and keep every table/RPC outside anonymous/client
   reach except the narrow authenticated challenge issue and grant-backed score
   wrapper.

Run:

```bash
supabase db reset
supabase test db supabase/tests/014_app_attest_integrity.test.sql
supabase test db
```

Expected: focused pgTAP RED first; then all database suites GREEN.

## Task 3: Add the authenticated challenge endpoint

**Files:**

- Create: `supabase/functions/app-attest-challenge/index.ts`
- Create: `supabase/functions/app-attest-challenge/index_test.ts`
- Modify: `supabase/config.toml`

1. RED-test POST-only, bearer required, in-function `auth.getUser`, exact
   bounded JSON keys, canonical UUID/digest/key-ID validation, and
   privacy-fingerprint rejection.
2. RED-test the exact response contract: version, challenge ID, canonical Base64
   challenge, expiry, and `attestation` or `assertion` kind only.
3. RED-test typed rate-limit, inactive-profile,
   unregistered/revoked-installation, and retryable backend failures without
   returning internal details.
4. Implement the handler using the authenticated challenge RPC. Configure
   `verify_jwt = false` so asymmetric Supabase JWTs are validated inside the
   function.

Run:

```bash
deno test --config supabase/functions/deno.json --allow-env --allow-net --allow-read supabase/functions/app-attest-challenge/index_test.ts
```

## Task 4: Require verified proof in score submission

**Files:**

- Modify: `supabase/functions/submit-score-revision/index.ts`
- Modify: `supabase/functions/submit-score-revision/index_test.ts`
- Modify: `supabase/functions/_shared/scoring_http.ts`
- Modify: `supabase/config.toml`

1. Replace the bare score body with an exact versioned envelope containing the
   existing score object and an App Attest proof object.
2. RED-test bounded body/proof sizes; absent proof; wrong payload hash; wrong
   profile/installation/challenge/key/kind; expired/replayed challenge; invalid
   attestation/assertion; stale/equal counter; and configuration absence.
3. RED-test first registration, assertion renewal, key replacement, concurrent
   replay, lost score response/idempotent resubmission, and fail-closed behavior
   before any score RPC.
4. RED-test that cryptographic verification receives only canonical score JSON
   and non-sensitive binding metadata.
5. Implement: authenticate, load private context with service role, verify proof
   with the shared verifier, exchange it for a one-use grant, then invoke
   `submit_attested_score_revision` with the original user bearer token.
6. Return existing canonical append/duplicate/conflict responses unchanged. Map
   App Attest policy failures to stable 401/409 codes and infrastructure
   failures to retryable 503.
7. Report a typed verifier failure only through an injected code-only seam.
   The live reporter emits a fixed event name plus the closed reason enum;
   reporter failure cannot change the generic client response.

Run:

```bash
deno test --config supabase/functions/deno.json --allow-env --allow-net --allow-read supabase/functions/submit-score-revision/index_test.ts
```

## Task 5: Add the injected iOS client and durable profile-scoped state

**Files:**

- Create: `HealthComp/Services/AppAttestClient.swift`
- Create: `HealthComp/Services/DeviceCheckAppAttestClient.swift`
- Create: `HealthCompTests/AppAttestClientTests.swift`
- Modify: `HealthComp/Services/AuthenticatedProfileStorage.swift`
- Modify: `HealthComp/Services/CompetitionRemoteAPI.swift`
- Modify: `HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`
- Modify: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Modify: `HealthComp/Services/CompetitionSyncModels.swift`
- Modify: `HealthCompTests/SupabaseCompetitionRemoteAPITests.swift`
- Modify: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Modify: `HealthCompTests/CompetitionSyncCoordinatorTests.swift`

1. Write Swift REDs for the byte-identical client-data golden, exact
   challenge/proof wire contracts, unsupported service, invalid key replacement,
   server-unavailable same-key/same-challenge retry, profile isolation, state
   corruption, and successful attestation-to-assertion transition.
2. Define an app-owned `AppAttestServiceProtocol`; place
   `DCAppAttestService.shared` only behind `DeviceCheckAppAttestClient`.
3. Persist only profile-scoped key ID and bounded pending-challenge metadata in
   a private protected file. Never persist a private key or attestation object.
4. Build an actor that serializes proof creation, reuses the same key/challenge
   after Apple's `serverUnavailable`, discards the key for other attestation
   errors, and starts over after `invalidKey`/reinstall/migration.
5. Wrap the mounted profile's score API with its stable installation ID.
   Challenge outages remain retryable; unsupported/malformed proof fails closed
   and is support-visible.
6. Keep deterministic DEBUG Test Lab composition inert and free of challenge
   requests.
7. Recover the historical beta `appAttestRejected` outbox encoding exactly once
   on coordinator startup by moving it to a dedicated durable recovery state.
   Preserve that provenance through bounded transport retry and relaunch, then
   persist any subsequent App Attest availability/proof/context/conflict
   failure as `appAttestRejectedTerminal`, which remains support-inspectable
   and is not a startup-recovery source.

Run focused tests with a unique `/tmp` DerivedData path and macro-validation
skip flags.

## Task 6: Add entitlements and deterministic project configuration

**Files:**

- Modify: `HealthComp/Resources/HealthComp.entitlements`
- Modify: `Configuration/Development.xcconfig`
- Modify: `Configuration/Staging.xcconfig`
- Modify: `Configuration/Production.xcconfig`
- Modify: `project.yml`
- Modify: `HealthComp.xcodeproj/project.pbxproj`

1. RED-test configuration parsing where practical.
2. Add
   `com.apple.developer.devicecheck.appattest-environment = $(APP_ATTEST_ENVIRONMENT)`.
3. Set Development/Staging to `development` and Production to `production`.
4. Regenerate with XcodeGen twice and prove the project hash is identical.
5. Build Debug, Staging, and Release without claiming that compilation proves
   portal capability or physical App Attest service operation.

## Task 7: Integration, review, and handoff

1. Run focused pgTAP, Deno, Swift, and transport tests after each RED-to-GREEN
   slice.
2. Run the full backend matrix, Core Debug/Release, iOS unit/UI suite,
   Release/Staging generic-device builds, XcodeGen determinism,
   `git diff --check`, migration diff, Deno lint/format, secret scan, and
   privacy-sentinel scan.
3. Independently review the complete diff for auth bypass, direct RPC bypass,
   challenge replay, counter races, certificate and CBOR gaps, key
   cross-binding, raw HealthKit leakage, and deletion cleanup.
4. Fix every validated Critical/Important finding with a new failing test first.
5. Commit only the reviewed Task 17 files:

```bash
git commit -m "feat(security): attest competition score submissions"
```

6. Push, open a ready PR, verify its exact head/check state, and merge with a
   head-SHA guard.
7. Record external evidence honestly: automated/simulator fixtures prove logic
   only. A real correctly signed iPhone, configured Apple App ID capability,
   matching Supabase environment values, accepted key registration/assertion,
   and fail-closed score submission remain Task 19 physical gates. The agreed
   hardware boundary is one physical iPhone plus simulators and two Apple
   accounts; key-loss/relaunch/profile-isolation scenarios may be automated or
   simulated but must not be labeled second-physical-device evidence.
