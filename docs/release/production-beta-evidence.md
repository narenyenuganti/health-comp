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
| Physical launch | iPhone Mirroring showed the selected white app icon in Spotlight and the selected build launched to the native Health Access prompt. No Health permission was granted or denied. This proves launch only, not authenticated staging transport or any HealthKit data flow | PASS |
| Sign in with Apple | Native authorization and staging Supabase profile bootstrap completed on the prior physical build; no account identity or token was retained; current-build repetition remains pending | PARTIAL |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration on selected release artifact `9d19937` remains pending | PARTIAL |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths. Each enabled relaunch reached the authenticated Sharing UI without an authorization-unavailable issue; only status/UI evidence was retained. Active-competition derived-score behavior remains unverified | PARTIAL |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging invitation lifecycle | The two unclaimed invitations expire between `2026-08-19T01:56:21Z` and `2026-08-19T03:37:49Z`. Their plaintext tokens are not recoverable from hosted state; no supported creator-cancel action or audited operator-cancel RPC exists. No third invitation, cleanup call, direct row edit, or other hosted mutation was performed during the preflight | PARTIAL |

## What the physical receipt proves

The selected-artifact physical receipt proves that exact source commit
`9d199377f5d72cb7bc90133c190e4e7681abfb41` can be signed by the paid-team
profile, installed on the paired iPhone, rendered with the selected app icon,
and launched to the native Health Access prompt. The app was absent before the
install, so the receipt proves a fresh install rather than an over-install or
replacement lifecycle. No Health permission choice was made.

The prior historical physical receipt proves that Xcode can resolve the paid
team, create a one-year staging development profile for the exact bundle, sign
and install a device build, launch it on the paired iPhone, complete native
Sign in with Apple, bootstrap a staging Supabase profile, and reach the
authenticated app.
The profile readback proves the required capability authorizations are present.
It also proves the HealthKit authorization lifecycle can return to an enabled
startup state and that one authenticated creator can durably create a private,
unclaimed staging competition without prematurely invoking App Attest. A later
read-only audit found two pending unclaimed competitions; it does not turn
either invitation into two-account claim or convergence evidence.

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

1. After both unavailable invitations expire, follow the exact guarded
   expired-invitation procedure in
   [Competition Support](../runbooks/competition-support.md#supported-operator-actions),
   including action-time scope approval, transaction bounds, and automatic
   rollback on scope drift or error. Confirm that it marks the two competitions
   expired, retains the invitation-history rows, and leaves zero live pending
   invitations. Do not create a third live invitation or edit lifecycle rows
   directly.
2. On already-installed selected release artifact `9d19937`, complete an
   explicitly authorized Health Access choice and repeat Sign in with Apple
   before creating or consuming a replacement invitation.
3. Create one replacement invitation on the clean Simulator endpoint and
   consume its opaque custom-scheme link immediately on the selected-artifact
   physical endpoint. Complete two-account convergence with the approved
   topology and two Apple accounts, including the first privacy-safe score
   submission.
4. Verify active-competition HealthKit behavior, the background observer, App
   Attest, and APNs foreground/background/cold-route delivery.
5. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

- No two-account staging E2E receipt exists under the approved one-physical-
  iPhone-plus-Simulator topology.
- Two live unclaimed invitations remain until their 2026-08-19 expiry window;
  neither plaintext claim token is recoverable from hosted state.
- No adversarial cross-account/tamper receipt exists.
- Selected release artifact `9d19937` is installed and launches on the physical
  iPhone, but current-build Sign in with Apple, authenticated transport,
  HealthKit behavior, and the remaining physical service gates are not yet
  exercised.
- No active-competition HealthKit derived-score, background-observer, APNs
  delivery, App Attest, deletion, or same-phone replacement-installation
  receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
