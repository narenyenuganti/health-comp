# Multi-User Supabase Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Turn HealthComp into a production-capable, two-person iPhone competition for an initial cohort of up to 25 people, using Sign in with Apple and Supabase while keeping raw HealthKit data on-device.

**Architecture:** Preserve the existing deterministic simulated-rival path exclusively for the DEBUG Test Lab. Add a remote-participant domain path whose local journal records owner HealthKit evidence, remote accepted-score revisions, synchronization receipts, and server-confirmed results. Supabase provides authentication, private invitation claims, participant-scoped durable history, append-only score revisions, finalization, anonymized deletion, Realtime wake-ups, and operational diagnostics.

**Tech Stack:** Swift 5.9, SwiftUI, The Composable Architecture, CompetitionCore, HealthKit, AuthenticationServices, DeviceCheck/App Attest, supabase-swift, PostgreSQL/RLS, Supabase Edge Functions, Supabase CLI, Deno tests, pgTAP, XcodeGen, XCTest, XCUITest, and GitHub Actions.

---

## Execution Rules

- Work only in `feature/multi-user-supabase` until the full verification boundary passes.
- Use strict RED -> GREEN -> refactor cycles. Capture the exact failing assertion or compiler diagnostic before production changes.
- Commit each task independently with the commit shown in that task.
- Do not reconnect or run the historical `Supabase/` migrations against any environment.
- Never upload raw HealthKit samples, workouts, heart rate, routes, locations, or unrelated Health data.
- Realtime is a wake-up hint only. Every wake-up must lead to an authenticated durable refetch.
- Never place a Supabase service-role key, Apple private key, App Attest key, or production access token in the app or repository.
- Simulator tests prove logic only. Sign in with Apple, HealthKit background delivery, App Attest, APNs, and deletion require physical-device gates.

## Baseline

The isolated worktree begins at `25c7cf9` on `feature/multi-user-supabase`.

- `swift test --package-path Modules/CompetitionCore`: 212 tests, 0 failures.
- Generic iOS Simulator Debug build: `BUILD SUCCEEDED`.
- Supabase CLI is not installed at plan-authoring time.
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

**Step 4: Document the boundary**

Update `README.md` so `supabase/` is the live backend source of truth and `SupabaseLegacy/` is historical reference that must never be deployed.

**Step 5: Verify and commit**

Run:

```bash
bash scripts/verify-supabase-layout.sh
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

They must also fail if any live table contains columns named or patterned as `heart_rate`, `workout`, `route`, `location`, `sample`, or `raw_health`.

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

`competitions` stores creator profile, frozen IANA time-zone identifier, local start day, scoring-policy identity, lifecycle, invitation expiry, best-available deadline, optional rematch parent, and timestamps.

`competition_participants` uses `(competition_id, profile_id)` as its key and restricts role to `creator` or `invitee`. Add a deferred constraint trigger that prevents more than two participants and prevents duplicate roles.

**Step 4: Implement append-only evidence and results**

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
- content fingerprint;
- evaluated-at timestamp;
- received-at timestamp.

Use a unique constraint on `(competition_id, participant_id, semantic_event_id)` and another on `(competition_id, participant_id, day_ordinal, client_revision)`.

`competition_results` is insert-only and unique by competition. It stores both participant totals, outcome keyed by winner profile rather than owner/opponent perspective, finalization basis, completed-at, and an immutable seven-day JSON projection whose shape is validated by a constraint function.

**Step 5: Verify and commit**

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

- Profiles: self plus current competition counterparts; never global discovery.
- Competitions, participants, score revisions, results, and awards: current participants only.
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

**Step 2: Put the transaction in PostgreSQL**

Edge Functions authenticate the caller, validate the request envelope, generate or hash the random token, and call narrowly granted RPCs. The SQL functions perform all membership, expiry, schedule, and state changes in one transaction.

The raw token is returned exactly once and is never logged.

**Step 3: Verify locally**

Run:

```bash
supabase functions serve --env-file supabase/.env.local
deno test --allow-env --allow-net supabase/functions/create-competition-invite
deno test --allow-env --allow-net supabase/functions/claim-competition-invite
supabase test db
```

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

Create one shared fixture covering Move, Move Time, Exercise, Stand, Roll, zero values, unavailable evidence, daily cap, fractional values, and invalid bounds. Swift and PostgreSQL must produce byte-equivalent fixed-point points and the same content fingerprints.

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

Each phone may attest its own seven-day window as `stable` or `best_available`. Store the window fingerprint and accepted revision set. A participant cannot attest the other participant's data.

**Step 4: Add server result creation**

The finalizer must create one immutable result when both stable attestations exist, or when the frozen best-available deadline passes. It must preserve unavailable days as unavailable rather than fabricating zeros. Concurrent finalizers must converge on one result.

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

The contract retains the existing publication stream, commands, mute preferences, notification authorization, reconciliation, and stop semantics. Provide:

```swift
struct CompetitionClient: Sendable {
    var start: @Sendable () -> AsyncStream<CompetitionPublication>
    var createInvite: @Sendable (CreateInviteRequest) async throws -> InviteLink
    var claimInvite: @Sendable (InviteToken) async throws -> Void
    var reconcileAll: @Sendable (ActivityRefreshTrigger) async -> CompetitionPublication
    var command: @Sendable (CompetitionCommand) async -> CompetitionPublication
    var stop: @Sendable () async -> Void
}
```

Use compatibility type aliases for presentation types during this task; do not mix behavioral changes with the rename.

**Step 3: Preserve the Test Lab boundary**

`CompetitionTestLabRootView` must explicitly inject `CompetitionClient.localFixture(...)`. Add a test that a poisoned live backend dependency receives zero calls under every Test Lab launch mode.

**Step 4: Verify and commit**

Run the existing 236-test iOS unit suite and the focused Test Lab UI launch test.

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
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionLifecycle.swift`
- Modify: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEngine.swift`
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/CompetitionLifecycleTests.swift`

