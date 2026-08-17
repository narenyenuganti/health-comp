# HealthComp Production Beta Evidence

This file records anonymized, reproducible rollout receipts. It excludes Apple
account details, device identifiers, tokens, private screenshots, raw HealthKit
data, exact Activity values, and reversible local fingerprints.

## Evidence snapshot

| Scope | Current evidence | Disposition |
| --- | --- | --- |
| Source | `main` commit `1ca67af76b738bd7fbb19277b238b448a555f8ef` | Current |
| Backend CI | [Run 31969272901](https://github.com/narenyenuganti/health-comp/actions/runs/31969272901), completed successfully on the current source commit | PASS |
| iOS CI | [Run 31969273029](https://github.com/narenyenuganti/health-comp/actions/runs/31969273029), completed successfully on the current source commit | PASS |
| Staging database | Fourteen ordered, identical local/remote migrations through `20260811000900`; `2026-08-16T05:34:16Z` dry run returned `up to date`; CLI unlinked afterward; hosted lint clean | PASS |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Physical build | Staging build completed for the paired physical iPhone using automatic paid-team signing | PASS |
| Physical install | Bundle `com.narenyenuganti.HealthComp.staging`, build 1, installed and visible in device inventory | PASS |
| Physical launch | Already-installed staging build launched while the paired iPhone was unlocked; authenticated Sharing UI was read back at `2026-08-16T07:02:20Z` | PASS |
| Sign in with Apple | Native authorization completed on the physical iPhone; staging Supabase session/profile bootstrap reached the required display-name setup and then the authenticated Sharing UI; no account identity or token was retained | PASS |
| APNs registration | iOS authorization completed; a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected | PASS |
| HealthKit startup cycle | The physical iPhone completed grant, revoke, and re-enable startup paths. Each enabled relaunch reached the authenticated Sharing UI without an authorization-unavailable issue; only status/UI evidence was retained. Active-competition derived-score behavior remains unverified | PARTIAL |
| Staging invitation creation | At `2026-08-17T02:01:59Z`, read-only UI and row-count checks agreed on exactly one pending competition and one unclaimed invitation. The creator showed `Waiting for competitor`; one profile-scoped local journal existed, while the outbox and local/hosted App Attest state remained empty. No identifier, token, digest, account detail, private screenshot, or HealthKit value was retained | PARTIAL |

## What the physical receipt proves

The current receipt proves that Xcode can resolve the paid team, create a
one-year staging development profile for the exact bundle, sign and install a
device build, launch it on the paired iPhone, complete native Sign in with
Apple, bootstrap a staging Supabase profile, and reach the authenticated app.
The profile readback proves the required capability authorizations are present.
It also proves the HealthKit authorization lifecycle can return to an enabled
startup state and that one authenticated creator can durably create a private,
unclaimed staging competition without prematurely invoking App Attest.

It does not prove active-competition HealthKit derived-score behavior,
background delivery, APNs foreground/background/cold-route delivery, App
Attest, deletion, or universal links. Those claims require the corresponding
physical or hosted service flow to complete.

## Immediate continuation

1. Connect a second physical iPhone, install the exact staging build, and sign
   in with a dedicated second Apple account.
2. Share and claim the existing single-use invitation without retaining its
   token, then verify convergence and the first privacy-safe score submission.
3. Verify active-competition HealthKit behavior, the background observer, App
   Attest, and APNs foreground/background/cold-route delivery.
4. Continue deletion and replacement-device gates in the checked-in order.

## Explicitly unresolved

- No two-account or two-device staging E2E receipt exists.
- No adversarial cross-account/tamper receipt exists.
- No active-competition HealthKit derived-score, background-observer, APNs
  delivery, App Attest, deletion, or replacement-device receipt exists.
- No HTTPS invitation domain is selected, so universal-link evidence cannot be
  produced.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
