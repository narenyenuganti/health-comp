# Multi-User Supabase Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn HealthComp into a production-capable, two-person iPhone competition for an initial cohort of up to 25 people, using Sign in with Apple and Supabase while keeping raw HealthKit data on-device.

**Architecture:** Preserve the existing deterministic simulated-rival path exclusively for the DEBUG Test Lab. Add a remote-participant domain path whose local journal records owner HealthKit evidence, remote accepted-score revisions, synchronization receipts, and server-confirmed results. Supabase provides authentication, private invitation claims, participant-scoped durable history, append-only score revisions, finalization, anonymized deletion, Realtime wake-ups, and operational diagnostics.

**Tech Stack:** Swift 5.9, SwiftUI, The Composable Architecture, CompetitionCore, HealthKit, AuthenticationServices, DeviceCheck/App Attest, supabase-swift, PostgreSQL/RLS, Supabase Edge Functions, Supabase CLI, Deno tests, pgTAP, XcodeGen, XCTest, XCUITest, and GitHub Actions.

**Review status:** Corrected after a read-only Fable Max adversarial review on 2026-08-11. The corrections were source-verified; no second review was requested.

---

## Execution Rules

- Work only in `feature/multi-user-supabase` until the full verification boundary passes.
- Use strict RED -> GREEN -> refactor cycles. Capture the exact failing assertion or compiler diagnostic before production changes.
- Commit each task independently with the commit shown in that task.
- Do not reconnect or run the historical `Supabase/` migrations against any environment.
- Never upload raw HealthKit samples, workouts, heart rate, routes, locations, or unrelated Health data.
- Never upload `ActivitySnapshotFingerprint`, `ActivityContentFingerprint`, the `activity-snapshot:` or `accepted-activity-score:` encodings, or any base64 value that contains their reversible value/goal bit patterns. Remote records use the wire fingerprint defined in Task 2.
- Realtime is a wake-up hint only. Every wake-up must lead to an authenticated durable refetch.
- Never place a Supabase service-role key, Apple private key, App Attest key, or production access token in the app or repository.
- Simulator tests prove logic only. Sign in with Apple, HealthKit background delivery, App Attest, APNs, and deletion require physical-device gates.

## Baseline

The isolated worktree begins at `25c7cf9` on `feature/multi-user-supabase`.

- `swift test --package-path Modules/CompetitionCore`: 212 tests, 0 failures.
- Generic iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Supabase CLI is not installed at plan-authoring time.
- Docker Desktop is required by the local Supabase stack and must be running before `supabase start`.
- XcodeGen 2.46.0 is installed.

Current Supabase documentation confirms:

- `SupabaseClient` supports custom auth storage and PKCE configuration.
- Sign in with Apple uses `signInWithIdToken(credentials:)` with an OIDC ID token and nonce.
- `authStateChanges` is an `AsyncStream` and stored sessions can be restored/refreshed.
- Realtime callbacks are registered before channel subscription; subscription state is observable.
- RLS uses `auth.uid()` and can call carefully scoped `security definer` helpers.
- The CLI supports local startup, migrations, reset, linking, deployment, and project secrets.

## Milestone 1: Clean Backend Foundation

### Task 1: Archive the Historical Backend and Initialize the Supabase CLI Layout

**Files:**

- Move: `Supabase/` -> `SupabaseLegacy/`
- Create: `supabase/config.toml`
- Create: `supabase/seed.sql`
- Create: `scripts/verify-supabase-layout.sh`
- Modify: `README.md`
- Modify: `.gitignore`

**Step 1: Install and record the CLI**

Run:

```bash
brew install supabase/tap/supabase
supabase --version
```

Expected: a current CLI version prints successfully. Do not authenticate or link a remote project yet.

Confirm Docker Desktop is installed and the daemon is available before the first `supabase start`.

**Step 2: Write the failing layout check**

Create `scripts/verify-supabase-layout.sh` to fail if executable migrations remain under `Supabase/`, if `supabase/config.toml` is absent, or if legacy SQL is referenced by the new config.

Run:

```bash
bash scripts/verify-supabase-layout.sh
```

Expected: FAIL because the legacy directory is still active and the new CLI layout is absent.

**Step 3: Archive and initialize**

Run:

```bash
git mv Supabase SupabaseLegacy
supabase init
```

Keep `SupabaseLegacy/` read-only. Add generated runtime/cache directories to `.gitignore`, but keep `supabase/config.toml`, migrations, functions, tests, and seed data tracked.

Replace the broad `docs/` ignore with ignores for genuinely local/generated documentation only, so `docs/runbooks/` and `docs/release/` are trackable without `git add -f`. Remove the two `Package.resolved` ignore patterns so Task 9 can commit the shared Swift package lock.

**Step 4: Document the boundary**

Update `README.md` so `supabase/` is the live backend source of truth and `SupabaseLegacy/` is historical reference that must never be deployed.

**Step 5: Verify and commit**

Run:

```bash
bash scripts/verify-supabase-layout.sh
if git check-ignore -v docs/runbooks/example.md; then exit 1; fi
if git check-ignore -v HealthComp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved; then exit 1; fi
git diff --check
```

Expected: both pass.

Commit:

```bash
git add .gitignore README.md scripts supabase SupabaseLegacy
git commit -m "chore(backend): initialize production Supabase layout"
```

### Task 2: Create the Production Schema and Privacy Constraints

**Files:**

- Create: `supabase/migrations/20260811000100_create_multi_user_competitions.sql`
- Create: `supabase/tests/001_schema.test.sql`
- Create: `supabase/tests/002_privacy_columns.test.sql`
- Modify: `supabase/seed.sql`

**Step 1: Write failing schema tests**

The pgTAP tests must require these tables:

- `profiles`
- `competitions`
- `competition_participants`
- `competition_invites`
- `daily_score_revisions`
- `participant_finalization_attestations`
- `competition_results`
- `competition_awards`
- `device_installations`
- `support_events`

Use an explicit per-table column allowlist as the primary privacy assertion. Also fail if any live table contains columns named or patterned as `heart_rate`, `workout`, `route`, `location`, `sample`, `raw_health`, `health_metric`, `activity_value`, or `goal_value`.

Run:

```bash
supabase start
supabase db reset
supabase test db
```

