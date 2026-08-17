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
| Source | `main` commit `21af9a7e418dbcc33077bfc861ca9d39a53e8417` | Current |
| Backend CI | [Run 31999779829](https://github.com/narenyenuganti/health-comp/actions/runs/31999779829), completed successfully on the current source commit | PASS |
| iOS CI | [Run 31999779841, attempt 2](https://github.com/narenyenuganti/health-comp/actions/runs/31999779841), completed successfully on the current source commit; attempt 1's single pre-existing fixture failure passed 100/100 local repeated iterations and the full rerun without a source change | PASS |
| Supabase transport | Focused transport/authentication/profile-isolation/API gate passed 52 tests; canonical local `HealthCompTests` passed 457/457; CodeRabbit reported no findings | PASS |
| Signed Simulator staging | Existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Automatic paid-team signing produced the prior source build for the paired physical iPhone; the current `21af9a7` transport build has not been built for that phone | PARTIAL |
| Physical install | Bundle `com.narenyenuganti.HealthComp.staging`, build 1 from source commit `1ca67af76b738bd7fbb19277b238b448a555f8ef`, was installed and visible in device inventory; the current build is not installed | PARTIAL |
| Physical launch | The prior staging build launched while the paired iPhone was unlocked; authenticated Sharing UI was read back at `2026-08-16T07:02:20Z`; current-build launch remains pending | PARTIAL |
| Sign in with Apple | Native authorization and staging Supabase profile bootstrap completed on the prior physical build; no account identity or token was retained; current-build repetition remains pending | PARTIAL |
| APNs registration | iOS authorization completed; a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected | PASS |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths. Each enabled relaunch reached the authenticated Sharing UI without an authorization-unavailable issue; only status/UI evidence was retained. Active-competition derived-score behavior remains unverified | PARTIAL |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging invitation lifecycle | The two unclaimed invitations expire between `2026-08-19T01:56:21Z` and `2026-08-19T03:37:49Z`. Their plaintext tokens are not recoverable from hosted state; no supported creator-cancel action or audited operator-cancel RPC exists. No third invitation, cleanup call, direct row edit, or other hosted mutation was performed during the preflight | PARTIAL |

## What the physical receipt proves

The prior physical receipt proves that Xcode can resolve the paid team, create a
one-year staging development profile for the exact bundle, sign and install a
device build, launch it on the paired iPhone, complete native Sign in with
Apple, bootstrap a staging Supabase profile, and reach the authenticated app.
The profile readback proves the required capability authorizations are present.
It also proves the HealthKit authorization lifecycle can return to an enabled
startup state and that one authenticated creator can durably create a private,
unclaimed staging competition without prematurely invoking App Attest. A later
read-only audit found two pending unclaimed competitions; it does not turn
either invitation into two-account claim or convergence evidence.

That physical receipt was captured on source commit
`1ca67af76b738bd7fbb19277b238b448a555f8ef`. It does not prove that the current
`21af9a7e418dbcc33077bfc861ca9d39a53e8417` transport build has been installed
or exercised on the phone. The current signed Simulator receipt proves only
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
2. Create one replacement invitation on the clean Simulator endpoint and
   consume its opaque custom-scheme link immediately on the physical endpoint.
   Complete two-account convergence with the approved topology and two Apple
   accounts, touching the physical phone only after explicit authorization.
3. Build, install, and launch the exact reviewed commit on the physical phone,
   then repeat Sign in with Apple and the first privacy-safe score submission.
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
- The current transport commit has not been installed or retested on the
  physical iPhone.
- No active-competition HealthKit derived-score, background-observer, APNs
  delivery, App Attest, deletion, or same-phone replacement-installation
  receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
