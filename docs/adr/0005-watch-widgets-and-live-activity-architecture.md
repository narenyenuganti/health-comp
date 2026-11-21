# ADR-0005: Watch, WidgetKit, and Live Activity Delivery and Layout Contracts

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `HealthCompWatch/`, `HealthCompWatchWidgets/`, `HealthCompWatchUITests/`, `HealthCompWidgets/`

## Context

The Apple Watch app, watchOS complications, iOS Home/Lock Screen widgets, and Dynamic Island Live Activity all operate under strict background-wake, App Group isolation, privacy-redaction, and small-screen layout constraints.

## Decisions

### 1. Snapshot-Only Extension Boundaries and Per-Device App Group Storage
- `HealthCompWidgets/HealthCompWidgets.swift`: The iOS widget extension only reads the app's snapshot file—never network or HealthKit.
- `HealthCompWidgets/MatchLiveActivityWidget.swift`: The final-day Live Activity receives all data via `ContentState`—no network, HealthKit, or App Group file access. `MatchActivityFamilyView` stays in the widget target because `MatchActivityViews.swift` has no WidgetKit `activityFamily` context.
- `HealthCompWatch/WatchStore.swift`: The Watch app stores the latest iPhone snapshot inside the Watch's own App Group container (per-device, not shared with the iPhone) so complications can read it. `HealthCompWatchApp.init()` initializes `WatchSnapshotModel.shared` eagerly because a background wake may never instantiate the SwiftUI scene.

### 2. WatchConnectivity Delivery and Notification Delegate Ordering
- `HealthCompWatch/WatchStore.swift`:
  - `UNUserNotificationCenter.current().delegate = self` is set at launch in `init()` so a notification tap that launches the app is never missed. `willPresent` is intentionally omitted so mirrored alerts stay silent while the Watch app is foregrounded.
  - `refresh()` re-checks `WCSession.default.receivedApplicationContext` on active view because delivery to a suspended Watch app stalled during watchOS spikes.
  - `finishDelivery()` polls `hasContentPending` and calls `refresh()` directly before the system re-suspends, because `hasContentPending` flipping false does not guarantee the delegate's actor hop has executed yet.
  - `seen.sentAt` advances only after `write(data)` succeeds atomically so a failed write retries on the next delivery.

### 3. Watch First-Result Reveal Choreography and Screen Layout
- `HealthCompWatch/WatchBoardView.swift`:
  - `drawn` trails `model.snapshot` so a background delivery while the wrist is down does not mutate the visible screen until the user raises their wrist.
  - `WatchScreen` is its own view struct so pushed navigation destinations continue tracking `drawn` and `path` updates.
  - First-result reveal (`WatchBoardPage.reveal()`) plays once per match per device: `stage == .done` guards duplicate trigger flips before `markSeen` runs (guaranteeing one clock and one haptic), and `markSeen` runs at the start so dropping the wrist never replays the reveal. `numberAnimation` is `nil` when entering rest state so a live match turning final does not flash the final number early.
  - `WatchBeltCard` holds for `(reduceMotion ? 0.2 : 0.75) + 1.2` seconds—sanctioned timing outside `Motion.swift`—and VoiceOver skips the overlay card while appending its copy (`spokenCard`) to the Board's accessibility label.
  - Pushed boards add `12 pt` top padding so the watchOS back button does not overlap content on 40 mm cases; group boards scroll because four seats overflow 40 mm at large Dynamic Type; `WatchBeltPlate` reuses `MarkPolygon.bars` and `MarkPolygon.block` so the belt matches the brand mark.

### 4. WidgetKit Timelines, Staleness, and Person Picker Stability
- `HealthCompWatchWidgets/HealthCompWatchWidgets.swift` & `HealthCompWidgets/HealthCompWidgets.swift`:
  - Timelines emit `now` plus every upcoming day start, day end, result-expiry boundary (and staleness boundary on Watch), avoiding `.atEnd` reload loops on a single `[now]` entry while letting widgets advance at the match calendar's midnight without waking the app.
  - On Watch complications, stale scores (older than one hour without the phone) switch margin styling to unaccented grey and replace `"LEAD"`/status with the `"Updated ..."` timestamp (included in circular complication VoiceOver labels as well).
  - `CompetitionPersonEntity`: Queries read exclusively from the snapshot (no directory/network). `"Ending soonest"` (`soonestID`) is listed first so a user can undo a selection. `entities(for:)` synthesizes an entity for every requested ID so WidgetKit never drops a stored person and silently reverts to the default match.

### 5. Privacy Redaction, Tinted Surfaces, and Dynamic Type Degradation
- `HealthCompWidgets/CompetitionMatchWidgetViews.swift` & `HealthCompWidgets/MatchLiveActivityWidget.swift`:
  - Names, scores, and name-bearing statuses (`state == .final(.loss)`, e.g. `"Sam won"`) carry `.privacySensitive()` so Lock Screen redaction hides personal data.
  - Dynamic Island and small Live Activity surfaces stay dark across every region so amber (`Theme.youFill`) remains legible as "you" on black. Won days carry `.widgetAccentable(outcome == .won)` on tinted Home Screens; Lock Screen accessory views place `AccessoryWidgetBackground()` explicitly in their body because the system drops container backgrounds.
  - `ViewThatFits` degradation order is intentional: Small drops the lead line before `"Updated"`; Medium drops Today lines before the day strip; Group Medium drops the lead line then non-adjacent rows while VoiceOver retains every seat.
  - `RectangularView` keys `ViewThatFits` choices by `.offset` (not text) so score updates animate in place instead of recreating views. `.scoreRoll` is keyed by `"\(match.id)/\(match.state(at: date) == .scheduled)"` so switching matches never rolls and the first margin fades in cleanly. `EmptyStateView` applies `.fixedSize(horizontal: false, vertical: true)` to prevent single-line truncation.

### 6. Watch UI Test Execution Notes
- `HealthCompWatchUITests/HealthCompWatchUITests.swift`: Runs on the dedicated Mac mini (not GitHub iOS CI) using `--watch-scenario` / `--watch-alert` / `--watch-redacted` launch arguments without WatchConnectivity. `testComplicationOnTheFace` presses `.home` once (pressing twice toggles between watch face and app grid) and verifies the default face's bottom slot; other complication families require manually configured faces. Fresh element queries are used after popping navigation stacks because pre-push queries can miss the revealed Board.
