# Sign in with Apple Sessions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a privacy-safe Sign in with Apple session state machine that reaches the main app only after server profile bootstrap and mounts local remote state under the authenticated profile UUID.

**Architecture:** Keep AuthenticationServices and Supabase SDK objects behind an app-owned `AuthenticationClient` made entirely of Sendable value types and async closures. `AppFeature` owns an explicit launch/auth/profile/main phase machine with auth-epoch stale-result rejection; `AccountFeature` owns only display-safe UI state. A profile-storage dependency derives fixed Application Support subpaths internally, tears down before sign-out/account replacement, and blocks mounting another profile if cleanup fails.

**Tech Stack:** Swift 5.9, SwiftUI, AuthenticationServices, Security, CryptoKit, Supabase Swift 2.49.0, Swift Composable Architecture 1.26.1, XCTest/TestStore, XcodeGen.

---

### Task 1: App-owned authentication contract and nonce validation

**Files:**
- Create: `HealthComp/Services/AuthenticationClient.swift`
- Create: `HealthCompTests/AuthenticationClientTests.swift`

**Steps:**
1. Write RED unit tests for cryptographically generated nonce shape, lowercase SHA-256 challenge, invalid UTF-8 Apple identity token, missing/mismatched nonce claim, cancellation mapping, and value models that contain no token/email/SDK fields.
2. Run only `AuthenticationClientTests`; require failures caused by missing production types.
3. Implement the minimal Sendable value models, typed failures, nonce generator/challenge, and defensive JWT-payload nonce check. Keep the raw nonce inside the adapter flow, never reducer state.
4. Rerun the focused tests and require green.

### Task 2: Supabase and AuthenticationServices adapter

**Files:**
- Create: `HealthComp/Services/SupabaseAuthenticationClient.swift`
- Modify: `HealthComp/Services/SupabaseConfiguration.swift`
- Test: `HealthCompTests/AuthenticationClientTests.swift`

**Steps:**
1. Add RED seam tests for no stored session, valid stored session, expired-session refresh, terminal refresh clearing local auth, retryable refresh preservation, Apple cancellation, valid ID-token exchange with original raw nonce, profile bootstrap with nil/name, auth-stream cancellation, and best-effort remote sign-out after local teardown.
2. Run the focused tests and confirm expected failures.
3. Implement an app-owned adapter over lazily supplied Supabase operations and an AuthenticationServices bridge. Decode only the Apple nonce claim locally; let Supabase verify identity/signature. Map SDK/network errors to closed app-owned categories without retaining or logging bodies or credentials.
4. Rerun the focused tests and require green.

### Task 3: Account reducer and presentation

**Files:**
- Create: `HealthComp/Features/Account/AccountFeature.swift`
- Create: `HealthComp/Features/Account/AccountView.swift`
- Create: `HealthCompTests/AccountFeatureTests.swift`

**Steps:**
1. Write RED TestStore coverage for signed-out sign-in request, cancellation, retryable/terminal errors, explicit display-name entry, validation, submission, and sign-out delegation.
2. Run only `AccountFeatureTests` and confirm missing behavior fails.
3. Implement minimal display-safe state/actions and delegate actions; keep SDK sessions, tokens, nonce, Apple credential objects, email, and error bodies out of state.
4. Rerun the focused tests and require green.

### Task 4: App launch/auth/profile/main state machine

**Files:**
- Modify: `HealthComp/App/AppFeature.swift`
- Modify: `HealthCompTests/AppFeatureTests.swift`

**Steps:**
1. Replace legacy direct-main expectations with RED TestStore cases for cold no-session restoration, valid session bootstrap, expired refresh success, terminal refresh to signed-out, retryable launch failure, display-name-required setup, successful setup, sign-in success/cancellation, token refresh, sign-out, deleted-account event, auth-stream cancellation, and stale auth-epoch results.
2. Run only `AppFeatureTests`; require expected compile/assertion failures.
3. Implement explicit phases `launching`, `signedOut`, `bootstrappingProfile`, `settingUpProfile`, `authenticated`, and `launchFailure`. Start one cancellable auth stream, tag async work with epochs, construct `MainTabFeature.State` only after a stable profile, and stop main runtime before teardown.
4. Rerun `AuthenticationClientTests`, `AccountFeatureTests`, and `AppFeatureTests` together.

### Task 5: Profile-scoped local runtime boundary

**Files:**
- Create: `HealthComp/Services/AuthenticatedProfileStorage.swift`
- Create: `HealthCompTests/AuthenticatedProfileStorageTests.swift`
- Modify: `HealthComp/App/AppFeature.swift`

**Steps:**
1. Write RED tests for internally derived lowercase UUID paths beneath `Application Support/HealthComp/Profiles/v1`, fixed child directories, symlink rejection, `.completeUntilFirstUserAuthentication`, exact-profile wipe, cleanup failure blocking a second profile, and sequential A→B sign-in proving B cannot load or drain A paths.
2. Run the two focused storage/app test classes and verify RED.
3. Implement the narrow mount/teardown dependency using atomic directory creation and existing filesystem safety conventions. Do not migrate the simulated unscoped journal.
4. Rerun the focused tests and require green.

### Task 6: Root UI, composition, and entitlement

**Files:**
- Modify: `HealthComp/App/HealthCompApp.swift`
- Modify: `HealthComp/Resources/HealthComp.entitlements`
- Modify: `project.yml`
- Regenerate: `HealthComp.xcodeproj/project.pbxproj`

**Steps:**
1. Add RED composition tests proving ordinary launch injects the auth adapter lazily and every DEBUG Test Lab mode creates neither Supabase nor auth clients.
2. Implement phase-specific root views, Sign in with Apple presentation, setup form, launch retry, and authenticated main view. Preserve deep-link routing only for authenticated main.
3. Add `com.apple.developer.applesignin = [Default]` while preserving HealthKit/background entitlements.
4. Run XcodeGen twice and require byte-identical generated project output.

### Task 7: Verification, review, and integration

**Files:** All Task 10 paths above.

**Steps:**
1. Run focused auth/account/app/storage tests on one simulator with bounded DerivedData and macro/plugin validation flags.
2. Run the full iOS unit suite once, then a generic Release build with fixture configuration and no signing.
3. Run credential-pattern scan and `git diff --check`.
4. Stage exactly Task 10 files and run independent CodeRabbit review; fix findings test-first and rerun affected gates.
5. Commit `feat(auth): add Sign in with Apple sessions`, push a purpose-named branch, merge through a guarded PR without squashing the logical commit, and verify local/origin main alignment.