**Step 1: Write failing remote-ledger tests**

Cover stable participant identity, immutable accepted schedule, ordinals 1...7, monotonic remote revisions, exact duplicate no-op, divergent duplicate rejection, unavailable evidence, fixed-point bounds, active-day visibility, and frozen-window identity.

Expected RED: the domain supports only `OpponentPlan`.

**Step 2: Introduce an explicit counterparty source**

Add:

```swift
public enum CompetitionCounterparty: Codable, Equatable, Sendable {
    case simulated(OpponentPlan)
    case remote(RemoteParticipant)
}
```

The simulated case must preserve all current bytes and behavior. The remote participant contains only a stable profile ID; mutable display names stay outside immutable Core state.

**Step 3: Implement the remote ledger**

The remote ledger accepts only server-accepted wire records and derives an ordered window commitment over ordinal, points, availability, content fingerprint, scoring-policy identity, and server revision. It never contains raw HealthKit evidence.

**Step 4: Verify compatibility**

Run all current Core tests plus the new remote suite. Existing simulated golden traces must remain byte-identical at this stage.

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
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/CompetitionReplayTests.swift`
- Modify: `Modules/CompetitionCore/Tests/CompetitionCoreTests/TallyReconciliationTests.swift`
- Create: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteCompetitionReplayTests.swift`

**Step 1: Capture payload-v4 RED**

Tests must fail on missing remote score and result events. Add sensitivity cases proving that changed participant ID, ordinal, accepted points, availability, server cursor, or result window changes semantic identity.

**Step 2: Add new events**

Add events equivalent to:

```swift
case remoteScoreRevisionRecorded(RemoteScoreRevision)
case remoteFinalWindowAttested(RemoteFinalWindowAttestation)
case sharedResultConfirmed(SharedCompetitionResult)
case synchronizationReceiptRecorded(SynchronizationReceipt)
```

The server-confirmed result must validate against the complete locally known owner and remote windows before completing. Perspective-specific win/loss is derived from the local profile ID; the canonical server result stores a winner profile ID or tie.

**Step 3: Upgrade the journal envelope**

Make payload v4 current while preserving explicit v1-v3 decoding. Never reinterpret a simulated `OpponentPlan` as a remote participant. Add poisoned-payload tests for every new discriminator and relationship.

**Step 4: Update semantic projections**

The terminal projection must include counterparty kind and either the simulated plan commitment or remote window commitment. Existing four simulated golden traces must remain valid; add four separate remote fixtures rather than overwriting them.

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

**Step 5: Verify and commit**

Run focused TestStore tests, the full iOS unit suite, and a generic Release build.

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

Test exact JSON for profile, competition descriptor, invite, claim, revision append, attestation, result, award, installation, and synchronization cursor. Add an allowlist test that recursively rejects keys associated with raw HealthKit data.

**Step 2: Define transport independently of SDK types**

Application and Core code must depend on `CompetitionRemoteAPI`, not `SupabaseClient`. The live adapter alone imports Supabase.

