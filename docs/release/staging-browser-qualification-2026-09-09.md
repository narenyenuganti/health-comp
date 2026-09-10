# Staging browser qualification checkpoint — September 9, 2026

**Release status: not production-ready.** This dated checkpoint advances the
source, deployment, and Simulator evidence beyond the September 4 release
snapshot. It does not select a new physical release artifact or transfer older
physical-device passes to the new authentication implementation.

Completion still uses one physical iPhone, dedicated Simulators, and two distinct
Apple accounts. Personal iCloud stays unchanged. Universal links remain explicitly
deferred; custom-scheme invitation evidence must be labeled separately.

## Source and automated verification

The qualified application/backend source candidate is merged main
`b24ecbd5437144b1c03364302343edda610af667`, tree
`77a73683ea8cfad8dbb70fdbfa896411b8e6fcd2`. It includes the paired staging
browser authentication/deletion implementation, app-owned authentication-lifetime
isolation, and app privacy manifest. Supabase Swift remains pinned to 2.55.1.
The tracked browser opt-in remains off.

Both post-merge runs were reread as terminal success on this exact source:

| Run | Verified scope |
| --- | --- |
| [Backend 34180299927](https://github.com/narenyenuganti/health-comp/actions/runs/34180299927) | Static backend boundaries and the configured migration, policy, and Edge Function test job |
| [iOS 34180299793](https://github.com/narenyenuganti/health-comp/actions/runs/34180299793) | Deterministic XcodeGen; browser contracts; app privacy manifest; CompetitionCore Debug/Release; app logic; release-style Staging tests; unsigned Debug/Staging/Release device builds; clean source tree |

These are GitHub Actions results, not local runs, hosted staging E2E, signed
physical-device execution, complete privacy-disclosure approval, or production
qualification. Each future source change still needs its own applicable gates.

## September 8 staging deployment

The recorded coordinated promotion applied only the three reviewed forward
migrations `20260906001100`, `20260906001200`, and `20260906001300`, bringing
staging to eighteen migrations. It replaced the native `delete-account` worker
and added `apple-deletion-begin`, `apple-deletion-callback`, and
`apple-deletion-complete` from the candidate above. All four were ACTIVE version
1 after promotion; native numbering restarted because that endpoint was
removed/recreated during containment. The other eight workers were unchanged.

The promotion receipt records thirty-two downloaded source/config files matching
the reviewed worktree, schema/access-control readback, ten limited HTTP smoke
checks, and unchanged aggregate account/history counts. The old native endpoint
was unavailable for over 400 seconds and deletion-state counts were zero before
migration. That was a pre-launch, sole-operator maintenance procedure, not a
general live-user traffic-drain guarantee.

The server browser opt-in was enabled for the exact staging project and configured
Services ID. Native client/key configuration was preserved. Apple registration
and the exact staging callbacks were read back. Production was not changed.

Deployment and smoke checks did not perform fresh Apple deletion authorization,
callback escrow, authenticated completion/resume, revocation, account deletion,
or physical-device acceptance. Do not infer those results from ACTIVE status.
Before any later promotion, repeat the [coordinated deployment
preflight](../runbooks/account-deletion.md#coordinated-staging-deployment-gate).

## September 8–9 Simulator runtime

The exact candidate was built with a private, staging-only browser opt-in and
state-preservingly over-installed on the dedicated staging Simulator. Strict
signature, embedded entitlement, packaged configuration, and packaged privacy
checks passed for that Simulator artifact. Its executable SHA-256 is
`ac7567c1b13692fd75831b4f6f144f20ac8f8f82632bfeada7c83c0fc1f03b61`.
This is not a physical-device binary.

Initial normal sign-out and one retry encountered connection-lost errors while
preserving local data. Fresh credential-free networking probes succeeded. After
one controlled, state-preserving app-process restart, normal sign-out reached
Welcome with zero profile roots/files and successful HTTP markers. The source
requires remote confirmation and authentication retirement before that state;
the HTTP aggregates were not independently correlated endpoint receipts.
No permanent networking fix or root cause was established.

The user then completed the already-open Apple browser login. Initial readback
showed a connection-lost page and zero local profile roots. Later readback reached
Sharing and mounted one root with eight files without another agent-triggered
login or callback replay. An owner-assisted, read-only aggregate matched that root
to one existing active Apple-linked profile with one new hosted session. The total
profile count remained two. No callback, authorization code, verifier, token, or
Keychain value was extracted or replayed.

### Current identity boundary

At `2026-09-10T01:30:20.614Z`, a read-only comparison found that the physical
staging app's sole profile-directory entry and the Simulator's sole profile root
were **the same**. The comparison retained only counts and an equality boolean.
It did not launch the phone app, change either account, or extract file contents.

This confirms existing-profile recovery, not distinct second-account choice.
It also does not establish which Apple credentials were entered or prove an
identity-merging defect. Both sessions remain intact while the operator clarifies
whether the browser login used the everyday Apple account or the separate test
account. Do not label this login Account B solely from the intended handoff or
infer subject continuity from an email/display name.

## Current history and lifecycle inventory

The owner-assisted READ ONLY transaction at `2026-09-10T01:26:50.465Z` used
repeatable-read isolation, a 15-second statement timeout, and ROLLBACK. It retained
only aggregate counts; the private local binding and SQL were not saved.

| Aggregate | Count |
| --- | ---: |
| Active profiles | 2 |
| Competitions / unfinished competitions | 3 / 0 |
| Completed results / involving the mounted profile | 1 / 1 |
| Accepted score revisions / submitting profiles | 2 / 1 |
| Accepted revisions belonging to the mounted profile | 2 |
| Consumed invitations | 1 |
| Unfinished deletions | 0 |
| Local primary journals / matching hosted participation | 1 / 1 |
| Local journals without matching hosted participation | 0 |

Sharing showed history without a refresh warning. The membership cross-check is
not an app-token RLS probe or adversarial-isolation pass. No unfinished competition
exists on which merely waiting would produce the remaining two-account lifecycle
evidence. One failed diagnostic query used the wrong score-owner column; source
inspection corrected that diagnostic before the successful query above. It was
not an application or server-contract failure.

## Remaining acceptance sequence

1. Resolve the current account-choice ambiguity without guessing. If the same
   Apple account was used, perform the separately scoped fresh login with the
   other existing account and verify the distinct profile. If different Apple
   accounts were used, preserve sessions and diagnose identity binding first.
2. Qualify native/browser identity continuity, cancellation, server-confirmed
   sign-out, zero prior local data, and sequential two-account isolation on the
   selected candidate. The historical receipts remain scoped to their old builds.
3. Establish a fresh agreed competition scope; obtain both accounts' own genuinely
   accepted derived scores and complete offline catch-up, seven-day finalization,
   results/history, rematch/mute/archive, and invitation consumption/replay.
4. Select and qualify an exact signed physical artifact. Obtain its required
   HealthKit, attributable background delivery, APNs routing, App Attest acceptance,
   and one-phone replacement-enrollment evidence. No old physical PASS transfers
   merely because source tests or Simulator execution passed.
5. After preserving evidence needed by scoring/lifecycle gates, perform the
   explicitly scoped physical test-account deletion and paired browser
   reauthorization. Verify remote completion, local wipe/no resurrection, and
   preserved Former competitor history. Never use a deletion begin/resume call
   as an inventory probe.
6. Complete the approved backup/restore rehearsal, privacy disclosures, support
   contact and credential-rotation ownership, and production qualification and
   promotion. The September 4 backup inventory is historical, not a fresh
   entitlement or recovery assessment.

The [production checklist](production-beta-checklist.md) and [evidence
ledger](production-beta-evidence.md) retain all older dated receipts. None of the
open acceptance gates above is waived by this documentation-only checkpoint.

## Retained operational receipt provenance

The local rollout archive retains these source receipts. Their
checksums identify documents, not users, devices, accounts, or profile fingerprints.
The table makes the source material auditable; a checksum alone is not proof that
an external gate passed. This checkpoint adds no sensitive screenshots, private
identifiers, credentials, health values, or account-level hashes to the repository.

| Receipt | SHA-256 |
| --- | --- |
| `staging-deletion-promotion-result-2026-09-08.md` | `9a70d89cb02677f49223f6e96f27adb1c5f87275bd60f1fb5619a17caaf0fdba` |
| `staging-browser-simulator-recovery-2026-09-08.md` | `7d711b38a55e788960ebf5bdc64a0908d2e56a90ba6499693704ba2781a06afb` |
| `staging-signout-browser-password-handoff-2026-09-09.md` | `02508f8105c582b5e2263468d15026c3f89304db743d4c81616fe1e29d784309` |
| `staging-browser-login-readback-2026-09-09.md` | `cae6d1459c6d51d441a8afa94e542a6b536fe9712677a0c76a204501f13c97a1` |
| `staging-browser-profile-comparison-2026-09-09.md` | `99e6f2df2307782dce2c276884bed71b59a207edea538b22002eeca7568f36c0` |
