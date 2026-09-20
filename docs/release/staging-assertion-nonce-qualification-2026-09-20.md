# Staging assertion-signature qualification — September 20, 2026

This checkpoint covers automated qualification and one staging Function
promotion. It does not close the physical assertion or production-release gates.

## Source and automated evidence

- [PR 100](https://github.com/narenyenuganti/health-comp/pull/100) merged as
  `e78aadc23f03c0e6181f75928db322bba4773b7a` after the approved read-only reviewer
  found no Standards or Spec findings and both exact-head workflows passed.
- Parent: `3100604a0667facbe2c68ba3041c3a09cf1a3bfe`. The merged Git tree equals
  reviewed head `38d4fd037a68e0f0f93eb0475f7fe38aa41a20ce` exactly:
  `1cd6435ef04beeba1c2b1ad594c88a4bf37710cf`.
- Exact-main [Backend CI](https://github.com/narenyenuganti/health-comp/actions/runs/35494931704)
  passed: 787 pgTAP assertions, rollback verifier 15/15 with zero residue,
  136 Deno passes with one intentional initial ignore, separate invitation
  tests 13/13, and the pinned Edge Runtime public assertion/attestation probe.
  Repeated execution of the same database suite is not a second set of tests.
- Exact-main [iOS CI](https://github.com/narenyenuganti/health-comp/actions/runs/35494931702)
  completed successfully at `2026-09-20T08:02:52Z`: Core 246/246 in each of
  Debug and Release, application logic 628/628, Staging 54/54, unsigned device
  builds in Debug/Staging/Release, project/browser/privacy checks, clean-tree
  verification, and dedicated Simulator cleanup. This does not assert a full
  interaction/UI-test pass or physical-device behavior.

Separate dated fixture evidence is retained in the continuation workspace's
`invitation-copy-full-ui-2026-09-14.md`: all 24 declared DEBUG UI tests passed
on `ee866581e07267f24a73ed99269dfd94cc9c4321`, with no failures/skips/expected
failures. A fresh Git comparison confirms the application, UI tests, project,
modules, and configuration are unchanged through `3100604` and `e78aadc`.
The original temporary result bundle is no longer present, so it could not be
reparsed in this audit. This is the dated fixture receipt and source-continuity
evidence, not a new test run or live staging/physical interaction qualification.

The fix verifies the nonce message and has no fallback to the incorrect
signature convention. The positive assertion fixture is independently published
test data, not an official Apple assertion fixture or HealthComp device proof.
See the [implementation plan](../plans/2026-09-19-app-attest-assertion-nonce.md).

## Exact staging promotion

Fresh readback selected `healthcomp-staging` (`xhfdfdrtxwptrwhvvlhg`) in
organization `bfglsgxxjnmaeqjlztzi`, `us-west-2`, `ACTIVE_HEALTHY`, PostgreSQL
17.6.1.155. A clean, unlinked purpose-named worktree at the exact merged commit
was used. The dirty root checkout was preserved.

The first API deployment omitted the shared import map and failed bundling on
bare import `cbor`. Independent readback confirmed version 13 remained active
and no other Function version changed. The corrected command used the existing
reviewed map without changing source or dependencies:

```sh
supabase functions deploy submit-score-revision \
  --project-ref xhfdfdrtxwptrwhvvlhg --use-api --jobs 1 \
  --import-map supabase/functions/deno.json
```

Only `submit-score-revision` advanced from version 13 to active version 14.
All twelve Functions remained active, and the other eleven versions and all
`verify_jwt` values were unchanged. The selected handler retains in-process
authentication with its reviewed `verify_jwt=false` configuration.

All four downloaded assets matched the merged commit byte-for-byte:

| Asset under `supabase/functions/` | SHA256 |
| --- | --- |
| `submit-score-revision/index.ts` | `ab123b56c4afec4f9519a85a89f0311bc527c510ee8c2c2be25013acc052101a` |
| `_shared/app-attest.ts` | `d91a4b32810a58cecc09da311f2ce32cd974a1a83f70ff2711175f492c10cb2e` |
| `_shared/scoring_http.ts` | `8b33d8f8f2ce43585a6cd125230f50bf190ba9c20f42f60d5e533e60df4e7915` |
| `deno.json` | `df7f5e76bd541fe9a7bfc5ded59f9af9095441ffde85f51e4a009fd32359e8ec` |

By `2026-09-20T08:05:53Z`, one credential-free empty-JSON POST passed the
expected `400 invalid_request` boot boundary. Temporary downloaded source and
generated metadata were removed afterward. No migration, secret, scheduler,
other Function, account, invitation, phone, or production change occurred.

## Physical evidence remains separate

The first post-promotion READ ONLY aggregate query found the preserved
competition with two accepted participants and two available creator revisions.
There was one current registered key, assertion counter zero, one fully bound
consumed enrollment chain, zero such assertion chains, and no current result.
Only counts were retained; no identity, token, proof, score, or Health value
was returned. These facts do not pass the assertion gate.

Mirroring then reported `Mac Locked`; one Connect attempt did not resolve it.
Its Minimize command was used, and no HealthComp launch or refresh occurred.
No iOS source, project, or configuration changed in this server correction,
so it does not itself require a phone rebuild or reinstall.

Once device availability and artifact/profile binding are verified, use one
genuine changed/new-day score opportunity. Require an accepted assertion on
the existing registered key with an increased counter, not another replacement
enrollment. Any consumed-capability replay check must establish exact binding,
unexpired deadlines, expected denial, and unchanged protected state. Label
owner-assisted database-contract checks separately from captured-byte HTTP or
cryptographic replay. Do not fabricate Health data or repeat login/invitations.

The actual seven-day lifecycle, remaining physical/background/APNs/replacement/
deletion evidence, contained recovery rehearsal, and production promotion remain
open. This checkpoint does not amend those acceptance requirements.
