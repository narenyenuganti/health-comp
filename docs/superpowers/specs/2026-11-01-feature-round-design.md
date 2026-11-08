# Feature round: design

Date: 2026-11-01 · Branch base: `main` at 8c5ca25 · Status: design, built on the defaults in §8 until the owner answers

## 1. Intent and why

The owner approved a round of ten features from the HealthComp playbook. They answer four gaps the audit round left open:

- **A reason to play the next week.** The belt and a page per person, then a recap card to share a result.
- **Knowing what to do today.** A "what it takes" panel on the Today page, and an evening reminder for it.
- **The score without opening the app.** Home Screen and Lock Screen widgets, then a final-day Live Activity.
- **Talking to the other person without a chat.** A nudge when their score is stale, block for unwanted challengers, and four preset reactions.
- **A first week without a rival.** A practice match against a pacer from the empty Home.
- **Control.** Per-kind notification switches in Account → Notifications.

**Stakes were rejected by the owner.** They appear nowhere: not on the result, the recap card, any notification, any widget or any test fixture.

The work is 14 PRs in 5 tracks (§6). §9 holds each PR's full spec, reviewed separately and reconciled here. Where §9's text and an "Integration amendments" block at the top of a section disagree, the amendment wins: it is how this document resolves contradictions between the specs (shared helpers, the notification switches several features wanted to add, Home card lines, fixture ids, migration order).

## 2. Goals, non-goals, anti-goals

**Goals**
- Each feature ships as specified in §9, with the owner's playbook mockups as the target and every deviation listed on that PR's preview artifact.
- One belt per pair, computed on the phone from finished weeks, with the same answer on History, the person page, the result banner, the recap card and the local result notification.
- One owner for every notification switch (PR 13). No feature adds its own Account row.
- Server PRs merge and promote one at a time, in a fixed migration order (§6), each moving the recovery harness by one.
- Every new control reaches AX5, has a VoiceOver label and a 44 pt target, and keeps existing accessibility identifiers.
- Practice weeks never count anywhere: History, records, the belt, the recap, widgets, the Live Activity, notifications, nudges, reactions.

**Non-goals (this round)**
- **Stakes of any kind** ("Double or Nothing", stakes on the recap card or anywhere else). Rejected by the owner.
- A Report action next to Block (§8 Q-block-3).
- ActivityKit push tokens or push-to-start (the Live Activity updates only from app refreshes).
- A Notification Service Extension or Apple's notification filtering entitlement (§8 Q-notifs-4).
- The belt on widgets, the match screen or History's week rows. If a widget ever shows it, the belt fold moves into CompetitionCore then (PR 1 Risks).
- Interactive widget buttons, `accessoryInline`, watchOS or CarPlay families.
- Practice notifications, a "Practice Again" action, practice in History.
- Chat or free-text reactions.
- Deleting the now-unused award model (`LocalCompetitionDashboard.awards`); marked with a `ponytail:` comment for a later `refactor/` PR (PR 1).

**Anti-goals: these would make the round a failure even if it technically works**
- Any stakes copy, field or state.
- Exact Health values (kcal, minutes, hours, goals) leaving the iPhone. The only places they appear are on-device: the Today panel and the local 7 PM reminder (§8 Q-takes-3).
- A server push that names a person. Server pushes stay generic ("Score update needed", "New reaction", "Challenge declined").
- A people directory, search or any way to look up an account. Block and reactions stay keyed to an existing match or challenge.
- A new app build reaching TestFlight before the production server it calls, or an installed 1.0.2 build breaking silently.
- Two screens disagreeing about who holds the belt, or a practice week counting in a record.
- Editing a historical migration, or two migrations with the same sequence number.
- A `project.pbxproj` that XcodeGen 2.46.0 can't regenerate identically, or accessibility identifier churn that breaks the UI suites.
- New colors, taglines or marketing copy.

## 3. Constraints

**Toolchain and verification path** (checked against 8c5ca25)
- Deployment target iOS 17.0 (`project.yml:5`), `SWIFT_VERSION: "5.9"`. PR CI uses Xcode 16.4 (iOS 18.5 SDK, iPhone 16 Pro simulator). Every API in §9 exists there, and none is newer than iOS 17, so no PR needs `if #available`. The newest APIs this round uses:
  - iOS 17: `AppIntentConfiguration`, `WidgetConfigurationIntent`, `AppIntentTimelineProvider`, `containerBackground(for:)`, `onChange(of:)` with the zero- and two-argument closures, `AccessibilityNotification.Announcement`
  - iOS 16.1/16.2: ActivityKit (`Activity.request(attributes:content:pushType:)`, `staleDate`, `activityEnablementUpdates`), `ImageRenderer`, `ShareLink`, `Transferable`, `AnyLayout`, `presentationDetents`
- This Linux VM has no Swift toolchain. Builds, unit and UI tests and captures run on the Mac mini (Xcode 26.6, work only in `~/dev-desktop`, `~/dev-desktop/ua/ua-mac6.sh` modes `xcodegen`, `unit`, `ui`, `ci`). `ua-mac6.sh ci` reads its UI list from `ci.yml`, so assertions in tests outside that list are gated only by a Mac mini `ui` run of the full classes, which must pass before a PR opens.
- **New Swift files and targets are allowed this round.** `project.pbxproj` is generated by XcodeGen 2.46.0 from `project.yml`, and CI checks it regenerates identically. Every PR that adds a file regenerates and commits the pbxproj on the Mac mini (`~/tools/xcodegen/bin/xcodegen generate`, run twice, no diff). `project.yml` itself changes only in PR 2 (Photos add key), PR 6 (widget target, App Group) and PR 7 (`NSSupportsLiveActivities`, widget sources). Whoever merges second regenerates; never hand-merge the pbxproj.
- `HealthComp/Features/Competition/CompetitionDateFormatting.swift` stays Foundation-only; CI compiles it alone (`scripts/tests/competition-local-date-formatting.swift`). Only PR 6 edits it (moves `CompetitionDayOutcome` and `competitionMarginText` in, adds two helpers). From PR 6 on it also compiles into the widget extension, so it must stay extension-safe.
- Modules/CompetitionCore is a Foundation-only package with its own `swift test`. Only PR 11 changes it (`OpponentGeneratorVersion.v2`); v1 bytes, commitments and goldens don't change.

**Design system**
- `HealthComp/App/Theme.swift` tokens only: amber (`Theme.you`, `Theme.youFill`) is you, ink is the other person, ring colors only on your own ring detail. No new colors. Three mockup tints that aren't tokens are dropped (the belt banner's and the takes panel's #FFF3D6, the reaction chip fill) and replaced by `themePanel()` / `Theme.control`. Two platform-control exceptions are owner questions: the system-green toggle tint (§8 Q-notifs-5) and none other.
- Reuse `SectionLabel`, `themePanel`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, `CompetitionPressButtonStyle`, `CompetitionRowButtonStyle`, `CompetitionDrawer`, `CompetitionMoreLabel`.
- One job per screen: detail goes in pushed screens (the person page), sheets with detents (Share Result, practice pace), or ••• menus (End Practice, Block). Each screen keeps one pinned primary action (Rematch stays pinned on the result; Share Result is a secondary button in the scroll).
- Copy is plain and minimal, numbers through the shared formatters (`competitionPointsText`, `competitionFinalFractionDigits`, `competitionPointsAccessibilityText`), apostrophes typographic.

**Privacy**
- Exact Health values never leave the iPhone. The widget snapshot, Live Activity content and recap image carry points only.
- No people directory or search. The recipient-bound challenge contract (`docs/plans/2026-10-19-recipient-bound-invitations.md`) holds: block is granted only through a challenge addressed to you (PR 8 amends the contract doc with a "Blocking" section), reactions only between accepted participants.
- Server push text is generic, with no names (audit Q3 default). Local notifications built on the iPhone may name the other person (belt sentence, the 7 PM reminder).
- `web/privacy.html` changes in five PRs (2, 8, 9, 12, 13); each deploy carries one effective date, and the page is live before the TestFlight build that needs it.

**Server and release**
- Migrations in `supabase/migrations` are forward-only; 26 exist at 8c5ca25, the newest `20261101002400_reset_challenge_link.sql`. Each new migration moves the recovery harness by one: `scripts/test-recovery-migrated-snapshot.sh:31` (count) and `:9` (`manifest_hash`, from `shasum -a 256 supabase/migrations/*.sql | shasum -a 256`), plus the allowed max-version list in `scripts/tests/recovery-migrated-fixture.sql:23-24`. A migration that adds a private table also moves the state-acceptance baseline (`scripts/recovery-state-acceptance-query.sql`, `scripts/test-recovery-state-acceptance.sh:32/:578`, `scripts/tests/recovery-state-fixtures.sql`, `.github/workflows/backend.yml:223`, `docs/runbooks/backup-restore.md`).
- Edge Functions in `supabase/functions` with Deno tests; pgTAP in `supabase/tests` (newest `022_reset_challenge_link.test.sql`). CI: `.github/workflows/backend.yml` (pgTAP, Deno, lint, diff, state acceptance) and `ci.yml` (app; the UI tests are an explicit `-only-testing` list at :212-228).
- Server ships Staging → production (through `docs/release/production-beta-checklist.md`) before any TestFlight build that calls it. Installed 1.0.2 and current builds keep working (compatibility tables in PRs 4, 8, 9, 13).
- `UNIQUE NULLS NOT DISTINCT` (PRs 4 and 9) needs PostgreSQL 15+; local `supabase/config.toml:42` is 17, Staging and production are an owner check (§7).

**Tests**: HealthCompTests (unit), HealthCompUITests (two classes with exact-string assertions), Modules/CompetitionCore `swift test`, pgTAP and Deno. `ci.yml` gains five UI tests this round (PRs 1, 2, 5, 10, 12); PR 13 extends `testNotificationsPageOpensSettingsAndUnmutes`, which is already in the list.

## 4. Decisions

**Owner decided**
- Build these ten features: the belt with a page per person, the recap card, what it takes (panel and reminder), notification choices, widgets, the final-day Live Activity, the practice match, nudge, block a challenger and reactions.
- **Stakes are rejected.** Nothing in this round adds them.
- The build order is the playbook's ("belt, then recap; what it takes; nudge; widgets and the Live Activity; reactions, block, practice and notification choices after that"). §6 follows it, with the one change below.

**Claude's calls** (the owner can overrule any; each PR section lists its own smaller ones)
- **Notification choices owns every switch, and lands after the features whose rows it shows** (Nudge, Live Activity, Reactions). The Live Activity and Reactions specs each had their own Account row; both rows are removed from those PRs and live only in PR 13. Reactions keeps `device_installations.supports_reactions` purely as a capability flag (true from every new build), and its on/off choice is PR 13's `muted_push_kinds`.
- **The 7 PM what-it-takes reminder lands after Notification choices** (the planned track B: panel → choices → reminder). PR 13 ships six rows; PR 14 adds the seventh ("What it takes") with one enum case and one mapping line, so no build ever has a reminder without a switch or a switch that does nothing. This resolves the circular dependency between the two specs.
- **Server PRs merge in the order Nudge → Block → Reactions → Notification choices**, one at a time. Provisional migration names and harness numbers are fixed in §6; whoever merges out of order renumbers.
- **One belt API** (`competitionBelt`, `competitionBeltEvent(for:in:)`, `competitionBeltResultText`, `CompetitionBeltMark`, in `CompetitionSharingView.swift`) is shared by the result banner, History, the person page, the planner and the recap card. The recap maps `CompetitionBeltEvent` to its own card wording with one adapter.
- **The belt result notification fires on every take** and a tie extends a reign (belt Q-a/Q-b defaults). The recap card never shows a belt line on a tie or for a deleted account.
- **Practice is excluded explicitly** wherever a dashboard is read: `competitionHistoryWeeks`, the recap's Share Result, the widget snapshot, the Live Activity planner and the nudge control. It is excluded automatically from the notification snapshot (never added), the belt and records (built on `competitionHistoryWeeks`) and reactions (`competitionCanReact` needs a remote profile identity). The what-it-takes panel does show on a practice week: it is the same Today page against the pacer.
- **Block stops challenges only.** It doesn't stop reactions in a live match; mute covers that (the reactions spec's suggested block check is not added).
- **Test Lab fixture ids** are allocated once (`…0008` is already `expiredRecipientID`): belt `…0009` (Jordan's past week), recap `…000A` (Casey), block `…000B` (incoming challenge), practice `…000C` (Pacer).

## 5. Glossary additions

Add to the audit spec's §5. These apply to every shipped string, VoiceOver label and notification.

| Term | Means | Don't say |
|---|---|---|
| **Belt** | One per pair of people; won by the first decided week, taken by beating the holder. Verbs: "holds", "took", "kept". "Title", "title defense" and "reign" are allowed (2026-11-05: a title defense is a win while holding the belt; a tie or the take is not one) | championship, trophy, crown, stakes |
| **Practice** / practice match | A solo 7-day week on this iPhone against the pacer. Status lines read "Practice · …" | test match, solo mode, bot |
| **Pacer** | The practice opponent's display name | AI, computer, simulated opponent (except the existing rules row "Pacer is simulated.") |
| **Reaction** | One of four presets (👏 Clap, 🔥 Fire, 😤 Huffing, 🫡 Salute) on the other person's day or the result. "{Name} reacted to your Day 2" | like, emoji, comment |
| **Nudge** | A generic push asking the other person to open HealthComp. "Nudge {Name}", "Nudged at 8:12 AM" | ping, poke, remind |
| **Block** / **Unblock** / **Blocked** | Stop one person from challenging you; the Account section is "BLOCKED" | ban, report, restrict |
| **Share Result** | The recap card's button and sheet title; the shared thing is "a result image" | recap, story, post |
| **Live Activity** | The Lock Screen and Dynamic Island card (Apple's term) | widget (for this), live card |

## 6. PR plan

| PR | Branch | Scope | Depends on (must merge first) | Can be built in parallel with | Touches server? |
|---|---|---|---|---|---|
| **1** Belt and a page per person (track A) | `feature/rivalry-belt` | Belt fold and helpers, Home chip, result banner replacing AWARDS, History record mark, person page (`CompetitionHomeRoute.person`), belt sentence in the local result notification, one ci.yml UI test | none | 3, 4, 6, 8, 11 | No |
| **2** Recap card (A) | `feature/recap-card` | Share Result sheet with a 1080×1350 PNG (`CompetitionRecapView.swift`), Show/Hide name, `NSPhotoLibraryAddUsageDescription`, Casey lab fixture, privacy sentence, one ci.yml UI test | 1 | 3–12 | No (static `web/privacy.html`) |
| **3** What it takes: Today panel (B) | `feature/what-it-takes` | `competitionWhatItTakes`, `CompetitionWhatItTakesPanel` above the ring panel, unit tests, one local UI test | none | everything | No |
| **4** Nudge: server (D) | `feature/nudge-server` | Migration `20261101002500_add_match_nudges.sql` (`nudge_day`, identity rebuild, RPC, lease discard arm), `nudge` kind in `send-competition-notification`, pgTAP 023, harness 26→27 | none (first server PR) | 1, 2, 3, 6, 7, 11, 12 | **Yes**: function first, then migration |
| **5** Nudge: app (D) | `feature/nudge` | RPC call and error mapping, `CompetitionClient.nudge`, nudge state, the control in the tally panel and under the freshness line, tally body copy, Riley fixture, one ci.yml UI test | 4 (in production before TestFlight) | 1, 2, 3, 6, 7, 11, 12 | No |
| **6** Widgets (C) | `feature/widgets` | `HealthCompWidgets` extension, App Group, points-only snapshot writer, AppIntent person picker, shared formatting helpers moved into `CompetitionDateFormatting.swift` | none | 1, 2, 3, 4, 5, 8, 11 | No (Apple portal: §7) |
| **7** Final-day Live Activity (C) | `feature/final-day-live-activity` | ActivityKit attributes and views, `MatchLiveActivityWidget` in the widget extension, planner and coordinator on `publish`, `NSSupportsLiveActivities`, DEBUG preview scenario. **No Account switch** (PR 13) | 6 | 1–5, 8–12 | No |
| **8** Block a challenger (D) | `feature/block-challenger` | Migration `…002600_add_account_blocks.sql`, three RPCs, block check in the shared create and both lookups, purge trigger, pgTAP 024, Deno race test, harness 27→28 and state baseline 19→20 tables; app: Decline and Block, ••• Block, Account BLOCKED | 4 merged (migration order) | 1, 2, 3, 5, 6, 7, 11, 12 | **Yes**: migration, Staging → production before TestFlight |
| **9** Reactions: server (D) | `feature/reactions-server` | Migration `…002700_add_competition_reactions.sql` (table, two RPCs, realtime wakeup, `reaction` push kind with hourly limit, `supports_reactions` and a 5-arg register overload), `reaction` kind in the function, pgTAP 025, harness 28→29 and state baseline 20→21, privacy page | 8 merged (migration order) | 1, 2, 3, 5, 6, 7, 11, 12 | **Yes**: function first, then migration |
| **10** Reactions: app (D) | `feature/reactions` | `CompetitionReactions.swift`, remote API and wire contract, client fetch/attach/set, picker in day drawers, result panel and REACTIONS list, unseen line on the match screen and Home, Test Lab fixture, one ci.yml UI test. **No Account switch** (PR 13) | 9 (in production before TestFlight) | 2, 3, 6, 7, 11, 12 | No |
| **11** Practice: pacer v2 (E) | `feature/practice-pacer-v2` | CompetitionCore `OpponentGeneratorVersion.v2` scaled to a baseline; v1 unchanged | none | everything | No |
| **12** Practice match (E) | `feature/practice-match` | Second `LocalCompetitionRuntime` in the remote coordinator, pace sheet from the empty Home, Practice labels, End Practice, exclusions everywhere, privacy sentence, Test Lab scenario, one ci.yml UI test | 11; 1 merged (history exclusion lands on the belt's helpers) | 2–10 | No (static `web/privacy.html`) |
| **13** Notification choices | `feature/notification-choices` | Account → Notifications with six switches (Lead changes, Close scores, Last day, Live Activity; Reactions, Nudges), planner suppression, Live Activity gate, `muted_push_kinds` registration; migration `…002800_let_installations_turn_off_push_kinds.sql`, pgTAP 026, harness 29→30, privacy line | 5, 7, 10 merged; 9 in production | 14 (built alongside) | **Yes**: migration, Staging → production before TestFlight |
| **14** What it takes: 7 PM reminder (B) | `feature/what-it-takes-reminder` | `what-it-takes` scheduled family, snapshot field from both projectors, one reminder per evening across matches, the seventh switch row | 3, 13 | — (last) | No |

**Sequencing**
1. **Start in parallel:** PR 1, PR 3, PR 4, PR 6 and PR 11 have no dependencies and touch different regions.
2. **Track A:** PR 1 → PR 2. The recap reads the belt event and mark.
3. **Track C:** PR 6 → PR 7. The Live Activity adds a widget to the extension PR 6 creates.
4. **Track D (server, strictly one at a time):** PR 4 → PR 8 → PR 9 → (PR 13's migration). Each server PR merges only after the previous one has merged, renumbers its migration if needed, copies the newest body of any function it replaces, and moves the recovery pins. PR 5 follows PR 4's production promotion; PR 10 follows PR 9's.
5. **Track E:** PR 11 → PR 12, after PR 1 so the practice exclusion lands on `competitionHistoryWeeks` with the belt already built on it.
6. **Track B:** PR 3 any time; PR 13 after PRs 5, 7 and 10; PR 14 last.

**Suggested global merge order** (keeps the hot files rebasing forward): 1, 3, 11, 4, 6, 2, 5, 7, 8, 12, 9, 10, 13, 14. Server promotions in that order too: PR 4 (function, then migration), PR 8, PR 9 (function, then migration), PR 13.

**Migration ordering** (provisional names; the date part is the merge date, the sequence must sort after every merged migration)

| Order | PR | Migration | Count at `test-recovery-migrated-snapshot.sh:31` | pgTAP | State baseline (tables / `rls_flag_mismatches` / FORCE) |
|---|---|---|---|---|---|
| 1 | 4 Nudge | `20261101002500_add_match_nudges.sql` | 26 → 27 | `023_match_nudges.test.sql`; `012` column list gains `nudge_day` | unchanged (19 / 18 / 7) |
| 2 | 8 Block | `20261102002600_add_account_blocks.sql` | 27 → 28 | `024_account_blocks.test.sql` | 19→20 / 18→19 / 7→8 (`private.account_blocks`) |
| 3 | 9 Reactions | `20261102002700_add_competition_reactions.sql` | 28 → 29 | `025_competition_reactions.test.sql`; `002` gains `supports_reactions` | 20→21 / 19→20 / 8→9 (`private.competition_reactions`) |
| 4 | 13 Notification choices | `20261103002800_let_installations_turn_off_push_kinds.sql` | 29 → 30 | `026_push_kind_switches.test.sql`; `002` gains `muted_push_kinds` | unchanged |

Each one also recomputes `manifest_hash` (`:9`) and appends its version to `recovery-migrated-fixture.sql:23-24`. Shared server regions, with the lineage each later PR copies:
- `competition_notification_work_kind_check`: PR 4 adds `'nudge'`; PR 9 restates the full list with `'nudge', 'reaction'`. PR 13 doesn't touch it.
- `competition_notification_work_identity_unique`: PR 4 rebuilds it with `nudge_day` (same name, `nulls not distinct`). PR 9's reaction enqueue uses it by name with `nudge_day` null.
- `lease_competition_notification_work`: PR 4 replaces it (copying 2300); PR 13 replaces it again, copying PR 4's body. PRs 8 and 9 don't replace it.
- `register_current_device_installation`: PR 9 adds the 5-argument overload (`supports_reactions`) and makes the 4-argument one delegate; PR 13 adds the 6-argument overload (`muted_push_kinds`) and makes the 5-argument one delegate. The app falls back 6 → 5 → 4 → 3 on PGRST202.
- `private.create_competition_invite_v2`, `resolve_challenge_link`, `resolve_invitation_recipient`: only PR 8. Any later replacement must copy PR 8's block check.
- `send-competition-notification`: PR 4 adds `"nudge"` and renames `challengeAlerts` → `genericAlerts`; PR 9 adds `"reaction"` to both. Deploy order for both: function first, then migration; never roll the function back past a kind that may be queued.

**Cross-feature rules** (whoever merges second applies them)
- **Practice guard** `!competition.isPractice` (property added by PR 12): recap Share Result gate (PR 2), nudge control gate in `MainTabView` (PR 5), widget snapshot builder (PR 6), Live Activity planner (PR 7). History weeks filter is PR 12's own.
- **Home cards.** `CompetitionHeroCard` gains `belt:` (PR 1) and `reaction:` (PR 10); `CompetitionSharingRow` gains `showsName`, `beltHolder` (PR 1) and `reaction` (PR 10). The live card's `competitionButton(caption:)` (VoiceOver only) is `[beltStanding, reactionA11y].compactMap { $0 }.joined(separator: ". ")`. Visible order in the hero card: status row, belt chip, scores, strip, then the reaction line. Status titles get the "Practice · " prefix (PR 12).
- **Result screen**, top to bottom: kicker ("Practice · Final · …" for practice, PR 12), title and score, belt banner (PR 1), reaction panel (PR 10), `.preservedHistory` label, Share Result (PR 2), inline rematch at AX sizes. Pinned: Rematch, or Challenge Someone for practice (PR 12).
- **Match screen**, top to bottom: scoreboard group with freshness line and the live nudge control (PR 5), the unseen-reaction line (PR 10), the tally panel with its nudge control (PR 5), the Today/Week picker; Today page: takes panel (PR 3) above the ring panel; day drawer: head-to-head row, reactions (PR 10), ring panel; ••• menu adds End Practice (PR 12).
- **`CompetitionNotificationMessage`** gains `beltTake` (PR 1) and `whatItTakes`, `matchTimeZoneIdentifier`, `matchDayEnd` (PR 14), all defaulted.
- **Account.** Account → Notifications is PR 13's page. Account root gets BLOCKED under YOUR CHALLENGE LINK (PR 8). `accountLiveMatchCount` excludes practice (PR 12).
- **`ci.yml`** `-only-testing` additions: `testBeltShowsOnHomeHistoryAndThePersonPage` (PR 1), `testShareResultPreviewsTheImageAndRemembersHideName` (PR 2), `testStaleMatchOffersOneNudgeADay` (PR 5), `testReactionsOnHomeMatchDayDrawerAndResult` (PR 10), `testPracticeMatchStartsFromEmptyHomeAndEndsFromTheMenu` (PR 12). Append-only conflicts.

**Files several PRs touch.** The PR that merges later (suggested order above) rebases; re-anchor by symbol, never by line number.

| File | PRs (merge order) | Regions |
|---|---|---|
| `HealthComp/Features/Competition/CompetitionSharingView.swift` | 1, 12, 10 | hero card, sharing row, record row, `CompetitionHomeRoute`, empty state, `competitionHomeLayout`, `competitionStatusText`, `competitionHistoryWeeks`, belt helpers |
| `HealthComp/Features/Competition/CompetitionResultView.swift` | 1, 6, 2, 12, 10 | inputs, body under the score, `resultKicker`, `rematchControl`, `hasMenuActions`, `competitionMarginText` (moves out in 6), week drawer |
| `HealthComp/Features/Competition/CompetitionDetailView.swift` | 3, 2, 5, 7, 12, 10 | `todayActivity`, `CompetitionDrawer` detents, tally panel and copy, scoreboard group, `competitionLeadText` (moves out in 7), ••• menu, `dayDrawer` |
| `HealthComp/Features/Competition/RemoteCompetitionClient.swift` | 6, 5, 7, 8, 12, 10, 13, 14 | `remote(...)` wiring, `publish` hooks, `reconcileNotifications`, `stop`, `performReconciliation`, notification projector |
| `HealthComp/Features/Competition/MultiUserCompetitionTestLabView.swift` | 1, 2, 5, 7, 8, 12, 10 | fixtures (ids in §4), scenario enum, `destination` |
| `HealthComp/Features/Competition/CompetitionFeature.swift` | 5, 8, 12, 10, 13 | State, Action, reducer, `stop` |
| `HealthComp/Features/Competition/CompetitionClient.swift` | 5, 8, 12, 10 | endpoints and init defaults |
| `HealthComp/Features/MainTab/MainTabView.swift` | 1, 5, 8, 12, 10 | route stack, destinations, result call site |
| `HealthComp/Features/MainTab/MainTabFeature.swift` | 1, 8, 12 | `historyPersonIdentity`, claim block, notification prompt |
| `HealthComp/Features/Account/AccountSettingsView.swift` | 8, 12, 13 | BLOCKED section, live count, Notifications page |
| `HealthComp/App/HealthCompApp.swift` | 6, 8, 13 | DEBUG widget sample, `AccountSheet` |
| `HealthComp/Services/CompetitionNotificationPlanner.swift`, `CompetitionNotificationModels.swift` | 1, 13, 14 | result candidate, `plan`, `opportunisticPlan`, scheduled families |
| `HealthComp/Services/CompetitionNotificationCoordinator.swift` | 13, 14 | preference read, snapshot copy |
| `HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`, `CompetitionRemoteAPI.swift` | 5, 8, 10, 13 | new RPCs, `classify`, `registerInstallation` fallback chain |
| `HealthComp/Services/CompetitionSyncModels.swift` | 10, 13 | `CompetitionInstallationRequest` and its validator |
| `HealthComp/Services/CompetitionNotificationClient.swift` | 6, 7 | `CompetitionRoute.url` (added in 6, reused by 7) |
| `HealthComp/Features/Competition/LocalCompetitionClient.swift` | 1, 12, 10, 14 | award `ponytail:` mark, projector parameters, `reactions` field, notification snapshot |
| `HealthComp/Features/Competition/CompetitionWeekChart.swift` | 6, 2 | `CompetitionDayOutcome`/bars (6), `competitionWeekText` `includesYear` (2) |
| `project.yml`, `project.pbxproj`, `HealthComp/Resources/Info.plist`, `Configuration/Staging-Info.plist` | 6, 2, 7 (+ pbxproj only: 10, 12) | regenerate after every rebase |
| `HealthCompUITests/MultiUserCompetitionUITests.swift`, `.github/workflows/ci.yml` | 1, 2, 5, 7, 8, 12, 10, 13 | append-only |
| `web/privacy.html` | 2, 8, 12, 9, 13 | different sections; one effective date per deploy |
| `supabase/functions/send-competition-notification/index.ts` and its test | 4, 9 | `workKinds`, `genericAlerts` |
| Recovery harness files | 4, 8, 9, 13 | count, hash, fixture list, state baseline |
| `supabase/tests/002_privacy_columns.test.sql` | 9, 13 | `device_installations` columns |
| `docs/runbooks/supabase-environments.md`, `competition-support.md` | 6, 4, 8, 9, 13 | new sections after "Challenge push capability" |

## 7. Owner actions

**Before work starts**
1. Answer the §8 questions or accept the defaults. Q-notifs-4 (server-held switches vs Apple's filtering entitlement) and Q-practice-1 (pacer v2) change a PR's shape. If Q-notifs-4 is answered "entitlement", request `com.apple.developer.usernotifications.filtering` for the Debug, Staging and Release bundle ids first.
2. Confirm Staging and production Postgres are 15 or later (`select current_setting('server_version_num')` ≥ 150000). PRs 4 and 9 use `UNIQUE NULLS NOT DISTINCT`.

**Apple developer portal (before the first signed build after PR 6 merges)**
3. Identifiers → App Groups: register `group.com.narenyenuganti.HealthComp` (production and Debug) and `group.com.narenyenuganti.HealthComp.staging`.
4. On App IDs `com.narenyenuganti.HealthComp` and `com.narenyenuganti.HealthComp.staging`, turn on App Groups with their group. Leave every other capability as it is.
5. Register explicit App IDs `com.narenyenuganti.HealthComp.widgets` and `com.narenyenuganti.HealthComp.staging.widgets` (team 23LUYD78QK), App Groups only, same group as the parent.
6. Regenerate the development and App Store profiles for both app App IDs and create profiles for both widget App IDs. At archive, confirm `PlugIns/HealthCompWidgets.appex` is signed with the `.widgets` profile and carries the same `CFBundleShortVersionString`/`CFBundleVersion` as the app, and bump both together from now on.
7. No new entitlement, capability or certificate for the Live Activity (PR 7) if PR 6 shipped first. App Attest allowlists, Supabase Apple Auth client ids and the APNs topic don't change.

**Server promotions** (each: Staging, smoke test with the two Staging accounts, then production through `docs/release/production-beta-checklist.md`, before any TestFlight build that calls it)
8. PR 4 Nudge: deploy `send-competition-notification` (with `nudge`) first, then migration 2500. Never redeploy a function version without `nudge`. Smoke test needs three calendar days on physical iPhones (PR 4/5 Verify).
9. PR 8 Block: migration only (runbook §4). Smoke test per PR 8 Verification step 6.
10. PR 9 Reactions: function (with `reaction`) first, then migration. Smoke test per PR 9/10 Verify step 5.
11. PR 13 Notification choices: migration. Manual checks per PR 13 Verify.
12. For each server PR, run the full migrated-snapshot recovery test (`bash scripts/test-recovery-migrated-snapshot.sh`) on an OrbStack Mac with supabase CLI 2.113.0, or the PR body says "not run". The VM, the Mac mini and CI can't run it.

**Website and App Store Connect**
13. Approve and deploy the `web/privacy.html` changes before the TestFlight build that needs them: result images and Photos add-only (PR 2), blocks (PR 8), reactions with a new effective date (PR 9, before its server merges), practice's 2-week read (PR 12), switched-off push kinds (PR 13). Confirm healthcomp.app/privacy is live each time.
14. Before submitting a build with reactions, review App Privacy in App Store Connect and add "Other User Content" (linked, App Functionality) if not declared.

**Previews and device checks**
15. Approve each PR's preview artifact (captures in light and dark, XS and AX5, next to the playbook mockup, deviations listed) before the PR opens. Every §9 section lists its captures.
16. Physical iPhone checks after TestFlight or on Staging builds: widget Lock Screen redaction and a cold-start tap (PR 6); practice keeps background HealthKit deliveries for real matches and the start/End Practice flow (PR 12, Staging build); the nudge push (PR 4/5); one 7 PM reminder (PR 14, with "What it takes" on); Live Activity on a real Day 7 (PR 7, optional).
17. Mention in the TestFlight notes that the 7 PM reminder is on by default (PR 14) and can be turned off in Account → Notifications.

## 8. Open questions

Merged across the ten specs, deduplicated and ranked: first the ones that change scope, privacy or the server, then product behavior, then look and copy. Each default is what §9 builds if the owner doesn't answer. Ids (`Q-<feature>-<n>`) are stable for replies.

### Decisions that change scope, privacy or the server

**Q-notifs-4** (Notification choices, PR 13). The mockup says server pushes (reactions, nudges) are hidden on arrival by the notification service. Without Apple's com.apple.developer.usernotifications.filtering entitlement, a notification service extension can rewrite a push but cannot drop it. How should switched-off server pushes be held back?
- **Default:** The server holds them back. Each installation sends the server-sent kinds you turned off (`device_installations.muted_push_kinds`), and the lease marks that work 'suppressed'. This is the mockup's own fallback ("a later migration can store the choice server-side"). The phone stays the source of truth: the server copy only lists switched-off push kinds, never Health values, and privacy.html says so.
- **Why it matters:** This is a privacy and product call. It puts a copy of two choices on the server and changes privacy.html. The entitlement route would instead need Apple's approval, a new extension target, an App Group, new provisioning profiles and `mutable-content` on every payload, and the server would still send pushes nobody sees.

**Q-practice-1** (Practice match, PR 11 and 12). Should the pacer really scale to your last 2 weeks (needs a CompetitionCore generator v2, PR A), or should practice ship first with today's fixed v1 paces?
- **Default:** Build v2 (PR A, small and Foundation-only). Fallback if PR A is cut: v1, with pace copy changed to "Easier days" / "Steady days" / "Harder days", because v1 is about 180–360, 260–480 and 360–600 points a day for everyone and "About half your usual rings" would be untrue.
- **Why it matters:** OpponentPlan v1 uses fixed point bands (OpponentPlan.swift:587-608). The mockup's copy only holds if the plan scales to a baseline.

**Q-notifs-3** (Notification choices, PR 13). Builds installed before this PR (1.0.2 and any build up to this PR) have no Nudges switch. Should they keep getting nudges?
- **Default:** Yes. The server stores an opt-out list (`muted_push_kinds`, empty by default), so builds without the switch keep getting nudges. Nudge exists to unstick a final score, and the person holding it up is the one most likely to be on an old build. Nudges use the `healthcomp.route.kind: competition` payload that every build opens. Whether reaction pushes reach builds that can't show reactions is the Reactions PR's capability gate, not this PR's.
- **Why it matters:** An opt-in list would silently withhold nudges from every build installed today. The challenge-push precedent (20261101002300) gated a push old builds couldn't show, and a nudge isn't one.

**Q-nudge-7** (Nudge, PR 4 and 5). Should nudges reach 1.0.2 installs (supports_challenges = false)?
- **Default:** Yes. 1.0.2 already handles the 'competition' route payload (the old score_update alert used the same keys) and syncs on foreground.
- **Why it matters:** The challenge kinds are gated because 1.0.2 can't show challenges. A match route is something it can show.

**Q-nudge-8** (Nudge, PR 4 and 5). Should the sender ever learn that the other person muted them or has no device registered?
- **Default:** No. Every successful call returns {nudged_at: now}, whether or not anything was stored or delivered. Muted rows are stored as 'suppressed'.
- **Why it matters:** Mute and sign-out are private. Returning a stored time only when rows exist would reveal whether the other person has a device.

**Q-takes-3** (What it takes, PR 3 and 14). Can the lock-screen reminder show ring amounts like '240 kcal of Move or 12 min of Exercise'?
- **Default:** Yes. It is a local notification built on this iPhone, and no value goes to the server or the other person. If you'd rather keep amounts off the lock screen, the body becomes '39% of your Move or Exercise ring.'
- **Why it matters:** These amounts come from your goals, and the privacy rule keeps exact Health values on the iPhone. A local notification stays on the phone, but anyone near a locked phone can read it, and iOS may mirror it to your Apple Watch.

**Q-widgets-2** (Home Screen and Lock Screen widgets, PR 6). Should names also be hidden on the Lock Screen while the phone is locked, or only the numbers?
- **Default:** Names, numbers and any status that contains a name ("Sam won") are privacySensitive, so iOS redacts them under its own setting. Status words without a name ("Day 5", "Final") stay visible. The VoiceOver label drops names and points while redacted.
- **Why it matters:** The mockup says the Lock Screen follows the system setting. On a locked phone, a rival's name can be as personal as the score.

**Q-recap-1** (Recap card, PR 2). On someone's first share, should the card show the other person's name or hide it?
- **Default:** Show {Name}, as in the mockup. After that, this iPhone remembers the choice.
- **Why it matters:** The card can travel well beyond the two people in the match. Hiding the name by default is more private but makes the first card less personal. The privacy policy update says the sharer can hide the name.

**Q-recap-6** (Recap card, PR 2). For a match against a deleted account ("Former competitor"), should Share Result show at all?
- **Default:** Yes, but the name is always hidden ("Them"/"They") and the Show/Hide choice isn't shown.
- **Why it matters:** "Former competitor won" would tell outsiders that the person deleted their account, and the privacy policy says the label doesn't make a person unidentifiable. Hiding Share Result entirely would also be acceptable.

**Q-block-2** (Block a challenger, PR 8). Should a block go both ways? And should it lift by itself when the blocker challenges the blocked person?
- **Default:** One-way, and it stays until the blocker taps Unblock in Account. The blocker can still challenge the blocked person. The UI promises only what's true: 'They aren’t notified.' The contract doc lists, as accepted limits, that a pair who plays again (or a rematch, or a fresh link from the blocker) lets the blocked person infer the block. Pair conflicts (incoming_challenge_exists, active_match_exists, pending_invitation_exists) are checked before the block, so they read the same as for anyone else.
- **Why it matters:** The alternative is (a): when the blocker sends a challenge to the blocked person, delete the block (one SQL statement in the create). That removes most inference cases but silently empties a list the person built. (b) is the smaller rule, and it never claims secrecy it can't keep.

**Q-block-1** (Block a challenger, PR 8). When someone you blocked rematches you from an old result, what should they see? Today they would see '{Name} isn’t on HealthComp anymore.'
- **Default:** Change InviteCreationFailure.recipientGone to 'You can’t challenge {Name}.' It's one string and one test expectation. It's true for a block and for an account that is being deleted. It does not hide the block: on a rematch, a named past opponent who refuses can only mean a block. The reset-link rule skips rematches (2400:216), and a fully deleted account shows as 'Former competitor'. This limit is listed in the contract doc.
- **Why it matters:** No wording can hide a block on the rematch path short of faking a successful send, which this round doesn't do. The old line is also false about an active account. Installed older builds keep showing the old line (compatibility table).

**Q-block-3** (Block a challenger, PR 8). Does App Review's user-generated-content rule (guideline 1.2) also need a Report action this round?
- **Default:** No. Blocking ships alone. The only user content is display names in private one-to-one matches, and the support email already exists.
- **Why it matters:** Guideline 1.2 asks UGC apps for block, report and a contact. Blocking covers the first. A report flow would need a server queue and a support process.

**Q-block-4** (Block a challenger, PR 8). Should the privacy policy mention blocks?
- **Default:** Yes. Add one sentence to the 'Controls, deletion, and retained history' section of web/privacy.html: 'You can block someone from a challenge they sent you. Blocks are stored with your account, aren’t shown to the blocked person, and are removed when either account is deleted.' The effective date stays the same unless the owner wants it bumped.
- **Why it matters:** A block is a new server record that links two accounts. The Controls section lists what is kept and what is purged.

**Q-practice-9** (Practice match, PR 11 and 12). Does web/privacy.html need a sentence for practice?
- **Default:** Yes. Under "Activity on your iPhone" add: "A practice match also reads your last 2 weeks of Activity on your iPhone to set the pacer; practice data is never sent." and move the effective date to the ship date.
- **Why it matters:** The policy says Activity is read "to calculate competition scores" between two people; setting a pacer from 14 prior days is a new on-device use.

**Q-practice-2** (Practice match, PR 11 and 12). Should a practice match post local notifications (Day 1 reminder, last day, result), or trigger the notifications permission prompt?
- **Default:** No to both. Practice posts nothing, is never added to the notification snapshot, has no Mute row, and doesn't count as "a match with a person" for the notifications prompt. The prompt waits for the first real match.
- **Why it matters:** The remote notification coordinator plans from server materializations only. The prompt (MainTabFeature.swift:858-883) would otherwise ask for notifications practice never sends, and Not Now defers it for the first real match too (:834-840).

**Q-practice-5** (Practice match, PR 11 and 12). Signing out deletes the practice match, because it lives in the profile's on-device folder. Should the sign-out confirmation say so?
- **Default:** No new copy. Practice is left out of the live-match count, so the message is unchanged for real matches.
- **Why it matters:** Profile teardown removes the whole profile root (AuthenticatedProfileStorage.swift:209-241). Mentioning practice would add a sentence for a minor loss.

**Q-reactions-5** (Reactions, PR 9 and 10). Should reactions from someone who later deleted their account stay with the match?
- **Default:** Yes, the same as their scores and results. A received reaction keeps showing, including on a 'Former competitor' result. You can't send a new one to a 'Former competitor'.
- **Why it matters:** Account deletion anonymizes the profile but keeps competition history. The privacy page is updated to say so.

**Q-reactions-1** (Reactions, PR 9 and 10). Should the app tell you when the other person's app is too old to see reactions?
- **Default:** No. Your reaction saves, they see it once they update, and they get no push meanwhile. Telling you would mean exposing their install capability to you.
- **Why it matters:** An older build has no reaction UI and is excluded from reaction pushes (supports_reactions false), so a reaction sent to someone on an old build goes unseen until they update.

**Q-reactions-6** (Reactions, PR 9 and 10). Is the push limit acceptable as at most one per hour per match per recipient, and also silent when no new score or result has reached the server since the last reaction push for that match?
- **Default:** Yes. The second condition comes from the existing work-row identity (competition, server_seq, kind, recipient, installation). During a live week scores upload several times a day, so it rarely bites.
- **Why it matters:** Any other limit means changing the durable work table's identity constraint, which existing functions reference by name.

**Q-live-1** (Final-day Live Activity, PR 7). When should the Live Activity start? The mockup says the first refresh on Day 7. But iOS ends a Live Activity 8 hours after it starts, and after that it can't be updated. iOS then leaves it on the Lock Screen, frozen, for up to 4 more hours. It can only start while HealthComp is open.
- **Default:** Start on the first refresh with HealthComp open during the last 7.5 hours of Day 7, from 4:30 PM match time. The card always reaches midnight while iOS still counts it as running. At midnight it switches to "Final score pending" without the app (staleDate), and iOS ends it at most 7.5 hours later. Midnight is effectively the end of the card. It never shows the result.
- **Why it matters:** If it starts at 9 AM, iOS ends it at 5 PM, before the finish the feature is for. With a full 8 h window, a 4:00 PM start would end exactly at midnight and could freeze with the live look. Nothing prompts people to open the app between 4:30 PM and midnight: the only Day 7 notification ("Last day") fires at the start of Day 7 (CompetitionNotificationPlanner.swift:561-577). Many close matches will therefore never show a card. The alternative is to start on the first Day 7 open and accept that a morning start ends in the afternoon, or to add a new local nudge later in the day (a separate feature).

**Q-live-3** (Final-day Live Activity, PR 7). Should muting someone also stop the Live Activity for matches with them?
- **Default:** No. The Live Activity has its own switch, and mute stays about notifications.
- **Why it matters:** This is a product choice, not a cost choice. Every notification reconcile already reads the muted set (CompetitionNotificationCoordinator.swift:238-246), and that last read could be reused at no extra network cost. The mute footer ("Muting someone silences all your matches with them.") might lead someone to expect the person's name to stay off their Lock Screen. If the owner says yes, the planner gets a `muted: Set<String>` input taken from the coordinator's last read.

**Q-live-2** (Final-day Live Activity, PR 7). If the result arrives while the card is still running (only possible for a card started late in the evening, after the final tally), should the card show the result?
- **Default:** No. The card ends right away (dismissal .immediate), and the existing result notification announces the result.
- **Why it matters:** iOS's 8 h cap makes this case rare, because the final tally usually settles after the card has stopped updating. A result phase would add a state, copy and tests for a screen almost nobody would see.

### Product behavior (defaults built; answer only to override)

**Q-belt-1** (Belt and a page per person, PR 1). Should a tie extend the holder's reign count?
- **Default:** Yes. A reign counts every finished match in a row since the holder took the belt, ties included, because a tie leaves the belt where it is.
- **Why it matters:** The playbook says both "a tie leaves it where it is" and "a reign counts finished matches in a row". The answer changes the week counts on the record row's VoiceOver text, the 3+ week banner gate, "Since … · N weeks" and "Longest reign".

**Q-belt-2** (Belt and a page per person, PR 1). Should the result notification add the belt sentence on a first win too?
- **Default:** Yes, on every take, as the playbook states with no condition. "You took the belt from {Name}." when you take it from them, "You took the belt." on your first win, and "{Name} took the belt." when they take it (first win or from you). No sentence on a kept week, a tie, or a Former competitor match.
- **Why it matters:** The alternative is to add the sentence only when the belt moves between the two people. That gives shorter first-result notifications, but then the notification and the result screen ("You took the belt") disagree on every pair's first result.

**Q-belt-3** (Belt and a page per person, PR 1). Should the result screen show a banner on every kept week, not only from 3 weeks?
- **Default:** No. The banner shows when the belt is taken, and on a kept week only once the reign reaches 3 weeks ("You kept the belt" / "3 weeks in a row."). This is the playbook's rule for the recap's belt line, so both surfaces follow one rule.
- **Why it matters:** The mockup shows only the change-of-hands banner. A banner on every kept week (and every tie) adds a panel to most result screens.

**Q-recap-7** (Recap card, PR 2). After a tie, should the card ever show a belt line ("Kept the belt · 4 weeks")?
- **Default:** No. A tie shows no belt line. The belt line shows only when the belt changed hands, or when the winner of this match kept it with a reign of 3 or more weeks.
- **Why it matters:** The playbook says "A tie leaves it where it is". "Kept the belt" under "All square" suggests a defense that didn't happen. Whether a tie adds a week to the reign is the belt PR's call.

**Q-recap-4** (Recap card, PR 2). Can simulated matches be shared (the DEBUG fixture now, Practice match if it ships)?
- **Default:** No. Share Result shows only when source == .remoteParticipants.
- **Why it matters:** A card from a match against a simulated person would pass as a real result.

**Q-recap-5** (Recap card, PR 2). Should the comeback and perfect-day highlights also cover the other person ("Sam came back from 86 down")?
- **Default:** No. Comeback means you won after trailing. Perfect day means your own 600 days.
- **Why it matters:** The card tells the sharer's story. Covering both people doubles the copy and the test cases for little gain.

**Q-recap-2** (Recap card, PR 2). Should the card follow the phone's appearance, or always be light?
- **Default:** Always light: ImageRenderer gets .environment(\.colorScheme, .light), whatever the phone's appearance.
- **Why it matters:** A shared image should look the same everywhere and match the website. A dark card would only differ for people who use dark mode.

**Q-recap-3** (Recap card, PR 2). Keep the plain-text 'healthcomp.app' footer on the card?
- **Default:** Yes. It is plain text, not a link and not a challenge link.
- **Why it matters:** The mockup shows it, and it's how people who don't use HealthComp find the app.

**Q-recap-8** (Recap card, PR 2). Should the in-app consent row ("{Name} sees your daily points and rounded ring percentages") also say that a result image can be shared?
- **Default:** No change to the consent row. Only web/privacy.html gains a sentence.
- **Why it matters:** The row describes what the other person sees, and that doesn't change. Changing it would also break the exact-string checks in testRemoteInvitationDisclosesSharedDerivedActivity and testHealthOnboardingDisclosesSharedDerivedActivity.

**Q-takes-1** (What it takes, PR 3 and 14). Should the evening reminder be on by default?
- **Default:** On. PR 13 starts every switch on (its Q7), and PR 14 adds the "What it takes" row, so the reminder can always be turned off. Merged with Q-notifs-7.
- **Why it matters:** With On, everyone who is behind gets a nudge at 7 PM each evening after they update. The playbook calls it 'optional', and a nightly nudge is the kind of chattiness Notification choices exists to stop. The owner's mockup still shows it on, so this spec doesn't override that.

**Q-takes-2** (What it takes, PR 3 and 14). When should the reminder fire?
- **Default:** 7:00 PM in the match's time zone (`schedule.calendar`), the same zone the 9:00 Final day reminder uses. If the phone first plans after 7 PM, there is no reminder that day.
- **Why it matters:** The mockup lock screen shows 7:02. The match day ends at midnight in the match zone, so the time has to come from that zone.

**Q-takes-4** (What it takes, PR 3 and 14). Should the panel show when the score is level, including 0–0 on Day 1?
- **Default:** Yes, as the playbook says ('behind or level'): '1 to take the lead'. It only appears once today's reading has been accepted, so a 0–0 before the first sync shows nothing.
- **Why it matters:** At 0–0 every new match would open with this line, which can feel like a nag.

**Q-takes-5** (What it takes, PR 3 and 14). On Days 1–6, should a gap that's too big for one day still say 'Out of reach today'?
- **Default:** Yes, as written. The headline names today, and the detail gives the gap and the points Move and Exercise can still add today.
- **Why it matters:** On Days 1–6 the lead can still be won on later days, so some people may read 'Out of reach' as 'lost'. The other option is to hide the panel before Day 7 when the gap is out of reach.

**Q-takes-6** (What it takes, PR 3 and 14). Should Stand count toward what's still reachable today?
- **Default:** No. Stand is never suggested and never counted. The panel is reachable only when Move and Exercise can cover the gap. The out-of-reach line says '…you have 110 points left in Move and Exercise today.' instead of the mockup's '…210 points left before today's cap.'
- **Why it matters:** The playbook says 'one or two rings'. Stand hours follow the clock: at 7 PM a 12/12 Stand ring can't reach 200% before midnight, so counting its room would call a gap reachable when it isn't. The mockup's 210 counts 100 Stand points that need 12 more stand hours.

**Q-notifs-1** (Notification choices, PR 13). The mockup labels the row "Final day". The notification it controls is titled "Last day", and so is the shared status (CompetitionSharingView.swift:1437). Which label should the row use?
- **Default:** "Last day". In code the case stays `finalDay` / raw value `final-day`, matching CompetitionScheduledNotificationFamily.finalDay.
- **Why it matters:** §5 of the audit spec: the same thing gets the same words. A switch named differently from the notification it silences is harder to find.

**Q-notifs-2** (Notification choices, PR 13). Four app notifications are in neither the mockup's switch list nor its always-on list: "600 today" (dailyMaximum), "Day 1 of 7" (scheduledStart), "Final score pending" (competitionEnded) and "Match update" (catchUp). Should any of them get a switch?
- **Default:** No. All four stay on and unlisted. Match update also stops firing when the only missed moments belong to families you switched off.
- **Why it matters:** Adding a row later is one enum case plus one mapping line.

**Q-nudge-1** (Nudge, PR 4 and 5). Push text: the mockup body says 'Open HealthComp so your match can finish.' That's untrue for a live match that isn't finishing. Use one text for both cases?
- **Default:** Title 'Score update needed', body 'Open HealthComp to update your match.' The same text in both phases, with no name (Q3).
- **Why it matters:** The worker knows only the kind and the match id. One generic string keeps the server simple and is true in both phases.

**Q-nudge-2** (Nudge, PR 4 and 5). During a live match there is no tally panel. Where does the Nudge button go?
- **Default:** Directly under the freshness line ('You: updated … · Sam: updated …') in the scoreboard group, using the same control as the tally panel.
- **Why it matters:** The mockup shows only the tallying case. The freshness line gives the context for why the button is there.

**Q-nudge-3** (Nudge, PR 4 and 5). The #190 tally bodies for the two waiting-on-them states begin with 'Nothing for you to do.' Should they change now that a Nudge button sits under them?
- **Default:** Drop 'Nothing for you to do.' from those two bodies only (always, not only while the button shows). They become 'If {Name} doesn’t sync by {deadline}, the result uses what’s in.' and 'If {Name} doesn’t open HealthComp by {deadline}, the result uses what’s in.' Keep the shipped headlines.
- **Why it matters:** Telling you there's nothing to do and then offering an action contradicts itself. No UI test asserts these two states (they occur only on real matches). Two assertions in CompetitionPresentationTests change. The mockup's 'Waiting on…' headline would churn more for no behavior gain.

**Q-nudge-5** (Nudge, PR 4 and 5). Is 'once per day' the match calendar day (the match's time zone) or a rolling 24 hours?
- **Default:** The match calendar day, (now at time zone competitions.time_zone_identifier)::date, plus at least 12 hours since your previous nudge. An 11:59 PM nudge followed by a 12:00 AM nudge is therefore one push, not two.
- **Why it matters:** This matches the copy 'You can nudge again tomorrow' and the server's existing date logic, and it stops two pushes a minute apart across midnight. A viewer in another time zone may see 'tomorrow' arrive a few hours early or late.

**Q-nudge-6** (Nudge, PR 4 and 5). In a live match where the other person has never uploaded, the freshness line is empty. Should the button get a line of context?
- **Default:** No new copy. The button shows on its own, and the Day strip already shows that they have no score yet.
- **Why it matters:** Adding '{Name} hasn’t updated yet' would change competitionFreshnessText for every match. The common case (a stale upload) has the freshness line, and the UI test now covers that case.

**Q-widgets-1** (Home Screen and Lock Screen widgets, PR 6). When you pick a person in the widget and you have no live, scheduled or recent match with them, what should it show?
- **Default:** "No match with {Name} right now." when that person is still in the current snapshot. Otherwise "No match with this person right now.". The widget never shows a name stored in the widget configuration, and it never falls back to another person's match.
- **Why it matters:** Falling back silently would show a different person than the one you picked. A stored name could belong to a previous account on this phone, or to someone who has since deleted their account.

**Q-widgets-3** (Home Screen and Lock Screen widgets, PR 6). What should tapping the empty widget do?
- **Default:** It just opens the app, with no deep link. No route opens the Challenge sheet today, and adding one is out of scope.
- **Why it matters:** Opening the Challenge sheet straight from a widget would need a new CompetitionRoute case and MainTabFeature handling.

**Q-widgets-4** (Home Screen and Lock Screen widgets, PR 6). When nothing is live but a challenge to you is waiting, what does the empty widget say?
- **Default:** Title "Nothing live right now", line "A challenge is waiting." in place of "Challenge someone". The snapshot carries one Bool, with no name and no count.
- **Why it matters:** Telling you to challenge someone while a challenge waits for your own answer points you the wrong way. A Bool keeps the challenger's name off the widget.

**Q-widgets-5** (Home Screen and Lock Screen widgets, PR 6). The mockup's small widget has a lead line and no update time. The behavior rule says the widget always shows when it was updated. Which wins?
- **Default:** The update time always shows, as the footer. The lead line sits above it only when it fits (ViewThatFits drops it at large text sizes).
- **Why it matters:** At large Dynamic Type sizes, systemSmall can't always fit both.

**Q-widgets-6** (Home Screen and Lock Screen widgets, PR 6). Should the medium widget label each number ("YOU", "SAM") even though the mockup doesn't?
- **Default:** Yes. It adds small themeLabel captions above both numbers, like HeroScoreboard does.
- **Why it matters:** Without labels, amber against ink is the only cue for whose number is whose. That fails color-blind and tinted-mode readers.

**Q-widgets-7** (Home Screen and Lock Screen widgets, PR 6). Should the belt glyph from the mockup appear on the widget?
- **Default:** Not in this PR. The belt PR adds it to the snapshot and the views once it ships.
- **Why it matters:** The belt is a separate, unmerged feature. Leaving it out keeps this PR independent.

**Q-practice-3** (Practice match, PR 11 and 12). Should a finished practice appear anywhere in History, unrecorded?
- **Default:** No. The result shows on Home under Recent results for the usual 3 days (no swipe Archive, no 'Moves to History' caption), then its journal is deleted from the phone. It is never in History, the record, awards, the belt or the recap.
- **Why it matters:** The playbook rule 'Not counted in History's record' leaves open whether the week is listed at all. Leaving it out is the smallest correct reading, and deleting it then keeps no hidden Health values.

**Q-practice-4** (Practice match, PR 11 and 12). Is the empty Home the only way in, and in which variant?
- **Default:** Only the "No matches yet" empty Home (no finished real weeks). "Nothing live right now" stays as today, with no Practice Match. Not in Account or the + sheet.
- **Why it matters:** The mockup shows only the first-time variant, and the feature fixes f-welcome. Finished practices never count as records, so a user who only practiced still sees it.

**Q-practice-6** (Practice match, PR 11 and 12). What pacer baseline applies to new or very inactive users?
- **Default:** 300 points a day (every ring closed) when fewer than 3 of the last 14 days scored. The baseline is clamped to 100...600 a day, so 'Relaxed' is never trivial (at least about 45 points a day).
- **Why it matters:** A user with no Health history would otherwise get a pacer that scores 0.

**Q-practice-8** (Practice match, PR 11 and 12). Should a live practice ever be the big hero card while a real match is scheduled or live?
- **Default:** No. A real match always takes the hero; the practice shows as a LIVE card or UP NEXT row. Practice is the hero only when it is alone.
- **Why it matters:** competitionHomeLayout (CompetitionSharingView.swift:1645-1649) makes any single live match the hero, so a live practice would push a real scheduled match down to a row.

**Q-reactions-2** (Reactions, PR 9 and 10). Show an unseen reaction on the match screen too, not only on Home and in that day's drawer?
- **Default:** Yes. While a received day reaction is unseen, one tappable line sits under the scoreboard and opens that day's drawer. It goes away once you leave the match screen.
- **Why it matters:** The 'New reaction' push opens the match screen, and the push doesn't name the day. Without this line, the reaction is behind Week > Day n with no hint which day.

**Q-reactions-3** (Reactions, PR 9 and 10). Should you be able to react to days after the result is in?
- **Default:** No. Day reactions close when the result lands, in the app and on the server. The result itself can still be reacted to.
- **Why it matters:** The result screen's week chart opens no day drawers. Allowing day reactions there means adding day drawers to the result screen.

**Q-reactions-4** (Reactions, PR 9 and 10). Should the 'New reaction' push have a body?
- **Default:** Title only: 'New reaction'. This matches 'Challenge declined' and 'Match cancelled'.
- **Why it matters:** The copy should be minimal, and server pushes stay generic with no names (Q3 default).

**Q-reactions-7** (Reactions, PR 9 and 10). Should the Reactions switch be per iPhone rather than per account?
- **Default:** Per iPhone, through PR 13: the Reactions switch adds `reaction` to this installation's `muted_push_kinds`, and the lease suppresses it. `supports_reactions` stays a capability flag only.
- **Why it matters:** There is no Notification Service Extension. Hiding a remote alert on arrival needs Apple's filtering entitlement, so the switch has to reach the server somehow. The install flag is the smallest way.

**Q-block-5** (Block a challenger, PR 8). Should the BLOCKED list sit inline on Account (as in the mockup), or behind one 'Blocked' row that opens its own page?
- **Default:** Inline, directly under YOUR CHALLENGE LINK, as the approved mockup shows. It appears only when the list isn't empty, with no load-error row and no retry. In practice it holds one or two names.
- **Why it matters:** Account's own comment (AccountSettingsView.swift:95-96) prefers a page per setting, and Muted lives on a pushed page. But the challenge link section is already inline, and the owner approved the inline mockup.

### Look and copy

**Q-belt-4** (Belt and a page per person, PR 1). The mockup's result banner has a light-amber fill (#FFF3D6) that isn't a Theme token. Add a tint token?
- **Default:** No. The banner uses themePanel. The holder's color is carried by the title text (Theme.you or Theme.ink) and the mark's plate. The mark's inner square uses Theme.ground instead of #FFF3D6.
- **Why it matters:** The design-system rule says no new colors. The Home chip needs no decision: the mockup's Home chip is the plain .chip (ground fill, hairline border), which Theme.ground and Theme.hairline already match.

**Q-notifs-5** (Notification choices, PR 13). Toggle color. The page tints everything `Theme.ink` (accountPageStyle, AccountSettingsView.swift:823-827). In dark mode ink is #F5F5F0, so an On switch is a white thumb on a near-white track. The app has no Toggle today to compare against.
- **Default:** Use the system switch green from the mockup (#34C759, `Color(uiColor: .systemGreen)`), set with `.tint` on the toggle only. It is the platform's control color, not a new Theme token.
- **Why it matters:** Theme.ink loses the thumb in dark mode. Theme.secondary in dark (#A3A3A8) is about 2.5:1 against the white thumb and reads as disabled. The dark capture of an On switch on the preview artifact settles it.

**Q-nudge-4** (Nudge, PR 4 and 5). Button look: the mockup draws a small left-aligned ink pill (.btn-sm). SecondaryButtonStyle is a full-width block with a 54 pt minimum height. Which one?
- **Default:** Match the mockup: a compact Theme.ink capsule with Theme.onInk text (the same look as the shipped 'Review' mark in CompetitionSharingView), left-aligned, with a 44 pt minimum hit area. No new colors.
- **Why it matters:** The live placement repeats on every stale live match. A full-width 54 pt block between the lead statement and the Today/Week picker is heavy. The preview captures show both placements for approval.

**Q-practice-7** (Practice match, PR 11 and 12). The mockup marks the selected pace with an amber dot. Use amber, or ink?
- **Default:** Ink checkmark.circle.fill, because amber marks you on scoreboards and a selection isn't you.
- **Why it matters:** Theme rule: amber = you. The preview artifact will show ink, so the owner should know it differs from the mockup.

**Q-belt-5** (Belt and a page per person, PR 1). Gate the new local-lifecycle assertions in PR CI by adding testOutgoingCompetitionCompletesTheSevenDayLifecycle to ci.yml?
- **Default:** No. The Mac mini `ui` run of both full UI classes is the gate for those assertions before the PR opens. CI time stays as it is.
- **Why it matters:** ci.yml runs an explicit list that has no LocalCompetitionLifecycleUITests. So the banner, record-row and person-page assertions in that class run only on the Mac mini.

### Answered or merged by this document

- **Q-notifs-6** (Q6. Build order. The playbook puts notification choices after What it takes, Nudge, the Li…): Answered by this document's plan (§6): Notification choices lands after Nudge, Live Activity and Reactions with six rows, and PR 14 adds "What it takes".
- **Q-notifs-7** (Q7. The playbook calls the What it takes evening reminder "Optional". Should its switch st…): Merged into Q-takes-1.

## 9. PR sections

One section per feature, in track order. A feature split into two PRs (server and app, or core and app) has one section that names which part belongs to which PR. Each section starts with its integration amendments, which override the reviewed spec text that follows. Line numbers are from `main` at 8c5ca25; re-anchor by symbol after rebasing.

### 9.1 PR 1: Belt and a page per person

Branches: `feature/rivalry-belt` · Server: no · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **Practice (PR 12).** Practice never reaches the notification snapshot, so the planner's `beltTake` needs no filter. The only exclusion is PR 12's `!$0.isPractice` in `competitionHistoryWeeks`, which records, History, the person page and `competitionBeltEvent` all read. The Risks bullet asking for two exclusion sites is superseded.
- **Shared with PR 2.** `CompetitionResultView`'s input is `beltEvent: CompetitionBeltEvent?` at both call sites, and `CompetitionBeltMark` stays internal so the recap card can draw it. PR 2 maps the event with its own adapter (PR 2 amendments).
- **Home caption.** `standing` is the first part of `competitionButton`'s VoiceOver caption; PR 10 appends its reaction text with ". " (§6 cross-feature rules).
- **Fixture id.** `jordanPastID = …0009` is the id allocated in §4 (`…0008` is `expiredRecipientID`). PR 2 adds Casey (`…000A`), who then holds the belt as "them" on Home and in History; no belt assertion reads Casey.
- **Widgets.** No belt on widgets this round (Q-widgets-7), so the fold stays in the app target.

#### PR scope
- `feature/rivalry-belt`: One app-only PR. Adds a belt fold next to competitionOpponentRecords, with its text helpers and a belt mark view. The fold orders weeks itself (schedule end, then id), so History and the notification planner can't disagree. Adds a chip to Home live and scheduled cards (hidden while an earlier match with the same person is unfinished). Adds a result banner that replaces the AWARDS list (Q12), shown when the belt is taken or a reign reaches 3+ weeks. Adds a belt mark and VoiceOver text on History record rows, and a page per person pushed from CompetitionRecordRow (Q18) through a new CompetitionHomeRoute.person case and MainTabFeature state. Adds one sentence to the app's local result notification on every take. Updates the unit, UI and planner tests, adds one MultiUser UI test to ci.yml, and adds one ponytail marker in LocalCompetitionClient.swift. No new Swift files, no project.yml or pbxproj change, no server change.

Branch `feature/rivalry-belt` · base `main` at 8c5ca25 · app only (no migration, no Edge Function, no project.yml or pbxproj change) · size M

#### Scope
- **One belt per pair.** A pure fold over the pair's finished matches, computed on the phone from the same weeks History already lists. It sits in `CompetitionSharingView.swift` next to `competitionOpponentRecords` (:1814), as the playbook's build note asks ("one helper next to `competitionOpponentRecords`"). The fold also orders the weeks itself, so every caller gets the same order. Nothing new is stored, uploaded or shared.
- **Home:** a chip on the live (and scheduled) card says who holds the belt going in.
- **Result:** a belt banner sits under the final score. It **replaces the AWARDS list** ("Victory Over {Name}"). This answers owner Q12: the belt is the award.
- **History:** each record row gets a belt mark and VoiceOver text, and becomes a link.
- **A new page per person** opens from `CompetitionRecordRow`. This answers owner Q18: a new route, `CompetitionHomeRoute.person`.
- **Result notification:** the app's local result notification adds one sentence whenever the belt is taken (Q-b).
- **Shared with the recap PR:** `competitionBeltEvent(for:in:)` and `competitionBeltResultText`. Nothing about the recap is specified here.
- **Not in scope:**
  - stakes of any kind (rejected by the owner)
  - a belt on the match (detail) screen, on Home's History button, on History's week rows, or in widgets

#### Rules (answered from the code)
| Rule | Code fact it rests on |
|---|---|
| Only finished matches count. Cancelled matches and expired or declined challenges don't. | `competitionHistoryWeeks` (:1797) keeps only `terminalResult != nil`, which is set for `.completed` and `.archived` only. The planner uses the same test on `CompetitionNotificationCompetitionSnapshot.terminalResult`. |
| The winner is the decided outcome, 2-decimal tiebreak included. | Uses `terminalResult.outcome`, the same value `competitionResultTitle` and the W/L/T chip use. Points are never compared again. |
| A pair is the other person's identity, not their name. | `opponentIdentity` (`remote-profile:v1:<uuid>`, or `local-opponent:v1:default` in the fixture). A rename keeps the belt. |
| Order: schedule end, oldest first; then competition uuid ascending. | `competitionBelt` sorts its input by `(end ?? .distantPast, id.rawValue.uuidString)`. Callers pass `competitionScheduleBoundaries(schedule)?.end`. completedAt is left out, because the notification snapshot doesn't carry it (`CompetitionNotificationModels.swift:74-78`). Both phones see the same server ids and schedules, so they get the same order. |
| Weeks can share an end, and each one counts. | The one-match-per-pair rule (`private.match_in_progress_between`, `20261101001900_add_challenge_links_and_responses.sql:45-65`) landed on 2026-11-01. Beta history from before it can hold overlapping matches with the same person. They are ordered by uuid, and each counts as one week of a reign ("a reign counts finished matches in a row, shown as weeks"). History's display order for equal ends (completedAt, then uuid) can differ. That changes only the row order, never a belt mark, because marks are looked up by id. |
| The first decided week's winner takes the belt. Ties before that leave nobody holding it. | The fold below. |
| A win by the holder, or a tie, keeps it. A win by the other person takes it. | The fold below. |
| A reign counts finished weeks in a row since the holder took it, ties included (Q-a). | The fold below. |
| "Title changes" counts every week the belt went to someone new, the first win included. | Derived from the approved mockup. Its "3–3" over 6 weeks has Sam winning the three visible weeks Oct 12–Nov 1 (Longest reign: Sam · 3 weeks). So the two hidden earliest weeks are your wins. Your first win, then Sam taking it, then you taking it back gives the mockup's "3". Counting only moves between the two people would give 2. |
| **Retired:** the other person deleted their account. | A DB check pins the display name: `profiles_identity_state_check` (`20260811000100:120-133`). The client enforces the same rule: `CompetitionParticipantDescriptor.init` (`HealthComp/Services/CompetitionSyncModels.swift:757`) requires anonymized ⇔ "Former competitor". The profile id survives deletion (`20260811000750:559-568`), so the person's weeks still group under one identity. The belt is retired when the record's newest name is the reserved literal "Former competitor". |
| "Going in": the chip waits while an earlier match with the same person is unfinished. | `match_in_progress_between` ignores a match once its local date is past Day 7 (`:60-62`). So match N+1 can be scheduled or live while match N is still `tallying`, and N's result could still move the belt. |

#### Behavior

##### Exact copy
| Where | Condition | Text |
|---|---|---|
| Home chip (shown uppercase via `.textCase(.uppercase)`) | holder is you / them, and no earlier unfinished match with that person | "You hold the belt" / "{Name} holds the belt" |
| Home card VoiceOver | same | the existing summary + ". You hold the belt" / ". {Name} holds the belt" |
| Result banner title | `.took(.you, _)` / `.took(.them, _)` | "You took the belt" / "{Name} took the belt" |
| Result banner detail | `.took(.you, fromWeeks: n)` / `.took(.them, fromWeeks: n)` | "{Name} held it for {n week(s)}." / "You held it for {n week(s)}." |
| | `.took(_, fromWeeks: nil)` (first win) | no detail |
| Result banner | `.kept(.you, n)` / `.kept(.them, n)` with n ≥ 3 | "You kept the belt" / "{Name} kept the belt", + "{n} weeks in a row." |
| | `.kept(_, n)` with n < 3, or `.vacant` | no banner |
| History record row VoiceOver | holder exists | "{Name}, 2 wins, 1 loss. You hold the belt, 1 week. Latest: {line}". Hint: "Opens your weeks with {Name}" |
| Person page | nav title | "{Name}" |
| | header | "3–3" (with ties: "3–3–1") and "6 WEEKS" / "1 WEEK" |
| | belt panel title | "You hold the belt" / "{Name} holds the belt" / "No one holds the belt yet" / "The belt is retired" |
| | since line (holder only) | "Since Nov 8 · 1 week" |
| | stat rows (when `changes > 0`) | "Longest reign" → "You · 2 weeks" / "{Name} · 3 weeks"; "Title changes" → "3" |
| | section label | "WEEKS" |
| | no weeks | "Finished matches appear here." (History's existing line) |
| Person page week row VoiceOver | every week | the week summary without the leading name ("You won · Nov 2 – 8. You 2,412 points. Sam 2,298 points") |
| | a week where the belt was taken | that + ". You took the belt" / ". {Name} took the belt" |
| Local result notification body (Q-b) | `.took(.you, fromWeeks: n)` | "{scores}. You took the belt from {Name}." |
| | `.took(.you, nil)` | "{scores}. You took the belt." |
| | `.took(.them, _)` | "{scores}. {Name} took the belt." |
| | kept, tie, vacant, Former competitor | unchanged |
| Result summary notification | each match's sentence gets its own belt sentence | "You beat Priya 3,410 to 3,180. You took the belt. Jordan won 3,302 to 3,117. Jordan took the belt." |

- **Weeks text:** "1 week" / "{n} weeks".
- **Names** come from `opponentDisplayName`.
- **Numbers** in notifications come from the existing `resultScores` (shared formatter). No new number formatting.
- **Tense:** every banner line stays true on an old result after the belt has moved on: "took", "held it for", "{n} weeks in a row". There is no present perfect.

**Glossary addition (§5 of the audit spec):** **Belt**: one per pair; "holds", "took", "kept". Don't say championship or trophy, and never stakes. "Title changes" is the one use of "title", taken from the approved mockup.

##### Retired pairs ("Former competitor")
- Home shows no chip (there can be no new match).
- The record row has no mark and no belt text.
- The person page reads "The belt is retired", with no since line. Longest reign and Title changes stay, as history.
- **Past result banners stay as they are.** They describe what that week did, so "You beat Former competitor" keeps "You took the belt".
- No notification sentence.

##### Accessibility
- Belt marks are `.accessibilityHidden(true)`. The words carry the meaning.
- The chip text wraps (`.fixedSize(horizontal: false, vertical: true)`, no `lineLimit`), so `.textClipped` passes at AX5.
- The banner is one combined element.
- The record row becomes a button and keeps its id. Its row height stays at least 76 pt.
- Person page header and stat rows switch to a VStack at accessibility sizes, using `AnyLayout`, not `ViewThatFits`. The precedent is `CompetitionResultView.swift:356` and `CompetitionDetailView.swift:586-587`.
- The reused `CompetitionSharingRow` and `CompetitionRecordRow` keep their `ViewThatFits`. Because of that, the new UI test does not run the `.dynamicType` audit (see Tests).

#### Design

##### 1. Belt fold and helpers: `CompetitionSharingView.swift`, new `// MARK: Belt` after `competitionHistorySummaryAccessibilityText` (:1851)
Everything below is internal, so `CompetitionNotificationPlanner.swift` and `CompetitionResultView.swift` (same target) can call it.
```swift
/// The reserved name of a deleted account (profiles_identity_state_check).
let competitionFormerCompetitorName = "Former competitor"

enum CompetitionBeltHolder: Equatable, Sendable { case you, them }

/// What one finished week did to the belt.
enum CompetitionBeltEvent: Equatable, Sendable {
    /// A tie before anyone held it.
    case vacant
    /// The winner took it; `fromWeeks` is the other person's reign, nil on the first win.
    case took(by: CompetitionBeltHolder, fromWeeks: Int?)
    /// The holder won again or tied; `weeks` counts the reign including this week.
    case kept(by: CompetitionBeltHolder, weeks: Int)
}

struct CompetitionBeltReign: Equatable, Sendable {
    let holder: CompetitionBeltHolder
    let weeks: Int
    let startID: CompetitionID
}

struct CompetitionBelt: Equatable, Sendable {
    let current: CompetitionBeltReign?
    let longest: CompetitionBeltReign?
    /// Weeks the belt went to someone new, the first win included.
    let changes: Int
    let events: [CompetitionID: CompetitionBeltEvent]
    let isRetired: Bool
    /// Nil before the first decided week and once the other person's account is deleted.
    var holder: CompetitionBeltHolder? { isRetired ? nil : current?.holder }
    static let vacant = Self(current: nil, longest: nil, changes: 0, events: [:], isRetired: false)
}

/// One pair's finished weeks in any order. The fold sorts them (schedule end,
/// then uuid) so History and the notification planner can't disagree.
func competitionBelt(
    _ weeks: [(id: CompetitionID, end: Date?, outcome: CompetitionOutcome)],
    isRetired: Bool = false
) -> CompetitionBelt {
    let ordered = weeks.sorted {
        ($0.end ?? .distantPast, $0.id.rawValue.uuidString) < ($1.end ?? .distantPast, $1.id.rawValue.uuidString)
    }
    var current: CompetitionBeltReign?
    var longest: CompetitionBeltReign?
    var changes = 0
    var events: [CompetitionID: CompetitionBeltEvent] = [:]
    for week in ordered {
        let winner: CompetitionBeltHolder? = switch week.outcome {
        case .win: .you
        case .loss: .them
        case .tie: nil
        }
        if let reign = current, winner == nil || winner == reign.holder {
            current = CompetitionBeltReign(holder: reign.holder, weeks: reign.weeks + 1, startID: reign.startID)
            events[week.id] = .kept(by: reign.holder, weeks: reign.weeks + 1)
        } else if let winner {
            events[week.id] = .took(by: winner, fromWeeks: current?.weeks)
            current = CompetitionBeltReign(holder: winner, weeks: 1, startID: week.id)
            changes += 1
        } else {
            events[week.id] = .vacant
        }
        // >=: on equal length the more recent reign is the longest.
        if let reign = current, reign.weeks >= (longest?.weeks ?? 0) { longest = reign }
    }
    return CompetitionBelt(current: current, longest: longest, changes: changes, events: events, isRetired: isRetired)
}

/// The belt event of one finished match, from its pair's record.
func competitionBeltEvent(
    for competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> CompetitionBeltEvent? {
    competitionOpponentRecords(competitions)
        .first { $0.opponentIdentity == competition.opponentIdentity }?
        .belt.events[competition.id]
}

/// True while an earlier match with the same person hasn't finished, so its
/// result could still move the belt ("going in" is not known yet).
func competitionBeltWaitsOnAnEarlierMatch(
    _ competition: LocalCompetitionPresentation,
    in competitions: [LocalCompetitionPresentation]
) -> Bool {
    func start(_ c: LocalCompetitionPresentation) -> Date? {
        c.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.start }
    }
    guard let mine = start(competition) else { return false }
    return competitions.contains { other in
        guard other.id != competition.id, other.opponentIdentity == competition.opponentIdentity,
              let theirs = start(other), theirs < mine else { return false }
        switch other.lifecycle {
        case .scheduled, .active, .endsToday, .tallying: return true
        default: return false
        }
    }
}

func competitionWeeksText(_ count: Int) -> String { count == 1 ? "1 week" : "\(count) weeks" }

/// "You hold the belt" / "Sam holds the belt".
func competitionBeltStandingText(_ holder: CompetitionBeltHolder, opponentName: String) -> String {
    holder == .you ? "You hold the belt" : "\(opponentName) holds the belt"
}

/// The result banner: on a take, or a reign of 3+ weeks; otherwise nil.
func competitionBeltResultText(
    _ event: CompetitionBeltEvent, opponentName: String
) -> (holder: CompetitionBeltHolder, title: String, detail: String?)? { /* table in Behavior */ }
```
- **`CompetitionOpponentRecord` (:1767)** gains `var belt: CompetitionBelt = .vacant`.
  - It's a `var` with a default, so the memberwise init used by `testHistorySummaryShowsTwoPeopleThenACount` (:1378) still compiles.
- **`competitionOpponentRecords` (:1814-1836)** sets the belt on each record:
  ```swift
  belt: competitionBelt(
      weeks.compactMap { w in w.terminalResult.map { (w.id, w.acceptedConfiguration.flatMap { competitionScheduleBoundaries($0.schedule)?.end }, $0.outcome) } },
      isRetired: latest.opponentDisplayName == competitionFormerCompetitorName
  )
  ```
- **Delete `competitionVictoryCountText` (:1473-1478).** Its only caller is the awards section, which is removed.

##### 2. Belt mark and chip views (same file, after `CompetitionOutcomeChip` :763)
- **`struct CompetitionBeltMark: View { let holder: CompetitionBeltHolder; var width: CGFloat = 22 }`** draws three rounded rects in the mockup's 44×24 geometry:
  - the strap: `Theme.ink`, full width, height 10/44
  - the plate: a 20/44 square, `Theme.youFill` when you hold it, `Theme.ink` when they do (amber always means you)
  - the inner square: 10/44, `Theme.ground`
  - frame `width × width·24/44`, `.accessibilityHidden(true)`
- **`private struct CompetitionBeltChip: View { let holder; let text }`** matches the mockup's plain `.chip`:
  - `HStack(spacing: 6) { CompetitionBeltMark(holder:); Text(text) }`
  - text in `.themeLabel`, `.tracking(1.2)`, `.textCase(.uppercase)`; foreground `Theme.you` when you hold it, `Theme.ink` when they do
  - padding h 9, v 4; background `Theme.ground` in `Capsule()`; overlay `Capsule().strokeBorder(Theme.hairline)`

##### 3. Home: `CompetitionSharingView`
- **`body` (:35):** bind `let records = self.records` (:169) once.
- **Add a helper:**
  ```swift
  private func belt(for competition: LocalCompetitionPresentation, in records: [CompetitionOpponentRecord]) -> CompetitionBelt? {
      guard !competitionBeltWaitsOnAnEarlierMatch(competition, in: publication.dashboard.competitions) else { return nil }
      return records.first { $0.opponentIdentity == competition.opponentIdentity }?.belt
  }
  ```
- **Hero (:56-62) and live compact cards (:73-79):**
  - pass `belt: belt(for: c, in: records)` to `CompetitionHeroCard`
  - pass `caption: standing` to `competitionButton`, where `standing = belt?.holder.map { competitionBeltStandingText($0, opponentName: c.opponentDisplayName) }`
  - `competitionButton`'s `caption` only appends to the VoiceOver label (:281-287), so no visible row changes.
- **`CompetitionHeroCard` (:407):**
  - add `var belt: CompetitionBelt? = nil`
  - in `body`, right after `statusRow` (:417), add `if let holder = belt?.holder { CompetitionBeltChip(holder: holder, text: competitionBeltStandingText(holder, opponentName: competition.opponentDisplayName)) }`
- **`CompetitionSharingRow` (:596):**
  - add `var showsName = true` and `var beltHolder: CompetitionBeltHolder? = nil`
  - `identity` skips the name `Text` when `showsName` is false
  - when `beltHolder` is set, draw `CompetitionBeltMark(holder:)` just before `trailingScore` in both `ViewThatFits` branches
  - only the person page sets either field
- **`sharingAccessibilitySummary` (:1263)** gains `includesName: Bool = true`. When false, the leading name part is dropped. The score parts still say "{Name} 2,298 points", so the scores stay attributed.

##### 4. History record row: `CompetitionRecordRow` (:981-1043) and `CompetitionHistoryView.recordSection` (:1074-1099)
- **In `recordSection`:**
  - wrap each row in `NavigationLink(value: CompetitionHomeRoute.person(record.opponentIdentity)) { CompetitionRecordRow(record: record).contentShape(Rectangle()) }` with `.buttonStyle(CompetitionRowButtonStyle())`
  - move `.accessibilityIdentifier("competition.record.<latest uuid>")` from the row onto the link, keeping the same string
  - only the link carries the id, so `records.count == 1` (`LocalCompetitionLifecycleUITests.swift:162`) still holds
  - this is the same label-inside, id-on-link pattern as `weeksSection` (:1110-1133)
- **In the row:**
  - `recordText` becomes `HStack(spacing: 8) { if let h = record.belt.holder { CompetitionBeltMark(holder: h) }; competitionRecordText(record)… }`, followed by the chevron `CompetitionSharingRow.trailingMark` draws (`chevron.right`, `.caption.weight(.bold)`, `Theme.tertiary`)
  - replace `.accessibilityAddTraits(.isStaticText)` with `.accessibilityHint("Opens your weeks with \(record.opponentDisplayName)")`
  - the label becomes `[record.accessibilityText, beltA11y, "Latest: \(line)"].compactMap { $0 }.joined(separator: ". ")`
    - `beltA11y` = `record.belt.current.flatMap { c in record.belt.holder.map { "\(competitionBeltStandingText($0, opponentName: record.opponentDisplayName)), \(competitionWeeksText(c.weeks))" } }`
    - for example: "You hold the belt, 1 week"
  - update the doc comment (:979-980), which says rows don't open anything

##### 5. Person page: new `struct CompetitionPersonView: View` in the same file, after `CompetitionHistoryView` (:1140)
It goes in this file because it reuses the file-private `competitionRecordText`, `CompetitionSharingRow`, `CompetitionRowDivider` and `sharingAccessibilitySummary` with no access changes.
```swift
struct CompetitionPersonView: View {
    let publication: LocalCompetitionPublication
    let opponentIdentity: String
    // record = competitionOpponentRecords(publication.dashboard.competitions).first { $0.opponentIdentity == opponentIdentity }
    // weeks  = competitionHistoryWeeks(publication.dashboard.competitions).filter { $0.opponentIdentity == opponentIdentity }  // newest first
}
```
- **Layout:** `ScrollView { VStack(alignment: .leading, spacing: 24) }`, padding h 16 / v 12, `.background(Theme.ground)`, `.navigationTitle(record?.opponentDisplayName ?? "")` inline, `.accessibilityIdentifier("competition.person")`.
- **Header:**
  - the record text in `.score(size:)` with `@ScaledMetric(relativeTo: .largeTitle) 64`, then `Spacer`, then the "N WEEKS" label (`.themeLabel`, tracking 1.2, `Theme.secondary`)
  - stacks at accessibility sizes (`AnyLayout`)
  - one element, label "{record.accessibilityText}. {n week(s)}", id `competition.person.record`
- **Belt panel:**
  - `VStack(alignment: .leading, spacing: 8).padding(16).themePanel()`, `.accessibilityElement(children: .combine)`, id `competition.person.belt`
  - first row: a 44 pt-wide mark (only when there's a holder) plus the title (`.headline`; `Theme.you` if you hold it, otherwise `Theme.ink`)
  - the since line: `"Since \(competitionDayText(lastDay, weekday: false, now: publication.evaluatedAt, locale: locale, timeZone: timeZone)) · \(competitionWeeksText(current.weeks))"`
    - `lastDay` = `try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay).last` of the week whose id is `current.startID`
    - this uses the `CompetitionDay` overload of `competitionDayText` (`CompetitionWeekChart.swift:605`)
  - then a hairline (`CompetitionRowDivider`) and the two stat rows (secondary label, bold value), only when `belt.changes > 0`
- **Weeks:**
  - `SectionLabel("WEEKS")` and the same panel as `CompetitionHistoryView.weeksSection` (:1102-1139)
  - each row is `NavigationLink(value: CompetitionHomeRoute.competition(id))` wrapping `CompetitionSharingRow(competition:, source:, showsName: false, beltHolder: tookHolder)`
    - `tookHolder` is set only for `.took(by:, _)` weeks
    - the row keeps the W/L/T chip, the status line ("You won · Nov 2 – 8", which carries the dates) and the scores
  - label: `sharingAccessibilitySummary(..., includesName: false)`, plus ". " and the banner title for weeks where the belt was taken
  - id: `competitionSharingIdentifier(competition)` (unchanged, so the result opens exactly as it does from History)
- **No record** (the person's weeks were deleted, fixture only): show History's "Finished matches appear here." line.
- **No primary action.** The page is a summary (one job), and Rematch lives on each result.

##### 6. Route: `CompetitionHomeRoute` (:1143-1171)
```swift
enum CompetitionHomeRoute: Hashable {
    case history
    case person(String)          // opponentIdentity; only ever pushed from History
    case competition(CompetitionID)
    static func stack(path: Binding<[CompetitionID]>, showsHistory: Binding<Bool>,
                      person: Binding<String?>) -> Binding<[CompetitionHomeRoute]>
}
```
- **get:** `(showsHistory ? [.history] + (person.map { [.person($0)] } ?? []) : []) + path.map(.competition)`.
- **set:**
  - `showsHistory = routes.first == .history`
  - `person` = the first `.person` id in `routes`, or nil
  - `path` = the `.competition` ids, as today

##### 7. Host state: `MainTabFeature.swift`
- **State (:72-108):** add `var historyPersonIdentity: String?`. It's declared with a default and kept out of `init`, like `acceptsClaimOnStart`.
- **Action (:177-178):** add `case historyPersonChanged(String?)`.
- **Reducer:**
  - `.historyPersonChanged(id)` sets `state.historyPersonIdentity = id`.
  - `.historyPresentationChanged(false)` (:393) also sets it to nil.
  - The route opener sets it to nil next to `state.showsHistory = false` (:944, in the visible-route branch of `resolve`). So does `followSentChallengeFromLink` (:1007). A notification route or a sent link closes the person page along with History.

##### 8. Host views
- **`MainTabView.swift`:**
  - pass `stack(... person: Binding(get: { store.historyPersonIdentity }, set: { store.send(.historyPersonChanged($0)) }))` (:84-92)
  - `.navigationDestination` (:142-152) adds `case let .person(identity): if let publication = store.competition.publication { CompetitionPersonView(publication: publication, opponentIdentity: identity).toolbarRole(.editor) }`
  - the result case (:295-307) replaces `awards: publication.dashboard.awards` (:298) with `beltEvent: competitionBeltEvent(for: competition, in: publication.dashboard.competitions)`
- **`MultiUserCompetitionTestLabView.swift`:**
  - add `@State private var historyPerson: String?` (:172), passed to `stack` (:185-188)
  - add a `.person` destination (:240-247)
  - the result passes `beltEvent:` (:286-294)
- **Fixture (:642+):**
  - add `jordanPastID = A1000000-0000-4000-8000-000000000009` (unused today; `…0008` is taken)
  - it is "Jordan", `opponentIdentity: active.opponentIdentity`, `.archived(outcome: .loss, …)`, `startDay: 1` (Aug 1–7), 3,050 vs 3,210, `completedAt` Aug 9
  - append it to the end of `competitions` (:804), so `.first`-based Test Lab tests don't change
  - Jordan then holds the belt for 1 week, and Morgan's single tie stays vacant
  - Home's History summary in this fixture becomes "Former competitor 1–0 · Morgan 0–0–1 · 1 more". No test asserts that text (checked by grep).
  - the `awards` fixture (:807-815) stays, because the dashboard model is unchanged

##### 9. Result screen: `CompetitionResultView.swift`
- **Inputs:** replace `let awards: [LocalCompetitionAward]` (:6) with `let beltEvent: CompetitionBeltEvent?`.
- **Body:** after the score `VStack` (:37-41), add `if let text = beltEvent.flatMap({ competitionBeltResultText($0, opponentName: opponentName) }) { beltBanner(text).opacity(isRevealed ? 1 : 0) }`.
- **Delete:**
  - the `visibleAwards` block (:57-60)
  - `awardPresentation`, `awardDetail` and `awardBadge` (:412-466)
  - `visibleAwards` (:765-768)
- **`beltBanner`:**
  - `VStack(spacing: 6) { CompetitionBeltMark(holder: text.holder, width: 44); Text(text.title).font(.title3.weight(.heavy).width(.condensed)).foregroundStyle(text.holder == .you ? Theme.you : Theme.ink); text.detail.map { Text($0).font(.subheadline).foregroundStyle(Theme.secondary) } }`
  - `.multilineTextAlignment(.center)`, `.frame(maxWidth: .infinity)`, `.padding(16)`, `.themePanel()`, `.accessibilityElement(children: .combine)`, `.accessibilityIdentifier("competition.result.belt")`
- **What stays:** the pinned Rematch control (one primary action) is unchanged. The mockup's "Share Result" button belongs to the recap PR.

##### 10. Notification sentence
- **`CompetitionNotificationModels.swift`:**
  - `CompetitionNotificationMessage` (:187-198) gets `var beltTake: CompetitionBeltEvent? = nil`, set only to a `.took` event
  - `PermissionOnboardingView.swift:194` builds a message and doesn't change (the field has a default)
- **`CompetitionNotificationPlanner.swift`:**
  - `candidate(...)` (:1080-1111) gets a `beltTake: CompetitionBeltEvent? = nil` parameter, passed into the message.
  - In `candidates(for:snapshot:)` (:858-870), the result candidate passes `beltTake: beltTake(for: competition, in: snapshot)`. This is a new private helper:
    ```swift
    guard competition.opponentDisplayName != competitionFormerCompetitorName else { return nil }
    let event = competitionBelt(snapshot.competitions
        .filter { $0.opponentIdentity == competition.opponentIdentity }
        .compactMap { w in w.terminalResult.map { (w.id, w.schedule.flatMap(competitionScheduleBoundaries)?.end, $0.outcome) } }
    ).events[competition.id]
    if case .took = event { return event }
    return nil
    ```
    - `schedule` is optional on the snapshot (:85), hence the `flatMap`
    - it reads every snapshot competition, muted ones included, so muting a person never shifts the history
  - **`liveV1Content`, `.opportunistic(.result)` (:165-182):** append `" " + sentence` to the scores body when `beltSentence(message)` isn't nil.
  - **Summary sentence map (:224-232):** append the same per message.
  - **`private static func beltSentence(_ m: CompetitionNotificationMessage) -> String?`:**
    - `.took(.you, nil)` → "You took the belt."
    - `.took(.you, _?)` → "You took the belt from \(name)."
    - `.took(.them, _)` → "\(name) took the belt."
    - otherwise nil
- **Where the history comes from:**
  - the local snapshot is built from every journal (`LocalCompetitionClient.swift:1290`); the remote one from every materialization (`RemoteCompetitionClient.swift:1955-1971`)
  - archived weeks are included, and the fold orders them itself, so the sentence agrees with the banner and the person page
  - each phone computes its own side, and both see the same ids, schedules and decided outcomes
- **Server pushes are untouched.** Results no longer alert from the server (`send-competition-notification/index.ts:266`), and the push text stays generic (audit §10 Q3). No names are added.

##### Shared with the recap PR
- The recap reads `competitionBeltEvent(for:in:)`. For its belt line it can reuse `competitionBeltResultText`, which has the same gate the playbook sets for the recap: a take, or a reign of 3+ weeks.
- With the name hidden, the recap must not pass "Them" into the {Name} template ("Them took the belt"). The hidden-name copy belongs to the recap spec, as do its highlights.

#### Mockup vs code (closest correct behavior chosen)
- **Colors:**
  - The banner's light-amber fill isn't a token, so it becomes `themePanel` (Q-e). The mark's inner square becomes `Theme.ground`.
  - The Home chip already matches the mockup's plain `.chip` with `Theme.ground` and `Theme.hairline`.
  - The mockup draws the belt with an amber plate for Sam too. The plate now follows the holder, because amber always means you.
- **Week rows on the person page:** the mockup shows dates, scores and the mark. The page drops the name (`showsName: false`) but keeps the W/L/T chip and the status line ("You won · Nov 2 – 8"). That way the outcome doesn't rest on color alone, and the ids match History. Flagged on the preview.
- **Since date:** "Since Nov 8" is the last day of the deciding week in the match calendar, not the moment it was finalized.
- **Which cards get the chip:** the mockup puts it on the single live hero. Compact live cards (two or more live) and the scheduled hero get it too, because each is "going in". A card waits while an earlier match with the same person is unfinished.
- **Banner:** the mockup shows only a take. A kept reign of 3+ weeks also shows one (Q-c), using the playbook's recap rule.
- **Result screen:** the result summary keeps today's wording ("Won by 114 points · won 4 days, lost 3"), not the mockup's "4 of 7 days".

#### Server changes
None:
- no migration, so the recovery harness migration count and manifest pin don't move
- no Edge Function
- nothing new stored, uploaded or shared

#### Tests
**HealthCompTests/CompetitionPresentationTests.swift** (an existing file; uses `homePresentation(id:name:identity:lifecycle:start:)`, :1511)
- `testBeltGoesToTheFirstWinnerAndTiesLeaveIt`:
  - weeks [tie, win, tie, loss, loss, win], one week apart
  - events: `.vacant`, `.took(.you, nil)`, `.kept(.you, 2)`, `.took(.them, 2)`, `.kept(.them, 2)`, `.took(.you, 2)`
  - `holder == .you`, `current.weeks == 1`, `current.startID` = week 6, `changes == 3`, `longest == (.them, 2, week 4)` (the more recent on equal length)
- `testBeltWithOnlyTiesHasNoHolder`: two ties give `holder == nil`, both events `.vacant`, and `changes == 0`.
- `testBeltRetiresForAFormerCompetitor`: three weeks named "Former competitor".
  - `record.belt.isRetired`, and `holder == nil`
  - `events` and `longest` are kept
  - `competitionBeltEvent` still returns `.took(.you, nil)` for the first week
- `testBeltOrdersWeeksByEndThenID`:
  - weeks passed shuffled, with two that share an end; the shared-end pair folds in uuid-ascending order
  - `competitionOpponentRecords` gives the same belt as a direct `competitionBelt` call
  - a `.cancelled`, a `.declined(…, .outgoing)` and an `.expired` with the same identity change nothing
- `testBeltChipWaitsWhileAnEarlierMatchWithThemIsUnfinished`:
  - match N is `.tallying` and match N+1 (a week later, same identity) is `.active`
  - `competitionBeltWaitsOnAnEarlierMatch` is true for N+1 and false for N
  - once N is `.completed`, it's false for N+1
  - a different identity never waits
- `testBeltCopy`:
  - `competitionBeltStandingText` gives "You hold the belt" and "Sam holds the belt"
  - `competitionWeeksText(1/3)` gives "1 week" and "3 weeks"
  - every row of the result table, including `.vacant` → nil, `.kept(_, 2)` → nil, `.kept(.them, 3)` → ("Sam kept the belt", "3 weeks in a row."), and the first-win nil detail
- `testHomeRouteStackKeepsThePersonPageUnderHistory`:
  - with local vars behind `Binding(get:set:)`, the getter gives `[.history, .person("p"), .competition(A)]`
  - setting `[.history]` clears the person and the path
  - setting `[]` clears all three
- **Change `testAwardsAreWinsOnlyNewestFirstWithOpponentIdentity` (:1105-1141):** delete the two `competitionVictoryCountText` assertions (:1129-1136). The award fold and identifier assertions stay.

**HealthCompTests/CompetitionNotificationPlannerTests.swift**
- **Extend `finishedMatch` (:749-765)** with `startDate: Date = Date(timeIntervalSinceReferenceDate: 1_036_800)` and `recorded: [(NotificationEmissionFamily, NotificationEpisodeKey)] = []`. Pass both through to `competitionSnapshot` (:1261), which already takes them.
  - Its identity is already `"local-opponent:v1:" + name`, so it needs no identity parameter.
  - An earlier week uses `startDate: 1_036_800 - 7 * 86_400` and `recorded: [(.result, .result)]`. Otherwise the planner emits its own result (every competition with a `terminalResult` goes through `opportunisticPlan`, :355-385, filtered only by `recordedIDs`, :634-640), and `immediateRequests` would collapse the two into a summary (:415-446).
- **Each new test** first asserts `emissionDecisions.filter { $0.record.family == .result }.count == 1`, then reads `planner.immediateRequests(for:in:)[0].content.body` with `enUSPolicy()`:
  - `testResultNotificationSaysYouTookTheBeltFromThem`: Sam won the earlier week, and you win this one. The body is "4,200 to 3,900. You took the belt from Sam."
  - `testResultNotificationSaysTheyTookTheBelt`: you won the earlier week, and Sam wins this one. The body is "3,302 to 3,117. Sam took the belt."
  - `testResultNotificationSaysYouTookTheBeltOnAFirstWin`: one finished match. The body is "4,200 to 3,900. You took the belt."
  - `testResultNotificationOmitsTheBeltWhenKeptTiedOrRetired`: a kept week, a tie after a holder, a tie with nobody holding it, and a "Former competitor" first win each keep today's body ("4,200 to 3,900." / "1,500 to 1,500.").
- **Change `testImmediateRequestsSummarizeResults` (:799-819):** the expected body becomes "You beat Priya 3,410 to 3,180. You took the belt. Jordan won 3,302 to 3,117. Jordan took the belt." Both are first matches for their pair.
- **Unchanged:** the bodies at :91, :150, :1148-1149 and :1188-1191, which build messages directly with no `beltTake`.

**HealthCompTests/MainTabFeatureTests.swift**
- `testRouteClosesHistoryAndAccountBeforeOpening` (:1434): set `historyPersonIdentity = "remote-profile:v1:x"` on the initial state, and expect it to be nil after the route.
- `testHistoryAndAccountPresentationActionsSetState` (:1463):
  - send `.historyPersonChanged("p")`, and expect it to be set
  - then send `.historyPresentationChanged(false)`, and expect `showsHistory` false and the person nil

**HealthCompUITests/LocalCompetitionLifecycleUITests.swift** (not in ci.yml; the Mac mini run gates it)
- `testOutgoingCompetitionCompletesTheSevenDayLifecycle`:
  - at :133, `XCTAssertEqual(app.descendants(matching: .any)["competition.result.belt"].label, "You took the belt")` replaces "Victory Over Alex"
  - after :164, `XCTAssertTrue(records.firstMatch.label.contains("You hold the belt, 1 week"))`
  - tap the record, wait for `navigationBars["Alex"]`, check that the `competition.person.belt` label contains "You hold the belt" and that `sharingCards(state: "completed").count == 1`
  - go back to History, and continue as today
- `testLossAndTieFixturesRenderBothResultOutcomes` (:354):
  - loss: the banner label is "Alex took the belt"
  - tie: `competition.result.belt` doesn't exist

**HealthCompUITests/MultiUserCompetitionUITests.swift**
- **`testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive` (in CI):** at :264, replace "Victory Over Former competitor" with a check that the `competition.result.belt` label is "You took the belt". Past weeks keep their banner when retired.
- **New `testBeltShowsOnHomeHistoryAndThePersonPage` (added to ci.yml):**
  - Home: `sharingCard(state: "active", name: "Jordan").label` contains "Jordan holds the belt"; Riley's card doesn't contain "belt"
  - open History: the record row whose label contains "Jordan" contains "Jordan holds the belt, 1 week"; Morgan's doesn't contain "belt"
  - tap Jordan's row: `navigationBars["Jordan"]` appears, and the `competition.person.belt` label hasPrefix "Jordan holds the belt"
  - tap `competition.sharing.archived.a1000000-0000-4000-8000-000000000009`: the banner label is "Jordan took the belt"
  - go back twice to History, then open the Former competitor row: the `competition.person.belt` label contains "The belt is retired"
  - relaunch with `UICTContentSizeCategoryAccessibilityXXXL` (as `testRemoteCompetitionAppearanceAndTypeSizeMatrix` does, :990-1001), reopen Jordan's person page, and run `try app.performAccessibilityAudit(for: XCUIAccessibilityAuditType.textClipped.union(.hitRegion).union(.sufficientElementDescription))`
  - **No `.dynamicType` audit.** It must run without a fixed size override (:1145-1146; `LocalCompetitionLifecycleUITests.swift:560-562`), it flags text that `ViewThatFits` swaps out (`CompetitionDetailView.swift:586-587`), and the reused rows use `ViewThatFits` (:606, :989). The remote suite already leaves it out for flakiness (:924-926).
- **Unchanged but now covers the banner:** `testRemoteCompetitionDynamicTypeRemainsReadable` (:1145-1181) runs `.dynamicType` on the Former competitor result page, which now shows the banner (plain wrapping `Text` in a `VStack`). It isn't in ci.yml, so the Mac mini `ui` run gates it.
- **`.github/workflows/ci.yml` (:211-227):** add `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testBeltShowsOnHomeHistoryAndThePersonPage`. CI runs an explicit list.

#### Verification (Mac mini, then PR CI)
```bash
git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/ua/belt/src && tar -x -C ~/dev-desktop/ua/belt/src'
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh xcodegen belt'   # must leave project.pbxproj unchanged (no new files)
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh unit belt'
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh ui belt -only-testing:HealthCompUITests/LocalCompetitionLifecycleUITests -only-testing:HealthCompUITests/MultiUserCompetitionUITests'
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh ci belt'          # CI's exact Debug selection
```
- **The `ui` run of both full classes is the gate** for every assertion outside ci.yml. That covers the local lifecycle banner, record-row and person-page checks, the loss and tie banners, and the `.dynamicType` audit of the Former competitor result page. The script's `ci` mode builds its list from ci.yml (`ua-mac6.sh:56`), so it doesn't cover them. All of these must pass before the PR opens.
- **Captures**, light and dark at XS and AX5:
  - Home: the Jordan compact card with the chip, and the local single hero with "You hold the belt" after a second fixture week
  - the result banner: take from them, first win, and kept 3+ weeks (finish weeks in the Test Lab)
  - History with record rows
  - the person page with a holder (Jordan), vacant (Morgan) and retired (Former competitor)
- Put the captures on a claude.ai preview artifact next to the playbook mockup, listing the deviations above. The owner approves it before the PR opens.
- **Notification check:** in the Test Lab, finish a second week where the belt changes hands, and confirm on a simulator that the delivered notification body ends with the belt sentence.
- **Not affected:**
  - no Deno, pgTAP or Staging steps
  - CompetitionCore and `CompetitionDateFormatting.swift` don't change, so `swift test` and the standalone formatter script aren't affected

#### Accessibility identifiers
- **Added:** `competition.result.belt`, `competition.person`, `competition.person.record`, `competition.person.belt`.
- **Same id, new behavior:**
  - `competition.record.<uuid>` moves from the row to its link. It is now a button (no longer static text), and its label gains the belt text.
  - `competition.sharing.<lifecycle>.<uuid>` is also used on the person page's week rows.
- **Removed:** none. The AWARDS section had no ids.
- **Unchanged:** `competition.rivalry`, `competition.history.open`, `competition.result`, `competition.result.summary`, `competition.rematch.*`.

#### Risks and conflict regions
- **Build order with the recap PR:** belt first (playbook order). The recap edits `CompetitionResultView` in the same region (under the score, above Rematch) and reads `competitionBeltEvent` / `competitionBeltResultText`.
- **Practice match PR:** its weeks must not count. Exclude them in both places that build a belt's weeks:
  - `competitionHistoryWeeks` (:1797), which records, History and the person page read
  - the planner's `beltTake` filter
  The types differ (presentation vs notification snapshot), so the exclusion lives in each model's own filter. The ordering can't diverge, because only `competitionBelt` sorts.
- **Widgets/Live Activity PRs:** if a widget shows the belt (the playbook mockup does), move `CompetitionBeltHolder`, `CompetitionBeltEvent`, `CompetitionBeltReign` and `competitionBelt` into `Modules/CompetitionCore` then. They depend only on `CompetitionID`, `CompetitionOutcome` and `Date`. Not done now, because nothing outside the app target needs it.
- **`CompetitionSharingView.swift`** is a hot file. The conflict regions are:
  - `CompetitionHeroCard` (:407-420)
  - `CompetitionSharingRow` (:596-715)
  - `CompetitionRecordRow` (:981-1043)
  - `CompetitionHomeRoute` (:1143)
  - `sharingAccessibilitySummary` (:1263)
  - the History helpers (:1767-1851)
- **Award model:** `LocalCompetitionDashboard.awards`, `LocalCompetitionAward.fold` and the remote `awards(from:)` stay in place, now with no UI consumer. Deleting them touches about 25 test constructors and the Test Lab fixtures, so it's left to a follow-up `refactor/` PR. Mark it at `HealthComp/Features/Competition/LocalCompetitionClient.swift:298` (`let awards: [LocalCompetitionAward]`) with `// ponytail: no UI reads awards since the belt; delete with its ~25 test constructors in a refactor PR`.
- **The planner sees only loaded journals.** If an older week failed to load, the sentence can misstate a take (for example, "You took the belt." when it was kept). The screen recomputes on the next refresh. Accepted as rare. The upgrade path is to skip the sentence when `knownCompetitionIDs` exceeds the loaded set.
- **Remote history size:** `listCompetitions` (`SupabaseCompetitionRemoteAPI.swift:1101-1110`) has no paging. Above PostgREST's row cap, the oldest weeks would drop and the belt would shift. Not reachable in the 2–5 person beta.
- **Local fixture "Delete Local Data"** removes an archived week, and the belt recomputes. This is fixture only. Real-match history is preserved on the server.

#### Rollout and compatibility
- App only. The installed 1.0.2 and current builds are unaffected, and people on older builds simply see no belt.
- Both phones derive the same belt from the same ids, schedules and decided outcomes. Nothing is persisted, so a reinstall recomputes it from the server's finished matches.
- No server step comes before TestFlight.

#### Review notes
Applied:
- planner tests mark earlier weeks as already emitted and assert one result decision
- `finishedMatch` gains `startDate` and `recorded` (it never had a no-schedule option, and its identity is already per name)
- one ordering, inside `competitionBelt`, using `schedule.flatMap(competitionScheduleBoundaries)?.end`; the claim that week ends never tie is dropped
- the AX5 audit set has no `.dynamicType`
- the Mac mini `ui` run is the gate for assertions outside ci.yml
- line references corrected (`CompetitionResultView.swift:356`, `HealthComp/Services/CompetitionSyncModels.swift:757`)
- `LocalCompetitionClient.swift` added to files_touched
- the chip waits on an earlier unfinished match with the same person
- Q-d removed; the mockup settles it
- Q-b default flipped to every take
- the Q-c banner follows the 3+ week rule with tense-neutral copy
- the recap contract is cut to the shared belt API; highlights and hidden-name copy go to the recap spec
- Q-e is narrowed to the banner fill
- person-page rows drop the name

Rejected or partly applied:
- **Tie order:** History's tie order (uuid descending, after completedAt) is not copied into the planner. Instead, both callers share the fold's own (end, uuid ascending) order, as the other reviewer proposed. History's row order can differ only for equal-end legacy weeks, and the marks still follow the belt.
- **Dynamic Type audit:** no `.dynamicType` audit is added, so `CompetitionSharingRow` and `CompetitionRecordRow` are not moved to `AnyLayout` in this PR.
- **Week filter:** "which weeks count" is not shared as one function, because the presentation and notification snapshot types differ. The practice-match PR note names both sites.
- **Person-page chip:** the W/L/T chip is kept on person-page rows, so the outcome isn't carried by color alone. Flagged on the preview.

#### Owner actions for this feature (merged into §7)
- Approve the preview artifact before the PR opens, at XS and AX5. It covers the Home chip; the result banner when taken (first win and from them) and when kept 3+ weeks; the History record row; and the person page with a holder, vacant and retired. The deviations listed under "Mockup vs code" are flagged on it.
- Answer the open questions below, or leave the defaults.

### 9.2 PR 2: Recap card

Branches: `feature/recap-card` · Server: no · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **Belt input (replaces Design E).** PR 1 already passes `beltEvent: CompetitionBeltEvent?` to `CompetitionResultView` at both call sites. This PR's adapter, in `CompetitionRecapView.swift`:
  ```swift
  func competitionRecapBelt(_ event: CompetitionBeltEvent?, outcome: CompetitionOutcome, isRetired: Bool) -> CompetitionRecapBelt? {
      guard !isRetired, outcome != .tie, let event else { return nil }
      switch event {
      case .took(.you, _): return .youTook
      case .took(.them, _): return .theyTook
      case let .kept(.you, n) where n >= 3 && outcome == .win: return .youKept(weeks: n)
      case let .kept(.them, n) where n >= 3 && outcome == .loss: return .theyKept(weeks: n)
      default: return nil
      }
  }
  ```
  The sheet call is `CompetitionRecapSheet(competition:, belt: competitionRecapBelt(beltEvent, outcome: competitionResultOutcome(competition), isRetired: !competitionRecapAllowsNameChoice(competition)))`. "Former competitor" gets no belt line (the result screen's banner still shows, per PR 1). Reign weeks count ties (Q-belt-1).
- **Glyph.** Draw `CompetitionBeltMark(holder: .you, width: 22)` from PR 1 on your lines only. Its colors are `Theme.ink`, `Theme.youFill` and `Theme.ground`, all tokens, so the "drop the glyph" fallback doesn't apply.
- **Casey has a belt line.** With PR 1 merged, the lab's records fold Casey's single loss into `.took(.them, nil)`, so the card ends "Casey took the belt." (hidden: "They took the belt."). The UI test's step 4 string includes it; step 5's hidden string ends "…Best day: Sunday, 512 points. They took the belt."; the Former competitor string has no belt line. The sentence "the lab's finished remote matches have no live belt holder" is superseded.
- **Fixture id** `caseyID = …000A` (§4).
- **Practice.** Share Result shows only when `source == .remoteParticipants && !competition.isPractice`. PR 12 renders practice results with `.remoteParticipants`, so the guard is required; whichever of PR 2 and PR 12 merges second adds it, plus a unit test.
- **Privacy page.** Four other PRs edit `web/privacy.html` (§6); keep this PR's sentences in their sections and one effective date per deploy.

#### PR scope
- `feature/recap-card`: Share Result on CompetitionResultView (real matches only) opens a Share Result sheet. The sheet has a live preview of a fixed 4:5 card, a remembered Show {Name} / Hide name choice (not shown for "Former competitor", which is always hidden) and a ShareLink of a 1080x1350 PNG. The card shows the week with the year, the headline, both final scores using the result screen's digits, the result screen's summary line, the 7-day strip, up to two highlights and the belt line. The belt glyph appears only when you hold the belt. New files: CompetitionRecapView.swift and CompetitionRecapTests.swift (the pbxproj is regenerated; project.yml sources don't change). Adds NSPhotoLibraryAddUsageDescription to project.yml, Info.plist and Staging-Info.plist, with a guard in the privacy-manifest scripts. Adds a named completed remote lab fixture ("Casey"). Adds one MultiUser UI test to ci.yml. Updates web/privacy.html so it says a result image can be shared. No server change, no stakes, no challenge link.

Date: 2026-11-01 · Base: `main` at 8c5ca25 · Depends on: **belt PR** (its per-match belt result and glyph) · Server: none · Size: M (the playbook says S; the privacy page, the Photos plist key and the lab fixture make it M)

Line numbers are from `main` at 8c5ca25. After rebasing onto the belt PR, re-anchor by symbol name.

#### Scope
- On the result screen of a **real** match (`source == .remoteParticipants`), a **Share Result** button opens a sheet. The sheet has:
  - a preview of the exact image that will be shared
  - one choice: Show {Name} / Hide name, remembered on this iPhone, and not shown for "Former competitor"
  - one primary action: **Share**
- The image is a fixed 360×450 pt SwiftUI view (4:5). `ImageRenderer` renders it at scale 3, which gives 1080×1350 px. It is shared as **PNG data** through a small `Transferable` wrapper and `ShareLink`. Both are iOS 16 APIs, so no `#available` is needed.
- On the card: the week with the year, the headline, both final scores using the result screen's digits, the result screen's summary line, the 7-day strip, up to two highlights, and the belt line from the belt PR.
- **Never on the card:**
  - stakes (rejected by the owner)
  - a challenge or invite link, or a QR code
  - ring values, ring colors, kcal, minutes, hours or goals
  - your own display name (your side always reads "YOU")
  - the "Former competitor" label
- No server change. Nothing is uploaded or logged. The image leaves the iPhone only through the system share sheet, after the person picks a destination.
- `project.yml`: add **`NSPhotoLibraryAddUsageDescription`**, because choosing "Save Image" in the share sheet without this key is a privacy crash.
  - `sources: - path: HealthComp` and `- path: HealthCompTests` already pick up the two new Swift files.
  - Regenerate `project.pbxproj` with XcodeGen 2.46.0 and commit it.
- `web/privacy.html` gains one sentence about result images and one line about the Photos add-only permission.

#### Behavior

##### Result screen (`CompetitionResultView`)
- A new **"Share Result"** button goes in the scroll content. It comes after the awards/belt panel and the `.preservedHistory` label (`:63-72`), and before the accessibility-size `rematchControl` (`:75-77`).
  - Style: `SecondaryButtonStyle`, with `Label("Share Result", systemImage: "square.and.arrow.up")`.
  - Identifier `competition.result.share`, hint "Opens a preview of the image to share".
- **Rematch stays the one pinned primary action** (`safeAreaInset`, `:86-96`). On a short result screen, Share Result ends up just above the pinned Rematch, which matches the mockup's "above Rematch".
- **Shown only when** `source == .remoteParticipants`. It works on `.completed` and `.archived` results.
- The sheet is presented with `.sheet(isPresented: $showsShare)`, next to the existing `.sheet(isPresented: $showsWeek)` (`:131-133`).

##### Share Result sheet (`CompetitionRecapSheet`)
Top to bottom, inside `CompetitionDrawer(title: "Share Result", detents: [.large])`:

1. **Header**: the title and the drawer's standard Close (×) button, label "Close". This replaces the mockup's "Done".
2. **Preview**: the rendered image, `.resizable().scaledToFit()`, max width 320 and centred.
   - It is clipped to a 20 pt continuous rounded rectangle with a 1 pt `Theme.hairline` stroke.
   - Until the first render finishes, `Color.clear.aspectRatio(4/5, contentMode: .fit)` with a `ProgressView()` holds the space.
   - VoiceOver reads it as one image: `.accessibilityElement(children: .ignore)`, `.accessibilityAddTraits(.isImage)`, `.accessibilityLabel(recap.accessibilityText)`, identifier `competition.recap.card`.
3. **Name choice** (identifier `competition.recap.name`). It is shown only when `competitionRecapAllowsNameChoice(competition)`, which is false for "Former competitor".
   - Below `.xxLarge` (the threshold `CompetitionWeekStrip` uses): `Picker("Name on the image", selection: $hidesName) { Text("Show \(name)").tag(false); Text("Hide name").tag(true) }.pickerStyle(.segmented)`
   - At `.xxLarge` and above: `Toggle("Hide name", isOn: $hidesName)`, because a segmented label can't wrap.
   - The value is `@AppStorage("healthcomp.recapHidesName")`, default `false`. It is **one setting for all people**.
4. **Share**: `ShareLink(item: png, preview: SharePreview(recap.headline, image: previewImage)) { Label("Share", systemImage: "square.and.arrow.up") }`.
   - `PrimaryButtonStyle`, identifier `competition.recap.share`, hint "Opens the system share sheet".
   - The label is "Share" without an ellipsis, like `competition.rematch.share`.
   - Until the PNG exists, a disabled `Button` with the same label and identifier and `accessibilityValue("Loading")` stands in. This is the `rematchShare` pattern (`:637-647`).
5. **Failure**: when `ImageRenderer.uiImage` or `pngData()` is nil, show `Text("Couldn’t make the image.")` in `.callout`, `Theme.secondary`, identifier `competition.recap.error`. Share stays disabled.

- **Detents: `[.large]` only.** The content (header, a 400 pt preview, the choice, Share) is about 560 pt, so at `.medium` the Share button falls below the fold.
- At accessibility sizes the drawer scrolls. The image never scales with Dynamic Type; the sheet around it does.
- The sheet follows the theme. The card inside it is always light (open question).

##### The card (`CompetitionRecapCard`, fixed 360×450 pt)
Layout: padding 28, `Theme.ground` full bleed, no corner radius.

Naming: "{Name}" is `competition.opponentDisplayName`. When the name is hidden (Hide name, or always for "Former competitor"), the label is **"Them"** and sentences use **"They"**.

| Row | Win | Loss | Tie |
|---|---|---|---|
| Top left | "HEALTHCOMP" | same | same |
| Top right (week, always with year) | "Nov 2 – 8, 2026" | same | same |
| Headline | "Match won" | "{Name} won" / "They won" | "All square" |
| Left side | "YOU" over the score, `Theme.you` | same | same |
| Right side | "{Name}" / "Them" over the score, `Theme.ink` | same | same |
| Summary line | "**Won by 144 points** · won 4 days, lost 3" | "**Lost by 108 points** · won 1 day, lost 6" | "tied 7 days" (margin hidden) |
| Strip | `CompetitionWeekStrip` at its default 10 pt bars | same | same |
| Highlights (0–2) | below | same | same |
| Belt line | below | same | same |
| Footer right | "healthcomp.app" (plain text, `Theme.secondary`) | same | same |

**Numbers.** The card uses the same values and helpers as the result screen.
- **Scores**: `competition.userPoints` / `opponentPoints` through `competitionPointsText(_, fractionDigits: digits, locale:)`, where `digits = competitionFinalFractionDigits(...)`. This gives "2,412", or "2,104.30" against "2,104.00".
- **Summary**: `competitionMarginText(...)` and `competitionDaysSummaryText(competition.days)`, joined by " · ", exactly as `summaryLine` (`:251-278`) builds them.
  - The margin is bold, in `Theme.you` when the displayed margin is above 0, otherwise `Theme.ink`.
- **Mockup conflict:** the mockup's "4 of 7 days" was replaced on the result screen by UI audit PR 3. The card uses the result screen's line.

**Week.** It runs from the first to the last `competition.days`.
- If `days` is empty, it uses `try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)` from `competition.acceptedConfiguration?.schedule`. If neither exists, the week is left out.
- It is formatted by `competitionWeekText(first, last, includesYear: true, locale:)`, which uses the new parameter in Design B.

**Highlights.** Candidates are built in this order, and the first two that exist are shown. Day values are always whole points, through `competitionPointsText(points)`.

1. **Photo finish**
   - Condition: the outcome isn't `.tie`, `m = competitionDisplayedMargin(user, opp, fractionDigits: digits)` isn't 0, and `abs(m) < 0.01 * max(user, opp)`.
   - Title "Photo finish". Value "Decided by \(competitionPointsText(abs(m), fractionDigits: digits))", for example "Decided by 0.30" or "Decided by 18".
2. **Comeback**
   - It uses the **final** day scores (`ownerAcceptedPoints ?? 0`, `opponentRevealedPoints ?? 0`), not a live history. Revealed points can include later revisions.
   - It only counts when those day sums agree with the final score: `competitionDisplayedMargin(sumUser, sumOpp, digits) == competitionDisplayedMargin(user, opp, digits)`. Otherwise it is skipped, which can happen with best-available results.
   - Condition: the outcome is `.win`, and after some day 1–6 (in ordinal order) the running displayed margin was `<= -50`.
   - The value uses the day with the largest deficit (the earliest one on ties). Title "Comeback". Value "Down \(competitionPointsText(deficit)) after \(weekdayText(day.day, locale:))", for example "Down 86 after Wed".
3. **Best day / Perfect day**
   - Among your days whose `ownerAcceptedPoints` round above 0, take the highest (the earliest on ties).
   - A day is **perfect** when its *displayed* value reaches 600: `points.rounded(.toNearestOrAwayFromZero) >= ActivityScore.maximumDailyPoints`. So a 599.6 day, which shows as "600", counts.
   - With one perfect day: title "Perfect day", value "Thu · 600". With n > 1 perfect days: value "\(n) days at 600".
   - Otherwise: title "Best day", value "Thu · 512".
   - **Mockup conflict:** best day and perfect day would name the same day twice, so a perfect day takes best day's slot.

Each highlight is drawn as a 1 pt `Theme.hairline` rule, the title (11 pt condensed bold, uppercase, `Theme.secondary`) and the value (17 pt semibold, `Theme.ink`). There are two equal columns, or one column when only one highlight exists.

**Belt line.** It comes from the belt PR's per-match result (Design E). It never needs the hidden name.

| This match | Line | Glyph |
|---|---|---|
| belt changed hands, you hold it (this includes your first decided win) | "Took the belt" | yes |
| belt changed hands, they hold it | "{Name} took the belt" / "They took the belt" | no |
| you won, kept the belt, reign ≥ 3 weeks | "Kept the belt · 3 weeks" | yes |
| they won, kept the belt, reign ≥ 3 weeks | "{Name} kept the belt · 3 weeks" / "They kept the belt · 3 weeks" | no |
| a tie, a reign under 3 weeks, a retired belt ("Former competitor"), or no belt data | no line, and no rule above the footer | — |

- The line is drawn as 15 pt semibold `Theme.ink` text on the footer row, to the left of "healthcomp.app".
- **The glyph shows only on your lines**, because amber always means you. The mockup glyph's `#FFF3D6` inner plate isn't a Theme token. On the card, the glyph must use only `Theme.youFill` / `Theme.onYouFill` / `Theme.ground`. If the belt PR's glyph uses any other color, the card shows the text without a glyph.

**Accessibility text** (`recap.accessibilityText`, used by the preview). It is built from separate parts:
1. the headline
2. the week, with the dash and its spaces replaced by " to " (regex `\s*–\s*`)
3. "You \(competitionPointsAccessibilityText(user, fractionDigits: digits))"
4. "\(label) \(competitionPointsAccessibilityText(opp, …))"
5. the summary, with " · " replaced by ", "
6. each highlight as "\(title): \(accessibilityValue)", using full weekday names (`weekdayName`) and "points"
7. the belt line, with " · " replaced by ", "

Rules:
- Parts are joined with ". ", and the text ends with "." (the pattern of the `competition.result` label, `:224-226`).
- There is no "Result image" prefix, because the `.isImage` trait already says it.

Highlight accessibility values:
- Photo finish: "decided by 0.30 points"
- Comeback: "down 86 points after Wednesday"
- Best day: "Thursday, 512 points"
- Perfect day: "Thursday, 600 points" or "2 days at 600 points"

Unit fixture, exact text: `"Match won. Nov 2 to 8, 2026. You 2,412 points. Sam 2,268 points. Won by 144 points, won 4 days, lost 3. Comeback: down 86 points after Wednesday. Best day: Thursday, 512 points. Took the belt."`

##### Edge cases
- **"Former competitor"** (a deleted account):
  - the name is always hidden ("Them"/"They"), and the name choice isn't shown
  - the belt is retired, so there is no belt line
  - the stored Hide name value is ignored and left unchanged
- **No days**: no strip and no highlights. The summary is the margin only. The week comes from the schedule.
- **Best-available basis**: the card shows the result screen's final score. The basis note stays on the screen only. The comeback is skipped if the day sums disagree with the final score.
- **Long names** (up to 64 characters, `AccountFeature.displayNameProblem`):
  - the card name label uses `lineLimit(2)` and `minimumScaleFactor(0.6)`
  - the headline uses `lineLimit(2)` and `minimumScaleFactor(0.5)`
  - the segmented label may truncate, but VoiceOver reads it in full
- **Exact tie**: "All square", the margin is hidden, and there is no photo finish, comeback or belt line.
- **The publication refreshes while the sheet is open** (a rename, an account deletion, archiving, a locale change): the image re-renders, because `.task(id: recap)` is keyed on the whole `recap` value. The image, the VoiceOver label and the SharePreview title always come from one value.
- **Image metadata**: the PNG built by `ImageRenderer` → `pngData()` has no EXIF and no location.

#### Design

**A. New file `HealthComp/Features/Competition/CompetitionRecapView.swift`.** It imports SwiftUI and CompetitionCore and is not Foundation-only, so it stays out of `CompetitionDateFormatting.swift`.
```swift
import CompetitionCore
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct CompetitionRecapHighlight: Equatable { let title: String; let value: String; let accessibilityValue: String }

/// The belt as the card tells it. Nil = no line (tie, short reign, retired, no data).
enum CompetitionRecapBelt: Equatable {
    case youTook, theyTook, youKept(weeks: Int), theyKept(weeks: Int)
    var isYours: Bool { switch self { case .youTook, .youKept: true; default: false } }
}

struct CompetitionRecap: Equatable {
    let weekText: String?
    let headline: String            // "Match won" / "{Name} won" / "They won" / "All square"
    let opponentLabel: String       // "{Name}" or "Them"
    let userPointsText: String
    let opponentPointsText: String
    let marginText: String?
    let marginIsYours: Bool
    let daysText: String?
    let days: [LocalCompetitionDayPresentation]
    let highlights: [CompetitionRecapHighlight]   // 0...2
    let belt: CompetitionRecapBelt?
    let beltText: String?
    let accessibilityText: String
}

/// False for "Former competitor": that name is always hidden.
func competitionRecapAllowsNameChoice(_ competition: LocalCompetitionPresentation) -> Bool

func competitionRecap(_ competition: LocalCompetitionPresentation, belt: CompetitionRecapBelt?,
                      hidesName: Bool, locale: Locale = .current) -> CompetitionRecap
    // hidden = hidesName || !competitionRecapAllowsNameChoice(competition)

func competitionRecapHighlights(days: [LocalCompetitionDayPresentation], userPoints: Double,
                                opponentPoints: Double, outcome: CompetitionOutcome,
                                fractionDigits: Int, locale: Locale = .current) -> [CompetitionRecapHighlight]

func competitionRecapBeltText(_ belt: CompetitionRecapBelt, opponentName: String?) -> String
    // opponentName nil = hidden → "They took the belt" / "They kept the belt · 3 weeks"

/// Fixed-size card; never reads Dynamic Type.
struct CompetitionRecapCard: View { let recap: CompetitionRecap
    static let size = CGSize(width: 360, height: 450) }

/// What the share sheet receives: PNG bytes, so size and type are known.
struct CompetitionRecapPNG: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
    }
}

/// 1080×1350 px, always light.
@MainActor func competitionRecapImage(_ recap: CompetitionRecap) -> UIImage? {
    let renderer = ImageRenderer(content: CompetitionRecapCard(recap: recap)
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .large))
    renderer.proposedSize = ProposedViewSize(CompetitionRecapCard.size)
    renderer.scale = 3
    renderer.isOpaque = true
    return renderer.uiImage
}

struct CompetitionRecapSheet: View {
    let competition: LocalCompetitionPresentation
    let belt: CompetitionRecapBelt?
    @AppStorage("healthcomp.recapHidesName") private var hidesName = false
    @State private var png: CompetitionRecapPNG?
    @State private var previewImage: Image?
    @State private var renderFailed = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.locale) private var locale
    private var recap: CompetitionRecap { competitionRecap(competition, belt: belt, hidesName: hidesName, locale: locale) }
    // body: CompetitionDrawer(title: "Share Result", detents: [.large]) { preview; nameChoice (if allowed); failure note; share }
    //   .task(id: recap) {
    //       let ui = competitionRecapImage(recap)
    //       png = ui?.pngData().map(CompetitionRecapPNG.init)
    //       previewImage = ui.map(Image.init(uiImage:))
    //       renderFailed = png == nil
    //   }
}
```

**Card layout.** It uses fixed fonts, never text styles. The one exception is the reused strip, which the `.large` override pins.
- **Top row**: the wordmark (13 pt heavy condensed, tracking 1.6, `Theme.ink`) and the week (13 pt bold condensed, uppercase, `Theme.secondary`).
- **Score block**:
  - the headline (13 pt bold condensed uppercase)
  - an `HStack(alignment: .lastTextBaseline)` with two sides; each is a label over `Text(points).font(.score(size: 60)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.5)`
  - the summary (15 pt)
- **Strip**: `CompetitionWeekStrip(days: recap.days, currentDayOrdinal: nil)` when `days` isn't empty. No new strip parameter.
- **Highlights**: an `HStack(alignment: .top, spacing: 16)`.
- **Footer**: a `Theme.hairline` rule, then the belt line and "healthcomp.app" (12 pt `Theme.secondary`).
- `Spacer`s between the blocks fill the fixed height.
- **No new colors**, and no `BrandMark`, because it uses ring colors.

**B. `CompetitionWeekChart.swift`**: in `competitionWeekText(_ first: CompetitionDay, _ last: CompetitionDay, …)` (`:625-644`), add the parameter **right after `_ last`**:
```swift
func competitionWeekText(_ first: CompetitionDay, _ last: CompetitionDay, includesYear: Bool? = nil,
                         now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
// passes includesYear: includesYear ?? (last.year != competitionYear(of: now, timeZone: timeZone))
```
- Existing callers don't change. `competitionWeekText(first, last, includesYear: true, locale:)` compiles because labelled arguments keep declaration order.
- `CompetitionDateFormatting.swift` and `CompetitionWeekStrip` don't change.

**C. `CompetitionDetailView.swift`, `CompetitionDrawer`** (`:457-494`): add `var detents: Set<PresentationDetent> = [.medium, .large]` after `subtitle`, and use it at `:490`. This is additive. It is a parameter rather than an outer modifier because the drawer applies its own `.presentationDetents` inside.

**D. `CompetitionResultView.swift`**
- **Extract the outcome.** The private `outcome` (`:770-776`) becomes `competitionResultOutcome(competition)`. Add next to `competitionResultTitle` (`:809`):
  ```swift
  /// The decided outcome, or the shown totals before a terminal result exists.
  func competitionResultOutcome(_ competition: LocalCompetitionPresentation) -> CompetitionOutcome
  ```
- **State**: after `:23`, add `@State private var showsShare = false`.
- **Body**: between the `.preservedHistory` block (ending `:72`) and `if dynamicTypeSize.isAccessibilitySize` (`:75`), add `if source == .remoteParticipants { shareResultButton }`.
  ```swift
  private var shareResultButton: some View {
      Button { showsShare = true } label: { Label("Share Result", systemImage: "square.and.arrow.up") }
          .buttonStyle(SecondaryButtonStyle())
          .accessibilityHint("Opens a preview of the image to share")
          .accessibilityIdentifier("competition.result.share")
  }
  ```
- **Sheet**: after `:131-133`, add `.sheet(isPresented: $showsShare) { CompetitionRecapSheet(competition: competition, belt: competitionRecapBelt(beltEvent, outcome: competitionResultOutcome(competition), isRetired: !competitionRecapAllowsNameChoice(competition))) }`.

**E. Belt input (from PR 1)**

- PR 1 replaces `CompetitionResultView`'s `awards` with `let beltEvent: CompetitionBeltEvent?` and updates both call sites (`MainTabView.destination(for:)`, `MainTabView.swift:296-308`, and `MultiUserCompetitionTestLabView.destination`, `:286-294`). This PR touches neither call site's arguments.
- This PR adds one adapter in `CompetitionRecapView.swift`, exactly as in the integration amendments: `func competitionRecapBelt(_ event: CompetitionBeltEvent?, outcome: CompetitionOutcome, isRetired: Bool) -> CompetitionRecapBelt?`. It returns `nil` on `.tie`, on a retired pair ("Former competitor"), and for a kept reign under 3 weeks.
- The glyph is PR 1's `CompetitionBeltMark(holder: .you, width: 22)`, on your lines only.
- **Belt-line coverage:** the unit tests, the DEBUG `XCTAttachment` captures, and the UI test's Casey card, which ends "Casey took the belt." (amendments).

**F. Test lab fixture: `MultiUserCompetitionTestLabView.swift`**

This gives the UI test a real name to show and hide. "Former competitor" now never shows a name choice.
- Add `static let caseyID = CompetitionID(UUID(uuidString: "A1000000-0000-4000-8000-00000000000A")!)`.
- Add a `casey` presentation built with the existing `presentation(...)` helper:
  - `opponentName: "Casey"`
  - `lifecycle: .completed(outcome: .loss, basis: .stableAcrossPostBoundaryReads, completedAt: completedAt)`
  - `userPoints: 2_692`, `opponentPoints: 2_800`
  - `days: completedDays()`, `currentDayOrdinal: nil`
  - a matching `LocalCompetitionTerminalPresentation`
  - `startDay` 13, the same week as Former competitor: Thu Aug 13 – Wed Aug 19 2026, completed Aug 20
- Add it to `competitions`. Add no award.
- New `private static func completedDays()`, patterned on `activeDays`:
  - all 7 days `.observed` with `scoringPolicy: .remoteWireV1` and no snapshots
  - owner `[420, 380, 300, 512, 400, 350, 330]`, opponent `[450, 400, 360, 380, 420, 390, 400]`
  - result: you won day 4 (Sun) only, lost by 108, and the best day is Sun 512
- Other UI tests find cards by name (`sharingCard(state:name:)`) and assert no card counts, so they are unaffected. Only the `remote-home-groups` screenshot changes.

**G. `project.yml` / plists / scripts**
- `project.yml`, under `targets.HealthComp.info.properties`, after `:48`:
  `NSPhotoLibraryAddUsageDescription: "HealthComp saves your match result image to Photos when you choose Save Image."`
- `HealthComp/Resources/Info.plist`: regenerated by XcodeGen, after `:40-41`.
- `Configuration/Staging-Info.plist`: add the same key by hand after `:50-51`. Otherwise `scripts/test-staging-apple-web-build-contract.sh` fails with `staging_base_plist_drift`.
- `scripts/verify-app-privacy-manifest.sh` (`--app-bundle` branch, `:47-50`): add a check that `.NSPhotoLibraryAddUsageDescription` is a non-blank string, otherwise `fail photo_add_usage_description_missing`.
- `scripts/test-app-privacy-manifest.sh` (pattern at `:53-62`): add the remove and blank cases, both expecting `photo_add_usage_description_missing`.
- `PrivacyInfo.xcprivacy`: no change. `@AppStorage` is covered by the existing `NSPrivacyAccessedAPICategoryUserDefaults` / `CA92.1`.
- `project.pbxproj`: regenerate with XcodeGen 2.46.0 and commit it. CI compares the hash.

**H. Privacy policy: `web/privacy.html`**
- In "Sharing and service providers", after the first paragraph's competitor sentence, add: "Either person can share an image of a finished match's result from the app. It shows both final scores, the week, which days each person won and up to two highlights, and the person sharing can hide the other person's name."
- In "Controls, deletion, and retained history", add: "If you choose Save Image for a result image, iOS asks for add-only Photos access, which you can change in Apple's system controls."
- Change the effective date (`:33`) to the merge date.
- `scripts/verify-website.sh` (`:46-48`): add `'image of a finished match'` to the `/privacy` expectations. The script's count of 9 checks doesn't change.
- The in-app consent row (`CompetitionInviteView.swift:469-470`) doesn't change (open question).

**I. Data flow**
`MainTabView.destination` / lab `destination` → `CompetitionResultView(…, beltEvent:)` (PR 1) → tap `competition.result.share` → `CompetitionRecapSheet(competition:, belt: competitionRecapBelt(beltEvent, outcome:, isRetired:))` → `recap` (pure, recomputed per render) → `.task(id: recap)` → `competitionRecapImage` (`@MainActor`) → `pngData()` → `CompetitionRecapPNG` + preview `Image` → `ShareLink`.
- No reducer, client, store or network change.
- `hidesName` lives only in `UserDefaults` on this iPhone.

#### Accessibility identifiers
- **Added**: `competition.result.share`, `competition.recap.card`, `competition.recap.name`, `competition.recap.share`, `competition.recap.error`.
- **Unchanged**: `competition.result`, `competition.result.summary`, `competition.result.week`, `competition.rematch.*`, `competition.more`. No renames.

#### Tests

**Unit: new `HealthCompTests/CompetitionRecapTests.swift`** (XCTest, `@testable import HealthComp`; the tests are `throws`)

Fixture helpers:
```swift
private let en = Locale(identifier: "en_US")
private func normalized(_ s: String) -> String  // U+2009/U+202F → " "
/// Nov 2 2026 is a Monday; ordinal 1...7 → Nov 2...8, UTC.
private func day(_ ordinal: Int, _ you: Double?, _ them: Double?) throws -> LocalCompetitionDayPresentation {
    LocalCompetitionDayPresentation(
        day: try CompetitionDay(era: 1, year: 2026, month: 11, day: 1 + ordinal, timeZoneIdentifier: "UTC"),
        ordinal: ordinal, ownerAcceptedPoints: you, ownerLatestAvailability: .observed,
        opponentRevealedPoints: them, scoringPolicy: .remoteWireV1)
}
/// Totals default to the day sums; outcome defaults to the totals. Built with
/// LocalCompetitionPresentation's memberwise init (as in CompetitionPresentationTests),
/// lifecycle .completed, terminalResult set, evaluatedAt Nov 20 2026, name "Sam".
private func match(_ days: [LocalCompetitionDayPresentation], user: Double? = nil, opponent: Double? = nil,
                   outcome: CompetitionOutcome? = nil, basis: … = .stableAcrossPostBoundaryReads,
                   name: String = "Sam") -> LocalCompetitionPresentation
```
Base days (you/them): Mon 330/300, Tue 260/330, Wed 284/330, Thu 512/300, Fri 400/350, Sat 300/344, Sun 326/314. That gives 2,412 against 2,268, a 144 margin, won 4 and lost 3, and down 86 after Wed.

- `testRecapHeadlineAndLabelsFollowOutcomeAndHiddenName`:
  - win → "Match won", label "Sam"
  - loss → "Sam won"; with the name hidden → "They won", "Them"
  - tie → "All square"
- `testHiddenNameNeverAppearsOnTheCard`: with `hidesName: true` and `belt: .theyKept(weeks: 4)`, no string field and not `accessibilityText` contains "Sam". The belt text is "They kept the belt · 4 weeks".
- `testFormerCompetitorIsAlwaysHidden`: with `name: "Former competitor"` and `hidesName: false`:
  - `competitionRecapAllowsNameChoice` is false
  - the label is "Them"
  - no field contains "Former competitor"
- `testRecapScoresAndSummaryMatchTheResultScreen`:
  - `marginText == competitionMarginText(...)` and `daysText == competitionDaysSummaryText(days)`
  - `user: 2104.30, opponent: 2104.00` → "2,104.30", "2,104.00", "Won by 0.30 points"
- `testRecapWeekAlwaysShowsTheYear`: `normalized(weekText) == "Nov 2 – 8, 2026"` with `evaluatedAt` in 2026. With `days: []`, it comes from the schedule window.
- `testComebackNeedsAWinAfterTrailingByFifty`:
  - the base days give exactly `[("Comeback", "Down 86 after Wed"), ("Best day", "Thu · 512")]`
  - Wed changed to 324/330 (down 46) → no comeback
  - the base days with `outcome: .loss` and the totals swapped → no comeback
- `testComebackSkipsWhenDaySumsDisagreeWithTheFinalScore`: the base days with `user: 2_420, basis: .bestAvailable` → no comeback; the highlights are `[Best day]` only.
- `testPhotoFinishIsUnderOnePercentOfTheWinner`:
  - Sun at 200/314 (2,286–2,268) → "Decided by 18"
  - totals 2,412–2,380 → none
  - a tie → none
  - 2104.30–2104.00 → "Decided by 0.30"
- `testPerfectDayTakesTheBestDaySlot`:
  - Thu 600 → "Perfect day" / "Thu · 600", and no "Best day"
  - Thu 599.6 → "Perfect day" / "Thu · 600"
  - Thu 599.4 → "Best day" / "Thu · 599"
  - Thu and Sat at 600 → "2 days at 600"
- `testHighlightsStopAtTwoInOrder`: Sun at 200/314 gives photo finish, comeback and best day. The result is exactly `[Photo finish "Decided by 18", Comeback "Down 86 after Wed"]`.
- `testBeltTextAndGlyphCoverEveryCase`:
  - the 4 cases × shown/hidden name
  - `isYours` is false for `.theyTook` / `.theyKept`
  - `competitionRecapBelt(nil, outcome: .win) == nil`, and a tie → `nil`
- `testRecapAccessibilityTextReadsTheCard`: with `belt: .youTook`, it equals `"Match won. Nov 2 to 8, 2026. You 2,412 points. Sam 2,268 points. Won by 144 points, won 4 days, lost 3. Comeback: down 86 points after Wednesday. Best day: Thursday, 512 points. Took the belt."`
- `@MainActor testRecapImageIs1080By1350AndAlwaysLight`:
  - render inside `UITraitCollection(userInterfaceStyle: .dark).performAsCurrent`
  - `size == 360×450`, `scale == 3`
  - pixel (3, 3) of `cgImage` ≈ `0xFAFAF7` (±2 per channel)
  - `UIImage(data: XCTUnwrap(image.pngData()))` is 1080×1350, at scale 1
- `testResultOutcomeUsesTerminalThenShownTotals`, for `competitionResultOutcome`.

**UI: `HealthCompUITests/MultiUserCompetitionUITests.swift`.** Add one new test, and don't extend the 4-case matrix. That keeps CI to one extra test.

`testShareResultPreviewsTheImageAndRemembersHideName`:
1. Run `launch(.sharing)`. Open `sharingCard(state: "completed", name: "Casey")` with `scrollToElement` and `revealRemoteElementFully`, then tap it, and wait for `navigationBars["Casey"]`.
2. Get `share = app.buttons["competition.result.share"]`. Call `scrollToElement(share)`, assert `isHittable`, then tap it.
3. Wait for `card = app.descendants(matching: .any)["competition.recap.card"]`. Tap `app.buttons["Show Casey"]`, which normalizes any leftover state.
4. `XCTAssertEqual(card.label, "Casey won. Aug 13 to 19, 2026. You 2,692 points. Casey 2,800 points. Lost by 108 points, won 1 day, lost 6. Best day: Sunday, 512 points. Casey took the belt.")`. Then wait until `app.buttons["competition.recap.share"].isEnabled`, using a predicate.
5. Tap "Hide name". The label must equal the same string with "They won." and "Them 2,800 points", and must not contain "Casey".
6. Tap "Close", reopen the sheet, and assert the label `hasPrefix("They won.")`. Tap "Show Casey", then "Close".
7. Run `navigateBackToSharing()` and open the "Former competitor" result, then Share Result. Assert:
   - the label equals `"Match won. Aug 13 to 19, 2026. You 3,520 points. Them 3,410 points. Won by 110 points."`
   - `competition.recap.name` doesn't exist
   - Then tap "Close".
8. Relaunch with `["-AppleInterfaceStyle", "Dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-UIAccessibilityReduceMotionEnabled", "YES"]` and open Casey.
   - On the **result screen, before opening the sheet**, run `assertRemoteRenderedConfiguration("Appearance: Dark; Dynamic Type: accessibility5")`. The banner sits behind the sheet, so this check is never run while the sheet is open, the same as the matrix's challenge-drawer step.
   - Call `scrollToElement(share)` (at AX5 the button is in the scroll, not pinned), then tap it and wait for the card.
   - Assert `app.switches["competition.recap.name"]` exists.
   - Run `try app.performAccessibilityAudit(for: .textClipped ∪ .hitRegion ∪ .sufficientElementDescription)`.
   - Attach the screenshot `"remote-recap-Dark-accessibility5"`, then tap "Close".

Don't add `-healthcomp.recapHidesName` to `launch()`: the argument domain would outrank the app domain, so the choice would never stick. The test resets the choice itself.

In `.github/workflows/ci.yml` (`:212-229`), add `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testShareResultPreviewsTheImageAndRemembersHideName`.

No existing exact-string assertion changes. The local fixture never shows Share Result.

**Scripts** (CI "Core checks"): `bash scripts/test-app-privacy-manifest.sh`, `bash scripts/test-staging-apple-web-build-contract.sh`. Website: `scripts/verify-website.sh` against `wrangler pages dev web`.

**Not needed:** CompetitionCore `swift test`, the standalone formatter script, pgTAP, Deno.

#### Verify on the Mac mini (on top of the shared steps)
1. Copy the tree: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/ua/recap-card/src && tar -x -C ~/dev-desktop/ua/recap-card/src'`.
2. Run `~/dev-desktop/ua/ua-mac6.sh xcodegen recap-card`, which prints the regenerated pbxproj's SHA-256.
   - The extracted tree has no `.git`, so compare hashes instead of running `git diff`. The printed hash must equal `sha256sum HealthComp.xcodeproj/project.pbxproj` on the VM.
   - `ssh … 'shasum -a 256 ~/dev-desktop/ua/recap-card/src/HealthComp/Resources/Info.plist'` must equal the VM's `sha256sum HealthComp/Resources/Info.plist`.
3. Run `ua-mac6.sh unit recap-card -only-testing:HealthCompTests/CompetitionRecapTests`, then the full `unit` mode.
4. Run `ua-mac6.sh ci recap-card`. It reads the UI list from `ci.yml`, so it includes the new test.
5. Manual check on the iOS 18.5 simulator, on the lab's Casey result:
   - Share → **Save Image**: the Photos prompt shows the new string and nothing crashes. The saved photo is 1080 × 1350 PNG.
   - Share → Messages: the image and the "Casey won" title show.
   - Dark mode: the sheet goes dark and the card stays light.
6. Repeat step 5 on the iOS 26.5 simulator (Xcode 26.6).
7. Captures for the preview artifact:
   - the Casey result screen with Share Result
   - the sheet in light and dark at XS and AX5
   - three cards from a DEBUG-only `XCTAttachment(image:)`, not committed: a win with "Took the belt", a loss with the name hidden, and a 2-decimal photo finish
8. Website: run `scripts/verify-website.sh` against the local Pages emulator.

#### Risks and conflict regions
- **Belt PR**:
  - it edits `CompetitionResultView` (awards → belt panel, a new `belt` input), `MainTabView.swift:296-308` and possibly the lab call site at `:286-294`
  - this PR rebases onto it and only adds `shareResultButton`, `showsShare`, the sheet and `competitionResultOutcome`
  - if the belt input lands under another name, re-anchor the adapter
  - if the belt glyph uses a non-Theme color, the card drops the glyph
- **Other features this round**:
  - `project.yml` / `project.pbxproj`: the widget adds a target. Always regenerate after a rebase; never hand-merge.
  - the `ci.yml` `-only-testing` list
  - `CompetitionDrawer`: the `detents` parameter is additive
  - `MultiUserCompetitionTestLabView` fixtures: other features may add fixtures, so use the id allocated in §4 (`…000A`)
  - `web/privacy.html`: other features may edit it, so merge the sentences and keep one effective date
  - this PR no longer touches `CompetitionWeekStrip`, so it doesn't conflict with Live there; `competitionWeekText` gets a defaulted parameter only
- **`Transferable` PNG**: if Save Image doesn't appear for `DataRepresentation(.png)` on iOS 18.5, add `ProxyRepresentation { Image(uiImage: UIImage(data: $0.data)!) }`. This is manual check 5.
- **Light-only rendering**: the image test pins that `Color(uiColor:)` dynamic colors resolve from `.environment(\.colorScheme, .light)` inside `ImageRenderer`. If they don't, also render inside `UITraitCollection(userInterfaceStyle: .light).performAsCurrent`.
- **Segmented label truncation**: long names truncate below `.xxLarge`. VoiceOver reads the full label.
- **Two `.sheet` modifiers on one view**: supported on iOS 17+, and the two are never presented together.
- **Main-thread render**: one render per `recap` change, a few ms. The roughly 5.8 MB RGBA image plus the PNG are held only while the sheet is open.

#### Rollout and compatibility
- App only, plus a static website edit. No server change, migration, Edge Function or push copy.
- Installed older builds are unaffected.
- No App Store privacy label change: nothing is collected, and Photos access is add-only and started by the person.
- The privacy page update ships with this PR's merge. The owner confirms it is live before the TestFlight build that contains Share Result.
- Ships in the next TestFlight build after the belt PR merges.

#### Claude's calls (overrule any)
- The summary line follows the result screen, not the mockup's "4 of 7 days".
- A perfect day (displayed 600) takes best day's slot.
- No belt line on a tie (open question).
- The belt glyph appears only next to your own belt lines.
- "Former competitor" is always hidden, with no name choice.
- Share Result is a secondary button in the scroll, not a second pinned button.
- The sheet closes with the standard drawer ×, and the button says "Share".
- The week always shows the year.
- The strip keeps the app's weekday labels, tertiary tie color and default bar height.
- The wordmark is text only.
- Hide name is one setting for all people.

#### Review notes
Applied:
1. **Matrix config assert under the sheet** (major): confirmed. `assertRemoteRenderedConfiguration` reads the lab banner behind the sheet, and the matrix's challenge-drawer step skips it. The matrix extension is dropped. The new test asserts on the result screen before opening the sheet, and calls `scrollToElement` before tapping.
2. **Stale image**: confirmed. The task is now keyed on `.task(id: recap)`.
3. **Lab call site**: confirmed (`MultiUserCompetitionTestLabView.swift:286-294`). It is named in Design E and Risks, and belt-line coverage is stated as unit tests plus captures only.
4. **`includesYear` placement**: confirmed. The signature is now spelled out, with the parameter right after `_ last`.
5. **Perfect day rounding**: confirmed (`competitionPointsText` rounds; `isDailyMaximum` uses the raw value). Perfect day is now decided on the displayed value, with 599.6 and 599.4 test cases.
6. **Accessibility trailing period**: the rule is now ". " joins plus a trailing ".", with the exact strings written out.
7. **Fixture under-specification**: confirmed (`CompetitionDay.init` throws; `ownerLatestAvailability` has no default, and `.notYetOccurred` → `.upcoming`). The helper signatures are given, and the impossible Day-7 case is dropped.
8. **`git diff` with no `.git`**: confirmed. Fixed with the hash that `ua-mac6.sh xcodegen` already prints, compared with `sha256sum` on the VM. This replaces `git init`, which would be extra steps.
9. **PNG Transferable**: applied. It is 6 lines and makes the size and type unit-tested.
10. **Privacy disclosures** (major): applied to `web/privacy.html` and `verify-website.sh`. The consent row is an open question, defaulting to no change.
11. **Belt glyph amber next to them** (major): confirmed. The playbook glyph uses `#F2A100` and `#FFF3D6`, and the mockup's History rows show it for Sam's weeks too. Fixed by drawing the glyph only on your lines, and requiring Theme tokens or no glyph. The suggestion to tint the glyph ink was not taken: an ink plate on an ink strap doesn't read, and tinting is the belt PR's view.
12. **Former competitor**: applied. The name is always hidden and there is no name choice. A named "Casey" lab fixture now carries the Show/Hide test.
13. **VoiceOver text**: applied: full weekday names, " · " → ", " in every part, the week included, and the "Result image" prefix dropped (`.isImage` stays).
14. **Comeback from final values**: applied. The wording now says "final day scores", the comeback requires the day sums to agree with the final margin, and there is a best-available test.
15. **Belt on a tie**: applied as an open question, defaulting to no line on a tie. Not applied: reading "reached 3+ weeks" as *exactly* 3. Any kept reign of 3 or more weeks after a win shows the line, and the reign definition comes from the belt PR.
16. **Scope/CI**: partly applied.
    - One new UI test and no matrix extension.
    - `barHeight` is dropped, and the default strip is used.
    - **Kept** the additive `detents` parameter: about 560 pt of content doesn't fit `.medium`, and capping the preview small enough to fit would make it about 180 pt wide.
    - **Kept** size M, because the privacy page, plist guard and lab fixture are real work.
    - Merge order relative to Live no longer matters for `CompetitionWeekStrip`.

#### Owner actions for this feature (merged into §7)
- Approve the preview artifact before the PR opens. It contains: the Casey result screen with Share Result; the sheet in light and dark at XS and AX5; and three rendered cards (a win with "Took the belt", a loss with the name hidden, and a 2-decimal photo finish).
- Answer the recap open questions or accept their defaults: first-share name default, card always light, footer domain, simulated matches, other-person highlights, Former competitor, belt line on a tie, and consent-row wording.
- Before the TestFlight build with Share Result goes out, confirm that the updated privacy policy (new result-image sentence, Photos add-only line, new effective date) is live at healthcomp.app/privacy.

### 9.3 PR 3 and 14: What it takes: Today panel (PR 3) and 7 PM reminder (PR 14)

Branches: `feature/what-it-takes` → `feature/what-it-takes-reminder` · Server: no · Size: M · Stakes: none

#### Integration amendments (override the text below)
- This section covers two PRs. **PR 3** (`feature/what-it-takes`) is everything under "PR (a)". **PR 14** (`feature/what-it-takes-reminder`) is everything under "PR (b)", and it now merges **after PR 13** (§4).
- **PR 3** has no dependencies. Its panel also shows on a practice week (PR 12): same Today page, the pacer as `{Name}`. Claude's call.
- **PR 14 switch (replaces the flag reading).** Drop the `includesWhatItTakes` parameter and the fallback that adds a `whatItTakes` flag to a preferences document. Instead PR 14:
  - adds `case whatItTakes = "what-it-takes"` to PR 13's `CompetitionNotificationChoice`, between `closeScore` and `finalDay` (title "What it takes", key `healthcomp.notifications.what-it-takes`, id `account.notifications.choice.what-it-takes`);
  - adds `case .scheduled(.whatItTakes): .whatItTakes` to PR 13's exhaustive `choice` mapping. PR 13's scheduled filter (`scheduledRequests(...).filter { !$0.message.family.isOff(in: switchedOff) }`) then drops the reminder when the switch is off, before `mergedScheduledRequests`;
  - planner tests pass `switchedOff: [.whatItTakes]` through PR 13's `plan` helper instead of `whatItTakes: false`; the coordinator test's revision 3 uses `switchedOff: { [.whatItTakes] }`;
  - updates PR 13's `testNotificationChoiceKeysAndTitlesNeverChange` (seven cases, this order), `testEveryMessageFamilyMapsToItsSwitchOrIsAlwaysOn`, and the UI test's row list in `testNotificationsPageOpensSettingsAndUnmutes`.
- **Default On** (merged Q-takes-1 / PR 13's "every row on"). Mention it in the TestFlight notes.
- **Message fields** sit beside PR 1's `beltTake` in `CompetitionNotificationMessage`.
- **Practice** never gets a reminder: it is never added to the notification snapshot.

#### PR scope
- `feature/what-it-takes`: PR (a): the Today-tab panel. Adds the pure `competitionWhatItTakes(_:locale:)`, the `CompetitionWhatItTakes` value and the `CompetitionWhatItTakesPanel` view to ActivityRingsView.swift, next to `competitionRingPanel`, and shows the panel above the ring panel in CompetitionDetailView `todayActivity`. Suggestions use Move and Exercise only (one or two rings). Adds unit tests to CompetitionPresentationTests and one local-fixture UI test. App only. No new files, no project.yml change.
- `feature/what-it-takes-reminder`: PR (b): the 7 PM reminder as a new scheduled family `what-it-takes` in CompetitionNotificationPlanner, gated by the Notification choices switch (notifs owns its default). Both projectors carry `competitionWhatItTakes` into `CompetitionNotificationCompetitionSnapshot`. The fire day comes from the value's own `dayOrdinal`; the zone suffix is computed at the match day's end instant. When several matches fire at the same time, only the one with the smallest gap fires. Adds planner, coordinator and remote projector tests. App only.

Branches: `feature/what-it-takes` (PR a) → `feature/what-it-takes-reminder` (PR b) · Base: `main` at 8c5ca25 · App only, no server

#### Scope
- **PR (a), panel.** On a live day where you're behind or level on the week, the Today page shows one panel above your ring panel. It says how many points take the lead and turns that into one or two of your own rings, Move and Exercise ("About 240 kcal of Move or 12 min of Exercise."). When Move and Exercise can't cover the gap today, it says "Out of reach today".
- **PR (b), reminder.** A reminder at 7 PM, at most once a day, and only while the lead can still be taken today. It is a new scheduled family, `what-it-takes`, in `CompetitionNotificationPlanner`. The "What it takes" switch from Notification choices (`notifs`) gates it, and `notifs` owns that switch's default.
- **Not in scope:**
  - Stakes, in any form (the owner rejected them).
  - Any server, migration or Edge Function change.
  - Home cards. One job per screen: the line lives only on the match's Today page.
  - A walking-minutes model (see Deviations).
  - Stand suggestions (see Q-takes-6).

#### What the code actually has on the iPhone (checked, not assumed)
| Input | Local fixture | Real (Supabase) match |
|---|---|---|
| Today's accepted snapshot (values **and goals**, in `ActivityRingReading.value/goal`) | `ledgerEntry?.acceptedScore?.snapshot` (LocalCompetitionClient.swift:1625) | `RemoteOwnerActivity.Day.acceptedSnapshot`, from the profile inventory cache (HealthComp/Services/RemoteCompetitionRuntime.swift:14-42). The projector shows it only when `acceptedClientRevision == owner row clientRevision` (RemoteCompetitionClient.swift:2261-2264) |
| Latest snapshot | latest completed read (`ownerLatestSnapshot`) | `activityDay?.latestSnapshot`. It can be newer than the accepted one (RemoteCompetitionClient.swift:2264-2266) |
| Scoring policy | `.healthKitCompatibility`: **no per-ring cap**, 600 a day (Modules/CompetitionCore/Sources/CompetitionCore/ActivityScore.swift:105-109) | `.remoteWireV1`: **200% per ring**, 600 a day (same file :115-119). Set on every remote day (RemoteCompetitionClient.swift:2279) |
| Today's accepted points | `ownerAcceptedPoints` (whole) | `acceptedCentiPoints / 100`, so **fractional** (RemoteCompetitionClient.swift:2269-2271) |
| The other person's points today | `opponentRevealedPoints` (grows through the day) | `opponentRevealedPoints` = their accepted points |
| Week totals | `userPoints` / `opponentPoints` | Ledger totals (RemoteCompetitionClient.swift:2158-2162). These already include the other person's accepted points for today |
| Current day | `currentDayOrdinal` (from the clock) | `currentDayOrdinal` from the clock (:2177-2180, :2335-2352). The lifecycle comes from the journal (:2128-2131), so the two can differ after the no-network boundary republish (:1739-1745) |

- **Real matches with no usable accepted snapshot on this phone get no panel:**
  - the score came from another device
  - the match finished before PR #180
  - the first read after an update hasn't happened yet
  - the newest reading hasn't synced yet (accepted nil, latest set: "These points haven’t synced yet.")
  - the accepted reading is older than the latest one (the ring panel's "Points use an earlier reading. Your rings have changed since.", ActivityRingsView.swift:73-79)

  The function needs an accepted snapshot that matches the latest one. Otherwise the suggestion would ask for kcal or minutes you may already have done.
- **The multi-user Test Lab** uses `.remoteWireV1` with accepted snapshots. You lead in both of its live matches (Jordan 1,450–1,440, Riley 1,020–990), so the panel never appears there. Its existing UI and AX5 tests don't change.

#### Behavior

##### When the panel shows
All of these must be true:
- lifecycle `.active` or `.endsToday`
- `currentDayOrdinal` is set and that day is in `days`
- that day has `ownerAcceptedSnapshot` and `ownerAcceptedPoints`
- `ownerLatestSnapshot` is nil or equals `ownerAcceptedSnapshot`
- the **displayed** margin `competitionDisplayedMargin(userPoints:opponentPoints:)` is ≤ 0

It is hidden when you lead, while tallying, on scheduled, pending and finished matches, on the Week page and in day drawers.

##### Numbers
- `margin = competitionDisplayedMargin(...)` (whole points as shown). `need = 1 − margin`. Adding `need` whole points always makes the shown margin exactly +1.
- `left = max(0, ActivityScore.maximumDailyPoints − today)`, where `today = ownerAcceptedPoints`.
- Per-ring room, **Move and Exercise only**. A ring whose value or goal is unusable (the same test as `competitionRingShares`, CompetitionWeekChart.swift:454-466) gets room 0.
  - `.remoteWireV1`: `room = min(left, max(0, 200 − share × 100))`, with `share` from `competitionRingShares(snapshot, perRingCap: 200)`
  - local fixture (`perRingCap == nil`): `room = left`
- `reach = floor(min(left, roomMove + roomExercise))`. This one whole number decides reachable vs out of reach **and** is the number printed. Fractional remote points can't make the copy contradict itself.
- Reachable iff `need ≤ reach`.

##### Copy (exact)
**Reachable.** Headline (amber, `Theme.you`): **"{N} to take the lead"**, N = `need`. "Sam leads by 38." gives "39 to take the lead". "All square." gives "1 to take the lead".

Detail (secondary) = `suggestion` + `" {Name} can still add points today."`. The second sentence is added only when today's `opponentRevealedPoints` is nil or below `ActivityScore.maximumDailyPoints` (600). Once they've hit today's cap it isn't true, so it is dropped.

| Case | Suggestion |
|---|---|
| Move and Exercise can each cover N on their own (`room ≥ need`) | "About 240 kcal of Move or 12 min of Exercise." (more room first; Move first on ties) |
| Only one can | "About 12 min of Exercise." |
| Neither alone, both together | "About 180 kcal of Move and 6 min of Exercise." (more room first. It takes all of its room, and the other ring takes the rest) |

- A ring with `room ≤ 0` is never a single or a split part.
- There are never more than two rings. **Stand is never suggested or counted** (Q-takes-6).
- **Ring names:** "Move", or "Move Time" with unit "min" when `moveMode == .moveMinutes`; "Exercise".
- **Amounts.** `p` points of a ring with goal `g` is `p/100 × g`, rounded **up**: kcal to the next 10, minutes to the next whole number, minimum one step. Subtract `1e-9` before rounding up, so that 30% of 30 min is 9, not 10. Numbers use `.number.precision(.fractionLength(0)).locale(locale)`, so 1,240 kcal reads "1.240 kcal" in de_DE.

**Out of reach** (`need > reach`). Headline (ink): **"Out of reach today"**. Detail, with `{gap} = competitionPointsText(−margin)`:
| State | Detail |
|---|---|
| behind, `reach ≥ 1` | "{Name} is {gap} ahead and you have {reach} points left in Move and Exercise today." (1 → "1 point") |
| behind, `floor(left) == 0` | "{Name} is {gap} ahead and you’ve reached today’s cap." |
| behind, `reach == 0`, `floor(left) ≥ 1` (both rings at 200%) | "{Name} is {gap} ahead and Move and Exercise are at the 200% cap." |
| level, `floor(left) == 0` | "All square, and you’ve reached today’s cap." |
| level, `reach == 0`, `floor(left) ≥ 1` | "All square, and Move and Exercise are at the 200% cap." |

**VoiceOver.** The panel is one element. Its label is the headline + detail, with spoken numbers (`competitionPointsAccessibilityText`, which already says "1 point") and spoken units that are **singular at exactly 1** ("1 minute", "1 kilocalorie"; otherwise "minutes", "kilocalories"):
- "39 points to take the lead. About 240 kilocalories of Move or 12 minutes of Exercise. Sam can still add points today."
- "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Alex can still add points today." (loss fixture, Day 1)
- "Out of reach today. Sam is 380 points ahead and you have 110 points left in Move and Exercise today."

##### Reminder (PR b)
- **Title:** "{N} to take the lead from {Name}"
- **Body:** "{suggestion} Day {d} ends at midnight." When the match zone's offset differs from the phone's **at the match day's end instant**, the abbreviation **for that instant** is appended ("…ends at midnight EST."). This is exactly the status line's `zone(_ instant:)` rule (CompetitionSharingView.swift:1371-1380): `secondsFromGMT(for:)` and `abbreviation(for:)`, never the current moment's offset.
- **Timing:** 7:00 PM in the match's time zone, on the day in `CompetitionWhatItTakes.dayOrdinal` (the same day N and "Day {d}" describe). It is scheduled only when all of these hold:
  - the switch is on
  - the opponent isn't muted
  - notifications are authorized
  - `whatItTakes?.points != nil` (reachable, and the panel's snapshot guards passed)
  - 7 PM is still ahead
- **One per day across matches.** Live matches that share a fire time post one reminder: the smallest N, ties broken by identifier. It keeps its route to that match.
- **Once a day.** It is naturally at most once a day: one identifier per match (`competition-notification:v1:<id>:what-it-takes`), and nothing is scheduled once 7 PM has passed.
- **Staying current.** Every publication re-plans the reminder. The content is re-upserted when it changes (the coordinator's `knownPendingRequests` diff). It is removed when you take the lead, the gap goes out of reach, or the accepted reading falls behind the latest one.
- **What triggers a re-plan.**
  - HealthKit background delivery (`com.apple.developer.healthkit.background-delivery`, HealthComp/Resources/HealthComp.entitlements:19) re-plans as your Activity changes.
  - The other person's newer points arrive only when the app reconciles.
- **Switch off.** The plan no longer includes the request, so the coordinator's obsolete pass removes it. Notification choices calls `reconcileLatest()` after a toggle (that is its job).
- **Privacy.** No server push, and nothing new reaches the server or the other person.

##### Deviations from the mockup (closest correct behavior)
1. **"38 to take the lead" → 39.** In the mockup, 1,150 − 1,112 = 38 would only tie. The playbook's own rule is "the gap … plus 1 point".
2. **Amber tint `#FFF3D6` isn't a Theme token** (no new colors). The panel uses `themePanel()` with the headline in `Theme.you`, so amber still means "you". Out-of-reach uses ink.
3. **"About 230 kcal … or 11 min" → amounts are rounded up**, so following the suggestion always takes the lead: 39 points becomes 240 kcal and 12 min. The comma before "or" is dropped.
4. **"About 20 minutes of walking" (lock screen).** The code has no kcal-per-minute or pace model. The reminder reuses the panel's ring suggestion. Exercise minutes are the closest real unit for a brisk walk.
5. **The reminder title adds the name** ("…from Sam"). With two live matches, a bare "38 to take the lead" can't say which match it means. Local notifications already name people. The server-push no-names rule (audit §10 Q3) doesn't apply here.
6. **The "target can move" rule** has no text in the mockup. It is the second sentence of the detail, shown only while it's true: "{Name} can still add points today."
7. **"up to 200% per ring"** is true only for real matches. The local fixture has no per-ring cap, and the footer under the ring panel already says which rule applies (ActivityRingsView.swift:80-86).
8. **"…you have 210 points left before today's cap" → "…you have 110 points left in Move and Exercise today."** In the mockup's numbers (Move 540/600, Exercise 60/30, Stand 12/12, today 390), 100 of the 210 points are Stand room that would take 12 more stand hours. Only Move and Exercise count (Q-takes-6).

#### Design

##### PR (a): `HealthComp/Features/Competition/ActivityRingsView.swift`
Add after `competitionRingPanel` (:27-104). It goes in the same file, so there is no project.yml or pbxproj change. It is a free function in a Swift 5.9-mode target (project.yml `SWIFT_VERSION: "5.9"`), so the notification projectors can call it off the main actor.
```swift
/// "39 to take the lead" on a live day when you're behind or level; nil otherwise.
struct CompetitionWhatItTakes: Equatable, Sendable {
    /// The day these numbers describe (the presentation's currentDayOrdinal).
    let dayOrdinal: Int
    /// Whole points that take the lead; nil when out of reach today.
    let points: Double?
    let headline: String            // "39 to take the lead" | "Out of reach today"
    let suggestion: String          // "About 240 kcal of Move or 12 min of Exercise." | out-of-reach sentence
    let detail: String              // suggestion (+ " Sam can still add points today." when reachable and true)
    let accessibilityLabel: String
}

func competitionWhatItTakes(_ competition: LocalCompetitionPresentation, locale: Locale = .current) -> CompetitionWhatItTakes?
```
(`CompetitionPresentation` is a typealias of `LocalCompetitionPresentation`, CompetitionClient.swift:15, so both projectors can call it.)

Body, in order:
1. `guard case .active/.endsToday`, `let d = currentDayOrdinal`, `day = days.first { $0.ordinal == d }`, `snapshot = day.ownerAcceptedSnapshot`, `today = day.ownerAcceptedPoints`, and `day.ownerLatestSnapshot == nil || day.ownerLatestSnapshot == snapshot`, else return nil.
2. `margin`, guard `margin <= 0`, then `need`, `left`.
3. `shares = competitionRingShares(snapshot, perRingCap: day.scoringPolicy.perRingCap)`. Build two rings, `(title, goal, unit, spokenUnit, step, room)`, for Move (`snapshot.move`; "Move Time"/min/step 1 when `.moveMinutes`, else "Move"/kcal/step 10) and Exercise (`snapshot.exercise`, min, step 1). `room` uses the rule above, 0 when unusable. Then `reach`.
4. If `need > reach`, return the out-of-reach value (`points: nil`, `suggestion == detail` = the table sentence).
5. `rings` = the two with `room > 0`, sorted by room descending (Move first on ties). `singles = rings.filter { $0.room >= need }`. If it's non-empty, join the singles' `amount(need)` with " or ". Otherwise split: `a = rings[0]` takes `a.room`, `b = rings[1]` takes `need − a.room`. Join as "A and B".
6. `amount(p) = max(step, ((p / 100 * goal) / step − 1e-9).rounded(.up) * step)`. Spoken unit: singular when the amount == 1.
7. `opponentToday = day.opponentRevealedPoints`. Add the sentence when `opponentToday.map { $0 < ActivityScore.maximumDailyPoints } ?? true`.
8. Use `competitionPointsText` / `competitionPointsAccessibilityText` (CompetitionDateFormatting.swift:15, :26) for every point number. CompetitionDateFormatting.swift stays untouched (Foundation-only).

New view in the same file:
```swift
struct CompetitionWhatItTakesPanel: View {
    let takes: CompetitionWhatItTakes
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(takes.headline)
                .font(.title3.weight(.heavy).width(.condensed))
                .foregroundStyle(takes.points == nil ? Theme.ink : Theme.you)
                .fixedSize(horizontal: false, vertical: true)
            Text(takes.detail)
                .font(.subheadline).foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .themePanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(takes.accessibilityLabel)
        .accessibilityIdentifier("competition.takes")
    }
}
```
`.width(.condensed)` is iOS 16+, so it is fine on the 17.0 target and the 18.5 SDK. There is no ViewThatFits and nothing is tappable. Dynamic Type wraps up to AX5.

##### PR (a): `CompetitionDetailView.swift` `todayActivity` (:234-245)
Wrap the `if let day = activityDay` branch in a `VStack(alignment: .leading, spacing: 12)` containing `if let takes = competitionWhatItTakes(competition, locale: locale) { CompetitionWhatItTakesPanel(takes: takes) }` followed by the existing `dayActivity(day, showsPullHint: true)`. `locale` already exists (:15). The else branch is unchanged, and there are no reducer, state or action changes. Pull to refresh re-publishes, so the panel updates in place.

##### PR (b): `HealthComp/Services/CompetitionNotificationModels.swift`
- `CompetitionScheduledNotificationFamily` (:4-9): add `case whatItTakes = "what-it-takes"`. The `CaseIterable` users pick it up. Check every exhaustive `switch` on the family (planner content, summary).
- `CompetitionNotificationCompetitionSnapshot` (:80-133): add `let whatItTakes: CompetitionWhatItTakes?`, with the init parameter `whatItTakes: CompetitionWhatItTakes? = nil` last. Existing call sites and tests compile unchanged.
- `CompetitionNotificationMessage` (:187-198): add `var whatItTakes: CompetitionWhatItTakes? = nil`, `var matchTimeZoneIdentifier: String? = nil` and `var matchDayEnd: Date? = nil` (the midnight instant the body names).

##### PR (b): `CompetitionNotificationPlanner.swift`
- **`liveV1.scheduledFireDate` (:37-53):** `bySettingHour: family == .whatItTakes ? 19 : 9`.
- **`plan(...)` (:328):** reads the flag that Notification choices adds (expected `choices.whatItTakes: Bool`; notifs owns the default). Pass it to `scheduledRequests(for:snapshot:includesWhatItTakes:)` → `scheduledBases(…, includesWhatItTakes:)`. If notifs stores no flag for this family, this PR adds `whatItTakes` to its preferences document, read with `decodeIfPresent`, default `true` (the approved mockup).
- **`scheduledBases` (:541-590):** in the `.active` and `.endsToday` cases only (never `.tallying` or `.scheduled`), when `includesWhatItTakes`, `let takes = competition.whatItTakes`, `takes.points != nil`, `takes.dayOrdinal == competition.currentDayOrdinal` and `days.indices.contains(takes.dayOrdinal − 1)`, append `(.whatItTakes, try calendar.startOfDay(days[takes.dayOrdinal − 1]), timeZone)`. The day comes from the value, not from `.active(dayOrdinal)`, so the trigger, N and "Day {d}" always describe the same (clock) day, even when the journal lifecycle lags after the no-network boundary republish. The existing `fireDate > snapshot.evaluatedAt` guard (:499-505) drops it once 7 PM has passed.
- **`scheduledRequests` (:493-539):** for `.whatItTakes`, set `message.whatItTakes = competition.whatItTakes`, `message.dayOrdinal = takes.dayOrdinal`, `message.matchTimeZoneIdentifier = timeZoneIdentifier` and `message.matchDayEnd = try calendar.startOfDay(calendar.day(after: days[takes.dayOrdinal − 1]))`. Pass the end instant along with the base, for example as an optional fourth tuple element that is nil for other families.
- **`mergedScheduledRequests` (:459-491):** when `family == .whatItTakes`, pick `members.min { (pts($0), id($0)) < (pts($1), id($1)) }` with `pts = message.whatItTakes?.points ?? .infinity`. Append that candidate's own request, keeping its route, and drop the rest. This branch runs before the summary path.
- **`liveV1Content` (:75):** new case `.scheduled(.whatItTakes)`:
  - Title: `"\(points(need)) to take the lead from \(name)"`.
  - Body: `"\(takes.suggestion) Day \(d) ends at midnight\(zone)."`, where
    ```swift
    let zone: String = {
        guard let end = message.matchDayEnd, let id = message.matchTimeZoneIdentifier,
              let matchZone = TimeZone(identifier: id),
              matchZone.secondsFromGMT(for: end) != timeZone.secondsFromGMT(for: end)
        else { return "" }
        return " " + (matchZone.abbreviation(for: end) ?? id)
    }()
    ```
    `timeZone` is the existing device-zone parameter.
  - Guard fallback (no takes or no points): the existing catch-up copy.
- **`liveV1SummaryContent` (:195):** add `.scheduled(.whatItTakes)` to the fallback case list (:258-260) that returns `liveV1Content(first)`. It is unreachable, because this family is never merged into a summary.

##### PR (b): carry the value into planning
- Local `notificationCompetition` (LocalCompetitionClient.swift:1309-1369): `whatItTakes: competitionWhatItTakes(projected)`.
- Remote `notificationCompetition(from:profile:context:)` (RemoteCompetitionClient.swift:1974-2018): the same. `projected` already carries the `ownerActivity` snapshots.
- Remote CAS reload `notificationCompetition(reloading:...)` (:2025-2089): `whatItTakes: baseline.whatItTakes`. That path has no owner activity, and it recomputes `currentDayOrdinal` from `baseline.evaluatedAt`, so the `dayOrdinal == currentDayOrdinal` check still holds.
- `CompetitionNotificationCoordinator.swift` `replacingEmissionHistory` (:498-517): pass `whatItTakes: whatItTakes`.

#### Tests

**PR (a), `HealthCompTests/CompetitionPresentationTests.swift`.** Add a helper `takesCompetition(user:opponent:today:accepted:latest:policy:lifecycle:ordinal:opponentToday:)` with its own day builder. It does **not** reuse `ringDay` (:759), which hard-codes `ordinal: 1` and `opponentRevealedPoints: 200`. It builds a `LocalCompetitionPresentation` whose `currentDayOrdinal == ordinal`, with opponent "Sam", `latest` defaulting to `accepted` and `opponentToday` defaulting to 248. All cases use en_US unless stated.
- `testWhatItTakesNamesThePointsAndTheRoomiestRings`: `.remoteWireV1`, Day 5, Move 410/600, Exercise 24/30, Stand 8/12, today 215, totals 1,112 vs 1,150.
  - headline "39 to take the lead", `points == 39`, `dayOrdinal == 5`
  - detail "About 240 kcal of Move or 12 min of Exercise. Sam can still add points today."
  - label "39 points to take the lead. About 240 kilocalories of Move or 12 minutes of Exercise. Sam can still add points today."
- `testWhatItTakesIsOneWhenLevel`: 1,000 vs 1,000.2 gives "1 to take the lead".
- `testWhatItTakesHidesWhenYouLeadOrTheDayIsNotLive`: 1,001 vs 1,000 → nil. `.tallying`, `.scheduled` and a missing `currentDayOrdinal` → nil.
- `testWhatItTakesSaysOutOfReachWhenMoveAndExerciseCantCoverTheGap`, `.remoteWireV1`, `.endsToday`, ordinal 7:
  - Move 540/600, Exercise 60/30, Stand 12/12, today 390, 2,010 vs 2,390 → "Out of reach today" / "Sam is 380 ahead and you have 110 points left in Move and Exercise today.", `points == nil`
  - Move 1,200/600, Exercise 60/30, Stand 24/12, today 600 → "Sam is 380 ahead and you’ve reached today’s cap."
  - the same at 2,390 vs 2,390 → "All square, and you’ve reached today’s cap."
- `testWhatItTakesNeverSuggestsStandWhenMoveAndExerciseAreCapped`: `.remoteWireV1`, Move 1,200/600, Exercise 60/30, Stand 6/12, today 450, 1,000 vs 1,038 → "Out of reach today" / "Sam is 38 ahead and Move and Exercise are at the 200% cap." Level at 1,000 vs 1,000 → "All square, and Move and Exercise are at the 200% cap."
- `testWhatItTakesUsesOneWholeNumberForReachAndCopy`: `.remoteWireV1`, Move 300/600, Exercise 15/30, today 390.4 (left 209.6, reach 209):
  - 1,000 vs 1,209 → "Out of reach today" / "Sam is 209 ahead and you have 209 points left in Move and Exercise today."
  - 1,000 vs 1,208 → "209 to take the lead" / "About 900 kcal of Move and 18 min of Exercise. Sam can still add points today."
- `testWhatItTakesUsesMoveTimeMinutes`: `.moveMinutes` Move Time 20/30, Exercise 24/30 → "About 12 min of Move Time or 12 min of Exercise."
- `testWhatItTakesSkipsARingAtItsCapAndSplitsWhenNoRingCoversItAlone`, `.remoteWireV1`:
  - Move 1,200/600, Exercise 15/30, need 39 → "About 12 min of Exercise." (no "10 kcal of Move")
  - Move 1,020/600 (room 30), Exercise 52.5/30 (room 25), Stand 6/12, today 445, 1,000 vs 1,049 → "About 180 kcal of Move and 6 min of Exercise."
- `testWhatItTakesHasNoPerRingCapInTheLocalFixture`: Move 1,500/600, Exercise 24/30, Stand 8/12, today 396.7, under `.healthKitCompatibility` → "About 240 kcal of Move or 12 min of Exercise." The same snapshot under `.remoteWireV1` → "About 12 min of Exercise."
- `testWhatItTakesNeedsAnAcceptedSnapshotThatMatchesTheLatest`: accepted nil with latest set → nil. No snapshots → nil. Accepted A with latest B ≠ A → nil.
- `testWhatItTakesDropsTheMovingTargetWhenTheyAreAtTodaysCap`: `opponentToday: 600` → detail "About 240 kcal of Move or 12 min of Exercise." with no second sentence. `opponentToday: nil` keeps it.
- `testWhatItTakesRoundsAmountsUpGroupsByLocaleAndSpeaksSingularUnits`:
  - need 30 with an Exercise goal of 30 → "9 min" (epsilon)
  - Move goal 1,000, need 124 → "1,240 kcal" in en_US and "1.240 kcal" in de_DE
  - Move goal 100, Exercise goal 100, 0 vs 0 → label "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Sam can still add points today."

**PR (a), `HealthCompUITests/LocalCompetitionLifecycleUITests.swift`.** New `testLossFixtureShowsWhatItTakesAboveYourRings`:
- `launch(fixture: "loss", direction: "outgoing")`, wait for `app.navigationBars["Home"]`, tap `pendingSharingCard`, tap "Start with Alex".
- `nextCheckpoint()` **once**, then `XCTAssertTrue(waitForStatus("Day 1 of 7"))`. The first checkpoint is the Day 1 boundary (CompetitionTestLabView.swift:323-331; the existing test at :61-62 does the same).
- `let takes = app.descendants(matching: .any)["competition.takes"]` and `waitForExistence(timeout: 3)`.
- Assert `takes.label == "1 point to take the lead. About 10 kilocalories of Move or 1 minute of Exercise. Alex can still add points today."`. The loss fixture's goals are 100 kcal/100 min/100 hr (`pointsSnapshot`, :511-522), you score 0, and Alex's revealed points are 0 at progress 0 of Day 1. If the Mac mini run shows Alex already above 0 at the boundary, relax the assertion to `hasSuffix` on the units sentence and record why in the test.
- `takes.frame.minY < app.otherElements["competition.ownerRings"].frame.minY`. Then `capture("light-small-takes")`.
- `for _ in 0..<6 { nextCheckpoint() }`, `XCTAssertTrue(waitForStatus("Last day"))` (checkpoint 7, Ends Today), then `app.buttons["Today"].tap()`. Assert that `takes.label.hasPrefix("Out of reach today")` (Alex has six full days and you have 0) and that the label doesn't contain "of Move". Then `capture("light-small-takes-out-of-reach")`.
- This suite is **not** in CI's `-only-testing` list (ci.yml:212-228). It runs on the Mac mini, and CI is left unchanged to keep its runtime down.

**PR (b), `HealthCompTests/CompetitionNotificationPlannerTests.swift`.** Extend `liveMatch` with `whatItTakes:` and the `plan` helper with `whatItTakes: Bool = false`. With the flag off, existing expectations don't change.
- `testWhatItTakesReminderFiresAtSevenInTheMatchZoneWhenEnabled`: Day 5, `takes(dayOrdinal: 5, points: 39)`, `evaluatedAt` Day 5 12:00 → one request with id `…:what-it-takes`, trigger hour 19 in the schedule zone on Day 5, route `.competition(id)`.
- `testWhatItTakesReminderUsesTheValuesDayNotTheLifecycleDay`: lifecycle `.active(dayOrdinal: 4)`, `currentDayOrdinal` 5, `takes.dayOrdinal` 5 → the trigger is on Day 5. With `takes.dayOrdinal` 4 ≠ `currentDayOrdinal` 5 → no request.
- `testWhatItTakesReminderIsSkippedWhenOffOutOfReachLeadingMutedOrPastSeven`: flag off; takes nil (leading or stale reading); takes with `points == nil`; muted identity; `evaluatedAt` at Day 5 19:00:01; `.tallying`. None of them has a `what-it-takes` request.
- `testWhatItTakesReminderKeepsOnlyTheSmallestGapAcrossMatches`: two matches with the same start, points 120 and 39 → one request, for the 39 match, with a non-nil route.
- In `testLiveV1CopyForEveryFamily` (:1096), call `liveV1Content(message, locale: en_US, timeZone: America/Los_Angeles)`:
  - match zone LA, `matchDayEnd` 2027-01-16T08:00Z → "39 to take the lead from Alex · About 240 kcal of Move or 12 min of Exercise. Day 5 ends at midnight."
  - match zone America/New_York, `matchDayEnd` 2027-01-16T05:00Z (winter) → "…Day 5 ends at midnight EST."
  - match zone America/New_York, `matchDayEnd` 2027-07-16T04:00Z (summer) → "…Day 5 ends at midnight EDT."
  - The dates are pinned, so the result doesn't depend on when the test runs.
- Add `.whatItTakes` at 19:00 to `testLivePolicyV1OwnsTimingBudgetPriorityAndPrivacyCopy` (:7).

**PR (b), `HealthCompTests/CompetitionNotificationCoordinatorTests.swift`.** New `testWhatItTakesReminderIsRemovedOnceYouLeadOrTheSwitchIsOff`. `coordinatorFixture` (:1359-1375) returns `baseDate` (midnight) as the fire date, which the `fireDate > evaluatedAt` guard would drop. So this test uses its own policy, `coordinatorFixture` with `scheduledFireDate: { family, base, _ in family == .whatItTakes ? base.addingTimeInterval(19 * 3600) : base }`, and `evaluatedAt` at 12:00 on the current day:
- revision 1, takes set and the flag on → the id is upserted
- revision 2, takes nil → `removePending` includes it
- revision 3, flag off and takes set → nothing is upserted

**PR (b), `HealthCompTests/RemoteCompetitionRuntimeTests.swift`.** New `testNotificationSnapshotCarriesWhatItTakesFromOwnerActivity`. `OwnerActivityHarness.append` (:3748-3785) writes fixed basis points for anyone, so the test uses a **level** score: append Day 1 revision 1 for `harness.creatorID` and for `profileID` at `dayOneNoon`. Each scores 255 → 255–255.
- Set `materialization.ownerActivity` with `acceptedSnapshot == latestSnapshot == harness.snapshot(move: 420)` and `acceptedClientRevision: 1` (the same setup as :1772).
- Assert `RemoteCompetitionProjector.notificationCompetition(from:profile:context:)?.whatItTakes?.points == 1` and `dayOrdinal == 1`.
- `notificationCompetition(reloading:profileID:baseline:)` keeps `baseline.whatItTakes`.

#### Accessibility identifiers
- Added: `competition.takes`. The notification identifier suffix `what-it-takes` is new; it is not an accessibility id.
- Unchanged: `competition.ownerRings`, `competition.notSynced`, `competition.updated`, `competition.day.N` and every scoreboard id.

#### Verification on the Mac mini
- Copy the branch: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/takes && tar -x -C ~/dev-desktop/takes'`. Build with its own `-derivedDataPath`.
- `xcodegen generate` (2.46.0) followed by `git diff --exit-code HealthComp.xcodeproj` must show no diff (no new files).
- `xcodebuild test` with CI's Debug flags, plus:
  - `-only-testing:HealthCompTests`
  - `-only-testing:HealthCompUITests/LocalCompetitionLifecycleUITests`, which includes the new test, `testDarkAccessibilitySizeRemainsNavigableAndReadable` and `testDynamicTypeAuditCyclesAllSupportedCategories`
  - `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testRemoteActiveDayRemainsReadableAtAccessibility5`, as a regression check
- Captures: light and dark, XS and AX5, for the loss fixture on Day 1 (1 checkpoint) and the out-of-reach state (7 checkpoints, "Last day").
- `swift test` in Modules/CompetitionCore and `bash scripts/test-competition-local-date-formatting.sh` are untouched but run as usual.

#### Risks and conflict regions
- **Stale reminder content.** A pending request carries the numbers from the last plan. Your own activity re-plans it through HealthKit background delivery, but iOS can throttle that, and the other person's points only arrive with a reconcile. The worst case is a reminder that lands just after you took the lead, or with a slightly low N. There is no cheap fix, because local notifications have no service extension. `// ponytail: content as of the last plan; a 6:45 PM BGAppRefresh re-plan is the upgrade if this bites.`
- **Reading changed but not uploaded yet.** The panel hides and the pending reminder is removed until the upload is accepted, and then both come back. If that window spans 7 PM, that evening's reminder is missed. This is accepted.
- **Account deletion or cancellation on the server.** Deleting an account cancels the other person's live matches (supabase/migrations/20260811000750_add_account_deletion.sql:348-359). A pending "39 to take the lead from Sam" stays on the phone until the next reconcile maps `cancelled` → `.declined` (RemoteCompetitionClient.swift:2098). Then `scheduledBases` returns nothing and the obsolete pass removes it. Until then it can fire and open a route to a match that is gone. The 9:00 Final day reminder already accepts the same exposure. `// ponytail: pending what-it-takes can outlive a server cancellation until the next reconcile; a generic cancellation push that triggers a reconcile is the upgrade (server change, out of scope).`
- **Different match zones.** Matches in different time zones fire at different instants, so two reminders are possible on one evening. This is accepted and marked with a `ponytail:` comment in `mergedScheduledRequests`.
- **Shared files.**
  - CompetitionDetailView `todayActivity`: the Live Activity and widget features may touch the same file. PR (a) owns only `todayActivity`.
  - ActivityRingsView.swift: PR (a) appends only.
  - The planner, models and coordinator: Notification choices (`notifs`) changes `plan(...)`'s signature and the coordinator's preference read (CompetitionNotificationCoordinator.swift:238-244). **PR (b) rebases onto it and must merge after it.** PR (a) has no dependency and can merge first.
- **The AX5 audits** now see a new panel in the local loss and late-sync flows whenever you're behind. It is wrapping text with no new targets.

#### Rollout and compatibility
- No server, migration or wire change. Older installed builds are unaffected.
- The reminder follows the Notification choices switch. notifs owns the default, and it is expected On, as in the approved mockup (Q-takes-1). If it is On, everyone who is behind gets a 7 PM reminder after updating. Say so in the TestFlight notes.
- PR (a) can ship on its own. PR (b) ships with or after Notification choices.
- Normal TestFlight checklist, plus the owner's device check in owner_actions.

#### Review notes
All 16 review points were checked against the code. Applied: the zone suffix at the day-end instant (1, 15); the reach/split rewrite (2, 12); UI test checkpoint counts and assertions (3, 14); singular spoken units (4); the fire day from `CompetitionWhatItTakes.dayOrdinal` (5); a 19:00 coordinator policy (6); the test harness changes (7); path and line fixes (8); one whole `reach` for both the decision and the copy (9); the Q1 default deferred to notifs (10); the opponent-at-cap sentence (11); the stale-reading guard (13); the account-deletion risk (16). Partly rejected:
- (2/12) Allowing Stand as the last part of a split, and capping Stand's room at the hours left before midnight. Both were rejected: the playbook says "one or two rings", and an hours-left cap would need the clock inside a pure function. Move and Exercise only is simpler and never overstates reach. Q6 asks the owner.
- (5) The alternative of checking `.active(dayOrdinal)` against `currentDayOrdinal` was not used. The value carries its own day, so there is one source.
- (13) Rejected "say in the copy that it uses the earlier reading". The ring panel below already says so, and a second note on one screen is noise. Hiding is simpler.
- (16) A cancellation push was rejected: it is a server change and out of scope. The risk is documented instead.
- (8) The draft's ActivityScore line numbers were right. Only the package path was implicit, and it is now spelled out.

#### Owner actions for this feature (merged into §7)
- Answer the open questions, or accept the defaults: the reminder's default is whatever Notification choices ships (its approved mockup draws it on), 7 PM in the match's time zone, ring amounts (kcal/min) on the lock screen, panel shown when level, 'Out of reach today' on Days 1–6 as well, Stand never counted or suggested, and the out-of-reach line names Move and Exercise instead of the mockup's 'before today's cap' figure.
- Before TestFlight, on a Staging build on a real iPhone: check that Account → Notifications → What it takes is on, be behind before 7 PM, and confirm one reminder arrives at 7 PM and opens the match. No server promotion is needed, because this feature is app only.

### 9.4 PR 4 and 5: Nudge: server (PR 4) and app (PR 5)

Branches: `feature/nudge-server` → `feature/nudge` · Server: yes · Size: M · Stakes: none

#### Integration amendments (override the text below)
- This section covers two PRs: **PR 4** `feature/nudge-server` (every `supabase/`, `scripts/`, `docs/` file and the Edge Function) and **PR 5** `feature/nudge` (every app file and `ci.yml`). PR 4 is the **first** server PR this round: migration `20261101002500`, count 26 → 27, pgTAP `023`.
- **Later server PRs** restate the kind list including `'nudge'` (PR 9), copy this PR's lease body (PR 13), and add to `genericAlerts` (PR 9). Q-notifs-3 / Q-nudge-7 agree: older builds keep nudges.
- **Switch.** PR 13 adds the Nudges row (`muted_push_kinds = {nudge}` → 'suppressed' at lease time). The Risks line about a payload marker is superseded.
- **Practice (PR 12).** The `MainTabView` gate is `publication.source == .remoteParticipants && !competition.isPractice`.

#### PR scope
- `feature/nudge-server`: Migration 20261101002500_add_match_nudges.sql adds the nudge kind, the nudge_day column, a rebuilt identity constraint, the nudge_competition_participant RPC and a lease discard arm. send-competition-notification gets the 'nudge' kind with a generic alert. Tests: new pgTAP 023_match_nudges, the nudge_day column added to the column list in 012_durable_notification_work, and Deno tests. Recovery harness count 26->27 plus the manifest and fixture pin. Runbook edits. Deploy order: function first, then migration, Staging then production. The function never goes back to a version without 'nudge'.
- `feature/nudge`: App: CompetitionRemoteAPI/Supabase RPC call and error mapping, CompetitionClient.nudge, CompetitionFeature nudge state, actions and cancel id, the CompetitionDetailView nudge control (in the tally panel when tallying, under the freshness line when live), the #190 tally bodies without 'Nothing for you to do.', MainTabView wiring, Test Lab fixture (Riley's last update 13 h ago), unit and UI tests, a ci.yml UI test entry. No project.yml change. No TestFlight build until the server PR is in production.

Line numbers are from `main` at 8c5ca25. Re-anchor by symbol after rebasing.

#### Scope
- During a real (Supabase) match, you can send the other person one generic push asking them to open HealthComp when:
  - **tallying:** the final score waits on them (#190's `awaitingOpponentCheck` or `opponentPlanUnavailable`), or
  - **live (`active` / `endsToday`):** their newest update is more than 12 hours old.
- At most **once per sender, per match, per match-calendar day**, and at least 12 hours after your previous nudge. After you send one, a quiet confirmation replaces the button.
- The person you nudge gets generic text with no name (audit §10 Q3). Tapping it opens the match and runs the normal refresh. If they muted you, nothing is delivered.
- Never on scheduled matches, challenges, finished matches, or the simulated fixture.
- **Polish rows / other findings:** none.

#### How "the final score waits on the other person" is computed today (#190)
- `RemoteCompetitionProjector.tallyPresentation` (`RemoteCompetitionClient.swift`, around :2337) builds `missingDays` for each side from the replay ledgers.
- `remoteTallyAttention(ownerMissing:opponentMissing:ownerAttestedStable:)` (`:2395-2405`) checks, in order:
  1. You have missing days and your stable check isn't in → `.incomplete`.
  2. They have missing day rows → `.opponentPlanUnavailable` ("Waiting for {Name} to sync").
  3. Your stable attestation is in → `.awaitingOpponentCheck` ("Waiting for {Name}’s last check").
  4. Otherwise → `.awaitingStability`.
- `attest_final_window` → `finalize_competition_locked` (migration 0400:320-433) finalizes in the same transaction as the second stable check. So a match that is still tallying after your stable check is waiting on theirs.
- **Server equivalent:** all of the following hold:
  - `match_today > start_day + 6`;
  - there is no `competition_results` row;
  - `now < best_available_deadline`;
  - the **recipient has no `participant_finalization_attestations` row with `basis = 'stable'`**.
  - A stable attestation needs all seven revisions (0400:345), so "they have missing rows" implies "they have no stable attestation". The server allows a superset of what the app offers, which is fine because the server is the abuse gate.
- **Server lifecycle:** the server never sets `active` / `ends_today` / `tallying`. A match stays `scheduled` until `finalize_competition_locked` sets `completed` (0400:433; comment at 1900:41-43). The server therefore **decides the phase by date** in `time_zone_identifier`, as `match_in_progress_between` and `cancel_competition` do.

#### Behavior

**Who sees the button.** The rules live in a pure function, `competitionCanNudge(_:)`:

| Lifecycle (app) | Condition | Button |
|---|---|---|
| `.tallying` | `tally.attention` is `.awaitingOpponentCheck` or `.opponentPlanUnavailable`, and `evaluatedAt < tally.bestAvailableDeadline` | yes, inside the tally panel |
| `.active`, `.endsToday` | `evaluatedAt - (opponentUpdatedAt ?? start of Day 1) > 12 h` | yes, under the freshness line |
| anything else | — | no |

- **The real-match gate is not in this function.** `LocalCompetitionPresentation` has no `source` field (`LocalCompetitionClient.swift:177-199`); the source lives on the publication. `MainTabView` passes `nudge: nil` for non-`.remoteParticipants` publications, so the control never renders on the simulated fixture.
- `opponentUpdatedAt` is the newest revision's `evaluated_at` (`CompetitionEventStore.swift:1565`, `RemoteCompetitionRuntime.swift:1771`).
- The server uses `received_at`, which is always at or after `evaluated_at`. The only possible disagreement is "the app shows the button, the server says it isn't stale" (a catch-up upload). That case is handled as **not needed** below.
- Start of Day 1 = `try? schedule.calendar.startOfDay(schedule.startDay)`, from `acceptedConfiguration`.

**Copy** (en_US). `{Name}` = `opponentDisplayName`. `{time}` = `competitionUpdatedText(nudgedAt, now: evaluatedAt, locale:, timeZone:)`: "8:12 AM" when the nudge falls on the viewer's current day, otherwise the weekday form "Mon 8:12 AM". That happens when the viewer's zone differs from the match zone. A shown confirmation is always under 24 hours old. Apostrophes are typographic (’), as in shipped code.

| State | What shows | Accessibility id |
|---|---|---|
| Can nudge, nothing sent today | Button **"Nudge {Name}"**; VoiceOver hint "Sends {Name} a notification to open HealthComp." | `competition.nudge` |
| Sending | The same button, disabled | `competition.nudge` |
| Sent (same match day) | Label with a `checkmark` icon: **"Nudged at {time}. You can nudge again tomorrow."** (Theme.ink, subheadline). An `AccessibilityNotification.Announcement` with the same text is posted only on the `.sending` → `.sent` transition | `competition.nudge.sent` |
| Connection or other failure | The button stays; under it: **"Couldn’t send the nudge. Try again."** (Theme.secondary) | `competition.nudge.error` |
| Server refused (`nudge_not_allowed` / `competition_not_found`) | No button; **"{Name} doesn’t need a nudge right now."** (Theme.secondary) until the match day ends. A foreground reconcile starts | `competition.nudge.error` |

- "Today" means the same calendar day as `evaluatedAt` in **the match time zone** (`competition.timeZoneIdentifier`), the same boundary the server uses. When the day rolls over, the button returns if the condition still holds. If the server's 12-hour spacing still applies, the tap returns a fresh `nudged_at` and queues nothing (see Server). The confirmation is true in effect: they received a push less than 12 hours ago, and it is still on the lock screen under the same collapse id.
- If the condition stops holding (they updated, or the result arrived), the whole control disappears, confirmation included. The freshness line or the result screen says what happened.
- **Tally copy:** the #190 headlines stay. The two waiting-on-them bodies drop their leading "Nothing for you to do." sentence, because the panel now offers an action (in `competitionTallyCopy`, `CompetitionDetailView.swift:928-937`):
  - `.opponentPlanUnavailable`: "If {Name} doesn’t sync by {deadline}, the result uses what’s in."
  - `.awaitingOpponentCheck`: "If {Name} doesn’t open HealthComp by {deadline}, the result uses what’s in."
  - Every other state, `nothingToDo` included, is unchanged. The mockup's "Waiting on…" headline and "{Name}’s iPhone last updated…" body are not adopted (see Open questions).
- **Push received** (lock screen): title **"Score update needed"**, body **"Open HealthComp to update your match."**
  - Sound default, `thread-id` `competition:<id>`, routes to the match.
  - No name and no numbers.
  - The mockup's "so your match can finish" is untrue for live matches, so one neutral body is used.
- **Opening the push runs the refresh. No new code is needed; this is verified, not built:**
  - Tap from background → the scene becomes active → `MainTabFeature` `.scenePhaseChanged(.active)` (`MainTabFeature.swift:249-257`) → `CompetitionFeature.sceneBecameActive` (`CompetitionFeature.swift:768-778`) → `reconcile(trigger: .foreground)`.
  - `RemoteCompetitionClient.reconcileAll` (`:731-746`) runs the same `performReconciliation()` for every trigger. Only Staging wraps `.pullToRefresh` with operator capture.
  - A cold launch runs `start()` → `performReconciliation()` (`:727`).
  - The route then opens the match through `resolve` (`MainTabFeature.swift:~918-950`).
  - The recipient's stable attestation happens inside that same sync.
- **Mute:** a nudge to someone who muted you is stored `suppressed`. The lease also re-checks `competition_notification_mutes` at send time (2300:170-176), so a mute added after the nudge stops it too. The sender sees the normal confirmation.
- **One job per screen:** one compact button in existing context. No new screen, sheet or menu item.

#### Design — server (`feature/nudge-server`)

##### Why "no new table, limit on the work rows" needs one schema change
- `private.competition_notification_work` (0700:1-75) makes each row unique on `(competition_id, server_seq, kind, recipient_profile_id, installation_id)`, and `server_seq` must reference `competition_change_log`.
- A nudge must not write a change-log row: `competition_change_payload` raises `server_contract_mismatch` for unknown change kinds (0500), which would break every installed app's feed. The nudge row therefore reuses the match's current `max(server_seq)`.
- **The conflict:** in exactly the case Nudge exists for, the other person stays silent overnight. With no new change, day 2's nudge has the **same `server_seq`**, so `on conflict … do nothing` drops it.
- **The fix:**
  - Add a nullable `nudge_day date` column.
  - Recreate the identity constraint, keeping its name, as `unique nulls not distinct (…, nudge_day)`.
  - Existing kinds leave `nudge_day` `NULL`, so their dedupe is unchanged.
  - The two existing `on conflict on constraint competition_notification_work_identity_unique` callers (0700 trigger :262-275, 1900 `enqueue_challenge_notification` :95-117) keep working by name.
- `semantic_id` keeps its own global `UNIQUE` (0700:3). The nudge semantic id carries the day, so it is unique per (match, day, recipient, installation). Same-day duplicates are prevented before the insert by the participant-row lock plus the "already nudged" check.

##### `supabase/migrations/20261101002500_add_match_nudges.sql` (new, forward-only)
```sql
-- Nudge: one generic push asking the other person to open HealthComp when
-- the result waits on their last check, or their newest upload in a live
-- match is over 12 hours old. Once per sender per match per match day, and
-- 12 hours apart. No change-log row: the feed has no 'nudge' change kind.

alter table private.competition_notification_work
  add column nudge_day date,
  drop constraint competition_notification_work_kind_check,
  add constraint competition_notification_work_kind_check check (
    kind in ('score_update', 'result', 'challenge_received',
      'challenge_declined', 'match_cancelled', 'nudge')
  ),
  add constraint competition_notification_work_nudge_day_shape
    check ((kind = 'nudge') = (nudge_day is not null));

-- Same name, so existing ON CONFLICT ON CONSTRAINT callers are unchanged.
-- A nudge on a later day can share the match's server_seq.
alter table private.competition_notification_work
  drop constraint competition_notification_work_identity_unique;
alter table private.competition_notification_work
  add constraint competition_notification_work_identity_unique
  unique nulls not distinct (
    competition_id, server_seq, kind, recipient_profile_id,
    installation_id, nudge_day
  );

create function public.nudge_competition_participant(competition_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  input_competition_id alias for competition_id;
  caller_profile_id uuid := private.require_active_caller_profile_id();
  as_of timestamptz := pg_catalog.statement_timestamp();
  target record;
  recipient_profile_id uuid;
  match_today date;
  last_update timestamptz;
  target_server_seq bigint;
  is_muted boolean;
begin
  if input_competition_id is null then
    raise exception 'invalid_competition_id' using errcode = '22023';
  end if;
  -- Locking the caller's own participant row (no key update, so score
  -- inserts' FK checks never wait) serializes a double tap.
  select c.id, c.lifecycle, c.time_zone_identifier, c.start_day,
    c.best_available_deadline
  into target
  from public.competitions c
  join public.competition_participants p
    on p.competition_id = c.id and p.profile_id = caller_profile_id
   and p.state = 'accepted'
  where c.id = input_competition_id
  for no key update of p;
  if not found then
    raise exception 'competition_not_found' using errcode = 'P0002';
  end if;
  match_today := (as_of at time zone target.time_zone_identifier)::date;

  select p.profile_id into recipient_profile_id
  from public.competition_participants p
  join public.profiles r on r.id = p.profile_id and r.state = 'active'
  where p.competition_id = target.id and p.profile_id <> caller_profile_id
    and p.state = 'accepted';
  select pg_catalog.max(l.server_seq) into target_server_seq
  from public.competition_change_log l where l.competition_id = target.id;

  if recipient_profile_id is null or target_server_seq is null
     or target.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')
     or match_today < target.start_day
     or exists (select 1 from public.competition_results r
       where r.competition_id = target.id) then
    raise exception 'nudge_not_allowed' using errcode = 'P0001';
  end if;
  if match_today > target.start_day + 6 then
    -- After Day 7: the result waits on their stable check.
    if as_of >= target.best_available_deadline or exists (
      select 1 from public.participant_finalization_attestations a
      where a.competition_id = target.id
        and a.participant_profile_id = recipient_profile_id
        and a.basis = 'stable') then
      raise exception 'nudge_not_allowed' using errcode = 'P0001';
    end if;
  else
    -- Live: their newest upload, or Day 1's start, is over 12 hours old.
    select pg_catalog.max(s.received_at) into last_update
    from public.daily_score_revisions s
    where s.competition_id = target.id
      and s.participant_profile_id = recipient_profile_id;
    if coalesce(last_update,
         target.start_day::timestamp at time zone target.time_zone_identifier)
       > as_of - interval '12 hours' then
      raise exception 'nudge_not_allowed' using errcode = 'P0001';
    end if;
  end if;

  -- Already nudged today, or within 12 hours: same answer, nothing queued.
  -- Every success returns as_of, never a stored time, so the answer doesn't
  -- reveal whether the recipient has a device (no device = no rows).
  if exists (
    select 1 from private.competition_notification_work w
    where w.competition_id = target.id and w.kind = 'nudge'
      and w.source_profile_id = caller_profile_id
      and (w.nudge_day = match_today
        or w.created_at > as_of - interval '12 hours')) then
    return pg_catalog.jsonb_build_object('nudged_at', as_of);
  end if;

  is_muted := exists (
    select 1 from private.competition_notification_mutes m
    where m.profile_id = recipient_profile_id
      and m.opponent_profile_id = caller_profile_id);
  insert into private.competition_notification_work (
    semantic_id, competition_id, server_seq, kind, nudge_day,
    recipient_profile_id, source_profile_id, installation_id,
    state, available_at, created_at, updated_at, completed_at
  )
  select 'healthcomp.server-notification:v1:' || target.id::text
      || ':nudge:' || match_today::text || ':'
      || recipient_profile_id::text || ':' || i.installation_id::text,
    target.id, target_server_seq, 'nudge', match_today,
    recipient_profile_id, caller_profile_id, i.installation_id,
    case when is_muted then 'suppressed' else 'pending' end,
    as_of, as_of, as_of,
    case when is_muted then as_of else null end
  from public.device_installations i
  where i.profile_id = recipient_profile_id and i.state = 'active'
  order by i.installation_id
  on conflict on constraint competition_notification_work_identity_unique
  do nothing;

  perform private.request_competition_notification_worker();
  return pg_catalog.jsonb_build_object('nudged_at', as_of);
end;
$$;
revoke all on function public.nudge_competition_participant(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.nudge_competition_participant(uuid)
  to authenticated;
```

**Lease.** Then `create or replace function public.lease_competition_notification_work(...)`:
- Copy 2300:122-262 verbatim.
- Add one arm to the `'discarded'` case, after the `challenge_received` arm (2300:166-168):
  ```sql
  or (work_row.kind = 'nudge'
      and (source_profile_row.state is distinct from 'active'
        or coalesce(competition_row.lifecycle, '') not in
          ('scheduled', 'active', 'ends_today', 'tallying')))
  ```
- A nudge queued just before finalization is dropped.
- No `supports_challenges` gate (see Open questions).
- Leased items keep the same seven keys.

**Notes**
- **The answer is the same for every success.**
  - The RPC always returns `{nudged_at: now}`: a first send, a repeat, a muted recipient, or a recipient with no active installation.
  - Eligibility is checked *before* the "already nudged" lookup. After the recipient updates, a repeat tap is refused the same way whether or not rows were stored.
  - The daily limit and 12-hour spacing come from stored rows. With no device nothing is stored, but nothing is delivered either.
  - `-- ponytail: no-device nudges aren't rate-limited (nothing to deliver); store a marker row if a non-push channel is added.`
- **What the RPC reveals to the caller:** a timestamp, or `nudge_not_allowed`. "Updated within 12 h" is already visible in the freshness line. No Health values, names, mute state or device presence.
- **Semantic id:** about 165 characters, under the 255-character check (0700:3-6).
- **No index added:** the limit lookup is bounded by `competition_id`, a prefix of `competition_notification_work_competition_idx` (0700:94-97).

##### `supabase/functions/send-competition-notification/index.ts`
- **`workKinds` (:22-28):** add `"nudge"`. This is also the compatibility point: `parseWorkItem` (:150-178) rejects unknown kinds, `parseLeaseResponse` (:180-202) then returns null, and the handler answers 502 for the **whole batch** (:443-450). The function must therefore deploy before the migration, and must never be rolled back to a version without `"nudge"`.
- **:270-284:**
  - Rename `challengeAlerts` → `genericAlerts`.
  - Comment: "Server alerts stay generic: no name, so they are safe on a lock screen."
  - Add `nudge: { title: "Score update needed", body: "Open HealthComp to update your match." }`.
  - `competitionNotificationPayload` is otherwise unchanged: same route keys, same `thread-id`.
  - `apns-collapse-id` (:319) stays `healthcomp:<id>`, so a day-2 nudge replaces day 1's on the lock screen.

##### Harness, existing tests and docs
- `supabase/tests/012_durable_notification_work.test.sql:153-168`: the test checks the sorted column list of `private.competition_notification_work`. Insert `'nudge_day'` between `'leased_apns_token_sha256'` and `'recipient_profile_id'`. Without this, CI (`backend.yml:107-108`, `supabase db reset` + `supabase test db`) fails.
- `scripts/test-recovery-migrated-snapshot.sh`:
  - :31 → `== 27`.
  - :9 `manifest_hash` → output of `shasum -a 256 supabase/migrations/*.sql | shasum -a 256 | awk '{print $1}'`, computed after the migration is final.
- `scripts/tests/recovery-migrated-fixture.sql:23-24`: add `'20261101002500'` to the allowed `max(version)` list.
- `docs/runbooks/supabase-environments.md`, after "Challenge push capability" (:473-497): a new `### Nudges` section covering:
  - the RPC and its rules (match day plus 12-hour spacing, the same answer for every success);
  - **deploy `send-competition-notification` before migration 2500**, and never roll the function back to a version without `nudge`;
  - how to disable nudges (Rollout below);
  - the app build needs 2500 in production first;
  - nudges reach 1.0.2 installs.
- `docs/runbooks/competition-support.md`, after :378: "`nudge` work is one row per recipient installation per sender per match day (`nudge_day`); a muted pair resolves `suppressed`, a finished match `discarded`. The support query needs no change."

#### Design — app (`feature/nudge`)
No new Swift files, no `project.yml` change, no CompetitionCore change, no `CompetitionDateFormatting.swift` change (it reuses `competitionUpdatedText`).

1. **`HealthComp/Services/CompetitionRemoteAPI.swift`**, after `cancelCompetition` (:106-108): `var nudgeCompetitionParticipant: @Sendable (UUID) async throws -> Date = { _ in throw CompetitionRemoteFailure.operationFailed }`, with the doc comment "Asks the other person to open HealthComp; returns the time the server accepted the nudge."
2. **`HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`**
   - In `make`, after `cancelCompetition` (:347-349), add `nudgeCompetitionParticipant: { id in … }`. It:
     - calls `validateUUID(id)`;
     - sends `.rpc(name: "nudge_competition_participant", parameters: encode(ArchiveCompetitionParameters(competitionID: id)))`;
     - decodes an object whose keys are exactly `["nudged_at"]`, parsing the value with `CompetitionWireCodec.date(_:)` (`CompetitionSyncModels.swift:96`);
     - throws `.serverContractMismatch` for anything else.
   - In `classify`, add `"nudge_not_allowed"` to the `.forbidden` list (:626-634). `competition_not_found` already maps to `.notFound` (:618-624).
3. **`HealthComp/Features/Competition/CompetitionClient.swift`**
   - Add `var nudge: @Sendable (CompetitionID) async throws -> Date` after `resolveChallengeLink` (:98-101).
   - Add an init parameter defaulting to `{ _ in throw CompetitionRemoteFailure.operationFailed }` (after :178-183), plus its assignment (:212).
   - The `LocalCompetitionClient` constructions (:581, :642) keep the default.
4. **`HealthComp/Features/Competition/RemoteCompetitionClient.swift:150-152`:** add `nudge: { id in try await coordinator.remote { try await $0.nudgeCompetitionParticipant(id.rawValue) } }`.
5. **`HealthComp/Features/Competition/CompetitionFeature.swift`**
   - A new type next to `CompetitionRematchState` (:80-90):
     ```swift
     enum NudgeStatus: Equatable, Sendable {
         case sending
         case sent(Date)
         case failed
         /// The server said no: they updated, or the result no longer waits on them.
         case notNeeded(Date)
     }
     ```
   - `State` (:104-128): `var nudges: [CompetitionID: NudgeStatus] = [:]`.
   - `Action` (:170-217): `case nudgeTapped(CompetitionID)` and `case nudgeResponse(CompetitionID, tappedAt: Date, Result<Date, CompetitionRemoteFailure>)`.
   - `CancelID` (:221-228): add `case nudge`.
   - Reducer, after `.cancelTapped` (:366-377):
     - **`nudgeTapped`:**
       - guard `state.nudges[id] != .sending`, then set `.sending`;
       - `tappedAt` = that competition's `evaluatedAt` from `state.publication`;
       - the `.run` calls `competitionClient.nudge(id)` and maps a thrown error to `(error as? CompetitionRemoteFailure) ?? .operationFailed`;
       - `.cancellable(id: CancelID.nudge)` without `cancelInFlight`, so nudges for two matches can both be in flight.
     - **`nudgeResponse`:**
       - `.success(d)` → `.sent(d)`;
       - `.failure(.forbidden)` or `.failure(.notFound)` → `.notNeeded(tappedAt)` and `return reconcile(trigger: .foreground)`. Not `.pullToRefresh`: in Staging builds `reconcileAll` wraps that trigger in operator capture (`RemoteCompetitionClient.swift:737-743`), and the user didn't pull;
       - any other failure → `.failed`.
   - `.stop` (:783-800): `state.nudges = [:]` and `.cancel(id: CancelID.nudge)` in the existing merge.
   - Not persisted. After a relaunch, a repeat tap the same day gets a fresh `nudged_at` and queues nothing, so the confirmation shows the time of that tap.
6. **`HealthComp/Features/Competition/CompetitionDetailView.swift`**
   - **Tally copy (`competitionTallyCopy`, :928-937):** the two bodies above, without "Nothing for you to do.". Nothing else changes.
   - **New parameter** after `cancelMatch` (:13): `var nudge: CompetitionNudge? = nil`.
   - **`struct CompetitionNudge`**, next to `CompetitionCancelMatch` (:1120-1124): `let status: CompetitionFeature.NudgeStatus?; let send: () -> Void`.
   - **Pure helpers** near `competitionTallyCopy`:
     - `func competitionCanNudge(_ c: LocalCompetitionPresentation) -> Bool` implements the Behavior table (lifecycle and time only). It uses `let competitionNudgeStaleInterval: TimeInterval = 12 * 60 * 60`, the same value as the server.
     - `enum CompetitionNudgeDisplay: Equatable { case button(error: String?, isSending: Bool), sent(String), notNeeded(String) }`.
     - `func competitionNudgeDisplay(_ status: CompetitionFeature.NudgeStatus?, competition: LocalCompetitionPresentation, locale: Locale, timeZone: TimeZone) -> CompetitionNudgeDisplay?`:
       - returns nil unless `competitionCanNudge`;
       - `.sent` and `.notNeeded` apply only when their date falls on `evaluatedAt`'s day in `TimeZone(identifier: competition.timeZoneIdentifier)`;
       - otherwise `.button`, carrying the failure string when `.failed`;
       - all copy strings live here.
   - **`private struct CompetitionNudgeControl: View`**, built from a display, a name and `send`:
     - **`.button`:**
       - `Button("Nudge \(name)", action: send)` with a private `CompetitionNudgeButtonStyle`, which matches the mockup's `.btn-sm` and the shipped "Review" mark (`CompetitionSharingView.swift:700-706`):
         - label `.font(.subheadline.weight(.semibold))`, `Theme.onInk`;
         - `.padding(.horizontal, 12).padding(.vertical, 6)`, `.background(Theme.ink, in: Capsule())`;
         - `.multilineTextAlignment(.leading)`;
         - pressed opacity 0.8, disabled 0.45 (as in Theme.swift);
         - outer `.frame(minHeight: 44)` and `.contentShape(Rectangle())`, so the hit target is 44 pt.
       - The row is left-aligned.
       - Modifiers: `.disabled(isSending)`, `.accessibilityHint(…)`, `.accessibilityIdentifier("competition.nudge")`.
       - Below it, the optional error `Text`: `.font(.subheadline)`, `Theme.secondary`, `.fixedSize(horizontal: false, vertical: true)`, id `competition.nudge.error`.
     - **`.sent`:**
       - `Label(text, systemImage: "checkmark")`, `.font(.subheadline)`, `Theme.ink`, fixedSize;
       - `.accessibilityElement(children: .combine)`, id `competition.nudge.sent`.
     - **Announcement:** `.onChange(of: display) { old, new in … }` on the control (iOS 17 two-value form). It posts `AccessibilityNotification.Announcement(text)` only when `old` is `.button(_, isSending: true)` and `new` is `.sent(text)`, so it fires once per tap and not on every reappearance.
     - **`.notNeeded`:** `Text`, `Theme.secondary`, id `competition.nudge.error`.
     - No new colors. No `@available`: every API is in iOS 17.
   - **Tally panel (:186-213).** The panel is one `.accessibilityElement(children: .combine)` today, which would swallow a button. Restructure to:
     ```swift
     VStack(alignment: .leading, spacing: 12) {
         VStack(alignment: .leading, spacing: 4) { headline; body }   // unchanged Texts
             .accessibilityElement(children: .combine)
             .accessibilityIdentifier("competition.tally")          // same id, same label
         if let nudge, let display = competitionNudgeDisplay(nudge.status, competition: competition, locale: locale, timeZone: timeZone) {
             CompetitionNudgeControl(display: display, name: competition.opponentDisplayName, send: nudge.send)
         }
     }
     .frame(maxWidth: .infinity, alignment: .leading).padding(16).themePanel(cornerRadius: 16)
     ```
   - **Live placement:** in the scoreboard group (:45-60), right after `freshnessLine` (:52), add `liveNudge`. It renders the same control only when `competition.lifecycle` is `.active` or `.endsToday`, so the control never appears twice.
7. **`HealthComp/Features/MainTab/MainTabView.swift:271-292`:** pass `nudge: publication.source == .remoteParticipants ? CompetitionNudge(status: store.competition.nudges[id], send: { store.send(.competition(.nudgeTapped(id))) }) : nil`. This is the real-match gate. The simulated fixture gets nil, so `LocalCompetitionLifecycleUITests` are unchanged.
8. **`HealthComp/Features/Competition/MultiUserCompetitionTestLabView.swift`** (DEBUG):
   - Add `@State private var labNudge: CompetitionFeature.NudgeStatus?`.
   - In `destination` (:280-284), pass `nudge: CompetitionNudge(status: labNudge, send: { labNudge = .sending; labNudge = .sent(MultiUserCompetitionTestLabFixtures.labNow) })`. `labNow` (:673) equals the fixture's `evaluatedAt`.
   - **Riley fixture (`secondActive`, :709-718):** add `opponentUpdatedAt: evaluatedAt.addingTimeInterval(-46_800)` (13 h). Riley then offers a nudge with the freshness line present ("Riley: updated …"), which is the common case. Without it, `competitionFreshnessText` returns nil for (nil, nil) (`CompetitionDetailView.swift:1018-1035`), and the button would sit with no context.
   - Home cards don't read `opponentUpdatedAt`; the only Riley UI assertion is the card order at `MultiUserCompetitionUITests:311-314`.
   - Jordan (`opponentUpdatedAt` = −1 h) does **not** offer a nudge.
   - The never-uploaded case is covered by unit tests.

**Accessibility identifiers**
- Added: `competition.nudge`, `competition.nudge.sent`, `competition.nudge.error`.
- Moved, same id: `competition.tally` moves from the padded panel to its text group. Its label is unchanged, except that the two waiting-on-them bodies lose "Nothing for you to do.". No UI test asserts those two states.
- Removed: none.

#### Tests

**pgTAP `supabase/tests/023_match_nudges.test.sql`** (`select no_plan();`, in the style of 021)

Setup:
- Profiles Ana and Ben. Ben has 2 active installations; Cal has none.
- A live match: UTC, `start_day = current_date - 2`, lifecycle `scheduled`.
- A tallying match: `start_day = current_date - 8`, `best_available_deadline = now() + interval '1 day'`, `invitation_expires_at = now() - interval '9 days'`.
- A vault worker secret, as in 012:247-260.
- `pg_temp.seed_revision(competition, participant, received_at)` calls `private.allocate_competition_server_seq` and inserts `daily_score_revisions` with `wire_content_sha256 = private.wire_score_digest_v1(...)` (pattern from 012:262-277).

Assertions, by name:
- **Access and eligibility**
  - `nudge RPC is a narrow authenticated definer function`
  - `a non-participant gets competition_not_found`
  - `a scheduled match before Day 1 refuses with nudge_not_allowed`
  - `a live match with a 2-hour-old upload refuses with nudge_not_allowed`
- **Queuing**
  - `a live match with a 13-hour-old upload queues one pending nudge per active installation`: 2 rows; `kind 'nudge'`, `nudge_day = current_date`, `source = Ana`, `server_seq = max(change log)`.
  - `a live match with no upload and Day 1 over 12 hours ago is stale`
- **Repeats and spacing**
  - `a second nudge the same day returns a nudged_at and queues nothing`: still 2 rows.
  - `a nudge on the next match day within 12 hours of the last queues nothing`: as owner, update the rows with `set nudge_day = current_date - 1, semantic_id = replace(semantic_id, ':nudge:' || current_date, ':nudge:' || (current_date - 1))`. `created_at` is unchanged. Call again → still 2 rows.
  - `a nudge on the next match day over 12 hours later queues new rows with the same server_seq`: also `set created_at = now() - interval '13 hours', available_at = now() - interval '13 hours'`. Call again → 4 rows. **This is the identity regression.** The semantic_id rewrite is needed because `semantic_id` has its own global UNIQUE (0700:3), and `ON CONFLICT ON CONSTRAINT` does not cover it.
- **Privacy**
  - `a muted recipient gets suppressed rows and the caller still gets nudged_at`
  - `a recipient with no installation returns nudged_at and queues nothing`
  - `after the recipient updates, a repeat refuses the same way with or without stored rows`: this proves no device-presence leak.
- **Tallying**
  - `tallying without the recipient's stable attestation allows a nudge`
  - `tallying after the recipient's stable attestation refuses`
  - `tallying after best_available_deadline refuses`
  - `a finished match (competition_results row) refuses`
- **Lease**
  - `the lease sends nudge work with the seven keys and kind nudge`
  - `the lease discards nudge work once the match is completed`
  - `the lease suppresses nudge work for a pair muted after queuing`
- **Constraints**
  - `a nudge row without nudge_day violates competition_notification_work_nudge_day_shape`; `a score_update with nudge_day violates it`
  - `existing kinds still dedupe on the identity constraint`: insert the same score_update identity twice with `on conflict on constraint … do nothing` → one row.

**pgTAP 012:** the column-list assertion gains `'nudge_day'` (above).

**Deno, `supabase/functions/send-competition-notification/index_test.ts`:**
- `nudge payload is generic and routes to the match`: checks the exact object, with alert `{ title: "Score update needed", body: "Open HealthComp to update your match." }`, the route keys and `thread-id`. Place it after :408-430.
- `nudge work is leased and sent with the existing seven keys`: one item with `kind: "nudge"` and a semanticId containing `:nudge:` → status 200, one APNs body.
- Existing tests are unchanged.

**HealthCompTests:**
- **`CompetitionPresentationTests`**
  - `testTallyCopyNamesWhoItWaitsOnAndWhetherToAct` (:777): update the expected bodies at :806 and :810 to "If Hermes doesn’t sync by Wed night, the result uses what’s in." and "If Hermes doesn’t open HealthComp by Wed night, the result uses what’s in."
  - `testNudgeIsOfferedWhenTheResultWaitsOnTheOtherPerson`:
    - true for `.awaitingOpponentCheck` and `.opponentPlanUnavailable`;
    - false for `.awaitingStability`, `.incomplete`, `.noRead` and nil;
    - false once `evaluatedAt >= bestAvailableDeadline`.
  - `testNudgeIsOfferedWhenALiveMatchIsTwelveHoursStale`:
    - 12 h 1 m → true; exactly 12 h → false; 11 h 59 m → false;
    - nil with Day 1 13 h ago → true; 2 h ago → false;
    - `.scheduled` and `.completed` → false.
  - `testNudgeConfirmationLastsUntilTheMatchDayEnds`: match zone America/Los_Angeles, viewer zone UTC, en_US, a live match stale throughout. Sent at 1_786_979_520 (Mon Aug 17 2026, 8:12 AM PDT = 15:12 UTC):
    - now 1_787_007_600 (4:00 PM PDT = 23:00 UTC, same UTC day) → `.sent("Nudged at 3:12 PM. You can nudge again tomorrow.")`;
    - now 1_787_032_800 (11:00 PM PDT = Tue 06:00 UTC; the zones disagree about the day) → `.sent("Nudged at Mon 3:12 PM. You can nudge again tomorrow.")`;
    - now 1_787_038_200 (Tue 12:30 AM PDT) → `.button(error: nil, isSending: false)`.
  - `testNudgeFailureAndRefusalCopy`: "Couldn’t send the nudge. Try again." and "Sam doesn’t need a nudge right now."
- **`RemoteCompetitionFeatureTests`** (near `testCancelTappedRunsCommand`, :909):
  - `testNudgeTappedSendsOnceAndShowsWhenItWasSent`: a second tap while `.sending` sends nothing.
  - `testNudgeRefusedByServerShowsNotNeededAndRefreshes`: `.forbidden` → `.notNeeded(evaluatedAt)` and `reconcileAll(.foreground)` called once; the same for `.notFound`.
  - `testNudgeConnectionFailureKeepsTheButton`: `.retryableTransport` → `.failed`.
  - `testStopClearsAndCancelsNudges`: tap, `.stop`, then resume the suspended client. No `nudgeResponse` is received and `nudges` stays empty.
- **`SupabaseCompetitionRemoteAPITests`** (after `testResetChallengeLinkCode`, :876): `testNudgeSendsCompetitionIDAndDecodesNudgedAt` checks:
  - the `assertRPC` name and body;
  - `{"nudged_at":"2026-11-09T16:12:00.123456+00:00"}` decodes;
  - an extra key → `.serverContractMismatch`;
  - `nudge_not_allowed` → `.forbidden`;
  - `competition_not_found` → `.notFound`.

**HealthCompUITests**
- `MultiUserCompetitionUITests.testStaleMatchOffersOneNudgeADay`:
  - `launch(.sharing)`. Open Jordan's card → `app.buttons["competition.nudge"]` doesn't exist. Go back.
  - Open Riley's card → the button exists with the label "Nudge Riley".
  - Run `app.performAccessibilityAudit(for: [.dynamicType, .textClipped, .hitRegion, .sufficientElementDescription])`.
  - Tap → `app.descendants(matching: .any).matching(identifier: "competition.nudge.sent").firstMatch` has a label that starts with "Nudged at " and ends with ". You can nudge again tomorrow.", and the button is gone.
- Add it to `.github/workflows/ci.yml` after :228: `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testStaleMatchOffersOneNudgeADay \`.

#### Verify
**Linux VM / local Supabase (server PR):**
- `supabase start && supabase db reset && supabase test db`: all suites, including 012 and 023.
- `deno test --allow-env --config supabase/functions/deno.json supabase/functions/send-competition-notification/`.
- `deno fmt --check` and `deno lint` with the CI arguments (backend.yml:62-68).
- `supabase db lint`.
- `bash scripts/test-recovery-migrated-snapshot.sh` where OrbStack is available (CI only runs `bash -n` on it).

**Mac mini (app PR):**
- Copy the tree with `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'tar -x -C ~/dev-desktop/<dir>'`.
- Unit tests: `~/dev-desktop/ua/ua-mac6.sh unit`.
- UI tests: `~/dev-desktop/ua/ua-mac6.sh ui`, with `-only-testing` covering:
  - the new test;
  - `testRemoteCompetitionAppearanceAndTypeSizeMatrix`;
  - `testHomeGroupsLiveMatchesByEndTimeAndShowsMatchIssues` (Riley's fixture changed).
- XcodeGen sanity: `~/tools/xcodegen/bin/xcodegen generate && git diff --exit-code HealthComp.xcodeproj` (expect no diff).
- Captures for a preview artifact next to the #nudge mockup:
  - Riley's match before and after the tap (live placement under the freshness line), light and dark, XS and AX5;
  - a tallying capture of the panel with the shortened body.
- Call out the compact capsule versus SecondaryButtonStyle for owner approval.

**Staging (owner, two accounts, physical iPhones):**
1. Deploy the function, then the migration, to Staging.
2. Day 0: B accepts A's challenge (Day 1 = tomorrow in the match zone). B's iPhone goes offline before midnight.
3. Before noon on Day 1 (match zone), A's RPC returns `nudge_not_allowed` (fewer than 12 h since Day 1 started).
4. After noon on Day 1:
   - A's button appears. Tap it. The "Notification work" query (competition-support.md:346-371) shows `nudge` → `sent`.
   - Tap again (after a relaunch): the same confirmation, no new row.
5. B's iPhone back online: B gets "Score update needed / Open HealthComp to update your match.". Tapping it opens the match, and B's freshness on A's screen updates.
6. Day 2, after B goes offline again and at least 12 h after the first nudge: B mutes A, A nudges, the row is `suppressed`, and no push arrives.
7. Promote to production through the checklist, function first.

#### Risks and conflict regions
- **Deploy order is load-bearing.** A `nudge` lease item reaching a function without `"nudge"` fails the whole batch with a 502. Rows stay leased until expiry and are re-leased for up to 10 attempts (2300:154), which delays challenge pushes too. The order is function → migration, and the function is never rolled back past this point.
- **Identity constraint rebuild:** the migration drops and recreates a unique constraint on a small, live, private table inside the migration transaction. `NULLS NOT DISTINCT` needs PG ≥ 15 (owner action).
- **Other features this round touching the same regions:**
  - Reactions (a new `reaction` work kind) touches `kind_check`, `workKinds`, `genericAlerts`, the lease function and the 012 column list if it adds columns.
  - Block touches migrations.
  - Whichever merges second rebases: renumber the migration, re-copy the newest lease body, and move the harness count, manifest hash and fixture pin.
  - Notification choices (a Nudges switch, app only) would need a payload marker to filter nudges on arrival; that is left to that feature.
- **`CompetitionDetailView.swift`:** the tally panel (:186-213), `competitionTallyCopy` and the scoreboard group (:45-60) are also touched by Belt/Recap/Live. Rebase by symbol.
- **Clock mismatch:** the app judges staleness from `evaluated_at`, the server from `received_at`. The worst outcome is "doesn't need a nudge right now" plus a refresh, never a wrong push.
- **The 12-hour spacing across midnight** can show "Nudged at {now}" for a tap that queued nothing. The push from under 12 hours earlier is still on their lock screen, so the statement is true in effect.
- **Older apps:** 1.0.2 and current builds receive nudges and route to the match. Builds without this PR never call the RPC.

#### Rollout / compatibility
- Server: Staging → production (function first, then migration) before any TestFlight build with `feature/nudge`.
- **Disabling or rolling back:** do **not** redeploy a function version without `"nudge"`. Any pending or re-leased nudge row would 502 every batch and stall challenge pushes. Instead, ship a forward migration that:
  - runs `revoke execute on function public.nudge_competition_participant(uuid) from authenticated`;
  - runs `update private.competition_notification_work set state = 'discarded', completed_at = now(), updated_at = now() where kind = 'nudge' and state = 'pending'`.
  - Leased rows finish normally, because the function still accepts the kind.
  - Older app builds then get `.forbidden` → "doesn't need a nudge" plus a refresh.
- No data backfill. Existing rows get `nudge_day = NULL`.

#### Review notes
Applied:
- The 012 column-list test now includes `nudge_day`.
- The pgTAP next-day test rewrites semantic_id (and created_at for the 12-hour rule).
- Fixed the confirmation unit-test expectation. `competitionUpdatedText` is kept, because `competitionDateFormatter` is `private` (`CompetitionDateFormatting.swift:75`) and the weekday form is the honest output when the zones disagree. The copy table now documents the weekday form.
- Rollback no longer redeploys the old function.
- Device-presence leak closed: every success returns `as_of`, and eligibility is checked before the repeat lookup.
- Removed the `source` row from `competitionCanNudge`.
- Added the `CancelID.nudge` cancel on `.stop`.
- Riley gets a 13 h-old `opponentUpdatedAt`.
- Rewrote the Staging smoke for Day 1 = next day (1900:180-181).
- Re-anchored `remoteTallyAttention` to :2395-2405.
- The announcement fires on the `.sending` → `.sent` change, not in `.onAppear`.
- Dropped "Nothing for you to do." from the two waiting-on-them bodies (no UI test asserts them).
- Added 12-hour spacing across midnight.
- A refused nudge uses `.foreground`, not `.pullToRefresh`.
- Compact capsule button per the mockup, with an owner question.
- Removed the out-of-scope meta sentence.

Rejected: none. The duplicate pair of issues (confirmation-format test, device leak) was each handled once. From the format pair, the time-only template was not taken because that formatter is private and drops the day context.

#### Owner actions for this feature (merged into §7)
- Approve the production promotion through docs/release/production-beta-checklist.md in this order: first deploy send-competition-notification (accepts 'nudge') to production, then apply migration 20261101002500. If the migration goes first, the old function receives a 'nudge' lease item, rejects the whole batch with a 502, and holds up challenge pushes. After this ships, never redeploy a function version without 'nudge' (see Rollout).
- Run the Staging smoke with the two Staging accounts on physical iPhones (APNs doesn't reach the simulator). Accepting a challenge always makes Day 1 the next local day, so the smoke takes three calendar days: B accepts on day 0. Around noon on Day 1 (match zone), with B's iPhone offline since Day 1 started, A nudges, B gets the generic push, and tapping it opens the match. On Day 2, B mutes A, A nudges again, the row is 'suppressed', and no push arrives.
- Confirm that Staging and production Postgres are version 15 or later (`select current_setting('server_version_num')` >= 150000). The migration uses UNIQUE NULLS NOT DISTINCT. Local config.toml says 17.
- Make sure no TestFlight build with feature/nudge ships before production has the migration. Without the RPC, the button answers 'doesn't need a nudge'.

### 9.5 PR 6: Home Screen and Lock Screen widgets

Branches: `feature/widgets` · Server: no · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **Practice (PR 12).** The snapshot builder skips practice: `guard !p.isPractice` in `Match(presentation:)`, and practice never appears in the person picker. Whichever of PR 6 and PR 12 merges second adds it with a unit case in `testWidgetSnapshotKeepsLiveScheduledAndRecentResultsOnly`.
- **Live Activity (PR 7)** adds `MatchLiveActivityWidget()` to this target's bundle and its shared sources (`HealthComp/LiveActivity`, `CompetitionLeadText.swift`) to `targets.HealthCompWidgets.sources`.
- **Belt glyph:** not in this PR or this round (Q-widgets-7).
- **Recap (PR 2)** edits `competitionWeekText` in `CompetitionWeekChart.swift`; this PR moves `CompetitionDayOutcome` and the bars out of the same file. Different symbols; rebase by symbol.

#### PR scope
- `feature/widgets`: New HealthCompWidgets WidgetKit extension (systemSmall, systemMedium, accessoryRectangular, accessoryCircular) with an AppIntent person picker; App Group container; the app writes a points-only snapshot after each reconcile where discovery succeeded, carrying forward matches that didn't sync, and reloads only when the content changes. It clears the snapshot on every signed-out path. Small Foundation-only helpers move into CompetitionDateFormatting.swift. No server change.

Line numbers are from `main` at 8c5ca25. Re-anchor by symbol after a rebase.

**Prototype check (2026-11-01, Mac mini, Xcode 26.6).** The `project.yml`, xcconfig, entitlements and Staging-plist changes below were applied to a scratch copy, along with a stub widget (AppIntentConfiguration, containerBackground, privacySensitive, widgetAccentable), compiling `Theme.swift` and `CompetitionDateFormatting.swift` into the extension.
- XcodeGen 2.46.0 generated an "Embed Foundation Extensions" phase.
- `scripts/test-staging-apple-web-build-contract.sh` passed.
- CI's unsigned Release device command (`-xcconfig Configuration/CI.xcconfig`) reported BUILD SUCCEEDED, with `PlugIns/HealthCompWidgets.appex` (and its `Metadata.appintents`) inside the app.
- The appex reported version 1.0, and `HEALTHCOMP_APP_GROUP` expanded to `group.com.narenyenuganti.HealthComp`.
- `verify-app-privacy-manifest.sh --app-bundle` passed with no manifest change.
- Not run: the Xcode 16.4 build and the Simulator ad hoc signing build. CI covers both.

#### Scope
- New WidgetKit extension target `HealthCompWidgets` with one widget, kind `CompetitionMatchWidget`.
  - Families: `.systemSmall`, `.systemMedium`, `.accessoryRectangular`, `.accessoryCircular`.
  - Configured through an iOS 17 `AppIntentConfiguration` with an optional Person parameter.
- An App Group shared container. The app writes `CompetitionWidgetSnapshot.json` there (points only) after each publication where discovery succeeded.
  - Matches that didn't sync this round are carried forward from the last file.
  - It calls `WidgetCenter.shared.reloadAllTimelines()` only when the content changed. An `updatedAt`-only change does not count.
  - Every signed-out path deletes the file: sign-out, account deletion, a session ending, and a cold launch with no session.
- The extension only reads that file. It makes no network calls, uses no HealthKit, and links no CompetitionCore, TCA or Supabase.
- Tapping the widget opens that match through the existing `healthcomp://competition/<uuid>` route (`healthcomp-staging://` in Staging).
- Small Foundation-only helpers move into `CompetitionDateFormatting.swift`, so the app and the widget share one rule:
  - moved: `CompetitionDayOutcome`, `competitionMarginText`;
  - new: `competitionLeadSentence`, `competitionSignedMarginText`.
- **Not in scope:** stakes of any kind, the belt glyph (open questions), Live Activities (a separate PR that reuses this target), interactive widget buttons, `accessoryInline`, and any server or push change.

#### Behavior

##### Which match the widget shows (evaluated at each timeline entry's date)
1. **Live (Day 1–7), ending soonest.**
   - Ties break by start, then name (`localizedStandardCompare`), then uuid. This is the same order as `competitionHomeLayout`'s `live` (CompetitionSharingView.swift:1617-1621).
   - One difference from Home: Day 1–7 matches rank ahead of "Final score pending". A pending tally has already ended, so ordering by end alone would always put it first, and hide an active match behind it until the tally deadline.
2. **Otherwise "Final score pending"**, by end, then name, then uuid.
3. **Otherwise the next scheduled match**, by start, then name, then uuid.
4. **Otherwise the latest result**, by `completedAt` descending, while it is still before Home's leave time (`competitionResultLeavesHome`, CompetitionSharingView.swift:1691-1720).
   - That time is the later of two match-calendar midnights: the start of the 4th day after Day 7 (the mockup's "3 days"), and the start of the 2nd day after the day the tally finished.
   - A late tally therefore keeps the result longer.
5. **Otherwise the empty state.**
- When the widget has a Person picked, the same chain runs on that person's matches only. If nothing matches, see the picked-person rows below (Q-widgets-1).
- Pending challenges, closed challenges, cancelled matches and archived matches never appear as a match. Only one thing about them reaches the widget: the empty state's "A challenge is waiting." line (a Bool, Q-widgets-4).

##### States and exact copy
`{Name}` is the display name in the current snapshot, including "Former competitor". It is never a name stored in the widget configuration.
- Numbers come from `competitionPointsText`: whole points with locale grouping.
- A decided result uses `competitionFinalFractionDigits`, so decimals appear only when whole numbers would tie.
- Lead sentences follow `competitionLeadText` (CompetitionDetailView.swift:1048-1066), including the period.

| State at entry date | Status (small) | Compact status (rectangular, redacted VO) | Lead line (small) | Circular caption / value |
|---|---|---|---|---|
| Scheduled (before Day 1 starts) | `Day 1 is Monday` (full weekday of Day 1 in the match calendar zone, same words as CompetitionDetailView.swift:799) | `Day 1 is Monday` | none; scores hidden | `DAY 1` / `Mon` |
| Day 1–6 | `Day 5 of 7` | `Day 5` | `You lead by 54.` / `Sam leads by 54.` / `All square.` | `LEAD` / `+54`, `−54` (U+2212) or `0` |
| Day 7 | `Last day` | `Last day` | same as above | same as above |
| After the end, no result yet | `Final score pending` | `Final score pending` | same as above | `LEAD` / signed margin |
| Result | `You won` / `{Name} won` / `Tied` (the card titles in `competitionStatusText`, CompetitionSharingView.swift:1449-1456) | `Final` | `Won by 114 points` / `Lost by 20 points` (`competitionMarginText`); none on a tie | `WON` / `LOST` / `TIED` and the signed margin |
| Snapshot exists, nothing to show | title `Nothing live right now`, line `Challenge someone`, or `A challenge is waiting.` when `hasIncomingChallenge` | `Nothing live right now` | none | SF Symbol `plus` |
| Person picked, in snapshot, nothing to show | `No match with {Name} right now.` | `{Name}` / `No match right now` | none | `plus` |
| Person picked, not in snapshot | `No match with this person right now.` | `No match right now` | none | `plus` |
| No snapshot (never written, signed out, before first unlock after a reboot) | title `HealthComp`, line `Open the app to see your matches.`. A picked person is ignored. | `HealthComp` / `Open the app to see your matches.` | none | `plus` |

- **Where the copy comes from.**
  - "Nothing live right now" is Home's title when the person has past records (CompetitionSharingView.swift:324).
  - "Challenge someone" is the playbook's words ("then 'Challenge someone'").
  - Home never shows these two together: with no records it says "No matches yet" / "Challenge someone to start a match." (:388). The widget can't know about past records, so this pairing is new copy.
  - "A challenge is waiting." is new copy (Q-widgets-4).
- **Updated line.** Every state that shows scores ends with `Updated {competitionUpdatedText(updatedAt, now: entry.date)}`. That reads "Updated 9:30 AM" today and "Updated Tue 9:30 PM" on an earlier day.
  - `updatedAt` is the newer of `lastSuccessfulFullWindowRefreshAt` and `opponentUpdatedAt`: the same two times as the app's freshness line (`competitionFreshnessText`, CompetitionDetailView.swift:1016-1035).
  - When both are nil, the line is omitted. Scheduled matches have no Updated line.
  - This deviates from the mockup on purpose. "Updated" means the newest number on the widget, not when iOS last redrew it.
- **Today line (medium only).**
  - Shows `Today 212` under each number while live, from that day's points at the entry date.
  - During "Final score pending" it reads `Day 7 212`, matching `competitionScorePeriodLabel` (CompetitionDetailView.swift:1041-1046).
  - Hidden when that side's points for the day are nil, and hidden for scheduled matches and results.

##### Per family (Theme tokens only)
- **systemSmall:**
  - Top: the status in `Font.themeLabel`, uppercase, `Theme.secondary`.
  - Two rows: `You` + number in `Theme.you`, then `{Name}` + number in `Theme.ink`.
  - Numbers use `Font.score(size: scoreSize)`, where `@ScaledMetric(relativeTo: .title) private var scoreSize: CGFloat = 28` follows Dynamic Type as Theme.swift:70-71 asks, plus `.monospacedDigit()`, `.minimumScaleFactor(0.5)` and `.lineLimit(1)`.
  - Then the lead line (`.caption`, `Theme.secondary`) only if it fits, via `ViewThatFits(in: .vertical)`.
  - Footer: the Updated line (`.caption2`, `Theme.tertiary`).
  - **Scheduled:** status, then `{Name}` (`.title3.weight(.heavy).width(.condensed)`, `Theme.ink`). No numbers and no footer.
  - Deviation from the mockup: the footer is the Updated time, and the lead line drops first (Q-widgets-5).
- **systemMedium:**
  - Header row: `{Name} · {status}` on the left, `Updated …` on the right.
    - Results use `{Name} · Final` (this avoids "Sam · Sam won").
    - Scheduled uses `{Name} · Day 1 is Monday` with no Updated.
  - Body: your number on the left in `Font.score(size: mediumScoreSize)` (`@ScaledMetric(relativeTo: .largeTitle) … = 40`), `Theme.you`, captioned `YOU`. The week strip in the middle. Their number on the right in `Theme.ink`, captioned with the uppercased name (Q-widgets-6).
  - Live: the Today lines sit under the numbers. Result: one line under the strip, `Won by 114 points` / `Lost by 20 points` / `Tied` (`.caption`, `Theme.secondary`). Scheduled: no numbers, only the strip of 7 upcoming bars.
  - The strip draws 7 `CompetitionDayBar`s with the same states as `CompetitionWeekStrip`: won `Theme.youFill`, lost `Theme.ink`, tied `Theme.tertiary`, no data hatched `Theme.faint`, upcoming `Theme.outline` stroke, today a dashed stroke in the leader's color.
  - At large text sizes `ViewThatFits` drops the strip first, then the Today lines.
- **accessoryRectangular:** up to three lines.
  1. `{Name} · {compact status}`, with ViewThatFits falling back to `{Name}`.
  2. `You 1,204 · Sam 1,150`, falling back to `You 1,204 · 1,150`.
  3. `Updated 9:30 AM`.
  - Scheduled: line 1 `{Name}`, line 2 `Day 1 is Monday`, no line 3.
  - Result: line 1 `{Name} · Final`, then lines 2 and 3 as above.
  - Deviation from the mockup: it adds the second name and the third line.
  - Default foreground, no Theme colors. Lock Screen vibrant mode ignores tint.
- **accessoryCircular:** a caption (`.caption2` bold condensed) above the value (`.title3` heavy compressed, `.minimumScaleFactor(0.5)`). The background comes only from `containerBackground` (below), not from an in-body view.
- **Backgrounds and accents:**
  - Home Screen families use `.containerBackground(Theme.ground, for: .widget)`.
  - Circular uses `.containerBackground(for: .widget) { AccessoryWidgetBackground() }`. Rectangular uses `.containerBackground(for: .widget) { Color.clear }`.
  - Your number gets `.widgetAccentable()`, so the iOS 18 tinted Home Screen keeps "you" as the accent.
  - No ring colors anywhere.

##### Tap
- `.widgetURL(match.url)` on the whole widget. The url is `\(CompetitionRoute.customURLScheme)://competition/<lowercased uuid>`, built by the app when it writes the snapshot, so the widget never hardcodes a scheme.
- `HealthCompApp.swift:248-251` `.onOpenURL` (inside `AppRootView` only) already parses it (`CompetitionRoute(url:)`, CompetitionNotificationClient.swift:141-215, host `competition`) and enqueues it on the live hub.
- `MainTabFeature.resolve` (MainTabFeature.swift:915-956) then:
  - closes History and the Account sheet and sets `path = [id]`;
  - holds an unknown id for 15 s (`routeHoldTimeout`, :211) while it refreshes, then drops it.
  - The hub replays pending routes on cold start (`CompetitionRouteHub.stream`). No routing code changes.
- The empty, picked-person-empty and no-snapshot states have no url, so the app just opens (Q-widgets-3).

##### Picking a person (Edit Widget)
- `CompetitionWidgetIntent: WidgetConfigurationIntent`:
  - title `Match`;
  - description `Shows the match ending soonest, or your match with the person you pick.`;
  - one optional parameter, `@Parameter(title: "Person") var person: CompetitionPersonEntity?`. Empty means the default chain above.
- **Suggested people:** the distinct `personID`s (`opponentIdentity`) in the snapshot, sorted by name.
  - Matches named "Former competitor" are left out. Those people can't start new matches, and several would show as identical entries. Their results still appear in the default chain.
  - There is no directory and no lookup: you can only pick someone you already have a live, scheduled or recent match with.
- **`entities(for:)` returns an entity for every requested id**, so WidgetKit never rehydrates a stored person as nil and silently falls back to the default chain.
  - The entity's name is the snapshot name when the id is there; otherwise it is `The other person` (§5 glossary).
- **The view ignores the entity's name.** It looks `personID` up in the current snapshot (states table).
  - So a widget configured under a previous account, or for someone who has since deleted their account, never shows the old name.
  - With no snapshot, the configuration is ignored entirely.
- Gallery: `.configurationDisplayName("Match")`, `.description("The score of your match.")`.

##### Privacy
- **Snapshot contents:** names, opponent identities, totals, per-day points, dates, outcome, match ids, and one `hasIncomingChallenge` Bool. There is no kcal, minutes, hours, goals or ring values, and no challenger name.
- Points are already uploaded to the server and shown on Home, so nothing new leaves the iPhone. The App Group container is on-device.
- **File handling:** the file is written with `.completeFileProtectionUntilFirstUserAuthentication`, so Lock Screen widgets can read it after the first unlock. `isExcludedFromBackup = true` is set after every atomic write, because the data can be rebuilt.
- **Redaction:** names, numbers and name-bearing status text (`{Name} won`) are `.privacySensitive()`, so the system redacts them on a locked device under the user's setting (Q-widgets-2).
  - Each view reads `@Environment(\.redactionReasons)`. When it contains `.privacy`, the VoiceOver label becomes `HealthComp, {compact status}.` with no names or points.
  - Without this, the custom label string would be read aloud while the view is visibly redacted.
- **Clear on every signed-out path**, so a signed-out phone never shows the old account's match (see §8):
  - every teardown's `removeProfileStorage` stage, including `restoredWithoutSession` with a nil profileID;
  - a cold launch whose restore finds no session.
- No server push or copy changes.
- **No new required-reason API.** The extension uses only `Data(contentsOf:)` and `JSONDecoder`. The app uses `Data.write` and `setResourceValues`, with no `UserDefaults(suiteName:)` and no file timestamps. `PrivacyInfo.xcprivacy` and `verify-app-privacy-manifest.sh` stay unchanged, and the extension ships no manifest.

##### Timing (the widget updates on iOS's schedule, not ours)
- **The app reloads the widget when the content changes.** The hook is in `publish(materializations:profile:issues:knownCompetitionIDs:)`, whose only callers are reconcile (:786) and the boundary republish (:1767).
  - **No write when discovery failed** (`knownCompetitionIDs == nil`): the full set of matches is unknown, so the last good file stays.
  - **Carry-forward:** ids in `knownCompetitionIDs` without a materialization this round keep their last-written `Match`, unless the dashboard already shows them (from `keepingFailedCompetitions`). These are matches whose sync was cancelled or failed.
    - This covers the HealthKit background relaunch, where `lastMaterializations` and `latestPublication` start empty.
    - A carried-forward match still advances and expires on its own dates, and its Updated line shows its age.
  - **Dedupe:** a snapshot equal to the last written one does nothing.
    - When only `updatedAt` differs (every Health read sets a new `readAt`, RemoteCompetitionClient.swift:2203), the file is rewritten without a reload. The next reload or timeline entry picks up the newer time.
    - Any other change writes and reloads.
  - Before the first write in a process, `lastWritten` is seeded from the file on disk. A background relaunch with unchanged data then doesn't spend the reload budget, and carry-forward has something to carry.
- **The widget advances on its own.**
  - The timeline provider returns one entry for now, plus one entry for each future boundary in the snapshot (each Day start, each `endsAt`, each result `leavesAt`), at most 12, with policy `.atEnd`. With no future boundary the policy is `.never`.
  - That way "Day 5 of 7" becomes "Day 6 of 7" at the match calendar's midnight, "Final score pending" appears at the end, and a result leaves on time, all without the app running.
- **Day rollover with a stale snapshot.** The new day's Today line is hidden (its points are nil). The strip draws the previous day from its last known points, as the app would before its next refresh, and the Updated line says how old they are.

##### Accessibility
- **One element per family:** `.accessibilityElement(children: .ignore)` with a label from `CompetitionWidgetSnapshot.Match.accessibilityLabel(at:redacted:locale:)`.
  - Live example: "Sam, Day 5 of 7. You 1,204 points. Sam 1,150 points. You lead by 54. Updated 9:30 AM."
  - Redacted: "HealthComp, Day 5." A result reads "HealthComp, Final."
  - Points use `competitionPointsAccessibilityText`, so VoiceOver never reads "--".
  - Circular, unredacted: "You lead Sam by 54 points", "Sam leads by 54 points" or "All square with Sam".
  - Empty states read their visible text.
- Accessibility identifiers (not used by CI; they help a local springboard query): `widget.match`, `widget.empty`. No existing app identifier changes.
- **Dynamic Type:** text uses text styles, and the score numerals use `@ScaledMetric` sizes with `minimumScaleFactor(0.5)`.
  - The ViewThatFits fallbacks above keep the status, both numbers and the Updated line at every size the system gives widgets.
  - There are no tap targets inside: the whole widget is one target.

#### Design

##### 1. `project.yml`
- **Target `HealthComp`:**
  - info properties (:35-57): add `HEALTHCOMP_APP_GROUP: "$(HEALTHCOMP_APP_GROUP)"`;
  - dependencies (:67-72): add `- target: HealthCompWidgets`. XcodeGen embeds it in "Embed Foundation Extensions" (prototype-verified).
- **New target after :72:**
```yaml
  HealthCompWidgets:
    type: app-extension
    platform: iOS
    sources:
      - path: HealthCompWidgets
      - path: HealthComp/Features/Widgets/CompetitionWidgetSnapshot.swift
      - path: HealthComp/Features/Competition/CompetitionDayBar.swift
      - path: HealthComp/Features/Competition/CompetitionDateFormatting.swift
      - path: HealthComp/App/Theme.swift
    info:
      path: HealthCompWidgets/Info.plist
      properties:
        CFBundleDisplayName: HealthComp
        HEALTHCOMP_APP_GROUP: "$(HEALTHCOMP_APP_GROUP)"
        NSExtension:
          NSExtensionPointIdentifier: com.apple.widgetkit-extension
    settings:
      base:
        CODE_SIGN_ENTITLEMENTS: HealthCompWidgets/HealthCompWidgets.entitlements
        PRODUCT_BUNDLE_IDENTIFIER: com.narenyenuganti.HealthComp.widgets
        TARGETED_DEVICE_FAMILY: "1"
        SWIFT_VERSION: "5.9"
      configs:
        Staging:
          PRODUCT_BUNDLE_IDENTIFIER: com.narenyenuganti.HealthComp.staging.widgets
```
- The shared files stay in the app through `path: HealthComp`. XcodeGen gives them one file reference and two build files.
- The explicit bundle IDs are required: the default `com.narenyenuganti.HealthCompWidgets` isn't prefixed by the app's ID, and the build fails without them.
- Deployment target 17.0 is inherited (`options.deploymentTarget`). `HEALTHCOMP_STAGING` reaches the extension through the project-level Staging.xcconfig.
- Schemes are unchanged: building HealthComp builds its dependency.
- Commit the generated `HealthCompWidgets/Info.plist`. XcodeGen's defaults give `1.0` (`1`), the same literals as the app plists.
- Regenerate with `~/tools/xcodegen/bin/xcodegen generate` on the Mac mini and commit `project.pbxproj`.

##### 2. Configuration
- `Configuration/Base.xcconfig`: add `HEALTHCOMP_APP_GROUP = group.com.narenyenuganti.HealthComp` (Debug and Release share the production bundle ID).
- `Configuration/Staging.xcconfig`: add `HEALTHCOMP_APP_GROUP = group.com.narenyenuganti.HealthComp.staging` before the `#include?` line.
- `Configuration/Staging-Info.plist`: add `HEALTHCOMP_APP_GROUP` = `$(HEALTHCOMP_APP_GROUP)` right after `HEALTHCOMP_APNS_ENVIRONMENT` (:40-41). "APNS" sorts before "APP_", which matches where XcodeGen writes it in `HealthComp/Resources/Info.plist`.
  - `test-staging-apple-web-build-contract.sh` compares the two plists with `jq -S` and fails `staging_base_plist_drift` unless both gain the key.
- `HealthComp/Resources/HealthComp.entitlements`: add `com.apple.security.application-groups` = [`$(HEALTHCOMP_APP_GROUP)`].
- New `HealthCompWidgets/HealthCompWidgets.entitlements` with only that key.

##### 3. Shared model: new `HealthComp/Features/Widgets/CompetitionWidgetSnapshot.swift` (Foundation only, compiled into both targets)
```swift
struct CompetitionWidgetSnapshot: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let fileName = "CompetitionWidgetSnapshot.json"
    var version = Self.currentVersion
    var matches: [Match]
    var hasIncomingChallenge: Bool      // a pending incoming challenge exists; no name, no count

    struct Match: Codable, Equatable, Sendable {
        var id: UUID
        var personID: String            // opponentIdentity
        var name: String                // opponentDisplayName
        var url: URL                    // CompetitionRoute.competition(id).url, built by the app
        var timeZoneIdentifier: String  // match calendar
        var dayStarts: [Date]           // 7 instants, match-calendar midnights
        var endsAt: Date                // midnight after Day 7
        var userPoints: Double
        var opponentPoints: Double
        var userDayPoints: [Double?]    // 7, by ordinal
        var opponentDayPoints: [Double?]
        var updatedAt: Date?
        var final: Final?
    }
    struct Final: Codable, Equatable, Sendable {   // not `Result`: avoids shadowing Swift.Result
        enum Outcome: String, Codable, Sendable { case win, loss, tie }
        var outcome: Outcome
        var completedAt: Date
        var leavesAt: Date
    }
    enum State: Equatable, Sendable {
        case scheduled, live(day: Int), finalPending, final(Final.Outcome), gone
    }
}
```
- **`Match.state(at:) -> State`:**
  - with `final`: `.final` before `leavesAt`, then `.gone`;
  - else before `dayStarts[0]`: `.scheduled`;
  - else at or after `endsAt`: `.finalPending`;
  - else `.live(day: last index whose start ≤ date, plus 1)`.
- **`featured(personID: String?, at: Date) -> Match?`** implements the chain in Behavior: live, then finalPending, then scheduled, then final.
- **`name(for personID: String) -> String?`** returns the first match's name for that id, or nil.
- **`suggestedPeople() -> [(id: String, name: String)]`:** distinct, excludes "Former competitor", sorted by `localizedStandardCompare`.
- **`ignoringUpdatedAt`:** a copy with every `updatedAt` set to nil. The writer uses it for the reload decision.
- **`merging(carriedForward ids: Set<UUID>, from previous: Self?) -> Self`:** appends the previous matches whose id is in `ids` and not already in `matches`.
- **`timelineDates(after: Date) -> [Date]`:** future `dayStarts`, `endsAt` and `leavesAt`, sorted, unique, `prefix(12)`.
- **`dayOutcomes(at:) -> [CompetitionDayOutcome]`** calls the shared rule (§4) with `hasOccurred: dayStarts[i] <= date`.
- **Copy:** `Match.status(at:compact:locale:)`, `Match.mediumHeader(at:locale:)`, `Match.leadLine(at:locale:)`, `Match.accessibilityLabel(at:redacted:locale:)`, and the circular caption and value.
  - The weekday uses a `DateFormatter` with template `EEEE`/`EEE` in `timeZoneIdentifier`.
  - The empty-state helpers `emptyLine` and `pickedPersonEmptyText(personID:)` follow the states table.
- **`static func fileURL(bundle: Bundle = .main) -> URL?`:** reads `HEALTHCOMP_APP_GROUP` from the Info.plist and calls `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.
- **`static func load(from: URL?) -> Self?`:** returns nil on a missing file, bad JSON or another version. A future version bump fails closed to "Open the app…".
- **`static func sample(now: Date, url: URL) -> Self`:** Sam, Day 5, 1,204–1,150, UTC calendar. The caller passes the url, because this Foundation-only file can't see `CompetitionRoute` (app only).
  - The DEBUG app flag passes a real `customURLScheme` url.
  - The extension's placeholder and gallery pass `URL(fileURLWithPath: "/")`, with the comment `// never tapped: placeholder and gallery entries aren't interactive`.

##### 4. `HealthComp/Features/Competition/CompetitionDateFormatting.swift` (stays Foundation-only)
- **Move `enum CompetitionDayOutcome`** from CompetitionWeekChart.swift:492-494.
- **Add** `func competitionDayOutcome(ordinal: Int, currentDayOrdinal: Int?, hasOccurred: Bool, ownerPoints: Double?, opponentPoints: Double?) -> CompetitionDayOutcome`.
  - The body is :497-513, with `hasOccurred` in place of `ownerLatestAvailability != .notYetOccurred`.
  - CompetitionWeekChart.swift:497-513 becomes a one-line wrapper.
  - `competitionDaysSummaryText` (CompetitionResultView.swift:842) and the tests at CompetitionPresentationTests.swift:939-952 are unchanged.
- **Move `competitionMarginText`** from CompetitionResultView.swift:820-838 (signature at :822), unchanged. It only calls shared functions.
- **Add `competitionLeadSentence(userPoints:opponentPoints:opponentDisplayName:fractionDigits: = 0, locale:) -> String`:** "You lead by 12.", "Hermes leads by 382." or "All square.".
  - Same margin rule as `competitionLeadText`.
  - The styled `Text` version stays in CompetitionDetailView, because the shared file can't use SwiftUI.
- **Add `competitionSignedMarginText(userPoints:opponentPoints:fractionDigits:locale:) -> String`:** "+54", "−54" (U+2212) or "0", from the displayed margin.

##### 5. New `HealthComp/Features/Competition/CompetitionDayBar.swift` (SwiftUI, both targets)
- Move `HatchFill` (CompetitionWeekChart.swift:526-538) and `HatchBar` (:540-546, now internal) here.
- Add `struct CompetitionDayBar: View { let outcome: CompetitionDayOutcome; let todayColor: Color }`, the switch from `CompetitionWeekStrip.bar` (:115-134).
- `CompetitionWeekStrip.bar(_:)` becomes `CompetitionDayBar(outcome: competitionDayOutcome(day, currentDayOrdinal:), todayColor: leaderColor(day))`.
- The rows at :165, :413 and :440 keep using `HatchBar`.
- Behavior is identical. Existing UI tests and captures are unaffected.

##### 6. App writer: new `HealthComp/Services/CompetitionWidgetSnapshotClient.swift`
```swift
import Dependencies
import Foundation
import WidgetKit

struct CompetitionWidgetSnapshotClient: Sendable {
    /// Writes `snapshot`, keeping last-written matches whose id is in `carryForward`.
    var write: @Sendable (_ snapshot: CompetitionWidgetSnapshot, _ carryForward: Set<UUID>) async -> Void
    var clear: @Sendable () async throws -> Void
    static let noop = Self(write: { _, _ in }, clear: {})
    static func live(fileURL: URL?, reload: @escaping @Sendable () -> Void) -> Self  // backed by a private actor
}
extension CompetitionWidgetSnapshotClient: DependencyKey {
    static let liveValue = Self.live(fileURL: CompetitionWidgetSnapshot.fileURL(),
                                     reload: { WidgetCenter.shared.reloadAllTimelines() })
    static let testValue = Self.noop
}
extension DependencyValues { var competitionWidgetSnapshotClient: CompetitionWidgetSnapshotClient { … } }
```
- **`write`:**
  - does nothing when `fileURL == nil`;
  - seeds `lastWritten` once from `load(from:)`;
  - `let next = snapshot.merging(carriedForward: carryForward, from: lastWritten)`;
  - does nothing when `next == lastWritten`;
  - otherwise does `JSONEncoder().encode`, then `data.write(to:options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])`, then sets `isExcludedFromBackup = true`;
  - calls `reload()` only if `next.ignoringUpdatedAt != lastWritten?.ignoringUpdatedAt`, then sets `lastWritten = next`;
  - errors are swallowed, with the comment `// ponytail: a failed write keeps the last file; the next publish retries`.
- **`clear`:** sets `lastWritten = nil` and removes the file. It ignores `CocoaError.fileNoSuchFile`, rethrows other errors, then calls `reload()`.
- **Builder** `extension CompetitionWidgetSnapshot { init(dashboard: CompetitionDashboard) }`:
  - It is non-failable. The "don't blank a good widget" job moves to the publish hook (§7) and carry-forward.
  - It maps each presentation through `Match(presentation:)`:
    - `.scheduled`, `.active`, `.endsToday` and `.tallying` have no `final`;
    - `.completed(outcome, _, completedAt)` gets a `final` with `leavesAt = competitionResultLeavesHome(p)?.at`, or is skipped when that is nil;
    - every other lifecycle is skipped.
  - `hasIncomingChallenge = dashboard.competitions.contains { if case .pending(.incoming, _, _) = $0.lifecycle { true } else { false } }`.
  - **Field sources:**
    - `dayStarts` from `schedule.calendar.sevenDayWindow(startingOn:)` mapped through `schedule.calendar.startOfDay`;
    - `endsAt` from `competitionScheduleBoundaries(schedule)?.end` (CompetitionDetailView.swift:849-864);
    - points from `p.userPoints` and `p.opponentPoints` (what Home shows);
    - day points from `p.days` by `ordinal` (`ownerAcceptedPoints`, `opponentRevealedPoints`);
    - `personID = p.opponentIdentity` (LocalCompetitionClient.swift:181);
    - `updatedAt = [p.lastSuccessfulFullWindowRefreshAt, p.opponentUpdatedAt].compactMap { $0 }.max()`;
    - `url = CompetitionRoute.competition(p.id).url` (6a below); never built by hand.
  - A presentation without a schedule (or, never in practice, a nil url) is skipped.

##### 6a. `HealthComp/Services/CompetitionNotificationClient.swift` (`CompetitionRoute`, :141)
- Add `var url: URL?`: `.competition(id)` → `URL(string: "\(Self.customURLScheme)://competition/\(id.rawValue.uuidString.lowercased())")`, nil for the other cases. Lowercased because `init?(url:)` (:192-195) rejects an uppercase uuid. PR 7's Live Activity attributes reuse it, so widget and Live Activity links are built one way.

##### 7. `HealthComp/Features/Competition/RemoteCompetitionClient.swift`
- **:5-29 `live(provider:)`:** pass `widgetSnapshots: .liveValue`.
- **:31-51 `remote(...)`:** add `widgetSnapshots: CompetitionWidgetSnapshotClient = .noop` before `lifecycleInvalidationObserver` (:50, which the tests at RemoteCompetitionClientTests.swift:2048 and :2127 pass by label). Thread it into `RemoteCompetitionClientCoordinator.init` (:433-463) as `private let widgetSnapshots`.
- **`publish(materializations:profile:issues:knownCompetitionIDs:)` (:1693-1738):** after the `notificationCoordinator.submit(…)` call that starts at :1728, add:
```swift
if let knownCompetitionIDs {
    let unsynced = Set(knownCompetitionIDs.subtracting(materializedIDs).map(\.rawValue))
    await widgetSnapshots.write(CompetitionWidgetSnapshot(dashboard: publication.dashboard), unsynced)
}
```
  - `materializedIDs` already exists at :1720.
  - The callers are reconcile (:786) and the boundary republish (:1767, which reuses `lastPublishInputs`).
  - It runs inside the operation gate, so `stop()` and teardown can't overtake a write.
  - The empty `publish(materializations:issues:)` (:1677-1691) and `publication(adding:)` (:934-949) do not write.
- The DEBUG Test Labs inject their own clients and never write.

##### 8. `HealthComp/App/AppFeature.swift`
- Add `@Dependency(\.competitionWidgetSnapshotClient) private var competitionWidgetSnapshotClient` after :199.
- **`resumeTeardown`, `case .removeProfileStorage` (:1035-1052):** inside the same `profileTransitionGate.run`, call `try await competitionWidgetSnapshotClient.clear()` first, outside the `if let profileID` block.
  - So `restoredWithoutSession` (profileID nil, :277-283) clears too.
  - A failure takes the existing `.teardownFailed(stage: .removeProfileStorage)` path ("signOutCleanupFailed"), so it can be retried.
  - This stage runs after `.prepareRuntime` has stopped the client (:1008-1024), so no later publish can rewrite the file.
- **`restoreSessionResponse`, `.success(nil)` (:269-292):** the cold-launch branch that calls `becomeSignedOut(state:message: nil)` (:285-286) returns `.run { _ in try? await competitionWidgetSnapshotClient.clear() }` instead of `.none`.
  - This covers a session that ended while the app was closed: a token revoked, or the account deleted from another device or the browser.
  - No runtime is running at this point, so nothing can race the clear.
  - `becomeSignedOut` (:1179-1193) stays a pure state helper.

##### 9. `HealthComp/App/HealthCompApp.swift` (DEBUG only)
- In the DEBUG `init(arguments:…)` (:78-120): `if arguments.contains("--widget-sample") { Task { await CompetitionWidgetSnapshotClient.liveValue.write(.sample(now: Date(), url: URL(string: "\(CompetitionRoute.customURLScheme)://competition/00000000-0000-0000-0000-000000000005")!), []) } }`.
- Use it only with `--multi-user-competition-test-lab`. That path builds no `AppFeature` store (`liveStore = nil`), so no publish or signed-out clear overwrites the sample.
  - A signed-out ordinary launch now clears the file (§8).
- It exists only for deterministic Mac mini captures.

##### 10. Extension: new `HealthCompWidgets/HealthCompWidgets.swift`
- `@main struct HealthCompWidgetBundle: WidgetBundle { var body: some Widget { CompetitionMatchWidget() } }`. The Live Activity PR adds its `ActivityConfiguration` here.
- **`CompetitionPersonEntity: AppEntity`:**
  - `id` = personID, `name`;
  - `static var typeDisplayRepresentation: TypeDisplayRepresentation = "Person"`;
  - `var displayRepresentation: DisplayRepresentation { "\(name)" }`;
  - `static var defaultQuery = CompetitionPersonQuery()`.
- **`CompetitionPersonQuery: EntityQuery`:**
  - `suggestedEntities() async throws` returns `snapshot.suggestedPeople()`;
  - `entities(for identifiers: [String]) async throws` maps every id to an entity named `snapshot?.name(for: id) ?? "The other person"`. It never drops an id.
- `CompetitionWidgetIntent: WidgetConfigurationIntent` with `static var title: LocalizedStringResource = "Match"` and `static var description = IntentDescription("Shows the match ending soonest, or your match with the person you pick.")`.
- `CompetitionWidgetEntry: TimelineEntry { let date: Date; let snapshot: CompetitionWidgetSnapshot?; let personID: String? }`. There is no person name: the view looks it up in `snapshot`.
- **`CompetitionWidgetProvider: AppIntentTimelineProvider`:**
  - `placeholder(in:)` returns `.sample(now:url:)`;
  - `snapshot(for:in:) async` uses `.sample` when `context.isPreview`, otherwise the file;
  - `timeline(for:in:) async` loads `CompetitionWidgetSnapshot.load(from: .fileURL())` and returns the entries described in Timing, with `personID = configuration.person?.id`.
- `CompetitionMatchWidget: Widget` builds `AppIntentConfiguration(kind: "CompetitionMatchWidget", intent: CompetitionWidgetIntent.self, provider: CompetitionWidgetProvider())`, with `.supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryCircular])`.

##### 11. Extension: new `HealthCompWidgets/CompetitionMatchWidgetViews.swift`
- `CompetitionMatchWidgetView` switches on `@Environment(\.widgetFamily)` to `SmallView`, `MediumView`, `RectangularView`, `CircularView` and `EmptyStateView`.
  - The name avoids `SwiftUI.EmptyView`.
- All copy comes from the §3 and §4 helpers.
- Every view applies:
  - `.widgetURL`;
  - `.privacySensitive()` on names, numbers and name-bearing status;
  - `.containerBackground` (family rules above);
  - the accessibility label (from `redactionReasons`) and identifier.
- `@ScaledMetric` score sizes live in `SmallView` and `MediumView`.
- `#Preview(as: .systemSmall)` and `#Preview(as: .systemMedium)` with `.sample` entries for Xcode-only checks.

**API floor.** Everything above exists in the iOS 18.5 SDK, and nothing needs `if #available` at iOS 17.0:
- iOS 17: `AppIntentConfiguration`, `WidgetConfigurationIntent`, `AppIntentTimelineProvider`, `containerBackground(for:)`;
- iOS 16: `AccessoryWidgetBackground`, accessory families, `widgetAccentable`, App Intents `AppEntity`/`EntityQuery`;
- iOS 15: `privacySensitive`, `redactionReasons` `.privacy`;
- iOS 14: `WidgetCenter`, `widgetURL`, `ScaledMetric`.

#### Server changes
- None. There is no migration, so the recovery-harness count and manifest pin don't move.
- No Edge Function and no push text changes.
- Installed 1.0.2 builds have no widget and are unaffected.
- There is nothing to promote to Staging or production before TestFlight.

#### CI
- No workflow change.
- **Signing in CI:** none needed.
  - `Configuration/CI.xcconfig` sets `CODE_SIGNING_ALLOWED[sdk=iphoneos*] = NO` for every target, so the device builds stay unsigned (prototype-verified).
  - Simulator builds sign the app and the extension ad hoc (`CODE_SIGN_IDENTITY = -`), with the App Group entitlement embedded and no provisioning.
- The XcodeGen determinism step covers the new target. HealthCompTests picks up the new test file through `path: HealthCompTests`.

#### Tests
- **`scripts/tests/competition-local-date-formatting.swift`** (standalone, `-warnings-as-errors`):
  - `competitionDayOutcome(ordinal:…)` gives won, lost, tied (300.4 vs 300.2), noData (0–0, one side nil), upcoming and today.
  - `competitionLeadSentence` gives "You lead by 54.", "Sam leads by 54.", "All square." (412.4 vs 411.6 displays 412–412), and de_DE "You lead by 1.217.".
  - `competitionSignedMarginText` gives "+54", "−54", "0", and "+0.20" with 2 digits.
  - `competitionMarginText` keeps its existing expectations (moved from CompetitionPresentationTests.swift:964).
- **New `HealthCompTests/CompetitionWidgetSnapshotTests.swift`:**
  - `testStateAdvancesAtMatchCalendarMidnightsWithoutTheApp`: an America/Los_Angeles week, Oct 28 – Nov 3 2026, which crosses the Nov 1 DST change. `state(at:)` gives:
    - `.scheduled` at Oct 27 23:59 PDT;
    - `.live(day: 1)` at Oct 28 00:00;
    - `.live(day: 5)` on Nov 1 after the DST change;
    - `.live(day: 7)` on Nov 3;
    - `.finalPending` at Nov 4 00:00 PST.
  - `testFinalShowsUntilItLeavesHome`: `.final(.win)` before `leavesAt`, `.gone` at it.
  - `testFeaturedPrefersLiveEndingSoonestThenPendingThenScheduledThenLatestFinal`:
    - two live matches ending Nov 3 and Nov 2 give the Nov 2 one;
    - a Day 3 match beats a `.finalPending` one that ended earlier;
    - with no live or pending match, scheduled Nov 5 beats Nov 6;
    - with neither, the newest unexpired final;
    - with none, nil;
    - equal ends order by name, then uuid.
  - `testFeaturedHonorsPickedPersonAndNeverFallsBack`: personID B with only A live gives nil.
  - `testPickedPersonMissingFromSnapshotUsesGenericCopy`: `pickedPersonEmptyText(personID: "gone")` gives "No match with this person right now.", and no stored name is reachable. A present person gives "No match with Sam right now.".
  - `testSuggestedPeopleExcludeFormerCompetitorAndSortByName`.
  - `testMergingCarriesForwardOnlyRequestedMissingIDs`: an id already in `matches` keeps the new copy.
  - `testTimelineDatesAreFutureBoundariesSortedAndCapped`.
  - `testCopyPerState` (en_US, LA). Small status:
    - "Day 1 is Wednesday", "Day 5 of 7", "Last day", "Final score pending", "You won"/"Sam won"/"Tied".
    - Compact: "Day 5", "Final".
    - Medium header: "Sam · Day 5 of 7", "Sam · Final", "Sam · Day 1 is Wednesday".
    - Rectangular scheduled: lines "Sam" and "Day 1 is Wednesday", with no Updated line.
    - "Updated 9:30 AM" vs "Updated Tue 9:30 PM", and "Won by 114 points".
  - `testEmptyStateSaysAChallengeIsWaiting`: `hasIncomingChallenge` gives "A challenge is waiting."; otherwise "Challenge someone".
  - `testFinalUsesTwoDecimalsOnlyWhenWholePointsTie`: 412.30 vs 412.10.
  - `testAccessibilityLabelNeverReadsDashes`.
  - `testRedactedAccessibilityLabelHasNoNamesOrPoints`: gives "HealthComp, Day 5." and "HealthComp, Final.", with no "Sam" and no digits other than the day.
  - `testLoadRejectsOtherVersionsAndBadJSON`.
  - `testWriterSkipsIdenticalSnapshotsAndReloadsOnChange`: temp dir; a reload counter shows that writes A, A, B reload twice.
  - `testWriterRewritesWithoutReloadWhenOnlyUpdatedAtChanges`: the file holds the new `updatedAt`, and the reload count is unchanged.
  - `testWriterCarriesForwardUnsyncedMatchesFromDisk`: seed the file with A and B, then a fresh client writes `[A']` with carryForward `{B}`. The file holds A' and B.
  - `testWriterSeedsFromDiskSoARelaunchDoesNotReload`.
  - `testWrittenFileIsExcludedFromBackup`.
  - `testClearRemovesTheFileAndToleratesMissing`.
- **`HealthCompTests/CompetitionPresentationTests.swift`** (reuses `homePresentation`, :1511):
  - `testWidgetSnapshotKeepsLiveScheduledAndRecentResultsOnly`:
    - pending, declined, expired, cancelled and archived matches are dropped;
    - a completed match gets `leavesAt == competitionResultLeavesHome(p)!.at`;
    - a late tally (`completedAt` on the 3rd day after Day 7) gets `leavesAt` from the tally day, the start of `completedAt`'s day + 2;
    - `dayStarts.count == 7`;
    - `endsAt` equals the boundaries' end.
  - `testWidgetSnapshotFlagsIncomingChallengeWithoutItsName`.
  - `testWidgetSnapshotURLRoundTripsThroughCompetitionRoute`: `CompetitionRoute(url: match.url) == .competition(id)`.
- **`HealthCompTests/CompetitionRoutingTests.swift`:** new `testCompetitionRouteURLRoundTrips`: `CompetitionRoute(url: CompetitionRoute.competition(id).url!) == .competition(id)`, and `.claimInvite` → nil.
  - `testWidgetSnapshotUpdatedAtIsTheNewerSide`.
  - The existing `competitionDayOutcome` assertions (:939-952) stay and now exercise the wrapper.
- **`HealthCompTests/RemoteCompetitionClientTests.swift`** (reuse the `testMountedRemoteClientPublishesEmptyCanonicalDashboard` (:329) setup with a spy `CompetitionWidgetSnapshotClient`):
  - `testCanonicalPublishWritesTheWidgetSnapshot`: records one `matches == []` write on the first publication, and no write after `stop()`.
  - `testColdMountCarriesForwardAMatchWhoseSyncFailedOrWasCancelled`: two known competitions on a cold mount; one sync throws and one is cancelled. The spy's carryForward holds both ids.
  - `testDiscoveryFailureDoesNotWriteTheWidgetSnapshot`.
- **`HealthCompTests/AppFeatureTests.swift`:**
  - `testSignOutClearsTheWidgetSnapshotBeforeRemovingProfileStorage`: a spy records the order [clear, teardown(profileID)].
  - `testRestoredWithoutSessionTeardownClearsTheWidgetSnapshot`: profileID nil, clear is called.
  - `testColdLaunchWithoutSessionClearsTheWidgetSnapshot`: `restoreSessionResponse(.success(nil))` with no profile reaches `.signedOut`, and clear is called.
  - `testWidgetSnapshotClearFailureRetriesTheStorageStage`: a throwing clear gives `.teardownFailed(stage: .removeProfileStorage)`, matching the table at :523-528.
- **UI tests:** no changes, and no existing identifiers or strings change. Widgets render in SpringBoard, so CI has no widget UI test.

#### Verify on the Mac mini (on top of the shared steps)
1. Copy the branch: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'tar -x -C ~/dev-desktop/<dir>'`. Then run `~/tools/xcodegen/bin/xcodegen generate` twice. `shasum` of `project.pbxproj` must match the committed file both times.
2. Run `bash scripts/test-staging-apple-web-build-contract.sh`, `bash scripts/test-competition-local-date-formatting.sh`, and `bash scripts/verify-app-privacy-manifest.sh`.
3. Use `~/dev-desktop/ua/ua-mac6.sh` for the `unit` and `ci` modes: HealthCompTests, and the Debug, Staging and Release device builds with `-xcconfig Configuration/CI.xcconfig`.
4. Captures on the slot Simulator (iPhone 16 Pro, iOS 18.5):
   - Launch the Debug app with `--multi-user-competition-test-lab --multi-user-competition-scenario sharing --widget-sample`.
   - Add Small, Medium, Rectangular and Circular through a local-only springboard XCUITest appended to the Mac copy and never committed, as in `demo.sh`.
   - Take `xcrun simctl io <sim> screenshot` in light and dark, at default size and with `xcrun simctl ui <sim> content_size accessibility-extra-extra-extra-large`.
   - Also capture the iOS 18 tinted Home Screen, and Edit Widget showing the Person list.
   - No tap check here: the Test Lab root has no `.onOpenURL`.
5. Staging on the Simulator, with the two Staging accounts and an ordinary signed-in launch:
   - The snapshot appears after the first refresh and updates after a score change.
   - A Medium widget tap lands on that match, from the background and after a force quit.
   - Pick the other account's person, sign out, and confirm every widget returns to "Open the app to see your matches.".
   - Sign in as the other account and confirm the picked widget shows "No match with this person right now.", not the old name.
6. Preview artifact: put the captures next to the playbook `#widget` mockups and call out the deviations: the Updated footer, the YOU/{NAME} captions, no belt glyph, the extra rectangular line, and "A challenge is waiting.". The owner approves before the PR opens.
7. On a physical iPhone after the owner's portal steps:
   - Lock Screen redaction while locked;
   - VoiceOver on the locked phone reads no names or points;
   - a cold-start tap.

#### Risks and conflict regions
- **Live Activity PR:** it shares this target. Conflicts are in:
  - `project.yml` (the target block);
  - `HealthCompWidgets/HealthCompWidgets.swift` (the bundle body);
  - possibly `RemoteCompetitionClient.swift` near :1728, where both hook publish.
  - Whichever merges second rebases. If Live Activity lands first, reuse its target and add only this widget.
- **Belt PR:** it touches `CompetitionWeekChart.swift`, and the home card the widget copies. This PR changes only :115-134 and :492-546, and moves code out. Re-anchor by symbol.
- **Recap and other PRs touching `CompetitionResultView.swift`:** only `competitionMarginText` moves out (:820-838). Any caller keeps compiling, because the function keeps its signature and stays module-visible.
- **AppFeature sign-out work:** this PR touches `restoreSessionResponse` (:269-292) and `removeProfileStorage` (:1035-1052). Re-anchor by symbol if another PR changes teardown.
- **Dynamic `UIColor` tokens in widgets.** `Theme` builds colors from `UIColor { traits in … }`. WidgetKit renders each appearance in-process, which should resolve them, but this is unverified.
  - Check dark mode in step 4.
  - Fallback without new colors: resolve with `@Environment(\.colorScheme)` in the views, using the same hex pairs.
- **Reload budget:** background `reloadAllTimelines` calls count against iOS's daily budget (foreground ones don't).
  - Excluding `updatedAt` from the reload decision removes the reload that every Health read would otherwise trigger.
  - During exercise, points still change often. When iOS throttles, the widget catches up at its next allowed reload or boundary entry. That is a staleness ceiling, not a correctness bug, and the Updated line shows it.
  - If captures show starved reloads, add a minimum interval between background reloads.
- **Carry-forward staleness:** a match that keeps failing to sync keeps its last numbers until it leaves on its own dates. That matches Home's `keepingFailedCompetitions` behavior.
- **Signing order:** merging is safe, because CI is unsigned. The first signed Staging or TestFlight build after merge fails until the owner's App Group and App ID steps are done.
  - Update `docs/runbooks/supabase-environments.md` (Apple checklist, :373-385):
    - add the widget App IDs to item 2 (register) and item 5 (profiles);
    - add a new item: both app App IDs and both widget App IDs get App Groups with the per-environment group, and the widget App IDs get nothing else.
  - Item 3 stays as it is: app App IDs only.
- **Shared-source compile:** `Theme.swift` and `CompetitionDateFormatting.swift` now compile into a second module (prototype-verified on Xcode 26.6). Anything added to them later must stay extension-safe: no `UIApplication.shared`, no CompetitionCore in the formatting file.
- **Versioning:** the extension's plist literals match the app's (1.0 / 1). Bumps made outside the repo are covered by the owner action, not by CI.

#### Rollout and compatibility
- App-only. It ships in the next TestFlight after the owner's portal steps, with no server ordering constraint.
- The first launch after updating writes the snapshot on its first reconcile where discovery succeeds. Until then a newly added widget shows "Open the app to see your matches.".
- Downgrading is harmless: an older build ignores the file, and deleting the app removes it with the App Group container.

#### Review notes
All items were checked against 8c5ca25. They are all applied except for these partial rejections:
- **Issue 1 (carry-forward), simpler key:**
  - The write is skipped when discovery fails. Last-written matches are carried forward for `knownCompetitionIDs − materializedIDs`, which already contains the `.competitionFailures` ids, because a failed id has no materialization that round. No separate failure set is needed.
  - This replaces the old issue-based nil guard in `init?(dashboard:)`.
- **Issue 3 (picker rehydration):** the `entities(for:)` fix is applied. The proposed `people` map of archived and older results is rejected. Issue 13's rule (name only from the current snapshot, generic copy otherwise) fixes the same bug with no stored names and no cross-account leak.
- **Issue 12 (clear on signed-out paths):** applied for `removeProfileStorage` without a profileID, and for the cold-launch `becomeSignedOut`. Clearing on launch failure is rejected:
  - `handleLaunchFailure` covers transient states, such as storage unavailable on a background relaunch before first unlock, where the session may still be valid.
  - Blanking there would wipe a good widget.
  - The next restore that finds no session clears it.
- **Issue 16 (tallying rank):** applied. "Indefinitely" overstates it: the tally has a deadline (CompetitionDetailView.swift:933-941, "…by {deadline}, the result uses what's in").
- **Issues 7 and 15** were the same citation error and are fixed once. The incoming-challenge part became a one-Bool flag (Q-widgets-4).
- **Issue 11:** the CI version check is dropped (YAGNI). `.github/workflows/ci.yml` is no longer touched.

#### Owner actions for this feature (merged into §7)
- Apple Developer > Identifiers > App Groups: register group.com.narenyenuganti.HealthComp (production and Debug) and group.com.narenyenuganti.HealthComp.staging (Staging).
- Apple Developer > Identifiers: on App ID com.narenyenuganti.HealthComp turn on App Groups and assign group.com.narenyenuganti.HealthComp. On com.narenyenuganti.HealthComp.staging, assign group.com.narenyenuganti.HealthComp.staging. Leave every other capability (Sign in with Apple, Push, HealthKit with background delivery, App Attest, Associated Domains) as it is.
- Apple Developer > Identifiers: register explicit App IDs com.narenyenuganti.HealthComp.widgets and com.narenyenuganti.HealthComp.staging.widgets under team 23LUYD78QK. Each gets App Groups only, with the same group as its parent app, and no other capability. Automatic signing can create these, but the runbook asks for a portal readback.
- Regenerate the development and App Store distribution provisioning profiles for both app App IDs, and make profiles for both widget App IDs (automatic signing does this on the next signed build). Do it before the next signed Staging device build or TestFlight archive. Once the app entitlements gain com.apple.security.application-groups, signing fails for an App ID without App Groups. CI is unaffected: device builds are unsigned and Simulator builds sign ad hoc.
- At archive and export, confirm HealthComp.app/PlugIns/HealthCompWidgets.appex is signed with the .widgets profile and has the same CFBundleShortVersionString and CFBundleVersion as the app. The repo plists all say 1.0 (1). Today 1.0.2 (1) is set outside the repo, so whenever you bump the app's version, bump the extension the same way. No CI check can see that bump.
- App Attest allowlists, Supabase Apple Auth Client IDs and the APNs topic stay the same: the extension makes no network calls and the app's bundle IDs don't change. No App Store Connect change: the extension ships inside the app.
- After TestFlight, on a physical iPhone: check that the Lock Screen widgets redact while the phone is locked, that VoiceOver on the locked phone reads no names or points, and that a widget tap opens the match from a cold start (the Simulator can't fully prove any of these).

### 9.6 PR 7: Final-day Live Activity

Branches: `feature/final-day-live-activity` · Server: no · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **No Account switch in this PR (PR 13 owns it).** Delete from this section: the "Account → Notifications" behavior block, Design G (switch wiring: `AccountNotificationSettings.liveActivityChanged`, the `@AppStorage` toggle, `HealthCompApp` wiring, `CompetitionFeature.liveActivitySettingChanged`), `CompetitionLiveActivityPreference.storageKey`/`isOn`, the `account.notifications.live-activity*` identifiers, `testLiveActivitySettingChangeReconcilesWithoutNetwork`, and the additions to `testNotificationsPageOpensSettingsAndUnmutes`. Those files leave `files_touched` (`AccountSettingsView.swift`, `CompetitionFeature.swift`, `HealthCompApp.swift`, `CompetitionFeatureTests.swift`).
- **`isAllowed`** in this PR is `ActivityAuthorizationInfo().areActivitiesEnabled`. PR 13 adds the switch check. `startedKey` (`healthcomp.liveActivity.startedMatchIDs`) stays here, in `CompetitionLiveActivityPreference`.
- **Keep** the `reconcileNotifications()` hook (E): PR 13's switch reaches the planner through it.
- **Practice (PR 12).** The planner skips practice: `presentations.filter { !$0.isPractice }` before choosing or reconciling, so a practice ending today never starts a card. Whichever of PR 7 and PR 12 merges second adds it with one case in `CompetitionLiveActivityTests`.
- **Depends on PR 6** for the target; the fallback that creates the target is kept only for the case PR 6 slips.

#### PR scope
- `feature/final-day-live-activity`: App only. Shared ActivityKit attributes and views, a Live Activity widget in the Widgets extension, an app-side planner and coordinator hooked into RemoteCompetitionClientCoordinator.publish, NSSupportsLiveActivities in both Info.plists, a DEBUG preview scenario, and tests. No server work.

Line numbers are from `main` at 8c5ca25. After rebasing onto the Widgets PR, re-anchor by symbol name. **Stakes are out of scope everywhere.** No stakes copy, state or field appears in the attributes, views or tests.

#### Scope
- An ActivityKit Live Activity for the closing hours of one real (remote) match. It shows on the Lock Screen and in the Dynamic Island: both totals, the lead, and how fresh each side's score is.
- **Start:** the app starts it from its normal refresh path while HealthComp is open, during the last 7.5 hours of Day 7 (from 4:30 PM match time; Q-live-1).
- **Updates:** every refresh updates it while iOS still counts it as running. That includes HealthKit background wakes, realtime pushes and the boundary republish. There are no ActivityKit push updates this round.
- **Midnight:** at the match's local midnight it turns into "Final score pending" without the app running (ActivityKit `staleDate`). Midnight is effectively the end of the card. iOS stops it at most 7.5 h after it started, then leaves it frozen on the Lock Screen for up to 4 h or until swiped away.
- **No result card.** When the result arrives while the card is still running, the card ends right away (Q-live-2). The result notification is unchanged.
- **Off switch:** Account → Notifications gets a "Live Activity" switch, stored on the phone and on by default.
- `NSSupportsLiveActivities` is added to the production/Debug Info.plist (via `project.yml`) and to the hand-kept `Configuration/Staging-Info.plist`.
- **Not in scope:**
  - ActivityKit push tokens or push-to-start (server work, later; these would lift the 8 h and foreground-only limits)
  - fixture (Test Lab) matches starting real activities
  - watchOS or CarPlay families (`supplementalActivityFamilies` is iOS 18 only)
  - any server, migration or Edge Function change

#### Mockup conflicts and the closest correct behavior (Claude's calls)

| Mockup / playbook says | Code reality | Built |
|---|---|---|
| "The app calls `Activity.update` at the end of each refresh in `CompetitionSyncCoordinator`" | `CompetitionSyncCoordinator` (Services/CompetitionSyncCoordinator.swift:94) is the outbox drain actor and never sees presentations. Each refresh ends in `RemoteCompetitionClientCoordinator.publish(materializations:profile:issues:knownCompetitionIDs:)` (RemoteCompetitionClient.swift:1693-1738), which already hands every publication to `notificationCoordinator.submit` (:1728-1736). That function runs for foreground refreshes, HealthKit background wakes, realtime updates and the boundary republish (:1757-1775). | The hook goes right after `notificationCoordinator.submit` and also passes `knownCompetitionIDs`. |
| "Starts the first time the app refreshes on the last day … until the result comes in" | iOS ends a Live Activity 8 h after it starts. After that, update and end calls are ignored, and iOS keeps it frozen on the Lock Screen for up to 4 h. `Activity.request` only works while the app is in the foreground. The final tally usually settles after midnight. | Starts on the first foreground refresh in the last 7.5 h of Day 7. Each match starts at most once. Midnight is the effective end, and there is no result card (Q-live-1, Q-live-2). |
| "Final day · Sam" | `.endsToday` already reads "Last day" in the shared formatter (`competitionStatusText`, CompetitionSharingView.swift:1434-1438), and the final-day notification uses the same word. The audit spec requires one name for Day 7. | "Last day · Sam" |
| "Ends midnight" | The formatter's `.endsToday` timing is "Ends at midnight", plus the match zone when the phone's zone differs (:1437). | "Ends at midnight" / "Ends at midnight PST" |
| "You lead by 19" | The app has one lead sentence, `competitionLeadText` ("You lead by 19.", with the margin bold: amber for you, ink for them). | That function, moved so the extension can compile it. |
| Compact island with "DAY 7" in the middle | The compact presentation only has leading and trailing regions; the camera sits in the middle. | Dropped. |
| Slanted divider between the scores | Home's `HeroScoreboard` already draws it: a 2 pt `Theme.outline` rectangle rotated 12°, hidden from VoiceOver, and left out when the layout is stacked (CompetitionSharingView.swift:551-557). | Kept on the Lock Screen with the same code. Dropped at accessibility sizes and in the island. |
| "iOS 16.1+" | The deployment target is 17.0 (project.yml:5). | No `#available` is needed. Every API below is from iOS 16.1, 16.2 or 17.0 and exists in the Xcode 16.4 SDK. |
| One "Updated 6:02" time | The app's freshness line keeps each side separate: `competitionFreshnessText` (CompetitionDetailView.swift:1016-1035) gives "You: updated 5:40 PM · Sam: updated 6:02 PM", "Updated 5:40 PM" (your side only), "Sam: updated 6:02 PM", or nil. | That exact string, so the card claims no more freshness than Home does. |

#### Behavior

**Which match (one at a time)**
- Only `publication.source == .remoteParticipants`. The fixture runs on a logical clock, which would make `staleDate` wrong, so it never starts one.
- `now` is the actor's injected clock (`Date.init` in production). It is not `presentation.evaluatedAt`, so a reconcile from the stored publication (for example after the switch is turned on) uses the real time.
- A match **starts** when all of these hold:
  - `lifecycle == .endsToday`
  - it has a schedule
  - `endsAt - startLead <= now < endsAt`, where `endsAt = competitionScheduleBoundaries(schedule)?.end` (CompetitionDetailView.swift:849-864, match-local midnight after Day 7)
  - its id isn't in the started-ID set
  - no current activity is `.active` or `.stale`
  - the switch is on, and `ActivityAuthorizationInfo().areActivitiesEnabled` is true
- If several qualify, pick the smallest `endsAt`, then the lowercased id string.
- An existing activity keeps its match until it ends. It is never swapped for another match.
- `Activity.request` throws in the background. The error is swallowed, the id is not recorded, and the next foreground refresh tries again.
- **Started-ID set**: UserDefaults key `healthcomp.liveActivity.startedMatchIDs`, capped at 20 ids. Its purpose is that a card the person swiped away (`.dismissed`) doesn't come back on the next launch. Any end the app itself causes, other than a match finishing, removes that id (switch off, iOS Live Activities off, `endAll`). So turning the switch back on, or a later successful mount after a failed one, can start the card again inside the window.
- **Activities iOS has ended** (`.ended` or `.dismissed`, including the 8 h cap) are invisible to the planner. `current()` returns only `.active` and `.stale`. They need no bookkeeping: updates to them are ignored, and the started-ID set stops them from being restarted.
- **Known limit:** the window start (4:30 PM) is not a republish boundary. An app left open across 4:30 PM starts the card on its next refresh (realtime, HealthKit wake, scene activation), not at 4:30 sharp. This is accepted; see Risks.

**States (`MatchActivityAttributes.ContentState.phase`)**

| Phase | When | Header (drawn uppercase) | Right of header | Scores | Bottom rows |
|---|---|---|---|---|---|
| `live` | `.endsToday` | dot + "Last day · Sam" | `competitionStatusText(p, style: .card).timing` → "Ends at midnight" (or "Ends at midnight PST") | whole points | `competitionLeadText`, then the freshness string |
| `pending` (set by the app) | `.tallying`, on a card iOS still runs | "Final score pending · Sam" | none (the formatter's tallying timing is nil, :1440) | whole points | lead sentence + " Not final yet.", then freshness |
| `pending` (stale, no app run) | `context.isStale` on live content | "Final score pending · Sam" | none | as last updated | lead sentence + " Not final yet.", then freshness |

- Titles come from the existing formatter, so the Lock Screen, Home and notifications use the same words.
- The stale fallback title is `MatchActivityCopy.pending = "Final score pending"`. A unit test pins it equal to the formatter's tallying title (CompetitionSharingView.swift:1440).
- `staleDate` is `endsAt` for `live` and nil for `pending`. Because the start window is 7.5 h, `staleDate` always comes at least 30 min before iOS's 8 h end, so every card reaches the stale look while still running.
- `update` is called only when the new `ContentState` differs from `activity.content.state`. Updates never carry an `AlertConfiguration`: no sound or banner, and lead changes stay notifications.

**End rules** (all `end(nil, dismissalPolicy: .immediate)`)
- The match is `.completed` or `.archived` (Q-live-2), or is in any other lifecycle except `.endsToday` / `.tallying`.
- The switch was turned off, or iOS Live Activities are off.
- The match is missing from the dashboard **and** the publication is authoritative (`knownCompetitionIDs != nil`). When discovery failed (`knownCompetitionIDs == nil`, RemoteCompetitionClient.swift:786-791, for example a cache load failure at RemoteCompetitionRuntime.swift:629-637), a missing match leaves the card unchanged. This is the same guard the notification coordinator uses before removing orphans (CompetitionNotificationCoordinator.swift:232-235).
- A second running activity exists (a leftover from a race): keep the first and end the rest.
- `RemoteCompetitionClientCoordinator.stop()` (sign-out, session end, account deletion, or a failed mount, AppFeature.swift:263/938/1020) calls `endAll()`, so another person's name doesn't stay on the Lock Screen. `endAll()` also removes the ids it ended from the started set, so a failed relaunch mount doesn't block the card for the rest of the window.
- On relaunch, an activity left from the previous process is adopted through `Activity<MatchActivityAttributes>.activities`. Nothing besides the started-ID set is persisted.

**Lock Screen view** (`MatchActivityLockScreenView`, mockup #live left)
- **Background and tap**: applied only in `MatchLiveActivityWidget.swift`, around the view (see I). The in-app preview draws `Theme.ground` itself.
- **Header row**: a 6 pt `Theme.ink` circle (live only, hidden from VoiceOver), then the header in `.themeLabel` + `.tracking(1.2)` + `.textCase(.uppercase)` in `Theme.ink`. On the right, the timing in the same label style in `Theme.secondary`.
- **Score row**:
  - Left: "YOU" (`.themeLabel`, `Theme.you`) over the score in `Font.score(size: 40)` `Theme.you`.
  - Middle: the `HeroScoreboard` divider (2 pt `Theme.outline`, height 40, `.rotationEffect(.degrees(12))`, `.accessibilityHidden(true)`).
  - Right: `state.opponentName` (uppercase label, `Theme.ink`) over the score in `Font.score(size: 40)` `Theme.ink`, trailing-aligned.
  - Scores use `competitionPointsText(points)`, `lineLimit(1)` and `minimumScaleFactor(0.5)`.
- **Bottom rows**:
  - `competitionLeadText(userPoints:opponentPoints:opponentDisplayName: state.opponentName)` in `.footnote`, with " Not final yet." appended for pending.
  - Below it, `state.freshness` in `.caption2` `Theme.secondary`, `lineLimit(1)`, `minimumScaleFactor(0.7)`. Omitted when nil.
- **Accessibility sizes** (`dynamicTypeSize.isAccessibilitySize`):
  - hide the header's right timing, the divider and the freshness line
  - the lead line wraps to 2 lines
  - every other line is `lineLimit(1)` with `minimumScaleFactor(0.7)`
  - The Lock Screen card is at most 160 pt tall, so XS through AX5 are checked in the in-app preview inside a 160 pt frame.
- **VoiceOver**: the root is `.accessibilityElement(children: .combine)`. Each score column is `.accessibilityElement(children: .ignore)` with the label "You \(competitionPointsAccessibilityText(...))" / "Sam \(...)". The live card reads: "Last day · Sam, Ends at midnight, You 2,190 points, Sam 2,171 points, You lead by 19., You: updated 5:40 PM · Sam: updated 6:02 PM".

**Dynamic Island** (`MatchLiveActivityWidget`, mockup #live right). Every region gets `.environment(\.colorScheme, .dark)`, so `Theme.you` resolves to #F2A100 and `Theme.ink` to #F5F5F0, and amber stays you on black.
- **compactLeading**: your score, `.headline.weight(.heavy).width(.compressed)`, `Theme.you`. Accessibility label "You \(competitionPointsAccessibilityText(...))".
- **compactTrailing**: their score, same font, `Theme.ink`. Accessibility label "\(opponentName) \(…)".
- **minimal**: the signed shown margin: "+19" in `Theme.you`, "−5" in `Theme.ink` (U+2212), "0" in `Theme.secondary`. Accessibility label: the lead sentence.
- **expanded**:
  - `.leading`: "YOU" over the score (`Font.score(size: 34)`).
  - `.trailing`: the name over the score.
  - `.center`: the header label. For live it adds `Text(attributes.endsAt, style: .relative) + Text(" left")` in `Theme.secondary`, which reads "5 hr, 45 min left" in en_US. iOS updates it with no app work.
  - `.bottom`: the lead line, then the freshness line (`lineLimit(1)`, `minimumScaleFactor(0.7)`).
  - Pending drops the countdown, the same way the Lock Screen does.
- `.widgetURL(attributes.url)`. No `keylineTint`: amber is reserved for you, and the system default keyline is neutral.

**Account → Notifications** (`AccountNotificationsPage`, AccountSettingsView.swift:521)
- A new `Section`, inserted between the status section (:529-568) and MUTED (:570):
  - header `SectionLabel("DURING A MATCH")`
  - row `Toggle("Live Activity", isOn: $liveActivityEnabled)`, `.frame(minHeight: 44)`, identifier `account.notifications.live-activity`. It inherits the app's ink tint.
  - footer: "Shows the score on the Lock Screen in the last hours of a match." (`Theme.secondary`)
- When Live Activities are off in iOS:
  - the toggle is `.disabled(true)`
  - a row `Button("Open Settings")` opens `UIApplication.openSettingsURLString` (the app's own Settings page, where the Live Activities switch lives). It has `.frame(minHeight: 44)` and identifier `account.notifications.live-activity.settings`.
  - the footer reads "Live Activities are off for HealthComp in iOS Settings."
- Enablement is `@State private var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled`, kept current with `.task { for await enabled in ActivityAuthorizationInfo().activityEnablementUpdates { activitiesEnabled = enabled } }` (iOS 16.1). The page therefore updates when the person comes back from Settings.
- It is shown whatever the notification authorization is, because Live Activities don't need notification permission.
- The existing status section, its notification Open Settings button (`account.notifications.settings`), its footer and the MUTED section are unchanged.
- If the Notification choices PR (`notifs`) merged first, add this row (and its conditional Settings row) as the last row of its "During a match" list instead, with the same identifiers and copy, and drop the duplicate header.

#### Design

**A. `HealthComp/LiveActivity/MatchActivityAttributes.swift`** (new; compiled into the app and the extension; imports only ActivityKit and Foundation)
```swift
struct MatchActivityAttributes: ActivityAttributes, Hashable {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable, Hashable { case live, pending }
        var phase: Phase
        var title: String          // "Last day", "Final score pending"
        var timing: String?        // "Ends at midnight", "Ends at midnight PST"
        var opponentName: String   // refreshed every update (renames, "Former competitor")
        var userPoints: Double
        var opponentPoints: Double
        var freshness: String?     // competitionFreshnessText output
        /// A live card past its stale date reads as pending without an app run.
        func resolved(isStale: Bool) -> Self
    }
    var matchID: String            // lowercased UUID
    var endsAt: Date               // match-local midnight after Day 7
    var url: URL                   // CompetitionRoute.competition(id).url
}
enum MatchActivityCopy { static let pending = "Final score pending" }
```
- The name sits in `ContentState`, not the immutable attributes. A rename, or "Former competitor" after an account deletion, appears on the next update, and the title and score column never disagree.
- Only points, names and display strings go in, never kcal, minutes, hours or goals. The content stays local to ActivityKit; nothing goes to a server.

**B. `HealthComp/LiveActivity/MatchActivityViews.swift`** (new; both targets; imports SwiftUI only, with no WidgetKit or ActivityKit view context)
- `MatchActivityLockScreenView(attributes:state:)`. Callers pass `state.resolved(isStale:)`.
- `MatchActivityScoreColumn(side: .you | .them, state:, size:)`, `MatchActivityHeader`, `MatchActivityBottomRows`, `MatchActivityCompactScore(side:)`, `MatchActivityMinimalLead`.
- No `.activityBackgroundTint`, `.activitySystemActionForegroundColor` or `.widgetURL` here. Those are WidgetKit modifiers and live in I.
- Because the views take no `ActivityViewContext`, the DEBUG preview (H) can render them inside the app at AX5.

**C. `HealthComp/Features/Competition/CompetitionLeadText.swift`** (new; both targets)
- Move `competitionLeadText`, with its doc comment and `@MainActor`, unchanged from CompetitionDetailView.swift:1047-1066 into this file, and delete it there.
- Its 2 call sites (CompetitionDetailView.swift:178, CompetitionSharingView.swift:509) don't change. It depends only on `competitionDisplayedMargin` / `competitionPointsText` (CompetitionDateFormatting.swift, Foundation-only, unchanged), `Theme` and SwiftUI.
- It has no unit test today and gets none (it returns `Text`, which can't be inspected). The real check that the file is self-contained is the extension target building in Debug, Staging and Release.

**D. `HealthComp/Services/CompetitionLiveActivities.swift`** (new; app only; imports ActivityKit, CompetitionCore, Foundation)
- `enum CompetitionLiveActivityPreference`:
  - `storageKey = "healthcomp.liveActivity"` (same `healthcomp.` prefix as `AppAppearance.storageKey`)
  - `startedKey = "healthcomp.liveActivity.startedMatchIDs"`
  - `static func isOn(_ defaults: UserDefaults = .standard) -> Bool`, where a missing value means on
- `struct CompetitionLiveActivitySnapshot: Equatable, Sendable { let matchID: String; let state: MatchActivityAttributes.ContentState }`, covering only activities whose `activityState` is `.active` or `.stale`.
- `enum CompetitionLiveActivityStep: Equatable, Sendable`:
  - `start(MatchActivityAttributes, MatchActivityAttributes.ContentState)`
  - `update(matchID: String, MatchActivityAttributes.ContentState, staleDate: Date?)`
  - `end(matchID: String, forgetStart: Bool)`. `forgetStart` is true for ends the person didn't cause by finishing the match (disallowed, `endAll`).
- `enum CompetitionLiveActivityPlanner` (pure; this is what the unit tests exercise):
  - `static let startLead: TimeInterval = 7.5 * 60 * 60`, with the comment `// ponytail: iOS caps a Live Activity at 8 h; 7.5 h guarantees the stale (pending) look before that. Push-to-start would lift this.`
  - `static func content(_ p: CompetitionPresentation, locale: Locale = .current, timeZone: TimeZone = .current) -> MatchActivityAttributes.ContentState?`. Returns nil for any lifecycle except `.endsToday` and `.tallying`. `freshness` = `competitionFreshnessText(p, locale:timeZone:)`.
  - `static func attributes(_ p: CompetitionPresentation) -> MatchActivityAttributes?`. Nil without a schedule.
  - `static func steps(presentations:source:knownCompetitionIDs:current:started:isAllowed:now:locale:timeZone:) -> [CompetitionLiveActivityStep]`, implementing the Behavior rules in order: disallowed or fixture → end all (`forgetStart: true`); then reconcile current (absence ends only when `knownCompetitionIDs != nil`); then at most one start.
- `struct CompetitionLiveActivityClient: Sendable` (ActivityKit behind closures, the same shape as `CompetitionNotificationClient`):
  - `current: () async -> [Snapshot]`
  - `start: (attrs, state, staleDate) async -> Bool`, which is `try Activity.request(attributes:content:pushType: nil)`, with failures returning false. Do not use the iOS 18 `style:` overload.
  - `update: (matchID, state, staleDate) async`
  - `end: (matchID) async`, which is `activity.end(nil, dismissalPolicy: .immediate)`
  - `isAllowed: () -> Bool`, which is `ActivityAuthorizationInfo().areActivitiesEnabled` (PR 13 adds its switch check)
  - `startedMatchIDs: () -> Set<String>` and `setStartedMatchIDs: (Set<String>) -> Void`
  - two values: `static let live` and `static let noop`
- `actor CompetitionLiveActivities`:
  - `init(client:, now: @escaping @Sendable () -> Date = Date.init)`
  - `submit(_ publication: CompetitionPublication, knownCompetitionIDs: Set<CompetitionID>?) async` stores both as `latest` and reconciles.
  - `reconcileLatest() async` plans `latest` against `now()`.
  - `endAll() async` clears `latest`, ends every current activity, and removes their ids from the started set.
  - When a `start` returns true, its id is inserted into the started set (capped at 20, oldest dropped). `end(forgetStart: true)` removes the id.

**E. `RemoteCompetitionClient.swift`**
- `CompetitionClient.live` (:6-29): pass `liveActivities: CompetitionLiveActivities(client: .live)`.
- `CompetitionClient.remote(...)` (:31-67): new parameter `liveActivities: CompetitionLiveActivities? = nil`, forwarded to the coordinator init (:437-461) and stored as `private let liveActivities: CompetitionLiveActivities?`.
- `publish(materializations:profile:issues:knownCompetitionIDs:)`: after `await notificationCoordinator.submit(...)` (:1728-1736), add `await liveActivities?.submit(publication, knownCompetitionIDs: knownCompetitionIDs)`.
  - The failure-only overload `publish(materializations:issues:)` (:1676-1691), which publishes an empty dashboard, is deliberately **not** hooked.
- `reconcileNotifications()` (:798-803): add `await liveActivities?.reconcileLatest()` inside the gate. This is the no-network path the switch uses.
- `stop()` (:1027-1068): inside the gate, after `stopRuntime()`, add `await liveActivities?.endAll()`.
  - **Not in `stopRuntime()` (:1373).** `mount` calls `stopRuntime()` first (:493), so putting it there would end, at every launch, the card left by the previous process.

**F. `CompetitionNotificationClient.swift`** (`CompetitionRoute`, :141)
- Reuse PR 6's `CompetitionRoute.url` (PR 6 design 6a) for `MatchActivityAttributes.url`; don't build the url by hand. Only if PR 7 lands before PR 6 (the fallback), add it here exactly as PR 6 defines it, with PR 6's round-trip test.

**G. Switch wiring**
- `AccountNotificationSettings` (AccountSettingsView.swift:17-28): add `var liveActivityChanged: () -> Void = {}`.
- `AccountNotificationsPage`:
  - `@AppStorage(CompetitionLiveActivityPreference.storageKey) private var liveActivityEnabled = true`
  - `@State activitiesEnabled` plus the `.task` over `activityEnablementUpdates` (see Behavior)
  - `.onChange(of: liveActivityEnabled) { settings.liveActivityChanged() }`, and the same call when `activitiesEnabled` changes
- `HealthCompApp.swift` `AccountSheet` (:316-327): pass `liveActivityChanged: { mainStore.send(.competition(.liveActivitySettingChanged)) }`.
- `CompetitionFeature.swift`:
  - new `Action.liveActivitySettingChanged` (enum at :200-216)
  - its reducer case, next to `.sceneBecameActive` (:768): `return .run { _ in await competitionClient.reconcileNotifications() }`
  - This needs no network and no `reconcileAll`. Turning the switch on inside the window starts the card right away, because the person is in the app and the planner uses the real `now`.
- `MultiUserCompetitionTestLabView.swift` (:603) keeps the default closure.

**H. DEBUG preview scenario** (`MultiUserCompetitionTestLabView.swift`, `#if DEBUG`)
- Add `case liveActivity = "live-activity"` to `MultiUserCompetitionTestLabScenario` (:7-28), and a `case .liveActivity: LiveActivityPreviewView()` arm to the exhaustive `scenarioView` switch (:120-155). `MultiUserCompetitionTestLabLaunchParser` (:42-75) already accepts any raw value.
- `LiveActivityPreviewView`, identifier `liveActivity.preview`, shows two `MatchActivityLockScreenView`s for "Sam", 2,190 vs 2,171, freshness "You: updated 5:40 PM · Sam: updated 6:02 PM", `endsAt = .now + 5h45m`:
  - live, identifier `liveActivity.preview.live`
  - pending (`resolved(isStale: true)`), identifier `liveActivity.preview.pending`
  - Each sits in a 160 pt-tall, 16 pt-padded `Theme.ground` card. Below them is an expanded-island mock on black.
- One button, "Start Live Activity" (`SecondaryButtonStyle`, identifier `liveActivity.preview.start`), calls `CompetitionLiveActivityClient.live.start` with the same sample, so the Dynamic Island can be captured on the simulator.

**I. Widget extension** (from the Widgets PR, target `HealthCompWidgets`)
- `HealthCompWidgets/MatchLiveActivityWidget.swift` (new): `struct MatchLiveActivityWidget: Widget` with `ActivityConfiguration(for: MatchActivityAttributes.self)`.
  - Lock Screen closure: `MatchActivityLockScreenView(attributes: context.attributes, state: context.state.resolved(isStale: context.isStale)).activityBackgroundTint(Theme.ground).activitySystemActionForegroundColor(Theme.ink).widgetURL(context.attributes.url)`
  - The `DynamicIsland { … }` regions from Behavior.
  - No `#Preview`. It would need a DEBUG-only sample, and the macro also compiles in the Staging and Release device builds CI runs (ci.yml:126-145, :317-334). The in-app preview (H) covers rendering.
- `HealthCompWidgets/HealthCompWidgets.swift` (PR 6's file): add `MatchLiveActivityWidget()` to the body of `@main struct HealthCompWidgetBundle: WidgetBundle`.
- The extension does no networking, HealthKit or App Group reads for this widget. All data arrives as `ContentState`.

**J. `project.yml` and plists** (XcodeGen 2.46.0)
- `targets.HealthComp.info.properties` (after :48): add `NSSupportsLiveActivities: true`. Run `xcodegen generate` and commit the regenerated `HealthComp/Resources/Info.plist`. CI's clean-tree step fails if it drifts.
- `Configuration/Staging-Info.plist`: hand-add `<key>NSSupportsLiveActivities</key><true/>`. Staging overrides `INFOPLIST_FILE` (project.yml configs.Staging), and XcodeGen doesn't write this file.
- `targets.HealthCompWidgets.sources`: add these if the Widgets PR didn't already list them:
  - `- path: HealthComp/LiveActivity`
  - `- path: HealthComp/Features/Competition/CompetitionLeadText.swift`
  - `- path: HealthComp/Features/Competition/CompetitionDateFormatting.swift`
  - `- path: HealthComp/App/Theme.swift`
  - The app target already includes them through `- path: HealthComp`, and XcodeGen allows one file in two targets.
- No new packages. The extension links neither CompetitionCore, TCA nor Supabase, so none of the shared files may import them.
- **Fallback if this PR lands before Widgets**: create the target exactly as the Widgets spec defines it:
  - `HealthCompWidgets`, `type: app-extension`, `platform: iOS`
  - `info.properties.NSExtension.NSExtensionPointIdentifier: com.apple.widgetkit-extension`
  - bundle IDs `com.narenyenuganti.HealthComp.widgets` / Staging `com.narenyenuganti.HealthComp.staging.widgets`
  - `SWIFT_VERSION: "5.9"`, `TARGETED_DEVICE_FAMILY: "1"`
  - add the app dependency `- target: HealthCompWidgets`, and create `HealthCompWidgets/HealthCompWidgets.swift` with `@main struct HealthCompWidgetBundle: WidgetBundle` whose body holds only `MatchLiveActivityWidget()`
- Then regenerate on the Mac mini (`~/tools/xcodegen/bin/xcodegen generate`) and commit `project.pbxproj`. CI's determinism check must pass.
- `PrivacyInfo.xcprivacy`: no change. The new UserDefaults reads are covered by `CA92.1`, and ActivityKit is not a required-reason API.

#### Server changes
None. There is no RPC, migration, Edge Function or push. Installed older builds are unaffected, and there is nothing to promote to Staging.

#### Tests

**HealthCompTests/CompetitionLiveActivityTests.swift** (new; `CompetitionLiveActivityPlanner` only, no ActivityKit)
- **Fixture**: a remote presentation named "Sam".
  - Schedule: `America/Los_Angeles`, Day 1 = 2026-11-01, so Day 7 = Sat Nov 7 and `endsAt` = 2026-11-08T08:00Z.
  - Points 2190.4 / 2171.2.
  - `lastSuccessfulFullWindowRefreshAt` 01:40Z, `opponentUpdatedAt` 02:02Z, `evaluatedAt` 02:05Z.
  - Locale en_US, phone zone LA.
  - `knownCompetitionIDs` = {id} unless stated.
- `testStartsOnlyInTheLastSevenAndAHalfHoursOfDay7`:
  - `.endsToday` with now 2026-11-08T00:29Z → no step
  - now 00:30Z → `.start`, with `endsAt` 08:00Z and url `healthcomp://competition/<id>`
  - now 07:59Z → `.start`
  - now 08:00Z, lifecycle still `.endsToday` (stored publication) → no step
  - `.active(dayOrdinal: 6)` → no step
- `testLiveContentUsesSharedWords`: title "Last day", timing "Ends at midnight", opponentName "Sam", freshness "You: updated 5:40 PM · Sam: updated 6:02 PM".
  - With phone zone `America/New_York`, the timing is "Ends at midnight PST".
  - With `opponentUpdatedAt` nil → freshness "Updated 5:40 PM". With `lastSuccessfulFullWindowRefreshAt` nil → "Sam: updated 6:02 PM". Both nil → nil.
- `testNeverStartsTwiceOrForAStartedMatch`:
  - started set contains the id → no step
  - a current activity for match A plus a qualifying match B → only A's update or nothing, no `.start`
- `testPicksTheMatchEndingSoonest`: two qualifying matches (LA and New York calendars) → starts the New York one. Equal ends → the lower lowercased id.
- `testUpdatesOnlyWhenContentChanges`:
  - current state equal to the computed one → []
  - points change → `.update(staleDate: endsAt)`
  - `opponentDisplayName` changes to "Former competitor" → `.update` whose state has `opponentName == "Former competitor"`
- `testTallyingBecomesFinalScorePending`: `.tallying` → `.update` with phase `.pending`, title "Final score pending", timing nil, staleDate nil.
- `testStaleLiveContentResolvesToPending`: `state.resolved(isStale: true)` → phase `.pending`, title `MatchActivityCopy.pending`, timing nil. Assert `MatchActivityCopy.pending == competitionStatusText(.tallying(startedAt: .distantPast), schedule: nil, opponentDisplayName: "Sam", style: .card).title`.
- `testFinishedOrDisallowedEndsImmediately`:
  - `.completed(.win)` → `.end(forgetStart: false)`
  - `isAllowed: false` → `.end(forgetStart: true)`
  - `source: .simulatedFixture` → `.end(forgetStart: true)`
  - a `.cancelled` lifecycle → `.end(forgetStart: false)`
- `testMissingMatchEndsOnlyWhenListIsAuthoritative`:
  - current activity for A, presentations [], `knownCompetitionIDs: []` → `.end`
  - same with `knownCompetitionIDs: nil` → []
- `testExtraActivitiesAreEnded`: two current snapshots → the second gets `.end`.

**HealthCompTests/RemoteCompetitionClientTests.swift**
- New `testPublishSubmitsToLiveActivitiesAndStopEndsThem`:
  - Copy the setup of `testStopCancelsPriorNotificationAfterTransientReconciliationFailure` (:3756).
  - Pass `liveActivities: CompetitionLiveActivities(client: probe)`. The probe records `current`, `start`, `end` and `setStartedMatchIDs` calls, returns one snapshot for an unrelated id, has `isAllowed: { true }`, and starts with that id in its started set.
  - After mount, assert the probe saw at least one `current` call (publish reached the actor).
  - Record `let before = probe.ends.count`, call `client.stop()`, and assert the delta is exactly 1, for that snapshot's id. Publish may already have ended it (the pending-only fixture is authoritative), so only the delta proves the `stop()` hook.
  - Assert the started set no longer contains the id.
- New `testRemountDoesNotEndLiveActivities`: mount, record the end count, mount the same profile again → no new `end`.

**HealthCompTests/CompetitionFeatureTests.swift**
- New `testLiveActivitySettingChangeReconcilesWithoutNetwork`: a `TestStore` with `reconcileNotifications` recording a call and `reconcileAll` set to `XCTFail`. Send `.liveActivitySettingChanged` → the call is recorded and the state is unchanged.

**HealthCompTests/CompetitionRoutingTests.swift**
- `testCompetitionRouteURLRoundTrips` is PR 6's (it moves here only in the PR-6-slips fallback).

**HealthCompUITests/MultiUserCompetitionUITests.swift**
- Add `case liveActivity = "live-activity"` to the test file's private `enum Scenario` (:1333-1348).
- `testNotificationsPageOpensSettingsAndUnmutes` (:915; already in ci.yml's `-only-testing` list), after :923:
  - `let live = app.switches["account.notifications.live-activity"]`
  - `XCTAssertTrue(live.exists)`
  - `XCTAssertTrue(app.staticTexts["DURING A MATCH"].exists)`
  - `XCTAssertTrue(text("Shows the score on the Lock Screen in the last hours of a match.").exists)`, with the comment `// Assumes the simulator default: Live Activities on for HealthComp.`
  - The existing audit then covers the new row (`.hitRegion`, `.textClipped`). Don't toggle it, or the test would depend on the simulator's defaults.
- New `testLiveActivityPreviewFitsAtAccessibilitySizes` (full suite on the Mac mini; not added to ci.yml):
  - `launch(.liveActivity, appearanceArguments: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])` (the same argument LocalCompetitionLifecycleUITests.swift:394-395 uses)
  - wait for `liveActivity.preview`
  - `performAccessibilityAudit(for: .textClipped.union(.sufficientElementDescription))`
  - `element("liveActivity.preview.live").label` contains "You lead by 19.", and `element("liveActivity.preview.pending").label` contains "Not final yet." (each card is one combined element, so assert on its label, not on separate staticTexts)

**Accessibility identifiers**
- Added (no `account.*` ids; PR 13 owns the Account row): DEBUG only `liveActivity.preview`, `liveActivity.preview.live`, `liveActivity.preview.pending`, `liveActivity.preview.start`.
- Renamed / removed / moved: none.
- Unchanged: `account.notifications`, `account.notifications.settings`, `account.notifications.unmute`, `competition.notifications.enable`.

#### Verify on the Mac mini (in addition to the shared §8 steps)
1. Copy and generate: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/live && tar -x -C ~/dev-desktop/live'`, then `~/tools/xcodegen/bin/xcodegen generate`. `git diff --exit-code -- HealthComp.xcodeproj HealthComp/Resources/Info.plist` must be empty.
2. Unit tests: `~/dev-desktop/ua/ua-mac6.sh unit` (HealthCompTests, including the new file). Also run `bash scripts/test-competition-local-date-formatting.sh`: CompetitionDateFormatting.swift is unchanged but now compiles in a second target.
3. Device builds as in CI: Debug, Staging and Release for `generic/platform=iOS` with `-xcconfig Configuration/CI.xcconfig`. The extension must compile in all three. Then `plutil -extract NSSupportsLiveActivities raw <app>/Info.plist` returns `true` for **both** the Debug and Staging products, and `bash scripts/verify-app-privacy-manifest.sh --app-bundle <app>` passes.
4. UI: run both suites (`ua-mac6.sh ui`), plus the new preview test at AX5.
5. Captures in light and dark, at XS and AX5:
   - the in-app preview (`--multi-user-competition-scenario live-activity`)
   - Account → Notifications, including the Live Activities-off state (turn it off in the simulator's Settings → HealthComp, return, and check that the page updates with no relaunch)
6. Real Live Activity: on the "HealthComp dev-desktop" iPhone 16 Pro iOS 18.5 sim, tap "Start Live Activity", then press Home through a local-only UI test (`XCUIDevice.shared.press(.home)`) and take `xcrun simctl io <sim> screenshot` captures of the compact island and of the expanded island after a long press. Lock the screen with the local-only private `pressLockButton` selector (never committed) and capture the Lock Screen card. Check VoiceOver on the compact regions (Accessibility Inspector). Also capture the iOS 26.5 sim.
7. Stale check: in the same local-only test, start a sample with `endsAt = .now + 60s`, wait 70 s, and capture. The header must read "FINAL SCORE PENDING · SAM" with no app run. Then end that activity from the test with `end(nil, .default)` and capture again, to see whether an ended card keeps the stale look. Note the result in the PR; see Risks.
8. Staging smoke test (optional, a real Day 7 match between the two Staging accounts): open the app after 4:30 PM match time → the card appears. Background the app and let a HealthKit wake or realtime update arrive → the score changes and the freshness line moves. After midnight the card reads pending. Turning the switch off ends it.

#### Risks and conflict regions
- **Depends on the Widgets PR** for the extension target, its bundle file, and possibly the same shared-source entries in `project.yml` (`Theme.swift`, `CompetitionDateFormatting.swift`). Whichever PR merges second dedupes the `sources` list and regenerates `project.pbxproj`. The Widgets PR owns the App IDs and signing.
- **Notification choices PR (`notifs`)**: both PRs edit `AccountNotificationsPage` and possibly `CompetitionFeature`'s action enum. The second to merge moves the "Live Activity" row into the "During a match" list and keeps both identifiers. The playbook proposes a `CompetitionNotificationPreferences` per-family store. The Live Activity switch stays a device-level UserDefaults key, because the coordinator is process-wide and has to read it without a profile mount.
- **`RemoteCompetitionClient.swift`** (publish :1693-1738, stop :1027-1068, `remote(...)` :31-67) is a hot file. Re-anchor by symbol.
- **`competitionLeadText` move** (CompetitionDetailView.swift:1047-1066): any concurrent PR editing it must edit the new file instead.
- **iOS limits are real and stated plainly**:
  - an 8 h cap; the card only starts with the app open
  - nothing brings people into the app after 4:30 PM, so many matches won't get a card (Q-live-1)
  - an app left open across 4:30 PM starts the card on its next refresh, not on the minute
  - the other person's side updates only when this app refreshes, and the freshness line shows how old each side is
  - Push updates are a later, server-side step.
- **Ended-card rendering**: Apple doesn't document whether a card iOS has ended keeps re-rendering against `staleDate`. The 7.5 h start window ensures it is already stale (pending) before iOS ends it. Step 7 checks what an ended card shows.
- **Lock Screen privacy**: the card shows the other person's name and both point totals to anyone holding the phone. Notification previews follow Settings → Notifications → Show Previews, but Live Activities don't. Exposure is controlled by iOS's Face ID & Passcode → Allow Access When Locked → Live Activities, and by the new in-app switch. No Health values are shown.
- **CI simulator**: unit tests never use the `.live` ActivityKit client. The test host's live composition only reaches ActivityKit with a signed-in Day 7 remote match, which CI never has.
- **No migrations.**

#### Rollout / compatibility
- App-only. It ships in the next TestFlight build with the Widgets extension. There is no server dependency, so there is no Staging → production step.
- Older installed builds are unaffected.
- On first run the switch defaults to on, and nothing starts until a real match reaches the last 7.5 hours of Day 7.

#### Review notes
Applied, after checking each against the code:
- 8 h cap: the window is now 7.5 h, the `final` phase and result card are gone, ended activities are ignored, and Q-live-1/Q-live-2 are rewritten.
- Missing-match ends now need an authoritative `knownCompetitionIDs` (two reviews raised this; merged into one change).
- The stop test now asserts on the delta.
- `endAll` forgets the ids it ends, covering a failed mount and sign-out.
- The planner uses the real `now`.
- WidgetKit modifiers moved into the widget file, and the G→H reference is fixed.
- `competitionLeadText` has 2 call sites and no tests; the false compile-only claim is removed.
- Enablement is observed through `activityEnablementUpdates`, with an Open Settings row (`openSettingsURLString`).
- The UI-test scenario wiring is listed.
- `opponentName` moved into `ContentState`.
- The per-side freshness string replaces "the older of the two".
- The divider is kept.
- `keylineTint` is removed.
- Compact VoiceOver labels are added.
- The preview cards get identifiers for label assertions.
- The footer copy is now "in the last hours".
- The privacy wording is corrected.
- Q-live-3's reasoning is restated.
- Self-found: the draft's pending timing "By Sun night" was wrong. The formatter's `.tallying` timing is nil (CompetitionSharingView.swift:1440).

Rejected or partly applied:
- `#Preview`: dropped instead of wrapped in `#if DEBUG`, because H already covers rendering.
- Window start as a boundary republish: not added. The limit is stated instead, because a foreground app gets realtime and HealthKit refreshes anyway.
- `.privacySensitive()`: not added. iOS's Allow Access When Locked → Live Activities switch is the documented control.
- A unit test for the moved `competitionLeadText`: not added, because `Text` can't be inspected. The extension's device builds are the check.

#### Owner actions for this feature (merged into §7)
- None if the Widgets PR has already shipped the HealthCompWidgets extension. Live Activities need no new entitlement, App Group, capability or push certificate. If this PR lands first, the owner must register the extension App IDs com.narenyenuganti.HealthComp.widgets and com.narenyenuganti.HealthComp.staging.widgets before the first TestFlight upload (see the Widgets spec).
- Approve the preview artifact before the PR opens: Mac mini captures of the in-app preview, plus Lock Screen and Dynamic Island screenshots from the simulator.
- Answer Q-live-1 to Q-live-3. The defaults are what gets built.

### 9.7 PR 8: Block a challenger

Branches: `feature/block-challenger` · Server: yes · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **Migration order:** second server PR, after PR 4. Name `20261102002600_add_account_blocks.sql`, count 27 → 28, pgTAP `024`. It is the first private table this round, so the state baseline moves 19 → 20 tables, `rls_flag_mismatches` 18 → 19, FORCE 7 → 8 exactly as written; PR 9 moves them again.
- **Fixture id** `incomingID = …000B` (§4).
- **Reactions (PR 9/10)** don't consult blocks: block stops challenges only, and mute covers a live match. Claude's call (§4).
- **Account.** The BLOCKED section is on the Account root, not on PR 13's Notifications page, so the two don't conflict there.

#### PR scope
- `feature/block-challenger`: One PR, like #195. One forward migration: the account_blocks table; the block_challenger, unblock_profile and list_blocked_profiles RPCs; a block check in private.create_competition_invite_v2 (after the pair checks), resolve_challenge_link and resolve_invitation_recipient; and a purge trigger on deactivation. Migration `20261102002600_add_account_blocks.sql`. Also recovery-harness pins, pgTAP `024_account_blocks.test.sql` and a Deno race test. App: 'Decline and Block {Name}' in the remote incoming decline dialog and in the /invite/ claim-sheet decline dialog, a ••• Block item on the incoming challenge screen, and an inline Account BLOCKED section with Unblock. Plus one sentence in web/privacy.html, a Test Lab scenario and UI tests. The server goes to Staging, then production, before any TestFlight build.

#### Intent
Anyone who has your challenge link or account id can challenge you again after every decline, with a push each time (`20261101001900` create path; audit §10 Q6). Reset Link (#195) stops everyone. Blocking stops one person. The owner approved it this round, so audit Q6's "build none" default is overridden for this one control.

Audit §10 Q5's default holds in this form: the blocked person is **never notified**. Every refusal they hit is the same collapsed error that a reset link or a gone account already produces. Inference stays possible in a few listed cases (Q-block-1, Q-block-2, accepted limits below), so the UI never says "they aren't told they're blocked". It says "They aren’t notified."

#### Scope
- **Server**: one forward migration. It adds:
  - `private.account_blocks`
  - three RPCs: `block_challenger`, `unblock_profile`, `list_blocked_profiles`
  - a block check in the single shared create, `private.create_competition_invite_v2`, which serves by-id, rematch and `/c/` link creates. The check runs **after** the pair checks.
  - a block check in both lookups: `resolve_challenge_link` and `resolve_invitation_recipient`
  - a purge trigger on account deactivation
- **No Edge Function changes.** `create-competition-invite/index.ts:200-205` already maps `recipient_unavailable` to 404 for every app version.
- **App, blocker side**:
  - "Decline and Block {Name}" in the remote incoming decline dialog and in the `/invite/` claim-sheet decline dialog. The mockup's rule is "Decline offers a second choice".
  - "Block {Name}" in a new ••• menu on the remote incoming challenge screen.
  - An inline Account **BLOCKED** section with Unblock.
- **App, blocked side**: no new UI. They see the existing collapsed copy (§4).
- **Web**: one privacy sentence (Q-block-4 default).
- **Not in scope**:
  - Block on live, scheduled or finished matches. Mute covers those (mockup "Live matches").
  - A Report action (Q-block-3).
  - Changing the Account challenge-link caption.
  - Refactoring `mutedRow`. The blocked row is its own small function.
- **Stakes: none anywhere.**
- **No new Swift files and no new targets.** `project.yml` and `project.pbxproj` don't change. The new files are SQL, pgTAP and Deno only, outside every Xcode target.

#### Behavior

##### 1. Decline dialog on a remote incoming challenge (`CompetitionInviteView`)
Today the remote and fixture declines share one `.alert` (`CompetitionInviteView.swift:58-72`). After this PR:
- **Remote incoming** uses `.confirmationDialog`. That matches the mockup's bottom sheet and the claim sheet's existing decline dialog (`ClaimCompetitionView.swift:93-102`).
  - Title (wording unchanged, `titleVisibility: .visible`): **"Decline challenge from {Name}?"**. This keeps audit PR 1's wording over the mockup's "Decline Alex's challenge?".
  - Buttons, in order:
    - **"Decline Challenge"** (destructive) → `.declineTapped(id)`
    - **"Decline and Block {Name}"** (destructive) → `.blockTapped(id)`
    - **"Keep Challenge"** (cancel)
  - Message: **"{Name} will see a decline either way. If you block them, they can’t challenge you again."** It names the person once. It is true for both buttons, and it states the privacy promise without overclaiming it.
- **Simulated fixture**: keeps today's `.alert`, title, buttons and message ("This closes the challenge without starting a match.") exactly. `LocalCompetitionLifecycleUITests:239` asserts `app.alerts["Decline challenge from Alex?"]`. The fixture has no server, so it offers no block.
- On success the server declines the challenge. It leaves the dashboard (`list_challenges` never lists a declined incoming challenge), the path is pruned (`MainTabFeature.swift:390`/`:736`), and Home shows nothing for it. That is the same end state as Decline.
- On failure the existing inline line shows: "Couldn’t complete that. Check your connection and try again." (`competition.invite.error`, `:169-171`). It is driven by `.commandRejected(id)`.

##### 2. Decline dialog in the `/invite/` claim sheet (`ClaimCompetitionView`)
- The existing `.confirmationDialog` (`:93-102`) adds **"Decline and Block {Name}"** (destructive) between "Decline Challenge" and "Keep Challenge". It shows only when the new optional `block` closure is non-nil.
- The message becomes the same line as §1: "{Name} will see a decline either way. If you block them, they can’t challenge you again." No UI test asserts the old claim message. `testDeclineBeforeHealthDeclinesOnTheServerAndKeepsHealthStep` taps only "Decline Challenge".
- The inline caption "{Name} is told if you decline." (`:240`) and the failure line "Couldn’t decline. Check your connection and try again." are unchanged. A failed block reuses that failure line.
- The claim preview is addressed to the caller (recipient-bound), and `decline_competition_challenge` already works from here (`MainTabFeature.swift:543-560`). So `block_challenger` accepts the same id.

##### 3. ••• menu on a remote incoming challenge
- `ToolbarItem(placement: .topBarTrailing)` → `Menu`, labelled with the existing `CompetitionMoreLabel()` (`CompetitionDetailView.swift:444`, VoiceOver "More"). Its id is `competition.more`, the same id as the match screen's menu.
- It appears only when `source == .remoteParticipants && direction == .incoming`. It is absent on outgoing challenges and in the fixture.
- It has one item: `Button(role: .destructive) { showsBlockConfirmation = true } label: { Label("Block \(name)", systemImage: "hand.raised") }`, with id `competition.invite.block` and `.disabled(isCommandInFlight)`.
- Confirmation: `.confirmationDialog("Block \(name)?", titleVisibility: .visible)`.
  - Buttons: **"Block {Name}"** (destructive, id `competition.invite.block.confirm`) → `.blockTapped(id)`, and **"Cancel"** (cancel).
  - Message: **"This declines the challenge. {Name} will see a decline and can’t challenge you again."**
- Success and failure work as in §1.

##### 4. Account → BLOCKED (inline, Q-block-5)
- A new section directly under YOUR CHALLENGE LINK (`AccountSettingsView.swift:118-122`). It is only for real accounts: the same `publication?.source == .remoteParticipants` gate as the link (`HealthCompApp.swift:340`).
- **It shows only when the loaded list is non-empty** (`blocked.people?.isEmpty == false`). It stays hidden while loading, when the list is empty, and when the first load fails. Nearly no one has blocks, so an offline Account never shows a blocked-list error. A failed refresh keeps the list already shown. The list reloads on the next appear.
- Header: `SectionLabel("BLOCKED")`.
- Rows: `ForEach(people, id: \.id)`. `AuthenticatedProfile` (`AuthenticationClient.swift:20`) is not `Identifiable`, and this PR doesn't add the conformance to a shared auth type.
  - Newest block first.
  - Initial circle and name, then **"Unblock"** (borderless, 44 pt, disabled while that id is in flight).
  - VoiceOver label **"Unblock {Name}"**, id `account.blocked.unblock`.
  - At accessibility sizes the row stacks vertically. It uses the same `AnyLayout` pattern as `mutedRow` (`:597-622`) but is written as its own `blockedRow`, and `mutedRow` isn't touched.
- Footer: **"Blocked people can’t challenge you. They aren’t notified."**
- Unblock has no confirmation. It is low risk, and Unmute works the same way.
  - On success the row disappears, and the section disappears with the last row.
  - On failure the row stays, and the section shows "Couldn’t unblock. Check your connection and try again." (id `account.blocked.error`). The error clears on the next unblock tap and the next time Account appears.

##### 5. What the blocked person sees
| They try | Server answer | Copy they see (existing) |
|---|---|---|
| Their pending challenge when the block happens | Declined exactly like Decline: `lifecycle='declined'`, `closed_by` = blocker, the same generic "Challenge declined" push (audit §10 Q3 default) | audit PR 4/PR 7's closed row "declined" with Challenge {Name} Again |
| Open the blocker's `/c/` link | `resolve_challenge_link` → `recipient_unavailable` | "Link not found" / "This challenge link isn’t active. Ask for a new one." (`CreateCompetitionView.swift:535`). Same as a reset link |
| Paste the link or code in the + sheet | same | "No account has this link. Check it and try again." |
| Challenge {Name} Again (by id) | `create_competition_invite` → 404 `recipient_unavailable` | sheet `.notFound`: same line as above. This is already the reset-link behavior (`RemoteCompetitionFeatureTests.testChallengeAgainRefusedAfterALinkResetShowsTheCollapsedCopy`) |
| Rematch from an old result | same | `.failed(.recipientGone)`. Copy is Q-block-1 (default "You can’t challenge {Name}."). Older builds: "{Name} isn’t on HealthComp anymore." |
| 1.0.2 by account code | same | 1.0.2's existing unavailable message |
| Create while the blocker's own challenge to them is pending, or while a match between them is in progress | `incoming_challenge_exists` / `active_match_exists` (pair checks run first) | existing conflict copy, the same as for anyone |
| A create that succeeded before the block, retried with the same idempotency key | the idempotent replay returns the existing id (now declined), unchanged | nothing new |

**Mockup conflict:** the mockup says the blocked person sees "Challenge unavailable". That string is the *recipient's* claim-sheet copy (`ClaimCompetitionView.swift:321`), and senders never see it. The closest correct behavior is the sender-side collapsed copy above, which is identical to a reset link and a deleted account.

##### 6. Rules and edge cases
- **Blocking needs a challenge from that person addressed to you**, in any lifecycle. That keeps the recipient-bound contract: there is no way to block, or probe, an arbitrary account id.
- **It declines every pending, unexpired challenge from them to you.** There is at most one, by the pair rule. If a challenge expired while the screen was open, the block still happens and nothing is declined.
- **Order in the create**: recipient active, reset link, rematch validity, pending, overlap, reciprocal, **then the block**, then insert. The pair checks only describe states both people can already see. So the blocked person gets `recipient_unavailable` only when the create would otherwise have succeeded. The block also applies to rematches, unlike the reset-link rule (2400:216).
- **One-way** (Q-block-2). The blocker can still challenge the blocked person, and the block stays. Accepting a challenge is never blocked.
- **Matches can't overlap a block decision.** Live and tallying matches can't coexist with a pending challenge from the same person: `match_in_progress_between` includes tallying (1900:60), and the create refuses with `active_match_exists`. So blocking never touches a match. Finished matches, History, scores, awards and mutes are untouched.
- **Deletion**: if either account starts deletion, its blocks are deleted (trigger). A recreated account isn't blocked. This is the same accepted limit as Reset Link.
- **Two devices**: the decline broadcasts like any decline (`broadcast_competition_change`), so the row leaves the other iPhone too.
- **Accepted limits** (contract doc):
  - A pair who plays again can infer the block: the blocker challenged, they played, and the blocked person's rematch is refused.
  - So can a refused rematch of an old result, under any copy.
  - A fresh link from the blocker also fails for the blocked person, even though "Ask for a new one." invites that probe. After a plain reset, a new link works.
  - A recreated account isn't blocked.
  - An idempotent replay returns its now-declined id.
  - The Account list shows the newest 200 blocks. Older blocks stay in force with no Unblock control, and support can't remove them. A block needs a real challenge, so this is not expected to happen in practice.
- **Dynamic Type to AX5**:
  - The dialogs and the menu are system controls.
  - The Account row stacks vertically.
  - The decline and block controls are the existing 44 pt buttons.

##### Copy (all new or changed strings)
- "Decline and Block {Name}"
- "{Name} will see a decline either way. If you block them, they can’t challenge you again." (replaces "{Name} will see that you declined." in both remote decline dialogs)
- "Block {Name}" / "Block {Name}?" / "This declines the challenge. {Name} will see a decline and can’t challenge you again." / "Cancel"
- "BLOCKED" / "Unblock" / VoiceOver "Unblock {Name}" / "Blocked people can’t challenge you. They aren’t notified."
- "Couldn’t unblock. Check your connection and try again."
- (Q-block-1 default) "You can’t challenge {Name}." replaces "{Name} isn’t on HealthComp anymore."
- (Q-block-4 default, web) "You can block someone from a challenge they sent you. Blocks are stored with your account, aren’t shown to the blocked person, and are removed when either account is deleted."

Glossary additions to §5:
- **Block** / **Unblock**: verbs, used only for challengers.
- **Blocked**: the Account section.
- Don't say: ban, report, restrict, or "aren't told they're blocked".

#### Design

##### Wire and API layer
- **`HealthComp/Services/CompetitionRemoteAPI.swift:89-121`**: add three closures. Each defaults to `throw CompetitionRemoteFailure.operationFailed`, like `declineChallenge`.
  - `blockChallenger: @Sendable (UUID) async throws -> Void`. Takes the competition id.
  - `listBlockedProfiles: @Sendable () async throws -> [AuthenticatedProfile]`
  - `unblockProfile: @Sendable (UUID) async throws -> Void`. Takes the profile id.
  - There is no new `CompetitionRemoteFailure` case. `classify` (`SupabaseCompetitionRemoteAPI.swift:505-640`) already maps `invite_unavailable` to `.inviteUnavailable` and a missing function (404) to `.notFound`.
- **`HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`**, inside `make` (after `:349`):
  - `blockChallenger: { id in try await sendCompetitionCommand("block_challenger", id, transport) }`. It reuses `:392-411`: the same `{competition_id}` body and echo check.
  - `listBlockedProfiles`: `sendReadOnly(.rpc(name: "list_blocked_profiles", parameters: encode(EmptyParameters())))` → a new private `decodeBlockedProfiles(_:)`.
    - It requires exactly the top-level keys `["blocked"]` and an array of at most 200 rows. Otherwise it throws `.serverContractMismatch`.
    - Each row goes through the existing `challengeProfile(_, idKey: "id", nameKey: "display_name")` (`:744-761`).
    - An unreadable row is skipped, as in `decodeChallengeList` (`:698`).
  - `unblockProfile: { id in validateUUID(id); send(.rpc(name: "unblock_profile", parameters: encode(["profile_id": id.uuidString.lowercased()]))) }`. The response must be exactly `{"profile_id": <same lowercased id>}` (checked with `wireUUID`). Otherwise it throws `.serverContractMismatch`.

##### Client (`CompetitionClient.swift`, `RemoteCompetitionClient.swift`)
- **`CompetitionClient.swift:48-100`** adds three properties. Their init params and defaults go next to `cancel` (`:162-164`).
  - `block: @Sendable (CompetitionID) async -> CompetitionPublication`, default `{ _ in .inert }`. Doc comment: "Declines the pending challenge and blocks its sender."
  - `loadBlockedProfiles: @Sendable () async throws -> [AuthenticatedProfile]`, default throws `.operationFailed`.
  - `unblock: @Sendable (UUID) async throws -> Void`, default throws `.operationFailed`.
  - The local fixture keeps the defaults, so no test doubles change.
- **`RemoteCompetitionClient.swift`**, live wiring (`:81-85` and `:135-150`):
  - `block: { id in await coordinator.respond(id) { try await $0.blockChallenger($1) } }`. It uses the existing `respond` (`:884-913`) without `inviteUnavailableIsDone`. A refusal is a real failure, so it marks `.commandRejected(id)`.
  - `loadBlockedProfiles: { try await coordinator.remote { try await $0.listBlockedProfiles() } }`
  - `unblock: { id in try await coordinator.remote { try await $0.unblockProfile(id) } }`

##### Reducer (`CompetitionFeature.swift`)
- State, after `challengeLinkResetFailed` (`:128`):
  ```swift
  /// People you blocked, newest first; nil until Account loads them.
  var blockedPeople: [AuthenticatedProfile]?
  var unblocksInFlight: Set<UUID> = []
  var unblockFailed = false
  ```
- Actions, next to `declineTapped` (`:195`): `blockTapped(CompetitionID)`, `blockedPeopleRequested`, `blockedPeopleResponse([AuthenticatedProfile]?)`, `unblockTapped(UUID)`, `unblockFinished(UUID, succeeded: Bool)`.
- `CancelID` (`:226-233`) adds `.blockedPeople`.
- `blockTapped`: copies `declineTapped` (`:556-568`), calling `competitionClient.block(id)` → `.commandFinished(id, expectedRevision:)`.
- `blockedPeopleRequested`: sets `unblockFailed = false`, then runs `.run { send(.blockedPeopleResponse(try? await competitionClient.loadBlockedProfiles())) }` with `.cancellable(id: .blockedPeople, cancelInFlight: true)`.
- `blockedPeopleResponse(people)`: `if let people { state.blockedPeople = people }`. A failure keeps whatever was shown, and there is no failure flag.
- `unblockTapped(id)`:
  - `guard state.unblocksInFlight.insert(id).inserted`
  - `unblockFailed = false`
  - `.run { send(.unblockFinished(id, succeeded: (try? await competitionClient.unblock(id)) != nil)) }`. Not cancellable, so the server call finishes.
- `unblockFinished(id, succeeded)`:
  - `guard state.unblocksInFlight.remove(id) != nil else { return .none }`. `stop` clears the set, so a result that arrives after a sign-out or profile switch is dropped and never marks the next account.
  - On success, `blockedPeople?.removeAll { $0.id == id }`. Otherwise, `unblockFailed = true`.
- `stop` (`:783-803`) resets the three fields and cancels `.blockedPeople`.
- No change to `sceneBecameActive`: Account reloads when it appears.

##### Reducer (`MainTabFeature.swift`, claim sheet)
- Add `case blockClaimConfirmed` next to `declineClaimConfirmed` (`:166`).
- Move the body of `.declineClaimConfirmed` (`:543-560`) into `private func declineClaim(_ state: inout State, block: Bool) -> Effect<Action>`. It calls `block ? competitionClient.block(id) : competitionClient.decline(id)`. Both cases call it, and both finish through the existing `.declineClaimFinished(sequence:succeeded:)`.
- `MainTabView.swift:47-58` passes `block: { store.send(.blockClaimConfirmed) }`.

##### Views
- **`CompetitionInviteView.swift`**:
  - Add `@State private var showsBlockConfirmation = false`.
  - Replace the single `.alert` (`:58-72`) with:
    - the fixture `.alert`, unchanged, bound to `showsDeclineConfirmation && source != .remoteParticipants`
    - the remote `.confirmationDialog` (§1), bound to `showsDeclineConfirmation && source == .remoteParticipants`
    - both through one private `func declineBinding(remote: Bool) -> Binding<Bool>`
  - Add the toolbar menu and the Block `.confirmationDialog` (§3) after `.navigationBarTitleDisplayMode` (`:57`).
  - The Decline button (`:213-231`) and its id `competition.invite.decline` are unchanged.
  - Dialog button ids: `competition.invite.decline.confirm`, `competition.invite.decline-block`, `competition.invite.block.confirm`.
- **`ClaimCompetitionView.swift`**:
  - Add `var block: (() -> Void)? = nil` after `decline` (`:14`). It is optional with a default, so the lab call site (`MultiUserCompetitionTestLabView.swift:423`) compiles unchanged.
  - In the dialog, add `if let block { Button("Decline and Block \(senderName)", role: .destructive, action: block).accessibilityIdentifier("competition.claim.decline-block") }`.
  - Change the message (§2).
- **`AccountSettingsView.swift`**:
  - Add a type next to `AccountChallengeLink` (`:5-13`):
    ```swift
    /// The people you blocked, for Account. Hidden until a non-empty list loads.
    struct AccountBlockedPeople {
        let people: [AuthenticatedProfile]?
        let unblocking: Set<UUID>
        let unblockFailed: Bool
        let load: () -> Void
        let unblock: (UUID) -> Void
    }
    ```
  - Add `var blockedPeople: AccountBlockedPeople?` after `challengeLink` (`:103`).
  - In `body` (`:117-125`), after `challengeLinkSection`: `if let blocked = blockedPeople, let people = blocked.people, !people.isEmpty { blockedSection(blocked, people) }`.
  - In `.task` (`:127-130`), add `blockedPeople?.load()`.
  - `blockedSection`: `Section { ForEach(people, id: \.id) { blockedRow($0, blocked) }; if blocked.unblockFailed { error Text } } header: { SectionLabel("BLOCKED") } footer: { … }` with `.listRowBackground(Theme.panel)`.
  - `blockedRow` copies the `mutedRow` layout: an `AnyLayout` switch on `dynamicTypeSize.isAccessibilitySize`, the initial circle in `Theme.control`, and its own `@ScaledMetric(relativeTo: .headline) private var blockedInitialSize: CGFloat = 34`. `AccountNotificationsPage` is untouched.
- **`HealthCompApp.swift`, `AccountSheet.accountSettings` (`:312-367`)**: build `AccountBlockedPeople(people: competition.blockedPeople, unblocking: competition.unblocksInFlight, unblockFailed: competition.unblockFailed, load: { mainStore.send(.competition(.blockedPeopleRequested)) }, unblock: { mainStore.send(.competition(.unblockTapped($0))) })` under the same remote gate as `challengeLink`. Pass it to both the Staging and the non-Staging `AccountSettingsView` inits.
- **`CreateCompetitionView.swift:445-446`** (Q-block-1 default): `.recipientGone` → `"You can’t challenge \(opponentName)."`.

##### DEBUG Test Lab (`MultiUserCompetitionTestLabView.swift`)
- New scenario `case incomingChallenge = "incoming-challenge"` (enum `:8-30`). Add it to `scenarioView` (`:120-153`) and to the claim `initialStatus` switch (`:405-412`, `.ready` group).
- New `private struct MultiUserCompetitionIncomingChallengeTestLabView`:
  - `NavigationStack { CompetitionInviteView(competition: Fixtures.incomingChallenge, source: .remoteParticipants, isCommandInFlight: false, link: nil, send: …) }`
  - `.declineTapped` shows the outcome "Declined", and `.blockTapped` shows "Declined and blocked". The outcome is a `Text` with id `multiuser.incoming.outcome`. Lab copy is exempt from the copy rules.
- The claim lab (`:423`) passes `block: { outcome = .declined }`, reusing the existing outcome so no enum case is added.
- Fixtures (`:642+`):
  - `incomingID = A1000000-0000-4000-8000-00000000000B`
  - `incomingChallenge = presentation(id: incomingID, opponentName: "Alex", lifecycle: .pending(direction: .incoming, createdAt: labNow, expiresAt: labNow + 20 h), userPoints: 0, opponentPoints: 0, days: [], currentDayOrdinal: nil, terminal: nil)`
  - It is **not** added to the Home `publication`, so the existing Home tests are untouched.
- Account lab (`:570-640`): `@State private var blocked = [AuthenticatedProfile(id: a1000000-0000-4000-8000-0000000000b1, displayName: "Alex")]`, passed as `AccountBlockedPeople(people: blocked, unblocking: [], unblockFailed: false, load: {}, unblock: { id in blocked.removeAll { $0.id == id } })`.

#### Server changes

##### 1. Forward migration `supabase/migrations/20261102002600_add_account_blocks.sql`
Never edit 1900 or 2400. DDL first, and no data updates. Everything is security definer with `set search_path = ''`.
1. **Table**
   ```sql
   create table private.account_blocks (
     blocker_profile_id uuid not null references public.profiles(id) on delete cascade,
     blocked_profile_id uuid not null references public.profiles(id) on delete cascade,
     created_at timestamptz not null default pg_catalog.statement_timestamp(),
     primary key (blocker_profile_id, blocked_profile_id),
     constraint account_blocks_distinct_profiles check (blocker_profile_id <> blocked_profile_id)
   );
   create index account_blocks_blocked_profile_id_idx on private.account_blocks(blocked_profile_id);
   alter table private.account_blocks enable row level security;
   alter table private.account_blocks force row level security;
   revoke all on table private.account_blocks from public, anon, authenticated, service_role;
   ```
2. **Purge on deactivation.** This copies `private.purge_app_attest_on_profile_deactivation` (`20260811000800:810-829`). Profiles are anonymized, not deleted, so the FK cascade alone never fires.
   - `private.purge_account_blocks_on_profile_deactivation()`: `if old.state = 'active' and new.state <> 'active' then delete from private.account_blocks b where b.blocker_profile_id = new.id or b.blocked_profile_id = new.id; end if;`
   - `create trigger purge_account_blocks_on_profile_deactivation after update of state on public.profiles for each row execute function …`
   - Revoke execute from all roles.
3. **`public.block_challenger(competition_id uuid) returns jsonb`**
   - `caller := private.require_active_caller_profile_id()`. A null input raises `invalid_competition_id` (22023).
   - `select creator_profile_id into sender from public.competitions where id = input and invited_profile_id = caller and creator_profile_id <> caller`. If not found, raise `invite_unavailable` (P0001), the collapsed error.
   - `perform 1 from public.profiles where id in (sender, caller) order by id for no key update`. This is the lock order `create_competition_invite_v2` uses (2400:184-186). A concurrent create either commits first (and is declined here) or waits, then sees the block.
   - `insert into private.account_blocks select caller, sender where exists (select 1 from public.profiles p where p.id = sender and p.state = 'active') on conflict do nothing`
   - `for declined in update public.competitions set lifecycle='declined', closed_by_profile_id=caller, closed_at=decision_time, updated_at=decision_time where creator_profile_id=sender and invited_profile_id=caller and lifecycle='pending' and invitation_expires_at > decision_time returning id loop perform private.enqueue_challenge_notification(declined.id, 'challenge_declined', sender, caller); end loop;`. These are exactly the effects of `decline_competition_challenge` (1900:269-301). The invitee participant stays pending.
   - Return `jsonb_build_object('competition_id', input)`. A repeat call is idempotent.
4. **`public.unblock_profile(profile_id uuid) returns jsonb`**
   - Takes the caller from `require_active_caller_profile_id()`. A null input raises `invalid_profile_id` (22023).
   - `delete from private.account_blocks where blocker_profile_id = caller and blocked_profile_id = input`
   - Returns `{profile_id}` whether or not a row existed. It touches only the caller's rows and reveals nothing.
5. **`public.list_blocked_profiles() returns jsonb`** (stable): `{"blocked": [{"id","display_name"}, …]}` for the caller's blocks whose profile is `active`, ordered by `created_at desc, id`, limit 200. Older rows beyond 200 are an accepted limit (§6).
6. **`create or replace function private.create_competition_invite_v2(...)`**, same signature.
   - Copy 2400:129-276 verbatim.
   - Insert the check directly after the reciprocal `incoming_challenge_exists` check (2400:247-252) and before the `insert into public.competitions`:
     ```sql
     -- Someone the recipient blocked reads as unavailable. Pair conflicts
     -- above describe only what both people already see.
     if exists (select 1 from private.account_blocks b
       where b.blocker_profile_id = input_recipient_profile_id
         and b.blocked_profile_id = caller_profile_id) then
       raise exception 'recipient_unavailable' using errcode = 'P0001';
     end if;
     ```
   - The public wrappers `create_competition_invite` (2400:278-292) and `create_competition_invite_from_link` (2400:300-342) call it. So by-id, rematch, 1.0.2 and `/c/` creates are all covered without touching the wrappers. Grants survive `create or replace`.
7. **`create or replace function public.resolve_invitation_recipient(profile_id uuid)`**: 2400:56-83, plus `or exists (select 1 from private.account_blocks b where b.blocker_profile_id = input_profile_id and b.blocked_profile_id = caller_profile_id)` in the final `recipient_unavailable` condition.
8. **`create or replace function public.resolve_challenge_link(code text)`**: 2400:102-126. The own-link branch stays first. The unavailable branch becomes `if not found or target.state <> 'active' or exists (select 1 from private.account_blocks b where b.blocker_profile_id = target.id and b.blocked_profile_id = caller_profile_id)`.
9. **Grants**:
   - `revoke all … from public, anon, authenticated, service_role` on the three new public functions and the trigger function.
   - `grant execute … to authenticated` on `block_challenger(uuid)`, `unblock_profile(uuid)` and `list_blocked_profiles()`.
10. **Unchanged**:
    - `preview_competition_invite`, `claim_competition_invite` and `accept_competition_challenge`. Accepting is never blocked.
    - `list_challenges`. A blocked sender has no pending row left to list.
    - The notification lease. It already supersedes a `challenge_received` push once the challenge isn't pending (2300:163-165).

##### 2. Recovery harness and inventories (each new migration moves these by one)
- `scripts/test-recovery-migrated-snapshot.sh`:
  - `:31`: change `== 27` (after PR 4) to `== 28`.
  - `:9`: recompute `manifest_hash` with `cd <repo> && sha256sum supabase/migrations/*.sql | sha256sum | awk '{print $1}'` (Linux). On macOS, `shasum -a 256` gives the same output. Checked on the VM: today's pin `975c46ce…54b8` reproduces with `sha256sum`.
- `scripts/tests/recovery-migrated-fixture.sql:23-24`: append `'20261102002600'` to the allowed max-version list.
- The new private table moves the state-acceptance baseline from 19 to 20 tables, and the FORCE private tables from 7 to 8:
  - `scripts/recovery-state-acceptance-query.sql`:
    - add `('private', 'account_blocks', true, true, false)` to `expected_tables` (`:25`)
    - add `('account_blocks', 'uuid', array['blocker_profile_id','blocked_profile_id'])` to `required_column_groups` (`:65`)
  - `scripts/tests/recovery-state-fixtures.sql`:
    - `create table private.account_blocks (blocker_profile_id uuid, blocked_profile_id uuid);`
    - enable and force RLS
    - add the table to the `truncate` list
    - note the migration in the header comment
  - `scripts/test-recovery-state-acceptance.sh`:
    - `:32`: `application_tables_checked=19` → `20`
    - add the table to the `drop table` list (`:207-211`) and to `set_fixture_rls` (`:568-573`)
    - `:578`: `rls_flag_mismatches=18` → `19`
  - `.github/workflows/backend.yml:223`: echo "… 20 application tables."
  - `docs/runbooks/backup-restore.md:776-816`: change 19 to 20 and seven to eight FORCE tables, and add `account_blocks` to the list.
  - The receipt keys stay at 33. There is no new violation counter, because the trigger keeps deactivated profiles block-free.

##### 3. Edge Functions
None change. `create-competition-invite` already returns 404 `recipient_unavailable`, which `index_test.ts:444` covers.

##### 4. Docs and web
- `docs/plans/2026-10-19-recipient-bound-invitations.md`: a new "## Blocking" section after "Challenge links and Reset Link" (`:34-54`). It covers:
  - Blocking is keyed by account id and granted only through a challenge addressed to you.
  - All create paths and both lookups return `recipient_unavailable`, after the pair checks.
  - A block declines like Decline.
  - One-way.
  - The full accepted-limits list from §6.
- `docs/runbooks/competition-support.md`, "Unsupported operations" (`:587`): operators don't add, remove or disclose blocks. The person unblocks in Account.
- `web/privacy.html` (Q-block-4 default): one sentence in the Controls section (`:107-129`). `scripts/verify-website.sh:46` checks only the page title.

##### 5. Compatibility
| Client | Effect |
|---|---|
| 1.0.2 (blocked sender, by id) | 404 `recipient_unavailable` → its existing message |
| Builds with #186/#195 (blocked sender), sheet or link | collapsed copy in §5 |
| Installed builds (blocked sender), rematch | "{Name} isn’t on HealthComp anymore." (false for a block; only new builds get the Q-block-1 copy) |
| Any older build as the blocker | no Block UI; nothing changes |
| New build against a server without the migration | `block_challenger` is missing → 404 → `.notFound` → "Couldn’t complete that…". This is why the server ships first |

#### Accessibility identifiers
- **Added**:
  - `competition.invite.block`, `competition.invite.block.confirm`
  - `competition.invite.decline.confirm`, `competition.invite.decline-block`
  - `competition.claim.decline-block`
  - `account.blocked.unblock`, `account.blocked.error`
  - `multiuser.incoming.outcome` (DEBUG lab)
- **Reused on a new screen**: `competition.more` (the incoming challenge's ••• menu).
- **Unchanged**: `competition.invite.accept/.decline/.cancel/.error`, `competition.claim.decline`, `account.notifications.unmute`, and every `account.challenge-link.*`.
- **Removed**: none.

#### Tests
**pgTAP `supabase/tests/024_account_blocks.test.sql`** (`no_plan`; fixtures in the style of 022: Naren, Maya, Tess, plus a completed match for the rematch case):
- `block_challenger, unblock_profile and list_blocked_profiles are security definers with an empty search path, for authenticated only`
- `account_blocks has RLS enabled and forced and no table privileges for client roles`
- `blocking declines the pending challenge exactly like Decline`: checks lifecycle, `closed_by`, `closed_at`, the invitee still pending, one `challenge_declined` work row for an active installation, and that Maya's `list_challenges().closed` row has the same shape as a plain decline.
- `a blocked sender gets recipient_unavailable by id, by rematch and by the current link code`
- `blocked lookups by link and by account id read like an unknown code`: the same SQLSTATE and message as `resolve_challenge_link('AAAAAAAAAAAAAAAAAAAAAA')`.
- `pair conflicts read as for anyone and the block refusal comes last`: while Naren's challenge to Maya is pending, Maya's by-id create gets `incoming_challenge_exists`. After Naren cancels it, she gets `recipient_unavailable`.
- `an exact retry of a create made before the block returns its id`
- `the blocker can still challenge the blocked person`
- `list_blocked_profiles shows only the caller's blocks of active profiles`: Maya's and Tess's lists are empty.
- `block_challenger refuses a challenge not addressed to the caller with invite_unavailable`: Tess on Naren's challenge, the creator on their own outgoing challenge, and null → `invalid_competition_id`.
- `blocking twice is idempotent`
- `blocking from an expired or declined challenge blocks without declining anything`
- `unblock_profile lets them challenge again and answers the same for someone never blocked`
- `starting account deletion removes that account's blocks in both directions`

**Deno** `supabase/functions/account_block_race_integration_test.ts` (modelled on `challenge_link_reset_race_integration_test.ts`; disposable local database only):
- Test name: "a block waits for the profile locks and wins cleanly against concurrent creates".
- **Seed**: Maya → Naren challenge, then Naren declines it. Now no pending row exists, and `block_challenger` has a valid key while a create can still succeed.
- **Lock probe**: open a transaction that runs Maya's by-id create and holds it uncommitted. In a second transaction, call `block_challenger(seed)` as Naren with `lock_timeout = '100ms'`. Expect `55P03`, which shows the block waits on the profile locks. Roll back the holder.
- **Race**: 20 by-id and link creates from Maya, fired concurrently with one `block_challenger(seed)` from Naren.
- **End state**:
  - no `pending` competition from Maya to Naren
  - at most one create succeeded; if one did, it is now `declined` with `closed_by_profile_id` = Naren
  - every other create failed with `pending_invitation_exists` or `recipient_unavailable`
  - one `account_blocks` row
  - no deadlock (`40P01`)
  - a create run after the race returns `recipient_unavailable`

**HealthCompTests**:
- `RemoteCompetitionFeatureTests`:
  - `testBlockTappedRunsBlockCommand` (copies `testCancelTappedRunsCommand` at `:909`)
  - `testBlockedPeopleLoadKeepsListOnFailedRefresh`: a first-load failure leaves `blockedPeople == nil` (section hidden). A later failed refresh keeps the shown list.
  - `testUnblockRemovesPersonOrShowsError`: a success removes the row. A failure sets `unblockFailed`, and the next `blockedPeopleRequested` clears it.
  - `testLateUnblockResultAfterStopIsDropped`: `stop`, then `.unblockFinished(id, succeeded: false)` leaves `unblockFailed == false`.
  - `testStopClearsBlockedPeople`
- `MainTabFeatureTests.testBlockClaimConfirmedBlocksAndConsumesRoute` and `testFailedBlockClaimReturnsToTheSheet`. Both copy the decline tests at `:264`/`:319`, with a `block` test double.
- `SupabaseCompetitionRemoteAPITests`:
  - `testBlockChallengerSendsCompetitionIDAndValidatesEcho`: RPC `block_challenger`, body `{"competition_id"}`. A mismatched echo gives `.serverContractMismatch`. P0001 `invite_unavailable` gives `.inviteUnavailable`.
  - `testListBlockedProfilesDecodesExactKeysAndSkipsUnreadableRows`: an extra top-level key, or more than 200 rows, gives a mismatch. A bad row is skipped.
  - `testUnblockProfileSendsIDAndValidatesEcho`
- `CompetitionPresentationTests.testRecipientAndFailureCopy` (`:1738-1741`): the `.recipientGone` expectation becomes "You can’t challenge Hermes." (Q-block-1 default).

**HealthCompUITests**:
- `MultiUserCompetitionUITests.testIncomingChallengeOffersDeclineAndBlock` (`.incomingChallenge`):
  - The dialog title, both buttons and the exact message "Alex will see a decline either way. If you block them, they can’t challenge you again." are present.
  - Keep Challenge dismisses.
  - Decline and Block gives the outcome "Declined and blocked".
- `MultiUserCompetitionUITests.testIncomingChallengeMoreMenuBlocksAfterConfirming`:
  - `competition.more` → `competition.invite.block` (label "Block Alex").
  - The "Block Alex?" dialog shows its exact message.
  - Cancel keeps the screen.
  - `competition.invite.block.confirm` gives the outcome.
- `MultiUserCompetitionUITests.testAccountListsBlockedPeopleAndUnblocks` (`.account`):
  - "Alex", the label "Unblock Alex" and the exact footer are present.
  - Tapping Unblock removes the section.
- `testDeclineBeforeHealthDeclinesOnTheServerAndKeepsHealthStep`: also assert that `app.buttons["Decline and Block Naren"]` exists in the claim dialog before tapping "Decline Challenge".
- `testChallengeScreensAppearanceAndTypeSizeMatrix` (`:576`):
  - Add an `.incomingChallenge` launch with a screenshot and `performAccessibilityAudit` at XS light and AX XXXL dark.
  - Add `incomingChallenge = "incoming-challenge"` to the test-side `Scenario` enum (`:1333-1348`).
- `LocalCompetitionLifecycleUITests.testIncomingDeclineClosesInPlaceAndReinviteIsReachableAndIdempotent` (`:227`): assert that `confirmation.buttons["Decline and Block Alex"]` doesn't exist and that `competition.more` doesn't exist on the fixture's incoming screen.
- The new UI tests aren't added to the `ci.yml` `-only-testing` list (#195 precedent). The Mac mini runs the full suite.

#### Verification (Mac mini, then CI)
1. Local server (Linux VM, Docker):
   - `supabase db reset && supabase test db` (all pgTAP, including 024)
   - `deno test --config supabase/functions/deno.json --allow-env --allow-net --allow-read supabase/functions`
   - `supabase db lint --local --level warning --fail-on warning`
   - `supabase db diff --local --agent no` must print nothing
   - `bash scripts/test-recovery-state-acceptance.sh --static`
   - **Pin check.** The migrated snapshot script exits early here (`orbstack_required`, `:16`), and CI only runs `bash -n` on it (`backend.yml:47`). So check its pins directly:
     - `ls supabase/migrations/*.sql | wc -l` must equal the count on `:31` (28)
     - `sha256sum supabase/migrations/*.sql | sha256sum | awk '{print $1}'` must equal `manifest_hash` on `:9`
     - the fixture's max-version list must contain the new version
   - The full snapshot run is an owner action on an OrbStack Mac. Otherwise the PR body says "not run".
2. Copy the code: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/ua/block/src && tar -x -C ~/dev-desktop/ua/block/src'`.
3. `ssh … '~/dev-desktop/ua/ua-mac6.sh xcodegen block'`: XcodeGen 2.46.0 must produce no `project.pbxproj` diff, since no files are added to targets.
4. Run `ssh … '~/dev-desktop/ua/ua-mac6.sh unit block'` (HealthCompTests), then `ssh … '~/dev-desktop/ua/ua-mac6.sh ui block'` (the full UI suite, both classes). Targeted runs with `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testIncomingChallengeOffersDeclineAndBlock` and the others also work.
5. Take captures from the xcresult and put them next to the mockup in a preview artifact: the decline dialog, the claim-sheet dialog, the ••• menu, the Block confirmation and Account BLOCKED, in light and dark at XS and AX5. Call out the deviations:
   - PR 1's title and nav name are kept.
   - The blocked side shows sender copy instead of "Challenge unavailable".
   - "They aren’t notified." replaces "They aren't told they're blocked."
6. Staging (owner action):
   - promote the migration (runbook §4)
   - Account A challenges B; B taps Decline and Block A
   - A sees "Challenge declined" and the generic push
   - A's link open shows "Link not found"; A's Challenge Again shows "No account has this link…"; A's rematch shows the Q-block-1 copy
   - B challenges A; A's create shows the existing incoming-challenge conflict; B cancels
   - B's Account → BLOCKED lists A → Unblock
   - A can challenge again
   - then production, then TestFlight
7. PR CI (Xcode 16.4, iOS 18.5) is the merge gate, including backend.yml (pgTAP, Deno, state acceptance, lint, diff).

#### Risks and conflict regions
- **Migration numbering** with the other server features this round (nudge, reactions, notification choices). Whichever merges second renames its file to the next sequence and re-pins the count, hash and fixture list (checked as in Verification step 1). Each migration that redefines `private.create_competition_invite_v2`, `resolve_challenge_link` or `resolve_invitation_recipient` must copy the **latest** body, including this block check. A later `create or replace` from a stale copy would silently drop the block. pgTAP 024 catches that.
- **Recovery state baseline** (table count, FORCE list, `rls_flag_mismatches`): conflicts with any other feature that adds a private table (for example reactions). Rebase and add both.
- **`CompetitionInviteView.swift`** toolbar and dialogs: a practice-match or reactions feature could touch the same view. The ••• menu is the shared place for incoming-challenge actions.
- **`AccountSettingsView.swift`**: the new section sits in `body` next to `challengeLinkSection`. `AccountNotificationsPage` and `mutedRow` aren't touched, so the notification-choices feature doesn't conflict there.
- **`CompetitionFeature.swift`** State, Action and `stop`, **`CompetitionClient.swift`** init, and **`MainTabFeature.swift`** claim actions: other features add fields in the same blocks. Mechanical rebase.
- **iOS 26** renders `confirmationDialog` as an anchored popover on iPhone. The tests query `app.buttons[…]`, not `app.sheets`, as the existing Cancel Challenge test does. CI's iOS 18.5 shows an action sheet.
- No API newer than iOS 17 is used, so no `if #available` is needed.
- **Size**: the playbook sized this S. It is M because of the server harness pins, the claim-sheet entry point and the tests. The `mutedRow` refactor was dropped to keep it from growing.

#### Claude's calls
- The block RPC is keyed by a challenge (competition id), not a profile id, to keep the recipient-bound, no-directory contract.
- A block reads as a plain decline, push included.
- The block check runs after the pair checks, so the only new refusal the blocked person can see is `recipient_unavailable`, on creates that would otherwise succeed.
- The remote decline moves to a `confirmationDialog`. The fixture keeps its alert.
- The claim sheet gets the same second choice, per the mockup rule.
- The BLOCKED section is hidden unless a non-empty list has loaded. There is no load-error row and no retry. Unblock needs no confirmation.
- No Account challenge-link caption change.
- One PR (#195 precedent).

#### Review notes
Applied:
- The recovery snapshot can't run on the VM, the Mac mini or in CI. Verification now uses a Linux pin check, and the full run is an owner action.
- Q-block-1 now says the rematch path reveals a block, and the contract doc lists it.
- The Deno race now has a declined seed, a `lock_timeout` probe and end-state assertions.
- A late `unblockFinished` is dropped after `stop`.
- No Account error for people with no blocks: the section shows only when non-empty, and the load-error row and `account.blocked.retry` are removed.
- `ForEach(people, id: \.id)`.
- Runbook §4, not §5.
- The "aren't told" promise became "They aren’t notified." Q-block-2 states the choice, and the pair checks now precede the block so `incoming_challenge_exists` stays truthful.
- `unblockFailed` clears on reload.
- The decline message is shorter and names the person once.
- The claim sheet gets Decline and Block.
- The "Ask for a new one." probe is an accepted limit.
- The privacy sentence is now Q-block-4, defaulting to adding it.
- A compatibility row for older builds on rematch.
- The `mutedRow` extraction was dropped.
- The 200-row cap is an accepted limit.
- The wrong "tallying match coexists" sentence was replaced.

Partly applied:
- **Account placement**: kept inline, as the owner-approved mockup shows and as the inline challenge-link section already does. The pushed-page alternative is now Q-block-5, not a silent call. A pushed page would also pop unpredictably when its NavigationLink row hides after the last Unblock.
- **200-row cap**: documented rather than enforced. Evicting the oldest block would silently unblock someone, and refusing would turn a decline into an error. A block needs a real challenge, so 200 is not expected to be reached.

Rejected: none.

#### Owner actions for this feature (merged into §7)
- Run the full migrated-snapshot recovery test (`bash scripts/test-recovery-migrated-snapshot.sh`) on an OrbStack Mac with supabase CLI 2.113.0 and Docker engine 28 or newer, as was done for #195. Neither the Linux VM (Docker context `default`) nor the Mac mini (no docker or supabase) can run it, and CI only runs `bash -n` on it. If it isn't run, the PR body must say "not run".
- Promote the migration to Staging (docs/runbooks/supabase-environments.md §4, "Dry-run and apply migrations"; this PR changes no Functions, so §5 doesn't apply). Smoke-test with the two Staging accounts using Verification step 6. Then promote to production through the docs/release/production-beta-checklist.md approval, before any TestFlight build that contains this PR.
- Deploy web/ (privacy sentence) with the release if Q-block-4's default is accepted.
- Approve the preview artifact before the PR opens. It holds captures of the decline dialog, the claim-sheet decline dialog, the ••• menu, the Block confirmation and Account BLOCKED, in light and dark at XS and AX5, with the deviations listed.
- Answer the open questions below, or accept the defaults.

### 9.8 PR 9 and 10: Reactions: server (PR 9) and app (PR 10)

Branches: `feature/reactions-server` → `feature/reactions` · Server: yes · Size: L · Stakes: none

#### Integration amendments (override the text below)
- This section covers two PRs: **PR 9** `feature/reactions-server` (migration, function, pgTAP, harness, runbooks, `web/privacy.html`) and **PR 10** `feature/reactions` (app). Third server PR: after PR 8. Migration `20261102002700`, count 28 → 29, pgTAP `025`, state baseline 20 → 21 tables, `rls_flag_mismatches` 19 → 20, nine FORCE tables. The kind list restates `'nudge'`, and the alert goes into PR 4's `genericAlerts`.
- **No Reactions switch in this round's reactions PRs (PR 13 owns it).** Decision 4 is narrowed: `device_installations.supports_reactions` is only a capability flag. New builds always send `true` (`CompetitionInstallationRequest.supportsReactions = true`, still encoded and validated); 1.0.2 and current builds get `false` through the delegating overloads. Delete from PR 10: `CompetitionReactionPushPreference` (Design A's "Push switch preference" block and the "push switch preference" in the scope line), Design G's "The Reactions switch … stays" sentence, Design I's `MountLease` bullet (`reactionPushesEnabled:`), Design Q's Account-scenario bullet (`reactionPushes: $reactionPushes`), the `account.notifications.reactions` identifier, the Risks bullet telling `notifs` to adopt `CompetitionReactionPushPreference.storageKey`, the coordinator's `reactionPushesEnabled` closure and `Registration` struct (`CompetitionPushRegistration.swift` doesn't change), `.reactionPushesChanged`, Design O and P (Account row and `HealthCompApp` binding), the `installationCoordinator?.reconcile()` addition to `reconcileNotifications()` (PR 13 adds it), `testReactionSwitchReregistersTheSameToken`, `testReactionPushesChangedReconcilesNotifications`, and the extension of `testNotificationsPageOpensSettingsAndUnmutes`. PR 13's Reactions row writes `muted_push_kinds` and the lease suppresses at send time, which also closes the "switch off with a row already pending" gap. Q-reactions-7 is answered by PR 13.
- **No block check** in `set_competition_reaction` (§4); the Risks line suggesting one is superseded.
- **Home caption.** `CompetitionHeroCard`/Live cards: the VoiceOver caption is `[beltStanding, reactionA11y].compactMap { $0 }.joined(separator: ". ")` (PR 1 first).
- **Result screen order:** PR 1's belt banner, then this PR's reaction panel, then PR 2's Share Result.
- **Practice** needs no change here (`competitionCanReact` is false for `practice-pacer:v1`).

#### PR scope
- `feature/reactions-server`: Migration `20261102002700_add_competition_reactions.sql`: private.competition_reactions, the set_competition_reaction(uuid, integer, text) and list_competition_reactions RPCs, a realtime wakeup to both participants, generic 'reaction' push work with an hourly limit, device_installations.supports_reactions and a 5-argument register overload. Also the send-competition-notification 'reaction' kind, pgTAP `025_competition_reactions.test.sql`, Deno tests, and the recovery harness (count, pin, acceptance manifest, rls_flag_mismatches) with backup-restore.md and the backend.yml echo. Plus runbooks and web/privacy.html (collection, sharing, deletion, effective date). Ships to Staging, then production, before any TestFlight build of the app PR. Order: Edge Function first, then the migration.
- `feature/reactions`: App: new CompetitionReactions.swift (model, AnyLayout picker, line, seen marks), the remote API and wire contract, RemoteCompetitionClient fetch/attach/set, CompetitionFeature actions, and the forbidden mapping for reaction_not_allowed. UI: the day drawer react row, a tappable unseen-reaction line on the match screen, the result screen panel and the REACTIONS list in its week drawer, and a Home line on the hero/Live cards and Recent results rows. No Reactions switch: `supports_reactions` is always true from new builds, and the per-iPhone switch is PR 13's. Seen marks are cleared on profile teardown. Also the Test Lab fixture, unit and UI tests, and project.pbxproj regenerated by XcodeGen 2.46.0 (project.yml unchanged).

Date: 2026-11-01 · Base: `main` at 8c5ca25 · Line numbers are from 8c5ca25. Re-anchor by symbol after rebasing. Stakes are out of scope everywhere (the owner rejected them).

#### Scope
- Each person can react to the **other person's day** and to the **result**, with one of four presets: 👏 clap, 🔥 fire, 😤 huffing, 🫡 salute.
  - Day reactions cover Days 1–7, once that day has started, while the match is live or tallying.
  - Each person has at most one reaction per target. Tapping the same preset again removes it. Tapping another preset changes it.
- **Where it shows:**
  - The day drawer: a react row, plus the reaction you got on that day.
  - The match screen: one tappable line while a received day reaction is unseen. It opens that day's drawer.
  - The result screen: a react panel, plus the reaction you got on the result.
  - The result screen's "The Week" drawer (how a finished match opens from Home and History): a REACTIONS list with result and day reactions.
  - Home: one line on the hero/Live card or the Recent results row until you leave that match's screen.
- **Push:** a generic "New reaction" push, at most one per hour per match per recipient. A muted person's reactions are suppressed. The new "Reactions" switch in Account → Notifications turns them off for this iPhone.
- **Live updates:** through the existing `competition_changed` realtime wakeup, sent to both participants.
- **Out of scope:**
  - Stakes.
  - Reactions in the simulated fixture or the local Test Lab: the control is nil there.
  - Chat or free text.
  - A Notification Service Extension.
  - Day drawers on the result screen (Q-reactions-3).

#### Decisions (Claude's calls; the owner can overrule)
1. **Reactions never enter `competition_change_log`.**
   - Every installed app syncs through `fetch_competition_changes` (20260811000450:859-981). Its `private.competition_change_payload` raises `server_contract_mismatch` for any kind it doesn't know (`else` branch, 20260811000450:843-845).
   - A reaction change-log row would break sync of that match for every build, including 1.0.2.
   - The log is also append-only (`reject_competition_change_log_mutation`), and reactions change and get removed.
   - So reactions live in their own table, read through one list RPC, the same way `list_challenges` (20261101001900:462-522) sits beside the feed.
2. **The table is private, and both reads and writes go through two security-definer RPCs.** The RPCs enforce participant-only access, and there is no client table grant (as with `private.challenge_links` and `private.competition_notification_mutes`).
   - The app reads everything through RPCs anyway.
   - A public table with a policy would need `expected_policies` and `public.*` privilege rows in `scripts/recovery-state-acceptance-query.sql`, and it would open a second read path.
   - RLS is enabled and forced, deny-all.
3. **Realtime reuses the exact broadcast, to both participants.** Event `competition_changed`, payload `{"server_cursor_hint": "<next_server_seq - 1>"}`, private topic `profile:<id>`.
   - It goes to every `accepted` participant whose profile is `active`: the same recipients as the change-log trigger (20261101001900:860-880).
   - Every installed app handles it with a normal reconcile (`RemoteCompetitionClientCoordinator.consumeRealtime`, RemoteCompetitionClient.swift:1561-1576, which ignores the hint).
   - So the author's second iPhone updates too. On the authoring phone, the reconcile replaces the optimistic row with the server row.
   - Older builds do one cheap extra sync and nothing else.
4. **The Reactions switch is a per-install capability flag (`device_installations.supports_reactions`), sent at registration.**
   - The app has no Notification Service Extension (project.yml targets: the app plus tests only). Dropping a remote alert on arrival needs Apple's `com.apple.developer.usernotifications.filtering` entitlement.
   - The same flag keeps reaction pushes away from older builds, which can't show reactions.
   - Unlike 20261101002300, which discards challenge work at lease time, reactions filter at **enqueue** time only, so the lease function is unchanged. Known gap: a reaction row already pending when you turn the switch off still sends, at most one per match (Edge cases).
   - A sender's account deletion is already covered: `20260811000750:378-389` supersedes pending/leased work whose `source_profile_id` is the deleted profile.
5. **The day drawer puts the react row between the day's head-to-head row and the ring panel,** so it shows at the `.medium` detent. The mockup has no ring panel.
6. **"Show in its History week"** means the REACTIONS list in `CompetitionResultView`'s week drawer, the week view of every finished match. It includes result reactions.
7. **Chips follow the mockup:**
   - Circles on `Theme.control`, at least 48 pt (`@ScaledMetric`).
   - Selected: a 2 pt `Theme.you` ring plus the `.isSelected` trait. `Theme.you` is the darker amber text token; `Theme.youFill` on `control` is under 3:1.
   - The mockup's light-amber fill (#FFF3D6) is not a token, so it's dropped. No new colors.
8. **Day reactions close when the result lands.** `CompetitionResultView`'s week chart has no `selectDay` (CompetitionResultView.swift:315-333, CompetitionWeekChart.swift:22), so the app can't offer them after that. The server refuses them too, so the two sides match.

#### Behavior

##### Rules
- **Day reactions.** Only on a day that has started in the match calendar's time zone (`competitions.time_zone_identifier`), and only while the server lifecycle is in (`scheduled`, `active`, `ends_today`, `tallying`). That is the live set used by `match_in_progress_between` (20261101001900:60) and the finalizer (20260811000900:27-29).
  - Current ordinal: `(now at time zone tz)::date - start_day + 1`. A tallying week allows all 7 days.
  - In the app the picker appears only in the live screen's day drawers. Those open only for days with `ownerLatestAvailability != .notYetOccurred` (CompetitionWeekChart.swift:22).
- **Result reaction.** Only once a `competition_results` row exists, on the result screen (`.completed` / `.archived`).
- **Who can react.** Both participants must be `accepted`, and the other person's profile must be `active`. With a "Former competitor" the app hides the picker and the server answers `reaction_not_allowed`. Received reactions still show.
- **Same preset twice** is a no-op on the server: no write, no wakeup, no push.
- **Removing** writes a delete and sends a wakeup, but no push.
- **Muting** a person (existing per-person mute) suppresses their reaction pushes. Their reactions still show in the app.
- **Push limit.** At most one `reaction` work row per (match, recipient) per rolling hour, in any state. Combined with the work-row identity, a second reaction at the same change-log position stays silent. A `ponytail:` comment in the SQL says so.

##### Copy (en_US; apostrophes typographic in code)
| Where | Text |
|---|---|
| Day drawer section label (`SectionLabel`) | `REACT TO {NAME}’S DAY` (name `uppercased(with: locale)`) |
| Day drawer footnote (caption, `Theme.secondary`) | `{Name} sees your reaction on this day.` |
| Received line: day drawer, match screen, Home, REACTIONS list | `{Name} reacted to your Day {n}` / `{Name} reacted to the result` |
| Your own line in the REACTIONS list | `You reacted to {Name}’s Day {n}` / `You reacted to the result` |
| Result panel label | `REACT TO THE RESULT` |
| Result week drawer section label | `REACTIONS` |
| Save failure (under the picker) | `Couldn’t send your reaction. Try again.` |
| Account → Notifications section header / switch | `FROM THE OTHER PERSON` / `Reactions` |
| Server push (APNs alert) | title `New reaction`, no body, no name |
| VoiceOver chip labels | `Clap`, `Fire`, `Huffing`, `Salute`. Selected chip: `.isSelected` trait and hint `Removes your reaction` |
| VoiceOver for a reaction line | `{Spoken}. {line}`, for example `Huffing. Jordan reacted to your Day 2` |
| VoiceOver hint on the match-screen line | `Opens Day {n}` |

- {n} is the plain day ordinal (`Day 2`, as in existing drawer titles). There are no other numbers.
- On Home, only the card's **accessibility** label gets `". {Spoken}. {line}"` appended, through `competitionButton`'s `caption` (CompetitionSharingView.swift:266-288). The visible caption is unchanged. Existing UI tests match Home cards with `label CONTAINS`.

##### Home line and seen marks
- **Which reaction.** `competitionUnseenReaction(_:seen:)` returns nil unless `competitionShouldShowScores(c.lifecycle)` (CompetitionSharingView.swift:1462-1471). That excludes cancelled matches left on Home after an account deletion. Otherwise it returns the newest reaction from the other person (max `updatedAt`, `isFromYou == false`) when its `updatedAt` is later than the stored mark for that match.
- **Stored mark.** One `@AppStorage(CompetitionReactionsSeen.storageKey)` value (`"healthcomp.reactionsSeen"`), `[lowercased uuid: TimeInterval]`. `marking(c)` stores the **server `updatedAt`** of that match's newest incoming reaction, never device time, so clock skew can't hide or re-show one.
- **When it is marked seen.** `CompetitionDetailView` and `CompetitionResultView` write the mark in `onDisappear`, which runs on back or pop. Presenting a drawer sheet doesn't trigger it. So the match-screen line stays while you're on the match, and Home is clean when you return.
- **Where it shows on Home:** `CompetitionHeroCard` (hero and compact Live cards) and the Recent results rows (`resultRow`). Not on Needs you or Up next rows: those are pending, scheduled-before-Day-1 or closed matches, which can't hold a live reaction.
- **Device-local.** A second iPhone shows the line until the match is opened there too.
- **Cleared on sign-out and account deletion:** `AuthenticatedProfileStorage.teardown(_:)` removes the key.
- `ponytail:` the dictionary never prunes (about 60 bytes per match). Prune it against the dashboard if that ever matters.

##### Edge cases
- **Tallying:** day drawers still offer the picker, since Days 1–7 are finished.
- **After the result:** no day picker anywhere. If the result lands while a live drawer is open, the next tap fails with the error line.
- **Offline or rejected** (for example, near midnight the phone's "today" is ahead of the match calendar): the chip reverts, the error line shows, and tapping again retries.
- **Other person on an older build:** your reaction saves. They see it after updating and get no push meanwhile (Q-reactions-1).
- **Switch turned off with a reaction push already pending:** that one row still sends (enqueue-time filter, Decision 4).
- **App killed while on the match screen:** `onDisappear` doesn't run, so the Home line shows once more after relaunch.
- **Simulated fixture / local Test Lab:** the `reactions` control is nil, so no picker, no lines and no switch.
- **Repeated toggling by one participant:** each change wakes both people's open apps, which reconcile. That cost already happens for every score upload. `ponytail:` add a per-author rate limit if abused.
- **Foreground:** the app has no `willPresent` delegate (HealthCompAppDelegate.swift), so an open app shows no banner. It updates through realtime instead.
- **Tapping the push:** it carries the standard route keys and opens the match through the existing route hold (MainTabFeature `resolve`). The match-screen line then leads to the day.

#### Design: app (feature/reactions)

**Build and platform**
- No `project.yml` change: `sources: - path: HealthComp` picks up the new file.
- Run XcodeGen 2.46.0 on the Mac mini (`~/tools/xcodegen/bin/xcodegen generate`) and commit the regenerated `HealthComp.xcodeproj/project.pbxproj`. CI's determinism check must show no diff.
- Nothing here is newer than iOS 17: `@AppStorage` with `RawRepresentable<String>` is iOS 14, `@ScaledMetric` is iOS 14, and `AnyLayout` is iOS 16.
- `CompetitionDateFormatting.swift` and Modules/CompetitionCore are untouched.

**A. New `HealthComp/Features/Competition/CompetitionReactions.swift`** (SwiftUI + Foundation)

Model types:
```swift
enum CompetitionReactionKind: String, CaseIterable, Sendable {
    case clap, fire, huffing, salute
    var emoji: String { switch self { case .clap: "👏"; case .fire: "🔥"; case .huffing: "😤"; case .salute: "🫡" } }
    var spokenName: String { switch self { case .clap: "Clap"; case .fire: "Fire"; case .huffing: "Huffing"; case .salute: "Salute" } }
}
enum CompetitionReactionTarget: Hashable, Sendable {
    case day(Int), result
    var dayOrdinal: Int? { if case let .day(n) = self { n } else { nil } }
}
/// On a presentation: who reacted is relative to you.
struct CompetitionReaction: Equatable, Sendable {
    let target: CompetitionReactionTarget
    let kind: CompetitionReactionKind
    let isFromYou: Bool
    let updatedAt: Date
}
struct CompetitionReactionKey: Hashable, Sendable {
    let competitionID: CompetitionID
    let target: CompetitionReactionTarget
}
```

Push switch preference (read by the Account switch and injected into the installation coordinator by `MountLease`):
```swift
enum CompetitionReactionPushPreference {
    static let storageKey = "healthcomp.notifications.reactions"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: storageKey) as? Bool ?? true
    }
}
```

Seen marks: `struct CompetitionReactionsSeen: RawRepresentable, Equatable`.
- Members: `static let storageKey = "healthcomp.reactionsSeen"`, `var seenAt: [String: TimeInterval]`, `init()`, `init?(rawValue:)` and `rawValue`.
- Encode and decode **only `seenAt`** with JSONEncoder/JSONDecoder.
- Do **not** add `Codable` to the wrapper: a `RawRepresentable` + `Codable` type would encode through `rawValue` and recurse.
- `func marking(_ c: LocalCompetitionPresentation) -> Self` sets `seenAt[c.id.rawValue.uuidString.lowercased()]` to the max `updatedAt.timeIntervalSince1970` of `c.reactions.filter { !$0.isFromYou }`, keeping the old value when it is larger. With no incoming reactions it returns `self`.

Pure helpers, unit-tested:
- `func competitionReactionText(_ r: CompetitionReaction, opponentName: String) -> String`: the copy table.
- `func competitionReactionAccessibilityText(_ r:, opponentName:) -> String`: `"\(r.kind.spokenName). \(text)"`.
- `func competitionUnseenReaction(_ c: LocalCompetitionPresentation, seen: CompetitionReactionsSeen) -> CompetitionReaction?`: starts with `guard competitionShouldShowScores(c.lifecycle) else { return nil }`.
- `func competitionCanReact(_ c: LocalCompetitionPresentation) -> Bool`. True when all of these hold:
  - the lifecycle is `.active`, `.endsToday`, `.tallying`, `.completed` or `.archived` (callers pick the target: days only on the live screen, the result only on the result screen);
  - `RemoteCompetitionOpponentIdentity.profileID(c.opponentIdentity) != nil`;
  - `c.opponentDisplayName != "Former competitor"`.
- `extension LocalCompetitionPresentation { func ownReaction(_ t: CompetitionReactionTarget) -> CompetitionReaction?; func receivedReaction(_ t:) -> CompetitionReaction? }`

Views:
- **`struct CompetitionReactionControl`**: `let pending: [CompetitionReactionTarget: CompetitionReactionKind?]`, `let failed: Set<CompetitionReactionTarget>`, `let react: (CompetitionReactionTarget, CompetitionReactionKind) -> Void`, and `func selection(_ t:, in c:) -> CompetitionReactionKind?`.
  - `pending[t]` is `Kind??`: use `if let p = pending[t] { return p }`, else `c.ownReaction(t)?.kind`.
- **`struct CompetitionReactionPicker: View`** (`selection`, `isPending`, `failed`, `select`), using `@Environment(\.dynamicTypeSize)` and `@ScaledMetric(relativeTo: .title2) private var chip: CGFloat = 48`.
  - Layout: `AnyLayout`, not `ViewThatFits`. The XCTest Dynamic Type audit flags text that ViewThatFits swaps out (CompetitionDetailView.swift:586-587, CompetitionResultView.swift:356).
    ```swift
    let layout = dynamicTypeSize.isAccessibilitySize
        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
        : AnyLayout(HStackLayout(spacing: 10))
    layout { HStack(spacing: 10) { chip(.clap); chip(.fire) }; HStack(spacing: 10) { chip(.huffing); chip(.salute) } }
    ```
    That gives one row of four normally, and 2×2 at AX sizes.
  - Each chip:
    - Content and size: `Button { select(kind) } label: { Text(kind.emoji).font(.title2).frame(width: chip, height: chip) }`.
    - Background: `.background(Theme.control, in: Circle())`, plus `.overlay { if selected { Circle().strokeBorder(Theme.you, lineWidth: 2) } }`.
    - Style: `.buttonStyle(CompetitionPressButtonStyle())`, `.disabled(isPending)`.
    - Accessibility: `.accessibilityLabel(kind.spokenName)`, `.accessibilityAddTraits(selected ? .isSelected : [])`, `.accessibilityHint(selected ? "Removes your reaction" : "")`, `.accessibilityIdentifier("competition.react.\(kind.rawValue)")`.
  - When `failed`, a caption line in `Theme.secondary` with the failure copy, id `competition.react.error`.
- **`struct CompetitionReactionLine: View`** (`reaction`, `opponentName`, `id: String?`):
  - `HStack(spacing: 8) { Text(emoji).font(.title3); Text(text).font(.subheadline).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }`
  - `.accessibilityElement(children: .ignore)` with label `competitionReactionAccessibilityText`, and the optional identifier.

There is no seen-marker ViewModifier. Each of the two screens has one `@AppStorage` property and one `onDisappear` line (sections J and K).

**B. `HealthComp/Features/Competition/LocalCompetitionClient.swift`**
- `LocalCompetitionPresentation` (:177-241): add `var reactions: [CompetitionReaction] = []` after `rematchParentID` (:199). The explicit init (:201-240) and every call site stay unchanged.

**C. `HealthComp/Services/CompetitionRemoteAPI.swift`**
- After `listChallenges` (:92-94), add closures with throwing defaults, so existing fakes compile:
  ```swift
  var listReactions: @Sendable () async throws -> [CompetitionReactionRecord] = { throw CompetitionRemoteFailure.operationFailed }
  var setReaction: @Sendable (CompetitionReactionRequest) async throws -> Void = { _ in throw CompetitionRemoteFailure.operationFailed }
  ```
- Add after `CompetitionChallengeList` (:144-170):
  ```swift
  struct CompetitionReactionRecord: Equatable, Sendable { let competitionID: UUID; let target: CompetitionReactionTarget; let authorProfileID: UUID; let kind: CompetitionReactionKind; let updatedAt: Date }
  struct CompetitionReactionRequest: Equatable, Sendable { let competitionID: UUID; let target: CompetitionReactionTarget; let kind: CompetitionReactionKind? }
  ```

**D. `HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`**
- **In `make(transport:)` after `listChallenges` (:323-329):**
  - `listReactions` sends `sendReadOnly(.rpc(name: "list_competition_reactions", parameters: encode(EmptyParameters())))`, then `decodeReactionList`.
  - `setReaction` validates the UUID and sends `.rpc(name: "set_competition_reaction", parameters:)` with exactly `{"competition_id": <lowercased>, "day_ordinal": <Int|null>, "reaction": <raw|null>}`. Encode the nulls explicitly, with a small `Encodable` struct using `encodeNil`.
  - The response must be exactly those three keys, echoing the request. Anything else is `.serverContractMismatch`.
- **New `private static func decodeReactionList(_ data: Data) throws -> [CompetitionReactionRecord]`, modelled on `decodeChallengeList` (:693-736):**
  - The top level must be exactly `["reactions"]`, an array of at most 2000. Otherwise `.serverContractMismatch`.
  - Each row must have exactly `competition_id`, `day_ordinal`, `author_profile_id`, `reaction`, `updated_at`.
  - `day_ordinal` is `NSNull` (result) or an Int 1...7.
  - `wireUUID` for both ids, `CompetitionReactionKind(rawValue:)`, `CompetitionWireCodec.date`.
  - An unreadable row is skipped (`continue`).
- **Failure mapping (:627-633):** add `"reaction_not_allowed"` to the `.forbidden` identifier list. `invalid_reaction` keeps falling to `.serverContractMismatch` through the 400 rule, since it means the app sent a bad value.
- **`registerInstallation` (:225-256)** becomes a fallback chain on `CompetitionRemoteFailure.notFound` (PGRST202):
  1. the current body, `encodeWire(request, contract: .installationRequest)`, which now has `supports_reactions`;
  2. `ChallengeInstallationParameters(request)`, a new private struct next to `LegacyInstallationParameters` (:897-913), with keys `installation_id`, `apns_token`, `environment`, `supports_challenges: true`;
  3. `LegacyInstallationParameters`.

  Write it as a loop over the three parameter `Data` values, and update the comment at :239-240.

**E. `HealthComp/Services/CompetitionSyncModels.swift`**
- `CompetitionInstallationRequest` (:1496-1548):
  - add `let supportsReactions: Bool`, an init parameter `supportsReactions: Bool = true`, and `CodingKeys.supportsReactions = "supports_reactions"`;
  - `encode(to:)` encodes it;
  - `init(from:)` uses `decodeIfPresent ?? true`.
- `validateInstallationRequest` (:3620-3641): the keys become `["apns_token", "environment", "installation_id", "supports_challenges", "supports_reactions"]`, plus `boolean(object["supports_reactions"])`. Either value is allowed.

**F. `HealthComp/Services/CompetitionPushRegistration.swift`, `CompetitionInstallationCoordinator` (:429-564)**
- `init` gains `reactionPushesEnabled: @escaping @Sendable () -> Bool = { true }`, stored.
  - The default is `{ true }`, not a UserDefaults read, so the existing `CompetitionPushRegistrationTests` call sites (:111, :156, :192) stay deterministic and unchanged.
  - `MountLease` (RemoteCompetitionClient.swift:559) passes `reactionPushesEnabled: { CompetitionReactionPushPreference.isEnabled() }`.
- `registeredToken: String?` (:438) becomes `private var registered: Registration?`, with `private struct Registration: Equatable { let token: String; let supportsReactions: Bool }`.
- `enqueue(_:)` (:526-536): `guard Registration(token: token, supportsReactions: reactionPushesEnabled()) != registered else { return }`.
- `register(_:)` (:538-563): reads the flag once, builds the request with `supportsReactions: flag`, and on success sets `registered = Registration(token:, supportsReactions: flag)`.
- `stopListening` (:479-487) and the failure path reset `registered = nil`.

**G. `HealthComp/Services/AuthenticatedProfileStorage.swift` `teardown(_:)` (:209-241)**
- Right after `activeProfileID = profileID`, add `UserDefaults.standard.removeObject(forKey: CompetitionReactionsSeen.storageKey)`. This keeps the privacy page's promise that sign-out and deletion clear this profile's local competition data.
- The Reactions switch is a per-iPhone notification preference and holds no account data, so it stays.

**H. `HealthComp/Features/Competition/CompetitionClient.swift`**
- Add `var setReaction: @Sendable (CompetitionID, CompetitionReactionTarget, CompetitionReactionKind?) async throws -> CompetitionPublication`, with a defaulted init parameter `= { _, _, _ in throw CompetitionRemoteFailure.operationFailed }`, after `resolveChallengeLink` (:100-103, :180-184, :210).

**I. `HealthComp/Features/Competition/RemoteCompetitionClient.swift`**
- **Wiring.** In `CompetitionClient.remote` (:68-160): `setReaction: { id, target, kind in try await coordinator.setReaction(id, target, kind) }`.
- **State.** Add `private var latestReactions: [CompetitionReactionRecord] = []` next to `latestChallenges` (:428). Reset it to `[]` everywhere `latestChallenges = .empty` is set (:502, :606, :691, :1056, :1387), so a profile switch never leaks reactions.
- **`performReconciliation` (:749-796).** After :764-766, add `if let reactions = try? await remoteAPI.listReactions() { latestReactions = reactions }`. A failure keeps the last good list, as challenges do.
- **`publish(materializations:profile:issues:knownCompetitionIDs:)` (:1694-1736).** Pass `reactions: latestReactions` into `RemoteCompetitionProjector.dashboard`.
- **`reconcileNotifications()` (:798-803).** Add `await installationCoordinator?.reconcile()` before `notificationCoordinator.reconcileLatest()`. The switch uses this endpoint, and the dedupe makes it a no-op when nothing changed.
- **`MountLease` (:559).** Pass `reactionPushesEnabled:` as in F.
- **New coordinator method,** next to `remote(_:)` (:921-932):
  ```swift
  func setReaction(_ id: CompetitionID, _ target: CompetitionReactionTarget, _ kind: CompetitionReactionKind?) async throws -> CompetitionPublication {
      try await withCancellableOperationGate {
          guard terminalTeardown == nil else { throw EnvironmentSignalOwnershipError.activeOwnerNotRetired }
          guard runtime != nil, let profile, let inputs = lastPublishInputs else { throw CompetitionRemoteFailure.unauthenticated }
          try await remoteAPI.setReaction(.init(competitionID: id.rawValue, target: target, kind: kind))
          latestReactions.removeAll { $0.competitionID == id.rawValue && $0.target == target && $0.authorProfileID == profile.id }
          if let kind {
              latestReactions.append(.init(competitionID: id.rawValue, target: target, authorProfileID: profile.id,
                                           kind: kind, updatedAt: await environment.context().instant.wallDate))
          }
          // Same republish as republishAtBoundary (:1755-1774): no network beyond the RPC.
          // The realtime wakeup that follows replaces this row with the server's.
          return await publish(materializations: inputs.materializations, profile: profile,
                               issues: inputs.issues, knownCompetitionIDs: inputs.knownCompetitionIDs)
      }
  }
  ```
- **`RemoteCompetitionProjector.dashboard` (:1862-1892)** gains `reactions: [CompetitionReactionRecord] = []`.
  - Build `let byMatch = Dictionary(grouping: reactions, by: \.competitionID)`.
  - In the `materialized` map, set `presentation.reactions = (byMatch[id] ?? []).map { CompetitionReaction(target: $0.target, kind: $0.kind, isFromYou: $0.authorProfileID == profile.id, updatedAt: $0.updatedAt) }.sorted { $0.updatedAt > $1.updatedAt }`.
  - Challenge presentations get none. `notificationSnapshot` is unchanged.

**J. `HealthComp/Features/Competition/CompetitionFeature.swift`**
- `State` (:103-172): add `var pendingReactions: [CompetitionReactionKey: CompetitionReactionKind?] = [:]` and `var reactionFailures: Set<CompetitionReactionKey> = []`. Both have defaults, so the explicit init is unchanged.
  - Add the helper `func reactionControl(for id: CompetitionID, send: @escaping (Action) -> Void) -> CompetitionReactionControl`.
- `Action` (:176-216): add `case reactionTapped(CompetitionID, CompetitionReactionTarget, CompetitionReactionKind)`, `case reactionFinished(CompetitionReactionKey, succeeded: Bool)` and `case reactionPushesChanged`.
- Reducer:
  ```swift
  case let .reactionTapped(id, target, kind):
      let key = CompetitionReactionKey(competitionID: id, target: target)
      guard state.pendingReactions[key] == nil,
            let competition = state.publication?.dashboard.competitions.first(where: { $0.id == id }) else { return .none }
      let next: CompetitionReactionKind? = competition.ownReaction(target)?.kind == kind ? nil : kind
      state.pendingReactions[key] = .some(next)   // must be .some: storing nil would remove the key
      state.reactionFailures.remove(key)
      return .run { send in
          do {
              let publication = try await competitionClient.setReaction(id, target, next)
              await send(.publication(publication))      // ordered before finish, so the chip never flickers back
              await send(.reactionFinished(key, succeeded: true))
          } catch { await send(.reactionFinished(key, succeeded: false)) }
      }
  case let .reactionFinished(key, succeeded):
      state.pendingReactions[key] = nil
      if !succeeded { state.reactionFailures.insert(key) }
      return .none
  case .reactionPushesChanged:
      return .run { _ in await competitionClient.reconcileNotifications() }
  ```
  `.publication` already ignores revisions at or below the current one (:247-251), so the duplicate from the hub stream is harmless.

**K. `HealthComp/Features/Competition/CompetitionDetailView.swift`**
- **Properties.** Add `var reactions: CompetitionReactionControl? = nil` after `cancelMatch` (:13), and `@AppStorage(CompetitionReactionsSeen.storageKey) private var reactionsSeen = CompetitionReactionsSeen()`. On the root `ScrollView`, after `.refreshable` (:84), add `.onDisappear { reactionsSeen = reactionsSeen.marking(competition) }`.
- **Match-screen line.** In `body`, after the scoreboard `VStack` (:45-61) and before `tallyPanel`, when `reactions != nil` and `let unseen = competitionUnseenReaction(competition, seen: reactionsSeen)` and `let day = unseen.target.dayOrdinal`:
  ```swift
  Button { drawer = .day(day) } label: {
      CompetitionReactionLine(reaction: unseen, opponentName: competition.opponentDisplayName, id: nil)
          .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
  }
  .buttonStyle(CompetitionRowButtonStyle())
  .accessibilityLabel(competitionReactionAccessibilityText(unseen, opponentName: competition.opponentDisplayName))
  .accessibilityHint("Opens Day \(day)")
  .accessibilityIdentifier("competition.reaction.latest")
  ```
- **`dayDrawer(_:)` (:291-309).** After the `CompetitionWeekChart` and before `dayActivity`, add a `VStack(alignment: .leading, spacing: 10)` when `if let reactions`:
  - `if let received = competition.receivedReaction(.day(ordinal)) { CompetitionReactionLine(reaction: received, opponentName: name, id: "competition.reaction.received") }`. It shows whenever one exists, including from a Former competitor.
  - `if competitionCanReact(competition) {` then:
    - `SectionLabel("REACT TO \(name.uppercased(with: locale))’S DAY")`;
    - `CompetitionReactionPicker(selection: reactions.selection(.day(ordinal), in: competition), isPending: reactions.pending[.day(ordinal)] != nil, failed: reactions.failed.contains(.day(ordinal)), select: { reactions.react(.day(ordinal), $0) })`;
    - `Text("\(name) sees your reaction on this day.")` in `.caption`, `Theme.secondary`.

    Then close with `}`.
- **Drawer state.** The drawer is a `.sheet(item:)` built from the parent's `competition`. Republishes re-render it, because `competition` is a `let` on the parent.

**L. `HealthComp/Features/Competition/CompetitionResultView.swift`**
- **Properties.** Add `var reactions: CompetitionReactionControl? = nil` after `retry` (:14), the same `@AppStorage` property as K, and `.onDisappear { reactionsSeen = reactionsSeen.marking(competition) }` beside `.onAppear` (:134).
- **Body.** After the `finalScore` / `summaryLine` VStack (:38-42), insert `reactionPanel.opacity(isRevealed ? 1 : 0)`.
  - Show it when `reactions != nil && (competitionCanReact(competition) || competition.receivedReaction(.result) != nil)`.
  - Content: a `VStack(alignment: .leading, spacing: 10)`.
    - When `competitionCanReact`: `SectionLabel("REACT TO THE RESULT")` and the picker for `.result`.
    - Always: `CompetitionReactionLine` for `receivedReaction(.result)` (id `competition.reaction.received`).
  - Modifiers: `.padding(16)`, `.frame(maxWidth: .infinity, alignment: .leading)`, `.themePanel()`, `.accessibilityElement(children: .contain)`, `.accessibilityIdentifier("competition.result.react")`.
- **`weekDrawer` (:315-333).** After `ringTotalsSection`, when `!competition.reactions.isEmpty`:
  - `SectionLabel("REACTIONS")` and a `VStack(alignment: .leading, spacing: 8)` of `CompetitionReactionLine`s.
  - Order: result reactions first, then by day ordinal; within a target, yours first.
  - Identifier `competition.reactions` on the container (`.accessibilityElement(children: .contain)`).
  - The list ignores `canReact`.
- The pinned rematch control (`safeAreaInset`, :86-97) is unchanged. The result screen keeps one primary action.

**M. `HealthComp/Features/Competition/CompetitionSharingView.swift`**
- **Properties.** `CompetitionSharingView` gets `@AppStorage(CompetitionReactionsSeen.storageKey) private var reactionsSeen = CompetitionReactionsSeen()` and `private func unseen(_ c:) -> CompetitionReaction? { competitionUnseenReaction(c, seen: reactionsSeen) }`.
- **Hero (:57-62) and Live (:73-79) calls:**
  - `competitionButton(c, caption: unseen(c).map { competitionReactionAccessibilityText($0, opponentName: c.opponentDisplayName) })`;
  - `CompetitionHeroCard(..., reaction: unseen(c))`.
- **`resultRow` (:231-252).** Keep the visible `caption` ("Moves to History …") as it is, and build a separate accessibility caption:
  ```swift
  let reaction = unseen(competition)
  let spokenCaption = [caption, reaction.map { competitionReactionAccessibilityText($0, opponentName: competition.opponentDisplayName) }]
      .compactMap { $0 }.joined(separator: ". ")
  competitionButton(competition, caption: spokenCaption.isEmpty ? nil : spokenCaption) {
      CompetitionSharingRow(competition: competition, source: publication.source, caption: caption, reaction: reaction)
  }
  ```
- **`rowButton` (:220-229)** (Needs you, Up next): unchanged.
- **`CompetitionHeroCard` (:407-452).** Add `var reaction: CompetitionReaction? = nil`. Under `CompetitionWeekStrip` (:427-430), when set: `Divider().overlay(Theme.hairline)`, then `CompetitionReactionLine(reaction:, opponentName:, id: nil)`.
- **`CompetitionSharingRow` (:596-670).** Add `var reaction: CompetitionReaction? = nil`. In `identity` (:651-672), after the caption `Text`, add the line.

**N. `HealthComp/Features/MainTab/MainTabView.swift` `destination(for:)` (:253-336)**
- `CompetitionDetailView(...)` (:273-293) and `CompetitionResultView(...)` (:296-308) get `reactions: publication.source == .remoteParticipants ? store.competition.reactionControl(for: id) { store.send(.competition($0)) } : nil`.
- `CompetitionClosedChallengeView` is unchanged. Closed matches never show a Home line (Home line section).

**O. `HealthComp/Features/Account/AccountSettingsView.swift`**
- `AccountNotificationSettings` (:17-28): add `var reactionPushes: Binding<Bool>? = nil`. Nil hides the row.
- `AccountNotificationsPage.body` (:528-580): between the status Section and MUTED, add:
  ```swift
  if let reactionPushes = settings.reactionPushes {
      Section { Toggle("Reactions", isOn: reactionPushes).tint(Theme.ink).frame(minHeight: 44)
                  .accessibilityIdentifier("account.notifications.reactions") }
      header: { SectionLabel("FROM THE OTHER PERSON") }
      .listRowBackground(Theme.panel)
  }
  ```
  If Notification choices (`notifs`) merges first, put this row in its "From the other person" group and drop the duplicate header.

**P. `HealthComp/App/HealthCompApp.swift` `accountSettings` (:312-345)**
- The containing view adds `@AppStorage(CompetitionReactionPushPreference.storageKey) private var reactionPushes = true`.
- Pass it when `competition.publication?.source == .remoteParticipants`:
  ```swift
  reactionPushes: Binding(get: { reactionPushes }, set: { reactionPushes = $0; mainStore.send(.competition(.reactionPushesChanged)) })
  ```

**Q. `HealthComp/Features/Competition/MultiUserCompetitionTestLabView.swift`** (DEBUG)
- **Fixtures.** `MultiUserCompetitionTestLabFixtures.publication(archivedIDs:)` (:682+) gains `ownReactions: [CompetitionReactionKey: CompetitionReactionKind]`.
  - Jordan (`activeID`): received 😤 `.day(2)`, `updatedAt = evaluatedAt - 1800`.
  - Morgan (`archivedID`, History): received 👏 `.result`.
  - "Former competitor" (`completedID`, Recent results): received 🫡 `.result`.
  - Your own reactions come from `ownReactions`.
- **Seen reset, once per process.** Never in a View initializer, because SwiftUI re-runs child inits when the root re-evaluates (the root reads colorScheme and dynamicTypeSize, :77-80).
  ```swift
  private static let resetReactionsSeen: Void = UserDefaults.standard.removeObject(forKey: CompetitionReactionsSeen.storageKey)
  ```
  This sits on `MultiUserCompetitionSharingTestLabView`, and its `init` does `_ = Self.resetReactionsSeen`. Launch arguments can't be used: an argument-domain value would mask the app's own writes.
- **Root view state.** The root view holds `@State private var ownReactions: [CompetitionReactionKey: CompetitionReactionKind] = [:]`. `destination(_:)` (:274-296) passes `reactions: CompetitionReactionControl(pending: [:], failed: [], react: { target, kind in toggle ownReactions })` to both the detail and the result view.
- **Account scenario** (:603-609): pass `reactionPushes: $reactionPushes` (`@State var reactionPushes = true`).

**Accessibility identifiers.**
- **Added:** `competition.react.clap`, `competition.react.fire`, `competition.react.huffing`, `competition.react.salute`, `competition.react.error`, `competition.reaction.received`, `competition.reaction.latest`, `competition.result.react`, `competition.reactions` and `account.notifications.reactions`.
- **Removed:** none. **Moved:** none.
- **Unchanged:** `competition.day.<n>`, `competition.result`, `competition.result.week`, `competition.sharing.<lifecycle>.<uuid>`, `competition.more`, `account.notifications`, `account.notifications.settings` and `account.notifications.unmute`.
- **Home line:** it sits inside a combined button, so it carries no identifier. Tests assert on the card's label.

#### Server changes (feature/reactions-server)

**`supabase/migrations/20261102002700_add_competition_reactions.sql`** (all DDL, no data fix):

1. **Table**
   ```sql
   -- Reactions are not change-log rows: every installed app's change feed
   -- rejects kinds it doesn't know (competition_change_payload).
   create table private.competition_reactions (
     competition_id uuid not null references public.competitions(id),
     author_profile_id uuid not null references public.profiles(id),
     day_ordinal smallint check (day_ordinal between 1 and 7), -- null: the result
     reaction text not null check (reaction in ('clap', 'fire', 'huffing', 'salute')),
     created_at timestamptz not null default pg_catalog.statement_timestamp(),
     updated_at timestamptz not null default pg_catalog.statement_timestamp(),
     constraint competition_reactions_one_per_target
       unique nulls not distinct (competition_id, author_profile_id, day_ordinal),
     constraint competition_reactions_membership_fk
       foreign key (competition_id, author_profile_id)
       references public.competition_participants(competition_id, profile_id)
   );
   alter table private.competition_reactions enable row level security;
   alter table private.competition_reactions force row level security;
   revoke all on table private.competition_reactions from public, anon, authenticated, service_role;
   ```
   `nulls not distinct` needs PostgreSQL 15 or later; `supabase/config.toml:42` is 17.
2. **Install capability and work kind**
   ```sql
   alter table public.device_installations add column supports_reactions boolean not null default false;
   alter table private.competition_notification_work
     drop constraint competition_notification_work_kind_check,
     add constraint competition_notification_work_kind_check check (kind in ('score_update', 'result',
       'challenge_received', 'challenge_declined', 'match_cancelled', 'nudge', 'reaction'));
   ```
3. **Registration overloads**
   - New `public.register_current_device_installation(installation_id uuid, apns_token text, environment text, supports_challenges boolean, supports_reactions boolean)`:
     - copy 20261101002300:10-94;
     - add `input_supports_reactions` (null raises `invalid_installation_request`);
     - insert it, and set it in `do update`;
     - same response shape.
   - `create or replace` the 4-argument function as a delegate passing `supports_reactions => false`, in the style of 20261101002300:96-110. The 3-argument function already delegates to the 4-argument one, so it gets false/false.
   - Revoke the 5-argument function from public, anon, authenticated and service_role, then grant execute to authenticated.
4. **`private.enqueue_reaction_notification(target_competition_id uuid, target_recipient_profile_id uuid, target_source_profile_id uuid) returns void`** (security definer, `search_path = ''`, revoked from every API role).
   - Modelled on `enqueue_challenge_notification` (**20261101001900:69-124**), with one early return and an install filter:
     ```sql
     -- ponytail: at most one per hour per match and recipient; the work row's identity (competition, server_seq, kind, recipient, installation)
     -- also makes a reaction with no new change-log row since the last reaction push silent. Change the identity if that ever matters.
     -- Filtered at enqueue only (the lease is unchanged): a row already pending when the recipient turns Reactions off still sends.
     if exists (select 1 from private.competition_notification_work w
       where w.competition_id = target_competition_id and w.recipient_profile_id = target_recipient_profile_id
         and w.kind = 'reaction' and w.created_at > decision_time - interval '1 hour') then return; end if;
     ```
   - Then set `server_seq := max(change_log.server_seq)` for the match.
   - The mute check marks the row `suppressed`.
   - Insert one row per `device_installations` row that is `state = 'active' and supports_reactions` and whose profile is active.
     - Semantic id: `'healthcomp.server-notification:v1:' || cid || ':reaction:' || seq || ':' || recipient || ':' || installation`.
     - `on conflict on constraint competition_notification_work_identity_unique do nothing`.
   - Finally `perform private.request_competition_notification_worker()`.
5. **`public.set_competition_reaction(competition_id uuid, day_ordinal integer, reaction text) returns jsonb`** (security definer, `search_path = ''`, aliases as in 1900).
   - **Parameter type:** `day_ordinal` is `integer`, not smallint. Postgres resolves functions through implicit casts only, and int4 → int2 is assignment-only, so `set_competition_reaction(id, 2, 'fire')` wouldn't resolve against a smallint parameter. The column stays smallint with its check.
   - **Caller:** `caller := private.require_active_caller_profile_id()`.
   - **Input checks:** a null `competition_id`, a `day_ordinal` outside 1..7, or a `reaction` not in the four values raises `invalid_reaction` (22023).
   - **Lock and load:** `select … from public.competitions c where c.id = … for no key update`, which serializes the hourly check. Load `other_profile_id`: the other participant must be `accepted`, the caller must be `accepted`, and the other profile must be `active`.
   - **Refusals:** raise `reaction_not_allowed` (P0001) in every refused case:
     - not found, or not a participant;
     - no other participant;
     - for a day: `c.lifecycle not in ('scheduled', 'active', 'ends_today', 'tallying')`, or `day_ordinal > (statement_timestamp() at time zone c.time_zone_identifier)::date - c.start_day + 1`;
     - for the result: `c.lifecycle not in ('completed', 'archived')`, or no `competition_results` row.

     One error for all of them, so a non-participant learns nothing.
   - **Write.** Read the current row. If it equals the request, return the echo with no side effects.
     - A null reaction deletes the row.
     - Otherwise: `insert … on conflict on constraint competition_reactions_one_per_target do update set reaction = excluded.reaction, updated_at = decision_time`.
   - **Side effects on a real change:**
     - Broadcast to both participants, with the recipient set of 20261101001900:860-880:
       ```sql
       for recipient in select p.profile_id from public.competition_participants p
         join public.profiles pr on pr.id = p.profile_id
         where p.competition_id = c.id and p.state = 'accepted' and pr.state = 'active' order by p.profile_id
       loop
         perform realtime.send(jsonb_build_object('server_cursor_hint', (c.next_server_seq - 1)::text),
           'competition_changed', 'profile:' || recipient.profile_id::text, true);
       end loop;
       ```
     - When the reaction is non-null, also `perform private.enqueue_reaction_notification(c.id, other_profile_id, caller)`.
   - **Return:** `jsonb_build_object('competition_id', c.id, 'day_ordinal', input_day_ordinal, 'reaction', input_reaction)`.
   - `ponytail:` no per-author rate limit. Participants only; add one if abused.
6. **`public.list_competition_reactions() returns jsonb`** (stable, security definer, `search_path = ''`).
   - Returns `{"reactions": [...]}`: up to 2000 rows, newest `updated_at` first, from matches where the caller's participant row is `accepted`.
   - Row keys: `competition_id`, `day_ordinal`, `author_profile_id`, `reaction`, `updated_at`.
   - `ponytail:` 2000 newest (about 125 finished matches). Page per match if anyone gets there.
7. **Grants.** Revoke all on both RPCs from public, anon, authenticated and service_role, then grant execute to authenticated. The lease function is **not** replaced.

**`supabase/functions/send-competition-notification/index.ts`**
- `workKinds` (:22-28): add `"reaction"`.
- `genericAlerts` (renamed from `challengeAlerts` by PR 4): add `reaction: { title: "New reaction" }`. Change the comment at :269 to "Challenge and reaction alerts stay generic: no name, so they are safe on a lock screen."
- The payload keeps `thread-id competition:<id>`, the route keys and `apns-collapse-id healthcomp:<id>`. Nothing else changes.

**Recovery harness and acceptance** (mirror 082e8e1 for `challenge_links`)
- `scripts/test-recovery-migrated-snapshot.sh`:
  - `:31`: `== 28` (after PRs 4 and 8) becomes `== 29`.
  - `:9` `manifest_hash`: recompute with `shasum -a 256 supabase/migrations/*.sql | shasum -a 256 | awk '{print $1}'` from the repo root.
- `scripts/tests/recovery-migrated-fixture.sql:23-24`: add `'20261102002700'` to the allowed max-version list.
- `scripts/recovery-state-acceptance-query.sql`:
  - `expected_tables` (:5-26): add `('private', 'competition_reactions', true, true, false)`.
  - `required_column_groups` (:29-66): add `('competition_reactions', 'uuid', array['competition_id','author_profile_id'])` and `('competition_reactions', 'text', array['reaction'])`.
- `scripts/test-recovery-state-acceptance.sh`:
  - `:32`: `application_tables_checked=20` (after PR 8) becomes `21`.
  - The drop list (:207-211) and the `set_fixture_rls` loop (:569-573) gain `private.competition_reactions`.
  - **`:578`:** `rls_flag_mismatches=19` (after PR 8) becomes `=20`, because the loop disables RLS on one more table.
- `scripts/tests/recovery-state-fixtures.sql`:
  - after :45, add `create table private.competition_reactions (competition_id uuid, author_profile_id uuid, reaction text);`
  - at :85-86, enable and force RLS;
  - add it to the list at :102.
- `.github/workflows/backend.yml:223`: the echo becomes `21 application tables`.
- `docs/runbooks/backup-restore.md`:
  - `:779`: `application_tables_checked=21`.
  - `:811-816`: the 21-table baseline with nine private tables with both flags, nine FORCE-protected tables, and `competition_reactions` added to the list.
- `supabase/tests/002_privacy_columns.test.sql:58`: add `'supports_reactions'` to the `device_installations` column list.

**Docs**
- `docs/runbooks/supabase-environments.md`: after "Challenge push capability" (:473-497), add a "Reactions" section covering:
  - the 5/4/3 overloads and the flag;
  - enqueue-time filtering and its pending-row gap;
  - deploy order: function, then migration;
  - reactions never enter the change log;
  - the hourly limit;
  - the app's 5 → 4 → 3 PGRST202 fallback.
- `docs/runbooks/competition-support.md` "Notification work" (:346+): add `reaction` to the kinds, and note "suppressed = muted; none enqueued for installs with supports_reactions false (older build)". The per-iPhone Reactions switch arrives with PR 13 (`muted_push_kinds`, suppressed at lease).
- `web/privacy.html` (needs the owner's OK; `verify-website.sh` must pass):
  - "Derived competition data" (:49-52): add "the preset reactions you send (👏 🔥 😤 🫡) and when you sent them".
  - Sharing (:70-73): "…results, the reactions you send, rounded …".
  - Deletion (:121-125): "Shared derived results, reactions you sent, stable history identifiers, and some operational records remain."
  - Effective date (:33): set it to the server PR's merge date.

#### Compatibility (installed builds)
| Build | Change feed | Realtime | Registration | Reaction push | Sees reactions |
|---|---|---|---|---|---|
| 1.0.2 | unchanged (no reaction rows) | same event and payload, one extra reconcile | 3-arg, flags false/false | never | no |
| Current main (challenges, pre-reactions) | unchanged | same | 4-arg, reactions false | never | no |
| New build | unchanged | same | 5-arg, true/true | yes, ≤1/h per match (PR 13 adds a per-iPhone switch) | yes |
| New build on an older server (inverted rollout) | unchanged | n/a | 404 → 4-arg → 3-arg | n/a | `list_competition_reactions` fails → keeps `[]`; `set` fails → error line |

With the old Edge Function and the new migration, no `reaction` rows can exist until a new build registers `supports_reactions = true`. Deploying the function first still removes the 502 risk.

#### Tests

**pgTAP: new `supabase/tests/025_competition_reactions.test.sql`**

Setup, in the style of 021: two players Ana and Ben plus outsider Cal, and one scheduled match started 2 days ago in UTC. Ben registers with the 5-arg call and Ana with the 4-arg call. Calls use plain literals (`set_competition_reaction(id, 2, 'fire')`), which works because the parameter is `integer`.

- **Table and functions:**
  - `private.competition_reactions` exists with RLS enabled and forced, and `has_table_privilege('authenticated', …, 'select')` is false.
  - Both RPCs are `prosecdef` with `search_path=""` and executable by authenticated only. The same holds for the 5-arg register (oidvector `2950 25 25 16 16`) and for `set_competition_reaction`'s oidvector `2950 23 25`.
- **Registration:** 5-arg true sets `supports_reactions`; the 4-arg call clears it; the 3-arg call clears it; null raises `invalid_installation_request`.
- **Day reactions:**
  - Ana reacts `fire` to Day 2 (started): it works and echoes the input.
  - Day 3 (today) works.
  - Day 4 (upcoming) raises `reaction_not_allowed`, and so does any day before Day 1.
- **Refusals:**
  - Cal (non-participant) and an unknown id both raise `reaction_not_allowed`, with the same message.
  - `reaction 'heart'` and `day_ordinal 9` raise 22023 `invalid_reaction`.
- **Result reaction:**
  - It raises `reaction_not_allowed` before a `competition_results` row exists.
  - After the row is inserted and the lifecycle is `completed`, it works. A **Day 2** reaction then raises `reaction_not_allowed`, and the existing Day 2 row still lists.
- **Writes:** the same reaction again adds no `realtime.messages` and no work row. Changing to `clap` keeps one row with `updated_at` advanced. Null deletes the row with one wakeup per participant and no work row.
- **Realtime:** each change sends exactly one `competition_changed` private broadcast to `profile:<Ana>` and one to `profile:<Ben>`, none to Cal. The payload keys are `{server_cursor_hint}`.
- **Older-build guard:** every reaction call leaves the `competition_change_log` row count unchanged, and `fetch_competition_changes` as Ben still succeeds over the whole feed.
- **Push:**
  - Ana → Ben creates one `reaction` work row per Ben install with `supports_reactions`, and none for an install registered with the 4-arg call.
  - Ben → Ana creates no row (Ana has 4-arg only).
  - A second Ana reaction within the hour creates no new row.
  - Ben muting Ana makes the row `suppressed`.
  - The lease returns the reaction item with the seven keys and `kind = 'reaction'`.
- **`list_competition_reactions`:** Ana and Ben each see both people's rows, Cal gets `{"reactions": []}`, and the order is newest first.
- **Anonymized:** with Ben anonymized (`state = 'anonymized'`), Ana's new reaction raises `reaction_not_allowed`, while Ben's existing rows (including a result reaction) still list for Ana.

**Deno: `supabase/functions/send-competition-notification/index_test.ts`**
- New `Deno.test("reaction payload is generic and routes to the match")`: `competitionNotificationPayload({ ...item, kind: "reaction" })` deep-equals `{ aps: { alert: { title: "New reaction" }, sound: "default", "thread-id": "competition:c3000000-…" }, route keys }`, with no name.
- `"challenge work items are leased and sent with the existing seven keys"` (:432-476): add `"reaction"` to `kinds`, use `batchSize` 4, and expect 4 sent bodies.

**Unit (HealthCompTests)**
- `SupabaseCompetitionRemoteAPITests`:
  - **New `testReactionsRouteThroughExactRPCs`:**
    - list decodes a day row and a result row (`day_ordinal: null`), and skips a row with an unknown reaction or an uppercase UUID;
    - extra top-level keys or more than 2000 rows give `.serverContractMismatch`;
    - `set` sends exactly `{"competition_id","day_ordinal","reaction"}`, with JSON `null` for the result and for removal;
    - an echo with a different reaction gives `.serverContractMismatch`;
    - a 400 with `reaction_not_allowed` maps to `.forbidden`.
  - **New `testInstallationRegistrationFallsBackThroughOlderCalls`:** a 404 on 5-arg retries 4-arg (`supports_challenges: true`, no `supports_reactions`), and a second 404 retries 3-arg.
  - **Update `testInstallationRegistrationFallsBackToLegacyCallOnUnmigratedServer`** (:451-480): the current body gains `"supports_reactions": true`, and the recorded requests go 5-arg, 4-arg, 3-arg.
- `CompetitionSyncModelsTests.testInstallationAndSynchronizationCursorContractsAreExact` (:330-360): expect `"supports_reactions": true`, and a request built with `supportsReactions: false` encodes `false` and passes the validator.
- `CompetitionPushRegistrationTests`:
  - **New `testReactionSwitchReregistersTheSameToken`:** with a mutable `reactionPushesEnabled` box, the coordinator registers once; `reconcile()` with the flag unchanged sends nothing; flipping to false and calling `reconcile()` sends a second registration with `supports_reactions: false`.
  - Existing tests are untouched: the default is `{ true }`.
- `AuthenticatedProfileStorageTests.testTeardownWipesExactlyOneProfileAndNeverItsSibling` (:145): set `CompetitionReactionsSeen.storageKey` in `.standard` first, and assert it is gone after teardown.
- `RemoteCompetitionClientTests`:
  - **New `testReactionsAttachToTheirMatchAndSurviveAFailedFetch`:** `listReactions` returns Jordan's 😤 Day 2 (author is the opponent) and your 🔥 Day 1. The published presentation has both, with `isFromYou` false and true. A later fetch that throws keeps them.
  - **New `testSetReactionRepublishesWithoutAFullReconcile`:** after the first publication, `setReaction` makes one `setReaction` API call and zero extra `listCompetitions` / `fetchChanges` calls. The returned publication carries the reaction with a higher revision.
  - **New `testProfileSwitchClearsReactions`:** modelled on the existing challenge-list profile-switch test (:1240-1300).
- `CompetitionFeatureTests`:
  - `testReactionTapSetsTogglesAndClears`;
  - `testReactionFailureMarksTheTargetAndClearsPending`;
  - `testReactionTapWhilePendingIsIgnored`;
  - `testReactionPushesChangedReconcilesNotifications`.
- `CompetitionPresentationTests`:
  - `testReactionCopy`: every row of the copy table, including the typographic ’.
  - `testUnseenReactionIsTheLatestIncomingAfterTheSeenMark`: your own reactions are ignored, the newest incoming wins, and `marking` (which stores the reaction's `updatedAt`) hides it.
  - `testUnseenReactionIgnoresMatchesWithoutScores`: `.cancelled` and `.scheduled` return nil even with a newer incoming reaction.
  - `testReactionsSeenRawValueRoundTrips`.
  - `testCanReactOnlyWithARealOtherPersonAfterTheMatchStarts`: `.scheduled` false, `.active` true, `.completed` true, "Former competitor" false, fixture identity false.

**UI (HealthCompUITests/MultiUserCompetitionUITests.swift)**
- **New `testReactionsOnHomeMatchDayDrawerAndResult`:**
  1. `launch(.sharing)`. `sharingCard(state: "active", name: "Jordan").label` contains `Jordan reacted to your Day 2`.
  2. Open the card. `competition.reaction.latest` has the label `Huffing. Jordan reacted to your Day 2`. Tap it: `competition.reaction.received` exists in the Day 2 drawer with the same label.
  3. Close the drawer, then `showWeek()` → `competition.day.3`:
     - `competition.react.fire` exists;
     - tap it and it becomes `isSelected`;
     - tap again and it is not selected;
     - `REACT TO JORDAN’S DAY` and `Jordan sees your reaction on this day.` exist.
  4. Run `performAccessibilityAudit` with the suite's set (`.textClipped`, `.hitRegion`, `.sufficientElementDescription`) on the open day drawer.
  5. Go back to Home: the Jordan card label no longer contains `reacted`.
  6. History → Morgan: `competition.result.react` exists, `Morgan reacted to the result` shows, and tapping `competition.react.clap` makes it selected.
  7. The "Former competitor" result: no `competition.react.clap`, but `competition.reaction.received` has the label `Salute. Former competitor reacted to the result`.
- **New `testReactionPickerFitsAtAccessibility5`:**
  - Launch with the AX5 arguments of `assertRemoteActiveDayReadability` (:1197-1210) and open the Day 3 drawer.
  - Swipe up on the drawer title `app.staticTexts["Day 3"]` to reach `.large`. Then swipe up on it again, at most 6 times, until `competition.react.salute` is hittable and inside `app.frame`. Don't use `scrollToElement`: its `app.scrollViews.firstMatch` can be the page behind the sheet.
  - Assert that all four chips are hittable, then run the suite's audit set **without** `.dynamicType`. It flags different elements on different runs (comment at :924-926).
- **Extend `testNotificationsPageOpensSettingsAndUnmutes`** (:915-944):
  - `FROM THE OTHER PERSON` exists, and `app.switches["account.notifications.reactions"]` has value `1`.
  - Tap the inner control, `app.switches["account.notifications.reactions"].switches.firstMatch.tap()`, because a row-centre tap hits the label on iOS 17/18. Then wait for the value `0` (`NSPredicate(format: "value == '0'")`, 3 s).
- **`.github/workflows/ci.yml:212-228`:** add `-only-testing:HealthCompUITests/MultiUserCompetitionUITests/testReactionsOnHomeMatchDayDrawerAndResult`.
- **Existing tests:** `testRemoteCompetitionAppearanceAndTypeSizeMatrix` (in CI) now renders Jordan's card and the Former competitor result row with a reaction line, and they must pass its audits at XS and AX5 in light and dark. Tests that match those cards use `label CONTAINS` (for example :129, :342), so no existing identifier or exact string changes.

#### Verify on the Mac mini (on top of the shared steps)
1. Copy the code: `git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'mkdir -p ~/dev-desktop/ua/reactions && tar -x -C ~/dev-desktop/ua/reactions'`.
2. In that folder:
   - Run `~/tools/xcodegen/bin/xcodegen generate` and commit the regenerated `project.pbxproj`. A second run must produce no diff.
   - Use `~/dev-desktop/ua/ua-mac6.sh` (unit, ui) or `~/dev-desktop/run.sh` with a per-PR `-derivedDataPath` on an iPhone 16 Pro iOS 18.5 slot simulator. Run HealthCompTests, both UI suites and the two new UI tests.
3. Take captures in light and dark at XS and AX5:
   - Home with Jordan's line;
   - Jordan's match screen with the latest line;
   - the Day 3 drawer at `.medium` and `.large`;
   - Morgan's result with the react panel;
   - the Former competitor result;
   - Account → Notifications.

   Put them in a claude.ai preview artifact next to the playbook mockups. The owner approves before the PR opens.
4. Server, locally:
   - `supabase db reset && supabase test db` (pgTAP including 025);
   - `deno test --allow-all --config supabase/functions/deno.json supabase/functions/send-competition-notification/`;
   - `deno fmt --check` and `deno lint` as in backend.yml;
   - `supabase db lint`, and `supabase db diff` (must be empty);
   - `bash scripts/test-recovery-state-acceptance.sh --static` and the full harness run CI uses (backend.yml:178-181), which checks `rls_flag_mismatches=20`;
   - `sh scripts/test-staging-adversarial-sql.sh`;
   - the recovery migrated snapshot (29 migrations).
5. Staging smoke test, after the function and then the migration:
   - Account A reacts to B's Day N. B's open app updates within seconds with no banner, and A's second phone (if signed in) updates too.
   - With B's app closed, B gets one "New reaction". Tapping it opens the match with the latest line, and tapping the line opens Day N.
   - A second reaction within the hour sends no push. Check with the "Notification work" query: one `reaction` row in `sent`.
   - B mutes A: the next push is `suppressed`.
   - B turns Reactions off: B's install row shows `supports_reactions = false`, and no new row is enqueued.
   - A 1.0.2 build on B still syncs, gets no reaction push, and its change feed works.

#### Risks and conflict regions
- **Deploy order:** the Edge Function before the migration (see Compatibility), and the production server before TestFlight.
- **Migration number and harness:** if another feature's migration lands first, this one is renumbered. Whoever merges second moves the count (29 → 30), the manifest hash, the fixture pin list, `application_tables_checked`, `rls_flag_mismatches`, the backend.yml echo and backup-restore.md.
- **Shared server regions with nudges and blocking** (features `nudge`, `block`):
  - `competition_notification_work_kind_check`: each migration must restate the full kind list, including every earlier kind.
  - `send-competition-notification` `workKinds` and alerts.
  - `register_current_device_installation`: if nudges also add a capability, coordinate one overload or merge the flags. Don't stack a 6-arg overload without need.
  - Blocking should also make `set_competition_reaction` raise `reaction_not_allowed` and skip the enqueue. Add one condition there when `block` lands.
- **Notification choices (`notifs`):**
  - The playbook has it extend `CompetitionNotificationPreferences` with one flag per family and hide server pushes "on arrival".
  - That store is an async per-profile file actor, while registration needs a synchronous per-install read, and on-arrival hiding needs an NSE that doesn't exist.
  - So `notifs` should adopt `CompetitionReactionPushPreference.storageKey` for its Reactions row, and give its server-push switches (nudges) the same re-register-the-install pattern, not on-arrival filtering.
- **Shared app regions:**
  - `AccountNotificationsPage` (`notifs` owns the grouping);
  - `CompetitionDetailView` body and `dayDrawer`;
  - the `CompetitionSharingView` hero card, `resultRow` and `CompetitionSharingRow` (`belt`, `live` features);
  - `RemoteCompetitionClient.performReconciliation` and the `latestChallenges` reset sites;
  - `CompetitionInstallationRequest` and its wire validator;
  - the `MultiUserCompetitionTestLabView` fixtures. UI tests elsewhere count cards or labels, so keep reactions only on Jordan, Morgan and Former competitor.
- **Hourly limit ceiling:** a reaction with no new change-log row since the last reaction push is silent (`ponytail:` in SQL). Accepted per the open question.
- **Enqueue-only filter:** turning the switch off doesn't cancel a row already pending, at most one per match. Accepted. Extending the lease's discard clause would mean copying the whole lease function into this migration, another conflict region.
- **Seen marks:** device-local, cleared on profile teardown, never pruned. A reinstall shows recent reactions on Home once.
- **Older builds** never see reactions, and the sender isn't told (Q-reactions-1).

#### Rollout
1. Server PR: Deno, pgTAP and the recovery harness green. Deploy the function to Staging, then the migration to Staging, then run the smoke test (step 5).
2. Promote the function, then the migration, to production through the beta checklist.
3. App PR: CI green on Xcode 16.4 / iOS 18.5, Mac mini suites green, preview approved, App Privacy reviewed. Merge, then TestFlight.

**Rollback:**
- App: ship without the UI.
- Server: the migration is forward-only. To disable reactions, redeploy the function with `reaction` → `null` payload, which discards rows; a plain redeploy of the previous function would 502 batches holding reaction rows. Or add a forward migration that makes `set_competition_reaction` raise.

#### Review notes
Applied: harness `rls_flag_mismatches` 18→19, plus backup-restore.md and the backend.yml echo; day reactions close at the result (app and server, new open question); integer RPC parameter; separate accessibility caption in `resultRow`; once-per-process Test Lab reset (two reports); AX5 test expands the drawer and drops `.dynamicType`; coordinator default `{ true }`, injected from MountLease; `reaction_not_allowed` → `.forbidden`; inner-switch tap; received reactions shown for Former competitor in the day drawer, the result panel and the REACTIONS list (with result reactions); enqueue citation fixed to 1900:69-124; no Home line for cancelled or not-yet-scored matches, and none on Needs you / Up next rows; match-screen latest line and seen-on-disappear for the push path (open question 2 flipped); privacy page now covers collection, sharing, deletion and the effective date; AnyLayout instead of ViewThatFits; seen marks cleared on teardown and keyed to server `updatedAt`; notifs coordination in Risks; mockup chips (circle, `Theme.you` ring); full live lifecycle set; broadcast to both participants; App Privacy owner action.

Rejected or partly rejected:
- **Sender deletion leaves reaction work pending.** Account deletion already supersedes pending/leased work whose `source_profile_id` is the deleted profile (20260811000750:378-389). Only the wording ("the challenge pattern") and the switch-off gap were real; both are fixed or documented, and the lease stays unchanged.
- **The Reactions switch must be cleared on sign-out.** It is a per-iPhone notification preference with no account data, so it stays.
- **Move the reaction flag into `CompetitionNotificationPreferencesStore` now.** That store is an async per-profile file actor, and the flag needs a synchronous per-install read at registration. The fix is recorded in Risks for `notifs` instead.

#### Owner actions for this feature (merged into §7)
- Approve the web/privacy.html changes before the server PR merges: reactions named in 'Derived competition data' and in Sharing, the deletion paragraph saying reactions you sent stay in shared history, and a new Effective date.
- Before the TestFlight or App Store submission, review App Privacy in App Store Connect. Add 'Other User Content' (linked to the user, App Functionality) if it isn't already declared.
- Deploy send-competition-notification to Staging, then apply the migration to Staging. The Edge Function goes FIRST: an older function returns 502 for a whole lease batch that contains an unknown kind, which would stall every push.
- Smoke-test on Staging with the two Staging accounts (steps in Verify), then promote the function and the migration to production through docs/release/production-beta-checklist.md.
- Only after production has the migration: upload the TestFlight build with the app PR.

### 9.9 PR 11 and 12: Practice match: pacer v2 (PR 11) and app (PR 12)

Branches: `feature/practice-pacer-v2` → `feature/practice-match` · Server: no · Size: L · Stakes: none

#### Integration amendments (override the text below)
- This section covers two PRs: **PR 11** `feature/practice-pacer-v2` ("Design: PR A") and **PR 12** `feature/practice-match` ("Design: PR B").
- **Fixture id** `practicePresentation()` uses `…000C` (§4).
- **Guards PR 12 adds to features merged before it** (or that those PRs add if they merge later): recap Share Result `&& !competition.isPractice` (PR 2), nudge control in `MainTabView.destination` `&& !competition.isPractice` (PR 5; `competitionCanNudge` would otherwise be true for a live practice with no opponent update), widget snapshot builder (PR 6), Live Activity planner (PR 7). Reactions need nothing (`competitionCanReact` requires a remote profile identity) and neither does the belt (built on `competitionHistoryWeeks`).
- **Notifications prompt** change in `MainTabFeature` stays as specified; PR 13's switches never see practice.

#### PR scope
- `feature/practice-pacer-v2`: Modules/CompetitionCore only: OpponentGeneratorVersion.v2, which scales the pacer to a baseline in daily points (v1 with a baseline throws), plus OpponentPlanTests. v1 bytes, commitments and goldens are unchanged. Merges first.
- `feature/practice-match`: App: a second LocalCompetitionRuntime hosted inside RemoteCompetitionClientCoordinator (its own per-profile journal directory, no HealthKit signal ownership, a pacer-checkpoint republish, auto-delete once a finished practice leaves Home), PracticeMatch.swift and PracticeMatchSheet.swift, the startPractice client endpoint, CompetitionFeature action, the notification prompt ignoring practice (MainTabFeature), the Home empty state and practice-only Challenge Someone, the hero rule, End Practice in the ••• menu, the Practice result kicker, exclusion from History, records and Account, one sentence in web/privacy.html, a MultiUser Test Lab scenario, unit and UI tests, the regenerated pbxproj and the ci.yml only-testing entry.

Date: 2026-11-01 · Base: `main` at 8c5ca25 · Size: **L, not the playbook's M** (see "Why it is bigger than it looks") · Server: none (one sentence on the static privacy page) · PRs: A `feature/practice-pacer-v2` (CompetitionCore), then B `feature/practice-match` (app)

Line numbers are from 8c5ca25. Re-anchor by symbol after rebasing onto other features from this round.

#### Intent
A person with no rival yet can play a real-looking 7-day match against a pacer, using their own Activity rings. It fixes f-welcome: the scoreboard gets seen before the first real match. It also exercises Health permission early. Practice is labeled "Practice", is on this iPhone only, runs one at a time, counts nowhere and can be ended from the ••• menu. There are no server calls, and stakes are not part of it anywhere.

#### Investigation: how the local engine works today, and whether it can run in a release build

**The pieces**
- **`LocalCompetitionRuntime`** (actor, `HealthComp/Services/LocalCompetitionRuntime.swift`) is the journal plus engine runner. It covers create (:139), accept (:434), refresh, reconcile and refreshAll (:289-301), delete (:206), loadAll (:247) and nextWake (:337).
  - Its only environment calls are `context()`, `instant()` and `read(window)` (:439-974).
  - `completeSignal` is called only from `handleAll` (:303-311) and `handle(_:competitionIDs:)` (:690-716).
  - `nextWake` (:337-424) holds expiry, day boundaries, tally deadlines/stability and the moment a result leaves Home (:417-424). It has **no pacer-checkpoint candidates**.
  - It compiles in Release: there is no `#if DEBUG` in the file.
- **`CompetitionEngine.accept`** (CompetitionCore/CompetitionEngine.swift:17-57) turns a pending genesis into `.scheduled`.
  - Day 1 is `calendar.startDay(afterAcceptanceAt:)`, which is tomorrow at local midnight (CompetitionCalendar.swift:40-42). That matches the mockup's "Start Tomorrow".
  - The opponent is `OpponentPlanGenerator.generate(seed:generatorVersion:difficulty:schedule:)` (OpponentPlan.swift:440-527).
  - The pacer is revealed as a step function: `OpponentPlan.revealedPoints` returns the last checkpoint at or below the time-of-day fraction (OpponentPlan.swift:294-307), computed from `now` at projection time in `LocalCompetitionProjector.dayPresentations` (LocalCompetitionClient.swift:1593-1616). So the pacer only moves when something re-projects.
  - Finalization uses the runtime's tally policy: 15 min stability, 2 stable complete reads, and best-available after 24 h (`LocalCompetitionRuntimeConfiguration.live`, LocalCompetitionRuntime.swift:11-14).
- **`CompetitionClient.localFixture`** (LocalCompetitionClient.swift:514-606) wraps the runtime in `LocalCompetitionCoordinator` (:683-1245). It is a fixture, not a reusable client:
  - `start()` (:727-783) creates a hard-coded "Alex" pending challenge (`bootstrapCompetitionID`, :745-770) when the store is empty.
  - Every presentation is named "Naren" vs "Alex" with identity `local-opponent:v1:default` (:1444-1446).
  - It takes HealthKit signal ownership for a random profile UUID and pumps `environment.signals()` (:951-980). On every publish it rewrites the process-wide summary subscriptions (:1073-1074), and `stop()` clears them (:912).
  - It publishes with `source: .simulatedFixture`.
- **The DEBUG Test Lab** (`CompetitionTestLabView.swift`, entirely `#if DEBUG`) builds `localFixture` over `.accelerated(source: FixtureActivitySource)`. `HealthCompApp` mounts it only in DEBUG with `--local-competition-test-lab` (HealthCompApp.swift:83-104). **Practice leaves all of this untouched.**
- **Release builds** have exactly one `competitionClient`: `CompetitionClient.live(provider:)` → `remote(...)` (RemoteCompetitionClient.swift:6-155). It has one publication stream, and every publication is `source: .remoteParticipants` (:1776-1800). The remote coordinator owns HealthKit signals per profile (`mount` :486-489, :565-569; `consume` → `performReconciliation` :1440-1493). It never calls `synchronizeSummarySubscriptions` (only the fixture and the environment wire it).
- **Notifications prompt:** `MainTabFeature.scheduleNotificationPromptIfDue` (MainTabFeature.swift:858-883) runs on every `.competition(.publication)` (:767) and schedules the prompt once any competition has `hasPerson(lifecycle)` (:904-913: pending/scheduled/active/endsToday/tallying). Not Now persists a deferral (:834-840) that later skips the prompt (:878-879).

**Can the local runtime run alongside the remote runtime in Release? The runtime can. `localFixture` can't.**
- A second `CompetitionClient` has nowhere to go: one dependency, one stream, one `source` per publication; Home, routing and Account read that single publication.
- `LocalCompetitionCoordinator` clashes with the remote client's HealthKit signal ownership (`HealthKitSignalOwnershipRegistry` / `HealthKitProviderSignalState`, process-global and single-owner, HealthKitProvider.swift:72-76, :647-845). Either it steals ownership (remote `mount` throws `EnvironmentSignalOwnershipError.activeOwnerNotRetired`, sign-in breaks) or runs signal-less; either way it creates "Alex" and overwrites the summary subscriptions.
- `LocalCompetitionRuntime` alone is safe beside the remote runtime if it is only driven through `reconcileAll` / `refreshAll`, never `handle`/`handleAll`. Then it only reads; `HKActivitySummaryQuery` reads are independent per caller.

**Why it is bigger than it looks**
1. `localFixture` can't be reused, so practice is composed into `RemoteCompetitionClientCoordinator`: a per-profile journal folder, refresh on every remote reconcile, its own wakes (day boundary, pacer checkpoints, leave-Home), merged into the one publication.
2. "About half your usual rings" can't be done with OpponentPlan v1 (fixed bands for everyone: relaxed 180–360, balanced 260–480, challenging 360–600, OpponentPlan.swift:587-608). PR A adds a baseline-scaled v2.
3. Every surface that assumes "a match = a real person" needs a practice branch: Home empty state and hero, rows, result screen, ••• menus, History, records, Account counts, mute and the notifications prompt.

**Smallest correct design (built below)**
- Host one extra `LocalCompetitionRuntime` inside the remote coordinator, store at `<profile>/PracticeEvents`, never taking signal ownership. It refreshes whenever the remote coordinator reconciles (launch, foreground, pull to refresh, observer wakeups, realtime) and at its own wakes.
- Merge practice presentations into the remote dashboard's `competitions`, never into `awards`.
- Tell practice apart by opponent identity `practice-pacer:v1`, so `LocalCompetitionPresentation` doesn't change.
- Skipped on purpose: practice notifications, summary subscriptions, History entries, "Practice Again", any server or migration work, Test Lab (`CompetitionTestLabView`) changes.

#### Scope
- **PR A (CompetitionCore):** `OpponentGeneratorVersion.v2`, which scales the pacer's daily final points to `baselineDailyPoints`. v1 output, canonical bytes and every existing golden stay unchanged.
- **PR B (app):**
  - start from the first-time empty Home through a pace sheet;
  - run on real HealthKit data in Debug, Staging and Release;
  - label the match Practice; allow one at a time; never take the hero from a real match;
  - End Practice from the ••• menu; delete a finished practice when it leaves Home;
  - leave practice out of History, records, awards, the belt and the recap, Account counts, mute, notifications and the notifications prompt;
  - one sentence in `web/privacy.html`;
  - add a MultiUser Test Lab scenario and tests.

#### Behavior and exact copy
Apostrophes in shipped copy are typographic (’), as everywhere in the app.

**1. Empty Home (remote source only)**, in `CompetitionSharingView.emptyState` (:318-366) and `emptyStateDescription` (:378-390)
- Title unchanged: "No matches yet", or "Nothing live right now" when `records` is non-empty.
- **"No matches yet" variant only** (`records.isEmpty`):
  - Description: **"Challenge someone to a 7-day match, or warm up against a pacer."** This replaces "Challenge someone to start a match."; no UI test asserts the old string.
  - Buttons, in order: "Challenge Someone" (PrimaryButtonStyle, `competition.create.empty`, unchanged), then **"Practice Match"** (SecondaryButtonStyle, id `competition.practice.open`, hint "Opens a practice match against a pacer").
- **"Nothing live right now" variant:** unchanged (description nil, only Challenge Someone). Finished practices never count as records (`competitionOpponentRecords` derives from `competitionHistoryWeeks`, :1814-1819), so a user who has only practiced still gets the first variant.
- The Practice button shows only when `publication.source == .remoteParticipants` and the host passes `practice`. The DEBUG local fixture never shows it.

**2. Pace sheet** (`PracticeMatchSheet`): `.sheet` with `.presentationDetents([.medium, .large])` and a grabber. Root id `competition.practice.sheet`.
- Title (`.title3.weight(.heavy).width(.condensed)`, header trait): **"Practice Match"**
- Line (subheadline, secondary): **"7 days against a pacer. It doesn’t count toward your record."**
- Three selectable rows in one `themePanel` with `CompetitionRowDivider`, `CompetitionRowButtonStyle`, min height 44:

  | id | Title | Detail |
  |---|---|---|
  | `competition.practice.pace.relaxed` | "Relaxed" | "About half your usual rings" |
  | `competition.practice.pace.balanced` (default selection) | "Balanced" | "About your usual rings" |
  | `competition.practice.pace.challenging` | "Challenging" | "A bit more than usual" |

  - Trailing mark: `checkmark.circle.fill` in `Theme.ink` when selected, `circle` in `Theme.tertiary` otherwise. This differs from the mockup's amber dot on purpose (owner question; amber stays reserved for you).
  - VoiceOver: label "Relaxed, About half your usual rings"; the selected row adds `.isSelected`.
- Pinned primary: **"Start Tomorrow"** (PrimaryButtonStyle, id `competition.practice.start`). Pinned with `safeAreaInset(edge: .bottom)`, inline at accessibility sizes (same pattern as `CompetitionResultView` :74-96).
  - In flight: a `ProgressView`, disabled, `accessibilityValue("Action in progress")`.
- On failure, above the button (callout, secondary, id `competition.practice.error`): **"Couldn’t start the practice match. Try again."** Shown only after a Start tap **in this presentation of the sheet** (sheet-local `@State hasAttempted`, set on tap, reset in `onAppear`), because `.commandRejected(startCommandID)` lingers in `dashboard.issues` until the next full publish (`publication(adding:)`, RemoteCompetitionClient.swift:935-950). A reopened sheet never shows a stale error.
- On success the sheet closes. Home then shows the scheduled practice as the hero, because nothing else is live.

**3. Home with a practice match**
- **Placement:** `competitionHomeLayout` (:1645-1649) changes so **a practice is never the hero while any real (non-practice) match is live or scheduled**:
  - hero candidates are real live matches first (if exactly one), then, with no real live match, the soonest real scheduled match;
  - only when no real live/scheduled match exists does today's rule apply to practice (single live → hero; none live → soonest scheduled);
  - a practice that isn't the hero goes to `live` (as an equal card under "LIVE") or `upNext` as today.
  - Examples: practice alone → hero. Live practice + real scheduled → real scheduled is the hero, practice is a LIVE card. Live practice + real live → two equal cards under "LIVE · 2" (unchanged). Done → Recent results.
- **Label:** every non-notification status title gets the prefix **"Practice · "**:
  - Card: "Practice · Day 2 of 7" + "Ends Sun night".
  - Scheduled card: "Practice · Scheduled" + "Starts Tue".
  - Row line: "Practice · Day 2 of 7 · Ends Sun night".
  - Result row: "Practice · You won · Oct 24 – 30".
  - The VoiceOver summary follows, because it is built from `competitionHomeStatusLine`. Cards keep the existing LIVE dot.
- **Name:** the other side is **"Pacer"**: "You 486 / Pacer 452", lead line "You lead by 34." from the existing helpers. Navigation title: "Pacer".
- **Pacer moves while Home is open:** the coordinator also republishes at the next pacer checkpoint (see Design), so "Pacer 452" doesn't freeze for hours in the foreground.
- **Challenge Someone stays in view:** when Home is not empty and **every** item on it is practice, a full-width **"Challenge Someone"** button (**SecondaryButtonStyle**, as in the mockup's `btn2`; id `competition.practice.challenge`) appears below the groups. It opens the same Challenge sheet as `competition.create.empty`.
- **Practice result rows** in Recent results: the plain row, with no swipe-to-Archive and no "Moves to History" caption. The row leaves Home by `competitionResultLeavesHome`, and at that moment the journal is deleted (§6).

**4. Practice match screen** (`CompetitionDetailView`)
- Works as today with `source: .simulatedFixture`; `source` only feeds the rules drawer (CompetitionDetailView.swift:141), which then shows the existing "Nothing leaves this iPhone" / "Pacer is simulated." row (CompetitionInviteView.swift:460-466).
- No Mute row, no Cancel Match.
- ••• menu (`competition.more`, unchanged id) adds **"End Practice"** (role destructive, systemImage `xmark.circle`, id `competition.practice.end`). It opens a confirmation dialog:
  - title **"End this practice match?"**, title visible;
  - buttons **"End Practice"** (destructive) and **"Keep Going"** (cancel);
  - message **"It’s removed from this iPhone."**
- Confirming deletes the journal. The next publication drops the id, and `MainTabFeature` filters the path (:388-391, :735-736), so the screen pops to Home.

**5. Practice result screen** (`CompetitionResultView`)
- Rendered with **`source: .remoteParticipants`**, so `competitionFixtureDisclosure` (CompetitionInviteView.swift:478-484) adds no "Pacer is simulated on this iPhone." line.
- Kicker: **"Practice · Final · Oct 24 – 30"** (`resultKicker`, :174-178, prepends "Practice" for practice). Title and score as today ("You beat Pacer", "Pacer won", "All square with Pacer").
- No ••• menu: no Archive, Delete or Mute (`hasMenuActions` false for practice). No awards.
- The pinned control is **"Challenge Someone"** (PrimaryButtonStyle, id `competition.practice.challenge`) in place of Rematch: the screen's one action. It pops to Home and opens the Challenge sheet.

**6. Everywhere else**
- History weeks, the record and the Home History button: practice is never counted.
- Awards: none. Belt and recap highlights: none.
- Account sign-out live count: excluded. Muted people: never listed.
- Notifications: none, and the notifications permission prompt ignores practice (it waits for a real match).
- **Retention:** a completed practice journal (exact daily Health values and plan) is deleted on the first practice refresh at or after `competitionResultLeavesHome`. `nextWake` already wakes at that moment (LocalCompetitionRuntime.swift:417-424), so no Health values linger out of sight.

**Edge cases**
- **One at a time:** Start is refused while a practice is scheduled, live or tallying. It is only reachable from the empty Home anyway. Starting deletes any finished or broken practice journal first.
- **Interrupted start** (crash between genesis and accept): the pending journal is never shown, and the next Start deletes it.
- **Health read denied or empty:** days read "no data" and score 0, as in a real match. The baseline falls back to 300.
- **Offline:** practice still refreshes, because it never touches the network.
- **A real match starts or arrives:** both are shown, the real one takes the hero, and the practice-only Challenge button goes away.
- **Time zone change:** the schedule's calendar is fixed at start, as for a real match. Times show a zone suffix through the existing `zone(_:)`.
- **Sign-out or account deletion:** removed with the profile folder.
- **Reinstall or second device:** none ("on this phone only").
- **Dynamic Type AX5:** the sheet scrolls, its rows wrap without a `lineLimit`, and the Start button goes inline.

#### Design: PR A, CompetitionCore (`feature/practice-pacer-v2`)
`Modules/CompetitionCore/Sources/CompetitionCore/OpponentPlan.swift`
- `OpponentGeneratorVersion`: add `public static let v2 = Self(rawValue: 2)`.
- `OpponentPlanError`: add `case invalidBaseline(Int?)`.
- `OpponentPlanGenerationRequest` (:424-438): add `public let baselineDailyPoints: Int?`; the init gets the trailing parameter `baselineDailyPoints: Int? = nil`. Stays `Codable`; the request is never persisted.
- `OpponentPlanGenerator.generate` (:441): add the trailing parameter `baselineDailyPoints: Int? = nil`. Replace the guard at :447-451:
  - `.v1`: a non-nil baseline throws `.invalidBaseline(baseline)`; with nil, output is byte-identical to today.
  - `.v2`: requires `baselineDailyPoints` in `100...600`, otherwise throws `.invalidBaseline(baseline)`.
  - Any other version still throws `unsupportedGeneratorVersion`.
- New `private extension OpponentDifficulty { func versionTwoPolicy(baseline: Int) -> OpponentDifficultyV1Policy }`:
  - Same checkpoint counts and curves as v1.
  - `finalPoints = clamp(round(B×lo), 0, 600)...clamp(round(B×hi), 0, 600)`: relaxed 0.45–0.60 (lateBuild, 6...8); balanced 0.90–1.10 (linear, 7...9); challenging 1.10–1.30 (earlyBuild, 8...10).
  - Example: B = 400 → relaxed 180...240, balanced 360...440, challenging 440...520. B = 600 → challenging 600...600.
- **No Codable or canonical-bytes change.** The plan stores every day's final points and checkpoints and `commitmentHex` covers them. `OpponentPlan.init` already accepts non-v1 generators with structural validation (`OpponentDayPlan` 0...600, :249-263). v1 commitments and `testBalancedGoldenPlan…` are untouched.

`CompetitionEngine.swift:42-47`: pass `baselineDailyPoints: request.baselineDailyPoints` to `generate`.

#### Design: PR B, app (`feature/practice-match`)

**New `HealthComp/Features/Competition/PracticeMatch.swift`** (app target; uses Foundation, CompetitionCore and app types such as `LocalCompetitionRuntime`, `CompetitionEnvironmentClient`, `ActivityWindowRead`, `LocalCompetitionDashboard`; no SwiftUI; compiles in Release)
```swift
enum PracticeMatch {
    static let opponentDisplayName = "Pacer"
    static let opponentIdentity = "practice-pacer:v1"
    /// In-flight and rejection key for Start. Never a journal id.
    static let startCommandID = CompetitionID(UUID(uuidString: "5A3C0000-0000-4000-8000-000000000001")!)
    static let fallbackBaselineDailyPoints = 300
    static let baselineRange = 100...600
    static let minimumRevealInterval: TimeInterval = 300
}
enum PracticeMatchError: Error { case alreadyUnderway, storageUnavailable }
extension LocalCompetitionPresentation { var isPractice: Bool { opponentIdentity == PracticeMatch.opponentIdentity } }
```
- **`static func baselineDailyPoints(_ reads: [ActivityWindowRead]) -> Int`** (pure): score every `.snapshot` with `ActivityScoreCalculator.score(_, policy: .healthKitCompatibility).availableScore?.points`, capped at 600. Fewer than 3 scored days → 300. Otherwise the rounded mean, clamped to `baselineRange`.
- **`static func readLastTwoWeeks(environment:context:) async -> [ActivityWindowRead]`:** `CompetitionCalendar(timeZoneIdentifier: context.timeZoneIdentifier)`; Foundation `Calendar(identifier: .gregorian)` in that zone for start of today minus 14 and minus 7 days, then `day(containing:)`; two `CompetitionActivityWindow`s, `try? await environment.read(_)` each (a failure is skipped). No `day(before:)` needed in core.
- **`static func start(_ difficulty: OpponentDifficulty, runtime: LocalCompetitionRuntime, environment: CompetitionEnvironmentClient) async throws -> CompetitionID`:**
  1. `loadAll()`. An enumeration failure throws `.storageUnavailable`.
  2. Any journal in `.scheduled/.active/.endsToday/.tallying` throws `.alreadyUnderway`.
  3. `try? await runtime.delete(competitionID:)` every other journal and every failed id.
  4. `context = await environment.context()`; baseline from `readLastTwoWeeks`.
  5. `id = CompetitionID(UUID())`, then `try await runtime.create(try CompetitionGenesis(competitionID: id, direction: .outgoing, createdAt: now, expiresAt: nil, scoringPolicy: .healthKitCompatibility, downwardRevisionPolicy: .maximumObserved))` (`CompetitionGenesis.init` throws, CompetitionEventStore.swift:22-29).
  6. `try await runtime.accept(competitionID: id, opponent: OpponentPlanGenerationRequest(seed: .random(in: .min ... .max), generatorVersion: .v2, difficulty: difficulty, baselineDailyPoints: baseline))`.
  7. Return `id`.
- **`static func nextPacerReveal(journals: [LoadedCompetitionJournal], now: Date) -> Date?`** (pure): for each active/endsToday practice journal, take today's day window `[start, end)` from its schedule calendar and the plan day's checkpoints; the first `start + progressBasisPoints/10_000 × (end − start)` after `now`, raised to at least `now + minimumRevealInterval`. Min over journals; nil when none.
- **`static func expiredResults(journals:now:) -> [CompetitionID]`** (pure): completed practice journals with `competitionResultLeavesHome(schedule:completedAt:)?.at <= now`.
- **`extension LocalCompetitionDashboard { func addingPractice(_ practice: [LocalCompetitionPresentation]) -> Self }`:** concatenate into `competitions`, sorted by uuid string as both projectors do. Leave `awards`, `issues` and the hidden count unchanged.

**`LocalCompetitionClient.swift`**
- `LocalCompetitionProjector.presentation(from:context:configuration:)` (:1397): add defaulted `ownerDisplayName: String = LocalCompetitionIdentity.ownerDisplayName`, `opponentDisplayName: String = LocalCompetitionIdentity.opponentDisplayName`, `opponentIdentity: String = LocalCompetitionIdentity.opponentIdentity`; use them at :1444-1446. Fixture output doesn't change.
- New `static func practicePresentations(journals:context:configuration:ownerDisplayName:) -> [LocalCompetitionPresentation]` next to `dashboard` (:1248): maps with the Pacer identity, keeps `.scheduled, .active, .endsToday, .tallying, .completed`; drops pending, closed and archived.

**`CompetitionClient.swift`**: new endpoint `var startPractice: @Sendable (OpponentDifficulty) async -> CompetitionPublication`. The init parameter defaults to `{ _ in .inert }`, so `localFixture`, `closed` and the test stubs don't change.

**`AuthenticatedProfileStorage.swift`** (:12-69): add `let practiceEventsDirectory` = `rootDirectory/PracticeEvents`, appended **last** in `fixedDirectories`. `mount()` creates it on upgrade (:196-200); `teardown` removes it with the root.

**`RemoteCompetitionClient.swift`**, `RemoteCompetitionClientCoordinator`
- State (:430-450): `practiceRuntime: LocalCompetitionRuntime?`, `practiceJournals: [LoadedCompetitionJournal] = []`, `practiceIssues: [CompetitionClientIssue] = []`.
- `mount` (after `self.runtime = runtime`, :537): `practiceRuntime = LocalCompetitionRuntime(environment: environment, store: JSONCompetitionEventStore(rootDirectory: paths.practiceEventsDirectory))`; reset journals and issues.
- `stopRuntime` (:1373-1409): `practiceRuntime = nil`, clear `practiceJournals` and `practiceIssues`.
- New `private func refreshPractice(_ trigger: ActivityRefreshTrigger) async`:
  - `outcome = await practiceRuntime.reconcileAll(trigger:)`. **Never `handleAll`**: the remote coordinator keeps completing observer deliveries.
  - `practiceJournals = await practiceRuntime.loadAll().successfulJournals`.
  - For each id in `PracticeMatch.expiredResults(journals: practiceJournals, now: context.instant.wallClock)`: `try? await practiceRuntime.delete(competitionID:)`; reload `practiceJournals` if any were deleted.
  - `practiceIssues = outcome.failures.isEmpty ? [] : [.competitionFailures(sorted ids)]`.
- `performReconciliation` (:749-796): `await refreshPractice(.reconciliationProbe)` after `runtime.synchronizeAll()`, before `publish`. The no-runtime guard path is unchanged.
- `publish(materializations:profile:issues:knownCompetitionIDs:)` (:1693-1739):
  - dashboard built with `issues + practiceIssues`, then `.addingPractice(LocalCompetitionProjector.practicePresentations(journals: practiceJournals, context: context, configuration: .live, ownerDisplayName: profile.displayName))`, then `.keepingFailedCompetitions`.
  - `scheduleBoundaryRepublish(at:)` (:1741) gets the min of `nextHomeBoundary`, `await practiceRuntime?.nextWake(in: practiceJournals, context: context)` and `PracticeMatch.nextPacerReveal(journals: practiceJournals, now:)`.
  - Notification snapshot, `knownCompetitionIDs` and `mountedCompetitionIDs` stay remote-only.
- `republishAtBoundary` (:1757-1774): `await refreshPractice(.dayBoundary)` before re-publishing (this also covers checkpoint wakes; one local read at most every 5 min). Extract the body into `private func republishLastInputs() async -> CompetitionPublication`, falling back to `performReconciliation()` when `lastPublishInputs == nil`.
- New `func startPractice(_ difficulty:) async -> CompetitionPublication` under `withOperationGate`:
  - `guard terminalTeardown == nil else { return terminalBlockedPublication() }`.
  - If `!hasStarted || practiceRuntime == nil`, or `PracticeMatch.start` throws, return `publication(adding: .commandRejected(PracticeMatch.startCommandID))`.
  - Otherwise `await refreshPractice(.reconciliationProbe); return await republishLastInputs()`. No network call.
- New `func endPractice(_ id:) async -> CompetitionPublication` under `withOperationGate`:
  - `guard terminalTeardown == nil else { return terminalBlockedPublication() }` (as `unsupported(_:)` does today, :852-861).
  - If the id isn't in `practiceJournals`, return `unsupported`-equivalent `publication(adding: .commandRejected(id))` (real matches stay rejected exactly as today). If delete throws, the same.
  - Otherwise `practiceRuntime.delete(competitionID:)`, reload `practiceJournals`, `republishLastInputs()`.
- `remote(...)` (:89): `delete: { id in await coordinator.endPractice(id) }` replaces `unsupported(id)`; add `startPractice: { await coordinator.startPractice($0) }`.

**`CompetitionFeature.swift`**
- New `Action.practiceStartTapped(OpponentDifficulty)`: `guard state.commandIDsInFlight.insert(PracticeMatch.startCommandID).inserted`; `.run { send(.commandFinished(PracticeMatch.startCommandID, expectedRevision: await competitionClient.startPractice(d).publicationRevision)) }` — the same pattern as `.reinviteTapped` (:636-648).
- End Practice reuses `.deleteTapped(id)` (:650-662). No new action.

**`MainTabFeature.swift`**
- `scheduleNotificationPromptIfDue` (:858-883): the guard becomes `dashboard.competitions.contains(where: { !$0.isPractice && Self.hasPerson($0.lifecycle) })`. Update the doc comment: "once a match with a person (not a practice) exists".

**New `HealthComp/Features/Competition/PracticeMatchSheet.swift`** (SwiftUI)
- `struct CompetitionPracticeStart { let isStarting: Bool; let failed: Bool; let start: (OpponentDifficulty) -> Void }`, in the style of `CompetitionCancelMatch` (CompetitionDetailView.swift:1120).
- `struct PracticeMatchSheet: View` with `@State selection: OpponentDifficulty = .balanced`, `@State hasAttempted = false` (set on Start, reset `onAppear`); the error shows when `hasAttempted && practice.failed && !practice.isStarting`.

**`CompetitionSharingView.swift`**
- `CompetitionHomeLayout` (:1545): add `var allItems: [LocalCompetitionPresentation] { [hero].compactMap { $0 } + needsYou + live + upNext + recentResults }`; `attributedIDs` (:172-178) uses it and also inserts `PracticeMatch.startCommandID`, so a start failure doesn't duplicate as a banner.
- `competitionHomeLayout` hero choice (:1645-1649) per Behavior §3.
- New property `var practice: CompetitionPracticeStart? = nil`, `@State private var isPracticePresented = false`.
- Empty state: Practice Match button and new description only when `records.isEmpty` (Behavior §1; :335-390).
- `.sheet(isPresented: $isPracticePresented) { PracticeMatchSheet(...) }`; `.onChange(of: practice?.isStarting)`: on true → false with `failed == false`, close the sheet.
- Practice-only button after the Recent results group: `if !layout.allItems.isEmpty, layout.allItems.allSatisfy(\.isPractice) { Button("Challenge Someone") { isChallengePresented = true }.buttonStyle(SecondaryButtonStyle()).accessibilityIdentifier("competition.practice.challenge") }`.
- `resultRow` (:231-251): `if competition.isPractice`, return `competitionButton(competition) { CompetitionSharingRow(...) }` with no swipe and no caption.
- `competitionStatusText(_ competition:style:locale:timeZone:)` (:1328-1355): when `competition.isPractice && style != .notification`, title "Practice · \(title)", including the tallying branch.
- `competitionHistoryWeeks` (:1797): filter `!$0.isPractice` (record, History and History button derive from it).

**`CompetitionDetailView.swift`**
- New `var endPractice: (() -> Void)? = nil`, `@State showsEndPracticeConfirmation`.
- Menu item after "How scoring works" (:88-120) and the confirmation dialog, as in Behavior §4.
- `competitionMuteIdentity` (:516): nil when `competition.isPractice`.

**`CompetitionResultView.swift`**
- New `var challengeSomeone: (() -> Void)? = nil`.
- `resultKicker` (:174-178): `[competition.isPractice ? "Practice" : nil, "Final", weekRangeText, isMuted ? "Muted" : nil]`.
- `hasMenuActions` (:734): `!competition.isPractice && (…today…)`.
- `rematchControl` (:471): `if competition.isPractice` shows Challenge Someone (PrimaryButtonStyle, `competition.practice.challenge`), or nothing when the closure is nil.

**`MainTabView.swift`**
- Pass `practice: publication.source == .remoteParticipants ? CompetitionPracticeStart(isStarting: store.competition.isCommandInFlight(PracticeMatch.startCommandID), failed: publication.dashboard.issues.contains(.commandRejected(PracticeMatch.startCommandID)), start: { store.send(.competition(.practiceStartTapped($0))) }) : nil` into `CompetitionSharingView` (:98-133).
- `destination(for:)` (:253-330), when `competition.isPractice`:
  - `.scheduled, .active, .endsToday, .tallying`: `source: .simulatedFixture`, `muteButton: nil`, `cancelMatch: nil`, `endPractice: { store.send(.competition(.deleteTapped(id))) }`.
  - `.completed, .archived`: `source: .remoteParticipants`, `muteButton: nil`, `challengeSomeone: { store.send(.pathChanged([])); isChallengePresented = true }`.

**`AccountSettingsView.swift`**: `accountLiveMatchCount` (:75) filters `!$0.isPractice`.

**`web/privacy.html`**: in the "Activity on your iPhone" item (:43-48), after the first sentence add "A practice match also reads your last 2 weeks of Activity on your iPhone to set the pacer; practice data is never sent." Move "Effective date" (:33) to the ship date.

**`MultiUserCompetitionTestLabView.swift`** (DEBUG)
- `MultiUserCompetitionTestLabScenario` (:8-30): add `case practice`.
- `scenarioView` (:120-152): add `case .practice: MultiUserCompetitionPracticeTestLabView()`.
- `MultiUserCompetitionClaimTestLabView.init` (:404-411): add `.practice` to the `.ready` list (the switch is exhaustive).
- `MultiUserCompetitionTestLabFixtures` (:642): add a non-private `static func practicePresentation() -> LocalCompetitionPresentation` that calls the private `presentation(...)` (:849) with id `A1000000-0000-4000-8000-00000000000C`, `opponentName: "Pacer"`, `opponentIdentity: PracticeMatch.opponentIdentity`, `.active(dayOrdinal: 2)`, userPoints 486, opponentPoints 452.
- `MultiUserCompetitionPracticeTestLabView`: starts with an empty `.remoteParticipants` publication; Start waits 80 ms, then shows `practicePresentation()`; its destination passes `endPractice`, which clears it.
- Add `practice` to the UI-test `Scenario` enum (MultiUserCompetitionUITests.swift:1333-1348).

**`project.yml`: no change.** `sources: - path: HealthComp` and `- path: HealthCompTests` pick up the new files. Regenerate `HealthComp.xcodeproj/project.pbxproj` with XcodeGen 2.46.0 on the Mac mini and commit it; CI's determinism step (ci.yml:72-89) checks it. `HealthCompStagingTests` lists files explicitly; `PracticeMatchTests` is not added there (uses DEBUG-only `FixtureActivitySource`).

**APIs:** all iOS 16 or earlier (`presentationDetents`, `confirmationDialog`, `safeAreaInset`). No `#available`. `CompetitionDateFormatting.swift` untouched.

#### Data flow
- **Start:** empty Home → sheet → `practiceStartTapped(d)` → `CompetitionClient.startPractice` → coordinator `startPractice` → `PracticeMatch.start` (reads 14 days on the phone → baseline → genesis → accept v2) → `refreshPractice` → `republishLastInputs` → hub → `CompetitionFeature.publication` clears the in-flight start → sheet closes, practice hero appears. `MainTabFeature` sees only a practice and schedules no notifications prompt.
- **Ongoing refresh:** every remote reconcile and every boundary republish (practice `nextWake` or next pacer checkpoint, ≥ 5 min apart) → `practiceRuntime.reconcileAll` → HealthKit read → journal (expired results deleted) → projected beside the remote matches.
- **Health values** stay in `<profile>/PracticeEvents` with the same file protection as `CompetitionEvents`. Nothing is sent.

#### Accessibility identifiers
- **Added:** `competition.practice.open`, `competition.practice.sheet`, `competition.practice.pace.relaxed`, `competition.practice.pace.balanced`, `competition.practice.pace.challenging`, `competition.practice.start`, `competition.practice.error`, `competition.practice.challenge` (Home secondary button and result pinned control; never on screen together), `competition.practice.end`.
- **Unchanged:** `competition.create.empty`, `competition.more`, `competition.sharing.<lifecycle>.<uuid>` (the practice card uses it too), `competition.history.open`, `competition.rivalry`.
- **Removed:** none.

#### Glossary (add to the audit spec §5)
- **Practice / practice match**: a solo week against the pacer. Don't say test match, solo mode or bot.
- **Pacer**: the practice opponent's display name. Don't say AI, computer or simulated opponent. The only exception is the existing rules row "Pacer is simulated." on the match screen; the result screen has no simulated line.

#### Tests
**CompetitionCore**, `OpponentPlanTests.swift` (swift test, Debug and Release)
- `testVersionTwoScalesDailyFinalsToTheBaselinePerDifficulty`: B = 400, seeds 0..<64; every day's `finalPoints` in 180...240, 360...440, 440...520; checkpoint counts follow the v1 bands.
- `testVersionTwoClampsToSixHundredAndRejectsMissingOrOutOfRangeBaseline`: B = 600 challenging → all days 600; nil, 99, 601 throw `.invalidBaseline`.
- `testVersionOneRejectsBaselineAndKeepsItsGolden`: v1 with baseline 300 throws `.invalidBaseline(300)`; v1 with nil equals today's output; `testBalancedGoldenPlanPinsTargetsCheckpointsAndCommitment` passes unchanged.
- `testVersionTwoPlanRoundTripsThroughCodable`.
- `testAcceptanceWithVersionTwoRequestCarriesTheScaledPlan` (engine.accept).

**HealthCompTests/PracticeMatchTests.swift** (new)
- `testBaselineAveragesScoredDaysOverTwoWeeks`, `testBaselineFallsBackTo300WithFewerThanThreeScoredDays`, `testBaselineClampsTo100And600`.
- `testStartCreatesOneScheduledV2PracticeStartingTomorrow` (temporary `JSONCompetitionEventStore`, `.accelerated(source:)`).
- `testStartRefusesWhileAPracticeIsUnderwayAndReplacesAFinishedOne`.
- `testStartDeletesAPendingPracticeLeftByAnInterruptedStart`.
- `testPracticePresentationsUsePacerIdentityAndHidePendingJournals`.
- `testNextPacerRevealIsTheNextCheckpointAndAtLeastFiveMinutesOut`.
- `testExpiredResultsListsACompletedPracticePastItsLeaveHomeTime`.

**HealthCompTests/RemoteCompetitionClientTests.swift**
- `testPracticePublishesBesideRemoteMatchesWithoutServerCalls`: list-call probe count unchanged by `startPractice`; one `isPractice` presentation named "Pacer"; `awards` empty.
- `testPracticeRefreshesOnReconcileAndAdvancesAtDayBoundary`.
- `testEndPracticeDeletesOnlyPracticeAndOtherDeletesStayRejected` (through `client.delete`, the production path).
- `testEndPracticeAfterTeardownIsTerminalBlocked`.
- `testFinishedPracticeIsDeletedWhenItLeavesHome`.
- `testPracticeNeverReachesTheNotificationSnapshot`.
- `testPracticeDoesNotTakeSignalOwnership`: observer signals still complete through the remote path while a practice exists.

**Other existing test files**
- `AuthenticatedProfileStorageTests.swift` :54-63: add "PracticeEvents" to the expected list.
- `CompetitionPresentationTests.swift`: `testPracticeStatusIsLabeledOnCardsRowsButNotNotifications`; `testHistoryWeeksAndRecordsLeavePracticeOut`; `testAccountLiveMatchCountLeavesPracticeOut`; `testMuteIdentityIsNilForPractice`; `testHomeLayoutMakesAPracticeTheHeroOnlyWhenAlone` (practice alone → hero; live practice + real scheduled → real hero, practice in `live`; scheduled practice + real scheduled → real hero).
- `CompetitionFeatureTests.swift`: `testPracticeStartTracksTheCommandUntilItsPublication` (stub returns revision 5; start id in flight until publication 5); `testEndPracticeSendsDelete`.
- `MainTabFeatureTests.swift` (next to `testNotificationPromptWaitsForLiveOrPendingMatchThenDefersOnNotNow`, :701): `testNotificationPromptWaitsForARealMatchNotAPractice` — a publication holding only an active practice leaves `notificationPrompt == .unscheduled`; adding a real scheduled match schedules it.

**UI**, `MultiUserCompetitionUITests.swift`: new `testPracticeMatchStartsFromEmptyHomeAndEndsFromTheMenu`.
1. Launch `.practice`. "No matches yet" shown. Tap `competition.practice.open`.
2. `competition.practice.pace.balanced` is selected; `competition.practice.error` does not exist. Tap `.challenging`, then `competition.practice.start`.
3. On Home, a `sharingCard(state: "active", name: "Pacer")` whose label contains "Practice · Day 2 of 7", and `competition.practice.challenge` exists.
4. Open the card. Tap `competition.more`, `competition.practice.end`, then "End Practice".
5. Back on Home, "No matches yet" shown.
6. `performAccessibilityAudit` on the sheet and on the practice Home.

Add it to the `-only-testing` list in `.github/workflows/ci.yml` (:212-228).

**Known coverage gap (accepted):** the Test Lab builds its own Home and destinations (MultiUserCompetitionTestLabView.swift:167-330), so the UI test does not drive `MainTabView.destination(for:)`, `CompetitionFeature.deleteTapped` or the remote `delete → endPractice` path. Those are covered by the unit tests above (client endpoints, feature in-flight tracking, MainTab prompt) and by the Staging walkthrough in owner actions; the view wiring in `destination` is checked in the preview captures.

#### Verify on the Mac mini (`ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini`, in `~/dev-desktop`)
1. `xcodegen generate && git status --short HealthComp.xcodeproj`: commit the regenerated pbxproj, run again, expect no diff.
2. `swift test --package-path Modules/CompetitionCore` and `swift test --configuration release --package-path Modules/CompetitionCore`.
3. `xcodebuild test -scheme HealthComp -destination 'platform=iOS Simulator,name=iPhone 16 Pro' -only-testing:HealthCompTests` and both UI suites. The new UI test passes at default size and AX5.
4. `xcodebuild build -scheme HealthComp -configuration Release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO`: practice compiles in Release with no DEBUG symbols.
5. Simulator captures for the preview artifact: empty Home, sheet, practice hero, ••• menu with End Practice, practice result with the "Practice · Final" kicker, in light and dark at XS and AX5.
6. Website: serve `web/` locally (wrangler Pages emulation) and check the privacy page renders.
7. Optional on the Linux VM: docker `swiftc -parse` on the new files.

#### Risks and conflict regions
- **HealthKit signal ownership:** practice must never call `handle`/`handleAll` or `environment.signals()`. Enforced by `testPracticeDoesNotTakeSignalOwnership` and the Staging device check.
- **Latency:** each remote reconcile adds one local HealthKit read (a few ms); checkpoint republishes add at most one read per 5 min while a practice is live and the app runs. Background observer wakeups still complete after the publish (:1494).
- **Shared files with other features this round:**
  - `CompetitionSharingView.swift`: emptyState :318-390, resultRow :231, `competitionHomeLayout` :1645, `competitionHistoryWeeks` :1797. Belt and recap must build on `competitionHistoryWeeks` or check `isPractice`.
  - `CompetitionDetailView.swift`: ••• menu :88-120.
  - `CompetitionResultView.swift`: `resultKicker`, `rematchControl`, menu. The recap card must skip practice.
  - `RemoteCompetitionClient.swift`: `publish`, `republishAtBoundary`. Widget and Live Activity features read the same dashboard and should check `isPractice`; default is to leave practice out of Live Activities.
  - `MainTabFeature.scheduleNotificationPromptIfDue`, `MainTabView.destination`.
- **Backups:** practice journals sit beside the remote journals; neither is excluded from device backups (no `isExcludedFromBackup`), so no new kind of exposure. Finished practices are deleted when they leave Home.

#### Rollout and compatibility
- App plus a static privacy-page sentence: no migration, Edge Function or Staging step. Publish the privacy page before the TestFlight build that contains practice.
- Installed 1.0.2 builds and server contracts are unaffected.
- On upgrade, `mount()` creates `PracticeEvents`. A downgrade ignores it.
- PR A merges first; PR B rebases onto it.

#### Review notes
All reviewer issues were checked against 8c5ca25. Applied: notifications prompt ignores practice (raised twice; confirmed at MainTabFeature.swift:858-913, and Not Now defers it, :834-840); Test Lab compile fixes (private `presentation` :849, exhaustive switches :120-152, :404-411); pacer checkpoint republish (`revealedPoints` is a step function, `nextWake` has no checkpoints); sheet-local error flag (`publication(adding:)` carries the issue forward); result screen uses `.remoteParticipants` with a "Practice · Final" kicker, so it shows no simulated line; owner device check is Staging-only (`#if HEALTHCOMP_STAGING`); v1 with a baseline throws; `try CompetitionGenesis`, a named `layout.allItems`, the wrong "Foundation only" claim dropped, and a `terminalTeardown` guard on `endPractice` and `startPractice`; Home Challenge Someone is secondary as in the mockup; hero rule corrected and decided; finished practices deleted when they leave Home; privacy-page sentence; Practice Match only in the "No matches yet" variant. Partly applied: the UI-test coverage gap is accepted and named, with unit tests and a Staging walkthrough in place of a new `competitionDestinationKind` helper, which would add an abstraction for one switch. Kept but raised as an owner question: the ink selection mark instead of the mockup's amber. Nothing rejected outright.

#### Owner actions for this feature (merged into §7)
- Approve the preview artifact (Mac mini captures of the empty Home with Practice Match, the pace sheet, a live practice hero with Challenge Someone under it, the practice match screen's ••• menu and a practice result with the "Practice · Final" kicker, in light and dark at XS and AX5) before the PR opens.
- On a physical iPhone running a Staging build (the delivery diagnostic logs only under HEALTHCOMP_STAGING) with a real match live: start a practice, lock the phone, walk, and confirm in the Staging diagnostics that background observer deliveries still complete (completion_called keeps appearing). This proves practice doesn't take HealthKit signal ownership from real matches.
- On the same Staging build, walk the production wiring the UI test can't reach: start a practice from the empty Home, confirm no notifications prompt appears, open it, End Practice, and confirm the screen pops to Home.
- Answer the Practice owner questions (pacer v2, notifications, History, entry points, sign-out, baseline floor, selection mark, hero rule, privacy page). Every default is already built into this spec.
- Publish the updated web/privacy.html (Cloudflare Pages deploy of web/) before the TestFlight build that contains practice.

### 9.10 PR 13: Notification choices

Branches: `feature/notification-choices` · Server: yes · Size: M · Stakes: none

#### Integration amendments (override the text below)
- **Six rows, not seven.** This PR ships DURING A MATCH: Lead changes, Close scores, Last day, Live Activity; FROM THE OTHER PERSON: Reactions, Nudges. PR 14 adds "What it takes" afterwards (one enum case, one mapping line, test updates; PR 14 amendments). Every mention of the Takes family below, in `CompetitionNotificationChoice`, `choice`, the tests and the UI assertions, moves to PR 14. Q-notifs-6 (build order) is answered by §6; Q-notifs-7 is merged into Q-takes-1.
- **Dependencies:** PRs 5, 7 and 10 merged, PR 9's migration in production. The register overload this PR extends is PR 9's 5-argument one (`…, supports_challenges, supports_reactions`), so the new overload has six arguments and the app's fallback chain is 6 → 5 → 4 → 3. Migration `20261103002800`, count 29 → 30, pgTAP `026`.
- **Lease lineage.** Copy PR 4's lease body (the newest). PR 9 adds no lease branch: reactions are capability-gated at enqueue (`supports_reactions`), so "the Reactions capability gate in the branch above" means PR 4's nudge discard arm and 2300's challenge gate; 'suppressed' for a switched-off kind applies at lease time and also catches reaction or nudge rows already pending when the switch turns off.
- **Live Activity row** absorbs PR 7's iOS-off handling: when `ActivityAuthorizationInfo().areActivitiesEnabled` is false (observed with `activityEnablementUpdates` in a `.task`), the toggle is `.disabled(true)` and the row is followed by the caption "Live Activities are off for HealthComp in iOS Settings." and an "Open Settings" button (`UIApplication.openSettingsURLString`, `.frame(minHeight: 44)`, id `account.notifications.live-activity.settings`). Id of the toggle is `account.notifications.choice.live-activity` (PR 7's `account.notifications.live-activity` is never shipped).
- **J (Live Activity gate).** Set `CompetitionLiveActivityClient.live.isAllowed` to `ActivityAuthorizationInfo().areActivitiesEnabled && !CompetitionNotificationChoice.switchedOff().contains(.liveActivity)`. No separate "Live end call" in F: `reconcileNotifications()` already calls `liveActivities.reconcileLatest()` (PR 7), whose planner ends every activity with `forgetStart: true` when not allowed.
- **Reactions row** raw value `reaction` (PR 9's work kind). PR 10 ships no switch of its own and no `healthcomp.notifications.reactions` key, so there is nothing to adopt.
- **Glossary and privacy page:** the privacy line lands in the same deploy rules as §3.

#### PR scope
- `feature/notification-choices`: One PR, following the precedent of #189 (a migration plus the app change, with server-first release order). Lands last, in the owner's build order, after What it takes, Nudge, Live Activity and Reactions. App: the full Account → Notifications page from the mockup, with 6 on-device switches in two sections (DURING A MATCH: Lead changes, Close scores, Last day, Live Activity; FROM THE OTHER PERSON: Reactions, Nudges). PR 14 adds What it takes afterwards. The planner, the Live Activity start and the installation registration all honor them. Server: one forward-only migration that adds device_installations.muted_push_kinds, a registration overload with one more argument, and a lease branch that suppresses switched-off nudge and reaction work. Includes pgTAP, a recovery-harness bump and a privacy.html line. No project.yml change and no new Swift files.

Base: `main` at 8c5ca25. Line numbers are from that commit. This PR lands after `takes`, `nudge`, `live` and `reactions` (owner's order, Q-notifs-6), so re-anchor by symbol name after rebasing. Symbols those PRs introduce are named here by role, for example "the Takes reminder family". Use their merged names.

#### Scope
- Account → Notifications gets the mockup's page: one switch per kind of notification you can turn off, so people who find lead changes too chatty can turn off just those.
- **Seven switches in two sections.**
  - DURING A MATCH: Lead changes, Close scores, What it takes, Last day, Live Activity.
  - FROM THE OTHER PERSON: Reactions, Nudges.
- Results, challenges and challenge expiry are always on and are not listed.
- The choices are stored **on this iPhone** in UserDefaults:
  - The planner applies them to app notifications.
  - The Live Activity start honors the Live Activity switch.
  - Registration sends the server-sent kinds that are switched off, so the server holds those pushes back (Q-notifs-4).
- Turning a switch off:
  - removes pending notifications of that kind on the reconcile the switch triggers right away
  - ends a running Live Activity
  - re-registers the installation
- **Server:** one migration (a column, a registration overload, a lease branch), pgTAP, a recovery-harness bump and a privacy.html line.
- **Not changed:** no Edge Function, no CompetitionCore change, no new Swift files, no `project.yml` / `project.pbxproj` change.

#### Behavior

##### Account → Notifications, top to bottom
1. **Status section.**
   - "Match notifications" On/Off and Turn On Notifications / Open Settings are unchanged.
   - The footer loses its " Turn them off in iOS Settings." suffix. With per-kind switches directly below, it pointed people at the wrong place. The Open Settings button stays.
   - Footer, in every state: `HealthComp only sends match moments, like lead changes and results. To mute someone, open your match with them.`
2. **`SectionLabel("DURING A MATCH")`.** Native `Toggle`s, all on by default (Q-takes-1), in this order:

   | Row label | Controls | Notification or effect it silences |
   |---|---|---|
   | `Lead changes` | `.opportunistic(.leadChange)` | "You took the lead" / "{Name} took the lead" |
   | `Close scores` | `.opportunistic(.closeScore)` | "Neck and neck with {Name}" |
   | `Last day` | `.scheduled(.finalDay)` | "Last day" (9:00 on Day 7, single or merged) |
   | `Live Activity` | Live PR's `Activity.request` | the Day 7 Lock Screen / Dynamic Island activity |

   PR 14 inserts `What it takes` (the evening reminder) between Close scores and Last day.
   Like every other row, the Live Activity row has no caption while Live Activities are on in iOS. PR 7's "Shows the score on the Lock Screen in the last hours of a match." is dropped. The only caption is the iOS-off one from the amendments.

3. **`SectionLabel("FROM THE OTHER PERSON")`:**

   | Row label | Server work kind | Effect |
   |---|---|---|
   | `Reactions` | `reaction` (the kind the Reactions migration added) | the lease marks the work 'suppressed' |
   | `Nudges` | `nudge` | the lease marks the work 'suppressed' |

4. **MUTED section: unchanged** ("Muting someone silences all your matches with them.").

Neither new section has a footer, as in the mockup. The mockup caption ("Results and challenges stay on…") is a design note. As page copy it would be false under a mute or with iOS notifications off.

The switches show and work in every authorization state, including `.denied` and `.notDetermined`. A choice made while iOS notifications are off applies once they're on. No extra copy.

##### Rules
- **Always on, never listed:**
  - result and the results summary
  - challenge expiry (`inviteExpiry`)
  - server challenge pushes
  - Day 1 (`scheduledStart`)
  - Final score pending (`competitionEnded`)
  - 600 today (`dailyMaximum`)
  - Match update (`catchUp`)

  "Always on" means no switch. A mute or iOS Settings still silences them. Q-notifs-2 covers the last four.
- **Last day off:** the pending `competition-notification:v1:<id>:final-day` request for every match is removed on the triggered reconcile, including a merged request. Delivered ones stay in Notification Center.
- **Lead changes / Close scores / What it takes off:**
  - From the next evaluation on, a candidate of that family is recorded durably as `.suppressed(reason: .superseded)` and nothing posts.
  - The match's one-per-evaluation slot goes to its next candidate. For example, with Close scores off, a lead change in the same evaluation posts.
  - If the Takes reminder is a scheduled family, it is dropped like Last day.
- **Live Activity off:** no new activity starts, and a running one ends on the triggered reconcile.
- **Reactions / Nudges off:**
  - Applies as soon as the re-registration succeeds.
  - If it fails (offline), the next launch's registration repairs it, and one push may arrive in between.
  - Applies to pushes queued before the switch too, because the lease decides at send time.
- **Turning a switch back on** never posts a late one:
  - The moment was recorded as suppressed. Only the next new moment posts.
  - The leader history stays right, because a switched-off lead change is still recorded.
- **Match update (catch-up)** fires only when a missed past-day moment belongs to a family that is on. Missed moments of switched-off families are still recorded (`.staleEpisode`). A missed "600 today" still triggers it.
- **Muting** works as today and sits above the switches:
  - On the phone, a muted person's matches plan nothing (CompetitionNotificationPlanner.swift:366-372).
  - On the server, a mute row resolves 'suppressed' first.
- **Scope of a choice:**
  - This iPhone, every match, every account signed in on it. It survives sign-out and account switching, like Appearance (`@AppStorage(AppAppearance.storageKey)`).
  - Each new sign-in registers the installation with the same switched-off push kinds.
  - Uninstalling clears it.
  - The server sees only the switched-off server-sent kinds (Reactions, Nudges), per installation.

##### Deviations from the mockup
1. "Final day" → **"Last day"** (Q-notifs-1).
2. Server pushes are held back by the server, not hidden by a notification service extension (Q-notifs-4). Without Apple's filtering entitlement an extension cannot drop a push.
3. The status footer drops " Turn them off in iOS Settings.". The Open Settings button stays, as the playbook requires.
4. The toggle tint follows the mockup's system green, set on the toggle only, so it is not a deviation. It is still outside the Theme tokens, so Q-notifs-5 flags it.

##### Accessibility
- Native `Toggle`. VoiceOver reads e.g. "Lead changes, Switch button, On". The label is the row text.
- List rows are at least 44 pt. At AX5 the system wraps the label; no `fixedSize`.
- `SectionLabel` already adds `.isHeader`.
- The UI test's existing `.textClipped` / `.hitRegion` / `.sufficientElementDescription` audit covers the new rows.

#### Design

**A. `HealthComp/Services/CompetitionNotificationPreferences.swift`**
- After the stored closures of `CompetitionNotificationPreferencesClient` (:96-101), add a defaulted property:
  ```swift
  /// Families switched off on this iPhone (Account → Notifications). Empty by
  /// default so tests and fixtures keep every family on.
  var switchedOff: @Sendable () -> Set<CompetitionNotificationChoice> = { [] }
  ```
  - The memberwise init stays source-compatible: `.live`, `.constant`, `.remote`, `.unavailable` and CompetitionNotificationCoordinatorTests.swift:359-363 compile unchanged.
- After :157, add the registry. Case order is page order.
  ```swift
  /// What Account → Notifications can switch off. Results, challenges and
  /// challenge expiry have no case: they're always on. Stored per iPhone.
  enum CompetitionNotificationChoice: String, CaseIterable, Sendable {
      case leadChange = "lead-change"
      case closeScore = "close-score"
      case whatItTakes = "what-it-takes"
      case finalDay = "final-day"
      case liveActivity = "live-activity"
      case reaction   // raw value = server work kind; match the Reactions migration
      case nudge      // raw value = server work kind

      var title: String {
          switch self {
          case .leadChange: "Lead changes"
          case .closeScore: "Close scores"
          case .whatItTakes: "What it takes"
          case .finalDay: "Last day"
          case .liveActivity: "Live Activity"
          case .reaction: "Reactions"
          case .nudge: "Nudges"
          }
      }

      /// Held back by the server, not the planner.
      var isServerSent: Bool { self == .reaction || self == .nudge }

      /// Persisted on devices: never rename a raw value.
      var storageKey: String { "healthcomp.notifications." + rawValue }

      /// A missing value means on.
      static func switchedOff(in defaults: UserDefaults = .standard) -> Set<Self> {
          Set(allCases.filter { defaults.object(forKey: $0.storageKey) as? Bool == false })
      }

      /// Sent with registration; sorted so equal sets encode equally.
      static func mutedPushKinds(in defaults: UserDefaults = .standard) -> [String] {
          switchedOff(in: defaults).filter(\.isServerSent).map(\.rawValue).sorted()
      }
  }
  ```
- **Why UserDefaults and not the JSON `CompetitionNotificationPreferencesStore`:**
  - Nothing in the app constructs the store (`.live(fileURL:)` has no caller in `HealthComp/`).
  - Real accounts keep mutes on the server (`.remote`).
  - UserDefaults is already declared in `PrivacyInfo.xcprivacy` (CA92.1), and `healthcomp.appearance` / `healthcomp.colorHintSeen` set the key style.

**B. `HealthComp/Services/CompetitionNotificationModels.swift`**, after `CompetitionNotificationMessageFamily` (:173-185)
```swift
extension CompetitionNotificationMessageFamily {
    /// The switch that silences this family; nil means always on. Exhaustive on
    /// purpose: a new family must choose.
    var choice: CompetitionNotificationChoice? {
        switch self {
        case .opportunistic(.leadChange): .leadChange
        case .opportunistic(.closeScore): .closeScore
        case .scheduled(.finalDay): .finalDay
        // + the Takes reminder family → .whatItTakes (its merged case name)
        case .opportunistic(.result), .opportunistic(.catchUp),
             .opportunistic(.dailyMaximum), .scheduled(.inviteExpiry),
             .scheduled(.scheduledStart), .scheduled(.competitionEnded):
            nil
        }
    }

    func isOff(in switchedOff: Set<CompetitionNotificationChoice>) -> Bool {
        choice.map(switchedOff.contains) ?? false
    }
}
```

**C. `HealthComp/Services/CompetitionNotificationPlanner.swift`** (one guard per place)
- `plan(_:authorization:mutedOpponentIdentities:)` (:328-332) gains a trailing `switchedOff: Set<CompetitionNotificationChoice> = []`.
- :374-379: `try scheduledRequests(for:snapshot:).filter { !$0.message.family.isOff(in: switchedOff) }`.
  - This drops `.finalDay` (and a scheduled Takes reminder) before `mergedScheduledRequests`.
  - The coordinator's obsolete-request removal (CompetitionNotificationCoordinator.swift:262-282) then removes the pending identifier.
- :380: `opportunisticPlan(for:snapshot:switchedOff:)`.
- In `opportunisticPlan` (:622), after the recordedIDs filter (:635-641) and before the daily-max sibling check (:644), add:
  ```swift
  // Switched off: recorded silently, so turning it back on never posts a
  // late one, and this match's slot goes to its next candidate.
  let isOff = { CompetitionNotificationMessageFamily.opportunistic($0).isOff(in: switchedOff) }
  for candidate in candidates where isOff(candidate.record.family) {
      result.suppressions.append(
          try suppressed(candidate.record, reason: .superseded, snapshot: snapshot)
      )
  }
  candidates.removeAll { isOff($0.record.family) }
  ```
  This is the same pattern as the "600 today once" suppression below it, and it reuses an existing `NotificationSuppressionReason`, so neither CompetitionCore nor the journal changes.
- :694-695, the catch-up condition: `!staleSuppressions.isEmpty` → `staleSuppressions.contains { !isOff($0.family) }`.
- `leadBaselineRecord` and `staleSuppressionRecords` are unchanged.

**D. `HealthComp/Services/CompetitionNotificationCoordinator.swift`**
- After the muted read succeeds (:238-247): `let switchedOff = preferences.switchedOff()`.
- Pass `switchedOff: switchedOff` to `planner.plan` at :251-255 **and** in the commit-time replan at :339-343. The replan must match the plan, or a switched-off lead change could be re-decided as an emission.

**E. `HealthComp/Features/Competition/RemoteCompetitionClient.swift`**
- :22-24, the only live preferences factory:
  ```swift
  notificationPreferencesFactory: { _ in
      var preferences = CompetitionNotificationPreferencesClient.remote(remoteAPI: remoteAPI)
      preferences.switchedOff = { CompetitionNotificationChoice.switchedOff() }
      return preferences
  },
  ```
  This keeps the test host's UserDefaults out of unit tests that build `.remote`.
- `CompetitionInstallationCoordinator(` (:559): pass `mutedPushKinds: { CompetitionNotificationChoice.mutedPushKinds() }`.
- `reconcileNotifications()` (:798-803): inside the gate, after `notificationCoordinator.reconcileLatest()`, add `await installationCoordinator?.reconcile()`. A server-sent switch then re-registers right away. The token plus kinds dedupe (G) makes this a no-op when nothing changed.

**F. `HealthComp/Features/Competition/CompetitionFeature.swift`**
- `Action`, after `enableNotificationsTapped` (:208): `case notificationChoicesChanged`.
- Reducer, next to `.enableNotificationsTapped` (:728):
  ```swift
  case .notificationChoicesChanged:
      return .run { _ in
          await competitionClient.reconcileNotifications()
          // + the Live PR's end call when CompetitionNotificationChoice.switchedOff().contains(.liveActivity)
      }
  ```
  `reconcileNotifications` is the closure at CompetitionClient.swift:60. No state is added; the view owns the stored value.

**G. Registration**
- **`HealthComp/Services/CompetitionSyncModels.swift`**
  - `CompetitionInstallationRequest` (:1498):
    - add `let mutedPushKinds: [String]` and an init parameter `mutedPushKinds: [String] = []`
    - validate each element against `CompetitionNotificationChoice.allCases.filter(\.isServerSent).map(\.rawValue)`, or throw `.serverContractMismatch`
    - add `CodingKeys.mutedPushKinds = "muted_push_kinds"`; `encode` writes it, and `init(from:)` decodes it with `decodeIfPresent ?? []`
  - `validateInstallationRequest` (:3620-3640) adds the key and checks it is an array of strings.
- **`HealthComp/Services/CompetitionPushRegistration.swift`**
  - `CompetitionInstallationCoordinator`:
    - init gains `mutedPushKinds: @Sendable () -> [String] = { [] }`
    - `registeredToken: String?` (:438) becomes `registered: Registration?`, with `struct Registration: Equatable { let token: String; let mutedPushKinds: [String] }`
    - `enqueue` (:526-527) compares `Registration(token: token, mutedPushKinds: mutedPushKinds())`
    - `register` passes the kinds into the request and stores `registered` on success; every place that clears `registeredToken` clears `registered`
- **`HealthComp/Services/SupabaseCompetitionRemoteAPI.swift`** `registerInstallation`: PR 10's loop over parameter `Data` values (on `CompetitionRemoteFailure.notFound`, PGRST202) grows from three steps to four:
  1. `encodeWire(request, contract: .installationRequest)`, which now has `muted_push_kinds` (6-argument overload, this PR);
  2. `ReactionInstallationParameters(request)`, a new private struct next to PR 10's `ChallengeInstallationParameters`, with keys `installation_id`, `apns_token`, `environment`, `supports_challenges: true`, `supports_reactions: true` (PR 9's 5-argument overload). It can't come from `encodeWire(…, contract: .installationRequest)`, because `validateInstallationRequest` checks an exact key set;
  3. `ChallengeInstallationParameters(request)` (4-argument, PR 10);
  4. `LegacyInstallationParameters(request)` (3-argument, #189).

  Update the comment above the loop to name the four overloads.

**H. `HealthComp/Features/Account/AccountSettingsView.swift`**
- `AccountNotificationSettings` (:17-28): add `var choicesChanged: () -> Void = {}` and `var liveActivitiesEnabled: Bool? = nil` (nil reads and observes `ActivityAuthorizationInfo`; a value overrides it for the DEBUG fixture). The `.account` Test Lab fixture (MultiUserCompetitionTestLabView.swift:603-609), which already models iOS-off with `authorization: .denied`, passes `liveActivitiesEnabled: false`, so the UI test can assert the disabled row, its caption and Open Settings.
- `AccountNotificationsPage` (:521):
  - Delete the `footer` computed property (:582-587) and use the base string literally in the status section's footer.
  - Insert between the status section and `if !settings.mutedPeople.isEmpty` (:565):
    ```swift
    choiceSection("DURING A MATCH", CompetitionNotificationChoice.allCases.filter { !$0.isServerSent })
    choiceSection("FROM THE OTHER PERSON", CompetitionNotificationChoice.allCases.filter(\.isServerSent))
    ```
    with
    ```swift
    private func choiceSection(_ title: String, _ choices: [CompetitionNotificationChoice]) -> some View {
        Section {
            ForEach(choices, id: \.self) { choice in
                NotificationChoiceToggle(choice: choice, changed: settings.choicesChanged)
            }
        } header: {
            SectionLabel(title)
        }
        .listRowBackground(Theme.panel)
    }
    ```
- New private view after `AccountNotificationsPage`:
  ```swift
  private struct NotificationChoiceToggle: View {
      let choice: CompetitionNotificationChoice
      let changed: () -> Void
      @AppStorage private var isOn: Bool

      init(choice: CompetitionNotificationChoice, changed: @escaping () -> Void) {
          self.choice = choice
          self.changed = changed
          _isOn = AppStorage(wrappedValue: true, choice.storageKey)
      }

      var body: some View {
          Toggle(choice.title, isOn: $isOn)
              .tint(Color(uiColor: .systemGreen))   // Q-notifs-5: the page's ink tint hides the thumb in dark mode
              .onChange(of: isOn) { changed() }      // iOS 17 zero-argument overload
              .accessibilityIdentifier("account.notifications.choice.\(choice.rawValue)")
      }
  }
  ```
  - `.tint` is needed because `accountPageStyle` (:823-827) tints the page `Theme.ink`.
  - `@AppStorage` writes UserDefaults synchronously before `onChange` fires.
  - `onChange(of:_:)` with a zero-argument closure is iOS 17.0 and is in the Xcode 16.4 SDK, so no `#available` is needed.

**I. `HealthComp/App/HealthCompApp.swift:316-329`** (`AccountSheet`): add `choicesChanged: { mainStore.send(.competition(.notificationChoicesChanged)) }` to the `AccountNotificationSettings` init.

**J. Live Activity PR's start site** (the one `Activity.request` call): guard with `!CompetitionNotificationChoice.switchedOff().contains(.liveActivity)`. This runs in the app process, so no App Group read is needed.

**K. Server migration `supabase/migrations/20261103002800_let_installations_turn_off_push_kinds.sql`** (forward-only; timestamp after the Nudge and Reactions migrations)
1. Add the column:
   ```sql
   alter table public.device_installations
     add column muted_push_kinds text[] not null default '{}'
     check (muted_push_kinds <@ array['nudge', 'reaction']::text[]);
   ```
   Use the exact kind names in `competition_notification_work_kind_check` as widened by the Nudge and Reactions migrations. This PR does not touch that constraint, because those PRs already widened it to insert their rows.
2. **New registration overload.** Add one `muted_push_kinds text[]` argument to PR 9's 5-argument `register_current_device_installation` overload, giving six arguments.
   - It rejects null and values outside the column check with the same error style as 20261101002300.
   - It upserts `muted_push_kinds = excluded.muted_push_kinds`.
   - The previous overload delegates with `'{}'`, and older overloads already delegate down the chain. Builds without the switch therefore keep getting nudges (Q-notifs-3).
   - Same grants as the 2300 overload.
3. **Lease.** `create or replace` `lease_competition_notification_work`, copying the newest body verbatim and widening only the mute branch:
   ```sql
   when exists (select 1 from private.competition_notification_mutes mute_row ...)
     or work_row.kind = any(installation_row.muted_push_kinds) then 'suppressed'
   ```
   - 'suppressed' because it is the recipient's own choice, like a mute. 'discarded' stays reserved for "this build can't show it": 2300's challenge gate and PR 4's nudge discard arm, both copied from PR 4's body.
   - Both states resolve the row identically (2300:206).
4. **Recovery harness:**
   - `scripts/test-recovery-migrated-snapshot.sh:31` migration count +1 from main at rebase (26 at 8c5ca25, plus the Nudge, Reactions and any Block migrations).
   - `:9` recompute `manifest_hash`.
   - `scripts/tests/recovery-migrated-fixture.sql:23-24` add the new version to the `max(version)` list.
5. **`supabase/tests/002_privacy_columns.test.sql:58`:** add `muted_push_kinds` to the approved `device_installations` columns, as #189 did for `supports_challenges`.

**L. Docs**
- `web/privacy.html:54-56`, "Installation and security information": `installation identifiers, notification tokens, which kinds of notification you turned off on that device, and app-integrity verification records support notification delivery, …`
- `docs/runbooks/supabase-environments.md`, after the 20261101002300 entry (:475): the new migration must be in production before any build containing this PR. The app falls back to the previous registration on PGRST202, but switched-off kinds aren't honored until then.
- `docs/runbooks/competition-support.md`, after :374: "Lead changes, close scores, What it takes, the Last day reminder and the Live Activity can be switched off per iPhone in Account → Notifications; the server can't see those. Reactions and nudges switched off show up as `device_installations.muted_push_kinds` and as 'suppressed' work. Ask the person to check that page first."

##### Data flow
1. A toggle writes `healthcomp.notifications.<raw>` to UserDefaults.
2. `onChange` calls `settings.choicesChanged()`, which sends `.competition(.notificationChoicesChanged)`.
3. The `CompetitionFeature` effect calls `competitionClient.reconcileNotifications()` (and the Live end call if that switch is off).
4. `RemoteCompetitionClientCoordinator.reconcileNotifications()` runs `notificationCoordinator.reconcileLatest()`:
   - it reads the mutes (server) and `switchedOff()` (UserDefaults)
   - it plans with them, removes obsolete pending requests, and commits suppressions with the same switches
5. Then `installationCoordinator?.reconcile()`. If the token or `mutedPushKinds()` changed, it calls `register_current_device_installation(…, muted_push_kinds)`.
6. At send time the lease marks work of a muted kind 'suppressed'.
7. Later HealthKit, realtime and launch evaluations go through the same path. If there is no snapshot yet, the first evaluation picks the choice up.

#### Server changes
- One migration (K): column, overload, lease branch.
- pgTAP:
  - the new suite
  - the `002_privacy_columns` update
- Recovery harness bump.
- No Edge Function change, no Deno change.

#### Tests

**`HealthCompTests/CompetitionNotificationPreferencesTests.swift`**
- `testNotificationChoicesAreOnUntilStoredOff`, using `UserDefaults(suiteName: "choices-\(UUID())")!` and `removePersistentDomain` in `defer`:
  - empty → `[]`
  - `false` for `.leadChange` → `[.leadChange]`
  - `true` → `[]`
- `testMutedPushKindsListsOnlySwitchedOffServerKinds`: set `.nudge`, `.reaction` and `.leadChange` to `false` → `["nudge", "reaction"]` (sorted).
- `testNotificationChoiceKeysAndTitlesNeverChange`: all 6 storage keys and titles, and the `allCases` order (PR 14 updates it to 7).

**`HealthCompTests/CompetitionNotificationPlannerTests.swift`**
- The private helper `plan(_:policy:muted:)` (:776) gains `switchedOff: Set<CompetitionNotificationChoice> = []` and passes it through. The 14 direct `.plan(` call sites compile unchanged through the default.
- `testEveryMessageFamilyMapsToItsSwitchOrIsAlwaysOn`: a table over every `CompetitionNotificationMessageFamily`. Only leadChange, closeScore, finalDay and the Takes reminder map.
- `testSwitchedOffLastDayDropsOnlyThatReminder`:
  - One `.scheduled` match, all on → desired includes `final-day`.
  - The same match with `[.finalDay]` → scheduledStart and competitionEnded only.
  - The two same-schedule matches from `testSameScheduleRemindersMergeIntoOne` with `[.finalDay]` → no `final-day` identifier; the merged "Day 1 of 7" is still present.
- `testSwitchedOffLeadChangeSuppressesALeadChangeThatWouldPost`:
  - `.liveV1`, Day 3 (no close score before Day 5), fresh, prior opponent-leader record, owner now leads.
  - All on → one `.leadChange` decision.
  - `[.leadChange]` → no decision, plus suppression `(.leadChange, .leader(3, .owner), .superseded)`.
- `testSwitchedOffCloseScoreFreesTheSlotForALeadChange`:
  - `.liveV1`, Day 5, owner leads by 10 with both at least 300, prior opponent-leader record.
  - Control, all on → `.closeScore` decided, because priority 30 beats 20.
  - `[.closeScore]` → one `.leadChange` decision, plus suppression `(.closeScore, .day(5), .superseded)`.
- `testTurningASwitchBackOnPostsNothingLate`: history holds `(.leadChange, .leader(3, .owner), .superseded)`, all on → no leadChange decision.
- `testAlwaysOnFamiliesIgnoreEverySwitch`, with `switchedOff: Set(CompetitionNotificationChoice.allCases)`:
  - a completed match → `.result`
  - an active Day 3 match at 600 → `.dailyMaximum`
  - `.pending(direction: .outgoing, expiresAt:)` → `invite-expiry`
  - a scheduled match → `scheduled-start` and `competition-ended`
- `testCatchUpCountsOnlyFamiliesThatAreOn`:
  - Fixture: `testStaleEpisodeIsSuppressedAndCollapsesToOneGenericCatchUp`, with Day 2 at 500 vs 250.
  - All on → one `.catchUp`.
  - `[.leadChange]` → no decision; the `.staleEpisode` leadChange suppression is still recorded.

**`HealthCompTests/CompetitionNotificationCoordinatorTests.swift`**
- `testSwitchingOffLastDayRemovesItsPendingRequestOnReconcile`:
  - Pending `final-day` and `scheduled-start` for one scheduled match.
  - Control with `switchedOff: { [] }` → `removePending` empty.
  - With `{ [.finalDay] }` → `removePending` is exactly the final-day identifier.
- `testCommitReplanHonorsSwitchedOffFamilies`:
  - `switchedOff: { [.leadChange] }` on a Day 3 lead-change snapshot.
  - The `commitDecisions` replan returns only `.suppression`, and nothing posts.

**`HealthCompTests/CompetitionFeatureTests.swift`**
- `testNotificationChoicesChangedReconcilesNotifications`: `reconcileNotifications` increments a `LockIsolated` counter; send `.notificationChoicesChanged`; no state change; `await store.finish()`; counter == 1.

**`HealthCompTests/CompetitionSyncModelsTests.swift`** (next to :352)
- The encoded request includes `"muted_push_kinds": []` by default and `["nudge"]` when given.
- An unknown kind throws `.serverContractMismatch`.

**`HealthCompTests/SupabaseCompetitionRemoteAPITests.swift`** (next to :474)
- `testRegisterInstallationFallsBackWithoutMutedPushKinds`: the first RPC returns PGRST202 → the second body is exactly `installation_id`, `apns_token`, `environment`, `supports_challenges: true`, `supports_reactions: true` (no `muted_push_kinds`).
- **Update PR 10's `testInstallationRegistrationFallsBackThroughOlderCalls`:** a 404 on 6-arg retries 5-arg (`supports_reactions: true`, no `muted_push_kinds`), a second 404 retries 4-arg, a third retries 3-arg.
- **Update `testInstallationRegistrationFallsBackToLegacyCallOnUnmigratedServer`:** the first body gains `"muted_push_kinds": []`, and the recorded requests go 6-arg, 5-arg, 4-arg, 3-arg.

**`HealthCompTests/CompetitionPushRegistrationTests.swift`**
- `testChangingMutedPushKindsReRegistersSameToken`:
  - Register with `[]`.
  - `reconcile()` with an unchanged closure → no second call.
  - Change the closure to `["nudge"]` and `reconcile()` → a second call with `["nudge"]`.

**`supabase/tests/026_push_kind_switches.test.sql`** (modeled on `021_challenge_push_capability.test.sql`)
- A nudge to an installation with `{nudge}` resolves 'suppressed'.
- A nudge to an installation with `{}` leases.
- A reaction to `{nudge}` leases (assuming its capability is set).
- The previous overload stores `'{}'`, and re-registering through it clears an earlier `{nudge}`.
- A sender mute still suppresses.
- Score, result and challenge kinds ignore `muted_push_kinds`.
- An unknown kind or a null is rejected.

**`HealthCompUITests/MultiUserCompetitionUITests.swift`**
- Extend `testNotificationsPageOpensSettingsAndUnmutes` (:914). It is in CI's list (ci.yml:227), so `ci.yml` doesn't change.
- Before the existing audit, assert:
  - `DURING A MATCH` and `FROM THE OTHER PERSON` exist
  - all 6 `app.switches["account.notifications.choice.<raw>"].firstMatch` exist with their row labels
  - Live Activity iOS-off state (the `.account` fixture passes `liveActivitiesEnabled: false`, see H): `account.notifications.choice.live-activity` has `isEnabled == false`, `app.staticTexts["Live Activities are off for HealthComp in iOS Settings."]` exists, and `account.notifications.live-activity.settings` exists and is hittable
- Flip and restore through a private helper. A `Toggle` in a `List` exposes a row-wide switch, and `tap()` at its center can land on the label:
  ```swift
  private func flip(_ toggle: XCUIElement) {
      let knob = toggle.switches.firstMatch
      if knob.exists { knob.tap() }
      else { toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap() }
  }
  ```
  Read `lead-change`'s `value`, flip it, assert it flipped ("1" ↔ "0"), flip it again, and assert it is restored, so reruns start clean.
- The 6 rows push `MUTED` down. If `mutedHeader` isn't hittable on the iPhone 16 Pro, `app.swipeUp()` before the unmute half.
- Don't pin values with `-healthcomp.notifications.* NO` launch arguments. The argument domain would override the toggle's writes.
- No other test asserts the status footer text (grep: only AccountSettingsView.swift:583-585), so dropping the suffix breaks nothing.

#### Verify
**Mac mini** (its `ua-mac6.sh` simulator is an iPhone 16 Pro on iOS 18.5, the CI runtime), on top of the audit spec §8 steps:
```bash
git archive HEAD | ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini 'rm -rf ~/dev-desktop/ua/notifs/src && mkdir -p ~/dev-desktop/ua/notifs/src && tar -x -C ~/dev-desktop/ua/notifs/src'
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh xcodegen notifs'   # expect no project.pbxproj diff
# Narrow unit run: `ui` mode passes filters through unchanged; `unit` mode hard-codes -only-testing:HealthCompTests and runs the whole suite.
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh ui notifs -only-testing:HealthCompTests/CompetitionNotificationPlannerTests -only-testing:HealthCompTests/CompetitionNotificationCoordinatorTests -only-testing:HealthCompTests/CompetitionNotificationPreferencesTests -only-testing:HealthCompTests/CompetitionFeatureTests -only-testing:HealthCompTests/CompetitionSyncModelsTests -only-testing:HealthCompTests/SupabaseCompetitionRemoteAPITests -only-testing:HealthCompTests/CompetitionPushRegistrationTests'
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh ui notifs -only-testing:HealthCompUITests/MultiUserCompetitionUITests/testNotificationsPageOpensSettingsAndUnmutes'   # run 3x: proves the flip helper before CI relies on it
ssh -F /home/ubuntu/secrets/mac-mini-ssh.conf mac-mini '~/dev-desktop/ua/ua-mac6.sh ci notifs'          # all HealthCompTests + CI's UI list
```
**Server, on this VM with the local Supabase stack** (backend.yml steps):
- `supabase db reset && supabase test db`
- `scripts/test-recovery-migrated-snapshot.sh`
- `scripts/test-staging-adversarial-sql.sh`
- `supabase db lint`, and a clean `supabase db diff`

**Captures:** Account → Notifications from the `.account` fixture, in light and dark, at XS and AX5, for the preview artifact next to the #notifs mockup.
- Flip one switch Off first, so both states show.
- **Check explicitly that an On switch's thumb is visible in the dark capture** (Q-notifs-5).
- Call out deviations 1–4.

**Manual on a Staging device** (after the migration is on Staging):
1. Last day off, reopen → `final-day` gone, `scheduled-start` remains.
2. Lead changes off; the Staging partner takes the lead → no banner, and a `.superseded` journal record.
3. Back on → no late banner.
4. Live Activity off on Day 7 → the activity ends.
5. Nudges off → the row shows `muted_push_kinds = {nudge}`; a partner's nudge work resolves 'suppressed' and nothing arrives.
6. Nudges on → the next nudge arrives.

#### Accessibility identifiers
- **Added:**
  - `account.notifications.choice.lead-change`, `.close-score`, `.final-day`, `.live-activity`
  - `account.notifications.choice.reaction`, `account.notifications.choice.nudge`
  - `account.notifications.live-activity.settings`
  - (`account.notifications.choice.what-it-takes` is PR 14's)
- **Unchanged:** `account.notifications`, `account.notifications.settings`, `account.notifications.unmute`, `competition.notifications.enable`.
- **Removed:** none.

#### Risks and conflict regions
- **Cross-spec ownership (Q-notifs-6):** the Takes, Nudge, Live and Reactions specs must ship without their own switch and say "switch lands with Notification choices". If one already added a switch, this PR adopts its storage key instead of adding a second one.
- **`CompetitionNotificationPlanner.swift`** `plan` (:328-412) / `opportunisticPlan` (:622-704): the Takes family lands first, and the exhaustive `choice` switch forces its mapping here.
- **Lease function:** `create or replace` must copy PR 4's body (2300's challenge gate plus PR 4's nudge discard arm) verbatim; PRs 8 and 9 don't touch the lease. Diff the function against the previous migration in review.
- **Registration overload chain:** extend PR 9's 5-argument overload; don't fork a parallel one. The app chain is 6 → 5 → 4 → 3 (G).
- **`AccountNotificationsPage`** (:521-625) is also touched by Block (MUTED area). `AccountSheet` (:313-360) is touched by any PR that adds Account settings.
- **`CompetitionFeature.Action`** (:202-215): append-only conflict with Nudge.
- **Journal:** `.superseded` can't tell "switched off" apart from "lost the slot". This is accepted to keep the CompetitionCore wire format. `// ponytail: reuse .superseded; add NotificationSuppressionReason.switchedOff in CompetitionCore if support needs to tell them apart.`
- **Cross-device:** a second iPhone on the same account keeps its own choices, and its installation row carries its own `muted_push_kinds`. Accepted.
- **Offline switch:** a server-sent switch flipped offline applies at the next successful registration (the next launch at the latest).
- **UserDefaults vs scenes:** `@AppStorage` writes `.standard`, which the coordinator and registration read. No App Group is needed while only the app process reads the choices.

#### Rollout and compatibility
- **Release order:** the migration ships Staging → production before any TestFlight build containing this PR. If the order slips, the PGRST202 fallback keeps registration working.
- **First launch after updating:** no keys exist, so everything is on. Registration sends `[]`, and behavior is identical to today until someone switches one off.
- **Installed 1.0.2 and older current builds:** their overloads store `'{}'`, so they keep getting nudges (Q-notifs-3). Reaction delivery to them is unchanged from the Reactions PR.
- **Downgrade:** older builds ignore the UserDefaults keys. Their registration resets `muted_push_kinds` to `'{}'`, which is correct, because they have no switch.
- **Rollback:**
  - App: revert. Durable `.superseded` records stay valid journal events.
  - Server: forward-only. A follow-up migration can restore the previous lease body. The column is harmless when no app writes it.

#### Claude's calls
- Follows the owner's order: lands after Nudge, Live Activity and Reactions with a 6-row page; PR 14 adds the seventh (Q-notifs-6, answered by §6).
- The registry lives in `CompetitionNotificationPreferences.swift`, stored in UserDefaults per iPhone, surviving sign-out like Appearance.
- Switched-off moments are recorded as suppressed, not deferred, so turning a switch back on never posts a late one.
- Match update fires only for missed moments of families that are on.
- The switches show in every authorization state.
- No section footers. The status footer drops its iOS Settings suffix.
- Server-sent switches are an opt-out list on the installation, suppressed at lease time (Q-notifs-4 default; Q-notifs-3 split for old builds).

#### Open questions
Q-notifs-1 (row label), Q-notifs-2 (no switch for four notifications), Q-notifs-3 (old builds keep getting nudges), Q-notifs-4 (server-held list vs filtering entitlement), Q-notifs-5 (toggle tint), Q-notifs-6 (build order) and Q-takes-1 (What it takes starts on) are in `open_questions` with defaults. The PR is built on the defaults.

#### Review notes
Applied:
- **Row tap:** the UI test flips the switch through a helper that taps the inner switch, or the trailing edge as a fallback, and is proven on the Mac mini's iOS 18.5 simulator.
- **Tint:** became Q-notifs-5, with an explicit dark On-state capture check.
- **Planner tests:**
  - a lead-change-only test
  - a switches-on control in the close-score and coordinator tests
  - a `switchedOff` default on the private `plan(_:policy:muted:)` helper
- **Mac mini `unit` mode:** confirmed it hard-codes `-only-testing:HealthCompTests`. The narrow run now uses `ui` mode.
- **Footers:**
  - The status footer suffix is dropped.
  - "Results and challenges are always on." is removed (false under a mute or with iOS notifications off).
- **Build order:** the owner's order is followed (depends_on takes, nudge, live, reactions; full page; Q-notifs-6).
- **Nudges and old builds:** an opt-out `muted_push_kinds` list, so old builds keep getting nudges (Q-notifs-3 restated).
- **Server hold-back is an owner call:** it became Q-notifs-4.
- **Lease state:** switched off → 'suppressed', with the reason stated; unsupported build → 'discarded', in the Reactions gate.
- **Citation:** `reconcileNotifications` is at CompetitionClient.swift:60.

Rejected or narrowed:
- **"Move the server design into the Nudge/Reactions specs."** Under the owner's order those PRs merge first without switches, so the PR that adds the switch must own the hold-back. Only the owner-decision part was taken (Q-notifs-4).
- **"Add a contract step that widens `competition_notification_work_kind_check`."** The Nudge and Reactions migrations must widen it to insert their rows at all, so this PR depends on that and doesn't touch the constraint.
- **"Use Theme.secondary as the dark-mode tint."** It is about 2.5:1 against the white thumb and reads as disabled, so it is not the default.
- **"On and Off look nearly the same" with ink.** Overstated: the dark Off track (~#3A3A3D) still differs sharply from an ink track. The real defect is the thumb vanishing (~1.07:1), which Q-notifs-5 covers.

#### Owner actions for this feature (merged into §7)
- Answer Q-notifs-1 to Q-notifs-5 and Q-takes-1 (Q-notifs-6 is answered by §6) below, or accept the defaults. Q-notifs-4 (server-held choice vs the Apple filtering entitlement) changes the PR's shape.
- If Q-notifs-4 is answered 'entitlement': request com.apple.developer.usernotifications.filtering from Apple for the Debug, Staging and Release bundle IDs before work starts. Only the account holder can do this.
- Approve the preview artifact before the PR opens. It shows Account → Notifications captures in light and dark, at XS and AX5, with the On state of a switch visible in dark mode, next to the #notifs mockup.
- Promote the migration Staging → production before any TestFlight build containing this PR is distributed (release order in docs/runbooks/supabase-environments.md).

## 10. Claude's calls

Collected from §4 and the PR sections; the owner can overrule any.
- Notification choices owns every switch and lands after Nudge, Live Activity and Reactions; the 7 PM reminder lands after it and adds its own row (§4).
- Server PRs merge Nudge → Block → Reactions → Notification choices, one at a time (§6).
- The belt fold orders weeks itself (schedule end, then uuid); ties extend a reign; the result notification adds a sentence on every take; the banner replaces AWARDS (PR 1).
- The recap card follows the result screen's summary line, shows no belt line on a tie or for a deleted account, draws the belt glyph only on your lines, always shows the year and is always light (PR 2).
- What it takes counts Move and Exercise only, rounds amounts up, and shows on practice weeks too (PR 3/14).
- Nudges reach 1.0.2 installs; every successful nudge call returns the same answer (PR 4/5).
- Widgets carry points only, redact names on a locked phone, and show the Updated time over the lead line (PR 6).
- The Live Activity starts only in the last 7.5 hours of Day 7 and never shows the result (PR 7).
- Block is keyed by a challenge, reads as a plain decline, and stops challenges only (PR 8).
- Reactions live outside the change log; the push is title-only and at most hourly (PR 9/10).
- Practice is labeled everywhere, never the hero beside a real match, deleted when it leaves Home, and excluded explicitly where a dashboard is read (PR 12).
- Test Lab fixture ids are allocated once (§4).