Expected: FAIL because the schema does not exist.

**Step 2: Implement identity without coupling history to auth deletion**

Use a surrogate `profiles.id uuid` as the durable participant identity. Store `auth_user_id uuid unique null references auth.users(id) on delete set null`. Other competition tables reference `profiles.id`, never `auth.users.id`.

Required profile fields:

```sql
id uuid primary key default gen_random_uuid(),
auth_user_id uuid unique references auth.users(id) on delete set null,
display_name text not null,
state text not null check (state in ('active', 'deleting', 'anonymized')),
anonymized_at timestamptz,
created_at timestamptz not null default now(),
updated_at timestamptz not null default now()
```

**Step 3: Implement two-person competition constraints**

`competitions` stores creator profile, frozen IANA time-zone identifier, local start day, scoring-policy identity, lifecycle, invitation expiry, best-available deadline, optional rematch parent, a monotonically increasing `next_server_seq bigint`, and timestamps.

`competition_participants` uses `(competition_id, profile_id)` as its key and restricts role to `creator` or `invitee`. Add a deferred constraint trigger that prevents more than two participants and prevents duplicate roles.

**Step 4: Freeze the wire numeric and fingerprint contract**

The first migration must define these units before any score endpoint is implemented:

- ring percentages are signed 32-bit integer basis points, where `10_000` means 100%; accepted input is `0...20_000` per ring so the existing 600-point aggregate cap remains representable;
- points are signed 32-bit integer centi-points, where `10_000` means 100 points and `60_000` is the 600-point daily cap;
- client conversion uses decimal round-half-even from the finite local `Double` into basis points, then server scoring operates only on integers and caps the aggregate at `60_000`;
- synchronized UI and result totals use the server-accepted centi-point values, eliminating client/server tie drift;
- competition totals are bounded by `420_000` centi-points.

Define `wire_content_sha256` as SHA-256 over canonical, length-delimited bytes containing only competition ID, participant profile ID, ordinal, modes, quantized percentages, accepted centi-points, availability, scoring-policy identity, and client revision. Swift and PostgreSQL must use the same field order and UTF-8/integer encoding. The digest never includes local snapshot fingerprints, raw values, raw goals, or an encoded wrapper around them.

**Step 5: Implement append-only evidence and results**

`daily_score_revisions` stores only:

- competition and participant IDs;
- day ordinal 1...7;
- client semantic event ID;
- participant-local monotonically increasing revision;
- Move and Stand modes;
- normalized Move, Exercise, and Stand percentages;
- accepted points in a deterministic fixed-point representation;
- availability reason;
- scoring-policy identity;
- `wire_content_sha256` using the contract above;
- transaction-assigned `server_seq bigint` unique within the competition;
- evaluated-at timestamp;
- received-at timestamp.

Use a unique constraint on `(competition_id, participant_id, semantic_event_id)` and another on `(competition_id, participant_id, day_ordinal, client_revision)`.

`competition_results` is insert-only and unique by competition. It stores both participant totals, outcome keyed by winner profile rather than owner/opponent perspective, finalization basis, completed-at, and an immutable seven-day JSON projection whose shape is validated by a constraint function.

The durable fetch cursor is `(competition_id, last_seen_server_seq)`. Every score revision, attestation, result, award, participant-state change, and deletion/anonymization projection change must receive a sequence from the same per-competition counter inside its transaction. Timestamps are never cursors.

**Step 6: Verify and commit**

Run:

```bash
supabase db reset
supabase test db
```

Expected: all schema and privacy tests pass.

Commit:

```bash
git add supabase/migrations supabase/tests supabase/seed.sql
git commit -m "feat(backend): add private competition schema"
```

### Task 3: Add Participant-Only RLS and an Adversarial Policy Matrix

**Files:**

- Create: `supabase/migrations/20260811000200_add_competition_rls.sql`
- Create: `supabase/tests/003_rls.test.sql`
- Create: `supabase/tests/004_rls_adversarial.test.sql`

**Step 1: Write the failing matrix**

Seed Alice, Bob, and Mallory auth/profile identities. Test every live table as:

- anonymous user;
- authenticated participant;
- authenticated nonparticipant;
- deleted/anonymized former participant.

Require that Mallory cannot enumerate competitions, profiles, score revisions, results, awards, invitations, installations, or support events belonging to Alice and Bob.

Expected RED: current tables have no policies.

**Step 2: Add helper functions with locked search paths**

Create `private.current_profile_id()` and `private.is_competition_participant(uuid)` as `security definer` functions owned by the migration role. Set `search_path = ''`, schema-qualify every object, and revoke execute from `public` unless an RLS policy explicitly needs it.

**Step 3: Add least-privilege policies**

- Profiles: self plus counterparts in pending, active, completed, or archived shared competitions; an anonymized counterpart exposes only the literal `Former competitor` presentation and stable non-auth history identity. Never permit global discovery.
- Competitions, participants, score revisions, results, and awards: current or historical participants only, with deleted identities detached from auth.
- Invites: no direct token lookup by clients.
- Device installations: owning active profile only.
- Support events: no client reads or writes.
- Score revisions and results: no direct client insert/update/delete.

**Step 4: Verify and commit**

Run `supabase db reset && supabase test db` and require the adversarial matrix to pass.

Commit:

```bash
git add supabase/migrations supabase/tests
git commit -m "feat(backend): enforce participant-only access"
```

### Task 4: Implement Private Invitation Creation and Atomic Claim

**Files:**

- Create: `supabase/migrations/20260811000300_add_invitation_functions.sql`
- Create: `supabase/functions/create-competition-invite/index.ts`
- Create: `supabase/functions/create-competition-invite/index_test.ts`
- Create: `supabase/functions/claim-competition-invite/index.ts`
- Create: `supabase/functions/claim-competition-invite/index_test.ts`
- Create: `supabase/tests/005_invitation_functions.test.sql`

**Step 1: Write failing invitation tests**

Cover:

- authenticated creator receives one opaque token and competition ID;
- database stores only the token SHA-256 digest;
- unauthenticated creation and claim fail;
- self-claim fails;
- expired, consumed, malformed, and unknown tokens fail without leaking participant data;
- two simultaneous claims produce exactly one invitee;
- successful claim freezes the creator's time zone and next local calendar day;
- reusing the token is idempotently rejected;
- a rematch produces a new competition and token linked to the completed source.
- expired unclaimed invitations are idempotently closed and their empty pending competition is removed or marked expired by an explicit cleanup RPC/scheduled sweep.

