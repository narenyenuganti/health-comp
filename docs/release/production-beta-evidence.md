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
| Application source | `dd0ed683a78de216f622e2a958baeda1cb996e46`, the corrected selected build-source commit; later evidence-only commits do not change the artifact under test | PASS |
| Selected release artifact | `dd0ed683a78de216f622e2a958baeda1cb996e46`; selected for the remaining staging and physical gates, but not cleared for production | PARTIAL |
| Backend CI | Post-merge [run 32231758224](https://github.com/narenyenuganti/health-comp/actions/runs/32231758224) completed successfully on selected application commit `dd0ed68`. Exact bugfix-head run `32227758782` passed before the guarded merge | PASS |
| iOS CI | Post-merge [run 32231758192](https://github.com/narenyenuganti/health-comp/actions/runs/32231758192) completed successfully on selected application commit `dd0ed68`: deterministic generation, both Core configurations, the complete app-test suite, unsigned Debug/Staging/Release device builds, and the clean-tree check passed. Exact bugfix-head run `32227758803` passed the same matrix before the guarded merge | PASS |
| Evidence publication | Evidence-only PR #27 merged as `2d2d5cf` without changing the then-selected pre-icon application artifact. Exact-head [Backend run 32027282748](https://github.com/narenyenuganti/health-comp/actions/runs/32027282748) and [iOS run 32027282728](https://github.com/narenyenuganti/health-comp/actions/runs/32027282728), followed by post-merge [Backend run 32030763547](https://github.com/narenyenuganti/health-comp/actions/runs/32030763547) and [iOS run 32030763718](https://github.com/narenyenuganti/health-comp/actions/runs/32030763718), completed successfully | PASS |
| App icon integration | PR #29 selected the supplied white 1024-pixel logo as AppIcon, retained all six supplied black and white source assets, removed only the opaque alpha channel from the selected icon, and passed exact-head [Backend run 32099524516](https://github.com/narenyenuganti/health-comp/actions/runs/32099524516) and [iOS run 32099524540](https://github.com/narenyenuganti/health-comp/actions/runs/32099524540). Those reviewed assets remain unchanged in selected commit `dd0ed68` | PASS |
| Terminal-invitation synchronization | PR #34 makes declined, expired, and cancelled descriptors prune only the matching local inventory item before materialization, while preserving the local journal and server-retained history. Focused runtime tests passed 22/22, including expired, declined, and cancelled cases; exact-head and post-merge CI passed. A corrected physical authenticated relaunch remained warning-free after a bounded refresh window | PASS |
| Exact-current evidence publication | PR #36 merged the exact-current Sign in with Apple receipt as `a45c325`; the only paths changed after selected application commit `dd0ed68` are this checklist and evidence file. Exact-head [Backend run 32280929100](https://github.com/narenyenuganti/health-comp/actions/runs/32280929100) and [iOS run 32280929157](https://github.com/narenyenuganti/health-comp/actions/runs/32280929157), followed by post-merge [Backend run 32284529024](https://github.com/narenyenuganti/health-comp/actions/runs/32284529024) and [iOS run 32284529049](https://github.com/narenyenuganti/health-comp/actions/runs/32284529049), completed successfully | PASS |
| Supabase transport | On pre-recovery transport baseline `21af9a7`, the focused transport/authentication/profile-isolation/API gate passed 52 tests and canonical local `HealthCompTests` passed 457/457; the integrated recovery matrix later passed the expanded 459-test canonical suite; CodeRabbit reported no findings | PASS |
| Signed Simulator staging | Existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared | PASS |
| Selected-build Simulator preparation | At `2026-08-19T18:36:33Z`, selected application source `dd0ed68` was rebuilt from docs-only main `a45c325` as the Staging Simulator bundle. Offline inspection confirmed the staging bundle ID, expected public project URL, publishable-key shape, blank invitation host, custom-scheme fallback, and Xcode-generated simulated sandbox/development capability values without exposing credentials. The bundle over-installed on the dedicated tester, exactly matched the verified build, preserved all 19 pre-existing data-container files, remained stopped, and was shut down without contacting hosted staging. The retained rebuildable artifact is 44 MiB; its 1.5 GiB DerivedData was removed | PASS |
| Realtime recovery integration | PR #26 pins Supabase Swift 2.55.1, passed the 90-test focused recovery matrix and 459/459 canonical app tests, passed 241/241 CompetitionCore tests in both Debug and Release, built unsigned Debug/Staging/Release device configurations, generated the project deterministically, and received a zero-finding CodeRabbit source review. A signed Staging Simulator over-install left the data-container file count unchanged at 19, restored the authenticated Sharing UI, and produced 42 process-local HTTP-200 markers with zero `-1005`, HealthKit-entitlement, or crash markers from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. Early hosted attempts exposed and closed cross-Xcode resolved-file omissions, then exposed the cancellation actor-hop race. The strengthened race passed 100/100 locally and exact-head hosted run `32020898831` passed the complete matrix. PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`, whose tree is identical to the reviewed PR head. PR #29 later added only the reviewed app-icon assets and selected `9d19937`. No invitation action occurred | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Automatic paid-team signing produced selected source commit `dd0ed683a78de216f622e2a958baeda1cb996e46` for the paired physical iPhone. The embedded profile authorizes exact App ID `23LUYD78QK.com.narenyenuganti.HealthComp.staging`, sandbox APNs, Sign in with Apple, HealthKit with background delivery, and App Attest; the bundle passed strict code-signature validation | PASS |
| Physical install | At `2026-08-19T08:18:49Z`, build 1 from selected source commit `dd0ed68` over-installed successfully as `com.narenyenuganti.HealthComp.staging` and appeared in device inventory. The existing authenticated session and local app state remained available. This proves a same-bundle upgrade, not the later remove/reinstall replacement lifecycle that must retire an installation and App Attest key | PASS |
| Physical launch | At `2026-08-19T15:06Z`, iPhone Mirroring read back selected artifact `dd0ed68` at the authenticated Sharing UI without a warning. The Account UI then confirmed the authenticated state and displayed the raw-HealthKit-on-device privacy boundary. A controlled terminate/relaunch returned to Sharing, and a bounded readback at `2026-08-19T15:07Z` remained warning-free. No account identity, token, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Sign in with Apple | In a user-approved physical sequence ending at `2026-08-19T17:13:03Z`, selected artifact `dd0ed68` completed sign-out, reached its clean welcome screen, completed fresh native Sign in with Apple, and returned to authenticated Sharing without a warning. No account identity, authorization payload, token, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Selected-build authenticated refresh | The prior `9d19937` relaunch reproduced `Some competition activity could not be refreshed.` and privacy-safe hosted readbacks isolated two terminal descriptors. PR #34 corrected the client boundary, and selected artifact `dd0ed68` reached authenticated Sharing without a warning on first launch, controlled terminate/relaunch, and the bounded post-refresh readback ending at `2026-08-19T15:07Z`. Retained server history and the local journal were not deleted | PASS |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration on selected release artifact `dd0ed68` remains pending | PARTIAL |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths historically. On prior selected artifact `9d19937`, all app-requested categories were granted through the native Health Access sheet. Selected artifact `dd0ed68` was over-installed under the same bundle, invoked its startup authorization request, and reached Sharing without `Activity authorization is unavailable.` This proves the exact-current startup request completed under the retained grant; public HealthKit does not reveal read denial, so active-competition derived score and background-observer behavior remain unverified | PARTIAL |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging database adversarial boundary | At `2026-08-20T01:18:06Z`, exact reviewed verifier commit `4fca597757befafc9ed10cafecc4af4b73e65026` ran against `healthcomp-staging` after SSL enforcement was enabled and read back. The certificate-verified session passed 15/15 database assertions, explicitly rolled back, independently found zero synthetic rows remaining, and returned no private values. The sole nonblank privacy-safe receipt has SHA-256 `852fc2d64c0daa93677726cda4fdddf4acd088b68884aa247939188f408660af`. This is database-boundary evidence only; replay of the consumed replacement invitation remains pending, while the separate sequential-Simulator receipt below now proves the profile-root isolation boundary | PASS |
| Staging expired-invitation cleanup | After both invitations expired, a privacy-safe snapshot returned exact count `2` and opaque scope SHA-256 `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`. Following action-time approval, the reviewed guard ran as one explicit serializable transaction through the authenticated Supabase Management API database-query route rather than `psql`; it retained the approved scope checks, timeouts, service-role request claim, cleanup-count assertion, and explicit commit. Dedicated read-only route readback at `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired competitions, two retained invitation-history rows, zero claimed or consumed invitations, and zero remaining eligible invitations. No identifier or token was selected, no lifecycle row was edited directly, and no replacement invitation was created | PASS |
| Staging replacement invitation | Following fresh action-time approval, exact selected artifact `dd0ed68` created exactly one replacement invitation on the isolated Simulator endpoint. The same opaque custom-scheme link cold-launched the selected-artifact physical endpoint and was accepted once. Read-only hosted readback ending at `2026-08-19T21:56:37Z` found one scheduled replacement competition, exactly two participant rows, and exactly one corresponding invitation row with claimant and consumption time present. Both endpoints converged on the scheduled competition after controlled relaunch. No token, identity, private identifier, screenshot, raw HealthKit datum, or exact Activity value is retained; this is not universal-link evidence | PASS |
| Selected-build invitation Function routing | Selected application source `dd0ed68` routes live invitation creation through `create-competition-invite` and claims through `claim-competition-invite`; that source remains unchanged through integrated commit `89ee243`. The exact selected artifact completed both actions above, and the hosted state records their create/consume effects. A read-only dashboard readback at `2026-08-20T02:32:28Z` reported exactly one invocation since the last deployment and no errors for each Function. No new request was sent, and no token, identity, request body, Function identifier, or execution identifier was retained | PASS |
| Sequential Simulator profile isolation | In a user-approved Account A to signed-out to Account B sequence ending at `2026-08-20T05:56:37Z`, exact selected artifact `dd0ed68` first mounted one Account A profile with three competition-journal files, two server cursors, one installation file, and no outbox, notification-preference, or App Attest file. After server-confirmed installation retirement, sign-out reached the clean welcome screen, reduced `Profiles/v1` to zero profile directories and zero profile files, and moved the aggregate sandbox installation state from two active / three revoked to one active / four revoked while the physical phone was untouched. A distinct Apple account then authenticated directly through HealthComp without enabling full Simulator iCloud sync. The app mounted exactly one Account B root, displayed the prior participant only as the legitimate scheduled opponent, and contained three server-rematerialized competition files, two cursors, one newly active installation, and zero outbox, notification-preference, or App Attest files. Aggregate hosted readback returned two active / four revoked installations. The selected artifact's canonical `AuthenticatedProfileStorageTests.testSequentialProfileTransitionCannotLoadOrDrainPriorPaths` additionally seeds a private Account A outbox and proves it is absent after teardown and Account B mount. The iOS 18.4 Simulator required clearing only rebuildable HTTP alternative-service cache rows to recover Apple's known transport defect; profile data was unchanged by that recovery. No Apple account, profile or installation identifier, token, local fingerprint, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Two-account staging convergence | Invitation creation, controlled custom-scheme delivery, cold acceptance, single consumption, two-participant membership, and scheduled-state convergence passed on the approved physical-iPhone-plus-Simulator topology. The competition starts `2026-08-20` in its frozen `America/Los_Angeles` time zone, so the first privacy-safe score and the remaining lifecycle/isolation cases are not yet available | PARTIAL |

## What the physical receipt proves

The current selected-artifact physical receipt proves that exact source commit
`dd0ed683a78de216f622e2a958baeda1cb996e46` can be signed by the paid-team
profile, over-installed on the paired iPhone, and launched with its existing
local state and authenticated session intact. A controlled terminate/relaunch
and bounded post-refresh readback remained at the Sharing UI without the prior
terminal-invitation warning. In a later user-approved sequence, the exact same
artifact completed sign-out, reached its clean welcome screen, completed fresh
native Sign in with Apple, and returned to authenticated Sharing without a
warning at `2026-08-19T17:13:03Z`. No private screenshot, account identity,
authorization payload, token, raw HealthKit datum, or exact Activity value is
retained. This receipt does not prove active-competition HealthKit behavior,
background delivery, or the later remove/reinstall replacement lifecycle.

The prior `9d199377f5d72cb7bc90133c190e4e7681abfb41` receipt proves a fresh
install, selected-icon rendering, fresh native Health Access approval, and
fresh native Sign in with Apple. Those remain historical current-lineage
capability receipts after selection advanced to `dd0ed68`; fresh native Sign
in with Apple is now also directly evidenced on the exact selected artifact.

The prior historical physical receipt proves that Xcode can resolve the paid
team, create a one-year staging development profile for the exact bundle, sign
and install a device build, launch it on the paired iPhone, complete native
Sign in with Apple, bootstrap a staging Supabase profile, and reach the
authenticated app.
The profile readback proves the required capability authorizations are present.
It also proves the HealthKit authorization lifecycle can return to an enabled
startup state and that one authenticated creator can durably create a private,
unclaimed staging competition without prematurely invoking App Attest. A later
read-only audit found two pending unclaimed competitions. After their expiry,
the approved guarded cleanup marked both competitions expired while retaining
both invitation-history rows. Neither invitation became two-account claim or
convergence evidence.

That broader historical capability receipt was captured on source commit
`1ca67af76b738bd7fbb19277b238b448a555f8ef`. It is historical capability
evidence only and, by itself, does not prove current-build Sign in with Apple,
authenticated transport, or HealthKit behavior on selected release artifact
`dd0ed68`. The current signed Simulator receipt proves only
transport, entitlement embedding, session restoration, and local profile
persistence in the Simulator environment.

It does not prove active-competition HealthKit derived-score behavior,
background delivery, APNs foreground/background/cold-route delivery, App
Attest, deletion, or universal links. Those claims require the corresponding
physical or hosted service flow to complete.

## Immediate continuation

1. After the scheduled `2026-08-20` Day 1 boundary, complete the first
   privacy-safe score submission and read back two-account convergence without
   retaining exact Activity values. Continue the remaining scheduled lifecycle,
   offline catch-up, relaunch, and profile-isolation cases.
2. Continue the adversarial matrix above the proven database, selected-build
   Function-routing, and sequential-Simulator profile-root boundaries: replay
   the consumed replacement invitation when its token is available and finish
   the remaining lifecycle isolation cases.
3. Verify active-competition HealthKit behavior, the background observer, App
   Attest, and APNs foreground/background/cold-route delivery.
4. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

- A partial two-account staging E2E receipt now exists: exact selected artifact
  `dd0ed68` created exactly one replacement invitation, the physical endpoint
  cold-accepted it once through the controlled custom scheme, hosted staging
  records one consumed invitation and exactly two participants, and both
  endpoints show the same scheduled competition. The remaining lifecycle and
  isolation matrix is not complete.
- The replacement invitation is consumed and the competition is scheduled for
  `2026-08-20` in its frozen `America/Los_Angeles` time zone. No first score can
  be evidenced before the Day 1 boundary; the earlier two expired invitation
  history rows remain retained.
- Selected application source `dd0ed68` is installed and currently authenticated
  on the dedicated staging Simulator with its profile-scoped local container
  preserved. It now provides direct invitation-creation and scheduled-
  convergence evidence, not merely build preparation.
- The rollback-only hosted database adversarial receipt passed 15/15 with zero
  residue, the selected build's create/claim Function routing is proven, and
  sequential Simulator profile-root teardown/remount now passes with remote
  installation retirement and re-registration. Replay of the consumed
  replacement invitation when its token is available and the remaining
  lifecycle isolation cases remain unresolved.
- Selected release artifact `dd0ed68` is installed, completed fresh native
  Sign in with Apple, and reaches authenticated Sharing without the prior
  terminal-invitation warning. The current artifact's startup Health
  authorization request completed under the retained same-bundle grant, but
  active-competition HealthKit behavior and the remaining physical service
  gates are not yet exercised.
- No active-competition HealthKit derived-score, background-observer, APNs
  delivery, App Attest, deletion, or same-phone replacement-installation
  receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
