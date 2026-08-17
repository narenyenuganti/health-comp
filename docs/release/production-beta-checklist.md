# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-17
**Reviewed commit:** `1ca67af76b738bd7fbb19277b238b448a555f8ef`
**Release status:** Not production-ready

Status meanings:

- **PASS** — direct current-state evidence exists for the stated scope.
- **PARTIAL** — some required evidence exists, but the gate is not complete.
- **BLOCKED** — a named external input or environment change is required.
- **PENDING** — the gate has not yet been executed.

## Automated matrix

- **PASS:** Backend CI completed successfully on the reviewed commit, including
  static backend boundaries, migrations, policies, Edge Functions, and the
  checked-in secret/privacy guards.
- **PASS:** iOS CI completed successfully on the reviewed commit, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests,
  iOS application-logic tests, unsigned device configuration builds, and a
  clean-tree check.
- **PASS:** The post-merge Backend and iOS workflows have no failed steps.

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
- **PASS:** Automatic signing produced a Staging device build for
  `23LUYD78QK.com.narenyenuganti.HealthComp.staging`.
- **PASS:** The generated staging development profile expires
  `2027-08-16T05:23:35Z` and authorizes sandbox APNs, Sign in with Apple,
  HealthKit, HealthKit background delivery, and App Attest.
- **PASS:** Build 1 was installed on the paired physical iPhone.
- **PASS:** The already-installed staging build launched on the unlocked paired
  iPhone. Native Sign in with Apple completed, staging Supabase profile
  bootstrap required and accepted a user-selected display name, and the
  authenticated Sharing UI was read back at `2026-08-16T07:02:20Z`. No Apple
  account identity, token, or private screenshot was retained.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PASS | Successful launch while the device is unlocked |
| Sign in with Apple | PASS | Native authorization, staging Supabase session/profile bootstrap, and authenticated UI readback |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed on the physical iPhone with status/UI-only evidence; active-competition privacy-safe derived-score behavior remains pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Real key registration, assertion, replay rejection, and replacement-device flow |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | BLOCKED | No HTTPS invitation domain has been selected; custom-scheme fallback is not universal-link evidence |
| Device replacement | PENDING | New installation enrollment and old-installation isolation |

## Multi-user and operational gates

- **PARTIAL:** The first dedicated account created one private staging
  competition and unclaimed invitation. The second account must still claim,
  synchronize, finish, revisit history, rematch, mute, archive, and relaunch.
- **PENDING:** Two-device invitation and convergence evidence. Sequential
  account switching on one phone may test profile isolation, but does not
  replace the required two-device gate.
- **PENDING:** Cross-account reads and mutations, replayed claims, modified
  points, stale/conflicting revisions, result rewrites, deleted-profile access,
  token leakage, and unregistered installations all fail closed.
- **BLOCKED:** Hosted backup/restore rehearsal requires a backup-capable plan
  and an approved disposable restore target.
- **BLOCKED:** No production Supabase project has been approved.

## Completion rule

Do not describe HealthComp as production-ready until every required automated,
two-account staging, adversarial, physical-device, deletion, restore, secret,
privacy, and release-evidence gate is **PASS**. A simulator result, successful
build, installed app, dashboard configuration, or source entitlement is not a
substitute for service-level physical evidence.
