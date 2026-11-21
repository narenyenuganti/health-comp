# ADR-0007: App Lifecycle, Authentication Retirement, and Routing

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `HealthComp/App/`, `HealthComp/Services/*Auth*`, `HealthComp/Services/SharedClientLifetime.swift`, `HealthComp/Services/AuthenticatedProfileStorage.swift`, `HealthComp/Features/MainTab/`

## Context

Account switching, sign-out, account deletion, deep-link claims, and HealthKit/Notification permission onboarding all span asynchronous boundaries where stale callbacks, dropped sheets, or unretired SDK sessions could leak one user's data into another user's session.

## Decisions

### 1. Explicit Client Lifetime Retirement and Session Isolation
- `SharedClientLifetime.swift`, `SupabaseConfiguration.swift`, `SupabaseAuthStorageLifetime.swift`, `SupabaseAuthKeychainStorage.swift`, `AuthenticationLifetimeTasks.swift`:
  - `SharedClientLifetime` admits a successor client only after confirmed retirement of the prior owner; once retirement confirmation succeeds, a later caller cancellation never misreports settled retirement.
  - `SupabaseAuthStorageLifetime` is immutable per client lifetime and never reopened. Beginning retirement sets `writesClosed = true` permanently (even if removal fails) so delayed callbacks from an old owner cannot revive a cancelled session or clear its pending-removal marker.
  - `SupabaseConfiguration` preserves Supabase Swift's project-scoped storage namespace (`authStorageKey`) and explicitly clears the legacy `"supabase.session"` key on retirement so the SDK cannot silently migrate a surviving legacy account over a fresh sign-in. Auxiliary PKCE keys never count as removal of the project session.
  - `SupabaseAuthKeychainStorage` gives the storage protocol explicit absence semantics without parsing private SDK error strings.
  - `AuthenticationLifetimeTasks.cancelAndDrain()` cooperatively drains app-owned listener tasks and must be called by the retiring coordinator, never from a task owned by the set.

### 2. Authentication Exchange, Cancellation, and Logout Confirmation
- `AuthenticationClient.swift`, `SupabaseAuthenticationClient.swift`:
  - `ExplicitAuthenticationOperationGate` serializes sign-in, session restoration, sign-out, and account deletion. Both native and browser exchanges may persist after cancellation, so uncancelled cleanup runs while the gate remains held—preventing any second account from entering until retirement finishes (`retirementRequired` blocks restore/admission on incomplete retirement).
  - `confirmableAccessToken()` refreshes an expired session before calling `logout` because `logout` answers an expired JWT with `401`, which would falsely look like a confirmed sign-out while the server session stayed active.
  - Deletion confirmation and remote sign-out receipts are preserved across local teardown so a later storage failure retries storage retirement without repeating server logout or misreporting ordinary session expiry.
  - `AppleWebAuthenticationSessionClient.swift` marks cancellation synchronously (a callback can reach `MainActor` before an enqueued cancellation task runs) and clears session ownership before calling `cancel()`.
  - `AppleWebAccountDeletionClient.swift` preserves confirmed server receipts even if cancellation raced them, uses independent random draws where only SHA-256 hex challenges leave memory, and never infers rollback from a failed request.
  - `StagingAppleWebAuthenticationConfiguration.swift` validates eligibility and callback URL shape/correlation only—never importing an Auth session or proving deletion on URL shape alone.

### 3. App Root, Profile Storage, and Teardown Boundaries
- `AppFeature.swift`, `HealthCompApp.swift`, `AuthenticatedProfileStorage.swift`:
  - `AppFeature` keeps a newly typed display name across mount failure and Try Again, records `newAccountClaimLinksThrough` on new-account submission so links that arrived before the account existed are rejected locally as `.wrongAccount` without querying the server (revealing nothing about the link), and clears widgets plus device-local reaction seen marks on every signed-out path.
  - Existing profile roots retain unsent scores and practice journals across Try Again; only a root newly created by a failing mount (`isNewlyCreated`) is removed on failure.
  - `AuthenticatedProfileStorage` marks practice journals (`practiceEventsDirectory`, holding exact Health values) as `isExcludedFromBackup = true` so raw Health data never enters iCloud or computer backups.
  - `HealthCompApp` fail-closed and fixture branches construct no live dependency graph, HealthKit source, or production journal. `AuthenticatedRootView` hosts Account behind the Home avatar (avoiding a two-item tab bar), keeps `AppProgressView` on a shared `LaunchWait` clock so phases (`launching`, `bootstrappingProfile`, `tearingDown`) hand off without restarting animations, and passes explicit `profilePhotos` and resolved `colorScheme` into sheets (since a `nil` preference does not reach an open sheet).
  - `HealthCompAppDelegate` activates `CompetitionWatchSync.shared` before the Test Lab early return so fixtures reach the watch, keeps foreground alerts silent (reloading Friends on Friends pushes), and handles background notification reaction actions via `CompetitionReactionAlert.send` only while the alert's recipient is still signed in.

### 4. MainTab Routing, Sheet Coordination, and Onboarding
- `MainTabFeature.swift`, `MainTabView.swift`, `PermissionOnboardingView.swift`, `PermissionOnboardingClient.swift`:
  - First-run onboarding covers Health only (HealthKit never exposes read-denial status, so either answer advances); notifications are prompted in context once a real human match exists.
  - Claim routes stay pending in the process-rooted route hub until explicitly accepted or rejected; a second claim link queues behind an open one (newest wins, releasing superseded routes from the hub). A `600ms` delay before presenting the notifications prompt prevents SwiftUI from dropping a sheet presented mid-dismissal; if another sheet opens while the prompt is `.presented`, it resets to `.unscheduled` to retry later.
  - Sheets (`Practice`, `Friends`, `Challenge`) are attached outside Home's `.refreshable` modifier so downward sheet drags dismiss instead of triggering pull-to-refresh.
  - The toolbar is omitted (not merely faded) during launch so iOS 26 does not render empty glass over the launch mark; a long wait reveals it so Account remains reachable.
  - `DrawerInteractivePop` restores the UIKit left-edge swipe-back gesture inside the Challenge drawer where the system navigation bar is hidden.
  - Person profile pages keep `isBlocked` as `nil` until the block list loads so a blocked person never renders more than the historical ledger.
