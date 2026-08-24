# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-23 PDT
**Selected application baseline:** `6ee1d2260cfcbe02a950630ef979076c317eca49`
**Selected release artifact:** `6ee1d2260cfcbe02a950630ef979076c317eca49`;
selected for the remaining staging and physical-device gates, but not yet
cleared for production.
**Current integrated application candidate:**
`0e08e2a0dc9f7ccfbcaa1f2c87df10ec184da684`; merged and green, but not yet
selected because its authenticated staging runtime receipt is inconclusive.
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

- **PASS:** Selected-application post-merge
  [Backend CI run 32560065403](https://github.com/narenyenuganti/health-comp/actions/runs/32560065403)
  completed successfully on selected application commit `6ee1d22`, including
  static backend boundaries, migrations, policies, Edge Functions, and the
  checked-in secret/privacy guards.
- **PASS:** Selected-application post-merge
  [iOS CI run 32560065372](https://github.com/narenyenuganti/health-comp/actions/runs/32560065372)
  completed successfully on selected application commit `6ee1d22`, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests, all
  iOS application-logic tests, unsigned Debug, Staging, and Release device
  builds, and the clean-tree check. Exact PR #52 head passed the same backend
  and iOS matrices before merge.
- **PASS:** PRs #43, #45, #46, #47, #48, #51, and #52 serially integrated the startup-race
  recovery, hosted-worker boot repair, compatible App Attest verification graph,
  terminal rejection recovery, privacy-safe rejection-stage diagnostics,
  corrected assertion-signature verification, and client-side submission
  serialization.
  Each exact PR head passed both required hosted workflows before its guarded
  merge; `6ee1d22` remains the selected release baseline for the incomplete
  physical gates.
- **PASS:** PR #62 application-source commit `1a2ddb5` separates a typed
  on-device Activity-read failure from otherwise valid remote competition
  materialization. Focused runtime/client, HealthKit-provider, and presentation
  tests passed 91/91, including successful cursor persistence, visible remote
  state, a scoped Activity warning, and zero score submission after the failed
  read. Exact-source Backend run `32634210205` and iOS run `32634210213`, final
  PR-head Backend run `32635614190` and iOS run `32635614199`, and post-merge
  Backend run `32636617904` and iOS run `32636617875` all passed. PR #62 merged
  as current-main candidate `0e08e2a`. Integration is complete, but its staging
  runtime gate remains partial; this does not complete physical HealthKit or
  App Attest evidence or replace selected artifact `6ee1d22`.
- **PASS:** Earlier post-merge Backend run `32442953606` and iOS run
  `32442953541` completed successfully on then-selected application commit
  `cb21189`; its exact PR #48 head runs `32440813806` and `32440813807` passed
  before merge. Those runs remain lineage evidence, not exact-current
  automation evidence.
- **PASS:** Earlier post-merge
  [Backend CI run 32231758224](https://github.com/narenyenuganti/health-comp/actions/runs/32231758224)
  and
  [iOS CI run 32231758192](https://github.com/narenyenuganti/health-comp/actions/runs/32231758192)
  completed successfully on then-selected application commit `dd0ed68`. Those
  runs remain lineage evidence, not exact-current automation evidence.
- **PASS:** PR #29 selected the white 1024-pixel logo as the app icon, preserved
  all six supplied black and white source assets, and produced an opaque icon
  accepted by Xcode's asset compiler without changing its visible pixels. The
  reviewed assets remain unchanged in selected merge commit `6ee1d22`; exact-head
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
- **PASS:** On reviewed PR #26 source whose application tree merged as pre-icon
  commit `ae28c6a`, a signed Staging Simulator build restored the existing
  profile-scoped data and authenticated session, completed staging requests
  with HTTP 200 responses, and produced no `-1005` or missing-HealthKit-
  entitlement error. This is historical transport evidence, not exact-current
  Simulator runtime.
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
- **PASS:** At `2026-08-22T23:48:42Z`, selected application source `6ee1d22`
  was installed as `com.narenyenuganti.HealthComp.staging` on the dedicated
  iOS 18.4 tester. The installed executable exactly matched the retained
  44 MiB build at SHA-256
  `b8a8d4b1863326e553cc83a8eb49417b4476e718b0f7b37ffe2df03f6c9ceb70`,
  and the state-preserving data container contained 23 files. Simulator
  Settings showed an active Apple Account session without retaining an
  identity, but that display does not prove the HealthComp Sign in with Apple
  profile. The app remained stopped, no staging request was made, and the
  worktree was clean after restoring an incidental Xcode resolved-file
  rewrite. This proves exact-current offline preparation, not authenticated
  staging runtime.
- **PARTIAL:** Following explicit approval, exact bundle
  `com.narenyenuganti.HealthComp.staging` launched once from
  `2026-08-22T23:55:00Z` through `23:55:30Z`, settled on the clean welcome
  screen, and was terminated without pressing Sign in with Apple or taking an
  in-app action. The data-container count remained 23 files and the post-window
  process count was zero. The bounded process log contained two occurrences of
  Supabase Swift v2.55.1's advisory initial-session warning and two successful
  network-activity completion markers, but no retained HTTP status marker.
  Pinned-source inspection confirms the warning is emitted by the SDK's default
  initial-session path and is not itself refresh-failure evidence. The receipt
  cannot distinguish an already-absent session from one removed during terminal
  refresh. The preserved profile root remained unmounted, maintaining the
  fail-closed cross-profile boundary. This does not prove authenticated staging
  transport or Account B profile mount.
- **PARTIAL:** Current-main candidate `0e08e2a` was built as the exact staging
  Simulator bundle with frozen package resolution and the expected simulated
  Sign in with Apple, HealthKit/background-delivery, sandbox APNs, development
  App Attest, bundle, and public configuration boundaries. Its state-preserving
  over-install retained one authenticated profile root and seven profile files;
  the installed executable matched SHA-256
  `4308ed164cabe956eaa785038700c16968715cf1516e6e86be5492c622865df7`.
  Following explicit approval, one Simulator launch action ran at
  `2026-08-23T18:11:40Z` with no retry. Accessibility exposed only a protected/
  blank surface, the app was already stopped at settled readback, and neither
  attributable transport nor diagnostic lines were available. The profile
  remained one root and seven files with one primary competition journal and
  two files in its server-cursor directory; no profile file changed after the
  launch timestamp. Receipt SHA-256:
  `cc8c28a12bbf1b2b5773c3e479972874de61cb9b74e67b3e13466faef035d6e4`.
  This proves exact-candidate build/install and authenticated local preservation,
  not successful runtime execution of the Activity-isolation fix. An unrelated
  storage cleanup later removed the complete Simulator device set. A targeted
  read-only Time Machine snapshot recovery restored only the dedicated tester
  and required registry; independent validation matched the exact executable,
  one profile root, and seven files. The separately approved retry then issued
  exactly one launch from `2026-08-23T21:36:23Z` through bounded termination at
  `23:29:26Z`. It reached authenticated Sharing immediately but retained `No
  Competition` and `Some competition activity could not be refreshed.` A
  credential-free Simulator-to-staging TLS probe succeeded, while the app
  process window contained 72 CFNetwork connection-loss / `-1005` markers and
  no precise HTTP response-status marker. After termination the exact
  executable, one profile root, seven files, one five-envelope primary journal,
  and zero-entry inventory remained. Only the inventory document changed; no
  second profile root appeared, and no pull-to-refresh or other in-app action
  occurred. Recovery-retry receipt SHA-256:
  `8dc3a1885446c373dd530f7d0a703af3e08a95270359220f35138a43874450d1`.
  This advances authenticated session-recovery and local-isolation evidence,
  not the warning-free remote Activity refresh gate. A fresh read-only
  preflight then revalidated the stopped exact executable, the same profile and
  journal counts, and credential-free staging TLS. Following explicit
  approval, the exact bundle launched once from `2026-08-24T00:38:44Z` through
  `00:41:24Z`; authenticated Sharing again showed `No Competition` plus the
  historical-refresh warning. Exactly one downward pull-to-refresh gesture was
  performed, with no retry or other in-app action. The immediate readback and a
  bounded ten-second observation retained the same UI. After termination, the
  profile tree was byte-for-byte unchanged at one root, seven files, one
  five-envelope journal, zero inventory entries, zero outbox entries, and zero
  App Attest files; no second root appeared. Predetermined log aggregates found
  zero `-1005`, `-7026`, missing-entitlement, and crash/fatal markers, but no
  precise attributable HTTP status marker was retained. Pull-refresh receipt
  SHA-256:
  `8ca2762c5a4acbb4b431f06ef1e65e174387129a8da0e26819db2c174cd7cedc`.
  This proves one fail-closed exact-candidate refresh attempt and continued
  profile isolation, not remote materialization, score submission, App Attest,
  or warning-free authenticated refresh.
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
  physical-device evidence for `6ee1d22`.
- **PASS:** On `2026-08-22` PDT, exact selected artifact `6ee1d22` was built for
  the paired physical iPhone with frozen package resolution, automatically
  signed by the paid team, and verified for strict code signing, unexpired
  provisioning, exact staging bundle/project configuration, Sign in with Apple,
  HealthKit background delivery, sandbox APNs, and development App Attest. The
  exact bundle over-installed without launching and preserved the stable
  profile subtree: 17 entries, seven directories, three outbox files, one
  App Attest state file, three competition files, and two server cursors.
  Two separately approved controlled launches each started the app process
  exactly once and stopped it without an in-window retry. This proves the
  exact-current build/install/launch
  boundary and authenticated Sharing readback with a competition-refresh
  warning, not fresh Sign in with Apple, active HealthKit, or App Attest
  acceptance.

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
  Apple gate only; it does not prove fresh authentication on `6ee1d22` or create
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
  commit `6ee1d22`. The then-selected artifact completed both actions above,
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
- **PASS:** In an exact-current follow-up ending at `2026-08-23T08:36:05Z`,
  selected source `6ee1d22` completed Account B's server-confirmed sign-out,
  reached zero profile roots and files, and then authenticated the earlier
  Account A through exactly one native HealthComp Sign in with Apple attempt.
  Account A mounted one root with seven files and a preserved five-envelope
  history journal; no second root was present. The bounded log aggregate
  contained only HTTP 200/204 markers and zero non-2xx, connection-lost,
  `-7026`, or missing-entitlement markers. The root remained after app
  termination. The receipt SHA-256 is
  `7bdb11a5e30aa71ea1bb8710d3ef0bc5b5bfdd91d61b42bcd184c694fe59e8fe`.
  The UI still showed `No Competition` and the historical-refresh warning, so
  this is exact-current sequential profile isolation rather than completed
  two-account lifecycle convergence.
- **PARTIAL:** The database portion of the adversarial participant-isolation
  and tamper matrix and current-source create/claim route continuity are
  proven, and both directions of the exact-current sequential Simulator
  profile-root boundary now pass. The successful create/accept runtime receipt
  remains historical.
  Replay of the consumed replacement invitation when its token is available
  and the remaining lifecycle isolation cases remain pending.
- **PASS:** Only `submit-score-revision` was advanced to active staging version 9 for
  selected source `6ee1d22`. Deployed source matched the reviewed runtime files,
  and the credential-free probe retained the exact `400 invalid_request`
  fail-closed boundary. No migration, secret, other Function, or production
  resource changed during that deployment.
- **PENDING:** Two exact-current physical launches began with four hosted App
  Attest challenges, one consumed challenge, one registered key, one grant,
  one consumed grant, and one accepted score revision. Every count was
  unchanged afterward. The second approved launch ran from
  `2026-08-22T22:21:55Z` through `2026-08-22T22:23:33Z`. Its API Gateway window
  showed successful HTTP 200 profile bootstrap, installation registration,
  competition listing, and change fetches plus an HTTP 101 Realtime WebSocket
  upgrade, while the
  Function overview remained at the one pre-launch credential-free boot probe.
  A temporary metadata-only outbox readback found four terminal score
  revisions: Day 1 revision 1 and Day 2 revisions 2 through 4. The runtime
  persists neither a successful unchanged-wire decision nor a HealthKit
  summary-read failure, so the current evidence cannot distinguish them. This
  is truthful no-new-score-revision evidence, not an App Attest pass or a new
  classified rejection.

## Paid-team signing and installation

- **PASS:** Xcode reads the paid Apple Developer team as an Admin team with one
  provisioned device.
- **PASS:** Automatic signing produced selected application commit `6ee1d22`
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
  selected artifact `6ee1d22`, active-competition derived scores, or background
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
  `6ee1d22`.
- **PARTIAL:** After the restored session was signed out, fresh native Sign in
  with Apple authorization completed directly on the physical iPhone for
  prior selected artifact `9d19937`. At `2026-08-19T06:59Z`, iPhone Mirroring
  read back the authenticated Sharing UI. Then-selected artifact `dd0ed68` later
  preserved that session through over-install and relaunch. This remains a
  historical supporting receipt. The later native authorization on then-
  selected artifact `dd0ed68` superseded the `9d19937` limitation at that time;
  neither historical receipt proves fresh authorization on current artifact
  `6ee1d22`. No Apple account identity, authorization payload, token, or private
  screenshot is included.
- **PASS:** In the later user-approved sequence ending at
  `2026-08-19T17:13:03Z`, then-selected artifact `dd0ed68` itself completed sign-out,
  displayed its clean welcome screen, completed fresh native Sign in with
  Apple, and returned to authenticated Sharing without a warning. The evidence
  retains no account identity, authorization payload, token, private
  screenshot, raw HealthKit datum, or exact Activity value.
- **PASS:** On `2026-08-22` PDT, selected source commit `6ee1d22` was signed with
  the paid-team profile, passed strict signature and capability validation, and
  over-installed without erasing the existing profile-scoped app container;
  the stable profile-subtree counts remained unchanged. Exactly one
  controlled process launch occurred and the app was
  stopped afterward. Authenticated Sharing was visible with a competition-
  refresh warning. This exact-current receipt does not claim a fresh native
  Apple authorization, active HealthKit score, or App Attest request.
- **PASS:** In a separately approved exact-current physical sequence on
  `2026-08-23`, selected source `6ee1d22` launched exactly once at
  `07:08:39Z`, initiated exactly one native Sign in with Apple action at
  `07:09:19.909Z`, and the user directly confirmed sign-in after handling the
  system prompt. A privacy-safe post-confirmation readback found one profile-
  scoped root with ten aggregate files; it retained no identity, token, file
  content, profile identifier, HealthKit value, score, or screenshot. The
  mirror became privacy-black and interrupted, so this passes native physical
  authorization but not warning-free refresh. Receipt SHA-256:
  `f6decf0e161e306ab6f340db88e0c0edf50e3fe6fa297e1a3a05d1456aed0441`.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PASS | Selected artifact `6ee1d22` was signed with the paid-team profile, over-installed as `com.narenyenuganti.HealthComp.staging`, preserved its stable profile-subtree counts, and completed two separately approved bounded launches with no in-window retry. The first reached authenticated Sharing with a competition-refresh warning; the second lacked an iPhone Mirroring window and is classified only by process, local, and hosted evidence |
| Sign in with Apple | PASS | Selected artifact `6ee1d22` launched once at `2026-08-23T07:08:39Z`, initiated exactly one native authorization action at `07:09:19.909Z`, and the user directly confirmed sign-in after handling the system prompt. A privacy-safe post-confirmation readback found one profile-scoped root with ten aggregate files. The mirror did not provide an authenticated-screen screenshot or hosted auth-log receipt, so warning-free refresh remains a separate partial gate |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed historically, and all app-requested categories were granted on prior artifact `9d19937`; exact-current `6ee1d22` launched under the retained same-bundle grant but produced no new score revision. Hosted logs prove remote reconciliation succeeded, but the retained evidence cannot distinguish an unchanged privacy-safe wire from a HealthKit summary-read failure. Active-competition derived score and background-observer behavior remain pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Selected artifact `6ee1d22` and active staging Function version 9 passed build/deployment guards, but both physical launches left the four-challenge / one-key / one-consumed-grant / one-accepted-score aggregate unchanged and generated no physical-launch Function invocation. The latest launch completed remote reconciliation and retained four terminal score revisions but no new revision, so it did not execute a new App Attest service gate. A new competition-day wire, replay rejection, and replacement-installation flow remain pending |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | DEFERRED | User-approved private-beta deferral because no HTTPS invitation domain will be provided; custom-scheme fallback is not universal-link evidence |
| Replacement installation | PENDING | Same-phone remove/reinstall, new installation and App Attest enrollment, retired-installation isolation, and no local-data resurrection |

## Multi-user and operational gates

- **PARTIAL:** Both dedicated accounts have authenticated staging profiles.
  Then-selected artifact `dd0ed68` completed one replacement invitation,
  controlled custom-scheme sharing, cold physical acceptance, single hosted
  consumption, two-participant membership, and scheduled-state convergence on
  the approved one-physical-iPhone-plus-Simulator topology. This remains
  historical runtime evidence after selection advanced to `6ee1d22`; PR #34
  continues to preserve terminal history and local journals without the former
  false warning.
- **PARTIAL:** The exact-current Account A readback proved hosted 200/204
  transport and a single isolated profile root, while the UI omitted the valid
  hosted active competition and reported a generic activity-refresh warning.
  Read-only diagnosis localized that mismatch to a typed on-device Activity
  read aborting the whole per-competition result after successful remote
  materialization. PR #62 is integrated as `0e08e2a` with complete focused,
  exact-head, and post-merge automation. Its first exact-candidate Simulator
  launch action retained the authenticated profile but yielded only a protected/
  blank surface and no attributable transport evidence. A fresh approved launch
  must still show the remote competition plus the truthful Activity-specific
  warning before this runtime gate advances.
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
- **PARTIAL:** A read-only inventory ending at `2026-08-23T06:06:35Z` found a
  dedicated `healthcomp-production` project active and healthy in the same
  organization as staging. It has zero deployed Edge Functions and zero
  configured secret names. No repository link, API-key read, database access,
  provider inspection, migration inspection, deployment, secret change, or
  production mutation occurred. Production configuration, promotion, backup
  policy, and release evidence remain pending.

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
