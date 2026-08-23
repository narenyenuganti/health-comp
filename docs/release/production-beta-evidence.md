# HealthComp Production Beta Evidence

This file records anonymized, reproducible rollout receipts. It excludes Apple
account details, device identifiers, tokens, private screenshots, raw HealthKit
data, exact Activity values, and reversible local fingerprints.

## Evidence snapshot

The user-approved completion topology is one physical iPhone, one or more iOS
Simulators, and two distinct Apple accounts. A second physical iPhone is not
required. Physical-only platform services still require evidence from the one
physical phone. Universal links are explicitly deferred because no HTTPS
invitation domain will be provided; the custom-scheme fallback must not be
represented as universal-link evidence.

| Scope | Current evidence | Disposition |
| --- | --- | --- |
| Application source | `6ee1d2260cfcbe02a950630ef979076c317eca49`, the selected application baseline and build-source commit; later evidence-only documentation commits do not change that selection | PASS |
| Selected release artifact | `6ee1d2260cfcbe02a950630ef979076c317eca49`; selected for the remaining staging and physical gates, but not cleared for production | PARTIAL |
| Current integrated application candidate | PR #62 merged as `0e08e2a0dc9f7ccfbcaa1f2c87df10ec184da684`; its reviewed Activity-isolation change and complete CI lineage are green, but it is not yet selected because exact-candidate authenticated staging runtime remains unproven | PARTIAL |
| Backend CI | Selected-application post-merge [run 32560065403](https://github.com/narenyenuganti/health-comp/actions/runs/32560065403) completed successfully on application baseline `6ee1d22`. Exact PR #52 head passed before merge | PASS |
| iOS CI | Selected-application post-merge [run 32560065372](https://github.com/narenyenuganti/health-comp/actions/runs/32560065372) completed successfully on application baseline `6ee1d22`: deterministic generation, both Core configurations, the complete app-test suite, unsigned Debug/Staging/Release device builds, and the clean-tree check passed. Exact PR #52 head passed the same matrix before merge | PASS |
| Evidence publication | Evidence-only PR #27 merged as `2d2d5cf` without changing the then-selected pre-icon application artifact. Exact-head [Backend run 32027282748](https://github.com/narenyenuganti/health-comp/actions/runs/32027282748) and [iOS run 32027282728](https://github.com/narenyenuganti/health-comp/actions/runs/32027282728), followed by post-merge [Backend run 32030763547](https://github.com/narenyenuganti/health-comp/actions/runs/32030763547) and [iOS run 32030763718](https://github.com/narenyenuganti/health-comp/actions/runs/32030763718), completed successfully | PASS |
| App icon integration | PR #29 selected the supplied white 1024-pixel logo as AppIcon, retained all six supplied black and white source assets, removed only the opaque alpha channel from the selected icon, and passed exact-head [Backend run 32099524516](https://github.com/narenyenuganti/health-comp/actions/runs/32099524516) and [iOS run 32099524540](https://github.com/narenyenuganti/health-comp/actions/runs/32099524540). Those reviewed assets remain unchanged in selected commit `6ee1d22` | PASS |
| Terminal-invitation synchronization | PR #34 makes declined, expired, and cancelled descriptors prune only the matching local inventory item before materialization, while preserving the local journal and server-retained history. Focused runtime tests passed 22/22, including expired, declined, and cancelled cases; exact-head and post-merge CI passed. A corrected physical authenticated relaunch remained warning-free after a bounded refresh window | PASS |
| Remote Activity refresh isolation integration | Read-only hosted staging and offline profile-scoped inspection showed that a valid gap-free two-participant competition was durably materialized before its on-device Activity read failed, but the typed Activity failure was promoted to a fatal per-competition result. PR #62 application-source commit `1a2ddb535f938e0acce9ec255c209fcec0deb2ee` keeps that validated remote materialization visible, persists its server cursor, and reports a separate truthful Activity issue while leaving storage, outbox, App Attest, score-submission, cancellation, and server-contract failures fatal. The focused runtime/client, HealthKit-provider, and presentation matrix passed 91/91. Exact-source [Backend run 32634210205](https://github.com/narenyenuganti/health-comp/actions/runs/32634210205) and [iOS run 32634210213](https://github.com/narenyenuganti/health-comp/actions/runs/32634210213), final-head [Backend run 32635614190](https://github.com/narenyenuganti/health-comp/actions/runs/32635614190) and [iOS run 32635614199](https://github.com/narenyenuganti/health-comp/actions/runs/32635614199), and post-merge [Backend run 32636617904](https://github.com/narenyenuganti/health-comp/actions/runs/32636617904) and [iOS run 32636617875](https://github.com/narenyenuganti/health-comp/actions/runs/32636617875) passed. PR #62 merged as current-main candidate `0e08e2a`; integration passes, while candidate runtime, physical HealthKit, and App Attest remain incomplete | PASS |
| Historical evidence publication | PR #36 merged the then-current Sign in with Apple receipt as `a45c325` without changing selected application commit `dd0ed68`. Exact-head [Backend run 32280929100](https://github.com/narenyenuganti/health-comp/actions/runs/32280929100) and [iOS run 32280929157](https://github.com/narenyenuganti/health-comp/actions/runs/32280929157), followed by post-merge [Backend run 32284529024](https://github.com/narenyenuganti/health-comp/actions/runs/32284529024) and [iOS run 32284529049](https://github.com/narenyenuganti/health-comp/actions/runs/32284529049), completed successfully. The receipt is historical after selection advanced to `6ee1d22` | PASS |
| App Attest recovery and diagnostics integration | PRs #43, #45, #46, #47, #48, #51, and #52 serially integrated startup-race recovery, hosted-worker boot repair, the compatible verification graph, terminal rejection recovery, privacy-safe rejection-stage diagnostics, corrected assertion-signature verification, and client-side submission serialization. Both required hosted workflows passed on every exact PR head and again on selected merge `6ee1d22` | PASS |
| Supabase transport | On pre-recovery transport baseline `21af9a7`, the focused transport/authentication/profile-isolation/API gate passed 52 tests and canonical local `HealthCompTests` passed 457/457; the integrated recovery matrix later passed the expanded 459-test canonical suite; CodeRabbit reported no findings | PASS |
| Historical signed Simulator staging | On reviewed PR #26 source whose application tree merged as pre-icon commit `ae28c6a`, existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared. This is historical transport evidence, not exact-current Simulator runtime | PASS |
| Historical Simulator preparation | At `2026-08-19T18:36:33Z`, then-selected application source `dd0ed68` was rebuilt from docs-only main `a45c325` as the Staging Simulator bundle. Offline inspection confirmed the staging bundle ID, expected public project URL, publishable-key shape, blank invitation host, custom-scheme fallback, and Xcode-generated simulated sandbox/development capability values without exposing credentials. The bundle over-installed on the dedicated tester, exactly matched the verified build, preserved all 19 pre-existing data-container files, remained stopped, and was shut down without contacting hosted staging. Its 1.5 GiB DerivedData was removed. This is historical preparation, not exact-current runtime evidence | PASS |
| Exact-current Simulator preparation | Selected application source `6ee1d22` was rebuilt normally for the dedicated iOS 18.4 staging tester after the earlier retained executable was found to lack its simulated-entitlement section. The corrected retained 44 MiB app has executable SHA-256 `ed61736fc205791ecb0aef5c167461130193012a68993a847bdea252917b9c4b`, passes strict code-signature validation, and contains the expected embedded Simulator entitlements. A state-preserving over-install retained the existing profile content; temporary DerivedData was removed. This proves exact-current signed preparation, while the separate runtime rows record what authenticated execution proved | PASS |
| Integrated-candidate Simulator launch | Current-main candidate `0e08e2a` was built as the exact staging Simulator bundle with frozen package resolution; its embedded simulated capability and public configuration boundaries were verified, and a state-preserving over-install retained one authenticated profile root with seven files. The installed executable matched SHA-256 `4308ed164cabe956eaa785038700c16968715cf1516e6e86be5492c622865df7`. The first explicitly approved launch action at `2026-08-23T18:11:40Z` exposed only a protected/blank surface and stopped before an attributable runtime result; its privacy-safe receipt SHA-256 is `cc8c28a12bbf1b2b5773c3e479972874de61cb9b74e67b3e13466faef035d6e4`. After an unrelated storage cleanup removed the complete Simulator device set, a targeted read-only Time Machine snapshot recovery restored only the dedicated tester and required registry. Independent validation matched the exact executable, one profile root, and seven files before a separately approved one-launch retry. That retry ran from `2026-08-23T21:36:23Z` through bounded termination at `23:29:26Z`, reached authenticated Sharing immediately, and retained `No Competition` plus `Some competition activity could not be refreshed.` A credential-free Simulator-to-staging TLS probe succeeded, but the process window contained 72 CFNetwork connection-loss / `-1005` markers and no precise HTTP status marker; warning-free authenticated transport is not claimed. After termination, the exact executable, single root, seven files, one five-envelope journal, and zero-entry inventory remained; only the inventory document changed, and no second profile root appeared. No pull-to-refresh or other in-app action occurred. The recovery-retry receipt SHA-256 is `8dc3a1885446c373dd530f7d0a703af3e08a95270359220f35138a43874450d1`. This proves exact-candidate authenticated session recovery and profile isolation, not successful runtime execution of the Activity-isolation fix | PARTIAL |
| Exact-current Simulator launch | Following explicit approval, exact staging bundle `com.narenyenuganti.HealthComp.staging` launched once from `2026-08-22T23:55:00Z` through `23:55:30Z`, settled on the clean welcome screen, and was terminated. Sign in with Apple was not pressed; no in-app action occurred. The data-container count remained 23 files and the post-window process count was zero. The bounded log contained two occurrences of Supabase Swift v2.55.1's advisory initial-session warning and two successful network-activity completion markers, but no retained HTTP status marker. Pinned-source inspection confirms that warning is emitted by the SDK's default initial-session path and does not itself prove refresh failed. The receipt cannot distinguish an already-absent session from one removed during terminal refresh. The preserved profile root remained unmounted, maintaining fail-closed cross-profile isolation. This is not authenticated staging transport or Account B profile-mount evidence | PARTIAL |
| Exact-current Account B native authentication and isolation | In one user-approved sequence ending at `2026-08-23T01:46:25Z`, selected source `6ee1d22` signed out the recovered Simulator session only after remote installation teardown completed, reached Welcome, and reduced local profile storage to zero roots and zero files. Exactly one native Account B Sign in with Apple attempt then completed under human credential entry and reached authenticated Sharing with `No Competition`. The new session mounted exactly one profile root with seven files, including one preserved four-envelope history journal; no second profile root was present. The bounded process log contained 39 HTTP 200 and one HTTP 204 markers, with zero non-2xx, `-1005`, `-7026`, or missing-entitlement markers. The single root and seven files remained after termination. The privacy-safe receipt SHA-256 is `5cf006c7918165373d15679a9cfcbb6988fcae68dc97c0c68b5efb0e07750f08`; it retains no identity, token, private identifier, screenshot, HealthKit value, or credential. The UI still reported `Some competition activity could not be refreshed.`, so this passes native authentication and profile-root isolation but not warning-free historical refresh | PASS |
| Exact-current Account A recovery after Account B | In a separately approved sequence ending at `2026-08-23T08:36:05Z`, selected source `6ee1d22` first completed Account B's server-confirmed HealthComp sign-out and read back zero profile roots and zero profile files. The Simulator's Apple session was then changed under human credential entry to the earlier Account A. Exactly one native HealthComp Sign in with Apple attempt completed, the user completed the HealthKit authorization sheet, and authenticated Sharing settled at `No Competition`. Account A mounted exactly one profile root with seven files and one preserved five-envelope history journal; no second root was present. The ten-minute process-log aggregate contained 118 HTTP 200 and two HTTP 204 markers, with zero non-2xx, connection-lost / `-1005`, `-7026`, or missing-entitlement markers. The sole root and seven files remained after termination. The privacy-safe receipt SHA-256 is `7bdb11a5e30aa71ea1bb8710d3ef0bc5b5bfdd91d61b42bcd184c694fe59e8fe`. This strengthens exact-current sequential account isolation and native authorization, but the UI retained `Some competition activity could not be refreshed.` and no active competition was recovered | PASS |
| Realtime recovery integration | PR #26 pins Supabase Swift 2.55.1, passed the 90-test focused recovery matrix and 459/459 canonical app tests, passed 241/241 CompetitionCore tests in both Debug and Release, built unsigned Debug/Staging/Release device configurations, generated the project deterministically, and received a zero-finding CodeRabbit source review. A signed Staging Simulator over-install left the data-container file count unchanged at 19, restored the authenticated Sharing UI, and produced 42 process-local HTTP-200 markers with zero `-1005`, HealthKit-entitlement, or crash markers from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. Early hosted attempts exposed and closed cross-Xcode resolved-file omissions, then exposed the cancellation actor-hop race. The strengthened race passed 100/100 locally and exact-head hosted run `32020898831` passed the complete matrix. PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`, whose tree is identical to the reviewed PR head. PR #29 later added only the reviewed app-icon assets and selected `9d19937`. No invitation action occurred | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Production project inventory | A read-only CLI audit ending at `2026-08-23T06:06:35Z` found the dedicated `healthcomp-production` project active and healthy in the same organization as staging, with zero deployed Edge Functions and zero configured secret names. The repository remained unlinked; no API key, database password, secret value, migration history, provider setting, or private row was requested or retained. The privacy-safe receipt SHA-256 is `df6cf08bbbc13ab6b9b50abb770e366eadb5b023edbfbba7823976453930c497`. This proves project existence only, not configuration, promotion, backup availability, or release readiness | PARTIAL |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Automatic paid-team signing produced selected source commit `6ee1d2260cfcbe02a950630ef979076c317eca49` for the paired physical iPhone using frozen package resolution. The embedded profile was unexpired, included the selected phone, and authorized exact App ID `23LUYD78QK.com.narenyenuganti.HealthComp.staging`, sandbox APNs, Sign in with Apple, HealthKit with background delivery, and App Attest; the bundle passed strict code-signature validation | PASS |
| Physical install | On `2026-08-22` PDT, selected source commit `6ee1d22` over-installed successfully as `com.narenyenuganti.HealthComp.staging` without launching. The stable profile subtree remained 17 entries, seven directories, three outbox files, one App Attest state file, three competition files, and two server cursors. This proves a same-bundle upgrade, not the later remove/reinstall replacement lifecycle that must retire an installation and App Attest key | PASS |
| Physical launch | Five separately approved `6ee1d22` windows each launched exactly once and ended without an in-window retry. The first showed authenticated Sharing with `Some competition activity could not be refreshed.` The second had no iPhone Mirroring window and is classified only by process, local, and hosted evidence. The third cold-launched to signed-out Welcome without pressing Sign in with Apple; local counts and bounded App Attest/score Function invocations were unchanged. The fourth initiated one native Apple-auth transition but returned to Welcome without a session. The fifth launched at `2026-08-23T07:08:39Z`, initiated exactly one native Apple-auth action at `07:09:19.909Z`, received direct user confirmation of sign-in, retained one running app process for the bounded readback, and was then terminated with zero HealthComp processes remaining. The fifth receipt SHA-256 is `f6decf0e161e306ab6f340db88e0c0edf50e3fe6fa297e1a3a05d1456aed0441`. No screenshot or private value was retained | PASS |
| Sign in with Apple | In the exact-current physical sequence on selected source `6ee1d22`, the app launched once at `2026-08-23T07:08:39Z`, exactly one native Apple authorization action began at `07:09:19.909Z`, and the user directly confirmed `Signed in` after handling the system prompt. A post-confirmation privacy-safe local readback found one profile-scoped root with ten aggregate files: three competition-event files, three outbox files, two server-cursor files, one installation file, one App Attest file, and zero notification-preference files. iPhone Mirroring became privacy-black and then interrupted, so no authenticated-screen screenshot or hosted auth-log receipt was retained. This passes the bounded physical native-authorization gate, but does not prove warning-free refresh or any other physical-service gate | PASS |
| Authenticated refresh | The prior `9d19937` relaunch reproduced `Some competition activity could not be refreshed.` and privacy-safe hosted readbacks isolated two terminal descriptors. PR #34 corrected the terminal-descriptor boundary, and then-selected artifact `dd0ed68` reached authenticated Sharing without a warning. Exact-current `6ee1d22` reached authenticated Sharing on the physical phone and sequentially on both Simulator accounts, but every retained UI readback still showed the historical-activity refresh warning. Account B mounted one four-envelope journal after zero-root teardown; the later Account A recovery again started from zero roots and mounted one distinct five-envelope journal. Both bounded `6ee1d22` Simulator windows returned only HTTP 200/204 markers with no non-2xx, connection-loss, `-7026`, or missing-entitlement marker. The later exact-candidate `0e08e2a` recovery retry again reached authenticated Sharing with the same generic warning and `No Competition`; its process window instead contained 72 CFNetwork `-1005` markers despite a successful credential-free staging TLS probe. The single five-envelope Account A journal remained unchanged and the refreshed inventory persisted zero entries, so the Activity-isolation behavior still lacked a remote competition to materialize. Warning-free exact-current refresh remains unproven | PARTIAL |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration and foreground/background/cold delivery on selected release artifact `6ee1d22` remain pending | PARTIAL |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths historically. On prior artifact `9d19937`, all app-requested categories were granted through the native Health Access sheet. Exact-current `6ee1d22` launched under the retained same-bundle grant but produced no new score revision. API Gateway logs prove remote reconciliation succeeded, but the retained evidence cannot distinguish an unchanged privacy-safe wire from a HealthKit summary-read failure. Public HealthKit does not reveal read denial, so active-competition derived score and background-observer behavior remain unverified | PARTIAL |
| Exact-current App Attest no-new-score-revision receipt | Only `submit-score-revision` was advanced to active staging version 9 from reviewed `6ee1d22`; the credential-free boot probe retained the expected `400 invalid_request` boundary. Hosted aggregates remained four challenges, one consumed challenge, one key, one grant, one consumed grant, and one accepted score revision across the first two physical launches. The second approved launch ran from `2026-08-22T22:21:55Z` through `2026-08-22T22:23:33Z`; API Gateway logs showed successful HTTP 200 profile bootstrap, installation registration, competition listing, and change fetches plus an HTTP 101 Realtime WebSocket upgrade, while the Function remained at the one pre-launch boot probe. A temporary metadata-only outbox readback found four `appAttestRejectedTerminal` score revisions: Day 1 revision 1 and Day 2 revisions 2 through 4. The third approved launch ran from `2026-08-23T03:03:47Z` through `03:05:07Z`, reached signed-out Welcome, left local profile-scoped counts unchanged, and produced no invocation of `app-attest-challenge` or `submit-score-revision` in the dashboard's bounded window; their since-deploy counts remained four and one, respectively, with no reported errors. The app produced no new Day 3 revision and never reached App Attest. This third-window receipt is a signed-out no-attempt receipt, not acceptance, rejection, HealthKit-derived score evidence, or authenticated refresh evidence. The fourth window also ended without an authenticated session and left the outbox and App Attest file counts unchanged, but no hosted App Attest/score aggregate is claimed for that window | PENDING |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging database adversarial boundary | At `2026-08-20T01:18:06Z`, exact reviewed verifier commit `4fca597757befafc9ed10cafecc4af4b73e65026` ran against `healthcomp-staging` after SSL enforcement was enabled and read back. The certificate-verified session passed 15/15 database assertions, explicitly rolled back, independently found zero synthetic rows remaining, and returned no private values. The sole nonblank privacy-safe receipt has SHA-256 `852fc2d64c0daa93677726cda4fdddf4acd088b68884aa247939188f408660af`. This is database-boundary evidence only; replay of the consumed replacement invitation remains pending, while the separate sequential-Simulator receipt below now proves the profile-root isolation boundary | PASS |
| Staging expired-invitation cleanup | After both invitations expired, a privacy-safe snapshot returned exact count `2` and opaque scope SHA-256 `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`. Following action-time approval, the reviewed guard ran as one explicit serializable transaction through the authenticated Supabase Management API database-query route rather than `psql`; it retained the approved scope checks, timeouts, service-role request claim, cleanup-count assertion, and explicit commit. Dedicated read-only route readback at `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired competitions, two retained invitation-history rows, zero claimed or consumed invitations, and zero remaining eligible invitations. No identifier or token was selected, no lifecycle row was edited directly, and no replacement invitation was created | PASS |
| Historical staging replacement invitation | Following fresh action-time approval, then-selected artifact `dd0ed68` created exactly one replacement invitation on the isolated Simulator endpoint. The same opaque custom-scheme link cold-launched that physical artifact and was accepted once. Read-only hosted readback ending at `2026-08-19T21:56:37Z` found one scheduled replacement competition, exactly two participant rows, and exactly one corresponding invitation row with claimant and consumption time present. Both endpoints converged on the scheduled competition after controlled relaunch. No token, identity, private identifier, screenshot, raw HealthKit datum, or exact Activity value is retained; this is not universal-link evidence | PASS |
| Invitation Function route continuity | Application source `dd0ed68` routes live invitation creation through `create-competition-invite` and claims through `claim-competition-invite`; those route boundaries remain present in selected source `6ee1d22`. The then-selected artifact completed both actions above, and the hosted state records their create/consume effects. A read-only dashboard readback at `2026-08-20T02:32:28Z` reported exactly one invocation since the last deployment and no errors for each Function. No new request was sent, and no token, identity, request body, Function identifier, or execution identifier was retained | PASS |
| Historical sequential Simulator profile isolation | In a user-approved Account A to signed-out to Account B sequence ending at `2026-08-20T05:56:37Z`, then-selected artifact `dd0ed68` first mounted one Account A profile with three competition-journal files, two server cursors, one installation file, and no outbox, notification-preference, or App Attest file. After server-confirmed installation retirement, sign-out reached the clean welcome screen, reduced `Profiles/v1` to zero profile directories and zero profile files, and moved the aggregate sandbox installation state from two active / three revoked to one active / four revoked while the physical phone was untouched. A distinct Apple account then authenticated directly through HealthComp without enabling full Simulator iCloud sync. The app mounted exactly one Account B root, displayed the prior participant only as the legitimate scheduled opponent, and contained three server-rematerialized competition files, two cursors, one newly active installation, and zero outbox, notification-preference, or App Attest files. Aggregate hosted readback returned two active / four revoked installations. The same profile-transition test remains in the exact-current suite, seeds a private prior-profile outbox, and proves it is absent after teardown and the next profile mount. No Apple account, profile or installation identifier, token, local fingerprint, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Two-account staging convergence | Invitation creation, controlled custom-scheme delivery, cold acceptance, single consumption, two-participant membership, and scheduled-state convergence passed historically on the approved physical-iPhone-plus-Simulator topology. The competition started `2026-08-20` in its frozen `America/Los_Angeles` time zone, but exact-current `6ee1d22` produced no changed Day 1 wire snapshot or accepted score; Day 1 convergence and the remaining lifecycle/isolation cases are incomplete | PARTIAL |

## What the physical receipt proves

The exact-current physical receipts prove that source commit
`6ee1d2260cfcbe02a950630ef979076c317eca49` can be built with frozen package
resolution, signed by the paid team, strictly validated, and over-installed on
the paired iPhone without erasing the profile-scoped container. The stable
profile subtree remained 17 entries, seven directories, three outbox files,
one App Attest state file, three competition files, and two server cursors.
Each separately approved window launched exactly once and stopped without an
in-window retry. The first showed authenticated Sharing with a competition-
refresh warning; the second lacked an iPhone Mirroring window and is classified
only by process, local, and hosted evidence. The third reached signed-out
Welcome and a passive ten-second refresh did not recover a session. Sign in
with Apple was not pressed, local profile-scoped counts were unchanged, and the
bounded dashboard readback showed no new App Attest challenge or score Function
invocation. The fourth reached Welcome, initiated one native Apple-auth
transition, returned to Welcome without an authenticated session or a retained
credential/two-factor prompt, and preserved the same profile-scoped counts. No
private screenshot was retained. The third window is a signed-out no-attempt
receipt; the fourth is a native-attempt/no-session receipt. A fifth bounded
window launched once, initiated one native Apple authorization action, and the
user directly confirmed sign-in after handling the system prompt. A privacy-
safe post-confirmation readback found one profile-scoped root and ten aggregate
files; the process was then stopped and the temporary copy moved to Trash. The
mirror became privacy-black and interrupted during the system transition, so
the fifth receipt contains no authenticated-screen screenshot or hosted auth-
log evidence. It proves the exact-current physical native-authorization gate,
not warning-free refresh or another platform-service gate.

The second controlled window proves the client successfully reached hosted
profile bootstrap, installation registration, competition listing, and change
fetches over HTTP 200 plus Realtime over HTTP 101 without creating a score
revision. Staging
retained four challenges, one consumed challenge, one key, one grant, one
consumed grant, and one accepted score revision. The sole Function invocation
since version-9 deployment remained the pre-launch credential-free boot probe.
The profile-scoped outbox retained four terminal score revisions and no pending
retry. The available evidence does not distinguish an unchanged Day 2 wire
from a HealthKit summary-read failure because neither decision is persisted.
This is a fail-closed no-new-score-revision receipt, not App Attest acceptance
or a new classified rejection.

Then-selected artifact `dd0ed683a78de216f622e2a958baeda1cb996e46`
historically proved authenticated Sharing, a warning-free refresh, and fresh
native Sign in with Apple on the physical phone. Prior artifact
`9d199377f5d72cb7bc90133c190e4e7681abfb41` proved fresh selected-icon
rendering and native Health Access approval. Broader source
`1ca67af76b738bd7fbb19277b238b448a555f8ef` proved initial paid-team signing,
native authentication, staging profile bootstrap, and sandbox installation
registration. Commit `cb21189` separately remains lineage evidence for the
earlier version-7 no-new-event attempt. These remain historical capability
receipts only after selection advanced to `6ee1d22`.

No retained receipt contains an account identity, authorization payload, token,
private screenshot, raw HealthKit datum, exact Activity value, device
identifier, challenge identifier, or App Attest material. Current evidence does
not prove active-competition HealthKit derived-score behavior, background
delivery, APNs foreground/background/cold-route delivery, App Attest
acceptance, deletion, or the same-phone replacement lifecycle.

## Immediate continuation

1. Obtain fresh approval for exactly one deterministic launch of installed
   candidate `0e08e2a` on the dedicated staging Simulator. Retain only
   privacy-safe UI, transport-status, process, and aggregate profile/cursor
   evidence. The gate advances only if validated remote competition state is
   visible while an on-device Activity failure is reported separately; do not
   treat another protected/blank surface as success.
2. On a genuinely new competition day or changed
   privacy-safe wire, obtain separate fresh approval for exactly one physical
   launch with iPhone Mirroring open. Read back only privacy-safe App Attest and
   score receipts; do not infer eligibility from an unrelated Health datum.
   Continue active HealthKit, background observer, and APNs foreground/
   background/cold-route evidence on the same build. The Account B Simulator
   native-authentication and profile-root-isolation sub-gate now passes.
3. Continue the adversarial matrix above the proven database and sequential-
   Simulator profile-root boundaries plus current-source Function-route
   continuity supported by the historical `dd0ed68` runtime receipt: replay the
   consumed replacement invitation when its token is available and finish the
   remaining lifecycle isolation cases.
4. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

- Current-main candidate `0e08e2a` is integrated and green, but its one approved
  staging Simulator launch action yielded only a protected/blank surface, no
  running HealthComp process at settled readback, no attributable transport or
  diagnostic evidence, and no post-launch profile-file change. The sole profile
  root and seven aggregate files were preserved. This does not select the
  candidate or prove the Activity-isolation runtime fix; a new launch requires
  fresh action-time approval.
- A partial two-account staging E2E receipt exists on then-selected artifact
  `dd0ed68`: it created exactly one replacement invitation, the physical endpoint
  cold-accepted it once through the controlled custom scheme, hosted staging
  records one consumed invitation and exactly two participants, and both
  endpoints show the same scheduled competition. The remaining lifecycle and
  isolation matrix is not complete.
- The replacement invitation is consumed and the competition started on
  `2026-08-20` in its frozen `America/Los_Angeles` time zone. Exact-current
  `6ee1d22` generated no changed Day 1 wire snapshot or accepted score; the
  earlier two expired invitation-history rows remain retained.
- Selected source `6ee1d22` is installed on the physical iPhone and stopped.
  Its corrected exact-current Simulator executable matches the retained signed
  build. The approved Account B native authorization now passes: prior profile
  teardown reached zero roots and zero files, Account B mounted exactly one
  root, authenticated transport returned only HTTP 200/204 status markers, and
  the UI showed `No Competition`. One four-envelope Account B history journal
  remains preserved and the historical-activity refresh warning persists.
  Exact-current native authorization on the physical phone now has one bounded,
  user-confirmed PASS receipt. The mirror did not provide a post-authenticated
  UI readback, so warning-free refresh remains unresolved.
- The rollback-only hosted database adversarial receipt passed 15/15 with zero
  residue, current-source create/claim route continuity is proven while the
  successful runtime receipt remains historical, and sequential Simulator
  profile-root teardown/remount now passes with remote installation retirement
  and re-registration. Replay of the consumed replacement invitation when its
  token is available and the remaining lifecycle isolation cases remain
  unresolved.
- Selected release artifact `6ee1d22` is installed and not in the foreground.
  Its first controlled physical window showed authenticated Sharing with a
  competition-refresh warning; the third reached signed-out Welcome without an
  auth action, and the fourth initiated one native Apple-auth transition but
  returned to Welcome without a session. A fifth window then completed exactly
  one user-confirmed native Sign in with Apple action on this exact artifact;
  warning-free refresh and active HealthKit behavior remain unverified.
- The first two exact-current App Attest launch windows produced no new score
  revision or hosted submission request. The second completed remote
  reconciliation, but its evidence cannot distinguish an unchanged privacy-safe
  wire from a HealthKit summary-read failure. The third was signed out and made
  no App Attest challenge or score Function request, so it is a no-attempt
  receipt. No acceptance or new classified-rejection receipt exists.
- No active-competition accepted score, background-observer, APNs delivery,
  deletion, or same-phone replacement-installation receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- The dedicated production Supabase project exists and is healthy, but it has
  no deployed Functions or configured secret names and has not been promoted.
- The product is not production-ready.
