# Empty-owner completed-result replay implementation plan

**Goal:** Reconstruct a server-confirmed best-available result when the local
participant has never submitted an accepted score, preserving strict validation.

**Architecture:** Keep the change in the Core result-replay branch. An absent
owner ledger represents no accepted rows, not a missing participant. Construct
an empty ledger from the already validated remote configuration and pass it to
the existing result-window validator; never invent accepted rows or skip checks.

**Tech stack:** Swift CompetitionCore, XCTest; no dependency or server changes.

## Evidence and scope

Source baseline is b24ecbd5437144b1c03364302343edda610af667. Staging's alternate
existing account reaches Sharing after clean retirement of the previous local
profile, but displays a competition-refresh warning and no completed history.
A read-only aggregate found one completed result involving that account and no
accepted score revisions belonging to it. Its local journal contains remote
configuration and clock transitions, but no accepted score or result events.

One controlled pull-to-refresh preserved the warning. These observations motivate
the synthetic regression; they do not independently identify the thrown runtime
error or prove this candidate fix repairs the installed app.

Prefer an empty comparison ledger at result replay over initializing ledgers for
every participant at configuration time, which changes more state. Reject bypassing
owner-window validation or manufacturing a zero-score accepted revision. Keep
server result hashes, deadlines, identities, immutable history, and stable-result
completeness checks unchanged. No schema, grants, SDK fork, auth changes, staging
data edits, account switching, invitation, or production action is in this slice.

## Task 1: Baseline and failing Core regression

Files: `Modules/CompetitionCore/Tests/CompetitionCoreTests/RemoteCompetitionReplayTests.swift`.

1. Use the isolated `bugfix/empty-owner-result-replay` worktree.
2. Run the existing replay tests with one Swift build worker and one owned scratch
   directory: `swift test --package-path Modules/CompetitionCore --scratch-path
   /tmp/healthcomp-empty-owner-core.5jojzI --jobs 1 --filter RemoteCompetitionReplayTests`.
3. Build synthetic signed/hashed result fixtures using existing fixture helpers.
   The owner has seven deadline-missing days and no score event. The opponent has
   ordinary accepted rows. Assert replay reaches completed with an owner loss,
   the same result hash, and no fabricated owner ledger entries.
4. Run the new named test alone. Require a real domain-transition failure before
   changing Core. Do not count compiler failures as regression evidence.

## Task 2: Minimal fix and fail-closed controls

Files: `Modules/CompetitionCore/Sources/CompetitionCore/CompetitionEventStore.swift`
and the Core test above.

1. At shared-result replay, replace the mandatory existing-owner-ledger binding
   with an existing ledger or a newly constructed empty `RemoteScoreLedger` using
   configuration competition, owner, schedule, and policy.
2. Keep the existing owner-window matcher and deadline/basis/hash checks intact.
3. Verify the original regression passes, plus rejection of accepted owner rows
   without cached evidence, premature deadline results, and stable missing rows.
4. Include a both-participants-empty best-available tie case. Ensure result replay
   remains atomic on rejected input and idempotent through the existing journal
   contract rather than a new repair path.
5. Run all Core tests using the same bounded scratch directory.

## Task 3: Runtime coverage, review, and integration

Files: `HealthCompTests/RemoteCompetitionRuntimeTests.swift` as needed for a
synthetic full-history case with accepted opponent scores and an empty owner.

1. Add the full runtime regression at the existing remote API fixture seam.
2. Serialize focused iOS tests and full integration gates; do not create a test
   clone pool or new private-data fixtures. Preserve current Simulator state.
3. Obtain independent review before integration; no new reviewer subagent is
   authorized by this plan. Conventionally commit the reviewed logical fix,
   publish a PR, verify exact-head CI, and integrate through the repository rules.
4. Only after review/integration select the exact new Simulator artifact, perform
   a state-preserving installation, and verify alternate-account completed history
   with one refresh. Keep source/test evidence distinct from that pending runtime
   gate and from physical/production acceptance.

## September 9 local execution and iOS verification checkpoint

- Existing Core replay baseline: 12 tests passed before test/source edits.
- First new scoreless-owner test failed with invalidDomainTransition at sequence
  13 before the production change. The expanded five-case run had exactly two
  failing positive cases (scoreless owner and scoreless tie) and three passing
  rejection controls. This is actual RED evidence, not a compilation failure.
- The empty validation-ledger change made all five focused cases pass.
- Full Core suite: 246 tests, zero failures, 5.214 seconds test execution.
  The original package compilation used one worker and took 17.86 seconds.
- The iOS runtime fixture reconstructs the same immutable result from both
  participant perspectives using separate stores. It passed as a focused test;
  all 26 RemoteCompetitionRuntimeTests then passed, followed by all 626 iOS
  application unit tests. Result bundles independently report zero failures and
  zero skipped tests. These are local tests, not GitHub Actions results.
- Added duplicate-result replay verification: the already completed journal
  cursor stays unchanged on replay of the same result. The final full Core suite
  passed 246/246 in both Debug and Release after that assertion was added.
- Xcode 26.6 with the iOS 18.4 runtime ran the application tests using fixture
  configuration, ad-hoc signing, one Simulator destination, and parallel testing
  disabled. The sole newly created disposable test Simulator was shut down and
  deleted afterward. The existing staging and fixture Simulators were preserved.
- XcodeGen 2.46.0 generated the project twice without changing any of the three
  checked project/scheme files. Supabase layout, app privacy manifest, and diff
  whitespace checks passed.
- Candidate changes remain uncommitted and unreviewed in the purpose-named
  bugfix worktree. The old b24ecbd staging app remains installed and its alternate
  account remains mounted. No new staging candidate is selected or qualified.
- Scratch directories: /tmp/healthcomp-empty-owner-core.5jojzI (457 MiB) and
  /tmp/healthcomp-empty-owner-ios.XEIUMJ (1.6 GiB) at checkpoint. Keep their test
  receipts; reuse them for remaining verification instead of duplicating caches.
  No local build is running. No container stack or reviewer subagent was started.
- Independent review permission has been requested. Review and exact-head PR
  integration gates remain before selecting/installing the new staging artifact.