The API exposes authenticated operations for:

- profile bootstrap and update;
- list/fetch competitions;
- create and claim invite;
- append score revision;
- submit final-window attestation;
- fetch changes after a server cursor;
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

Cover atomic append, relaunch, exact duplicate, divergent semantic duplicate, in-flight crash, ack after durable server response, exponential backoff, offline suspension, auth change, cursor conflict, concurrent drains, corrupt primary recovery, file protection, and deletion.

**Step 2: Implement append-before-send**

An owner score revision is first persisted to the Core journal and outbox in an ordered local operation. Network transmission can begin only afterward. Acknowledgement is removed only after a durable server acceptance or exact duplicate response.

**Step 3: Implement one serialized drain**

The coordinator owns one drain task, coalesces wake-ups, observes connectivity opportunistically, and retries only typed retryable failures. Permanent failures remain inspectable and do not spin.

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

Cover bootstrap with zero competitions, incoming/outgoing pending invitations, scheduled start, owner HealthKit refresh, remote revision arrival, Day 1...7, tallying, stable and best-available result, rematch, archive, relaunch, offline cache, partial enumeration failure, and terminal stop.

**Step 2: Compose local and remote authority**

The runtime combines:

- local Core journal and HealthKit environment;
- durable outbox;
- authenticated remote API;
- server cursor and Realtime wake-ups;
- notification coordinator;
- one monotonic publication hub.

Commands return expected publication revisions but never apply command-returned state directly; the canonical stream remains the sole publisher.

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
- Modify: `project.yml`
- Create: `HealthCompTests/RemoteCompetitionFeatureTests.swift`
- Create: `HealthCompUITests/MultiUserCompetitionUITests.swift`

**Step 1: Write user-flow RED tests**

Cover create/share, cold-link claim, warm-link claim, sign-in-before-claim, expired/consumed link, incoming accept/decline confirmation, creator time-zone disclosure, scheduled concrete dates, remote score updates, history, anonymized former competitor, rematch, archive, and offline/error recovery.

**Step 2: Replace simulated copy in production**

Production must never label a real opponent as simulated. Test Lab retains its disclosure. Display-name changes affect presentation only, never immutable participant or score identity.

**Step 3: Handle links safely**

Use a universal HTTPS link as the shareable production form and keep the custom `healthcomp://` scheme for controlled fallback/testing. Parse strictly, park cold routes until auth and the first canonical publication, and consume every accepted or rejected token exactly once.

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

Store installation tokens per profile/device. Edge Functions use generic privacy-safe content, record emission decisions before posting, and remove obsolete pending requests. Keep all service credentials in Supabase secrets.

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

Cover cancellation, reauthentication requirement, active-competition cleanup, pending invite removal, APNs cleanup, auth deletion, idempotent retry, crash between phases, opponent history preservation, `Former competitor` presentation, and inability to reverse-map the anonymized profile.

**Step 2: Implement a durable deletion state machine**

The authenticated function first marks the profile `deleting`, cancels unfinished relationships and installations, anonymizes completed shared records, writes an audit-safe support event, and only then deletes the auth user with server credentials. Retrying resumes from the recorded phase.

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

**Step 3: Add support operations**

Document read-only diagnosis and audited RPCs for invitation resend, reconciliation, unfinished cancellation, and deletion retry. Do not document direct final-score editing.

**Step 4: Rehearse backup and rollback**

Restore a staging backup, verify historical competition counts and immutable result hashes, and rehearse migration rollback or forward repair before production launch.

**Step 5: Commit**

```bash
git add .github docs README.md scripts
git commit -m "ci: verify multi-user backend and iOS release"
```

### Task 19: Execute the Production Verification Matrix

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

Use separate Naren and Alex test Apple accounts on two iPhones or production-shaped test identities in staging. Verify create, link share, cold acceptance, frozen time zone, scheduled start, Days 1...7, offline catch-up, Tallying Points, stable and best-available results, history, rematch, mute, archive, deep link, and relaunch.

**Step 3: Run adversarial staging cases**

Attempt cross-account reads, replayed invite claims, modified points, stale revisions, duplicate semantic IDs with changed payloads, result rewrites, deleted-profile access, token leakage, and unregistered installations. Each must fail safely and produce no unrelated data.

**Step 4: Run physical-device gates**

Verify Sign in with Apple, HealthKit grant/deny/re-enable, background observer completion after durable journal write, APNs foreground/background delivery, cold notification routing, App Attest, device replacement, account deletion, and relaunch without resurrection.

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