**Step 2: Put the transaction in PostgreSQL**

Edge Functions authenticate the caller, validate the request envelope, generate or hash the random token, and call narrowly granted RPCs. The SQL functions perform all membership, expiry, schedule, and state changes in one transaction. The cleanup transaction uses the same state machine and sequence allocation as user-driven claim/expiry paths.

The raw token is returned exactly once and is never logged.

**Step 3: Verify locally**

Run:

```bash
supabase functions serve --env-file supabase/.env.local > /tmp/healthcomp-supabase-functions.log 2>&1 &
FUNCTIONS_PID=$!
trap 'kill "$FUNCTIONS_PID" 2>/dev/null || true' EXIT
deno test --allow-env --allow-net supabase/functions/create-competition-invite
deno test --allow-env --allow-net supabase/functions/claim-competition-invite
supabase test db
kill "$FUNCTIONS_PID"
trap - EXIT
```

Tests use real local JWTs. Do not disable JWT verification.

Expected: all invitation race, privacy, and schedule cases pass.

**Step 4: Commit**

```bash
git add supabase/functions supabase/migrations supabase/tests
git commit -m "feat(invites): add private single-use competition links"
```

### Task 5: Implement Idempotent Score Submission and Server Finalization

**Files:**

- Create: `supabase/migrations/20260811000400_add_score_and_finalization_functions.sql`
- Create: `supabase/functions/submit-score-revision/index.ts`
- Create: `supabase/functions/submit-score-revision/index_test.ts`
- Create: `supabase/functions/finalize-competitions/index.ts`
- Create: `supabase/functions/finalize-competitions/index_test.ts`
- Create: `supabase/tests/006_score_revision.test.sql`
- Create: `supabase/tests/007_finalization.test.sql`
- Create: `supabase/tests/fixtures/scoring-v1.json`
- Create: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteScoringGoldenTests.swift`

**Step 1: Write cross-language RED tests**

Create one shared fixture covering Move, Move Time, Exercise, Stand, Roll, zero values, unavailable evidence, daily cap, fractional values, round-half-even boundaries, the 200% per-ring wire cap, and invalid bounds. Swift and PostgreSQL must produce byte-equivalent basis-point inputs, centi-point scores, and `wire_content_sha256` digests.

Add mutation-sensitive privacy cases proving the same allowed wire fields produce the same digest, changed allowed fields change it, and no local `ActivitySnapshotFingerprint`/`ActivityContentFingerprint` value or reversible wrapper is accepted as input.

Expected RED: no server scorer or wire fixture exists.

**Step 2: Add atomic score append**

The authenticated Edge Function must ignore client-supplied participant identity and derive it from the JWT. The SQL RPC must:

- verify membership and accepted lifecycle;
- verify day ordinal against the frozen schedule;
- recompute points with the versioned server scorer;
- reject nonfinite, negative, out-of-bounds, wrong-policy, or post-finalization input;
- accept exact semantic duplicates as no-ops;
- reject divergent duplicates;
- reject revision regression;
- append, never update, accepted rows.

Return `appended`, `duplicate`, or a typed rejection with the accepted server cursor.

**Step 3: Add final-window attestations**

Each phone may attest its own seven-day window as `stable` or `best_available`. Store an owner-only window commitment over that participant's seven ordered `points | unavailable(reason)` rows and accepted revision set. A participant cannot attest the other participant's data. Do not reuse `CompleteWindowContent`, which requires a complete owner/opponent pair.

**Step 4: Add server result creation**

The finalizer must create one immutable result when both stable attestations exist, or when the frozen best-available deadline passes. Each participant/day row is exactly `points(centiPoints)` or `unavailable(reason)`. History and UI preserve unavailable rows as unavailable; totals are defined as the sum of accepted point rows only, so unavailable rows contribute no points without being misrepresented as observed zero activity. Winner/tie comparison uses those defined totals. Concurrent finalizers must converge on one result.

The server result carries both participant ledgers and their commitments. On receipt, a phone must exactly validate every owner-side row against its own durable accepted journal. Remote rows are server-authoritative; any remote revisions already cached locally must match, but remote completeness is never required for acceptance. A mismatch rejects the result and creates an inspectable synchronization failure.

Schedule the production finalizer separately from request handling; foreground score submission may opportunistically invoke the same idempotent transaction.

**Step 5: Verify and commit**

Run all Deno, pgTAP, and `RemoteScoringGoldenTests`. Stress the duplicate and finalizer races at least 100 times locally.

Commit:

```bash
git add supabase Modules/CompetitionCore
git commit -m "feat(scoring): validate revisions and confirm shared results"
```

## Milestone 2: Remote Competition Domain

### Task 6: Generalize the App Dependency Without Changing Local Behavior

**Files:**

- Create: `HealthComp/Features/Competition/CompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/LocalCompetitionClient.swift`
- Modify: `HealthComp/Features/Competition/CompetitionFeature.swift`
- Modify: `HealthComp/Features/Competition/CompetitionTestLabView.swift`
- Modify: `HealthCompTests/CompetitionFeatureTests.swift`
- Modify: `HealthCompTests/CompetitionTestLabTests.swift`
- Modify: `project.yml`
- Regenerate: `HealthComp.xcodeproj/project.pbxproj`

**Step 1: Write compile-time RED tests**

Change new tests to inject `CompetitionClient` and prove the DEBUG lab adapts `LocalCompetitionClient` without creating a live backend client.

Expected RED: `CompetitionClient` does not exist.

**Step 2: Add the generic client contract**

This task is a pure rename/generalization. Preserve the complete existing endpoint surface and behavior exactly: `start`, `updates`, `reconcileAll`, `accept`, `decline`, `archive`, `rematch`, `reinvite`, `delete`, `reconcileNotifications`, `loadMutedOpponentIdentities`, `setNotificationMuted`, `loadNotificationAuthorizationState`, `requestNotificationAuthorization`, `waitUntil`, and `stop`.

Do not add `createInvite`, `claimInvite`, a command enum, remote transport, or new error behavior here. Those APIs arrive with executable remote tests in Tasks 13 and 14. This keeps the Test Lab and existing reducers source-compatible during the rename.

Use compatibility type aliases for presentation types during this task; do not mix behavioral changes with the rename.

**Step 3: Preserve the Test Lab boundary**

`CompetitionTestLabRootView` must explicitly inject `CompetitionClient.localFixture(...)`. Add a test that a poisoned live backend dependency receives zero calls under every Test Lab launch mode.

**Step 4: Verify and commit**

Run the current full iOS unit suite and the focused Test Lab UI launch test. Do not pin this gate to a historical test count.

Commit:

```bash
git add HealthComp HealthCompTests project.yml HealthComp.xcodeproj
git commit -m "refactor(competition): introduce source-agnostic client"
```

### Task 7: Add Remote Counterparty and Score-Ledger Types to CompetitionCore

**Files:**

- Create: `Modules/CompetitionCore/Sources/CompetitionCore/RemoteParticipant.swift`
- Create: `Modules/CompetitionCore/Sources/CompetitionCore/RemoteScoreLedger.swift`
- Create: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteScoreLedgerTests.swift`

