# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-19
**Selected application baseline:** `dd0ed683a78de216f622e2a958baeda1cb996e46`
**Selected release artifact:** `dd0ed683a78de216f622e2a958baeda1cb996e46`;
selected for the remaining staging and physical-device gates, but not yet
cleared for production.
**Release status:** Not production-ready

Status meanings:

- **PASS** — direct current-state evidence exists for the stated scope.
- **PARTIAL** — some required evidence exists, but the gate is not complete.
- **BLOCKED** — a named external input or environment change is required.
- **PENDING** — the gate has not yet been executed.
- **DEFERRED** — the user explicitly removed the gate from this private-beta
  completion boundary; the capability must not be claimed as verified.

## Approved private-beta device topology

- **APPROVED:** Completion uses one physical iPhone, one or more iOS
  Simulators, and two distinct Apple accounts. A second physical iPhone is not
  required.
- **APPROVED:** One physical iPhone plus one Simulator may provide the two
  simultaneously isolated endpoints for invitation, convergence, account
  switching, and participant-isolation evidence.
- **REQUIRED:** Sign in with Apple, active-competition HealthKit, background
  delivery, APNs, App Attest, and deletion service evidence must still run on
  the physical iPhone where the platform capability requires it. Simulator
  results do not substitute for those physical service receipts.
- **REQUIRED:** Physical-device receipts count toward completion only when
  they name the exact selected release artifact above. Receipts from older
  commits remain historical capability evidence only.
- **APPROVED:** Replacement is exercised as a replacement-installation
  lifecycle on the same physical iPhone: retire the old installation, remove
  and reinstall the exact build, enroll a new installation/App Attest key, and
  prove the retired installation remains unusable.
- **DEFERRED:** Universal-link evidence is outside this private-beta boundary
  because no HTTPS invitation domain will be provided. The controlled custom-
  scheme staging fallback remains in scope and must not be described as a
  universal link.

## Automated matrix

