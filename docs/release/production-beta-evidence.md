# HealthComp Production Beta Evidence

This file records anonymized, reproducible rollout receipts. It excludes Apple
account details, device identifiers, tokens, private screenshots, raw HealthKit
data, exact Activity values, and reversible local fingerprints.

## Evidence snapshot

| Scope | Current evidence | Disposition |
| --- | --- | --- |
| Source | `main` commit `47d65964607ad8fe8cdb48d35129cc8bf88cc464` | Current |
| Backend CI | [Run 31930884414, attempt 2](https://github.com/narenyenuganti/health-comp/actions/runs/31930884414), completed successfully after the first attempt's local Edge Runtime container crash | PASS |
| iOS CI | [Run 31930884445](https://github.com/narenyenuganti/health-comp/actions/runs/31930884445), completed successfully with no failed steps | PASS |
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

## What the physical receipt proves

The current receipt proves that Xcode can resolve the paid team, create a
one-year staging development profile for the exact bundle, sign and install a
device build, launch it on the paired iPhone, complete native Sign in with
Apple, bootstrap a staging Supabase profile, and reach the authenticated app.
The profile readback proves the required capability authorizations are present.

It does not prove that HealthKit, background delivery, APNs foreground,
background, or cold-route delivery, App Attest, deletion, or universal links
work. Those claims require the corresponding physical or hosted service flow
to complete.

## Immediate continuation

1. Exercise HealthKit grant, deny, and re-enable paths with only boolean/status
   evidence retained.
2. Verify APNs foreground, background, and cold-route delivery when a second
   staging participant is available.
3. Continue the background observer, App Attest, deletion, and
   replacement-device gates in the checked-in order.

## Explicitly unresolved

- No two-account or two-device staging E2E receipt exists.
- No adversarial cross-account/tamper receipt exists.
- No real physical HealthKit, background observer, APNs delivery, App Attest,
  deletion, or replacement-device receipt exists.
- No HTTPS invitation domain is selected, so universal-link evidence cannot be
  produced.
- Backup restore is not rehearsed against a disposable hosted target.
- No Supabase project is approved as production.
- The product is not production-ready.
