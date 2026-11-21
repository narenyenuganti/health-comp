# ADR-0002: CompetitionCore Journal, Replay, and Privacy Contracts

- **Status:** Accepted
- **Date:** 2026-11-21
- **Scope:** `Modules/CompetitionCore/`

## Context

`CompetitionCore` is the pure domain and replay engine shared by the iOS app, tests, and fixtures. Persisted journals must remain deterministically replayable across app versions while never leaking raw HealthKit diagnostics, authorization inferences, or wire hashes into durable journals or terminal projections.

## Decisions

### 1. Immutable Persisted Payload Schema Mirrors
- `CompetitionEventStore.swift`: Payload versions 1, 2, and 3 are decoded through frozen private schema mirrors (`ActivityStandModeV1`, `CompetitionDomainEventV2`, `CompetitionDomainEventV3`) independent of the live `CompetitionDomainEvent` union. Adding a new live union case or v4 field must never silently broaden older envelope decoders.
- New writes use payload version 4; envelopes preserve exact encoded bytes and semantic duplicate checks compare decoded values.
- `ActivitySnapshot.swift`: The `init(..., isPaused: Bool)` initializer preserves the payload-v1 construction surface while mapping into the explicit `ActivityPauseState` model introduced in payload v2.
- `CompetitionJournalCursor`: Sequences are one-based; `unknownSequence` (`0`) indicates an unsupported future envelope that did not expose a v1 sequence field.

### 2. Canonical Binary Commitments (Genesis & Opponent Plan)
- `CompetitionEventStore.swift` (`CompetitionGenesis` commitment v1): Computed over canonical binary bytes (`JournalCanonicalBytes`) independent of JSON number/date formatting—domain tag `"healthcomp.competition-genesis"`, schema, UUID, direction, reference-date IEEE bits, optional expiry, scoring-policy identity, and downward-revision policy. Strings are `UInt64`-length-prefixed; integers are fixed-width big-endian.
- `OpponentPlan.swift` (commitment v1): Encoded via `CanonicalBinaryEncoder` in fixed order—domain `"healthcomp.opponent-plan"`, schema, generator, seed, difficulty, explicit schedule, then all days and checkpoints—with `UInt32`-length-prefixed strings and big-endian integers. The commitment itself is excluded. Optional `opponentName` is appended only when present so v1–v3 commitments remain byte-identical.
- `OpponentPlan.matches(_:)` binds complete tally content to the exact immutable plan (commitment identity and every per-day final point); totals alone are deliberately insufficient.

### 3. Journal Ancestry, Validation Seam, and Tombstone Deletion
- `CompetitionEventStore.swift`: `CompetitionJournal.init(validating:...)` is `internal` so only storage adapters and adversarial tests construct from already-stored envelopes while running full replay validation; external callers cannot publish an unchecked stream.
- `CompetitionJournal.relationship(to:)` compares exact persisted ancestry; a nonempty prefix must terminate cleanly between append commits (sharing bytes mid-commit is `.divergent`).
- `CompetitionJournalStore.delete(_:expectedCursor:)` deletes a live stream only while the cursor still matches under the store lock; once the durable tombstone commit point is reached, retries are idempotent regardless of cursor.
- `CompetitionEventStore.finalReadEvidence(after:)` constructs evidence that must be appended immediately after the refresh event in the same journal commit without mutating the receiver.

### 4. Remote vs. Simulated Protocol Isolation
- `CompetitionLifecycle.swift`: `RemoteCompetitionConfiguration` (v4-only, carrying `backendDescriptorRevision` = `next_server_seq - 1` at acceptance) sits alongside—never inside—the simulated acceptance payload, preventing older journals from reinterpreting an opponent plan as a human participant.
- `CompetitionEventStore.swift` (`CompetitionReplayer`): Remote journals accept only server-accepted remote rows; local HealthKit refreshes are simulated-protocol evidence and are rejected on remote competitions.
- `CompetitionEventStore.swift`: Because no separate acceptance timestamp is stored, `.remoteConfigurationAccepted` falls back to `acceptedSchedule.startDay` as its closest bound.
- `CompetitionEventStore.swift`: `remoteLatestRecordedAt` (newest Health read time per participant across accepted remote revisions) is derived on replay and never persisted.
- Empty remote history at attestation or deadline: An owner or participant with no accepted rows may attest best-available with an all-zero vector (validated without manufacturing score evidence), whereas the stable attestation branch still requires accepted rows.

### 5. Remote Score Ledger Ordering and Ring Backfill Equality
- `RemoteParticipant.swift`: Holds only the immutable backend profile identity; mutable presentation metadata (display name, avatar) belongs to the application layer, never replayable state.
- `RemoteScoreLedger.swift`: `RemoteAcceptedScoreRow` stores server-accepted scores without local HealthKit data or source fingerprints. `ringBasisPoints` (Move/Exercise/Stand summing to accepted score) is display-only and `nil` on older rows. Because `wireContentSHA256` already binds the ring values, equality ignores `ringBasisPoints` so an older stored row matches its ring-bearing replay, and `accept(_:)` backfills `ringBasisPoints` in place when a replay carries them.
- `RemoteScoreLedger.acceptedHistory` persists full accepted history so exact replays remain idempotent and server cursor collisions stay detectable after a day is superseded. Client revisions are participant-global across days, so a lower revision whose response was lost can arrive out of order after a later revision; it is retained in history while `visibleEntry(forActiveDayOrdinal:)` (pure lookup; calendar/lifecycle gates apply downstream) returns the highest revision per day.

### 6. Time-Zone Window End, Finalization Stability, and Move-Mode Resets
- `CompetitionLifecycle.swift` (`localWindowEnd(in:)`): Health reads days by local calendar date, so a player west of the frozen competition calendar is still filling day 7 after the match moves to tallying; stable attestation waits for this instant (capped by `bestAvailableDeadline`).
- `FinalizationPolicy.swift`: Reads whose actual timestamp precedes the competition boundary are persisted as events but excluded from reconciliation decision state. An incomplete window read represents absence of evidence—it updates latest read metadata without destroying a previously established complete stability anchor.
- `ScoreLedger.swift`: A mid-day Move goal type or wheelchair-status change restarts the day's maximum in the new mode so the accepted score always matches the mode of its underlying evidence.

### 7. Privacy-Safe Diagnostics, Terminal Projections, and Durable Notification Episodes
- `ActivityRefreshAttempt.swift`: `ActivityQueryFailureReason` and `ActivityUnavailableReason` are deliberately closed, non-diagnostic enums; HealthKit error descriptions and authorization-denial inferences never enter the durable journal.
- `CompetitionSemanticTerminalProjection.swift`: Non-persisted, transport-independent comparison projection that excludes monotonic timing metadata, OS notification delivery state, wire content hashes, and HealthKit fingerprints (`RemoteDay.wireContentSHA256` stays a non-encoded `nil` affordance). Simulated fields keep their original types and coding keys so simulated golden terminal bytes remain unchanged; remote finalization sets `ledgerIsFrozen = true` (server result is immutable terminal evidence) and retains an in-memory `downwardRevisionPolicy = .maximumObserved` solely for the shared type while omitting it from the remote wire shape.
- `NotificationEmission.swift`: Records only durable one-time opportunistic notification episode decisions (`NotificationEpisodeKey` encodes to the semantic notification identifier suffix). Calendar-scheduled requests are derived state and intentionally excluded; no copy, activity values, or OS delivery claims enter the domain model.
