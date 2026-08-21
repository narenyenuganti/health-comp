# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-20 PDT
**Selected application baseline:** `cb211896eb422909bff0561f3fb25b5d4942b06b`
**Selected release artifact:** `cb211896eb422909bff0561f3fb25b5d4942b06b`;
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

- **PASS:** Exact-current post-merge
  [Backend CI run 32442953606](https://github.com/narenyenuganti/health-comp/actions/runs/32442953606)
  completed successfully on selected application commit `cb21189`, including
  static backend boundaries, migrations, policies, Edge Functions, and the
  checked-in secret/privacy guards.
- **PASS:** Exact-current post-merge
  [iOS CI run 32442953541](https://github.com/narenyenuganti/health-comp/actions/runs/32442953541)
  completed successfully on selected application commit `cb21189`, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests, all
  iOS application-logic tests, unsigned Debug, Staging, and Release device
  builds, and the clean-tree check. Exact PR #48 head runs
  [32440813806](https://github.com/narenyenuganti/health-comp/actions/runs/32440813806)
  and
  [32440813807](https://github.com/narenyenuganti/health-comp/actions/runs/32440813807)
  passed the same backend and iOS matrices before merge.
- **PASS:** PRs #43, #45, #46, #47, and #48 serially integrated the startup-race
  recovery, hosted-worker boot repair, compatible App Attest verification graph,
  terminal rejection recovery, and privacy-safe rejection-stage diagnostics.
  Each exact PR head passed both required hosted workflows before its guarded
  merge; `cb21189` is the resulting current integration boundary.
- **PASS:** Earlier post-merge
  [Backend CI run 32231758224](https://github.com/narenyenuganti/health-comp/actions/runs/32231758224)
  and
  [iOS CI run 32231758192](https://github.com/narenyenuganti/health-comp/actions/runs/32231758192)
  completed successfully on then-selected application commit `dd0ed68`. Those
  runs remain lineage evidence, not exact-current automation evidence.
- **PASS:** PR #29 selected the white 1024-pixel logo as the app icon, preserved
  all six supplied black and white source assets, and produced an opaque icon
  accepted by Xcode's asset compiler without changing its visible pixels. The
  reviewed assets remain unchanged in selected merge commit `cb21189`; exact-head
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
- **PASS:** Evidence-only PR #36 merged as `a45c325` without changing its
  then-selected application commit `dd0ed68`. Exact-head
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
- **PASS:** At `2026-08-19T18:36:33Z`, then-selected application source `dd0ed68`
  was rebuilt from docs-only main `a45c325` as a Staging Simulator bundle.
  Offline checks confirmed the exact staging bundle ID, expected public project
  URL, publishable-key shape, blank invitation host, custom-scheme fallback,
  and Xcode-generated simulated sandbox/development capability values without
  exposing credentials. The over-install exactly matched the verified build,
  kept the pre-existing data-container count at 19, and left the app stopped.
  The dedicated tester was then shut down without contacting hosted staging.
  Only the 44 MiB app and simulator-entitlement receipt were retained; the
  1.5 GiB DerivedData was removed. This is historical selected-build
  preparation, not exact-current authenticated-runtime, invitation, or
  physical-device evidence.
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
- **PASS:** Then-selected release artifact `dd0ed68` was signed, over-installed, and
  launched on the physical iPhone. At `2026-08-19T15:06Z`, it reached the
  authenticated Sharing UI without a warning. Its Account UI confirmed the
  authenticated state and raw-HealthKit-on-device boundary. A controlled
  terminate/relaunch and bounded readback ending at `2026-08-19T15:07Z`
  remained free of both the prior refresh warning and `Activity authorization
  is unavailable.` Current source requests Health authorization during startup,
  so this proves corrected authenticated transport and a completed startup
  authorization request under the retained same-bundle grant, not fresh native
  Sign in with Apple or active HealthKit behavior. Simulator receipts are not
  physical-device evidence for `cb21189`.
- **PASS:** On `2026-08-20` PDT, exact selected artifact `cb21189` was built for
  the paired physical iPhone with frozen package resolution, automatically
  signed by the paid team, and verified for strict code signing, unexpired
  provisioning, exact staging bundle/project configuration, Sign in with Apple,
  HealthKit background delivery, sandbox APNs, and development App Attest. The
  exact bundle over-installed without launching, preserved the existing app
  container file count and terminal outbox bytes, and left the hosted aggregate
  unchanged. Exactly one later controlled launch started the app process; the
  process was reacquired and stopped after the console connection dropped. No
  second launch occurred. This proves the exact-current build/install/launch
  boundary, not authenticated UI, fresh Sign in with Apple, active HealthKit,
  or App Attest acceptance.

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
  history. Then-selected artifact `dd0ed68` remained warning-free through first
  authenticated launch, controlled terminate/relaunch, and a bounded refresh
  readback ending at `2026-08-19T15:07Z`. No identifier, account detail, token,
  or Health datum was selected.
- **PASS:** In a user-approved physical sequence ending at
  `2026-08-19T17:13:03Z`, then-selected artifact `dd0ed68` completed sign-out,
  reached its clean welcome screen, completed fresh native Sign in with Apple,
  and returned to authenticated Sharing without a warning. No account identity,
  authorization payload, token, private screenshot, raw HealthKit datum, or
  exact Activity value is retained. This closes that artifact's Sign in with
  Apple gate only; it does not prove fresh authentication on `cb21189` or create
  invitation, convergence, HealthKit activity, background-delivery,
  APNs-delivery, App Attest, deletion, or replacement-installation evidence.
- **PASS:** Following fresh action-time approval, then-selected artifact
  `dd0ed68` created exactly one replacement invitation from the isolated
  Simulator endpoint. The same opaque custom-scheme link cold-launched that
  then-selected physical artifact, displayed the explicit claim decision,
  and was accepted once. A read-only hosted readback ending at
  `2026-08-19T21:56:37Z` found one scheduled competition for the replacement,
  exactly two participant rows, and exactly one corresponding invitation row
  with both claimant and consumption time present. Both endpoints then showed
  the same scheduled competition after controlled relaunch. No token, account
  identity, profile/competition identifier, private screenshot, raw HealthKit
  datum, or exact Activity value is retained. This is controlled custom-scheme
  evidence, not universal-link evidence.
- **PASS:** Application source `dd0ed68` routes live invitation
  creation through `create-competition-invite` and claims through
  `claim-competition-invite`; those route boundaries remain present in selected
  commit `cb21189`. The then-selected artifact completed both actions above,
  and hosted state records their create/consume effects. At
  `2026-08-20T02:32:28Z`, read-only dashboard summaries reported exactly one
  invocation since the last deployment and no errors for each Function. No new
  request was sent, and no token, identity, request body, Function identifier,
  or execution identifier was retained.
- **PASS:** At `2026-08-20T01:18:06Z`, exact reviewed verifier commit
  `4fca597757befafc9ed10cafecc4af4b73e65026` ran against
  `healthcomp-staging` only after SSL enforcement was enabled and read back.
  The certificate-verified session passed all 15 database adversarial
  assertions, explicitly rolled back, independently confirmed zero synthetic
  rows remaining, and returned no private values. The sole nonblank
  privacy-safe receipt has SHA-256
  `852fc2d64c0daa93677726cda4fdddf4acd088b68884aa247939188f408660af`.
- **PASS:** In a user-approved sequential Simulator sequence ending at
  `2026-08-20T05:56:37Z`, then-selected artifact `dd0ed68` remotely retired
  Account A's installation, reached zero local profile roots and files, and mounted one
  distinct Account B root. The hosted aggregate moved from two active / three
  revoked installations, to one / four after sign-out, to two / four after
  Account B registration. Account B contained only the legitimate
  server-rematerialized scheduled competition, two cursors, and its one active
  installation; no outbox, notification preference, or App Attest file was
  present. The same profile-transition test remains in the exact-current suite,
  seeds a private prior-profile outbox, and rejects cross-profile loading. No
  identity, identifier, token, local fingerprint, or private screenshot is
  retained. The iOS 18.4
  Simulator transport-cache recovery touched only rebuildable alternative-
  service rows and did not alter profile data.
- **PARTIAL:** The database portion of the adversarial participant-isolation
  and tamper matrix and current-source create/claim route continuity are
  proven, and the sequential Simulator profile-root boundary now passes. The
  successful create/accept runtime receipt remains historical.
  Replay of the consumed replacement invitation when its token is available
  and the remaining lifecycle isolation cases remain pending.
- **PASS:** Only `submit-score-revision` was advanced to staging version 7 for
  selected source `cb21189`. Deployed source matched the reviewed runtime files,
  and the credential-free probe retained the exact `400 invalid_request`
  fail-closed boundary. No migration, secret, other Function, or production
  resource changed during that deployment.
- **PENDING:** The exact-current physical run began with 9 hosted App Attest
  challenges, 0 consumed challenges, 0 registered keys, 0 grants, 0 consumed
  grants, and 0 accepted score revisions. After the single controlled launch,
  every count was unchanged, bounded hosted logs contained 0
  `app-attest-challenge` and 0 `submit-score-revision` calls, and the local
  outbox still contained only the prior terminal `appAttestRejectedTerminal`
  entry with no retry. The unchanged HealthKit-derived wire snapshot correctly
  produced no new eligible event. This is truthful no-attempt evidence, not an
  App Attest pass or classified rejection.

## Paid-team signing and installation

- **PASS:** Xcode reads the paid Apple Developer team as an Admin team with one
  provisioned device.
- **PASS:** Automatic signing produced selected application commit `cb21189`
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
  selected artifact `cb21189`, active-competition derived scores, or background
  delivery.
- **PASS:** At `2026-08-19T08:18:49Z`, then-selected source commit `dd0ed68` was
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
  `cb21189`.
- **PARTIAL:** After the restored session was signed out, fresh native Sign in
  with Apple authorization completed directly on the physical iPhone for
  prior selected artifact `9d19937`. At `2026-08-19T06:59Z`, iPhone Mirroring
  read back the authenticated Sharing UI. Then-selected artifact `dd0ed68` later
  preserved that session through over-install and relaunch. This remains a
  historical supporting receipt. The later native authorization on then-
  selected artifact `dd0ed68` superseded the `9d19937` limitation at that time;
  neither historical receipt proves fresh authorization on current artifact
  `cb21189`. No Apple account identity, authorization payload, token, or private
  screenshot is included.
- **PASS:** In the later user-approved sequence ending at
  `2026-08-19T17:13:03Z`, then-selected artifact `dd0ed68` itself completed sign-out,
  displayed its clean welcome screen, completed fresh native Sign in with
  Apple, and returned to authenticated Sharing without a warning. The evidence
  retains no account identity, authorization payload, token, private
  screenshot, raw HealthKit datum, or exact Activity value.
- **PASS:** On `2026-08-20` PDT, selected source commit `cb21189` was signed with
  the paid-team profile, passed strict signature and capability validation, and
  over-installed without erasing the existing profile-scoped app container; its
  file count and terminal outbox bytes remained unchanged. Exactly one
  controlled process launch occurred and the app was
  stopped afterward. This exact-current receipt intentionally does not claim a
  fresh native Apple authorization, authenticated UI readback, active HealthKit
  score, or App Attest request.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PASS | Selected artifact `cb21189` was signed with the paid-team profile, over-installed as `com.narenyenuganti.HealthComp.staging`, preserved its profile-scoped container and terminal outbox, launched exactly once, and was stopped afterward; authenticated UI readback is not claimed |
| Sign in with Apple | PARTIAL | Fresh native Sign in with Apple passed on then-selected artifact `dd0ed68`; exact-current `cb21189` preserved the same-bundle container and launched, but did not repeat sign-out and native reauthorization |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed historically, and all app-requested categories were granted on prior artifact `9d19937`; exact-current `cb21189` launched under the retained same-bundle grant but produced no changed privacy-safe wire snapshot. Active-competition derived score and background-observer behavior remain pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Selected artifact `cb21189` and staging Function version 7 passed build/deployment guards, but the single physical launch generated no new eligible event, challenge, key, grant, or submission and therefore did not execute the App Attest service gate. Real registration, assertion acceptance or classified rejection, replay rejection, and replacement-installation flow remain pending |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | DEFERRED | User-approved private-beta deferral because no HTTPS invitation domain will be provided; custom-scheme fallback is not universal-link evidence |
| Replacement installation | PENDING | Same-phone remove/reinstall, new installation and App Attest enrollment, retired-installation isolation, and no local-data resurrection |

## Multi-user and operational gates

- **PARTIAL:** Both dedicated accounts have authenticated staging profiles.
  Then-selected artifact `dd0ed68` completed one replacement invitation,
  controlled custom-scheme sharing, cold physical acceptance, single hosted
  consumption, two-participant membership, and scheduled-state convergence on
  the approved one-physical-iPhone-plus-Simulator topology. This remains
  historical runtime evidence after selection advanced to `cb21189`; PR #34
  continues to preserve terminal history and local journals without the former
  false warning.
- **PARTIAL:** The replacement competition started on `2026-08-20` in its
  frozen `America/Los_Angeles` time zone. The exact-current physical launch did
  not generate a changed Day 1 wire snapshot or accepted score. Day 1
  convergence, Days 1...7, offline catch-up, tallying/results, history, rematch,
  mute, archive, and deep-link relaunch remain pending. Sequential Simulator
  profile-root teardown/remount, non-cross-load of the private outbox, cursor
  scoping, and remote installation retirement/re-registration now pass.
- **PARTIAL:** The rollback-only hosted database matrix proved its fixed
  synthetic cross-account reads and mutations, replayed claims, modified
  points, stale/conflicting revisions, result rewrites, deleted-profile access,
  private-column/raw-table denial, and unregistered-installation cases fail
  closed. Current-source create/claim route continuity is also proven, while
  the successful create/accept runtime receipt remains historical;
  consumed-token replay and the remaining lifecycle isolation evidence remain
  pending.
- **BLOCKED:** Hosted backup/restore rehearsal requires a backup-capable plan
  and an approved disposable restore target.
- **BLOCKED:** No production Supabase project has been approved. The current
  read-only project inventory still contains only healthy staging plus an
  unrelated inactive project; the runbook explicitly forbids treating that
  inactive project as production without a separate user decision.

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
