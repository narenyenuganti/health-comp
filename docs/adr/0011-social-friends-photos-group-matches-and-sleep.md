# ADR-0011: Social Features, Profile Photos, Group Matches, and Sleep Beta

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `HealthComp/Features/Account/`, `HealthComp/Features/Friends/`, `HealthComp/Features/GroupMatch/`, `HealthComp/Features/Competition/CompetitionFeature.swift`, `CompetitionBadges.swift`, `CompetitionRivalry.swift`, `CompetitionSleep.swift`, `ClaimCompetitionView.swift`, `CreateCompetitionView.swift`, `PracticeMatchSheet.swift`

## Context

Account privacy settings, usernames, friends search, profile photos, badges/records, group matches, and Sleep Beta introduce cross-cutting privacy, concurrency, and UI state invariants across TCA reducers and SwiftUI views.

## Decisions

### 1. Account Settings, Username Filtering, and Friends Concurrency
- `AccountFeature.swift`, `AccountSettingsView.swift`, `AccountView.swift`:
  - The username is the only name a player chooses. `profiles.display_name` stays the wire field every surface reads (matches, widgets, watch, pushes, older builds), and `AppFeature.followUsername` writes the username into it whenever friend settings arrive with a username that differs. Players without a username keep their old display name: a username makes a player searchable, so none is claimed for them.
  - Sign-up calls `sign_up_with_username`, which creates the profile holding the username or creates nothing, so a taken username is reported on the sign-up screen. The server must have that migration before a build with this sign-up ships. `bootstrap_current_profile` stays for launch and for older builds.
  - Account groups rows by subject: the username under the photo, the challenge link's everyday actions, Your Data (Health, Sleep, Privacy) and Preferences (Notifications, Appearance, Sounds). Privacy holds everything about who can reach you: search, challenge policy, Reset Challenge Link and the blocked list.
  - `AccountView` retains `LastDrawn` so the root crossfade off Welcome/Setup never draws signed-in state; Privacy Policy uses a `48 pt` minimum target (not `44 pt`) because centered content on fractional origins can round below `44 pt`.
  - `AccountSettingsView` puts `44 pt` frames *inside* button labels so hit areas stay valid, attaches Sign Out alert to its button rather than the `List` (preventing collision with the Delete Account alert), keeps QR codes black-on-white in both modes, crossfades appearance changes via UIKit snapshot (`Motion.fade`) because dynamic colors do not interpolate through SwiftUI transactions, and splits `listWithHaptics` into plain `Bool` bindings so Xcode 16 type-checks within budget.
- `UsernameSheet.swift`:
  - Wraps `UITextField` (`UsernameField`) instead of SwiftUI `TextField` to filter disallowed characters *before* they land on screen; SwiftUI's `TextField` renders rejected keystrokes first and on busy devices can skip redraw/`onChange` so invalid or overlong usernames stay visible. Mid-composition marked text passes through untouched until composition ends, and `editingChanged` also filters dictation/prediction input.
- `FriendSettingsFeature.swift`, `FriendsFeature.swift`, `FriendsView.swift`:
  - Both `State` structs omit `@ObservableState` because Account and parent reducers pass them by value.
  - Debounced username availability and people search deliberately avoid TCA's `.cancelInFlight`: under main-thread load an older edit's effect can start *after* a newer edit's effect and cancel the newest request, leaving a stuck spinner. Instead, every edit increments a monotonic generation counter (`edit` / `searchGeneration`) and only the latest generation dispatches or applies results.
  - Search requires at least 3 Unicode scalars (excluding a leading `@`) and skips checking the user's own current username because every search counts against the server rate limit.
  - Block and Report run under a separate `CancelID.safety` (cancelled only by sign-out, never by navigating away), cancel in-flight list loads so stale reads cannot restore unblocked/blocked rows, and in "Report and Block" execute Report before Block because a blocked user can no longer be reported.
  - `FriendsView` checks `saved.map { $0.username == nil } ?? false` (not `saved?.username == nil`) so the one-time username prompt triggers when settings arrive with no username rather than evaluating true before settings load, and persists the "prompted" key only after settings succeed.

