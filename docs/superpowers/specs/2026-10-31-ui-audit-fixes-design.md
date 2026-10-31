# UI audit fixes: design

Date: 2026-10-31 · Branch base: `main` at 7c5853f · Status: design, awaiting owner answers in §10

## 1. Intent and why

A UI audit of HealthComp found 30 findings (ids `f-…`) and 20 smaller polish rows. They cluster around a few root causes:

- the same thing has several names
- numbers and dates are formatted five ways
- real (Supabase) matches show less than the simulated fixture does
- Home has no order once you have more than one match
- challenges are hard to send, lose their link and close without a word
- notifications get lost, repeat or say nothing

**The owner decided to fix all of them.** The work is split into 8 PRs:

1. shared wording and formatting (the foundation)
2. real-match data parity
3. match and result screens
4. Home and History
5. notifications, app and server push
6. challenges, app side
7. challenges, server side
8. first run, Account and the remaining polish

This document is the single design for all eight. §9 holds each PR's full spec. §7 maps every audit item to exactly one PR.

## 2. Goals, non-goals, anti-goals

**Goals**
- Every one of the 30 findings and 20 polish rows is fixed by exactly one PR (§7).
- One vocabulary (§5), one number rule (whole points, locale grouping, a lead line computed from the shown numbers) and one style each for a day, a week and a moment, used on every screen and in every notification.
- Real matches show what the fixture shows: your rings, refresh times, "HOW YOU SCORED", freshness and pull to refresh.
- One job per screen. Home is grouped and ordered (Needs you / Live / Up next / Recent results). Secondary detail lives in pushed screens, sheets with detents or ••• menus, and each screen pins one primary action.
- Challenges can be sent without leaving the app, keep their link, say what happened when they close, and can be cancelled.
- Results are never lost. "600 today" posts at most once a day. Trivial alerts ("A close competition" at 0–0) stop.
- Dynamic Type up to AX5, VoiceOver labels without "--", and 44 pt targets on every new control. Light and dark mode both checked.

**Non-goals (this round)**
- Conceding a live match (Claude's call, §4). The Match menu polish row ships only its Cancel Match half.
- A server re-share of a challenge's link, rotating or resetting a challenge link, blocking, and a decline cooldown, unless the owner says otherwise (§10 Q6, Q7).
- Any directory, prefix search or email lookup for finding people.
- A per-person History page, persisted dismissals and an "unseen result" state (§10 Q18, Q19; PR 4).
- The pre-existing sync failure when the stand mode is unknown on a real match. It needs a scoring decision, so it gets its own `bugfix/` PR (PR 2 Risks).
- Copy in the DEBUG Test Lab, the Staging diagnostics page and `web/`. The exceptions are the privacy-page edits a §10 answer may require, and PR 7's `web/challenge.html` and AASA change.
- New colors, new Swift files, and any server change in PRs 1–4, 6 and 8.

**Anti-goals: these would make the work a failure even if it technically works**
- A screen whose shown winner, lead or day count disagrees with the decided outcome, or with another screen.
- Exact Health values (kcal, minutes, hours, goals) leaving the iPhone, including through device or iCloud backups, or the consent card telling people less than the other person can actually read.
- Weakening recipient binding: a display name treated as an identity, a way to look people up, or a token that works for an account it wasn't sent to.
- Installed 1.0.2 builds breaking silently, or a new app reaching TestFlight before the production server it calls.
- Duplicate or lost notifications, including a second result banner from the server.
- Taglines, marketing tone or new colors creeping into copy and UI.
- Accessibility identifier churn that silently breaks the UI suites, or a project.pbxproj that XcodeGen can't regenerate identically.
- Editing a historical migration.

## 3. Constraints

**Toolchain and verification path**
- This Linux VM has no Swift toolchain. Builds, unit tests, UI tests and simulator captures run on the shared Mac mini (Xcode 26.6, work only in `~/dev-desktop`). PR CI (Xcode 16.4, iPhone 16 Pro, iOS 18.5 simulator) is the merge gate.
- Every API must exist on iOS 18 with the Xcode 16.4 SDK. The app's deployment target is still iOS 17.0 (`project.yml:5`), so anything newer than iOS 17 also needs an `if #available` guard; none of the APIs below does. The newest APIs these PRs use are:
  - iOS 17: `containerRelativeFrame`, `scrollTargetBehavior`, `AccessibilityNotification.Announcement`, `scrollBounceBehavior`
  - iOS 16: `UIApplication.openNotificationSettingsURLString`
  - CoreImage `CIFilter.qrCodeGenerator()`
- **No PR adds a Swift file**, so `project.pbxproj` doesn't change. PR 1 edits `project.yml` and `Info.plist` together; run XcodeGen 2.46.0 on the Mac mini to confirm there is no diff.
- `HealthComp/Features/Competition/CompetitionDateFormatting.swift` must stay Foundation-only. CI compiles it on its own with `scripts/tests/competition-local-date-formatting.swift`. PRs 1, 2 and 3 add helpers there; anything that needs CompetitionCore or SwiftUI lives in an app file.
- Modules/CompetitionCore is a Foundation-only package with its own `swift test`. PR 2 adds one derived projection field and one display-only policy constant there. Nothing changes in the journal, genesis or wire formats.

**Design system**
- `HealthComp/App/Theme.swift` tokens only: amber (`Theme.you`, `Theme.youFill`) is you, ink is the other person, and the ring colors appear only on your own ring detail. No new colors. The one documented exception is PR 7's QR code, which must be black on white so it can be scanned.
- Reuse `SectionLabel`, `themePanel`, `PrimaryButtonStyle`, `SecondaryButtonStyle`, `CompetitionPressButtonStyle` and `CompetitionRowButtonStyle`.
- Copy is plain and minimal, with no taglines.

**Release process**
- Follow `docs/release/production-beta-checklist.md` and `docs/runbooks/` (especially `supabase-environments.md` and `competition-support.md`).
- Migrations are forward-only. PR 7 adds `20261101001900_add_challenge_links_and_responses.sql`, and the recovery harness count and manifest pin move by one.
- Migrations and Edge Functions are promoted to Staging, smoke-tested with the two Staging accounts, then promoted to production through the checklist approval.
- Installed older versions (1.0.2) must keep working or fail with a message they already show. PR 7 §3 has the compatibility table.
- For PR 7 the production server must be live before the TestFlight build goes out.

**Recipient-bound invitation contract** (`docs/plans/2026-10-19-recipient-bound-invitations.md`)
- A challenge is bound to one existing account, chosen before it is created. A display name is not an identity.
- There is no directory, prefix search or email lookup.
- There is at most one pending challenge per sender/recipient pair, and a challenge expires after 24 hours.
- PR 7 keeps all of this. A challenge link (`/c/<22 chars>`) resolves to one account, the same way the account code does today, and grants only "may create a pending challenge to me".
- PR 7 adds one amendment: the bound recipient may accept in the app without the token, because the signed-in account is the identity check. It edits the contract doc (:44-46) to match. This is Claude's call (§11), so the owner should know about it.

## 4. Decisions

**Owner decided**
- Fix all 30 findings and all 20 polish rows, in the 8 PRs listed in §1.

**Claude's calls** (made by Claude, not the owner; the owner can overrule any of them)
- **Home uses layout A from the audit.**
  - With exactly one live match, its card is today's large scoreboard.
  - With two or more there is no single hero: they get equal cards, ordered by end time, soonest first.
  - The groups are "Needs you", "Live", "Up next" and "Recent results".
- **Finished results move off Home into History on their own 3 days after the week ends.** Exactly: at the start of the 4th calendar day after the last day, in the match calendar, and never less than one full day after the tally finished. A swipe archives a result sooner. Leaving Home only hides the row; nothing is archived on the server.
- **Conceding a live match is out of scope this round.** Cancel Match (scheduled matches only) ships in PR 7.
- **The server work is designed now.** That is the server part of PR 5 and all of PR 7. Whether it ships this round or in a follow-up waits on the owner's answer (§10 Q1).

Every other Claude's call is listed in §11.

## 5. Glossary

These words apply to every shipped string, VoiceOver label and notification.

| Term | Means | Don't say |
|---|---|---|
| **Match** | A 7-day head-to-head between two people | competition, activity competition |
| **Challenge** | A match that hasn't been accepted yet; also the verb ("Challenge Sam") | invitation, private invitation, outgoing invitation |
| **{Name}** | The other person's display name, as stored ("Hermes", "Former competitor") | competitor, participant, opponent, creator |
| **Home** | The first screen, including its hidden navigation title and VoiceOver identity | Sharing |

- Your own side always reads **"YOU"** / "You" (PR 1). Your display name appears only in Account and the avatar.
- When no name is known, say "The other person…" or "Someone".
- **What stays as it is:**
  - Code names: `Competition*` types, the `CompetitionSharingView` type, and the `competition.*` / `competition.sharing.*` identifiers.
  - The server literal "Former competitor".
  - Strings in the DEBUG Test Lab and Staging diagnostics.
  - 1.0.2's own copy ("Invitation unavailable"), quoted only in compatibility tables.
- In code, PR 7 tells an **invite link** (one challenge's single-use token, `/invite/…`) apart from a **challenge link** (a person's reusable link, `/c/…`). Users only ever see "challenge link" and "link".

## 6. PR plan

| PR | Scope | Depends on (must merge first) | Can be built in parallel with | Touches server? |
|---|---|---|---|---|
| **1** Shared wording and formatting | f-round, f-midnight, f-dates, f-vocab. The shared status formatter, number/date helpers and lead line. 10 polish rows | none | none (lands first) | No |
| **2** Real-match data parity | f-remote-empty, f-fresh, Ring panel polish. On-device snapshots for real matches, freshness line, pull to refresh, "not synced yet" | PR 1 | 3, 4, 5, 8 | No. One CompetitionCore change (derived field and display constant) |
| **3** Match and result screens | f-tally, f-chart, f-scheduled, f-mute, f-rules, f-chips, Result title polish | PR 1 | 2, 4, 5, 8 | No |
| **4** Home and History | f-hero, f-pile, f-vanish, f-errors, f-rivalry. Home empty state, Avatar and Deep links polish | PR 1 | 2, 3, 5, 8 | No |
| **5** Notifications | f-lostresult, f-expiry, f-trivial, f-serverpush | PR 1; **PR 4 merges first** (routing) | 2, 3, 8 (build alongside 4) | Yes: the `send-competition-notification` Edge Function only, no migration. Ships independently of the app part (§10 Q1) |
| **6** Challenges, app side | f-lostlink (client), f-invite-errors, f-rematch (client). Challenge code field and Share payload polish | PR 1; **PR 4 merges first** | 2, 3, 5, 8 | No. Relies on create's existing idempotent replay |
| **7** Challenges, server side | f-claim, f-uuid, f-lostlink (Cancel Challenge), f-rematch (overlap rules). Match menu polish (Cancel Match) | PR 1, PR 3, PR 4, PR 6; production server before TestFlight | none (last) | Yes: one migration, a new `preview-competition-invite` function, changes to the create/claim/notification functions, `web/challenge.html`, `_redirects`, `_headers`, AASA |
| **8** First run, Account and remaining polish | f-permfirst, f-notifpage, f-signout, f-welcome. Launch failure, Display name and Delete account polish | PR 1 | 2, 3, 4, 5 | No |

**Sequencing**
1. **PR 1 first.** Every other PR rebases onto it and calls its helpers.
2. **Then PRs 2, 3, 4, 5 and 8 are built in parallel.** Merge PR 4 before PR 5, because PR 5's notification taps rely on PR 4's route hold and its 24 h retention of closed challenges. PR 3 and PR 2 can merge either side of PR 4. PR 3 and PR 5 share two notification titles through the formatter (tallying → "Final score pending", tie → "All square with {Name}"): whichever merges second updates the other's planner test expectations, and until PR 3 lands a tie reads "You tied with {Name}" alone but "All square with {Name}" in PR 5's summary sentence. This merge order is Claude's call.
3. **Then PR 6, then PR 7.** PR 6 needs PR 4: the lapsed-pending → expired projection, `challengeAgainTapped` and `ownProfile`. PR 7 is written against PR 1, 3, 4 and 6 as specified, and its server goes Staging → production before its app parts reach TestFlight.

**Files several PRs touch.** Whichever PR merges second rebases. Each PR's Risks section names the exact regions.

| File | PRs |
|---|---|
| `CompetitionDetailView.swift` | 1, 2, 3, 4, 7, 8 |
| `CompetitionSharingView.swift` | 1, 4, 6, 7, 8 |
| `RemoteCompetitionClient.swift` | 2, 3, 4, 5, 6, 7 |
| `MainTabFeature.swift` | 4, 6, 7, 8 |
| `CompetitionResultView.swift` | 1, 3, 4, 6, 7 |
| `MultiUserCompetitionTestLabView.swift` | 2, 4, 6, 7, 8 |
| `send-competition-notification/index.ts` and the lease function | 5, 7 |

## 7. Traceability

Every audit item has exactly one owning PR. Two findings have a server part in PR 7; the client PR owns them.

**Findings (30)**

| Id | Finding | PR | Note |
|---|---|---|---|
| f-hero | Random hero, the other live match gets a row | 4 | |
| f-pile | MATCHES is one pile; finished weeks never leave | 4 | |
| f-vanish | Expired and declined challenges vanish silently | 4 | |
| f-rivalry | History adds up different people; awards look alike | 4 | |
| f-errors | Errors only on Home, never say which match | 4 | |
| f-round | "You lead by 0"; lead line disagrees with the scores | 1 | |
| f-midnight | "ENDS Nov 4 at 12:00 AM PST" for a Tuesday-night end | 1 | |
| f-vocab | One thing, five names; a screen called "Sharing" | 1 | |
| f-dates | Five date styles; US-only numbers | 1 | |
| f-remote-empty | Real matches: empty Today tab, wrong Activity Sync | 2 | |
| f-tally | Tallying looks final, talks like the engine, three names for Day 7 | 3 | |
| f-fresh | No freshness, no refresh; "not synced" reads as missing | 2 | |
| f-chart | Week chart states look alike | 3 | |
| f-scheduled | Scheduled match shows its end twice, never its start | 3 | |
| f-mute | Mute is per person, hidden, leaves no trace | 3 | Account → Notifications MUTED list is PR 8 (f-notifpage) |
| f-rules | Three privacy stories; no rule for who wins | 3 | Lock-row detail depends on §10 Q2 |
| f-chips | "You Won" next to "2 of 7 days"; unlabeled chips | 3 | |
| f-rematch | Rematch gives no feedback; returns after it's accepted | 6 | Server overlap rules: PR 7 |
| f-uuid | Two trips out of the app and a 36-character code | 7 | Needs the server (§10 Q1) |
| f-lostlink | The share link is easy to lose and can't be recovered | 6 | Cancel Challenge: PR 7. Server re-share only if §10 Q7 is yes |
| f-claim | Accepting never says who sent it | 7 | Needs the server (§10 Q1). Before sign-in stays nameless (§10 Q4) |
| f-invite-errors | Errors blame the wrong thing; setup jargon | 6 | |
| f-permfirst | Five screens before the challenge; Health can't be fixed later | 8 | |
| f-notifpage | Notifications page has nothing to tap; status goes stale | 8 | |
| f-signout | One-tap sign-out; vague failures; mismatched button | 8 | |
| f-welcome | Welcome explains a scoreboard nobody has seen | 8 | |
| f-lostresult | Two matches end together; one result never arrives | 5 | |
| f-expiry | "Expires soon" fires at expiry; tap dumps you on Home | 5 | The tap fix is PR 4's route hold |
| f-serverpush | Vague server alert on every upload; duplicate results | 5 | The server part ships per §10 Q1 |
| f-trivial | "A close competition" at 0–0; "Lead change" with no prior leader | 5 | |

**Polish rows (20)**

| # | Row | PR | Note |
|---|---|---|---|
| 1 | Match status row ("DAY 3 OF 7", one element) | 1 | |
| 2 | Scoreboards ("YOU" on your side) | 1 | |
| 3 | Result labels (all via `SectionLabel`) | 1 | |
| 4 | Ring panel (pause line only when paused) | 2 | PR 3 also listed it; deduplicated to PR 2, whose rewrite deletes the code PR 3 would have edited |
| 5 | Day status ("Day 3 synced") | 1 | |
| 6 | Breakdown (parts add up to the total) | 1 | |
| 7 | VoiceOver (no "--", "upcoming") | 1 | |
| 8 | VoiceOver rows (dates in labels) | 1 | |
| 9 | Nav titles (the person's name) | 1 | PR 6 also changes the outgoing challenge's large title to "Waiting for {Name}" |
| 10 | Match menu (Cancel match / Concede) | 7 | **Partly covered:** Cancel Match ships; Concede is out of scope (Claude's call) |
| 11 | Home empty state ("Nothing live right now") | 4 | |
| 12 | Loading ("Loading matches…") | 1 | |
| 13 | Avatar (initial from the profile) | 4 | |
| 14 | Deep links (close History and sheets first) | 4 | |
| 15 | Challenge code field (one line, Return = Find) | 6 | PR 7 later turns the field into a challenge-link field |
| 16 | Share payload (sender, message, link) | 6 | |
| 17 | Launch failure (title, one line, Try Again) | 8 | |
| 18 | Display name ("That name is reserved") | 8 | |
| 19 | Delete account (drop the middle page; "Account deleted") | 8 | |
| 20 | Result title (two lines, neutral tie) | 3 | |

**Gaps.** Every item is covered. Three are only partly covered:
- Match menu: Concede is deferred.
- f-claim, f-uuid and the server half of f-serverpush depend on the owner shipping the server work (§10 Q1). If it is deferred, those three stay open and PR 6 ships alone.

## 8. Verification per PR

**Every PR goes through these steps, in order:**
1. **Unit tests.** HealthCompTests (and `swift test` in Modules/CompetitionCore when it changes, plus the standalone formatter script when `CompetitionDateFormatting.swift` changes) pass on the Mac mini.
2. **Mac mini build and UI tests.** Both UI suites (`LocalCompetitionLifecycleUITests`, `MultiUserCompetitionUITests`) pass, including the `performAccessibilityAudit` passes (`.dynamicType`, `.textClipped`, `.hitRegion`, `.sufficientElementDescription`). Simulator captures are taken in light and dark at XS and AX5 for the screens listed below.
3. **Preview artifact.** A claude.ai artifact puts the captures next to the audit's Proposed mockup for each finding. The owner approves it before the PR opens; iterate on it, not on the PR. Deviations from the mockup are called out on the artifact, with the reason from the PR's section.
4. **PR CI** (Xcode 16.4, iPhone 16 Pro, iOS 18.5) is the merge gate, including the XcodeGen determinism check and Deno and pgTAP where they apply.
5. **Server changes** (PR 5's function, PR 7's migration, functions and web) go to Staging first, are smoke-tested with the two Staging accounts, then go to production through the beta checklist's approval.

**What each PR adds to those steps**

| PR | Tests beyond HealthCompTests | Captures (light and dark, XS and AX5) | Server / Staging |
|---|---|---|---|
| 1 | Rewritten standalone formatter script; XcodeGen no-diff for `project.yml` and `Info.plist`; about 70 UI-test string edits | Home card, match screen, result | none |
| 2 | `swift test` (CompetitionCore); standalone script (`competitionUpdatedText`) | Today page (scored, earlier reading, not synced), day drawer | One Staging run with two accounts: rows, freshness line, pull to refresh, airplane-mode relaunch. No promotion |
| 3 | Standalone script (`competitionDeadlineText`); confirm the ••• menu subtitle renders on iOS 18.5 (fallback in PR 3 Design C) | Scheduled, Day 3 Week tab with no data / not synced, tallying, win, loss and tie results, ••• menu | none |
| 4 | MainTabFeatureTests route-hold tests; confirm the horizontal swipe row doesn't fight vertical scroll | Home (one live, two live, closed row, empty with History), History | none |
| 5 | `deno test` for `send-competition-notification`; on a device: two Test Lab results post one summary, and a kept result tap opens the match from History | none (no UI change) | Function to Staging; `score_update` and `result` rows reach `discarded` with no push; then production; update `competition-support.md` |
| 6 | RemoteCompetitionFeatureTests rewrite; replay-store tests | + sheet states, pending challenge screen, rematch rows at AX5 | none |
| 7 | pgTAP `020_…`, Deno for 3 functions plus the race test, `invitation-page.test.ts`, recovery harness, `verify-website.sh` | Claim sheet, link sheet, Account challenge link, QR sheet | PR 7 Server §4 order. Includes AASA on Apple's CDN and cold/warm `/c/` taps on a physical iPhone. Production before TestFlight |
| 8 | AppFeature teardown and route tests; the Settings → Health entry check on iOS 18.5 | Color hint, Account → Health, Account → Notifications, Welcome (both variants) | none |

**Accessibility identifier changes (all PRs)**

Unchanged everywhere: `competition.create.open`, `competition.create.empty`, `competition.more`, `competition.history.open`, `competition.sharing.<lifecycle>.<uuid>`, `account.privacy`, `competition.scoreHeader.naren/.alex`, `competition.day.<n>`, `competition.result`, `competition.notifications.mute`, `competition.claim.sheet/.accept/.retry/.dismiss`. Navigation-bar titles do change: "Sharing" → "Home", and the match, challenge and result screens take the person's name (PR 1 lists every UI-test edit).

| PR | Added | Removed | Moved, or same id with new behavior |
|---|---|---|---|
| 1 | `competition.status` | none | none |
| 2 | `competition.updated`, `competition.notSynced` | `competition.ownerActivityText` (unreferenced) | `competition.ownerRings` is now the ring-list panel |
| 3 | `competition.tally`, `competition.result.summary` | none | `competition.schedule.dates` moves to the "Day 1 is …" line; `competition.notifications.preference-error` moves to the top of the scroll |
| 4 | `competition.home.needsYou/.live/.upNext/.results`, `competition.closedRow.again.<uuid>`, `competition.closedRow.dismiss.<uuid>`, `competition.closed`, `competition.closed.again`, `competition.archive.<uuid>`, `competition.issue.<uuid>`, `competition.issue.retry.<uuid>`, `competition.record.<uuid>` | none | `competition.rivalry` moves to the RECORD section; `competition.sharing.expired/.declined.<uuid>` are now rendered on closed rows |
| 5 | none | none | none |
| 6 | `competition.create.time-zone/.recipient-error/.send-error/.open-existing`, `competition.invite.share/.share-retry/.link-missing/.expiry`, `competition.rematch.sent/.next/.open-existing/.error/.share-retry` | none | `competition.rematch.create` is now also on the local button; `competition.create.already-pending` and `.configuration-error` are on new elements |
| 7 | `competition.claim.not-now/.sender/.start/.decline-error`, `competition.invite.accept/.decline/.cancel/.error`, `competition.match.cancel`, `competition.cancel.error`, `competition.sharing.cancelled.<uuid>`, `competition.link.sheet/.name/.send`, `competition.create.share-own-link/.conflict`, `competition.rematch.view-match/.review`, `account.challenge-link.url/.show-code/.share/.qr/.retry` | `account.settings.share-account-code` | `competition.claim.decline` now opens a server-decline confirmation; `competition.create.recipient-code` accepts a challenge link; `competition.create.find-recipient` is labeled "Find" |
| 8 | `account.health`, `account.health.connect`, `account.health.settings`, `account.notifications.settings`, `account.notifications.unmute`, `account.sign-out.confirm`, `account.subtitle` | `account.delete.open` | `account.delete` is now the Account-root row; `onboarding.notNow` is also on the in-context notifications sheet; `competition.claim.dismiss` is also the Done button of `.wrongAccount` |

## 9. The 8 PR sections

How to read these sections:
- Line numbers are from `main` at 7c5853f unless marked otherwise. After rebasing onto earlier PRs, re-anchor by symbol name.
- Each section's "Verify on the Mac mini" list comes on top of the shared steps in §8.
- Each section's open questions have moved to §10. In-text references read "§10 Q<n>".
- Where the input sections disagreed, the text below has been reconciled. §11 "Made during assembly" lists each change.
- Apostrophes in shipped copy are typographic (’), as in today's code, even where a table below types a straight one ("didn't", "That's"). Exact-string tests match the code.

### PR 1 — Shared wording and formatting (foundation)

#### Scope
- **f-round**: whole points wherever totals or days are compared. The lead line and margins come from the displayed values. No "+0", "−0" or "by 0".
- **f-midnight**: the end names the last day ("Ends Tue night", "Ends at midnight"), a scheduled match shows its start, and a zone suffix appears only when the zone differs from the phone's.
- **f-dates**: one locale-aware style each for a day, a week and a moment. Notification numbers use the user's locale.
- **f-vocab**: Match / Challenge / {Name} / Home in every shipped string. The navigation title and VoiceOver identity read "Home". The DEBUG Test Lab, the Staging diagnostics page and web/ are excluded.
- Polish **Match status row**: "DAY 3 OF 7" as one accessibility element.
- Polish **Scoreboards**: "YOU" on your side, their name on theirs.
- Polish **Result labels**: every section label goes through `SectionLabel`.
- Polish **Day status**: "Day 3 Activity observed" becomes "Day 3 synced".
- Polish **Breakdown**: round once and give the remainder to the largest part.
- Polish **VoiceOver**: no more "--" or "future, --".
- Polish **VoiceOver rows**: reuse the visible status line, dates included.
- Polish **Nav titles**: the other person's name on the match, challenge and result screens.
- Polish **Loading**: "Loading matches…".
- One shared lifecycle status formatter with row, card and notification styles. The match screen uses the card style.

#### Behavior

##### Numbers (f-round)
- **The rule.** A score is shown as whole points, rounded half away from zero: 382.2 → 382, 0.5 → 1, 412.5 → 413. Numbers are grouped in the user's locale: en "1,217", de "1.217", fr "1 217". A missing value still draws "--" on screen; VoiceOver never reads it (see VoiceOver).
- **Where it applies.** Home card scoreboard, match screen totals and Today row, Home/History rows ("382 / 0"), week chart day values, ring panel accepted points, local notifications.
- **Lead line** (match screen and Home card). The margin is `round(you) − round(them)`:
  - margin > 0: "You lead by 12." The number is bold amber.
  - margin < 0: "Hermes leads by 382." The number is bold ink. The Home card used to show the opponent's number unbolded; both screens now use this styling.
  - margin == 0: "All square." This covers 0–0 on Day 1, exact ties, and a 0.03-point lead that shows as 0–0.
- **Who won a day** compares displayed whole values: the week strip color, the chart's bright/dim numbers and the result's "N of 7 days". A day showing 300 vs 300 is a tie, in neutral.
- **Days vs the week total (Claude's call).** Each day is rounded on its own, and the week total is rounded once from its exact value. There is no week-level remainder rule, so the seven shown days can differ from the shown total by up to 3 points (seven days of 100.4 show as 100 each, under a total of 703). Reasons:
  - A day keeps one number everywhere it appears: the chart, its drawer, its VoiceOver row, the "HOW TODAY ADDS UP" total and its win/loss color. A remainder rule would make the chart's day disagree with that day's own drawer, and it could flip day wins and the "N of 7 days" count.
  - No screen adds up the seven days. The audit's f-round complaint was the lead line disagreeing with the scores above it, plus mixed decimals. Both are fixed by the rules above.
  - The total stays tied to the exact ledger (scores are stored in hundredths, `RemoteCompetitionClient.swift:1707`, `:1882-1887`), so the shown winner always matches the decided outcome.
  - The result tie-break is unaffected: it compares only the two totals. When it shows "412.30 – 412.00", the "HOW YOU SCORED" parts still add up to the whole 412.
- **Results (Claude's call).** Whole points, except when a decided match would show the same whole number on both sides (exact totals differ by less than one displayed point). In that case the final totals, the margin chip and VoiceOver use exactly 2 decimals: "412.30 – 412.00", chip "+0.30". Without this, the screen would say "Hermes won" over "412 – 412". An exact tie stays whole, with no chip. The same digit count is used on the result screen, in the trailing score and VoiceOver of finished rows, and in the result notification body.
- **Margin chip.** "+12" / "−12", computed from displayed values. Hidden when the displayed margin is 0. PR 3 (f-chips) adds its label.
- **Breakdown** (match screen "HOW TODAY ADDS UP", result drawer "HOW YOU SCORED"). Whole parts that add up exactly to the whole total. Round each part, then add `round(total) − Σ rounded parts` to the part with the largest raw value (the first one on ties). Example: 120.4 + 80.4 + 31.4 = 232.2 shows as **121 + 80 + 31 = 232**. Bar widths keep the raw values.
- **VoiceOver unit.** "1 point" when the displayed value is 1 (so 0.6 reads "1 point"), otherwise "N points". A missing value reads "no points yet".

##### End and start (f-midnight)
The status row has a title and a timing. The strings are sentence case in code and drawn uppercase:

| State | Title | Timing |
|---|---|---|
| Scheduled | SCHEDULED | STARTS WED, OCT 28 |
| Day 1–6 | DAY 4 OF 7 | ENDS TUE NIGHT |
| Day 7 | LAST DAY | ENDS AT MIDNIGHT |
| Tallying | TALLYING | — |

- **Which day.** "Tue" is the 7th day of the match calendar: a week from Wed Oct 28 to Tue Nov 3 reads "Tue". The start is the first day, in the day style.
- **No noise.** No year, no clock time, and never the exclusive midnight boundary.
- **Zone suffix (Claude's call; §10 Q14).** Compare the match calendar's UTC offset with the phone's at the boundary instant: the end for Day 1–7, the start for Scheduled. If they differ, append the calendar zone's abbreviation: "ENDS TUE NIGHT PST", "ENDS AT MIDNIGHT PST", "STARTS WED, OCT 28 PDT". An America/Vancouver phone on an America/Los_Angeles match has the same offset, so no suffix.
- **Deviation from the mockup.** "STARTS WED, OCT 28" keeps the locale's comma, because it reuses the single day style. The mockup has "WED OCT 28".
- **Scheduled card** on the match screen (`competition.schedule.dates`) shows the inclusive week, "Oct 28 – Nov 3". Today it shows "Oct 28, 2026, 12:00 AM – Nov 4, 2026, 12:00 AM PST". PR 3 (f-scheduled) restructures the card itself.
- **Supersedes an earlier plan.** This replaces the end badge and schedule range from docs/plans/2026-10-27-local-time-displays.md (local date-time plus zone); the owner approved the audit later. Activity reads and the tally deadline stay in phone-local time.

##### Dates (f-dates)

| Job | en_US output | Used by |
|---|---|---|
| Day | "Thu, Oct 29"; adds ", 2025" when not the current year | day drawer subtitle, stacked chart rows, "Earned Fri, Oct 30", History "Latest victory Fri, Oct 30", VoiceOver day rows, scheduled start |
| Day, no weekday | "Oct 29" | match screen chart date line under "THU" (the weekday is already the line above) |
| Week | "Oct 24 – 30", "Oct 28 – Nov 3"; adds the year when the last day is not in the current year | row status, result kicker "FINAL · OCT 24 – 30", result week drawer subtitle, scheduled card |
| Moment | "Tue 9:41 PM" within 6 days of now; otherwise "Oct 21, 9:41 PM" (adds the year if different) | Activity Sync lines, tally deadline |
| Number | 1,217 · 1.217 · 1 217 | everywhere, including notifications |

- **How it is formatted.** DateFormatter templates and DateIntervalFormatter, with the injected locale. Calendar days (`CompetitionDay`) are formatted in UTC so they never shift. Instants are formatted in the phone's zone, with no zone suffix.
- **What "now" is (Claude's call).** "Now", which sets the year suffix and the moment style's 6-day window, is the projection's time, not the wall clock. Screens that draw a match pass `competition.evaluatedAt`. Home and History award and rivalry lines pass `publication.evaluatedAt`. The rest of the screen ("Day 4 of 7", "Today", "Last day") is already computed at that instant, so the dates agree with it. On real matches it is the wall time of the latest refresh (`context.instant.wallDate`), so the output matches `Date()` in practice. The Test Lab's logical date (`MultiUserCompetitionTestLabView.swift:613`, `:666`) then gives stable labels and captures whatever the wall clock says, including after January 2027. The formatters in A and B keep `now: Date = Date()` as a default only for the standalone script and the unit tests. No app call site relies on that default.

##### Shared status (same state, same words)
The formatter returns `title` + `timing`. A row draws `line` = "title · timing".

| Lifecycle | row | card (Home card and match screen) | notification title |
|---|---|---|---|
| pending, outgoing | Challenge sent | Challenge sent | Challenge to {Name} |
| pending, incoming | Challenge received | Challenge received | {Name} challenged you |
| declined / expired | Declined / Expired | same | Challenge declined / Challenge expired |
| scheduled | Starts Wed, Oct 28 | Scheduled · Starts Wed, Oct 28 | Starts Wed, Oct 28 |
| scheduled, no schedule | Scheduled | Scheduled | Scheduled |
| active(n) | Day n of 7 · Ends Tue night | same | Day n of 7 |
| endsToday | Last day · Ends at midnight | same | Last day |
| tallying | Tallying | same | Tallying |
| finished, win | You won · Oct 24 – 30 | same | You beat {Name} |
| finished, loss | {Name} won · Oct 24 – 30 | same | {Name} won |
| finished, tie | Tied · Oct 24 – 30 | same | You tied with {Name} |

- **Notification timing** is always nil.
- **Claude's call on result wording.** The winner is named because "Won" under someone else's name was ambiguous.
- **On screen.** Home card: "● LIVE  DAY 4 OF 7 … ENDS TUE NIGHT". Match screen: "● DAY 4 OF 7 … ENDS TUE NIGHT" (the dot shows on Day 1–7). At accessibility sizes the title and timing stack, using the existing AnyLayout switch. Timing wraps rather than truncating.
- **Long names** wrap in rows and in the lead line. Navigation titles tail-truncate (UIKit default).
- **Multiple matches and repeat opponents.** Every card and row calls the same function. Repeat weeks with the same person differ by their week dates, both on screen and in VoiceOver.

##### YOU on your side (Scoreboards polish)
- **Shows "YOU":**
  - Home card scoreboard
  - match screen scoreboard
  - Home scheduled headline ("YOU VS HERMES")
  - result final score ("You")
  - stacked chart rows at accessibility sizes ("You")
  - every VoiceOver label below
- **The other side** shows their name.
- **Your display name stays** only in Account, the avatar and the ring panel's VoiceOver "Naren activity". ActivityRingsView is not touched; PR 2 owns that panel.

##### VoiceOver
- **Match screen status row** is one element with identifier `competition.status` and label = `line`: "Day 4 of 7 · Ends Tue night", "Scheduled · Starts Wed, Oct 28", "Last day · Ends at midnight", "Tallying".
- **Rows and the Home card**: "{Name}. {row line}. [fixture disclosure.] [You 412 points. {Name} 380 points.]". Example: "Hermes. You won · Oct 24 – 30. You 412 points. Hermes 380 points". There are no scores for challenge or scheduled rows.
- **Score headers** (`competition.scoreHeader.naren` / `.alex`):
  - "You, Today 312 points, total 1,450 points"
  - before a score: "You, Today no points yet, total 0 points"
  - while tallying: "You, Final day 300 points, provisional total 1,450 points"
  - the other side: "Hermes, Today 290 points, total 1,440 points"
- **Day rows:**
  - today: "Day 3, Today, scores so far. You, 312 points. Hermes, 290 points."
  - closed: "Day 2, Sun, Aug 9, complete. You, 321 points. Hermes, 300 points." If their score is missing: "… Hermes, score not available."
  - future: "Day 5, Thu, Oct 29, upcoming." with no per-person parts.
- **Your side of a day:**
  - synced, no score: "You, synced, no score yet"
  - missing: "You, missing activity data, no points yet" (or "…, 412 points")
  - unavailable: "You, Activity source is temporarily unavailable, no points yet"
- **Result**: "You Won. Final score. You 4,200 points. Alex 3,900 points."
- **Breakdown**: "Move 121 plus Exercise 80 plus Stand 31 equals 232 points."

##### Navigation titles and small polish
- **Nav titles.** The match screen, both challenge directions and the result screen use `competition.opponentDisplayName` as the inline title.
- **Result kicker** drops "VS {NAME}" because the title now carries the name: "FINAL · OCT 24 – 30".
- **Challenge screen large title**: "Challenge from Hermes" / "Challenge to Hermes". The claim sheet title is "Challenge".
- **Home title** is "Home": still visually hidden, but it is the VoiceOver and navigation identity. The back-button label is unchanged, because destinations use `.toolbarRole(.editor)`.
- **Day status**: "Day 3 synced".
- **Loading**: "Loading matches…".
- **Result section labels**: `SectionLabel("FINAL SCORE")`, `SectionLabel("THE WEEK")`, `SectionLabel("AWARDS")`. They become ink with the header trait (today "Final score" is secondary).

##### Glossary sweep (f-vocab): exact replacements
| File:line | Now | After |
|---|---|---|
| CompetitionSharingView.swift:55 | "Sharing" | "Home" |
| CompetitionSharingView.swift:124, :822 | "Opens this competition" | "Opens this match" |
| CompetitionSharingView.swift:186 | "Opens finished competitions and awards" | "Opens finished matches and awards" |
| CompetitionSharingView.swift:196 | "No competition yet" | "No matches yet" |
| CompetitionSharingView.swift:214 | "Invite \(Alex) Again" | "Challenge \(Alex) Again" |
| CompetitionSharingView.swift:242 | "The previous invitation closed. You can invite Alex again." | "The last challenge closed. You can challenge Alex again." |
| CompetitionSharingView.swift:243 | "A local invitation will appear here." | "A local challenge will appear here." |
| CompetitionSharingView.swift:245 | "Create and share a private invitation to begin." | "Challenge someone to start a match." |
| CompetitionSharingView.swift:260 | "Competition status. …" | "Match status. …" |
| CompetitionSharingView.swift:641; CompetitionResultView.swift:407 | "Competition Complete" | "Match Complete" |
| CompetitionSharingView.swift:713 | "COMPETITION HISTORY" | "MATCH HISTORY" |
| CompetitionSharingView.swift:836 | "Awards appear here when a competition finishes." | "Awards appear here when a match finishes." |
| CompetitionSharingView.swift:1128 | "Local competition storage is unavailable." | "Match storage on this iPhone is unavailable." |
| CompetitionSharingView.swift:1134 | "Competition data could not be refreshed." | "Matches could not be refreshed." |
| CompetitionSharingView.swift:1143 | "Some competition activity could not be refreshed." | "Some matches could not be refreshed." |
| CompetitionSharingView.swift:1149 | "Competition is available, but Activity could not be refreshed." | "Matches loaded, but Activity could not be refreshed." |
| CompetitionSharingView.swift:1151 | "The latest competition action could not be completed." | "The last match action could not be completed." |
| CompetitionDetailView.swift:47 | Picker "Competition view" | "Match view" |
| CompetitionDetailView.swift:184 | "Starts next competition day" | "Starts next match day" |
| CompetitionDetailView.swift:187 | "Your stored schedule sets the seven competition days." | "Your saved schedule sets the seven match days." |
| CompetitionDetailView.swift:994 | "Waiting for the first complete post-competition Activity check." | "Waiting for the first complete Activity check after the match." |
| CompetitionDetailView.swift:1126 | "…under the competition scoring policy." | "…under the match scoring rules." |
| CompetitionWeekChart.swift:162 | "Move, Exercise and Stand are your rings. \(name) is your opponent." | "Move, Exercise and Stand are your rings. The single bar is \(name)." |
| CompetitionResultView.swift:57 | "Archived competition history is preserved." | "Archived match history is preserved." |
| CompetitionResultView.swift:99 | "Delete this competition from this iPhone?" | "Delete this match from this iPhone?" |
| CompetitionResultView.swift:109 | "This permanently removes the local competition journal and its notifications." | "This permanently removes the match and its notifications from this iPhone." |
| CompetitionResultView.swift:516 / :525 / :538 | "Create Rematch Invitation" / "Creating rematch invitation…" / "Share Rematch Invitation" | "Create Rematch Challenge" / "Creating rematch challenge…" / "Share Rematch Challenge" |
| CompetitionResultView.swift:565; CreateCompetitionView.swift:218 | "An invitation to this account is already pending. …" | "A challenge to this account is already waiting. It expires 24 hours after it was created." |
| CompetitionInviteView.swift:28 | "Decline invitation from \(n)?" | "Decline challenge from \(n)?" |
| CompetitionInviteView.swift:31 / :32 | "Keep Invitation" / "Decline Invitation" | "Keep Challenge" / "Decline Challenge" |
| CompetitionInviteView.swift:36 | "This closes the invitation without starting a competition." | "This closes the challenge without starting a match." |
| CompetitionInviteView.swift:68 | "…accepting this local invitation." | "…accepting this local challenge." |
| CompetitionInviteView.swift:84 | "Open the invitation link to review and accept" | "Open the challenge link to review and accept" |
| CompetitionInviteView.swift:105 | hint "Accepts the local simulated competition" | "Accepts the local simulated match" |
| CompetitionInviteView.swift:124 / :140 | "Accept invitation from \(n)" / "Decline invitation from \(n)" | "Accept challenge from \(n)" / "Decline challenge from \(n)" |
| CompetitionInviteView.swift:126 / :142 | "Starts on the next competition calendar day." / "Closes this invitation without starting." | "Starts on the next match calendar day." / "Closes this challenge without starting." |
| CompetitionInviteView.swift:184 | "\(n) invited you to compare Activity points for seven days." | "\(n) challenged you to compare Activity points for seven days." |
| CompetitionInviteView.swift:187 | "Only this HealthComp account can accept. The invitation expires 24 hours after creation. Day 1 begins on the next competition calendar day after acceptance." | "Only this HealthComp account can accept. The challenge expires 24 hours after it was created. Day 1 begins on the next match calendar day after they accept." |
| CompetitionInviteView.swift:188 | "…next competition calendar day." | "…next match calendar day." |
| CompetitionInviteView.swift:293; PermissionOnboardingView.swift:98 | "Derived competition data is shared" | "Derived match data is shared" |
| CompetitionInviteView.swift:317 / :318 | "Invitation from \(n)" / "Outgoing invitation to \(n)" | "Challenge from \(n)" / "Challenge to \(n)" |
| ClaimCompetitionView.swift:39 | "Competition Invitation" | "Challenge" |
| ClaimCompetitionView.swift:107, :111 | "Accept Invitation"; hint "Claims the private invitation and schedules the competition." | "Accept Challenge"; "Accepts the challenge and schedules the match." |
| ClaimCompetitionView.swift:114, :127, :116 | "Decline Invitation"; hint "Closes this invitation on this device without joining." | "Decline Challenge"; "Closes this challenge on this device without joining." |
| ClaimCompetitionView.swift:181 / :183 / :185 / :189 | "Join this competition?" / "Accepting invitation…" / "Confirming competition…" / "Invitation unavailable" | "Join this match?" / "Accepting challenge…" / "Confirming match…" / "Challenge unavailable" |
| ClaimCompetitionView.swift:198 | "Accept to start a private seven-day Activity competition on the creator’s calendar schedule." | "Accept to start a private seven-day Activity match on the sender’s calendar." |
| ClaimCompetitionView.swift:200 | "HealthComp is securely claiming this single-use invitation." | "HealthComp is securely accepting this single-use challenge." |
| ClaimCompetitionView.swift:202 | "The server accepted your invitation. Waiting for the confirmed competition before opening it." | "The server accepted your challenge. Waiting for the confirmed match before opening it." |
| ClaimCompetitionView.swift:204 | "…has not received the confirmed competition yet. Try refreshing or check Sharing later." | "The server accepted your challenge, but HealthComp hasn’t received the confirmed match yet. Try refreshing or check Home later." |
| ClaimCompetitionView.swift:206 | "…Ask the sender for a new invitation." | "This link may be expired, already used, or no longer valid. Ask the sender for a new challenge." |
| ClaimCompetitionView.swift:208 | "The invitation is still private on this device. …" | "The challenge is still private on this device. Check your connection and try again." |
| CreateCompetitionView.swift:28 / :32 | "Your competition calendar uses \(tz)." / a11y "Competition time zone, \(tz)" | "Your match calendar uses \(tz)." / "Match time zone, \(tz)" |
| CreateCompetitionView.swift:133 | "Invite \(name)" | "Challenge \(name)" |
| CreateCompetitionView.swift:137 | "…before creating the invitation." | "…before creating the challenge." |
| CreateCompetitionView.swift:155 / :160 / :166 | "Create Private Invitation" / "Creating invitation…" / a11y "Creating private invitation" | "Create Challenge" / "Creating challenge…" / "Creating challenge" |
| CreateCompetitionView.swift:173 / :176 | subject "Join my HealthComp competition" / "Share Private Invitation" | "Join my HealthComp match" / "Share Challenge" |
| CreateCompetitionView.swift:200 | "HealthComp couldn’t create the invitation. Your request can be retried safely." | "HealthComp couldn’t create the challenge. It’s safe to try again." |
| CreateCompetitionView.swift:210 | "Private invitation links are not configured for this build." | "Challenge links are not configured for this build." |
| MainTabView.swift:99 | "Loading local competition…" | "Loading matches…" |
| MainTabView.swift:230 / :232 | "Invitation Closed" / "Return to Sharing to see current competitions." | "Challenge Closed" / "Go back to Home to see your matches." |
| MainTabView.swift:237 / :239 | "Competition Unavailable" / "Return to Sharing to refresh this competition." | "Match Unavailable" / "Go back to Home to refresh this match." |
| AccountView.swift:122; AccountSettingsView.swift:294 | "Competitors receive daily points, rounded Activity percentages and modes(.)" | "The other person gets your daily points, rounded Activity percentages and modes(.)" (keep each site's trailing period as today) |
| AccountView.swift:252 | "Sign in to join private Activity competitions." | "Sign in to play private Activity matches." |
| AccountView.swift:254 | "Your competitor will see this name. You can change it later." | "The people you play will see this name. You can change it later." |
| AccountView.swift:260; AccountSettingsView.swift:199 | "…local competition cache…" | "…local match cache…" |
| AccountSettingsView.swift:89 | "Display name · shown to competitors" | "Display name · shown to people you play" |
| AccountSettingsView.swift:122 | "…your competition history." | "…your match history." |
| AccountSettingsView.swift:244 / :254 / :265 | "Competition notifications" / "Enable Competition Notifications" / "Competition notifications are disabled in Settings." | "Match notifications" / "Enable Match Notifications" / "Match notifications are disabled in Settings." |
| AccountSettingsView.swift:275 | "HealthComp only sends competition moments, …" | "HealthComp only sends match moments, like lead changes and results. To mute someone, open your match with them." |
| AccountSettingsView.swift:336 | "Deletion is permanent. Active competitions are cancelled, … for the other participant as Former competitor." | "Deletion is permanent. Live matches are cancelled, this profile’s local data is removed, and finished matches stay in the other person’s history under the name Former competitor." ("Former competitor" is the server's literal placeholder, so it stays.) |
| PermissionOnboardingView.swift:62 / :63 | "…to score each competition day." / "HealthComp only sends competition moments, like these." | "…to score each match day." / "HealthComp only sends match moments, like these." |
| RemoteCompetitionClient.swift:1581 | "Waiting for competitor" | "Someone" (only reachable for invitations created before recipient binding; bound invitations always have the invitee as a participant, see supabase/migrations/20261019001800_bind_invitation_recipients.sql:201-203) |
| project.yml:46 and Info.plist:39 | "HealthComp reads your activity data to score competitions with friends." | "HealthComp reads your Activity data to score matches with friends." |
| project.yml:48 and Info.plist:41 | "…for Activity competitions…" | "HealthComp uses read-only Health access for Activity matches and does not save or change Health data." |

Local notification copy, from `CompetitionNotificationPlanner.swift:66-130`:

| Family | Title | Body |
|---|---|---|
| inviteExpiry | Challenge expiring | Your challenge with {Name} expires soon. |
| scheduledStart | Day 1 of 7 *(formatter)* | Your match with {Name} starts today. |
| finalDay | Last day *(formatter)* | Today is the last day of your match with {Name}. |
| competitionEnded | Tallying *(formatter)* | HealthComp is checking the latest Activity data before finalizing your result with {Name}. |
| leadChange | Lead change | The lead changed in your match with {Name}. You 1,217, {Name} 1,194. |
| closeScore | A close match | Your match with {Name} is close. You 1,217, {Name} 1,194. |
| dailyMaximum | Daily maximum reached | You reached 600 points today against {Name}. |
| result | You beat {Name} / {Name} won / You tied with {Name} *(formatter)*; when the outcome is nil: "Match complete" | Final score: You 2,431, {Name} 2,198. When points are missing: "Your match with {Name} is complete." |
| catchUp | Match update | Open HealthComp for the latest on your match with {Name}. |

- **Scores in notifications** are whole and use the user's locale. The result body uses the tie-break digits from Numbers.
- **Onboarding samples** (`PermissionOnboardingView.swift:155-170`) are generated from this policy instead of hard-coded strings, so they cannot drift (see Design E).

#### Design

**A. `HealthComp/Features/Competition/CompetitionDateFormatting.swift`: must stay Foundation-only.** CI compiles this file on its own with `scripts/tests/competition-local-date-formatting.swift` (`scripts/test-competition-local-date-formatting.sh`, CI step "Verify local-time display formatting", `.github/workflows/ci.yml:88`). Do not import CompetitionCore or SwiftUI here.
- **Delete** `competitionDateRangeText` (:3-15), `competitionDateTimeText` (:17-29) and `competitionAwardDateText` (:31-42).
- **Move here** `competitionPointsText` from MainTabView.swift:280-283 (delete it there) and `competitionPointsAccessibilityText` from CompetitionDetailView.swift:961-965 (delete it there).
- **Add:**
```swift
private func competitionDisplayedPoints(_ points: Double, _ fractionDigits: Int) -> Double {
    let scale = pow(10, Double(fractionDigits))
    return (points * scale).rounded(.toNearestOrAwayFromZero) / scale
}
func competitionPointsText(_ points: Double?, fractionDigits: Int = 0, locale: Locale = .current) -> String {
    guard let points else { return "--" }
    return competitionDisplayedPoints(points, fractionDigits)
        .formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
}
func competitionPointsAccessibilityText(_ points: Double?, fractionDigits: Int = 0, locale: Locale = .current) -> String
    // nil → "no points yet"; displayed value == 1 → "1 point"; else "\(text) points"
func competitionDisplayedMargin(userPoints: Double, opponentPoints: Double, fractionDigits: Int = 0) -> Double
    // displayed(user) − displayed(opponent)
func competitionFinalFractionDigits(userPoints: Double, opponentPoints: Double) -> Int
    // userPoints != opponentPoints && competitionDisplayedMargin(...) == 0 ? 2 : 0
func competitionRoundedParts(_ parts: [Double], total: Double) -> [Double] {
    var rounded = parts.map { $0.rounded(.toNearestOrAwayFromZero) }
    guard let largest = parts.indices.max(by: { parts[$0] < parts[$1] }) else { return rounded }
    rounded[largest] += total.rounded(.toNearestOrAwayFromZero) - rounded.reduce(0, +)
    return rounded
}
func competitionDayText(_ date: Date, weekday: Bool = true, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
    // template: (weekday ? "EEE" : "") + (sameYear ? "" : "y") + "MMMd"
func competitionWeekText(_ first: Date, _ last: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
    // DateIntervalFormatter, gregorian, dateTemplate sameYear(last) ? "MMMd" : "yMMMd"
func competitionMomentText(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
    // |date − now| < 6 × 86_400 ? "EEEjmm" : (sameYear ? "MMMdjmm" : "yMMMdjmm")
func competitionAwardEarnedText(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
    // "Earned \(competitionDayText(date, now:, locale:, timeZone:))"
```
- **Two private helpers.** One builds a gregorian `DateFormatter` with `setLocalizedDateFormatFromTemplate`. The other answers "same year as `now`", using a gregorian calendar in `timeZone`.

**B. CompetitionDay adapters: `CompetitionWeekChart.swift:397-409`** (next to `weekdayText`, which already builds the UTC date).
- **`weekdayText`** becomes `weekdayText(_ day: CompetitionDay, locale: Locale = .current) -> String` and returns "Wed" (drop `.uppercased`). Its two callers (:89-101 strip, :285 DayLabel) add `.textCase(.uppercase)`, so the screen still shows "WED".
- **Add** `competitionDayText(_ day: CompetitionDay, weekday: Bool = true, now: Date = Date(), locale: Locale = .current) -> String` and `competitionWeekText(_ first: CompetitionDay, _ last: CompetitionDay, now: Date = Date(), locale: Locale = .current) -> String`. Each converts the day(s) to UTC midnight and calls A with `TimeZone(identifier: "UTC")!`.

**C. Status formatter: `CompetitionSharingView.swift:1046-1065`.** It replaces `competitionSharingStatus`, which is deleted.
```swift
enum CompetitionStatusStyle: Equatable, Sendable { case row, card, notification }
struct CompetitionStatusText: Equatable, Sendable {
    let title: String
    let timing: String?
    var line: String { [title, timing].compactMap { $0 }.joined(separator: " · ") }
}
func competitionStatusText(_ competition: LocalCompetitionPresentation, style: CompetitionStatusStyle,
                           locale: Locale = .current, timeZone: TimeZone = .current) -> CompetitionStatusText
    // forwards lifecycle, acceptedConfiguration?.schedule, opponentDisplayName, now: competition.evaluatedAt
func competitionStatusText(_ lifecycle: LocalCompetitionLifecyclePresentation, schedule: CompetitionSchedule?,
                           opponentDisplayName: String, style: CompetitionStatusStyle,
                           now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> CompetitionStatusText
```
- **Strings**: the table under "Shared status".
- **Inputs**: `days = try? schedule.calendar.sevenDayWindow(startingOn: schedule.startDay)` and `bounds = competitionScheduleBoundaries(schedule)` (kept at CompetitionDetailView.swift:909-924).
- **Ends**: `"Ends \(weekdayText(days.last, locale:)) night" + zone(bounds.end)` and `"Ends at midnight" + zone(bounds.end)`.
- **Starts**: `"Starts \(competitionDayText(days.first, now:, locale:))" + zone(bounds.start)`.
- **Week**: `competitionWeekText(days.first, days.last, now:, locale:)`.
- **Zone suffix**: `zone(t)` returns `" " + (calZone.abbreviation(for: t) ?? id)` when `calZone.secondsFromGMT(for: t) != timeZone.secondsFromGMT(for: t)`, otherwise `""`.
- **Missing schedule**: when `schedule` or `days` is nil, timing is nil and scheduled falls back to "Scheduled".
- **Why no fourth style.** The match screen uses `.card`; it is the same status row by design, and a `.detail` case would duplicate it.

**D. Lead line: `CompetitionDetailView.swift`, global placed after `competitionScorePeriodLabel` (:1082-1087).**
```swift
@MainActor
func competitionLeadText(userPoints: Double, opponentPoints: Double, opponentDisplayName: String, locale: Locale = .current) -> Text
```
- **Body**: `margin = competitionDisplayedMargin(...)`. 0 → `Text("All square.")`. Above 0 → `Text("You lead by ") + Text(competitionPointsText(abs(margin), locale: locale)).fontWeight(.bold).foregroundStyle(Theme.you) + Text(".")`. Below 0 → the same with the name and `Theme.ink`.
- **Callers**: `leadText` (:122-134) becomes a call to it, and the Home card's `statement` (CompetitionSharingView.swift:372-387) is replaced by it.

**E. Call sites**

Every call site below that formats a date passes `now: competition.evaluatedAt` (or `publication.evaluatedAt` on Home/History), per "What now is". This is written as `now:` below.

CompetitionDetailView.swift
- :71 → `.navigationTitle(competition.opponentDisplayName)`.
- :153 `competitionTallyDeadlineText(...)` call → add `now:`.
- :175-177 → `competitionScheduleDateRangeText(schedule, now:, locale: locale)`.
- :896-907 changes to `competitionScheduleDateRangeText(_ schedule: CompetitionSchedule, now: Date = Date(), locale: Locale = .current) -> String?`. It returns `competitionWeekText(window.first, window.last, …)` and returns nil when `sevenDayWindow` throws (the mismatched-zone fallback is preserved).
- :205-225 `dayBreakdown` → pass `segments: competitionRoundedParts(segments.map { $0.points }, total: total)`. `TodayBreakdown` (:709-840) stays as is and now draws whole numbers. Its a11y label (:734) reads the rounded parts.
- :230-238, :308-313: replace the `ownerName:` argument with `now: competition.evaluatedAt` (see F).
- :302-307 drawer subtitle → `competitionDayText(day.day, now:)`.
- :326-331 → `competitionRefreshTimelineText(..., now:, locale:, timeZone:)`. It gains `now: Date = Date()` and uses `competitionMomentText` at :1043 and :1048. `competitionTallyDeadlineText` (:1056-1076) gains `now:` the same way and uses `competitionMomentText` at :1063.
- **:543-585 `statusRow` / `statusTitle` / `endText`** are replaced with one row:
  - `let status = competitionStatusText(competition, style: .card, locale: locale, timeZone: timeZone)`
  - leading `HStack { if isLive { dot }; Text(status.title).foregroundStyle(Theme.ink) }`
  - trailing `if let timing = status.timing { Text(timing).foregroundStyle(Theme.secondary).tracking(0).fixedSize(horizontal: false, vertical: true) }`
  - on the row: `.textCase(.uppercase)`, `.accessibilityElement(children: .ignore)`, `.accessibilityLabel(status.line)`, `.accessibilityIdentifier("competition.status")`
  - delete the separate "of 7" Text (:568-571) and the comment at :556-557
- :606-615 `ownerBlock` → `name: "You"`. The identifiers `competition.scoreHeader.naren` / `.alex` are unchanged.
- :650 label stays the same shape, built from `competitionPointsAccessibilityText` (which now reads nil as "no points yet").
- :847-860 `competitionDetailTitle` deleted.
- :862-886 `competitionDayAccessibilityLabel` becomes `(_ day:, currentDayOrdinal: Int? = nil, opponentName: String, now: Date = Date(), locale: Locale = .current) -> String`, producing the VoiceOver day-row strings. Its caller (CompetitionWeekChart.swift:63) passes the chart's `now`. A day is future when `day.ownerLatestAvailability == .notYetOccurred && day.ordinal != currentDayOrdinal`.
- :888-894 `competitionDayDateText` deleted.
- :926-940 `competitionEndText` deleted.
- :942-959 `competitionOwnerAccessibilityText`: `.notYetOccurred` → "upcoming"; observed with no score → "synced, no score yet". The other cases keep their shape and now say "no points yet" for nil.
- :973 → `"Day \(ordinal) synced"`.

CompetitionSharingView.swift
- :55 "Home".
- :116-123 and :814-821 still call `sharingAccessibilitySummary`, rebuilt at :993-1023: `[name, competitionStatusText(c, style: .row, locale:, timeZone:).line, disclosure?]`, plus for scored lifecycles `"You \(a11y(user, digits))"` and `"\(name) \(a11y(opp, digits))"`, joined with ". ". `digits = sharingOutcome(...) != nil ? competitionFinalFractionDigits(...) : 0`.
- :329-370 Home card: `statusLeading` = LIVE dot/word (unchanged) + `Text(status.title)`; `statusTrailing` = `status.timing`; style `.card`; `.textCase(.uppercase)` on the row. Delete `statusText` and `endText`.
- :389-401 → `Text("YOU")` in place of the uppercased owner name.
- :412-417 `HeroScoreboard` owner side `name: "You"`.
- :534-544 row `statusText` → `competitionStatusText(competition, style: .row, locale: locale, timeZone: timeZone).line`. Add `@Environment(\.locale)` / `\.timeZone` to `CompetitionSharingRow`.
- :553-560 `trailingScore` uses `digits` (as above) on both numbers.
- :645-650 `competitionAwardEarnedText(award.awardedAt, now: publication.evaluatedAt, locale:, timeZone:)` (now the day style).
- :699-702 → `"Latest victory \(competitionDayText(latestOwnerVictoryAt, now: now, locale:, timeZone:))"`. `CompetitionRivalrySummaryCard` (:674) gains `let now: Date`; its one caller (:766) passes `publication.evaluatedAt`.
- :1046-1065 replaced by C.

CompetitionWeekChart.swift (F)
- Replace the `ownerName` property (:10) with `let now: Date`, and thread it where `ownerName` was threaded (:45-50, :60-69). Callers pass `competition.evaluatedAt`: CompetitionDetailView :230 and :308, CompetitionResultView :294.
- `StackedDayRow` (:240-276) shows "You" for your side and `competitionDayText(day.day, now: now)` in place of "M/D" (:251).
- `DayLabel` (:290) uses `competitionDayText(day.day, weekday: false, now: now)`.
- Day values stay rounded per day (see "Days vs the week total"); no week-level remainder.
- Strip `winnerColor` / `leaderColor` (:123-143) and `HeadToHeadDayRow` `ownerColor` / `opponentColor` (:223-237) compare with `competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent)` (> 0, < 0, == 0, ≥ 0 in place of the raw comparisons).
- :162 legend copy.

CompetitionResultView.swift
- Add `private var digits: Int { competitionFinalFractionDigits(userPoints: competition.userPoints, opponentPoints: competition.opponentPoints) }`.
- :84 → name title.
- :128-163 kicker `Text(["Final", weekRangeText].compactMap { $0 }.joined(separator: " · ")).textCase(.uppercase)`. `weekRangeText` → `competitionWeekText(first, last, now: competition.evaluatedAt)`. Also used at :293.
- :167-170 → `SectionLabel("FINAL SCORE")`.
- :180 a11y uses "You" and digits.
- :186-199 `FinalScoreOwner(name: "You", …)`. `FinalScoreOwner` (:726-747) gains `let fractionDigits: Int`.
- :238-242 `marginText` uses `competitionDisplayedMargin(…, fractionDigits: digits)`; nil when 0.
- :244-253 `daysWonText` counts `competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent) > 0`.
- :262-265 → `SectionLabel("THE WEEK")`.
- :297 replace `ownerName:` with `now: competition.evaluatedAt`.
- :326-383 compute `let shown = competitionRoundedParts(totals.map(\.points), total: sum)` and pass it to `ringTotalLabels` (replacing `.rounded()` at :377).
- :388 → `SectionLabel("AWARDS")`.
- :426-433 `awardDetail` (completion award) → `competitionAwardEarnedText(award.awardedAt, now: competition.evaluatedAt, locale:, timeZone:)`. PR 4 later deletes this branch.

CompetitionInviteView.swift
- :169-173 `navigationTitle` → `competition.opponentDisplayName`.
- :312-319 `competitionInviteTitle` copy.

CompetitionNotificationPlanner.swift
- :66 `private static func liveV1Content` becomes internal `static func liveV1Content(_ message: CompetitionNotificationMessage, locale: Locale = .current) -> CompetitionNotificationContent`. :63 stays `content: { liveV1Content($0) }`.
- Titles for scheduledStart / finalDay / competitionEnded / result come from `competitionStatusText(lifecycle, schedule: nil, opponentDisplayName: opponent, style: .notification).title`, through one private mapping:
  - `.scheduledStart` → `.active(dayOrdinal: 1)`
  - `.finalDay` → `.endsToday`
  - `.competitionEnded` → `.tallying(startedAt: .distantPast)`
  - `.result` with an outcome → `.completed(outcome:, basis: .stableAcrossPostBoundaryReads, completedAt: .distantPast)`
  - The formatter ignores the dates.
- `scoreCopy` (:132-142) uses `competitionPointsText(_, fractionDigits:, locale:)`. For the result, digits come from `competitionFinalFractionDigits`. Delete `pointsText` (:144-154) and its en_US_POSIX formatter.

Other files
- PermissionOnboardingView.swift:153-170: build the three samples from `CompetitionNotificationPolicy.liveV1.content(CompetitionNotificationMessage(...))`: leadChange 1,217/1,194, finalDay, and result `.win` 2,431/2,198, all with "Alex", using a fixed sample `CompetitionID`. They render as "Lead change" / "Last day" / "You beat Alex" with the bodies above.
- MainTabView.swift :99, :230-239 copy. :280-283 deleted (moved to A).
- **Deleted, so no caller may reference them:** `competitionDateRangeText`, `competitionDateTimeText`, `competitionAwardDateText`, `competitionEndText`, `competitionDetailTitle`, `competitionSharingStatus`, `competitionDayDateText`.
- **No new Swift files, so no project.pbxproj change.** project.yml and Info.plist get the same edit. Run XcodeGen 2.46.0 on the Mac mini to confirm there is no diff.
- **No reducer state or actions change.**
- **Untouched:** the `CompetitionSharingView` type name and the `competition.sharing.*` identifiers.

#### Server changes
None.
- **Server push copy** in `supabase/functions/send-competition-notification/index.ts:260-264` ("Competition complete" / "Competition updated") still uses the old words. PR 5 (f-serverpush) replaces it.
- **"Former competitor"** is a server-side literal (constraints and redaction migrations), shown as a display name. Unchanged.
- **Installed versions.** No wire, RPC or migration changes, so app versions already installed behave exactly as before.

#### Tests
**Standalone formatter checks.** Rewrite `scripts/tests/competition-local-date-formatting.swift`; the old checks call deleted functions. Keep its `normalized` helper (`\s+` → " ", which also matches U+2009 and U+202F). The checks:
- `competitionPointsText(382.2, locale: en_US)` == "382"; 0.5 → "1"; 2.5 → "3"; nil → "--"; `(412.3, fractionDigits: 2, en_US)` == "412.30"; `(1217, de_DE)` == "1.217"; `normalized((1217, fr_FR))` == "1 217".
- `competitionPointsAccessibilityText`: nil → "no points yet"; 1 → "1 point"; 0.6 → "1 point"; 412.4 → "412 points".
- `competitionDisplayedMargin`: (0.03, 0) == 0; (412.54, 412.46) == 1; (412.46, 412.54) == −1; (382.2, 0) == 382.
- `competitionFinalFractionDigits`: (412.3, 412.0) == 2; (412, 412) == 0; (420, 412.3) == 0; (412.46, 412.54) == 0.
- `competitionRoundedParts`: ([120.4, 80.4, 31.4], 232.2) == [121, 80, 31]; ([0.5, 0.5, 0.5], 1.5) == [0, 1, 1]; ([], 0) == [].
- Day, with `now` = 2026-10-31T12:00Z and `la` = America/Los_Angeles:
  - `competitionDayText(2026-10-29T19:00Z, now, en_US, la)` == "Thu, Oct 29"
  - same with `now` = 2027-02-01 → "Thu, Oct 29, 2026"
  - `weekday: false` → "Oct 29"
  - `fr_FR` result contains "29" and differs from en
- Week, in UTC: `normalized(competitionWeekText(Oct 24, Oct 30))` == "Oct 24 – 30"; (Oct 28, Nov 3) == "Oct 28 – Nov 3"; with `now` in 2027 it contains "2026".
- Moment, for 2026-10-28T04:41Z in `la`:
  - with `now` 2026-10-31 → `normalized` == "Tue 9:41 PM"
  - with `now` 2026-11-20 → contains "Oct 27" and "9:41"
  - `fr_FR` contains "21:41"
- `competitionAwardEarnedText(2001-01-01T12:00Z, now: 2001-02-01, en_US, UTC)` normalized == "Earned Mon, Jan 1".

**HealthCompTests/CompetitionPresentationTests.swift**
- **New `testStatusTextNamesEveryLifecycleInEveryStyle`.** The schedule is LA, starting Wed 2026-10-28. With phone zone LA and `now` 2026-10-31, assert every row of the status table for row, card and notification. Use the lifecycle overload with an explicit `now`. Spot checks:
  - `.active(4)`, `.row` → title "Day 4 of 7", timing "Ends Tue night", line "Day 4 of 7 · Ends Tue night"
  - `.endsToday` → ("Last day", "Ends at midnight")
  - `.scheduled`, `.card` → ("Scheduled", "Starts Wed, Oct 28"); `.row` → ("Starts Wed, Oct 28", nil)
  - `.completed(.loss)`, `.row`, name "Hermes" → title "Hermes won", normalized timing "Oct 28 – Nov 3"
  - `.completed(.win)`, `.notification` → "You beat Hermes", timing nil
  - `schedule: nil` with `.active(4)` → timing nil
  - presentation overload, `.completed(.win)`, `.row`, presentation `evaluatedAt` 2027-02-01 → the timing contains "2026" (it reads the presentation's time, not the wall clock)
- **New `testStatusTimingAddsCalendarZoneOnlyWhenOffsetDiffers`.** Phone Asia/Tokyo → "Ends Tue night PST", "Ends at midnight PST", "Starts Wed, Oct 28 PDT". Phone America/Vancouver → no suffix.
- **New `testRingPartsAddUpToTheDayTotal`.** For the 232-point split from `testWeekChartSplitsAcceptedPointsByRingShareAndKeepsTheTotal`, `competitionRoundedParts(...).reduce(0, +)` == 232 and every part is whole.
- **Rewrite `testDayAccessibilityNamesTodayProgressClosedDateAndUpcomingState` (:672-702)** with `now` 2026-08-31 and no `ownerName`:
  - today contains "Day 2, Today, scores so far. You, 321 points."
  - closed contains "Day 2, Sun, Aug 9, complete." and "You, 321 points"
  - future == "Day 2, Sun, Aug 9, upcoming."
  - none contain "--"
- **`testClosedDayWithoutOpponentScoreIsUnavailableRatherThanFuture` (:704-715)**: drop `ownerName`. Expect "Opponent, score not available." and no "--".
- **Replace `testScheduledCompetitionShowsActualEndInViewerTimeZone` (:188-229) with `testScheduleCardShowsTheInclusiveWeek`.** Keep the boundary assertions. `normalized(competitionScheduleDateRangeText(schedule, now: 2026-08-01, locale: en_US))` == "Aug 13 – 19", contains no ":", and contains no "GMT". The mismatched schedule → nil.
- **Delete `testFinalDayEndTextUsesViewerDateRatherThanCanonicalDay` (:247-283).** The Tokyo status test replaces it.
- **`testCurrentFailureAndPriorSuccessfulReadAreBothDisclosed` (:357-377)**: pass `now: Date(timeIntervalSinceReferenceDate: 3_000)`. Replace the GMT+9 assertion with: `normalized(lines[0])` contains "Mon 9:33 AM" and does not contain "GMT".
- **`testRemoteParticipantCopyUsesRealIdentityWithoutFixtureLanguage` (:115-121)** → "Challenge to Priya".
- **`testEveryTallyAttentionHasUserFacingCopy` (:605-632)**: noRead → "Waiting for the first complete Activity check after the match."
- **`testDifferentAcceptedAndLatestSnapshotsUseNeutralPolicyCopy` (~:549)** → "preserves earlier source evidence under the match scoring rules".
- **`testCompactChartDistinguishesFutureMissingUnavailableAndZero` (:443-446)** → "synced, no score yet".
- **`testAwardEarnedDateAndRivalrySummaryComeFromCanonicalDashboard` (:766-772)**: pass `now: Date(timeIntervalSinceReferenceDate: 2_592_000)`, then assert normalized == "Earned Mon, Jan 1".
- **`testWeekChartSplitsAcceptedPointsByRingShareAndKeepsTheTotal` (:836-841)**: expect `calendar.shortWeekdaySymbols[3]` ("Wed"), not uppercased.

**HealthCompTests/CompetitionNotificationPlannerTests.swift**
- **`testLivePolicyV1OwnsTimingBudgetPriorityAndPrivacyCopy` (:60-88)**: use `CompetitionNotificationPolicy.liveV1Content(message, locale: Locale(identifier: "en_US"))`. The result has title "You beat Alex" and body "Final score: You 4,200, Alex 3,900."
- **New `testLivePolicyV1UsesTheUsersLocaleAndWholePoints`.** de_DE leadChange with 1,217.4 / 1,194 → body == "The lead changed in your match with Alex. You 1.217, Alex 1.194."
- **New `testLivePolicyV1LifecycleTitlesMatchTheStatusFormatter`.** The finalDay, competitionEnded, scheduledStart and result(.loss) titles equal the `.notification` formatter titles: "Last day", "Tallying", "Day 1 of 7", "Alex won".
- **New `testResultCopyShowsDecimalsOnlyWhenWholePointsWouldHideTheWinner`.** 412.3 / 412.0 with `.win` → "Final score: You 412.30, Alex 412.00."

**Other unit tests**
- **HealthCompTests/RemoteCompetitionClientTests.swift:3157, :3161, :3501, :3508**: use the new issue-summary strings from the glossary table.
- **No change needed:** RemoteCompetitionRuntimeTests :304/:403 ("Waiting for competitor" is only an input literal there); CompetitionFeatureTests :785/:791 ("--" is unchanged); CompetitionTestLabTests :205 (Test Lab labels are unchanged).

**UI tests.** Add one helper to both suites:
```swift
private func waitForStatus(_ prefix: String, timeout: TimeInterval = 5) -> Bool {
    app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label BEGINSWITH %@",
        "competition.status", prefix)).firstMatch.waitForExistence(timeout: timeout)
}
```

LocalCompetitionLifecycleUITests.swift
- **Navigation bars:**
  - 16× `navigationBars["Sharing"]` → `["Home"]` (:27, 124, 144, 155, 171, 198, 206, 220, 231, 246, 281, 287, 305, 336, 470, 515)
  - 5× `["Result"]` → `["Alex"]` (:149, 180, 293, 415, 505)
  - 2× `["Compete with Alex"]` → `["Alex"]` (:38, :479)
  - :217 `["Invitation from Alex"]` → `["Alex"]`
- **Status checks:**
  - `staticTexts["Scheduled"]` (:47, :237) → `waitForStatus("Scheduled")`
  - `["Day 1"]` (:59, 255, 390, 487, 523) → `waitForStatus("Day 1 of 7")`
  - `["Ends Today"]` (:75, 401, 493) → `waitForStatus("Last day")`
  - `["Tallying Points"]` (:85, 404, 497) → `waitForStatus("Tallying")`
- **Copy:**
  - :30 "Outgoing invitation" → "Challenge sent"; :207 "Incoming invitation" → "Challenge received"
  - :34 `!contains("total points")` → `!contains("points")`
  - :41 → "Challenge to Alex"; :210 → "Challenge from Alex"
  - :212-214 and :233 → "Accept challenge from Alex" / "Decline challenge from Alex"
  - :215 → `alerts["Decline challenge from Alex?"]`; :218 → "Keep Challenge"; :219 → "Decline Challenge"
  - :190 sheet → "Delete this match from this iPhone?"
  - :221 → "Challenge Alex Again"
  - :113 and :135 → "Match Complete"
- **Labels:**
  - :52 schedule dates → `XCTAssertFalse(… .contains(":"))`
  - :69-70 → contains "upcoming" and not "--"
  - :78, :117, :347, :535 "Naren" → "You"
  - :112 → `otherElements["competition.result"].label.contains("Final score")`
  - :261-263 → "You, Activity source is temporarily unavailable, no points yet"
  - :545-553 `assertSevenPairedDays`: label contains "Day n"; if it contains "upcoming", assert it contains neither "You" nor "Alex"; otherwise assert it contains both
- :312 "Naren activity" is unchanged.

MultiUserCompetitionUITests.swift
- **Navigation bars:**
  - 8× `navigationBars["Sharing"]` → `["Home"]` (:54, 118, 319, 545, 673, 736, 851, and :984 inside `navigateBackToSharing`)
  - 4× `["Result"]` → `["Former competitor"]` (:59, 183, 626, 692)
  - `["Competition with Priya"]` (:147) → `["Priya"]`; `["Competition with Jordan"]` (:159, 222, 567, 679, 744) → `["Jordan"]`
  - :323 `["Compete with Sam"]` → `["Sam"]`
  - :242 `["Competition Invitation"]` → `["Challenge"]`
- **Copy:**
  - :24 → "Challenge Sam"
  - :126 → "Match time zone, America/Los_Angeles"
  - :245 → "Join this match?"
  - :290 → "Challenge unavailable"; :293-295 → the new unavailable message
  - :324 and :338 → "Derived match data is shared"
  - :372 and :405 → "The other person gets your daily points, rounded Activity percentages and modes"
- **Status and labels:**
  - :151 → `XCTAssertFalse(localRange.contains(":"))`
  - :162 → `waitForStatus("Day 3 of 7")`
  - :164-165, :573, :609, :630 "Beta Alice" → "You"
  - :697 → "You Won. Final score. You 3,520 points. Former competitor 3,410 points." (PR 3 later changes the title part)
  - :233 → "You, 500 points"
  - :596-611: day 7 context → "upcoming."; names asserted only for days 1 and 3 ("You", "Jordan"); day 7 asserts `!contains("--")`
  - :753-756 → contains "upcoming.", delete both "future, --" lines, add `!contains("--")`
  - :765 → "Day 3, Today, scores so far. You, 430 points. Jordan, 450 points."
- **Unchanged (Test Lab strings):** :253 "Competition Confirmed", :272 signed-out copy, :282 "Invitation Declined", :301 "Invitation Closed".

**Accessibility identifiers.** Added: `competition.status` (match screen status row). Renamed: none. Removed: none. `competition.scoreHeader.naren/.alex`, `competition.sharing.<lifecycle>.<uuid>`, `competition.schedule.dates`, `competition.result`, `competition.day.<n>` and all `competition.create.*` / `competition.claim.*` identifiers are unchanged.

**Verify on the Mac mini before opening the PR:** the standalone script, HealthCompTests, both UI suites (including the `performAccessibilityAudit` Dynamic Type passes), and light/dark captures of the Home card, match screen and result at XS and AX5.

#### Risks and sequencing
- **Land PR 1 first.** Every other PR touches CompetitionSharingView, CompetitionDetailView, CompetitionResultView, CompetitionWeekChart and the planner, and they rebase onto it. They call the helpers in the API summary. None may re-introduce the deleted functions, raw `M/D` dates, `en_US_POSIX` numbers, or comparisons on raw points. New date call sites pass the projection's `evaluatedAt` as `now`, never the `Date()` default.
- **CompetitionDateFormatting.swift must stay Foundation-only.** CI compiles it alone. That is why the CompetitionDay adapters, the status formatter and the lead Text live in app files.
- **Copy that later PRs replace.** PR 5 rewrites notification copy (f-lostresult, f-trivial, f-expiry). PR 6 rewrites the Create, Claim and Invite screens. PR 8 rewrites Welcome and Account. PR 4 (f-errors) rewrites the issue banner. Each must keep the glossary and take titles from `competitionStatusText`.
  - The lead-change body can read "You 412, Alex 412" when the leader is ahead by less than half a point. That is a PR 5 (f-trivial) decision.
- **Left for other PRs (f-tally, f-chips):** the "Final day" period label and the tally sentences (f-tally); the result title "You Won" / "It’s a Tie" (f-chips and Result title polish). The ring panel's "Naren activity" is left for PR 2.
- **Scheduled local notifications refresh on their own.** After the update, the first plan re-upserts every scheduled request: `knownPendingRequests` starts empty, CompetitionNotificationCoordinator.swift:379-389. Pending notifications get the new copy without migration.
- **Info.plist usage strings** change, and App Review sees them. Both files must match, or the XcodeGen determinism check fails.
- **UI test churn is large** (about 70 edits). A missed string fails CI rather than shipping wrong copy.

#### Open questions
Moved to §10: Q14 (zone wording for travelers) and Q17 (breakdown precision). Both defaults are built above.

### PR 2 — Real-match data parity

#### Scope
- **f-remote-empty**: real (Supabase) matches get your on-device ring snapshots, refresh times and the result's "HOW YOU SCORED". The Today page becomes one ring list whose rows add up to the period row, so each of today's numbers appears once.
- **f-fresh**: one "Updated …" line (yours, plus the other person's when it exists), pull-to-refresh on the match screen, and a separate "Today hasn't synced yet" state that replaces "? Day 4 is missing activity data." for the current day.
- Handed over by PR 1: the ring panel's VoiceOver "Naren activity" becomes "Your rings".
- Polish **Ring panel**: the rewritten panel only shows a pause line when tracking is paused. This PR owns the row (§7). PR 3 does not edit ActivityRingsView.swift.


#### Behavior

##### Today page (f-remote-empty), live and tallying matches
The Today/Week picker stays. Under **Today** there is one panel for `activityDay` (today, Day 7 while tallying, or else the last day that has started). It replaces the old "HOW TODAY ADDS UP" equation, the other person's block and the Apple ring graphic, following the Proposed mockup.

```
■ Move · 420/500 kcal          84
■ Exercise · 36/30 min        120
■ Stand · 9/12 hr              75
1 point per 1% of each ring. Your ring values stay on this iPhone.
```

- **Row titles.** "Move", or "Move Time" when the move mode is minutes. "Exercise". "Stand", "Roll", or "Stand or Roll" when the stand mode is unknown. "Stand or Roll" only appears in the local fixture: a real match never stores an unknown-stand reading (see Design E and Risks).
- **Row detail.** "{value}/{goal} {unit}", with unit kcal, min or hr. Numbers are whole and use the user's locale ("1,000/500 kcal"). A missing value or goal shows "No data".
- **Row points.** Whole points from PR 1's `competitionRoundedParts`, so the three rows always add up to the whole number in the period row. Each ring's share is its **scored** percentage, scaled to the day total:
  - Real matches: `min(200%, value/goal)`. This is what the server scores: `RemoteScoringWireV1.quantizePercent` clamps each ring to 20000 basis points (RemoteScoringWireV1.swift:21,29), and `submit_score_revision` accepts `least(mbp+ebp+sbp, 60000)` (20260928001600_allow_score_catch_up.sql:64-66). Example: Move 300%, Exercise 100%, Stand 100% → rows 200/100/100, total 400, the same as the accepted score.
  - Local fixture: raw `value/goal` (`.healthKitCompatibility` has no per-ring cap, ActivityScore.swift:105-108); the 600 daily cap still applies.
  - Unless the 600 daily cap bites (local fixture only, since 3 × 200 = 600), each row equals the ring's scored percentage.
- **Footer** (caption, secondary, under the panel):
  - real match: "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone." (always shown; a real day can't pass 600)
  - local fixture, normal: "1 point per 1% of each ring. Your ring values stay on this iPhone."
  - local fixture, capped (the ring percentages add up to more than 600): "Capped at 600 points a day. Your ring values stay on this iPhone."
  - **Deviation from the mockup** ("Hermes sees your points, not your rings"): the server and the other person's app do receive your per-ring percentages. The change feed carries `move_basis_points`, `exercise_basis_points` and `stand_basis_points` for both people (CompetitionSyncModels.swift:3705-3745), and Account already discloses "rounded Activity percentages". "Not your rings" would contradict that disclosure. What really stays on the phone is the kcal, minute and hour values and the goals.
- **Pause.** "Activity tracking paused" appears inside the panel (caption, bold, ink) only when the shown snapshot is paused. The panel never shows running or unknown states.
- **Which snapshot (one snapshot, never two side by side).** The panel draws the accepted snapshot when there is one, otherwise the latest. One optional note sits inside the panel, as a caption under the rows:
  - The accepted snapshot is shown and the latest differs or is missing: "Points use an earlier reading. Your rings have changed since."
  - Only the latest snapshot exists and it can be scored (remote: read but not yet accepted by the server): the rows show the calculator's points, using the same per-ring cap as the server on real matches, and the note says "These points haven’t synced yet." The period row still shows "--", because it only ever shows accepted points.
  - Only the latest exists and it can't be scored (paused, or a goal is missing): the rows show no points and there is no note.
- **No snapshot at all:**
  - `.notSyncedYet` (Today page): a panel with
    - "Today hasn’t synced yet" (headline, ink, sync icon)
    - "Your rings update as you move. Pull down to check now." (subheadline, secondary)
  - `.notSyncedYet` (day drawer): the first line only, since a sheet can't be pulled to refresh.
  - Anything else: the existing one-line label from `competitionOwnerAvailabilityText` ("Day 4 synced", "Day 3 is missing activity data.", "Activity source is temporarily unavailable.", …). For example, a real match with an accepted score but no snapshot on this phone (score from another device, or before the first read after updating) shows "Day 4 synced".
- **Today's points appear once.** Your number is the period row; the rows add up to it. The other person's number is the period row only (the old block for the other person under the equation is removed). Scoreboard VoiceOver is unchanged.
- **0–0 / Day 1 at midnight.** With a snapshot of 0/500 the rows show "0" each and add up to "0". Before any read the day is `.notSyncedYet`.
- **Day 7 / Last day** behaves like any other "today". **Tallying**: `activityDay` is Day 7, the panel shows the Day 7 snapshot, and `.notSyncedYet` never applies (`currentDayOrdinal` is nil).
- **Scheduled**: no Today page, unchanged.

##### Day drawer
Tapping a started day in the Week chart opens a drawer: title "Day N", the PR 1 date subtitle, the one-day chart row (both people's points for that day), then the same panel and footer for that day. The old breakdown, the evidence caption and the bare repeated row are gone. In a real match, the drawer for a past day shows that day's rings when this phone read it.

##### Result screen
"HOW YOU SCORED" (CompetitionResultView.swift:309-358) now appears for real matches whenever every scored day has an accepted snapshot on this phone. No view change is needed; it reads `ownerAcceptedSnapshot` through `ringSegments`, which now splits by scored percentage (200% per-ring cap on real matches, Design H), as do the Week chart bars. It stays hidden for matches that finished before this version was installed (there are no stored snapshots), for days scored from another device, and for days whose accepted row this phone can't match to a reading. That is today's fallback, so nothing claims a wrong split.

##### Freshness line (f-fresh)
A single caption line (secondary, wraps, never truncates) directly under the lead line ("You lead by 116.") on the match screen. It shows when `competitionShouldShowScores(lifecycle)` is true (active, last day, tallying):

| You | Them | Line |
|---|---|---|
| yes | yes | "You: updated 9:41 AM · Hermes: updated 11:40 PM" |
| yes | no | "Updated 9:41 AM" |
| no | yes | "Hermes: updated 11:40 PM" |
| no | no | no line |

- **Time.** On the same calendar day as `competition.evaluatedAt` (phone zone) it is the time only: "9:41 AM". Otherwise it is PR 1's moment style: "Fri 11:40 PM", or "Oct 21, 9:41 PM" beyond 6 days.
- **"You"** = `lastSuccessfulFullWindowRefreshAt`: the last Health read that completed, even if nothing changed. A failed check does not move it; the failure still shows in ••• → Activity Sync and in the existing issue banner.
- **"Them"** (real matches only) = the Health read time (`evaluated_at`) of their newest accepted score revision. Their device only sends a revision when their numbers change, so this is "their numbers are as of". The simulated fixture has no "them" part.
- **Deviation from the f-remote-empty mockup**: there is no "TODAY · 9:41 AM" in the period row. The period label sits between both columns, so one time there can't say whose it is. The f-fresh mockup's two-name line covers both people.
- Long names wrap. VoiceOver reads the visible text. Identifier `competition.updated`.

##### Pull-to-refresh (f-fresh)
Pull down on the match screen (Today and Week pages, live and tallying) to run the same reconcile as Home (`.pullToRefresh` trigger). The system spinner shows until reconciliation finishes. Afterwards the publication updates the scoreboard, the panel and the freshness line in place. Drawers aren't refreshable.

##### "Not synced yet" vs "missing" (f-fresh)
A new availability, `.notSyncedYet`, means today (the current match day) with no score and no Health summary on this phone yet.

| Where | Before | After |
|---|---|---|
| Today panel | "? Day 4 is missing activity data." | "Today hasn’t synced yet" + "Your rings update as you move. Pull down to check now." |
| Week chart value | "?" | "–" (the existing `.unscored` glyph) |
| VoiceOver, your side of the day | "missing activity data, no points yet" (PR 1) | "not synced yet" → "Day 4, Today, scores so far. You, not synced yet. Hermes, 0 points." |
| Period row | "--" | "--" (unchanged; PR 1's "no value" glyph) |

- **The other person's today** keeps their real number, "0" included. **Deviation** from the mockup "– TODAY –": a 0 there is a server-accepted score (or the fixture's revealed progress), so a dash would hide a real value. See §10 Q16.
- **Past days** with no data stay "Day N is missing activity data." and "?".
- **Real matches**: a server row with reason `sourceDataUnavailable` means "HealthKit had no summary for that day". It is the only reason the runtime sends for a `.missing` read (RemoteCompetitionRuntime.swift:1355-1363). It now reads as missing ("?", "Day 3 is missing activity data."), or as `.notSyncedYet` today, instead of "Activity source is temporarily unavailable." Other reasons (paused, a missing goal, …) stay `.unavailable`.
- **The local fixture** keeps `.unavailable(.sourceDataUnavailable)` for a failed read (Health locked or unavailable), so the "unavailable" fixture still says "Activity source is temporarily unavailable."

##### Activity Sync drawer (real matches)
••• → Activity Sync now shows real lines, in PR 1's moment style:
- "Latest Activity check Sat 9:41 AM: Activity data updated." (or the failure copy from `competitionRefreshStatusText`, e.g. "Health data is locked — unlock this iPhone to update.")
- "Last complete Activity read Sat 9:41 AM."

"No Activity check yet." only appears before this phone has read Health for that match. The evidence caption under the lines is removed (the panel note replaces it).

##### Accessibility
- **Panel**: one VoiceOver element, identifier `competition.ownerRings`. Label: "Your rings. Move, 420 of 500 kilocalories, 84 points. Exercise, 36 of 30 minutes, 120 points. Stand, 9 of 12 hours, 75 points." It adds ". Activity tracking paused" and the note when present. Rows without points drop the ", N points" part. Missing values read "no data".
- **Footer** is a separate element. The not-synced panel is one combined element with identifier `competition.notSynced`.
- **Accessibility sizes**: the row text wraps across lines, the points stay trailing and `fixedSize`, and there is no ViewThatFits (the Dynamic Type audit flags it). It must pass the existing `.textClipped`, `.hitRegion`, `.sufficientElementDescription` and `.dynamicType` audits. Nothing new is tappable, so no new 44pt targets.
- **Multiple matches / repeat opponents**: snapshots, refresh times and the "them" time are kept per match, so two live matches with the same person never share data. Each match reads its own window in the same reconciliation, so "You: updated" can differ by seconds between matches.

#### Design

**A. New availability case: `LocalCompetitionClient.swift:86-91`**
```swift
enum LocalCompetitionOwnerAvailability: Equatable, Sendable {
    case notYetOccurred
    case notSyncedYet      // today, no score and no Health summary yet
    case observed
    case missing
    case unavailable(reason: ActivityUnavailableReason)
}
```
Every exhaustive switch must handle it (the compiler lists them), all in CompetitionDetailView.swift:
- `competitionOwnerAccessibilityText` (:942-959): "not synced yet".
- `competitionOwnerAvailabilityText` (:967-985): "Today hasn’t synced yet".
- `competitionOwnerChartState` (:1098-1115): `.unscored`.
- `availabilitySymbol` (:1134-1143): "arrow.triangle.2.circlepath".
- `availabilityTint` (:1145-1153): `Theme.secondary`.

**B. Presentation fields: `LocalCompetitionClient.swift`**
- `LocalCompetitionPresentation` (:159-216): add `let opponentUpdatedAt: Date?` and the init parameter `opponentUpdatedAt: Date? = nil` after `lastSuccessfulFullWindowRefreshAt`. Existing call sites compile unchanged.
- `LocalCompetitionDayPresentation` (:93-125): add `/// How this day's snapshot turns into points; only used to split and preview them.` `let scoringPolicy: ActivityScoringPolicy` and the init parameter `scoringPolicy: ActivityScoringPolicy = .healthKitCompatibility` last. The local projector keeps the default; the remote projector (G) and the Test Lab (L) pass `.remoteWireV1`.

**B2. CompetitionCore: the real-match display policy. `Modules/CompetitionCore/Sources/CompetitionCore/ActivityScore.swift`, next to `healthKitCompatibility` (:105-109)**
```swift
/// What the server scores for `healthcomp.activity-score.v1`: each ring
/// capped at 200%, the day at 600. Display only: remote genesis and
/// `remoteEvidence` stay on `.healthKitCompatibility`, and the wire clamps
/// separately in `RemoteScoringWireV1.quantizePercent`.
public static let remoteWireV1 = ActivityScoringPolicy(
    uncheckedQuantization: .exactAggregate,
    perRingCap: 200,
    pausedSummaryPolicy: .scoreReportedValuesWhenUnknown
)
```
- Inside the type, so the private unchecked init is reachable. `ActivityScore`'s percentages come back capped (ActivityScore.swift:385-386).
- It differs from the wire only by the wire's 0.01% bankers rounding (≤ 0.015 points a day), which matters only for the "haven't synced yet" preview. Accepted rows show the server's exact centi-points.
- Remote genesis (RemoteCompetitionRuntime.swift:1517, 1937) is **not** changed; changing it would break genesis validation for every existing match.

**C. Local projector: `LocalCompetitionClient.swift:1460-1532`** (`dayPresentations`)
- Move `let ledgerEntry = …` (:1495) above the availability block.
- Add `let isToday = !isFuture && end.map { now < $0 } == true` after :1473.
- At :1481 (`case .missing`) and :1486 (no latest observation): `availability = isToday && ledgerEntry?.acceptedScore == nil ? .notSyncedYet : .missing`.
- Nothing else changes. The fixture already fills both snapshots (:1530-1531).

**D. Owner activity record: `RemoteCompetitionRuntime.swift`, next to `RemoteCompetitionCacheEntry` (:12-28)**
```swift
/// What this phone last read from Health for one real match. It stays on
/// this device: exact values and goals never go into wire payloads.
struct RemoteOwnerActivity: Codable, Equatable, Sendable {
    struct Day: Codable, Equatable, Sendable {
        let ordinal: Int
        let latestSnapshot: ActivitySnapshot?    // nil: Health had no summary
        let acceptedSnapshot: ActivitySnapshot?  // the reading behind the accepted row
        let acceptedClientRevision: Int64?       // the row it produced
    }
    let checkedAt: Date                          // last read attempt
    let checkFailure: ActivityQueryFailureReason?
    let readAt: Date?                            // last completed read; `days` come from it
    let days: [Day]                              // started days only
}
```
- `RemoteCompetitionCacheEntry` gains `let ownerActivity: RemoteOwnerActivity?`, and its init gains `ownerActivity: RemoteOwnerActivity? = nil`.
  - The synthesized Codable uses `decodeIfPresent` / `encodeIfPresent`, so files written by the current version load unchanged and an entry with nil writes the same JSON as today.
  - `Document.currentVersion` stays 1.
  - Add `// ponytail: owner activity rides in the 1 MiB inventory file, ~2–4 KB per match; move it to its own file if a profile nears ~250 listed matches.`
- `RemoteCompetitionMaterialization` (:407-410) gains `var ownerActivity: RemoteOwnerActivity? = nil`. Use a `var` with a default so the 10 existing memberwise call sites compile.
- `RemoteOwnerScoreRefreshOutcome` (:427-430) gains `let ownerActivity: RemoteOwnerActivity?`.
- **Claude's call: persist the snapshots** in the profile-scoped inventory cache rather than keep them in memory.
  - Finished matches are never read again (refreshOwnerScores skips `.completed` / `.archived`, :966-976), so without persistence "HOW YOU SCORED" could never return for real matches after a relaunch.
  - The file already has `completeUntilFirstUserAuthentication` protection and mode 0600 (:240-297), and it is deleted with the profile root (AuthenticatedProfileStorage.swift:233).
  - The local fixture already persists snapshots in its journal.
  - The remote journal can't hold them: replay rejects `activityRefreshAttemptRecorded` / `activitySnapshotRecorded` for remote matches (CompetitionEventStore.swift:1626-1645).
- **Claude's call: exclude the inventory file from device and iCloud backups.** Today nothing sets `isExcludedFromBackup`, so the file (and with this PR, exact kcal/min/hr values and goals) would land in backups. That contradicts "Raw HealthKit data stays on your iPhone" (web/privacy.html:46) and the footer, and risks App Store guideline 5.1.3(ii) (no HealthKit data in iCloud). The file is a cache the server can rebuild, so excluding it costs only an offline view and "HOW YOU SCORED" for finished matches on a restored phone.
  - In `persist` (:240-297), after the final `fileProtection.apply(…, to: fileURL)`:
    ```swift
    // Exact Health values must not leave this iPhone, backups included.
    var backupURL = fileURL
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    do { try backupURL.setResourceValues(values) }
    catch { throw RemoteCompetitionCacheFailure.unsafeFilesystemEntry }
    ```
    Set after every save: `renameat` replaces the file. iOS 4+ API, no SDK concern.
  - No schema change; `ownerActivity` stays in the inventory file.

**E. Runtime flow: `RemoteCompetitionRuntime.swift`**
- **`refreshOwnerScores(in:previous:)`** (:939). The new parameter is `previous: RemoteOwnerActivity?`.
  - Missing dependencies (:949) and skipped lifecycles (:962) return `ownerActivity: previous`.
  - Read failure (:982-1000) returns
    ```swift
    RemoteOwnerActivity(checkedAt: now(), checkFailure: Self.queryFailureReason(failure),
                        readAt: previous?.readAt, days: previous?.days ?? [])
    ```
  - Success (:1118-1131): after the reload, build `Self.ownerActivity(read:window:evaluatedAt:ledger:previous:competitionID:profileID:)` from `loaded.projection.remoteScoreLedgers[profileID]` and return it.
- **New `private static func ownerActivity(...) throws -> RemoteOwnerActivity`**. For each started day (`startOfDay <= evaluatedAt`):
  - `latest` = the `.snapshot` payload, or nil for `.missing`.
  - `row = ledger?.visibleEntry(forActiveDayOrdinal:)`.
  - If `row != nil` and `Self.wire(…, evidence: Self.remoteEvidence(from: result), clientRevision: row.clientRevision).wireContentSHA256 == row.wireContentSHA256`, the accepted row is exactly this reading: `accepted = latest`, `acceptedClientRevision = row.clientRevision`.
  - Otherwise, if `previous` has this ordinal with `acceptedClientRevision == row?.clientRevision` (non-nil), keep its `acceptedSnapshot` and revision. This is the not-yet-synced case.
  - Otherwise both are nil.
  - Result: `checkedAt = readAt = evaluatedAt`, `checkFailure = nil`.
- **New `private static func queryFailureReason(_ error: CompetitionActivitySourceError) -> ActivityQueryFailureReason`**: healthDataUnavailable → .healthDataUnavailable, protectedDataUnavailable → .protectedDataUnavailable, invalidResponse → .invalidResponse, unclassifiedQueryFailure → .unknown. This mirrors LocalCompetitionRuntime.swift:1098-1111.
- **`synchronize(descriptor:cachedEntry:)`** (:892-901): call `refreshOwnerScores(in: lifecycleReconciled, previous: cachedEntry?.ownerActivity)`. Then:
  ```swift
  var attested = try await enqueueFinalWindowAttestation(for: refreshed.materialization)
  attested.ownerActivity = refreshed.ownerActivity
  ```
  and return `attested`. Pending matches keep nil.
- **`synchronizeInventory`** (:656): `RemoteCompetitionCacheEntry(descriptor:, lastSeenServerSequence:, ownerActivity: synchronized.materialization.ownerActivity)`. When `synchronize` throws, the previous cache entry, and so its activity, is kept as today.
- **`offlineOutcome`** (:727): `RemoteCompetitionMaterialization(descriptor: entry.descriptor, journal: loaded, ownerActivity: entry.ownerActivity)`.
- **No change to what is sent.** Enqueue decisions, wire content and the outbox are unchanged.
- **Unknown stand mode on a real match (answered by the code).** `ownerActivity(...)` runs only after the enqueue loop succeeds. For a scorable reading with `standMode == .unknown`, the loop's `Self.wire(...)` already throws `RemoteScoringWireV1.ValidationError.invalidMode` on the client (RemoteScoringWireV1.swift:84), before anything reaches `submit_score_revision`. So `synchronize` throws, the cache entry and its `ownerActivity` stay as before (:651-680), and the panel never shows such a reading with points or a "haven't synced yet" note. No real-match case is needed in `competitionRingPanel`. **Claude's call:** fixing that sync failure is out of scope for PR 2 (see Risks).

**F. CompetitionCore: the other person's latest read time. `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEventStore.swift`**
- `CompetitionReplayProjection` (:904-932) gains `public let remoteLatestRecordedAt: [UUID: Date]`, documented as "the newest `recordedAt` (Health read time) of each participant's accepted remote revisions; derived on replay, never persisted". The internal init gains `remoteLatestRecordedAt: [UUID: Date] = [:]` as its last parameter.
- `apply` (:1515-1556): `var workingRemoteRecordedAt = projection.remoteLatestRecordedAt`. In `.remoteScoreRevisionRecorded`, after `ledger.accept`: `workingRemoteRecordedAt[pid] = max(workingRemoteRecordedAt[pid] ?? revision.recordedAt, revision.recordedAt)`. Pass it to the rebuild at :1720-1728.
- `recordedAt` is already the read time: the server's `evaluated_at` for downloaded rows (RemoteCompetitionRuntime.swift:1629), and `request.evaluatedAt` for this phone's own rows (CompetitionSyncCoordinator.swift:56). The journal format is unchanged.

**G. Remote projector: `RemoteCompetitionClient.swift`**
- `presentation(from:profile:context:)` (:1775-1839), with `let activity = materialization.ownerActivity`:
  - pass `ownerActivity: activity` to `dayPresentations` (:1792).
  - :1827: set `lastRefresh` to
    ```swift
    activity.map { LocalCompetitionRefreshPresentation(trigger: .reconciliationProbe, attemptedAt: $0.checkedAt,
        readAt: $0.checkedAt, status: $0.checkFailure.map { .failed(reason: $0) } ?? .completed) }
    ```
    No screen shows `trigger`, and remote reads don't carry one; comment that.
  - :1837: `lastSuccessfulFullWindowRefreshAt: activity?.readAt`.
  - add `opponentUpdatedAt: opponentID.flatMap { projection.remoteLatestRecordedAt[$0] }`.
- `dayPresentations` (:1841-1892) gains `ownerActivity: RemoteOwnerActivity? = nil`. The notification path (:1697) keeps the default nil. Per day:
  - `let end = try? schedule.calendar.startOfDay(schedule.calendar.day(after: day))`
  - `let isToday = !future && end.map { now < $0 } == true`
  - `let activityDay = ownerActivity?.days.first { $0.ordinal == ordinal }`
  - availability, first match wins:
    1. `future` → `.notYetOccurred`
    2. `activityDay?.latestSnapshot != nil` → `.observed`
    3. `owner?.acceptedCentiPoints != nil` → `.observed`
    4. `owner?.availabilityReason` is set and is not `"sourceDataUnavailable"` → `.unavailable(reason: ActivityUnavailableReason(rawValue:) ?? .invalidSourceData)`
    5. `isToday` → `.notSyncedYet`
    6. otherwise → `.missing`
  - :1888 `ownerAcceptedSnapshot`: `activityDay?.acceptedSnapshot`, but only when `activityDay?.acceptedClientRevision != nil && activityDay?.acceptedClientRevision == owner?.clientRevision`; otherwise nil. This re-check means an older reading never labels a newer row.
  - :1889 `ownerLatestSnapshot: activityDay?.latestSnapshot`.
  - `scoringPolicy: .remoteWireV1` on every day (the notification path included; it doesn't read it).
- `tallyPresentation` (:1972-1977): a row whose `availabilityReason == "sourceDataUnavailable"` counts as **missing**, not unavailable, to match the day states:
  ```swift
  guard let ownerLedger, let row = try? ownerLedger.visibleEntry(forActiveDayOrdinal: $0) else { return true }
  return row.availabilityReason == "sourceDataUnavailable"
  ```
  The unavailable filter (:1978-1986) already excludes `missing`.

**H. Ring panel: rewrite `ActivityRingsView.swift`** (same file, so no pbxproj change)
- Delete `import HealthKit` / `import HealthKitUI`, the `SystemActivityRingView` (HKActivityRingView), `ActivityRingContent`, `ActivityValueRow`, the fallback, `activityRingSupportsSystemPresentation`, `activityRingAccessibilityLabel` and the private helpers.
- Add:
```swift
struct CompetitionRingRow: Equatable, Sendable {
    let title: String          // "Move" | "Move Time" | "Exercise" | "Stand" | "Roll" | "Stand or Roll"
    let detail: String         // "420/500 kcal" | "No data"
    let spokenDetail: String   // "420 of 500 kilocalories" | "no data"
    let points: Double?        // whole; nil when the reading has no score
}

struct CompetitionRingPanel: Equatable, Sendable {
    let rows: [CompetitionRingRow]   // always Move, Exercise, Stand
    let isPaused: Bool
    let note: String?
    let footer: String
    var accessibilityLabel: String   // "Your rings. Move, 420 of 500 kilocalories, 84 points. …[ Activity tracking paused.][ note]"
}

/// Nil when the day has neither snapshot.
func competitionRingPanel(_ day: LocalCompetitionDayPresentation, locale: Locale = .current) -> CompetitionRingPanel?
```
- **Rules:**
  - `snapshot = day.ownerAcceptedSnapshot ?? day.ownerLatestSnapshot`
  - `isAccepted = day.ownerAcceptedSnapshot != nil`
  - `total`: `isAccepted ? day.ownerAcceptedPoints : (ActivityScoreCalculator.score(snapshot, policy: day.scoringPolicy)` → `.available(score).points`, else nil`)`
  - `shares = competitionRingShares(snapshot, perRingCap: day.scoringPolicy.perRingCap)`, `sum = shares.reduce(0, +)`
  - `points = total.map { t in competitionRoundedParts(shares.map { sum > 0 ? t * $0 / sum : 0 }, total: t) }`, or nil per row
  - `note` follows Behavior: accepted and `day.ownerLatestSnapshot != snapshot` → the "earlier reading" copy; not accepted and `total != nil` → "These points haven’t synced yet."; else nil
  - `footer` prefix: `if let cap = day.scoringPolicy.perRingCap` → "1 point per 1% of each ring, up to \(Int(cap))% per ring."; else `sum * 100 > ActivityScore.maximumDailyPoints ? "Capped at 600 points a day." : "1 point per 1% of each ring."`. Then " Your ring values stay on this iPhone."
  - numbers use `.number.precision(.fractionLength(0)).locale(locale)`
- **View:** `struct ActivityRingsView: View { let panel: CompetitionRingPanel }`.
  - The body is a `VStack(alignment: .leading, spacing: 8)` holding the panel and then the footer `Text` (caption, `Theme.secondary`, `fixedSize(horizontal: false, vertical: true)`).
  - The panel is `VStack(spacing: 12)` with rows, the pause line and the note; `.padding(16)`, `.themePanel()`, `.accessibilityElement(children: .ignore)`, `.accessibilityIdentifier("competition.ownerRings")`, `.accessibilityLabel(panel.accessibilityLabel)`.
  - Each row is `HStack(alignment: .firstTextBaseline, spacing: 10)`:
    - `SlantedBar().fill([Theme.move, Theme.exercise, Theme.stand][i]).frame(width: 10, height: 10)`
    - `Text(title).fontWeight(.semibold).foregroundStyle(Theme.ink) + Text(" · \(detail)").foregroundStyle(Theme.secondary)`, in `.subheadline` with `.frame(maxWidth: .infinity, alignment: .leading)`
    - the optional points `Text(competitionPointsText(p))`, `.headline.weight(.heavy).width(.condensed).monospacedDigit()`, `Theme.ink`, `.fixedSize()`
  - Only Theme tokens; ring colors only on your own rows.
- **`CompetitionWeekChart.swift:358-383`:** extract `func competitionRingShares(_ snapshot: ActivitySnapshot, perRingCap: Double?) -> [Double]` (the existing guard: `value/goal`, else 0; then `min(cap / 100, share)` when `perRingCap` is set). `ringSegments` calls it with `day.scoringPolicy.perRingCap`. Local behavior is unchanged; real-match Week bars and "HOW YOU SCORED" now split like the server scores.

**I. Match screen: `CompetitionDetailView.swift`**
- **Body (:31-39):** after `leadStatement`, add `freshnessLine`:
  ```swift
  if competitionShouldShowScores(competition.lifecycle), let text = competitionFreshnessText(competition, locale: locale, timeZone: timeZone) {
      Text(text)
          .font(.caption)
          .foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("competition.updated")
  }
  ```
- **Today page (:54-60):** replace `dayBreakdown(day)` + `ringsSection` with `todayActivity`. If `activityDay` exists it is `dayActivity(day, showsPullHint: true)`; otherwise it is the existing "Activity appears when Day 1 begins." label (:276-282) in a `themePanel`.
- **New `@ViewBuilder private func dayActivity(_ day: LocalCompetitionDayPresentation, showsPullHint: Bool)`:**
  - `if let panel = competitionRingPanel(day, locale: locale)` → `ActivityRingsView(panel: panel)`
  - `else if day.ownerLatestAvailability == .notSyncedYet` → a `themePanel` with the label (title from `competitionOwnerAvailabilityText`) and, when `showsPullHint`, the hint line; `.accessibilityElement(children: .combine)`, identifier `competition.notSynced`
  - `else` → the existing availability label (:261-271) in a `themePanel`
- **`dayDrawer` (:302-318):** keep the drawer and the one-day `CompetitionWeekChart`. Replace `dayBreakdown(day)`, `ringsPanel(day)` and `evidenceCaption(day)` with `dayActivity(day, showsPullHint: false)`.
- **`activitySyncDrawer`:** delete `evidenceCaption(activityDay)` (:350).
- **Delete:** `dayBreakdown` (:203-226), `ringsSection` (:242-247), `ringsPanel` (:249-283), `evidenceCaption` (:285-298), `ringsTitle` (:354-359), `TodayBreakdown` (:707-840), `ringLabels` (:842-845) and `activityEvidenceCaption` (:1117-1132). PR 1's `competitionRoundedParts` call in `dayBreakdown` goes with it; `competitionRingPanel` now owns the rounding.
- **Add global** (placed after `competitionRefreshTimelineText`):
```swift
func competitionFreshnessText(_ competition: LocalCompetitionPresentation, locale: Locale = .current, timeZone: TimeZone = .current) -> String?
```
  - `you = lastSuccessfulFullWindowRefreshAt` and `them = opponentUpdatedAt`, each through `competitionUpdatedText(_, now: competition.evaluatedAt, locale:, timeZone:)`.
  - The output strings follow the Freshness table.
- **No reducer state or actions change.**

**J. `CompetitionDateFormatting.swift`** (stays Foundation-only)
```swift
/// "9:41 AM" when `date` is on `now`'s day in `timeZone`; otherwise the moment style.
func competitionUpdatedText(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
```
- Body: use a gregorian `Calendar` with `timeZone`. If `isDate(date, inSameDayAs: now)`, return `date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: timeZone))`. Otherwise return `competitionMomentText(date, now: now, locale: locale, timeZone: timeZone)`.

**K. Pull-to-refresh: `MainTabView.swift:203-208`**
- Add to the `CompetitionDetailView(...)` destination:
  ```swift
  .refreshable { await store.send(.competition(.pullToRefresh)).finish() }
  ```
- It is the same action as Home (:95-97); it reaches the detail ScrollView through the environment. Pending, result and closed destinations stay non-refreshable.

**L. Multi-user Test Lab: `MultiUserCompetitionTestLabView.swift`** (mirrors what real matches now publish)
- `presentation(...)` (:636-668) gains `refreshedAt: Date? = nil, opponentUpdatedAt: Date? = nil`. For the active Jordan match, pass `evaluatedAt − 600` and `evaluatedAt − 3_600`.
  - `refreshedAt` feeds both `lastSuccessfulFullWindowRefreshAt` and `lastRefresh` (`.completed`, `trigger: .reconciliationProbe`).
- `activeDays()` (:688-706): every day gets `scoringPolicy: .remoteWireV1`. Days 1–3 get identical accepted and latest snapshots that produce exactly the existing points under the 200% per-ring cap (no ring over 200%, so a real match could produce them):
  - Day 1 (500): Move 1000/500 kcal, Exercise 60/30, Stand 12/12, standHours, running
  - Day 2 (520): Move 1000/500, Exercise 60/30, Stand 12/10 (200 + 200 + 120)
  - Day 3 (430): Move 900/500, Exercise 45/30, Stand 12/12 (180 + 150 + 100)

#### Server changes
None.
- **No migration, RPC, Edge Function or push change.**
- **Wire payloads are unchanged.** Snapshots stay on the device (and out of backups), matching docs/plans/2026-08-11-multi-user-production-design.md:94. Scoring is unchanged too: the panel adopts the server's existing per-ring cap, it doesn't add one.
- **Installed app versions:**
  - The inventory cache keeps `version: 1` and only gains an optional key. Older builds (e.g. a TestFlight downgrade) ignore it, and this build reads older files with `ownerActivity == nil`.
  - Existing remote journals replay unchanged. `remoteLatestRecordedAt` is derived, not stored.
  - Matches that finished before the update show no "HOW YOU SCORED", as today.
- **No Staging promotion step.** The beta checklist's normal app build verification applies.

#### Tests
**CompetitionCore: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteCompetitionReplayTests.swift`**
- New `testReplayKeepsNewestRecordedAtPerParticipant`. Owner revision at t1, remote revisions at t3 then t2 (a later client revision whose read time is earlier). Assert `remoteLatestRecordedAt == [owner: t1, remote: t3]`, and that a journal without remote revisions gives `[:]`.

**CompetitionCore: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteScoringGoldenTests.swift`**
- New `testRemoteWireV1PolicyMatchesWireAcceptedPoints`. For Move 1500/500 kcal, Exercise 30/30, Stand 12/12 (standHours, running) and for Move 420/500, 36/30, 9/12: `ActivityScoreCalculator.score(s, policy: .remoteWireV1)` points == the `RemoteScoreRevisionWireV1` `acceptedCentiPoints / 100` built from `quantizePercent` of the `.healthKitCompatibility` percentages (400 and 279). The first case's `movePercentage == 200`.

**HealthCompTests/RemoteCompetitionRuntimeTests.swift**
- Extend `testOwnerHealthRefreshEnqueuesPrivacySafeRevisionAndPersistsAck` (:1325). `materialized.ownerActivity` has:
  - `readAt == dayOneNoon`, `checkedAt == dayOneNoon`, `checkFailure == nil`
  - `days.count == 1` (only Day 1 has started)
  - Day 1: `latestSnapshot == snapshot`, `acceptedSnapshot == snapshot`, `acceptedClientRevision == 1`
- Extend `testActivityReadFailurePreservesRemoteMaterializationAndCursor` (:1202): `ownerActivity?.checkFailure == .healthDataUnavailable`, `readAt == nil`, `days == []`, and the saved cache entry carries the same value.
- New `testUnsyncedReadKeepsEarlierAcceptedSnapshot`.
  - Run 1 is accepted, as in :1325.
  - Run 2 uses a changed snapshot (Move 480/600) and `appendScoreRevision` throws `CompetitionRemoteFailure.operationFailed`.
  - Day 1: `latestSnapshot` is the new snapshot, `acceptedSnapshot` the original, `acceptedClientRevision == 1`.
- New `testOwnerActivityPersistsAndPublishesOffline`. Run with a `JSONRemoteCompetitionCacheStore`, then a second runtime whose `listCompetitions` throws. `outcome.successfulCompetitions.first?.ownerActivity` equals run 1's.
- New `testCacheRoundTripsOwnerActivityAndOmitsTheKeyWhenAbsent`. Save and load an entry with activity → equal. Encode an entry with nil → the JSON has no `"ownerActivity"` key, and a document written without the key loads. After each of two saves, the inventory file's `resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true`.
- New `testProjectorFeedsSnapshotsRefreshAndOtherPersonsReadTime`. Reuse :1793's setup (opponent rows with known `evaluated_at`) plus an owner read. Call `RemoteCompetitionProjector.dashboard(materializations: outcome.successfulCompetitions, profile:, context: CompetitionEnvironmentContext(instant:, timeZoneIdentifier: "America/Los_Angeles"), issues: [])` and assert the competition's:
  - `lastRefresh?.status == .completed`
  - `lastSuccessfulFullWindowRefreshAt == dayOneNoon`
  - `opponentUpdatedAt` == the newest opponent `evaluated_at`
  - Day 1 `ownerAcceptedSnapshot == ownerLatestSnapshot == snapshot`
  - every day's `scoringPolicy == .remoteWireV1`
- New `testProjectorDropsAcceptedSnapshotWhenTheRowMovedOn`. Build a materialization whose `ownerActivity` Day 1 has `acceptedClientRevision: 1` while the ledger row is revision 2. Assert `ownerAcceptedSnapshot == nil` and `ownerLatestSnapshot != nil`.
- New `testRemoteTodayWithoutSummaryIsNotSyncedAndPastDayIsMissing`. Owner rows: Day 1 `sourceDataUnavailable`, Day 2 `summaryPaused`, Day 3 (today) `sourceDataUnavailable`, no owner activity. (A row for a day after today can't exist, and rule 1 would make it `.notYetOccurred` anyway.) Assert:
  - Day 1 `.missing`
  - Day 2 `.unavailable(reason: .invalidSourceData)`
  - Day 3 `.notSyncedYet`
  - tallying with a Day 7 `sourceDataUnavailable` row → attention `.incomplete(missingOrdinals: [7], unavailableOrdinals: [])`

**HealthCompTests/LocalCompetitionClientTests.swift**
- New `testTodayWithoutHealthSummaryIsNotSyncedYetAndPastDaysStayMissing`. It is a copy of the :420-480 setup with a snapshot only for `window.days[1]` (today = Day 2), plus a second case with snapshots for neither day. Assert Day 2 `.notSyncedYet` and Day 1 `.missing`, and in the first case Day 2 `.observed`.

**HealthCompTests/CompetitionPresentationTests.swift**
- New `testRingPanelRowsAddUpToTheAcceptedDayScore`. Snapshot 420/500 kcal, 36/30, 9/12 standHours, accepted 279. Assert:
  - titles ["Move", "Exercise", "Stand"]
  - details ["420/500 kcal", "36/30 min", "9/12 hr"] (en_US)
  - points [84, 120, 75]
  - note nil
  - footer "1 point per 1% of each ring. Your ring values stay on this iPhone."
  - label == "Your rings. Move, 420 of 500 kilocalories, 84 points. Exercise, 36 of 30 minutes, 120 points. Stand, 9 of 12 hours, 75 points."
- New `testRingPanelSplitsACappedDayAndSaysSo` (local policy): 1100/500, 60/30, 24/12, accepted 600 → points sum 600, each whole, footer starts with "Capped at 600 points a day."
- New `testRealMatchRingPanelCapsEachRingAt200`: `scoringPolicy: .remoteWireV1`, Move 1500/500, 30/30, 12/12.
  - accepted 400 → points [200, 100, 100]; footer "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone."
  - `ringSegments(day).map(\.points) == [200, 100, 100]`
  - same snapshot unaccepted (latest only) → calculator points [200, 100, 100], note "These points haven’t synced yet."
- New `testRingPanelDrawsTheAcceptedSnapshotAndNotesANewerReading`: accepted ≠ latest → the rows come from accepted, and the note is "Points use an earlier reading. Your rings have changed since."
- New `testRingPanelMarksAScorableUnsyncedReading`: accepted nil, latest scorable, points nil → points from the calculator, note "These points haven’t synced yet."
- New `testRingPanelOmitsPointsForAPausedReading`: accepted nil, latest paused → all `points == nil`, `isPaused`, note nil, label contains "Activity tracking paused".
- New `testRingPanelIsNilWithoutSnapshots`.
- Replace `testUnknownStandAndPauseStillSupportTruthfulSystemRings` (:449) with `testUnknownStandModeReadsStandOrRoll` (local policy; real matches can't store this reading): the label contains "Stand or Roll" and does not contain "pause".
- Replace `testMoveTimeRollAccessibilityUsesFullTruthfulUnits` (:468) with `testRingPanelMoveTimeRollUsesFullSpokenUnits`: the label contains "Your rings", "Move Time, 60 of 30 minutes, 200 points", "Exercise, 60 of 30 minutes, 200 points" and "Roll, 24 of 12 hours, 200 points".
- Delete `testNilAcceptedSnapshotNeverClaimsEarlierHigherEvidence` (:488) and `testDifferentAcceptedAndLatestSnapshotsUseNeutralPolicyCopy` (:517); the two ring-panel note tests above replace them. PR 1 edits the second one's copy, so drop it on rebase.
- `testPerDayUnavailableReasonsStayDistinctAndNeutral` (:325): add `.notSyncedYet` → "Today hasn’t synced yet".
- `testCompactChartDistinguishesFutureMissingUnavailableAndZero` (:379): add `.notSyncedYet` → `.unscored` and accessibility "not synced yet".
- New `testFreshnessLineNamesBothSidesOnlyWhenBothExist`. Use `evaluatedAt` 2026-10-31T16:41Z, LA, en_US, and opponent "Hermes":
  - you = `evaluatedAt`, them = 2026-10-31T06:40Z → normalized "You: updated 9:41 AM · Hermes: updated Fri 11:40 PM"
  - you only → "Updated 9:41 AM"
  - them only → "Hermes: updated Fri 11:40 PM"
  - neither → nil

**Standalone formatter script: `scripts/tests/competition-local-date-formatting.swift`** (on top of PR 1's rewrite). With `now` = 2026-10-31T16:41Z and `la`:
- `competitionUpdatedText(2026-10-31T16:41Z, now, en_US, la)` normalized == "9:41 AM"
- `(2026-10-31T06:40Z, …)` == "Fri 11:40 PM"
- `(2026-10-20T04:41Z, …)` contains "Oct 19"

**UI tests: LocalCompetitionLifecycleUITests.swift**
- :61-64 (Day 1, late-sync):
  - keep `rings.label.contains("Stand or Roll")`
  - replace the "pause status unknown" assertion with `rings.label.contains("200 points")`
  - add `XCTAssertTrue(app.staticTexts["competition.updated"].label.hasPrefix("Updated "))`
- After :75 (the Ends Today checkpoint; late-sync Day 7 has no summary): add `XCTAssertTrue(app.descendants(matching: .any)["competition.notSynced"].exists)`.
- `testMoveTimeRollUsesOwnerOnlyTruthfulSystemRings` (:303-317), renamed `testMoveTimeRollRingRowsUseTruthfulUnits`:
  - "Naren activity" → "Your rings"
  - keep the "Move Time", "60 of 30 minutes" and "Roll, 24 of 12 hours" assertions
  - then `app.scrollViews.firstMatch.swipeDown()` (pull-to-refresh) and assert `rings.waitForExistence(timeout: 5)` and `competition.updated` still exist
- Unchanged: :254 (`competition.ownerRings` absent in the unavailable fixture) and :257 ("Activity source is temporarily unavailable.").

**UI tests: MultiUserCompetitionUITests.swift**
- `testRemoteDayDrawerShowsBothAcceptedScoresWithoutRawHealthSnapshots` (:215-236), renamed `testRemoteDayDrawerShowsRingsThatAddUpToTheDayScore`:
  - keep the two summary assertions (PR 1 rewrites the first to "You, 500 points")
  - replace :235 with `XCTAssertTrue(app.otherElements["competition.ownerRings"].exists)`
  - the label contains "Move, 1,000 of 500 kilocalories, 200 points" and "Stand, 12 of 12 hours, 100 points" (Day 1)
  - the footer reads "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone."
- At :162 (active Jordan match): `let updated = app.staticTexts["competition.updated"].label`, then `XCTAssertTrue(updated.hasPrefix("You: updated"))` and `XCTAssertTrue(updated.contains("Jordan: updated"))`.

**Accessibility identifiers**
- Added: `competition.updated` (freshness line) and `competition.notSynced` (not-synced panel).
- Kept, on a new element: `competition.ownerRings` (now the ring list panel).
- Removed: `competition.ownerActivityText`. No test references it.
- Unchanged: `competition.lastSync`, `competition.lastSync.N`, `competition.day.N`, `competition.scoreHeader.naren/.alex`, `competition.more`, `competition.status` (PR 1).

**Verify on the Mac mini:**
- HealthCompTests, `swift test` in Modules/CompetitionCore, the standalone script, and both UI suites, including the `.dynamicType` audit and the AX XXXL `.textClipped` / `.hitRegion` audits.
- Light/dark captures of the Today page (scored, earlier-reading note, not synced) and a day drawer, at XS and AX5.
- One Staging run with two accounts: the Today rows, "You: updated … · {Name}: updated …", pull-to-refresh, then relaunch in airplane mode and confirm the rows and freshness line persist.

#### Risks and sequencing
- **Depends on PR 1** and rebases onto it. It uses `competitionPointsText`, `competitionPointsAccessibilityText`, `competitionRoundedParts`, `competitionMomentText`, `competitionDayText` (CompetitionDay overload, drawer subtitle), PR 1's `competitionRefreshTimelineText(..., now:)` and PR 1's rewrite of `competitionOwnerAccessibilityText`, which gets the new case.
- **Gap in PR 1.** It has no same-day time-only style, so PR 2 adds `competitionUpdatedText` to CompetitionDateFormatting.swift (Foundation-only, with standalone checks). If PR 1 later adds an equivalent, use it instead.
- **Shared file: CompetitionDetailView.swift.** PR 1 rewrites the status row, scoreboard, `competitionDayAccessibilityLabel` and the drawer subtitle; PR 3 (f-chips, f-tally, f-scheduled) owns the status/scoreboard/tally/scheduled regions.
  - PR 2 owns the Today page body, `dayDrawer`, `activitySyncDrawer`, the ring panel and the freshness line slot directly under `leadStatement`.
  - Land PR 2 before PR 3, or rebase whichever is second. PR 3 must keep `competition.updated` under the lead line and must not reintroduce `TodayBreakdown`.
- **Other shared files:**
  - PR 3 also touches CompetitionResultView; PR 2 changes nothing there.
  - CompetitionWeekChart.swift: PR 2 only extracts `competitionRingShares` (PR 1 changes the same file elsewhere).
  - PR 4 (Home) might want the freshness text on cards; it should call `competitionFreshnessText`.
- **Ring panel polish row.** It is satisfied here, because the rewritten panel has no "running" line. PR 3 drops its own ActivityRingsView.swift edits for it.
- **f-tally alignment.** Real-match `sourceDataUnavailable` rows now count as missing in the tally attention ("Day 7 is missing activity data." instead of "Day 7 activity source is unavailable."). PR 3 rewrites those sentences and should keep that mapping.
- **CompetitionCore change.** One derived projection field and one display-only policy constant (`.remoteWireV1`); there is no journal, genesis or wire format change. CompetitionCore CI (`swift test`) must pass.
- **Pre-existing defect, out of scope (Claude's call).** When the wheelchair characteristic read throws, HealthKitProvider sets `standMode = .unknown` (HealthKitProvider.swift:128-136). For a live real match, every scorable day then throws `invalidMode` in `RemoteScoreRevisionWireV1.init`, so that match's whole sync fails as `.discoveryUnavailable` and the user's scores never upload. PR 2 doesn't change this. File it as its own `bugfix/` PR: the fix decides how such a day is scored (e.g. send `unsupportedActivityConfiguration`, or assume standHours), which is a scoring decision, not a display one.
- **Backup exclusion.** After this PR, a phone restored from backup re-downloads matches; finished real matches lose "HOW YOU SCORED" there (same as a fresh install).
- **Cache size ceiling.** ~2–4 KB per listed match inside the 1 MiB inventory file. Past roughly 250 listed matches a save throws, and the next publication reports `.storageUnavailable`. This is marked with a `ponytail:` comment; split into its own file when it matters.
- **Behavior change on real matches.** Past days with no Health summary flip from "!" / "Activity source is temporarily unavailable." to "?" / "Day N is missing activity data.". This is intended, but call it out in the PR description.
- **Dropping the Apple ring graphic (HKActivityRingView)** follows the Proposed mockup. Screenshots in docs/release that show the ring graphic go stale.

#### Open questions
Moved to §10: Q16 (the other person's 0 before you sync) and Q15 (footer privacy wording). Both defaults are built above.

### PR 3 — Match and result screens

#### Scope
- **f-tally**: the score is visibly provisional; status reads "FINAL SCORE PENDING · BY WED NIGHT"; one plain card says who or what it is waiting on and whether you need to do anything; remote matches can now say they are waiting on the other person; singular/plural fixed; no warning icon; Day 7 has one name.
- **f-chart**: four distinct closed-day states (won, lost, tied, no data) plus upcoming and today in the strip; words instead of glyphs in week rows; "DAY 3 · FRI" on rows; "Not synced" is different from "Upcoming"; the legend follows Stand/Roll and explains no data.
- **f-scheduled**: one compact block ("YOU VS HERMES", "Day 1 is Wednesday. Points start counting at midnight.", weekday strip). The range card, the "Scores begin Day 1" line and the seven empty rows are removed.
- **f-mute**: "Mute {Name}" with the subtitle "All your matches with {Name}"; "· MUTED" next to the status; load and save errors are separate, named per person, and shown at the top of the screen.
- **f-rules**: one rules card (dates, scoring, how the winner is decided, what {Name} sees) used on the match, challenge, claim and create screens. The line "Their ring detail stays on their iPhone." is removed.
- **f-chips** (result): "You beat {Name}" / "{Name} won" / "All square with {Name}" (the tie in neutral); "Won by 230 points · won 2 days, lost 4, tied 1"; tied and missing days are no longer counted as losses; a margin that rounds to 0 is hidden.
- Polish **Ring panel**: owned by PR 2. PR 2 rewrites ActivityRingsView.swift and deletes the code this PR used to edit, so this PR leaves that file alone.
- Polish **Result title**: `lineLimit(2)` + `minimumScaleFactor(0.5)`; the tie is drawn in neutral.

#### Behavior

Strings are written in sentence case. Rows marked "drawn uppercase" use `.textCase(.uppercase)`. All dates use PR 1 helpers with `now: competition.evaluatedAt`.

##### f-tally: tallying match screen
Top to bottom:
1. **Status row** (PR 1 row, `competition.status`): title "Final score pending", timing "By {D}". It is drawn uppercase: "FINAL SCORE PENDING  BY WED NIGHT". VoiceOver: "Final score pending · By Wed night". There is no live dot.
2. **Scoreboard**: "YOU 3,413 / HERMES 3,398" (PR 1). Below it, in place of the hairline and the period row, a centered outlined capsule reads "PROVISIONAL" (`Theme.secondary` text, `Theme.outline` stroke). The capsule is hidden from VoiceOver because the score headers already say "provisional total".
   - **Score header VoiceOver**: "You, Day 7 300 points, provisional total 3,413 points". The period label is "Day 7", no longer "Final day".
   - **Deviation**: the mockup dims the scoreboard to 75% opacity. That is not built, because dimmed amber fails 4.5:1 in light mode.
3. **Lead line**: PR 1's `competitionLeadText`, followed by " Not final yet." only while tallying. Examples: "You lead by 15. Not final yet.", "Hermes leads by 3. Not final yet.", "All square. Not final yet." The mockup says "You're ahead by"; PR 1's "You lead by" is kept so there is one lead sentence app-wide.
4. **Tally card** (`competition.tally`, one combined VoiceOver element): a semibold ink headline and a secondary body, with no icon in any state.
5. **Segmented control**: "Day 7 | Week". It reads "Today" only while a day is live (`currentDayOrdinal != nil`). PR 2 replaces the sections under it with its ring panel; this PR only renames the segment. Day 7 is now called "Day 7" everywhere.

**{D}, the deadline.** It is `competitionDeadlineText(tally.bestAvailableDeadline, …)`:
- If the deadline is exactly midnight in the phone's zone, it names the day that ends: "Wed night". Remote deadlines are midnight at the start of match day 9 in the calendar zone (supabase/migrations/20261019001800_bind_invitation_recipients.sql:257, offset 8), so a phone in the match zone sees "Wed night".
- Otherwise it is PR 1's moment: "Wed 9:00 PM". This is what a phone in another zone sees, and what the local fixture sees (`startedAt + bestAvailableGrace`).

**Card copy.** Let `days` be `competitionDayListText(ordinals)`: "Day 7", "Days 5 and 7", or "Days 3, 5, and 7" (locale list style). It is nil for 4 or more days. Let `verb` be "hasn’t" for one day and "haven’t" for more.

| Attention | Headline | Body |
|---|---|---|
| `.opponentPlanUnavailable` (remote: their day rows missing; fixture: simulated plan not final) | Waiting for Hermes to sync | Nothing for you to do. If Hermes doesn’t sync by {D}, the result uses what’s in. |
| `.incomplete(missing, [])` (yours) | Waiting for your {days} (≥4 days: "Waiting for your Activity") | {days} {verb} synced from this iPhone. Open HealthComp again before {D}, or the result uses what’s in. (≥4: "7 days haven’t synced…") |
| `.incomplete(_, unavailable≠∅)` (fixture only) | Waiting for your {days of missing ∪ unavailable} | HealthComp couldn’t read {days} on this iPhone. Open HealthComp again before {D}, or the result uses what’s in. (≥4: "couldn’t read 4 days") |
| `.unacceptedScores(o)` (fixture) | Scoring your {days} (≥4: "Scoring your Activity") | Nothing for you to do. If it isn’t done by {D}, the result uses what’s in. |
| `.noRead` (fixture) | Checking Activity on this iPhone | Nothing for you to do. If it isn’t done by {D}, the result uses what’s in. |
| `.awaitingStability`, or `attention == nil` | Checking the last scores | Nothing for you to do. The result is final by {D} at the latest. |
| any, when `evaluatedAt >= deadline` | Finishing the result | The deadline passed, so the result uses what’s in. It appears here shortly. |

- **Waiting-on-you copy deviates slightly from the audit note.** The note says "Open HealthComp on it before Wed 9 PM". The person is already in HealthComp when they read this, so the copy says "Open HealthComp again" and adds the consequence.
- **Opponent headline deviates from the mockup ("…last days").** The missing days are not always the last ones. All 7 are missing when they have never synced.

**Remote wait (Claude's call, from the code).** The remote attention is computed from both ledgers:
1. Any of your day rows missing: `.incomplete(missingOrdinals: yours, unavailableOrdinals: [])`.
2. Otherwise, any of their rows missing: `.opponentPlanUnavailable`.
3. Otherwise: `.awaitingStability`.

Your rows with an unavailable reason count as "in". Your iPhone attests `stable` as soon as all 7 rows exist, including unavailable ones (`RemoteCompetitionRuntime.swift:1176-1182`). The server then finalizes when both attestations are stable (supabase/migrations/20260811000400_add_score_and_finalization_functions.sql:417-420). So an unavailable row never blocks the result, and telling the person to act on it was the "wrong wait" the audit describes. The day's chart row still says "No data".

**Status everywhere.** The tallying title changes in PR 1's shared formatter, so Home rows read "Final score pending · By Wed night" and the competitionEnded notification title reads "Final score pending". The timing appears only in the `.row` and `.card` styles, only through the presentation overload, and only before the deadline.

##### f-chart: strip and week rows
**`CompetitionDayOutcome`.** One rule, shared by the strip and the result's day counts:
- `today`: `day.ordinal == currentDayOrdinal`
- `upcoming`: `ownerLatestAvailability == .notYetOccurred`
- `noData`: either score is nil, **or both displayed scores are 0** (Claude's call; §10 Q11)
- `won` / `lost` / `tied`: from `competitionDisplayedMargin` > 0 / < 0 / == 0

**Strip** (`CompetitionWeekStrip`: Home card, result week card, scheduled block):

| Outcome | Bar |
|---|---|
| won | solid `Theme.youFill` |
| lost | solid `Theme.ink` |
| tied | solid `Theme.tertiary` (mid grey, clearly darker than track/outline) |
| noData | vertical hatch, 1 pt `Theme.faint` lines every 3 pt, clipped to the slanted bar |
| upcoming | empty bar, 1 pt `Theme.outline` stroke |
| today | dashed stroke in the leader's color (unchanged) |

Labels are unchanged ("TODAY", "WED"). While tallying, `currentDayOrdinal` is nil, so Day 7 shows its weekday.

**Week rows** (`HeadToHeadDayRow`, sizes below the accessibility sizes):
- **Centre label**: "DAY 3 · FRI", or "DAY 4 · TODAY" for today, drawn uppercase. PR 1's date line "Oct 30" stays under it when `showsDates`.
- **Your cell**:
  - a score shows the number, as today
  - `.missing` / `.unavailable` show "No data"
  - `.unscored` shows "Not scored"
- **Their cell**: the number; "No data" when they sent a row with no score (`opponentReportedNoData`, remote only); otherwise "Not synced" when nil on a started day.
  - **Claude's call: their synced-but-empty day reads "No data", not "Not synced".** A remote row with `accepted_centi_points` null (for example `summaryPaused`, `missingMoveGoal`) counts as "in" for the tally, so the tally card says "Checking the last scores". Showing "Not synced" in the same row would blame Hermes for a wait that isn't happening. The remote day presentation (RemoteCompetitionClient.swift:1878-1890) carries only `acceptedCentiPoints`, so this PR adds one Bool (Design D, E). The reason itself is not shown, matching your own "No data" cell.
  - **Deviation**: the mockup has "Hermes not synced". The name is dropped because long names would crush the bars. The cell is already on their side, and VoiceOver says the name.
- **Word style**: words use `.footnote.weight(.semibold)` in `Theme.secondary` and `fixedSize()`. Numbers keep the current font and colors.
- **Bars**: a "No data" or "Not synced" cell draws a 24 pt-wide hatch stub (10 pt tall), not today's 2 pt line.
- **Upcoming row**: the row collapses to one centred line, "DAY 5 · SUN" plus "Upcoming" (`Theme.tertiary`), with no bars or values.
- **Accessibility sizes** (`StackedDayRow`) use the same words. An upcoming day shows its title, PR 1's date line and "Upcoming", with no score blocks.

**Legend** (`CompetitionRingLegend`, under the match Week tab and in the result week drawer):
- **Your swatches**: "MOVE EXERCISE STAND". "ROLL" replaces "STAND" when any day's accepted snapshot has `standMode == .rollHours`. When no day has a three-ring split (remote matches today), a single amber "YOU" swatch replaces the three ring swatches.
- **Theirs**: "{NAME}" in ink.
- **No data**: a hatch swatch "NO DATA", shown only when some started day has a nil score on either side.
- **VoiceOver**: "Move, Exercise and Roll are your rings. The single bar is Hermes. Striped bars mean no data." When there is no ring split, the first sentence is "The left bar is yours."
- **Deviation**: the mockup's "▭ AHEAD" item is not built. Upcoming rows say "Upcoming" in words, so it would label nothing on screen.
- The result drawer's "HOW YOU SCORED" third label follows Stand/Roll the same way.

**VoiceOver day rows.** PR 1's labels are kept. One change: a closed day with no score from them reads "Hermes, not synced.", or "Hermes, no data." when `opponentReportedNoData`, matching the screen (PR 1 has "score not available").

##### f-scheduled: scheduled match screen
- **Status row** (PR 1): "SCHEDULED  STARTS WED, OCT 28". PR 1's comma deviation stands.
- **In the same panel**, replacing "Scores begin Day 1":
  - "YOU  VS  HERMES": `.title.weight(.heavy).width(.condensed)`; YOU in `Theme.you`, VS smaller in `Theme.tertiary`, the name in ink. It wraps for long names. VoiceOver: "You versus Hermes".
  - "Day 1 is Wednesday. Points start counting at midnight." (`.body`, `Theme.secondary`, identifier `competition.schedule.dates`). Wednesday is the full weekday of `days[0]` in the injected locale.
  - **Same wording for both people, in any zone (answered from the code).** Scores come from each person's own Activity summary for that calendar date. The HealthKit query uses calendar-only date components with no time zone (HealthKitProvider.swift:360-390, `activitySummaryPredicate`, fixed in #177 and covered by `testActivitySummaryPredicateUsesCalendarOnlyDayComponentsAcrossTimeZones` for LA and Kolkata). The weekday comes from the date's year/month/day (`weekdayText` uses a UTC calendar on those components), so it is the same for everyone. A recipient in another zone gets their own Wednesday's rings, which start at their own midnight. Late catch-up submissions are accepted (20260928001600_allow_score_catch_up.sql), so a phone ahead of the match zone still counts its Wednesday. The tally deadline differs because it is one instant, which is why only it falls back to the moment style. `CompetitionScheduledSummary` takes no time zone.
  - `CompetitionWeekStrip(days:, currentDayOrdinal: nil)`: seven outlined bars labelled WED…SUN. It hides the labels at xxLarge and above (existing rule).
- **Removed**: the `scheduledCard` (range card and its fallback), the segmented control and the week rows. The rules card (••• → How scoring works) carries the week dates.
- **No days** (schedule missing or mismatched): the line reads "Day 1 starts on the next match day." and the strip is omitted.

##### f-mute
- **••• menu, in order**:
  - "Mute Hermes" (bell.slash.fill) or "Unmute Hermes" (bell.fill), with the subtitle "All your matches with Hermes"
  - "Sync status" (was "Activity Sync"); its drawer is titled "Sync status"
  - "How scoring works" (was "Rules"); its drawer is titled "How scoring works"
  - The result screen's menu shows the same mute item.
- **Muted marker**: when muted, the match status row title reads "DAY 4 OF 7 · MUTED", with "· MUTED" in `Theme.secondary`. VoiceOver appends ". Muted" to the status label. The result kicker reads "FINAL · OCT 24 – 30 · MUTED". The marker shows only when the mute button exists (notifications authorized and the opponent known; `competitionMuteIdentity`).
- **Error note**: the first item of the scroll, above the scoreboard panel or result hero. It is caption, `Theme.secondary`, `exclamationmark.circle`, identifier `competition.notifications.preference-error`, and per person:
  - load failed: "Couldn’t check whether Hermes is muted."
  - mute save failed (rolled back): "Couldn’t mute Hermes. Try again from the More menu."
  - unmute save failed (rolled back): "Couldn’t unmute Hermes. Try again from the More menu."
- **Precedence and clearing**:
  - A save failure for this person outranks the load failure.
  - Tapping the item again clears that person's save failure. Other people's failures stay.
  - The load failure clears on the next successful load, even when the loaded set equals the current one. Today that case sends no action, so the flag would stick.

##### f-rules: `CompetitionRulesCard`
The rows are `CompetitionRuleRow`s with dividers:

| Icon | Title | Detail |
|---|---|---|
| calendar | Seven days | the week, e.g. "Oct 28 – Nov 3", from PR 1's `competitionScheduleDateRangeText`; before a schedule exists: "Day 1 is the day after the challenge is accepted." |
| rings | 1 point per 1% of each ring | Up to 600 points a day |
| trophy | Most points after 7 days wins | Equal totals tie. A day with no data scores 0. |
| lock.iphone | remote: "Hermes sees your daily points and rounded ring percentages" (no name known: "The other person sees…") · fixture: "Nothing leaves this iPhone" | remote (default, §10 Q2): "Also whether you use Move Time or Roll, why a day has no data, and when your iPhone last updated your scores. Your Health data stays on your iPhone." · fixture: "Hermes is simulated." (with no name: nil) |

- **Deviations from the mockup**:
  - The week uses PR 1's week style without weekdays.
  - "A day with no data scores 0." is added because the audit lists the missing-day rule as a gap.
  - The detail clauses are added because the other participant can read every `daily_score_revisions` column for the match (RLS `daily_score_revisions_participant_read`, add_competition_rls.sql:121-125), and the `score_revision_recorded` feed payload carries `move_mode`/`stand_mode`, `availability_reason` and `evaluated_at` (20260811000500_include_attestation_version_in_change_feed.sql:73-91). This card is the consent point, so it must not under-disclose. The published privacy policy already says your competitor sees "availability" and "Activity modes" (web/privacy.html:70-73). It does not name the update time.
  - The title stays as it is, so the exact-string UI assertions (MultiUserCompetitionUITests :247, :324) do not depend on the answer to §10 Q2. Only the detail line changes, and the UI tests check it with `CONTAINS "Your Health data stays on your iPhone"`.
- **Where the card appears**:
  - match ••• → How scoring works: name and week
  - challenge screen: name, no week yet
  - claim sheet: no name, no week; replaces its private 3-row card
  - create screen: unchanged call, no name
- **Removed**: the Today breakdown's "Hermes’s points. Their ring detail stays on their iPhone." now reads "Hermes’s points." If PR 2 has landed, its rewrite already removed that block and there is nothing to change.

##### f-chips and Result title
- **Kicker** (PR 1) is unchanged except for "· MUTED".
- **Title**:
  - win: "You beat Hermes" in `Theme.you`
  - loss: "Hermes won" in `Theme.ink`
  - tie: "All square with Hermes" in `Theme.secondary`
  - Base size 52 (was 64), `@ScaledMetric(relativeTo: .largeTitle)`, `lineLimit(2)`, `minimumScaleFactor(0.5)`, centred, header trait.
- **Subtitle line removed**, as in the mockup. Fixture matches show `competitionFixtureDisclosure` ("Alex is simulated on this iPhone.") in its place, so the simulation disclosure the old subtitle carried survives.
- **Final score panel** is unchanged (PR 1).
- **Summary line** replaces both chips. It is one centred `Text` with identifier `competition.result.summary`:
  - Margin: "Won by 230 points" in bold `Theme.you`, or "Lost by 230 points" in bold `Theme.ink`.
    - "1 point" when the shown margin is 1.
    - PR 1's tie-break digits give "Won by 0.30 points".
    - Hidden when the displayed margin is 0, which means an exact tie.
  - " · " in `Theme.tertiary`.
  - Days, in `Theme.secondary`:
    - Count only days with both scores, excluding displayed 0–0 days (the `CompetitionDayOutcome` rule).
    - List the non-zero parts in the order won, lost, tied. The first part carries the noun: "won 2 days, lost 4, tied 1", "won 5 days, lost 2", "lost 1 day", "tied 7 days".
    - Hidden when nothing counts.
  - Either part alone shows without the separator. With both hidden, there is no line.
  - VoiceOver reads the text as is.
- **Week card** VoiceOver: "The week. won 2 days, lost 4, tied 1", or "The week" when there are no counts.
- **Result VoiceOver** (PR 1 shape): "You beat Hermes. Final score. You 3,410 points. Hermes 3,180 points."
- **Notifications (Claude's call)**: the result notification title also becomes "All square with {Name}" for ties, via the shared formatter, so a tie is named one way. Win and loss titles already match PR 1.
- **Out of scope**: the mockup's nav title "Hermes · Oct 24–30" (PR 1 keeps the name only) and "Rematch Hermes" (PR 6, rematch).

##### Ring panel pause caption
Owned by PR 2: its panel shows "Activity tracking paused" only when paused, and nothing for running or unknown.

##### Edge cases
- **Multiple matches and repeat opponents**: every view reads its own presentation. Mute is per person, so the "· MUTED" marker and errors show on every match with that person.
- **Long names** wrap in "YOU VS {NAME}", the tally headline, the rules title and the error note. The result title shrinks to 50%, then truncates after 2 lines. The full title stays in the VoiceOver label.
- **Accessibility sizes**:
  - The status row stacks (PR 1).
  - The PROVISIONAL capsule is `fixedSize`.
  - Stacked rows show words.
  - The strip hides weekday labels at ≥ xxLarge (existing).
  - The rules card and tally card wrap (`fixedSize(horizontal: false, vertical: true)`).
- **Day 1**: no tally state applies. A 0–0 strip bar for today is still drawn dashed (today rule).

#### Design

"PR 1's X" means the code PR 1 writes at that anchor.

**A. CompetitionDateFormatting.swift (Foundation-only), after PR 1's `competitionMomentText`**
```swift
/// A tally deadline: "Wed night" when it falls exactly on midnight in `timeZone`, else the moment style.
func competitionDeadlineText(_ date: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String
```
- Use a gregorian calendar in `timeZone`. If `calendar.startOfDay(for: date) == date`, return `"\(weekday) night"`, where `weekday` formats `date - 1` with template "EEE" through PR 1's private formatter helper.
- Otherwise return `competitionMomentText(date, now:, locale:, timeZone:)`.

**B. CompetitionWeekChart.swift**
- **After PR 1's `weekdayText`** (:397-409), add
  ```swift
  func weekdayName(_ day: CompetitionDay, locale: Locale = .current) -> String
  ```
  It has the same body as `weekdayText`, using `calendar.weekdaySymbols` and `calendar.locale = locale`.
- **After `ringSegments`** (:362-383), add:
  ```swift
  enum CompetitionDayOutcome: Equatable { case today, upcoming, won, lost, tied, noData }
  func competitionDayOutcome(_ day: LocalCompetitionDayPresentation, currentDayOrdinal: Int?) -> CompetitionDayOutcome
  func competitionDayListText(_ ordinals: Set<Int>, locale: Locale = .current) -> String?
      // 1 → "Day 7"; 2–3 → "Days " + sorted.map(String.init).formatted(.list(type: .and).locale(locale)); ≥4 or 0 → nil
  /// Vertical 1 pt lines every 3 pt: the "no data" fill.
  struct HatchFill: Shape  // path: move/addLine at x = minX, minX+3, … < maxX
  ```
  Draw it as `HatchFill().stroke(Theme.faint, lineWidth: 1).clipShape(SlantedBar())`.
- **`CompetitionWeekStrip`** (:110-134):
  - `bar(_:)` switches on `competitionDayOutcome(day, currentDayOrdinal:)`.
  - `.today` keeps the dashed stroke with `leaderColor`.
  - `.upcoming` → `SlantedBar().stroke(Theme.outline, lineWidth: 1)`.
  - `.noData` → the hatch.
  - Otherwise fill with youFill / ink / tertiary.
  - Delete `winnerColor`. PR 1's displayed-margin edit to it is superseded.
- **`CompetitionRingLegend`** (:148-184): replace `let opponentName: String` with `let days: [LocalCompetitionDayPresentation]; let opponentName: String`. Compute:
  - `showsRings = days.contains { ringSegments($0).count == 3 }`
  - `usesRoll = days.contains { $0.ownerAcceptedSnapshot?.standMode == .rollHours }`
  - `showsNoData = days.contains { $0.ownerLatestAvailability != .notYetOccurred && ($0.ownerAcceptedPoints == nil || $0.opponentRevealedPoints == nil) }`
  - The rings row becomes either the three swatches (STAND/ROLL) or `swatch(Theme.youFill, "YOU")`. Add the hatch swatch "NO DATA". The VoiceOver label follows Behavior.
- **`HeadToHeadDayRow`** (:186-238):
  - When `ownerState == .future && !isToday`, return the centred `HStack { DayLabel; Text("Upcoming") }`.
  - Otherwise the cells use the new `chartCellText` with a word style for non-numbers.
  - Their side is `day.opponentRevealedPoints.map(competitionPointsText) ?? (day.opponentReportedNoData ? "No data" : "Not synced")`.
- **`OwnerDayBar`** (:322-323): `.missing, .unavailable, .unscored` → hatch stub `frame(width: 24, height: 10)`.
- **`OpponentDayBar`** (:348-350): take an extra `let started: Bool`. Non-score with `started` → hatch stub; otherwise the track line.
- **`StackedDayRow`** (:240-276): an upcoming day shows only the title, the date line and `Text("Upcoming")`. The score values use `chartCellText` and the same their-side rule.
- **`DayLabel`** (:278-298): line 1 is `isToday ? "Day \(n) · Today" : "Day \(n) · \(weekdayText(day.day))"` with `.textCase(.uppercase)`.
- **`chartValueText`** (:385-395) is replaced by:
  ```swift
  private func chartCellText(_ state: CompetitionChartState) -> String
      // score/missingWithScore/unavailableWithScore → competitionPointsText; .missing/.unavailable → "No data"; .unscored → "Not scored"; .future → "Upcoming"
  ```

**C. CompetitionDetailView.swift**
- **Body** (:29-110):
  - **Scroll content** is `VStack { muteButton?.failureNote; VStack(spacing: 12) { CompetitionScoreboardPanel(…, isMuted: muteButton?.isMuted == true); leadStatement }; tallyPanel; if competitionShouldShowScores(competition.lifecycle) { Picker … } }`.
  - **Removed**: the `.scheduled` branch (:43-45, `scheduledCard` + `weekSection`) and `muteButton?.saveFailure` at :64.
  - **Picker label** (:48) becomes `Text(todayTabTitle)`, with `private var todayTabTitle: String { todayDay.map { $0.ordinal == competition.currentDayOrdinal ? "Today" : "Day \($0.ordinal)" } ?? "Today" }`.
  - **Menu** (:79-91): "Sync status" and "How scoring works". The rules drawer (:104-107) becomes `CompetitionDrawer(title: "How scoring works") { CompetitionRulesCard(source: source, opponentName: competition.opponentDisplayName, weekText: competition.acceptedConfiguration.flatMap { competitionScheduleDateRangeText($0.schedule, now: competition.evaluatedAt, locale: locale) }) }`. The activitySync drawer title (:322) becomes "Sync status".
- **`leadStatement`** (:113-120): `competitionLeadText(...)` from PR 1, plus `(scoresAreProvisional ? Text(" Not final yet.") : Text(""))`.
- **`tallyPanel`** (:136-169) is replaced by:
  ```swift
  let copy = competitionTallyCopy(tally, opponentDisplayName: competition.opponentDisplayName,
                                  now: competition.evaluatedAt, locale: locale, timeZone: timeZone)
  VStack(alignment: .leading, spacing: 4) {
      Text(copy.headline).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
      Text(copy.body).font(.subheadline).foregroundStyle(Theme.secondary)
  }  // each .fixedSize(horizontal: false, vertical: true); then .frame(maxWidth: .infinity, alignment: .leading)
     // .padding(16).themePanel(cornerRadius: 16).accessibilityElement(children: .combine).accessibilityIdentifier("competition.tally")
  ```
- **Deleted**: `scheduledCard` (:171-200).
- **`CompetitionMuteButton`** (:385-422):
  ```swift
  enum CompetitionMuteFailure: Equatable, Sendable { case load, mute, unmute }
  struct CompetitionMuteButton: View {
      let opponentName: String; let isMuted: Bool; let isInFlight: Bool
      let failure: CompetitionMuteFailure?          // replaces saveFailed: Bool
      let toggle: () -> Void
      // body: Button(action: toggle) { Label(isMuted ? "Unmute \(opponentName)" : "Mute \(opponentName)", systemImage: …); Text("All your matches with \(opponentName)") }
      //       .disabled(isInFlight).accessibilityIdentifier("competition.notifications.mute")
      @ViewBuilder var failureNote: some View   // replaces saveFailure; copy from competitionMuteFailureText; same identifier as today
  }
  func competitionMuteFailureText(_ failure: CompetitionMuteFailure, opponentName: String) -> String
  ```
  - Two `Text`s in a `Menu` button label render as title and subtitle on iOS 15+. Verify this on the iOS 18.5 simulator.
  - **Fallback** if the subtitle does not render: wrap the item in `Section("All your matches with \(opponentName)") { … }` inside the menus at :76-78 and in ResultView :507-509.
- **`CompetitionScoreboardPanel`** (:509-707):
  - Add `let isMuted: Bool`.
  - **PR 1's status row title**: `Text(status.title)` plus, if muted, `Text(" · Muted").foregroundStyle(Theme.secondary)`. The label is `status.line + (isMuted ? ". Muted" : "")`.
  - **Body** (:520-535):
    ```swift
    if competitionShouldShowScores(...) { scoreboard; if isProvisional { provisionalTag } else { hairline; periodRow } }
    else { CompetitionScheduledSummary(competition: competition) }
    ```
  - **`provisionalTag`**: `Text("PROVISIONAL").font(.themeLabel).tracking(1.2).foregroundStyle(Theme.secondary).padding(.horizontal, 8).padding(.vertical, 2).overlay(Capsule().stroke(Theme.outline)).fixedSize().frame(maxWidth: .infinity).accessibilityHidden(true)`.
- **New, internal so PR 4 can reuse it on the Home card**, placed after the panel:
  ```swift
  struct CompetitionScheduledSummary: View { let competition: LocalCompetitionPresentation }  // locale from @Environment
  ```
  It contains the headline `Text` concatenation, `.accessibilityLabel("You versus \(name)")`, the Day 1 line with `competition.schedule.dates`, and the strip.
  - Day 1 line: `"Day 1 is \(weekdayName(first.day, locale: locale)). Points start counting at midnight."`.
  - Fallback when `competition.days` is empty: "Day 1 starts on the next match day."
- **`TodayBreakdown.opponentNote`** (:834-839): `Text("\(opponentName)’s points.")`. Skip this if PR 2 has landed; PR 2 deletes `TodayBreakdown`.
- **Tally text helpers**: delete `competitionTallyAttentionText` (:987-1012), `competitionTallyDeadlineText` (:1056-1076, including PR 1's `now:` change) and `tallyStatusSymbol` (:1155-1161). Add:
  ```swift
  struct CompetitionTallyCopy: Equatable { let headline: String; let body: String }
  func competitionTallyCopy(_ tally: LocalCompetitionTallyPresentation, opponentDisplayName: String,
                            now: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> CompetitionTallyCopy
  ```
  It implements the table in Behavior, using `competitionDeadlineText` and `competitionDayListText`.
- **`competitionScorePeriodLabel`** (:1082-1087): `.tallying` → "Day 7".
- **PR 1's `competitionDayAccessibilityLabel`**: the closed-day nil opponent reads "\(opponentName), not synced", or "\(opponentName), no data" when `day.opponentReportedNoData`.

**D. LocalCompetitionClient.swift**
- `LocalCompetitionDayPresentation` (:93-125): add `let opponentReportedNoData: Bool` with the doc comment "The other person sent this day with no score (for example tracking paused). Remote only." Add `opponentReportedNoData: Bool = false` to the init after `opponentRevealedPoints`, so the fixture and every existing call site (including those spelled `CompetitionDayPresentation(`) compile unchanged.
- `LocalCompetitionTallyAttention` (:134-143): no new case.
- Update the doc comment on `.opponentPlanUnavailable`: "The other person's final days are not in yet: a non-final simulated plan in the fixture, missing ledger rows in remote."
- `tallyPresentation` (:1536-1580) is unchanged.

**E. RemoteCompetitionClient.swift**
- **:1828-1832**: pass `opponentID: opponentID` into `tallyPresentation`.
- **Day presentation (:1878-1890)**: add `opponentReportedNoData: !(future && terminal == nil) && remote != nil && remote?.acceptedCentiPoints == nil`. This is the one line in PR 2's area.
- **:1963-1999**: the new signature is `tallyPresentation(competition:projection:ownerID:opponentID: UUID?)`, with:
  ```swift
  func missingDays(_ id: UUID?) -> Set<Int> {
      let ledger = id.flatMap { projection.remoteScoreLedgers[$0] }
      return Set((1...7).filter { day in ledger.flatMap { try? $0.visibleEntry(forActiveDayOrdinal: day) } == nil })
  }
  attention = remoteTallyAttention(ownerMissing: missingDays(ownerID), opponentMissing: missingDays(opponentID))

  static func remoteTallyAttention(ownerMissing: Set<Int>, opponentMissing: Set<Int>) -> CompetitionTallyAttention {
      if !ownerMissing.isEmpty { return .incomplete(missingOrdinals: ownerMissing, unavailableOrdinals: []) }
      if !opponentMissing.isEmpty { return .opponentPlanUnavailable }
      return .awaitingStability
  }
  ```
  `remoteTallyAttention` is internal (not private) on `RemoteCompetitionProjector`, for tests. The `unavailable` set computation is deleted.

**F. CompetitionSharingView.swift, PR 1's status formatter (replacing :1046-1065)**
- **Lifecycle overload**:
  - `.tallying` title becomes "Final score pending" for every style; timing nil.
  - The `.completed` / `.archived` `.notification` title becomes `competitionResultTitle(outcome:opponentDisplayName:)`.
- **Presentation overload**: after forwarding, if the lifecycle is `.tallying`, `style != .notification`, `let deadline = competition.tally?.bestAvailableDeadline` and `competition.evaluatedAt < deadline`, return `CompetitionStatusText(title: base.title, timing: "By \(competitionDeadlineText(deadline, now: competition.evaluatedAt, locale: locale, timeZone: timeZone))")`.

**G. CompetitionResultView.swift**
- **Hero** (:126-145):
  - Add `@Environment`-free `var isMuted: Bool { muteButton?.isMuted == true }`. The kicker (PR 1's) appends "Muted" when `isMuted`.
  - The title gets `.foregroundStyle(titleColor)` (win `Theme.you`, loss `Theme.ink`, tie `Theme.secondary`), `.lineLimit(2)` and `.minimumScaleFactor(0.5)`. `headlineSize` (:18) becomes 52.
  - The `resultSubtitle` Text (:138-141) is replaced by `if let d = competitionFixtureDisclosure(source:opponentDisplayName:) { Text(d) … }`.
- **Body** (:29-67): `muteButton?.failureNote` becomes the first child of the VStack. Delete it at :66.
- **`marginChips`** (:203-227), `chipBackground` (:229-236) and `daysWonText` (:244-253) are replaced by `summaryLine` (Behavior), built from:
  ```swift
  func competitionMarginText(userPoints: Double, opponentPoints: Double, fractionDigits: Int, locale: Locale = .current) -> String?
      // m = competitionDisplayedMargin(...fractionDigits:); m == 0 → nil; "Won by "/"Lost by " + competitionPointsAccessibilityText(abs(m), fractionDigits:, locale:)
  func competitionDaysSummaryText(_ days: [LocalCompetitionDayPresentation]) -> String?
      // counts competitionDayOutcome(day, currentDayOrdinal: nil) ∈ {won, lost, tied}
  ```
  Both are globals at the end of the file. `marginText` (:238-242) is deleted. The line passes PR 1's `digits`.
- **`weekCardAccessibilityLabel`** (:287-290): `["The week", competitionDaysSummaryText(competition.days)].compactMap { $0 }.joined(separator: ". ")`.
- **`weekDrawer`** (:300-302): always `CompetitionRingLegend(days: competition.days, opponentName: …)`.
- **`ringTotals`** (:319-323): the third title is "ROLL" when any day's accepted snapshot is `.rollHours`.
- **`competitionResultTitle`** (:637-646): "You beat \(n)" / "\(n) won" / "All square with \(n)".
- **Deleted**: `competitionResultSubtitle` (:648-663) and `resultSubtitle` (:605-611).

**H. CompetitionFeature.swift**
- **State** (:35-37, :55-57, :71-75): replace `notificationPreferenceSaveFailed: Bool` with `mutePreferencesLoadFailed: Bool = false` and `muteSaveFailures: [String: Bool] = [:]`. The value is the `isMuted` that failed to save.
- **`.task`** (:140-162): capture `let loadFailed = state.mutePreferencesLoadFailed`, and send `.mutePreferencesLoaded(loaded)` when `loaded != currentMutedIdentities || loadFailed`.
- **Cases**:
  - `.mutePreferencesLoaded(nil)` (:381-384) → `mutePreferencesLoadFailed = true`.
  - A non-nil set → set the identities and `mutePreferencesLoadFailed = false`.
  - `.muteTapped` (:404) → `state.muteSaveFailures[identity] = nil`.
  - `.muteFinished(…, succeeded: false)` (:435) → `state.muteSaveFailures[identity] = isMuted`.
- **No new actions.**

**I. MainTabView.swift:256-265**
`failure: store.competition.muteSaveFailures[identity].map { $0 ? .mute : .unmute } ?? (store.competition.mutePreferencesLoadFailed ? .load : nil)`.

**J. CompetitionInviteView.swift**
- `CompetitionRulesCard` (:274-302) becomes `struct CompetitionRulesCard: View { let source: CompetitionPublicationSource; var opponentName: String? = nil; var weekText: String? = nil }` with the four rows from Behavior. The trophy row uses `.symbol("trophy")`.
- Call site :16 → `CompetitionRulesCard(source: source, opponentName: competition.opponentDisplayName)`.
- CreateCompetitionView.swift:27 is unchanged.

**K. ClaimCompetitionView.swift**
- Delete `privacyCard` (:82-100). :28-30 becomes `CompetitionRulesCard(source: .remoteParticipants).frame(maxWidth: 440)`.
- The card grows to 4 rows. Wrap the sheet's VStack (:12-38) in `ScrollView { … }.scrollBounceBehavior(.basedOnSize)` so AX5 does not clip. Its `Spacer(minLength:)`s keep their minimums.

**L. ActivityRingsView.swift**: no change. The Ring panel polish row is PR 2's.

**No new Swift files, so no project.pbxproj change.**

#### Server changes
None.
- The remote tally change is client-side projection only. It reads ledger rows the app already downloads.
- Installed older versions keep their current tally copy.
- No RPC, migration or Edge Function changes, and nothing to promote to Staging.

#### Tests

**scripts/tests/competition-local-date-formatting.swift** (PR 1's rewritten script):
- `competitionDeadlineText(2026-11-05T08:00Z, now: 2026-11-04T05:00Z, en_US, America/Los_Angeles)` == "Wed night".
- `competitionDeadlineText(2026-11-05T05:00Z, same now, en_US, LA)`, normalized, == "Wed 9:00 PM".
- The 08:00Z deadline with `Asia/Tokyo` is not midnight there, so it uses the moment style: contains "5:00 PM".

**HealthCompTests/CompetitionPresentationTests.swift**
- **New `testTallyCopyNamesWhoItWaitsOnAndWhetherToAct`.** Deadline 2026-11-05T08:00Z, now 2026-11-04T05:00Z, en_US, LA, name "Hermes". Assert every row of the Behavior table exactly:
  - `.opponentPlanUnavailable`
  - `.incomplete([7], [])`
  - `.incomplete([5], [7])` (headline "Waiting for your Days 5 and 7"; body "HealthComp couldn’t read Days 5 and 7 on this iPhone. …")
  - `.incomplete(1...7, [])` → "Waiting for your Activity" / "7 days haven’t synced from this iPhone. …"
  - `.unacceptedScores([3, 4])` → "Scoring your Days 3 and 4"
  - `.noRead`
  - `.awaitingStability`
  - nil
  - now == deadline → "Finishing the result"
  - A 05:00Z deadline puts "Wed 9:00 PM" in the opponent body.
  - No headline or body contains "days 7", "Missing days", "best available" or "stable read".
- **New `testDayListTextIsSingularPluralAndCapped`**:
  - [7] → "Day 7"
  - [7, 5] → "Days 5 and 7"
  - [3, 5, 7] → "Days 3, 5, and 7"
  - [1, 2, 3, 4] → nil
  - [] → nil
- **New `testTallyingStatusShowsFinalScorePendingAndDeadline`.**
  - The presentation overload, `.tallying` with a tally (deadline above) and `evaluatedAt` = now:
    - `.card` → title "Final score pending", timing "By Wed night"
    - `.row` line → "Final score pending · By Wed night"
    - `.notification` timing → nil
  - With `evaluatedAt` = deadline, the timing is nil.
- **Update PR 1's `testStatusTextNamesEveryLifecycleInEveryStyle`**:
  - tallying → ("Final score pending", nil)
  - completed tie `.notification` → "All square with Hermes"
- **New `testDayOutcomeSeparatesWonLostTiedNoDataUpcomingToday`**:
  - 320/300 → won; 300/320 → lost; 300.4/300.2 → tied (displayed 300 = 300)
  - 0/0 → noData; 320/nil → noData; nil/300 (`.missing`) → noData
  - `.notYetOccurred` → upcoming
  - ordinal == currentDayOrdinal → today
- **New `testResultTitlesNameTheOtherPerson`**: `.win` → "You beat Hermes", `.loss` → "Hermes won", `.tie` → "All square with Hermes".
- **New `testMarginTextIsLabelledAndHiddenAtZero`**:
  - (3410.2, 3180, 0) → "Won by 230 points"
  - (3180, 3410.2, 0) → "Lost by 230 points"
  - (413, 412, 0) → "Won by 1 point"
  - (412.3, 412.0, 2) → "Won by 0.30 points"
  - (412, 412, 0) → nil
  - (0.4, 0, 0) → nil
- **New `testDaysSummarySplitsWonLostTiedAndSkipsMissingDays`**:
  - 2 won, 4 lost, 1 tied → "won 2 days, lost 4, tied 1"
  - 5 won, 1 opponent-nil, 1 at 0–0 → "won 5 days"
  - 1 lost, the rest nil → "lost 1 day"
  - 7 tied → "tied 7 days"
  - no scored days → nil
- **New `testMuteFailureTextNamesThePersonAndAction`**: the three strings from Behavior, with "Hermes".
- **`testRemoteParticipantCopyUsesRealIdentityWithoutFixtureLanguage` (:106)**:
  - result title → "Priya won"
  - delete the subtitle and `competitionTallyAttentionText` parts
  - add `competitionTallyCopy(.opponentPlanUnavailable…, "Priya")`, whose body contains "Priya" and not "simulat"
- **`testFixtureParticipantCopyRetainsExplicitSimulationDisclosure` (:170)**: delete the `competitionResultSubtitle` assertion and keep the disclosure assertion.
- **Delete, now covered above**: `testTallyUsesProvisionalTotalsAndHonestDeadlineCopy` (:553; move its `competitionScoreTotalLabel` assertion into the new tally test), `testOpponentPlanAttentionUsesUserFacingSimulatedScoreCopy` (:598), `testEveryTallyAttentionHasUserFacingCopy` (:605), `testMixedIncompleteTallyCopyNeverDropsAReason` (:634; the [5],[7] case keeps both days) and `testOpponentPlanDeadlineDoesNotBlameAcceptedOwnerScores` (:654; assert the opponent body does not contain "your").
- **`testTallyScoreHeaderUsesFinalDayInsteadOfToday` (:717)** is renamed `testTallyCallsTheLastDayDay7`: `.tallying` → "Day 7"; `.active` and `.endsToday` → "Today".
- **PR 1's `testClosedDayWithoutOpponentScoreIsUnavailableRatherThanFuture` (:704)**: expect "Opponent, not synced." Add a second day with `opponentReportedNoData: true` and expect "Opponent, no data."
- Ring panel tests are PR 2's (`testRingPanelOmitsPointsForAPausedReading`, `testUnknownStandModeReadsStandOrRoll`).

**HealthCompTests/CompetitionFeatureTests.swift**
- **`testMuteOptimisticallyUpdatesAndGuardsStableOpponentIdentity` (:369)**: remove the `notificationPreferenceSaveFailed = false` line.
- **`testMutePersistenceFailureRollsBackOptimisticState` (:404)**: expect `$0.muteSaveFailures[identity] = true` instead of the Bool.
- **New `testMuteLoadFailureIsSeparateAndClearsOnNextEqualLoad`**:
  - `loadMutedOpponentIdentities` throws → receive `.mutePreferencesLoaded(nil)` with `mutePreferencesLoadFailed = true`
  - swap the client to return `[]`, send `.task` again → receive `.mutePreferencesLoaded([])` with `mutePreferencesLoadFailed = false`
- **New `testRetappingClearsOnlyThatPersonsSaveFailure`**:
  - Initial `muteSaveFailures = ["a": true, "b": false]`.
  - `.muteTapped("a")` → `["b": false]`, plus the optimistic changes.

**HealthCompTests/RemoteCompetitionClientTests.swift**
- **New `testRemoteTallyWaitsOnWhoeverHasMissingDays`**:
  - `RemoteCompetitionProjector.remoteTallyAttention(ownerMissing: [7], opponentMissing: [6, 7])` == `.incomplete(missingOrdinals: [7], unavailableOrdinals: [])`
  - `([], [7])` == `.opponentPlanUnavailable`
  - `([], [])` == `.awaitingStability`
- **`testAnonymizedOpponentIdentityRemainsVisibleInRemoteHistory` (:764, assertion :826)**: "Former competitor won".

**UI tests.** These edits apply on top of PR 1's. Line numbers are current.

LocalCompetitionLifecycleUITests.swift
- **:50-52**: keep the `competition.schedule.dates` existence check (PR 1's no-":" check). Add `label.hasPrefix("Day 1 is ")` and `label.hasSuffix("Points start counting at midnight.")`.
- **:55 and :238** ("Scores begin Day 1"):
  - Replace with `XCTAssertTrue(app.staticTexts["You versus Alex"].exists)`.
  - Add `XCTAssertFalse(app.buttons["Week"].exists)` (no rows or picker while scheduled).
- **:85, :404 and :497** (PR 1's `waitForStatus("Tallying")`) → `waitForStatus("Final score pending")`.
- **:87**: replace with `let tally = app.descendants(matching: .any)["competition.tally"]`, then:
  - `XCTAssertTrue(tally.label.contains("Waiting for your Day 7"))`
  - `XCTAssertFalse(tally.label.contains("days 7"))`
  - `XCTAssertTrue(app.buttons["Day 7"].exists)`
  - `XCTAssertFalse(app.buttons["Today"].exists)`
- **:88**: `tapMoreMenuItem("Sync status")`.
- **:100-102**: add `.contains("Day 7")` alongside "provisional total".
- **:106** → `tally.label.contains("Checking the last scores")`, with a wait.
- **:111** → `staticTexts["You beat Alex"]`. Add `app.staticTexts["competition.result.summary"].label.hasPrefix("Won by ")`.
- **:323 / :328** → "Alex won" / "All square with Alex".

MultiUserCompetitionUITests.swift
- **:150-152**: PR 1's assertions still hold, because the identifier now sits on the Day 1 line. Add `hasPrefix("Day 1 is ")`.
- **:184** → `staticTexts["You beat Former competitor"]`.
- **:247** (claim) → `staticTexts["The other person sees your daily points and rounded ring percentages"].exists` and `staticTexts["Most points after 7 days wins"].exists`.
- **:324-327** (invite):
  - `disclosure = staticTexts["Sam sees your daily points and rounded ring percentages"]`
  - a predicate `label CONTAINS "Your Health data stays on your iPhone"` exists
  - `staticTexts["Day 1 is the day after the challenge is accepted."].exists`
  - This replaces PR 1's "Derived match data is shared" edit at :324. PR 1's :338 onboarding edit is unaffected.
- **:697** → "You beat Former competitor. Final score. You 3,520 points. Former competitor 3,410 points."

**Accessibility identifiers**
- Added:
  - `competition.tally`, the tally card
  - `competition.result.summary`, the margin and days line
- Renamed: none.
- Removed: none.
- Moved:
  - `competition.schedule.dates`, from the deleted range card to the "Day 1 is …" line
  - `competition.notifications.preference-error`, from the scroll bottom to the scroll top
- Unchanged: `competition.notifications.mute`, `competition.more`, `competition.result`, `competition.result.week`, `competition.day.<n>`, `competition.scoreHeader.naren/.alex`, `competition.status` (PR 1), `competition.lastSync*`, `competition.ownerRings`.

**Verify on the Mac mini.** Run:
- HealthCompTests, the standalone script and both UI suites, including the `.textClipped`, `.hitRegion` and `.dynamicType` audits
- light and dark captures at XS and AX5 of:
  - scheduled, Day 3 Week tab (with a no-data day and a "Not synced" day), tallying, win, loss and tie results
  - the ••• menu, showing the mute subtitle

#### Risks and sequencing
- **Lands after PR 1 and calls its API**: `competitionStatusText`, `competitionLeadText`, `competitionPointsText` / `…AccessibilityText`, `competitionDisplayedMargin`, `competitionFinalFractionDigits` (via `digits`), `competitionMomentText`, `competitionScheduleDateRangeText`, `weekdayText`, `competitionDayText`, and `CompetitionWeekChart(now:)`.
  - PR 1 lacks two helpers, added here: `competitionDeadlineText`, in PR 1's Foundation-only file because it needs PR 1's private formatter helper, and `weekdayName`.
  - PR 3 edits three things in PR 1's formatter: the tallying title, the tally timing, and the tie notification title. Two PR 1 tests change with it.
- **PR 2 (remote parity)**:
  - It touches `RemoteCompetitionClient.swift` day presentations near :1868-1916. This PR edits :1828-1832, :1963-1999 and adds one argument to the day presentation at :1878-1890 (`opponentReportedNoData`). Whichever lands second keeps that argument.
  - It owns ActivityRingsView. This PR doesn't touch it.
  - If PR 2 adds remote ring splits, the legend switches to ring swatches automatically (`showsRings`).
  - Land in either order and rebase.
- **PR 4 (Home)**:
  - The strip changes show on the Home card.
  - Home's scheduled card should reuse `CompetitionScheduledSummary`.
  - The Home card can show "· MUTED" and PROVISIONAL with the same pieces. This PR does not touch CompetitionSharingView beyond PR 1's formatter.
- **PR 5 (notifications)**: two notification titles change through the shared formatter, competitionEnded → "Final score pending" and tie result → "All square with {Name}". PR 5's planner tests must expect them.
- **PR 6 (challenges)**: it rewrites the Create, Claim and Invite screens. It must keep `CompetitionRulesCard(source:opponentName:weekText:)` as the single rules and consent card, and should pass the chosen recipient's name on Create.
- **CompetitionFeature state rename** (`notificationPreferenceSaveFailed` → two fields): any later PR touching mute must use the new fields. Only MainTabView and CompetitionFeatureTests reference the old field today.
- **The Menu subtitle needs an on-device check** (Design C fallback).
- **No migrations.**

#### Open questions
Moved to §10: Q2 (how much the rules card's lock row discloses; owner, privacy consent) and Q11 (is a closed 0–0 day no data or tied). Both defaults are built above.

### PR 4 — Home and History

#### Scope
- **f-hero**: the UUID-order hero is gone. Home uses layout A (Claude's call): one live match gets the big scoreboard; two or more get equal cards ordered by end time.
- **f-pile**: Home has four groups (Needs you, Live, Up next, Recent results). Empty groups don't render. Results leave Home 3 days after the week ends (Claude's call), and a swipe archives them sooner. The Home History button summarizes the record per person.
- **f-vanish**: an outgoing challenge that expires or is declined stays on Home for 24 hours as a dismissible row with "Challenge {Name} Again". A challenge screen that is open when the challenge closes changes in place to a closed state.
- **f-errors**: a problem with one match shows on that match's Home row/card and on its match and result screens, with Retry. The top banner is kept for problems that affect everything.
- **f-rivalry**: History shows a record per person (keyed on `opponentIdentity`) and every week newest first, each opening its result. The completion award is dropped. Awards are sorted by date, and the local award fold stops hard-coding the name.
- Polish **Home empty state**: when History has anything, Home says "Nothing live right now" and shows a Challenge button.
- Polish **Avatar**: the initial comes from the profile's display name, read from `competition.ownProfile` (the field PR 6 also uses).
- Polish **Deep links**: a route closes History and the Account sheet before it navigates. A route to a match that isn't loaded yet waits for it to appear and leaves the current screens in place.

#### Behavior

##### Home layout (f-hero, f-pile)
Top to bottom: the global banner (only if any), Needs you, the hero card or Live, Up next, Recent results, then the History button. Each group renders only when it has rows. The rules below are computed at `publication.evaluatedAt` ("now"), so they agree with the rest of the screen.

**Which group each match is in**

| Lifecycle | Group |
|---|---|
| `.pending(.incoming, …)` | Needs you |
| `.active`, `.endsToday`, `.tallying` | Live |
| `.scheduled` | Up next (or the hero, see below) |
| `.pending(.outgoing, …)` | Up next |
| `.expired`/`.declined`, outgoing, not dismissed (the dashboard only keeps them for 24 h) | Up next |
| `.expired`/`.declined`, incoming | not on Home (it stays reachable from an open screen) |
| `.completed` while now < its leave time | Recent results |
| `.completed` after its leave time, and `.archived` | History only |

**Order inside each group** (every sort ends on `id.rawValue.uuidString` so it is stable):
- Needs you: `expiresAt` ascending (nil last), then `createdAt` ascending.
- Live: week end ascending (the exclusive end from `competitionScheduleBoundaries`), then week start, then `opponentDisplayName` by `localizedStandardCompare`. A tallying match has already ended, so it sorts first. A match with no schedule sorts last.
- Up next: scheduled matches by start ascending (then name), then outgoing challenges by `expiresAt` ascending (nil last, then `createdAt`), then closed challenges by closed time, newest first.
- Recent results: `terminalResult.completedAt` descending.

**Hero (Claude's call A).**
- Exactly one live match: it is the hero. This is today's big card (`CompetitionHeroCard`, 64pt scores, week strip, "MATCH DETAILS →"), with no group label above it.
- No live match but at least one scheduled: the soonest scheduled match is the hero, using today's scheduled headline. It is removed from Up next. This keeps today's one-match behavior from acceptance through Day 1 (§10 Q13).
  - Claude's call: PR 4 does not wait for PR 3. If PR 3's `CompetitionScheduledSummary` is already on main when PR 4 is built, the scheduled hero's body uses it; otherwise PR 3 makes that one swap when it rebases. Home cards and rows get no "· MUTED" or PROVISIONAL tag: the audit puts the mute state on the match screen and in Account, and a tallying card already says it isn't final through its status.
- Two or more live matches: there is no hero. The label reads "LIVE · 2" (the count), and each match gets an equal compact card in its own panel. A compact card has the status row, a 40pt scoreboard ("YOU" and the name, from PR 1), the lead line (`competitionLeadText`), the week strip and the fixture disclosure. It has no "MATCH DETAILS →" footer and no LIVE dot, because the group label already says it. A tallying card shows the tallying status from the shared formatter (PR 1's "TALLYING"; PR 3 renames it there, and Home picks that up with no change).

**Rows** keep the current `CompetitionSharingRow` shape: badge, name as the headline, one status line, trailing score or chevron. The status line is `competitionHomeStatusLine` (Design), which is PR 1's `.row` line plus an expiry for pending challenges:

| Row | Status line (en_US, phone in the match zone) | Trailing |
|---|---|---|
| Incoming challenge (Needs you) | "Challenge received · Expires Sun 2:14 PM" | a "Review" capsule (ink fill, onInk text) in place of the chevron |
| Outgoing challenge (Up next) | "Challenge sent · Expires Sun 2:14 PM" | chevron |
| Scheduled (Up next) | "Starts Wed, Oct 28" | chevron |
| Result (Recent results) | "You won · Oct 24 – 30", "Hermes won · …", "Tied · …" + a second line "Moves to History Tue" (caption, secondary) | score "3,410 / 3,180" + chevron |

- The expiry uses `competitionMomentText`: "Sun 2:14 PM" when it is within 6 days, otherwise "Oct 21, 9:41 PM". It is left out when `expiresAt` is nil or already past.
- **Deviation from the f-pile mockup**: the mockup's Needs you row reads "Maya challenged you". The row here reads "Maya" / "Challenge received · Expires …", because PR 1 already gives this state one row wording on every surface, and a second wording would split it.
- "Moves to History {weekday}" uses the weekday of the day the result leaves (see the rule below). It can't be ambiguous, because that day is at most 4 days away.
- **Unseen results are not treated as Needs you (decided).** Telling them apart needs a per-device "seen" record. The result notification and the top position in Recent results already cover it.

**When a result leaves Home.** It leaves at the start of the 4th calendar day after its last day, in the match calendar. Example: a week of Sat Oct 24 – Fri Oct 30 leaves at 00:00 on Tue Nov 3, so the row reads "Moves to History Tue". A tally that finishes late still gets at least one full day on Home: the leave day is the later of (last day + 4) and (the day `completedAt` falls on + 2). Without a schedule (not expected for finished weeks), the row stays until it is archived and has no caption. Leaving Home only hides the row on the phone. Nothing is archived on the server, the result stays in History, and its ••• menu still offers Archive.

**Swipe to archive.** On a Recent results row only, swiping left reveals an "Archive" action: ink fill, onInk text, 96pt (scaled). Tapping it sends `archiveTapped(id)`, and the next publication moves the row to History. While the command is in flight the action shows a spinner and is disabled. If archiving fails, the row stays and shows "Couldn't finish that. Try again." (f-errors). The action stays in the accessibility tree as a real button, so VoiceOver, Switch Control and Voice Control can reach it. Its label is "Archive. {Name}. {status line}" and its hint is "Moves this result to History".

**Group labels** are `SectionLabel` (header trait): "NEEDS YOU", "LIVE · 2" (only with 2+), "UP NEXT", "RECENT RESULTS".

**History button** (`competition.history.open`), shown when any finished week exists (completed or archived, on Home or not):
- Title "History". Subtitle: the records of the two people with the most recent weeks, joined with " · ": "Hermes 2–1 · Andy 1–0". With more people it adds " · 2 more". With one person: "Alex 3–1".
- The record text is "W–L", or "W–L–T" when ties > 0 ("1–0–1"), using an en dash. Wins are drawn in `Theme.you` bold, losses in ink and ties in secondary.
- VoiceOver: label "History", value "Hermes, 2 wins, 1 loss. Andy, 1 win, 0 losses. 2 more people" (with ", 1 tie" or ", 2 ties" when there are ties), hint "Opens finished matches".

**Empty states.** "Empty" means no banner rows and no hero, Needs you, Live, Up next or Recent results.
- No finished weeks at all: today's panel with PR 1's copy ("No matches yet" / "Challenge someone to start a match." + "Challenge Someone", `competition.create.empty`).
- Some finished week exists (polish row): the same panel with the title "Nothing live right now", no description (remote), and the same "Challenge Someone" button (`competition.create.empty`). The History button sits below it.
- Local fixture: the reinvite button ("Challenge Alex Again", PR 1 copy) and PR 1's "The last challenge closed. You can challenge Alex again." description show when `hiddenTerminalCompetitionCount > 0` **or** the dashboard holds any `.declined`/`.expired` presentation. The second condition is new: closed challenges now stay in the dashboard for a day, so the hidden count alone would drop the button right after a decline.

**Edge cases.**
- 0–0, ties, Day 1, Day 7 and tallying use PR 1's status and lead strings unchanged; Home only decides placement and order.
- Two live matches against the same person (possible today, f-rematch) are told apart by their end ("ENDS TUE NIGHT" / "ENDS WED NIGHT"), both on screen and in VoiceOver.
- Long names wrap in every row, card and closed-row headline (no `lineLimit`).
- At accessibility sizes, rows switch to their stacked `ViewThatFits` branch, scoreboards stack (existing `AnyLayout`), and the closed row's ✕ stays top trailing.

##### Closed challenges (f-vanish)
**The rule.** A closed challenge (`.expired(at:direction:)` / `.declined(at:direction:)`) stays in the dashboard while `now < at + 24 h`. Both projectors apply this rule, so routes and the path keep it too. Home shows it only when it is outgoing and the person hasn't dismissed it. The row sits in Up next, in the slot where "Challenge sent" was.

**Real matches.** The server only flips a lapsed challenge to `expired` when the sender creates another challenge or an operator runs `cleanup_expired_competition_invites` (there is no cron). The remote dashboard therefore treats a `pending` challenge whose `expiresAt <= now` as `.expired(at: expiresAt, direction:)`. This applies only to the dashboard presentation. The notification snapshot keeps `pending`, so PR 5 keeps control of expiry notifications.

**The Home row.** It is not a navigation button.

| | Expired (outgoing) | Declined (outgoing) |
|---|---|---|
| Headline | "Sam didn't accept" | "Sam declined" |
| Line | "Your challenge expired Sun 2:00 PM" | "Declined Sun 2:00 PM" |
| Button | "Challenge Sam Again" (`SecondaryButtonStyle`, full width) | same |
| Top trailing | ✕, 44×44, VoiceOver "Dismiss", hint "Removes this from Home" | same |

- Times use `competitionMomentText(at, now: evaluatedAt)`.
- **Dismiss** hides the row in memory for the rest of the session (Claude's call; §10 Q19).
- **"Challenge Sam Again", real matches:** prefills the Challenge sheet with Sam's account (the same binding as a rematch, with no rematch parent) and opens it. The person still taps Create. The button is hidden when the identity has no profile ID (`remote-profile:v1:pending`).
- **"Challenge Alex Again", local fixture:** sends the existing `reinviteTapped`. It shows a spinner and is disabled while `isReinviteInFlight`.
- **VoiceOver:** the row is a container. Its text reads "Sam didn't accept. Your challenge expired Sun 2:00 PM.", followed by the two buttons.

**On the challenge screen.** When the challenge closes while its screen is open, the next publication keeps the route, because the match is still in the dashboard, and the destination draws the closed view in place (MainTabView). The view is `ContentUnavailableView` with the person's name as the inline navigation title:

| | Title | Description | Action |
|---|---|---|---|
| Outgoing, expired | "Sam didn't accept" | "Your challenge expired Sun 2:00 PM." | "Challenge Sam Again" (`PrimaryButtonStyle`): pops to Home, then behaves like the row button |
| Outgoing, declined | "Sam declined" | "Declined Sun 2:00 PM." | same |
| Incoming, declined (local decline) | "Challenge declined" | "You declined Alex's challenge." | none |
| Incoming, expired | "Challenge expired" | "Alex's challenge expired Sun 2:00 PM." | none |

- PR 1's "Challenge Closed" / "Go back to Home…" view (MainTabView.swift:228-234) is replaced.
- After 24 h the match leaves the dashboard. An open screen then pops, as any pruned route does today.
- **Known gap:** when the sender creates any new challenge, the server flips all of their lapsed challenges to `expired`, and the runtime skips those descriptors (RemoteCompetitionRuntime.swift:634-642). A closed row for Sam therefore disappears as soon as the sender challenges Maya. This is accepted: the sender is already starting the next step.

##### Problems on the affected match (f-errors)
**Which problems are tied to a match.** `competitionFailures`, `activityFailures` and `commandRejected` carry IDs. When more than one applies to a match, the strongest wins: command, then refresh, then activity.

| Issue | Line | Action |
|---|---|---|
| `commandRejected(id)` | "Couldn't finish that. Try again." | none: the original control (swipe, •••, Rematch) is right there |
| `competitionFailures` contains id | "Couldn't update scores" | "Retry" |
| `activityFailures` contains id | "Couldn't read your Activity" | "Retry" |

- **Deviation from the mockup**: it says "Couldn't update Andy's score". A failed sync can leave both sides stale, so the line says "scores".
- **Where the line shows:** directly under the affected Home row or card (inside its panel, outside the row's button), and at the top of the match screen and the result screen. History rows don't show it.
- **The line itself:** `exclamationmark.triangle.fill` + text in ink (no new color), with Retry trailing. Retry has a 44pt minimum and the label "Retry", and runs `pullToRefresh` and awaits it. While it runs, Retry shows a spinner and is disabled. The line disappears when a publication no longer carries the issue.
- **Archive failure on a result** now reads "Couldn't finish that. Try again." on the result screen, where today the button just re-enables.
- **The top banner** shows only for problems that affect everything, or for a match ID that isn't in the dashboard. `remoteUnavailable` now reads **"Offline. Scores update when you reconnect."** (mockup copy). The other banner strings are PR 1's. A local reinvite failure is `commandRejected(bootstrapID)`, whose ID isn't in the dashboard, so it still falls to "The last match action could not be completed."

##### History (f-rivalry)
The screen is titled "History" (inline). It replaces the summary tiles and the Matches/Awards picker with two sections, following the proposed mockup:

1. **RECORD.** The label row is `SectionLabel("RECORD")` with "4 WEEKS" trailing ("1 WEEK" when there is one), in the theme label style, secondary. The container has `competition.rivalry`. Below it is one row per person, in a panel, ordered by their latest week (newest first).
   - Each row has the initial badge, the name (headline), the latest week's PR 1 row line ("You won · Oct 24 – 30") and the trailing record "2–1".
   - Records are grouped by `opponentIdentity`, so two friends named Sam are two rows. The name shown comes from the newest week, so a rename or "Former competitor" shows the current name.
   - The rows are not tappable and have no chevron. **This deviates from the mockup's chevrons**, because there is no per-person page and the weeks below already open each result (§10 Q18).
   - VoiceOver reads one element: "Hermes. 2 wins, 1 loss. Latest: You won · Oct 24 – 30."
2. **WEEKS.** Every finished week (completed and archived), newest first: week end descending, then `completedAt` descending.
   - Each row is today's `CompetitionSharingRow` (W/L/T chip, name, "You won · Oct 24 – 30", score) inside the existing `NavigationLink(value: .competition(id))`.
   - It keeps its `competition.sharing.completed|archived.<uuid>` identifier and the PR 1 VoiceOver label.
   - The label is "WEEKS". The mockup's "· NEWEST FIRST" is dropped as redundant next to the dates.

**Awards.**
- The completion award is dropped everywhere (History and the result screen).
- The Awards page goes away: a win's W chip is its award, as in the mockup.
- The victory award stays on the result screen. Its "N wins against {Name}" count uses `opponentIdentity`.
- `dashboard.awards` is sorted by `awardedAt` descending, then `id`.

**Empty History.** It is reachable only by a route, because the button hides when there is nothing. It shows "Finished matches appear here." in secondary.

##### Avatar (polish)
- The avatar shows the first character of `competition.ownProfile?.displayName`, uppercased, in `Theme.you`. It updates after a rename, because AppFeature writes the new profile into that field.
- Claude's call: PR 4 owns this polish row. PR 4 adds `CompetitionFeature.State.ownProfile` exactly as PR 6 specifies it (PR 6 Design B), so there is one profile copy and no name parameter threaded through AppRootView and AuthenticatedRootView. PR 6 then finds the field in place and only adds its own readers (`senderName`, the own-code check).
- With no profile it shows the existing `person.fill`.
- The VoiceOver label "Account" and the identifier `app.account` are unchanged.

##### Deep links and notification taps (polish)
- **A route to a loaded match:**
  - closes History, closes the Account sheet, and sets the path to `[id]`, all in one reducer step;
  - Back then goes to Home;
  - this includes closed challenges within their 24 h, which open the closed view.
- **A route to a match that isn't loaded yet** (for example a notification about a match the phone hasn't synced):
  - The current screens are left exactly as they are, the route is held, and one refresh starts.
  - If the match appears in any publication within 15 s, it opens as above.
  - If it doesn't, the route is dropped (consumed) and nothing moves.
  - A newer route replaces a held one.
- **Left alone:** the Challenge sheet and the claim sheet. Closing the Challenge sheet can lose an unshared link, and PR 6 owns that sheet.
- **Ownership:** PR 4 owns `resolve(_:state:)`, `visibleCompetitionIDs` and their MainTabFeatureTests. PR 5 adds no routing code and relies on the hold above for its expiry taps.

#### Design


##### 1. Presentation model: LocalCompetitionClient.swift
- **:61-83 `LocalCompetitionLifecyclePresentation`:** change to `case declined(at: Date, direction: InvitationDirection)` and `case expired(at: Date, direction: InvitationDirection)`. Patterns with no bindings (`case .declined:`) still compile. Update the two constructors (below and Remote :1904-1905).
- **:218-262 `LocalCompetitionAward`:**
  - Delete `enum Kind` and `let kind`; every award is now a victory.
  - Add `let opponentIdentity: String`.
  - `fold(completed:)`: only `terminal.outcome == .win` produces an award. It keeps `id "\(prefix):victory"`, sets `friendDisplayName: presentation.opponentDisplayName` (no more `LocalCompetitionIdentity.opponentDisplayName`) and `opponentIdentity: presentation.opponentIdentity`.
  - Sort with `{ ($0.awardedAt, $1.id) > ($1.awardedAt, $0.id) }`: newest first, ties by `id` ascending.
- **After :282 (next to `LocalCompetitionDashboard`), add:**
```swift
/// Closed challenges stay a day so Home and an open challenge screen can say what happened.
let competitionClosedChallengeRetention: TimeInterval = 24 * 60 * 60

func competitionIsRetainedOnDashboard(
    _ lifecycle: LocalCompetitionLifecyclePresentation, now: Date
) -> Bool {
    switch lifecycle {
    case let .declined(at, _), let .expired(at, _):
        now < at.addingTimeInterval(competitionClosedChallengeRetention)
    default: true
    }
}
```
- **:1176-1183 (`LocalCompetitionProjector.dashboard`):** replace the declined/expired filter with `all.filter { competitionIsRetainedOnDashboard($0.lifecycle, now: context.instant.wallDate) }`. `hiddenTerminalCompetitionCount` keeps `all.count - visible.count`. The UUID sort at :1175 stays; Home and History sort for themselves.
- **:1318 and :1376-1388:** `lifecyclePresentation(_:direction:)` takes `loaded.journal.genesis.direction` and builds `.declined(at: at, direction: direction)` / `.expired(at: at, direction: direction)`.

##### 2. Remote projector: RemoteCompetitionClient.swift
- **:1594-1609 `dashboard`:**
  - Build each presentation with `presentation(from:profile:context:closesLapsedChallenges: true)`.
  - Filter with `competitionIsRetainedOnDashboard(_, now: context.instant.wallDate)`.
  - Keep the hidden-count formula.
- **:1766 `presentation(from:profile:context:)`:**
  - Add `closesLapsedChallenges: Bool = false`.
  - Compute `var lifecycle = lifecyclePresentation(competition.lifecycle, direction: materialization.journal.genesis.direction)`.
  - When the flag is set and `case let .pending(direction, _, expiresAt?) = lifecycle, expiresAt <= context.instant.wallDate`, set `lifecycle = .expired(at: expiresAt, direction: direction)`.
  - `notificationCompetition(from:)` (:1636) keeps the default `false`.
- **:1718 (`notificationCompetition(reloading:)`):** passes `direction: loaded.journal.genesis.direction`; it is only fed to `notificationLifecycle`, which ignores the direction.
- **:1894-1905:** `lifecyclePresentation(_:direction:)` mirrors the local version.
- **:2003-2030 `awards(from:)`:** same changes as the local fold: wins only, `opponentIdentity`, newest first.
- **No runtime change.** RemoteCompetitionRuntime.swift:634-642 still skips server-`expired`/`declined` descriptors (see the known gap).

##### 3. Home helpers: CompetitionSharingView.swift (new globals after :1152)
```swift
struct CompetitionHomeLayout: Equatable {
    let hero: LocalCompetitionPresentation?
    let needsYou: [LocalCompetitionPresentation]
    let live: [LocalCompetitionPresentation]        // empty when the single live match is the hero
    let upNext: [LocalCompetitionPresentation]      // scheduled, outgoing waiting, closed outgoing
    let recentResults: [LocalCompetitionPresentation]
    var isEmpty: Bool { hero == nil && needsYou.isEmpty && live.isEmpty && upNext.isEmpty && recentResults.isEmpty }
}
func competitionHomeLayout(_ dashboard: LocalCompetitionDashboard, now: Date,
                           dismissedChallengeIDs: Set<CompetitionID> = []) -> CompetitionHomeLayout
func competitionIsClosedOutgoing(_ lifecycle: LocalCompetitionLifecyclePresentation) -> Bool

/// The start of the 4th day after the last day, and never before the start of
/// the 2nd day after the week finished, both in the match calendar.
func competitionResultLeavesHome(_ competition: LocalCompetitionPresentation) -> (day: CompetitionDay, at: Date)?

/// PR 1's `.row` line, plus " · Expires {moment}" for a pending challenge whose
/// expiry is still ahead. Rows, the VoiceOver summary and History all use it.
func competitionHomeStatusLine(_ competition: LocalCompetitionPresentation,
                               locale: Locale = .current, timeZone: TimeZone = .current) -> String

struct CompetitionOpponentRecord: Equatable {
    let opponentIdentity: String
    let opponentDisplayName: String               // from the newest week
    let wins: Int, losses: Int, ties: Int
    let latest: LocalCompetitionPresentation
    var text: String                              // "2–1" or "2–1–1"
    var accessibilityText: String                 // "Hermes, 2 wins, 1 loss" (+ ", 1 tie")
}
func competitionHistoryWeeks(_ competitions: [LocalCompetitionPresentation]) -> [LocalCompetitionPresentation]
func competitionOpponentRecords(_ competitions: [LocalCompetitionPresentation]) -> [CompetitionOpponentRecord]
func competitionHistorySummaryText(_ records: [CompetitionOpponentRecord]) -> String  // "Hermes 2–1 · Andy 1–0 · 2 more"

enum CompetitionRowIssue: Equatable, Sendable { case command, refresh, activity }
func competitionRowIssue(_ id: CompetitionID, in issues: [LocalCompetitionClientIssue]) -> CompetitionRowIssue?
```
- **`competitionHomeLayout`** implements the group table and sort orders from Behavior. Week bounds come from `competitionScheduleBoundaries(acceptedConfiguration.schedule)` (CompetitionDetailView.swift:909-924, which PR 1 keeps). It checks a result's leave time with `now < competitionResultLeavesHome(c)?.at ?? .distantFuture`. Hero selection follows the rule in Behavior.
- **`competitionResultLeavesHome`:**
  - `cal = schedule.calendar`, `last = sevenDayWindow(...).last`.
  - `a` = `last` advanced 4 times with `cal.day(after:)`.
  - `b` = `cal.day(containing: completedAt)` advanced twice.
  - Return whichever of `a` and `b` has the later `startOfDay`.
  - Return nil when there is no schedule or no terminal result.
- **`competitionHomeStatusLine`:** returns `competitionStatusText(c, style: .row, locale:, timeZone:).line`, with `" · Expires \(competitionMomentText(expiresAt, now: c.evaluatedAt, locale:, timeZone:))"` appended for `.pending` when `expiresAt > c.evaluatedAt`.
- **`competitionHistoryWeeks`:** keeps `terminalResult != nil`, sorted by week end (`competitionScheduleBoundaries` end, or `completedAt` when there is none) descending, then `completedAt` descending, then id.
- **`competitionOpponentRecords`:** groups `competitionHistoryWeeks` by `opponentIdentity`, preserving first-seen order, which is newest first.
- **`competitionRowIssue`:** a `commandRejected` with this id returns `.command`; else a `competitionFailures` containing it returns `.refresh`; else an `activityFailures` containing it returns `.activity`; else nil.
- **:1126-1152 `competitionIssueSummary`:**
  - New signature: `func competitionIssueSummary(_ issues: [LocalCompetitionClientIssue], attributedIDs: Set<CompetitionID>) -> String?`.
  - First drop the per-ID issues whose IDs are all in `attributedIDs`; return nil if nothing is left.
  - Otherwise use today's precedence with PR 1's strings, except `.remoteUnavailable`, which returns "Offline. Scores update when you reconnect."
- **:1078-1100 delete** `CompetitionRivalrySummary` and `competitionRivalrySummary`. Keep `competitionVictoryCountText` (:1102-1107), which the result screen uses.

##### 4. Home view: CompetitionSharingView.swift
- **:7-22 properties.** Add:
  - `let challengeAgain: (CompetitionID) -> Void`
  - `let archive: (CompetitionID) -> Void`
  - `let commandIDsInFlight: Set<CompetitionID>`
  - `let retry: () async -> Void`
  - `@State private var dismissedChallengeIDs: Set<CompetitionID> = []` with the comment `// ponytail: in-memory, a dismissed row returns after relaunch within its 24 h; persist per profile if that annoys`
- **:80-104** (`homeCompetitions`, `heroCompetition`, `otherCompetitions`, `rivalry`) are replaced by:
  - `layout = competitionHomeLayout(publication.dashboard, now: publication.evaluatedAt, dismissedChallengeIDs: dismissedChallengeIDs)`
  - `records = competitionOpponentRecords(publication.dashboard.competitions)`
- **:26-50 body** becomes:
  - the banner, when `competitionIssueSummary(publication.dashboard.issues, attributedIDs: Set(publication.dashboard.competitions.map(\.id)))` is non-nil
  - `needsYouSection`
  - the hero, if any: `competitionButton(hero) { CompetitionHeroCard(competition: hero, source:, isCompact: false) }` + `issueLine(hero)`
  - `liveSection` when `layout.live.count >= 2`
  - `upNextSection`
  - `recentResultsSection`
  - `emptyState` when `layout.isEmpty`
  - `historyButton` when `!records.isEmpty`
- **Sections.** Each is `VStack(alignment: .leading, spacing: 10) { SectionLabel(...).padding(.horizontal, 4); panel }` with `.accessibilityElement(children: .contain)` and the identifiers `competition.home.needsYou`, `competition.home.live`, `competition.home.upNext` and `competition.home.results`.
  - **Row panels** keep today's `VStack(spacing: 0)` + `CompetitionRowDivider` + `.themePanel()` + `clipShape` (:138-156). Each cell is `VStack(spacing: 0) { rowButton; issueLine(c) }`. The issue line is padded leading 70 to align past the badge.
  - **Live** cards are a `VStack(spacing: 12)`. Each item is `VStack(alignment: .leading, spacing: 12) { competitionButton(c) { CompetitionHeroCard(…, isCompact: true) }.buttonStyle(CompetitionPressButtonStyle()); issueLine(c) }.padding(16).themePanel()`.
  - **Up next** draws closed outgoing challenges with `CompetitionClosedChallengeRow` and everything else with `CompetitionSharingRow`.
  - **Recent results** wraps each row button in `CompetitionArchiveSwipeRow` and passes `caption: "Moves to History \(weekdayText(leave.day, locale: locale))"`.
- **:106-127 `competitionButton`:**
  - Gains `caption: String? = nil`.
  - The `accessibilityLabel` becomes `sharingAccessibilitySummary(c, source:, locale:, timeZone:)`, plus `". \(caption)"` when there is a caption.
  - The hint "Opens this match" (PR 1) is unchanged.
- **:161-188 `historyButton`:**
  - The subtitle is `competitionHistorySummaryText(records)`, styled per the record colors.
  - Add `.accessibilityLabel("History")`, `.accessibilityValue(records accessibility text)` and the hint "Opens finished matches".
- **:190-247 `emptyState`:**
  - The title is "Nothing live right now" when `!records.isEmpty`; otherwise PR 1's title and description.
  - The local reinvite condition becomes `publication.dashboard.hiddenTerminalCompetitionCount > 0 || publication.dashboard.competitions.contains { if case .declined = $0.lifecycle { true } else if case .expired = $0.lifecycle { true } else { false } }`.
- **:249-262 `issueBanner`** takes the summary string. Its VoiceOver label is PR 1's.
- **:267-402 `CompetitionHeroCard`** gains `var isCompact = false`. When compact:
  - `isLive` dot/word hidden;
  - no "MATCH DETAILS →" block (:301-308);
  - `HeroScoreboard(competition:, isCompact:)`.
- **:404-460 `HeroScoreboard`:** `init(competition:isCompact:)` sets `_scoreSize = ScaledMetric(wrappedValue: isCompact ? 40 : 64, relativeTo: .largeTitle)`.
- **:462-567 `CompetitionSharingRow`:**
  - Add `var caption: String? = nil`, drawn under the status line in `.caption`, secondary.
  - Status comes from `competitionHomeStatusLine` (replacing `statusText`, :534-544).
  - When `.pending(.incoming, …)`, draw the "Review" capsule in place of the chevron, `.accessibilityHidden(true)`.
- **New `private struct CompetitionClosedChallengeRow: View`** with `competition`, `isInFlight`, `challengeAgain`, `dismiss`.
  - Layout: `VStack(alignment: .leading, spacing: 12) { HStack(alignment: .top) { badge; texts; Spacer; ✕ button }; againButton? }.padding(16)`.
  - `.accessibilityElement(children: .contain)`, `.accessibilityIdentifier(competitionSharingIdentifier(c))`. Today's switch already yields `competition.sharing.expired.<uuid>` / `.declined.<uuid>`.
  - The texts are combined into one element. The buttons have the identifiers `competition.closedRow.again.<uuid>` and `competition.closedRow.dismiss.<uuid>`.
  - Dismiss inserts the ID into `dismissedChallengeIDs`.
- **New `private struct CompetitionArchiveSwipeRow<Row: View>: View`.** Home is a plain VStack on purpose (:27-28 keeps every card in the hierarchy), so `List.swipeActions` isn't available.
```swift
ScrollView(.horizontal) {
    HStack(spacing: 0) {
        row.containerRelativeFrame(.horizontal)
        Button(action: archive) { /* "Archive" or ProgressView, onInk on Theme.ink */ }
            .frame(width: actionWidth).frame(maxHeight: .infinity)
            .disabled(isInFlight)
            .accessibilityLabel(label).accessibilityHint("Moves this result to History")
            .accessibilityIdentifier("competition.archive.\(uuid)")
    }
    .fixedSize(horizontal: false, vertical: true)
    .scrollTargetLayout()
}
.scrollTargetBehavior(.viewAligned)
.scrollIndicators(.hidden)
.scrollBounceBehavior(.basedOnSize)
```
  `@ScaledMetric var actionWidth: CGFloat = 96`. All of these APIs are on iOS 17+.
- **New `struct CompetitionIssueLine: View` (internal; the match and result screens use it too)** with `issue: CompetitionRowIssue`, `retry: (() async -> Void)?` and `id: CompetitionID`.
  - It holds `@State isRetrying`.
  - Layout: `HStack(alignment: .firstTextBaseline) { Label(text, systemImage: "exclamationmark.triangle.fill").font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink); Spacer(minLength: 8); retryButton }`. Retry shows for `.refresh` and `.activity` when `retry != nil`, with a 44pt minimum height and width.
  - Retry runs `Task { isRetrying = true; await retry(); isRetrying = false }`.
  - Identifiers: `competition.issue.<uuid>` on the label and `competition.issue.retry.<uuid>` on the button.
- **:616-672 `CompetitionAwardDashboardRow` and :674-747 `CompetitionRivalrySummaryCard`:** delete. PR 1's `now` edit to the card goes with them.
- **New `private struct CompetitionRecordRow: View`:**
  - Badge, name, `competitionHomeStatusLine(record.latest)`, trailing record.
  - `ViewThatFits` stacked branch at large sizes.
  - `.accessibilityElement(children: .ignore)` with the label `"\(record.accessibilityText). Latest: \(line)"`.
  - Identifier `competition.record.<latest competition uuid>`. No profile IDs go into identifiers.
- **:749-863 `CompetitionHistoryView`:**
  - Delete `Page`, the picker, `awardList` and `finished`.
  - The body is `recordSection` (labelled `competition.rivalry`) and `weeksSection` (today's `matchList` :797-830, iterating `competitionHistoryWeeks(publication.dashboard.competitions)`).
  - The empty text is "Finished matches appear here."
  - Its signature stays `CompetitionHistoryView(publication:)`.
- **:993-1023 `sharingAccessibilitySummary`:** PR 1's rebuild, using `competitionHomeStatusLine` for the status part.

##### 5. Host: MainTabView.swift
- **:9-13:** delete `@State showsHistory`; it moves to the reducer.
- **:53-58:** `CompetitionHomeRoute.stack(path: navigationPath, showsHistory: Binding(get: { store.showsHistory }, set: { store.send(.historyPresentationChanged($0)) }))`.
- **:61-94 new arguments:**
  - `openHistory: { store.send(.historyPresentationChanged(true)) }`
  - `challengeAgain: challengeAgain(_:)`
  - `archive: { store.send(.competition(.archiveTapped($0))) }`
  - `commandIDsInFlight: store.competition.commandIDsInFlight`
  - `retry: { await store.send(.competition(.pullToRefresh)).finish() }`
- **New `private func challengeAgain(_ id: CompetitionID)`:** for the fixture, `store.send(.competition(.reinviteTapped))`; for real matches, `store.send(.competition(.challengeAgainTapped(id)))` then `isChallengePresented = true`.
- **:152-156 `accountInitial`:** `store.competition.ownProfile?.displayName.first.map { String($0).uppercased() }`. Delete the "Every competition shares the owner's display name." comment.
- **:202-226 destinations:**
  - `CompetitionDetailView(…, issue: competitionRowIssue(id, in: publication.dashboard.issues), retry: retry)`.
  - `CompetitionResultView(…)` gets the same two arguments.
- **:228-234:** replace with `CompetitionClosedChallengeView(competition:, isInFlight:, challengeAgain: { store.send(.pathChanged([])); challengeAgain(id) })`. The fixture's `isInFlight` is `isCommandInFlight(bootstrapCompetitionID)`.
- **New `private struct CompetitionClosedChallengeView: View` in this file:**
  - `ContentUnavailableView { Label(title, systemImage: "person.crop.circle.badge.xmark") } description: { Text(detail) } actions: { if outgoing && canChallengeAgain { Button("Challenge \(name) Again") … .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("competition.closed.again") } }`
  - `.navigationTitle(name)`, `.navigationBarTitleDisplayMode(.inline)`, `.accessibilityIdentifier("competition.closed")` on the container.
  - `canChallengeAgain` is true for the fixture, and for real matches when `RemoteCompetitionOpponentIdentity.profileID(identity) != nil`.

##### 6. HealthComp/App/HealthCompApp.swift and AppFeature.swift
- **HealthCompApp.swift :236-247 `AppRootView`:** unchanged.
- **HealthCompApp.swift :270-292 `AuthenticatedRootView`:**
  - Delete `@State isAccountPresented`.
  - `MainTabView(store: mainStore, openAccount: { mainStore.send(.accountPresentationChanged(true)) })`.
  - The sheet binds with `Binding(get: { mainStore.isAccountPresented }, set: { mainStore.send(.accountPresentationChanged($0)) })`.
  - `done: { mainStore.send(.accountPresentationChanged(false)) }`.
- **AppFeature.swift** sets `ownProfile` (the same three edits as PR 6 Design B):
  - :96 and :356 become `MainTabFeature.State(competition: CompetitionFeature.State(ownProfile: profile))`, using the profile in scope there.
  - :479 adds `state.mainTab?.competition.ownProfile = profile` after `state.profile = profile`.

##### 7. Reducer: MainTabFeature.swift
- **State (:35-71):** add `var showsHistory: Bool`, `var isAccountPresented: Bool` and `var heldRouteSequence: UInt64?`, all as `init` parameters with defaults `false`, `false` and `nil`.
- **Actions (:79-102):** add `historyPresentationChanged(Bool)`, `accountPresentationChanged(Bool)` and `pendingRouteTimedOut(UInt64)`.
- **CancelID (:109-113):** add `routeHold`. Next to :115 add `private static let routeHoldTimeout: Duration = .seconds(15)`.
- **Reducer cases:**
  - `historyPresentationChanged(b)` sets `state.showsHistory = b`.
  - `accountPresentationChanged(b)` sets `state.isAccountPresented = b`.
  - `pendingRouteTimedOut(seq)`: guard `state.pendingRoute?.sequence == seq`. Then set `pendingRoute = nil`, `heldRouteSequence = nil` and `lastHandledRouteSequence = max(…, seq)`, and return `.run { _ in competitionRoutingClient.consume(seq) }`.
- **`.stop` (:209-220):** add `.cancel(id: CancelID.routeHold)` and `state.heldRouteSequence = nil`.
- **`resolve(_:state:)` (:467-490), rewritten:**
```swift
guard envelope.sequence > state.lastHandledRouteSequence else { state.pendingRoute = nil; return .none }
switch envelope.route {
case let .competition(id):
    guard visibleCompetitionIDs(in: state).contains(id) else {
        state.pendingRoute = envelope                       // keep the stack as it is
        guard state.heldRouteSequence != envelope.sequence else { return .none }
        state.heldRouteSequence = envelope.sequence         // refresh and time out once per route
        return .merge(
            .send(.competition(.pullToRefresh)),
            .run { send in
                try await continuousClock.sleep(for: Self.routeHoldTimeout)
                await send(.pendingRouteTimedOut(envelope.sequence))
            }.cancellable(id: CancelID.routeHold, cancelInFlight: true)
        )
    }
    state.pendingRoute = nil; state.heldRouteSequence = nil
    state.lastHandledRouteSequence = envelope.sequence
    state.showsHistory = false; state.isAccountPresented = false
    state.path = [id]
    return .merge(.cancel(id: CancelID.routeHold), .run { _ in competitionRoutingClient.consume(envelope.sequence) })
case .claimInvite:
    state.pendingRoute = nil; state.lastHandledRouteSequence = envelope.sequence
    return .none
}
```
  `.competition(.publication)` (:451-453) already calls `resolve(pending)` on every publication, so a held route opens as soon as its match appears. The `heldRouteSequence` guard stops a refresh loop: a refresh publishes, which re-resolves, which would refresh again.
- **Pruning (:438-440, :252-255) is unchanged.** Closed challenges are in the dashboard for 24 h, so an open challenge screen is no longer pruned when the challenge closes.

##### 8. Challenge again and own profile: CompetitionFeature.swift
- **State (:31-91):** add `var ownProfile: AuthenticatedProfile?`, an `init` parameter defaulting to nil (PR 6 Design B; PR 6 keeps it).
- **:93-125:** add `case challengeAgainTapped(CompetitionID)`.
- **`challengeAgainTapped(id)`**, written inline against today's fields (Claude's call: PR 4 lands before PR 6, see Risks; no `prefillRecipient` extraction, because PR 6 deletes the rematch prefill at :328-333 that it would share):
  - Guard `publication?.source == .remoteParticipants`, `state.inviteCreationStatus != .creating`, the parent is in the dashboard, and `RemoteCompetitionOpponentIdentity.profileID(parent.opponentIdentity)` is non-nil.
  - If `state.inviteCreationRematchParentID != nil` or `state.inviteRecipient?.id != profileID`, call `clearInviteCreation`, so the + sheet (which only shows status when the rematch parent is nil, MainTabView.swift:63-70) starts fresh.
  - Set `inviteRecipient = AuthenticatedProfile(id: profileID, displayName: parent.opponentDisplayName)`, `inviteRecipientCode = profileID.uuidString.lowercased()`, `inviteRecipientStatus = .idle`, and return `.none`. Nothing is created until Create is tapped, with `rematchParentID: nil`. The server rejects an expired parent as `rematch_not_allowed`.
  - `rematchTapped` is unchanged.
- **When PR 6 lands on top**, it ports this case to its slot model: ignore the tap while the `.sheet` slot is `.creating` or `.sent` (the sheet still opens and shows that state), otherwise drop a failed `.sheet` slot and set the same three recipient fields, which PR 6 keeps for the sheet. The rematch-parent clear goes away with `inviteCreationRematchParentID`.

##### 9. Match and result screens (issue line only)
- **CompetitionDetailView.swift:4-7:** add `var issue: CompetitionRowIssue? = nil` and `var retry: (() async -> Void)? = nil`. **:31** (first child of the content VStack): `if let issue { CompetitionIssueLine(issue: issue, retry: retry, id: competition.id) }`.
- **CompetitionResultView.swift:4-12:** add the same two properties. **:25**: the same insertion.
- **Removing the award kind:**
  - :386-424: title always `"Victory Over \(award.friendDisplayName)"` (or PR 1's casing);
  - :426-441 `awardDetail`: always `competitionVictoryCountText(awards.filter { $0.opponentIdentity == award.opponentIdentity }.count, friendDisplayName:)`;
  - :444-459 `awardBadge`: only the trophy branch.
- **MultiUserCompetitionTestLabView** keeps compiling unchanged for these two screens, because the new properties have defaults.

##### 10. MultiUserCompetitionTestLabView.swift (DEBUG UI test fixture)
- **:179-210 new arguments:**
  - `challengeAgain: { _ in recipient = AuthenticatedProfile(id: MultiUserCompetitionTestLabFixtures.expiredRecipientID, displayName: "Taylor"); recipientStatus = .idle; isChallengePresented = true }`
  - `archive: { archivedIDs.insert($0) }`
  - `commandIDsInFlight: []`
  - `retry: {}`
- **:490-610 fixtures:**
  - Add `secondActiveID` "Riley", `.active(dayOrdinal: 2)`, with its schedule starting Aug 14 (add a `startDay` parameter to `schedule()`), and `.competitionFailures([secondActiveID])` in `issues`.
  - Add `expiredID` "Taylor": `.expired(at: evaluatedAt − 2 h, direction: .outgoing)`, with `expiredRecipientID` used as the identity's profile ID.
  - Remove both `kind: .completion` awards. Drop `kind:` from the victory award and add `opponentIdentity:`.
- Fixed UUIDs are in the `A1000000-0000-4000-8000-00000000000N` series (N = 6, 7, 8).

#### Server changes
None.
- The real-match changes are client-side: the dashboard projection treats a lapsed `pending` challenge as expired for 24 h, and finished weeks leave Home on the phone without being archived.
- No migration, RPC, Edge Function or push change. Installed older apps keep today's behavior against the same server.
- Nothing to promote to Staging.

#### Tests

**HealthCompTests/CompetitionPresentationTests.swift** (existing file, so no pbxproj change). Add a helper `homePresentation(id:name:identity:lifecycle:startDay:completedAt:evaluatedAt:)` using an LA schedule.
- `testHomeLayoutSingleLiveMatchIsTheHero`: one `.active(4)` plus one `.scheduled`. `hero` is the active match, `live` is empty and `upNext` holds the scheduled one.
- `testHomeLayoutTwoLiveMatchesAreEqualCardsByEndTime`:
  - Hermes (starts Oct 28), Andy (starts Oct 27) and a tallying match: `live` is [tallying, Andy, Hermes] and `hero` is nil.
  - Two live matches with the same start and the names "Zoe" and "amy": order by name ("amy" first).
  - Same start and same name: order by uuid.
- `testHomeLayoutGroupsEveryLifecycle`:
  - Incoming challenges expiring at T+5h and T+1h, plus one with nil expiry, give `needsYou` [T+1h, T+5h, nil].
  - Scheduled starting Nov 2, then Nov 1, plus an outgoing challenge plus a closed outgoing one give `upNext` [Nov 1, Nov 2, outgoing, closed].
  - Completed wins at T−1d and T−2d give `recentResults` newest first.
  - An archived match and a completed match past its leave time appear in no group.
- `testHomeLayoutScheduledLeadsOnlyWhenNothingIsLive`: two scheduled matches and none live. `hero` is the sooner one and `upNext` holds the other.
- `testClosedChallengesShowOutgoingOnlyAndHonorDismissal`: an `.expired(…, .outgoing)` appears in `upNext`; a `.declined(…, .incoming)` doesn't; the same expired match with its id in `dismissedChallengeIDs` doesn't; an all-closed dashboard has `isEmpty == true`.
- `testResultLeavesHomeOnTheFourthDayAfterTheWeek`:
  - A week of Sat Oct 24 – Fri Oct 30 2026 in America/Los_Angeles, completed Sat Oct 31 01:00, gives day Nov 3 and `at` 2026-11-03T08:00:00Z, across the Nov 1 DST change. `weekdayText(day, locale: en_US)` is "Tue".
  - The same week completed Mon Nov 2 15:00 gives day Nov 4 (a late tally still gets a day).
- `testHomeStatusLineAddsChallengeExpiry`:
  - en_US, LA, `evaluatedAt` Fri Oct 30 2026 10:00. An incoming challenge expiring Sun Nov 1 14:14 gives "Challenge received · Expires Sun 2:14 PM".
  - An outgoing challenge with nil expiry gives "Challenge sent".
  - An expiry earlier than `evaluatedAt` gives no suffix.
- `testOpponentRecordsGroupByIdentityAndShowTheNewestName`:
  - Two people both named "Sam" with different identities give two records.
  - One identity whose name is "Max" in older weeks and "Maxine" in the newest week gives one record named "Maxine".
  - W/L/T counts are correct. `text` is "2–1" and "1–0–1"; `accessibilityText` is "Sam, 1 win, 0 losses, 1 tie".
  - Records are ordered by their latest week.
- `testHistorySummaryShowsTwoPeopleThenACount`: 1, 2 and 4 records give "Alex 3–1", "Hermes 2–1 · Andy 1–0" and "Hermes 2–1 · Andy 1–0 · 2 more".
- `testHistoryWeeksAreNewestFirst`: three finished weeks given in uuid order come out ordered by week end descending.
- `testRowIssuePrefersCommandThenRefreshThenActivity`: all three issues for id A give `.command`; refresh plus activity give `.refresh`; activity only gives `.activity`; an issue for id B gives nil for A.
- `testIssueSummaryShowsOnlyGlobalOrUnattributedProblems`:
  - `[.competitionFailures([A])]` with attributed {A} gives nil; with attributed {} it gives PR 1's "Some matches could not be refreshed."
  - `[.remoteUnavailable]` gives "Offline. Scores update when you reconnect."
  - `[.commandRejected(bootstrapID)]` with attributed {A} gives "The last match action could not be completed."
- **Change `testAwardEarnedDateAndRivalrySummaryComeFromCanonicalDashboard` (:729-786)** into `testAwardsAreWinsOnlyNewestFirstWithOpponentIdentity`:
  - The fold of a win (T0), a loss and a win (T2) gives two awards, [T2, T0], each with `opponentIdentity` and `friendDisplayName` taken from its presentation.
  - Keep the `competitionVictoryCountText` and `competitionSharingIdentifier` assertions.
  - Drop the rivalry assertions. Drop the `competitionAwardEarnedText` assertion if that function is deleted (Risks).

**HealthCompTests/LocalCompetitionClientTests.swift**
- :490-516 (award fold idempotence): expect `first.count == 1`, no `kind` and `friendDisplayName == "Alex"` from the presentation. Order is by `awardedAt` (all equal here, so by id).
- :1238-1246: after `decline(id)`, `declined.dashboard.competitions.map(\.lifecycle)` is `[.declined(at: <now>, direction: .incoming)]` (`makePendingClient` creates an incoming genesis, :1465) and `hiddenTerminalCompetitionCount == 0`. The notification snapshot assertions are unchanged. This is the incoming path: Home keeps the row off and falls back to the empty-state reinvite, which `testHomeLayout…` and the incoming-decline UI test also cover. The outgoing closed row is covered by `testClosedChallengesShowOutgoingOnlyAndHonorDismissal` and the Taylor UI test.
- New `testClosedInvitationStaysOnDashboardForOneDay`: call `LocalCompetitionProjector.dashboard(journals:context:configuration:issues:)` on the declined journal at `at + 23h59m` (visible) and at `at + 24h` (hidden, count 1).

**HealthCompTests/RemoteCompetitionClientTests.swift**
- New `testLapsedPendingChallengeShowsAsExpiredForOneDayOnlyOnTheDashboard`: a pending outgoing materialization with `expiresAt = now − 1h`.
  - `RemoteCompetitionProjector.dashboard` gives `.expired(at: expiresAt, direction: .outgoing)`.
  - At `expiresAt + 24h` the competition is gone and the hidden count is 1.
  - `notificationCompetition(from:)` still gives `.pending(expiresAt:)`.
- New `testRemoteAwardsAreWinsOnlyNewestFirst`.
- :3148-3169 and :3500-3509: update to `competitionIssueSummary(_, attributedIDs:)`. `.remoteUnavailable` gives the new offline string; `.activityFailures([id])` with attributed `[id]` gives nil, and with `[]` gives PR 1's activity string.

**HealthCompTests/AppFeatureTests.swift**
- The 4 expectations that build `MainTabFeature.State()` after a profile mount become `MainTabFeature.State(competition: .init(ownProfile: profile))`.
- New `testRenameUpdatesCompetitionOwnProfile`: after a successful `updateProfileResponse`, `mainTab?.competition.ownProfile?.displayName` is the new name. (PR 6 lists the same test; it moves here.)

**HealthCompTests/CompetitionFeatureTests.swift**
- :207-210: `completed.dashboard.awards.count == 1`.
- New `testChallengeAgainPrefillsTheSameAccountWithoutRematchParent`: a remote publication with an expired outgoing challenge to profile P plus a stale rematch-parent state. (PR 6 rewrites its expectations for the `.sheet` slot.)
  - After `.challengeAgainTapped(id)`, the state has `inviteRecipient == P`, `inviteRecipientCode == P.lowercased`, `inviteCreationRematchParentID == nil` and `inviteCreationStatus == .idle`, and no client call is made.
  - With the fixture source it does nothing.

**HealthCompTests/MainTabFeatureTests.swift**
- Replace `testArchivedRoutesWhileUnknownConsumesAtRoot` (:285-339) with `testUnknownRouteHoldsTheStackAndRefreshesOnce`:
  - Start from path `[archivedID]`; route an unknown id.
  - `pendingRoute` is set, `heldRouteSequence == 2` and `path` is unchanged.
  - It receives `.competition(.pullToRefresh)` (stub `reconcileAll`).
  - Sending an unrelated publication sends no second refresh.
- New `testHeldRouteOpensWhenItsCompetitionAppears`: a publication that includes the id gives `path == [id]` and `pendingRoute == nil`, and the sequence is consumed once.
- New `testHeldRouteTimesOutWithoutClearingTheStack`: advancing the `TestClock` by 15 s delivers `.pendingRouteTimedOut(2)`. `pendingRoute == nil`, `path` is unchanged and the sequence is consumed.
- New `testRouteClosesHistoryAndAccountBeforeOpening`: from `showsHistory: true, isAccountPresented: true` and a visible route, the result is both `false` and `path == [id]` in the same step.
- New `testHistoryAndAccountPresentationActionsSetState`.
- `testColdRouteParks…` and `testWarmVisibleRoute…` pass unchanged.

**UI tests.** Everything runs on the Mac mini (Xcode 26.6), and CI is the gate.
- **LocalCompetitionLifecycleUITests.swift:**
  - :113: delete the completion-award assertion (PR 1 renamed it to "Match Complete"). Keep the Victory assertion.
  - :129-140: replace with:
    - `rivalry` exists;
    - one `competition.record.` row whose label contains "Alex" and "1 win";
    - `sharingCards(state: "completed").count == 1` in History;
    - no `app.buttons["Awards"]`; drop the "Earned" lookup.
  - :145-155: replace the ••• Archive with a swipe:
    - `sharingCards(state: "completed").firstMatch.swipeLeft()`;
    - tap the first `competition.archive.` button;
    - the completed count is 0 on Home and the archived count is 1 in History.
    - The ••• Archive path stays covered by MultiUserCompetitionUITests:203.
  - :203-226, renamed `testIncomingDeclineClosesInPlaceAndReinviteIsReachableAndIdempotent`:
    - after "Decline Challenge", `competition.closed` exists with the static text "Challenge declined" and the nav bar "Alex";
    - tap back and wait for Home;
    - `app.buttons["Challenge Alex Again"]` (PR 1 copy) exists; double tap; the pending count is 1.
  - :123-127: the rematch then appears in Up next and the result in Recent results. Assert `descendants["competition.home.upNext"]` and `["competition.home.results"]` exist.
- **MultiUserCompetitionUITests.swift:**
  - New `testHomeGroupsLiveMatchesByEndTimeAndShowsMatchIssues`:
    - `competition.home.live` exists with a static text beginning "LIVE · 2";
    - the Jordan card's `frame.minY` is less than the Riley card's (Jordan ends first);
    - `competition.issue.<riley>` has the label "Couldn't update scores" and `competition.issue.retry.<riley>` exists;
    - no "Some matches" banner text;
    - Priya appears under `competition.home.upNext`, and "Former competitor" under `competition.home.results` with a static text beginning "Moves to History".
  - New `testClosedChallengeRowChallengesAgainAndDismisses`:
    - `competition.sharing.expired.<taylor>` contains "Taylor didn't accept";
    - tapping `competition.closedRow.again.<taylor>` opens the challenge drawer showing Taylor; close it;
    - tapping `competition.closedRow.dismiss.<taylor>` removes the row.
  - `testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive` (:115): unchanged apart from PR 1's renames. The scheduled card is now an Up next row and is still found by `sharingCard(state: "scheduled", name: "Priya")`.
  - :185: the "Victory Over Former competitor" assertion stays (it is a win).
  - Appearance matrix (:510-660): include the new Home in light/dark at XS and AX5 captures. `performAccessibilityAudit` must pass: the Retry and ✕ 44pt targets, and text contrast on ink capsules.

**Accessibility identifiers.**
- **Added:**
  - `competition.home.needsYou`, `competition.home.live`, `competition.home.upNext`, `competition.home.results`
  - `competition.closedRow.again.<uuid>`, `competition.closedRow.dismiss.<uuid>`
  - `competition.closed`, `competition.closed.again`
  - `competition.archive.<uuid>`
  - `competition.issue.<uuid>`, `competition.issue.retry.<uuid>`
  - `competition.record.<uuid>`
- **Newly rendered from the existing function:** `competition.sharing.expired.<uuid>` and `competition.sharing.declined.<uuid>`, on closed-row containers (`otherElements`, not buttons).
- **Renamed:** none. **Removed:** none. `competition.rivalry` moves from the summary card to the RECORD section. `competition.history.open`, `competition.create.empty`, `competition.create.open`, `app.account`, `competition.more` and `competition.sharing.<lifecycle>.<uuid>` on rows and cards are unchanged.

#### Risks and sequencing
- **Landing order (Claude's call, a sequencing choice that doesn't change what ships):** PR 1 → PR 4 → PR 5 and PR 6. PR 4 before PR 5 is required (routing). PR 4 before PR 6 lets `challengeAgainTapped` and `ownProfile` be written once against today's fields; PR 6 then ports one case (Design 8). PR 3 can land either side of PR 4.
- **Depends on PR 1** for `competitionStatusText` (`.row` and `.card`), `competitionLeadText`, `competitionMomentText`, `weekdayText(_ CompetitionDay)`, `competitionPointsText`, `competitionFinalFractionDigits`, the rebuilt `sharingAccessibilitySummary` and its copy. PR 4 rewrites most of CompetitionSharingView.swift: PR 1's edits to `statusText` (:534-544), the hero (:329-401) and the rivalry card (:674-747) are carried forward or deleted.
- **Gap in PR 1's API:** nothing gives the weekday only for a `Date`. PR 4 avoids needing one by expressing the leave time as a `CompetitionDay` and using `weekdayText`.
- **`competitionAwardEarnedText` (PR 1) has no caller after PR 4.** The History award rows and the completion-award detail are gone. PR 4 deletes it and its test assertion (PR 3 doesn't use it).
- **Shared files:**
  - **CompetitionResultView.swift** (PR 3: result screen and award section): PR 4 adds two properties and one line at the top, and removes the completion-award branches (:386-459). Whichever lands second rebases. PR 3 must not reintroduce `award.kind`.
  - **CompetitionDetailView.swift** (PR 3): two properties and one line at :31.
  - **MainTabView.swift:** the initial reads `competition.ownProfile`; PR 8 adds nothing for the avatar. PR 6 may restyle the closed view, but it must keep the closed state in place and keep `competition.closed`.
  - **MainTabFeature.swift:** PR 5 (f-expiry) relies on PR 4's route holding and on the 24 h retention, so an expiry tap opens the closed screen instead of dumping the person on Home. PR 5's spec adds no routing and no MainTabFeatureTests change, so the two don't conflict.
  - **CompetitionFeature.swift / AppFeature.swift:** PR 6 reworks invite creation (f-uuid, f-lostlink). It keeps `ownProfile` (added here) and ports `challengeAgainTapped` as the "same account again" entry point (Design 8). PR 6's AppFeature `ownProfile` edits and `testRenameUpdatesCompetitionOwnProfile` are already done by PR 4.
  - **CompetitionSharingView.swift (PR 3):** if PR 3 lands second, it swaps the Home scheduled hero body to `CompetitionScheduledSummary` (Behavior, Hero).
  - **RemoteCompetitionClient.swift:** PR 2 edits `presentation(from:)` (:1766-1830) for snapshots and refresh. PR 4 adds one parameter and the lapsed mapping in the same function, plus the `dashboard` filter. Expect a textual conflict, not a semantic one.
- **Notifications:**
  - The local projector's `dashboard` change does not touch `notificationSnapshot` (:1193), which builds from journals.
  - The remote notification path keeps `closesLapsedChallenges: false`, so PR 5 controls when expiry cleanup happens.
  - The enum gaining `direction` doesn't affect `notificationLifecycle`, because those patterns don't bind.
- **No migration or server risk.** The client accepts the server's lazy expiry as it is. The runtime skips server-closed descriptors (:634-642), so PR 7 materializes its server-side declines and cancels from `list_challenges` (PR 7, Client and projector), the step this PR asks for.
- **`ScrollView(.horizontal)` row:** check that a horizontal drag starting on the row doesn't fight pull-to-refresh or the vertical scroll on iOS 18.5. Axis lock should handle it; confirm on the simulator and the Mac mini. Also confirm the inner horizontal ScrollView doesn't pick up Home's `.refreshable` (MainTabView.swift:95), which reaches it through the environment. The fallback, if it misbehaves, is `.contextMenu { Button("Archive") }` plus the same accessible button, and it should be reported as a deviation.
- **Verify on the Mac mini before opening the PR:** HealthCompTests, both UI suites, and light/dark captures of Home (one live, two live, closed row, empty with History) and History at XS and AX5.

#### Open questions
Moved to §10: Q12 (remove the Awards page), Q13 (lone scheduled match as the big card), Q18 (History record rows open anything) and Q19 (dismissed closed rows survive relaunch). All defaults are built above.

### PR 5 — Notifications (app + server push)

#### Scope
- **f-lostresult**: the posting cap applies per match, not per evaluation. Two or more results in one evaluation post as one summary. "600 today" posts at most once per day and names nobody. Same-time 9:00 reminders for matches on one schedule merge into one notification.
- **f-expiry**: the challenge expiry reminder fires 4 hours before expiry, with copy that depends on who sent the challenge. Tapping a notification whose match is gone no longer clears the navigation stack. PR 4's `resolve` rewrite delivers that part, so this PR adds no routing code (see Design F).
- **f-trivial**: "Neck and neck" needs Day 5 or later and real totals. A lead change needs an earlier leader, never fires on Day 1, and names who moved.
- **f-serverpush**: the app is the only source of visible match notifications. The server stops alerting for score uploads and for results. App and server notifications share one thread per match.
- **Locale numbers**: every number goes through PR 1's `competitionPointsText` with the user's locale.
- **Polish rows**: none. The "Deep links" polish row (close History and the Account sheet, hold routes to matches that aren't loaded yet) is in PR 4, and PR 4 rewrites `resolve`. This PR lands after PR 4, see Risks.

#### Behavior

All copy is en_US with the default locale. Numbers come from `competitionPointsText(_, fractionDigits:, locale:)`, for example "1,217" / "1.217" / "1 217". **{Name}** is `opponentDisplayName`, shown exactly as stored with no truncation in code. iOS wraps the body and cuts the title to one line. **{Days}** depends on the current day:

| Current day | {Days} |
|---|---|
| 7 (also `endsToday`) | "Last day." |
| 6 | "Two days left." |
| 5 | "Three days left." |
| 4 | "Four days left." |
| 3 | "Five days left." |
| 2 | "Six days left." |
| 1 | "Seven days left." |
| no day | {Days} and the space after it are left out |

##### Final copy table (replaces PR 1's table for these rows; PR 1 rows not listed stay as PR 1 wrote them)

| Family | Title | Body |
|---|---|---|
| inviteExpiry, outgoing (you sent it) | `{Name} hasn't accepted yet` | `Your challenge expires at {time}.` |
| inviteExpiry, incoming (you received it; local fixture only, since remote incoming challenges have no local journal, PR 7 §3) | `{Name} challenged you` (PR 1 `.notification` title for pending incoming) | `The challenge expires at {time}.` |
| leadChange, you lead | `You took the lead` | `You {own}, {Name} {opp}. {Days}` |
| leadChange, they lead | `{Name} took the lead` | `{Name} {opp}, you {own}. {Days}` |
| closeScore | `Neck and neck with {Name}` | `{Days} You're {n} behind.` / `{Days} You're {n} ahead.` / `{Days} All square.` |
| dailyMaximum | `600 today` | `That's the daily max.` (1 live match) · `That's the daily max. It counts in both your matches.` (2) · `That's the daily max. It counts in all {k} of your matches.` (3+) |
| result, win | `You beat {Name}` (PR 1 formatter) | `{own} to {opp}.` |
| result, loss | `{Name} won` (PR 1 formatter) | `{opp} to {own}.` |
| result, tie | `All square with {Name}` (formatter, after PR 3's tie title) | `{own} to {opp}.` |
| results summary (2+ in one evaluation) | `{k} matches finished` | One sentence per match, joined by a space: `You beat {Name} {own} to {opp}.` / `{Name} won {opp} to {own}.` / `All square with {Name} at {own}.` |
| catchUp summary (2+) | `Match update` | `Open HealthComp for the latest on your matches with {names}.` |
| scheduledStart, merged | `Day 1 of 7` | `Your matches with {names} start today.` |
| finalDay, merged | `Last day` | `Today is the last day of your matches with {names}.` |
| competitionEnded, merged | `Final score pending` (formatter title, after PR 3) | `HealthComp is checking the latest Activity data before finalizing your results with {names}.` |

- **{time}** is `expiresAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))`, for example "2:14 PM" or fr_FR "14:14". It needs no date: the reminder fires 4 h before, so the time is unambiguous.
- **{n}** is `competitionPointsAccessibilityText(abs(margin), locale:)`, for example "18 points" or "1 point". `margin = competitionDisplayedMargin(userPoints:opponentPoints:)` with 0 digits.
- **{own} / {opp}** use 0 fraction digits for lead and close. Results use `competitionFinalFractionDigits(userPoints:opponentPoints:)`, so 412.3 vs 412.0 reads "412.30 to 412.00."
- **{names}** is the unique names of the other people, sorted with `localizedStandardCompare` and joined by `ListFormatter` with `locale`: "Jordan and Priya", or "Jordan, Priya, and Sam".
- **Summary order**: wins, then ties, then losses. Within each, by name (`localizedStandardCompare`), then by competition id. This gives the mockup's "You beat Priya … Jordan won …".
- **Unchanged from PR 1**: scheduledStart, finalDay and competitionEnded for one match (their titles come from the formatter, so competitionEnded reads "Final score pending" once PR 3 lands), catchUp for one match, and the result with a nil outcome ("Match complete" / "Your match with {Name} is complete.").

**Two deviations from the mockups:**
1. The expiry body leaves out "Send it again?". Tapping the reminder opens the pending challenge, where PR 6 puts Share Link Again (and PR 7 adds Cancel Challenge), so the body doesn't need to ask. See §10 Q20.
2. The result body leaves out "Tap for the week, or rematch.", because the owner dislikes taglines. Tapping already opens the match.

##### f-lostresult
- **Per-match cap.** Each match can post at most `maximumPostsPerEvaluation` (1) notification per evaluation. Matches no longer compete with each other for that slot. Inside one match, priority is unchanged: result > dailyMaximum > closeScore > leadChange > catchUp, and lower-priority candidates are still recorded as `.superseded`.
- **Two matches finish together.** Both results are recorded as `.emitted` and one notification posts: "2 matches finished" with both sentences. Three matches give "3 matches finished" with three sentences.
  - The summary takes the lowest identifier of the results it covers, which ends in `:result:result`. Archive cleanup (`.nonResult`) therefore keeps it.
  - It has no route. Tapping it opens the app where it was and pushes nothing.
- **Exactly one result** posts on its own (per-match title and body above), routed to that match.
- **Results across evaluations.** Match A finishes in one evaluation and match B in a later one: each posts alone, so neither is lost.
- **"600 today"** posts at most once per day, however many live matches reach the daily max.
  - It names nobody and has no route.
  - k counts the snapshot's matches whose lifecycle is `.active` or `.endsToday`, including muted ones, because the points count there too.
  - **Same evaluation.** Every match that produces a dailyMaximum decision records it as `.emitted`, and the coordinator posts one request for the group.
  - **Later evaluations.** Records live in each match's own emission history, so per-match records alone do not stop a second post. Example: match B's sync fails in the evaluation where A posts. B reaches its own fresh, completed refresh later that day and builds its own dailyMaximum candidate. f-lostresult asks for one post, so the limit is one per day. Claude's call on how: a match does not post a dailyMaximum when another `.active` or `.endsToday` match in the snapshot already has a dailyMaximum record (emitted or suppressed) for that other match's current day. B's candidate is recorded as `.suppressed(reason: .superseded)`, so B's slot in that evaluation goes to its next candidate. Matches with different start days still match, because each sibling is checked against its own current day.
  - Claude's call: the sibling check reads any recorded disposition, because `NotificationEmissionProjection` keeps `recordedIDs` without dispositions (NotificationEmission.swift:289-310). The cost is that if the first match's dailyMaximum was suppressed by its own 2-per-day budget and no other match emitted that evaluation, nobody gets "600 today" that day. That is accepted, and it avoids a CompetitionCore change.
  - Claude's call: matches whose calendars are in different time zones can disagree about "today" near midnight, and a sibling that fails to load from the store is missing from the snapshot. In either case a second "600 today" can still post. Both are rare and accepted.
- **Repeat opponents** (two matches with Priya finishing together): "You beat Priya 3,410 to 3,180. Priya won 3,302 to 3,117." This is intentional, because the scores tell the two matches apart.
- **9:00 reminders.** When two or more unmuted matches have the same scheduled family (scheduledStart / finalDay / competitionEnded) at the same instant, they merge into one pending request.
  - It takes the lowest identifier among them, keeps their shared trigger, has no route, and uses the merged copy above.
  - The other members' pending requests are removed as obsolete by the existing reconcile (CompetitionNotificationCoordinator.swift:262-277).
  - If a member is later muted, archived or deleted, the next plan rebuilds the group, and a group of one goes back to the single copy and route.
  - Matches on different calendars or start days fire at different instants and never merge.
- **Threads.** Every notification for one match uses thread id `competition:<lowercased uuid>`, which matches the server's `thread-id` (index.ts:271). Summaries use `competition-summary`.

##### f-expiry
- **Fire time.** The reminder fires at `expiresAt − 4 h` and goes to both sender and recipient.
  - If that moment has already passed when the plan runs, no reminder is scheduled. This reuses the existing `fireDate > evaluatedAt` guard at CompetitionNotificationPlanner.swift:277.
  - Challenges always expire 24 h after creation, so a new challenge gets its reminder 20 h in.
  - After the update installs, the first plan re-upserts the same identifier with the earlier trigger. If the earlier trigger is already past, the old at-expiry request is removed as obsolete.
- **Accepted, declined or expired before the reminder fires.** The lifecycle leaves `.pending`, so the request is no longer desired and is removed at the next reconcile. If the app does not run before then, the reminder can still arrive. That is accepted.
- **Taps** follow PR 4's `resolve` rewrite (PR 4 "Deep links and notification taps"). This PR changes no routing.
  - **Summaries and the merged 9:00 reminders** carry no route. `userInfo` is empty, so no route envelope is created and the app opens where it was.
  - **A match still in `publication.dashboard.competitions`** opens: History and the Account sheet close and the path becomes `[id]`. This covers finished results that PR 4 moved off Home. Leaving Home only hides the row: History is built from `competitionHistoryWeeks(publication.dashboard.competitions)` and `.archived` stays in the dashboard (PR 4 lifecycle table; MainTabFeatureTests.swift:285-323 routes to an archived id today). So tapping a kept "You beat Priya" opens that match. It also covers expired or declined challenges within the dashboard's 24 h retention, which open the closed view.
  - **A match not in the dashboard** (deleted, or not synced yet): the current screens stay, the route is held for one refresh, and it is consumed after 15 s if the match does not appear.

##### f-trivial
- **closeScore** posts only when all of these hold:
  - the current day is 5 or later;
  - `min(own, opp) >= 300`;
  - `abs(competitionDisplayedMargin) <= 50`;
  - plus the existing freshness, lifecycle and episode rules.
- **closeScore examples:**
  - 0–0 on Day 1 → nothing.
  - 1,200 vs 1,190 on Day 4 → nothing.
  - Day 5 → "Neck and neck with Hermes · Three days left. You're 10 points behind."
  - Day 7, 2,400 vs 2,382 → "Neck and neck with Andy · Last day. You're 18 points ahead."
  - Day 6, 250 vs 240 → nothing.
  - It can fire once per day on Days 5–7, within the existing budget of 2 posts per match per day.
- **Leader.** The leader is the sign of `competitionDisplayedMargin(userPoints:opponentPoints:)`. A displayed margin of 0, for example 412.3 vs 412.0, means no leader, so "You 412, Alex 412" can never appear.
- **First leader.** When no leader has been recorded yet, the first leader is recorded silently as `.suppressed(reason: .superseded)` (episode `.leader(day, leader)`). It is the baseline and posts nothing. This needs no CompetitionCore change.
- **Day 1.** Every leader change is recorded silently, because these are usually sync order.
- **Day 2 and later.** A leader different from the most recent recorded one posts "{Name} took the lead · {Name} 1,032, you 1,010. Three days left." (Day 5) or "You took the lead · …".
- **Ties after a lead** record nothing, and the earlier leader stays the baseline.
- **Past-day leads and closes** are recorded as `.staleEpisode` using the same displayed-margin and day rules (planner :461-536).
- **Tallying, completed and archived** matches never produce lead, close or daily-max notifications. That is unchanged (`permitsFreshScoreCopy`).

##### f-serverpush
- **After the server part ships:**
  - A score upload by the other person triggers no push.
  - A finalized result triggers no server push. The app's result notification (named, with scores, in the user's locale, summarized when there are several) is the only one.
  - The server work rows still exist and resolve as `discarded` without contacting APNs.
- **Before the server part ships** (it may be deferred, see Risks): the server's generic pushes continue, and they now group into the same per-match thread as the app's notifications in Notification Center.
- **Installed older app versions:** they stop receiving the server's generic pushes. They keep posting their own local notifications (old copy), so nothing breaks, but 1.0.2's global post cap can then drop a second simultaneous result with no server alert behind it (§10 Q10).

##### Accessibility
- System notifications are read by VoiceOver as title then body. The copy contains no symbols or abbreviations; "Neck and neck" and "All square" read naturally.
- There is no in-app UI change, so Dynamic Type and 44 pt targets are unaffected.

#### Design

No new Swift files and no `project.pbxproj` change. PR 1 rewrites CompetitionNotificationPlanner.swift:66-154 first, so build on PR 1's version of that range.

**A. `HealthComp/Services/CompetitionNotificationModels.swift`**
- :45-55, `CompetitionNotificationLifecycle`: `case pending(expiresAt: Date?)` → `case pending(direction: InvitationDirection, expiresAt: Date?)`. `InvitationDirection` is from CompetitionCore and is already imported at :1.
- :135-157, add next to `CompetitionNotificationPlanningSnapshot`:
  ```swift
  extension CompetitionNotificationLifecycle {
      var isLiveDay: Bool {
          switch self { case .active, .endsToday: true; default: false }
      }
  }

  extension CompetitionNotificationPlanningSnapshot {
      /// Matches whose current day counts today; muted ones included.
      var liveMatchCount: Int { competitions.filter(\.lifecycle.isLiveDay).count }
  }
  ```
  (`isLiveDay` lives here rather than in the planner so both the snapshot extension and the planner can use it.)
- :173-180, `CompetitionNotificationMessage` adds four defaulted vars after `outcome`. The memberwise init stays source-compatible.
  ```swift
  var dayOrdinal: Int? = nil
  var liveMatchCount: Int = 1
  var expiresAt: Date? = nil
  var invitationDirection: InvitationDirection = .outgoing
  ```
- :182-185, `CompetitionNotificationEmissionDecision` adds `let message: CompetitionNotificationMessage` between `record` and `request`. The coordinator rebuilds summary content from it.

**B. `HealthComp/Services/CompetitionNotificationClient.swift`**
- :258-262 and :264-269: `route: CompetitionRoute` → `route: CompetitionRoute?` in both request structs. Existing `route: .competition(id)` call sites compile unchanged.
- After :269, add a global function, outside the `#if` so tests can reach it:
  ```swift
  func competitionNotificationThreadIdentifier(_ route: CompetitionRoute?) -> String {
      if case let .competition(id)? = route {
          return "competition:" + id.rawValue.uuidString.lowercased()
      }
      return "competition-summary"
  }
  ```
- :397-407, `makeContent(_:route:)` takes `CompetitionRoute?`:
  - `content.userInfo = route?.userInfo ?? [:]`
  - `content.threadIdentifier = competitionNotificationThreadIdentifier(route)`
  - An empty userInfo decodes to nil in `HealthCompAppDelegate.userNotificationCenter(_:didReceive:)` (HealthCompAppDelegate.swift:52-61), so a summary tap opens the app without routing. This already works.
- `UNMutableNotificationContent.threadIdentifier` is available on iOS 10+.

**C. `HealthComp/Services/CompetitionNotificationPlanner.swift`**

Policy struct (:4-21):
- :12-15: `isCloseScore` becomes `(_ ownerPoints: Double, _ opponentPoints: Double, _ dayOrdinal: Int) -> Bool`.
- After :20, add `var summaryContent: @Sendable (_ messages: [CompetitionNotificationMessage]) -> CompetitionNotificationContent = { CompetitionNotificationPolicy.liveV1SummaryContent($0) }`. The default value keeps every test fixture's memberwise init valid.
- :5: add a doc comment saying `maximumPostsPerEvaluation` is the cap **per match** per evaluation.

`liveV1` (:27-64):
- :31: `guard family != .inviteExpiry else { return baseDate.addingTimeInterval(-4 * 60 * 60) }`.
- :45-49:
  ```swift
  isCloseScore: { owner, opponent, dayOrdinal in
      owner.isFinite && opponent.isFinite && dayOrdinal >= 5 && min(owner, opponent) >= 300
          && abs(competitionDisplayedMargin(userPoints: owner, opponentPoints: opponent)) <= 50
  },
  ```
- :63 stays `content: { liveV1Content($0) }`.

Copy (PR 1's version of :66-154):
- Signature: `static func liveV1Content(_ message: CompetitionNotificationMessage, locale: Locale = .current, timeZone: TimeZone = .current) -> CompetitionNotificationContent`. This is PR 1's signature plus a defaulted `timeZone`, needed for {time}.
- Implement the table above:
  - **inviteExpiry**: switch on `message.invitationDirection`. When `expiresAt` is nil, the body falls back to "Your challenge expires soon." (outgoing) or "The challenge expires soon." (incoming). The planner only schedules the reminder when `expiresAt` exists, so this is defensive.
  - **leadChange and closeScore**: they read `message.dayOrdinal` and the displayed margin. A margin of 0 can only reach closeScore, as "All square."
  - **dailyMaximum**: reads `message.liveMatchCount`. Its title is `competitionPointsText(ActivityScore.maximumDailyPoints, locale:) + " today"`.
  - **result**: the body uses `competitionFinalFractionDigits`.
- Add `static func liveV1SummaryContent(_ messages: [CompetitionNotificationMessage], locale: Locale = .current) -> CompetitionNotificationContent`. It switches on `messages[0].family`:
  - `.opportunistic(.result)` and `.opportunistic(.catchUp)`: summary rows.
  - `.scheduled(.scheduledStart / .finalDay / .competitionEnded)`: merged rows.
  - Any other family returns `liveV1Content(messages[0], locale:)`.
  - It sorts the messages as specified in Behavior.
- Add `private static func daysLeftText(_ dayOrdinal: Int?) -> String?`, returning the {Days} table, and `private static func uniqueNamesText(_ messages: [CompetitionNotificationMessage], locale: Locale) -> String`, built with `ListFormatter`.
- `scoreCopy` (:132-142) is deleted. Its callers are rewritten above.

`plan(...)` (:166-262):
- **Delete the global cap** at :236-251. Keep the sort at :230-235 so output stays deterministic.
- **Scheduled requests.** `scheduledRequests` (:264-302) returns `[ScheduledCandidate]`, a new nested `private struct ScheduledCandidate { let request: CompetitionScheduledNotificationRequest; let message: CompetitionNotificationMessage; let fireDate: Date }`. It is collected at :212-217.
- **Merge.** After the loop, `let scheduled = mergedScheduledRequests(candidates)`, using a new `private func mergedScheduledRequests(_ candidates: [ScheduledCandidate]) -> [CompetitionScheduledNotificationRequest]`:
  - Group by the `(family, fireDate)` of `message.family`, for families `.scheduledStart`, `.finalDay` and `.competitionEnded` only.
  - A group of 1 keeps its request unchanged.
  - A group of 2+ becomes `CompetitionScheduledNotificationRequest(identifier: group.map(\.request.identifier).min()!, content: policy.summaryContent(group.map(\.message)), dateComponents: <that member's components>, route: nil)`.
  - :254-256 sorts the result by identifier, as today.
- **inviteExpiry message.** `scheduledRequests` builds it with `expiresAt` and `invitationDirection` taken from `competition.lifecycle`.

`scheduledBases` (:312-316):
- `case let .pending(_, expiresAt):`. The direction is read in `scheduledRequests` when building the message.

`opportunisticPlan` (:385-459):
- **Baseline.** Before :393, `if let baseline = try leadBaselineRecord(for: competition, snapshot: snapshot) { result.suppressions.append(baseline) }`, after filtering against `recordedIDs`.
- **Daily max once per day.** After the `recordedIDs` filter (:393-400): if `dailyMaximumRecordedInAnotherMatch(competition, snapshot:)`, remove the `.dailyMaximum` candidate before the priority sort and append it to `result.suppressions` as `.suppressed(reason: .superseded)` with the same family and episode. Removing it before the sort lets the match's next candidate take its slot.
- **Decisions.** Decisions built at :421-431 pass `message: candidate.message`.

New `private func dailyMaximumRecordedInAnotherMatch(_ competition: CompetitionNotificationCompetitionSnapshot, snapshot: CompetitionNotificationPlanningSnapshot) -> Bool`:
```swift
snapshot.competitions.contains { other in
    guard other.id != competition.id,
          other.lifecycle.isLiveDay,              // .active or .endsToday
          let day = other.currentDayOrdinal,
          let id = try? NotificationEmissionRecorded.semanticID(
              competitionID: other.id, family: .dailyMaximum, episodeKey: .day(day))
    else { return false }
    return other.emissionHistory.recordedIDs.contains(id)
}
```
- `isLiveDay` is defined in section A.
- The lifecycle guard stops a match that ended yesterday (tallying, still on day 7) from suppressing today's post.
- Muted matches never record anything (`plan` skips them at :204-210), so they never suppress.
- `semanticID(competitionID:family:episodeKey:)` is the static function `mostRecentRecordedLeader` already uses (:711).

New `private func currentLeader(_ competition: CompetitionNotificationCompetitionSnapshot) -> NotificationEmissionLeader?`:
- Uses `competitionDisplayedMargin(userPoints: competition.ownerPoints, opponentPoints: competition.opponentPoints)`.
- Returns `> 0` → `.owner`, `< 0` → `.opponent`, `0` → nil.

New `private func leadBaselineRecord(for:snapshot:) throws -> NotificationEmissionRecorded?`. All of these must hold:
- the same freshness, lifecycle and ordinal guard as :653-659;
- `currentLeader` is non-nil and differs from `mostRecentRecordedLeader(in:through:)`;
- either the previous leader is nil, or `ordinal == 1`.

When they hold, it returns `.suppressed(reason: .superseded)` for `.leader(dayOrdinal: ordinal, leader:)`.

`candidates` (:613-702):
- **dailyMaximum message** (:640-650): gets `dayOrdinal: ordinal, liveMatchCount: max(1, snapshot.liveMatchCount)`.
- **closeScore** (:661-664): `policy.isCloseScore(competition.ownerPoints, competition.opponentPoints, ordinal)`. Its message gets `dayOrdinal: ordinal`.
- **leadChange** (:678-700): replace with: `if let leader = currentLeader(competition), ordinal >= 2, let previous = mostRecentRecordedLeader(in: competition, through: ordinal), previous != leader { … }`. Its message gets `dayOrdinal: ordinal`.
- Extend `candidate(...)` (:729-757) with a `dayOrdinal: Int? = nil` and a `liveMatchCount: Int = 1` parameter, passed into the message.

`staleSuppressionRecords` (:461-536):
- :501: `policy.isCloseScore(ownerTotal, opponentTotal, day.ordinal)`.
- :512-519: derive the leader from `competitionDisplayedMargin(userPoints: ownerTotal, opponentPoints: opponentTotal)`.

`catchUpDecision` (:564-611):
- Pass `message: message` into the decision at :603.

New public planner method, placed after `plan`:
```swift
/// Collapses durable, accepted emissions from one evaluation into what iOS posts.
func immediateRequests(
    for emissions: [CompetitionNotificationEmissionDecision],
    in snapshot: CompetitionNotificationPlanningSnapshot
) -> [CompetitionImmediateNotificationRequest]
```
Rules, applied in input order with grouped families placed where their first member was:
- **`.result` and `.catchUp`**: a group of 1 keeps its `request`. A group of 2+ becomes one request with `identifier = min(identifiers)`, `content = policy.summaryContent(messages)` and `route = nil`.
- **`.dailyMaximum`**: always exactly one request, regardless of group size:
  - `identifier`: the minimum identifier in the group;
  - `content`: `policy.content(first.message` with `liveMatchCount = max(1, snapshot.liveMatchCount))`;
  - `route`: nil.
- **`.leadChange` and `.closeScore`**: unchanged, one request each, routed to their match.

**D. `HealthComp/Services/CompetitionNotificationCoordinator.swift`, :302-377**
- Declare `var accepted: [CompetitionNotificationEmissionDecision] = []` before the loop.
- :312: `guard !isSuperseded(snapshot) else { return }` → `if isSuperseded(snapshot) { break }`.
- :363-372: replace the immediate `postNow` with appending each `.emission` to `accepted`.
- :373: → `if isSuperseded(snapshot) { break }`.
- After the loop:
  ```swift
  for request in planner.immediateRequests(for: accepted, in: snapshot) {
      do { try await notifications.postNow(request) }
      catch { reportError("notification-post-failed-after-append") }
  }
  guard !isSuperseded(snapshot) else { return }
  ```
  Committed decisions are still always posted, even when a newer snapshot arrives mid-loop. That preserves `testSupersedingSnapshotAfterAppendDoesNotSwallowCommittedPost`.
- The replan closure (:320-358) is unchanged. `emissionBudget` is now each match's own count, which is 0 or 1.

**E. Projectors (pending direction)**
- `HealthComp/Features/Competition/LocalCompetitionClient.swift:1289-1290`: `case let .pending(direction, _, expiresAt): return .pending(direction: direction, expiresAt: expiresAt)`.
- `HealthComp/Features/Competition/RemoteCompetitionClient.swift:1754-1755`: the same, inside `RemoteCompetitionProjector.notificationLifecycle`.

**F. `HealthComp/Features/MainTab/MainTabFeature.swift`: no change** (PR 4 owns `resolve`; see f-expiry "Taps").
- Claude's call: if PR 5 is ever built before PR 4, add only the minimal guard `if visibleCompetitionIDs(in: state).contains(id) { state.path = [id] }` at :477-481, and have PR 4 replace it. Do not build a second hold mechanism.

**G. Reducer state and actions**
- No change. No view changes. `PermissionOnboardingView` samples come from the policy since PR 1. After this PR they read:
  - "You took the lead · You 1,217, Alex 1,194." (PR 1's sample message has no `dayOrdinal`, so {Days} is left out)
  - "Last day · Today is the last day of your match with Alex."
  - "You beat Alex · 2,431 to 2,198."

#### Server changes
Edge Function only. **No migration**, so the pgTAP suites, recovery harness, migration count and manifest are untouched.

**`supabase/functions/send-competition-notification/index.ts`**
- **:255-277, `competitionNotificationPayload`** returns `Record<string, unknown> | null`:
  - `null` for `"score_update"` and `"result"`. The app owns all visible match notifications.
  - The two alert literals ("Competition updated…", "Competition complete…") are deleted.
- **:32-38, `NotificationWorkerDependencies`** adds `payload(item: NotificationWorkItem): Record<string, unknown> | null`.
- **:79-89, defaults** add `payload: competitionNotificationPayload`.
- **:279-304, `apnsRequest`** takes the payload as a fourth argument and uses it for `body`. The headers are unchanged, including `apns-collapse-id`.
- **:446-457, handler loop:**
  ```ts
  const payload = deps.payload(item);
  if (payload === null) {
    decision = { outcome: "discard", retryAfterSeconds: null };
  } else {
    try { decision = await resolution(await deps.send(apnsRequest(item, deps.configuration!, providerToken, payload)), item.environment); }
    catch { decision = { outcome: "retry", retryAfterSeconds: 60 }; }
  }
  ```
  - Resolution goes through the existing `resolve_competition_notification_work` with `outcome: "discard"`, which migration 0700:450 already allows.
  - `parseWorkItem` (:140-168) still accepts both kinds, so leased leftovers never fail a batch.
- **Ponytail comment** at the payload function: `// ponytail: triggers still enqueue score/result rows that resolve as discarded; drop enqueue_competition_notification_work_from_score/_from_result in a forward migration (e.g. with PR 7's) once pgTAP 012/019 fixtures insert work rows directly.`
- **Why not stop at the source now.** Migrations 0700 triggers are what pgTAP 012 (53 assertions) and 019 use to create work rows. A trigger-dropping migration would also have to update the recovery harness: `scripts/test-recovery-migrated-snapshot.sh:31` expects 23 migrations, and `scripts/tests/recovery-migrated-fixture.sql:23,35` pins the latest version. That cost buys only skipping a discarded row.

**Behavior and compatibility**
- **APNs.** Nothing is sent for any existing kind. The worker, lease, retry, token revocation and delivery-log code stay for PR 7's challenge push. PR 7 makes `competitionNotificationPayload` return a payload for its new kind.
- **Installed app versions** keep working. They simply stop receiving the generic alerts, and their own local notifications are unaffected.
- **Rollback** is redeploying the previous function version.

**Staging promotion** (docs/runbooks/supabase-environments.md)
1. Deploy `send-competition-notification` to Staging only.
2. Upload a score from the Staging pair and run the "Notification work" query (docs/runbooks/competition-support.md:346-371). New `score_update` rows must reach `discarded` with `attempt_count` 1, and no push may arrive on the Staging device.
3. Repeat with a Staging finalization for `result`.
4. Promote to production only through the docs/release/production-beta-checklist.md approval.
5. Update competition-support.md after :373 with: "`score_update` and `result` work resolves as `discarded` without APNs; the app posts match notifications."

#### Tests

**HealthCompTests/CompetitionNotificationPlannerTests.swift**
- **`testLivePolicyV1OwnsTimingBudgetPriorityAndPrivacyCopy` (:7-89):**
  - :27-34: expect `base.addingTimeInterval(-14_400)`.
  - :44-45 becomes four checks: `isCloseScore(1_000, 1_050, 5)` true; `(1_000, 1_051, 5)` false; `(1_000, 1_050, 4)` false; `(250, 290, 6)` false.
  - The result (via `liveV1Content(_, locale: en_US)`) has title "You beat Alex" and body "4,200 to 3,900."
- **Delete `testMaximumPostsPerEvaluationIsGlobalAcrossCompetitions` (:341-392). Add `testEachMatchHasItsOwnPostCap`.** Use the same two competitions, both with a daily max: 2 dailyMaximum decisions and no `.superseded` dailyMaximum suppression.
- **New `testTwoResultsInOneEvaluationBothEmit`.** Two `.completed` competitions with `terminalResult` give 2 `.result` decisions, and each carries its message.
- **New `testImmediateRequestsSummarizeResults`** (`.liveV1`, en_US). Decisions: win vs "Priya" 3,410/3,180 and loss vs "Jordan" 3,117/3,302, built via `plan` on two completed competitions. Expect one request:
  - identifier == the smaller result identifier;
  - title "2 matches finished";
  - body "You beat Priya 3,410 to 3,180. Jordan won 3,302 to 3,117.";
  - route nil.
  - One result alone returns its own request unchanged.
- **New `testDailyMaximumIsNotRepeatedByALaterMatchTheSameDay`** (`.liveV1`). Match A is active on day 3, with an emitted `(.dailyMaximum, .day(3))` record in its history. Match B is active, fresh and completed, with 600 accepted today:
  - B on day 3: no dailyMaximum decision, and one suppression `(.dailyMaximum, .day(3), .superseded)` for B. If B also qualifies for closeScore (day 5+ variant), closeScore is decided instead.
  - B on day 5 (different start day), with A's record on its own day 3: B is still suppressed.
  - A `.tallying` with a day-7 record: B's dailyMaximum is decided.
  - A's record on day 2 while A is on day 3 (yesterday): B's dailyMaximum is decided.
- **New `testImmediateRequestsPostDailyMaximumOnceWithoutAName`.** Two dailyMaximum decisions:
  - snapshot with 2 active matches → one request, title "600 today", body "That's the daily max. It counts in both your matches.", no "Alex", route nil;
  - 1 live → "That's the daily max.";
  - 3 live → "That's the daily max. It counts in all 3 of your matches.".
- **New `testSameScheduleRemindersMergeIntoOne`.** Two `.scheduled` competitions (names "Priya", "Jordan") with the same schedule, evaluated before the start.
  - Expect 3 desired requests: scheduledStart, finalDay and competitionEnded. Each has the smaller competition's identifier, route nil, and body "Your matches with Jordan and Priya start today." (and so on).
  - With different start days → 6 requests with single copy.
  - With one muted → 3 single requests.
- **New `testInviteExpiryFiresFourHoursEarly`.** Use `.pending(direction: .outgoing, expiresAt: E)`:
  - evaluatedAt E−10 h → one request whose components resolve to E−4 h;
  - evaluatedAt E−3 h → none.
- **New `testInviteExpiryCopyDependsOnDirection`.** With `liveV1Content(_, locale: en_US, timeZone: America/Los_Angeles)` and E = 2026-10-31T21:14Z:
  - outgoing → "Sam hasn't accepted yet" / "Your challenge expires at 2:14 PM.";
  - incoming → "Sam challenged you" / "The challenge expires at 2:14 PM.";
  - fr_FR body contains "14:14".
- **New `testCloseScoreNeedsRealTotalsLateInWeek`** (`.liveV1`, fresh). No closeScore for 0/0 on day 1, 1,200/1,190 on day 4, or 250/240 on day 6. Day 5 1,200/1,190 → closeScore with body "Three days left. You're 10 points behind."
- **New `testFirstLeaderIsSilentAndOnlyAChangeNotifies`** (`.liveV1`):
  - empty history, owner leads on day 3 → no leadChange decision; one suppression `(.leadChange, .leader(3, .owner), .superseded)`;
  - with that record and opponent 1,032 vs owner 1,010 on day 5 → one leadChange, title "Alex took the lead", body "Alex 1,032, you 1,010. Three days left.";
  - day 1 flip with a prior record → suppression only.
- **New `testLeaderUsesDisplayedPoints`.** 412.3 vs 412.0 on day 4 with a prior opponent record → no leadChange and no baseline.
- **New `testLiveV1CopyForEveryFamily`** (en_US, LA). One assertion per row of the copy table, including:
  - tie → "1,500 to 1,500.";
  - the 2-digit result "412.30 to 412.00.";
  - close "All square.";
  - summary tie sentence "All square with Sam at 3,180.";
  - catchUp summary;
  - dayOrdinal nil → no {Days}.
- **PR 1's tests:**
  - `testLivePolicyV1UsesTheUsersLocaleAndWholePoints`: expect "You took the lead" / "You 1.217, Alex 1.194.".
  - `testResultCopyShowsDecimalsOnlyWhenWholePointsWouldHideTheWinner`: expect "412.30 to 412.00.".
- **Fixture** `.fixture` (:648-675): `isCloseScore: { owner, opponent, _ in abs(owner - opponent) <= 25 }`. `testMixedPastFamiliesAreSuppressedBeforeOneCatchUp` keeps `.closeScore: 1, .leadChange: 2`.

**HealthCompTests/CompetitionNotificationCoordinatorTests.swift**
- **`NotificationOperationRecorder` (:1092-1117)** adds `private(set) var posted: [CompetitionImmediateNotificationRequest]`, appended in `postNow`.
- **Replace `testPerCompetitionCASReplanPreservesGlobalEvaluationBudget` (:597-654) with `testTwoResultsInOneEvaluationCommitBothAndPostOneSummary`:**
  - 2 emitted durable decisions, one per competition;
  - exactly one `post:`, whose identifier is the smaller result identifier;
  - `posted[0].route == nil`.
- **New `testDailyMaximumAcrossMatchesPostsOnce`** (`multiDecisionFixture`, two active competitions at 600 today): two dailyMaximum emissions committed and one post.
- **New `testSupersededSnapshotStillPostsEveryAcceptedDecisionOnce`.** Two competitions; the gate supersedes after the first commit. Exactly one post, and it covers only the first competition.
- **Fixtures** `coordinatorFixture`, `multiDecisionFixture`, `staleFixture` (:1166-1224): `isCloseScore` gets a third `_` parameter.

**Other unit tests**
- `HealthCompTests/LocalCompetitionClientTests.swift:1876`: `isCloseScore: { _, _, _ in false }`.
- `HealthCompTests/RemoteCompetitionRuntimeTests.swift:305, :404`: `.pending(direction: .outgoing, expiresAt: descriptor.invitationExpiresAt)`. Use `.incoming` if the descriptor's profile is the invitee.
- `HealthCompTests/CompetitionTraceIntegrationTests.swift:196` and `HealthCompTests/LocalCompetitionRuntimeTests.swift:1813`: pass `message: CompetitionNotificationMessage(family: .opportunistic(family), competitionID:, opponentDisplayName: "Alex", ownerPoints: nil, opponentPoints: nil, outcome: nil)`.
- **`HealthCompTests/CompetitionNotificationClientTests.swift`, new `testThreadIdentifierGroupsByMatch`:** `competitionNotificationThreadIdentifier(.competition(id))` == "competition:ead172f8-531d-4327-823d-e82a4f696070", and nil → "competition-summary".
- **`HealthCompTests/MainTabFeatureTests.swift`:** no change in this PR. PR 4 owns the `resolve` tests, including `testArchivedRoutesWhileUnknownConsumesAtRoot` (:285-339) and the new route-hold tests.

**Edge Function: `supabase/functions/send-competition-notification/index_test.ts`**
- **`dependencies(...)` (:211-223)** adds `payload: () => testAlertPayload`, where `testAlertPayload` is a fixed `{ aps: { alert: { title: "t", body: "b" }, sound: "default", "thread-id": "competition:c3000000-…" }, route keys }`. Every send-path test (:48-210, :403-680) keeps exercising APNs.
- **:474** expects `testAlertPayload`.
- **Replace "payloads are generic, route-only, and contain no score or identity" (:332-362) with "score and result work no longer alerts".**
  - `competitionNotificationPayload(item)` and `({ ...item, kind: "result" })` are `null`.
  - A handler run with the default payload over `[item, resultItem]`: `send` is never called, both resolve with `outcome: "discard"`, and the response has `discardedCount: "2"` and `sentCount: "0"`.

**pgTAP and UI tests**
- pgTAP: no change.
- **UI tests:** no accessibility identifier is added, renamed or removed. If PR 1 added a UI assertion on the onboarding samples, update it to "You took the lead", "Last day" and "You beat Alex".

**Verify on the Mac mini:**
- HealthCompTests and both UI suites.
- `deno test` for the function (CI already runs it).
- On a device:
  - two Test Lab matches finishing together produce one "2 matches finished" banner, and tapping it keeps the current screen;
  - tapping a kept result notification for a match now in History opens that match.

#### Risks and sequencing
- **Depends on PR 4** for tap routing (route hold, closing History and Account, 24 h retention of closed challenges). Land PR 4 first.
- **Depends on PR 1** (`liveV1Content(_:locale:)`, `competitionStatusText`, the points helpers). This PR rewrites PR 1's leadChange, closeScore, dailyMaximum, result-body and inviteExpiry rows, and adds `timeZone:` to `liveV1Content`.
- **PR 1 has no time-only formatter**, and `competitionMomentText` gives "Tue 2:14 PM". The expiry body uses `Date.FormatStyle(date: .omitted, time: .shortened, locale:, timeZone:)` inline (iOS 15+) instead of a new shared helper.
- **Shared regions:**
  - MainTabFeature.swift:467-497 (`resolve`, `visibleCompetitionIDs`): owned by PR 4. This PR doesn't touch them. If PR 4 ever moves History weeks out of `dashboard.competitions`, `visibleCompetitionIDs` must cover History too, or kept result-notification taps get held and then dropped.
  - RemoteCompetitionClient.swift:1612-1760 and LocalCompetitionClient.swift:1250-1300: PR 2 (data parity) may touch the notification projections. PR 4 adds a `direction:` parameter to the remote `lifecyclePresentation` and keeps `closesLapsedChallenges: false` on the notification path. This PR's `.pending(direction:expiresAt:)` binds the direction that `.pending` presentations already carry (RemoteCompetitionClient.swift:1898-1903). So PR 4's note that "`notificationLifecycle` ignores the direction" stops being true once this PR lands, which is harmless.
  - PermissionOnboardingView.swift samples: PR 8.
  - Pending and challenge copy: PR 6 and 7.
- **The server part is independent** (§10 Q1). If the owner defers it, the app part ships alone, and the server's generic pushes continue in the same per-match thread. The duplicate result banner remains until the server part ships.
- **PR 7** (challenge push) must give `competitionNotificationPayload` a payload for its new kind. If it adds a migration, it can drop the two dormant triggers then. That is the ponytail ceiling noted in the function.
- **No migration**, so there is no recovery-harness or manifest change in this PR.
- **One "600 today" covers several matches,** but each match that emitted in that evaluation spends one of its 2 posts for the day. Accepted. A match suppressed later by the sibling rule spends nothing. A second "600 today" the same day remains possible only across time zones near midnight, or when a sibling fails to load. A known first-match budget gap can also skip the post for a day. See Behavior.
- **Retiring the server result alert** means a result arrives when the app next evaluates. Remote evaluation runs on every HealthKit observer wake (RemoteCompetitionClient.swift:647/679 publish → coordinator), so for most users this is within hours. See §10 Q10.

#### Open questions
Moved to §10: Q10 (keep a server result alert as a fallback) and Q20 ("Send it again?" in the expiry reminder). Both defaults are built above.

### PR 6 — Challenges, app side

#### Scope
- **f-lostlink (client).** The link belongs to the pending challenge and survives keystrokes, a second Find Account, a rematch elsewhere and relaunch. The pending challenge screen shows the exact expiry and Share Link Again. Find Account is disabled once the challenge is sent. The + button always opens the sheet empty; PR 4's "Challenge {Name} Again" is the one prefilled open (§1).
- **Not in PR 6: Cancel Challenge.** PR 7 owns it end to end, app wiring included (PR 7, §5, `cancel_competition`). PR 6 has no dependency on PR 7 and merges on its own.
- **f-invite-errors.** One message per cause:
  - account code field: own code, malformed code, not found, network
  - sending: network, build configuration (a friendly line in Release), already pending, account gone
  - claim: your own link
  - The time-zone line is in words, not an IANA id.
  - No wrong-account claim message. PR 7's contract keeps that case collapsed into `invite_unavailable` (PR 7); see §10 Q5.
- **f-rematch (client).** The button follows the rematch: "Rematch {Name}", then "Rematch sent" with Share, then "Rematch starts Wed" opening the new match. Errors are shown. The local fixture's Rematch confirms in place. Invite state is kept per slot (the + sheet, and each result screen), so one flow can't wipe another's link.
- Polish **Challenge code field**: one line, Return = Find, results announced to VoiceOver.
- Polish **Share payload**: "Naren challenged you to a week of rings on HealthComp: <link>".
- Polish **Nav titles (challenge screen)**: PR 1 sets the nav title to the person's name. PR 6 replaces the outgoing large title with "Waiting for {Name}", so the name isn't repeated in a "Challenge to {Name}" heading.

#### Behavior

Apostrophes are typographic (’), matching existing copy (e.g. CreateCompetitionView.swift:128). UI tests must match strings exactly. "{Name}" is `opponentDisplayName`, or `AuthenticatedProfile.displayName` in the sheet. Long names wrap everywhere except navigation titles.

##### 1. The + sheet (CreateCompetitionView)

**Opening.**
- Every open from + (`competition.create.open`, `competition.create.empty`) starts empty: no code, no person, no status, no link.
- **The one prefilled open: PR 4's "Challenge {Name} Again"** (Home closed row and closed challenge view). It sends `.challengeAgainTapped(id)` and then opens the sheet with that person already found (status ready, code = their profile id). The person still taps Create. Claude's call: PR 6 keeps PR 4's entry point (PR 4) and rewrites it onto the new state (Design D).
- Any dismissal sends `.challengeSheetDismissed`, which resets all of the sheet's state, including a `.creating` sheet slot: the close button (`competition.create.done`), a swipe, or Open Challenge (below).
- If a creation is still in flight when the sheet closes, it still finishes. Its link is kept with the new challenge (see 2), and the sheet does not reopen into it. Because dismissal already dropped the slot, the next open (empty or prefilled) never finds the sheet locked by that earlier creation.

**Code field** (`competition.create.recipient-code`)
- One line, monospaced. A long code scrolls inside the field.
- The Return key is labeled Search and runs Find Account.
- The Done accessory (`competition.create.keyboard-done`) stays.
- The field is disabled while the challenge is being created or once it is sent.

**Find Account** (`competition.create.find-recipient`) is disabled when any of these holds:
- the trimmed code is empty
- a lookup is running
- the challenge is being created or has been sent

**Lookup results.** Errors show in one `Text` (`competition.create.recipient-error`) under the button, and the same text is announced.

| Cause | Detected | Copy |
|---|---|---|
| Not a UUID, or the nil UUID | locally | That isn’t a full account code. Ask them to share it again. |
| Your own profile id (case-insensitive) | locally, no network call | That’s your own code. Ask them for theirs. |
| `recipientUnavailable` / `notFound` / mismatched id | server | No account has this code. Check it and try again. |
| Any other failure | server | Couldn’t look up that code. Check your connection and try again. |
| Success | — | "Challenge {Name}" (PR 1 copy) plus the PR 1 confirmation caption. VoiceOver announces "Found {Name}". |

- **Deviation (own code):** the audit has "Ask {Name} for theirs". No name is known at that point (the code *is* how you find the person), so the copy says "them".

**Time zone** (`competition.create.time-zone`, a plain `Text` with no custom accessibility label).
- Copy: "Days run midnight to midnight, {generic zone name}."
- en_US America/Los_Angeles reads "Days run midnight to midnight, Pacific Time."
- The zone name comes from Foundation's localized generic name, so it keeps that capitalization (the audit had "Pacific time"). It falls back to the identifier when Foundation returns nil.

**Pinned control by status** (pinned below the content; placed after the content at accessibility sizes, as today at :20-22):

| Status | Header title | Control |
|---|---|---|
| ready | Challenge someone | "Create Challenge" (`competition.create.button`), disabled until a person is found |
| alreadyChallenged(c) (a pending, unexpired outgoing challenge to this person is already on Home) | Challenge someone | `Text` "You already challenged {Name}. Expires {moment}." (`competition.create.already-pending`). Primary "Open Challenge" (`competition.create.open-existing`) closes the sheet and opens c. The Create button is not shown. |
| creating | Challenge someone | Progress "Creating challenge…" (PR 1) |
| sent | **Challenge sent** | ShareLink "Share Challenge" (`competition.create.share`), then a caption (rows below) |
| failed(connection) | Challenge someone | Label "Couldn’t send the challenge. Check your connection and try again." (`competition.create.send-error`). "Try Again" (`competition.create.button`) reuses the same idempotency key. |
| failed(unavailable) | Challenge someone | Label (`competition.create.configuration-error`), with no button. Release: "Challenges aren’t available right now." Debug and Staging (`#if DEBUG \|\| HEALTHCOMP_STAGING`): "Challenge links are not configured for this build." |
| failed(alreadyPending), challenge not on Home yet | Challenge someone | `Text` "You already challenged {Name}. It expires 24 hours after you sent it." (`competition.create.already-pending`). The app refreshes, and the row turns into alreadyChallenged once the challenge shows up. |
| account deleted between Find and Create (`recipientUnavailable`) | Challenge someone | The person is cleared and the lookup error reads "No account has this code. Check it and try again." |

**Sent caption.**
- While the challenge is pending, or not yet published: "Waiting for {Name}. Expires {moment}." Before the publication has the challenge, the second sentence is "Expires in 24 hours."
- If the challenge has already left pending while the sheet is still open (they accepted at once): Share is hidden, and the caption is PR 1's `competitionStatusText(c, style: .row).line` (for example "Starts Wed, Nov 4").

**Announcements.** VoiceOver also announces "Challenge sent" on the change to sent, and the failure text on each failure.

**Shared helpers.**
- `{moment}` = `competitionMomentText(expiresAt, now: publication.evaluatedAt, locale:, timeZone:)`, for example "Sun 2:14 PM".
- **Share payload**, used by every Share button:
  - item, a single `String`: "{Sender} challenged you to a week of rings on HealthComp: {url}"
  - subject: "Join my HealthComp match"
  - when no sender name is known: "Join me for a week of rings on HealthComp: {url}"
  - Sender is your profile's display name in the sheet, and `competition.ownerDisplayName` on the challenge and result screens.
  - It stays one `String`, so Copy carries the full link. The existing copy tests depend on this; a URL plus a separate message loses one of the two in some share targets.
  - The accessibility hint stays "Opens the system share sheet. The private link is not read aloud."

##### 2. Pending challenge screen (CompetitionInviteView, remote, outgoing)
Mockup. Nav title "{Name}" (PR 1). Kicker "CHALLENGE SENT". The large title and body are below. Rules card. Pinned at the bottom: Share Link Again (PR 7 later adds Cancel Challenge under it).

| Case | Large title | Body (`competition.invite.expiry`) |
|---|---|---|
| expiresAt set | Waiting for {Name} | Expires {moment}. If {Name} accepts, Day 1 is the next day. |
| expiresAt nil | Waiting for {Name} | If {Name} accepts, Day 1 is the next day. |

- **No expired case here.** The server never flips a lapsed challenge on a schedule: `cleanup_expired_competition_invites` runs only from the support runbook (docs/runbooks/competition-support.md:542) or inside the sender's next create. PR 4 handles this in the client instead: the remote dashboard turns a `pending` challenge with `expiresAt <= now` into `.expired(at:direction:)` (PR 4), and MainTabView draws PR 4's closed view in place of this screen. This view therefore only ever sees an unexpired pending challenge.

- The hourglass label "Waiting for {Name} to accept" (:81-89) is removed for remote outgoing; the title now says it.
- Incoming remote and local fixture challenges keep their PR 1 title, body and controls.
- **Link control** (pinned; after the content at accessibility sizes). When the screen appears without a link in memory, it asks for one (`.inviteLinkNeeded`).

| Link state | Shows |
|---|---|
| ready | Primary ShareLink "Share Link Again" (`competition.invite.share`) |
| not requested yet / loading | The same primary button, disabled, with a ProgressView before the title (`competition.invite.share`, value "Loading") |
| failed (network) | Caption "Couldn’t load the link. Check your connection and try again." plus Secondary "Try Again" (`competition.invite.share-retry`) |
| notOnThisPhone (made on another device, by an app version before this PR, before a reinstall, or a create whose response was lost; see Design G) | Caption "The link for this challenge isn’t on this iPhone." (`competition.invite.link-missing`). No button. Until PR 7 ships, the challenge can only be left to expire. |

- **No Cancel Challenge in PR 6.** PR 7 adds it with its own endpoint and wiring (PR 7 §5). Remote `decline` stays `coordinator.unsupported(id)` (RemoteCompetitionClient.swift:79); no remote outgoing screen shows a Decline or Cancel button in PR 6, so nothing reaches it.

##### 3. Rematch on the result screen (CompetitionResultView)
**What the pinned control shows.**
- One state, derived by `State.rematchState(for:)`; the full rules are in Design D.
- Placement: pinned at the bottom as today (:75-83). At accessibility sizes it moves after the content, like the + sheet.
- **Claude's call:** this keeps the stacked panel from covering the screen at AX5.

| State | Remote | Local fixture |
|---|---|---|
| available | Primary "Rematch {Name}" (`competition.rematch.create`) | Same label and identifier (local today is "Rematch" with no identifier) |
| sending | Progress "Sending rematch…" | Same, shown while the local command is in flight |
| sent | Panel row (`competition.rematch.sent`): title "Rematch sent". Detail "Waiting for {Name} · expires {moment}" (only "Waiting for {Name}" when the expiry is unknown). Chevron. Tap opens the challenge. Trailing Share (link states below). | Row title "Rematch ready", no detail, no Share. Tap opens the challenge, where "Start with Alex" lives. |
| next, child scheduled | Row (`competition.rematch.next`): title "Rematch starts {weekdayText(startDay)}" ("Rematch starts Wed"). Detail `competitionScheduleDateRangeText(schedule, now:)` ("Nov 4 – 10"). Chevron. Opens the match. | Same |
| next, child live / tallying / finished | Row: title "Rematch". Detail PR 1 `competitionStatusText(child, style: .row).line` ("Day 2 of 7 · Ends Tue night", "You won · Nov 4 – 10"). Opens it. | Same |
| alreadyChallenged(c) | `Text` "You already challenged {Name}." plus Primary "Open Challenge" (`competition.rematch.open-existing`) | Not used |
| failed(connection) | `Text` "Couldn’t send the challenge. Check your connection and try again." (`competition.rematch.error`) plus Primary "Try Again" (`competition.rematch.retry`), same key | Not used |
| failed(recipientGone) (`recipientUnavailable`, or `forbidden`, which is the server's `rematch_not_allowed`) | `Text` "{Name} isn’t on HealthComp anymore." (`competition.rematch.error`). No button. | Not used |
| failed(unavailable) | Same Release / Staging strings as the sheet (`competition.rematch.error`) | Not used |
| failed(alreadyPending), challenge not on Home yet | "You already challenged {Name}. It expires 24 hours after you sent it." (`competition.rematch.error`) | Not used |

**Share in the sent row** (link states).

| Link state | Shows |
|---|---|
| ready | ShareLink with `SecondaryButtonStyle`, sized to fit: Label "Share" with square.and.arrow.up (`competition.rematch.share`) |
| loading / not requested yet | The same, disabled, with a ProgressView |
| failed | Secondary "Try Again" (`competition.rematch.share-retry`) |
| notOnThisPhone | Hidden |

**Layout.**
- Above accessibility sizes, the row and Share sit side by side.
- At accessibility sizes they stack, and Share spans the full width.
- The rows use `themePanel(cornerRadius: 14)` with `CompetitionRowButtonStyle`, minimum height 54.

**VoiceOver.**
- The rows read as one element each: "Rematch sent. Waiting for Hermes, expires Sun 2:14 PM", with hint "Opens the challenge" (next rows: "Opens the match").
- When the state leaves `sending`, VoiceOver announces the new title ("Rematch sent", "Rematch ready") or the error text.

**Edge cases.**
- Two results with the same person: each result tracks only its own children and its own slot. A rematch from result A never changes result B's control or link, nor the + sheet.
- A non-rematch challenge to the same person already pending: alreadyChallenged, before the tap, so the request is never sent.
- A closed rematch child (`.expired` or `.declined`, which PR 4 keeps in the dashboard for 24 h, including the lapsed pending ones it turns into `.expired`) is ignored, which brings back "Rematch {Name}". Claude's call: closed counts as "no child"; the closed outcome is already shown on Home by PR 4.
- Deleted opponent ("Former competitor"): the first tap shows "Former competitor isn’t on HealthComp anymore." No new server lookup is added just to hide the button in advance.

##### 4. Claim: your own link
- Opening your own live challenge link currently shows "Challenge unavailable / This link may be expired…".
- New: title "That’s your challenge", message "You sent this link. Only the person you challenged can accept it.", icon person.crop.circle.badge.checkmark, button "Done" (`competition.claim.dismiss`).
- Every other claim failure keeps PR 1's collapsed copy, including a link opened on the wrong account (§10 Q5).

#### Design

**A. `CompetitionFeature.swift` types**, replacing :7-18.
```swift
enum InviteSlot: Hashable, Sendable { case sheet; case rematch(of: CompetitionID) }
enum InviteCreationFailure: Equatable, Sendable { case connection, unavailable, recipientGone, alreadyPending }
struct InviteCreation: Equatable, Sendable {
    enum Status: Equatable, Sendable { case creating, sent(CompetitionID), failed(InviteCreationFailure) }
    var recipientID: UUID
    var idempotencyKey: UUID
    var status: Status
}
enum InviteLinkState: Equatable, Sendable {
    case loading
    case ready(CompetitionInviteShareLink, minimumRevision: UInt64)
    case notOnThisPhone
    case failed
}
enum InviteRecipientStatus: Equatable, Sendable { case idle, lookingUp, invalidCode, ownCode, notFound, connectionFailed }
enum ChallengeSheetStatus: Equatable, Sendable {
    case ready, creating
    case alreadyChallenged(LocalCompetitionPresentation)
    case sent(challengeID: CompetitionID, challenge: LocalCompetitionPresentation?, link: CompetitionInviteShareLink?)
    case failed(InviteCreationFailure)
}
enum CompetitionRematchState: Equatable, Sendable {
    case available, sending
    case sent(challengeID: CompetitionID, expiresAt: Date?, link: InviteLinkState?)
    case next(LocalCompetitionPresentation)
    case alreadyChallenged(LocalCompetitionPresentation)
    case failed(InviteCreationFailure)
}
```
- `InviteCreationStatus` is deleted.
- `InviteCreationResponse` (:20-28) is unchanged.
- Raw tokens never enter state or actions; only the redacted `CompetitionInviteShareLink` does, as today.

**B. State (:31-91).**
- Delete: `inviteCreationStatus`, `inviteCreationIdempotencyKey`, `inviteCreationRematchParentID`, `createdInviteLink`, `createdInviteCompetitionID`, `createdInviteExpectedPublicationRevision`. Update the init to match.
- Add, with init parameters defaulting to nil or empty (`ownProfile` already exists from PR 4):
  - `var inviteCreations: [InviteSlot: InviteCreation]`
  - `var inviteLinks: [CompetitionID: InviteLinkState]`
- Keep `inviteRecipientCode`, `inviteRecipient` and `inviteRecipientStatus`, which now belong to the sheet only.
- **AppFeature.swift**: no change here. PR 4 already sets `ownProfile` (:96, :356, :479), and the avatar reads it.

**C. Actions (:93-125).**
- Change: `createInviteResponse(InviteSlot, idempotencyKey: UUID, InviteCreationResponse)`.
- Add:
  - `challengeSheetDismissed`
  - `inviteLinkNeeded(CompetitionID)`
  - `inviteLinkResponse(CompetitionID, InviteLinkState)`

**D. Reducer.**
- **`.publication` (:175-194).** Replace `clearConsumedOrExpiredInvite` with `pruneInviteLinks(state:)`, which replaces :514-541.
  - Check each `inviteLinks` entry only when `publication.publicationRevision >= minimumRevision` (0 for non-ready states).
  - Keep the entry if its challenge is present, pending and unexpired.
  - Remove it if the challenge is present in any other state.
  - If the challenge is missing, remove the entry only when no blocking issue exists. Blocking issues are the exact switch at :524-536, extracted as `private func discoveryIsIncomplete(for id: CompetitionID, in publication: CompetitionPublication) -> Bool`.
  - Removing an entry also removes any `.rematch` slot whose status is `.sent(thatID)`. The `.sheet` slot is left alone until the sheet is dismissed.
- **`.inviteRecipientCodeChanged` (:196-203).**
  - Ignore it while the sheet is locked (`inviteCreations[.sheet]` is `.creating` or `.sent`), or when the code is unchanged.
  - Otherwise set the code, clear the person, set `.idle`, drop a failed `.sheet` slot, and cancel `CancelID.inviteRecipient`.
  - Remove the `clearInviteCreation` call at :202.
- **`.findInviteRecipientTapped` (:205-230).**
  - Ignore it if locked, already looking up, or the trimmed code is empty.
  - Bad UUID or the nil UUID → `.invalidCode`.
  - `id == ownProfile?.id` → `.ownCode`, with no effect.
  - Otherwise `.lookingUp`, drop a failed `.sheet` slot, and run the existing lookup effect.
- **`.inviteRecipientResponse` (:232-243).** Success with a matching id → set the person. `.recipientUnavailable` or `.notFound` (or a mismatched id) → `.notFound`. Any other failure → `.connectionFailed`.
- **`.createInviteTapped` (:245-249):** `beginInviteCreation(state:, slot: .sheet, recipient: state.inviteRecipient)`.
- **`beginInviteCreation(state:slot:recipient:)` (:551-641).**
  - Guard that the person is non-nil and the slot isn't creating or sent.
  - If `!canCreateShareLink()`: set the slot to `.failed(.unavailable)` with a new key, and stop (no server write).
  - Key: reuse the slot's key when it has the same `recipientID` and `.failed(.connection)`; otherwise `makeIdempotencyKey()`.
  - Set the slot to `.creating`.
  - The effect body is unchanged, except that it sends `.createInviteResponse(slot, idempotencyKey:, …)`. Keep `.cancellable(id: CancelID.inviteCreation, cancelInFlight: false)`.
- **`.createInviteResponse(slot, key, response)` (:251-278).**
  - On `.success(link, cid, rev)`, first set `inviteLinks[cid] = .ready(link, minimumRevision: rev)`, even if the slot is gone. This is what keeps a link created after the sheet was closed.
  - Then guard that `inviteCreations[slot]` has this key and is `.creating`, and apply:

| Response | Result |
|---|---|
| success | `.sent(cid)`, then `pruneInviteLinks` |
| `.pendingInvitationExists` | `.failed(.alreadyPending)`. Return `reconcile(trigger: .pullToRefresh)` so the existing challenge shows up |
| `.recipientUnavailable` or `.forbidden` on `.sheet` | Remove the slot, clear the person, set `inviteRecipientStatus = .notFound` |
| `.recipientUnavailable` or `.forbidden` on `.rematch` | `.failed(.recipientGone)` |
| `.divergentDuplicate` | `.failed(.connection)`, with the slot's key replaced by `makeIdempotencyKey()`. A changed time zone can no longer pin the slot to a conflicting key forever. |
| other failure | `.failed(.connection)` |
| `.configurationUnavailable` | `.failed(.unavailable)` |

- **`.rematchTapped` (:322-350).**
  - Remote: guard that the parent is found and `RemoteCompetitionOpponentIdentity.profileID` succeeds, and that `rematchState(for: parent)` is `.available` or `.failed(.connection)`.
  - Then call `beginInviteCreation(slot: .rematch(of: id), recipient: AuthenticatedProfile(id: profileID, displayName: parent.opponentDisplayName))`.
  - Delete :328-333; the rematch no longer writes the sheet's code or person. PR 4 wrote `challengeAgainTapped` inline, so nothing else shares this code.
  - Local path: unchanged.
- **`.challengeSheetDismissed` (new).** `inviteCreations[.sheet] = nil` (whatever its status, `.creating` included), code `""`, person nil, `.idle`, and return `.cancel(id: CancelID.inviteRecipient)`.
- **`.challengeAgainTapped(id)` (PR 4, rewritten).** PR 6 lands after PR 4, so this case exists.
  - Keep PR 4's guards: remote source, parent in the dashboard, `RemoteCompetitionOpponentIdentity.profileID(parent.opponentIdentity)` non-nil.
  - Then `inviteCreations[.sheet] = nil`, `inviteRecipient = AuthenticatedProfile(id: profileID, displayName: parent.opponentDisplayName)`, `inviteRecipientCode = profileID.uuidString.lowercased()`, `inviteRecipientStatus = .idle`, and return `.cancel(id: CancelID.inviteRecipient)`.
  - PR 4 wrote this case inline. Its "ignore while creating" and "clear creation if the recipient differs" guards go away, because the sheet slot is always nil once the sheet is closed (see `.challengeSheetDismissed`), and its `clearInviteCreation` call goes with them.
  - The view still sends this before presenting the sheet (PR 4), so the sheet's first frame already shows the person.
- **`.inviteLinkNeeded(id)` (new).**
  - Guard that the source is `.remoteParticipants` and `inviteLinks[id]` is nil or `.failed`.
  - Set `.loading`, then run `competitionClient.restoreInvite(id)`.
  - Build the link inside the effect with `makeShareLink(outcome.invite.token)`, after checking that `outcome.invite.competitionID == id.rawValue`.
  - Send `.ready(link, minimumRevision: outcome.expectedPublicationRevision)`, or `.notOnThisPhone` when the id is wrong or the link is nil.
  - On `catch CompetitionRemoteFailure.notFound` or `.divergentDuplicate`, send `.notOnThisPhone`.
  - On `CancellationError` or `.cancelled`, send nothing.
  - On anything else, send `.failed`.
- **`.inviteLinkResponse(id, s)` (new):** apply `s` only if `inviteLinks[id] == .loading`, so late responses after `.stop` are dropped.
- **`.stop` (:488-500):** also `inviteCreations = [:]` and `inviteLinks = [:]`. Delete `clearInviteCreation` (:505-512).

**E. Derived state (new `extension CompetitionFeature.State` in CompetitionFeature.swift).**
- `func pendingOutgoingChallenge(to opponentIdentity: String) -> LocalCompetitionPresentation?`: the first competition that is `.pending(.outgoing, _, _)` with a matching `opponentIdentity`. Remote source only; nil for the fixture. No expiry check: after PR 4 the remote dashboard never carries a lapsed `.pending` (it is `.expired`), and the projector uses the same instant as `publication.evaluatedAt`.
- `var challengeSheetStatus: ChallengeSheetStatus`, in this order:
  1. The sheet slot is `.creating` → `.creating`.
  2. The slot is `.sent(id)` → `.sent(id, the competition with that id, the link if inviteLinks[id] is .ready)`.
  3. A person is chosen and `pendingOutgoingChallenge(to: RemoteCompetitionOpponentIdentity.identity(for: recipient.id))` finds one → `.alreadyChallenged`.
  4. The slot is `.failed(f)` → `.failed(f)`.
  5. Otherwise `.ready`.
- `func rematchState(for parent: LocalCompetitionPresentation) -> CompetitionRematchState`:
  1. Children are the competitions whose `rematchParentID == parent.id`, excluding closed ones (`.declined`, `.expired`; PR 7 adds `.cancelled` to this list). Pick a pending child first, then a scheduled, live or tallying one, then any child (completed or archived). PR 4's lifecycle cases carry `direction:`; match them without bindings (`case .declined, .expired:`) so the code compiles before and after.
  2. A pending child gives `.sent(child.id, expiresAt, inviteLinks[child.id])`. Any other child gives `.next(child)`.
  3. With no child, the local source gives `isCommandInFlight(parent.id) ? .sending : .available`.
  4. Remote, no child: the slot `.creating` gives `.sending`, and `.sent(id)` gives `.sent(id, nil, inviteLinks[id])`.
  5. Otherwise `pendingOutgoingChallenge(to: parent.opponentIdentity)` gives `.alreadyChallenged`.
  6. Otherwise the slot `.failed(f)` gives `.failed(f)`, and no slot gives `.available`.

**F. Presentation gains the parent link.**
- `LocalCompetitionPresentation` (LocalCompetitionClient.swift:160-216) adds `let rematchParentID: CompetitionID?`, as an init parameter defaulting to `nil`. The 10 existing init sites compile unchanged.
- Remote: `RemoteCompetitionProjector.presentation` (RemoteCompetitionClient.swift:1806-1838) passes `materialization.descriptor.rematchParentID.map(CompetitionID.init)`. The field already exists on `CompetitionDescriptor` (CompetitionSyncModels.swift:812) and in the select (SupabaseCompetitionRemoteAPI.swift:811).
- Local: `LocalCompetitionProjector.dashboard` (LocalCompetitionClient.swift:1170-1176) maps `all` so that a presentation whose id equals `LocalCompetitionIdentity.rematchID(for: other.id)` for another journal gets `rematchParentID = other.id`. It is rebuilt through a small `with(rematchParentID:)` copy helper on the struct.
  - This is the same deterministic id `rematch` uses (:35, :746-750). The local re-invite child also links to its declined source, which is harmless because only completed parents ask.
  - Tests that inject a custom `idGenerator` get nil, which is acceptable.

**G. Keeping the link across relaunch, with no server change.**
- **Why replay works.** `create-competition-invite` derives the token as HMAC(sender, idempotencyKey) (supabase/functions/create-competition-invite/index.ts:35-58).
- The RPC returns the existing competition when the same key and request arrive again, and it does so before any pending or recipient check (supabase/migrations/20261019001800_bind_invitation_recipients.sql:145-161). Replaying a stored request therefore returns the same id and the same link. Nothing secret is stored: the key is useless without the sender's session and the server secret.
- **`CompetitionClient.swift`.** Add `var restoreInvite: @Sendable (CompetitionID) async throws -> CompetitionInviteCreationOutcome`, with an init parameter defaulting to `{ _ in throw CompetitionRemoteFailure.notFound }`. Place it after `resolveInviteRecipient` (:85, :139-141, :165). The local and test clients are unchanged.
- **`RemoteCompetitionClient.swift`:**
  - :128-130: wire `restoreInvite: { id in try await coordinator.restoreInvite(id) }`.
  - **New `actor RemoteInviteRequestStore`** in the same file, modeled on `CompetitionNotificationPreferencesStore`:
    - The file is `paths.rootDirectory/InviteRequests.json`: `{version: 1, entries: {"<competition uuid, lowercased>": {request: CompetitionInviteCreationRequest, createdAt: Date}}}`.
    - It is written with `.atomic` and `.completeFileProtectionUntilFirstUserAuthentication`.
    - `func save(_ request: CompetitionInviteCreationRequest, for id: CompetitionID, now: Date)` keeps an existing entry's `createdAt` and drops entries older than 25 hours.
    - `func request(for id: CompetitionID, now: Date) -> CompetitionInviteCreationRequest?` returns nil when the entry is older than 25 hours.
    - An unreadable or corrupt file counts as empty, and errors are swallowed. Losing it only degrades to "isn't on this iPhone".
    - Profile teardown already deletes the root (AuthenticatedProfileStorage.swift:330-346 accepts regular files), so no new directory and no teardown change.
  - **Coordinator:**
    - Hold `private var inviteRequests: RemoteInviteRequestStore?`.
    - Create it in `mount` next to `CompetitionInstallationStateStore` (:400), and set it to nil in `stop()` (:862-868).
    - In `createInvite` (:810), after `remoteAPI.createInvite` succeeds: `await inviteRequests?.save(request, for: CompetitionID(invite.competitionID), now: await environment.context().instant.wallDate)`.
    - New `func restoreInvite(_ id: CompetitionID) async throws -> CompetitionInviteCreationOutcome`: load the request, throw `.notFound` if absent, call `createInvite(request)`, and check that the returned id matches, else `.serverContractMismatch`.
- **Known gap: a lost create response.** The store saves only after a successful response. If the server creates the challenge but the response is lost (the sheet shows failed(connection)), Try Again with the same key recovers it while the sheet stays open. If the person closes the sheet or the app relaunches first, the challenge shows "The link for this challenge isn’t on this iPhone.", and a new attempt to that person gets `pending_invitation_exists` until it expires (24 h). Claude's call: keep save-after-success. Writing before the call needs a second lookup path (the competition id isn't known yet), and replaying a request that never landed can create a challenge when the pending one lapses at the server between publication and replay (the RPC expires lapsed rows, then inserts; bind_invitation_recipients.sql:183-190). PR 7 narrows the gap without changing create (a pending conflict stays 409): Cancel Challenge lets the sender withdraw the challenge and send again, and in-app delivery means the recipient doesn't need the link. A server re-share is built only if the owner asks for it (§10 Q7).
- **Claude's call: build the replay store whether or not PR 7 ships this round.** It lets PR 6 merge without waiting for PR 7's Staging and production promotion. Under PR 7's default (no server re-share, §10 Q7) the store stays. Only if the owner picks the re-share does PR 7 point `coordinator.restoreInvite` at `remoteAPI.shareInvite(id)` and delete `RemoteInviteRequestStore`; the reducer, link states and views stay as PR 6 builds them.

**H. Views.**
- **`CreateCompetitionView.swift`.** Rewrite the inputs at :6-13:
  - `status: CompetitionFeature.ChallengeSheetStatus`, `timeZoneIdentifier`, `evaluatedAt: Date`, `recipientCode` binding, `recipient`, `recipientStatus`, `senderName: String?`, `findRecipient`, `create`, `openChallenge: (CompetitionID) -> Void`.
  - :28-33 becomes the time-zone `Text`.
  - :108-117: drop `axis: .vertical` and `.lineLimit(3, reservesSpace: true)`. Add `.submitLabel(.search)`, `.onSubmit { if canFind { find() } }`, and `.disabled(isLocked)`.
  - :118-124: `.disabled(!canFind)`.
  - :125-131: progress, or the error `Text`.
  - :145-149: the title follows `.sent`.
  - :151-230: switch on the new status.
  - Announcements: `.onChange(of: recipientStatus)`, `.onChange(of: recipient?.id)` and `.onChange(of: status)` call `AccessibilityNotification.Announcement(text).post()` (iOS 17+).
  - New file-level functions:
    - `func competitionTimeZoneText(_ identifier: String, locale: Locale = .current) -> String`: `TimeZone(identifier:)?.localizedName(for: .generic, locale:) ?? identifier`.
    - `func competitionShareMessage(senderName: String?, link: CompetitionInviteShareLink) -> String`
    - `func competitionRecipientErrorText(_ status: CompetitionFeature.InviteRecipientStatus) -> String?`
    - `func competitionInviteFailureText(_ failure: CompetitionFeature.InviteCreationFailure, opponentName: String) -> String`, which holds the `#if DEBUG || HEALTHCOMP_STAGING` switch for `.unavailable`.
- **`CompetitionSharingView.swift`.**
  - :9-10: replace `inviteCreationStatus` and `createdInviteLink` with `challengeStatus: CompetitionFeature.ChallengeSheetStatus`, `senderName: String?` and `dismissChallenge: () -> Void`.
  - :66-77: `.sheet(isPresented: $isChallengePresented, onDismiss: dismissChallenge)`, passing `evaluatedAt: publication.evaluatedAt` and `openChallenge: { isChallengePresented = false; selectCompetition($0) }`.
- **`MainTabView.swift`.**
  - :61-94 passes `challengeStatus: store.competition.challengeSheetStatus`, `senderName: store.competition.ownProfile?.displayName` and `dismissChallenge: { store.send(.competition(.challengeSheetDismissed)) }`. This deletes the slot ternaries at :63-70.
  - :194-200 passes `link: store.competition.inviteLinks[id]`.
  - :210-226 passes `rematch: store.competition.rematchState(for: competition)` and `openCompetition: { store.send(.pathChanged(store.path + [$0])) }`. This deletes :214-221.
- **`CompetitionInviteView.swift`.**
  - Add `let link: CompetitionFeature.InviteLinkState?` (:4-8).
  - :175-189: the remote outgoing title and body come from the table in 2. The body takes `.accessibilityIdentifier("competition.invite.expiry")`.
  - :77-112: remove the remote outgoing hourglass.
  - Add `.safeAreaInset(edge: .bottom)` holding `shareControl` (PR 7 adds its Cancel button there). At accessibility sizes it is placed after the rules card instead.
  - Add `.task(id: competition.id) { if isRemoteOutgoing && link == nil { send(.inviteLinkNeeded(competition.id)) } }`.
- **`CompetitionResultView.swift`.**
  - :8-9: replace the two inputs with `rematch: CompetitionRematchState` and `openCompetition: (CompetitionID) -> Void`.
  - :461-474 and :512-569: replace them with one `rematchControl` switch per 3.
  - Add `.task(id:)` on the sent row: if remote and `link == nil`, send `.inviteLinkNeeded(challengeID)`.
  - :75-83: pin only when `!dynamicTypeSize.isAccessibilitySize`.
- **Claim:**
  - `MainTabFeature.InviteClaimStatus` (MainTabFeature.swift:11-19) adds `case ownChallenge`.
  - :365: add `case .failure(.forbidden):` with the same body as `.inviteUnavailable`, but setting `.ownChallenge`.
  - Add `.ownChallenge` beside `.unavailable` in the switches at MainTabFeature.swift:409 and :433, MainTabView.swift:175, and ClaimCompetitionView.swift:60-71, :104-157 and :178-209.
  - SupabaseCompetitionRemoteAPI.swift:444: before the claim 4xx catch-all, add `if context == .claimInvite, !identifiers.isDisjoint(with: ["self_claim_forbidden", "cannot_claim_own_invite"]) { return .forbidden }`.
- **`MultiUserCompetitionTestLabView.swift:153-322` (DEBUG lab).** Swap the `@State` fakes for the new types:
  - `challengeStatus: ChallengeSheetStatus`. `createInvite` sets `.sent(challengeID: pendingID, challenge: nil, link: shareLink(0x51))`.
  - `rematchState: CompetitionRematchState`, which `.rematchTapped` sets to `.sent(challengeID: pendingID, expiresAt: nil, link: .ready(shareLink(0x52), minimumRevision: 0))`.
  - The pending Sam `CompetitionInviteView` gets `link: .ready(shareLink(0x53), minimumRevision: 0)` and `expiresAt` = createdAt + 24 h (:568-573).
  - `findRecipient`: a malformed code gives `.invalidCode`; `a1000000-0000-4000-8000-000000000099` gives `.ownCode`; Sam's code gives Sam; anything else gives `.notFound`.
  - `openCompetition: { path.append($0) }`.
  - PR 4's `challengeAgain` closure (PR 4) also sets `challengeStatus = .ready`.

#### Server changes
None, and PR 6 does not wait for PR 7: every file in this section merges as soon as PR 6 is reviewed. It relies only on the shipped `create-competition-invite` idempotent replay and the existing `self_claim_forbidden` code. Already-installed app versions are unaffected.
- What PR 7 later changes on top of PR 6 (owned and specified by PR 7): Cancel Challenge on this screen, in-app delivery of the challenge, and, only if the owner picks it (§10 Q7), `restoreInvite` backed by `shareInvite`. Create keeps returning 409 on a pending conflict.

#### Tests
**RemoteCompetitionFeatureTests.swift.** Rewrite the existing invite tests to the new state, keeping their intent:
- :14 `testInvitationRequiresExplicitAccountResolutionAndClearsSelectionWhenCodeChanges`
- :41 `testInvalidAccountCodeNeverCreatesAnInvitation`: now `.invalidCode`
- :52, :73, :101, :122, :152, :172, :215, :293, :361 (`.failed(.unavailable)`, 0 requests), :399, :469

New tests:
- `testLinkSurvivesSheetDismissAndCodeEdits`: success sets `inviteLinks[id] = .ready`. Then `.challengeSheetDismissed` clears the code, person and `.sheet` slot, and the link stays.
- `testFindAccountAndCodeEditsIgnoredOnceSent`: with the slot `.sent`, `.findInviteRecipientTapped` and `.inviteRecipientCodeChanged` change nothing.
- `testOwnCodeRejectedWithoutLookup`: with `ownProfile.id` typed in uppercase, the result is `.ownCode` and the resolve call count is 0.
- `testLookupFailureMapping`: `recipientUnavailable` → `.notFound`; `retryableTransport` → `.connectionFailed`.
- `testResponseAfterSheetDismissStillKeepsLink`: dismiss during `.creating`; the success still writes `inviteLinks` and leaves no slot.
- `testRematchesKeepSeparateSlotsAndLinks`: parents A and B; rematch both. Both links are present, and the sheet code and person are untouched.
- `testRematchAccountGoneShowsRecipientGone`: `.recipientUnavailable` → `rematchState == .failed(.recipientGone)`.
- `testChallengeAgainPrefillsSheet` (rewrites PR 4's challenge-again test): with a `.creating` sheet slot, `.challengeSheetDismissed` then `.challengeAgainTapped(closedID)` gives no sheet slot, the person and code set, `.idle`, and `challengeSheetStatus == .ready`. A `remote-profile:v1:pending` identity changes nothing.
- `testRematchStateFollowsChild`, with one publication per case:
  - pending child → `.sent(expiresAt:)`
  - scheduled child → `.next`
  - `.expired` child → `.available`
  - `.declined` child → `.available`
  - a non-rematch pending challenge to the same person → `.alreadyChallenged`
  - a local in-flight command → `.sending`
- `testChallengeSheetStatusOrdering`: covers creating, sent, alreadyChallenged, failed and ready.
- `testPendingConflictRefreshesAndOffersExistingChallenge`: `.pendingInvitationExists` → `.failed(.alreadyPending)` plus a `reconcileAll(.pullToRefresh)` call. A later publication with the pending challenge gives `.alreadyChallenged`.
- `testDivergentDuplicateRotatesKey`: the retry uses a new key.
- `testInviteLinkRestore`, in three branches:
  - success → `.loading` then `.ready(link, minimumRevision:)`
  - `.notFound` → `.notOnThisPhone`
  - `.retryableTransport` → `.failed`, and a second `.inviteLinkNeeded` retries
- `testLateRestoreAfterStopIsDropped`.
- `testPruneRemovesLinksAndRematchSentSlots`: covers accepted, expired, and missing with a clean publication.
- `testPruneKeepsLinksOnIncompleteDiscovery`: the three blocking issues exercised at :127.
- `XCTAssertFalse(String(reflecting: store.state).contains(rawToken))` is kept in the create and restore tests.

**RemoteCompetitionClientTests.swift** (harness from :2363):
- `testCreatedInviteRequestIsReplayedToRestoreLink`:
  1. Mount, then `createInvite(request)`.
  2. Build a new client on the same `fixture.paths`, mount it, and call `restoreInvite(id)`.
  3. The stub sees a second request equal to the first (same idempotency key), and the outcome's token matches.
- `testRestoreInviteWithoutStoredRequestThrowsNotFound`.
- `testInviteRequestStoreDropsEntriesAfter25Hours`: at the store level, with an injected `now`.
- `testRemotePresentationCarriesRematchParentID`: a descriptor with `rematchParentID` set (adapt the :651 fixture).

**Other unit tests:**
- **CompetitionFeatureTests.swift:241:** in `testAcceleratedLifecyclePublishesCanonicalTimelineAndJournal`, assert `newPending.rematchParentID == sourceID`.
- **CompetitionPresentationTests.swift:**
  - `testTimeZoneTextUsesGenericName`: en_US America/Los_Angeles == "Days run midnight to midnight, Pacific Time."; an unknown identifier is echoed back.
  - `testShareMessageCarriesSenderAndLink`: the exact string, plus the nil-sender fallback.
  - `testRecipientAndFailureCopy`: every `InviteRecipientStatus` and `InviteCreationFailure` string. The `.unavailable` test asserts the Debug string.
- **SupabaseCompetitionRemoteAPITests.swift:548** `testClaimFailuresRemainPrivacyCollapsed`: move the `(403, "self_claim_forbidden")` case into a new `testOwnClaimMapsToForbidden`. The other three stay `.inviteUnavailable`.
- **MainTabFeatureTests:** `testOwnClaimShowsOwnChallenge`: `.failure(.forbidden)` → `.ownChallenge`, the route is consumed, and `.dismissClaimStatus` → `.idle`.
- **AppFeatureTests:** none. PR 4 owns the `ownProfile` expectations and `testRenameUpdatesCompetitionOwnProfile`.

**UI tests: MultiUserCompetitionUITests.swift**
- :16 `testCreatingInvitationRequiresConfirmingAnExistingAccount`: after create, assert that
  - `competition.create.find-recipient` is not enabled
  - the code field is not enabled
  - the static text "Challenge sent" exists
- New `testChallengeSheetReopensEmpty`: create, close and reopen. `competition.create.recipient-name` is absent, the field's value is empty, and `competition.create.button` is disabled.
- New `testAccountCodeErrorsAndReturnKey`:
  - type "abc\n": `competition.create.recipient-error` reads "That isn’t a full account code. Ask them to share it again."
  - clear, then type "a1000000-0000-4000-8000-000000000099\n": "That’s your own code. Ask them for theirs."
  - clear, then type Sam's code plus "\n": `competition.create.recipient-name` appears (Return = Find, no Find tap).
- :115 `testCreateRemoteUpdatesHistoryAnonymizationRematchAndArchive`:
  - :126: `app.staticTexts["competition.create.time-zone"].label == "Days run midnight to midnight, Pacific Time."`
  - after the rematch tap, `competition.rematch.sent` exists and its label contains "Rematch sent", plus `competition.rematch.share`.
- :316 `testRemoteInvitationDisclosesSharedDerivedActivity`:
  - "Waiting for Sam to accept" → `staticTexts["Waiting for Sam"]`
  - `competition.invite.share` exists
  - the `competition.invite.expiry` label begins with "Expires "
  - PR 1 already moves the nav bar to "Sam".
- :36 and :51 copy tests: unchanged identifiers. They still expect "Complete invitation link", since the payload is a single string containing the link.
- :641 `testRemoteCompetitionAppearanceAndTypeSizeMatrix`: `competition.rematch.create` is kept.

**UI tests: LocalCompetitionLifecycleUITests.swift:115-123**
- Use `app.buttons["competition.rematch.create"]` with label "Rematch Alex", and replace `doubleTap()` with `tap()`. The second tap could otherwise open the new row; the double-submit guard stays covered by `testPerIDCommandGuardSuppressesDoubleTapUntilCommandFinishes`.
- Assert that `competition.rematch.sent` appears with a label containing "Rematch ready", then go back to Home.

**Accessibility identifiers**
- **Added:** competition.create.time-zone, competition.create.recipient-error, competition.create.send-error, competition.create.open-existing, competition.invite.share, competition.invite.share-retry, competition.invite.link-missing, competition.invite.expiry, competition.rematch.sent, competition.rematch.next, competition.rematch.open-existing, competition.rematch.error, competition.rematch.share-retry.
- **Reused on new elements:** competition.rematch.create (now also on the local button), competition.create.already-pending, competition.create.configuration-error.
- **Renamed or removed:** none.

#### Risks and sequencing
- **PR 1 first.**
  - PR 6 builds on PR 1's nav titles, glossary and helpers (`competitionMomentText`, `weekdayText(CompetitionDay)`, `competitionScheduleDateRangeText(_:now:locale:)`, `competitionStatusText(_:style:)`).
  - PR 6 overwrites these PR 1 strings:
    - CreateCompetitionView :28/:32 (time zone), :200 (retryable) and :218 (already pending)
    - CompetitionResultView :516, :525, :538 and :565
    - CompetitionInviteView's outgoing title and body (:187, :318)
  - Keep everything else of PR 1.
- **PR 4 before PR 6 (Claude's call, following the PR numbering and PR 4).** PR 6 relies on PR 4 for:
  - the lapsed-pending → `.expired` projection and the 24 h closed retention (no expired case on CompetitionInviteView, no expiry check in `pendingOutgoingChallenge`, closed children ignored by `rematchState`)
  - the `direction:` payload on `.declined`/`.expired` (matched without bindings)
  - `challengeAgainTapped`, which PR 6 rewrites, and PR 4's closed view, which PR 6 leaves alone (`competition.closed` kept)
  - If PR 6 ever had to land first, it would need the expiry checks back and the "Challenge expired" body; that is not planned.
- **PR 7 after PR 6.** PR 7 builds Cancel Challenge, server re-share and its claim sheet on PR 6's outgoing screen, link states and claim statuses. PR 7's preview path reuses PR 6's `.ownChallenge` copy; there is no second "That’s your challenge" message.
- **Shared regions.**
  - PR 3 also edits CompetitionResultView. PR 6 owns only :8-9, :75-83 and :461-569; rebase onto whichever lands first.
  - PR 4 rewrites CompetitionSharingView. PR 6 touches only the props (:9-15) and the `.sheet` (:66-77).
  - PR 2 edits `RemoteCompetitionProjector.presentation`, where PR 6 adds one argument.
  - PR 4 owns the avatar and `ownProfile`. PR 8 edits AppFeature elsewhere.
  - Every PR touching MultiUserCompetitionTestLabView conflicts there.
- **PR 7 push on create.** PR 7 enqueues `challenge_received` after the insert, and the RPC's idempotent-retry branch returns before it, so PR 6's replay never re-notifies the recipient (PR 7 Server §1.13).
- **Until PR 7 is in production,** a challenge whose link isn't on this iPhone can only expire (24 h, unchanged from today). That includes the lost-response case in Design G.
- **Challenges created before this PR** have no stored request and show "The link for this challenge isn’t on this iPhone." until they expire. That is at most 24 hours after rollout.
- **Opening a match from the + sheet.** Navigating while the sheet is dismissing works on iOS 18. If a push is ever dropped, the fallback is to navigate in `onDismiss` through a pending id.
- **Project files.** No new Swift files, so project.pbxproj is unchanged.

#### Open questions
Moved to §10: Q5 (should a claim on the wrong account say so). Default: no; nothing is built.

### PR 7 — Challenges, server side

#### Scope
- **f-claim**: the claim sheet shows a server preview: who sent the challenge, the start day, the time zone and when it expires. A second link is queued and never replaces the first. Decline is real, confirmed and reaches the sender. Not Now and swiping down only dismiss the sheet. The sheet uses the shared rules card.
- **f-uuid**: Account shows "Your challenge link" (Show Code / Share Link) in place of the raw account UUID. Opening someone's link shows "Challenge Maya?". A bound challenge arrives in the recipient's app (an incoming row on Home plus a push), so nothing has to be sent back.
- **f-lostlink (server part)**: Cancel Challenge. Share Link Again and the link cache are PR 6's (local replay, PR 6 Design G). With in-app delivery the link is only a fallback, so the server re-share is not built by default (§10 Q7).
- **f-rematch (server part)**: creating or accepting a challenge is blocked while a scheduled or live match with that person exists. Before this PR, only pending invitations were checked (`20261019001800_bind_invitation_recipients.sql:186-190`).
- **Polish "Match menu"**: Cancel Match for a scheduled match that hasn't started, confirmed. (Concede is out of scope; that is Claude's call, already made.)
- **Compatibility**: installed 1.0.2 builds keep working, or fail with a message they already show. This includes a latent listing bug fixed along the way (see Server changes §1.9).

Everything here needs the server, so the app wiring for these features lives in this PR too. Whether the server work ships this round or in a follow-up is still the owner's call (§10 Q1). Until it ships, the app parts of this PR can't merge (Risks §1).

**Baseline.** This PR is written against PR 1, PR 4 and PR 6 as specified, not against main. Where it names a type or action from those PRs (`InviteSlot`, `inviteCreations`, `inviteLinks`, `InviteLinkState`, `ChallengeSheetStatus`, `CompetitionRematchState`, `InviteCreationFailure`, `ownProfile`, `.ownChallenge`, `challengeAgainTapped`, PR 4's closed row and `dismissedChallengeIDs`), it means their spec. Line numbers marked "main" point at today's code and will have shifted after those PRs; edit the named function, not the line.

#### Behavior

Terms in code: an **invite link** is one challenge's single-use token link (`/invite/<43 chars>`, the existing `CompetitionInviteShareLink`). A **challenge link** is a person's reusable link (`/c/<22 chars>`, new `CompetitionChallengeLinkCode`).

##### 1. Claim sheet (f-claim), recipient opened an invite link
Sheet: `.large` detent, drag indicator, inline nav title "Challenge" (PR 1).

| Status | Emblem / title / message | Controls |
|---|---|---|
| `.loadingPreview` | spinner · "Opening challenge…" | none. Swipe = Not Now |
| `.ready` | face-off (`CompetitionInvitationFaceOff`, "YOU" / "NAREN") · title **"Naren challenged you"** · line **"Starts Sun, Nov 1 · Pacific Time"** · line **"Answer by Sat 2:14 PM"** · shared rules card (PR 3, with sender name) | **Accept** (Primary) · **Not Now** (Secondary) · **Decline** (quiet text button) · caption **"Naren is told if you decline."** |
| `.declining` | same as ready | Accept and Not Now disabled. Decline is replaced by a spinner and "Declining…" |
| `.claiming` / `.waitingForCompetition` / `.confirmationTimedOut` | unchanged (PR 1 copy) | unchanged |
| `.unavailable` | unchanged: "Challenge unavailable" / "This link may be expired, already used, or no longer valid. Ask the sender for a new challenge." Also used for a live link opened by the wrong account (§10 Q5) | Done |
| `.ownChallenge` (PR 6 §4) | PR 6's copy: "That’s your challenge" / "You sent this link. Only the person you challenged can accept it." Now also reached from the preview | Done |
| `.activeMatchExists` (new) | "You’re already in a match" / "You can accept a new challenge from this person after your current match ends." | Done |
| `.retryable` | unchanged (PR 1 copy) | Try Again (Primary) · Not Now (Secondary). "Decline Challenge" is removed here |

- **Start line**: `"Starts \(competitionDayText(startDay, now: now, locale: locale)) · \(competitionTimeZoneText(preview.timeZoneIdentifier, locale: locale))"`. `competitionDayText` is PR 1's `CompetitionDay` variant; `competitionTimeZoneText` is PR 6's helper (`TimeZone.localizedName(for: .generic, locale:)` with the identifier as fallback).
  - `startDay = try CompetitionCalendar(timeZoneIdentifier: preview.timeZoneIdentifier).startDay(afterAcceptanceAt: now)`. This is the same rule the server freezes at accept time.
  - The zone always shows here, even when it matches the phone, because the sender's calendar defines the week.
  - Deviation from the mockup: no "tomorrow". PR 1's day style has no relative words.
- **Expiry line**: `"Answer by \(competitionMomentText(preview.expiresAt, now: now, locale: locale))"`. Here `now` is the reducer's injected `Date` at preview time, stored on the preview.
- **Decline flow**: tapping Decline opens `.confirmationDialog("Decline challenge from Naren?")`. Its message is "Naren will see that you declined." The buttons are "Decline Challenge" (destructive) and "Keep Challenge" (cancel), matching PR 1's in-app wording.
  - Confirm → `.declining`.
  - Success → the sheet closes. The sender gets a push and PR 4's closed row (§4).
  - Failure → back to `.ready` with the caption "Couldn’t decline. Check your connection and try again."
  - If the challenge stopped being pending meanwhile (cancelled or expired), the server reports it unavailable. The client treats that as done and closes the sheet.
- **Not Now** and **swipe down** in `.ready`, `.loadingPreview` or `.retryable` forget the link on this phone. Nothing is sent. The challenge is still on Home under Needs you (§3), so nothing is lost. Swiping is disabled while `.claiming`, `.waitingForCompetition` or `.declining`.
- **Second link while a sheet is up**:
  - A different token is queued; only the newest queued link is kept. The current sheet adds the caption "Another challenge link is waiting."
  - The queued link opens when the current flow ends: after accepting and navigating, after declining, after Not Now, or after dismissing an error.
  - The same token again is ignored.
- **Already accepted by me** (preview state `accepted`, e.g. the link was tapped twice): no sheet. Navigate to the match, or wait for it as today (`waitingForCompetition`).
- **Long names** wrap (`fixedSize(horizontal: false, vertical: true)`). At accessibility sizes the controls scroll with the content instead of being pinned (same `pinsControl` pattern as `CreateCompetitionView.swift:22`, main).
- **VoiceOver**:
  - The title is a header. The face-off stays hidden.
  - The start and expiry lines combine into one element: "Starts Sunday, November 1, Pacific Time. Answer by Saturday 2:14 PM." Use full date and time styles in the a11y label.
  - Button labels: Accept → "Accept Naren’s challenge". Not Now → "Not now", hint "Keeps the challenge on Home". Decline → "Decline Naren’s challenge", hint "Naren is told".
- 0–0, ties and Day 1–7 don't apply (no scores yet). Repeat opponents: each challenge has its own preview, and the server blocks overlap (§6).

##### 2. Challenge link (f-uuid)
**Account → new section, header `SectionLabel("YOUR CHALLENGE LINK")`**, placed directly under PROFILE. It replaces the account-code block at `AccountSettingsView.swift:114-131` (main).
- URL text without the scheme, e.g. `healthcomp.app/c/Xb3kP9qL2mN8vR4tY6wZ1a`.
  - Style: `.callout.monospaced()`, wraps, selectable.
  - VoiceOver reads "Your challenge link", not the code.
- Buttons in an `HStack`, switching to a `VStack` at accessibility sizes:
  - **Show Code**: `SecondaryButtonStyle`, `qrcode` symbol.
  - **Share Link**: `PrimaryButtonStyle`, `square.and.arrow.up`. It is `ShareLink(item: url, subject: Text("My HealthComp challenge link"), message: Text("Challenge me to a week of rings on HealthComp."))`.
- Caption: **"Anyone with this link can challenge you. You still choose whether to accept."** That is the whole promise: the link can't be reset and a stranger who has it can't be muted (§10 Q6).
- Loading: `ProgressView("Loading your link…")`. Failure: "Couldn’t load your link." plus a **Try Again** button.
- **Show Code** opens a sheet (`[.medium, .large]`) with inline title "Your Challenge Code".
  - QR of the https URL, black modules on a white quiet zone in both modes, inside `themePanel`. Scanners need dark-on-light, so this is the one place the image isn't drawn with Theme tokens.
  - Size: `min(availableWidth - 64, 320)` square.
  - Caption: "They can scan this with the iPhone Camera." Toolbar: Done.
  - VoiceOver: "QR code for your challenge link".

**Opening someone's link.** `https://healthcomp.app/c/<code>` opens the app directly as a universal link (Claude's call: `/c/*` is added to the AASA file, Web below). Without the app, or before Apple's CDN has the new AASA, it lands on `web/challenge.html` → "Open in HealthComp" → `healthcomp://challenge/<code>`. Staging uses `staging.healthcomp.app` / `healthcomp-staging`. Both URL forms parse to the same route.
- The "Challenge Maya?" sheet (`.large`), with a header row like `CreateCompetitionView.swift:69-98` (main) and a close ✕.
  - Avatar: an initial circle "M" in `Theme.ink` on `Theme.control`.
  - Name **"Maya"** (headline, wraps), then **"From Maya’s challenge link"**.
  - The shared rules card (PR 3) with no schedule yet, so its first row reads "Day 1 is the day after the challenge is accepted."
  - **Send Challenge** (Primary), with the caption **"Maya gets it in HealthComp. Nothing to send back."**
  - Title text: "Challenge Maya?".
- States while resolving the code:
  - Resolving: `ProgressView("Opening link…")`.
  - Unknown, inactive or malformed code: "Link not found" / "This challenge link isn’t active. Ask for a new one." · Done.
  - Own link: "That’s your link" / "Share it with someone so they can challenge you." · Done.
  - Offline: "Couldn’t connect" / "Check your connection and try again." · Try Again.
- Sending uses PR 6's `.sheet` slot, so the control follows `challengeSheetStatus`:
  - `.creating`: the button becomes a spinner and "Sending…".
  - `.sent(id, …)`: the sheet closes and the challenge screen (PR 6 §2, plus Cancel from §5) is pushed.
  - `.alreadyChallenged(c)` (PR 6): "You already challenged Maya." + **Open Challenge**.
  - `.challengedYou(c)` (new, §6): "Maya already challenged you." + **Review Challenge**, which opens c.
  - `.inMatch(c)` (new, §6): "You already have a match with Maya." + **View Match**.
  - `.failed(…)`: PR 6's failure copy, plus `.failed(.conflict)` (§6).

**+ sheet** (`CreateCompetitionView`), recipient section as PR 6 left it, with these changes:
- Header: `SectionLabel("THEIR CHALLENGE LINK")`.
- Helper text: "Paste the challenge link they shared. Or send them yours so they can challenge you."
- The field placeholder is "Challenge link". It accepts a challenge link URL (https or custom scheme), a bare 22-character code, or a legacy 36-character account code from 1.0.2 users.
- The "Find Account" button becomes "Find".
- New **Share Your Link** button (`SecondaryButtonStyle`) under the field. It shares your own challenge link and is hidden until that link has loaded.
- PR 6's lookup copy changes for the new input:
  - Not a link, a 22-character code or a UUID → "That isn’t a full challenge link. Ask them to share it again." (`.invalidCode`)
  - Your own link (server `own_challenge_link`) or own UUID (local) → "That’s your own link. Ask them for theirs." (`.ownCode`)
  - The not-found and network rows keep PR 6's wording with "code" → "link".
- PR 6's pinned control gains the `.challengedYou` / `.inMatch` rows (same copy as the link sheet) and `.failed(.conflict)`.
- The sent state stays as PR 6 built it (Share Challenge in the sheet). Claude's call: its caption gains a first sentence, "{Name} gets it in HealthComp.", so the sender knows the share is optional.

##### 3. Bound challenge delivered in-app (f-uuid)
- The recipient's Home lists each pending, unexpired challenge addressed to them as an incoming challenge presentation: `.pending(direction: .incoming, createdAt:, expiresAt:)`, with the sender's name and identity. PR 4 groups it under **Needs you**, soonest-expiring first. PR 4 owns the row ("Challenge received · Expires …" with a Review capsule).
- Tapping it opens `CompetitionInviteView` (incoming). Remote now shows the same **Accept** / **Decline** buttons as the fixture, replacing "Open the challenge link to review and accept" at `CompetitionInviteView.swift:80-89` (main).
  - Body adds: "Answer by \(competitionMomentText(expiresAt, now: competition.evaluatedAt)). Day 1 is the day after you accept."
  - The remote decline alert message is "\(name) will see that you declined." (PR 1's title and buttons).
  - On accept, the same screen becomes the scheduled match. The destination switches on lifecycle at `MainTabView.swift:192` (main).
  - On failure: inline label "Couldn’t complete that. Check your connection and try again." under the buttons.
  - Accepting here needs no token. Claude's call: the bound recipient's signed-in account is the identity check; the token only ever carried the challenge to them. The PR amends the contract doc to match (Design, Docs).
- **Push (server)**: the copy depends on §10 Q3. Default (generic): title **"New challenge"**, body **"Open HealthComp to accept or decline."** Tapping it routes to the challenge, using the existing `competition` route kind. It is suppressed if the recipient has muted the sender (only possible for someone they've played before). It is discarded if the challenge stops being pending before delivery.
- No local expiry reminder for remote incoming challenges. Claude's call: incoming challenges have no local journal, so there is no schedule or emission history to feed PR 5's planner; the push at creation and the Needs-you row (which shows the expiry) cover it. PR 5's incoming reminder row stays fixture-only. Add it if testers miss challenges.
- The row appears live: realtime wakeups now also reach the pending invitee.
- Multiple incoming challenges from different people each get their own row. A sender can have only one pending challenge to you, and reciprocal challenges are blocked (§6), so one person never shows twice.

##### 4. Sender learns of a decline; the other person learns of a cancel
- **Push to the sender on decline**: default (generic) title **"Challenge declined"**, no body. Named alternative: "Maya declined your challenge" (§10 Q3).
- **Push to the other person on Cancel Match**: default (generic) title **"Match cancelled"**, no body. Named alternative: "Naren cancelled your match".
- **Home row**: PR 4's closed row, for 24 hours after it happened, in **Up next** (PR 4's grouping), dismissed with PR 4's ✕ and `dismissedChallengeIDs`.
  - A decline arrives as `.declined(at: closedAt, direction: .outgoing)`, which PR 4 already renders (with its "Challenge {Name} Again").
  - A cancelled match arrives as the new `.cancelled(at: closedAt)`. PR 4's grouping treats it like a closed outgoing challenge (Up next, dismissable). Row line: PR 1's status text "Match cancelled" plus `competitionMomentText(closedAt, now:)`.
  - Only the person who did not act sees it. Withdrawing your own challenge (Cancel Challenge) shows nothing to the recipient: their incoming row just disappears.
- A push tap that lands on a closed item shows PR 4's closed view. This PR adds the cancelled case: `ContentUnavailableView("Match cancelled", systemImage: "calendar.badge.minus", description: Text("\(name) cancelled it before it started. Nothing was recorded."))`.

##### 5. Outgoing challenge screen (f-lostlink), remote
PR 6 §2 owns this screen: "Waiting for {Name}", the expiry body (`competition.invite.expiry`) and the pinned Share Link Again with its link states (`competition.invite.share`, `.share-retry`, `.link-missing`). This PR adds only:
- **Cancel Challenge** (quiet destructive text, 44 pt, `competition.invite.cancel`), under the share control in PR 6's `safeAreaInset` (after the rules card at accessibility sizes).
  - It opens a `confirmationDialog`: "Cancel your challenge to Sam?", message "Sam won’t be able to accept it." Buttons: "Cancel Challenge" (destructive) / "Keep Challenge". Claude's call: this wording replaces PR 6's draft "The link will stop working.", because the challenge now also reaches Sam in the app, not only through the link.
  - On success the row leaves Home and the screen pops (existing path pruning).
  - On failure: "Couldn’t cancel the challenge. Check your connection and try again." (`competition.invite.error`).
- PR 6's notOnThisPhone caption becomes "The link isn’t on this iPhone. Sam can still accept it in HealthComp." Cancel Challenge shows here too, so a challenge without a link is no longer a dead end.

##### 6. Overlap rules (f-rematch server part)
- **Blocked**: a create, or an accept by link or in-app, while the two people share a match whose week hasn't ended. Today that means server lifecycle `scheduled` and the sender-zone local date ≤ `start_day + 6`.
  - After Day 7 (while tallying) a new challenge is allowed.
  - The server lifecycle stays `scheduled` until finalization, so the rule can't rely on lifecycle alone.
- **Pending to the same person**: unchanged, create returns 409 `pending_invitation_exists`. The new app handles it with PR 6's `.alreadyChallenged` → Open Challenge. 1.0.2 keeps its current message. (Claude's call: no "return the existing link" branch in create; see §10 Q7.)
- **They already challenged you**: create fails with `incoming_challenge_exists`.
- **App side, derived first, server as backstop.** Like PR 6's `.alreadyChallenged`, the conflicts are derived from the dashboard before any tap, so the request is normally never sent:
  - `.challengedYou(c)`: a `.pending(.incoming, …)` presentation with the chosen person's `opponentIdentity`.
  - `.inMatch(c)`: a `.scheduled`, `.active` or `.endsToday` presentation with that identity, earliest start first (tallying is allowed, matching the server).
  - A race (the server knows before the dashboard does) returns `incoming_challenge_exists` / `active_match_exists` → `InviteCreationFailure.conflict` with copy "You already have a challenge or match with {Name}.", and the reducer reconciles; once the dashboard catches up, the derived case replaces it.
- **Result screen rematch** (PR 6's `CompetitionRematchState`) gains the same two derived states, checked after PR 6's `.next(child)` and `.alreadyChallenged`:
  - `.inMatch(c)`: "You’re already in a match with Hermes." + **View Match** (`competition.rematch.view-match`).
  - `.challengedYou(c)`: "Hermes already challenged you." + **Review Challenge** (`competition.rematch.review`).
  - `.failed(.conflict)` uses `competition.rematch.error`.

##### 7. Cancel Match (polish)
- In the scheduled match's ••• menu (`CompetitionDetailView.swift:73-97`, main), remote only, lifecycle `.scheduled`: `Button(role: .destructive)` → `Label("Cancel Match", systemImage: "xmark.circle")`, placed last.
- Confirmation: "Cancel your match with Hermes?", message "It hasn’t started yet. Hermes will be told." Buttons: "Cancel Match" (destructive) / "Keep Match".
- On success the match leaves Home and the screen pops. The other person gets the push and the row (§4).
- On failure (including Day 1 having started meanwhile): inline label under PR 3's scheduled summary (`CompetitionScheduledSummary`; PR 3 deletes `scheduledCard`), **"Couldn’t cancel the match. It may have already started."**
- Hidden on live, tallying and finished matches, and in the simulated fixture.

#### Design

No new Swift files. Everything goes into existing files, so `project.pbxproj` doesn't change. New non-Swift files: one migration, one Edge Function (`preview-competition-invite/index.ts` + `index_test.ts`), `web/challenge.html`, and one pgTAP file.

##### Wire and API layer
- **`CompetitionRemoteAPI.swift:3-23`** `CompetitionRemoteFailure` adds `activeMatchExists`, `incomingChallengeExists`, `ownChallengeLink`. (Own invite reuses `.forbidden`, as PR 6 does for claim.)
  - **`CompetitionSyncCoordinator.swift:568`** (exhaustive switch) maps all three to `.operationFailed`.
- **`CompetitionRemoteAPI.swift:25-86`** adds closures. Each default throws `CompetitionRemoteFailure.operationFailed`, like `resolveInviteRecipient`:
  - `listChallenges: () async throws -> CompetitionChallengeList`
  - `previewInvite: (CompetitionInviteClaimRequest) async throws -> CompetitionInvitePreview`
  - `acceptChallenge: (UUID) async throws -> Void`
  - `declineChallenge: (UUID) async throws -> Void`
  - `cancelCompetition: (UUID) async throws -> Void`
  - `loadChallengeLinkCode: () async throws -> CompetitionChallengeLinkCode`
  - `resolveChallengeLink: (CompetitionChallengeLinkCode) async throws -> AuthenticatedProfile`
- **`SupabaseCompetitionRemoteAPI.swift`**, inside `make` (after `:307`, main):
  - `listChallenges`: `.rpc("list_challenges", {})` → `CompetitionWireCodec.decode(CompetitionChallengeList.self, contract: .challengeList)`.
  - `previewInvite`: `.function("preview-competition-invite", body: encodeWire(request, .inviteClaimRequest))`, `context: .previewInvite` → decode `.invitePreviewResponse`.
  - `acceptChallenge` / `declineChallenge` / `cancelCompetition`: `.rpc("accept_competition_challenge" | "decline_competition_challenge" | "cancel_competition", {"competition_id": id})`. Each returns jsonb `{competition_id}`, the same shape as `archive_competition`, and decodes with `decodeCompetitionIDResponse`: `decodeArchiveResponse` at `:536-547` renamed and used by archive too. It checks that the id matches.
  - `loadChallengeLinkCode`: `.rpc("get_my_challenge_link", {})` → exact keys `["code"]` → `CompetitionChallengeLinkCode(rawValue:)`, otherwise `.serverContractMismatch`.
  - `resolveChallengeLink`: `.rpc("resolve_challenge_link", {"code": raw})` → decode `.profile` (same as `:294-307`).
  - `ErrorContext` (`:333-338`) adds `.previewInvite`.
  - `classify` (`:402-518`) inserts before the claim-context 4xx rule at `:444`:
    - `active_match_exists` → `.activeMatchExists`
    - `incoming_challenge_exists` → `.incomingChallengeExists`
    - `own_challenge_link` → `.ownChallengeLink`
    - PR 6's `self_claim_forbidden` / `cannot_claim_own_invite` → `.forbidden` rule is widened from `context == .claimInvite` to `.claimInvite || .previewInvite`.
  - The existing claim-context 4xx rule is widened the same way and maps the rest to `.inviteUnavailable`. Add `cancel_not_allowed` to the `.forbidden` set at `:506-511`.
- **`CompetitionSyncModels.swift:9-27`** adds contracts `.challengeList` and `.invitePreviewResponse`, wired at `:3140-3180`. New types go next to `CompetitionInvite` (`:1042`):
  ```swift
  struct CompetitionInvitePreview: Equatable, Sendable {
      enum State: String, Equatable, Sendable { case pending, accepted }
      let competitionID: UUID; let state: State
      let sender: CompetitionProfilePresentation       // :705
      let timeZoneIdentifier: String; let expiresAt: Date
  }
  // wire: {"competitionId","state","sender":{"id","displayName"},"timeZoneIdentifier","expiresAt"} exact keys
  struct CompetitionChallengeList: Equatable, Sendable {
      struct Incoming: Equatable, Sendable { let competitionID: UUID; let sender: CompetitionProfilePresentation
          let timeZoneIdentifier: String; let createdAt: Date; let expiresAt: Date }
      struct Closed: Equatable, Sendable { enum Kind: String, Sendable { case declined, cancelled }
          let competitionID: UUID; let kind: Kind; let other: CompetitionProfilePresentation; let closedAt: Date }
      var incoming: [Incoming]; var closed: [Closed]
      static let empty = Self(incoming: [], closed: [])
  }
  // wire: {"incoming":[{"competition_id","sender":{"id","display_name"},"time_zone_identifier","created_at","expires_at"}],
  //        "closed":[{"competition_id","kind","other":{"id","display_name"},"closed_at"}]}  exact keys, ≤50 each
  ```
  Validators: UUIDs via `uuid(...)`, names via `CompetitionWireValue.validPresentationName` (not "Former competitor"), timestamps via `isTimestamp`, tz via `CompetitionDay.timeZone(for:)`, kind enum.
- **`CompetitionNotificationClient.swift:33-54`**: add `struct CompetitionChallengeLinkCode` beside `CompetitionInviteClaimToken`, with the same redacted description. Valid when the raw value matches `^[A-Za-z0-9_-]{22}$`.
- **`CompetitionNotificationClient.swift:113-251`** `CompetitionRoute`:
  - Add `case challengeLink(CompetitionChallengeLinkCode)` and `Kind.challengeLink`.
  - Custom scheme: host `"challenge"`, path = code. https: same host rule as `/invite/`, path prefix `/c/`. Both are live paths (universal link and web fallback).
  - `userInfo` returns `[:]`, like `claimInvite` at `:236-239`.
- **`CompetitionRouting.swift:30-64`**: `CompetitionInviteLinkClient` adds `makeChallengeLink: @Sendable (CompetitionChallengeLinkCode) -> URL?`. Production builds `https://\(host)/c/\(code)`, falling back to `\(customURLScheme)://challenge/\(code)` when the custom-scheme fallback is allowed, mirroring `makeShareLink`. The test default returns nil.

##### Client and projector (`RemoteCompetitionClient.swift`)
- **`CompetitionClient.swift:48-85`** adds closures; defaults go in `init` at `:87-166`:
  - `cancel: (CompetitionID) async -> CompetitionPublication`, default returns an empty publication.
  - `previewInvite: (CompetitionInviteClaimRequest) async throws -> CompetitionInvitePreview`
  - `loadChallengeLinkCode: () async throws -> CompetitionChallengeLinkCode`
  - `resolveChallengeLink: (CompetitionChallengeLinkCode) async throws -> AuthenticatedProfile`
  - Each throwing default throws `.operationFailed`. The local fixture keeps the defaults.
- **`:78-80`** (main): `accept` → `coordinator.acceptChallenge(id)`, `decline` → `coordinator.declineChallenge(id)` (incoming only), new `cancel` → `coordinator.cancel(id)` (outgoing challenge or scheduled match). New closures go next to `createInvite` at `:120-128`. There is no separate `cancelInvite` closure.
- The coordinator copies `archive` (`:749-767`) three times:
  - `acceptChallenge`, `declineChallenge` and `cancel` call the API, then `performReconciliation()`. Errors → `publication(adding: .commandRejected(id))`.
  - Exception: in `declineChallenge`, `.inviteUnavailable` counts as done (reconcile, no issue). The challenge is no longer pending, so there is nothing to decline.
  - `previewInvite`, `loadChallengeLinkCode` and `resolveChallengeLink` copy `resolveInviteRecipient` (`:790-798`).
- PR 6's `RemoteInviteRequestStore` and `coordinator.restoreInvite` stay as PR 6 builds them. PR 6's replay of create hits the RPC's idempotent branch, which never enqueues a push (Server §1.13), so restoring a link never re-notifies the recipient.
- Actor state `private var latestChallenges = CompetitionChallengeList.empty`.
  - In `performReconciliation` (`:637-681`), after `runtime.synchronizeAll()`: `if let list = try? await remoteAPI.listChallenges() { latestChallenges = list }`. On failure the last list is kept; the existing discovery issues already cover being offline.
  - Pass `latestChallenges` into `publish(materializations:profile:issues:knownCompetitionIDs:)` at `:1490`, then into `RemoteCompetitionProjector.dashboard(...)` at `:1587` as `challenges:`.
- **`RemoteCompetitionProjector.dashboard`** (`:1587-1610`) appends, after PR 4's closed-challenge filter:
  - Each `incoming` with `expiresAt > context.instant.wallDate` → `CompetitionPresentation(id: CompetitionID(competitionID), ownerDisplayName: profile.displayName, opponentDisplayName: sender.displayName, opponentIdentity: RemoteCompetitionOpponentIdentity.identity(for: sender.id), lifecycle: .pending(direction: .incoming, createdAt:, expiresAt:), acceptedConfiguration: nil, userPoints: 0, opponentPoints: 0, days: [], currentDayOrdinal: nil, lastRefresh: nil, tally: nil, terminalResult: nil, evaluatedAt: context.instant.wallDate, timeZoneIdentifier: tz)`.
  - Each `closed` with `closedAt > wallDate - 86_400` → the same shape with `lifecycle: .declined(at: closedAt, direction: .outgoing)` or `.cancelled(at: closedAt)`. This is the "materialize closed descriptors" step PR 4 asked for (PR 4).
  - Skip any id already materialized (defensive).
  - `notificationSnapshot` is unchanged, so incoming challenges never schedule local notifications (Claude's call, §3).
- **`LocalCompetitionClient.swift:61-84`** `LocalCompetitionLifecyclePresentation` adds `case cancelled(at: Date)`. Fix every exhaustive switch the compiler flags. Known sites:
  - `CompetitionSharingView.swift:1052`, `:1071`, `:1114` (main): "Cancelled" / non-scored / "cancelled"; `competitionSharingIdentifier` yields `competition.sharing.cancelled.<uuid>`.
  - `CompetitionDetailView.swift:857`: "Cancelled".
  - `MainTabView.swift:192-234` (§4 closed view).
  - `RemoteCompetitionClient.swift:1750-1770` `notificationLifecycle` (map `.cancelled` like `.declined`).
  - PR 1's `competitionStatusText`: row "Match cancelled", card "Cancelled", notification "Match cancelled", timing nil.
  - PR 4's `competitionHomeLayout`: `.cancelled` goes to Up next as a closed row, under the same 24 h and dismissal rules as closed outgoing challenges.
  - PR 6's `rematchState` excludes `.cancelled` children (PR 6 already notes this).

##### Reducers
**`CompetitionFeature.swift`** (PR 6's types)
- `InviteCreationFailure` adds `.conflict`.
- `ChallengeSheetStatus` adds `.challengedYou(LocalCompetitionPresentation)` and `.inMatch(LocalCompetitionPresentation)`. `CompetitionRematchState` adds the same two.
- PR 6's derived extension adds `func incomingChallenge(from opponentIdentity: String)` and `func matchInProgress(with opponentIdentity: String)` (§6 rules, remote only), next to `pendingOutgoingChallenge`.
  - `challengeSheetStatus`: insert after step 3 (`.alreadyChallenged`): incoming → `.challengedYou`, then in progress → `.inMatch`.
  - `rematchState(for:)`: insert after step 5 the same two checks.
- State adds:
  - `challengeLink: URL?`
  - `challengeLinkLoadFailed = false`
- Actions add:
  - `cancelTapped(CompetitionID)`: same command pattern as `archiveTapped` (`:304-316`, main), calling `competitionClient.cancel`.
  - `challengeLinkRequested` → `loadChallengeLinkCode` → `makeChallengeLink` → `challengeLinkResponse(URL?)`. nil sets `challengeLinkLoadFailed`.
  - `challengeRecipientChosen(AuthenticatedProfile)`: the same body as PR 6's `challengeAgainTapped` after its guards (clear the `.sheet` slot, set person, code = their id, `.idle`, cancel lookup).
- `createInviteResponse`: `.incomingChallengeExists` / `.activeMatchExists` → `.failed(.conflict)` and `reconcile(trigger: .pullToRefresh)`, like PR 6's `.alreadyPending` row.
- `findInviteRecipientTapped` (PR 6's version) parses the trimmed input:
  1. `CompetitionRoute(url:)` == `.challengeLink(code)`, or `CompetitionChallengeLinkCode(rawValue:)` → `.lookingUp` → `resolveChallengeLink`.
  2. A non-nil `UUID` → PR 6's path (own id → `.ownCode` locally, otherwise `resolveInviteRecipient`).
  3. Otherwise `.invalidCode`.
  - `inviteRecipientResponse` changes its first payload from `UUID` to the input `String` it resolved; the guard compares it to the current trimmed input (a link code has no id to compare). `.ownChallengeLink` → `.ownCode`. PR 6's other mappings stay.

**`MainTabFeature.swift`** (main line numbers; PR 4 and PR 6 add to the same functions)
- `InviteClaimStatus` (`:11-19`) adds `.loadingPreview`, `.declining`, `.activeMatchExists`. (`.ownChallenge` is PR 6's.)
- State (`:34-71`) adds:
  - `inviteClaimPreview: CompetitionInvitePreview?`
  - `inviteClaimPreviewEvaluatedAt: Date?` (the `now` used for the sheet's dates)
  - `queuedClaimRoute: CompetitionRouteEnvelope?`
  - `claimDeclineFailed = false`
  - `challengeFromLink: ChallengeFromLink?`
  ```swift
  struct ChallengeFromLink: Equatable, Sendable, Identifiable {
      enum Status: Equatable, Sendable { case resolving, ready(AuthenticatedProfile), ownLink, unavailable, retryable }
      let sequence: UInt64; let code: CompetitionChallengeLinkCode; var status: Status
      var id: UInt64 { sequence }
  }
  ```
- Actions (`:79-102`):
  - Rename `declineClaimTapped` → `notNowClaimTapped`, same body as `:312-327`, then `advanceClaimQueue`.
  - Add `claimPreviewResponse(sequence: UInt64, Result<CompetitionInvitePreview, CompetitionRemoteFailure>)`, `declineClaimConfirmed`, `declineClaimFinished(sequence: UInt64, succeeded: Bool)`, `challengeLinkResolved(sequence: UInt64, Result<AuthenticatedProfile, CompetitionRemoteFailure>)`, `sendChallengeFromLinkTapped`, `retryChallengeFromLinkTapped`, `dismissChallengeFromLink`.
  - Add `@Dependency(\.date) var date`.
- `routeReceived` (`:222-238`), claim branch:
  - Ignore if `sequence <= lastHandledClaimRouteSequence` or the token equals `pendingClaimRoute`'s or `queuedClaimRoute`'s.
  - If `inviteClaimStatus != .idle` and `pendingClaimRoute != nil` → `queuedClaimRoute = envelope`, return.
  - Else `pendingClaimRoute = envelope`, then `startPreview(&state)` if `publication != nil`.
  - New `.challengeLink(code)` branch: `challengeFromLink = ChallengeFromLink(sequence:, code:, status: .resolving)`, newest wins. If `publication != nil`, run `resolveChallengeLink`. Otherwise it resolves in the `.competition(.publication)` handler.
- `startPreview` (new private func): if `claimRouteSequenceInFlight == nil` → status `.loadingPreview` → effect `competitionClient.previewInvite(CompetitionInviteClaimRequest(token:))` → `claimPreviewResponse`. Cancellable on `CancelID.inviteClaim`.
- `claimPreviewResponse` (ignored unless `sequence == pendingClaimRoute?.sequence`):
  - `.success(p)`, `p.state == .pending` → store the preview and `date.now`, status `.ready`.
  - `p.state == .accepted` → reuse the `claimInviteResponse(.success(id, expectedRevision: publication.publicationRevision))` body. Navigation follows when the match is visible.
  - `.inviteUnavailable` → `.unavailable`, consume the route.
  - `.forbidden` → `.ownChallenge` (PR 6), `.activeMatchExists` → `.activeMatchExists`; both consume the route.
  - Any other failure → `.retryable`.
- `acceptClaimTapped` (`:306-310`): unchanged (claim by token).
- `retryClaimTapped` (`:393-412`), `.retryable`: if `inviteClaimPreview == nil` → `startPreview`, else `processPendingClaim`.
- `declineClaimConfirmed`: guard `.ready` and a preview → `.declining` → effect `competitionClient.decline(CompetitionID(preview.competitionID))`. `succeeded = !returned.dashboard.issues.contains(.commandRejected(id))`.
- `declineClaimFinished`:
  - Success → consume the route (as in Not Now), clear the preview, `.idle`, `advanceClaimQueue`.
  - Failure → `.ready`, `claimDeclineFailed = true`.
- `advanceClaimQueue` (new): if `queuedClaimRoute` → move it to `pendingClaimRoute` and `startPreview`. Called from Not Now, decline success, `dismissClaimStatus` (`:424-436`, extended to `.activeMatchExists`; PR 6 adds `.ownChallenge`), and after `resolveClaimedNavigation` clears `pendingClaimNavigation` (`:499-511`).
- `.competition(.publication)` (`:438-459`):
  - Replace the `.idle → .ready` promotion at `:454-458` with `startPreview` when `pendingClaimRoute != nil && status == .idle`.
  - Resolve a waiting `challengeFromLink` in `.resolving`.
  - If `challengeFromLink` is `.ready` and `competition.challengeSheetStatus` is `.sent(id, …)` → `challengeFromLink = nil`, `path = [id]`, and send `.competition(.challengeSheetDismissed)` (PR 6) to free the slot. The link remains in `inviteLinks[id]`.
- `challengeLinkResolved`: `.success(p)` → `.ready(p)`; `.ownChallengeLink` → `.ownLink`; `.recipientUnavailable` / `.notFound` → `.unavailable`; other → `.retryable`. Ignored unless `sequence` matches.
- `sendChallengeFromLinkTapped` (guard `.ready(profile)`) → `.concatenate(.send(.competition(.challengeRecipientChosen(profile))), .send(.competition(.createInviteTapped)))`.
- `dismissChallengeFromLink` → `challengeFromLink = nil` and `.send(.competition(.challengeSheetDismissed))`.
- `resolve` (`:477-486`): `.challengeLink` returns `.none`, like `.claimInvite`.
- `stop` (`:209-220`) also clears the preview, the queue and `challengeFromLink`.

##### Views
- **`ClaimCompetitionView.swift`**, rewritten in place:
  - Inputs: `status`, `preview: CompetitionInvitePreview?`, `now: Date`, `hasQueuedChallenge: Bool`, `declineFailed: Bool`, and closures `accept`, `notNow`, `decline` (confirmed), `retry`, `dismiss`.
  - Layout: `ScrollView`, with the controls pinned to the bottom `safeAreaInset` except at accessibility sizes.
  - The privacy card at `:82-100` is deleted in favour of PR 3's shared rules card.
  - `quietButton` (`:163-176`) is kept for Decline.
  - The confirmation lives in view `@State`.
  - `interactiveDismissDisabled` for `.claiming`, `.waitingForCompetition`, `.declining`.
- **`MainTabView.swift`**:
  - `:41-49`: pass the new inputs. `decline` → `.declineClaimConfirmed`, `notNow` → `.notNowClaimTapped`.
  - `:165-184` swipe binding: `.ready` / `.loadingPreview` / `.retryable` → `.notNowClaimTapped`. `.unavailable` / `.confirmationTimedOut` / `.ownChallenge` / `.activeMatchExists` → `.dismissClaimStatus`.
  - Add `.sheet(item:)` on `store.challengeFromLink` → `ChallengeFromLinkView`, passing `status: store.competition.challengeSheetStatus`. Its dismissal sends `.dismissChallengeFromLink`. Its `openCompetition` closes the sheet and appends to the path, like PR 6's `openChallenge`.
  - `:228-234`: the `.cancelled` presentation uses the §4 view inside PR 4's closed view.
  - Pass `cancelMatch` into `CompetitionDetailView` (`:202-207`) when `publication.source == .remoteParticipants`, and `cancelChallenge` into the remote outgoing `CompetitionInviteView`.
- **`CreateCompetitionView.swift`** (PR 6's version):
  - Recipient section per §2. It gains the input `ownChallengeLink: URL?`.
  - The status switch adds `.challengedYou`, `.inMatch` and `.failed(.conflict)`; the buttons reuse PR 6's `openChallenge` closure.
  - **Add `struct ChallengeFromLinkView: View`** in this file (§2). Inputs: `link: MainTabFeature.ChallengeFromLink`, `status: CompetitionFeature.ChallengeSheetStatus`, closures `send`, `retry`, `openCompetition`, `close`.
- **`CompetitionInviteView.swift`** (PR 6's version):
  - Inputs gain `commandFailed: Bool` and `cancelChallenge: (() -> Void)?` (non-nil for remote outgoing).
  - `:77-112` (main): remote incoming → the fixture's `incomingButtons`, wired to `acceptTapped` / `declineTapped`. Remote outgoing → PR 6's share control plus the Cancel button and its confirmation in `@State`.
  - `:27-37`: the alert message depends on source (§3).
  - `:169-189`: the incoming remote body (§3). The outgoing title and body are PR 6's.
- **`CompetitionDetailView.swift`**:
  - Add `var cancelMatch: CompetitionCancelMatch? = nil`, where `struct CompetitionCancelMatch { let isInFlight: Bool; let failed: Bool; let cancel: () -> Void }` is defined in this file.
  - The menu at `:73-97` adds the item and its confirmation when it's non-nil and the lifecycle is `.scheduled`.
  - `failed` comes from `publication.dashboard.issues.contains(.commandRejected(id))`.
- **`CompetitionResultView.swift`** (PR 6's `rematchControl`): add the `.inMatch`, `.challengedYou` and `.failed(.conflict)` rows, using PR 6's `openCompetition`.
- **`AccountSettingsView.swift`**:
  - Replace `var accountCode: UUID?` (`:21`) with `var challengeLink: AccountChallengeLink?`, where `struct AccountChallengeLink { let url: URL?; let failed: Bool; let load: () -> Void }`. nil hides the section.
  - New private `challengeLinkSection` (§2), private `ChallengeLinkCodeView`, and a private `func challengeLinkQRCode(_ url: URL) -> UIImage?`:
    - `CIFilter.qrCodeGenerator()` (CoreImage.CIFilterBuiltins), message = UTF-8 of `absoluteString`, `correctionLevel = "M"`.
    - Scale 10× with `CGAffineTransform`, render through `CIContext().createCGImage`, display with `.interpolation(.none)`.
  - `.task { if challengeLink?.url == nil { challengeLink?.load() } }`.
- **`HealthCompApp.swift`**:
  - Remove the `accountCode` plumbing (`:238`, `:273`, `:286`, `:298`, `:326`).
  - `AccountSheet` builds `AccountChallengeLink(url: mainStore.competition.challengeLink, failed: mainStore.competition.challengeLinkLoadFailed, load: { mainStore.send(.competition(.challengeLinkRequested)) })`. It is set only when `publication?.source == .remoteParticipants`.
  - `onOpenURL` (`:248-251`) needs no change. `CompetitionRoute(url:)` parses the new link. Universal links arrive through the same handler.
- **`MultiUserCompetitionTestLabView.swift`**:
  - Fixed preview for the claim fixture (`:325-420`): sender "Naren", `America/Los_Angeles`, expiry = the lab's logical date + 20 h. Add a `notNow` outcome.
  - `:457` passes a fixed `AccountChallengeLink`.
  - The pending Sam `CompetitionInviteView` (PR 6's fixed link) gets a `cancelChallenge` closure that shows the dialog and then pops.
- **Home closed row** (§4): PR 4's row and dismissal; only the `.cancelled` case is new.

##### Web
- **`web/challenge.html`** (new; copy `web/invite.html`'s structure and styles):
  - Title and h1: "Open in HealthComp to challenge them". Paragraph: "Someone shared their HealthComp challenge link. Open it on an iPhone with HealthComp installed." Button "Open in HealthComp".
  - The script sets `href = scheme + "://challenge/" + code` only when `location.pathname.split("/")[2]` matches `^[A-Za-z0-9_-]{22}$`. Use the same staging hostname switch.
  - Meta: no-referrer, noindex. og:title "HealthComp challenge link".
- **`web/_redirects`**: add `/c/*  /challenge  200`.
- **`web/_headers`**: add a `/c/*` block identical to `/invite/*`.
- **`web/.well-known/apple-app-site-association`**: add `{ "/": "/c/*", "comment": "HealthComp challenge links." }` to `components`. The entitlement (`applinks:$(HEALTHCOMP_INVITE_HOST)`) already covers the host, so no app-side change. Claude's call: without it the https branch of `CompetitionRoute` would never run and every tap would bounce through Safari.
- **`web/privacy.html`**: no change under the default for §10 Q3. If the owner picks named pushes, replace "Notification alerts contain generic text" (`:78-79`) with "Challenge alerts name the person who sent, declined or cancelled; other alerts contain generic text."

##### Docs
- **`docs/plans/2026-10-19-recipient-bound-invitations.md`**: amend the pending-membership paragraph (`:44-46`) to "…before they accept it, by opening the link or from the incoming challenge in the app. Only the bound account can accept." (Claude's call, §3.)
- If §10 Q3 is answered "named", also amend the APNs step of `docs/plans/2026-08-11-multi-user-supabase-implementation.md` (`:837`) in the same PR.

#### Server changes

##### 1. Forward migration `supabase/migrations/20261101001900_add_challenge_links_and_responses.sql`
Never edit migration 018. Order matters: all DDL first, and this migration has no data updates (lesson from 018's `55006`).

1. **Columns**: `alter table public.competitions add column closed_by_profile_id uuid references public.profiles(id), add column closed_at timestamptz, add constraint competition_closed_shape check ((closed_by_profile_id is null and closed_at is null) or (closed_by_profile_id is not null and closed_at is not null and lifecycle in ('declined','cancelled')));`. Account-deletion cancels leave both null.
2. **Challenge links**:
   - `create table private.challenge_links (profile_id uuid primary key references public.profiles(id), code text not null unique check (code ~ '^[A-Za-z0-9_-]{22}$'), created_at timestamptz not null default now());`
   - `enable` + `force row level security`, revoke everything from API roles.
   - Generator `private.new_challenge_link_code_v1()`: `pg_catalog.translate(pg_catalog.rtrim(pg_catalog.encode(extensions.gen_random_bytes(16),'base64'),'='),'+/','-_')`. That is 128 random bits, so codes are not enumerable.
   - The code is reusable. It grants only "can create a pending challenge to me". The owner can decline each one; mute works only for someone they've already played (`set_notification_mute`, `20260811000650:100-116`), and there is no reset (§10 Q6).
   - It stays outside the PostgREST-exposed schema and outside `public.profiles`, so profile column grants (`20260811000200:89-91`) are untouched.
3. **`private.match_in_progress_between(first_profile_id uuid, second_profile_id uuid) returns uuid`** (stable, definer):
   - Returns the first `c.id` where both people are `accepted` participants, `c.lifecycle in ('scheduled','active','ends_today','tallying')` and `(statement_timestamp() at time zone c.time_zone_identifier)::date <= c.start_day + 6`, ordered by `start_day`.
4. **`private.accept_pending_invitation(target_competition_id uuid, caller_profile_id uuid) returns uuid`**: the body of 018's claim (`:234-270`), keyed by competition id.
   - Lock `competitions` and its `competition_invites` row (`for update of c, i`, newest invite).
   - Same idempotent return when consumed by the caller.
   - Same `invite_unavailable` / `cannot_claim_own_invite` / wrong-recipient checks (wrong recipient stays `invite_unavailable`, 018 `:253`).
   - **New**: `raise 'active_match_exists'` (P0001) if `match_in_progress_between(creator, caller)` is not null.
   - Then the same participant, invite and schedule updates.
5. **`public.claim_competition_invite(bytea)`**: create or replace with the same signature and errors. Look up `competition_id` by digest (`invite_unavailable` if missing), then `return private.accept_pending_invitation(...)`.
6. **`public.accept_competition_challenge(competition_id uuid) returns jsonb`** (authenticated): auth checks as in `archive_competition` (`20260811000550:12-29`) → `{"competition_id": private.accept_pending_invitation(id, caller)}`. No token: the bound account is the check (§3).
7. **`public.decline_competition_challenge(competition_id uuid) returns jsonb`** (authenticated):
   - Lock the row.
   - If already `declined` with `closed_by = caller`, return the id.
   - Require `invited_profile_id = caller`, `lifecycle = 'pending'` and `invitation_expires_at > now`; otherwise `invite_unavailable`.
   - `update … set lifecycle='declined', closed_by_profile_id=caller, closed_at=now, updated_at=now`.
   - The invitee participant row **stays `pending`**. That keeps the creator's `can_view_profile` creator clause (018 `:80-82`) valid, so descriptors still embed the recipient's name. Without it, 1.0.2's strict descriptor validator would reject the whole list.
   - `perform private.enqueue_challenge_notification(id,'challenge_declined',creator,caller)`. Return `{competition_id}`.
8. **`public.cancel_competition(competition_id uuid) returns jsonb`** (authenticated). This is the one cancel RPC.
   - Lock the row.
   - Already `cancelled` with `closed_by = caller` → return.
   - `pending` and `creator_profile_id = caller` → cancel, retire the unconsumed invite row as 018 does on expiry, no push.
   - `scheduled`, caller is an `accepted` participant, and `(now at time zone tz)::date < start_day` → cancel, then `enqueue_challenge_notification(id,'match_cancelled',other,caller)`.
   - Otherwise `raise 'cancel_not_allowed'` (P0001).
   - Cancel sets `lifecycle='cancelled', closed_by_profile_id, closed_at`. Returns `{competition_id}`.
   - The finalizer (`20260811000900:27-29`) and score submission (`20260928001600:43`) already exclude `cancelled`.
9. **`private.can_view_profile`**: create or replace with 018's body (`:64-86`), adding `'cancelled'` to the accepted-counterpart lifecycle list.
   - This fixes a latent bug. A counterpart's profile embed is null in a competition whose only shared lifecycle is `cancelled`. Today that happens when a partner deletes their account. After this PR it would also happen on every Cancel Match.
   - The descriptor validator (`CompetitionSyncModels.swift:3248-3262`) then rejects the whole `listCompetitions` array in every installed build.
10. **`public.preview_competition_invite(token_digest bytea) returns jsonb`** (authenticated, stable, definer):
    - Same caller and digest checks as claim. No lock.
    - Consumed by the caller → state `accepted`.
    - Missing, consumed by another account, expired, not pending, or wrong account → `invite_unavailable`. It is the same error for every case, matching claim (§10 Q5 covers whether the wrong account should be told).
    - Creator → `cannot_claim_own_invite`.
    - Overlap → `active_match_exists`.
    - Returns `{competition_id, state, sender:{id, display_name}, time_zone_identifier, expires_at}`. The sender must be `active`; otherwise `invite_unavailable`.
11. **`public.list_challenges() returns jsonb`** (authenticated):
    - `incoming`: `invited_profile_id = caller`, `lifecycle='pending'`, `invitation_expires_at > now`, creator `active`. Ordered by `invitation_expires_at`, limit 50.
    - `closed`: caller is a participant, `closed_by_profile_id <> caller`, `closed_at > now - interval '24 hours'`, and either (`lifecycle='declined'` and `creator_profile_id = caller`) or (`lifecycle='cancelled'` and the caller is an `accepted` participant). The other person is `active` or `anonymized`. Ordered `closed_at desc`, limit 50.
    - `kind` = lifecycle.
12. **`public.get_my_challenge_link() returns jsonb`** (authenticated): `insert … on conflict (profile_id) do nothing`, then `{code}`.
    **`public.resolve_challenge_link(code text) returns jsonb`** (authenticated): a malformed or unknown code, or an inactive owner → `recipient_unavailable`. Own code → `own_challenge_link`. Otherwise `{id, display_name}`, the same shape as `resolve_invitation_recipient`.
13. **`public.create_competition_invite(bytea,text,uuid,uuid,uuid,smallint,uuid)`**: create or replace 018 `:94-208` with the same signature. After the existing `pending_invitation_exists` check (`:186-190`, unchanged):
    - `match_in_progress_between(caller, recipient)` → `active_match_exists` (P0001).
    - Then an unexpired pending from the recipient to the caller → `incoming_challenge_exists` (P0001).
    - After the inserts: `perform private.enqueue_challenge_notification(new_id,'challenge_received',recipient,caller)`.
    - The idempotent-retry branch (`:146-161`) is unchanged, returns before the inserts and never re-enqueues. PR 6's replay therefore never sends a second push.
14. **Notifications** (`20260811000700`):
    - Drop and re-add the `kind` check (inline today, so Postgres named it `competition_notification_work_kind_check`) to `('score_update','result','challenge_received','challenge_declined','match_cancelled')`.
    - New `private.enqueue_challenge_notification(target_competition_id uuid, target_kind text, target_recipient_profile_id uuid, target_source_profile_id uuid)`:
      - `server_seq = max(server_seq)` of that competition's change log, i.e. the change that caused it.
      - One row per active installation of an active recipient, `suppressed` if muted.
      - Semantic id in the existing format, `on conflict on constraint competition_notification_work_identity_unique do nothing`, then `perform private.request_competition_notification_worker()`.
    - Create or replace `public.lease_competition_notification_work` (`:294-410`):
      - The `discarded` case also covers challenge kinds whose source profile isn't `active`, and `challenge_received` when the competition is no longer `pending` or `invitation_expires_at <= as_of`.
      - Leased items keep their current seven keys. Only if §10 Q3 is answered "named": add `'sourceDisplayName', source_profile.display_name`.
15. **Realtime** (`20260811000600:12-45`): create or replace `private.broadcast_competition_change` so recipients also include `participant_row.role = 'invitee' and participant_row.state = 'pending'`. The payload stays the cursor hint only, so no id or name leaks.
16. **Grants**: every new public function gets `revoke all … from public, anon, authenticated, service_role`, then `grant execute` to `authenticated`. Every new private function gets `revoke all`.

##### 2. Edge Functions
- **`create-competition-invite/index.ts:148-155`**: add `active_match_exists` → 409 `active_match_exists` "A match with this account is in progress", and `incoming_challenge_exists` → 409 `incoming_challenge_exists` "This account already challenged you". `pending_invitation_exists` (409) and the fresh-create 201 are unchanged.
- **`claim-competition-invite/index.ts:250-263`**: before the P0001 rule, add `active_match_exists` → 409 `active_match_exists`.
- **New `preview-competition-invite/index.ts`**: copies claim (same `parseToken` and user client).
  - RPC `preview_competition_invite`.
  - 200 `{competitionId, state, sender:{id, displayName}, timeZoneIdentifier, expiresAt}`, renamed to camelCase from the RPC.
  - `cannot_claim_own_invite` → 409 `self_claim_forbidden`; `active_match_exists` → 409; `authentication_required` → 401; other P0001 → 404 `invite_unavailable`; anything else → 503 `temporarily_unavailable`.
  - Gateway JWT verification stays on (no `config.toml` entry, same as claim).
- **`send-competition-notification/index.ts`**:
  - The `kind` union (`:27`) and `parseWorkItem` (`:146-170`) accept the three new kinds. Allowed keys stay the current seven.
  - `competitionNotificationPayload` (`:255-278`, or PR 5's version if it landed): `challenge_received` → `{title: "New challenge", body: "Open HealthComp to accept or decline."}`. `challenge_declined` → `{title: "Challenge declined"}`. `match_cancelled` → `{title: "Match cancelled"}`. If PR 5 made the old kinds return no alert, these three are the only alerting kinds.
  - Named alternative (§10 Q3): parse an optional `sourceDisplayName` (1–64 characters, no ASCII control characters, required for challenge kinds) and use "\(name) challenged you" / "Accept or decline within 24 hours.", "\(name) declined your challenge", "\(name) cancelled your match".
  - Routing keys are unchanged (`kind: "competition"`, `competitionID`). 1.0.2 routes a challenge push to Home, because the id isn't visible there (`MainTabFeature.swift:479-481`).

##### 3. Compatibility with installed 1.0.2 (claim by token, current RPCs)
| 1.0.2 action | After PR 7 |
|---|---|
| Create to someone with a pending challenge | Unchanged: 409, the app's existing message. |
| Create while a match is live, or when they already challenged you | 409, which the app classifies as `.operationFailed` and shows as its existing "couldn't create… try again". The challenge is blocked, with a generic message. |
| Claim by token | Same body and response. An overlap → 409, shown as "Invitation unavailable" (claim context, 4xx). |
| Account code (UUID) | `resolve_invitation_recipient` is kept. The new + sheet still accepts UUIDs. |
| The other person declines or cancels | The row disappears (the runtime skips terminal lifecycles, `RemoteCompetitionRuntime.swift:635-642`). Listing keeps working because of fix §1.9. |
| Receives a challenge push | The alert shows. Tapping it opens Home, which lists nothing new, so the sender still has to share the link (PR 6's Share Link Again works if it's on their phone). Release note: update via TestFlight. |
| Opens a `/c/` link | With 1.0.2 installed, the universal link opens the app, which doesn't know the route and stays on Home. Same release note. |
| Extra realtime wakeups | A harmless reconcile. |

##### 4. Staging then production, in this order (runbook `docs/runbooks/supabase-environments.md` §5)
1. Deploy `send-competition-notification` first. It tolerates the new kinds; if it isn't deployed first, one unknown item fails the lease parse for the whole batch.
2. Apply the migration, then check that `supabase migration list` shows 24 versions. PR 5 adds no migration, so the count is 24 whichever lands first.
3. Deploy `create-competition-invite`, `claim-competition-invite` and `preview-competition-invite` with `--import-map supabase/functions/deno.json --jobs 1`.
   - In the window between steps 2 and 3 the old create function maps `active_match_exists` to 500, so create fails with a retryable error. That is acceptable.
4. Deploy `web/`, then check that `/c/<code>`, the `/invite/` headers and the new AASA (`curl https://<host>/.well-known/apple-app-site-association` and Apple's CDN at `https://app-site-association.cdn-apple.com/a/v1/<host>`) serve correctly.
5. Smoke test the Staging app with the two dedicated Staging accounts: link → Send → incoming row + push → preview sheet → Decline → sender row; Cancel Challenge; Cancel Match on a fresh scheduled pair. On a physical iPhone, tap a `/c/` link from Messages once with the app closed (cold) and once in the background (warm); both must open the "Challenge …?" sheet without Safari.
6. Repeat on production, then upload the TestFlight build. The new app must not reach testers before the production server: its preview call would hit a missing function and show "unavailable".

#### Tests

**pgTAP: new `supabase/tests/020_challenge_links_and_responses.test.sql`**
- Function existence and grants for every RPC above: authenticated only, never anon.
- Preview:
  - The recipient gets exactly the sender id and name, tz and expiry.
  - A third account, an expired, a consumed and a cancelled challenge all raise `invite_unavailable`, the identical error.
  - The creator gets `cannot_claim_own_invite`. After the recipient accepts, state is `accepted`.
- `accept_competition_challenge`: it schedules the match exactly like claim, with the same `start_day` and deadline. It is idempotent for the recipient and rejects a third account. Claim after accept-by-id returns the same id.
- Overlap:
  - Create while a `scheduled` match whose `start_day + 6 >= today` exists → `active_match_exists`.
  - The same check passes once `today > start_day + 6`.
  - Accept of a legacy reciprocal pending while a live match exists → `active_match_exists`.
  - A reciprocal create → `incoming_challenge_exists`.
- Create: a pending conflict still raises `pending_invitation_exists`; an idempotent retry enqueues no second `challenge_received`.
- Decline:
  - Sets `declined`, `closed_by` and `closed_at`, and leaves the invitee participant `pending`.
  - The creator's `can_view_profile(invitee)` stays true.
  - It is idempotent. It rejects the creator and a third account, and an expired challenge.
  - It enqueues one `challenge_declined` per creator installation; a muted creator gets `suppressed`.
- Cancel:
  - Pending by the creator → ok, no work enqueued. Pending by the recipient → `cancel_not_allowed`.
  - Scheduled before `start_day` by either participant → ok, with `match_cancelled` enqueued to the other.
  - On or after `start_day` → `cancel_not_allowed`. Completed → `cancel_not_allowed`.
- `can_view_profile`: true for the counterpart in a cancelled-only relationship, including an anonymized one after an account-deletion cancel.
- `list_challenges`:
  - Incoming excludes expired, other recipients' and inactive senders' challenges.
  - Closed shows declined only to the creator and cancelled only to the non-actor, within 24 h, newest first.
  - Nothing leaks scores or history.
- Challenge links:
  - The code matches the regex and is stable across calls.
  - Resolve returns `{id, display_name}`. Unknown, malformed and inactive codes → `recipient_unavailable`; own code → `own_challenge_link`.
  - `select count(*) from public.profiles` as the resolver stays 1, so resolving grants no directory. `private.challenge_links` can't be selected by `authenticated`.
- Lease: discards `challenge_received` after a cancel or after expiry; items keep exactly the seven keys.
- Broadcast: a pending invitee receives a `competition_changed` wakeup on create.
- Update `001_schema` / `002_schema_invariants` where they enumerate `competitions` columns or notification kinds.

**Deno**
- New `preview-competition-invite/index_test.ts`: method and body validation; 401; each error mapping (`self_claim_forbidden` 409, `active_match_exists` 409, P0001 404, other 503); the success body has exactly the camelCase keys and never contains the token.
- `create-competition-invite/index_test.ts`: `active_match_exists` / `incoming_challenge_exists` → 409; `pending_invitation_exists` still → 409.
- `claim-competition-invite/index_test.ts`: `active_match_exists` → 409.
- `send-competition-notification/index_test.ts`: parses the three new kinds; rejects an eighth key; checks the generic titles and bodies for all three kinds; old kinds are unchanged (or as PR 5 left them).
- `invitation_recipient_race_integration_test.ts`: a concurrent claim and `accept_competition_challenge` → exactly one acceptance. Concurrent A→B and B→A creates → one succeeds and the other gets `incoming_challenge_exists`.
- `scripts/tests/invitation-page.test.ts`: the same four cases for `web/challenge.html` (22-character code, staging scheme, preview host, malformed).
- `scripts/verify-invitation-functions.sh:141-143`: add the new function directory.
- `scripts/test-recovery-migrated-snapshot.sh:9,31`: the new count and manifest hash. Update `scripts/tests/recovery-migrated-fixture.sql` for the two nullable columns, following the 018 precedent.
- `scripts/verify-website.sh` (or its test): the AASA lists both `/invite/*` and `/c/*`.

**Unit (HealthCompTests)**
- `SupabaseCompetitionRemoteAPITests`:
  - `testListChallengesDecodesIncomingAndClosed` / `…RejectsExtraKeys` / `…RejectsFormerCompetitorSender`.
  - `testPreviewInviteUsesFunctionAndMapsErrors` (`self_claim_forbidden` → `.forbidden`, `active_match_exists` → `.activeMatchExists`, 404 → `.inviteUnavailable`).
  - `testAcceptDeclineCancelSendCompetitionIDAndValidateEcho`.
  - `testChallengeLinkCodeAndResolve` (`own_challenge_link` → `.ownChallengeLink`).
  - `testCreateClassifiesIncomingAndActiveConflicts`.
- `CompetitionRoutingTests`:
  - `testChallengeLinkParsesHttpsAndCustomScheme`.
  - `testChallengeLinkRejectsWrongLengthQueryTrailingSlashAndHost`.
  - `testChallengeLinkNeverEntersUserInfo`.
  - `testChallengeLinkCodeIsRedacted`.
- `RemoteCompetitionClientTests`:
  - `testProjectorAddsIncomingChallengeWithSenderIdentity`.
  - `testProjectorDropsExpiredIncoming`.
  - `testProjectorAddsClosedDeclinedAndCancelledWithin24Hours` (declined arrives as `.declined(…, .outgoing)`).
  - `testIncomingChallengesNotInNotificationSnapshot`.
  - `testAcceptDeclineCancelCallAPIThenReconcile`.
  - `testDeclineOfNoLongerPendingIsNotAnIssue`.
  - `testCommandFailureAddsCommandRejected`.
  - `testListChallengesFailureKeepsPreviousList`.
- `MainTabFeatureTests`:
  - `testClaimRouteLoadsPreviewThenReady`.
  - `testSecondClaimLinkIsQueuedNotReplaced`.
  - `testQueuedLinkOpensAfterNotNow`.
  - `testDuplicateTokenIgnored`.
  - `testNotNowConsumesRouteWithoutServerCall`.
  - `testDeclineConfirmedCallsDeclineAndConsumes`.
  - `testDeclineFailureReturnsToReadyWithError`.
  - `testPreviewAcceptedNavigatesToMatch`.
  - `testPreviewOwnChallengeAndActiveMatchStatuses`.
  - `testChallengeLinkResolvesToReady`.
  - `testChallengeLinkOwnAndUnavailable`.
  - `testCreateFromLinkNavigatesToChallengeAndFreesSlot`.
  - Rename existing `declineClaimTapped` expectations to `notNowClaimTapped`.
- `RemoteCompetitionFeatureTests`:
  - `testCancelTappedRunsCommand`.
  - `testChallengeLinkRequested`.
  - `testFindRecipientAcceptsLinkCodeAndLegacyUUID`.
  - `testRecipientResponseForStaleInputIgnored`.
  - `testChallengeSheetStatusDerivesChallengedYouAndInMatch` (tallying does not count as in a match).
  - `testRematchStateDerivesChallengedYouAndInMatch`.
  - `testServerConflictSetsConflictAndReconciles`.
  - PR 6's `alreadyPending` tests still pass.

**UI tests (`MultiUserCompetitionUITests`)**
- `testColdWarmAndSignedOutClaimConfirmationFlows`:
  - Assert `competition.claim.sender` = "Naren challenged you" and that `competition.claim.start` contains "Pacific Time".
  - Assert `competition.claim.accept`, `competition.claim.not-now` and `competition.claim.decline` exist.
  - Signed-out path: Decline → the dialog button "Decline Challenge" → outcome.
  - Add a Not Now path that ends at the dismissed outcome.
  - Update the copy assertions to PR 1's.
- `testCreatingInvitationRequiresConfirmingAnExistingAccount` and `…CustomScheme…`: enter a challenge link instead of a UUID in one of them; the rest is PR 6's flow (`competition.create.share` stays).
- New `testAccountShowsChallengeLinkAndCode`: `account.challenge-link.url` contains "/c/"; `account.challenge-link.show-code` → `account.challenge-link.qr` exists; `account.challenge-link.share` exists; the debug description contains no 36-character UUID.
- New `testRemoteOutgoingChallengeOffersCancel`: pending Sam → PR 6's `competition.invite.share`, then `competition.invite.cancel` → dialog → pop.
- Run the appearance matrix at xSmall and accessibility5, light and dark, over the claim sheet, the link sheet, the Account section and the QR sheet.

**Accessibility identifiers**
- **Added**:
  - Claim sheet: `competition.claim.not-now`, `competition.claim.sender`, `competition.claim.start`, `competition.claim.decline-error`.
  - Challenge screen (PR 6's `competition.invite.*` namespace): `competition.invite.accept`, `competition.invite.decline` (remote and fixture incoming buttons), `competition.invite.cancel`, `competition.invite.error`.
  - Match: `competition.match.cancel`, `competition.cancel.error`.
  - Home: `competition.sharing.cancelled.<uuid>` (from the existing identifier function, on PR 4's closed row).
  - Link sheet: `competition.link.sheet`, `competition.link.name`, `competition.link.send`.
  - Create sheet: `competition.create.share-own-link`, `competition.create.conflict`.
  - Rematch: `competition.rematch.view-match`, `competition.rematch.review`.
  - Account: `account.challenge-link.url`, `account.challenge-link.show-code`, `account.challenge-link.share`, `account.challenge-link.qr`, `account.challenge-link.retry`.
- **Removed**: `account.settings.share-account-code`.
- **Same id, new behavior**:
  - `competition.claim.decline` now opens a server-decline confirmation.
  - `competition.create.recipient-code` accepts a challenge link.
  - `competition.create.find-recipient` is labeled "Find".
- Unchanged: `competition.claim.sheet`, `.accept`, `.retry`, `.dismiss`, `.refresh-confirmation`, every PR 6 `competition.create.*` / `competition.invite.*` / `competition.rematch.*` id, `competition.more`.
- Not added (earlier draft names): `competition.challenge.*`, `competition.create.view-conflict`. The cancelled closed view reuses PR 4's `competition.closed` / `competition.closed.again`; this PR adds no other `competition.closed.*` id.

#### Risks and sequencing
1. **Server before app.** The app parts call one new Edge Function and six new RPCs, and must not reach TestFlight before the production server (Server §4). If the owner defers the server, all of PR 7 waits, including the app parts. Nothing here is useful without the server.
2. **PR 1** (lands first): uses `competitionDayText(_ day: CompetitionDay, …)`, `competitionMomentText`, PR 1's claim and challenge copy, and `competitionStatusText`.
   - PR 1 needs a `.cancelled(at:)` row in its status table: row "Match cancelled", card "Cancelled", notification "Match cancelled". PR 1 lacks it, so this PR adds it.
3. **PR 3** owns the shared rules card. The claim sheet and the link sheet call it with the sender's name and no week, which PR 3 already supports (`weekText: nil` → "Day 1 is the day after the challenge is accepted.").
4. **PR 4** owns Home groups and the closed row. This PR relies on: `.pending(.incoming)` → Needs you; closed outgoing `.declined` → Up next with dismissal; and it adds `.cancelled` to the same closed-row rule. Overlap: `CompetitionSharingView.swift` row code and `competitionHomeLayout`.
5. **PR 5**:
   - Shares `send-competition-notification/index.ts` and `lease_competition_notification_work`. Whichever lands second rebases. PR 5 has no migration, so only this PR replaces the lease function.
   - Push names follow PR 5's default (generic server payloads) unless the owner answers §10 Q3 otherwise. The earlier draft's "PR 5 reuses `sourceDisplayName`" is withdrawn.
   - PR 5's incoming expiry reminder stays fixture-only (§3).
6. **PR 6** lands first and is the baseline. PR 6 carries no Cancel wiring and no `cancel_competition_invite`. Its replay store stays unless the owner picks the server re-share (§10 Q7).
7. **PR 8** (f-permfirst) opens the claim sheet after sign-in and before Health. Welcome (before sign-in) stays nameless, because the preview needs a session. Whether the pre-Health sheet can call the preview depends on whether `previewInvite` can run before the runtime starts (it needs only a session). Whichever of PR 7 and PR 8 lands second makes that work or falls back to the nameless sheet. PR 8's `.wrongAccount` status is for brand-new accounts and is decided on the device, so it is used whatever §10 Q5 says.
8. **Migration risks**:
   - Replacing `claim_competition_invite`, `create_competition_invite` and `can_view_profile` must match 018's bodies apart from the stated deltas. Diff them in review.
   - Adding the `kind` values is a drop and re-add of the check constraint on a table with live rows. Every existing row satisfies the new check.
   - No data backfill. The recovery harness manifest pin moves by one.
   - Run `scripts/staging-adversarial-rollback.sql` against Staging after applying.
9. **QR colors** use black on white, outside Theme tokens. That is required for scanning, and kept local to the QR image.
10. **AASA caching.** Apple's CDN can take hours to pick up the new path; until then `/c/` links show the web page, which still works. Verify on a device before the TestFlight upload.
11. **Skipped**:
    - Server re-share of a challenge's link (§10 Q7).
    - Rotating or resetting a challenge link, blocking, and a decline cooldown (§10 Q6).
    - Server-side dismissal of closed rows. Dismissal is PR 4's per-session state.

#### Open questions
Moved to §10: Q1 (server this round), Q3 (named pushes), Q5 (wrong-account message), Q6 (unwanted challengers), Q7 (server re-share), Q8 (who may cancel a scheduled match) and Q9 (pushes to 1.0.2). All defaults are built above.

### PR 8 — First run, Account and remaining polish

#### Scope
- f-permfirst: a challenge link on a fresh install shows the challenge before any permission. For an existing account, Health is asked in the match's terms. A brand-new account is told at once that the challenge is for someone else. Notifications are asked once a challenge or match with a person exists. Account gets a Health row with a way to recover, and Home's Health issue points to it.
- f-notifpage: Account → Notifications re-reads permission on foreground, links to iOS Settings and lists muted people with Unmute.
- f-signout: sign-out asks first and states what actually happens. Failed sign-out or deletion gets copy for the step that failed. The account-mismatch button matches its title.
- f-welcome: Welcome is the mark, the title, Sign in with Apple and the Privacy Policy. "Amber is always you." appears once, the first time a scoreboard shows scores.
- Polish "Launch failure": one title, one line, Try Again.
- Polish "Display name": "Former competitor" gets "That name is reserved. Try another."
- Polish "Delete account": the alert stays and the middle page goes. Welcome shows "Account deleted." after success.

All copy below assumes PR 1's glossary strings have landed (Match, Challenge, "The other person…").

#### Behavior

**f-permfirst: first run from a challenge link**

What the code allows (verified):
- The claim token is a bearer secret. Nothing in the code can read who sent it before sign-in: `claimInvite` needs an authenticated, mounted runtime (RemoteCompetitionClient.swift:819-835), and the recipient-bound contract gives no access before acceptance.
- Nothing reads the sender's name even after sign-in. No preview call exists today, and PR 6 adds none. PR 7 designs a recipient-only preview that only ships with its server work (§10 Q1, Q4). ClaimCompetitionView's `.ready` state shows "Join this match?" and the rules card only (ClaimCompetitionView.swift:104-119, :175-179 after PR 1). The first call that learns anything about the match is `claimInvite`, and that call also accepts it.
- A challenge is bound to an account that existed before the challenge was made (docs/plans/2026-10-19-recipient-bound-invitations.md:17-18). The display-name screen appears only when the person has no profile yet (AppFeature.swift:318-326, `.displayNameRequired`). An account created on that screen is newer than any link opened before it, so it can never be that link's recipient. The real audience for challenge-first is an existing account on a new or reinstalled iPhone. Those people skip the display-name step.
- Starting the competition runtime is what asks iOS for Health (RemoteCompetitionClient.swift:586-603). MainTab therefore starts it only after onboarding (MainTabFeature.swift:123-135).
- HealthKit never tells an app whether reads were allowed (PermissionOnboardingClient.swift:74-80). `statusForAuthorizationRequest` only says whether iOS has asked yet.

Flow on a fresh install opened from a challenge link. Deliberate deviations from the mockup are marked.
1. **Welcome (challenge).** Mark. Title **"You have a challenge"**. Subtitle **"Sign in with the account it was sent to."** Then Sign in with Apple, "Sign in with Apple in Browser" (Staging only, as today) and Privacy Policy.
   - *Deviation:* the mockup's "Naren challenged you" needs the sender's name, and nothing can supply it before sign-in (§10 Q4).
   - Claude's call: the subtitle names the account rule instead of promising the sender's name. It is true for every reader, including someone who has no account yet.
   - Cancelling Apple sign-in returns to this same screen.
   - A link that arrives while the person is signed in never sets this state.
2. **Existing account** (profile bootstrap succeeds, so there is no display-name step):
   1. **Challenge sheet.** The existing ClaimCompetitionView, with PR 6's content, opens over the Health screen before Health is asked. It shows no sender name unless PR 7's preview can run here (§10 Q4, PR 7 Risks 7).
      - **Accept:** the sheet closes and the Health screen switches to the challenge copy (step iii). Nothing is sent to the server yet.
      - **Decline:** works as today. The link is consumed, and the Health screen shows its normal copy.
      - **Swipe down:** today it declines. PR 7 turns it into "Not now"; the sheet then comes back after Health, because the link is still pending.
   2. **Health, challenge copy.**
      - Label "HEALTH".
      - Title **"Connect Health so your rings count"**.
      - Body **"HealthComp reads your Activity rings to score each match day. You’ll join the match right after."**
      - Ring rows, privacy rows, the "Connect Health" button and "iOS will ask which Activity data to share." are unchanged.
   3. The iOS Health prompt appears. Whatever the answer, the competition starts. On its first publication the accepted challenge is claimed automatically: the sheet shows PR 6's "Accepting challenge…", then "Confirming match…", then the match screen opens (existing `resolveClaimedNavigation`).
      - *Deviation:* the claim is sent after Health, not at the Accept tap, because claiming needs the started runtime.
      - If the claim fails, the existing sheets appear over Home: a wrong-account sheet only if the owner says yes to §10 Q5, otherwise "Challenge unavailable" for expired, used or other-account links, and the retry sheet for offline.
      - An existing account that is not the recipient only learns so here, after Health. Only PR 7's recipient-only preview (§10 Q4) could say so earlier.
3. **New account** (display-name step shown):
   - The display-name screen never mentions the challenge. Its subtitle is always PR 1's "The people you play will see this name. You can change it later."
   - Claude's call: once the new account is mounted, any claim link that arrived before it existed is consumed on the device with no claim request. The claim sheet opens at once, over the Health screen, in a `.wrongAccount` state. It uses PR 6's proposed copy: title **"This challenge is for someone else"**, message **"Only the account it was sent to can accept it. Ask the sender to challenge this account."**, and button "Done" (`competition.claim.dismiss`).
     - This is decided on the device from the order of events. It reveals nothing about the link, so it does not depend on §10 Q5. PR 6 does not ship `.wrongAccount`, so this PR adds the case and its copy (see Design); if the owner says yes to §10 Q5, PR 7 reuses it.
   - "Done" closes the sheet. Health onboarding then continues with its normal copy, and nothing else about the link remains.
   - A link that arrives after the account exists goes through the normal claim path.
4. **Notifications, in context.** About 0.6 s after the first publication that contains a pending challenge or a live match, a sheet shows the existing notifications explainer (PermissionOnboardingView `.notifications`). The trigger is a match whose lifecycle is `.pending` (either direction, not expired or declined), `.scheduled`, `.active`, `.endsToday` or `.tallying`.
   - **"Turn On Notifications"** asks iOS, then closes.
   - **"Not now"**, or swiping down, closes it and records the existing "deferred" flag. It never appears again; Account → Notifications stays the way to turn them on.
   - *Deviation:* the mockup says "at the first lead change". The app learns of lead changes in the background, so a prompt then would appear at random.
   - Claude's call: a pending challenge triggers it too, in both directions. A pending challenge is the earliest moment that has a person attached, and PR 5's inviteExpiry reminders (20 h after sending) reach only people who already allowed notifications.
   - It never shows during onboarding, while the claim sheet or PR 6's Challenge sheet is up, when permission is already decided, or more than once per session.
   - Senders get it when they close the Challenge sheet after sending their first challenge. Recipients get it once their challenge or match first appears with the claim sheet closed. Existing users who were never asked get it on their next launch that has a pending challenge or live match.
- **Second link while onboarding:** if the person accepted and a newer link arrives before Health, the acceptance is cleared and the sheet asks again for the new link. Accept always applies to the link on screen.
- **App killed on the Health screen after Accept:** the link is lost, because routes live in memory, as today. The person taps the link again.
- **Health already asked on this iPhone** (onboarding has no steps): nothing changes. The competition starts and the challenge sheet opens over Home once the first publication arrives. A new account still gets the wrong-account sheet at once.
- **Notifications leave first-run onboarding entirely.** The first run is now Health only.

**f-permfirst: Account → Health**

Row: `Label("Health", systemImage: "heart")`, first in the settings section. Order: Health, Notifications, Appearance, Privacy, as in the mockup. It opens a page titled "Health" (Account's pattern is that each setting has its own page; the mockup's inline button is not used). Three states:

| State | When | Row value | Page |
|---|---|---|---|
| Off | iOS has not asked yet (`shouldRequest`) | "Off" | `LabeledContent("Health access", value: "Off")`; button **"Connect Health"**; footer **"Your points can’t update until HealthComp can read your Activity rings."** |
| Unavailable | HealthKit is not available on the device, or the dashboard has `.authorizationUnavailable` | "Unavailable" | `LabeledContent("Health access", value: "Unavailable")`; button **"Open Settings"**; footer **"HealthComp can’t read Health on this iPhone right now, so your points can’t update."** |
| Asked | iOS has asked (`unnecessary`) and there is no issue | no value | Text **"HealthComp reads Move, Exercise and Stand to score your matches."**; button **"Open Settings"**; footer **"iOS doesn’t tell apps whether Health access is on. If your points aren’t updating, turn on all categories for HealthComp in Settings → Privacy & Security → Health."** |

- *Deviation:* when iOS has asked, the row cannot say "Off" even after the person denied access, because iOS hides that. The Asked page explains how to check instead.
- "Connect Health" asks iOS, then re-reads the status.
- "Open Settings" opens `UIApplication.openSettingsURLString`.
- The status is re-read each time Account opens and each time the app returns to the foreground while it has been read this session. Coming back from Settings therefore updates it.
- **Home banner** (CompetitionSharingView.swift:1131): "Activity authorization is unavailable." becomes **"HealthComp can’t read Health. Check Account → Health."**

**f-notifpage: Account → Notifications**

| Authorization | Row value | First section |
|---|---|---|
| not determined | "Off" | `LabeledContent("Match notifications", "Off")`, then button **"Turn On Notifications"** (keeps `competition.notifications.enable`) |
| denied | "Off" | `LabeledContent("Match notifications", "Off")`, then secondary text **"Turned off in iOS Settings"**, then button **"Open Settings"** |
| authorized / provisional / ephemeral | "On" | `LabeledContent("Match notifications", "On")`, then button **"Open Settings"** |
| not loaded (nil) | "Off" | label only |

- **Footer** in every state: **"HealthComp only sends match moments, like lead changes and results. To mute someone, open your match with them."** When notifications are on, it adds **" Turn them off in iOS Settings."**
- **Open Settings** opens `UIApplication.openNotificationSettingsURLString` (iOS 16+), which lands on HealthComp's notification settings.
- **MUTED section,** shown only when at least one muted person can be named.
  - Header: `SectionLabel("MUTED")`.
  - Each row: an initial in a `Theme.control` circle with a `Theme.ink` letter, the name in `Theme.ink` (wraps, no line limit), and a borderless button **"Unmute"** with VoiceOver label **"Unmute \(name)"**. The button is disabled while that mute is saving.
  - At accessibility sizes the name and button stack vertically.
  - Footer: **"Muting someone silences all your matches with them."**
  - Rows are sorted with `localizedStandardCompare`.
  - A name comes from the first match in the publication whose `opponentIdentity` matches.
  - Muted identities with no match in the publication are not listed. They have nothing to notify about, and a new challenge from that person adds them back.
  - Unmute sends the existing `.competition(.muteTapped(identity))`, which toggles. Muted people are listed even while notifications are off.
- **Freshness.** Notification permission is re-read every time the app becomes active, so this page, the row value and the match-screen mute buttons follow changes made in iOS Settings without a relaunch.

**f-signout**

Verified sign-out behavior (AppFeature.swift:886-1028, RemoteCompetitionClient.swift:880-1206, CompetitionPushRegistration.swift:489-514, SupabaseConfiguration.swift:587-591):
- The push installation is revoked on the server. Sign-out fails if that fails.
- Local scheduled notifications are cancelled and the runtime stops, so nothing uploads.
- Local profile storage is removed.
- The Supabase sign-out uses **global** scope.
- Each refresh reads the whole 7-day window (RemoteCompetitionRuntime.swift:968-994). Days missed while signed out are therefore submitted after signing back in, as long as the match has not been finalized.

**Confirmation.** Tapping Sign Out in Account shows an alert titled **"Sign out?"** with buttons **Cancel** and **Sign Out** (destructive). The message depends on N, the number of matches that are active, end today or are tallying:
- N = 0: **"Notifications stop until you sign back in."**
- N = 1: **"While you’re signed out, your points stop reaching your live match and notifications stop. Sign back in before it ends to catch up."**
- N ≥ 2: **"While you’re signed out, your points stop reaching your \(N) live matches and notifications stop. Sign back in before they end to catch up."** N is formatted with `N.formatted()`.

The mockup's "this iPhone" becomes "your points", because sign-out is global. The footer under Sign Out (today "Signing out removes this profile’s local match cache…") is removed; the alert now carries that information.

**Account mismatch** (`.profileConflict` mode):
- Title: **"This iPhone has history for another account"**.
- Subtitle: **"Only this iPhone is signed out. Saved history and your other devices are unchanged."**
- Button: **"Sign Out to Switch"**.
- The separate `.profileConflict` message line is no longer drawn in this mode.

**Teardown failures.** These land on the launch-failure screen. The title and subtitle come from the failure:

| Reason / stage | Title | Line |
|---|---|---|
| user sign-out, prepareRuntime or finishUserSignOut | "Couldn’t sign out" | "Check your connection and try again." |
| user sign-out, removeProfileStorage | "Couldn’t sign out" | "HealthComp couldn’t remove your data from this iPhone. Try again." |
| user sign-out, retireAuthentication | "Couldn’t finish signing out" | "You’re signed out, but HealthComp couldn’t finish clearing this iPhone. Try again." |
| account deleted, any stage | "Account deleted" | "Your account is deleted, but HealthComp couldn’t finish clearing this iPhone. Try again." |
| session ended, any stage | "Your session ended" | "HealthComp couldn’t finish clearing this iPhone. Try again." |
| profile conflict, any stage | "Couldn’t sign out" | "Your saved history is safe. Check your connection and try again." |
| restoredWithoutSession / cancelledAuthentication | "Couldn’t connect" | "Check your connection and try again." |

Every row's button is "Try Again" (`account.retry`), which resumes the teardown as today.

**Deletion failure.** A failure shows under the Delete Account row, not in the profile section:
- generic failure: **"Couldn’t delete your account. Check your connection and try again."**
- reauthentication needed: "Confirm with Sign in with Apple to delete your account." (unchanged)
- cancel: no message

**Polish: launch failure.** Title **"Couldn’t connect"**, line **"Check your connection and try again."**, button "Try Again". There is no separate message line. "Your local data is safe" and "HealthComp could not connect. Please try again." are gone. `.tryAgain` now reads **"Check your connection and try again."** everywhere: Welcome sign-in failure, display-name save failure, launch.

**Polish: display name.** On first-run setup and on Account → Edit, "Former competitor" (exact match after trimming, as the server checks) shows **"That name is reserved. Try another."** Other invalid names keep "Choose a name from 1 to 64 characters without line breaks." If the server rejects a name, the generic message still applies.

**Polish: delete account.**
- The Account root row is a **"Delete Account"** button (destructive role, `Theme.ink` label) that opens the alert directly. The pushed page is gone.
- Alert title: "Delete Account?". Buttons: "Delete Account" (destructive), "Delete with Apple in Browser" (only when available, as today) and "Cancel".
- Alert message: **"You’ll confirm with Sign in with Apple. Live matches are cancelled, and finished matches stay in the other person’s history under the name Former competitor. This can’t be undone."**
- While deleting, the row's accessibility value is "Deleting account" and the root overlay shows a spinner, as today.
- On success, Welcome shows the message **"Account deleted."** (`account.message`). The same happens when the server reports the account deleted, for example after deleting in a browser.

**f-welcome**
- Signed out, with no link: mark (`BrandMark(grows: true)`), **"Welcome to HealthComp"**, no subtitle, Sign in with Apple, browser sign-in (Staging), Privacy Policy. The "HOW TO READ IT" card is deleted.
- The raw-versus-shared disclosure still appears before any Health read, on the Health onboarding screen, and on Account → Privacy. The Privacy Policy link stays on Welcome.
- **Color hint.** The first time a match screen scoreboard shows scores (active, ends today or tallying; finished matches open the result screen, which has no scoreboard panel), a footnote line appears under the period row (under PR 3's PROVISIONAL tag while tallying): an amber swatch (`SlantedBar`, `Theme.youFill`, 18×6) and **"Amber is always you."** in `.footnote`, `Theme.secondary`.
  - It disappears for good once that screen goes away, stored in `@AppStorage("healthcomp.colorHintSeen")`.
  - It is hidden from VoiceOver, because color carries no meaning there and the side labels already say "YOU".
  - It wraps at accessibility sizes.
  - Scheduled matches don't show it.

#### Design
No new Swift files, so no project.pbxproj change.

**HealthComp/Services/PermissionOnboardingClient.swift**
- After the step enum at :6-9 add:
  ```swift
  enum HealthAccessStatus: Equatable, Sendable { case unavailable, notRequested, requested }
  ```
- Replace the fields at :12-17 with `requestHealthAccess`, `deferNotifications` (comment: "Records Not now on the notifications prompt."), plus:
  ```swift
  var healthAccess: @Sendable () async -> HealthAccessStatus
  var notificationsDeferred: @Sendable () async -> Bool
  ```
  Delete `pendingSteps` and `requestNotifications`. Notification requests go through `competition(.enableNotificationsTapped)` so CompetitionFeature's authorization state stays in sync.
- Replace `steps(...)` at :21-34 with:
  ```swift
  static func steps(health: HealthAccessStatus) -> [PermissionOnboardingStep] {
      health == .notRequested ? [.health] : []
  }
  ```
- `inert` at :36-41: `healthAccess: { .requested }`, `notificationsDeferred: { true }`. The `true` keeps the local Test Lab, which injects `.inert` at CompetitionTestLabView.swift:737, from ever showing the prompt.
- `liveValue` at :48-88. `healthAccess`:
  - `HKHealthStore.isHealthDataAvailable()` false → `.unavailable`.
  - `try await statusForAuthorizationRequest(toShare: [], read: HealthKitProvider.competitionReadTypes())` returns `.shouldRequest` → `.notRequested`; `.unnecessary` or `.unknown` → `.requested`; a thrown error → `.unavailable`.
  - `notificationsDeferred` reads the existing `deferredKey`.

**HealthComp/Features/MainTab/MainTabFeature.swift**
- State (:34-71). Add properties with inline defaults (the explicit init needs no change):
  ```swift
  var acceptsClaimOnStart = false   // Accept tapped before the competition started
  var healthAccess: HealthAccessStatus?
  var notificationPrompt: NotificationPromptPhase = .unscheduled
  var isChallengeSheetOpen = false  // PR 6's Challenge sheet; mirrors MainTabView's isChallengePresented
  /// Claim links up to this sequence arrived before this account existed, so they can't be for it.
  var claimLinksBeforeAccountThrough: UInt64 = 0
  ```
  Add `enum NotificationPromptPhase: Equatable, Sendable { case unscheduled, scheduled, presented, finished }` next to `PermissionOnboarding` (:26-32).
- Action (:79-102):
  - Remove `onboardingNotNowTapped`.
  - Add `refreshHealthAccess`, `healthAccessLoaded(HealthAccessStatus)`, `connectHealthTapped`, `challengeSheetVisibilityChanged(Bool)`, `notificationPromptReady`, `notificationPromptSkipped`, `notificationPromptTurnOnTapped`, `notificationPromptNotNowTapped`.
- `InviteClaimStatus` (:11-19): add `case wrongAccount` only if PR 6 has not added it. Add it beside `.unavailable` in the switches at :409 and :433 (and wherever PR 6's `.ownChallenge` sits). `.dismissClaimStatus` returns it to `.idle`.
- Add `case notificationPrompt` to CancelID (:109-113). Add `private static let notificationPromptDelay: Duration = .milliseconds(600)`.
- `.task` (:126-136): send `.onboardingChecked(PermissionOnboardingClient.steps(health: await permissionOnboardingClient.healthAccess()))`.
- `.scenePhaseChanged(.active)` (:148-150): keep the onboarding guard. Return `.merge(.send(.competition(.sceneBecameActive)), state.healthAccess == nil ? .none : .send(.refreshHealthAccess))`.
- `.onboardingChecked` (:160-165): after setting `state.onboarding`, if `state.pendingClaimRoute != nil && state.claimRouteSequenceInFlight == nil && state.inviteClaimStatus == .idle`, set `state.inviteClaimStatus = .ready`.
- `.onboardingContinueTapped` (:176-181): only `.health` remains. `.notifications` becomes unreachable in onboarding; make it `case .notifications: break`.
- Delete `.onboardingNotNowTapped` (:185-196).
- `.routeReceived` claim branch (:222-238):
  - Right after the `lastHandledClaimRouteSequence` guard: if `envelope.sequence <= state.claimLinksBeforeAccountThrough && state.claimRouteSequenceInFlight == nil`, then:
    - Raise `lastHandledClaimRouteSequence` to it.
    - Clear `pendingClaimRoute` if its sequence is ≤ this one.
    - Set `inviteClaimStatus = .wrongAccount`.
    - Return `.run { _ in competitionRoutingClient.consume(envelope.sequence) }`.
    - No claim request is made, and `acceptsClaimOnStart` is never set.
  - Before the `.ready` assignment, set `state.acceptsClaimOnStart = false` whenever `pendingClaimRoute` is replaced.
  - Widen the condition at :233 to `(state.competition.publication != nil || state.onboarding != nil) && state.claimRouteSequenceInFlight == nil`.
- `.acceptClaimTapped` (:306-310): after the `.ready` guard, if `state.competition.publication == nil`, set `state.acceptsClaimOnStart = true`, set `state.inviteClaimStatus = .idle` and return `.none`. Otherwise `.send(.processPendingClaim)` as today.
- `.claimInviteResponse` success (:335-363): append `scheduleNotificationPromptIfDue(state: &state)` to the returned merge.
- `.stop` (:209-220): set `acceptsClaimOnStart = false`, `isChallengeSheetOpen = false` and `notificationPrompt = .unscheduled`; add `.cancel(id: CancelID.notificationPrompt)` to the merge.
- `.competition(.publication)` (:438-459):
  - Before the `.ready` block at :454-458: if `state.acceptsClaimOnStart`, set it to `false`. If `pendingClaimRoute != nil && claimRouteSequenceInFlight == nil`, append `.send(.processPendingClaim)` and skip the `.ready` assignment.
  - Append `scheduleNotificationPromptIfDue(state: &state)`.
- New cases, placed before the `.competition` catch-all at :461:
  - `.competition(.notificationAuthorizationLoaded)` → `scheduleNotificationPromptIfDue(state: &state)`.
  - `.competition(.notificationAuthorizationRequestFinished)` → if `notificationPrompt == .presented`, set `.finished`; return `.none`.
  - `.refreshHealthAccess` → `.run { send(.healthAccessLoaded(await permissionOnboardingClient.healthAccess())) }`.
  - `.healthAccessLoaded(s)` → `state.healthAccess = s`.
  - `.connectHealthTapped` → `.run { await requestHealthAccess(); await send(.healthAccessLoaded(await healthAccess())) }`.
  - `.challengeSheetVisibilityChanged(open)` → set `isChallengeSheetOpen = open`. When it becomes false, return `scheduleNotificationPromptIfDue(state: &state)`.
  - `.notificationPromptReady` → guard `notificationPrompt == .scheduled`, `inviteClaimStatus == .idle`, `!isChallengeSheetOpen`, `onboarding == nil` and `competition.notificationAuthorizationState == .notDetermined`. If any fails, set `.unscheduled` so the next publication retries. Otherwise set `.presented`.
  - `.notificationPromptSkipped` → `.finished`.
  - `.notificationPromptTurnOnTapped` → guard `.presented`, then `.send(.competition(.enableNotificationsTapped))`.
  - `.notificationPromptNotNowTapped` → guard `.presented`, set `.finished`, then `.run { await permissionOnboardingClient.deferNotifications() }`.
- New private helper:
  ```swift
  private func scheduleNotificationPromptIfDue(state: inout State) -> Effect<Action>
  ```
  - Guard: `notificationPrompt == .unscheduled`, `onboarding == nil`, `inviteClaimStatus == .idle`, `!isChallengeSheetOpen`, `competition.notificationAuthorizationState == .notDetermined`, and the publication contains a competition whose lifecycle is `.pending` (either direction), `.scheduled`, `.active`, `.endsToday` or `.tallying`. Expired and declined challenges do not count.
  - Then set `.scheduled` and return `.run { send in try await continuousClock.sleep(for: Self.notificationPromptDelay); await send(await permissionOnboardingClient.notificationsDeferred() ? .notificationPromptSkipped : .notificationPromptReady) }.cancellable(id: CancelID.notificationPrompt, cancelInFlight: true)`.
  - The delay lets the claim sheet finish dismissing; SwiftUI drops a sheet presented mid-dismissal.

**HealthComp/Features/MainTab/MainTabView.swift**
- :18-23: pass `isForChallenge: store.acceptsClaimOnStart` and `notNowTapped: {}`. The parameter stays for the prompt.
- Add `.onChange(of: isChallengePresented) { _, open in store.send(.challengeSheetVisibilityChanged(open)) }` next to the existing `onChange` at :31. Without it, a sender's own pending challenge would present the prompt while the Challenge sheet is still up, and SwiftUI would drop it.
- On `home`'s NavigationStack (:53, after `.navigationDestination` at :117), add a sheet. It goes here, not on the Group at :41, so it does not share a view with the claim sheet:
  ```swift
  .sheet(isPresented: Binding(get: { store.notificationPrompt == .presented },
                              set: { if !$0 { store.send(.notificationPromptNotNowTapped) } })) {
      PermissionOnboardingView(step: .notifications,
          isRequesting: store.competition.notificationAuthorizationRequestIsInFlight,
          continueTapped: { store.send(.notificationPromptTurnOnTapped) },
          notNowTapped: { store.send(.notificationPromptNotNowTapped) })
  }
  ```

**HealthComp/Features/Competition/ClaimCompetitionView.swift** (only if PR 6 has not added `.wrongAccount`)
- Add `.wrongAccount` beside PR 6's `.ownChallenge` in the switches at :60-71, :104-157 and :178-209: the title and message from Behavior (new account), icon `person.crop.circle.badge.xmark`, and one "Done" button (`competition.claim.dismiss`) that calls `dismiss`.
- MainTabView.swift :170: `.wrongAccount` dismisses like `.unavailable`.

**HealthComp/Features/MainTab/PermissionOnboardingView.swift**
- Add `var isForChallenge = false` after :8.
- In `header` (:52-64), when `step == .health && isForChallenge`, use the title and body copy from Behavior step 2.ii ("Health, challenge copy"). Everything else is unchanged.

**HealthComp/Features/Competition/CompetitionFeature.swift**
- Extract the authorization-load `.run` from `.task` (:161-172) into:
  ```swift
  private func loadNotificationAuthorization(current: CompetitionNotificationAuthorizationState?) -> Effect<Action>
  ```
  `.task` keeps using it.
- `.sceneBecameActive` (:482-483) returns `.merge(reconcile(trigger: .foreground), loadNotificationAuthorization(current: state.notificationAuthorizationState))`.

**HealthComp/Features/Competition/CompetitionSharingView.swift:1131**: the new Home banner string from Behavior.

**HealthComp/Features/Competition/CompetitionDetailView.swift**
- Add `struct CompetitionColorHint: View` near `CompetitionScoreboardPanel` (:509):
  - `static let storageKey = "healthcomp.colorHintSeen"`.
  - `@AppStorage(Self.storageKey) private var isSeen = false`.
  - Body: `if !isSeen { HStack(spacing: 8) { swatch; Text("Amber is always you.") }.accessibilityHidden(true).onDisappear { isSeen = true } }`.
- Insert `CompetitionColorHint()` inside the `competitionShouldShowScores` branch (:521-527), after the `periodRow` / PR 3 `provisionalTag` switch, so it shows in both.

**HealthComp/Features/Account/AccountFeature.swift**
- `Message` (:34-62). Add cases with their `text`:
  - `reservedDisplayName`: "That name is reserved. Try another."
  - `deleteFailed`: "Couldn’t delete your account. Check your connection and try again."
  - `accountDeleted`: "Account deleted."
  - `signOutFailed`, `signOutCleanupFailed`, `signOutFinishFailed`, `deletedCleanupFailed`, `sessionEndedCleanupFailed`: the lines from the teardown table.
- Change these texts:
  - `.tryAgain`: "Check your connection and try again."
  - `.profileRecoveryFailed`: "Your saved history is safe. Check your connection and try again."
  - `.profileConflict`: "Sign in with the account you used before to continue."
- Add `var failureTitle: String?` returning the titles from the teardown table:
  - `.tryAgain` → "Couldn’t connect"
  - `.invalidCredential` → "Couldn’t sign in"
  - `.profileConflict` → "This iPhone has history for another account"
  - all other cases → nil
- Add `var isDeletionMessage: Bool { self == .deleteFailed || self == .reauthenticationRequired }`.
- `validDisplayName` (:257-268) becomes:
  ```swift
  private func displayNameProblem(_ value: String) -> Message?
  ```
  It returns `.reservedDisplayName` for the trimmed value `"Former competitor"`, `.invalidDisplayName` for the other failures, and nil when the name is valid. `.submitDisplayNameButtonTapped` (:134-142) and `.saveDisplayNameButtonTapped` (:165-181) set `state.message` from it. Keep the trimming and assignment as today.
- `.operationFailed` (:230-234): capture `let wasDeleting = state.isDeletingAccount` before clearing. Then `state.message = wasDeleting ? deletionMessage(for: failure) : message(for: failure)`.
- Add:
  ```swift
  private func deletionMessage(for: AuthenticationClientFailure) -> Message?
  ```
  It maps `.cancelled` → nil, `.reauthenticationRequired` → `.reauthenticationRequired`, and everything else → `.deleteFailed`.
- No change to `signOutButtonTapped`. The confirmation is view state, so the existing delegate tests stay valid.

**HealthComp/Features/Account/AccountView.swift**
- Add `var hasPendingChallenge = false` after `store` (:8).
- Delete `colorCodeCard`, `codeRow` and their use (:18-20, :102-154).
- `title` (:239-247):
  - signedOut → `hasPendingChallenge ? "You have a challenge" : "Welcome to HealthComp"`
  - launchFailure → `store.message?.failureTitle ?? "Couldn’t connect"`
  - profileConflict → "This iPhone has history for another account"
- `subtitle` (:249-262) becomes `String?`:
  - signedOut → the challenge line or nil
  - settingUpProfile → PR 1's default, always (a new account can't be a challenge's recipient)
  - launchFailure → `store.message?.text ?? "Check your connection and try again."`
  - profileConflict → the mismatch line
  - authenticated → nil
- In `header` (:51-54), render the subtitle only when non-nil, with `.accessibilityIdentifier("account.subtitle")`.
- Draw the standalone message (:21-27) only in `.signedOut` and `.settingUpProfile`. Launch failure and profile conflict fold it into the subtitle.
- :224: the button title becomes `"Sign Out to Switch"`. The identifier `account.recover-profile` is unchanged.

**HealthComp/Features/Account/AccountSettingsView.swift**
- `AccountNotificationSettings` (:6-14) gains:
  ```swift
  var mutedPeople: [AccountMutedPerson] = []
  var mutesInFlight: Set<String> = []
  var unmute: (String) -> Void = { _ in }
  ```
- New:
  ```swift
  struct AccountMutedPerson: Equatable, Identifiable { let id: String; let name: String }
  static func list(_ competitions: [LocalCompetitionPresentation], muted: Set<String>) -> [AccountMutedPerson]
  ```
  The rule is in Behavior.
- New:
  ```swift
  struct AccountHealthSettings {
      let access: HealthAccessStatus
      let isReadFailing: Bool
      let connect: () -> Void
      enum State: Equatable { case off, unavailable, asked }
      var state: State   // isReadFailing || access == .unavailable → .unavailable; .notRequested → .off; else .asked
  }
  ```
- New free functions:
  ```swift
  func accountSignOutMessage(liveMatchCount: Int) -> String
  func accountLiveMatchCount(_ competitions: [LocalCompetitionPresentation]) -> Int  // .active, .endsToday, .tallying
  ```
  If PR 4 has introduced a "Live" grouping predicate by then, implement `accountLiveMatchCount` with it.
- `AccountSettingsView` params (:18-24): add `var health: AccountHealthSettings?` and `var liveMatchCount = 0`. Add `@State private var isSignOutConfirmationPresented = false` and `@Environment(\.openURL) private var openURL` to the pages that use it.
- `settingsSection` (:138-181):
  - New first row: `NavigationLink { AccountHealthPage(settings: health) }`, label `LabeledContent { Text(value) } label: { Label("Health", systemImage: "heart") }`, identifier `account.health`, shown when `health != nil`.
  - Then Notifications (:151-162) and Appearance (:140-149), then Privacy.
- `signOutSection` (:184-204):
  - The button sets `isSignOutConfirmationPresented = true`.
  - Attach `.alert("Sign out?", isPresented: $isSignOutConfirmationPresented) { Button("Sign Out", role: .destructive) { store.send(.signOutButtonTapped) }.accessibilityIdentifier("account.sign-out.confirm"); Button("Cancel", role: .cancel) {} } message: { Text(accountSignOutMessage(liveMatchCount: liveMatchCount)) }` **to the button**, not the List, so it does not collide with the delete alert.
  - Delete the footer (:197-202).
- `deleteSection` (:206-216) becomes:
  ```swift
  Button(role: .destructive) { store.send(.deleteAccountButtonTapped) } label: { Text("Delete Account").foregroundStyle(Theme.ink) }
  ```
  - With `.frame(maxWidth: .infinity, minHeight: 44)`, `.disabled(store.isRequestInFlight)`, identifier `account.delete`, and `.accessibilityValue(store.isDeletingAccount ? "Deleting account" : "")`.
  - Below it: `if let message = store.message, message.isDeletionMessage { Text(message.text)…accessibilityIdentifier("account.message") }`.
  - Move the alert (:346-374) onto this button and change only its message string.
  - Delete `AccountDeletionPage` (:310-376).
- `profileSection` message (:108-113): add the condition `!message.isDeletionMessage`.
- `AccountNotificationsPage` (:237-283): rebuild to the Behavior table.
  - Open Settings: `Button("Open Settings") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }`, `.frame(minHeight: 44)`, identifier `account.notifications.settings`.
  - The MUTED `Section` uses `ForEach(settings.mutedPeople)`. The layout switches with `dynamicTypeSize.isAccessibilitySize` to `AnyLayout(VStackLayout)`, the codebase's pattern from AppearancePicker :565-567. Unmute buttons have identifier `account.notifications.unmute`.
- New `private struct AccountHealthPage: View` with the Behavior table.
  - Buttons: Connect Health (`account.health.connect`) and Open Settings (`account.health.settings`, opening `UIApplication.openSettingsURLString`). Both have `minHeight: 44`.
  - Page title "Health" via `accountPageStyle`.

**HealthComp/App/AppFeature.swift**
- State (:47-54 plus init :56-76): add `var pendingChallengeSequence: UInt64?`, declared with a default, and `var hasPendingChallenge: Bool { pendingChallengeSequence != nil }`.
- Action (:152-183): add `case routeReceived(CompetitionRouteEnvelope)`.
- Add `@Dependency(\.competitionRoutingClient) private var competitionRoutingClient` and `case routes` to CancelID (:191-196).
- `.task` (:204-228): merge a routes observation into every return:
  ```swift
  .run { send in for await e in competitionRoutingClient.routes() { guard !Task.isCancelled else { return }; await send(.routeReceived(e)) } }
      .cancellable(id: CancelID.routes, cancelInFlight: true)
  ```
  It never consumes routes. CompetitionRouteHub replays pending routes to each stream (CompetitionRouting.swift:121-139), so MainTab still receives the link.
- `.stop` (:230-248): add `.cancel(id: CancelID.routes)` to both branches.
- `.routeReceived(e)`: if `e.route.kind` is the claim kind and `state.phase` is one of `.launching`, `.signedOut`, `.bootstrappingProfile`, `.settingUpProfile` or `.launchFailure`, set `state.pendingChallengeSequence = max(state.pendingChallengeSequence ?? 0, e.sequence)`. Return `.none`.
- `.profileStorageResponse` success (:349-356):
  - Read `let isNewAccount = state.phase == .settingUpProfile` before the phase becomes `.authenticated`. The phase stays `.settingUpProfile` from the name submit (:458-460) through `bootstrapProfileResponse` success (:313-316) until this point.
  - After `state.mainTab = MainTabFeature.State()`: if `isNewAccount`, set `state.mainTab?.claimLinksBeforeAccountThrough = state.pendingChallengeSequence ?? 0`.
  - Then set `state.pendingChallengeSequence = nil`.
- `.teardownCompleted` (:416-426): message is `.sessionEnded` for sessionEnded, `.accountDeleted` for accountDeleted, nil otherwise.
- `.teardownFailed` (:428-444): replace :442-443 with `state.account.message = teardownFailureMessage(reason: pendingTeardown.reason, stage: stage)`. The new private static func maps exactly the teardown table.

**HealthComp/App/HealthCompApp.swift**
- :223-225: `AccountView(store: …, hasPendingChallenge: store.hasPendingChallenge)`.
- `AccountSheet` (:295-336). Build:
  - `health` = `mainStore.healthAccess.map { AccountHealthSettings(access: $0, isReadFailing: mainStore.competition.publication?.dashboard.issues.contains(.authorizationUnavailable) == true, connect: { mainStore.send(.connectHealthTapped) }) }`
  - `liveMatchCount` = `accountLiveMatchCount(publication?.dashboard.competitions ?? [])`
  - On `AccountNotificationSettings`: `mutedPeople: AccountMutedPerson.list(…, muted: mainStore.competition.mutedOpponentIdentities)`, `mutesInFlight: mainStore.competition.muteOpponentIdentitiesInFlight`, `unmute: { mainStore.send(.competition(.muteTapped($0))) }`
  - Pass them in both the Staging and non-Staging initializers.
  - Add `.task { mainStore.send(.refreshHealthAccess) }` on the NavigationStack (:302).

**HealthComp/Features/Competition/MultiUserCompetitionTestLabView.swift** (DEBUG)
- Scenario enum (:8-24): add `welcomeChallenge = "welcome-challenge"` and `healthOnboardingChallenge = "health-onboarding-challenge"`. Wire them in `scenarioView` (:114-135) and add them to the exhaustive switch at :342-347.
- `MultiUserCompetitionAccountTestLabView` (:429-470):
  - Add `hasPendingChallenge` and pass it to `AccountView`.
  - For authenticated mode, pass `health: AccountHealthSettings(access: .requested, isReadFailing: false, connect: {})`, `liveMatchCount: 2`, and `notifications: AccountNotificationSettings(authorization: .denied, isRequestInFlight: false, request: {}, mutedPeople: muted, unmute: { id in muted.removeAll { $0.id == id } })`. `muted` is `@State` and starts as `[AccountMutedPerson(id: "remote-opponent:v1:hermes", name: "Hermes")]`.
  - The existing `openURL` override already prints the opened URL.

#### Server changes
None. The recipient-only preview (alternative A in §10 Q4) is PR 7's; an anonymous preview (B) would be more PR 7 work.

#### Tests
**HealthCompTests/MainTabFeatureTests.swift**
- `testOnboardingAsksOnlyForHealthBeforeTheCompetitionStarts` replaces :33-79.
  - The recorder returns `.notRequested`, so `.task` receives `onboardingChecked([.health])`.
  - `.scenePhaseChanged(.active)` does nothing.
  - Continue: `onboardingStepCompleted` makes `onboarding` nil, then `competition(.task)` is received.
  - `calls == ["health"]` and `startCount == 1`.
- Delete `testNotNowDefersNotificationsAndStartsTheCompetition` (:81-108).
- `testOnboardingShowsOnlyPermissionsIOSHasNotAskedFor` (:110-144) becomes `steps(health:)`: `.notRequested` → `[.health]`; `.requested` → `[]`; `.unavailable` → `[]`.
- `testClaimLinkDuringOnboardingShowsChallengeBeforeHealth` uses MainTabClaimRecorder, onboarding `[.health]` and a claim route.
  - Status becomes `.ready`.
  - `acceptClaimTapped` sets `acceptsClaimOnStart = true` and status `.idle`, with `requestCount == 0`.
  - Continue makes `onboarding` nil, then `competition(.task)`.
  - The publication triggers `processPendingClaim`: status `.claiming`, then `requestCount == 1`.
  - The success leads to path `[id]`.
  - Run it in both orders: route before `onboardingChecked`, and after.
- `testDecliningChallengeDuringOnboardingKeepsHealthStep`: the route is consumed, `onboarding` is unchanged, `acceptsClaimOnStart == false`.
- `testNewerClaimLinkClearsEarlierAcceptance`: after an accept, a higher-sequence route sets `acceptsClaimOnStart = false` and status `.ready`.
- `testClaimLinkFromBeforeNewAccountShowsWrongAccountWithoutClaiming`: `claimLinksBeforeAccountThrough = 5`, onboarding `[.health]`.
  - Route 5 gives status `.wrongAccount`, consumes 5, sets `lastHandledClaimRouteSequence = 5`, and leaves `requestCount == 0`, `onboarding` unchanged and `acceptsClaimOnStart == false`.
  - `.dismissClaimStatus` gives `.idle`.
  - Route 6 then follows the normal path and gives `.ready`.
- `testNotificationPromptWaitsForLiveOrPendingMatchThenDefersOnNotNow` uses TestClock with authorization `.notDetermined`.
  - A publication with only expired or declined challenges, or only completed matches, does nothing.
  - A publication with a `.pending` match (run once with `.incoming` and once with `.outgoing`) sets `.scheduled`. So does one with only a `.scheduled` match.
  - Advancing 600 ms receives `.notificationPromptReady` and sets `.presented`.
  - Not now sets `.finished` and records `"deferNotifications"`.
  - A further publication changes nothing.
- `testNotificationPromptTurnOnGoesThroughCompetitionAndCloses`: `.presented`, Turn On, receive `competition(.enableNotificationsTapped)` (in flight), receive `competition(.notificationAuthorizationRequestFinished(.authorized))`, then `.finished`.
- `testNotificationPromptSkipsWhenDeferredOrDecided`: deferred `true` leads to `.notificationPromptSkipped` and `.finished`. Authorization `.denied`, or nil, never schedules.
- `testNotificationPromptWaitsForClaimSheetAndOnboarding`: status `.ready`, or onboarding non-nil, means no scheduling. When `.notificationPromptReady` arrives while the sheet is up, the phase goes back to `.unscheduled`.
- `testNotificationPromptWaitsForChallengeSheet`: with `challengeSheetVisibilityChanged(true)`, a publication with an outgoing `.pending` match does not schedule. `challengeSheetVisibilityChanged(false)` sets `.scheduled`, and 600 ms later `.presented`.
- `testHealthAccessRefreshesOnAccountAndForeground`:
  - `refreshHealthAccess` leads to `healthAccessLoaded(.requested)`.
  - `scenePhaseChanged(.active)` with `healthAccess != nil` receives `competition(.sceneBecameActive)` and `refreshHealthAccess`.
  - With nil, only the former.
- `testConnectHealthRequestsAccessThenRereads`.
- `testStopClearsInFlightInviteClaimState` (:197) also asserts `acceptsClaimOnStart == false`, `isChallengeSheetOpen == false` and `notificationPrompt == .unscheduled`.
- `PermissionOnboardingRecorder` (:960-990) takes `health: HealthAccessStatus` and `deferred: Bool`.

**HealthCompTests/CompetitionFeatureTests.swift**
- `testSceneBecameActiveRereadsNotificationAuthorization`: with the client returning `.denied` and state `.authorized`, `sceneBecameActive` receives `notificationAuthorizationLoaded(.denied)`.

**HealthCompTests/AccountFeatureTests.swift**
- `testDisplayNameValidationStaysLocalAndRejectsReservedOrUnsafeInput` (:61-74): "Former competitor" and " Former competitor " give `.reservedDisplayName`; the other values give `.invalidDisplayName`. Add the same check through `saveDisplayNameButtonTapped` in authenticated mode.
- `testDeletionFailuresStayWithDeleteRow`: with `isDeletingAccount`, `.operationFailed(.operationFailed)` gives `.deleteFailed`; `.reauthenticationRequired` gives itself; `.cancelled` gives nil. Assert `isDeletionMessage` for both.
- `testFailureTitlesNameTheStepThatFailed`: `failureTitle` for every case in the teardown table, plus `.tryAgain` and `.invalidCredential`.
- `testSignOutMessageCountsLiveMatches`: `accountSignOutMessage` for 0, 1 and 3 equals the exact strings.
- `testLiveMatchCountCountsActiveEndsTodayAndTallying`: scheduled, pending and completed are not counted.
- `testMutedPeopleResolveNamesFromMatches`: an unknown identity is dropped, the result is sorted, and a duplicate identity appears once.
- `testHealthSettingsState`: the four input combinations give the right `.off`, `.unavailable` or `.asked`.

**HealthCompTests/AppFeatureTests.swift**
- :1383 expects `.signOutFailed`. :1455 expects `.signOutFailed`. :2233 expects `.signOutCleanupFailed`.
- :565-567 expects `.accountDeleted` when the reason is `.accountDeleted`. The `teardownCompleted(… .accountDeleted)` assertions at :1618 and :1857 add `$0.account.message = .accountDeleted`.
- :1745 and :1791 expect `.deleteFailed`.
- New `testTeardownFailureMessageNamesTheFailedStep`: for each (reason, stage) row, seed a running `pendingTeardown`, send `teardownFailed`, and assert the message.
- New `testPendingChallengeLinkShowsOnlyBeforeAuthentication`: a routing client yields a claim envelope.
  - While signed out, `hasPendingChallenge` becomes true.
  - Through `.displayNameRequired`, a name submit and profile storage success: `mainTab.claimLinksBeforeAccountThrough` equals the envelope's sequence.
  - Through a bootstrap that succeeds without a name (existing account): it stays 0.
  - Profile storage success makes it false.
  - The same envelope while authenticated leaves it false.
  - The route is never consumed.

**HealthCompTests/RemoteCompetitionClientTests.swift:3168**: the new banner string.

**HealthCompUITests/MultiUserCompetitionUITests.swift**
- `testWelcomeDisclosesSharedDerivedActivity` (:353-392) becomes `testWelcomeIsSignInAndPrivacyPolicyOnly`.
  - Assert "Welcome to HealthComp", `account.sign-in-with-apple`, and that "HOW TO READ IT" and "Your rings" do not exist.
  - Keep the Privacy Policy checks (≥44 pt, opens the URL).
- New `testWelcomeWithPendingChallengeAsksToSignIn` (`welcome-challenge`): "You have a challenge", and `account.subtitle` equals "Sign in with the account it was sent to."
- New `testChallengeHealthOnboardingFramesTheMatch` (`health-onboarding-challenge`): the title and body strings, `onboarding.continue`, and the derived-data disclosure still present.
- `testAccountEditingAndPrivacyBoundariesRemainAccessible` (:434-437): expect "That name is reserved. Try another."
- `testAccountDeletionConfirmationCanBeCancelledSafely` (:443-471):
  - Tap `account.delete` on the Account root; no "Delete Account" navigation bar.
  - Alert message is the new string.
  - After Cancel, `navigationBars["Account"]` exists.
- `testAccountDeletionFailureRemainsVisibleOnDeletionPage` (:473-493) becomes `testAccountDeletionFailureShowsUnderDeleteRow`: `account.message` equals "Couldn’t delete your account. Check your connection and try again.", and `account.delete` is enabled.
- New `testSignOutAsksFirstAndStatesTheEffect`:
  - Tap `account.sign-out`. Alert "Sign out?" shows the N=2 message.
  - Cancel: no progress.
  - Tap again, then `account.sign-out.confirm`. The `account.sign-out` value becomes "Signing out".
- New `testNotificationsPageOpensSettingsAndUnmutes`:
  - `account.notifications` shows "Turned off in iOS Settings".
  - `account.notifications.settings` displays a static text equal to `UIApplication.openNotificationSettingsURLString`.
  - The button labelled "Unmute Hermes" removes the MUTED section.
  - The page also passes `performAccessibilityAudit`.
- New `testHealthPageOpensSettings`: `account.health` shows the footer string; `account.health.settings` displays `UIApplication.openSettingsURLString`.
- `launch(_:appearanceArguments:)` (:876-879) and LocalCompetitionLifecycleUITests.swift `launch` (:623-630) append `"-healthcomp.colorHintSeen", "YES"`, so scoreboard layouts are deterministic across test order. Neither lab parser rejects single-dash arguments.
- Accessibility identifiers:
  - Added: `account.health`, `account.health.connect`, `account.health.settings`, `account.notifications.settings`, `account.notifications.unmute`, `account.sign-out.confirm`, `account.subtitle`.
  - Removed: `account.delete.open`.
  - Moved: `account.delete` is now the Account-root row (it was the button on the deleted page).
  - Unchanged: `account.notifications`, `account.sign-out`, `account.recover-profile`, `account.retry`, `account.message`, `account.privacy`, `account.privacy-policy`, `account.delete.confirm`, `account.delete.browser.confirm`, `competition.notifications.enable`, `onboarding.continue`, `onboarding.notNow` (now also used on the in-context notifications sheet), `competition.claim.dismiss` (PR 6's; also the Done button of `.wrongAccount`).
- Visual check on the Mac mini: the color hint, both new pages and the Welcome screen, light and dark, at XS and AX5.
- Check on the iOS 18.5 simulator whether Settings → Apps → HealthComp shows a Health entry. Keep "Open Settings" either way (the footer's path is correct regardless). If there is no Health entry, ask the owner whether to drop the button on the Asked page. (This was its second open question; it is a check, not a decision.)

#### Risks and sequencing
- **PR 1 first.** This PR rewrites strings PR 1 sets in AccountView, AccountSettingsView and PermissionOnboardingView. It uses none of PR 1's formatting helpers. The issue-banner line at CompetitionSharingView.swift:1131 is untouched by PR 1.
- **PR 6 and PR 7 share regions.**
  - MainTabFeature claim branches: `routeReceived` :222-238, `acceptClaimTapped` :306-310, `declineClaimTapped` :312-327, `.competition(.publication)` :438-459. Also ClaimCompetitionView, and the account-code block in AccountSettingsView `profileSection` :114-131.
  - Whichever lands second rebases. Its contract: Accept before start only records `acceptsClaimOnStart`, and a newer link clears it.
  - PR 6 adds no challenge preview. PR 7's preview is covered in §10 Q4 and PR 7 Risks 7.
  - PR 6 does not ship `.wrongAccount`, so this PR adds the case itself; the new-account check needs no server answer.
  - PR 6's Challenge sheet keeps `isChallengePresented` in MainTabView. The `onChange` this PR adds must stay attached to that state.
  - PR 7 adds a `.challengeLink` route kind. AppFeature's pre-sign-in check tracks claim links only; whichever of PR 7 and PR 8 lands second decides whether Welcome also reacts to a challenge link.
- **PR 3 / PR 2** edit CompetitionScoreboardPanel. This PR adds one view call after `periodRow`.
- **PR 4** owns Home and f-errors.
  - If PR 4 lands first, this PR adds `CompetitionColorHint()` to the single-live large scoreboard. If PR 8 lands first, PR 4 adds it.
  - f-errors may rewrite the banner sentence, but it must keep pointing to Account → Health.
  - Use PR 4's "Live" predicate for the sign-out count if one exists.
- **PR 5 / f-mute** keep `mutedOpponentIdentities` and `muteTapped`. The muted list depends only on those.
- **HealthKit hides read denial,** so Account → Health can never show a definite "On". The Asked page is honest about that.
- **The privacy disclosure leaves Welcome.** It remains on the Health explainer before any read, on Account → Privacy, and behind the Privacy Policy link. Flag this in the release checklist's App Review notes.
- **Existing users:** anyone who tapped "Not now" at the old onboarding is never prompted again, because the deferred key is reused. Anyone never asked is prompted at their next launch with a pending challenge or live match.
- **No server, migration or Edge Function change.** Installed older app versions are unaffected.
- **Sign-out is global** (verified at SupabaseConfiguration.swift:587-591). The copy avoids "this iPhone" for that reason. Making it device-local would be an auth change outside this PR.

#### Open questions
Moved to §10: Q4 (who sees the sender's name before accepting). The Settings check that was its second question is now under Tests.

## 10. Open questions

These are for the owner only. They are merged across PRs, deduplicated and ranked by importance. Each default is what the PR sections build if the owner doesn't answer.

### Decisions that change scope, privacy or the server

**Q1. Does the server work ship this round?** (PR 7, and the server part of PR 5)
- **Why it matters:**
  - PR 7 is all-or-nothing. Cancel Challenge, Cancel Match, the claim preview, in-app delivery and challenge links all need the migration in production first.
  - If PR 7 is deferred, PR 6 ships alone, a link that isn't on the sender's phone can only expire, and f-claim and f-uuid stay open.
  - PR 5's server part (the Edge Function stops alerting for score uploads and results) is independent. If it is deferred, the server's generic pushes continue in the same per-match thread, and the duplicate result banner stays until it ships.
- **Default:** yes. Both are promoted to Staging first, then production, before the TestFlight build.

**Q2. How much should the rules card's lock row tell you the other person can see?** (PR 3, f-rules; shown on the challenge, claim and create screens)
- **Why it matters:**
  - The other person can read every `daily_score_revisions` column for the match. That is more than points and ring percentages: it includes your Move Time/Roll mode, why a day has no data (`availability_reason`, for example `summaryPaused` or `missingMoveGoal`), and when your iPhone evaluated each score (`evaluated_at`).
  - This is consent copy. The privacy policy (`web/privacy.html:70-73`) already says the other person sees "availability" and "Activity modes", but not the update time.
  - The title and the exact-string UI assertions stay the same whatever the answer.
  - If the update time stays in the card, PR 8 edits the privacy policy to match.
- **Default:**
  - Keep the title "Hermes sees your daily points and rounded ring percentages".
  - List all three in the detail line: "Also whether you use Move Time or Roll, why a day has no data, and when your iPhone last updated your scores. Your Health data stays on your iPhone."

**Q3. May server pushes name the other person ("Naren challenged you")?** (PR 7; PR 5 keeps generic pushes)
- **Why it matters:** `web/privacy.html:78-79` and the multi-user plan (`docs/plans/2026-08-11-multi-user-supabase-implementation.md:837`) promise generic alert text. Named pushes need `sourceDisplayName` in the lease and in the sender's validation, plus edits to the privacy page and the plan doc in the same release.
- **Default:** generic. "New challenge" / "Open HealthComp to accept or decline.", "Challenge declined" and "Match cancelled". No `sourceDisplayName`, no privacy-page edit.

**Q4. Who can see who sent a challenge before accepting it?** (PR 8 and PR 7, f-claim)
- **Why it matters:**
  - The PR 8 section was written as if nothing ever shows the sender. The PR 7 section already designs alternative A below. The question is reconciled here.
  - Before sign-in, nothing can know the sender: the token is a bearer secret and the preview needs a session.
  - The options:
    - **None:** no name anywhere before accepting.
    - **A, authenticated and recipient-only:** PR 7's `preview_competition_invite` returns the sender's name only to the bound account. The claim sheet then reads "Naren challenged you", with its loading and error states. An existing account that isn't the recipient learns so before Health instead of after it.
    - **B, anonymous:** the same preview before sign-in, so Welcome could say "Naren challenged you". Anyone holding the link learns the sender's display name.
  - A ships only with the server work (Q1). The Welcome and claim-sheet copy depend on the choice.
- **Default:**
  - **Before sign-in:** no name. Welcome reads "You have a challenge / Sign in with the account it was sent to." Option B is not built.
  - **After sign-in:** A, through PR 7's preview, if the server ships this round. Otherwise the claim sheet keeps "Join this match?" with no name.
  - With in-app delivery (PR 7) the Needs-you row also names the sender after sign-in.

**Q5. Should opening a live challenge link on the wrong account say the challenge is for someone else?** (PR 6 and PR 7; merged from both sections)
- **Why it matters:**
  - Saying so tells whoever holds the link that it is live and bound to an account.
  - Migration 018 and `testClaimFailuresRemainPrivacyCollapsed` keep this case collapsed into `invite_unavailable`.
  - A yes changes the preview and claim RPCs (`invite_for_another_account`, 403), the Edge mapping, `classify`, a new `.wrongAccount` claim status and its copy, and the pgTAP identical-error test.
  - This is all PR 7 work. PR 6's file list doesn't change either way.
  - It does not affect PR 8's new-account sheet, which is decided on the device and reveals nothing.
- **Default:** no. Keep "Challenge unavailable" and build nothing. If the owner says yes, PR 7 returns `invite_for_another_account` for live links only and reuses PR 8's `.wrongAccount` status and copy: "This challenge is for someone else" / "Only the account it was sent to can accept it. Ask the sender to challenge this account."

**Q6. What can a challenge-link owner do about unwanted challengers?** (PR 7)
- **Why it matters:** a stranger with your link can't be muted, because mute needs an accepted shared match (`20260811000650:100-116`). They can also challenge again, with a push, after every decline. Each fix is a migration plus an app change:
  - (a) widen `set_notification_mute`, plus a Mute item on the incoming screen
  - (b) a decline cooldown check in `create_competition_invite`
  - (c) `reset_my_challenge_link()`, plus an Account item
- **Default:** accept the risk for the 2–5 person beta and build none of them. The Account caption and section text say only what is true: "Anyone with this link can challenge you. You still choose whether to accept."

**Q7. Should the server re-share a challenge's link so it works on every device, or is PR 6's local replay enough?** (PR 7)
- **Why it matters:**
  - A yes means building:
    - a service-role RPC (`load_invitation_reshare_key`)
    - `deriveInviteTokenV1` moved into `_shared`
    - a new `share-competition-invite` Edge Function
    - a `shareInvite` client closure
    - their Deno and pgTAP tests
  - PR 6's `restoreInvite` would then fall back to it (and its replay store could be deleted).
  - A no means none of that gets built.
- **Default:** local replay only. PR 7 builds Cancel Challenge and no re-share. With in-app delivery the link is only a fallback for 1.0.2 recipients, and a challenge whose link isn't on this phone can now be cancelled and sent again. Create keeps returning today's 409 on a pending conflict.

**Q8. Who may cancel a scheduled match?** (PR 7, Match menu polish)
- **Why it matters:** the answer changes the `cancel_competition` RPC check, and whether the recipient sees the menu item.
- **Default:** either participant, until local midnight at the start of Day 1 in the match's time zone.

**Q9. Should challenge pushes go to 1.0.2 installs, which can't show the challenge?** (PR 7)
- **Why it matters:** not sending them needs a client-capability flag on `register_current_device_installation`, which changes the registration RPC and both apps.
- **Default:** send anyway. The beta testers auto-update through TestFlight.

### Lower-stakes product questions (defaults built; answer only to override)

The PR sections raised these. Each is a product choice with a sensible default already built in.

**Q10. Should the server keep a result alert as a fallback?** (PR 5)
- **Default:** no. The app is the only source of result notifications, because the server payload is generic by design and can't name the person or format numbers in the user's locale.
- **The alternative** needs Q3 = named and a lease migration. The app would then post its own result passively when a server push in the same thread was already delivered.
- **Cost of the default:** a result arrives when the app next evaluates, which for most users is within hours.
- **Installed 1.0.2 builds** lose the server result alert too, and they still have the global one-post-per-evaluation cap (the f-lostresult bug), so on 1.0.2 a second result that finishes in the same evaluation is never announced at all. The server can't tell app versions apart (work items carry no app version), so the only way to protect them is to keep the `result` alert until testers are on the new build.

**Q11. Is a closed 0–0 day "no data" or "tied"?** (PR 3, f-chart and f-chips)
- **Default:** no data. The strip draws it hatched, the result's day counts skip it, and the rows still show "0" and "0".
- **The alternative:** treat it as tied.

**Q12. Should the Awards page be removed?** (PR 4, f-rivalry)
- **Default:** yes, following the mockup's "a win is the award". The victory still shows on the result screen, and the completion award is dropped.
- **The alternative:** keep an Awards tab of victories.

**Q13. Should a lone scheduled match lead Home as the big card when nothing is live?** (PR 4)
- **Default:** yes, as today, so a new match isn't reduced to a row between acceptance and Day 1.

**Q14. What should the end/start line say when the phone is in a different time zone from the match calendar?** (PR 1, f-midnight)
- **Default:** name the calendar's last day and add its zone: "ENDS TUE NIGHT PST".
- **The alternative:** the phone-local moment ("ENDS WED 5:00 PM"), which no longer matches "LAST DAY".

**Q15. What should the Today panel's footer say about privacy?** (PR 2)
- **Default:** "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone."
- **Why not the mockup:** its "Hermes sees your points, not your rings" contradicts the per-ring percentages the other person really receives, and the Account disclosure.

**Q16. Should the other person's "0" show before your today has synced?** (PR 2)
- **Default:** show their real number ("-- TODAY 0"), because a 0 there is an accepted score.
- **The alternative:** dash both sides, as the mockup does.

**Q17. How precise should the breakdown be?** (PR 1)
- **Default:** whole parts, with the remainder given to the largest part, so the parts add up to the day total shown above them.
- **The alternative:** one decimal on the parts, with the total also in decimals.

**Q18. Should History's record rows open anything?** (PR 4)
- **Default:** no. They are a summary, and each week below them opens its result.
- **The alternative:** a per-person screen, which needs a new route and a new screen.

**Q19. Should a dismissed closed-challenge row stay dismissed after relaunch?** (PR 4)
- **Default:** in memory only. A dismissed row can come back after a relaunch within its 24 hours.

**Q20. Should the challenge-expiry reminder end with "Send it again?"?** (PR 5)
- The PR 5 section said to add it if PR 6 gave a pending challenge a re-share action, and PR 6 now does (Share Link Again).
- **Default:** still leave it out. Copy stays minimal, and tapping the reminder opens the challenge screen, where Share Link Again and (with PR 7) Cancel Challenge already are.

## 11. Claude's calls

Claude made these calls, not the owner. The owner can overrule any of them. They are grouped by where they apply.

**Top level (§4)**
- Home uses layout A: no single hero once 2 or more matches are live; equal cards ordered by end time, soonest first; groups Needs you / Live / Up next / Recent results; with exactly one live match the card is today's large scoreboard.
- Finished results move off Home into History on their own 3 days after the week ends; a swipe archives them sooner.
- Conceding a live match is out of scope this round.
- The server work (the server part of PR 5, and PR 7) is designed now. Whether it ships this round waits on the owner (§10 Q1).
- Merge order: PR 1, then PR 4 before PR 5 and PR 6 (routing; `challengeAgainTapped` and `ownProfile` are written once against today's fields). PR 3 can land either side of PR 4.

**PR 1**
- **Each day is rounded on its own; the week total is rounded once from its exact value.**
  - There is no week-level remainder rule, so the seven shown days can miss the total by up to 3 points.
  - A day keeps one number everywhere it appears: the chart, the drawer, the VoiceOver row, "HOW TODAY ADDS UP", the win color and the "N of 7 days" count.
  - The total stays tied to the exact centi-point ledger, so the shown winner matches the decided outcome. No screen adds up the seven days.
  - (The PR 1 author said the audit complained about this gap. It didn't: f-round was about the lead line versus the scores, and about mixed decimals.)
  - The result tie-break compares only the two totals, so it is unaffected. The "HOW YOU SCORED" parts still add up to the whole total.
- **Results are shown in whole points, with one exception.** When a decided match would show the same whole number on both sides, the totals, margin and VoiceOver use 2 decimals ("412.30 – 412.00").
- **Result wording names the winner** ("Hermes won"), because "Won" under someone else's name was ambiguous.
- **A zone suffix is added only when the calendar's UTC offset differs from the phone's** (§10 Q14).
- **"Now" means the projection's time, not the wall clock.** It sets the year suffix and the moment style's 6-day window.
  - Screens that draw a match pass `competition.evaluatedAt`. Home and History award and rivalry lines pass `publication.evaluatedAt`.
  - On real matches this equals the wall time of the latest refresh. In the Test Lab and UI tests it keeps labels and captures stable after January 2027.
  - The `Date()` defaults remain only for the standalone script and the unit tests.
- **Follows from the above:**
  - The presentation overload of `competitionStatusText` drops its `now:` parameter and reads `competition.evaluatedAt`.
  - `CompetitionWeekChart` replaces its `ownerName` property with `let now: Date`.
  - `CompetitionRivalrySummaryCard` gains `let now: Date`.
  - The tally-deadline call at `CompetitionDetailView.swift:153` passes `now:`.

**PR 2**
- **Real matches score `sum(min(200%, ring))`, capped at 600** (answered from the code).
  - Ring rows, the "haven't synced yet" preview, the Week bars and "HOW YOU SCORED" split by the capped per-ring percentages.
  - This uses a display-only `ActivityScoringPolicy.remoteWireV1` (perRingCap 200), carried on `LocalCompetitionDayPresentation.scoringPolicy` (default `.healthKitCompatibility`).
  - Remote genesis and `remoteEvidence` don't change.
- **The real-match footer always reads** "1 point per 1% of each ring, up to 200% per ring. Your ring values stay on this iPhone." "Capped at 600" appears only in the local fixture.
- **Test Lab days use `.remoteWireV1`, with no ring over 200%.** Day 2: Move 1000/500, Exercise 60/30, Stand 12/10 = 520. Day 3: 180+150+100 = 430.
- **On-device snapshots persist in the profile-scoped inventory cache**, so "HOW YOU SCORED" survives relaunch for finished real matches.
- **The inventory cache file is set `isExcludedFromBackup = true` after every save.**
  - Exact Health values then stay out of iCloud and computer backups (privacy page line 46, App Store 5.1.3(ii)).
  - There is no schema change.
  - The cost: a restored phone re-downloads its matches and loses "HOW YOU SCORED" for finished ones.
- **A real match can never show an unknown-stand reading with points** (answered from the code). `RemoteScoreRevisionWireV1.init` throws `invalidMode` before the owner activity is built. "Stand or Roll" is fixture-only.
- **The unknown-stand sync failure on a live real match is out of scope.** Scores never upload, and the match shows as `.discoveryUnavailable`. It goes to its own `bugfix/` PR, because fixing it is a scoring decision.

**PR 3**
- **The other person's synced day with no score reads "No data", not "Not synced"**, matching the tally card.
  - This adds `LocalCompetitionDayPresentation.opponentReportedNoData` (default false).
  - The remote projector sets it at `RemoteCompetitionClient.swift:1878-1890`. That is a one-argument edit in PR 2's area, so whichever PR lands second keeps the argument.
- **The Day 1 line ("Day 1 is Wednesday. Points start counting at midnight.") is the same for both people in any time zone** (answered from the code). Scores come from each person's own Activity summary for that calendar date. Only the tally deadline is a single instant, so only it falls back to the moment style.
- **The remote tally waits on whoever has missing day rows** (yours first, then theirs, then stability). Your rows that carry an unavailable reason count as in.
- **A closed 0–0 day counts as no data** (§10 Q11).
- **The tie result notification is titled "All square with {Name}"**, so a tie has one name everywhere.

**PR 4**
- **PR 4 owns the Avatar polish row.**
  - It adds `CompetitionFeature.State.ownProfile`, including the AppFeature edits at :96, :356 and :479, and `MainTabView` reads `competition.ownProfile`.
  - The `accountName` parameter chain is dropped.
  - The `AppFeatureTests` updates and `testRenameUpdatesCompetitionOwnProfile` move from PR 6 into PR 4.
- **`challengeAgainTapped` is written inline, with no `prefillRecipient` extraction.** `rematchTapped` is unchanged.
- **PR 4 doesn't wait for PR 3.** If `CompetitionScheduledSummary` is already on main, the scheduled hero uses it; otherwise PR 3 makes that swap when it rebases.
- **Home cards get no MUTED or PROVISIONAL tag.**
- **A dismissed closed row is hidden in memory only** (§10 Q19).

**PR 5**
- **"600 today" posts at most once per day, without new cross-match state.**
  - New helper `dailyMaximumRecordedInAnotherMatch`: a match's `dailyMaximum` is recorded as `.suppressed(.superseded)` when another `.active`/`.endsToday` match already has a `dailyMaximum` record for its own current day.
  - No CompetitionCore change. Covered by `testDailyMaximumIsNotRepeatedByALaterMatchTheSameDay`.
  - The PR 5 author was right that durable per-match records alone don't stop a second post.
- **The sibling check counts any recorded disposition.** Accepted gap: if the first match's post was suppressed by its own 2-per-day budget, no "600 today" posts that day.
- **A second "600 today" is still accepted in two rare cases:** matches in different time zones near midnight, and a sibling that fails to load.
- **`CompetitionNotificationLifecycle.isLiveDay` is added** in `CompetitionNotificationModels.swift`. `liveMatchCount` and the sibling check both use it.
- **Tapping a result whose week has moved to History still opens that match** (answered from PR 4's spec). History weeks stay in `publication.dashboard.competitions`, PR 4 rewrites `resolve`, and PR 4 lands first. PR 5 changes no routing.
- **If PR 5 is ever built before PR 4,** it adds only a minimal visible-id guard for PR 4 to replace.

**PR 6**
- **PR 6 relies on these PR 4 pieces:** the lapsed-pending → `.expired` projection, its 24 h retention, the `direction:` payload on closed cases, and `challengeAgainTapped`.
- **Closed rematch children count as "no child"** (`.expired`, `.declined`, and PR 7's `.cancelled`), so "Rematch {Name}" comes back. They are matched without bindings.
- **The "Challenge expired" case is removed from `CompetitionInviteView`**, along with the expiry check in `pendingOutgoingChallenge`. PR 4's projection and its closed view cover that case.
- **PR 4's "Challenge {Name} Again" stays the one prefilled open of the sheet.** It is rewritten onto the slot state, and `prefillRecipient` never exists.
- **Cancel Challenge lives entirely in PR 7, app wiring included.** PR 6 merges without waiting. `RemoteCompetitionClient.swift:79` stays `coordinator.unsupported(id)`.
- **The replay store saves only after a create succeeds.** The lost-response case is a known gap, which PR 7 narrows with Cancel Challenge and in-app delivery.
- **The replay store is built whether or not PR 7 ships this round.** It stays unless the owner picks the server re-share (§10 Q7).
- **PR 7's own-invite preview reuses PR 6's `.ownChallenge` copy.**
- **The rematch control moves after the content at accessibility sizes,** so it doesn't cover the screen at AX5.

**PR 7**
- **PR 7 is written against PR 1, PR 4 and PR 6 as specified**, not against main.
- **`cancel_competition(uuid)`, returning jsonb `{competition_id}`, is the only cancel RPC.** `decline:` means declining an incoming challenge; `cancel:` is a new closure.
- **Identifiers use PR 6's `competition.invite.*` namespace.** `competition.create.share` is kept.
- **The Cancel Challenge dialog says "Sam won't be able to accept it."**
- **Create never returns 200 with the existing link.** A pending conflict stays 409 → PR 6's `.alreadyChallenged` → Open Challenge.
- **The + sheet keeps PR 6's sent state, and its caption adds "{Name} gets it in HealthComp."** Only the "Challenge Maya?" link sheet closes and pushes the challenge.
- **Conflicts are derived from the dashboard** (`.challengedYou`, `.inMatch`). Server errors map to `InviteCreationFailure.conflict` plus a reconcile.
- **An own invite in the preview goes through PR 6's `.forbidden` → `.ownChallenge`.**
- **Declined and cancelled items use PR 4's closed row in Up next.** Only `.cancelled(at:)` is new.
- **`/c/*` is added to the AASA file**, so challenge links open the app directly. `web/challenge.html` is the fallback.
- **No local expiry reminder for remote incoming challenges.**
- **The bound recipient may accept in the app without the token.** The contract doc is amended at :44-46.
- **The challenge-link copy doesn't claim link owners can mute strangers.**

**PR 8**
- **The challenge Welcome subtitle is "Sign in with the account it was sent to."**
- **The display-name screen never mentions a challenge.** A new account can't be the recipient.
- **A claim link that arrived before a new account existed is consumed on the device.** No claim request is sent, and the claim sheet opens at once in `.wrongAccount`. PR 8 adds that case, because PR 6 doesn't ship it.
- **A pending challenge, incoming or outgoing, also triggers the one-time notifications prompt.** The prompt waits while PR 6's Challenge sheet is open.

**Made during assembly** (Claude reconciled these where the PR sections disagreed)
- **Ring panel polish row:** PR 2 owns it alone. PR 3's ActivityRingsView edits and their tests are dropped, because PR 2's rewrite deletes that code. PR 3's `TodayBreakdown` edit applies only if PR 3 lands before PR 2.
- **PR 5's notification copy follows the shared formatter:**
  - the result tie title and the summary tie sentence read "All square with {Name}" (PR 3)
  - the merged competitionEnded title reads "Final score pending"
  - the incoming expiry reminder is marked fixture-only (PR 7 §3)
- **PR 6 Design G and its server notes match PR 7's final contract:** create stays 409, there is no server re-share by default, and the replay store stays.
- **PR 6 no longer refers to `prefillRecipient`**, and its AppFeature `ownProfile` edits and tests are listed only under PR 4.
- **PR 8's sender-name question is merged with PR 7's recipient-only preview** (§10 Q4).
- **PR 8's wrong-account references point to §10 Q5**, and PR 8 adds `.wrongAccount` itself.
- **New risk:** whether PR 7's preview can run on PR 8's pre-Health claim sheet (PR 7 Risks 7).
- **PR 8's Settings → Health question is now a verification step**, not a decision.
- **PR 5's rationale for leaving out "Send it again?" was updated** now that PR 6 adds Share Link Again (§10 Q20).
- **PR 4's note that PR 7 should materialize closed descriptors** now points at PR 7's `list_challenges`.
- **Sequencing:** the "PRs 2–5 and 8 in parallel" plan is kept for building. PR 4's merge-before-PR 5 and PR 6 rule is kept for merging.