- **PASS:** [Backend CI run 32231758224](https://github.com/narenyenuganti/health-comp/actions/runs/32231758224)
  completed successfully on selected application commit `dd0ed68`, including
  static backend boundaries, migrations, policies, Edge Functions, and the
  checked-in secret/privacy guards.
- **PASS:** [iOS CI run 32231758192](https://github.com/narenyenuganti/health-comp/actions/runs/32231758192)
  completed successfully on selected application commit `dd0ed68`, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests, all
  iOS application-logic tests, unsigned Debug, Staging, and Release device
  builds, and the clean-tree check. Exact bugfix-head run `32227758803` passed the
  same matrix before the guarded merge.
- **PASS:** PR #29 selected the white 1024-pixel logo as the app icon, preserved
  all six supplied black and white source assets, and produced an opaque icon
  accepted by Xcode's asset compiler without changing its visible pixels. The
  reviewed assets remain unchanged in selected merge commit `dd0ed68`; exact-head
  Backend run `32099524516` and iOS run `32099524540` completed successfully.
- **PASS:** Earlier selected-application iOS run `32023749062` completed
  successfully on pre-icon application commit `ae28c6a`, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests, all
  iOS application-logic tests, unsigned Debug, Staging, and Release device
  builds, and a clean-tree check. Exact PR-head run `32020898831` passed the
  same matrix before the guarded merge.
- **PASS:** Evidence-only PR #27 preserved the then-selected pre-icon
  application tree. Its exact-head Backend run `32027282748` and iOS run
  `32027282728`, followed by post-merge Backend run `32030763547` and iOS run
  `32030763718`, completed successfully. Evidence commits do not silently
  replace the selected release artifact named above.
- **PASS:** Evidence-only PR #36 merged as `a45c325`; only this checklist and
  evidence file changed after selected application commit `dd0ed68`. Exact-head
  Backend run `32280929100` and iOS run `32280929157`, followed by post-merge
  Backend run `32284529024` and iOS run `32284529049`, completed successfully.
- **PASS:** Attempt 1 of earlier iOS run `31999779841` reported one failure
  in the pre-existing cancellation-scheduling fixture test. The exact test
  then passed 100/100 locally and the full attempt-2 rerun, but the same test
  recurred as the sole app-suite failure in PR #26 run `32019147010` after
  dependency resolution, deterministic generation, and both Core configurations
  passed. Cancellation cleanup re-enters the fixture actor asynchronously, so
  virtual time could resume the continuation before cleanup. The candidate now
  rechecks cancellation after the suspension boundary, and the test waits for
  actual waiter registration before exercising the race. The strengthened
  test passed 100/100 locally, and exact-head run `32020898831` passed the
  complete hosted app suite. No transport test failed.

## Staging client transport

- **PASS:** The live Supabase client uses one injected ephemeral `URLSession`
  with persistent cookies, URL credentials, and URL caching disabled.
- **PASS:** On pre-recovery transport baseline `21af9a7`, the focused
  transport/authentication/profile-isolation/API gate passed 52 tests, and the
  canonical local `HealthCompTests` gate passed all 457 tests without failures
  or skips. The integrated recovery matrix below later passed the expanded
  459-test canonical suite.
- **PASS:** A signed Staging Simulator build restored the existing
  profile-scoped data and authenticated session, completed staging requests
  with HTTP 200 responses, and produced no `-1005` or missing-HealthKit-
  entitlement error.
- **PASS:** At `2026-08-19T18:36:33Z`, selected application source `dd0ed68`
  was rebuilt from docs-only main `a45c325` as a Staging Simulator bundle.
  Offline checks confirmed the exact staging bundle ID, expected public project
  URL, publishable-key shape, blank invitation host, custom-scheme fallback,
  and Xcode-generated simulated sandbox/development capability values without
  exposing credentials. The over-install exactly matched the verified build,
  kept the pre-existing data-container count at 19, and left the app stopped.
  The dedicated tester was then shut down without contacting hosted staging.
  Only the 44 MiB app and simulator-entitlement receipt were retained; the
  1.5 GiB DerivedData was removed. This is selected-build preparation, not
  authenticated-runtime, invitation, or physical-device evidence.
- **PASS:** The integrated PR #26 recovery change
  pins Supabase Swift 2.55.1 and passed 90/90 focused recovery tests, 459/459
  canonical app tests, 241/241 CompetitionCore tests in both Debug and
  Release, unsigned Debug/Staging/Release device builds, deterministic project
  generation, and a zero-finding CodeRabbit re-review. Its signed Staging
  Simulator over-install left the data-container file count unchanged at 19
  and restored the authenticated Sharing UI. The current process produced 42
  process-local HTTP-200 markers and zero `-1005`, HealthKit-entitlement, or crash markers
  from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. No invitation was
  created or consumed. The first hosted iOS attempt stopped before app tests
  because Xcode 16.4 required the dormant OpenCombine pin. The second accepted
  that pin, passed deterministic generation and both Core configurations, then
  required Supabase's optional OpenTelemetry package in the resolved-file
  superset. The exact compatible OpenTelemetry pin and its Linux-only Swift
  Atomics dependency are now retained with OpenCombine and passed strict local
  resolution unchanged. The third hosted attempt accepted the complete package
  graph and passed deterministic generation and both Core configurations, then
  ran the app suite with only the known cancellation fixture test failing. Its
  cancellation-precedence correction passed the strengthened exact test 100/100
  locally. Exact-head run `32020898831` then passed the complete hosted matrix,
  and PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`
  with a tree identical to the reviewed PR head. PR #29 later added only the
  reviewed app-icon assets and selected merge commit `9d19937`.
- **PASS:** Selected release artifact `dd0ed68` was signed, over-installed, and
  launched on the physical iPhone. At `2026-08-19T15:06Z`, it reached the
  authenticated Sharing UI without a warning. Its Account UI confirmed the
  authenticated state and raw-HealthKit-on-device boundary. A controlled
  terminate/relaunch and bounded readback ending at `2026-08-19T15:07Z`
  remained free of both the prior refresh warning and `Activity authorization
  is unavailable.` Current source requests Health authorization during startup,
  so this proves corrected authenticated transport and a completed startup
  authorization request under the retained same-bundle grant, not fresh native
  Sign in with Apple or active HealthKit behavior. Simulator receipts are not
  physical-device evidence.

## Hosted staging

- **PASS:** The current Staging target is `xhfdfdrtxwptrwhvvlhg`. Approval of a
  future Production environment must verify a different project reference
  before any promotion.
- **PASS:** At `2026-08-16T05:34:16Z`, `supabase migration list --linked`
  returned fourteen identical local/remote pairs in this order:
  `20260811000100`, `20260811000200`, `20260811000300`, `20260811000400`,
  `20260811000450`, `20260811000500`, `20260811000550`, `20260811000600`,
  `20260811000650`, `20260811000700`, `20260811000750`, `20260811000800`,
  `20260811000850`, and `20260811000900`.
- **PASS:** In the same read-only audit,
  `supabase db push --linked --dry-run` returned `up to date`; the CLI was then
  unlinked and no project-ref file remained.
- **PASS:** The corrected five-minute finalizer and one-minute notification
  repair jobs have both completed successfully.
- **PASS:** Apple Auth, environment-scoped Function secrets, worker Vault
  values, and the topic-restricted sandbox APNs key were read back without
  exposing secret values.
- **PASS:** A SELECT-only hosted inventory ending at
  `2026-08-17T07:12:08Z` found two active profiles, two active sandbox
  installations, two pending competitions, two live unclaimed invitations,
  and zero consumed invitations. The pending-competition distribution across
  the two active profiles was `[0,2]`; no profile, installation, competition,
  invitation, token, or digest identifier was selected or retained.
- **PASS:** The same privacy-bounded inventory found zero App Attest keys,
  account-deletion records, daily-score revisions, and competition results.
  No third invitation or hosted mutation was created during the audit.
- **PASS:** After both invitations expired, a fresh privacy-safe scope snapshot
  returned count `2` and opaque scope SHA-256
  `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`.
  Following action-time approval, the exact reviewed guard from
  [Competition Support](../runbooks/competition-support.md#supported-operator-actions)
  ran as one explicit serializable transaction through the authenticated
  Supabase Management API database-query route. The transport was the
  Management API rather than `psql`; the transaction retained the approved
  count/fingerprint checks, bounded timeouts, service-role request claim,
  cleanup-count assertion, and explicit commit.
- **PASS:** Readback through the dedicated read-only Management API route at
  `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired
  competitions, two retained invitation-history rows, zero claimed or consumed
  invitations, and zero remaining eligible invitations. No identifier or token
  was selected, no lifecycle row was edited directly, and no replacement
  invitation was created.
- **PASS:** Fresh Sign in with Apple succeeded on prior selected artifact
  `9d19937`, but a controlled relaunch at `2026-08-19T07:02Z` reproduced
  `Some competition activity could not be refreshed.` A privacy-safe hosted
  readback sequence ending at `2026-08-19T07:06:16.64042Z` confirmed zero
  pending and two expired competitions; accepted-membership, retained-
  unclaimed-invitation, and lifecycle-change distributions were each `[1,1]`.
  Prior client source mapped each expired descriptor to
  `competitionNotMaterialized` and then to a per-competition warning. PR #34
  now prunes declined, expired, and cancelled inventory descriptors before
  materialization while preserving the local journal and retained server
  history. Selected artifact `dd0ed68` remained warning-free through first
  authenticated launch, controlled terminate/relaunch, and a bounded refresh
  readback ending at `2026-08-19T15:07Z`. No identifier, account detail, token,
  or Health datum was selected.
- **PASS:** In a user-approved physical sequence ending at
  `2026-08-19T17:13:03Z`, exact selected artifact `dd0ed68` completed sign-out,
  reached its clean welcome screen, completed fresh native Sign in with Apple,
  and returned to authenticated Sharing without a warning. No account identity,
  authorization payload, token, private screenshot, raw HealthKit datum, or
  exact Activity value is retained. This closes the exact-current-artifact
  Sign in with Apple gate only; it does not create invitation, convergence,
  HealthKit activity, background-delivery, APNs-delivery, App Attest, deletion,
  or replacement-installation evidence.
- **PENDING:** Create exactly one replacement invitation and consume it
  immediately during the two-account staging flow when the physical iPhone is
  available. First launch the prepared selected-build Simulator endpoint and
  confirm its isolated authenticated state; obtain fresh action-time approval
  immediately before creation.
- **PENDING:** Adversarial participant-isolation and tamper matrix.

## Paid-team signing and installation

- **PASS:** Xcode reads the paid Apple Developer team as an Admin team with one
  provisioned device.
- **PASS:** Automatic signing produced selected application commit `dd0ed68`
  as a Staging device build for
  `23LUYD78QK.com.narenyenuganti.HealthComp.staging`.
- **PASS:** The generated staging development profile expires
  `2027-08-16T05:23:35Z` and authorizes sandbox APNs, Sign in with Apple,
  HealthKit, HealthKit background delivery, and App Attest.
- **PASS:** Build 1 from prior selected source commit
  `9d199377f5d72cb7bc90133c190e4e7681abfb41` was signed with the paid-team
  profile, freshly installed after device inventory confirmed that no
  HealthComp bundle was present, displayed the selected white app icon in
  Spotlight, and launched to the native Health Access prompt. At
  `2026-08-19T06:53Z`, after fresh action-time approval, the native
  `Turn On All` and final `Allow` actions enabled every category requested by
  HealthComp, and the selected build reached the authenticated Sharing UI using
  its restored session. This checked-in receipt contains no account identity,
  token, private screenshot, raw HealthKit datum, or exact Activity value. This proves
  prior-artifact signing, installation, icon rendering, launch, and Health
  authorization UI behavior; it does not prove those service paths on current
  selected artifact `dd0ed68`, active-competition derived scores, or background
  delivery.
- **PASS:** At `2026-08-19T08:18:49Z`, selected source commit `dd0ed68` was
  signed with the same paid-team profile and over-installed on the physical
  iPhone. The app remained installed as
  `com.narenyenuganti.HealthComp.staging`, retained its authenticated session
  and local state, and passed the clean physical relaunch receipt ending at
  `2026-08-19T15:07Z`. This is same-bundle upgrade evidence, not the pending
  remove/reinstall replacement lifecycle.
- **PARTIAL:** Build 1 from historical source commit
  `1ca67af76b738bd7fbb19277b238b448a555f8ef`
  was installed and launched on the paired physical iPhone. Native Sign in
  with Apple completed, staging Supabase profile bootstrap required and
  accepted a user-selected display name, and the authenticated Sharing UI was
  read back at `2026-08-16T07:02:20Z`. No Apple account identity, token, or
  private screenshot was retained. This is historical capability evidence,
  not current-build Sign in with Apple evidence for selected release artifact
  `dd0ed68`.
- **PARTIAL:** After the restored session was signed out, fresh native Sign in
  with Apple authorization completed directly on the physical iPhone for
  prior selected artifact `9d19937`. At `2026-08-19T06:59Z`, iPhone Mirroring
  read back the authenticated Sharing UI. Selected artifact `dd0ed68` later
  preserved that session through over-install and relaunch. This remains a
  historical supporting receipt; the exact-current receipt below supersedes
  its former artifact-version limitation. No Apple account identity,
  authorization payload, token, or private screenshot is included.
- **PASS:** In the later user-approved sequence ending at
  `2026-08-19T17:13:03Z`, selected artifact `dd0ed68` itself completed sign-out,
  displayed its clean welcome screen, completed fresh native Sign in with
  Apple, and returned to authenticated Sharing without a warning. The evidence
  retains no account identity, authorization payload, token, private
  screenshot, raw HealthKit datum, or exact Activity value.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PASS | Selected artifact `dd0ed68` was signed with the paid-team profile, over-installed as `com.narenyenuganti.HealthComp.staging`, retained local state and its authenticated session, and remained warning-free through controlled relaunch and bounded refresh |
| Sign in with Apple | PASS | Exact selected artifact `dd0ed68` completed a user-approved sign-out and fresh native Sign in with Apple sequence, then returned to authenticated Sharing without a warning at `2026-08-19T17:13:03Z`; no identity or authorization payload is retained |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed historically, and all app-requested categories were granted on prior artifact `9d19937`; selected artifact `dd0ed68` invoked its startup authorization request and launched without `Activity authorization is unavailable.` Public HealthKit does not expose read denial, so active-competition privacy-safe derived score and background-observer behavior remain pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Real key registration, assertion, replay rejection, and replacement-device flow |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | DEFERRED | User-approved private-beta deferral because no HTTPS invitation domain will be provided; custom-scheme fallback is not universal-link evidence |
| Replacement installation | PENDING | Same-phone remove/reinstall, new installation and App Attest enrollment, retired-installation isolation, and no local-data resurrection |

## Multi-user and operational gates

- **PARTIAL:** Both dedicated accounts have authenticated staging profiles. PR #34
  corrected terminal invitation inventory handling without deleting retained
  history or the local journal, and selected artifact `dd0ed68` remained clean
  through physical authenticated relaunch and bounded refresh. The prior false
  warning no longer blocks a fresh invitation, but invitation acceptance,
  convergence, and participant-isolation evidence remain pending below.
- **PENDING:** Two-account invitation, controlled custom-scheme sharing, cold
  acceptance, and convergence evidence using the approved one-physical-iPhone-
  plus-Simulator topology. Sequential account switching must additionally
  prove profile-scoped journal, outbox, cursor, mute, and installation
  isolation.
- **PENDING:** Cross-account reads and mutations, replayed claims, modified
  points, stale/conflicting revisions, result rewrites, deleted-profile access,
  token leakage, and unregistered installations all fail closed.
- **BLOCKED:** Hosted backup/restore rehearsal requires a backup-capable plan
  and an approved disposable restore target.
- **BLOCKED:** No production Supabase project has been approved.

## Completion rule

Do not describe HealthComp as production-ready until every in-scope automated,
two-account staging, adversarial, physical-device, deletion, restore, secret,
privacy, and release-evidence gate is **PASS** under the approved one-physical-
iPhone-plus-Simulator topology. Simulator evidence is valid for invitation,
convergence, account switching, and participant isolation under that approved
topology. It is not a substitute for a gate that specifically requires
physical-device or service-level evidence. A successful build, installed app,
dashboard configuration, or source entitlement alone is likewise not service-
level evidence. A **DEFERRED** capability is not a blocker for this private-
beta boundary, but it must not be claimed as supported or verified.