**Step 1: Write failing remote-ledger tests**

Cover stable participant identity, immutable accepted schedule, ordinals 1...7, monotonic remote revisions, exact duplicate no-op, divergent duplicate rejection, unavailable evidence, fixed-point bounds, active-day visibility, and frozen-window identity.

Expected RED: the domain supports only `OpponentPlan`.

**Step 2: Introduce v4-ready remote types without widening persisted lifecycle types**

Add:

```swift
public enum CompetitionCounterparty: Codable, Equatable, Sendable {
    case simulated(OpponentPlan)
    case remote(RemoteParticipant)
}
```

The remote participant contains only a stable profile ID; mutable display names stay outside immutable Core state. Do not add this enum to `AcceptedCompetitionConfiguration`, `CompetitionEvent`, `CompetitionDomainEvent`, or another type reused by payload v1-v3. Task 8 introduces it through a new v4-only configuration event after freezing the v3 decoder.

**Step 3: Implement the remote ledger**

The remote ledger accepts only server-accepted wire records and derives an ordered window commitment over ordinal, points, availability, `wire_content_sha256`, scoring-policy identity, and server revision. It never contains raw HealthKit evidence or any local activity fingerprint.

**Step 4: Verify compatibility**

Run all current Core tests plus the new remote suite. Existing lifecycle, engine, journal, and simulated golden bytes must be untouched at this stage.

**Step 5: Commit**

```bash
git add Modules/CompetitionCore
git commit -m "feat(core): model remote competition score ledgers"
```

### Task 8: Persist Remote Revisions and Server-Confirmed Results in Journal Payload v4

**Files:**

- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEvent.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEventStore.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/FinalizationPolicy.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionSemanticTerminalProjection.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionLifecycle.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEngine.swift`
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/CompetitionReplayTests.swift`
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/TallyReconciliationTests.swift`
- Create: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteCompetitionReplayTests.swift`
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/CompetitionTraceTests.swift`
- Modify: `HealthCompTests/Fixtures/late-watch-sync.json`
- Modify: `HealthCompTests/Fixtures/win.json`
- Modify: `HealthCompTests/Fixtures/loss.json`
- Modify: `HealthCompTests/Fixtures/tie.json`

**Step 1: Capture payload-v4 RED**

Tests must fail on missing remote score and result events. Add sensitivity cases proving that changed participant ID, ordinal, accepted points, availability, server cursor, or result window changes semantic identity.

**Step 2: Add new events**

Add events equivalent to:

```swift
case remoteConfigurationAccepted(RemoteCompetitionConfiguration)
case remoteScoreRevisionRecorded(RemoteScoreRevision)
case remoteFinalWindowAttested(RemoteFinalWindowAttestation)
case sharedResultConfirmed(SharedCompetitionResult)
case synchronizationReceiptRecorded(SynchronizationReceipt)
```

`RemoteCompetitionConfiguration` binds the server competition UUID (which must equal `CompetitionID`), local owner profile ID, remote participant profile ID, frozen schedule, scoring-policy identity, and backend descriptor revision. This event is the only source of remote owner/counterparty perspective after replay.

The server-confirmed result follows Task 5's validation rule: validate all owner rows exactly, validate cached remote rows when present, and accept missing remote rows as server-authoritative. Perspective-specific win/loss is derived from the persisted local owner profile ID; the canonical server result stores a winner profile ID or tie.

**Step 3: Upgrade the journal envelope**

Before changing any live union, snapshot a frozen `CompetitionDomainEventV3` decoder and any persisted lifecycle leaf types it needs. Payload v1-v3 must reject every remote case. Gate every new remote discriminator behind `payloadVersion >= 4`, then make payload v4 current. Never reinterpret a simulated `OpponentPlan` as a remote participant. Add poisoned-payload tests for every new discriminator and relationship.

For remote configurations, local `competitionFinalized` is invalid. A remote journal reaches completed state only through `sharedResultConfirmed`; local `FinalizationPolicy` remains the simulated-rival path. Remote UI displays the server descriptor's frozen best-available deadline.

**Step 4: Update semantic projections**

The terminal projection must include counterparty kind and either the simulated plan commitment or remote window commitment. Regenerate the four existing simulated golden fixtures only for the envelope payload-version field, keeping semantic IDs and terminal content byte-identical; replace hardcoded `payloadVersion == 3` assertions with the v4 expectation. Add four separate remote fixtures rather than converting the simulated fixtures.

**Step 5: Verify and commit**

Run the full Core suite in Debug and Release.

Commit:

```bash
git add Modules/CompetitionCore
git commit -m "feat(core): persist remote competition evidence"
```

## Milestone 3: iOS Authentication and Transport

### Task 9: Add Reproducible Supabase Swift Configuration

**Files:**

- Modify: `project.yml`
- Modify: `.gitignore`
- Create: `Configuration/Base.xcconfig`
- Create: `Configuration/Development.xcconfig`
- Create: `Configuration/Staging.xcconfig`
- Create: `Configuration/Production.xcconfig`
- Create: `HealthComp/Services/SupabaseConfiguration.swift`
- Create: `HealthCompTests/SupabaseConfigurationTests.swift`
- Regenerate: `HealthComp.xcodeproj/project.pbxproj`
- Track: `HealthComp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Step 1: Write fail-closed configuration tests**

