# HealthComp

HealthComp is an iPhone Activity competition. The shipping app currently reads
the owner's Activity summaries from HealthKit and runs its deterministic local
competition path. The repository is adding a participant-scoped Supabase
backend for private two-person competitions while keeping raw HealthKit data on
the owner's device.

## What it does

- Runs invitation, scheduled, active, final-day, tallying, completed, archive,
  rematch, and local-deletion states on one iPhone.
- Scores Move, Exercise, and Stand or Roll progress through a versioned policy.
- Re-reads the complete seven-day HealthKit window so late revisions can be
  reconciled before finalization.
- Persists an event journal and notification decisions locally for deterministic
  replay after relaunch.
- Provides DEBUG-only accelerated fixtures for lifecycle, accessibility, and
  parity testing without mixing fixture data with production HealthKit dates.

## Tech stack

- Swift 5.9 language mode, SwiftUI, and The Composable Architecture
- `CompetitionCore`, a Foundation-only local Swift package
- HealthKit and UserNotifications adapters in the iOS application target
- XCTest and XCUITest, with XcodeGen as the project source of truth

## Project structure

```text
HealthComp/                         iOS app, local runtime, and adapters
HealthCompTests/                    iOS unit and integration tests
HealthCompUITests/                  accelerated lifecycle and accessibility tests
Modules/CompetitionCore/           deterministic event-sourced domain engine
supabase/                           live backend source of truth
SupabaseLegacy/                     historical backend reference; never deploy
project.yml                         XcodeGen project definition
```

Only lowercase `supabase/` may contain executable migrations and Edge Functions
for the live backend. `SupabaseLegacy/` is retained solely as historical
reference: never link, reset, push, or deploy it. The current application target
does not import the Supabase SDK until the authenticated transport milestone.

## Setup

1. Install XcodeGen: `brew install xcodegen`.
2. Install the Supabase CLI: `brew install supabase/tap/supabase`.
3. Start Docker Desktop before running the local Supabase stack.
4. Generate the project from the repository root: `xcodegen generate`.
5. Open `HealthComp.xcodeproj`.
6. Use the DEBUG competition test lab on an installed simulator, or run the
   production environment on a physical iPhone for real HealthKit data.

HealthKit authorization, background delivery, and real Activity updates require
physical-device verification. The accelerated fixtures exercise logical
calendar boundaries but do not prove Apple-identical timing or Watch-sync
detection.

## Verification

```sh
swift test --package-path Modules/CompetitionCore
supabase start
supabase db reset
supabase test db
xcodebuild test \
  -project HealthComp.xcodeproj \
  -scheme HealthComp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Scoring

The default policy adds the owner's Move, Exercise, and Stand or Roll goal
percentages and caps each accepted day at 600 points. Policy identity,
quantization, unavailable data, revisions, reconciliation, and the frozen
seven-day ledger are explicit domain state; the app does not claim undocumented
Apple score quantization.

## License

Private