### 2. Profile Photo Privacy, Metadata Stripping, and Caching
- `ProfilePhotos.swift`, `ProfilePhotoViews.swift`, `CompetitionFeature.swift`:
  - `ProfilePhotoImage` redraws picked images into a fresh `512×512` JPEG (≤ `512 KiB`, matching bucket policy) and strips every JPEG `APPn` segment except `APP0` (JFIF) via `withoutMetadataSegments`, removing even ImageIO's generated `APP1` Exif and `APP13` Photoshop blocks so files contain pixels only.
  - Downloads are validated by `isAcceptableDownload` (single JPEG frame, ≤ `512 px`, ≤ `512 KiB`) before display, decoded off the main actor (`ProfilePhoto.init`), and cached under `AuthenticatedProfileStorage` (`<owner>_<version>.jpg`) so sign-out and deletion wipe them together.
  - Photos upload without upsert (new UUID version per upload) after pruning leftovers to stay within the 3-object folder policy; `ownPhotoSaves` counter prevents an in-flight `list_profile_photos` response from evicting a newly saved own photo.
  - `CompetitionFeature.loadProfilePhotos` runs outside the sync operation gate so avatars never block score reconciliation, verifying `isMountedPhotoCache` after every `await` so late responses never write into another account's cache.

### 3. Group Match Isolation and Presentation Rules
- `GroupMatchPresentation.swift`, `GroupMatchFeature.swift`, `GroupMatchHomeCards.swift`, `GroupMatchRecord.swift`, `GroupMatchResultView.swift`, `GroupWeekGrid.swift`:
  - Group matches live in `dashboard.groupMatches` (never `dashboard.competitions`), render in their own Home section and History section below duels, never enter duel-only surfaces (belt, hero card, head-to-head rivalry records), and are toggled via `GroupMatchRollout`.
  - Group matches use `MatchScoring` for live projections and render the server's frozen standings, seat totals, and day values verbatim once finished (`frozenSeats` maps day-0 leave cutoffs to resolved zeros).
  - Nothing is edited in place: a declined/expired/cancelled group stays a read-only lobby; a four-way with an empty seat can drop to a three-way only during creation.
  - Doubles renders amber for you, an amber outline (`Theme.you`, `2 pt` stroke for contrast) for a human partner, and neutral ink/grey for bots and opponents (a bot never wears amber). `GroupWeekGrid` caps Dynamic Type at `.xxxLarge` because seven columns of scores fit a phone only up to that size.
  - `GroupMatchResultView` omits the podium if a tie spans 3rd and 4th place so tied places never appear unequal.

### 4. Duels, Invites, Rivalry History, Badges, and Sleep Beta
- `CompetitionFeature.swift`, `ClaimCompetitionView.swift`, `CreateCompetitionView.swift`:
  - Challenge links never expose account IDs; only a friend or known account ID enables pre-send conflict detection (links rely on the server on Send). Rematch and sheet creations keep separate `InviteSlot` idempotency keys; creating rotates to a fresh key after a conflict so a modified retry cannot stay pinned to a conflicting request.
  - `ClaimCompetitionView` keeps its last real preview while `.idle` dismisses so the slide-down never blanks out.
  - `CreateCompetitionView` uses a multi-line code field so long codes wrap and meet the `44 pt` minimum hit target, and uses a collapsed status enum for animations because `status` payloads change on every publication.
  - `CompetitionFeature.pruneInviteLinks` treats partial/failed discovery (`discoveryIsIncomplete`) as unknown rather than proof a pending challenge retired.
- `CompetitionBadges.swift`, `CompetitionRivalry.swift`:
  - All nine badges and personal/rivalry records are computed purely on-device from finished 1v1 weeks (never sent to the server, excluding practice matches and retiring deleted accounts' belts). On record ties, the later week holds the record (`>=`).
  - Person pages exclude any finished week whose Verdict hasn't been seen yet when computing belt state so the person page never spoils the ceremony. Year-scoped rivalry filters appear only once 3 weeks exist in the current calendar year.
- `CompetitionSleep.swift`:
  - Rings + Sleep nights live beside ring scores (`list_sleep_scoring` / `submit_sleep_night`) and fold into match presentations in a single place (`addingSleep`), comparing combined scores in hundredths so floating-point noise never splits a tie. Because the server result is rings-only during Sleep Beta, `addingSleep` derives the displayed verdict from the combined score.