Require typed errors for missing URL, non-HTTPS URL, missing publishable key, placeholder values, and service-role-shaped keys. Verify that DEBUG Test Lab creates no Supabase client.

**Step 2: Add the official Swift package**

Add `https://github.com/supabase/supabase-swift` and the `Supabase` product through XcodeGen. Commit the resolved package lock for reproducible production builds.

**Step 3: Add environment injection**

Expose only `SUPABASE_URL` and `SUPABASE_PUBLISHABLE_KEY` through build-setting substitutions. Keep local override files ignored. Do not call the project `anon key` if the dashboard supplies the newer publishable-key format.

**Step 4: Verify and commit**

Run XcodeGen twice and require identical project and package resolution. Run Debug and Release builds with fixture configuration and ensure secret-pattern scanning reports zero service-role/private keys.

Commit:

```bash
git add .gitignore Configuration HealthComp HealthCompTests project.yml HealthComp.xcodeproj
git commit -m "build(supabase): add reproducible Swift client configuration"
```

### Task 10: Implement Sign in with Apple and Auth Session State

**Files:**

- Create: `HealthComp/Services/AuthenticationClient.swift`
- Create: `HealthComp/Services/SupabaseAuthenticationClient.swift`
- Create: `HealthComp/Features/Account/AccountFeature.swift`
- Create: `HealthComp/Features/Account/AccountView.swift`
- Create: `HealthCompTests/AuthenticationClientTests.swift`
- Create: `HealthCompTests/AccountFeatureTests.swift`
- Modify: `HealthComp/App/AppFeature.swift`
- Modify: `HealthComp/App/HealthCompApp.swift`
- Modify: `HealthComp/Resources/HealthComp.entitlements`
- Modify: `project.yml`

**Step 1: Write reducer and nonce RED tests**

Cover cold session restoration, signed-out root, Sign in with Apple success, cancellation, invalid credential, nonce mismatch, expired session, token refresh, sign-out, deleted account, and auth-stream cancellation.

**Step 2: Implement the authentication adapter**

Use `AuthenticationServices` to generate a cryptographically random raw nonce and SHA-256 challenge. Send the Apple identity token and raw nonce through Supabase `signInWithIdToken(credentials:)`. Never log credentials, token bytes, email, or Apple authorization payloads.

**Step 3: Gate the app root**

`AppFeature.State` becomes an explicit launch/auth/main state machine. Construct the live competition dependency only after a valid session and profile bootstrap. The DEBUG Test Lab remains outside this graph.

**Step 4: Restore the entitlement**

Add `com.apple.developer.applesignin` with `Default` while retaining HealthKit and background-delivery entitlements.

Configure the Supabase Apple provider separately for development, staging, and production using the exact App ID/bundle-ID client identifier. Enable Sign in with Apple on the Apple App ID and regenerate provisioning profiles before physical-device tests. Record these dashboard/portal steps in Task 18's environment runbook; never commit the Apple `.p8` key or generated client-secret JWT.

**Step 5: Scope local state to the authenticated profile**

After profile bootstrap, construct every remote journal, outbox, server cursor, mute preference, and installation cache under an Application Support path namespaced by the stable profile UUID. Sign-out closes all streams, stops drains, removes the current profile's local remote cache, and constructs no competition client until the next authenticated profile is known. Account deletion performs the same local wipe after durable server acknowledgement.

**Step 6: Verify and commit**

Run focused TestStore tests, including sequential sign-in as two different profiles on one device; prove profile B cannot load, display, or drain profile A's journal/outbox. Then run the full iOS unit suite and a generic Release build.

Commit:

```bash
git add HealthComp HealthCompTests project.yml HealthComp.xcodeproj
git commit -m "feat(auth): add Sign in with Apple sessions"
```

### Task 11: Add Typed Supabase API and Privacy-Safe Wire DTOs

**Files:**

- Create: `HealthComp/Services/CompetitionSyncModels.swift`
- Create: `HealthComp/Services/CompetitionRemoteAPI.swift`
- Create: `HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`
- Create: `HealthCompTests/CompetitionSyncModelsTests.swift`
- Create: `HealthCompTests/SupabaseCompetitionRemoteAPITests.swift`

**Step 1: Write contract RED tests**

Test exact JSON for profile, competition descriptor, invite, claim, revision append, attestation, result, award, installation, and `(competitionID, lastSeenServerSeq)` synchronization cursor. Add an explicit recursive key/value allowlist. Reject local fingerprint prefixes `activity-snapshot:`, `accepted-activity-score:`, and `live-day-score:` directly and after base64 decoding. Reject raw value/goal fields and opaque blobs not defined by the wire contract.

**Step 2: Define transport independently of SDK types**

Application and Core code must depend on `CompetitionRemoteAPI`, not `SupabaseClient`. The live adapter alone imports Supabase.

The API exposes authenticated operations for:

- profile bootstrap and update;
- list/fetch competitions;
- create and claim invite;
- append score revision;
- submit final-window attestation;
- fetch changes after a per-competition `server_seq` cursor;
- register notification installation;
- request account deletion.

**Step 3: Map typed server errors**

Map HTTP/PostgREST errors into stable app failures: unauthenticated, forbidden, invite invalid/expired/consumed, divergent duplicate, stale revision, finalized competition, retryable transport, incompatible policy, and server contract mismatch.

**Step 4: Verify and commit**

Use an injected `URLProtocol` or Supabase transport seam so tests require no live network.

Commit:

```bash
git add HealthComp/Services HealthCompTests
git commit -m "feat(sync): add privacy-safe competition API"
```

### Task 12: Add a Durable, Idempotent Outbox

**Files:**

- Create: `HealthComp/Services/CompetitionOutboxStore.swift`
- Create: `HealthComp/Services/JSONCompetitionOutboxStore.swift`
- Create: `HealthComp/Services/CompetitionSyncCoordinator.swift`
- Create: `HealthCompTests/JSONCompetitionOutboxStoreTests.swift`
- Create: `HealthCompTests/CompetitionSyncCoordinatorTests.swift`

