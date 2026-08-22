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
| Backend CI | Selected-application post-merge [run 32560065403](https://github.com/narenyenuganti/health-comp/actions/runs/32560065403) completed successfully on application baseline `6ee1d22`. Exact PR #52 head passed before merge | PASS |
| iOS CI | Selected-application post-merge [run 32560065372](https://github.com/narenyenuganti/health-comp/actions/runs/32560065372) completed successfully on application baseline `6ee1d22`: deterministic generation, both Core configurations, the complete app-test suite, unsigned Debug/Staging/Release device builds, and the clean-tree check passed. Exact PR #52 head passed the same matrix before merge | PASS |
| Evidence publication | Evidence-only PR #27 merged as `2d2d5cf` without changing the then-selected pre-icon application artifact. Exact-head [Backend run 32027282748](https://github.com/narenyenuganti/health-comp/actions/runs/32027282748) and [iOS run 32027282728](https://github.com/narenyenuganti/health-comp/actions/runs/32027282728), followed by post-merge [Backend run 32030763547](https://github.com/narenyenuganti/health-comp/actions/runs/32030763547) and [iOS run 32030763718](https://github.com/narenyenuganti/health-comp/actions/runs/32030763718), completed successfully | PASS |
| App icon integration | PR #29 selected the supplied white 1024-pixel logo as AppIcon, retained all six supplied black and white source assets, removed only the opaque alpha channel from the selected icon, and passed exact-head [Backend run 32099524516](https://github.com/narenyenuganti/health-comp/actions/runs/32099524516) and [iOS run 32099524540](https://github.com/narenyenuganti/health-comp/actions/runs/32099524540). Those reviewed assets remain unchanged in selected commit `6ee1d22` | PASS |
| Terminal-invitation synchronization | PR #34 makes declined, expired, and cancelled descriptors prune only the matching local inventory item before materialization, while preserving the local journal and server-retained history. Focused runtime tests passed 22/22, including expired, declined, and cancelled cases; exact-head and post-merge CI passed. A corrected physical authenticated relaunch remained warning-free after a bounded refresh window | PASS |
| Historical evidence publication | PR #36 merged the then-current Sign in with Apple receipt as `a45c325` without changing selected application commit `dd0ed68`. Exact-head [Backend run 32280929100](https://github.com/narenyenuganti/health-comp/actions/runs/32280929100) and [iOS run 32280929157](https://github.com/narenyenuganti/health-comp/actions/runs/32280929157), followed by post-merge [Backend run 32284529024](https://github.com/narenyenuganti/health-comp/actions/runs/32284529024) and [iOS run 32284529049](https://github.com/narenyenuganti/health-comp/actions/runs/32284529049), completed successfully. The receipt is historical after selection advanced to `6ee1d22` | PASS |
| App Attest recovery and diagnostics integration | PRs #43, #45, #46, #47, #48, #51, and #52 serially integrated startup-race recovery, hosted-worker boot repair, the compatible verification graph, terminal rejection recovery, privacy-safe rejection-stage diagnostics, corrected assertion-signature verification, and client-side submission serialization. Both required hosted workflows passed on every exact PR head and again on selected merge `6ee1d22` | PASS |
| Supabase transport | On pre-recovery transport baseline `21af9a7`, the focused transport/authentication/profile-isolation/API gate passed 52 tests and canonical local `HealthCompTests` passed 457/457; the integrated recovery matrix later passed the expanded 459-test canonical suite; CodeRabbit reported no findings | PASS |
| Historical signed Simulator staging | On reviewed PR #26 source whose application tree merged as pre-icon commit `ae28c6a`, existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared. This is historical transport evidence, not exact-current Simulator runtime | PASS |
| Historical Simulator preparation | At `2026-08-19T18:36:33Z`, then-selected application source `dd0ed68` was rebuilt from docs-only main `a45c325` as the Staging Simulator bundle. Offline inspection confirmed the staging bundle ID, expected public project URL, publishable-key shape, blank invitation host, custom-scheme fallback, and Xcode-generated simulated sandbox/development capability values without exposing credentials. The bundle over-installed on the dedicated tester, exactly matched the verified build, preserved all 19 pre-existing data-container files, remained stopped, and was shut down without contacting hosted staging. Its 1.5 GiB DerivedData was removed. This is historical preparation, not exact-current runtime evidence | PASS |
| Realtime recovery integration | PR #26 pins Supabase Swift 2.55.1, passed the 90-test focused recovery matrix and 459/459 canonical app tests, passed 241/241 CompetitionCore tests in both Debug and Release, built unsigned Debug/Staging/Release device configurations, generated the project deterministically, and received a zero-finding CodeRabbit source review. A signed Staging Simulator over-install left the data-container file count unchanged at 19, restored the authenticated Sharing UI, and produced 42 process-local HTTP-200 markers with zero `-1005`, HealthKit-entitlement, or crash markers from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. Early hosted attempts exposed and closed cross-Xcode resolved-file omissions, then exposed the cancellation actor-hop race. The strengthened race passed 100/100 locally and exact-head hosted run `32020898831` passed the complete matrix. PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`, whose tree is identical to the reviewed PR head. PR #29 later added only the reviewed app-icon assets and selected `9d19937`. No invitation action occurred | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Automatic paid-team signing produced selected source commit `6ee1d2260cfcbe02a950630ef979076c317eca49` for the paired physical iPhone using frozen package resolution. The embedded profile was unexpired, included the selected phone, and authorized exact App ID `23LUYD78QK.com.narenyenuganti.HealthComp.staging`, sandbox APNs, Sign in with Apple, HealthKit with background delivery, and App Attest; the bundle passed strict code-signature validation | PASS |
| Physical install | On `2026-08-22` PDT, selected source commit `6ee1d22` over-installed successfully as `com.narenyenuganti.HealthComp.staging` without launching. The stable profile subtree remained 17 entries, seven directories, three outbox entries, one App Attest state file, three competition files, and two server cursors. This proves a same-bundle upgrade, not the later remove/reinstall replacement lifecycle that must retire an installation and App Attest key | PASS |
| Physical launch | Exactly one controlled `6ee1d22` launch began at `2026-08-22T08:29:49Z` and was stopped at `2026-08-22T08:30:51Z` without relaunching. Authenticated Sharing was visible with `Some competition activity could not be refreshed.` No screenshot or private value was retained. The local and hosted receipts below prove the launch generated no new eligible score/App Attest event | PASS |
| Sign in with Apple | In a user-approved physical sequence ending at `2026-08-19T17:13:03Z`, then-selected artifact `dd0ed68` completed sign-out, reached its clean welcome screen, completed fresh native Sign in with Apple, and returned to authenticated Sharing without a warning. Exact-current `6ee1d22` preserved the same-bundle container and launched, but did not repeat native authorization | PARTIAL |
| Authenticated refresh | The prior `9d19937` relaunch reproduced `Some competition activity could not be refreshed.` and privacy-safe hosted readbacks isolated two terminal descriptors. PR #34 corrected the client boundary, and then-selected artifact `dd0ed68` reached authenticated Sharing without a warning. Exact-current `6ee1d22` reached authenticated Sharing but again displayed the competition-refresh warning; retained server history and the stable profile subtree were not deleted | PARTIAL |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration and foreground/background/cold delivery on selected release artifact `6ee1d22` remain pending | PARTIAL |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths historically. On prior artifact `9d19937`, all app-requested categories were granted through the native Health Access sheet. Exact-current `6ee1d22` launched under the retained same-bundle grant but produced no changed privacy-safe wire snapshot. Public HealthKit does not reveal read denial, so active-competition derived score and background-observer behavior remain unverified | PARTIAL |
| Exact-current App Attest no-new-event receipt | Only `submit-score-revision` was advanced to active staging version 9 from reviewed `6ee1d22`; the credential-free boot probe retained the expected `400 invalid_request` boundary. Before and after the one physical launch, hosted aggregates remained four challenges, one consumed challenge, one key, one grant, one consumed grant, and one accepted score revision. The Function overview showed exactly one invocation since deployment—the pre-launch boot probe—so the physical launch made no submission request. Stable local profile-subtree counts also remained unchanged. The unchanged wire snapshot produced no new eligible attempt; this is neither acceptance nor a classified rejection | PENDING |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging database adversarial boundary | At `2026-08-20T01:18:06Z`, exact reviewed verifier commit `4fca597757befafc9ed10cafecc4af4b73e65026` ran against `healthcomp-staging` after SSL enforcement was enabled and read back. The certificate-verified session passed 15/15 database assertions, explicitly rolled back, independently found zero synthetic rows remaining, and returned no private values. The sole nonblank privacy-safe receipt has SHA-256 `852fc2d64c0daa93677726cda4fdddf4acd088b68884aa247939188f408660af`. This is database-boundary evidence only; replay of the consumed replacement invitation remains pending, while the separate sequential-Simulator receipt below now proves the profile-root isolation boundary | PASS |
| Staging expired-invitation cleanup | After both invitations expired, a privacy-safe snapshot returned exact count `2` and opaque scope SHA-256 `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`. Following action-time approval, the reviewed guard ran as one explicit serializable transaction through the authenticated Supabase Management API database-query route rather than `psql`; it retained the approved scope checks, timeouts, service-role request claim, cleanup-count assertion, and explicit commit. Dedicated read-only route readback at `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired competitions, two retained invitation-history rows, zero claimed or consumed invitations, and zero remaining eligible invitations. No identifier or token was selected, no lifecycle row was edited directly, and no replacement invitation was created | PASS |
| Historical staging replacement invitation | Following fresh action-time approval, then-selected artifact `dd0ed68` created exactly one replacement invitation on the isolated Simulator endpoint. The same opaque custom-scheme link cold-launched that physical artifact and was accepted once. Read-only hosted readback ending at `2026-08-19T21:56:37Z` found one scheduled replacement competition, exactly two participant rows, and exactly one corresponding invitation row with claimant and consumption time present. Both endpoints converged on the scheduled competition after controlled relaunch. No token, identity, private identifier, screenshot, raw HealthKit datum, or exact Activity value is retained; this is not universal-link evidence | PASS |
| Invitation Function route continuity | Application source `dd0ed68` routes live invitation creation through `create-competition-invite` and claims through `claim-competition-invite`; those route boundaries remain present in selected source `6ee1d22`. The then-selected artifact completed both actions above, and the hosted state records their create/consume effects. A read-only dashboard readback at `2026-08-20T02:32:28Z` reported exactly one invocation since the last deployment and no errors for each Function. No new request was sent, and no token, identity, request body, Function identifier, or execution identifier was retained | PASS |
| Historical sequential Simulator profile isolation | In a user-approved Account A to signed-out to Account B sequence ending at `2026-08-20T05:56:37Z`, then-selected artifact `dd0ed68` first mounted one Account A profile with three competition-journal files, two server cursors, one installation file, and no outbox, notification-preference, or App Attest file. After server-confirmed installation retirement, sign-out reached the clean welcome screen, reduced `Profiles/v1` to zero profile directories and zero profile files, and moved the aggregate sandbox installation state from two active / three revoked to one active / four revoked while the physical phone was untouched. A distinct Apple account then authenticated directly through HealthComp without enabling full Simulator iCloud sync. The app mounted exactly one Account B root, displayed the prior participant only as the legitimate scheduled opponent, and contained three server-rematerialized competition files, two cursors, one newly active installation, and zero outbox, notification-preference, or App Attest files. Aggregate hosted readback returned two active / four revoked installations. The same profile-transition test remains in the exact-current suite, seeds a private prior-profile outbox, and proves it is absent after teardown and the next profile mount. No Apple account, profile or installation identifier, token, local fingerprint, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Two-account staging convergence | Invitation creation, controlled custom-scheme delivery, cold acceptance, single consumption, two-participant membership, and scheduled-state convergence passed historically on the approved physical-iPhone-plus-Simulator topology. The competition started `2026-08-20` in its frozen `America/Los_Angeles` time zone, but exact-current `6ee1d22` produced no changed Day 1 wire snapshot or accepted score; Day 1 convergence and the remaining lifecycle/isolation cases are incomplete | PARTIAL |

## What the physical receipt proves

The exact-current physical receipt proves that source commit
`6ee1d2260cfcbe02a950630ef979076c317eca49` can be built with frozen package
resolution, signed by the paid team, strictly validated, and over-installed on
the paired iPhone without erasing the profile-scoped container. The stable
profile subtree remained 17 entries, seven directories, three outbox entries,
one App Attest state file, three competition files, and two server cursors.
The app process launched exactly once and was stopped without a second launch.
Authenticated Sharing was visible with a competition-refresh warning, but no
private screenshot was retained. This does not prove fresh native authorization.

The same controlled window proves the client did not fabricate or reopen an
App Attest attempt when the HealthKit-derived wire snapshot was unchanged.
Staging retained four challenges, one consumed challenge, one key, one grant,
one consumed grant, and one accepted score revision. The sole Function
invocation since version-9 deployment was the pre-launch credential-free boot
probe, so the physical launch made no score-submission request. This is a
fail-closed no-new-event receipt, not App Attest acceptance or a classified
rejection.

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

1. Wait for a genuinely changed HealthKit-derived wire snapshot or a new
   competition day, then obtain fresh approval for exactly one additional
   physical launch. Read back only privacy-safe App Attest and score receipts.
2. Repeat exact-current native Sign in with Apple, authenticated UI, active
   HealthKit, background observer, and APNs foreground/background/cold-route
   evidence on `6ee1d22`.
3. Continue the adversarial matrix above the proven database and sequential-
   Simulator profile-root boundaries plus current-source Function-route
   continuity supported by the historical `dd0ed68` runtime receipt: replay the
   consumed replacement invitation when its token is available and finish the
   remaining lifecycle isolation cases.
4. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

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
  The dedicated staging Simulator retains its prior profile-scoped container
  and historical invitation/convergence receipt; exact-current Simulator
  runtime has not been repeated.
- The rollback-only hosted database adversarial receipt passed 15/15 with zero
  residue, current-source create/claim route continuity is proven while the
  successful runtime receipt remains historical, and sequential Simulator
  profile-root teardown/remount now passes with remote installation retirement
  and re-registration. Replay of the consumed replacement invitation when its
  token is available and the remaining lifecycle isolation cases remain
  unresolved.
- Selected release artifact `6ee1d22` is installed and has one controlled
  process-launch receipt. Authenticated Sharing was visible with a competition-
  refresh warning. Fresh native Sign in with Apple, warning-free refresh, and
  active HealthKit behavior on this exact artifact remain unverified.
- The exact-current App Attest launch produced no newly eligible event or
  hosted request. No acceptance or classified-rejection receipt exists.
- No active-competition accepted score, background-observer, APNs delivery,
  deletion, or same-phone replacement-installation receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
