# Staging browser qualification checkpoint — September 9, 2026

**Release status: not production-ready.** This dated checkpoint advances the
source, deployment, and Simulator evidence beyond the September 4 release
snapshot. A new signed physical package is prepared but not installed or
runtime-qualified. No older physical-device pass transfers to the new source.

Completion still uses one physical iPhone, dedicated Simulators, and two distinct
Apple accounts. Personal iCloud stays unchanged. Universal links remain explicitly
deferred; custom-scheme invitation evidence must be labeled separately.

## Source and automated verification

The September 8 application/backend source candidate was merged main
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

### September 9 completed-history repair

[PR #97](https://github.com/narenyenuganti/health-comp/pull/97) integrated the
scoreless-participant result-replay correction as
`db8273468748e359c8242cb0aaf08ab52f7e50d5`. Its tree,
`68f1c6d5340412d5b799c3ce34bf74bb1aa7b7e0`, exactly matches independently
reviewed head `7f307ee6ec958c6d4cd918ea256ecaff570dfd23`. The one approved
read-only reviewer reported zero Standards or Spec findings. Both exact-head
[Backend](https://github.com/narenyenuganti/health-comp/actions/runs/34432681720)
and [iOS](https://github.com/narenyenuganti/health-comp/actions/runs/34432681608)
workflows passed before the guarded squash merge.

The separate push-to-main [Backend run 34435362419](https://github.com/narenyenuganti/health-comp/actions/runs/34435362419)
and [iOS run 34435362448](https://github.com/narenyenuganti/health-comp/actions/runs/34435362448)
subsequently completed successfully on exact merged commit db82734. The iOS run
included the configured Core/app/Staging tests, device matrix and clean-tree gate.
No workflow was restarted. These runs do not qualify this later documentation draft.

The Core change validates a server result against an empty comparison ledger
when the owner has no accepted score events. It neither persists a fabricated
ledger nor invents accepted rows; existing participant, commitment/hash, deadline,
stable-completeness and owner-window checks remain. Backend source, grants,
migrations, authentication behavior and the pinned SDK did not change in PR 97.
Fresh merged-source Core Debug passed 246/246. Local fixture gates also passed
Core Release 246/246, application tests 626/626, runtime tests 26/26, and
release-style Staging tests 54/54, all with zero failures/skips where reported.
These overlapping suites must not be summed as unique tests.

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

### Earlier same-profile login, superseded by distinct-account readback

At `2026-09-10T01:30:20.614Z`, a read-only comparison found that the physical
staging app's sole profile-directory entry and the Simulator's sole profile root
were **the same**. The comparison retained only counts and an equality boolean.
It did not launch the phone app, change either account, or extract file contents.

That first login confirmed existing-profile recovery, not distinct-account
choice or an identity-merging defect. The user subsequently identified it as
their everyday account. The normal app sign-out reached Welcome with zero
profile roots/files at `2026-09-10T02:08:43.196Z`. This is source-gated retirement
evidence, not an independent endpoint-specific logout audit. Global app logout
may retire that account's phone staging session; personal iCloud was unchanged.

The user then completed Apple authentication with the alternate existing account.
Readback found one Simulator root/eight files. At `02:12:53.105Z`, a nonrecursive
metadata comparison found that root differed from the phone's retained profile
directory. The phone app was not launched and no identity value/hash was retained.
An owner-assisted READ ONLY aggregate at `02:14:32.354Z` matched one preexisting
active Apple-linked profile and one recent hosted session; total profiles stayed
two. This resolves account-choice ambiguity for that dated login without inferring
identity from email or display name. It does not establish current phone
authentication, authenticated RLS/adversarial isolation, or full lifecycle coverage.

## Earlier everyday-account history and lifecycle inventory

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

## Alternate-account history recovery on db82734

The later alternate-account inventory had zero accepted score revisions belonging
to its mounted profile and one completed result involving it. Sharing initially
showed No Competition and a refresh warning. Synthetic tests reproduced rejection
of a legitimate best-available result when that owner lacked a score ledger;
the correction above passed both positive regressions and fail-closed controls.

The signed db82734 Simulator executable has SHA-256
`74926d36d99c1ea67cbe86d51ef49bcd396c67bd58624c6b2d0d4d04d40ce592`.
Signature, simulated entitlements, packaged staging/browser configuration and
privacy checks passed. Over-install preserved the existing one root/eight files
and every profile path/hash exactly, compared in memory. No sign-out, account
switch, uninstall or erase was performed for the history repair.

One launch at `2026-09-10T04:05:45.721Z` showed Completed without the prior
refresh warning, Unable to connect, or No Competition presentation. After
termination, its sole primary journal contained one configuration, ten lifecycle,
two remote revision and one shared-result event. The journal matched the mounted
participant; unrelated journal count was zero. Owner accepted revision count
remained zero, with seven deadline-missing result days. Thus reconstruction does
not satisfy the still-missing alternate-account accepted-score gate.

Manual pull-to-refresh remains unverified: three Computer Use scroll requests
returned noWindowsAvailable, with no proven delivered gesture/handler invocation.
The successful on-launch history recovery is not a manual-refresh pass.
A bounded log reduction found 56 HTTP-200 markers and no HTTP-401 or
connection-lost marker, without retaining raw logs. These are transport markers,
not independent endpoint/subject proof. The app terminated and both preserved
Simulators were verified Shutdown.

## Physical package prepared, runtime qualification pending

The physical db82734 staging package was built separately using the existing
staging team, cached signing identity/profile and frozen packages. Its executable
SHA-256 is `f9b5459a420c42ceaccde28892259201823ae1834e0351c2fc8383f0c59c804d`.
Strict signature, required native Apple/HealthKit/background/APNs/App Attest
entitlements, packaged staging/browser configuration and privacy checks passed.
The unexpired embedded profile was privately matched to the known iPhone.
No signing credential or provisioning update was created.

The phone's installed staging app and directory metadata were reachable through
CoreDevice. That does not establish the installed executable, current authenticated
session or usable phone UI. This package has not been physically installed or
launched. Older c5932ed physical receipts remain historical, not passes for
db82734. State-preserving installation and actual native/browser authorization
and physical-service readbacks remain required.

## Backup readiness

A September 9 read-only dashboard check found staging on Free, with scheduled
backups unavailable under that plan. It returned a plan message, not an enumerated
backup inventory; no fresh zero-backup count is claimed. No paid plan, target or
restore method was approved or selected. Any restore still requires the exact
[quarantine, authorization and recovery prerequisites](../runbooks/backup-restore.md#execution-readiness).

## Remaining acceptance sequence

1. Preserve the now-distinct alternate-account Simulator session and repaired
   completed history. Finish the unverified manual-refresh check only with
   working controls or a human gesture; do not repeat login to repair history.
2. When the phone is idle and controls work, revalidate the prepared physical
   artifact, state-preservingly install it, and classify actual session state
   before any candidate-specific identity or score action. Qualify native/browser
   identity continuity, cancellation, server-confirmed sign-out, zero prior local
   data, and sequential two-account isolation on the selected candidate. The
   historical receipts remain scoped to their old builds.
3. Establish a fresh agreed competition scope; obtain both accounts' own genuinely
   accepted derived scores and complete offline catch-up, seven-day finalization,
   results/history, rematch/mute/archive, and invitation consumption/replay.
4. Complete the selected physical artifact's required HealthKit, attributable
   background delivery, APNs routing, App Attest acceptance, and one-phone
   replacement-enrollment evidence. Defer destructive replacement until evidence
   needed by unfinished scoring/lifecycle work is preserved. No old physical PASS
   transfers merely because source tests or Simulator execution passed.
5. After preserving evidence needed by scoring/lifecycle gates, perform the
   explicitly scoped physical test-account deletion and paired browser
   reauthorization. Verify remote completion, local wipe/no resurrection, and
   preserved Former competitor history. Never use a deletion begin/resume call
   as an inventory probe.
6. Complete the approved backup/restore rehearsal, privacy disclosures, support
   contact and credential-rotation ownership, and production qualification and
   promotion. The September 9 Free-plan check is not a restore rehearsal or
   permission to purchase resources or import data.

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
| `staging-other-account-two-factor-handoff-2026-09-09.md` | `b0d01bb495aa5b365920355b1537de2bb8882d88f7d82264727eb8900b9c6c2f` |
| `empty-owner-result-replay-review-2026-09-09.md` | `020afe9752d89dff52dd519f8794e045c4a746ba6e961d4284d9c219279c064c` |
| `staging-scoreless-history-qualification-db82734-2026-09-09.md` | `b453384d380fe713ff7c55b2a8c0baf041af7409f614bddcafbbd0e9bd9e4bec` |
| `staging-browser-physical-build-db82734-2026-09-09.md` | `08fb3d45d0c84a77d3f79c54521ea35638db1200b388b9f1855b17e95e614de8` |
| `staging-backup-availability-2026-09-09.md` | `fd04aff5be2f1ccc34c611291e3af773d756a6547bf438cf114fe47b1621ff4b` |