**Step 1: Write durability and race RED tests**

Cover atomic append, relaunch, exact duplicate, divergent semantic duplicate, in-flight crash, ack after durable server response, exponential backoff, offline suspension, auth change, cursor conflict, concurrent drains, corrupt primary recovery, file protection, deletion, and two sequential accounts using the same device.

**Step 2: Implement append-before-send**

An owner score revision is first persisted to the Core journal and outbox in an ordered local operation. Network transmission can begin only afterward. Acknowledgement is removed only after a durable server acceptance or exact duplicate response.

**Step 3: Implement one serialized drain**

The coordinator owns one drain task per authenticated profile, coalesces wake-ups, observes connectivity opportunistically, and retries only typed retryable failures. Permanent failures remain inspectable and do not spin. An auth/profile change terminates the old drain before opening the new profile namespace; an item can never be submitted under a different profile's JWT.

**Step 4: Verify and commit**

Run the focused tests under concurrency stress and relaunch fixtures.

Commit:

```bash
git add HealthComp/Services HealthCompTests
git commit -m "feat(sync): persist and drain competition outbox"
```

## Milestone 4: Production Competition Experience

### Task 13: Build the Remote Competition Coordinator

**Files:**

- Create: `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- Create: `HealthComp/Services/RemoteCompetitionRuntime.swift`
- Create: `HealthCompTests/RemoteCompetitionClientTests.swift`
- Create: `HealthCompTests/RemoteCompetitionRuntimeTests.swift`
- Modify: `HealthComp/Features/Competition/CompetitionClient.swift`
- Modify: `HealthComp/App/HealthCompApp.swift`

**Step 1: Write canonical-stream RED tests**

Cover bootstrap with zero competitions, incoming/outgoing pending invitations, scheduled start, owner HealthKit refresh, remote revision arrival, Day 1...7, tallying, stable and incomplete best-available result, rematch, archive, relaunch, offline cache, partial enumeration failure, profile switch, and terminal stop.

**Step 2: Compose local and remote authority**

The runtime combines:

- local Core journal and HealthKit environment;
- durable outbox;
- authenticated remote API;
- server cursor and Realtime wake-ups;
- notification coordinator;
- one monotonic publication hub.

Commands return expected publication revisions but never apply command-returned state directly; the canonical stream remains the sole publisher.

Extend the generic client here with `createInvite`, returning the share token/link plus competition ID, and `claimInvite`, returning the claimed competition descriptor/ID. Do not return `Void`; routing needs the durable claimed ID. Keep local fixtures explicit no-op/fail-closed implementations.

Remote completion occurs only after `sharedResultConfirmed`; the coordinator must never invoke local `FinalizationPolicy` for a remote configuration.

**Step 3: Switch only the production root**

`CompetitionClient.liveValue` becomes remote. `CompetitionClient.localFixture` remains the explicit Test Lab source. Remove the production bootstrap of simulated Alex without deleting simulation code or tests.

**Step 4: Verify and commit**

Run remote integration tests with two independent clients sharing a fake server and separate local stores. Require convergence after offline and duplicate sequences.

Commit:

```bash
git add HealthComp HealthCompTests
git commit -m "feat(competition): synchronize real participants"
```

### Task 14: Add Invite-Link, Account, and Historical UI

**Files:**

- Create: `HealthComp/Features/Competition/CreateCompetitionView.swift`
- Create: `HealthComp/Features/Competition/ClaimCompetitionView.swift`
- Create: `HealthComp/Features/Account/AccountSettingsView.swift`
- Modify: `HealthComp/Features/Competition/CompetitionFeature.swift`
- Modify: `HealthComp/Features/Competition/CompetitionSharingView.swift`
- Modify: `HealthComp/Features/Competition/CompetitionInviteView.swift`
- Modify: `HealthComp/Features/Competition/CompetitionDetailView.swift`
- Modify: `HealthComp/Features/Competition/CompetitionResultView.swift`
- Modify: `HealthComp/Features/MainTab/MainTabFeature.swift`
- Modify: `HealthComp/Features/MainTab/MainTabView.swift`
- Modify: `HealthComp/Services/CompetitionRouting.swift`
- Modify: `HealthComp/Services/CompetitionNotificationClient.swift`
- Modify: `HealthComp/Resources/HealthComp.entitlements`
- Modify: `project.yml`
- Create: `supabase/functions/apple-app-site-association/index.ts`
- Create: `supabase/functions/apple-app-site-association/index_test.ts`
- Create: `HealthCompTests/RemoteCompetitionFeatureTests.swift`
- Create: `HealthCompUITests/MultiUserCompetitionUITests.swift`

**Step 1: Write user-flow RED tests**

Cover create/share, cold-link claim, warm-link claim, sign-in-before-claim, expired/consumed link, incoming accept/decline confirmation, creator time-zone disclosure, scheduled concrete dates, remote score updates, history, anonymized former competitor, rematch, archive, and offline/error recovery.

**Step 2: Replace simulated copy in production**

Production must never label a real opponent as simulated. Remove production use of `LocalCompetitionIdentity.ownerDisplayName` (`Naren`) and `opponentDisplayName` (`Alex`); Test Lab retains those fixture names and its simulation disclosure. Display-name changes affect presentation only, never immutable participant or score identity.

**Step 3: Handle links safely**

Choose and provision one HTTPS invitation domain per environment. Host a cache-correct `/.well-known/apple-app-site-association` response, add `com.apple.developer.associated-domains` entries through `project.yml` and entitlements, and verify the signed-app/domain association on a physical device.

Use the universal HTTPS link as the shareable production form and keep the custom `healthcomp://` scheme for controlled fallback/testing. Parse strictly, park cold routes until auth and the first canonical publication, and consume every accepted or rejected token exactly once. Replace the route hub's single pending slot with per-kind pending slots so a claim token cannot be overwritten by a notification route. Raw claim tokens never enter logs, analytics, notification payloads, accessibility labels, or support events.

**Step 4: Verify accessibility and privacy**

Run light/dark and small/accessibility-size UI matrices. VoiceOver must distinguish the local participant, opponent, provisional current-day values, frozen days, unavailable evidence, and final results without reading tokens or internal IDs.

**Step 5: Commit**

