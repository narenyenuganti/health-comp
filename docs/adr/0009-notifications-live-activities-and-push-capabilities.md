# ADR-0009: Notifications, Live Activities, and Watch/Widget Payloads

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `HealthComp/Services/CompetitionNotification*.swift`, `HealthComp/Services/CompetitionPushRegistration.swift`, `HealthComp/Services/CompetitionLiveActivities.swift`, `HealthComp/LiveActivity/`, `HealthComp/Features/Widgets/`

## Context

Local and push notifications, Live Activities, widgets, and Watch snapshots must stay privacy-safe on Lock Screens, never duplicate or contradict on-screen copy, and degrade gracefully across device sizes and Dynamic Type.

## Decisions

### 1. Durable Notification Decisions and Copy/Dedupe Separation
- `CompetitionNotificationCoordinator.swift`, `CompetitionNotificationModels.swift`, `CompetitionNotificationPlanner.swift`:
  - `CompetitionNotificationDecisionCommitter` persists semantic emission decisions atomically in the competition journal; `.appended` proves durable deduplication, never OS/APNs delivery.
  - Semantic notification identifiers deliberately exclude `liveV1` copy, timing, and budget settings so wording and schedules can evolve without breaking durable dedupe keys.
  - `CompetitionNotificationCoordinator` retains recently committed records in memory until reflected in journal snapshots so cross-match rules (posting `"600 today"` at most once per day across all live matches) stay consistent across rapid evaluations and CAS retries (`evaluatedAt` is carried per aggregate so CAS retries do not consult wall time).
  - `knownCompetitionIDs == nil` suppresses orphan notification cleanup when store enumeration failed; `knownCompetitionIDs` includes group matches so orphan cleanup preserves group evening banter.
  - Lead-change alerts never fire on Day 1 (initial leaders and Day 1 flips record silent baselines), compare displayed whole points (preventing `"You 412, Alex 412"` alerts), and fall back to end-of-day totals when same-day dual baselines exist.
  - Multiple results, catch-ups, or same-time 9:00 reminders collapse into a single summary notification; result summaries hold back the winner so the Verdict reveal isn't spoiled.
  - Switched-off families record silent decisions so re-enabling a switch never fires a late backlog.

### 2. Notification Preferences, Privacy, and Alert Reaction Actions
- `CompetitionNotificationClient.swift`, `CompetitionNotificationPreferences.swift`, `CompetitionPushRegistration.swift`:
  - `CompetitionNotificationChoice` raw values match server work kinds (`reaction`, `nudge`, `friend_request`, `friend_accepted`) and `UserDefaults` storage keys (`healthcomp.notifications.<rawValue>`), so raw values must never be renamed. Results, challenges, and challenge expiry have no off-switch.
  - Invite tokens and challenge link codes are forbidden in notification payloads; co-installed Staging builds use a distinct scheme so they never intercept production invite links.
  - Communication notification sender photos (`CompetitionNotificationSender`) reuse only locally cached bytes after revalidating current visibility (never downloading for an alert, failing closed offline). `deleteDonatedInteractions()` is fired without awaiting on sign-out because the system callback can hang on simulators.
  - Local lead-change and result alerts attach the four reaction actions (`CompetitionReactionAlert`), requiring device unlock (`.authenticationRequired`) so the keychain session is accessible and pocket taps cannot react, carrying `recipientUserID` so background actions only send if that user is still signed in.
  - `CompetitionPushRegistration` compares `(token, mutedPushKinds)` against the last confirmed `registered` value inside the drain loop rather than on arrival so in-flight changes are not dropped.

### 3. Final Day Live Activity Lifecycle and Layout Bounds
- `CompetitionLiveActivities.swift`, `MatchActivityAttributes.swift`, `MatchActivityViews.swift`:
  - Live Activities run only for real `.remoteParticipants` matches (never simulated fixtures whose logical clock produces invalid stale dates), keep one active card at a time, and persist `startedMatchIDs` so a user-dismissed card does not restart on the next launch (`forgetStart` resets that record when ended by sign-out or non-completion).
  - `MatchActivityAttributes` carries display points/strings only (never Health values), resolves stale live states directly to `"Final score pending"` without an app wake, and refreshes `opponentName` on every update so renames and `"Former competitor"` propagate immediately.
  - `MatchActivityViews` compiles into both app and widget targets with zero WidgetKit/ActivityKit imports so the Test Lab can render every state.
  - The Lock Screen card caps Dynamic Type at `.accessibility2` because iOS caps Lock Screen Live Activities at `160 pt` height; Dynamic Island surfaces stay dark (`matchActivityIsland()`) and cap at `.xxxLarge` (where iOS 18.5 stops growing island text), use `29 pt` scores so heights stay stable when the Updated line appears, and drop Updated text above default text size to prevent vertical clipping.

### 4. Shared Watch & Widget Snapshot Contracts
- `CompetitionWatchBoard.swift`, `CompetitionWidgetSnapshot.swift`:
  - Both files stay Foundation-only so `HealthCompTests` exercises all Watch and Widget logic on iOS CI without requiring a separate watchOS CI lane.
  - `CompetitionWatchPayload` strips `personID` before leaving the iPhone; `action(after:)` ignores out-of-order older snapshots by `sentAt`, always applies clears regardless of clock skew, and fails closed to clear on corrupt payloads.
  - `CompetitionWidgetSnapshot` keeps `belt`, `chase`, and `group` optional for backward decoding (older Watch builds render a group match using the legacy duel fields against the next place up), caps `timelineDates` at 12 transitions, fails closed to `nil` on unknown snapshot versions, excludes `"Former competitor"` and group matches from the person picker, and redacts names, points, and name-bearing statuses on locked screens (`namesSomeone` is true for anything other than lone `"You"`).
  - Watch score numerals scale with `0.34 em` per character (`competitionWatchScoreSize`) so values like `1,840.25` never truncate on 41 mm screens; unrevealed finals display only `"Final"` in the Watch card list so the list never spoils the Board reveal.
