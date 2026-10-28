# HealthComp Production Beta Evidence

This file records anonymized, reproducible rollout receipts. It excludes Apple
account details, device identifiers, tokens, private screenshots, raw HealthKit
data, exact Activity values, and reversible local fingerprints.

## Controlled-beta delivery checkpoint — October 28, 2026

**Delivered for external testing; controlled-beta completion remains open.**
The [current checklist](production-beta-checklist.md#controlled-beta-delivery-checkpoint--october-28-2026)
selects production TestFlight **1.0.2 (1)** from merged
`9145b3199ea4245cf63007a6fdca6346edd31521`.

- **Source:** [PR #174](https://github.com/narenyenuganti/health-comp/pull/174)
  removes the opponent legend's extra qualifier, including its accessibility
  copy. [PR #175](https://github.com/narenyenuganti/health-comp/pull/175)
  condenses schedules and localizes displayed timestamps without changing the
  canonical competition calendar, scoring or backend. Its exact reviewed head
  `8a725af1ebee2e4e5ae1abf4e402d803458d6421` passed
  [iOS CI](https://github.com/narenyenuganti/health-comp/actions/runs/40639400135)
  and [Backend CI](https://github.com/narenyenuganti/health-comp/actions/runs/40639400130).
  The merged and tested trees are identical. Duplicate post-merge runs were
  cancelled, not passed; they add no qualification.
- **Distribution package:** the retained signed App Store export passed bundle,
  production-backend, profile, signature, entitlement, privacy and symbol checks.
  Its IPA SHA-256 is
  `972a2928baa24cdb330bec0bc6ce33a85663fb0e7070e7e8896040f34f736e16`.
  Native upload and Apple processing completed. After owner reauthentication,
  the external Friends Beta group showed this build as **Testing** on October
  28. This clears the review wait for this build, not every distribution or
  individual-membership eligibility question. No Apple Support inquiry occurred.
- **Installed clients:** the Staging phone package was over-installed without
  uninstalling; production was updated through TestFlight, not from a developer
  archive. Each retained the same sampled profile root and relative file names
  across its update. Both Simulator packages were also updated. These are
  installation/metadata findings, not file-content equality, an on-device
  executable hash or independent authenticated-server evidence.
- **Current UI:** normal foregrounding of the updated physical production app
  and the production Simulator companion showed their expected existing accounts,
  opponent, active Day 1 and matching local end boundary. The physical Week
  legend no longer has the removed qualifier. The companion's installed binary
  hash, signature and production backend matched its retained candidate. No
  explicit refresh, debugger, reinstall, account/key change or new invitation
  was used for these UI observations. Automatic app/network side effects were
  not independently measured. The dedicated Simulator was returned to its
  original shutdown state and the external app windows were minimized.
- **Publication:** all eight existing production website checks passed on
  October 28, including the privacy/support pages, static association file and
  fake-token invitation page. These HTTP checks are not physical universal-link
  or real-invitation qualification.

The physical detail screen reported **Activity source is temporarily unavailable**.
No available production score or matching companion score readback is proved by
this checkpoint. The source maps missing Activity-summary data to that neutral
state, but the physical cause is not established. Do not infer denied permission,
a backend rejection, successful zero-point acceptance or a code regression from
the message alone. Continue the existing-match smoke check only when genuine
source availability is confirmed, then finish the retained completion audit.
Earlier checkpoints and owner-approved deferrals remain unchanged.

Private, aggregate-only receipts remain outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `staging-physical-update-9145b31-20261028T074722Z.json` | `f810c97d2ab146ab32c9a2658a25783a7b29f857bddc800a310944765b22238b` |
| `production-testflight-update-9145b31-20261028.json` | `d6a051c600ab34a1de78fcf67c1a5d53fdbce0fbd1706d6608584be7d85b3154` |
| `production-post-update-ui-9145b31-20261028.json` | `208212e99b1b046d3e0b37689a0b8af36c71ca619f0ace102f6db26d2b2d7265` |
| `production-companion-ui-9145b31-20261028.json` | `8ee10111f91c025d395e43139690b3e7172510c08cad197faac8faa9dbfd5686` |
| `testflight-external-1.0.2-review-20261028.json` | `2ab33274984b4bdfcffb45cb8693eacc8513682162db32c338839b8f21acdb17` |

## Controlled friends beta scope — October 24, 2026

The owner approved the smaller 2–5-person beta and the five qualification
deferrals in the [current completion checklist](production-beta-checklist.md#controlled-friends-beta-scope--october-24-2026).
This records a scope decision, not new runtime evidence. Existing receipts and
their limits remain unchanged; deferred checks are not converted into passes.

Same-phone replacement qualification, full live stable-result qualification,
the exhaustive APNs state matrix, actual hosted recovery/forward repair and
additional live adversarial/replay qualification no longer block this beta.
The physical deletion waiver and universal-link deferral remain unchanged.
Security behavior, automated coverage and accurate privacy disclosures remain
required. Release configuration, privacy/distribution, signed delivery with a
short two-account smoke test, and a truthful handoff are still uncompleted
release gates. The current competition may continue without holding delivery
for a seven-day result. No new competition is required by this scope decision.

This amendment changes no app, backend, account, device or provider settings.
It proves neither TestFlight acceptance nor general production readiness.

## Private beta scope exception October 4 2026

Physical account-deletion verification is owner-skipped before beta, not passed:
server completion, local cleanup and post-deletion anonymized-history readback
remain unverified. No account was deleted to establish this exception. The
[checklist](production-beta-checklist.md#private-beta-scope-exception-october-4-2026)
and [recovery runbook](../runbooks/backup-restore.md#private-beta-deletion-test-exception)
preserve the deletion feature, existing automated coverage and privacy/history
safeguards. Other gates and **not production-ready** status remain unchanged.

## Current qualification checkpoint — October 23, 2026 UTC

The [current checklist](production-beta-checklist.md#current-qualification-checkpoint--october-23-2026-utc)
selects merged `e92970ab98036d48f75365884da8c6cc92bd81ae` and Staging scoring
Function version 18. This fixes one demonstrated public-fixture rejection and
records a subsequent new-day score with a stored assertion chain. The later
bound observation below adds current-key counter-window and consumed-capability
database-contract evidence. Status remains **not production-ready**; HTTP replay,
independent proof-byte verification and replacement enrollment are not qualified.

The exact reviewed and merged trees match. Reviewed-head Backend run
`39908144598` and iOS run `39908144551` passed. Merged-main Backend run
`39913831861` and iOS run `39913831824` also passed. Completed-log readback
qualifies the checklist's test counts, three unsigned device builds,
clean-source verification and dedicated CI Simulator cleanup. This is not a
signed archive/export or production qualification. The public fixture,
provenance and license are checked in; its acceptance is not evidence of the
phone's actual assertion flag.

Private aggregate receipts remain outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `extended-assertion-staging-deployment-20261023T071027Z.json` | `5ebf5bd06fd10d5944346ffc6027cd7515f887583502f08c6977d4d34fcc02a0` |
| `staging-v18-current-cycle-baseline-20261023T071217Z.json` | `14b7fd54597c129b4395443c081f846ce41ca72e1dad90519d479a3789bd2ab9` |
| `physical-staging-v18-new-day-20261023T072214Z.json` | `c88cb8025b359d3c809a258fdc6c0d71bf32ba60a8bbd950ae84d0245c078324` |

At 07:10 UTC, only `submit-score-revision` advanced to ACTIVE version 18.
All four downloaded source assets matched merged source. The other eleven
Functions, gateway settings and secret metadata remained unchanged; secret
values were not read. One credential-free boot probe returned the expected
invalid-request response. Scratch and temporary project selection were removed.
This is deployment/boot evidence, not authenticated scoring evidence.

The separate 07:12 UTC baseline found two participants and three elapsed days:
zero creator revisions; 12 invitee revisions spanning two days; one latest
available enrollment-backed day; zero latest assertion-backed days; no result.
The ordinary physical Staging visit then visibly showed Day 3 Activity and
points. The only attempted refresh gesture had no observed spinner and followed
the visible score change, so refresh invocation and causality are unproved.
No numeric Activity/score values were copied to these receipts. The closed
one-shot observation was left closed. No debugger, restart, reinstall, sign-in,
account/key change or new invitation occurred. Mirroring was minimized and the
phone released before the hosted readback.

At 07:22 UTC, the same aggregate-only read-only/repeatable-read query found
15 invitee revisions spanning three days, two latest available days, one latest
assertion-backed day and one latest enrollment-backed day. These proof
classifications may overlap. Creator revisions remained zero; no result existed.
The increase supports new-day server scoring with a stored assertion chain,
not exact phone/key binding, independent proof-byte validation, a counter pair,
replay resistance or gesture causality. Both queries passed strict field/type
validation; no identifiers, Health values, scores or proof bytes were returned.
These 07:22 findings do not inherit the later visit's exact binding or replay
findings. Existing owner holds and scope exceptions are unchanged.

### Later bound physical observation — October 23, 23:15 UTC

| Private aggregate receipt label | SHA-256 |
| --- | --- |
| Creator accepted-score aggregate, 07:45 UTC | `d0970881de69ec948e6a5f21af2cfa0eebd7e12ee6c70b9cae0de0f701196816` |
| `physical-bound-replay-20261023T231453Z.json` | `494a38086ac08d74d8c973ba784029902fcebb05d1d9a1cd6b55ed1ff7429828` |
| `physical-staging-bound-activity-20261023T2315Z.json` | `f4f2e5b8a1de5c53290499d9a1681b4f93384db0e89b46e5b57e14452183d202` |

At 07:45 UTC, the same cycle had three creator revisions covering three days,
two latest available days and two latest assertion-backed days; the invitee had
17 revisions covering three days and two latest available days. Both participants
therefore had server-available score days. The one-phone/two-account topology
does not establish independent physical participants or Health sources.

At 23:13–23:15 UTC, the retained local package from `03e1998` passed the pinned
hash/signature/provision checks and native metadata matched its Staging version.
This is not an on-device executable hash. Private local profile/installation/key
binding stayed equal across the sampled process/profile checks and two read-only,
repeatable-read counter queries. The counter advanced 10 to 11; available/total
revision and consumed assertion-chain counts each increased by one.

One strict rollback-only query then selected a unique fresh available score
after the server baseline, bound its consumed grant/challenge to the exact
existing key/installation, and required the key to predate the baseline. All six
aggregate assertions passed: bound assertion, existing key, still-unexpired
capabilities, consumed-context denial, consumed-grant denial and unchanged
protected state. The transaction rolled back. No identifiers, scores, Health
values or proof bytes were returned or retained in these receipts.

The app was foregrounded after the baseline and **Check Activity Now** invoked
once. Its observation completed one read, reported three unchanged accepted
revisions, zero enqueues and zero read/reconciliation failures. The fresh score
may have arrived during foreground catch-up, not from the button. The raw
receipt's conservative `refresh_causality_proven`,
`score_linked_counter_advancement_proven` and `replay_resistance_proven` fields
remain false; the six separate contract assertions do not turn them into proof
of an exact counter increment's cause or captured-byte HTTP/cryptographic replay.
Continuous process lifetime, source-inode identity and independent cryptographic
verification of the phone's proof bytes were not established.

The diagnostic display was cleared, Account closed and Mirroring explicitly
minimized. The reader completed; private copies were removed. No debugger,
reinstall, account/key reset, new competition or production action occurred.
Replacement enrollment, final-result, notification routing, recovery, privacy,
distribution and production gates remain open as listed in the checklist.

## Previous qualification checkpoint — October 22, 2026 UTC

The [previous checklist](production-beta-checklist.md#previous-qualification-checkpoint--october-22-2026-utc)
selects merged `3c155c89b97c9af527f9a8670877b2e1c20c7996` for the automated
matrix, `04d1792` for the Staging version 17 scoring deployment, and `03e1998`
for the installed one-tap Activity package. These are separate observations.
Status remains **not production-ready**.

Exact-main Backend run `39779485955` and iOS run `39779485964` both passed.
Independent numeric-only log readback qualifies the checklist's counts, three
unsigned device builds, clean-source verification and dedicated CI Simulator
cleanup. PR #162's exact reviewed head also passed both suites before its
guarded squash merge; the reviewed and merged trees are identical. That change
only recognizes the exact support mailbox in a plain or Cloudflare-encoded
anchor, with malformed/wrong-target negative tests. Seven live Staging website
checks passed; no website content or app behavior changed.

Private aggregate receipts remain outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `assertion-diagnostics-staging-deployment-20261022T085126Z.json` | `3dd15e439a405cdbf9b195f61305ac8680b6eb77d5b851fe8fe0827b1d4be3c8` |
| `staging-physical-update-03e1998-20261022T100323Z.json` | `05dfe0acfec3bff387038fe75c33b5836a554b9019dcbd05925866b4027f01c1` |
| `staging-one-tap-physical-observation-20261022T1004Z.json` | `230a0da6bd10a7d1479ecc652a87fbbcce2a8ae90967641c207605be5b1a0acf` |
| `staging-current-cycle-proof-20261022T100847Z.json` | `8b3942bdfedcfef03a16af9f7d1dc0e95f4170fb779c4ffed6eecf7e9880a4e5` |

The version 17 deployment changed only fixed diagnostic labels. Four returned
assets matched the selected source; the other eleven Functions and gateway
authentication settings were unchanged. Two credential-free probes returned
the expected invalid-request result. The first local checker expected the wrong
flat error shape; source inspection corrected it to the existing nested contract
before the second probe. These responses do not prove authenticated acceptance.
No migration, account/key change or production action occurred.

At 10:04 UTC, one normal launch and one **Check Activity Now** invocation
completed on the updated physical app. One Activity read started/completed;
the aggregate observation counted one summary day, six missing summary days,
five future-day skips, nine non-scoring lifecycle skips, two unchanged-accepted
skips and zero enqueues. No read or reconciliation failure was reported.
The counters cover all competitions in that refresh, not one bound match.
Missing summaries are not proof of zero Activity. An accepted skip means equality
with an already visible local server-derived row, not new server acceptance.
There was no debugger, manual refresh gesture or separate response capture.
The diagnostic was cleared, the Account drawer closed and Mirroring minimized.
The over-install preserved one profile root and 26 file-name metadata entries,
not independently verified file contents or an on-device executable hash.

At 10:08:47 UTC, a separate bounded Staging Management query selected only 16
allowlisted aggregate fields in a read-only, repeatable-read transaction with
rollback. It found two participants and two elapsed days in the unique current
cycle: no creator revisions; four invitee revisions spanning two days; one
latest available invitee day classified as enrollment-backed by the query; zero
latest assertion-backed days; zero results. It returned no identifiers, scores, Health
values or proof bytes. The query does not establish exact current-phone binding,
proof-byte validation, counter advancement, replay resistance, refresh causality
or stable two-client results. Assertion/enrollment counts may overlap and must
not be added. A retired installation/key can explain an absent current chain.

The next physical check needs genuinely changed Activity, not another unchanged
refresh. Preserve the existing October 21–27 cycle; October 28 only opens its
final-result check. Current-installation APNs routing, hosted recovery, privacy
publication, signed distribution and production promotion remain unqualified.
The owner-skipped deletion test, universal-link deferral, paid-setup hold and
Apple-contact hold remain unchanged. No completed historical notification
lookup needs repeating.

## Earlier qualification checkpoint — October 22, 2026 UTC

The [earlier checklist](production-beta-checklist.md#earlier-qualification-checkpoint--october-22-2026-utc)
selects merged `d897a73` for its completed automated matrix and the scoped
Staging version 16 deployment. Status remains **not production-ready**. App and
configuration source remain unchanged from the selected `7839acb` package; the
shared server verifier changed. Source, deployment and physical findings are
separate.

Private aggregate receipts are retained outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `app-attest-extension-rollout-frozen-2026-10-22.json` | `ce9f7ba2d03d403d6086d31e91331e2a754ce92a1da04789401ea992f4119d8e` |
| `staging-v16-normal-app-observation-2026-10-22.json` | `1368df992290a0cf1c02e2ed883069d40a9cb8cc9c54becf3b67d50cdcaa2316` |

Exact-main Backend run `39691971124` completed at October 21, 23:20:54 UTC.
iOS run `39691971125`, attempt 2, completed at October 22, 00:43:32 UTC. Bounded
completed-log readback qualifies the checklist's counts, successful clean-tree
and dedicated Simulator cleanup, and three unsigned device builds. The original
PR failure was missing system Copy in the share sheet; the original main failure
was a rendered-configuration wait timing out before a matching subsequent read.
Each received one failed-only retry on unchanged code. Passing retries do not
establish either original cause or an application fix.

One named deployment completed at 00:51:17 UTC. Staging scoring became ACTIVE
version 16 with `verify_jwt=false`, unchanged from version 15. The four returned
entrypoint/shared-verifier/shared-HTTP/import-map assets matched selected source.
Eight target metadata fields held stable around the post-deploy download and
after boot; other eleven Function versions/authentication settings were unchanged.
One credential-free `POST {}` returned HTTP 400, `invalid_request` / `Invalid
score revision`, before authentication. Both owned source scratch directories
were removed and absence verified; the worktree remained clean and unlinked.
No migration, credential prompt, app installation or production action occurred.
No deployed lockfile was returned, so deployed dependency-graph equality is not
claimed. The [public rollout receipt](https://github.com/narenyenuganti/health-comp/pull/157#issuecomment-6330031783)
records the same scope.

At 01:03:04 and 01:07:02 UTC, separate structural queue snapshots each found one
terminal Day 1 App Attest rejection, no pending/recovery/accepted target entries
and no new target score entry. Only the primary outbox and server cursor inventory
were copied privately; copies were removed. The first wrapper stopped after its
snapshot, so private identity equality across snapshots is not proved. Neither
snapshot is a full payload decode, continuous-process/inode proof or on-device
executable hash. Normal activation preserved the sampled process; Mirroring then
reported `noWindowsAvailable` on the sole refresh tool call. Execution was not
confirmed and the gesture was not repeated. The phone was released at 01:07:22
UTC with Mirroring minimized. There was no post-phone hosted lookup.

The earlier saved rejection and separate hosted flags event were not attributed
to the same exact request; the physical flag byte remains unknown. Public-fixture
RED-to-GREEN establishes parser compatibility only. Neither unchanged queue
counts nor the boot response prove physical fix acceptance or failure, score
counter advancement, replay resistance, replacement enrollment or stable results.
Preserve all remaining gates, historical receipts and explicit owner holds.

## Historical qualification checkpoint — October 21, 2026 UTC

The [historical checklist](production-beta-checklist.md#historical-qualification-checkpoint--october-21-2026-utc)
selects `a5809f9` for its completed exact-source Backend/iOS matrix and the hosted
20/v2 database verifier. Application/configuration and Function source remain
unchanged from `7839acb`; this source advance proves no new installation. The
one accepted diagnostic match restores a scoring target but supplies no accepted
score, assertion replay or stable result. Status remains **not production-ready**.

Private operator receipts are retained outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `recipient-rollback-verifier-ci-2026-10-20.json` | `cc4a51095f15608f7ed960d864fa7b5b42e28e69df568da49e8198b3c4e4b5fa` |
| `staging-recipient-hosted-verifier-a5809f9-attempt.json` | `876bec0d23501ab7a012f3254bd3b5ca8f19ca5843f9c9bf7fb2d8086ac1265a` |
| `staging-recipient-hosted-verifier-2026-10-20.json` | `1c9a05d64cfff9f038fae856a818d948fc7c28c5a81b8b4a443825c322441f9c` |
| `staging-diagnostic-match-2026-10-20.json` | `bedf706979afc32c09664694e0c4c2ade7e5c72d097d97e2d8725b42bbaea67e` |

The selected verifier SQL has SHA-256
`bf5fde7f55d929b14713b6fc435069ac58337ee635eaa4488276a9ed66a96bff`.
Independent local receipt validation at October 21, 03:43:13 UTC found the exact
six-field `healthcomp_staging_adversarial_v2` pass: 20 assertions, rollback, zero
synthetic rows and no private values returned. The local receipt modification time
was 03:42:38 UTC; neither time is an independently queried server execution time.
The pinned runner required zero `psql` exit status, empty captured stderr and the
sole nonblank stdout matching the strict allowlist. The password went directly
to native `psql`'s hidden TTY prompt, not helper input, arguments, environment or a
saved file. No raw native output was persisted beyond the aggregate receipt.

The hosted pass covers the selected sequential database adversarial boundary,
including the five recipient checks documented in the
[runbook](../runbooks/supabase-environments.md#rollback-only-adversarial-staging-verifier).
It is separate from isolated CI and does not qualify live Edge concurrency,
physical scoring, cryptographic App Attest replay, stable results, operational
recovery or production readiness. No phone, deployment or production action was
part of this verifier run. Do not rerun the completed attempt.

The diagnostic match's two-client schedule is October 21–27, Los Angeles time.
Its October 20 UTC receipt proves observed create/accept/rendered scheduling only,
not an exact claim-request count or a score. All other gates, holds and the
owner-skipped physical deletion exception remain unchanged.

## Historical qualification checkpoint — October 20, 2026 UTC

The [historical checklist](production-beta-checklist.md#historical-qualification-checkpoint--october-20-2026-utc)
selects merged `7839acb`, its completed exact-source Backend/iOS CI, current
Staging package observations, four-asset scoring-source equality and the new
narrow Apple delivery finding. It preserves all unclosed release gates and
**not production-ready** status. Source, installation, hosted and physical
findings remain separate; none supplies the missing stable-result or replay pass.

Private operator receipts are retained outside this public repository:

| Receipt | SHA-256 |
| --- | --- |
| `staging-physical-update-7839acb-20261020T034553Z.json` | `6d5f397849d067349a85da06cc7c0518a4b586e11dd6ed19cc595a5af4a01069` |
| `staging-diagnostic-screen-simulator-update-2026-10-19.json` | `414f2bc2cb18d61249fd2d7cacebc28e66ed0a0fea60bba4d806fa67493059ed` |
| `staging-scoring-source-drift-readback-2026-10-19.json` | `664f10ddb534c6da48a7968e9ea005a7e25b4f842836c408984550d8d9158277` |
| `staging-existing-cycle-eligibility-2026-10-20.json` | `cb8f61d251bc66e808f72ed835f25215a04b817d5b3b7267e37cf1e65077dcfe` |
| `staging-existing-apns-apple-readback-2026-10-20.json` | `ffd2a9fb4967737b2a641d9bbe596a979b853dacaa6ede05c4fa5136d1a14035` |

Apple's four lookup results were one delivered and three expired after offline
storage, with exact reference and Development-environment matches. This does not
bind delivery to the current phone or prove tap routing. No replacement sends
or repeat lookups were used to improve the count. No reference or token value
is published. The private receipt documents limited initial identifier exposure
in tool output and a transient token read in RAM; no claim of zero prior exposure,
provider-history deletion or secure memory erasure is made.

## Historical qualification checkpoint — October 19, 2026 UTC

The [historical checklist](production-beta-checklist.md#historical-qualification-checkpoint--october-19-2026-utc)
records exact-main `9f9fb5e` Backend/iOS CI, the integrated recipient invitation
contract, the exact-tree PR #151 CI pass and current-schema local synthetic
recovery qualification. It also
records the earlier empty system-share-sheet CI failure without claiming a
confirmed cause or application fix. Local populated restores and passing source
CI are not hosted recovery or physical qualification.

The preserved October 11–17 competition reached `best_available`, not stable:
the post-deadline aggregate-only readback found two accepted participants,
zero daily revision coverage for either and zero stable attestations/results.
Its receipt is scoped by a unique schedule, not a fresh private client/key
binding. Waiting cannot close this cycle's stable-result gate. Preserve the
fallback history; diagnose the real submission failure before another lifecycle.

At 20:20 UTC, explicitly approved Staging migration 018 produced the expected
23-version chain and expired four old unnamed pending invitations. Same-process
aggregate and ordered-row comparisons preserved all four accepted competitions
and related history. Only `create-competition-invite` advanced ACTIVE version 5
to version 6, with gateway JWT verification preserved and other Function metadata
unchanged. Downloaded entry/shared/import-map bytes matched source; no deployed
lockfile was returned, so dependency-lock/graph equality remains unproved.

By 20:38 UTC, one matching Simulator install and one normal launch completed.
Its executable/signature matched the prepared artifact, but the combined
path/mode/byte preservation assertion failed and its RAM baseline is gone.
Original byte equality and failure cause remain unproved. Independent stopped
Core replay passed five journals/147 events and owner binding; the October 11
cached result is completed `best_available` with zero accepted day slots and
14 deadline-missing slots, not stable. Ordinary startup network effects were not
classified. The app was terminated and dedicated Simulator shut down. Current
history validity does not prove the lost installation comparison.

The matching physical candidate remains uninstalled, the physical live reader
remains disabled/old-install pinned, and the live recipient flow remains
unqualified. No new invitation, physical action, hosted recovery, policy
publication, release distribution or production promotion is established by
these readbacks. The [invitation plan](../plans/2026-10-19-recipient-bound-invitations.md#dated-staging-rollout-evidence)
records the dated rollout boundary. The owner-skipped deletion test, deferred
universal links and paid-setup/Apple-contact holds remain unchanged. Release status
remains **not production-ready**. Older receipts retain their named time and scope.

## Historical qualification checkpoint — October 13, 2026 UTC

The [historical checklist](production-beta-checklist.md#historical-qualification-checkpoint--october-13-2026-utc)
records successful exact-source CI for `da412f9`, its locally qualified but
not-installed diagnostic Staging package, the preserved October 11–17 competition,
and the last dated day-one rejection evidence. The October 18–19 confirmation
window requires actual seven-day coverage and matching final commitments; it
does not promise completion. Physical scoring, request correlation and the
independent release/recovery/production gates remain unqualified. Historical
receipts below retain their original artifact, time and scope. Release status
remains **not production-ready**.

## Historical qualification checkpoint — September 28, 2026 UTC

The [historical checklist](production-beta-checklist.md#historical-qualification-checkpoint--september-28-2026-utc)
records exact-source CI, both installed `507c2c5` Staging packages, the accepted
September 28–October 4 competition, the still-unverified usable day-one score,
and the local-only recovery milestone. October 5 is the earliest stable-result
check, not full-goal completion. All dated receipts below remain limited to their
named artifacts and observations; they do not qualify the newly selected binary.
Release status remains **not production-ready**.

## Historical qualification checkpoint — September 9, 2026

The [staging browser checkpoint](staging-browser-qualification-2026-09-09.md)
records the b24ecbd staging backend promotion and the later independently reviewed
db82734 completed-history correction with successful exact-head PR CI. The earlier
same-profile browser login was followed by zero-root sign-out and a verified
distinct existing alternate-account login. Its state-preserved db82734 Simulator
build now reconstructs the completed result without inventing owner score rows.
Manual refresh and full two-account lifecycle qualification remain incomplete.

A signed db82734 physical package is prepared and validated but has not been
installed or runtime-qualified. No physical service pass is inferred from it.
All older PASS entries below retain only their stated artifact, timestamp, and
scope. The original rollout objective remains incomplete and the app is not
production-ready.

## Evidence snapshot

**Historical snapshot:** September 4, 2026 PDT. Integrated evidence main is
`32c5df7ee4951ffa32965217d6c51ea4c07e10de`; selected physical build commit is
`c5932ed2ff83c157f0703472a279474cb0240cc4`, containing reviewed application
source `76b797d2fc706d40121dd85478c3edbedac04e38`. Between selected build and
evidence main, only the two release ledgers changed. No new binary is selected
by this documentation update.

Runtime and hosted rows below are dated, last-observed receipts. The September 4
read-only hosted inventory below refreshes project, Function, backup-list, and
aggregate lifecycle facts only. Phone/Simulator process and authentication
state, jobs, provider/key validity, and plan entitlements were not refreshed.
A recorded PASS applies only to its stated source/artifact, time, and scope.

The user-approved completion topology is one physical iPhone, one or more iOS
Simulators, and two distinct Apple accounts. A second physical iPhone is not
required. Physical-only platform services still require evidence from the one
physical phone. Universal links are explicitly deferred because no HTTPS
invitation domain will be provided; the custom-scheme fallback must not be
represented as universal-link evidence.

| Scope | Current evidence | Disposition |
| --- | --- | --- |
| Application source | Integrated evidence main `32c5df7ee4951ffa32965217d6c51ea4c07e10de` preserves selected build `c5932ed`'s reviewed application source `76b797d`: the shared-client seam, score-row identifier correction, fail-closed authentication sign-out boundary, reviewed named-source Account B evidence, closed App Attest assertion-stage diagnostics, the exact 37-byte legacy signed-flag verification repair, PR #80's durable remote HealthKit callback receipt and teardown-race hardening, and PR #84's process-rooted observer-delivery provenance classifier. PR #85 changed only the release ledgers | PASS |
| Selected release artifact offline validation | `HealthComp-Staging-c5932ed-20260901.app` was built from exact build commit `c5932ed2ff83c157f0703472a279474cb0240cc4`, whose application tree equals source `76b797d2fc706d40121dd85478c3edbedac04e38`. The retained 23,180 KiB artifact passed strict signing, paid-team provisioning, exact public staging configuration, publishable-key shape, custom-scheme-only routing, provisioned Sign in with Apple, HealthKit/background delivery, sandbox APNs, development App Attest, source-cleanliness, and frozen package-lock validation. Executable SHA-256: `1658b606f986ce39fc878673fc3b5b7e7fe495e72f386109be1181f4397a6e71`; package-lock SHA-256: `436fe2d4c83e2e7bbe1f236afb6dcb81b0d5b530e4fa75aaf920a6da51519a21`; build receipt `physical-current-build-c5932ed-2026-09-01T232030Z.json` SHA-256: `c98c3880971fbc0c02f3402b95ca5f85096243ce75d6f71222e5958602fa23a4`. The 1.5 GiB scratch root and copied local configuration were removed while the root configuration was preserved. This build-time receipt proves offline selection only; the later September 2 physical receipts below separately prove installation, retained-session launch, and a partial background-observer result | PASS |
| Selected September 2 physical installation and retained-session continuity | Selected `c5932ed` over-installed without erasing state: one profile root, eleven files, and thirteen pre-install observer receipts were preserved exactly. One launch reached authenticated Sharing without a sign-in/setup, connection-error, or Health-prompt surface. This passes installation and retained-session continuity, not fresh native authorization or foreground accepted-score/App Attest evidence. Receipt `physical-background-observer-process-replaced-c5932ed-2026-09-02T064419Z.json` SHA-256: `1ba673b9763339a4a06ce0c88726c59464c5f57c2eb4664ce7f7521bfb453c83`. Its separate background attempt appended zero new receipts and found a different final process; that gate failed closed. No crash report was found in the window, and the cause of process replacement was not established | PASS |
| Selected September 2 background receipts and incomplete provenance | A later window on selected `c5932ed` advanced the sealed event baseline from 38 to 44 receipts. All six new receipts were unique `observerWakeupBackground` entries with zero issues and positive publication revisions; there were zero new foreground/disqualifying receipts and all preexisting receipts were unchanged. The delayed final readback found a different process from the foreground-armed process, so process continuity could not be established and `gate_passed` remains `false`. Receipt `physical-background-observer-receipts-process-continuity-unproven-c5932ed-2026-09-02T221010Z.json` SHA-256: `79bf470b8af7320b1b31b1ee7c2d073cdb0fa972dd9021dc48b1f1d077762bb7`. This proves the app-side receipt subset, not the complete background-wake gate or current phone state | PARTIAL |
| Historical `c3a8fb2` physical install, authenticated-session continuity, and observer-callback durability | Before installation, the historical same-bundle profile contained one root, ten files, 48,118 bytes, and zero `observerWakeupBackground` occurrences. Then-selected artifact `c3a8fb2` over-installed without changing those aggregate root/file counts or total bytes. Exactly one manual foreground launch restored authenticated Sharing without a sign-in prompt or warning. The physical HealthKit observer then produced six unique callbacks under the application's internal `observerWakeupBackground` label: all six were issue-free, all carried positive publication revisions, and all were durably committed under the reviewed commit-before-callback-completion contract. Because the receipt retained no app-state or system-wake provenance, it does not prove that HealthKit woke the app for background delivery. The app terminated with zero remaining processes; temporary snapshot roots were removed and iPhone Mirroring was minimized. Privacy-safe receipt SHA-256: `0383fde3ee55bceff2dbccbdf0a14195687471c12211822ad5f410a40c92e1e7`; it retains no identity, token, signal identifier, Health value, score, filename, file content, or screenshot. This physical evidence does not transfer to selected artifact `c5932ed` | PASS |
| Physical authentication and earlier refresh | Signed artifact `aa16411` was state-preservingly over-installed and its executable matched SHA-256 `913a915b6eeae671be5148187a05456ff2d0f30fe6a532c77b8e440775bc795b`. Exactly one launch initiated native Sign in with Apple; after the user handled the system prompt, Mirroring reconnected to authenticated Sharing with one active competition and no warning. One pull-to-refresh gesture was issued. The bounded hosted window contained four HTTP-200 App Attest challenges, two HTTP-400 score requests, and two HTTP-401 score requests with the former fixed `invalid_assertion` diagnostic. Aggregate local persistence contained one profile root, ten files, seven terminal score revisions, zero pending entries, five `appAttestRejectedTerminal` failures, and two `serverContractMismatch` failures. The app terminated with zero remaining processes. Receipt SHA-256: `335d7d21535667540a601c56819412c5ddd361817ac10f6c294306c6feeaf9c9`; it retains no identity, token, private identifier, Health value, score, request/proof material, or screenshot | PARTIAL |
| Current integrated application candidate | PR #67 supplied one project-wide Supabase client. PR #68 corrected downloaded score changes to accept the backend's score-row `entity_id` while retaining participant and server-sequence validation. PR #70 replaced best-effort sign-out with server-first global logout, verified Keychain removal, an identity-free pending-removal tombstone, and a fail-closed UI transition. PR #73 published the exact-main fresh Account B sign-out, reauthorization, and isolated-profile readback. PR #74 split hosted App Attest assertion rejection into closed object, key, and signature stages without weakening verification or changing the public client response. A later physical new-day wire localized the real iOS 26.6 rejection to `invalid_assertion_object`; PR #76 accepts Apple's signed `0x40` flag only for the exact 37-byte legacy authenticator and merged as `bb2910f`. PR #80 integrated durable remote HealthKit callback receipts and terminal teardown-race hardening as `886bd60`; evidence-only PRs #81 and #82 advanced integrated main to `7218065`. PR #84 integrated the process-rooted fail-closed observer-delivery provenance classifier as `c5932ed`; evidence-only PR #85 advanced main to `32c5df7` without changing application/backend source. Selected artifact `c5932ed` has signed offline validation, September 2 state-preserving installation/retained-session continuity, and six clean new background-classified receipt facts. Fresh selected-artifact Sign in with Apple, foreground HealthKit submission, a selected-artifact App Attest assertion, attributable background-wake provenance, APNs delivery, deletion, replacement enrollment, the full two-account lifecycle, invitation replay, backup/restore, and production promotion remain incomplete | PARTIAL |
| Remote HealthKit observer-callback durability and background wake | A bounded physical attempt on then-selected artifact `aa16411` found no durable observer marker and did not pass. Receipt SHA-256: `63c8589f4865fe829342186f2ba003fd01b2d24e4771e8a8d2d51d10302169c9`. PR #80 integrated a bounded, protected, profile-scoped receipt that must commit before callback completion. During one manual foreground launch of previously selected artifact `c3a8fb2`, six unique, issue-free, positive-revision callbacks passed durable persistence. [Apple documents](https://developer.apple.com/documentation/healthkit/executing-observer-queries) that updates can also arrive as an app launches; that historical receipt retained no app-state or system-wake provenance, so its labels remain excluded from background attribution. The old app terminated cleanly and temporary snapshot roots were removed. Historical receipt SHA-256: `0383fde3ee55bceff2dbccbdf0a14195687471c12211822ad5f410a40c92e1e7`. Selected artifact `c5932ed` contains PR #84's callback-ingress classifier and has its own September 2 six-receipt result above. Its final process differed from the armed process, so the selected warm-background provenance gate remains incomplete | PARTIAL |
| Backend CI | PR #80 exact-head [run 33362188428](https://github.com/narenyenuganti/health-comp/actions/runs/33362188428) and post-merge `886bd60` [run 33364463074](https://github.com/narenyenuganti/health-comp/actions/runs/33364463074), PR #81 exact-head [run 33367099192](https://github.com/narenyenuganti/health-comp/actions/runs/33367099192) and post-merge `c3a8fb2` [run 33367877846](https://github.com/narenyenuganti/health-comp/actions/runs/33367877846), PR #82 exact-head [run 33371796629](https://github.com/narenyenuganti/health-comp/actions/runs/33371796629) and post-merge `7218065` [run 33412251604](https://github.com/narenyenuganti/health-comp/actions/runs/33412251604), and PR #84 exact-head [run 33563672310](https://github.com/narenyenuganti/health-comp/actions/runs/33563672310) and post-merge `c5932ed` [run 33566573121](https://github.com/narenyenuganti/health-comp/actions/runs/33566573121), completed successfully. The matrix includes static backend boundaries, migrations, policies, adversarial SQL, the full Deno matrix, pinned Edge Runtime verification, and secret/schema-diff guards | PASS |
| iOS CI | PR #80 exact-head [run 33362188433](https://github.com/narenyenuganti/health-comp/actions/runs/33362188433) and post-merge `886bd60` [run 33364463129](https://github.com/narenyenuganti/health-comp/actions/runs/33364463129), PR #81 exact-head [run 33367099142](https://github.com/narenyenuganti/health-comp/actions/runs/33367099142) and post-merge `c3a8fb2` [run 33367877833](https://github.com/narenyenuganti/health-comp/actions/runs/33367877833), PR #82 exact-head [run 33371796644](https://github.com/narenyenuganti/health-comp/actions/runs/33371796644) and post-merge `7218065` [run 33412251794](https://github.com/narenyenuganti/health-comp/actions/runs/33412251794), and PR #84 exact-head [run 33563672220](https://github.com/narenyenuganti/health-comp/actions/runs/33563672220) and post-merge `c5932ed` [run 33566573134](https://github.com/narenyenuganti/health-comp/actions/runs/33566573134), completed successfully. The PR #84 matrix passed deterministic generation, both Core configurations, 546 application tests, unsigned Debug/Staging/Release device builds, and the clean-tree check | PASS |
| Evidence publication | Evidence-only PR #27 merged as `2d2d5cf` without changing the then-selected pre-icon application artifact. Exact-head [Backend run 32027282748](https://github.com/narenyenuganti/health-comp/actions/runs/32027282748) and [iOS run 32027282728](https://github.com/narenyenuganti/health-comp/actions/runs/32027282728), followed by post-merge [Backend run 32030763547](https://github.com/narenyenuganti/health-comp/actions/runs/32030763547) and [iOS run 32030763718](https://github.com/narenyenuganti/health-comp/actions/runs/32030763718), completed successfully | PASS |
| Current evidence-main CI | Evidence-only PR #85 merged as `32c5df7ee4951ffa32965217d6c51ea4c07e10de`. [Backend run 33573624938](https://github.com/narenyenuganti/health-comp/actions/runs/33573624938) and [iOS run 33573624883](https://github.com/narenyenuganti/health-comp/actions/runs/33573624883) completed successfully on that exact commit on September 2 UTC; the September 4 takeover audit verified completed run/job metadata. These are recorded successful executions, not new reruns. Source is identical to selected build `c5932ed` outside the release ledgers. The hosted iOS job runs `HealthCompTests`; full XCUITest/release interaction evidence is a separate incomplete gate | PASS |
| App icon integration | PR #29 selected the supplied white 1024-pixel logo as AppIcon, retained all six supplied black and white source assets, removed only the opaque alpha channel from the selected icon, and passed exact-head [Backend run 32099524516](https://github.com/narenyenuganti/health-comp/actions/runs/32099524516) and [iOS run 32099524540](https://github.com/narenyenuganti/health-comp/actions/runs/32099524540). Those reviewed assets remain unchanged in selected artifact `c5932ed` | PASS |
| Terminal-invitation synchronization | PR #34 makes declined, expired, and cancelled descriptors prune only the matching local inventory item before materialization, while preserving the local journal and server-retained history. Focused runtime tests passed 22/22, including expired, declined, and cancelled cases; exact-head and post-merge CI passed. A corrected physical authenticated relaunch remained warning-free after a bounded refresh window | PASS |
| Remote Activity refresh isolation integration | Read-only hosted staging and offline profile-scoped inspection showed that a valid gap-free two-participant competition was durably materialized before its on-device Activity read failed, but the typed Activity failure was promoted to a fatal per-competition result. PR #62 application-source commit `1a2ddb535f938e0acce9ec255c209fcec0deb2ee` keeps that validated remote materialization visible, persists its server cursor, and reports a separate truthful Activity issue while leaving storage, outbox, App Attest, score-submission, cancellation, and server-contract failures fatal. The focused runtime/client, HealthKit-provider, and presentation matrix passed 91/91. Exact-source [Backend run 32634210205](https://github.com/narenyenuganti/health-comp/actions/runs/32634210205) and [iOS run 32634210213](https://github.com/narenyenuganti/health-comp/actions/runs/32634210213), final-head [Backend run 32635614190](https://github.com/narenyenuganti/health-comp/actions/runs/32635614190) and [iOS run 32635614199](https://github.com/narenyenuganti/health-comp/actions/runs/32635614199), and post-merge [Backend run 32636617904](https://github.com/narenyenuganti/health-comp/actions/runs/32636617904) and [iOS run 32636617875](https://github.com/narenyenuganti/health-comp/actions/runs/32636617875) passed. PR #62 merged as historical main candidate `0e08e2a`; integration passed, while its candidate runtime, physical HealthKit, and App Attest evidence remained incomplete at that point | PASS |
| Historical evidence publication | PR #36 merged the then-current Sign in with Apple receipt as `a45c325` without changing selected application commit `dd0ed68`. Exact-head [Backend run 32280929100](https://github.com/narenyenuganti/health-comp/actions/runs/32280929100) and [iOS run 32280929157](https://github.com/narenyenuganti/health-comp/actions/runs/32280929157), followed by post-merge [Backend run 32284529024](https://github.com/narenyenuganti/health-comp/actions/runs/32284529024) and [iOS run 32284529049](https://github.com/narenyenuganti/health-comp/actions/runs/32284529049), completed successfully. The receipt remains historical after selection later advanced through `6ee1d22` to `aa16411` | PASS |
| App Attest recovery and diagnostics integration | PRs #43, #45, #46, #47, #48, #51, and #52 serially integrated startup-race recovery, hosted-worker boot repair, the compatible verification graph, terminal rejection recovery, privacy-safe rejection diagnostics, corrected assertion-signature verification, and client-side submission serialization. PR #74 then added closed object, key, and signature-stage labels while preserving the same fail-closed response and acceptance boundary. Exact-head and post-merge Backend/iOS workflows passed through integrated commit `6dae97b` | PASS |
| Supabase transport | On pre-recovery transport baseline `21af9a7`, the focused transport/authentication/profile-isolation/API gate passed 52 tests and canonical local `HealthCompTests` passed 457/457; the integrated recovery matrix later passed the expanded 459-test canonical suite; CodeRabbit reported no findings | PASS |
| Historical signed Simulator staging | On reviewed PR #26 source whose application tree merged as pre-icon commit `ae28c6a`, existing profile-scoped data and authentication survived reinstall; authenticated staging requests returned HTTP 200; no `-1005` or missing-HealthKit-entitlement error appeared. This is historical transport evidence, not exact-current Simulator runtime | PASS |
| Historical Simulator preparation | At `2026-08-19T18:36:33Z`, then-selected application source `dd0ed68` was rebuilt from docs-only main `a45c325` as the Staging Simulator bundle. Offline inspection confirmed the staging bundle ID, expected public project URL, publishable-key shape, blank invitation host, custom-scheme fallback, and Xcode-generated simulated sandbox/development capability values without exposing credentials. The bundle over-installed on the dedicated tester, exactly matched the verified build, preserved all 19 pre-existing data-container files, remained stopped, and was shut down without contacting hosted staging. Its 1.5 GiB DerivedData was removed. This is historical preparation, not exact-current runtime evidence | PASS |
| Historical `6ee1d22` Simulator preparation | Then-selected application source `6ee1d22` was rebuilt normally for the dedicated iOS 18.4 staging tester after the earlier retained executable was found to lack its simulated-entitlement section. The corrected retained 44 MiB app has executable SHA-256 `ed61736fc205791ecb0aef5c167461130193012a68993a847bdea252917b9c4b`, passes strict code-signature validation, and contains the expected embedded Simulator entitlements. A state-preserving over-install retained the existing profile content; temporary DerivedData was removed. This proves signed preparation for that named historical artifact, while the separate runtime rows record what authenticated execution proved | PASS |
| Historical integrated-candidate Simulator launch | Historical main candidate `0e08e2a` was built as the exact staging Simulator bundle with frozen package resolution; its embedded simulated capability and public configuration boundaries were verified, and a state-preserving over-install retained one authenticated profile root with seven files. The installed executable matched SHA-256 `4308ed164cabe956eaa785038700c16968715cf1516e6e86be5492c622865df7`. The first explicitly approved launch action at `2026-08-23T18:11:40Z` exposed only a protected/blank surface and stopped before an attributable runtime result; its privacy-safe receipt SHA-256 is `cc8c28a12bbf1b2b5773c3e479972874de61cb9b74e67b3e13466faef035d6e4`. After an unrelated storage cleanup removed the complete Simulator device set, a targeted read-only Time Machine snapshot recovery restored only the dedicated tester and required registry. Independent validation matched the exact executable, one profile root, and seven files before a separately approved one-launch retry. That retry ran from `2026-08-23T21:36:23Z` through bounded termination at `23:29:26Z`, reached authenticated Sharing immediately, and retained `No Competition` plus `Some competition activity could not be refreshed.` A credential-free Simulator-to-staging TLS probe succeeded, but the process window contained 72 CFNetwork connection-loss / `-1005` markers and no precise HTTP status marker; warning-free authenticated transport is not claimed. After termination, the exact executable, single root, seven files, one five-envelope journal, and zero-entry inventory remained; only the inventory document changed, and no second profile root appeared. The recovery-retry receipt SHA-256 is `8dc3a1885446c373dd530f7d0a703af3e08a95270359220f35138a43874450d1`. After a fresh read-only preflight again passed credential-free staging TLS, a separately approved launch from `2026-08-24T00:38:44Z` through `00:41:24Z` recovered the same authenticated UI and consumed exactly one pull-to-refresh gesture. The immediate readback and bounded ten-second observation retained `No Competition` and the warning. The full profile tree remained byte-for-byte unchanged at one root, seven files, one five-envelope journal, zero inventory entries, zero outbox entries, and zero App Attest files. Predetermined log aggregates contained no `-1005`, `-7026`, missing-entitlement, or crash/fatal marker, but no precise attributable HTTP status marker. The pull-refresh receipt SHA-256 is `8ca2762c5a4acbb4b431f06ef1e65e174387129a8da0e26819db2c174cd7cedc`. This proves one fail-closed historical-candidate refresh attempt and continued profile isolation, not successful runtime execution of the Activity-isolation fix | PARTIAL |
| Account A hosted eligibility inventory | Following separate approval, one certificate-verified `psql` transaction ending at `2026-08-24T03:40:32Z` ran with repeatable-read, `READ ONLY`, statement/lock/idle timeouts, and explicit rollback. It returned exactly one active Account A profile, one accepted membership, one client-visible scheduled competition, exactly two participant rows for that competition, and one gap-free change log with zero gap-present competitions. The profile identifier remained an in-memory query parameter only. The 24-key aggregate receipt returned, displayed, and retained no identifier, name, Apple identity, token, score, Health datum, or row body; it is mode `0600` and has SHA-256 `e7af774da15905ebc3a7308237903c35fd8c365d9673a9fe60563c7ae28fe0b3`. This proves hosted eligibility and history integrity in that dated window, not authenticated app discovery, decoding, or materialization | PASS |
| Historical Account A staging runtime on then-main `224840e` | Exact then-merged main `224840e` built with frozen package resolution, state-preservingly over-installed on the dedicated staging Simulator, and matched the installed arm64 executable slice. Exactly one launch and one Account A pull-to-refresh settled on authenticated Sharing with one competition, no sign-in prompt, and no refresh error. The app terminated, the Simulator returned to Shutdown, and aggregate local persistence retained three competition-event files and two server-cursor files. Receipt SHA-256: `66eef307a8c9744d2e10313cb3a6d8a2640b95112fd29bbd21b0a29492161fae`. No identity, token, private identifier, score, Health value, screenshot, hosted write, account switch, invitation, physical-device, or production action was retained or performed | PASS |
| Fail-closed sign-out integration and named-source staging retry | PR #70 merged the reviewed fail-closed sign-out change as application source `fb55f93`; evidence-only main `1d73abe` preserves that application tree. The final local suite passed 488/488, unsigned Staging and Release builds passed, the secret/diff checks passed, and both required hosted workflows passed. The first configured runtime artifact was incorrectly reused from the unsigned compile gate and had no Mach-O `__entitlements` section; its immediate Apple `-7026` / AuthenticationServices `1000` failures are artifact-selection evidence, not an Account B Apple-service defect. A normal frozen-package Staging build from then-current exact main produced a strictly valid locally signed artifact with the expected Simulator entitlements. It first restored the distinct Account B session into one nine-file profile root, one active competition, and a warning-free Sharing UI. In the later sequence ending at `2026-08-25T01:49:39Z`, user-requested sign-out first retired the remote installation and received the global logout response. Local SDK removal verification then failed closed: the app exposed no signed-out state, activated the identity-free removal tombstone, and showed the retry surface. Profile storage was already zero roots and zero files. The designed recovery suppressed the stale credential and reached Welcome. Exactly one fresh native Account B authorization completed through human password entry, cleared the tombstone, returned to warning-free Sharing with one active competition, and mounted exactly one root with nine files. The bounded aggregate contained zero connection-loss, Apple-auth-failure, missing-entitlement, crash/fatal, and non-2xx markers. Termination left zero app processes and the same one root/nine files before Simulator shutdown. Receipt SHA-256: `edf7b209cd193f267021365aaffa73eebf505c855ec6327666a207b90e882d45`; it retains no identity, credential, token, private identifier, score, Health datum, or screenshot | PASS |
| Historical `6ee1d22` Simulator launch | Following explicit approval, exact staging bundle `com.narenyenuganti.HealthComp.staging` launched once from `2026-08-22T23:55:00Z` through `23:55:30Z`, settled on the clean welcome screen, and was terminated. Sign in with Apple was not pressed; no in-app action occurred. The data-container count remained 23 files and the post-window process count was zero. The bounded log contained two occurrences of Supabase Swift v2.55.1's advisory initial-session warning and two successful network-activity completion markers, but no retained HTTP status marker. Pinned-source inspection confirms that warning is emitted by the SDK's default initial-session path and does not itself prove refresh failed. The receipt cannot distinguish an already-absent session from one removed during terminal refresh. The preserved profile root remained unmounted, maintaining fail-closed cross-profile isolation. This is not authenticated staging transport or Account B profile-mount evidence | PARTIAL |
| Historical `6ee1d22` Account B native authentication and isolation | In one user-approved sequence ending at `2026-08-23T01:46:25Z`, then-selected source `6ee1d22` signed out the recovered Simulator session only after remote installation teardown completed, reached Welcome, and reduced local profile storage to zero roots and zero files. Exactly one native Account B Sign in with Apple attempt then completed under human credential entry and reached authenticated Sharing with `No Competition`. The new session mounted exactly one profile root with seven files, including one preserved four-envelope history journal; no second profile root was present. The bounded process log contained 39 HTTP 200 and one HTTP 204 markers, with zero non-2xx, `-1005`, `-7026`, or missing-entitlement markers. The single root and seven files remained after termination. The privacy-safe receipt SHA-256 is `5cf006c7918165373d15679a9cfcbb6988fcae68dc97c0c68b5efb0e07750f08`; it retains no identity, token, private identifier, screenshot, HealthKit value, or credential. The UI still reported `Some competition activity could not be refreshed.`, so this passes native authentication and profile-root isolation for that named artifact but not warning-free historical refresh | PASS |
| Historical `6ee1d22` Account A recovery after Account B | In a separately approved sequence ending at `2026-08-23T08:36:05Z`, then-selected source `6ee1d22` first completed Account B's server-confirmed HealthComp sign-out and read back zero profile roots and zero profile files. The Simulator's Apple session was then changed under human credential entry to the earlier Account A. Exactly one native HealthComp Sign in with Apple attempt completed, the user completed the HealthKit authorization sheet, and authenticated Sharing settled at `No Competition`. Account A mounted exactly one profile root with seven files and one preserved five-envelope history journal; no second root was present. The ten-minute process-log aggregate contained 118 HTTP 200 and two HTTP 204 markers, with zero non-2xx, connection-lost / `-1005`, `-7026`, or missing-entitlement markers. The sole root and seven files remained after termination. The privacy-safe receipt SHA-256 is `7bdb11a5e30aa71ea1bb8710d3ef0bc5b5bfdd91d61b42bcd184c694fe59e8fe`. This strengthens historical sequential account isolation and native authorization for that named artifact, but the UI retained `Some competition activity could not be refreshed.` and no active competition was recovered | PASS |
| Realtime recovery integration | PR #26 pins Supabase Swift 2.55.1, passed the 90-test focused recovery matrix and 459/459 canonical app tests, passed 241/241 CompetitionCore tests in both Debug and Release, built unsigned Debug/Staging/Release device configurations, generated the project deterministically, and received a zero-finding CodeRabbit source review. A signed Staging Simulator over-install left the data-container file count unchanged at 19, restored the authenticated Sharing UI, and produced 42 process-local HTTP-200 markers with zero `-1005`, HealthKit-entitlement, or crash markers from `2026-08-17 02:46:15.068` through `02:49:22.348` PDT. Early hosted attempts exposed and closed cross-Xcode resolved-file omissions, then exposed the cancellation actor-hop race. The strengthened race passed 100/100 locally and exact-head hosted run `32020898831` passed the complete matrix. PR #26 was guarded-squash-merged as pre-icon application commit `ae28c6a`, whose tree is identical to the reviewed PR head. PR #29 later added only the reviewed app-icon assets and selected `9d19937`. No invitation action occurred | PASS |
| Staging database parity | A historical linked audit proved fourteen ordered, identical local/remote migrations through `20260811000900`; its `2026-08-16T05:34:16Z` dry run returned `up to date`. The retained `2026-08-21` rollout receipt then records a linked dry run proposing exactly `20260822001000_add_pre_ios27_app_attest_compatibility.sql`, successful application, and gap-free post-deployment readback through `20260822001000` with every local and remote version paired exactly once. The CLI was unlinked afterward. Receipt SHA-256: `c086a75e402df327465e8cfd950a0fd52b961cd2d53e9c3b18c5ab53c2ca5b05` | PASS |
| Production project inventory | A read-only CLI audit ending at `2026-08-23T06:06:35Z` found the dedicated `healthcomp-production` project active and healthy in the same organization as staging, with zero deployed Edge Functions and zero configured secret names. The repository remained unlinked; no API key, database password, secret value, migration history, provider setting, or private row was requested or retained. The privacy-safe receipt SHA-256 is `df6cf08bbbc13ab6b9b50abb770e366eadb5b023edbfbba7823976453930c497`. This proves project existence only, not configuration, promotion, backup availability, or release readiness | PARTIAL |
| Hosted finalizer | Exact private `healthcomp-finalize-due` job; first corrected run succeeded at 2026-08-16 04:00 UTC | PASS |
| Notification repair | Exact private one-minute job; HTTP 200 worker response and zero unresolved work at readback | PASS |
| Staging build inputs | Exact staging bundle, expected public Supabase URL, nonempty ignored publishable key, blank invitation host, development App Attest setting | PASS |
| Paid-team provisioning | Staging development profile for team `23LUYD78QK`, expiring `2027-08-16T05:23:35Z` | PASS |
| Profile entitlements | Sandbox APNs, Sign in with Apple, HealthKit, HealthKit background delivery, and App Attest authorized | PASS |
| Selected signed build | Automatic paid-team signing produced selected artifact `c5932ed` as a retained 23,180 KiB Staging device build with frozen package resolution. The profile expires `2027-08-16T05:23:35Z` and authorizes exact App ID `23LUYD78QK.com.narenyenuganti.HealthComp.staging`, sandbox APNs, Sign in with Apple, HealthKit with background delivery, and development App Attest. Strict validation passed; executable SHA-256 is `1658b606f986ce39fc878673fc3b5b7e7fe495e72f386109be1181f4397a6e71`; package-lock SHA-256 is `436fe2d4c83e2e7bbe1f236afb6dcb81b0d5b530e4fa75aaf920a6da51519a21`; build receipt `physical-current-build-c5932ed-2026-09-01T232030Z.json` SHA-256 is `c98c3880971fbc0c02f3402b95ca5f85096243ce75d6f71222e5958602fa23a4`. Scratch and the copied local configuration were removed while the root configuration was preserved | PASS |
| Selected physical install | The September 2 selected `c5932ed` receipt above proves exact state preservation through physical over-install and one authenticated retained-session launch. It supersedes the build-time not-yet-installed status without transferring older-artifact service evidence | PASS |
| Historical `6ee1d22` physical launch windows | Five separately approved `6ee1d22` windows each launched exactly once and ended without an in-window retry. The first showed authenticated Sharing with `Some competition activity could not be refreshed.` The second had no iPhone Mirroring window and is classified only by process, local, and hosted evidence. The third cold-launched to signed-out Welcome without pressing Sign in with Apple; local counts and bounded App Attest/score Function invocations were unchanged. The fourth initiated one native Apple-auth transition but returned to Welcome without a session. The fifth launched at `2026-08-23T07:08:39Z`, initiated exactly one native Apple-auth action at `07:09:19.909Z`, received direct user confirmation of sign-in, retained one running app process for the bounded readback, and was then terminated with zero HealthComp processes remaining. The fifth receipt SHA-256 is `f6decf0e161e306ab6f340db88e0c0edf50e3fe6fa297e1a3a05d1456aed0441`. No screenshot or private value was retained | PASS |
| Sign in with Apple | Then-selected artifact `aa16411` initiated exactly one native Sign in with Apple authorization; after the user handled the system prompt, Mirroring reconnected to warning-free authenticated Sharing. A post-confirmation privacy-safe local readback found one profile-scoped root with ten aggregate files. Receipt SHA-256: `335d7d21535667540a601c56819412c5ddd361817ac10f6c294306c6feeaf9c9`. Previously selected artifact `c3a8fb2` then preserved and restored that physical session through a state-preserving over-install without a sign-in prompt or warning. Historical receipt SHA-256: `0383fde3ee55bceff2dbccbdf0a14195687471c12211822ad5f410a40c92e1e7`. Neither receipt retains identity, token, private identifier, Health value, score, request material, or screenshot. Selected artifact `c5932ed` has its own September 2 retained-session continuity receipt, but fresh native authorization remains pending | PARTIAL |
| Authenticated refresh | Historical receipts localized the generic activity warning to terminal-descriptor handling and then to an on-device Activity-read failure masking otherwise valid remote materialization. PR #34 and PR #62 corrected those boundaries. Exact merged main `224840e` then completed one Account A pull-to-refresh with one authenticated competition, no sign-in prompt, and no refresh warning. Later application source `fb55f93` subsequently restored Account B to the same warning-free one-competition state and repeated it after server-confirmed sign-out, zero-root teardown, and exactly one fresh native authorization. Both named-source receipts mounted exactly one isolated profile root and retained zero selected connection-loss, Apple-auth-failure, missing-entitlement, crash/fatal, or non-2xx markers. This passes warning-free authenticated refresh for both named Simulator-account receipts; it does not replace physical HealthKit/App Attest/APNs/background evidence or the remaining two-account lifecycle | PASS |
| APNs registration | On historical physical build `1ca67af`, iOS authorization completed and a read-only staging query returned exactly one `sandbox` / `active` installation updated at `2026-08-16T07:04:49.701324Z`; no installation, profile, or token identifier was selected. Registration and foreground/background/cold delivery on selected release artifact `c5932ed` remain pending | PARTIAL |
| HealthKit startup, foreground submission, observer-callback durability, and background wake | The physical iPhone completed grant, revoke, and re-enable startup paths historically. On prior artifacts, the app reached one active competition with a visible derived score and submitted one HealthKit-derived revision through App Attest. Previously selected artifact `c3a8fb2` durably recorded six issue-free positive-revision callbacks under the pre-fix provenance contract. Selected `c5932ed` now has six new clean positive-revision background-classified receipts under the corrected classifier, but failed process continuity keeps its full background-wake gate incomplete. Fresh selected-artifact authorization and foreground accepted submission remain pending. This ledger retains no Health value or score | PARTIAL |
| Historical App Attest acceptance and replay | After the earlier iOS 26.6 rejection was classified and fixed by PR #76, then-selected signed artifact `aa16411` accepted one derived revision. Exact consumed-challenge and consumed-grant replays failed closed without changing hosted aggregates. Receipt SHA-256: `efb3ebf8dc877efc62fc9f682484e12116dd92a133c6a9d659a1dba5a6646f44`. No identity, token, identifier, score, Health value, proof material, or screenshot was retained. Selected artifact `c5932ed` has physical installation and retained-session evidence but no attributable accepted foreground assertion receipt; selected-artifact acceptance and replacement-installation enrollment remain pending | PARTIAL |
| Hosted staging preflight | A SELECT-only audit ending at `2026-08-17T07:12:08Z` found two active profiles, two active sandbox installations, two pending competitions, two live unclaimed invitations, zero consumed invitations, and a pending distribution of `[0,2]` across the active profiles. It also found zero App Attest keys, account-deletion records, daily-score revisions, and competition results. No identifier, token, digest, account detail, private screenshot, or HealthKit value was selected or retained | PASS |
| Staging database adversarial boundary | At `2026-08-20T01:18:06Z`, exact reviewed verifier commit `4fca597757befafc9ed10cafecc4af4b73e65026` ran against `healthcomp-staging` after SSL enforcement was enabled and read back. The certificate-verified session passed 15/15 database assertions, explicitly rolled back, independently found zero synthetic rows remaining, and returned no private values. The sole nonblank privacy-safe receipt has SHA-256 `852fc2d64c0daa93677726cda4fdddf4acd088b68884aa247939188f408660af`. This is database-boundary evidence only; the consumed replacement-invitation replay is separately PENDING below, while the sequential-Simulator receipt below proves the profile-root isolation boundary | PASS |
| Consumed replacement-invitation replay | The consumed replacement-invitation token was not retained, so that historical token cannot supply the required replay receipt. The rollback-only synthetic verifier does not substitute for this lifecycle check. Create exactly one fresh transient staging invitation, consume it once, replay it once, and retain only privacy-safe aggregate evidence | PENDING |
| Staging expired-invitation cleanup | After both invitations expired, a privacy-safe snapshot returned exact count `2` and opaque scope SHA-256 `0ebe0077d5312b7245ce55065dc2d30437e1af052f14ae98ee391af92542f314`. Following action-time approval, the reviewed guard ran as one explicit serializable transaction through the authenticated Supabase Management API database-query route rather than `psql`; it retained the approved scope checks, timeouts, service-role request claim, cleanup-count assertion, and explicit commit. Dedicated read-only route readback at `2026-08-19T04:16:02.604717Z` found zero pending competitions, two expired competitions, two retained invitation-history rows, zero claimed or consumed invitations, and zero remaining eligible invitations. No identifier or token was selected, no lifecycle row was edited directly, and no replacement invitation was created | PASS |
| Historical staging replacement invitation | Following fresh action-time approval, then-selected artifact `dd0ed68` created exactly one replacement invitation on the isolated Simulator endpoint. The same opaque custom-scheme link cold-launched that physical artifact and was accepted once. Read-only hosted readback ending at `2026-08-19T21:56:37Z` found one scheduled replacement competition, exactly two participant rows, and exactly one corresponding invitation row with claimant and consumption time present. Both endpoints converged on the scheduled competition after controlled relaunch. No token, identity, private identifier, screenshot, raw HealthKit datum, or exact Activity value is retained; this is not universal-link evidence | PASS |
| Invitation Function route continuity | Application source `dd0ed68` routes live invitation creation through `create-competition-invite` and claims through `claim-competition-invite`; those route boundaries remain present in selected artifact `c5932ed`. The then-selected artifact completed both actions above, and the hosted state records their create/consume effects. A read-only dashboard readback at `2026-08-20T02:32:28Z` reported exactly one invocation since the last deployment and no errors for each Function. No new request was sent, and no token, identity, request body, Function identifier, or execution identifier was retained | PASS |
| Historical sequential Simulator profile isolation | In a user-approved Account A to signed-out to Account B sequence ending at `2026-08-20T05:56:37Z`, then-selected artifact `dd0ed68` first mounted one Account A profile with three competition-journal files, two server cursors, one installation file, and no outbox, notification-preference, or App Attest file. After server-confirmed installation retirement, sign-out reached the clean welcome screen, reduced `Profiles/v1` to zero profile directories and zero profile files, and moved the aggregate sandbox installation state from two active / three revoked to one active / four revoked while the physical phone was untouched. A distinct Apple account then authenticated directly through HealthComp without enabling full Simulator iCloud sync. The app mounted exactly one Account B root, displayed the prior participant only as the legitimate scheduled opponent, and contained three server-rematerialized competition files, two cursors, one newly active installation, and zero outbox, notification-preference, or App Attest files. Aggregate hosted readback returned two active / four revoked installations. The same profile-transition test remains in the exact-current suite, seeds a private prior-profile outbox, and proves it is absent after teardown and the next profile mount. No Apple account, profile or installation identifier, token, local fingerprint, private screenshot, raw HealthKit datum, or exact Activity value is retained | PASS |
| Two-account staging convergence | Invitation creation, controlled custom-scheme delivery, cold acceptance, single consumption, two-participant membership, and scheduled-state convergence passed historically on the approved physical-iPhone-plus-Simulator topology. Then-selected physical artifact `aa16411` later persisted two accepted score revisions across two days from one participant. On historical integrated main `224efcb`, the retained verified Account B Simulator executable launched once into warning-free authenticated Sharing and materialized the opponent's accepted aggregate score while retaining exactly one nine-file profile root. Hosted counts remained two revisions from one profile, one competition, and two days; no Account B score, finalization attestation, or result was created. The app terminated and the Simulator shut down. Receipt SHA-256: `e12fd592672636894d5a0b73724273d1dc3d0768d9a80a922aab5282405a2dfb`; it retains no identity, credential, token, identifier, score value, Health value, or screenshot. Seven-day two-participant scoring, finalization/results, and the remaining lifecycle cases are incomplete | PARTIAL |

## Integrated observer-delivery provenance correction

Reviewed source commit `76b797d`, integrated through PR #84 as merge commit
`c5932ed`, roots a fail-closed lifecycle classifier at the process. Unknown,
initial inactive, and initial background states remain foreground; background
is recognized only after this process observed active-to-background; will-enter-
foreground clears background synchronously. The observer trigger is snapshotted
before any controller lock, hook, or async yield. Both observer triggers retain
completion ownership and persist through the unchanged schema-v1 protected
receipt, while non-observer triggers remain invalid.

Local verification passed 546/546 application tests, 241/241 CompetitionCore
tests in Debug and Release, unsigned Debug/Staging/Release device builds,
deterministic XcodeGen, an unchanged package lock, secret/layout guards, and
independent standards/spec reviews with no Critical or Important findings. The
deployed `BackgroundDelivery` directory,
`background-delivery-receipts.v1.json` filename, temporary-file prefix,
five-field schema, retention, durability, privacy validation, and teardown
behavior remain unchanged. Exact-head Backend and iOS CI passed on PR head
`b2bc965`; post-merge Backend and iOS CI passed on exact merge commit
`c5932ed`; evidence-only main `32c5df7` subsequently passed both hosted CI
workflows. Those automated/build receipts prove their named scopes. The
September 2 physical receipts separately establish selected installation,
retained-session launch, and six clean new background-classified receipts,
while the full same-process background-provenance gate remains incomplete.

## September 4 read-only hosted inventory

Receipt `hosted-release-readonly-inventory-2026-09-04T213741Z.json` has SHA-256
`bbb263d9c3036fb8b20a70df78cf1c25c5c12da53cd8a0377dacd1a5c7519a42`.
It used existing CLI authentication and SELECT-only aggregate queries; no
password, identifier, row body, device access, or hosted mutation was involved.

Staging was `ACTIVE_HEALTHY`, with nine `ACTIVE` Functions including
`submit-score-revision` version 11, and fifteen applied migrations. Production
was `INACTIVE`, superseding only the August 23 project-status observation.
Staging had two active profiles, zero anonymized profiles, three competitions,
zero unfinished competitions, one completed/archived competition, zero overdue
unfinalized competitions, two accepted revisions from one distinct submitting
profile, zero final-window attestations, one `best_available` result, zero
stable results, one award, and one consumed invitation.

The aggregate counts do not identify which account submitted. They establish
that the existing competition reached a result, but do not prove both accounts'
own accepted scores or the complete seven-day lifecycle. No active competition
exists on which waiting alone can close those missing gates. Preserve the
completed shared history and plan the remaining two-participant scoring and
lifecycle evidence before deletion or replacement.

The backup list was empty and PITR was disabled; restore rehearsal remains
unpassed. Plan entitlements/pricing were not verified. Function `ACTIVE` is
deployment inventory, not invocation or delivery evidence. Scheduler health,
notification delivery, authenticated app sessions, physical services, and
production configuration/promotion were not exercised.

## What the physical receipt proves

The historical physical receipts prove that then-selected source commit
`6ee1d2260cfcbe02a950630ef979076c317eca49` can be built with frozen package
resolution, signed by the paid team, strictly validated, and over-installed on
the paired iPhone without erasing the profile-scoped container. The stable
profile subtree remained 17 entries, seven directories, three outbox files,
one App Attest state file, three competition files, and two server cursors.
Each separately approved window launched exactly once and stopped without an
in-window retry. The first showed authenticated Sharing with a competition-
refresh warning; the second lacked an iPhone Mirroring window and is classified
only by process, local, and hosted evidence. The third reached signed-out
Welcome and a passive ten-second refresh did not recover a session. Sign in
with Apple was not pressed, local profile-scoped counts were unchanged, and the
bounded dashboard readback showed no new App Attest challenge or score Function
invocation. The fourth reached Welcome, initiated one native Apple-auth
transition, returned to Welcome without an authenticated session or a retained
credential/two-factor prompt, and preserved the same profile-scoped counts. No
private screenshot was retained. The third window is a signed-out no-attempt
receipt; the fourth is a native-attempt/no-session receipt. A fifth bounded
window launched once, initiated one native Apple authorization action, and the
user directly confirmed sign-in after handling the system prompt. A privacy-
safe post-confirmation readback found one profile-scoped root and ten aggregate
files; the process was then stopped and the temporary copy moved to Trash. The
mirror became privacy-black and interrupted during the system transition, so
the fifth receipt contains no authenticated-screen screenshot or hosted auth-
log evidence. It proves `6ee1d22`'s physical native-authorization gate, not
warning-free refresh or another platform-service gate for the then-selected
artifact `aa16411`. Previously selected artifact `c3a8fb2` was subsequently
installed and restored authenticated Sharing, but it did not initiate a fresh
native authorization in that bounded window. Current selected artifact
`c5932ed` subsequently passed its own September 2 state-preserving install and
authenticated retained-session launch; fresh native authorization remains pending.

The second controlled window proves the client successfully reached hosted
profile bootstrap, installation registration, competition listing, and change
fetches over HTTP 200 plus Realtime over HTTP 101 without creating a score
revision. Staging
retained four challenges, one consumed challenge, one key, one grant, one
consumed grant, and one accepted score revision. In that historical version-9
window, the sole Function invocation remained the pre-launch credential-free
boot probe. The profile-scoped outbox retained four terminal score revisions
and no pending retry. The available evidence does not distinguish an unchanged
Day 2 wire
from a HealthKit summary-read failure because neither decision is persisted.
This is a fail-closed no-new-score-revision receipt, not App Attest acceptance
or a new classified rejection.

Then-selected artifact `dd0ed683a78de216f622e2a958baeda1cb996e46`
historically proved authenticated Sharing, a warning-free refresh, and fresh
native Sign in with Apple on the physical phone. Prior artifact
`9d199377f5d72cb7bc90133c190e4e7681abfb41` proved fresh selected-icon
rendering and native Health Access approval. Broader source
`1ca67af76b738bd7fbb19277b238b448a555f8ef` proved initial paid-team signing,
native authentication, staging profile bootstrap, and sandbox installation
registration. Commit `cb21189` separately remains lineage evidence for the
earlier version-7 no-new-event attempt. These remain historical capability
receipts only after selection later advanced through `aa16411` and `c3a8fb2`
to selected artifact `c5932ed`.

No retained receipt contains an account identity, authorization payload, token,
private screenshot, raw HealthKit datum, exact Activity value, device
identifier, challenge identifier, or App Attest material. The successful
`aa16411` App Attest receipt proves active-competition HealthKit-derived
submission,
physical App Attest acceptance, durable persistence, and consumed challenge/
grant replay rejection. Previously selected `c3a8fb2` evidence proves physical
observer-callback durability during one manual foreground launch, but its six
pre-fix background-labelled receipts are excluded from attributable HealthKit
background-wake evidence. Source commit `76b797d` corrects that classification
boundary and is integrated in selected artifact `c5932ed`. The September 2
selected-artifact receipts prove installation/retained-session continuity and
six clean new background-classified callbacks, with the full gate false because
process continuity was unproven. Current evidence also does
not prove fresh selected-artifact Sign in with Apple, foreground HealthKit
submission, a selected-artifact App Attest assertion, APNs foreground/background/
cold-route delivery, deletion, or the same-phone replacement lifecycle and
replacement App Attest enrollment.

## Immediate continuation

1. Revalidate selected artifact `c5932ed` and current phone/profile/process
   state; do not reinstall solely because the old build-time record predates
   the successful September 2 installation. Establish a fresh foreground-to-
   background process and sealed post-transition receipt baseline. Coordinate
   one real Watch save with immediate readback; compare signal identities only
   in memory and accept only new issue-free, positive-revision
   `observerWakeupBackground` receipts with the same process and unchanged
   preexisting receipts. Retain aggregate facts and artifact provenance only.
   The previous armed baseline and six pre-fix `c3a8fb2` labels cannot qualify.
   If process continuity fails again, investigate the procedure before asking
   for repeated physical events. Fresh selected-artifact Sign in with Apple,
   foreground accepted HealthKit submission, and App Attest evidence remain pending.
2. Continue APNs foreground/background/cold-route evidence on selected artifact
   `c5932ed`.
3. Continue the adversarial matrix above the proven database and sequential-
   Simulator profile-root boundaries plus current-source Function-route
   continuity supported by the historical `dd0ed68` runtime receipt. The old
   consumed invitation token was not retained; use one fresh transient
   invitation for a consume-once/replay-once privacy-safe receipt within the
   authorized staging workflow, then finish the remaining lifecycle isolation
   cases. The September 4 aggregate readback found no unfinished competition;
   waiting alone cannot supply both accounts' own accepted scores. Preserve the
   completed result while preparing the missing scoring/finalization lifecycle.
4. Continue deletion and same-phone replacement-installation gates in the
   checked-in order.

## Explicitly unresolved

- Named-source application commit `fb55f93` supplied the retained Account B
  Simulator receipt; current integrated evidence main is `32c5df7` with reviewed
  application source `76b797d`. The prior `224840e` Account A pull-to-refresh
  remains a passing
  receipt for its named source. PR #70 added server-first global logout, verified
  local session removal, and relaunch-safe stale-session suppression. The first configured
  runtime attempt mistakenly used an unsigned compile-gate artifact with no
  embedded Simulator entitlements; its `-7026` / `1000` failures do not indict
  the Apple Account. The corrected normally signed artifact contains the
  expected embedded entitlements and restored Account B into one isolated root
  with nine files, one active competition, and no refresh warning. For named
  source `fb55f93`, restored-session isolation, server-confirmed user-requested
  sign-out, fail-closed stale-credential suppression, and one fresh native
  Account B reauthentication pass. Physical-service repetition remains pending.
- The separately approved
  Account A state-preserving staging over-install, single launch, and single
  pull-to-refresh recovered one authenticated competition with no sign-in
  prompt or refresh warning. This closes the prior Account A discovery/
  materialization defect but does not complete the full two-account lifecycle,
  physical HealthKit/App Attest/APNs/background-wake gates,
  deletion, replacement installation, restore rehearsal, or production.
- A partial two-account staging E2E receipt exists on then-selected artifact
  `dd0ed68`: it created exactly one replacement invitation, the physical endpoint
  cold-accepted it once through the controlled custom scheme, hosted staging
  records one consumed invitation and exactly two participants, and both
  endpoints show the same scheduled competition. The remaining lifecycle and
  isolation matrix is not complete.
- The replacement invitation is consumed and the competition started on
  `2026-08-20` in its frozen `America/Los_Angeles` time zone. Historical
  `6ee1d22` generated no changed Day 1 wire snapshot or accepted score; the
  earlier two expired invitation-history rows remain retained.
- Historical source `6ee1d22` was previously installed on the physical iPhone
  and stopped. Its corrected historical Simulator executable matched the
  retained signed build. The named-source Account B native authorization
  passed: prior profile
  teardown reached zero roots and zero files, Account B mounted exactly one
  root, authenticated transport returned only HTTP 200/204 status markers, and
  the UI showed `No Competition`. One four-envelope Account B history journal
  remains preserved and the historical-activity refresh warning persists.
  That historical artifact's native authorization on the physical phone has
  one bounded, user-confirmed PASS receipt. The mirror did not provide a post-
  authenticated UI readback, so warning-free refresh remained unresolved for
  that receipt. Current selected-artifact evidence is recorded separately below.
- The rollback-only hosted database adversarial receipt passed 15/15 with zero
  residue, current-source create/claim route continuity is proven while the
  successful runtime receipt remains historical, and sequential Simulator
  profile-root teardown/remount now passes with remote installation retirement
  and re-registration. The consumed replacement-invitation replay is PENDING
  because its historical token was not retained; the required receipt can use
  one fresh transient invitation consumed once and replayed once. The remaining
  lifecycle isolation cases remain unresolved.
- Previously selected artifact `c3a8fb2` is signed, retained, and was installed
  over then-selected artifact `aa16411` without erasing profile state. One launch
  restored warning-free authenticated Sharing and terminated cleanly. It did not
  perform fresh native authorization or an App Attest submission in that window.
  Selected artifact `c5932ed` has its own September 2 physical install and
  authenticated retained-session launch receipt; it still lacks fresh native
  authorization and foreground accepted-score/App Attest evidence.
  Historical `6ee1d22` windows showed the competition-refresh warning, signed-out
  Welcome, and native-attempt/no-session boundaries. Then-selected artifact
  `aa16411` later completed one user-confirmed fresh native Sign in with Apple
  action; a separate `aa16411` launch reached warning-free authenticated Sharing,
  displayed an active HealthKit-derived score, and accepted one revision through
  App Attest.
- The first two historical `6ee1d22` App Attest launch windows produced no new score
  revision or hosted submission request. The second completed remote
  reconciliation, but its evidence cannot distinguish an unchanged privacy-safe
  wire from a HealthKit summary-read failure. The third `6ee1d22` window was
  signed out and made no App Attest challenge or score Function request, so it is
  a no-attempt receipt. A later `aa16411` physical receipt accepted one revision and proved
  consumed challenge/grant replay rejection. Previously selected `c3a8fb2` did
  not make an App Attest submission in its bounded window; selected `c5932ed`
  lacks an attributable accepted foreground assertion receipt, and replacement-installation
  App Attest enrollment remains pending.
- One bounded background-observer attempt on then-selected artifact `aa16411`
  found no legacy marker and remains historical. Integrated candidate `886bd60`
  resolved the independent durability and isolation findings. Previously selected
  `c3a8fb2` then persisted six unique, issue-free, positive-revision physical
  observer-callback receipts under that commit-before-completion contract during
  one manual foreground launch. Callback durability passes, but those pre-fix
  background-labelled receipts are excluded from provenance. `76b797d` supplies
  the automated fail-closed classification fix and is integrated as `c5932ed`
  with exact-head and post-merge CI passing. Selected artifact `c5932ed` passes
  signed offline validation and its September 2 install/retained-session gate.
  Six new clean background-classified receipts passed the app-side subset, but
  final process replacement left the full provenance gate false. A fresh
  baseline and same-process physical receipt remain pending. No APNs
  delivery, deletion, or same-phone replacement-installation receipt exists.
- Universal-link evidence is explicitly deferred for this private-beta
  boundary because no HTTPS invitation domain will be provided. Only the
  controlled custom-scheme fallback may be exercised or claimed.
- Backup restore is not rehearsed against a disposable hosted target.
- The August 23 production inventory found the dedicated project healthy with
  no deployed Functions or configured secret names. The September 4 project
  inventory supersedes that health status with `INACTIVE`; current production
  Function and secret-name inventories were not refreshed. Production has not
  been promoted.
- The product is not production-ready.
