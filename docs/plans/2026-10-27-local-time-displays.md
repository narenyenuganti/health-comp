# Local Time Displays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans or a single delegated implementer for this tightly coupled UI change. Steps use checkbox syntax for tracking.

**Goal:** Condense the schedule card to a local date/time range and show every production UI timestamp in the viewer's local time zone without changing the competition calendar or backend.

**Architecture:** Reuse the existing presentation functions and native Foundation formatting. Keep actual instant formatting in one small Foundation-only source file so it can be tested without building an iOS app. Derive schedule boundaries with the existing CompetitionCalendar APIs; do not alter domain models or persistence.

**Tech Stack:** Swift, Foundation, SwiftUI, existing standalone Swift checks and app/UI tests; no new dependency.

**Spec:** Owner's October 27 request: remove the redundant "Seven-day schedule" heading, display the converted local date/time range, and apply local formatting to all displayed times/timestamps; UI only. Owner has explicitly opted out of routine design/approval questions and selected subagent execution.

## Global Constraints

- Canonical saved competition time zone stays unchanged (LA for the current match; do not hardcode LA globally).
- Real end is the start of the day after the seventh scoring day. Never add 168 hours or invent 11:59 PM.
- Use device time zone and locale/12-24-hour preferences for absolute instants, with a short recognizable zone indication; do not show raw IANA identifiers as the schedule label.
- Preserve canonical CompetitionDay identity, ordinal, scoring, Today/lifecycle evaluation, notification fire dates, wire encodings and DEBUG Test Lab's fixed clock.
- Cover schedule, home/detail end badges, Activity read timestamps, reconciliation deadlines, and award/history/result dates, including accessibility.
- Keep safe missing/invalid-schedule fallbacks; retain competition.schedule.dates.
- Preserve PR174's separate Points Only removal; no phone, hosted, database, account, notification or release upload action.

## Review Focus

- LA October 28-November 4, 2026 boundary spans 169 hours; local range must include the real end.
- Spring DST and distant zones can change local dates/hours independently of canonical score-day labels.
- Midnight date rollover must also affect award and Activity-read displays.
- US and 24-hour locales must not be forced to en_US_POSIX or a fixed AM/PM pattern.
- Device locale/time-zone changes must refresh visible formatting; don't capture a startup zone or mutate stored scheduling.

### Task 1: Localize presentation and condense the schedule

**Files:** Existing CompetitionDetailView.swift, CompetitionSharingView.swift, CompetitionResultView.swift and their tests; a small Foundation-only CompetitionDateFormatting.swift if needed to share/test the existing formatters. Relevant invitation/onboarding copy and test expectations only where audit shows inaccurate time wording. No backend/Core/wire changes.

**Interfaces:** Keep competitionScheduleDateRangeText(_:) as the canonical-schedule presentation entry point. Reuse competitionDateTimeText and competitionAwardDateText names, with explicit testable locale/display-TimeZone parameters defaulting to the current viewer context. Use SwiftUI locale/timeZone environment where necessary for live re-rendering. A small range-of-Date formatter may be shared; do not create a new module or configurable formatting framework.

- [x] Write focused runtime assertions against the real formatting helper before changing behavior; demonstrate the old canonical/forced-English behavior fails the intended local result. Use the existing standalone Swift script pattern for cheap local RED/GREEN, with app tests for schedule integration.
- [x] Hand-check fixtures: start 2026-10-28T07:00:00Z, end 2026-11-04T08:00:00Z. LA shows Oct28 00:00 PDT through Nov4 00:00 PST; New York shows Oct28 03:00 EDT through Nov4 03:00 EST; Tokyo shows Oct28 16:00 through Nov4 17:00. Test a spring-forward interval, date rollover, 12/24h locale, mismatch fallback, and unchanged canonical day identity. Host fixture checks passed; added app-only schedule tests await iOS CI.
- [x] Implement the compact single-label schedule, localized absolute timestamps and true end badges, preserving accessible descriptions and dynamic type wrapping. Remove misleading tomorrow copy where it assumes the viewer's day equals the competition day. Do not add an alternate time-zone picker.
- [x] Update existing app and UI expectations for the removed heading/local range and injected display context. Keep deterministic test-only/wire formats unchanged; exercise actual formatting rather than grepping source in a permanent test.
- [ ] Run the standalone formatter tests, Swift parse, diff/secret/privacy guards, and exact-head full CI. Run local full iOS tests only within the existing bounded/serialized build boundary; no physical phone is required.
- [ ] Obtain independent spec/quality review, commit on design/local-time-displays, and integrate only after exact-head CI passes. Keep the delivered TestFlight build/source distinct; no automatic phone update or release upload is part of this task.

**Sources:** [Apple interval formatting](https://developer.apple.com/documentation/foundation/date/intervalformatstyle), [Apple date format style](https://developer.apple.com/documentation/foundation/date/formatstyle).
