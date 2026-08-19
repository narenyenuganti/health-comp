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
| Application source | `9d199377f5d72cb7bc90133c190e4e7681abfb41`, the selected build-source commit; later evidence-only commits do not change the artifact under test | PASS |
| Selected release artifact | `9d199377f5d72cb7bc90133c190e4e7681abfb41`; selected for the remaining staging and physical gates, but not cleared for production | PARTIAL |
| Backend CI | [Run 32101691658](https://github.com/narenyenuganti/health-comp/actions/runs/32101691658), completed successfully on selected application commit `9d19937` | PASS |
| iOS CI | Post-merge [run 32101691575](https://github.com/narenyenuganti/health-comp/actions/runs/32101691575) completed successfully on selected application commit `9d19937`: deterministic generation, both Core configurations, the complete app-test suite, unsigned Debug/Staging/Release device builds, and the clean-tree check passed. Exact PR-head run `32099524540` passed the same matrix before the guarded merge | PASS |
| Evidence publication | Evidence-only PR #27 merged as `2d2d5cf` without changing the then-selected pre-icon application artifact. Exact-head [Backend run 32027282748](https://github.com/narenyenuganti/health-comp/actions/runs/32027282748) and [iOS run 32027282728](https://github.com/narenyenuganti/health-comp/actions/runs/32027282728), followed by post-merge [Backend run 32030763547](https://github.com/narenyenuganti/health-comp/actions/runs/32030763547) and [iOS run 32030763718](https://github.com/narenyenuganti/health-comp/actions/runs/32030763718), completed successfully | PASS |
| App icon integration | PR #29 selected the supplied white 1024-pixel logo as AppIcon, retained all six supplied black and white source assets, removed only the opaque alpha channel from the selected icon, and passed exact-head [Backend run 32099524516](https://github.com/narenyenuganti/health-comp/actions/runs/32099524516) and [iOS run 32099524540](https://github.com/narenyenuganti/health-comp/actions/runs/32099524540). The reviewed PR tree is identical to selected merge commit `9d19937` | PASS |
| Supabase transport | On pre-recovery transport baseline `21af9a7`, the focused transport/authentication/profile-isolation/API gate passed 52 tests and canonical local `HealthCompTests` passed 457/457; the integrated recovery matrix later passed the expanded 459-test canonical suite; CodeRabbit reported no findings | PASS |
| Signed Simulator staging | Existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared | PASS |
| Realtime recovery integration | PR #26 pins Supabase Swift 2.55.1, passed the 90-test focused recovery matrix and 459/459 canonical app tests, passed 241/241 CompetitionCore tests in both Debug and Release, built unsigned Debug/Staging/Release device configurations, generated the project deterministically, and received a zero-finding CodeRabbit source review. A signed Staging Simulator over-install left the data-container file count unchanged at 19, restored the authenticated Sharing UI, and produced 42 process-local HTTP-200 markers with zero `-1005`, HealthKit-entitlement, or crash markers from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. Early hosted attempts exposed and closed cross-Xcode resolved-file omissions, then exposed the cancellation actor-hop race. The strengthened race passed 100/100 locally and exact-head hosted run `32020898831` passed the complete matrix. PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`, whose tree is identical to the reviewed PR head. PR #29 later added only the reviewed app-icon assets and selected `9d19937`. No invitation action occurred | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Automatic paid-team signing produced selected source commit `9d199377f5d72cb7bc90133c190e4e7681abfb41` for the paired physical iPhone. The embedded profile authorizes exact App ID `23LUYD78QK.com.narenyenuganti.HealthComp.staging`, sandbox APNs, Sign in with Apple, HealthKit with background delivery, and App Attest; the bundle passed strict code-signature validation | PASS |
| Physical install | A pre-install device query found no installed HealthComp bundle. At `2026-08-18T05:12:52Z`, build 1 from selected source commit `9d19937` installed successfully as `com.narenyenuganti.HealthComp.staging` and appeared in device inventory. Because the app was absent beforehand, this was a fresh install and is not replacement-installation evidence | PASS |
| Physical launch | iPhone Mirroring showed the selected white app icon in Spotlight and the selected build launched to the native Health Access prompt. At `2026-08-19T06:53Z`, after fresh action-time approval, every Health category requested by the app was enabled through the native `Turn On All` control and the final `Allow` action completed. The selected build then reached the authenticated Sharing UI through its restored session. This checked-in receipt contains no account identity, token, private screenshot, raw HealthKit datum, or exact Activity value. This proves selected-build launch and the Health authorization UI path, not active-competition derived-score or background behavior | PASS |
| Sign in with Apple | After the restored session was signed out, fresh native Sign in with Apple authorization completed directly on the physical iPhone for selected artifact `9d19937`. At `2026-08-19T06:59Z`, iPhone Mirroring read back the authenticated Sharing UI. The checked-in receipt contains no Apple account identity, authorization payload, or token | PASS |
| Selected-build authenticated refresh | A controlled relaunch at `2026-08-19T07:02Z` reproduced `Some competition activity could not be refreshed.` Privacy-safe hosted readbacks ending at `2026-08-19T07:06:16.64042Z` found zero pending competitions and two expired competitions; accepted-membership, retained-unclaimed-invitation, and lifecycle-change distributions were each `[1,1]`. Selected client source treats every declined, expired, or cancelled descriptor as `competitionNotMaterialized`, which the publication layer exposes as a per-competition failure. No identifier, account detail, token, or Health datum was selected. The terminal-invitation synchronization defect must be fixed before replacement-invitation staging | PARTIAL |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration on selected release artifact `9d19937` remains pending | PARTIAL |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths on the historical build. On selected artifact `9d19937`, all app-requested categories were granted through the native Health Access sheet and the app reached the authenticated Sharing UI without an authorization-unavailable issue. Only privacy-safe status/UI evidence was retained. Active-competition derived-score and background-observer behavior remain unverified | PARTIAL |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging expired-invitation cleanup | After both invitations expired, a privacy-safe snapshot returned exact count `2` and opaque scope SHA-256 `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`. Following action-time approval, the reviewed guard ran as one explicit serializable transaction through the authenticated Supabase Management API database-query route rather than `psql`; it retained the approved scope checks, timeouts, service-role request claim, cleanup-count assertion, and explicit commit. Dedicated read-only route readback at `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired competitions, two retained invitation-history rows, zero claimed or consumed invitations, and zero remaining eligible invitations. No identifier or token was selected, no lifecycle row was edited directly, and no replacement invitation was created | PASS |
| Staging replacement invitation | One replacement invitation must be created only after selected-build Health Access and Sign in with Apple are complete, then consumed immediately on the second isolated endpoint | PENDING |

## What the physical receipt proves

The selected-artifact physical receipt proves that exact source commit
`9d199377f5d72cb7bc90133c190e4e7681abfb41` can be signed by the paid-team
profile, installed on the paired iPhone, rendered with the selected app icon,
and launched to the native Health Access prompt. The app was absent before the
install, so the receipt proves a fresh install rather than an over-install or
replacement lifecycle. A later action-time-approved pass enabled every
app-requested Health category through the native sheet and reached the
authenticated Sharing UI using the restored session. No private screenshot,
raw HealthKit datum, or exact Activity value is included in this receipt. This
does not prove active-competition derived-score or background behavior.

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
evidence only. It does not prove current-build Sign in with Apple, authenticated
transport, or HealthKit behavior on selected release artifact `9d19937`. The
current signed Simulator receipt proves only
transport, entitlement embedding, session restoration, and local profile
persistence in the Simulator environment.

It does not prove active-competition HealthKit derived-score behavior,
background delivery, APNs foreground/background/cold-route delivery, App
Attest, deletion, or universal links. Those claims require the corresponding
physical or hosted service flow to complete.

## Immediate continuation

1. Fix and verify terminal invitation synchronization so the two retained
   expired server descriptors do not produce a false refresh failure. Select,
   sign, and reinstall the corrected artifact before continuing physical
   evidence.
2. After the corrected artifact has clean authenticated readback, create one
   replacement invitation on the clean Simulator endpoint and
   consume its opaque custom-scheme link immediately on the selected-artifact
   physical endpoint. Complete two-account convergence with the approved
   topology and two Apple accounts, including the first privacy-safe score
   submission.
3. Verify active-competition HealthKit behavior, the background observer, App
   Attest, and APNs foreground/background/cold-route delivery.
4. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

- No two-account staging E2E receipt exists under the approved one-physical-
  iPhone-plus-Simulator topology.
- No live invitation remains after the approved expired-invitation cleanup;
  both history rows are retained, and the one replacement invitation required
  for two-account staging has not been created.
- No adversarial cross-account/tamper receipt exists.
- Selected release artifact `9d19937` is installed, has all app-requested
  Health categories authorized, and reaches the authenticated Sharing UI using
  both its restored session and a fresh direct-on-iPhone Sign in with Apple.
  Its authenticated competition refresh consistently reports the diagnosed
  terminal-invitation synchronization defect, so clean authenticated transport
  readback, active-competition HealthKit behavior, and the remaining physical
  service gates are not yet exercised.
- No active-competition HealthKit derived-score, background-observer, APNs
  delivery, App Attest, deletion, or same-phone replacement-installation
  receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