```bash
git add HealthComp HealthCompTests HealthCompUITests project.yml HealthComp.xcodeproj
git commit -m "feat(ui): add real-user invitations and history"
```

### Task 15: Reconcile Realtime, Push Notifications, and Mutes

**Files:**

- Create: `HealthComp/Services/CompetitionRealtimeClient.swift`
- Create: `HealthComp/Services/SupabaseCompetitionRealtimeClient.swift`
- Modify: `HealthComp/Services/CompetitionNotificationCoordinator.swift`
- Modify: `HealthComp/Services/CompetitionNotificationModels.swift`
- Modify: `HealthComp/Services/CompetitionNotificationPreferences.swift`
- Modify: `HealthComp/App/HealthCompAppDelegate.swift`
- Modify: `HealthComp/Resources/HealthComp.entitlements`
- Modify: `project.yml`
- Create: `supabase/functions/send-competition-notification/index.ts`
- Create: `supabase/functions/send-competition-notification/index_test.ts`
- Create: `HealthCompTests/CompetitionRealtimeClientTests.swift`
- Modify: `HealthCompTests/CompetitionNotificationCoordinatorTests.swift`

**Step 1: Write wake-up and dedupe RED tests**

Prove that dropped, duplicated, reordered, and reconnected Realtime messages still converge through durable refetch. Prove that a notification decision has a stable semantic ID and never claims OS delivery.

**Step 2: Add one authenticated private channel per account**

Register callbacks before subscription. Treat every event as `reconcileAfter(serverCursorHint:)`; never deserialize it directly into competition state.

**Step 3: Move opponent mutes to the account**

Persist mutes by stable remote profile ID so they survive relaunch, rematch, and display-name change. Preference read failure remains privacy-safe and emits no notification.

**Step 4: Add APNs server coordination**

Enable Push Notifications for each App ID and signed configuration, add the appropriate `aps-environment` entitlement through project generation/signing, call `registerForRemoteNotifications`, and handle `didRegisterForRemoteNotificationsWithDeviceToken` plus failure in `HealthCompAppDelegate`. Persist the token through the authenticated installation API and remove it on sign-out/deletion.

Store installation tokens per profile/device. Edge Functions use generic privacy-safe content, record emission decisions before posting, and remove obsolete pending requests. Keep the APNs `.p8`, key ID, and team ID in environment-scoped Supabase secrets.

Define the send trigger explicitly: score/result transactions append durable notification work; an authenticated worker/Edge Function drains it, with a scheduled sweep repairing missed invocations. Never rely on Realtime for delivery. Generalize the current notification coordinator's `LocalCompetitionRuntime?` decision-commit dependency to a runtime-neutral durable decision-commit seam implemented by both local and remote runtimes.

**Step 5: Verify and commit**

Run deterministic planner/coordinator tests, Realtime reconnection stress, and physical-device notification gates later in Task 19.

Commit:

```bash
git add HealthComp HealthCompTests supabase
git commit -m "feat(notifications): coordinate remote competition updates"
```

### Task 16: Implement Account Deletion and Anonymized Shared History

**Files:**

- Create: `supabase/migrations/20260811000500_add_account_deletion.sql`
- Create: `supabase/functions/delete-account/index.ts`
- Create: `supabase/functions/delete-account/index_test.ts`
- Create: `supabase/tests/008_account_deletion.test.sql`
- Modify: `HealthComp/Features/Account/AccountFeature.swift`
- Modify: `HealthComp/Features/Account/AccountSettingsView.swift`
- Create: `HealthCompTests/AccountDeletionTests.swift`
- Modify: `HealthCompUITests/MultiUserCompetitionUITests.swift`

**Step 1: Write deletion RED tests**

Cover cancellation, reauthentication requirement, active-competition cleanup, pending invite removal, APNs cleanup, Apple token revocation, Supabase auth deletion, idempotent retry, crash between phases, opponent history preservation, `Former competitor` presentation, and inability to reverse-map the anonymized profile.

**Step 2: Implement a durable deletion state machine**

The authenticated function first marks the profile `deleting`, cancels unfinished relationships and installations, anonymizes completed shared records, writes an audit-safe support event, revokes the Apple authorization at Apple's token-revocation endpoint, and only then deletes the Supabase auth user with server credentials. The Apple client-secret JWT is signed server-side with a `.p8` stored only in Supabase secrets. Retrying resumes from the recorded phase and treats already-revoked credentials as success.

**Step 3: Verify and commit**

Run pgTAP, Deno, reducer, integration, and relaunch tests.

Commit:

```bash
git add supabase HealthComp HealthCompTests HealthCompUITests
git commit -m "feat(account): anonymize history during deletion"
```

### Task 17: Add App Attest as a Beta Integrity Layer

**Files:**

- Create: `HealthComp/Services/AppAttestClient.swift`
- Create: `HealthComp/Services/DeviceCheckAppAttestClient.swift`
- Create: `HealthCompTests/AppAttestClientTests.swift`
- Create: `supabase/functions/app-attest-challenge/index.ts`
- Create: `supabase/functions/app-attest-challenge/index_test.ts`
- Create: `supabase/functions/_shared/app-attest.ts`
- Modify: `supabase/functions/submit-score-revision/index.ts`
- Modify: `HealthComp/Resources/HealthComp.entitlements`

**Step 1: Write challenge and failure RED tests**

Cover first registration, assertion renewal, nonce replay, wrong bundle/team/environment, unsupported simulator, key replacement, rate limiting, server outage, and fail-closed score submission in production.

**Step 2: Add an injected client**

Use `DCAppAttestService` behind an app-owned protocol. DEBUG fixtures inject an inert attestation client and must never contact production challenge endpoints.

**Step 3: Verify assertions server-side**

Bind assertions to the authenticated profile, installation, request payload hash, one-time challenge, and monotonic counter. Never treat App Attest as proof that HealthKit data itself is untampered.

Before implementation, choose and pin a vetted Deno-compatible App Attest verifier or document the exact in-house CBOR, certificate-chain, nonce, public-key, and assertion-counter validation algorithm against current Apple documentation. Do not improvise certificate validation inside the request handler.

**Step 4: Verify and commit**

Run unit and server fixtures, then reserve real App Attest verification for a physical production-signed build.

Commit:

