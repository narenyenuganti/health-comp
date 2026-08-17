# HealthComp Production Beta Verification Checklist

**Snapshot:** 2026-08-17
**Integrated baseline:** `acd8a1caa15a01a650f8d3d4bc8d5b7ceccfc37b`
**Selected release artifact:** Pending the guarded merge of
`bugfix/supabase-network-recovery`; the uncommitted candidate is not yet an
eligible release artifact.
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
- **REQUIRED:** Physical-device receipts count toward completion only when
  they name the exact selected release artifact above. Receipts from older
  commits remain historical capability evidence only.
- **APPROVED:** Replacement is exercised as a replacement-installation
  lifecycle on the same physical iPhone: retire the old installation, remove
  and reinstall the exact build, enroll a new installation/App Attest key, and
  prove the retired installation remains unusable.
- **DEFERRED:** Universal-link evidence is outside this private-beta boundary
  because no HTTPS invitation domain will be provided. The controlled custom-
  scheme staging fallback remains in scope and must not be described as a
  universal link.

## Automated matrix

- **PASS:** [Backend CI run 32010702616](https://github.com/narenyenuganti/health-comp/actions/runs/32010702616)
  completed successfully on current `main` commit `acd8a1c`, including static
  backend boundaries, migrations, policies, Edge Functions, and the checked-in
  secret/privacy guards.
- **PASS:** [iOS CI run 32010702582](https://github.com/narenyenuganti/health-comp/actions/runs/32010702582)
  completed successfully on current `main` commit `acd8a1c`, including
  deterministic Xcode generation, CompetitionCore Debug and Release tests, all iOS
  application-logic tests, unsigned Debug, Staging, and Release device builds,
  and a clean-tree check.
- **PASS:** Attempt 1 of earlier iOS run `31999779841` reported one failure in
  the pre-existing cancellation-scheduling fixture test. The exact test then passed 100/100
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
- **PARTIAL:** The uncommitted `bugfix/supabase-network-recovery` candidate
  pins Supabase Swift 2.55.1 and passed 90/90 focused recovery tests, 459/459
  canonical app tests, 241/241 CompetitionCore tests in both Debug and
  Release, unsigned Debug/Staging/Release device builds, deterministic project
  generation, and a zero-finding CodeRabbit re-review. Its signed Staging
  Simulator over-install left the data-container file count unchanged at 19
  and restored the authenticated Sharing UI. The current process produced 42
  process-local HTTP-200 markers and zero `-1005`, HealthKit-entitlement, or crash markers
  from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. No invitation was
  created or consumed. Commit, hosted CI, and guarded integration remain
  pending.
- **PARTIAL:** The prior integrated transport baseline `21af9a7` and the
  uncommitted recovery candidate have not been installed or retested on the
  physical iPhone. Only the eventual guarded-merge commit may become the
  selected release artifact. Simulator receipts are not physical-device evidence.

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
- **PASS:** A SELECT-only hosted inventory ending at
  `2026-08-17T07:12:08Z` found two active profiles, two active sandbox
  installations, two pending competitions, two live unclaimed invitations,
  and zero consumed invitations. The pending-competition distribution across
  the two active profiles was `[0,2]`; no profile, installation, competition,
  invitation, token, or digest identifier was selected or retained.
- **PASS:** The same privacy-bounded inventory found zero App Attest keys,
  account-deletion records, daily-score revisions, and competition results.
  No third invitation or hosted mutation was created during the audit.
- **PARTIAL:** The two unclaimed invitations expire between
  `2026-08-19T01:56:21Z` and `2026-08-19T03:37:49Z`. Their plaintext tokens are
  not recoverable from hosted state, no supported creator-cancel action or
  audited operator-cancel RPC exists, and no direct row edit was attempted.
  After expiry, follow the guarded expired-invitation procedure in
  [Competition Support](../runbooks/competition-support.md#supported-operator-actions).
  It must mark the competitions expired while retaining invitation history. A
  readback of zero live pending invitations must precede creation of one
  immediately consumed replacement invitation.
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
  private screenshot was retained. This is historical capability evidence,
  not evidence for the still-pending selected release artifact.

## Physical-device gates

| Gate | Status | Required evidence |
| --- | --- | --- |
| Signed staging launch | PARTIAL | Prior commit `1ca67af` launched successfully as historical evidence; the exact selected release artifact remains pending and must be installed on the phone |
| Sign in with Apple | PARTIAL | Native authorization, staging Supabase session/profile bootstrap, and authenticated UI readback passed on the historical physical build; repetition on the exact selected release artifact remains pending |
| HealthKit | PARTIAL | Grant, revoke, and re-enable startup paths completed on the physical iPhone with status/UI-only evidence; active-competition privacy-safe derived-score behavior remains pending |
| Background observer | PENDING | Durable journal write before completion callback |
| APNs | PARTIAL | iOS authorization and one active sandbox installation were verified at `2026-08-16T07:04:49.701324Z`; foreground, background, and cold-route delivery remain pending |
| App Attest | PENDING | Real key registration, assertion, replay rejection, and replacement-device flow |
| Account deletion | PENDING | Reauthorization, server-confirmed completion, local wipe, no resurrection, and preserved Former competitor history |
| Universal link | DEFERRED | User-approved private-beta deferral because no HTTPS invitation domain will be provided; custom-scheme fallback is not universal-link evidence |
| Replacement installation | PENDING | Same-phone remove/reinstall, new installation and App Attest enrollment, retired-installation isolation, and no local-data resurrection |

## Multi-user and operational gates

- **PARTIAL:** Both dedicated accounts have authenticated staging profiles, but
  the two existing invitations remain unclaimed and are owned by only one
  profile. A fresh invitation must still be created and immediately claimed,
  then synchronized, finished, revisited in history, rematched, muted,
  archived, and relaunched.
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
