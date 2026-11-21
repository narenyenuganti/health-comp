# ADR-0008: Remote Sync, HealthKit Ownership, and Group Match Runtime

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `HealthComp/Services/`, `HealthComp/Features/Competition/RemoteCompetitionClient.swift`, `HealthComp/Features/Competition/LocalCompetitionClient.swift`, `HealthComp/Features/Competition/PracticeMatch.swift`

## Context

Score synchronization spans process-rooted HealthKit observer callbacks, wake-up-only Supabase Realtime channels, a shared persistent outbox for duels and group matches, App Attest serialization, and multi-version server RPC compatibility.

## Decisions

### 1. Process-Rooted HealthKit Signal Ownership and Privacy
- `HealthKitProvider.swift`, `HealthKitDeliveryDiagnostic.swift`, `RemoteCompetitionRuntimeFailure.swift`:
  - HealthKit observer callback completion ownership lives in a process-rooted registry (`productionOwnershipRegistry`) so runtime replacement replays pending callbacks instead of dropping or completing them before a durable journal receipt is persisted.
  - HealthKit observer descriptors are wake-up signals only (never persisted as evidence) and trigger an authoritative one-shot reread.
  - Read authorization denial is never inferred or exposed: characteristic read failures keep `standMode = .unknown` while preserving numeric ring readings, and authorization-like query errors map to `.unclassifiedQueryFailure`. Diagnostic enums accept fixed static labels only—never IDs, Health values, tokens, or error descriptions.
  - Date component queries omit explicit component time zones because setting one can filter out otherwise-readable day summaries.
  - `HealthKitObserverDeliveryReceipt` stores committed signal IDs in process-lifetime memory only because signal IDs embed a per-process UUID.
  - `FixtureActivitySource.swift` re-checks `Task.checkCancellation()` at suspension boundaries so virtual time never resumes a continuation ahead of actor-bound cancellation cleanup.

### 2. Local Journal Recency, Monotonic Identity, and Event Store Isolation
- `LocalCompetitionRuntime.swift`, `JSONCompetitionEventStore.swift`, `JSONCompetitionOutboxStore.swift`, `CompetitionEnvironmentClient.swift`:
  - Append order is not read recency: a slower writer can commit an older HealthKit read first, so refresh suppression compares against the newest completed read (falling back to wall time across reboot/clock-uncertainty boundaries). Durable attempt semantic IDs depend only on logical ordinal—never process epoch or uptime.
  - One unreadable journal in `JSONCompetitionEventStore` still lists its ID so `load(id)` reports failure for that match alone without hiding healthy matches.
  - `JSONCompetitionOutboxStore` validates canonical wire bytes for whole-second timestamps rather than requiring lossy in-memory `Date` equality.
  - `CompetitionEnvironmentClient` guards `rounded < Double(UInt64.max)` before `UInt64` conversion because `Double(UInt64.max)` rounds up to `2^64` and traps.
  - `LocalCompetitionClient` derives deterministic `opponentSeed` (FNV-1a 64 over domain + RFC-4122 UUID bytes) and `rematchID` (UUID v5 over domain + UUID bytes) as stable persistence formats, and delivers publications inside an `NSRecursiveLock` so subscribers observe publications, replay, and finish in one total order.

