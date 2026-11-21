# ADR-0012: Database, Unit, and UI Test Invariants

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `supabase/tests/`, `HealthCompTests/`, `HealthCompUITests/`, `HealthComp/Features/Competition/*TestLab*.swift`, `HealthComp/Features/GroupMatch/GroupMatchTestLab.swift`

## Context

The pgTAP database suites, Swift unit tests, Test Lab harnesses, and XCUITest accessibility suites encode several non-obvious test-infrastructure workarounds and security assertions that must stay intact as tests evolve.

## Decisions

### 1. PostgreSQL / pgTAP Test Patterns (`supabase/tests/`)
- `003_rls.test.sql`, `004_rls_adversarial.test.sql`: Apply transaction-local `GRANT SELECT` inside rolled-back test transactions to isolate RLS policy failures as ordinary TAP assertions rather than aborting early on base privilege revokes.
- `006_score_revision.test.sql`: Explicitly sets `set local time zone 'Pacific/Kiritimati'` so Day-8 grace-window assertions are independent of the SQL session's calendar.
- `013_account_deletion.test.sql`: Exercises public presentation/feed seams *before* deletion so post-deletion anonymization assertions cannot pass vacuously when no historical name was ever written.
- `018_web_deletion_recovery.test.sql`: Tests a sibling secret named with `X` in place of `_` (`healthcompXwebXdeletionXcode:...`) to catch unescaped SQL `LIKE` underscore wildcards.
- `027_profile_photos.test.sql`: Sets `storage.operation = 'storage.object.sign'` and `storage.allow_delete_query = 'true'` locally to replicate Storage API GUC state during RLS policy tests.
- `028_friends_wakeups.test.sql`: Strips only `realtime.send`'s transport-generated `id` field when asserting broadcast payloads, and temporarily disables `purge_friends_on_profile_deactivation` inside a rolled-back transaction solely to test the active-recipient filter against corrupt state.
- `045_career_sharing.test.sql`: Drops `competition_result_frozen_window_check` inside its rolled-back transaction so synthetic week results can test career folding across ties, blocks, deletions, and group-match exclusions (confirming same-day finished weeks fold deterministically by UUID).
- `046_audit_fixes.test.sql`: Verifies RLS policies check participant sets once rather than invoking definer functions per row, verifies every `authenticated`-callable RPC is `SECURITY DEFINER` with an empty `search_path` and unreachable by `anon`/`service_role`, verifies western-timezone Day-7 grace windows, and confirms account deletion settles an already-ended duel instead of cancelling it.
- `900_released_api.test.sql`: Enforces both signature backward compatibility and PostgREST `PGRST203` overload uniqueness (PostgREST resolves overloads by parameter names alone and rejects calls when two overloads accept the same argument names).

### 2. Test Lab and Launch-Argument Seams
- `MultiUserCompetitionTestLabView.swift`, `CompetitionTestLabView.swift`, `ProfilePhotoTestLabServer.swift`, `GroupMatchTestLab.swift`:
  - Fixtures never touch real HealthKit, real notification permissions, or real user photos (portraits are procedurally illustrated).
  - Process-wide Test Lab resets run once per process (not per SwiftUI `init`, which re-executes on root re-evaluation), and avoid overriding `UserDefaults` via launch arguments because the argument domain masks app writes.
  - Because `XCUITest` cannot drive `PhotosPicker`, toggle simulator Reduce Motion/VoiceOver, or inspect fast transient animations before app idle, Test Lab harnesses support `--profile-photo-fixture`, `--versus-intro`, `--versus-hold`, `--versus-reduce-motion`, `--versus-voiceover`, `--belt-ceremonies`, `--belt-reduce-motion`, and `--judges-decision`.
  - `CompetitionTestLabView` attaches its root accessibility identifier to a leaf marker so it does not mask child control identifiers.

### 3. XCUITest Accessibility-Audit & Simulator Quirks (`HealthCompUITests/`)
- `BeltUITests.swift`, `ChallengeFriendUITests.swift`, `FriendsUITests.swift`, `FriendsAccountUITests.swift`, `LocalCompetitionLifecycleUITests.swift`, `MultiUserCompetitionUITests.swift`:
  - `performAccessibilityAudit` scrolls the page while inspecting it, so screenshots are captured *before* running the audit; Dynamic Type audits must run without a fixed preferred-category launch override so XCTest can cycle categories.
  - On iOS 18 simulators, `performAccessibilityAudit` occasionally reports text-clipping issues with `nil` element or false-positives on wrapped two-line titles (`"FORMER COMPETITOR"`), tracked section labels, and `List` rows that swap layouts via `ViewThatFits`; affected suites explicitly filter those known iOS 18 false positives (verifying the real rendering via attached screenshots) and keep `.dynamicType` audits on stable non-swapping screens.
  - Simulator bulk `typeText` can drop repeated characters, so critical text-entry helpers replace text cleanly and verify the resulting field value; keyboards are dismissed before auditing because the system predictive bar lacks audit labels.
  - `XCTest` subscript queries cap at 128 characters, so long accessibility predicates use `NSPredicate` directly.
  - Scroll helpers scale drag distance proportionally to distance from viewport center (`min(0.35, max(0.03, abs(offset)))`) because a fixed 8% minimum drag (~44 pt after touch slop) oscillates back and forth across tall cards (`584 pt` in a `627 pt` viewport).
  - At AX5, cards taller than the viewport are checked by top-edge visibility, and sheet share rows are reached via swipes because `scrollTo` does not reliably report them hittable.
