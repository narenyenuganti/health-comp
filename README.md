# HealthComp

A fitness competition app for iOS. Challenge friends to 1v1, group, or team competitions scored across multiple health metrics — calories, exercise, steps, sleep, and more. Built with SwiftUI, TCA, and Supabase.

## What it does

- **Compete** — Challenge friends to 7-day (or custom duration) health competitions with preset or custom scoring formulas
- **Fair scoring** — Goals lock when a competition starts, fixing the calorie target exploit from Apple's Activity Competitions
- **Multi-metric** — Score across calories, exercise minutes, stand hours, steps, sleep, and distance with configurable weights
- **Friends** — Find friends by username, contacts, or invite link. See their daily activity and rivalry stats
- **Awards** — Earn badges for wins, streaks, and milestones. Unlock cosmetics with Competitive Points
- **Real health data** — Pulls from HealthKit with abstractions for Fitbit/Garmin

## Tech stack

- **iOS:** Swift, SwiftUI, The Composable Architecture (TCA)
- **Backend:** Supabase (Postgres, Auth, Realtime, Edge Functions)
- **Health data:** HealthKit (primary), protocol-based abstraction for future providers
- **Auth:** Apple Sign In via Supabase Auth

## Project structure

```
HealthComp/
├── HealthComp/
│   ├── App/              # App entry point, root router
│   ├── Config/           # Supabase credentials
│   ├── Models/           # User, HealthMetric, Competition, Friendship, Badge
│   ├── Features/
│   │   ├── Auth/         # Apple Sign In
│   │   ├── Onboarding/   # Profile setup
│   │   ├── Compete/      # Active competitions, invites
│   │   ├── Friends/      # Friend list, search, requests
│   │   ├── Awards/       # Badges, cosmetics shop
│   │   └── MainTab/      # Tab bar composition
│   └── Services/         # HealthKit provider, Supabase client, sync
├── HealthCompTests/      # 42 unit tests
└── Supabase/
    ├── migrations/       # 6 SQL migrations
    └── functions/        # Scoring + lifecycle edge functions
```

## Setup

1. Clone the repo
2. Install [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
3. Create a [Supabase](https://supabase.com) project and run the migrations in `Supabase/migrations/` in order
4. Enable Apple Sign In in Supabase Auth settings
5. Update `HealthComp/Config/Secrets.swift` with your Supabase URL and anon key
6. Generate the Xcode project: `cd HealthComp && xcodegen generate`
7. Open `HealthComp.xcodeproj` and run on a device (HealthKit requires a real device)

## Scoring

Competitions use a weighted formula. Each metric earns points as a percentage of the user's locked goal, multiplied by its weight:

```
dailyScore = sum(actualValue / lockedGoal * 100 * weight) for each metric
           = min(dailyScore, dailyCap)
```

**Presets:**
| Mode | Metrics | Daily Cap |
|------|---------|-----------|
| Active Living | Calories 40%, Exercise 35%, Stand 25% | 600 |
| Total Wellness | Calories 25%, Exercise 25%, Stand 15%, Sleep 20%, Steps 15% | 600 |
| Sleep Challenge | Sleep 70%, Steps 15%, Exercise 15% | 600 |
| Step Battle | Steps 100% | 600 |

## License

Private
