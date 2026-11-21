# Architecture Decision Records

Non-obvious engineering, protocol, privacy, and UX decisions live here rather than in inline code comments. See [ADR-0001](0001-no-code-comments-and-ratchet.md) for the no-comment policy and ratchet workflow.

## Index

| ADR | Title | Scope |
| --- | --- | --- |
| [0001](0001-no-code-comments-and-ratchet.md) | No code comments with a per-file ratchet | Repository-wide (`scripts/verify-no-comments.py`, `scripts/comment-ratchet.json`, `.claude/skills/delete-comment/SKILL.md`) |
| [0002](0002-competition-core-journal-and-replay-contracts.md) | CompetitionCore journal, replay, and privacy contracts | `Modules/CompetitionCore/` |
| [0003](0003-scoring-bots-sleep-and-banter-determinism.md) | Scoring policies, deterministic bots, sleep, and banter | `Modules/CompetitionCore/` |
| [0004](0004-backend-edge-functions-security-and-delivery.md) | Backend Edge Functions security, deletion, and push delivery | `supabase/functions/`, `functions/` |
| [0005](0005-watch-widgets-and-live-activity-architecture.md) | Watch, WidgetKit, and Live Activity delivery and layout contracts | `HealthCompWatch/`, `HealthCompWatchWidgets/`, `HealthCompWidgets/` |
| [0006](0006-ci-verification-and-release-scripts.md) | CI verification and release safety scripts | `scripts/` |
| [0007](0007-app-lifecycle-auth-retirement-and-routing.md) | App lifecycle, authentication retirement, and routing | `HealthComp/App/`, `HealthComp/Services/*Auth*`, `HealthComp/Features/MainTab/` |
| [0008](0008-remote-sync-healthkit-and-group-match-runtime.md) | Remote sync, HealthKit ownership, and group match runtime | `HealthComp/Services/`, `RemoteCompetitionClient.swift`, `LocalCompetitionClient.swift` |
| [0009](0009-notifications-live-activities-and-push-capabilities.md) | Notifications, Live Activities, and Watch/Widget payloads | `HealthComp/Services/CompetitionNotification*.swift`, `HealthComp/LiveActivity/`, `HealthComp/Features/Widgets/` |
| [0010](0010-design-system-motion-sound-and-ceremonies.md) | Design system, motion, sound, and ceremonies | `Theme.swift`, `Motion.swift`, `Sounds.swift`, `HealthComp/Features/Competition/` |
| [0011](0011-social-friends-photos-group-matches-and-sleep.md) | Social features, profile photos, group matches, and Sleep Beta | `HealthComp/Features/Account/`, `Friends/`, `GroupMatch/`, `Competition/` |
| [0012](0012-database-and-ui-test-invariants.md) | Database, unit, and UI test invariants | `supabase/tests/`, `HealthCompTests/`, `HealthCompUITests/`, Test Labs |

## Adding an ADR

1. Pick the next sequential number (`NNNN-short-slug.md`) or append a new subsection to an existing domain ADR when the decision belongs tightly to that subsystem.
2. State **Context**, **Decision**, **Consequences / Invariants**, and the exact **Code References** (`path` and symbol names, avoiding brittle line numbers).
3. Update the index table above.