### 3. Outbox Ordering, Revision Non-Reuse, and Partitioning
- `CompetitionSyncCoordinator.swift`, `RemoteCompetitionRuntime.swift`, `RemoteGroupMatchClient.swift`:
  - Because the server refuses a revision lower than one it already holds, `CompetitionSyncCoordinator` drains each match's score uploads in queue order (`heldCompetitionIDs` holds later uploads for a match behind an in-flight/backed-off upload) while letting other matches proceed.
  - `RemoteCompetitionRuntime` reads the outbox *before* the ledger so any upload accepted mid-pass appears in at least one of the two, guaranteeing a spent `clientRevision` is never reused. `GroupMatchStore.allocateRevision` persists the next revision before queuing so crashes leave gaps rather than reused revisions.
  - `GroupOutboxPartition` gives group matches and duels separate drain coordinators over the same shared outbox (tagged by semantic-ID domain) so a stalled request in one family never blocks the other; terminal stop cancels both coordinators simultaneously because they share App Attest's one-at-a-time gate.
  - Unrecordable server contract mismatches park only their own entry as `.permanentFailure` (kept support-inspectable until the match finishes) rather than stalling the queue. `.attestationAcknowledged` entries stay in the outbox until the authoritative change feed or group read model materializes them.
  - `RemoteCompetitionRuntime` marks its inventory file `isExcludedFromBackup = true` after every atomic rename so exact `ownerActivity` Health values never enter backups. `GroupMatchStore` uses plain atomic file replacement (without the duel store's `fsync` dance) because any lost write after power loss rebuilds from server heads on refresh.
  - When a player's wheelchair status is `.unknown`, `RemoteCompetitionRuntime` maps scored days to stand hours because the wire protocol rejects `.unknown` on scored days and the stand ring numeric value is identical.
  - Finished matches journaled before rows stored `ringBasisPoints` trigger a one-time display-only `ringBackfill` read of their feed.

### 4. Reconciliation, Transient Failure Suppression, and Terminal Teardown
- `RemoteCompetitionClient.swift`, `CompetitionRealtimeClient.swift`, `SupabaseCompetitionRealtimeClient.swift`:
  - Realtime channels are strictly wake-up hints (never authoritative state). `SupabaseCompetitionRealtimeClient` registers `broadcastStream` synchronously before subscribing, guards post-cleanup channel creation with `activeGeneration`, and stops late-opening drivers when cancelled before reporting retirement.
  - `RemoteCompetitionClient` coalesces bursts of HealthKit/Realtime wake-ups through one `reconcileDrainTask`, runs group sync alongside duels so slow group reads never delay duel publications, and retries a retryable failure once (after `1s`)—or drains a queued wake-up—before publishing so transient wake-up errors or expired-JWT refreshes never flash `"Couldn't update scores"`.
  - Source activation is the atomic profile ownership reservation; on terminal stop/teardown, signal and realtime tasks are cancelled *before* joining the operation gate so suspended external work unwinds cleanly while preserving completion-bearing signals for the quiesce/drain phase.
  - `RemoteInviteRequestStore` caches pending challenge creation requests for 25 hours (24h expiry + 1h clock-skew slack) so pending links can be deterministically replayed after relaunch without storing any secret.
  - Practice matches run on a separate `LocalCompetitionRuntime` that only reads Health (never claiming HealthKit observer ownership), caps pacer reveals to once per 5 minutes while Home is open, and deletes expired finished practice journals once they leave Home so Health data does not linger.

### 5. Supabase Wire Compatibility, Expired-JWT Refresh, and Staging Capture
- `SupabaseCompetitionRemoteAPI.swift`, `CompetitionSyncModels.swift`, `StagingScoringOperatorControls.swift`, `StagingScoringResponseCapture.swift`:
  - `SupabaseClient`'s default request adapter uses `try? await auth.session`, which swallows wake-up network errors on an expired JWT and sends an unauthenticated request that fails `401`. `SupabaseCompetitionRemoteAPI` explicitly refreshes an expired current session before sending.
  - Device installation registration tries the newest overload first and falls back strictly on `PGRST202` (8 args group matches → 7 Friends → 6 muted push kinds → 5 reactions → 4 challenges → 3 legacy), throwing all other errors including `404`.
  - `GroupMatchWire` decodes `list_group_matches` atomically (rejecting the entire response on any malformed field so partial reads never replace the cache), encodes 64-bit integers as decimal strings (never JSON numbers), and validates every score row by recomputing its `RemoteScoreRevisionWireV1` digest.
  - `strictBool` rejects numeric `0`/`1` that Swift's `as? Bool` accepts on JSON booleans; list decoders skip individual unreadable rows (e.g., unknown time zones) so one bad row never hides the rest.
  - `StagingScoringResponseCapture` is default-off and RAM-only; debugger entry points (`@objc arm()`) never wait on a stopped thread's lock, and multiple matching tasks before destructive retrieval close as ambiguous rather than misattributing a response.

### 6. Watch Sync and Widget Snapshot Publishing
- `CompetitionWatchSync.swift`, `CompetitionWidgetSnapshotClient.swift`:
  - `CompetitionWatchSync` runs on a serial queue so slow re-reads cannot stamp a newer `sentAt` than a later mirror, throttles complication transfers to every 30 minutes (conserving Apple's ~50/day budget for evening scores) without letting a signed-out clear throttle the first signed-in snapshot, and skips wiping the watch when a snapshot file exists on disk but fails to decode.
  - `CompetitionWidgetSnapshotClient` loads `lastWritten` on startup to avoid redundant WidgetKit reloads, reloads only when `ignoringUpdatedAt` changes materially, carries forward matches whose sync failed or was cancelled, sets `updatedAt` to the *older* of owner and opponent read times (so a fresh opponent never hides your stale score), and clears widgets/reminders/Live Activities on every signed-out path.