```bash
git add HealthComp HealthCompTests supabase
git commit -m "feat(security): attest competition score submissions"
```

## Milestone 5: Delivery and Production Readiness

### Task 18: Add Separate Environments, CI, and Operational Runbooks

**Files:**

- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/backend.yml`
- Create: `docs/runbooks/supabase-environments.md`
- Create: `docs/runbooks/competition-support.md`
- Create: `docs/runbooks/account-deletion.md`
- Create: `docs/runbooks/backup-restore.md`
- Create: `scripts/verify-no-secrets.sh`
- Modify: `README.md`

**Step 1: Add failing CI/static gates locally**

Require:

- no service-role/private key patterns;
- no production URL/key in DEBUG fixture artifacts;
- legacy migrations excluded;
- migrations reset and pgTAP pass;
- Edge Function tests pass;
- Core Debug and Release tests pass;
- iOS unit tests pass;
- generic Debug and Release builds pass;
- XcodeGen regeneration is deterministic;
- `git diff --check` is clean.

**Step 2: Define environment promotion**

Create distinct development, staging, and production projects. Link and deploy one environment at a time. Require migration-list readback before and after deployment. Store project tokens and function secrets only in environment-scoped secret stores.

For every environment, document and verify: Supabase Apple provider client ID/secret rotation; Apple App ID capabilities for Sign in with Apple, Push Notifications, Associated Domains, HealthKit, and App Attest; regenerated provisioning profiles; universal-link domain/AASA; APNs `.p8` provisioning; finalizer and notification sweep schedules; and the production signing environment.

**Step 3: Add support operations**

Document read-only diagnosis and audited RPCs for invitation resend, reconciliation, unfinished cancellation, and deletion retry. Do not document direct final-score editing.

For the 25-person beta, the support surface is an authenticated read-only/operator runbook and audited RPC tooling rather than a custom web console. A graphical support console is explicitly deferred unless beta operations prove it necessary.

**Step 4: Rehearse backup and rollback**

Restore a staging backup, verify historical competition counts and immutable result hashes, and rehearse migration rollback or forward repair before production launch.

**Step 5: Commit**

```bash
git add .github docs README.md scripts
git commit -m "ci: verify multi-user backend and iOS release"
```

### Task 19: Execute the Production Verification Matrix

**Approved execution amendment (2026-08-17):** The private-beta completion
topology is one physical iPhone, one or more iOS Simulators, and two distinct
Apple accounts. A second physical iPhone is not required. Invitation,
convergence, account-switching, and participant-isolation evidence may use one
physical iPhone plus a Simulator as the two isolated endpoints. Physical-only
Sign in with Apple, HealthKit, background-delivery, APNs, App Attest, and
deletion evidence must still run on the physical iPhone. Device replacement is
verified as a same-phone replacement-installation lifecycle: retire the old
installation, remove and reinstall the exact build, enroll a new installation
and App Attest key, and prove the retired installation remains unusable.
Universal links are explicitly deferred because no HTTPS invitation domain
will be provided; the controlled custom-scheme fallback remains in scope and
must not be represented as universal-link evidence.

**Files:**

- Create: `docs/release/production-beta-checklist.md`
- Create: `docs/release/production-beta-evidence.md`
- Modify: `HealthCompUITests/MultiUserCompetitionUITests.swift`

**Step 1: Run automated gates from clean state**

Run:

```bash
supabase stop --no-backup || true
supabase start
supabase db reset
supabase test db
deno test --allow-env --allow-net supabase/functions
swift test --package-path Modules/CompetitionCore
xcodegen generate
xcodebuild test \
  -project HealthComp.xcodeproj \
  -scheme HealthComp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -skipMacroValidation \
  -skipPackagePluginValidation
xcodebuild build \
  -project HealthComp.xcodeproj \
  -scheme HealthComp \
  -configuration Release \
  -destination 'generic/platform=iOS'
bash scripts/verify-no-secrets.sh
git diff --check
```

Expected: all commands exit 0.

**Step 2: Run two-account staging E2E**

Use two dedicated test Apple accounts on the approved one-physical-iPhone-plus-
Simulator topology. Verify create, custom-scheme share, cold acceptance, frozen
time zone, scheduled start, Days 1...7, offline catch-up, Tallying Points,
stable and incomplete best-available results, history, rematch, mute, archive,
deep link, and relaunch. Also sign out and switch accounts on one endpoint; the
second account must see no first-account journals, outbox entries, cursors,
mutes, or installations.

**Step 3: Run adversarial staging cases**

Attempt cross-account reads, replayed invite claims, modified points, stale revisions, duplicate semantic IDs with changed payloads, result rewrites, deleted-profile access, token leakage, and unregistered installations. Each must fail safely and produce no unrelated data.

**Step 4: Run physical-device gates**

On the physical iPhone, verify Sign in with Apple plus provider configuration,
HealthKit grant/deny/re-enable, background observer completion after durable
journal write, APNs token registration and foreground/background delivery,
cold notification routing, App Attest, same-phone replacement installation,
Apple token revocation during account deletion, and relaunch without
resurrection. Exercise the controlled custom-scheme invitation fallback on the
approved topology; universal-link opening is deferred and must not be claimed.

**Step 5: Roll out gradually**

Start with the owner and one trusted pair. Inspect the first completed real competition, then expand to five participants. Expand to 25 only after synchronization, notification, deletion, and historical-data evidence remains clean.

**Step 6: Commit evidence**

Do not commit tokens, private screenshots, account emails, or raw Health data. Commit anonymized results and hashes only.

```bash
git add docs/release HealthCompUITests/MultiUserCompetitionUITests.swift
git commit -m "test(e2e): verify production multi-user beta"
```

## Final Review and Integration

After Task 19:

1. Run `superpowers:requesting-code-review` on the complete feature diff.
2. Run a security diff scan focused on RLS, Edge Function authorization, token handling, deletion, App Attest, and secrets.
3. Fix every validated Critical or Important finding through a new RED -> GREEN cycle.
4. Rerun all affected suites and the full automated matrix.
5. Confirm `feature/multi-user-supabase` contains only logical commits and no environment credentials.
6. Use `superpowers:finishing-a-development-branch` to choose PR/merge handling.
7. Do not call the release production-ready until physical-device gates and staging two-account E2E both pass.
