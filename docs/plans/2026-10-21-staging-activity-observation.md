# Staging Activity-to-submission observation

## Boundary

The ordinary refresh can complete without producing a new score request. The
existing failed-response capture cannot explain a request that was never made.
Add an independent, default-off observation to the existing Staging diagnostic
page. This is a diagnostic aid, not a scoring fix or production qualification.

Do not change Activity reads, normalized scores, revision identity, retries,
terminal entries, authentication, App Attest, or any server contract. No new
dependency, SDK fork, remote call, saved diagnostic file, or debugger is needed.
The existing response-reference capture remains independent and unchanged.

## Readout

- Explicitly observe the next manual pull-to-refresh, within ten minutes.
- Collect only fixed, bounded counts: read start/completion/failure, days with
  or without summaries, future days, skipped lifecycles, unchanged saved or
  accepted revisions, unchanged terminal revisions, completed revision enqueue
  operations, missing runtime dependencies, and reconciliation failures.
- Counts cover every competition evaluated by that refresh. They contain no
  identifiers, dates, ring values, score values, Health samples, proof material,
  request references, or arbitrary text. An enqueue operation is neither proof
  of a unique new entry nor server acceptance.
- Count reconciliation failures from the returned discovery/per-competition
  failures, once each; separately report Activity-source read failures.
- Keep the observation in RAM only. Clear it on explicit cancellation, expiry,
  app inactivity, authentication-owner retirement, or replacement. Reading it
  never extends the deadline. Expiry is checked on access, not by an independent
  timer. Do not promise instantaneous or secure memory erasure or prevent users
  from taking screenshots.
- Scope counters to the selected refresh's task tree. Ignore unrelated work,
  late work from retired owners, and work after completion. A new observation
  requires a new app process or authentication-owner session and explicit
  operator arming; replacing an owner must never carry over the prior counts.

## Verification

Use the existing operator-controls and `RemoteCompetitionRuntime.synchronizeAll`
interfaces. Native synthetic tests cover default-off behavior, immutable result
and error propagation, bounded counts, expiry, cancellation, unrelated work and
owner replacement. The existing runtime fixture checks counts while still
verifying its ordinary accepted score behavior. Compile the Staging app and
retain the non-Staging absence guard, then independently review the immutable
change and pass exact-head CI before integration.

The runtime fixture uses DEBUG's existing synthetic Activity source with the
Staging observation condition enabled for that test build only. It is not a
release-style build; the separate Staging compile and test target preserve that
distinction and include the operator tests without enabling DEBUG.

Source-only verification does not authorize or prove a physical install or live
observation. Preserve the current competition and history. The misleading remote
Activity Sync timestamp label is a separate finding, not proof that HealthKit
was or was not read.
