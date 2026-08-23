# Remote Activity Refresh Isolation Design

## Problem

Hosted staging returns a gap-free two-participant competition descriptor and
history, and the exact-current client durably materializes that history before
advancing its local clock. If the following on-device Activity-window read
fails, `RemoteCompetitionRuntime.synchronize` currently throws from the entire
per-competition operation. The coordinator therefore publishes `No
Competition` with a generic competition-failure warning even though the
server-owned descriptor and append-only history were valid.

This couples remote competition visibility to HealthKit availability. It also
prevents the descriptor cursor from being cached, so every reconciliation
replays the full server history before reaching the same device-local failure.

## Decision

Keep remote materialization authoritative and model Activity refresh as a
nonfatal sub-result. A synchronization that validates the descriptor, replays
the gap-free history, advances the local clock, and then receives a typed
`CompetitionActivitySourceError` will return:

- a successful `RemoteCompetitionMaterialization` for publication and cursor
  persistence; and
- a separate competition-scoped Activity refresh failure for truthful UI
  reporting and later retry.

The coordinator will publish the competition and surface a dedicated
`activityFailures` issue. The Sharing UI will explain that the competition is
available while Activity could not be refreshed. Existing environment signals
and explicit reconciliations will retry the read.

Cancellation, server-contract failures, storage failures, outbox failures,
App Attest failures, and score-submission failures remain fatal to the same
boundaries they guard. No missing or synthetic HealthKit values are converted
into a score, and no server sequence, idempotency, profile-isolation, or raw-
HealthKit-on-device contract changes.

## Alternatives considered

1. **Keep the all-or-nothing operation and add diagnostics.** This would
   identify the HealthKit failure but continue hiding a valid competition and
   replaying full history. Rejected because it preserves the broken product
   behavior.
2. **Treat every score-refresh error as nonfatal.** This could conceal outbox,
   persistence, App Attest, or server failures. Rejected because it weakens
   fail-closed contracts.
3. **Depend on Simulator HealthKit becoming available.** This would not repair
   the same coupling on locked, protected-data, or temporarily failing physical
   devices. Rejected as an environmental workaround.

## Verification

A focused runtime test will begin with a scheduled two-participant history and
a typed failing Activity source. Before the implementation it must reproduce
the current failed materialization. Afterward it must prove one successful
competition, one scoped Activity failure, a persisted cursor, and no score
submission. A client-level test will prove the competition remains visible and
the dedicated issue reaches presentation. Existing success and fatal-failure
tests must remain green before the full hosted matrices run.
