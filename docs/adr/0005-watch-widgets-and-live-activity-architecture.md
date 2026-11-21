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

### 3. Watch Crown-Paged Architecture, Reveal Choreography, and Layout
- `HealthCompWatch/WatchBoardView.swift` & `HealthComp/Features/Widgets/CompetitionWidgetSnapshot.swift`:
  - `CompetitionWidgetSnapshot.Match` carries optional, backward-compatible `todayRings`, `chase.suggestion`, and `rivalry` fields populated on iPhone (`CompetitionWidgetSnapshotClient`) so Watch stays strictly read-only with zero HealthKit or network dependencies.
  - `WatchRootView` launches directly onto the featured match (or notification-routed match) instead of forcing multi-match users through a flat list; when multiple matches exist, a `.topBarLeading` toolbar button toggles the tonal card-based `WatchMatchesListView` switcher.
  - Each active match renders inside a vertical Digital Crown `TabView(.verticalPage(transitionStyle: .blur))` with semantic top-down `containerBackground` washes: Page 1 (Match Overview scoreboard, labeled 7-day strip, belt chip, and Today swing or chase bar), Page 2 (Today's Rings slanted progress bars + actionable What It Takes chase card), Page 3 (7-day paired column chart masking upcoming days + Best Day / Daily Avg + scrollable per-day exact scores, enabled for both 1v1 and Group matches), and Page 4 (Rivalry H2H record, 5-week form strip, Belt reign card, and strongest ring edge).
  - `drawn` trails `model.snapshot` so a background delivery while the wrist is down does not mutate the visible screen until the user raises their wrist.
  - First-result reveal (`WatchOverviewPage.reveal()`) plays once per match per device: `stage == .done` guards duplicate trigger flips before `markSeen` runs (guaranteeing one clock and one haptic), and `markSeen` runs at the start so dropping the wrist never replays the reveal. `numberAnimation` is `nil` when entering rest state so a live match turning final does not flash the final number early.
  - `WatchBeltCard` holds for `(reduceMotion ? 0.2 : 0.75) + 1.2` seconds—sanctioned timing outside `Motion.swift`—and VoiceOver skips the overlay card while appending its copy (`spokenCard`) to the Overview's accessibility label.
  - Every vertical page adds right-edge clearance (`10 pt`) so watchOS vertical page dots never overlap scores, wraps taller infographic pages in `.scrollIndicators(.hidden)` `ScrollView`s so 40 mm cases and large Dynamic Type stay clear of the status bar and toolbar, and reuses `MarkPolygon.bars` and `MarkPolygon.block` in `WatchBeltPlate`.
- `HealthCompWatchWidgets/HealthCompWatchWidgets.swift`:
  - Rectangular Smart Stack widgets pair a subtle semantic `.containerBackground(for: .widget)` wash (amber when leading and fresh, neutral slate when trailing/stale) with HealthComp's 12° slanted score divider and inline `"<N> to lead"` status when trailing.

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
