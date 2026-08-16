# HealthComp Production Beta Evidence

This file records anonymized, reproducible rollout receipts. It excludes Apple
account details, device identifiers, tokens, private screenshots, raw HealthKit
data, exact Activity values, and reversible local fingerprints.

## Evidence snapshot

| Scope | Current evidence | Disposition |
| --- | --- | --- |
| Source | `main` commit `645f96bfe2a3ac35e6fb0ef1b735bc4d5634ab5f` | Current |
| Backend CI | [Run 31927324144](https://github.com/narenyenuganti/health-comp/actions/runs/31927324144), completed successfully with no failed steps | PASS |
| iOS CI | [Run 31927324156](https://github.com/narenyenuganti/health-comp/actions/runs/31927324156), completed successfully with no failed steps | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Staging build completed for the paired physical iPhone using automatic paid-team signing | PASS |
| Physical install | Bundle `com.narenyenuganti.HealthComp.staging`, build 1, installed and visible in device inventory | PASS |
| Physical launch | Three launch attempts returned the explicit iOS `Locked` denial | BLOCKED |

## What the physical build proves

The current receipt proves that Xcode can resolve the paid team, create a
one-year staging development profile for the exact bundle, sign a device build,
and install that build on the paired iPhone. The profile readback proves the
required capability authorizations are present.

It does not prove that Sign in with Apple, HealthKit, background delivery,
APNs, App Attest, deletion, or universal links work. Those claims require the
app to launch and the corresponding physical or hosted service flow to complete.

## Immediate continuation

1. Unlock the paired iPhone and keep it awake.
2. Launch the already installed staging bundle without rebuilding.
3. Complete native Sign in with Apple and verify Supabase profile bootstrap
   without recording account details or tokens.
4. Exercise HealthKit grant, deny, and re-enable paths with only boolean/status
   evidence retained.
5. Continue the APNs, background observer, App Attest, deletion, and
   replacement-device gates in the checked-in order.

## Explicitly unresolved

- No two-account or two-device staging E2E receipt exists.
- No adversarial cross-account/tamper receipt exists.
- No real physical Sign in with Apple, HealthKit, background, APNs, App Attest,
  deletion, or replacement-device receipt exists.
- No HTTPS invitation domain is selected, so universal-link evidence cannot be
  produced.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
