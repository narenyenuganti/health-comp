# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-17
**Reviewed commit:** `21af9a7e418dbcc33077bfc861ca9d39a53e8417`
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
- **APPROVED:** Replacement is exercised as a replacement-installation
  lifecycle on the same physical iPhone: retire the old installation, remove
  and reinstall the exact build, enroll a new installation/App Attest key, and
  prove the retired installation remains unusable.
- **DEFERRED:** Universal-link evidence is outside this private-beta boundary
  because no HTTPS invitation domain will be provided. The controlled custom-
  scheme staging fallback remains in scope and must not be described as a
  universal link.

## Automated matrix

- **PASS:** [Backend CI run 31999779829](https://github.com/narenyenuganti/health-comp/actions/runs/31999779829)
  completed successfully on the reviewed commit, including static backend
  boundaries, migrations, policies, Edge Functions, and the checked-in
  secret/privacy guards.
- **PASS:** [iOS CI run 31999779841, attempt 2](https://github.com/narenyenuganti/health-comp/actions/runs/31999779841)
  completed successfully on the reviewed commit, including deterministic
  Xcode generation, CompetitionCore Debug and Release tests, all iOS
  application-logic tests, unsigned Debug, Staging, and Release device builds,
  and a clean-tree check.
- **PASS:** Attempt 1 of the iOS run reported one failure in the pre-existing
  cancellation-scheduling fixture test. The exact test then passed 100/100
  local repeated iterations, had passed the prior ten main-branch CI runs, and
  passed in the full attempt-2 rerun without a source change. No transport test
  failed in either attempt.

## Staging client transport

- **PASS:** The live Supabase client uses one injected ephemeral `URLSession`
  with persistent cookies, URL credentials, and URL caching disabled.
- **PASS:** The focused transport/authentication/profile-isolation/API gate
  passed 52 tests, and the canonical local `HealthCompTests` gate passed all
  457 tests without failures or skips.
- **PASS:** A signed Staging Simulator build restored the existing
  profile-scoped data and authenticated session, completed staging requests
  with HTTP 200 responses, and produced no `-1005` or missing-HealthKit-
  entitlement error.
- **PARTIAL:** The reviewed transport commit has not been installed or retested
  on the physical iPhone. The Simulator receipt is not physical-device
  evidence.

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
- **PARTIAL:** At `2026-08-17T02:01:59Z`, one authenticated physical creator
  had created exactly one pending competition and one unclaimed invitation.
  The creator UI showed `Waiting for competitor`; claim and two-account
  convergence remain pending.
- **PENDING:** Adversarial participant-isolation and tamper matrix.

## Paid-team signing and installation

- **PASS:** Xcode reads the paid Apple Developer team as an Admin team with one
  provisioned device.
- **PASS:** Automatic signing previously produced a Staging device build for
  `23LUYD78QK.com.narenyenuganti.HealthComp.staging`.
- **PASS:** The generated staging development profile expires
  `2027-08-16T05:23:35Z` and authorizes sandbox APNs, Sign in with Apple,
  HealthKit, HealthKit background delivery, and App Attest.
- **PARTIAL:** Build 1 from source commit `1ca67af76b738bd7fbb19277b238b448a555f8ef`
  was installed and launched on the paired physical iPhone. Native Sign in
  with Apple completed, staging Supabase profile bootstrap required and
  accepted a user-selected display name, and the authenticated Sharing UI was
  read back at `2026-08-16T07:02:20Z`. No Apple account identity, token, or
  private screenshot was retained. The reviewed commit has not been installed
  on that phone.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PARTIAL | Prior commit `1ca67af` launched successfully; reviewed commit `21af9a7` has not been installed on the phone |
| Sign in with Apple | PARTIAL | Native authorization, staging Supabase session/profile bootstrap, and authenticated UI readback passed on the prior physical build; current-build repetition remains pending |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed on the physical iPhone with status/UI-only evidence; active-competition privacy-safe derived-score behavior remains pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Real key registration, assertion, replay rejection, and replacement-device flow |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | DEFERRED | User-approved private-beta deferral because no HTTPS invitation domain will be provided; custom-scheme fallback is not universal-link evidence |
| Replacement installation | PENDING | Same-phone remove/reinstall, new installation and App Attest enrollment, retired-installation isolation, and no local-data resurrection |

## Multi-user and operational gates

- **PARTIAL:** The first dedicated account created one private staging
  competition and unclaimed invitation. The second account must still claim,
  synchronize, finish, revisit history, rematch, mute, archive, and relaunch.
- **PENDING:** Two-account invitation, controlled custom-scheme sharing, cold
  acceptance, and convergence evidence using the approved one-physical-iPhone-
  plus-Simulator topology. Sequential account switching must additionally
  prove profile-scoped journal, outbox, cursor, mute, and installation
  isolation.
- **PENDING:** Cross-account reads and mutations, replayed claims, modified
  points, stale/conflicting revisions, result rewrites, deleted-profile access,
  token leakage, and unregistered installations all fail closed.
- **BLOCKED:** Hosted backup/restore rehearsal requires a backup-capable plan
  and an approved disposable restore target.
- **BLOCKED:** No production Supabase project has been approved.

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
